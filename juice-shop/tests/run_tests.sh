#!/usr/bin/env bash
# Tests for check-locks.py. Needs python3 only.
set -u
cd "$(dirname "$0")"
CHK="python3 -I ../check-locks.py"
F=fixtures
bad=0
n=0

# t NAME EXPECTED_EXIT EXPECTED_TEXT ARGS...
t() {
  local name=$1 want=$2 text=$3
  shift 3
  local out got
  out=$($CHK "$@" 2>&1)
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

t "good lock passes"                  0 "2 packages checked, 0 bundled skipped, 0 problems" $F/good.json
t "bundled dependency is skipped"     0 "1 packages checked, 1 bundled skipped, 0 problems" $F/bundled.json
t "link entry is skipped"             0 "2 packages checked" $F/link.json
t "git url refused"                   1 "resolved is not https://registry.npmjs.org/" $F/git-url.json
t "http url refused"                  1 "resolved is not https://registry.npmjs.org/" $F/http-url.json
t "lookalike host refused"            1 "registry.npmjs.org.evil.example" $F/lookalike-host.json
t "other host refused"                1 "https://example.com/a-1.0.0.tgz" $F/other-host.json
t "missing resolved refused"          1 "resolved is not" $F/no-resolved.json
t "missing integrity refused"         1 "integrity is not sha512" $F/no-integrity.json
t "sha1 only refused"                 1 "sha1-CCCC" $F/sha1-only.json
t "lockfileVersion 1 is bad input"    2 "lockfileVersion must be 2 or 3" $F/v1.json
t "no packages is bad input"          2 "no \"packages\" section" $F/empty.json
t "not json is bad input"             2 "cannot read" $F/not-json.json
t "missing file is bad input"         2 "cannot read" $F/does-not-exist.json
t "no arguments is bad input"         2 "usage" 
t "one bad file fails the run"        1 "problems" $F/good.json $F/git-url.json
t "bad input outranks a problem"      2 "lockfileVersion" $F/git-url.json $F/v1.json
t "bad input outranks, other order"  2 "lockfileVersion" $F/v1.json $F/git-url.json

echo "---"
echo "$n tests, $bad failed"
[ "$bad" -eq 0 ]
