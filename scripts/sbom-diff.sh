#!/bin/sh
# sbom-diff.sh <list> <regenerated.json> <rc1.json>
#
# Compares two CycloneDX SBOMs after deleting the paths <list> names. <list> is
# configs/attestation/rc1-sbom-diff.txt: the lines "volatile:" and "deliberate:" start sections; any
# other non-blank line not starting with # is a jq path, and a deliberate path carries a trailing
# "# reason". Both files go through jq -S 'del(<all paths>)'.
#   equal:     one OK line, exit 0
#   different: the diff -u of the normalised files, exit 1
#   missing input, no volatile: section, deliberate path without a reason: exit 2
set -u

if [ $# -ne 3 ]; then
    echo "usage: sbom-diff.sh <list> <regenerated.json> <rc1.json>" >&2
    exit 2
fi
list=$1; new=$2; old=$3
for f in "$list" "$new" "$old"; do
    [ -f "$f" ] || { echo "sbom-diff: missing $f" >&2; exit 2; }
done

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

awk -v paths="$tmp/paths" '
    /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
    /^[[:space:]]*volatile:[[:space:]]*$/ { sect = "v"; seen = 1; next }
    /^[[:space:]]*deliberate:[[:space:]]*$/ { sect = "d"; next }
    {
        line = $0
        reason = ""
        i = index(line, "#")
        if (i > 0) { reason = substr(line, i + 1); line = substr(line, 1, i - 1) }
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        gsub(/[[:space:]]/, "", reason)
        if (sect == "") { printf "sbom-diff: path outside a section: %s\n", $0 > "/dev/stderr"; bad = 1; next }
        if (sect == "d" && reason == "") { printf "sbom-diff: deliberate path without a reason: %s\n", line > "/dev/stderr"; bad = 1; next }
        print line > paths
    }
    END { if (!seen) { print "sbom-diff: " FILENAME " has no volatile: section" > "/dev/stderr"; bad = 1 }; exit bad }
' "$list" || exit 2

: >> "$tmp/paths"
expr=$(paste -sd, "$tmp/paths")
if [ -n "$expr" ]; then filter="del($expr)"; else filter="."; fi

jq -S "$filter" "$new" > "$tmp/new.json" || { echo "sbom-diff: cannot normalise $new" >&2; exit 2; }
jq -S "$filter" "$old" > "$tmp/old.json" || { echo "sbom-diff: cannot normalise $old" >&2; exit 2; }

if diff -u "$tmp/old.json" "$tmp/new.json" > "$tmp/diff"; then
    echo "sbom-diff: OK, $new equals $old outside the listed paths"
    exit 0
fi
cat "$tmp/diff"
exit 1
