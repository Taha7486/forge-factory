#!/usr/bin/env bash
# Tests for vuln_gate.py. Needs python3 only. Every case pins --today, so the result does
# not depend on the real date. The fixtures use made-up CVE-2099-* ids.
set -u
cd "$(dirname "$0")"
GATE="python3 -I ../vuln_gate.py"
F=fixtures
TODAY=2026-10-16
bad=0
n=0

# t NAME EXPECTED_EXIT EXPECTED_TEXT ARGS...   (the text must appear in stdout or stderr)
t() {
  local name=$1 want=$2 text=$3
  shift 3
  local out got
  out=$($GATE "$@" 2>&1)
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

V="--vuln $F/vuln-findings.json --today $TODAY"
C="--vuln $F/vuln-clean.json --today $TODAY"

t "no waivers: findings block, duplicates counted once" 1 "BLOCKED (2)" $V --waivers $F/waivers-empty.json
t "CRITICAL and HIGH are gated, MEDIUM is not"          1 "HIGH CVE-2099-0002" $V --waivers $F/waivers-empty.json
t "clean image passes with no waivers"                  0 "RESULT: PASSED" $C --waivers $F/waivers-empty.json
t "all blocking findings waived: passes"                0 "WAIVED (2)" $V --waivers $F/waivers-valid-all.json
t "waived finding shows owner and justification"        0 "owner taha, expires 2026-12-01" $V --waivers $F/waivers-valid-all.json
t "partial waivers: the rest still blocks"              1 "BLOCKED (1)" $V --waivers $F/waivers-partial.json
t "waiver for the wrong package does not help"          1 "CVE-2099-0001 libfoo 1.0 (fixed in: 1.1): no waiver" $V --waivers $F/waivers-wrong-package.json
t "expired waiver blocks again"                         1 "waiver expired on 2026-10-10" $V --waivers $F/waivers-expired.json
t "demo 4: valid today, expired once the clock moves"   1 "waiver expired on 2026-12-01" --vuln $F/vuln-findings.json --today 2026-12-01 --waivers $F/waivers-valid-all.json
t "waiver works the day before it expires"              0 "RESULT: PASSED" --vuln $F/vuln-findings.json --today 2026-11-30 --waivers $F/waivers-valid-all.json
t "waiver is dead on the expiry date itself"            1 "waiver expired" --vuln $F/vuln-findings.json --today 2026-12-01 --waivers $F/waivers-valid-all.json
t "waiver close to expiry warns"                        0 "expires in 9 days" $V --waivers $F/waivers-expiring-soon.json
t "waiver that matches nothing warns"                   0 "matches no CRITICAL/HIGH finding" $C --waivers $F/waivers-stale.json

t "missing owner fails closed"                          2 "missing owner" $V --waivers $F/waivers-missing-owner.json
t "empty owner fails closed"                            2 "owner is empty" $V --waivers $F/waivers-empty-owner.json
t "waiver longer than 90 days fails closed"             2 "the limit is 90 days" $V --waivers $F/waivers-too-long.json
t "unknown field fails closed"                          2 "unknown field ticket" $V --waivers $F/waivers-unknown-field.json
t "duplicate waiver fails closed"                       2 "duplicate" $V --waivers $F/waivers-duplicate.json
t "short justification fails closed"                    2 "shorter than 20" $V --waivers $F/waivers-short-justification.json
t "wrong date format fails closed"                      2 "YYYY-MM-DD" $V --waivers $F/waivers-bad-date-format.json
t "impossible date fails closed"                        2 "not a real date" $V --waivers $F/waivers-impossible-date.json
t "waiver created in the future fails closed"           2 "is in the future" $V --waivers $F/waivers-created-in-future.json
t "expires before created fails closed"                 2 "expires must be after created" $V --waivers $F/waivers-expires-before-created.json
t "wrong file shape fails closed"                       2 "exactly one key" $V --waivers $F/waivers-wrong-shape.json
t "malformed JSON fails closed"                         2 "cannot read waiver file" $V --waivers $F/waivers-malformed.json
t "missing waiver file fails closed"                    2 "cannot read waiver file" $V --waivers $F/does-not-exist.json
t "not a Trivy report fails closed"                     2 "not a Trivy cosign-vuln report" --vuln $F/vuln-not-trivy.json --today $TODAY --waivers $F/waivers-empty.json
t "bad --today fails closed"                            2 "--today" --vuln $F/vuln-findings.json --today 2026-02-30 --waivers $F/waivers-empty.json

# --today must not work in GitHub Actions, or a workflow could pretend it is still last month.
out=$(GITHUB_ACTIONS=true $GATE $V --waivers $F/waivers-valid-all.json 2>&1); got=$?
n=$((n + 1))
if [ "$got" -eq 2 ] && grep -qF "refused in GitHub Actions" <<<"$out"; then echo "ok    --today is refused in GitHub Actions"; else echo "FAIL  --today is refused in GitHub Actions: exit $got"; bad=$((bad + 1)); fi

# The Markdown summary is appended, not overwritten.
sum=$(mktemp); echo "earlier step" >"$sum"
$GATE $V --waivers $F/waivers-partial.json --summary "$sum" >/dev/null 2>&1
n=$((n + 1))
if grep -q "earlier step" "$sum" && grep -q "## Vulnerability gate: FAILED" "$sum" && grep -q "CVE-2099-0002" "$sum"; then echo "ok    summary is appended"; else echo "FAIL  summary is appended"; bad=$((bad + 1)); fi
rm -f "$sum"

echo "---"
echo "$n tests, $bad failed"
[ "$bad" -eq 0 ]
