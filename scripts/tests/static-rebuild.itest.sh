#!/bin/sh
# B01-AC-16 (change 13): a rebuilt static library rebuilds its cached consumers.
#
# An integration test: it runs real cross builds in the pinned builder image (podman or docker) on the
# pinned Gentoo tree, so it is not a unit test. Run it as `make test-static-rebuild`, or
# `sh scripts/tests/static-rebuild.itest.sh` on a host with the builder image and `make sync-portage` done.
#
# Four steps, each a fresh container (so the target root starts empty, as in each CI run); only a scratch
# PKGDIR carries over, as the GHCR cache does between runs. Each step runs scripts/build-packages.sh in
# development mode (MONOLITH_USEPKG=y) with CONFIGS_DIR (/configs in the container) a copy of configs/ whose
# world is monolith-test/usemarker, whose versions.lock locks both fixture packages and whose repos.conf adds
# the fixture overlay scripts/tests/fixtures/static-rebuild/.
#   1 cold: both packages are built from source.
#   2 control: both come from the cache (so the next steps test something).
#   3 libmarker -> -r1: both built from source; the installed usemarker carries LIBMARKER-1-r1, not LIBMARKER-1.
#   4 package.use "monolith-test/libmarker alt": both built from source; the binary carries the -alt string.
#
# Seam this test assumes in build-packages.sh: it copies ${CONFIGS_DIR}/portage/repos.conf/* into the
# sysroot's /etc/portage/repos.conf/ (as it already copies package.use and the other portage dirs), so that
# CONFIGS_DIR can add a repository.
#
# Environment: DOCKER (default: podman, else docker), TREE_DIR (default output/repos/gentoo), SCRIPTS_DIR
# (default scripts; the scripts mounted at /scripts), KEEP=1 keeps the scratch directory.
set -u

cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
FIX="$ROOT/scripts/tests/fixtures/static-rebuild"
SCRIPTS_DIR=${SCRIPTS_DIR:-$ROOT/scripts}
TREE_DIR=${TREE_DIR:-$ROOT/output/repos/gentoo}
fails=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
finish() {
	if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
	echo "$fails FAIL"
	exit 1
}

if [ -z "${DOCKER:-}" ]; then
	if command -v podman >/dev/null 2>&1; then DOCKER=podman
	elif command -v docker >/dev/null 2>&1; then DOCKER=docker
	else
		# Under `make test-unit` (toolbox, no container runtime) this integration test cannot run.
		echo "SKIP: no podman or docker; B01-AC-16 runs as make test-static-rebuild"
		exit 0
	fi
fi

digest=$(sed -n 's/^BUILDER_DIGEST := //p' Makefile)
registry=$(sed -n 's/^REGISTRY ?= //p' Makefile)
[ -n "$digest" ] && [ -n "$registry" ] || { fail "cannot read BUILDER_DIGEST and REGISTRY from the Makefile"; finish; }

# The pinned builder: the local image if it carries the pinned digest, else pulled by digest.
IMG=monolith-builder
if ! $DOCKER image inspect --format '{{.RepoDigests}}' "$IMG" 2>/dev/null | grep -q "$digest"; then
	IMG="$registry/builder@$digest"
	$DOCKER pull "$IMG" >/dev/null 2>&1 || { fail "B01-AC-16: the pinned builder $IMG is not available"; finish; }
fi
[ -d "$TREE_DIR/profiles" ] || { fail "B01-AC-16: no pinned tree in $TREE_DIR (make sync-portage)"; finish; }

S=$(mktemp -d "${TMPDIR:-/tmp}/static-rebuild.XXXXXX") || exit 1
[ -n "${KEEP:-}" ] || trap 'rm -rf "$S"' EXIT
echo "scratch: $S (builder $IMG, tree $TREE_DIR, runtime $DOCKER)"

# The configs copy: world, versions.lock, repos.conf and the overlay as the spec says.
CFG="$S/configs"
cp -r "$ROOT/configs" "$CFG"
cp -r "$FIX" "$CFG/static-rebuild-overlay"
echo 'monolith-test/usemarker' > "$CFG/portage/world"
printf 'monolith-test/libmarker:1:0\nmonolith-test/usemarker:1:0\n' > "$CFG/portage/versions.lock"
rm -rf "$CFG/portage/repos.conf"
mkdir -p "$CFG/portage/repos.conf"
printf '[static-rebuild]\nlocation = /configs/static-rebuild-overlay\npriority = 30\nmasters = gentoo\nauto-sync = no\n' \
	> "$CFG/portage/repos.conf/static-rebuild.conf"
