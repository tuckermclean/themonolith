#!/bin/sh
# S01 slice 2: source checks of scripts/attestation.sh and the gate lane.
# Covers S01-AC-2, S01-AC-5, S01-AC-8 (the brief's ruling 17).  Source and make -n checks only.
# Comments are stripped before the code checks, so a comment cannot satisfy or trip them.
# Every case against an absent subject prints its own FAIL.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

SRC="$ROOT/scripts/attestation.sh"
ENR="$ROOT/scripts/enrich-sbom.py"
have_src=0; [ -f "$SRC" ] && have_src=1
if [ $have_src = 1 ]; then
    # code lines only: whole-line comments removed
    grep -v '^[[:space:]]*#' "$SRC" > "$TMP/code.sh"
    # the Pillar 4 block: from its marker comment to the Pillar 5 marker, comments removed
    awk '/Pillar 4/ {on=1} /Pillar 5/ {on=0} on' "$SRC" | grep -v '^[[:space:]]*#' > "$TMP/p4.sh"
else
    : > "$TMP/code.sh"; : > "$TMP/p4.sh"
fi

# needs <label> : FAIL when the subject is absent
need_src() { [ $have_src = 1 ] || { fail "$1 (scripts/attestation.sh is absent)"; return 1; }; }

# ---- S01-AC-2: the unowned gate fails closed in attestation.sh ----------------
if need_src "S01-AC-2 Pillar 4 block found"; then
    if [ -s "$TMP/p4.sh" ] && grep -q 'check-unowned\|UNOWNED_SCRIPT' "$TMP/p4.sh"; then
        ok "S01-AC-2 Pillar 4 block found"
    else
        fail "S01-AC-2 Pillar 4 block found (no code between the Pillar 4 and Pillar 5 markers)"
    fi
    if ! grep -qi 'skipping' "$TMP/p4.sh" && ! grep -qi 'skipping unowned' "$TMP/code.sh"; then
        ok "S01-AC-2 the Pillar-4 skip warning is gone"
    else
        fail "S01-AC-2 the Pillar-4 skip warning is gone (a 'skipping' line remains)"
    fi
    if grep -Eq 'UNOWNED_RC=[1-9]' "$TMP/p4.sh"; then
        ok "S01-AC-2 the missing sbom.syft.json branch sets UNOWNED_RC non-zero"
    else
        fail "S01-AC-2 the missing sbom.syft.json branch sets UNOWNED_RC non-zero (no UNOWNED_RC=<non-zero> in Pillar 4)"
    fi
    # the Syft file is still tested, and the non-zero assignment is not the one on the success path
    if grep -Eq 'SYFT_JSON_FILE' "$TMP/p4.sh" && grep -Eq '(-f|-e|-s)[[:space:]]+"?\$\{?SYFT_JSON_FILE' "$TMP/p4.sh"; then
        ok "S01-AC-2 the Syft JSON's presence is tested in Pillar 4"
    else
        fail "S01-AC-2 the Syft JSON's presence is tested in Pillar 4"
    fi
    if grep -q -e '--allowlist' "$TMP/p4.sh"; then
        ok "S01-AC-2 the allowlist is passed (--allowlist in Pillar 4)"
    else
        fail "S01-AC-2 the allowlist is passed (no --allowlist in Pillar 4)"
    fi
    # no guard on the allowlist's presence: no test of UNOWNED_ALLOWLIST_FILE, and the --allowlist line is plain
    if ! grep -Eq '(-f|-e|-s|-r)[[:space:]]+"?\$\{?UNOWNED_ALLOWLIST_FILE' "$TMP/code.sh" \
       && ! grep -e '--allowlist' "$TMP/p4.sh" | grep -Eq '\[|&&|\|\||\bif\b|\btest\b'; then
        ok "S01-AC-2 the allowlist is passed unconditionally (no guard on its presence)"
    else
        fail "S01-AC-2 the allowlist is passed unconditionally (a guard on the allowlist file remains)"
    fi
