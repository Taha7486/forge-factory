#!/usr/bin/env bash
# Tests for build.sh with stand-ins for git and docker (no network, no image is built).
# The stand-in git "checks out" a directory tree and reports the commit named in STUB_HEAD; the
# stand-in docker writes its arguments to a file. Needs bash and python3.
set -u
cd "$(dirname "$0")"
real=$(cd .. && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bad=0
n=0

mkdir -p "$tmp/bin"
cat > "$tmp/bin/git" <<'STUB'
#!/usr/bin/env bash
# git -C DIR <init|fetch|checkout|rev-parse> ...
dir=$2; cmd=$3
case "$cmd" in
  init) mkdir -p "$dir" ;;
  fetch) echo "fetch $*" >> "$STUB_LOG" ;;
  checkout) mkdir -p "$dir/frontend" ;;
  rev-parse) echo "$STUB_HEAD" ;;
esac
STUB
cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
STUB
chmod +x "$tmp/bin/git" "$tmp/bin/docker"

# a copy of the build directory with small valid lockfiles
mk() {
  local d=$1
  mkdir -p "$d/locks" "$d/tests"
  cp "$real"/{build.sh,source.env,check-locks.py,Dockerfile} "$d/"
  cp "$real/locks/npmrc" "$d/locks/"
  cp fixtures/good.json "$d/locks/package-lock.json"
  cp fixtures/good.json "$d/locks/frontend-package-lock.json"
}

# run NAME WANT_EXIT WANT_TEXT BUILD_DIR HEAD ARGS...
run() {
  local name=$1 want=$2 text=$3 d=$4 head=$5
  shift 5
  : > "$tmp/log"
  local out got
  out=$(STUB_LOG="$tmp/log" STUB_HEAD="$head" PATH="$tmp/bin:$PATH" "$d/build.sh" "$@" 2>&1)
  got=$?
  n=$((n + 1))
  if [ "$got" -eq "$want" ] && grep -qF -- "$text" <<<"$out"; then
    echo "ok    $name"
  else
    echo "FAIL  $name: exit $got (want $want), wanted text: $text"
    echo "$out" | sed 's/^/        /'
    bad=$((bad + 1))
  fi
}

. "$real/source.env"

mk "$tmp/ok"
export WORKDIR="$tmp/work1"
run "builds with the pinned commit" 0 "built reg/forge/juice-shop:abc" "$tmp/ok" "$UPSTREAM_COMMIT" reg/forge/juice-shop:abc abc
grep -q "fetch .* $UPSTREAM_COMMIT" "$tmp/log" && echo "ok    fetches exactly the pinned commit" || { echo "FAIL  fetch of the pinned commit"; bad=$((bad + 1)); }
n=$((n + 1))
for want in "-f $WORKDIR/src/Dockerfile.forge" "--build-arg NODE_IMAGE=$NODE_IMAGE" "--build-arg RUNTIME_IMAGE=$RUNTIME_IMAGE" \
            "--build-arg UPSTREAM_COMMIT=$UPSTREAM_COMMIT" "--build-arg FACTORY_SHA=abc" "-t reg/forge/juice-shop:abc"; do
  n=$((n + 1))
  if grep -qF -- "$want" "$tmp/log"; then echo "ok    docker gets: ${want:0:50}"; else echo "FAIL  docker lacks: $want"; bad=$((bad + 1)); fi
done
n=$((n + 1))
if [ -f "$WORKDIR/src/package-lock.json" ] && [ -f "$WORKDIR/src/frontend/package-lock.json" ]; then
  echo "ok    lockfiles are copied into the source tree"
else echo "FAIL  overlay not copied"; bad=$((bad + 1)); fi

n=$((n + 1))
if grep -qx "Dockerfile.forge" "$tmp/work1/src/.dockerignore"; then echo "ok    Dockerfile.forge is added to .dockerignore"; else echo "FAIL  .dockerignore lacks Dockerfile.forge"; bad=$((bad + 1)); fi

export WORKDIR="$tmp/work2"
run "a different commit stops the build" 1 "expected $UPSTREAM_COMMIT" "$tmp/ok" "0000000000000000000000000000000000000000" reg/x:y
n=$((n + 1)); if grep -q "^docker build" "$tmp/log"; then echo "FAIL  docker was called after a wrong commit"; bad=$((bad + 1)); else echo "ok    docker not called after a wrong commit"; fi

export WORKDIR="$tmp/work3"; mkdir -p "$WORKDIR/src"; touch "$WORKDIR/src/leftover"
run "a non-empty source directory is refused" 1 "is not empty" "$tmp/ok" "$UPSTREAM_COMMIT" reg/x:y

mk "$tmp/badlock"; cp fixtures/git-url.json "$tmp/badlock/locks/package-lock.json"
export WORKDIR="$tmp/work4"
run "a bad lockfile stops the build" 1 "resolved is not https://registry.npmjs.org/" "$tmp/badlock" "$UPSTREAM_COMMIT" reg/x:y
n=$((n + 1)); if grep -q "^docker build" "$tmp/log"; then echo "FAIL  docker was called after a bad lockfile"; bad=$((bad + 1)); else echo "ok    docker not called after a bad lockfile"; fi

export WORKDIR="$tmp/work5"
run "no image argument is refused" 1 "usage" "$tmp/ok" "$UPSTREAM_COMMIT"

echo "---"
echo "$n tests, $bad failed"
[ "$bad" -eq 0 ]
