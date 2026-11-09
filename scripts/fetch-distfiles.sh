#!/bin/sh
# fetch-distfiles.sh <distdir> <archive.tar> <source-date-epoch>: list the distfiles Portage fetched into
# <distdir> (distfiles.list, one name per line, sorted) and pack them with that list into <archive.tar>:
# sorted, every mtime clamped to the epoch, owner-neutral, so the same files give the same bytes.
set -eu

[ $# -eq 3 ] || { echo "usage: fetch-distfiles.sh <distdir> <archive.tar> <source-date-epoch>" >&2; exit 2; }
dir=$1
archive=$2
sde=$3
[ -d "$dir" ] || { echo "fetch-distfiles: $dir is not a directory" >&2; exit 1; }
case $sde in
'' | *[!0-9]*) echo "fetch-distfiles: SOURCE_DATE_EPOCH '$sde' is not a number" >&2; exit 1 ;;
esac
case $archive in
/*) ;;
*) archive=$(pwd)/$archive ;;
esac

rm -f "$dir/distfiles.list"
(cd "$dir" && find . -type f ! -path './.*' | sed 's,^\./,,' | LC_ALL=C sort) >"$archive.list"
mv "$archive.list" "$dir/distfiles.list"
[ -s "$dir/distfiles.list" ] || { echo "fetch-distfiles: Portage fetched no distfile into $dir" >&2; exit 1; }

rm -f "$archive.part"
(cd "$dir" && { cat distfiles.list; echo distfiles.list; } >"$archive.files" &&
	tar --create --file "$archive.part" --no-recursion --files-from "$archive.files" \
		--sort=name --mtime="@$sde" --owner=0 --group=0 --numeric-owner --mode=u=rw,go=r --format=posix \
		--pax-option=delete=atime,delete=ctime)
rm -f "$archive.files"
mv "$archive.part" "$archive"
echo "fetch-distfiles: $(wc -l <"$dir/distfiles.list") distfiles in $archive"
