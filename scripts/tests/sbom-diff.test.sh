#!/bin/sh
# S01 slice 2: scripts/sbom-diff.sh (brief ruling 16; S01-AC-7's unit half) and its list (node spec change 8).
#   sbom-diff.sh <list> <regenerated.json> <rc1.json>
#   list: "volatile:" and "deliberate:" start sections; other non-blank, non-# lines are jq paths; every deliberate
#   path line carries a trailing "# reason".  jq -S 'del(<all paths>)' on both; equal -> 0 and one OK line;
#   different -> diff -u printed, 1; missing input, no volatile: section, deliberate without reason -> 2.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
S="$ROOT/scripts/sbom-diff.sh"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is not available in this harness"; exit 1; }

cat > "$TMP/a.json" <<'J'
{"serialNumber":"urn:uuid:1","metadata":{"timestamp":"2026-01-01T00:00:00Z","tools":{"components":[{"name":"syft"}]},"component":{"name":"iso"}},
 "components":[{"name":"zlib","version":"1.3"},{"name":"busybox","version":"1.36","distribution":"x"}]}
J
# b: volatile differences only
cat > "$TMP/b.json" <<'J'
{"components":[{"version":"1.3","name":"zlib"},{"name":"busybox","version":"1.36","distribution":"x"}],
 "metadata":{"component":{"name":"iso"},"tools":{"components":[{"name":"other"}]},"timestamp":"2026-02-02T00:00:00Z"},
 "serialNumber":"urn:uuid:2"}
J
# c: the deliberate path differs too (components[1].distribution)
cat > "$TMP/c.json" <<'J'
{"serialNumber":"urn:uuid:3","metadata":{"timestamp":"t","tools":{},"component":{"name":"iso"}},
 "components":[{"name":"zlib","version":"1.3"},{"name":"busybox","version":"1.36","distribution":"y"}]}
J
# d: a difference elsewhere (zlib version)
cat > "$TMP/d.json" <<'J'
{"serialNumber":"urn:uuid:4","metadata":{"timestamp":"t","tools":{},"component":{"name":"iso"}},
 "components":[{"name":"zlib","version":"9.9.9"},{"name":"busybox","version":"1.36","distribution":"x"}]}
J
cat > "$TMP/list.txt" <<'L'
# list under test
volatile:
.serialNumber
.metadata.timestamp
.metadata.tools

deliberate:
.components[1].distribution   # the distribution reference is new in this repository
L
cat > "$TMP/noreason.txt" <<'L'
volatile:
.serialNumber
deliberate:
.components[1].distribution
L
cat > "$TMP/novol.txt" <<'L'
deliberate:
.components[1].distribution   # reason
L
cat > "$TMP/volonly.txt" <<'L'
volatile:
.serialNumber
.metadata.timestamp
.metadata.tools
L

run() { OUT=$(sh "$S" "$@" 2>&1); RC=$?; }
need() { [ -f "$S" ] || { fail "$1 (scripts/sbom-diff.sh is absent)"; return 1; }; }
want() { # <label> <rc>
    need "$1" || return
    [ $RC -eq "$2" ] && ok "$1" || fail "$1 (rc=$RC, want $2: $(echo "$OUT" | head -2 | tr '\n' '|'))"
}

run "$TMP/list.txt" "$TMP/a.json" "$TMP/b.json"; want "S01-AC-7 identical after the volatile paths: exit 0" 0
if [ -f "$S" ] && [ "$(echo "$OUT" | grep -c .)" -eq 1 ]; then ok "S01-AC-7 the OK result is one line"; else fail "S01-AC-7 the OK result is one line"; fi
run "$TMP/list.txt" "$TMP/a.json" "$TMP/c.json"; want "S01-AC-7 a difference only at a deliberate path: exit 0" 0
run "$TMP/list.txt" "$TMP/a.json" "$TMP/d.json"; want "S01-AC-7 a difference elsewhere: exit 1" 1
if [ -f "$S" ] && echo "$OUT" | grep -q '9.9.9' && echo "$OUT" | grep -Eq '^[-+]'; then ok "S01-AC-7 the diff is printed"; else fail "S01-AC-7 the diff is printed"; fi
run "$TMP/volonly.txt" "$TMP/a.json" "$TMP/c.json"; want "S01-AC-7 without the deliberate path the same pair differs: exit 1" 1
run "$TMP/noreason.txt" "$TMP/a.json" "$TMP/b.json"; want "S01-AC-7 a deliberate line without # reason: exit 2" 2
run "$TMP/novol.txt" "$TMP/a.json" "$TMP/b.json"; want "S01-AC-7 no volatile: section: exit 2" 2
run "$TMP/list.txt" "$TMP/nope.json" "$TMP/b.json"; want "S01-AC-7 missing regenerated input: exit 2" 2
run "$TMP/list.txt" "$TMP/a.json" "$TMP/nope.json"; want "S01-AC-7 missing rc1 input: exit 2" 2
run "$TMP/nolist.txt" "$TMP/a.json" "$TMP/b.json"; want "S01-AC-7 missing list: exit 2" 2

# change 8: the real list
L="$ROOT/configs/attestation/rc1-sbom-diff.txt"
if [ -f "$L" ]; then
    ok "S01-AC-7 configs/attestation/rc1-sbom-diff.txt exists"
    vol=$(awk '/^volatile:/ {on=1; next} /^deliberate:/ {on=0} on' "$L" | sed 's/[[:space:]]*#.*//' | grep -v '^[[:space:]]*$')
    for p in .serialNumber .metadata.timestamp .metadata.tools; do
        echo "$vol" | grep -qxF "$p" && ok "S01-AC-7 volatile: lists $p" || fail "S01-AC-7 volatile: lists $p"
    done
    bad=$(awk '/^deliberate:/ {on=1; next} /^volatile:/ {on=0} on' "$L" | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*#' | grep -v '#[[:space:]]*[^[:space:]]' || true)
    [ -z "$bad" ] && ok "S01-AC-7 every deliberate line has a reason" || fail "S01-AC-7 every deliberate line has a reason: $bad"
else
    fail "S01-AC-7 configs/attestation/rc1-sbom-diff.txt exists"
    for p in .serialNumber .metadata.timestamp .metadata.tools; do fail "S01-AC-7 volatile: lists $p (list absent)"; done
    fail "S01-AC-7 every deliberate line has a reason (list absent)"
fi

echo "sbom-diff: $fails failure(s)"
[ "$fails" -eq 0 ]
