#!/bin/sh
# S01 slice 2: scripts/gates-verdict.sh (brief ruling 16; rc1 verdict of ruling 3, S01-AC-6's unit half).
#   gates-verdict.sh [--rc1] <attestation-dir>
#   reads <dir>/attestation-summary.json and <dir>/cve-report-coverage.json.
#   no --rc1: exit 0 iff overall is pass.  --rc1: exit 0 iff license_check and unowned_check are pass and the
#   coverage report exists with non-empty db.built (cve_check ignored).  Both modes print the CVE gating findings and
#   append a Markdown table to $GITHUB_STEP_SUMMARY.  Missing or unparseable summary, or missing coverage report:
#   non-zero, naming the file.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
S="$ROOT/scripts/gates-verdict.sh"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
unset GITHUB_STEP_SUMMARY

# mk <name> <license> <cve> <unowned> <overall> <dbbuilt|null|empty> <cov:yes|no>
mk() {
    d="$TMP/$1"; mkdir -p "$d"
    python3 - "$d" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import json, sys
d, lic, cve, un, ov, built, cov = sys.argv[1:8]
b = None if built == "null" else ("" if built == "empty" else built)
json.dump({"license_check": lic, "cve_check": cve, "unowned_check": un, "overall": ov,
           "cve_failures": [], "cve_db": {"built": b}}, open(d + "/attestation-summary.json", "w"))
if cov == "yes":
    json.dump({"db": {"built": b},
               "findings": [
                 {"cve": "CVE-2099-1111", "severity": "High", "component": "zlib", "gating": True},
                 {"cve": "CVE-2099-2222", "severity": "Critical", "component": "openssl", "gating": True},
                 {"cve": "CVE-2099-3333", "severity": "Low", "component": "busybox", "gating": False}]},
              open(d + "/cve-report-coverage.json", "w"))
PY
}
# gv <dir> [flags...] : runs the script, sets RC and OUT
gv() { d=$1; shift; OUT=$(sh "$S" "$@" "$d" 2>&1); RC=$?; }
need() { [ -f "$S" ] || { fail "$1 (scripts/gates-verdict.sh is absent)"; return 1; }; }
expect_rc0() { need "$1" || return; [ $RC -eq 0 ] && ok "$1" || fail "$1 (rc=$RC: $(echo "$OUT" | head -2 | tr '\n' '|'))"; }
expect_nz()  { need "$1" || return; [ $RC -ne 0 ] && [ $RC -ne 127 ] && ok "$1" || fail "$1 (rc=$RC)"; }

D="2026-08-21T06:17:24Z"
mk p   pass pass pass pass "$D" yes;  gv "$TMP/p";  expect_rc0 "S01-AC-6 non-rc1: overall pass exits 0"
mk f   pass fail pass fail "$D" yes;  gv "$TMP/f";  expect_nz  "S01-AC-6 non-rc1: overall fail exits non-zero"
mk fo  pass pass pass fail "$D" yes;  gv "$TMP/fo"; expect_nz  "S01-AC-6 non-rc1: overall fail exits non-zero even with every gate pass"
mk po  pass fail pass pass "$D" yes;  gv "$TMP/po"; expect_rc0 "S01-AC-6 non-rc1: follows overall (pass) not cve_check"

mk r1  pass fail pass fail "$D" yes;  gv "$TMP/r1" --rc1; expect_rc0 "S01-AC-6 --rc1: cve_check fail passes when licence+unowned pass and db.built set"
mk r2  pass pass pass pass "$D" yes;  gv "$TMP/r2" --rc1; expect_rc0 "S01-AC-6 --rc1: all pass exits 0"
mk r3  fail fail pass fail "$D" yes;  gv "$TMP/r3" --rc1; expect_nz  "S01-AC-6 --rc1: licence fail exits non-zero"
mk r4  pass fail fail fail "$D" yes;  gv "$TMP/r4" --rc1; expect_nz  "S01-AC-6 --rc1: unowned fail exits non-zero"
mk r5  pass fail pass fail null yes;  gv "$TMP/r5" --rc1; expect_nz  "S01-AC-6 --rc1: db.built null exits non-zero"
mk r6  pass fail pass fail empty yes; gv "$TMP/r6" --rc1; expect_nz  "S01-AC-6 --rc1: db.built empty exits non-zero"
mk r7  pass fail pass fail "$D" no;   gv "$TMP/r7" --rc1; expect_nz  "S01-AC-6 --rc1: missing coverage report exits non-zero"
if [ -f "$S" ]; then
    echo "$OUT" | grep -q 'cve-report-coverage.json' && ok "S01-AC-6 --rc1: missing coverage report is named" \
        || fail "S01-AC-6 --rc1: missing coverage report is named"
