#!/bin/sh
# normalize-vdb.sh <vdb-dir>: make a rootfs copy of var/db/pkg independent of when and in which order
# the packages were built. Rewrites <vdb-dir> in place.
#   BUILD_TIME   := SOURCE_DATE_EPOCH (Portage records the wall clock)
#   COUNTER      := 1..N in LC_ALL=C order of category/pn-pv
#   environment.bz2 loses the declare lines of variables that change every run or between builders (time, random,
#   JOBS, LOAD_AVG, MAKEOPTS, the compression command, the host name), then bzip2 -9
#   BINPKGMD5    removed (md5 of the gpkg just packed, which embeds the build time and file mtimes)
#   CONTENTS     the trailing mtime of every obj and sym line := SOURCE_DATE_EPOCH
set -eu

[ -n "${SOURCE_DATE_EPOCH-}" ] || { echo "normalize-vdb.sh: SOURCE_DATE_EPOCH is not set" >&2; exit 1; }
[ $# -eq 1 ] || { echo "usage: normalize-vdb.sh <vdb-dir>" >&2; exit 2; }
vdb=$1
[ -d "$vdb" ] || { echo "normalize-vdb.sh: $vdb is not a directory" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/normalize-vdb.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

(cd "$vdb" && for d in */*/; do [ -d "$d" ] && echo "${d%/}"; done) | LC_ALL=C sort >"$tmp/cpvs"

n=0
while read -r cpv; do
	n=$((n + 1))
	p=$vdb/$cpv
	if [ -f "$p/BUILD_TIME" ]; then echo "$SOURCE_DATE_EPOCH" >"$p/BUILD_TIME"; fi
	if [ -f "$p/COUNTER" ]; then echo "$n" >"$p/COUNTER"; fi
	if [ -f "$p/environment.bz2" ]; then
		bzip2 -dc "$p/environment.bz2" >"$tmp/env"
		grep -v -E '^declare [^=]* (EPOCHREALTIME|EPOCHSECONDS|SRANDOM|RANDOM|BASHPID|JOBS|LOAD_AVG|MAKEOPTS|PORTAGE_COMPRESSION_COMMAND|HOSTNAME|HOST|PORTAGE_NICENESS)=' "$tmp/env" >"$tmp/env.n" || [ $? -eq 1 ]
		bzip2 -9 -c "$tmp/env.n" >"$tmp/env.bz2"
		cat "$tmp/env.bz2" >"$p/environment.bz2"
	fi
	rm -f "$p/BINPKGMD5"
	if [ -f "$p/CONTENTS" ]; then
		sed -E "s/^(obj|sym) (.*) [0-9]+\$/\\1 \\2 $SOURCE_DATE_EPOCH/" "$p/CONTENTS" >"$tmp/contents"
		cat "$tmp/contents" >"$p/CONTENTS"
	fi
done <"$tmp/cpvs"
