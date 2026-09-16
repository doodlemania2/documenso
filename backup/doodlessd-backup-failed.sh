#!/usr/bin/env bash
#
# doodlessd-backup-failed.sh — the OnFailure= handler.
#
# Invoked by systemd as `doodlessd-backup-failed@<unit>.service` when the
# backup or prune unit fails. This exists in ADDITION to the ERR trap inside
# the scripts themselves, and the overlap is the point: the trap knows which
# step broke but cannot run if the process was OOM-killed, SIGKILLed, hit the
# unit's timeout, or failed before bash got far enough to load the config.
# This handler fires for all of those.
#
# Installed at /usr/local/sbin/doodlessd-backup-failed.sh.

set -euo pipefail

UNIT="${1:?usage: doodlessd-backup-failed.sh <unit-name>}"

CONFIG_FILE="${CONFIG_FILE:-/etc/doodlessd-backup/backup.env}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/doodlessd-backup}"

# Best effort: if the config is unreadable there is nothing to send to, but
# this handler must still exit 0 — a failing failure-handler is noise on top of
# the real problem and systemd would log it as a second, confusing failure.
if [[ -r "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set +a
fi
# shellcheck source=/dev/null
source "${LIB_DIR}/lib-otlp.sh" 2>/dev/null || exit 0

RESULT="$(systemctl show -p Result --value "$UNIT" 2>/dev/null || echo unknown)"
STATUS="$(systemctl show -p ExecMainStatus --value "$UNIT" 2>/dev/null || echo unknown)"
# The last lines of the journal say more than any status word. Truncated,
# because an OTLP log record is not a log shipper.
TAIL="$(journalctl -u "$UNIT" -n 25 --no-pager -o cat 2>/dev/null | tail -c 3000 || true)"

otlp_log ERROR 17 "systemd unit ${UNIT} FAILED (result=${RESULT} exit=${STATUS}) on $(hostname -s)
${TAIL}"

exit 0
