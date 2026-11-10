#!/bin/sh
# Markdown report of the package differences between rc1's SBOM and a new one; fails on any without a reason.
# Usage: rc1-diff.sh <rc1-bom.cdx.json> <new-bom.cdx.json> <reasons.tsv>
set -u
[ $# -eq 3 ] || { echo "usage: $0 <rc1-bom> <new-bom> <reasons.tsv>" >&2; exit 2; }
for f in "$1" "$2" "$3"; do [ -r "$f" ] || { echo "rc1-diff: cannot read $f" >&2; exit 2; }; done
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
pk() { jq -r '.components[]? | select(.type != "file" and .name != null and .version != null) | "\(.name)@\(.version)"' "$1" > "$TMP/raw" && sort -u "$TMP/raw"; }
pk "$1" > "$TMP/old" || { echo "rc1-diff: invalid SBOM $1" >&2; exit 2; }
pk "$2" > "$TMP/new" || { echo "rc1-diff: invalid SBOM $2" >&2; exit 2; }
comm -13 "$TMP/old" "$TMP/new" | sed 's/^/added\t/' > "$TMP/diff"
comm -23 "$TMP/old" "$TMP/new" | sed 's/^/removed\t/' >> "$TMP/diff"
awk -F'\t' '/^#/ || NF < 2 || $3 ~ /^[ \t]*$/ {next} {print $1 "\t" $2 "\t" $3}' "$3" | sort -u > "$TMP/reasons"
echo "# Package differences from rc1"
rc=0
for kind in added removed; do
	echo; echo "## $kind"; echo
	awk -F'\t' -v k=$kind '$1 == k {print $2}' "$TMP/diff" | while IFS= read -r p; do
		r=$(awk -F'\t' -v k=$kind -v p="$p" '$1 == k && $2 == p {print $3; exit}' "$TMP/reasons")
		if [ -n "$r" ]; then echo "- $p: $r"; else echo "- $p: NO REASON"; echo "rc1-diff: $kind $p has no reason line" >&2; fi
	done
done
cut -f1,2 "$TMP/diff" | sort > "$TMP/dkeys"
cut -f1,2 "$TMP/reasons" | sort > "$TMP/rkeys"
comm -13 "$TMP/dkeys" "$TMP/rkeys" | tr '\t' ' ' | sed 's/^/- unused reason line: /' > "$TMP/unused"
[ -z "$(comm -23 "$TMP/dkeys" "$TMP/rkeys")" ] || rc=1
if [ -s "$TMP/unused" ]; then echo; echo "## unused"; echo; cat "$TMP/unused"; fi
exit $rc
