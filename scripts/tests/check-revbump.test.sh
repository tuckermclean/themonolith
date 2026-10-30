#!/bin/sh
# R04 revbump-check: scripts/check-revbump.sh <base> <head>, `make test-revbump`, pr-validate.yml.
# Criteria: R04-AC-1 .. R04-AC-4. Builds its own temporary git repos; never reads this checkout's
# history (it also runs in commit-less copies). Needs no network.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES GIT_DIR GIT_WORK_TREE

here=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
script=$root/scripts/check-revbump.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-revbump.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

O=configs/overlay
n=0
g() { git "$@"; }
snap() { # snap <message> [<tag>]: stage everything in $repo, record it, optionally tag
	(
		cd "$repo" || exit 1
		g add -A || exit 1
		g commit -q -m "$1" || exit 1
		if [ -n "${2:-}" ]; then g tag "$2"; fi
	) >/dev/null 2>&1
}
newrepo() { # newrepo: sets repo; the base revision holds the fixture overlay, tagged "base"
	n=$((n + 1)); repo=$tmp/r$n
	mkdir -p "$repo/$O/app-misc/foo/files" "$repo/$O/app-misc/bar/files" "$repo/$O/eclass"
	(cd "$repo" && g init -q -b main .) >/dev/null 2>&1
	printf 'EAPI=8\ninherit myecl\n' >"$repo/$O/app-misc/foo/foo-1.ebuild"
	printf 'EAPI=8\ninherit myecl\n' >"$repo/$O/app-misc/bar/bar-1.ebuild"
	printf 'EAPI=8\n' >"$repo/$O/app-misc/bar/bar-2.ebuild"
	printf 'patch\n' >"$repo/$O/app-misc/foo/files/a.patch"
	printf 'patch\n' >"$repo/$O/app-misc/bar/files/b.patch"
	echo '<pkgmetadata/>' >"$repo/$O/app-misc/foo/metadata.xml"
	echo '<pkgmetadata/>' >"$repo/$O/app-misc/bar/metadata.xml"
	echo 'DIST x 1' >"$repo/$O/app-misc/foo/Manifest"
	echo 'DIST y 1' >"$repo/$O/app-misc/bar/Manifest"
	echo '# eclass' >"$repo/$O/eclass/myecl.eclass"
	echo '# eclass' >"$repo/$O/eclass/unused.eclass"
	snap base base
}
change() { snap change; }
run() { # runs the script over base..HEAD; sets rc, out
	out=$(cd "$repo" && sh "$script" base HEAD 2>&1); rc=$?
}
expect_pass() { # expect_pass <label>
	run
	if [ $rc -eq 0 ]; then pass "$1"; else fail "$1 (rc=$rc: $out)"; fi
}
expect_fail() { # expect_fail <label> <named pkg> [<pkg not to name>]
	l=$1; named=$2; other=${3:-}
	run
	if [ ! -f "$script" ]; then fail "$l (script missing)"; return; fi
	if [ $rc -eq 0 ]; then fail "$l (rc=0: $out)"; return; fi
	case $out in *"$named"*) ;; *) fail "$l (does not name $named: $out)"; return ;; esac
	if [ -n "$other" ]; then
		case $out in *"$other"*) fail "$l (names $other: $out)"; return ;; esac
	fi
	pass "$l"
}

if [ -f "$script" ]; then pass "scripts/check-revbump.sh exists"; else fail "scripts/check-revbump.sh exists"; fi

# ---- R04-AC-1: edit without a new ebuild fails, naming <cat>/<pn> ----
newrepo; echo 'src_install() { :; }' >>"$repo/$O/app-misc/foo/foo-1.ebuild"; change
expect_fail "R04-AC-1 edited ebuild, no new ebuild" app-misc/foo app-misc/bar

newrepo; echo '# comment only' >>"$repo/$O/app-misc/foo/foo-1.ebuild"; change
expect_fail "R04-AC-1 comment-only ebuild edit is not exempt" app-misc/foo

newrepo; echo more >>"$repo/$O/app-misc/foo/files/a.patch"; change
expect_fail "R04-AC-1 edited file under files/" app-misc/foo

newrepo; echo new >"$repo/$O/app-misc/foo/files/new.patch"; change
expect_fail "R04-AC-1 added file under files/" app-misc/foo

newrepo; (cd "$repo" && g rm -q "$O/app-misc/foo/files/a.patch") >/dev/null 2>&1; change
expect_fail "R04-AC-1 removed patch under files/" app-misc/foo

newrepo; (cd "$repo" && g mv "$O/app-misc/bar/bar-1.ebuild" "$O/app-misc/bar/bar-1-r1.ebuild") >/dev/null 2>&1; change
expect_fail "R04-AC-1 renamed ebuild is not a new ebuild" app-misc/bar

