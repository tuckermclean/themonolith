#!/bin/sh
# S02: scripts/check-licenses.py reads a Gentoo || ( ... ) group as OR.
#   S02-AC-1: parse_portage_expr returns one alternative per item of a || group.
#   S02-AC-2: the CLI reports pass/fail per component and exits 0/1 accordingly.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
S="$ROOT/scripts/check-licenses.py"
FX="$ROOT/scripts/fixtures/S02"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# parse_case <expr> <expected JSON>   (S02-AC-1)
parse_case() {
    got=$(python3 -I - "$S" "$1" <<'PY' 2>&1
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("check_licenses", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(json.dumps(m.parse_portage_expr(sys.argv[2])))
PY
    )
    if [ "$got" = "$2" ]; then ok "S02-AC-1 parse '$1' -> $2"
    else fail "S02-AC-1 parse '$1': expected $2, got: $got"; fi
}

parse_case '|| ( MIT GPL-2+ )'        '[["MIT"], ["GPL-2+"]]'
parse_case 'MIT || ( ISC BSD )'       '[["MIT", "ISC"], ["MIT", "BSD"]]'
parse_case '|| ( ( A B ) C )'         '[["A", "B"], ["C"]]'
parse_case '|| ( A || ( B C ) )'      '[["A"], ["B"], ["C"]]'
parse_case 'MIT'                      '[["MIT"]]'
parse_case 'MIT BSD-2-Clause'         '[["MIT", "BSD-2-Clause"]]'
parse_case 'MIT OR Apache-2.0'        '[["MIT"], ["Apache-2.0"]]'

# run_sbom <fixture> <tag>: runs the CLI, sets RC and REPORT   (S02-AC-2)
run_sbom() {
    REPORT="$TMP/$2.json"
    python3 -I "$S" --sbom "$FX/$1" --policy "$FX/policy.yaml" --output "$REPORT" >"$TMP/$2.out" 2>&1
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

# expect_status <tag> <component> <expected> <expression>
expect_status() {
    st=$(status_of "$1" "$2")
    if [ "$st" = "$3" ]; then ok "S02-AC-2 '$4' reported $3"
    else fail "S02-AC-2 '$4': expected status $3, got $st"; fi
}

expect_rc() {
    if [ "$RC" -eq "$1" ]; then ok "S02-AC-2 $2: exit $1"
    else fail "S02-AC-2 $2: expected exit $1, got $RC"; fi
}

run_sbom pass.cdx.json pass
expect_status pass mit-or-notallowed        pass '|| ( MIT NOT-ALLOWED )'
expect_status pass mit-or-llvm              pass '|| ( MIT Apache-2.0-with-LLVM-exceptions )'
expect_status pass nested-group-or-apache   pass '|| ( ( MIT NOT-ALLOWED ) Apache-2.0 )'
expect_rc 0 'SBOM of the three passing components'

run_sbom fail-a-b.cdx.json fail-a-b
expect_status fail-a-b not-a-or-not-b fail '|| ( NOT-A NOT-B )'
expect_rc 1 'SBOM holding || ( NOT-A NOT-B )'

run_sbom fail-nested.cdx.json fail-nested
expect_status fail-nested nested-group-or-not-b fail '|| ( ( MIT NOT-ALLOWED ) NOT-B )'
expect_rc 1 'SBOM holding || ( ( MIT NOT-ALLOWED ) NOT-B )'

# S02-AC-2 fail-closed: malformed input inside a || group must not pass vacuously
run_sbom fail-empty-group.cdx.json fail-empty-group
expect_status fail-empty-group malformed-empty-group fail '|| ( NOT-ALLOWED ( ) ) fail-closed'
expect_rc 1 'SBOM holding || ( NOT-ALLOWED ( ) ) fail-closed'

run_sbom fail-unclosed.cdx.json fail-unclosed
expect_status fail-unclosed malformed-unclosed fail '|| ( NOT-ALLOWED ( fail-closed'
expect_rc 1 'SBOM holding || ( NOT-ALLOWED ( fail-closed'

# S02-AC-2 fail-closed: AND keeps its conjunctive meaning inside a || group
run_sbom fail-and-in-or.cdx.json fail-and-in-or
expect_status fail-and-in-or and-in-or fail '|| ( MIT AND NOT-ALLOWED ) fail-closed'
expect_rc 1 'SBOM holding || ( MIT AND NOT-ALLOWED ) fail-closed'

# S02-AC-2 fail-closed: a stray || with no ( inside a || group is malformed
run_sbom fail-stray-or.cdx.json fail-stray-or
expect_status fail-stray-or stray-or fail '|| ( || NOT-ALLOWED ) OR fail-closed'
expect_rc 1 'SBOM holding || ( || NOT-ALLOWED ) OR fail-closed'

if [ "$fails" -ne 0 ]; then echo "check-licenses.test.sh: $fails failure(s)"; exit 1; fi
echo "check-licenses.test.sh: all passed"
