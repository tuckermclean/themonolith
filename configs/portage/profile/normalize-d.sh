#!/bin/sh
# Normalises the wall-clock stamps in a package image directory before Portage records CONTENTS:
#   gzip files (*.gz, *.tgz)  MTIME field of the header (bytes 4-7) -> 0
#   ar archives (*.a)         date field of the first member, the armap (bytes 24-35) -> "0"
# File mtimes and modes are kept. Usage: normalize-d.sh <image-dir>
set -eu

dir=${1:?usage: normalize-d.sh <image-dir>}
[ -d "$dir" ] || { echo "normalize-d: $dir is not a directory" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# patch <file> <offset> <printf format of the replacement bytes>
patch() {
	mode=$(stat -c %a "$1")
	touch -r "$1" "$tmp/ref"
	chmod u+w "$1"
	printf "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none
	chmod "$mode" "$1"
	touch -r "$tmp/ref" "$1"
}

find "$dir" -type f \( -name '*.gz' -o -name '*.tgz' -o -name '*.a' \) >"$tmp/list"

gz=0
ar=0
while IFS= read -r f; do
	case "$f" in
	*.gz|*.tgz)
		[ "$(head -c 2 "$f" | od -An -tx1 | tr -d ' \n')" = 1f8b ] || continue
		patch "$f" 4 '\000\000\000\000'
		gz=$((gz + 1))
		;;
	*.a)
		[ "$(head -c 8 "$f")" = '!<arch>' ] || continue
		patch "$f" 24 '0           '
		ar=$((ar + 1))
		;;
	esac
done <"$tmp/list"

echo "normalize-d: $gz gzip, $ar ar in $dir"
