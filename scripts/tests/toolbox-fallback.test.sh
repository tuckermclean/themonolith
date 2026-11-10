#!/bin/sh
# F02-AC-1: a fallback build of the toolbox is loud in Actions and says whether it was expected.
# Runs toolbox/run against a fake engine whose pull fails, in a temporary git repository holding
# copies of toolbox/run, toolbox/Containerfile, toolbox/selfcheck, scripts/toolbox-fallback.sh and a
# Makefile REGISTRY line, so it needs no history of the checkout. Fixed interface (brief item 1):
#   toolbox/run, GITHUB_ACTIONS=true, no image and no pull: stderr gets `toolbox/run: no <tag> to pull; building`,
#   then `sh scripts/toolbox-fallback.sh <tag>` prints one ::warning:: line on stderr and appends one line to
#   GITHUB_STEP_SUMMARY: "as expected" (inputs differ from the base), "main's image is missing" + "Toolbox Image"
#   (equal; never "as expected"), "base could not be read" (unreadable). Base: BASE, else origin/$GITHUB_BASE_REF
#   (fetched when missing), else origin/main.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES

# Fake engine: logs each call; FAKE_HAVE=1 local image exists, FAKE_PULL=1 the pull works.
cat >"$TMP/engine" <<'EOS'
#!/bin/sh
echo "$*" >>"$FAKE_LOG"
case $1 in
image) [ "${FAKE_HAVE:-0}" = 1 ] ;;
pull) [ "${FAKE_PULL:-0}" = 1 ] ;;
esac
EOS
chmod +x "$TMP/engine"

git_() { git -c user.email=t@example.test -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

W=$TMP/work
mkdir -p "$W/toolbox" "$W/scripts"
cp "$ROOT/toolbox/run" "$ROOT/toolbox/Containerfile" "$ROOT/toolbox/selfcheck" "$W/toolbox/"
[ -f "$ROOT/scripts/toolbox-fallback.sh" ] && cp "$ROOT/scripts/toolbox-fallback.sh" "$W/scripts/"
printf 'REGISTRY ?= registry.example.test/owner/repo\n' >"$W/Makefile"
(
	cd "$W" || exit 1
	git_ init -q . >/dev/null
	# c1: an older Containerfile; c2: the real inputs.
	{ cat toolbox/Containerfile; echo '# older'; } >"$TMP/old"
	cp toolbox/Containerfile "$TMP/real"
	cp "$TMP/old" toolbox/Containerfile
	git_ add -A && git_ commit -q -m c1
	cp "$TMP/real" toolbox/Containerfile
	git_ add -A && git_ commit -q -m c2
) || { echo "FAIL: temporary repository"; exit 1; }
C1=$(git -C "$W" rev-parse HEAD~1)
C2=$(git -C "$W" rev-parse HEAD)
inputs=$(cd "$W/toolbox" && cat Containerfile selfcheck | sha256sum | cut -c1-12)
tag=registry.example.test/owner/repo/toolbox:$inputs

# A local bare "origin": main = c2 (equal), trunk = c1 (differs).
git_ init -q --bare "$TMP/origin.git" >/dev/null
git_ -C "$W" remote add origin "file://$TMP/origin.git"
git_ -C "$W" push -q origin "$C2:refs/heads/main" "$C1:refs/heads/trunk" 2>/dev/null
git_ -C "$W" update-ref -d refs/remotes/origin/trunk 2>/dev/null

# go <name> VAR=value... : run toolbox/run in the repo; out/err/summary/log under $TMP/<name>.*
go() {
	n=$1; shift
	: >"$TMP/$n.log"; : >"$TMP/$n.sum"
	(
		cd "$W" || exit 1
		env -u TOOLBOX -u REGISTRY -u GITHUB_ACTIONS -u BASE -u GITHUB_BASE_REF -u GITHUB_STEP_SUMMARY \
			-u MONOLITH_TOOLBOX_PULL -u GITHUB_TOKEN \
			MONOLITH_ENGINE="$TMP/engine" FAKE_LOG="$TMP/$n.log" XDG_RUNTIME_DIR="$TMP" \
			GITHUB_STEP_SUMMARY="$TMP/$n.sum" "$@" toolbox/run -- true >"$TMP/$n.out" 2>"$TMP/$n.err"
	)
}
warn() { grep '^::warning::' "$TMP/$1.err"; }
nowarn() { ! grep -q '::warning::' "$TMP/$1.err" "$TMP/$1.out"; }
# check <name> <label> <phrase> [<phrase>...] : warning line (stderr) and summary line name the tag and hold every phrase
check() {
	n=$1; l=$2; shift 2
	w=$(warn "$n"); s=$(cat "$TMP/$n.sum")
	good=1
	[ "$(printf '%s\n' "$w" | grep -c .)" = 1 ] || good=0
	[ "$(grep -c . "$TMP/$n.sum")" = 1 ] || good=0
	case $w in *"$tag"*) ;; *) good=0 ;; esac
	case $s in *"$tag"*) ;; *) good=0 ;; esac
	for p in "$@"; do
		case $w in *"$p"*) ;; *) good=0 ;; esac
		case $s in *"$p"*) ;; *) good=0 ;; esac
	done
	grep -q "^toolbox/run: no $tag to pull; building\$" "$TMP/$n.err" || good=0
	grep -q '::warning::' "$TMP/$n.out" && good=0
	if [ $good = 1 ]; then ok "$l"; else
		fail "$l"; sed 's/^/  | err: /' "$TMP/$n.err"; sed 's/^/  | summary: /' "$TMP/$n.sum"
	fi
}
absent() { # <name> <label> <phrase>: neither the warning nor the summary holds the phrase
	w=$(warn "$1"); s=$(cat "$TMP/$1.sum")
	if [ -z "$w" ] || [ -z "$s" ]; then fail "$2 (no warning or summary line at all)"; return; fi
	case $w$s in *"$3"*) fail "$2" ;; *) ok "$2" ;; esac
}