else
    for c in "Pillar 4 block found" "the Pillar-4 skip warning is gone" \
             "the missing sbom.syft.json branch sets UNOWNED_RC non-zero" \
             "the Syft JSON's presence is tested in Pillar 4" "the allowlist is passed" \
             "the allowlist is passed unconditionally"; do
        fail "S01-AC-2 $c (scripts/attestation.sh is absent)"
    done
fi

# ---- S01-AC-5: no provenance; a failing builder scan does not set OVERALL_STATUS -
if need_src "S01-AC-5 no PROVENANCE text"; then
    if ! grep -Eq 'PROVENANCE|generate-provenance' "$TMP/code.sh"; then
        ok "S01-AC-5 no PROVENANCE / generate-provenance text in attestation.sh"
    else
        fail "S01-AC-5 no PROVENANCE / generate-provenance text in attestation.sh ($(grep -Ec 'PROVENANCE|generate-provenance' "$TMP/code.sh") code line(s))"
    fi
    # an assignment of OVERALL_STATUS on a line naming BUILDER_*_RC, or inside an if/elif naming one (3 lines up)
    awk '
        { line[NR]=$0 }
        END {
            bad=0
            for (i=1;i<=NR;i++) if (line[i] ~ /(^|[^A-Z_])OVERALL_STATUS=/) {
                if (line[i] ~ /BUILDER_(SBOM|CVE)_RC/) { bad++; continue }
                for (j=i-1;j>=1 && j>=i-3;j--)
                    if (line[j] ~ /^[[:space:]]*(if|elif|while)[[:space:]]/ && line[j] ~ /BUILDER_(SBOM|CVE)_RC/) { bad++; break }
            }
            print bad
        }' "$TMP/code.sh" > "$TMP/bad.n"
    n=$(cat "$TMP/bad.n")
    if [ "$n" = 0 ]; then
        ok "S01-AC-5 no OVERALL_STATUS assignment driven by BUILDER_SBOM_RC / BUILDER_CVE_RC"
    else
        fail "S01-AC-5 no OVERALL_STATUS assignment driven by BUILDER_SBOM_RC / BUILDER_CVE_RC ($n assignment(s))"
    fi
    if ! grep -q 'STAGE3_DIGEST' "$TMP/code.sh"; then
        ok "S01-AC-5 (ruling 7) no STAGE3_DIGEST in attestation.sh"
    else
        fail "S01-AC-5 (ruling 7) no STAGE3_DIGEST in attestation.sh"
    fi
    if ! grep -Eq 's3://|--distribution-url' "$TMP/code.sh"; then
        ok "S01-AC-5 (change 2) no s3:// or --distribution-url in attestation.sh"
    else
        fail "S01-AC-5 (change 2) no s3:// or --distribution-url in attestation.sh"
    fi
else
    for c in "no PROVENANCE / generate-provenance text in attestation.sh" \
             "no OVERALL_STATUS assignment driven by BUILDER_SBOM_RC / BUILDER_CVE_RC" \
             "(ruling 7) no STAGE3_DIGEST in attestation.sh" \
             "(change 2) no s3:// or --distribution-url in attestation.sh"; do
        fail "S01-AC-5 $c (scripts/attestation.sh is absent)"
    done
fi
if [ -f "$ENR" ]; then
    if ! grep -v '^[[:space:]]*#' "$ENR" | grep -Eq 's3://|--distribution-url'; then
        ok "S01-AC-5 (change 2) no s3:// or --distribution-url in enrich-sbom.py"
    else
        fail "S01-AC-5 (change 2) no s3:// or --distribution-url in enrich-sbom.py"
    fi
else
    fail "S01-AC-5 (change 2) no s3:// or --distribution-url in enrich-sbom.py (scripts/enrich-sbom.py is absent)"
fi
# generate-provenance.py absent: this can pass before the port, it is a guard against porting it
if [ ! -e "$ROOT/scripts/generate-provenance.py" ]; then
    ok "S01-AC-5 scripts/generate-provenance.py is absent from the tree"
else
    fail "S01-AC-5 scripts/generate-provenance.py is absent from the tree"
