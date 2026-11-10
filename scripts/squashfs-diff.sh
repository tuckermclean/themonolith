#!/bin/sh
# Markdown report of the paths added to and removed from a squashfs, from `unsquashfs -lls` listings.
# Sizes, owners and times are not compared; a symlink's target is not part of its path.
# Usage: squashfs-diff.sh <old.squashfs> <new.squashfs>
set -u
[ $# -eq 2 ] || { echo "usage: $0 <old.squashfs> <new.squashfs>" >&2; exit 2; }
for f in "$1" "$2"; do [ -r "$f" ] || { echo "squashfs-diff: cannot read $f" >&2; exit 2; }; done
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
# An entry is <mode> <owner/group> <size, or major, minor> <date> <time> <path> [-> <target>].
paths() {
	unsquashfs -lls "$1" > "$TMP/list" || return 1
	sed -nE -e 's/^l[^ ]+ +[^ ]+ +[0-9]+ +[0-9-]+ +[0-9:]+ (.*) -> .*$/\1/p' \
		-e 's/^[^l][^ ]+ +[^ ]+ +[0-9]+(, *[0-9]+)? +[0-9-]+ +[0-9:]+ (.*)$/\2/p' "$TMP/list" | LC_ALL=C sort -u
}
paths "$1" > "$TMP/old" || { echo "squashfs-diff: unsquashfs failed on $1" >&2; exit 2; }
paths "$2" > "$TMP/new" || { echo "squashfs-diff: unsquashfs failed on $2" >&2; exit 2; }
echo "# Squashfs file differences from rc1"
for kind in added removed; do
	echo; echo "## Paths $kind"; echo
	if [ $kind = added ]; then LC_ALL=C comm -13 "$TMP/old" "$TMP/new"; else LC_ALL=C comm -23 "$TMP/old" "$TMP/new"; fi | sed 's/^/- /'
done
exit 0