newrepo; echo 'DIST x 2' >>"$repo/$O/app-misc/foo/Manifest"; change
expect_fail "R04-AC-1 Manifest-only change" app-misc/foo

newrepo; echo x >>"$repo/$O/app-misc/foo/foo-1.ebuild"; echo y >>"$repo/$O/app-misc/bar/bar-2.ebuild"
cp "$repo/$O/app-misc/bar/bar-2.ebuild" "$repo/$O/app-misc/bar/bar-2-r1.ebuild"; change
expect_fail "R04-AC-1 two packages, one bumped: names only the unbumped one" app-misc/foo app-misc/bar

# ---- R04-AC-2: a new ebuild passes; metadata.xml-only passes ----
newrepo; echo x >>"$repo/$O/app-misc/foo/foo-1.ebuild"; cp "$repo/$O/app-misc/foo/foo-1.ebuild" "$repo/$O/app-misc/foo/foo-1-r1.ebuild"; change
expect_pass "R04-AC-2 edited ebuild with an added -r1 ebuild"

newrepo; echo more >>"$repo/$O/app-misc/foo/files/a.patch"; printf 'EAPI=8\n' >"$repo/$O/app-misc/foo/foo-1-r1.ebuild"; change
expect_pass "R04-AC-2 files/ change with an added -r1 ebuild"

newrepo; echo more >>"$repo/$O/app-misc/foo/files/a.patch"; printf 'EAPI=8\n' >"$repo/$O/app-misc/foo/foo-2.ebuild"; change
expect_pass "R04-AC-2 files/ change with a new version"

newrepo; echo '<!-- c -->' >>"$repo/$O/app-misc/foo/metadata.xml"; change
expect_pass "R04-AC-2 metadata.xml-only change"

newrepo; echo 'DIST x 2' >>"$repo/$O/app-misc/foo/Manifest"; printf 'EAPI=8\n' >"$repo/$O/app-misc/foo/foo-1-r1.ebuild"; change
expect_pass "R04-AC-2 Manifest change together with a new ebuild"

newrepo; mkdir -p "$repo/$O/dev-libs/new/files"
printf 'EAPI=8\n' >"$repo/$O/dev-libs/new/new-1.ebuild"; echo p >"$repo/$O/dev-libs/new/files/p.patch"
echo '<pkgmetadata/>' >"$repo/$O/dev-libs/new/metadata.xml"; echo 'DIST n 1' >"$repo/$O/dev-libs/new/Manifest"; change
expect_pass "R04-AC-2 brand-new package"

newrepo; echo hi >"$repo/README"; mkdir -p "$repo/scripts"; echo x >"$repo/scripts/other.sh"; change
expect_pass "R04-AC-2 no overlay changes"

newrepo
expect_pass "R04-AC-2 empty range"

# ---- R04-AC-3: eclass change passes only when every inheritor gains a new ebuild ----
newrepo; echo '# changed' >>"$repo/$O/eclass/myecl.eclass"; change
expect_fail "R04-AC-3 eclass change, no inheritor bumped" app-misc/foo

newrepo; echo '# changed' >>"$repo/$O/eclass/myecl.eclass"; printf 'EAPI=8\ninherit myecl\n' >"$repo/$O/app-misc/foo/foo-1-r1.ebuild"; change
expect_fail "R04-AC-3 eclass change, one of two inheritors bumped: names the other" app-misc/bar app-misc/foo

newrepo; echo '# changed' >>"$repo/$O/eclass/myecl.eclass"
printf 'EAPI=8\ninherit myecl\n' >"$repo/$O/app-misc/foo/foo-1-r1.ebuild"
printf 'EAPI=8\ninherit myecl\n' >"$repo/$O/app-misc/bar/bar-1-r1.ebuild"; change
expect_pass "R04-AC-3 eclass change, every inheritor bumped"

newrepo; echo '# changed' >>"$repo/$O/eclass/unused.eclass"; change
expect_pass "R04-AC-3 eclass change with no inheritor"

# ---- R04-AC-4: make test-revbump on fixture commits, test includes it, workflow ----
mk4() { # mk4: fixture repo with Makefile, toolbox and the script; base revision tagged "base"
	n=$((n + 1)); repo=$tmp/m$n
	mkdir -p "$repo/scripts" "$repo/$O/app-misc/foo"
	(cd "$repo" && g init -q -b main .) >/dev/null 2>&1
	cp "$root/Makefile" "$repo/Makefile"
	cp -R "$root/toolbox" "$repo/toolbox"
	if [ -f "$script" ]; then cp "$script" "$repo/scripts/check-revbump.sh"; fi
	printf 'EAPI=8\n' >"$repo/$O/app-misc/foo/foo-1.ebuild"
	snap base base
}
runmake() { # runmake [make args...]; sets rc, out
	out=$(cd "$repo" && timeout 300 make "$@" 2>&1); rc=$?
}

