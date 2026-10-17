#!/usr/bin/env bash
# Regenerates the two lockfiles for the pinned upstream commit. Upstream commits none (its
# .npmrc says package-lock=false), so Forge keeps its own, reviewed in a pull request.
#   juice-shop/update-locks.sh
# It fetches the pinned commit, runs `npm install --package-lock-only --ignore-scripts` inside the
# pinned node image (no package is installed, no script runs; only registry metadata is read), copies
# the results to locks/ and checks them. Review `git diff juice-shop/locks` before committing.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/source.env"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
src=$work/src
mkdir -p "$src"
git -C "$src" init -q
git -C "$src" fetch -q --depth 1 "$UPSTREAM_REPO" "$UPSTREAM_COMMIT"
git -C "$src" checkout -q FETCH_HEAD
[ "$(git -C "$src" rev-parse HEAD)" = "$UPSTREAM_COMMIT" ] || { echo "update-locks.sh: wrong commit" >&2; exit 1; }

# Upstream's .npmrc says package-lock=false; ours does not.
cp "$here/locks/npmrc" "$src/.npmrc"
cp "$here/locks/npmrc" "$src/frontend/.npmrc"
rm -f "$src/package-lock.json" "$src/frontend/package-lock.json"

docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e NPM_CONFIG_UPDATE_NOTIFIER=false \
  -v "$src:/src" -w /src "$NODE_IMAGE" \
  sh -c 'npm install --package-lock-only --ignore-scripts --no-audit --no-fund && cd frontend && npm install --package-lock-only --ignore-scripts --no-audit --no-fund'

cp "$src/package-lock.json" "$here/locks/package-lock.json"
cp "$src/frontend/package-lock.json" "$here/locks/frontend-package-lock.json"
python3 -I "$here/check-locks.py" "$here/locks/package-lock.json" "$here/locks/frontend-package-lock.json"
echo "locks written to $here/locks; review the diff before committing"
