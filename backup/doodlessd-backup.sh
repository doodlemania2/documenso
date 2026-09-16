#!/usr/bin/env bash
#
# doodlessd-backup.sh — the whole-host backup for doodlessd.
#
# Runs as root from doodlessd-backup.service (daily timer). Installed at
# /usr/local/sbin/doodlessd-backup.sh, config at
# /etc/doodlessd-backup/backup.env.
#
# Scope is the HOST, not Documenso. Before this existed the box had no backups
# of any kind: no restic, no borg, no duplicity, no rclone, no cron job, no
# timer. It fronts every hostname we serve, so the blast radius of losing it is
# not one app.
#
# Order of operations matters and is deliberate:
#   1. Preflight — refuse early and loudly rather than produce a partial set.
#   2. Stage the things that cannot be safely file-copied (Postgres, SQLite).
#   3. Hand restic ONE list containing both the staged dumps and the live paths.
#   4. Report, whether it worked or not.

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/doodlessd-backup/backup.env}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/doodlessd-backup}"
LOCK_FILE="/run/doodlessd-backup.lock"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Serialise against the prune job.
#
# restic takes its own repository lock, but its error on contention is a
# stack-trace-shaped message about a locked repo that reads like corruption.
# A local flock fails in one obvious line instead. -n: do not queue behind a
# running prune — if a prune is mid-flight the next timer tick is soon enough,
# and a queued backup that starts hours late is worse than a skipped one.
# ---------------------------------------------------------------------------
exec 9>"$LOCK_FILE"
flock -n 9 || die "another doodlessd-backup or prune run holds $LOCK_FILE"

[[ -r "$CONFIG_FILE" ]] || die "config $CONFIG_FILE is missing or unreadable"
set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a
# shellcheck source=/dev/null
source "${LIB_DIR}/lib-otlp.sh"

START_EPOCH="$(date +%s)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE_DIR="${STAGE_DIR:-/var/backups/doodlessd}"
PG_CONTAINERS="${PG_CONTAINERS:-}"
EXTRA_SOURCES="${EXTRA_SOURCES:-}"

# ---------------------------------------------------------------------------
# Failure reporting.
#
# The systemd unit also carries OnFailure=, which covers the cases this trap
# cannot reach (OOM-kill, SIGKILL, the script failing to start at all). Both
# exist on purpose: this trap knows WHICH step failed, the unit-level hook only
# knows THAT something did.
# ---------------------------------------------------------------------------
CURRENT_STEP="startup"
on_error() {
  local rc=$?
  otlp_log ERROR 17 "doodlessd backup FAILED during '${CURRENT_STEP}' (exit ${rc}), run ${RUN_ID}"
  log "FAILED during '${CURRENT_STEP}' with exit ${rc}"
  exit "$rc"
}
trap on_error ERR

