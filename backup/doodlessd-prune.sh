#!/usr/bin/env bash
#
# doodlessd-prune.sh — retention and integrity, on its own weekly timer.
#
# Separate from the backup run on purpose. `restic forget --prune` rewrites
# pack files and can take a long time on a remote repository; folding it into
# the daily job would mean a slow prune delays or fails a backup. A backup that
# did not happen is a real loss; a prune that did not happen is a slightly
# larger bill.
#
# Installed at /usr/local/sbin/doodlessd-prune.sh.

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/doodlessd-backup/backup.env}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/doodlessd-backup}"
LOCK_FILE="/run/doodlessd-backup.lock"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FATAL: $*" >&2; exit 1; }

# Same lock as the backup job — they must never touch the repository at once.
# Blocking (no -n) here, unlike the backup: a prune that waits for a running
# backup is fine, it has all week.
exec 9>"$LOCK_FILE"
flock 9

[[ -r "$CONFIG_FILE" ]] || die "config $CONFIG_FILE is missing or unreadable"
set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a
# shellcheck source=/dev/null
source "${LIB_DIR}/lib-otlp.sh"

CURRENT_STEP="startup"
on_error() {
  local rc=$?
  otlp_log ERROR 17 "doodlessd prune FAILED during '${CURRENT_STEP}' (exit ${rc})"
  exit "$rc"
}
trap on_error ERR

: "${KEEP_DAILY:=14}"
: "${KEEP_WEEKLY:=8}"
: "${KEEP_MONTHLY:=12}"
: "${KEEP_YEARLY:=3}"
: "${CHECK_READ_DATA_SUBSET:=5%}"

CURRENT_STEP="forget"
log "applying retention: ${KEEP_DAILY}d / ${KEEP_WEEKLY}w / ${KEEP_MONTHLY}m / ${KEEP_YEARLY}y"
# --tag doodlessd scopes retention to this host's snapshots. Without it, a
# repository later shared with a second host would have each host's prune
# deleting the other's snapshots — the policy counts snapshots, and it would
# count somebody else's.
#
# --prune in the same call so the space is actually reclaimed; `forget` alone
# only removes the snapshot reference and the packs stay.
restic forget \
  --tag doodlessd \
  --keep-daily   "$KEEP_DAILY" \
  --keep-weekly  "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --keep-yearly  "$KEEP_YEARLY" \
  --prune

CURRENT_STEP="check"
# `restic check` on its own only verifies the metadata: that every blob the
# index claims exists is referenced correctly. It will pronounce a repository
# healthy while the pack files underneath have silently rotted or been
# truncated by a flaky upload. --read-data-subset actually downloads and
# re-hashes a slice of the packs.
#
# The `N%` form picks a DIFFERENT slice each run (restic rotates it), so at 5%
# a week the whole repository is verified over about five months without ever
# downloading it all at once.
log "verifying repository (reading ${CHECK_READ_DATA_SUBSET} of pack data)"
restic check --read-data-subset="$CHECK_READ_DATA_SUBSET"

CURRENT_STEP="reporting"
otlp_gauge "backup.last_prune.timestamp" "$(date +%s)" "s"
if raw=$(restic stats --mode raw-data --json 2>/dev/null); then
  size=$(printf '%s' "$raw" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_size"])' 2>/dev/null || echo 0)
  # Repository size trending is how you notice that a new source got added by
  # accident, or that deduplication stopped working after someone enabled
  # compression upstream of restic.
  otlp_gauge "backup.repository.size" "$size" "By"
fi
otlp_log INFO 9 "doodlessd prune + check OK"
log "done"
