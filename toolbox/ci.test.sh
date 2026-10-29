#!/bin/sh
# Tests for toolbox/ci against the fixture workflows in toolbox/testdata/.
#   sh toolbox/ci.test.sh            (on the host, or inside the toolbox)
set -u
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
export MONOLITH_WORKFLOWS="$root/toolbox/testdata/workflows"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
has() { grep -qE "$2" "$tmp/$1"; }

toolbox/ci lint >"$tmp/lint" 2>&1; rc=$?
if [ $rc = 0 ] && has lint '3 workflow\(s\), 0 problem'; then pass "lint: triggerable and called workflows conform, dispatch-only skipped"
else fail "lint default scope (rc=$rc)"; cat "$tmp/lint"; fi

toolbox/ci lint toolbox/testdata/other/bad.yml >"$tmp/bad" 2>&1; rc=$?
ok=1
for pat in "runs-on 'self-hosted'" "job containers" "if: 'contains" "actions/setup-python" "'sudo apt-get" \
           "expression inside run" "'curl -sSfL" "format\('" "shell 'python'" "9 problem"; do
	has bad "$pat" || { ok=0; echo "  missing: $pat"; }
done
if [ $rc = 1 ] && [ $ok = 1 ]; then pass "lint: each rule break is reported"; else fail "lint bad.yml (rc=$rc)"; cat "$tmp/bad"; fi

toolbox/ci run good >"$tmp/good" 2>&1; rc=$?
if [ $rc = 0 ] && has good 'ok +consume +check output' && has good 'callee got 2'; then
	pass "run: matrix step outputs reach a needed job and a called workflow"
else fail "run good (rc=$rc)"; cat "$tmp/good"; fi
if has good 'ci-only +produce \(1\) +secret step +\[needs secrets.SOME_TOKEN\]' && has good 'ci-only +consume +actions/attest'; then
	pass "run: secret and attestation steps are reported CI-only"
else fail "CI-only steps"; fi
if has good 'skip +produce \(2\) +only on failure' && has good 'ok +consume +event'; then pass "run: if: failure() skipped, event condition true"
else fail "if: on a passing job"; fi

toolbox/ci run good consume --event push >"$tmp/push" 2>&1
if has push 'skip +consume +event +\[if: false\]'; then pass "run: --event changes github.event_name"; else fail "--event"; cat "$tmp/push"; fi

toolbox/ci run good produce --matrix n=1 >"$tmp/pin" 2>&1; rc=$?
if [ $rc = 0 ] && has pin 'produce \(1\)' && ! has pin 'produce \(2\)'; then pass "run: --matrix pins one combination"
else fail "--matrix (rc=$rc)"; cat "$tmp/pin"; fi

start=$(date +%s)
toolbox/ci run failing >"$tmp/failing" 2>&1; rc=$?
took=$(( $(date +%s) - start ))
if [ $rc = 1 ] && has failing 'FAIL +first .*\[exit 3\]' && has failing 'skip +first +skipped after failure' \
   && has failing 'ok +first +always runs' && has failing 'ok +first +failure runs' && has failing 'skip +second .*a needed job failed'; then
	pass "run: a failed step skips the rest, always()/failure() still run, dependants skip"
else fail "run failing (rc=$rc)"; cat "$tmp/failing"; fi
if has failing 'FAIL +slow +too slow +\[exit 124\]' && [ "$took" -lt 25 ]; then pass "run: step timeout-minutes stops the container (${took}s)"
else fail "timeout (${took}s)"; fi

echo "$fails failure(s)"
[ $fails = 0 ]
