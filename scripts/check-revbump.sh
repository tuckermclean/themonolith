#!/bin/sh
# check-revbump.sh <base> <head>: a change to an overlay package needs a new ebuild (-rN or version).
set -eu
[ $# -eq 2 ] || { echo "usage: check-revbump.sh <base> <head>" >&2; exit 2; }
base=$1 head=$2
O=configs/overlay
tmp=$(mktemp -d "${TMPDIR:-/tmp}/revbump.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
: >"$tmp/added"; : >"$tmp/touched"; : >"$tmp/eclasses"; : >"$tmp/bad"

git diff --name-status -M "$base" "$head" -- "$O" >"$tmp/diff"
tab=$(printf '\t')
while IFS=$tab read -r st p1 p2; do
	for p in $p1 $p2; do
		rest=${p#"$O"/}
		case $rest in
		eclass/*.eclass) basename "$rest" .eclass >>"$tmp/eclasses"; continue ;;
		eclass/*) continue ;;
		*/*/*) ;;
		*) continue ;;
		esac
		cat=${rest%%/*}; r2=${rest#*/}; pn=${r2%%/*}; file=${r2#*/}
		if [ "$st" = A ]; then
			case $file in */*) ;; *.ebuild) echo "$cat/$pn" >>"$tmp/added" ;; esac
		fi
		[ "$file" = metadata.xml ] || echo "$cat/$pn" >>"$tmp/touched"
	done
done <"$tmp/diff"

# a package passes when it gains an ebuild; otherwise any change besides metadata.xml fails
sort -u "$tmp/touched" | while read -r pkg; do
	grep -qxF "$pkg" "$tmp/added" || echo "$pkg: changed without a new ebuild (add a new -rN or version)" >>"$tmp/bad"
done

# an eclass change needs every inheriting package bumped
sort -u "$tmp/eclasses" | while read -r ecl; do
	re=$(printf '%s' "$ecl" | sed 's/[.]/[.]/g')
	git ls-tree -r --name-only "$head" -- "$O" | grep -E "^$O/[^/]+/[^/]+/[^/]+[.]ebuild\$" | while read -r f; do
		if git show "$head:$f" | grep -Eq "^[[:space:]]*inherit([[:space:]]+[^#]*)?[[:space:]]$re([[:space:]]|\$)"; then
			rest=${f#"$O"/}; pkg=${rest%/*}
			grep -qxF "$pkg" "$tmp/added" || echo "$pkg: inherits changed eclass $ecl without a new ebuild" >>"$tmp/bad"
		fi
	done
done

if [ -s "$tmp/bad" ]; then
	echo "check-revbump: overlay change needs a revision bump:" >&2
	sort -u "$tmp/bad" >&2
	exit 1
fi
echo "check-revbump: ok"