else fail "S01-AC-6 --rc1: missing coverage report is named (script absent)"; fi

mkdir -p "$TMP/nosum"; gv "$TMP/nosum"; expect_nz "S01-AC-6 missing summary exits non-zero"
if [ -f "$S" ]; then
    echo "$OUT" | grep -q 'attestation-summary.json' && ok "S01-AC-6 missing summary is named" || fail "S01-AC-6 missing summary is named"
else fail "S01-AC-6 missing summary is named (script absent)"; fi
mkdir -p "$TMP/bad"; echo '{not json' > "$TMP/bad/attestation-summary.json"; gv "$TMP/bad" --rc1
expect_nz "S01-AC-6 unparseable summary exits non-zero"
if [ -f "$S" ]; then
    echo "$OUT" | grep -q 'attestation-summary.json' && ok "S01-AC-6 unparseable summary is named" || fail "S01-AC-6 unparseable summary is named"
else fail "S01-AC-6 unparseable summary is named (script absent)"; fi

# gating findings printed (also on a passing rc1 run), non-gating not
mk g   pass fail pass fail "$D" yes; gv "$TMP/g" --rc1
if [ -f "$S" ] && echo "$OUT" | grep 'CVE-2099-1111' | grep -q 'zlib' && echo "$OUT" | grep 'CVE-2099-1111' | grep -q 'High' \
   && echo "$OUT" | grep 'CVE-2099-2222' | grep -q 'openssl' && echo "$OUT" | grep 'CVE-2099-2222' | grep -q 'Critical'; then
    ok "S01-AC-6 gating findings are printed with CVE id, component, severity"
else fail "S01-AC-6 gating findings are printed with CVE id, component, severity"; fi
if [ -f "$S" ] && ! echo "$OUT" | grep -q 'CVE-2099-3333'; then
    ok "S01-AC-6 a non-gating finding is not printed"
else fail "S01-AC-6 a non-gating finding is not printed"; fi
gv "$TMP/f"
if [ -f "$S" ] && echo "$OUT" | grep -q 'CVE-2099-1111'; then ok "S01-AC-6 non-rc1 mode prints the gating findings too"
else fail "S01-AC-6 non-rc1 mode prints the gating findings too"; fi

# GITHUB_STEP_SUMMARY gets a Markdown table with each gating CVE id
: > "$TMP/step.md"
if [ -f "$S" ]; then GITHUB_STEP_SUMMARY="$TMP/step.md" sh "$S" --rc1 "$TMP/g" >/dev/null 2>&1; fi
if [ -f "$S" ] && grep -q 'CVE-2099-1111' "$TMP/step.md" && grep -q 'CVE-2099-2222' "$TMP/step.md" \
   && grep -q '^|' "$TMP/step.md" && grep -Eq '^\|[ :|-]*-[ :|-]*\|' "$TMP/step.md" && ! grep -q 'CVE-2099-3333' "$TMP/step.md"; then
    ok "S01-AC-6 GITHUB_STEP_SUMMARY gets a Markdown table of the gating CVEs"
else fail "S01-AC-6 GITHUB_STEP_SUMMARY gets a Markdown table of the gating CVEs"; fi
echo "preexisting" > "$TMP/step2.md"
if [ -f "$S" ]; then GITHUB_STEP_SUMMARY="$TMP/step2.md" sh "$S" "$TMP/f" >/dev/null 2>&1; fi
if [ -f "$S" ] && head -1 "$TMP/step2.md" | grep -q preexisting && grep -q 'CVE-2099-2222' "$TMP/step2.md"; then
    ok "S01-AC-6 GITHUB_STEP_SUMMARY is appended to, not overwritten"
else fail "S01-AC-6 GITHUB_STEP_SUMMARY is appended to, not overwritten"; fi

echo "gates-verdict: $fails failure(s)"
[ "$fails" -eq 0 ]
