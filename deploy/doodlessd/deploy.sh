#!/usr/bin/env bash
# Rolls the documenso app container to the image in deploy/docker-compose.image.yml.
# Run by .github/workflows/deploy.yml on the doodlessd runner:
#
#   deploy.sh <dir with the checked-in compose files>      e.g. "$GITHUB_WORKSPACE/deploy"
#
# What it does, in order. Any failure after step 5 rolls back to the previous files and image.
#   1. Read the new image reference. Refuse a downgrade (version in the tag, compared with sort -V).
#   2. Pull the new image by digest.
#   3. Dump the database (pg_dumpall inside the db container) to $STACK_DIR/predeploy/.
#   4. Save the stack's current compose files to $STACK_DIR/.rollback/.
#   5. Copy the checked-in compose files into the stack and `up -d documenso`.
#   6. Wait for the container to be healthy and to run the pulled image.
#
# A rollback restores the old image. It does NOT undo database migrations that already ran. If the
# new version migrated the schema, restore the dump from step 3 before you trust the old image.
set -euo pipefail

src="${1:?usage: deploy.sh <dir with docker-compose*.yml>}"
STACK_DIR="${STACK_DIR:-/home/derek/documenso-stack}"
APP=documenso-app
DB=documenso-db
KEEP_DUMPS=5
HEALTH_WAIT_SECONDS="${HEALTH_WAIT_SECONDS:-300}" # first boot runs the Prisma migrations
FILES=(docker-compose.yml docker-compose.azure-kv.yml docker-compose.image.yml)

die() { echo "deploy: $*" >&2; exit 1; }

# v2.21.1-tdp.3 -> 2.21.1.3, so sort -V orders it. Empty output means "no version in the string".
sortable_version() {
  grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+-tdp\.[0-9]+' <<<"$1" | head -n1 | sed -E 's/^v//; s/-tdp\./\./'
}

# True when $1 is older than $2.
older_than() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

compose() {
  local args=() f
  for f in "${FILES[@]}"; do
    [[ -f "$STACK_DIR/$f" ]] && args+=(-f "$STACK_DIR/$f")
  done
  docker compose --project-directory "$STACK_DIR" "${args[@]}" "$@"
}

wait_healthy() { # wait_healthy <image id the container must run, or empty>
  local want="$1" deadline=$((SECONDS + HEALTH_WAIT_SECONDS)) status have
  while ((SECONDS < deadline)); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$APP" 2>/dev/null || echo missing)"
    have="$(docker inspect -f '{{.Image}}' "$APP" 2>/dev/null || true)"
    if [[ "$status" == healthy && ( -z "$want" || "$have" == "$want" ) ]]; then return 0; fi
    sleep 3
  done
  return 1
}

[[ -f "$src/docker-compose.image.yml" ]] || die "$src/docker-compose.image.yml is missing"
new_ref="$(sed -nE 's/^[[:space:]]*image:[[:space:]]*([^[:space:]#]+).*/\1/p' "$src/docker-compose.image.yml" | head -n1)"
[[ "$new_ref" == *@sha256:* ]] || die "image reference is not pinned by digest: '$new_ref'"

# 1. Downgrade guard. The database may already be migrated by a newer version.
new_v="$(sortable_version "$new_ref")"
[[ -n "$new_v" ]] || die "no version (vX.Y.Z-tdp.N) in the new image tag: $new_ref"
if docker inspect "$APP" >/dev/null 2>&1; then
  cur_ref="$(docker inspect -f '{{.Config.Image}}' "$APP")"
  cur_v="$(sortable_version "$cur_ref")"
  [[ -n "$cur_v" ]] || die "cannot read a version from the running image '$cur_ref'; refusing to guess"
  if older_than "$new_v" "$cur_v"; then
    die "refusing to deploy $new_v over the running $cur_v (a downgrade; the schema may be newer)"
  fi
  echo "version check: running $cur_v -> new $new_v"
fi

# 2. Pull first, so a bad reference fails before anything changes.
docker pull "$new_ref"
want_id="$(docker image inspect -f '{{.Id}}' "$new_ref")"

# 3. Database dump.
mkdir -p "$STACK_DIR/predeploy"
dump="$STACK_DIR/predeploy/documenso-$(date +%Y%m%dT%H%M%S).sql.gz"
db_user="$(docker exec "$DB" printenv POSTGRES_USER)"
(umask 077; docker exec -u postgres "$DB" pg_dumpall --clean --if-exists -U "$db_user" | gzip > "$dump")
[[ -s "$dump" ]] || die "the database dump is empty: $dump"
echo "database dump: $dump"
# shellcheck disable=SC2012 # names are our own timestamps
ls -1t "$STACK_DIR"/predeploy/documenso-*.sql.gz | tail -n +$((KEEP_DUMPS + 1)) | xargs -r rm -f --

# 4. Save the current state.
rm -rf "$STACK_DIR/.rollback"; mkdir -p "$STACK_DIR/.rollback"
for f in "${FILES[@]}"; do
  [[ -f "$STACK_DIR/$f" ]] && cp -a "$STACK_DIR/$f" "$STACK_DIR/.rollback/$f"
done
had_running=0; docker inspect "$APP" >/dev/null 2>&1 && had_running=1

rollback() {
  echo "deploy: ROLLING BACK" >&2
  for f in "${FILES[@]}"; do
    if [[ -f "$STACK_DIR/.rollback/$f" ]]; then cp -a "$STACK_DIR/.rollback/$f" "$STACK_DIR/$f"; else rm -f "$STACK_DIR/$f"; fi
  done
  if ((had_running)); then
    compose up -d documenso || true
    if wait_healthy ""; then echo "deploy: rolled back; the app is healthy on the previous image" >&2
    else echo "deploy: ROLLBACK DID NOT BECOME HEALTHY. Look at the host now." >&2; fi
  fi
  echo "deploy: database dump from before this deploy: $dump" >&2
  echo "deploy: a rollback does not undo migrations. If the schema changed, restore that dump first." >&2
  docker logs --tail=60 "$APP" >&2 || true
}

# 5. Switch.
for f in "${FILES[@]}"; do
  [[ -f "$src/$f" ]] || die "$src/$f is missing" # nothing has changed yet
done
for f in "${FILES[@]}"; do cp -f "$src/$f" "$STACK_DIR/$f"; done
compose config -q || { rollback; die "the compose files do not validate"; }
compose up -d documenso || { rollback; die "docker compose up failed"; }

# 6. Verify.
if wait_healthy "$want_id"; then
  echo "$new_ref" > "$STACK_DIR/.deployed-image"
  echo "deploy: documenso is healthy on $new_ref"
else
  rollback
  die "documenso did not become healthy on $new_ref within ${HEALTH_WAIT_SECONDS}s"
fi