# The subject missing is a failure of every Actions case below, never a skip.
[ -f "$ROOT/scripts/toolbox-fallback.sh" ] || echo "note: scripts/toolbox-fallback.sh is absent"

go differ GITHUB_ACTIONS=true BASE="$C1"
check differ "F02-AC-1: inputs differ from BASE: warning (stderr) and summary name the tag and say 'as expected'" "as expected"

go equal GITHUB_ACTIONS=true BASE="$C2"
check equal "F02-AC-1: inputs equal BASE: warning and summary name the tag, say main's image is missing and name Toolbox Image" \
	"main's image is missing" "Toolbox Image"
absent equal "F02-AC-1: inputs equal BASE: neither line says 'as expected'" "as expected"

go unread GITHUB_ACTIONS=true BASE=0123456789abcdef0123456789abcdef01234567
check unread "F02-AC-1: BASE unreadable: warning and summary name the tag and say the base could not be read" "base could not be read"
absent unread "F02-AC-1: BASE unreadable: neither line says 'as expected'" "as expected"

go nobase GITHUB_ACTIONS=true
check nobase "F02-AC-1: no BASE, no GITHUB_BASE_REF: the base is origin/main (equal here)" "main's image is missing" "Toolbox Image"

go fetchref GITHUB_ACTIONS=true GITHUB_BASE_REF=trunk
check fetchref "F02-AC-1: GITHUB_BASE_REF=trunk, origin/trunk missing: fetched, the base is origin/trunk (differs here)" "as expected"

go local GITHUB_ACTIONS=true GITHUB_BASE_REF=trunk BASE="$C2"
check local "F02-AC-1: BASE wins over GITHUB_BASE_REF" "main's image is missing"

go plain BASE="$C1"
if grep -q "^toolbox/run: no $tag to pull; building\$" "$TMP/plain.err" && nowarn plain && [ ! -s "$TMP/plain.sum" ]; then
	ok "F02-AC-1: without GITHUB_ACTIONS: the stderr line, no ::warning::, no summary"
else fail "F02-AC-1: without GITHUB_ACTIONS: the stderr line, no ::warning::, no summary"; sed 's/^/  | err: /' "$TMP/plain.err"; fi

go pulled GITHUB_ACTIONS=true BASE="$C1" FAKE_PULL=1
if grep -q '^toolbox/run: pulled ' "$TMP/pulled.err" && nowarn pulled && [ ! -s "$TMP/pulled.sum" ] \
	&& ! grep -q 'to pull; building' "$TMP/pulled.err"; then
	ok "F02-AC-1: a successful pull prints neither the warning nor a summary line"
else fail "F02-AC-1: a successful pull prints neither the warning nor a summary line"; sed 's/^/  | err: /' "$TMP/pulled.err"; fi

go have GITHUB_ACTIONS=true BASE="$C1" FAKE_HAVE=1
if nowarn have && [ ! -s "$TMP/have.sum" ] && ! grep -q 'building\|pulled' "$TMP/have.err"; then
	ok "F02-AC-1: an existing local image prints neither the warning nor a summary line"
else fail "F02-AC-1: an existing local image prints neither the warning nor a summary line"; sed 's/^/  | err: /' "$TMP/have.err"; fi

if [ $fails = 0 ]; then echo "toolbox-fallback.test.sh: all passed"; else echo "toolbox-fallback.test.sh: $fails failed"; exit 1; fi
