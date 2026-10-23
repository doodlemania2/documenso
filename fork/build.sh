#!/usr/bin/env bash
# Builds our Documenso image: upstream at a pinned commit, plus the patches in
# fork/patches/, using upstream's own Dockerfile. It builds an image and does
# nothing else: switching the stack to it is a separate, deliberate step (see
# fork/README.md).
#
# Run it on doodlemanage (linux/amd64), never on doodlessd. doodlessd serves the
# live sites, and a 30-minute monorepo build there slows them down. doodlemanage
# pushes the image to the internal registry; doodlessd pulls it. See "Building"
# in fork/README.md.
#
#   fork/build.sh            # build, tag, print the image ID
#   PUSH=1 fork/build.sh     # also push to the internal registry (needs docker login)
#
# Extra `docker build` arguments come from BUILD_EXTRA_ARGS, e.g.
#   BUILD_EXTRA_ARGS="--cpuset-cpus 0-3 --memory 12g" fork/build.sh
#
# Every input is pinned. The upstream commit is checked after the clone, so a
# moved or re-pointed tag fails the build instead of silently building
# something else, and each patch is checked against its recorded SHA-256 before
# it is applied.
set -euo pipefail

FORK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fork/pins.env
source "$FORK_DIR/pins.env"

: "${UPSTREAM_REPO:?}" "${UPSTREAM_TAG:?}" "${UPSTREAM_COMMIT:?}" "${IMAGE_TAG:?}"

# Upstream's Dockerfile needs BuildKit. The legacy builder creates
# `WORKDIR /app` owned by root even after `USER nodejs`, so the runner stage's
# `npm ci` fails with EACCES on /app/node_modules — after a full 30-minute
# monorepo build. Fail now instead.
if ! docker buildx version >/dev/null 2>&1; then
  echo "!! docker buildx is missing, so 'docker build' would use the legacy builder," >&2
  echo "   which cannot build upstream's Dockerfile. See fork/README.md, 'Building'." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> cloning $UPSTREAM_REPO at $UPSTREAM_TAG"
git clone --quiet --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$WORK/src"

actual="$(git -C "$WORK/src" rev-parse HEAD)"
if [[ "$actual" != "$UPSTREAM_COMMIT" ]]; then
  echo "!! $UPSTREAM_TAG resolves to $actual, expected $UPSTREAM_COMMIT. Refusing to build." >&2
  exit 1
fi

echo "==> verifying and applying patches"
(cd "$FORK_DIR/patches" && sha256sum --check --strict SHA256SUMS)
for patch in "$FORK_DIR"/patches/*.patch; do
  echo "    $(basename "$patch")"
  git -C "$WORK/src" apply --check "$patch"
  git -C "$WORK/src" apply "$patch"
done

echo "==> building $IMAGE_TAG (this takes a while: full turbo build of the monorepo)"
# Upstream's Dockerfile, unmodified. The telemetry build args are left empty on
# purpose: the official image can carry a telemetry key; ours does not.
# shellcheck disable=SC2086 # BUILD_EXTRA_ARGS is deliberately word-split
docker build ${BUILD_EXTRA_ARGS:-} \
  --file "$WORK/src/docker/Dockerfile" \
  --build-arg NEXT_PRIVATE_TELEMETRY_KEY= \
  --build-arg NEXT_PRIVATE_TELEMETRY_HOST= \
  --label "org.opencontainers.image.source=https://github.com/doodlemania2/documenso" \
  --label "org.opencontainers.image.version=$IMAGE_TAG" \
  --label "org.opencontainers.image.revision=$UPSTREAM_COMMIT" \
  --label "org.opencontainers.image.licenses=AGPL-3.0" \
  --tag "$IMAGE_TAG" \
  "$WORK/src"

echo
echo "==> built $IMAGE_TAG"
echo "    image ID: $(docker image inspect --format '{{.Id}}' "$IMAGE_TAG")"
echo "    Record that ID in deploy/docker-compose.azure-kv.yml before switching the stack to it."

# The registry name keeps the tag, so doodlessd can pull it and re-tag it as $IMAGE_TAG.
REGISTRY="${REGISTRY:-registry.cluster.thedoodleproject.net}"
REGISTRY_IMAGE="$REGISTRY/documenso:${IMAGE_TAG#*:}"
if [[ "${PUSH:-}" == "1" ]]; then
  echo "==> pushing $REGISTRY_IMAGE"
  docker tag "$IMAGE_TAG" "$REGISTRY_IMAGE"
  docker push "$REGISTRY_IMAGE"
  echo "    On doodlessd: docker pull $REGISTRY_IMAGE && docker tag $REGISTRY_IMAGE $IMAGE_TAG"
else
  echo "    Not pushed. Run again with PUSH=1 to push to $REGISTRY_IMAGE."
fi
