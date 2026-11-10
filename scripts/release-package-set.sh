#!/bin/sh
# Fail unless every atom of the fixed list is in world, in the rootfs VDB and in built-this-run audit rows.
# Usage: release-package-set.sh --world <world> --rootfs <dir> --audit <source-audit.tsv> [--atoms <list>]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
world= rootfs= audit= atoms=$HERE/../configs/release/world-b9f533b.txt
usage() { echo "usage: $0 --world <world> --rootfs <dir> --audit <source-audit.tsv> [--atoms <list>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || usage
	case $1 in
	--world) world=$2 ;; --rootfs) rootfs=$2 ;; --audit) audit=$2 ;; --atoms) atoms=$2 ;;
	*) usage ;;
	esac
	shift 2
done
[ -n "$world" ] && [ -n "$rootfs" ] && [ -n "$audit" ] || usage
[ -r "$world" ] && [ -r "$audit" ] && [ -r "$atoms" ] && [ -d "$rootfs/var/db/pkg" ] || { echo "release-package-set: unreadable input" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
# category/package from an atom or a cpv: operators, slot and version stripped
norm() { sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' -e 's/^[<>=~!]*//' -e 's/:.*//' -e 's/-[0-9][^/]*$//' | sort -u; }

norm < "$world" > "$TMP/world"
( cd "$rootfs/var/db/pkg" && for d in */*; do [ -d "$d" ] && echo "$d"; done ) | norm > "$TMP/vdb"
awk -F'\t' 'NR > 1 && $3 == "built-this-run" { print $2 }' "$audit" | norm > "$TMP/audit"
sed -e '/^$/d' "$atoms" | sort -u > "$TMP/atoms"

rc=0
for src in world vdb audit; do
	comm -23 "$TMP/atoms" "$TMP/$src" | while IFS= read -r a; do echo "$a: missing from $src"; done > "$TMP/miss"
	if [ -s "$TMP/miss" ]; then cat "$TMP/miss"; rc=1; fi
done
[ "$rc" = 0 ] && echo "release-package-set: OK, $(wc -l < "$TMP/atoms" | tr -d ' ') atoms in world, vdb and audit"
exit $rc