mk4
echo x >>"$repo/$O/app-misc/foo/foo-1.ebuild"; printf '#!/bin/sh\nexit 0\n' >"$repo/scripts/check-revbump.sh"; change
runmake test-revbump BASE=base
case $out in *app-misc/foo*) named=1 ;; *) named=0 ;; esac
if [ $rc -ne 0 ] && [ $named -eq 1 ]; then pass "R04-AC-4 test-revbump judges by the base's script, not the PR's exit-0 copy"
else fail "R04-AC-4 test-revbump judges by the base's script, not the PR's exit-0 copy (rc=$rc: $out)"; fi

mk4
cp "$repo/$O/app-misc/foo/foo-1.ebuild" "$repo/$O/app-misc/foo/foo-1-r1.ebuild"; printf '#!/bin/sh\nexit 0\n' >"$repo/scripts/check-revbump.sh"; change
runmake test-revbump BASE=base
if [ $rc -eq 0 ]; then pass "R04-AC-4 test-revbump passes a bumped change"; else fail "R04-AC-4 test-revbump passes a bumped change (rc=$rc: $out)"; fi

# BASE defaults to the merge base with main
mk4
(cd "$repo" && g checkout -q -b feature) >/dev/null 2>&1
echo x >>"$repo/$O/app-misc/foo/foo-1.ebuild"; change
runmake test-revbump
if [ $rc -ne 0 ] && [ -f "$script" ]; then pass "R04-AC-4 BASE defaults to the merge base with main (unbumped change fails)"
else fail "R04-AC-4 BASE defaults to the merge base with main (unbumped change fails: rc=$rc: $out)"; fi
(cd "$repo" && g checkout -q main) >/dev/null 2>&1
echo y >"$repo/other"; snap mainmove
(cd "$repo" && g checkout -q feature) >/dev/null 2>&1
runmake test-revbump
if [ $rc -ne 0 ] && [ -f "$script" ]; then pass "R04-AC-4 default BASE is the merge base, not the tip of main"
else fail "R04-AC-4 default BASE is the merge base, not the tip of main (rc=$rc: $out)"; fi

# bootstrap: the base has no script; the working-tree copy is used
mk4
(cd "$repo" && g rm -q scripts/check-revbump.sh) >/dev/null 2>&1
snap noscript base2
if [ -f "$script" ]; then cp "$script" "$repo/scripts/check-revbump.sh"; fi
echo x >>"$repo/$O/app-misc/foo/foo-1.ebuild"; change
runmake test-revbump BASE=base2
if [ $rc -ne 0 ] && [ -f "$script" ]; then pass "R04-AC-4 bootstrap: no script at BASE, working-tree copy judges"
else fail "R04-AC-4 bootstrap: no script at BASE, working-tree copy judges (rc=$rc: $out)"; fi

# make test includes test-revbump
mk4
if (cd "$repo" && make -qp test 2>/dev/null) | grep -E '^test:' | grep -qw test-revbump; then
	pass "R04-AC-4 make test includes test-revbump"
else fail "R04-AC-4 make test includes test-revbump"; fi

# pr-validate.yml
wf=$root/.github/workflows/pr-validate.yml
if grep -Eq 'fetch-depth:[[:space:]]*0' "$wf"; then pass "R04-AC-4 pr-validate.yml checks out with fetch-depth: 0"
else fail "R04-AC-4 pr-validate.yml checks out with fetch-depth: 0"; fi
if grep -Eq 'run:[[:space:]]*make test-lint test-unit test-revbump[[:space:]]*$' "$wf"; then pass "R04-AC-4 pr-validate.yml runs make test-lint test-unit test-revbump"
else fail "R04-AC-4 pr-validate.yml runs make test-lint test-unit test-revbump"; fi
if grep -Eq 'BASE:[[:space:]]*\$\{\{[[:space:]]*github\.event\.pull_request\.base\.sha[[:space:]]*\}\}' "$wf"; then pass "R04-AC-4 pr-validate.yml maps BASE from the PR base sha via env"
else fail "R04-AC-4 pr-validate.yml maps BASE from the PR base sha via env"; fi
if grep -q 'check-revbump\.sh' "$wf"; then fail "R04-AC-4 pr-validate.yml does not run the script directly"
else pass "R04-AC-4 pr-validate.yml does not run the script directly"; fi

echo
if [ "$fails" -eq 0 ]; then echo "check-revbump: all passed"; else echo "check-revbump: $fails FAILED"; exit 1; fi
