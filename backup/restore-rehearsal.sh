#!/usr/bin/env bash
#
# restore-rehearsal.sh — prove the backup actually restores.
#
# A backup nobody has restored is a hypothesis. Everything up to this point —
# the timer going green, restic reporting success, the snapshot list growing —
# is evidence that bytes were written somewhere. None of it is evidence that
# those bytes can be turned back into a working system. The gap between the
# two is where backup systems die.
#
# This script closes it, non-destructively and often enough to be routine:
#
#   1. Restore the newest snapshot into a scratch directory.
#   2. Load the Postgres dump into a THROWAWAY postgres container and query it.
#   3. Run an integrity check on the restored nginx-proxy-manager database.
#   4. Confirm the certificates and the stack configs are actually there.
#   5. Tear it all down.
#
# It never writes to a production path, never touches a running container, and
# never publishes a port. Run it as root:
#
#   sudo /usr/local/sbin/doodlessd-restore-rehearsal.sh
#
# Expected cadence: monthly, and ALWAYS after changing the destination, the
# retention policy, or the Postgres major version.

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/doodlessd-backup/backup.env}"
# Deliberately not under /var/backups: a scratch tree that shares a parent with
# the staging directory is one `rm -rf` typo away from being a very bad day.
WORK_DIR="${WORK_DIR:-/var/tmp/doodlessd-restore-rehearsal}"

# A name nothing else on this host uses, so a stray `docker rm` in this script
# can never hit documenso-db.
SCRATCH_CONTAINER="restore-rehearsal-pg"
# Must match the production database image, or the rehearsal proves the dump
# loads into a DIFFERENT Postgres than the one you would restore onto.
SCRATCH_IMAGE="postgres:17-alpine@sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73"
SCRATCH_PASSWORD="rehearsal-only-$(date +%s)"

PASS=0; FAIL=0
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
# SKIP is not PASS and not FAIL. It exists for the one honest case: a thing that is
# genuinely not deployed yet cannot be restored, and calling that a failure would leave
# the rehearsal permanently red — which is the fastest way to teach everyone to ignore
# it. The moment PG_CONTAINERS names a container, these become real checks again.
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run as root"
[[ -r "$CONFIG_FILE" ]] || die "config $CONFIG_FILE is missing"
set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a

cleanup() {
  log "cleaning up"
  # --force so a container that failed to start is still removed; -v so the
  # anonymous volume holding the rehearsal database goes with it rather than
  # accumulating a dangling volume per rehearsal.
  docker rm -f -v "$SCRATCH_CONTAINER" >/dev/null 2>&1 || true
  rm -rf -- "${WORK_DIR:?}"
}
trap cleanup EXIT

rm -rf -- "${WORK_DIR:?}"
install -d -m 0700 "$WORK_DIR"

# ---------------------------------------------------------------------------
# 1. Restore
# ---------------------------------------------------------------------------
log "listing snapshots"
restic snapshots --tag doodlessd --last || die "cannot list snapshots"

log "restoring latest snapshot into $WORK_DIR"
# `latest` resolves against the tag, so a snapshot from another host in a shared
# repository cannot be picked up by mistake.
restic restore latest --tag doodlessd --target "$WORK_DIR" \
  || die "restic restore failed — STOP. The backup is not a backup."

# restic restores absolute paths under the target, so $STAGE_DIR lands at
# $WORK_DIR$STAGE_DIR.
#
# Derived from the CONFIG, never hardcoded. It was hardcoded to /var/backups/doodlessd
# once, while backup.env staged to /var/tmp/doodlessd-backup — so the rehearsal reported
# "no NPM database in the snapshot" against a snapshot that contained it perfectly well.
# A verifier that fails for the wrong reason is worse than no verifier: it teaches you
# to skim past a red line, and the day the red line is real you skim past that too.
STAGED="${WORK_DIR}${STAGE_DIR:-/var/tmp/doodlessd-backup}"
if [[ -d "$STAGED" ]]; then
  ok "staged dumps directory restored"
elif [[ -z "${PG_CONTAINERS// /}" ]]; then
  skip "no staged dumps expected — PG_CONTAINERS is empty"
else
  bad "no staged dumps in the snapshot"
fi

