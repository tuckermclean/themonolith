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

# S01-AC-9 (summary half): "raw matches: N", N = the number of raw grype matches.  The coverage report
# records them as summary.total_findings (one finding per grype match; coverage.matched counts distinct
# components and differs here: 4 matches over 2 components).
mk rm pass fail pass fail "$D" yes
python3 - "$TMP/rm/cve-report-coverage.json" <<'PY'
import json, sys
p = sys.argv[1]; r = json.load(open(p))
r["findings"] = [{"cve": "CVE-2099-%04d" % i, "severity": "High", "component": c, "gating": True}
                 for i, c in enumerate(["zlib", "zlib", "openssl", "openssl"])]
r["coverage"] = {"total_components": 10, "scanned": 9, "unscanned": 1, "matched": 2, "clean": 7}
r["summary"] = {"total_findings": 4, "gating_findings": 4, "waived_findings": 0}
json.dump(r, open(p, "w"))
PY
gv "$TMP/rm" --rc1
if [ -f "$S" ] && echo "$OUT" | grep -Eq '^raw matches: 4$'; then ok "S01-AC-9 gates-verdict prints 'raw matches: N' (N=4 matches, not 2 components)"
else fail "S01-AC-9 gates-verdict prints 'raw matches: N' (N=4 matches, not 2 components)"; fi
: > "$TMP/stepm.md"
if [ -f "$S" ]; then GITHUB_STEP_SUMMARY="$TMP/stepm.md" sh "$S" --rc1 "$TMP/rm" >/dev/null 2>&1; fi
if [ -f "$S" ] && grep -Eq 'raw matches: 4' "$TMP/stepm.md" && grep -q 'CVE-2099-0000' "$TMP/stepm.md"; then
    ok "S01-AC-9 GITHUB_STEP_SUMMARY carries 'raw matches: 4' with the gating findings"
else fail "S01-AC-9 GITHUB_STEP_SUMMARY carries 'raw matches: 4' with the gating findings"; fi

# --- slice 3 (S01 change 9, B03 change 13): --cve-report-only, the CVE gate reported not gating (not rc1) ---
# licence and unowned decide and db.built must be set, as for --rc1; the verdict is not rc1's (overall is ignored too).
mk c1 pass fail pass fail "$D" yes;  gv "$TMP/c1" --cve-report-only
expect_rc0 "B03-AC-7 --cve-report-only: cve fail with licence+unowned pass and db.built set exits 0"
if [ -f "$S" ] && echo "$OUT" | grep -Eq '^raw matches: [0-9]+$' && echo "$OUT" | grep 'CVE-2099-1111' | grep -q 'zlib' \
   && echo "$OUT" | grep 'CVE-2099-2222' | grep -q 'openssl'; then
    ok "B03-AC-7 --cve-report-only: still prints 'raw matches:' and the gating findings"
else fail "B03-AC-7 --cve-report-only: still prints 'raw matches:' and the gating findings"; fi
: > "$TMP/stepc.md"
if [ -f "$S" ]; then GITHUB_STEP_SUMMARY="$TMP/stepc.md" sh "$S" --cve-report-only "$TMP/c1" >/dev/null 2>&1; fi
if [ -f "$S" ] && grep -q 'raw matches:' "$TMP/stepc.md" && grep -q 'CVE-2099-1111' "$TMP/stepc.md" && grep -q 'CVE-2099-2222' "$TMP/stepc.md"; then
    ok "B03-AC-7 --cve-report-only: GITHUB_STEP_SUMMARY still gets the findings"
else fail "B03-AC-7 --cve-report-only: GITHUB_STEP_SUMMARY still gets the findings"; fi
mk c2 pass pass pass pass "$D" yes;  gv "$TMP/c2" --cve-report-only; expect_rc0 "B03-AC-7 --cve-report-only: all pass exits 0"
mk c3 pass fail fail fail "$D" yes;  gv "$TMP/c3" --cve-report-only; expect_nz  "B03-AC-7 --cve-report-only: unowned fail exits non-zero"
mk c4 fail fail pass fail "$D" yes;  gv "$TMP/c4" --cve-report-only; expect_nz  "B03-AC-7 --cve-report-only: licence fail exits non-zero"
mk c5 pass fail pass fail empty yes; gv "$TMP/c5" --cve-report-only; expect_nz  "B03-AC-7 --cve-report-only: empty db.built exits non-zero"
mk c6 pass fail pass fail null yes;  gv "$TMP/c6" --cve-report-only; expect_nz  "B03-AC-7 --cve-report-only: null db.built exits non-zero"
mk c7 pass fail pass fail "$D" no;   gv "$TMP/c7" --cve-report-only; expect_nz  "B03-AC-7 --cve-report-only: missing coverage report exits non-zero"
gv "$TMP/c3" --cve-report-only
if [ -f "$S" ] && ! echo "$OUT" | grep -q 'usage:' && echo "$OUT" | grep -q 'gates-verdict: FAIL'; then
    ok "B03-AC-7 --cve-report-only: the non-zero exits are verdicts (unowned fail named), not a usage error"
else fail "B03-AC-7 --cve-report-only: the non-zero exits are verdicts (unowned fail named), not a usage error"; fi
gv "$TMP/c1"; expect_nz "B03-AC-7 without --cve-report-only a cve fail (overall fail) still exits non-zero"

# --- slice 3b (S01 change 9, B03 change 13): --cve-report-only gates on sbom_check; --rc1 lane unchanged ---
# setsbom <name> <value>: sets sbom_check in an mk-made summary
setsbom() {
    python3 - "$TMP/$1/attestation-summary.json" "$2" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["sbom_check"] = sys.argv[2]; json.dump(d, open(p, "w"))
PY
}
mk s1 pass fail pass fail "$D" yes; setsbom s1 fail; gv "$TMP/s1" --cve-report-only
expect_nz "B03-AC-7 --cve-report-only: sbom_check fail (licence, unowned pass; cve fail) exits non-zero"
if [ -f "$S" ] && ! echo "$OUT" | grep -q 'usage:' && echo "$OUT" | grep -q 'gates-verdict: FAIL' && echo "$OUT" | grep -i 'FAIL:.*sbom' >/dev/null; then
    ok "B03-AC-7 --cve-report-only: the sbom_check failure is a verdict naming the SBOM check, not a usage error"
else fail "B03-AC-7 --cve-report-only: the sbom_check failure is a verdict naming the SBOM check, not a usage error"; fi
mk s2 pass fail pass fail "$D" yes; setsbom s2 pass; gv "$TMP/s2" --cve-report-only
expect_rc0 "B03-AC-7 --cve-report-only: sbom_check pass with cve fail exits 0 (regression guard, passes at head)"
mk s3 pass pass pass pass "$D" yes; setsbom s3 fail; gv "$TMP/s3" --cve-report-only
expect_nz "B03-AC-7 --cve-report-only: sbom_check fail with every other gate pass exits non-zero"
# --rc1 at head ignores sbom_check (it compares the SBOM elsewhere); the rc1 lane must not move.
mk s4 pass fail pass fail "$D" yes; setsbom s4 fail; gv "$TMP/s4" --rc1
expect_rc0 "B03-AC-7 --rc1: sbom_check fail is still ignored, exit 0 as at head (regression guard, passes at head)"

echo "gates-verdict: $fails failure(s)"
[ "$fails" -eq 0 ]
