#!/usr/bin/env bash
# Builds the Juice Shop image from the pinned upstream commit. CI and a laptop use the same script.
#   juice-shop/build.sh IMAGE [FACTORY_SHA]
# IMAGE is the full tag to build (for example <registry>/forge/juice-shop:<sha>). FACTORY_SHA goes
# into the image label (default: unknown). WORKDIR (env) names the directory for the upstream
# checkout, default a new temporary one; it must not exist or must be empty.
# Needs git, docker and python3. Does not push anything.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=source.env
. "$here/source.env"

image=${1:?usage: build.sh IMAGE [FACTORY_SHA]}
factory_sha=${2:-unknown}
work=${WORKDIR:-$(mktemp -d)}
src=$work/src
mkdir -p "$src"
if [ -n "$(ls -A "$src")" ]; then echo "build.sh: $src is not empty" >&2; exit 1; fi

echo "== fetching $UPSTREAM_REPO at $UPSTREAM_COMMIT ($UPSTREAM_TAG)"
git -C "$src" init -q
git -C "$src" fetch -q --depth 1 "$UPSTREAM_REPO" "$UPSTREAM_COMMIT"
git -C "$src" checkout -q FETCH_HEAD
got=$(git -C "$src" rev-parse HEAD)
if [ "$got" != "$UPSTREAM_COMMIT" ]; then
  echo "build.sh: checked out $got, expected $UPSTREAM_COMMIT" >&2
  exit 1
fi

echo "== overlay: lockfiles, Dockerfile"
cp "$here/locks/package-lock.json" "$src/package-lock.json"
cp "$here/locks/frontend-package-lock.json" "$src/frontend/package-lock.json"
cp "$here/Dockerfile" "$src/Dockerfile.forge"
# Keep our Dockerfile out of the image (and out of the layer cache key); docker still reads it with -f.
printf '\nDockerfile.forge\n' >> "$src/.dockerignore"
python3 -I "$here/check-locks.py" "$src/package-lock.json" "$src/frontend/package-lock.json"

echo "== docker build $image"
docker build -f "$src/Dockerfile.forge" \
  --build-arg NODE_IMAGE="$NODE_IMAGE" --build-arg RUNTIME_IMAGE="$RUNTIME_IMAGE" \
  --build-arg UPSTREAM_COMMIT="$UPSTREAM_COMMIT" --build-arg UPSTREAM_TAG="$UPSTREAM_TAG" \
  --build-arg FACTORY_SHA="$factory_sha" \
  -t "$image" "$src"
echo "== built $image (checkout in $src)"
