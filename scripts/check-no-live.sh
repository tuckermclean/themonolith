#!/bin/sh
# check-no-live.sh <file>: <file> holds `emerge --pretend` output. Exit 1, naming every live package
# (category/package-version with a 9999 version) the graph would merge, host side or target side; exit 0 when
# there is none. A live ebuild has no distfile: it cannot be archived, pinned or fetched offline.
set -u

[ $# -eq 1 ] || { echo "usage: check-no-live.sh <emerge-pretend-output>" >&2; exit 2; }
[ -f "$1" ] && [ -r "$1" ] || { echo "check-no-live: $1 is missing or unreadable" >&2; exit 2; }

live=$(awk '/^\[ebuild/ { i = index($0, "] "); if (i == 0) next; split(substr($0, i + 2), f, " "); p = f[1]; sub(/::.*/, "", p); sub(/:[^:]*$/, "", p); if (p ~ /-[0-9][0-9.]*9999(-r[0-9]+)?$/ || p ~ /-9999(-r[0-9]+)?$/) print p }' "$1" | sort -u) || { echo "check-no-live: cannot read $1" >&2; exit 2; }

if [ -n "$live" ]; then
	echo "check-no-live: the graph holds live (9999) packages, which have no distfile and cannot be built offline:" >&2
	echo "$live" | sed 's/^/  /' >&2
	exit 1
fi
echo "check-no-live: no live package in the graph"