mkdir -p "$S/pkgdir"

# run_step N: a fresh container; leaves $S/stepN/{build.out,emerge.log,usemarker}.
run_step() {
	n=$1
	d="$S/step$n"
	mkdir -p "$d/out"
	echo "==> step $n: running build-packages.sh in a fresh $IMG container"
	# The build exits non-zero after the emerge (no kernel in this world); the emerge log and the installed
	# binary are what is checked.
	$DOCKER run --rm \
		-v "$CFG:/configs" -v "$SCRIPTS_DIR:/scripts:ro" \
		-v "$d/out:/output" -v "$S/pkgdir:/output/packages" \
		-v "$TREE_DIR:/var/db/repos/gentoo" \
		-e JOBS="$(nproc)" -e LOAD_AVG="$(nproc)" -e MONOLITH_USEPKG=y \
		"$IMG" bash -c '/scripts/build-packages.sh; rc=$?; cp -L /usr/i486-linux-musl/usr/bin/usemarker /output/usemarker.bin 2>/dev/null; exit $rc' \
		> "$d/build.out" 2>&1
	echo "    build-packages.sh exit $? (see $d/build.out)"
	cp "$d/out/logs/emerge-parallel.log" "$d/emerge.log" 2>/dev/null || : > "$d/emerge.log"
	cp "$d/out/usemarker.bin" "$d/usemarker" 2>/dev/null || rm -f "$d/usemarker"
}

# how N PKG source|binary: the emerge log of step N has that package's merge line of that kind.
how() {
	case $3 in
	source) grep -Eq "^>>> Emerging \([0-9]+ of [0-9]+\) monolith-test/$2-" "$S/step$1/emerge.log" ;;
	binary) grep -Eq "^>>> Emerging binary \([0-9]+ of [0-9]+\) monolith-test/$2-" "$S/step$1/emerge.log" ;;
	esac
}

# both N source|binary LABEL
both() {
	ok=1
	for p in libmarker usemarker; do
		if how "$1" "$p" "$2"; then :; else ok=0; echo "    $p: no '>>> Emerging$([ "$2" = binary ] && echo ' binary') (' line in step $1's log"; fi
	done
	if [ "$ok" = 1 ]; then pass "B01-AC-16 step $1 ($3): both packages $2-merged"; else fail "B01-AC-16 step $1 ($3): both packages should be merged from $2"; grep -a '^>>> Emerging\|^ \* ERROR\|^ERROR\|not found\|No ebuilds' "$S/step$1/build.out" | head -n 8; fi
}

# marker N EXPECTED LABEL: every LIBMARKER-* string in the installed usemarker is EXPECTED.
marker() {
	if [ ! -f "$S/step$1/usemarker" ]; then
		fail "B01-AC-16 step $1 ($3): no installed usemarker binary"
		return
	fi
	got=$(grep -ao 'LIBMARKER-[0-9A-Za-z._-]*' "$S/step$1/usemarker" | sort -u | tr '\n' ' ')
	if [ "$got" = "$2 " ]; then pass "B01-AC-16 step $1 ($3): installed usemarker carries $2 and no other marker"
	else fail "B01-AC-16 step $1 ($3): installed usemarker carries '${got% }', want $2"; fi
}

# Step 1: cold.
run_step 1
both 1 source cold
marker 1 LIBMARKER-1 cold

# Step 2: control, nothing changed.
run_step 2
both 2 binary control

# Step 3: libmarker revbumped to -r1 (the lock follows).
mv "$CFG/static-rebuild-overlay/monolith-test/libmarker/libmarker-1.ebuild" \
	"$CFG/static-rebuild-overlay/monolith-test/libmarker/libmarker-1-r1.ebuild"
printf 'monolith-test/libmarker:1-r1:0\nmonolith-test/usemarker:1:0\n' > "$CFG/portage/versions.lock"
run_step 3
both 3 source "libmarker -r1"
marker 3 LIBMARKER-1-r1 "libmarker -r1"

# Step 4: package.use gains libmarker alt.
echo 'monolith-test/libmarker alt' > "$CFG/portage/package.use/static-rebuild"
run_step 4
both 4 source "package.use alt"
marker 4 LIBMARKER-1-r1-alt "package.use alt"

finish
