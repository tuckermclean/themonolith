#!/bin/sh
# S03: scripts/check-licenses.py reads SPDX WITH, bare-group OR and dangling OR correctly.
#   S03-AC-1: parse_portage_expr returns the expected alternatives.
#   S03-AC-2: the CLI reports pass/fail per component and exits 0/1 accordingly.
#   S03-AC-3: rl144's expression from Build run 42721213707 passes with the R05 policy.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
S="$ROOT/scripts/check-licenses.py"
FX="$ROOT/scripts/fixtures/S03"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# parse_case <expr> <expected JSON>   (S03-AC-1)
parse_case() {
    got=$(python3 -I - "$S" "$1" <<'PY' 2>&1
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("check_licenses", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(json.dumps(m.parse_portage_expr(sys.argv[2])))
PY
    )
    if [ "$got" = "$2" ]; then ok "S03-AC-1 parse '$1' -> $2"
    else fail "S03-AC-1 parse '$1': expected $2, got: $got"; fi
}

parse_case 'Apache-2.0 WITH LLVM-exception'     '[["Apache-2.0 WITH LLVM-exception"]]'
parse_case 'MIT OR Apache-2.0 WITH LLVM-exception' '[["MIT"], ["Apache-2.0 WITH LLVM-exception"]]'
parse_case 'MIT AND (A OR B)'                   '[["MIT", "A"], ["MIT", "B"]]'
parse_case 'MIT AND (A OR B WITH C)'            '[["MIT", "A"], ["MIT", "B WITH C"]]'
parse_case '(A OR B) AND (C OR D)'              '[["A", "C"], ["A", "D"], ["B", "C"], ["B", "D"]]'
parse_case '( A || ( B C ) )'                   '[["A", "B"], ["A", "C"]]'
parse_case 'NOT-A OR'                           '[["NOT-A"]]'
parse_case 'MIT AND (NOT-A OR)'                 '[["MIT", "NOT-A"]]'
parse_case 'OR'                                 '[["OR"]]'
parse_case '( MIT BSD )'                        '[["MIT", "BSD"]]'
parse_case '(A AND B) OR C'                     '[["A", "B"], ["C"]]'
parse_case 'MIT WITH'                           '[["MIT", "WITH"]]'

# run_sbom <ac> <sbom> <policy> <tag>: runs the CLI, sets RC and REPORT
run_sbom() {
    REPORT="$TMP/$4.json"
    python3 -I "$S" --sbom "$FX/$2" --policy "$FX/$3" --output "$REPORT" >"$TMP/$4.out" 2>&1
    RC=$?
}

# status_of <tag> <component name>: prints the component's status, or "none"
status_of() {
    python3 -I - "$TMP/$1.json" "$2" <<'PY' 2>/dev/null || echo none
import json, sys
r = json.load(open(sys.argv[1]))
print(next((c["status"] for c in r["components"] if c["name"] == sys.argv[2]), "none"))
PY
}

# expect_status <ac> <tag> <component> <expected> <expression>
expect_status() {
    st=$(status_of "$2" "$3")
    if [ "$st" = "$4" ]; then ok "$1 '$5' reported $4"
    else fail "$1 '$5': expected status $4, got $st"; fi
}

expect_rc() {
    if [ "$RC" -eq "$2" ]; then ok "$1 $3: exit $2"
    else fail "$1 $3: expected exit $2, got $RC"; fi
}

run_sbom AC-2 pass.cdx.json policy.yaml pass
expect_status S03-AC-2 pass llvm-alone           pass 'Apache-2.0 WITH LLVM-exception'
expect_status S03-AC-2 pass nota-or-llvm         pass 'NOT-A OR Apache-2.0 WITH LLVM-exception'
expect_status S03-AC-2 pass mit-and-group-apache pass 'MIT AND (NOT-A OR Apache-2.0)'
expect_status S03-AC-2 pass mit-and-group-llvm   pass 'MIT AND (NOT-A OR Apache-2.0 WITH LLVM-exception)'
expect_rc S03-AC-2 0 'SBOM of the four passing components'

# fail_case <component> <expression>: SBOM holding only that expression
fail_case() {
    run_sbom AC-2 "fail-$1.cdx.json" policy.yaml "fail-$1"
    expect_status S03-AC-2 "fail-$1" "$1" fail "$2"
    expect_rc S03-AC-2 1 "SBOM holding $2"
}
fail_case mit-with-llvm          'MIT WITH LLVM-exception'
fail_case apache-with-bad        'Apache-2.0 WITH NOT-AN-EXCEPTION'
fail_case group-both-bad         'MIT AND (NOT-A OR NOT-B)'
fail_case nota-and-group         'NOT-A AND (MIT OR Apache-2.0)'
fail_case nota-dangling-or       'NOT-A OR'
fail_case mit-and-group-dangling 'MIT AND (NOT-A OR)'

# S03-AC-3: rl144 expression of Build run 42721213707, verbatim
run_sbom AC-3 rl144.cdx.json policy-rl144.yaml rl144-full
expect_status S03-AC-3 rl144-full games-roguelike/rl144 pass 'rl144 with the five-licence policy'
expect_rc S03-AC-3 0 'rl144 with the five-licence policy'
run_sbom AC-3 rl144.cdx.json policy-rl144-no-unicode.yaml rl144-nouni
expect_status S03-AC-3 rl144-nouni games-roguelike/rl144 fail 'rl144 without Unicode-3.0'
expect_rc S03-AC-3 1 'rl144 without Unicode-3.0'

if [ "$fails" -ne 0 ]; then echo "check-licenses-spdx.test.sh: $fails failure(s)"; exit 1; fi
echo "check-licenses-spdx.test.sh: all passed"
