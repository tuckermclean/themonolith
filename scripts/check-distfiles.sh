#!/bin/sh
# check-distfiles.sh <distdir>: every file named in <distdir>/distfiles.list is present in <distdir>.
# Exit 0 only then; otherwise exit 1 naming each missing file. It touches no network.
set -u

[ $# -eq 1 ] || { echo "usage: check-distfiles.sh <distdir>" >&2; exit 2; }
dir=$1
list=$dir/distfiles.list
[ -s "$list" ] || { echo "check-distfiles: $list is missing or empty" >&2; exit 1; }

missing=0
while IFS= read -r f; do
	[ -n "$f" ] || continue
	if [ ! -f "$dir/$f" ]; then
		echo "check-distfiles: missing distfile: $f" >&2
		missing=$((missing + 1))
	fi
done <"$list"
if [ $missing -ne 0 ]; then
	echo "check-distfiles: $missing distfile(s) missing; the offline build cannot fetch them" >&2
	exit 1
fi
echo "check-distfiles: all $(wc -l <"$list") distfiles are present"
