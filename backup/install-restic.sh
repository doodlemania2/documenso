#!/usr/bin/env bash
#
# install-restic.sh — install restic, the backup scripts and the systemd units
# on doodlessd. Idempotent: safe to re-run to upgrade restic or refresh the
# scripts.
#
# Run as root from a checkout of this repo:
#   sudo ./backup/install-restic.sh
#
# WHY restic, and not the alternatives:
#   - Encrypted client-side, always. Not optional, not a flag. That is what
#     makes it acceptable to ship /etc/oltp-relay, the stacks' .env files and
#     a full Documenso dump to somebody else's bucket.
#   - Content-defined chunking with real deduplication. A daily pg_dumpall of a
#     slowly-changing database costs almost nothing after the first one.
#   - One static binary, no daemon, no database on the client. Nothing to
#     babysit, and nothing that can be "the backup service is down".
#   - Many backends behind one interface (sftp, s3, b2, rclone, azure), so the
#     destination can be chosen — and changed — without touching these scripts.
#   - Restores are file-granular and can be mounted (`restic mount`), which is
#     what makes the restore rehearsal in restore-rehearsal.sh cheap enough to
#     actually happen.
#
# borg was the other serious candidate and loses on one point that matters
# here: it needs borg installed on the REMOTE end for remote repositories,
# which constrains the destination choice before Derek has made it.
#
# WHY NOT the Ubuntu package: noble ships restic 0.16.4. Repository format v2
# (native compression) and several prune correctness fixes landed after that.
# The upstream binary is a single self-contained file with a published
# checksum, so there is no reason to take the stale one.

set -euo pipefail

RESTIC_VERSION="0.19.1"
# From https://github.com/restic/restic/releases/download/v0.19.1/SHA256SUMS
# Verify this line by hand when bumping the version. An unverified download of
# the thing that holds every secret on the host is not a shortcut worth taking.
RESTIC_SHA256="f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c"

SBIN_DIR="/usr/local/sbin"
LIB_DIR="/usr/local/lib/doodlessd-backup"
CONF_DIR="/etc/doodlessd-backup"
UNIT_DIR="/etc/systemd/system"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '==> %s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run as root"

# ---------------------------------------------------------------------------
# restic
# ---------------------------------------------------------------------------
if [[ "$(restic version 2>/dev/null | awk '{print $2}')" == "$RESTIC_VERSION" ]]; then
  log "restic ${RESTIC_VERSION} already installed"
else
  log "installing restic ${RESTIC_VERSION}"
  tmp="$(mktemp -d)"
  # Trap on EXIT rather than cleaning up at the end: an error between here and
  # there would otherwise leave a directory in /tmp on every failed attempt.
  trap 'rm -rf "$tmp"' EXIT

  url="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2"
  curl -fsSL --retry 3 -o "${tmp}/restic.bz2" "$url"

  echo "${RESTIC_SHA256}  ${tmp}/restic.bz2" | sha256sum -c - \
    || die "checksum mismatch on the restic download — do NOT install it"

  bunzip2 "${tmp}/restic.bz2"
  # install(1), not mv: sets mode and ownership atomically, and replacing the
  # binary in place while a backup is mid-run is safe because the running
  # process holds the old inode.
  install -m 0755 -o root -g root "${tmp}/restic" "${SBIN_DIR}/restic"
  # /usr/local/sbin is not on a non-login PATH for all tools; the units use an
  # absolute path, but an operator's interactive `restic` should find it too.
  ln -sf "${SBIN_DIR}/restic" /usr/local/bin/restic
  log "installed $(restic version)"
fi

# ---------------------------------------------------------------------------
# Scripts
# ---------------------------------------------------------------------------
log "installing scripts"
install -d -m 0755 "$LIB_DIR"
install -m 0644 "${SRC_DIR}/lib-otlp.sh"                "${LIB_DIR}/lib-otlp.sh"
install -m 0755 "${SRC_DIR}/doodlessd-backup.sh"        "${SBIN_DIR}/doodlessd-backup.sh"
install -m 0755 "${SRC_DIR}/doodlessd-prune.sh"         "${SBIN_DIR}/doodlessd-prune.sh"
install -m 0755 "${SRC_DIR}/doodlessd-backup-failed.sh" "${SBIN_DIR}/doodlessd-backup-failed.sh"
install -m 0755 "${SRC_DIR}/restore-rehearsal.sh"       "${SBIN_DIR}/doodlessd-restore-rehearsal.sh"

# ---------------------------------------------------------------------------
# Config
#
# Never overwrite an existing backup.env. It holds the repository password, and
# clobbering it with the template would strand every existing snapshot behind a
# password nobody has.
# ---------------------------------------------------------------------------
install -d -m 0700 -o root -g root "$CONF_DIR"
if [[ -e "${CONF_DIR}/backup.env" ]]; then
  log "${CONF_DIR}/backup.env exists — leaving it alone"
else
  install -m 0600 -o root -g root "${SRC_DIR}/backup.env.example" "${CONF_DIR}/backup.env"
  log "wrote ${CONF_DIR}/backup.env from the template — EDIT IT before enabling the timer"
fi

install -d -m 0700 -o root -g root /var/backups/doodlessd

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
log "installing units"
install -m 0644 "${SRC_DIR}/systemd/doodlessd-backup.service"    "${UNIT_DIR}/"
install -m 0644 "${SRC_DIR}/systemd/doodlessd-backup.timer"      "${UNIT_DIR}/"
install -m 0644 "${SRC_DIR}/systemd/doodlessd-prune.service"     "${UNIT_DIR}/"
install -m 0644 "${SRC_DIR}/systemd/doodlessd-prune.timer"       "${UNIT_DIR}/"
install -m 0644 "${SRC_DIR}/systemd/doodlessd-backup-failed@.service" "${UNIT_DIR}/"
systemctl daemon-reload

cat <<'NEXT'

==> Installed. NOT enabled — the timers stay off until the destination is real.

Next, in order:

  1. Edit /etc/doodlessd-backup/backup.env
       - RESTIC_REPOSITORY  must point OFF this machine
       - RESTIC_PASSWORD    generate it, then store it in the password manager
                            BEFORE step 2. There is no recovery without it.
       - OTLP_API_KEY       relayctl issue --tenant doodlessd-backup

  2. Initialise the repository (once, ever):
       set -a; . /etc/doodlessd-backup/backup.env; set +a
       restic init

  3. Take one backup by hand and watch it:
       systemctl start doodlessd-backup.service
       journalctl -u doodlessd-backup.service -f

  4. Rehearse a restore BEFORE trusting any of it:
       doodlessd-restore-rehearsal.sh

  5. Only then:
       systemctl enable --now doodlessd-backup.timer doodlessd-prune.timer

NEXT
