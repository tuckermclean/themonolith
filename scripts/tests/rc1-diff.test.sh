#!/bin/sh
# P01 slice 1: scripts/rc1-diff.sh, the package diff against rc1's SBOM (node spec change 8).
#   P01-AC-7  fails on a package that is added or removed without a reason line and passes with one; an unused
#             reason line is reported and does not fail.
#
# Interface under test (the implementer writes the script from this header alone):
#   sh scripts/rc1-diff.sh <rc1-bom.cdx.json> <new-bom.cdx.json> <reasons.tsv>
#     Package set of an SBOM: jq over .components[], entries with a .name and a .version, as "name@version" lines
#     (components of type "file" are ignored: rc1's SBOM has none); sets compared with sort and comm.
#     reasons.tsv: lines "<added|removed><TAB><name@version><TAB><reason>"; blank lines and lines starting with #
#     are ignored; docs/rc1-diff-reasons.tsv is the real file.
#     stdout: a Markdown report (the release asset rc1-diff.md) listing added and removed packages with their
#     reasons, and one line containing "unused" and the entry for each reason line that matches no difference.
#     exit 0 when every added and removed package has a reason line of the right kind (a version change is one
#     removed plus one added); exit 1 listing (a line each, on stdout or stderr) the packages without one;
#     exit 2 on a usage error or an unreadable/invalid input.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
S="$ROOT/scripts/rc1-diff.sh"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/old.json" <<'J'
{"bomFormat":"CycloneDX","metadata":{"component":{"name":"iso"}},
 "components":[{"type":"library","name":"zlib","version":"1.3"},
               {"type":"library","name":"busybox","version":"1.36.1"},
               {"type":"library","name":"oldtool","version":"2.0"}]}
J
cat > "$TMP/same.json" <<'J'
{"bomFormat":"CycloneDX","metadata":{"component":{"name":"iso"}},
 "components":[{"type":"library","name":"busybox","version":"1.36.1"},
               {"type":"library","name":"oldtool","version":"2.0"},
               {"type":"library","name":"zlib","version":"1.3"},
               {"type":"file","name":"/usr/bin/extra","version":"x"}]}
J
cat > "$TMP/new.json" <<'J'
{"bomFormat":"CycloneDX","metadata":{"component":{"name":"iso"}},
 "components":[{"type":"library","name":"zlib","version":"1.3.1"},
               {"type":"library","name":"busybox","version":"1.36.1"},
               {"type":"library","name":"newtool","version":"1.0"}]}
J
# new vs old: removed oldtool@2.0, zlib@1.3; added newtool@1.0, zlib@1.3.1
: > "$TMP/none.tsv"
printf '# reasons\n\nadded\tnewtool@1.0\tnew in this tree\nremoved\toldtool@2.0\tdropped\nadded\tzlib@1.3.1\tbump\nremoved\tzlib@1.3\tbump\n' > "$TMP/all.tsv"
grep -v 'newtool' "$TMP/all.tsv" > "$TMP/no-added.tsv"
grep -v 'oldtool' "$TMP/all.tsv" > "$TMP/no-removed.tsv"
{ cat "$TMP/all.tsv"; printf 'added\tghost@9\tnever happened\n'; } > "$TMP/unused.tsv"
printf 'removed\tnewtool@1.0\twrong kind\nremoved\toldtool@2.0\tdropped\nadded\tzlib@1.3.1\tb\nremoved\tzlib@1.3\tb\n' > "$TMP/wrongkind.tsv"

run() { out=$(sh "$S" "$@" 2>&1); rc=$?; }

run "$TMP/old.json" "$TMP/same.json" "$TMP/none.tsv"
[ "$rc" = 0 ] && ok "P01-AC-7: identical package sets (a file component ignored) need no reasons, exit 0" || fail "P01-AC-7: identical sets must exit 0 (rc=$rc)"

run "$TMP/old.json" "$TMP/new.json" "$TMP/none.tsv"
if [ "$rc" = 1 ] && echo "$out" | grep -q 'newtool@1.0' && echo "$out" | grep -q 'oldtool@2.0'; then
	ok "P01-AC-7: added and removed packages without reason lines exit 1 and are named"
else fail "P01-AC-7: no reasons must exit 1 naming newtool@1.0 and oldtool@2.0 (rc=$rc)"; fi

run "$TMP/old.json" "$TMP/new.json" "$TMP/no-added.tsv"
if [ "$rc" = 1 ] && echo "$out" | grep -q 'newtool@1.0'; then ok "P01-AC-7: an added package without a reason exits 1"
else fail "P01-AC-7: added package without reason must exit 1 (rc=$rc)"; fi

run "$TMP/old.json" "$TMP/new.json" "$TMP/no-removed.tsv"
if [ "$rc" = 1 ] && echo "$out" | grep -q 'oldtool@2.0'; then ok "P01-AC-7: a removed package without a reason exits 1"
else fail "P01-AC-7: removed package without reason must exit 1 (rc=$rc)"; fi

run "$TMP/old.json" "$TMP/new.json" "$TMP/wrongkind.tsv"
[ "$rc" = 1 ] && ok "P01-AC-7: a reason of the wrong kind does not count" || fail "P01-AC-7: wrong-kind reason must exit 1 (rc=$rc)"

run "$TMP/old.json" "$TMP/new.json" "$TMP/all.tsv"
if [ "$rc" = 0 ] && echo "$out" | grep -q 'new in this tree'; then ok "P01-AC-7: every difference has a reason line, exit 0, report carries the reasons"
else fail "P01-AC-7: all reasons present must exit 0 with a report (rc=$rc)"; fi

run "$TMP/old.json" "$TMP/new.json" "$TMP/unused.tsv"
if [ "$rc" = 0 ] && echo "$out" | grep -i 'unused' | grep -q 'ghost@9'; then ok "P01-AC-7: an unused reason line is reported and does not fail"
else fail "P01-AC-7: unused reason line must be reported with exit 0 (rc=$rc)"; fi


[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