# ---------------------------------------------------------------------------
# 2. Postgres — load the dump into a throwaway cluster and QUERY it
#
# Checking that the .sql file exists proves nothing; a truncated dump is still
# a file. The only honest test is replaying it into a real postmaster and
# reading rows back out.
# ---------------------------------------------------------------------------
DUMP="${STAGED}/pg_dumpall_documenso-db.sql"
if [[ -s "$DUMP" ]]; then
  ok "Documenso dump present ($(wc -c < "$DUMP") bytes)"

  log "starting throwaway postgres"
  # No published ports, no bind mounts, no network beyond the default bridge.
  # This container must be able to touch nothing.
  docker run -d --name "$SCRATCH_CONTAINER" \
    -e POSTGRES_PASSWORD="$SCRATCH_PASSWORD" \
    "$SCRATCH_IMAGE" >/dev/null

  log "waiting for it to accept connections"
  for _ in $(seq 1 60); do
    if docker exec "$SCRATCH_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then break; fi
    sleep 1
  done
  docker exec "$SCRATCH_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 \
    || die "throwaway postgres never became ready"

  log "replaying the dump"
  # ON_ERROR_STOP=1 is the whole point: without it psql reports success after
  # skipping every statement it could not run, and a rehearsal that passes on a
  # dump which restored nothing is worse than no rehearsal.
  #
  # pg_dumpall output is a full cluster dump, so it is fed to `psql postgres`,
  # not to a specific database — it issues its own CREATE DATABASE.
  if docker exec -i "$SCRATCH_CONTAINER" \
       psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "$DUMP" >/dev/null 2>"${WORK_DIR}/psql.err"; then
    ok "dump replays cleanly"
  else
    bad "dump replay FAILED: $(tail -n 5 "${WORK_DIR}/psql.err")"
  fi

  # Rows, not schema. An empty-but-valid schema restores without error and
  # would sail past every check above.
  users=$(docker exec "$SCRATCH_CONTAINER" psql -tAU postgres -d documenso \
            -c 'SELECT count(*) FROM "User";' 2>/dev/null || echo ERR)
  if [[ "$users" =~ ^[0-9]+$ ]] && [[ "$users" -gt 0 ]]; then
    ok "restored database has ${users} user row(s)"
  else
    bad "could not read User rows from the restored database (got: ${users})"
  fi

  # Documents live in Postgres (NEXT_PUBLIC_UPLOAD_TRANSPORT=database), so this
  # is simultaneously the test that the uploaded documents survived. If the
  # upload transport is ever switched to s3, this check stops meaning that and
  # an object-store restore test has to be added here.
  docs=$(docker exec "$SCRATCH_CONTAINER" psql -tAU postgres -d documenso \
           -c 'SELECT count(*) FROM "Document";' 2>/dev/null || echo ERR)
  if [[ "$docs" =~ ^[0-9]+$ ]]; then
    ok "Document table readable (${docs} row(s))"
  else
    bad "Document table not readable (got: ${docs})"
  fi
elif [[ -z "${PG_CONTAINERS// /}" ]]; then
  skip "no Postgres dump expected — PG_CONTAINERS is empty (Documenso not deployed yet)"
else
  bad "no Documenso dump in the snapshot — check PG_CONTAINERS and whether the container was running"
fi

# ---------------------------------------------------------------------------
# 3. nginx-proxy-manager
#
# Losing this means every hostname on the box stops answering, so it gets a
# real integrity check rather than a file-exists test.
# ---------------------------------------------------------------------------
NPM_DB="${STAGED}/npm-database.sqlite"
if [[ -s "$NPM_DB" ]]; then
  if result=$(python3 -c "
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
print(c.execute('PRAGMA integrity_check').fetchone()[0])
hosts=c.execute('SELECT count(*) FROM proxy_host WHERE is_deleted=0').fetchone()[0]
print(hosts)
" "$NPM_DB" 2>&1); then
    integ=$(printf '%s' "$result" | sed -n 1p)
    hosts=$(printf '%s' "$result" | sed -n 2p)
    [[ "$integ" == "ok" ]] && ok "NPM database integrity_check: ok" || bad "NPM database integrity_check: $integ"
    [[ "$hosts" -gt 0 ]] 2>/dev/null && ok "NPM has ${hosts} live proxy host(s)" || bad "NPM proxy_host table is empty"
  else
    bad "NPM database unreadable: $result"
  fi
else
  bad "no NPM database in the snapshot"
fi

# keys.json holds the key NPM uses for its own encrypted columns. The SQLite
# file without it is not a usable restore.
[[ -s "${WORK_DIR}/data/compose/27/data/keys.json" ]] \
  && ok "NPM keys.json restored" || bad "NPM keys.json missing"

# ---------------------------------------------------------------------------
# 4. Certificates and stack configs
# ---------------------------------------------------------------------------
if compgen -G "${WORK_DIR}/data/compose/27/letsencrypt/live/*/fullchain.pem" >/dev/null; then
  n=$(compgen -G "${WORK_DIR}/data/compose/27/letsencrypt/live/*/fullchain.pem" | wc -l)
  ok "${n} Let's Encrypt certificate(s) restored"
else
  bad "no Let's Encrypt certificates in the snapshot"
fi

for f in \
  "${WORK_DIR}/home/derek/npm-stack/docker-compose.yml" \
  "${WORK_DIR}/home/derek/docs-stack/docker-compose.yml"
do
  [[ -s "$f" ]] && ok "restored ${f#"$WORK_DIR"}" || bad "missing ${f#"$WORK_DIR"}"
done

# The Documenso stack only exists after the cutover; report it, do not fail on
# it, so this rehearsal is useful before the cutover as well as after.
if [[ -s "${WORK_DIR}/home/derek/documenso-stack/docker-compose.yml" ]]; then
  ok "restored /home/derek/documenso-stack/docker-compose.yml"
else
  log "note: no documenso-stack in the snapshot (expected before cutover)"
fi

# ---------------------------------------------------------------------------
printf '\n===== rehearsal: %d passed, %d failed =====\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'The backup did NOT fully restore. Treat this as an outage-in-waiting.\n'
  exit 1
fi
printf 'Restore verified. Record the date in backup/README.md.\n'
