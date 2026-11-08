#!/bin/sh
# unpack-distfiles.sh <archive.tar> <sha256:digest> <distdir> [drop-name]: check the archive against the digest
# recorded in release-inputs.json, then unpack it into <distdir>. drop-name (the AC-4 run) removes that one file
# afterwards, so the build must fail on it.
set -eu

[ $# -ge 3 ] && [ $# -le 4 ] || { echo "usage: unpack-distfiles.sh <archive.tar> <sha256:digest> <distdir> [drop-name]" >&2; exit 2; }
archive=$1
want=$2
dir=$3
drop=${4:-}

[ -f "$archive" ] || { echo "unpack-distfiles: $archive is missing" >&2; exit 1; }
case $want in
sha256:?*) ;;
*) echo "unpack-distfiles: '$want' is not a sha256:<hex> digest" >&2; exit 1 ;;
esac
got=$(sha256sum "$archive")
got=sha256:${got%% *}
[ "$got" = "$want" ] || { echo "unpack-distfiles: $archive is $got, release-inputs.json says $want" >&2; exit 1; }

rm -rf "$dir"
mkdir -p "$dir"
tar --extract --no-same-owner --file "$archive" --directory "$dir"
if [ -n "$drop" ]; then
	case $drop in
	*/* | .*) echo "unpack-distfiles: refusing to drop '$drop'" >&2; exit 1 ;;
	esac
	[ -f "$dir/$drop" ] || { echo "unpack-distfiles: $drop is not in the archive" >&2; exit 1; }
	rm -f "$dir/$drop"
	echo "unpack-distfiles: removed $drop (test input)"
fi
