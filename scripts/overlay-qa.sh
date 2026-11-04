#!/bin/sh
# overlay-qa.sh <tree> <overlay> <accepted>
# pkgcheck scan of <overlay> against the pinned <tree> and its profiles/embedded. Exit 0 iff pkgcheck
# succeeded and the set of reported "<category>/<package> <Keyword>" pairs equals the pairs listed in the
# first fenced block under "## Accepted warnings" in <accepted> (each line needs a "# reason").
set -eu

[ $# -eq 3 ] || { echo "usage: overlay-qa.sh <tree> <overlay> <accepted>" >&2; exit 2; }
tree=$(cd "$1" && pwd -P)
overlay=$(cd "$2" && pwd -P)
accepted=$3
[ -f "$accepted" ] || { echo "overlay-qa: $accepted: no such file" >&2; exit 2; }
[ -d "$tree/profiles/embedded" ] || { echo "overlay-qa: $tree/profiles/embedded: no such directory" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/overlay-qa.XXXXXX")
rmcache=
cleanup() {
	rm -rf "$work"
	[ -z "$rmcache" ] || rm -rf "$rmcache"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# Accepted pairs.
awk '/^## /{s=($0=="## Accepted warnings");f=0;next} s&&/^```/{if(f){exit}f=1;next} s&&f' "$accepted" \
	| grep -v '^[[:space:]]*$' >"$work/accepted.raw" || true
bad=0
while IFS= read -r line; do
	if printf '%s\n' "$line" | grep -Eq '^[^[:space:]#]+/[^[:space:]#]+ [A-Za-z0-9_]+[[:space:]]+# [^[:space:]]'; then
		printf '%s\n' "$line" | awk '{print $1, $2}' >>"$work/accepted.pairs"
	else
		echo "overlay-qa: accepted line needs '<category>/<package> <Keyword>  # <reason>': $line" >&2
		bad=1
	fi
done <"$work/accepted.raw"
[ "$bad" -eq 0 ] || exit 1
touch "$work/accepted.pairs"
LC_ALL=C sort -u "$work/accepted.pairs" >"$work/accepted"

# pkgcore reads repos.conf and make.profile under /etc/portage, a link to $HOME/portage in the toolbox.
conf=${HOME:?}/portage
mkdir -p "$conf"
printf '[DEFAULT]\nmain-repo = gentoo\n\n[gentoo]\nlocation = %s\n\n[monolith]\nlocation = %s\n' \
	"$tree" "$overlay" >"$conf/repos.conf"
rm -rf "$conf/make.profile"
ln -s "$tree/profiles/embedded" "$conf/make.profile"

[ -e "$overlay/metadata/md5-cache" ] || rmcache=$overlay/metadata/md5-cache
rc=0
pkgcheck scan --config no --cache no --repo "$overlay" -R FormatReporter \
	--format '{category}/{package} {name}' >"$work/out" 2>"$work/err" || rc=$?
if [ "$rc" -ne 0 ]; then
	cat "$work/out" "$work/err" >&2
	echo "overlay-qa: pkgcheck exited $rc" >&2
	exit 1
fi
if [ -s "$work/err" ]; then
	cat "$work/err" >&2
fi
if grep -Ev '^[^[:space:]]+/[^[:space:]]+ [A-Za-z0-9_]+$' "$work/out" | grep -v '^$' >"$work/junk"; then
	cat "$work/junk" >&2
	echo "overlay-qa: unexpected pkgcheck output (not '<category>/<package> <Keyword>')" >&2
	exit 1
fi
grep -v '^$' "$work/out" | LC_ALL=C sort -u >"$work/reported" || true

fail=0
LC_ALL=C comm -13 "$work/accepted" "$work/reported" | while IFS= read -r l; do echo "overlay-qa: new warning: $l"; done >"$work/new"
LC_ALL=C comm -23 "$work/accepted" "$work/reported" | while IFS= read -r l; do
	echo "overlay-qa: stale accepted warning: $l; remove it from $accepted"
done >"$work/stale"
if [ -s "$work/new" ]; then cat "$work/new"; fail=1; fi
if [ -s "$work/stale" ]; then cat "$work/stale"; fail=1; fi
if [ "$fail" -ne 0 ]; then exit 1; fi
echo "overlay-qa: $(wc -l <"$work/reported" | tr -d ' ') reported warning(s), all accepted"
