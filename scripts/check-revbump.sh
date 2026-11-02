#!/bin/sh
# check-revbump.sh <base> <head>: a change to an overlay package needs a new ebuild (-rN or version).
set -eu
[ $# -eq 2 ] || { echo "usage: check-revbump.sh <base> <head>" >&2; exit 2; }
base=$1 head=$2
O=configs/overlay
tmp=$(mktemp -d "${TMPDIR:-/tmp}/revbump.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
: >"$tmp/added"; : >"$tmp/dropped"; : >"$tmp/other"; : >"$tmp/touched"; : >"$tmp/eclasses"; : >"$tmp/bad"

# role: d = path removed (deleted, or the source of a rename), n = path new or changed
git -c core.quotePath=false diff --name-status -M "$base" "$head" -- "$O" >"$tmp/diff"
tab=$(printf '\t')
while IFS=$tab read -r st p1 p2; do
	case $st in
	D) roles="d:$p1" ;;
	R*) roles="d:$p1 n:$p2" ;;
	*) roles="n:$p1" ;;
	esac
	for pr in $roles; do
		role=${pr%%:*}; p=${pr#*:}
		rest=${p#"$O"/}
		case $rest in
		profiles/* | metadata/*) continue ;;
		eclass/*.eclass) basename "$rest" .eclass >>"$tmp/eclasses"; continue ;;
		eclass/*) continue ;;
		*/*/*) ;;
		*) continue ;;
		esac
		cat=${rest%%/*}; r2=${rest#*/}; pn=${r2%%/*}; file=${r2#*/}
		pkg=$cat/$pn
		case $file in
		*/*) ebuild=0 ;;
		*.ebuild) ebuild=1 ;;
		*) ebuild=0 ;;
		esac
		[ "$file" = metadata.xml ] || echo "$pkg" >>"$tmp/touched"
		if [ "$role" = d ]; then
			[ "$ebuild" = 1 ] && echo "$pkg" >>"$tmp/dropped"
			continue
		fi
		# a new ebuild is a bump when added, or renamed within its package
		if [ "$ebuild" = 1 ] && case $st:$p1 in A:* | R*:"$O/$pkg/"*) true ;; *) false ;; esac; then
			echo "$pkg" >>"$tmp/added"
		elif [ "$file" != metadata.xml ] && [ "$file" != Manifest ]; then
			echo "$pkg" >>"$tmp/other"
		fi
	done
done <"$tmp/diff"

# a package passes when it gains an ebuild, or drops one and changes nothing else but Manifest/metadata.xml;
# otherwise any change besides metadata.xml fails
sort -u "$tmp/touched" | while read -r pkg; do
	grep -qxF "$pkg" "$tmp/added" && continue
	if grep -qxF "$pkg" "$tmp/dropped" && ! grep -qxF "$pkg" "$tmp/other"; then continue; fi
	echo "$pkg: changed without a new ebuild (add a new -rN or version)" >>"$tmp/bad"
done

# an eclass change needs every inheriting package bumped
sort -u "$tmp/eclasses" | while read -r ecl; do
	re=$(printf '%s' "$ecl" | sed 's/[.]/[.]/g')
	git -c core.quotePath=false ls-tree -r --name-only "$head" -- "$O" | grep -E "^$O/[^/]+/[^/]+/[^/]+[.]ebuild\$" | while read -r f; do
		if git show "$head:$f" | sed -E -e ':a' -e '/\\$/{N;s/\\\n/ /;ba' -e '}' -e 's/(^|[[:space:]])#.*//' |
			grep -Eq "(^|[;&|[:space:]])inherit[[:space:]]([^#]*[[:space:]])?$re([[:space:];&|)]|\$)"; then
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
