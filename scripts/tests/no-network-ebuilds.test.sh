#!/bin/sh
# R05: the overlay's Rust packages build from distfiles alone.
#   R05-AC-1  no overlay ebuild has network-sandbox in RESTRICT or calls cargo
#             without --offline (unless it inherits cargo.eclass)
#   R05-AC-3  rl144 and stele have -r1 revisions, Manifests listing the source
#             tarball and every crate, and matching versions.lock lines
#   R05-AC-4  every crates.io package of the project's Cargo.lock and of the
#             pinned toolchain's library/Cargo.lock is in CRATES (git sources
#             in GIT_CRATES)
# Lock files come from scripts/fixtures/R05/ (no network, Git history or image):
#   rl144-Cargo.lock      github.com/tuckermclean/rl144 f33a80efc4b0b02ce72e708182594b84695e742d
#   stele-Cargo.lock      github.com/tuckermclean/stele-browser 0e4921bbb85c88899a7919a45415a8d749df3ec8
#   library-Cargo.lock    builder image BUILDER_DIGEST (Makefile), nightly-2026-07-15
#                         lib/rustlib/src/rust/library/Cargo.lock
# CRATES entries are read as name@version (the form cargo.eclass documents) or
# name-version (older form); Manifest lines are DIST <name>-<version>.crate.
cd "$(dirname "$0")/../.." || exit 2
ROOT=$(pwd)
FIX=$ROOT/scripts/fixtures/R05
OVERLAY=$ROOT/configs/overlay
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
fails=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
check() { # check <label> <status>
	if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

# join_ebuild FILE: comments dropped, backslash continuations joined, and each
# multi-line quoted assignment (RESTRICT, CRATES, inherit) folded to one line.
join_ebuild() {
	awk '
	{ line = $0
	  if (!inq) sub(/^[ \t]*#.*/, "", line)
	  else sub(/(^|[ \t])#.*/, "", line)
	  if (cont != "") { line = cont " " line; cont = "" }
	  if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); cont = line; next }
	  if (inq) { buf = buf " " line; n = gsub(/"/, "\"", line); if (n % 2 == 1) { print buf; inq = 0 }; next }
	  n = gsub(/"/, "\"", line)
	  if (n % 2 == 1) { buf = line; inq = 1; next }
	  print line }
	END { if (inq) print buf; if (cont != "") print cont }' "$1"
}

# scan_ebuild FILE: prints one line per R05-AC-1 violation.
scan_ebuild() {
	f=$1
	join_ebuild "$f" >"$TMP/joined"
	grep -E '^[[:space:]]*(RESTRICT|[A-Z_]*RESTRICT)\+?=.*network-sandbox' "$TMP/joined" |
		sed 's/^/RESTRICT has network-sandbox: /'
	if ! grep -Eq '^[[:space:]]*inherit[[:space:]]+([^#]*[[:space:]])?cargo([[:space:]]|$)' "$TMP/joined"; then
		grep -E '(^|[;&|(]|[[:space:]]then|[[:space:]]do)[[:space:]]*cargo([[:space:]]|$)' "$TMP/joined" |
			grep -v -e '--offline' | sed 's/^/cargo without --offline: /'
	fi
}

# lock_registry LOCK: name-version of every crates.io package; lock_git: names of git ones.
lock_awk() { # lock_awk <registry|git> LOCK
	awk -v want="$1" '
	function flush() { if (name != "" && src ~ ("^" want)) print (want == "registry" ? name "-" ver : name); name = ""; ver = ""; src = "" }
	/^\[\[package\]\]/ { flush(); next }
	/^name = / { gsub(/"/, "", $3); name = $3 }
	/^version = / { gsub(/"/, "", $3); ver = $3 }
	/^source = / { gsub(/"/, "", $3); src = $3 }
	END { flush() }' "$2" | sort -u
}

# ebuild_crates EBUILD: normalized name-version of each CRATES entry, sorted unique.
ebuild_crates() {
	join_ebuild "$1" | awk '
	/^[[:space:]]*CRATES\+?="/ { s = $0; sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s); print s }' |
		tr -s ' \t' '\n' | sed '/^$/d; s/@/-/' | sort -u
}
ebuild_crates_count() { # entries, not unique
	join_ebuild "$1" | awk '
	/^[[:space:]]*CRATES\+?="/ { s = $0; sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s); print s }' |
		tr -s ' \t' '\n' | sed '/^$/d' | wc -l | tr -d ' '
}
ebuild_git_crates() { # keys of GIT_CRATES[name]=
	join_ebuild "$1" | sed -n 's/^[[:space:]]*\[\([^]]*\)\]=.*/\1/p; s/^[[:space:]]*GIT_CRATES\[\([^]]*\)\]=.*/\1/p' | sort -u
}
manifest_crates() { sed -n 's/^DIST \(.*\)\.crate .*/\1/p' "$1" | sort -u; }

# missing_from WANTED_FILE HAVE_FILE -> lines in WANTED not in HAVE
missing_from() { comm -23 "$1" "$2"; }

# ---- AC-1 controls: the scan must flag a bad ebuild and accept a clean one ----
CTL=$TMP/ctl
mkdir -p "$CTL"
cat >"$CTL/bad-restrict1.ebuild" <<'E'
EAPI=8
RESTRICT="network-sandbox"
E
cat >"$CTL/bad-restrict2.ebuild" <<'E'
EAPI=8
RESTRICT="
	mirror
	network-sandbox
"
E
cat >"$CTL/bad-cargo.ebuild" <<'E'
EAPI=8
src_compile() {
	cargo "+nightly" \
		-Z build-std \
		build --release || die
}
E
cat >"$CTL/good-offline.ebuild" <<'E'
EAPI=8
# RESTRICT="network-sandbox" in a comment is not a restriction
RESTRICT="mirror"
src_compile() {
	cargo "+nightly" \
		build --release --offline --frozen || die
}
E
cat >"$CTL/good-eclass.ebuild" <<'E'
EAPI=8
inherit cargo
src_compile() {
	cargo build --release || die
}
E
for c in bad-restrict1 bad-restrict2 bad-cargo; do
	n=$(scan_ebuild "$CTL/$c.ebuild" | wc -l)
	[ "$n" -gt 0 ]
	check "R05-AC-1 control: scan flags $c" $?
done
for c in good-offline good-eclass; do
	n=$(scan_ebuild "$CTL/$c.ebuild" | wc -l)
	[ "$n" -eq 0 ]
	check "R05-AC-1 control: scan accepts $c" $?
done

# ---- AC-1: every ebuild under configs/overlay ----
find "$OVERLAY" -name '*.ebuild' | sort >"$TMP/ebuilds"
[ -s "$TMP/ebuilds" ]
check "R05-AC-1 scan has ebuilds to scan" $?
while IFS= read -r e; do
	out=$(scan_ebuild "$e")
	if [ -z "$out" ]; then
		pass "R05-AC-1 ${e#"$ROOT"/}: no network-sandbox, no cargo without --offline"
	else
		fail "R05-AC-1 ${e#"$ROOT"/}: $(echo "$out" | head -3 | tr '\n' ';')"
	fi
done <"$TMP/ebuilds"

# ---- AC-4 control: the lock-vs-CRATES comparison detects a gap ----
cat >"$CTL/lock" <<'E'
[[package]]
name = "proj"
version = "0.1.0"

[[package]]
name = "aaa"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "bbb"
version = "2.3.4"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "ggg"
version = "0.1.0"
source = "git+https://example.org/ggg?rev=abc#abc"
E
cat >"$CTL/full.ebuild" <<'E'
CRATES="
	aaa@1.0.0
	bbb@2.3.4
"
declare -A GIT_CRATES=(
	[ggg]="https://example.org/ggg;abc;ggg-%commit%"
)
E
cat >"$CTL/gap.ebuild" <<'E'
CRATES="
	aaa@1.0.0
"
E
lock_awk registry "$CTL/lock" >"$CTL/want"
lock_awk git "$CTL/lock" >"$CTL/wantgit"
ebuild_crates "$CTL/full.ebuild" >"$CTL/have"
ebuild_git_crates "$CTL/full.ebuild" >"$CTL/havegit"
[ "$(cat "$CTL/want")" = "aaa-1.0.0
bbb-2.3.4" ] && [ "$(cat "$CTL/wantgit")" = "ggg" ] && [ -z "$(missing_from "$CTL/want" "$CTL/have")" ] &&
	[ -z "$(missing_from "$CTL/wantgit" "$CTL/havegit")" ]
check "R05-AC-4 control: complete CRATES/GIT_CRATES is accepted" $?
ebuild_crates "$CTL/gap.ebuild" >"$CTL/have"
[ "$(missing_from "$CTL/want" "$CTL/have")" = "bbb-2.3.4" ]
check "R05-AC-4 control: a missing crate is detected" $?

# ---- AC-3 / AC-4: the two packages ----
LOCKFILE=$ROOT/configs/portage/versions.lock
lock_awk registry "$FIX/library-Cargo.lock" >"$TMP/lib.want"
lock_awk git "$FIX/library-Cargo.lock" >"$TMP/lib.wantgit"
[ -s "$TMP/lib.want" ]
check "R05-AC-4 library lock fixture lists crates.io packages ($(wc -l <"$TMP/lib.want" | tr -d ' '))" $?

check_pkg() { # check_pkg category/name project-lock-fixture
	cp=$1 projlock=$2
	cat=${cp%/*} pn=${cp#*/}
	dir=$OVERLAY/$cat/$pn
	# the highest revision ebuild
	best=$(find "$dir" -maxdepth 1 -name "$pn-*.ebuild" 2>/dev/null | sed "s|.*/$pn-||; s|\.ebuild\$||" | sort -V | tail -1)
	if [ -z "$best" ]; then
		fail "R05-AC-3 $cp: no ebuild under configs/overlay/$cp"
		return
	fi
	pvr=$best
	case $pvr in *-r[0-9]*) ;; *) fail "R05-AC-3 $cp: highest ebuild $pvr is not a new revision (-rN)"; return ;; esac
	pv=${pvr%-r*}
	rev=${pvr##*-r}
	pass "R05-AC-3 $cp: revision ebuild $pn-$pvr exists"
	[ "$rev" -ge 1 ]
	check "R05-AC-3 $cp: revision is -r1 or higher" $?
	eb=$dir/$pn-$pvr.ebuild
	man=$dir/Manifest

	# AC-3: versions.lock line matches the highest ebuild
	grep -qx "$cp:$pvr:0" "$LOCKFILE"
	check "R05-AC-3 $cp: versions.lock has $cp:$pvr:0" $?
	n=$(grep -c "^$cp:" "$LOCKFILE")
	[ "$n" -eq 1 ]
	check "R05-AC-3 $cp: exactly one versions.lock line ($n)" $?

	# AC-3: Manifest lists the source tarball and every crate
	if [ ! -f "$man" ]; then
		fail "R05-AC-3 $cp: Manifest missing"
		fail "R05-AC-3 $cp: Manifest lists every CRATES entry (no Manifest)"
		fail "R05-AC-3 $cp: CRATES count equals Manifest crate DIST lines (no Manifest)"
	else
		grep -q "^DIST $pn-$pv\.tar\.gz " "$man"
		check "R05-AC-3 $cp: Manifest has DIST $pn-$pv.tar.gz" $?
		ebuild_crates "$eb" >"$TMP/have"
		manifest_crates "$man" >"$TMP/man"
		cnt=$(ebuild_crates_count "$eb")
		mcnt=$(grep -c '^DIST .*\.crate ' "$man")
		[ "$cnt" -gt 0 ] && [ "$cnt" -eq "$mcnt" ] && [ "$cnt" -eq "$(wc -l <"$TMP/have" | tr -d ' ')" ]
		check "R05-AC-3 $cp: CRATES entries ($cnt) = Manifest crate DIST lines ($mcnt), no duplicates" $?
		m=$(missing_from "$TMP/have" "$TMP/man" | head -5 | tr '\n' ' ')
		[ -z "$m" ] && [ -s "$TMP/have" ]
		check "R05-AC-3 $cp: Manifest has a DIST <name>-<version>.crate line for every CRATES entry ${m:+(missing: $m...)}" $?
		m=$(missing_from "$TMP/man" "$TMP/have" | head -5 | tr '\n' ' ')
		[ -z "$m" ]
		check "R05-AC-3 $cp: Manifest lists no crate outside CRATES ${m:+(extra: $m...)}" $?
	fi

	# AC-4: lock entries against CRATES / GIT_CRATES
	ebuild_crates "$eb" >"$TMP/have"
	ebuild_git_crates "$eb" >"$TMP/havegit"
	lock_awk registry "$FIX/$projlock" >"$TMP/proj.want"
	lock_awk git "$FIX/$projlock" >"$TMP/proj.wantgit"
	[ -s "$TMP/proj.want" ]
	check "R05-AC-4 $cp: project lock fixture $projlock lists crates.io packages ($(wc -l <"$TMP/proj.want" | tr -d ' '))" $?
	m=$(missing_from "$TMP/proj.want" "$TMP/have" | head -5 | tr '\n' ' ')
	[ -s "$TMP/have" ] && [ -z "$m" ]
	check "R05-AC-4 $cp: CRATES covers every package of the project Cargo.lock ${m:+(missing: $m...)}" $?
	m=$(missing_from "$TMP/lib.want" "$TMP/have" | head -5 | tr '\n' ' ')
	[ -s "$TMP/have" ] && [ -z "$m" ]
	check "R05-AC-4 $cp: CRATES covers every package of the toolchain library/Cargo.lock ${m:+(missing: $m...)}" $?
	cat "$TMP/proj.wantgit" "$TMP/lib.wantgit" | sort -u >"$TMP/allgit"
	m=$(missing_from "$TMP/allgit" "$TMP/havegit" | head -5 | tr '\n' ' ')
	[ -z "$m" ]
	check "R05-AC-4 $cp: GIT_CRATES covers every git-sourced lock package ($(wc -l <"$TMP/allgit" | tr -d ' ') needed) ${m:+(missing: $m...)}" $?
}

check_pkg games-roguelike/rl144 rl144-Cargo.lock
check_pkg www-client/stele stele-Cargo.lock

if [ "$fails" -gt 0 ]; then
	echo "no-network-ebuilds: $fails check(s) FAILED"
	exit 1
fi
echo "no-network-ebuilds: all checks passed"