cleanup() {
  # The staging directory holds a plaintext dump of every database on this
  # host. Leaving it behind would put an unencrypted copy of the Documenso
  # database — signatures, audit trail and all — on the local disk between
  # runs, which is precisely the exposure the encrypted repository avoids.
  if [[ -n "${STAGE_DIR:-}" && -d "$STAGE_DIR" ]]; then
    rm -rf -- "${STAGE_DIR:?}"/*
  fi
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
CURRENT_STEP="preflight"
[[ "$(id -u)" -eq 0 ]] || die "must run as root (reads /etc/oltp-relay and the NPM data directory)"
command -v restic >/dev/null || die "restic is not installed — run install-restic.sh"
command -v docker >/dev/null || die "docker is not installed"
command -v python3 >/dev/null || die "python3 is required for the SQLite hot copy"

[[ -n "${RESTIC_REPOSITORY:-}" ]] || die "RESTIC_REPOSITORY is unset. Pick an OFF-MACHINE destination — a repository on doodlessd protects nothing."
if [[ "$RESTIC_REPOSITORY" == REPLACE_ME* ]]; then
  die "RESTIC_REPOSITORY is still the placeholder"
fi
[[ -n "${RESTIC_PASSWORD:-}" ]] || die "RESTIC_PASSWORD is unset"

# Refuse a repository that lives on the machine being backed up. This is the
# single most common way a backup system ends up worthless, and it looks
# perfectly healthy right up until the disk it is on is the thing that died.
case "$RESTIC_REPOSITORY" in
  /*|local:/*)
    die "RESTIC_REPOSITORY points at local path '$RESTIC_REPOSITORY'. A backup stored on the machine it protects is not a backup." ;;
esac

# Prove the repository is reachable and the password is right BEFORE spending
# time on dumps. `restic cat config` is the cheapest call that exercises
# network, credentials and decryption together.
restic cat config >/dev/null 2>&1 \
  || die "cannot open repository $RESTIC_REPOSITORY — wrong password, bad credentials, or it was never initialised (see backup/README.md)"

install -d -m 0700 -o root -g root "$STAGE_DIR"

# ---------------------------------------------------------------------------
# Postgres — logical dumps
#
# WHY THE VOLUME IS NOT ENOUGH, and this is the part people skip:
#
# A file-level copy of a running Postgres data directory is not a backup. The
# postmaster writes 8KB pages while your copy walks the tree, so you capture
# some files before a write and some after — torn pages, an index pointing at a
# row version that is not in the heap you copied, a control file describing a
# WAL position whose segment you missed. The copy still *looks* fine: it is the
# right size, restic reports success, the volume mounts. It fails only when you
# restore it, under pressure, and Postgres refuses to start or — worse — starts
# and serves subtly wrong data.
#
# A physical backup CAN be made consistent, but only with pg_basebackup or
# pg_start_backup()/pg_stop_backup() plus every WAL segment generated in
# between. That is a whole extra mechanism with its own failure modes. For a
# database this size, a logical dump is consistent by construction: pg_dumpall
# runs inside one snapshot-isolation transaction, so it is a point-in-time view
# no matter what the application does during it.
#
# pg_dumpall, not pg_dump: it also captures roles and grants. A restore that
# recreates the tables but not the role that owns them fails on the first
# GRANT and leaves you debugging permissions during an outage.
#
# The dump runs INSIDE the container. The host's pg_dump is 16.15 and the
# container runs Postgres 17, and pg_dump refuses to dump a server newer than
# itself ("server version 17.x; pg_dump version 16.x"). Using the container's
# own binaries makes that class of skew impossible, now and after any future
# major-version bump.
# ---------------------------------------------------------------------------
CURRENT_STEP="postgres dumps"
for container in $PG_CONTAINERS; do
  if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
    # Not fatal on its own — a stack may legitimately be stopped — but it must
    # be loud, because "the database container was down so we skipped it" is
    # not something to discover at restore time.
    otlp_log WARN 13 "postgres container '${container}' is not running; NO dump was taken this run"
    log "WARN: container '$container' is not running, skipping dump"
    continue
  fi

  pg_user="$(docker exec "$container" printenv POSTGRES_USER 2>/dev/null || echo postgres)"
  out="${STAGE_DIR}/pg_dumpall_${container}.sql"

  log "dumping $container as role '$pg_user'"
  # -u postgres + the container's unix socket: the official image trusts local
  # connections, so no password crosses the process table or ends up in `ps`.
  #
  # --clean --if-exists makes the dump idempotent to replay onto a cluster that
  # already has objects, which is what a real restore looks like.
  #
  # NOT gzipped, deliberately. restic's repository format v2 compresses
  # natively, and pre-compressing would destroy deduplication: two consecutive
  # daily dumps of a barely-changed database are ~99% identical as plain SQL
  # and share almost every chunk, but their gzip output differs from the first
  # changed byte onward, so every day would store a whole new copy.
  docker exec -u postgres "$container" \
    pg_dumpall --clean --if-exists --username="$pg_user" > "$out"

  # A zero-length or truncated dump is the failure this whole script exists to
  # prevent. Check it here, while it is still a fixable error rather than a
  # discovery during a restore.
  [[ -s "$out" ]] || die "dump of $container is empty"
  grep -q 'PostgreSQL database cluster dump complete' "$out" \
    || die "dump of $container is truncated — no completion marker"
  chmod 600 "$out"
  log "  $(wc -c < "$out") bytes"
done

# ---------------------------------------------------------------------------
# nginx-proxy-manager — SQLite hot copy
#
# Losing NPM's configuration means every hostname on this box stops working:
# the proxy hosts, the Let's Encrypt certificates and their renewal state, the
# access lists. It is the single highest-leverage thing on the server and it
# lives in one 300KB SQLite file plus a keys.json.
#
# The same tearing argument as Postgres applies, in miniature: copying
# database.sqlite while NPM has a write transaction open can capture a file
# with a hot journal and no matching -wal, which SQLite will refuse or silently
# roll back. sqlite3's online backup API takes a consistent copy of a live
# database without stopping the writer, and python3's stdlib exposes it — no
# extra package on the host, which matters because the sqlite3 CLI is NOT
# installed here and neither is it in the NPM image.
# ---------------------------------------------------------------------------
CURRENT_STEP="npm sqlite copy"
NPM_DATA="${NPM_DATA:-/data/compose/27/data}"
if [[ -f "${NPM_DATA}/database.sqlite" ]]; then
  log "hot-copying nginx-proxy-manager database"
  python3 - "$NPM_DATA/database.sqlite" "${STAGE_DIR}/npm-database.sqlite" <<'PY'
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
# Read-only URI so this can never write to NPM's live database, even on a bug.
s = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
d = sqlite3.connect(dst)
with d:
    s.backup(d)
d.close(); s.close()
PY
  chmod 600 "${STAGE_DIR}/npm-database.sqlite"
else
  otlp_log WARN 13 "expected NPM database at ${NPM_DATA}/database.sqlite and did not find it"
  log "WARN: no NPM database at ${NPM_DATA}/database.sqlite"
fi

# ---------------------------------------------------------------------------
# Host inventory
#
# Not data, but the difference between a restore and an archaeology project.
# Rebuilding this host from the file backup alone means guessing which
# containers existed, which image digests they ran and which volumes they used.
# These three files answer that in the same snapshot as the data.
# ---------------------------------------------------------------------------
CURRENT_STEP="host inventory"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}' > "${STAGE_DIR}/docker-ps.txt" || true
docker volume ls --format '{{.Driver}}\t{{.Name}}'                      > "${STAGE_DIR}/docker-volumes.txt" || true
# RepoDigests, not tags: a tag tells you what it was called, a digest tells you
# what it actually was. `latest` on three of these containers means the tag
# alone cannot reproduce the running state.
docker images --no-trunc --format '{{.Repository}}:{{.Tag}}\t{{.Digest}}'> "${STAGE_DIR}/docker-images.txt" || true
dpkg -l                                                                  > "${STAGE_DIR}/dpkg-list.txt" || true
systemctl list-unit-files --state=enabled --no-pager                     > "${STAGE_DIR}/systemd-enabled.txt" || true

# ---------------------------------------------------------------------------
# The file set
#
# Explicit list, not "/" with excludes. An allow-list cannot accidentally start
# shipping 100GB of /var/lib/docker overlay layers because someone added a
# container; a deny-list can, and you find out from the bill.
# ---------------------------------------------------------------------------
CURRENT_STEP="assembling source list"
SOURCES=(
  # The dumps and inventory produced above.
  "$STAGE_DIR"

  # nginx-proxy-manager: config, keys.json (its own encryption keys — without
  # it the SQLite rows for certificates are useless), and the nginx vhost
  # fragments it generates.
  "$NPM_DATA"
  # Let's Encrypt account keys, live certs and renewal config. Re-issuing is
  # usually possible, but not while the proxy that answers the ACME challenge
  # is the thing that is down.
  "/data/compose/27/letsencrypt"

  # Every stack's compose file and .env, by convention at /home/derek/*-stack.
  # Tiny, and they are the instructions for rebuilding everything else.
  "/home/derek/docs-stack"
  "/home/derek/npm-stack"
  "/home/derek/documenso-stack"
  "/home/derek/docker-compose.yml"

  # The relay stack: compose file and provisioning script...
  "/opt/oltp-relay/deploy"
  "/opt/oltp-relay/collector"
  # ...and its secrets, which are root-only and live outside the stack dir.
  # These are API keys and their hashes; they are in the backup because the
  # repository is encrypted before anything leaves the host.
  "/etc/oltp-relay"

  # This backup system's own configuration. A restore that cannot restore the
  # restorer is an unpleasant surprise.
  "/etc/doodlessd-backup"
)

if [[ -n "$EXTRA_SOURCES" ]]; then
  # shellcheck disable=SC2206  # word splitting is the intended behaviour here
  SOURCES+=($EXTRA_SOURCES)
fi

# Drop anything that does not exist rather than letting restic fail the whole
# run over one path. Documenso's stack directory, in particular, will not exist
# until the cutover, and backups of everything else must not wait for it.
PRESENT=()
for s in "${SOURCES[@]}"; do
  if [[ -e "$s" ]]; then PRESENT+=("$s"); else log "skip (absent): $s"; fi
done
[[ ${#PRESENT[@]} -gt 0 ]] || die "no source paths exist — refusing to write an empty snapshot"

EXCLUDES=(
  # 155MB of NPM access logs, rewritten constantly and worth nothing at
  # restore time. They dominate the NPM directory and would dominate the
  # backup's change rate.
  --exclude "${NPM_DATA}/logs"
  # Backup files someone left in a stack directory; the real thing is already
  # in the set.
  --exclude "*.bak-*"
  --exclude "*.tar.gz"
  --exclude-caches
)

# ---------------------------------------------------------------------------
# Back up
# ---------------------------------------------------------------------------
CURRENT_STEP="restic backup"
log "backing up ${#PRESENT[@]} paths to $RESTIC_REPOSITORY"
BACKUP_LOG="$(mktemp)"
trap 'rm -f "$BACKUP_LOG"; cleanup' EXIT

# --tag: `doodlessd` groups every snapshot from this host so retention and
# restores can target it even if the repository is shared with another host
# later. The run id makes one specific run addressable by name.
#
# No --one-file-system: every source is on /dev/sda2 anyway, and the flag would
# silently drop anything later moved to a separate mount.
# errexit off for this pipeline only. `set -o pipefail` is on, so a non-zero
# restic would otherwise abort the script here and the exit-3 branch below
# would be unreachable — restic's "completed, some files unreadable" would be
# reported as a hard failure every time it happened.
set +e
restic backup \
  --verbose \
  --tag doodlessd \
  --tag "run-${RUN_ID}" \
  "${EXCLUDES[@]}" \
  "${PRESENT[@]}" 2>&1 | tee "$BACKUP_LOG"
# restic is at the head of a pipe, so $? is tee's. PIPESTATUS is the only
# honest answer, and getting it wrong would make every failure look green.
rc="${PIPESTATUS[0]}"
set -e
# restic exits 3 when it completed but could not read some files. That is a
# real warning — a source may have been renamed — but not a failed backup; the
# snapshot exists and is restorable.
if [[ "$rc" -eq 3 ]]; then
  otlp_log WARN 13 "backup completed with unreadable files (restic exit 3), run ${RUN_ID}"
  log "WARN: restic exit 3 — snapshot written, some files unreadable"
elif [[ "$rc" -ne 0 ]]; then
  # The last lines are where restic says why. Carry them into the alert so the
  # notification is actionable without an ssh session.
  otlp_log ERROR 17 "doodlessd backup FAILED: restic exit ${rc}, run ${RUN_ID}
$(tail -n 20 "$BACKUP_LOG")"
  # The ERR trap would emit a second, vaguer alert; skip it.
  trap - ERR
  die "restic backup exited $rc"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
CURRENT_STEP="reporting"
DURATION=$(( $(date +%s) - START_EPOCH ))

# The heartbeat. SigNoz alerts on its ABSENCE:
#     now() - backup_last_success_timestamp_seconds > 36h
# which is the only check that catches a timer that stopped firing entirely.
# An OnFailure hook cannot fire for a unit that never ran.
otlp_gauge "backup.last_success.timestamp" "$(date +%s)" "s"
otlp_gauge "backup.duration"               "$DURATION"   "s"

# Snapshot count is a cheap corruption/retention canary: if it stops growing
# while backups report success, forget/prune is eating more than it should.
if snap_count=$(restic snapshots --tag doodlessd --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null); then
  otlp_gauge "backup.snapshot.count" "$snap_count" "1"
fi

otlp_log INFO 9 "doodlessd backup OK in ${DURATION}s, run ${RUN_ID}"
log "done in ${DURATION}s"