fi
if [ -e "$ROOT/.git" ] && command -v git >/dev/null 2>&1; then
    if git -C "$ROOT" ls-files 2>/dev/null | grep -q 'generate-provenance'; then
        fail "S01-AC-5 generate-provenance is not tracked by git"
    else
        ok "S01-AC-5 generate-provenance is not tracked by git"
    fi
fi

# ---- S01-AC-8: test-gates is in make test; the lane workflow runs only make ----
MK_TEST=$(make -n -C "$ROOT" test 2>&1); mk_rc=$?
DB=$(make -pn -C "$ROOT" test 2>/dev/null | grep -E '^test:' | head -1)
if echo "$DB" | grep -Eq '(^|[[:space:]])test-gates([[:space:]]|$)'; then
    ok "S01-AC-8 make test lists test-gates"
else
    fail "S01-AC-8 make test lists test-gates (test: $DB)"
fi
if [ $mk_rc = 0 ] && echo "$MK_TEST" | grep -q 'attestation\.sh'; then
    ok "S01-AC-8 make -n test reaches attestation.sh through test-gates"
else
    fail "S01-AC-8 make -n test reaches attestation.sh through test-gates (rc=$mk_rc)"
fi
MK_GATES=$(make -n -C "$ROOT" test-gates 2>&1); g_rc=$?
if [ $g_rc = 0 ] && echo "$MK_GATES" | grep -q 'attestation\.sh'; then
    ok "S01-AC-8 make -n test-gates names attestation.sh"
else
    fail "S01-AC-8 make -n test-gates names attestation.sh (rc=$g_rc)"
fi
if [ $g_rc = 0 ] && echo "$MK_GATES" | grep -q 'gates-verdict\.sh'; then
    ok "S01-AC-8 make -n test-gates names gates-verdict.sh"
else
    fail "S01-AC-8 make -n test-gates names gates-verdict.sh (rc=$g_rc)"
fi

WF="$ROOT/.github/workflows/sbom-gates-rc1.yml"
if [ -f "$WF" ]; then
    ok "S01-AC-8 .github/workflows/sbom-gates-rc1.yml exists"
    python3 - "$WF" > "$TMP/runs.txt" 2> "$TMP/runs.err" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
n = 0
for jn, j in (d.get("jobs") or {}).items():
    for s in j.get("steps") or []:
        if "run" in s:
            for l in str(s["run"]).splitlines():
                if l.strip():
                    print(l.strip()); n += 1
if n == 0:
    print("NO-RUN-LINES")
PY
    if [ -s "$TMP/runs.txt" ] && ! grep -q NO-RUN-LINES "$TMP/runs.txt" && ! grep -Ev '^make( |$)' "$TMP/runs.txt" | grep -q .; then
        ok "S01-AC-8 every run: line of sbom-gates-rc1.yml is a make target"
    else
        fail "S01-AC-8 every run: line of sbom-gates-rc1.yml is a make target ($(grep -Ev '^make( |$)' "$TMP/runs.txt" | head -3 | tr '\n' '|'))"
    fi
    if grep -v '^[[:space:]]*#' "$WF" | grep -Eq 'apt-get|pip|setup-'; then
        fail "S01-AC-8 sbom-gates-rc1.yml has no apt-get, pip or setup-"
    else
        ok "S01-AC-8 sbom-gates-rc1.yml has no apt-get, pip or setup-"
    fi
    if grep -q 'test-gates' "$TMP/runs.txt"; then
        ok "S01-AC-8 sbom-gates-rc1.yml runs make test-gates"
    else
        fail "S01-AC-8 sbom-gates-rc1.yml runs make test-gates"
    fi
else
    fail "S01-AC-8 .github/workflows/sbom-gates-rc1.yml exists"
    fail "S01-AC-8 every run: line of sbom-gates-rc1.yml is a make target (workflow absent)"
    fail "S01-AC-8 sbom-gates-rc1.yml has no apt-get, pip or setup- (workflow absent)"
    fail "S01-AC-8 sbom-gates-rc1.yml runs make test-gates (workflow absent)"
fi

echo "attestation-static: $fails failure(s)"
[ "$fails" -eq 0 ]
