#!/bin/sh
# R05-AC-2 and the build half of R05-AC-4: rl144 and stele build from fetched distfiles alone, offline, in the builder.
#   1. the builder's std lock (library/Cargo.lock) equals scripts/fixtures/R05/library-Cargo.lock, so the CRATES lists
#      the fixture checks cover the std that the image will compile;
#   2. a container with network runs `emerge --fetchonly` of both -r2 atoms into a host DISTDIR, the only way files get there;
#   3. a second container with --network none and FETCHCOMMAND=RESUMECOMMAND=/bin/false emerges both from that DISTDIR,
#      through the cross wrapper with the build's mounts and make.conf. No binary package is used (no --usepkg/--getbinpkg),
#      so cargo compiles the project and std (-Z build-std) from the distfiles' vendor directory;
#   4. the binaries run: rl144 --render-frame (exit 0) and stele with no arguments (exit 0, "i486 binary live").
# Dependencies: neither ebuild declares any, and the rest of the world is binary packages in the normal build, so both are
# emerged with --nodeps: the job is about these two packages' own source fetch and build.
# Env: DOCKER (default docker; may be several words, e.g. podman --cgroup-manager=cgroupfs), BUILDER_REF (also $1; the builder image by digest), CONFIGS_DIR, TREE_DIR (the pinned
# tree), RUST_OFFLINE_DIR (state; DISTDIR is $RUST_OFFLINE_DIR/distfiles). Any failure exits non-zero.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd -P)
engine=${DOCKER:-docker}
BUILDER_REF=${1:-${BUILDER_REF:-}}
[ -n "$BUILDER_REF" ] || { echo "rust-offline: BUILDER_REF (or \$1) is the builder image by digest" >&2; exit 2; }
CONFIGS_DIR=${CONFIGS_DIR:-$PWD/configs}
TREE_DIR=${TREE_DIR:-$PWD/output/repos/gentoo}
STATE=${RUST_OFFLINE_DIR:-$PWD/output/rust-offline}
FIXTURE=$HERE/fixtures/R05/library-Cargo.lock
LIBLOCK=/opt/rustup/toolchains/nightly-2026-07-15-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library/Cargo.lock
ATOMS='=games-roguelike/rl144-0.1.0_p20260805-r2 =www-client/stele-0.1.0_p20260821-r2'
JOBS=${JOBS:-$(nproc)}
LOAD_AVG=${LOAD_AVG:-$JOBS}

case $CONFIGS_DIR in /*) ;; *) CONFIGS_DIR=$PWD/$CONFIGS_DIR ;; esac
case $TREE_DIR in /*) ;; *) TREE_DIR=$PWD/$TREE_DIR ;; esac
case $STATE in /*) ;; *) STATE=$PWD/$STATE ;; esac
DISTDIR=$STATE/distfiles
mkdir -p "$STATE"
rm -rf "$DISTDIR" "$STATE/output"
mkdir -p "$DISTDIR" "$STATE/output"
chmod 0777 "$DISTDIR" "$STATE/output"
# Run the engine from the state dir so podman's cgroupfs `oom` file does not land in the checkout (all paths are absolute).
cd "$STATE"

# The mounts of the package build (Makefile BUILD_MOUNTS): configs, the pinned tree, DISTDIR (/var/cache/distfiles),
# and /output (PKGDIR, from make.conf).
MOUNTS="-v $CONFIGS_DIR:/configs -v $TREE_DIR:/var/db/repos/gentoo -v $DISTDIR:/var/cache/distfiles -v $STATE/output:/output"

# What build-packages.sh does before it emerges: the cross wrapper reads the sysroot's /etc/portage, so the configs
# and the overlay registration go there.
PREP='set -eu
SYS=/usr/${CROSS_TARGET:-i486-linux-musl}
P=$SYS/etc/portage
mkdir -p $P/repos.conf
cp /configs/portage/make.conf /configs/portage/bashrc $P/
for d in package.use package.accept_keywords package.mask package.env env savedconfig profile; do
	if [ -d /configs/portage/$d ]; then mkdir -p $P/$d; cp -r /configs/portage/$d/. $P/$d/; fi
done
{ echo "[monolith]"; echo "location = /configs/overlay"; echo "priority = 20"; echo "masters = gentoo"; echo "auto-sync = no"; } > $P/repos.conf/monolith.conf
unset BUILD_DIR
'

echo "==> (d) the builder's library/Cargo.lock must equal the fixture"
$engine run --rm "$BUILDER_REF" cat "$LIBLOCK" >"$STATE/image-library-Cargo.lock"
if ! cmp "$STATE/image-library-Cargo.lock" "$FIXTURE"; then
	echo "rust-offline: the builder image's library/Cargo.lock differs from $FIXTURE; regenerate CRATES and the fixture" >&2
	exit 1
fi

echo "==> (a) fetch the distfiles of both packages, with network"
$engine run --rm $MOUNTS -e JOBS="$JOBS" -e LOAD_AVG="$LOAD_AVG" "$BUILDER_REF" sh -c "$PREP"'
${CROSS_TARGET:-i486-linux-musl}-emerge --fetchonly --oneshot --nodeps '"$ATOMS"
echo "    DISTDIR: $(find "$DISTDIR" -type f | wc -l) files"

echo "==> (b) build both offline from that DISTDIR"
$engine run --rm --network none $MOUNTS -e JOBS="$JOBS" -e LOAD_AVG="$LOAD_AVG" \
	-e FETCHCOMMAND=/bin/false -e RESUMECOMMAND=/bin/false "$BUILDER_REF" sh -c "$PREP"'
SYS=/usr/${CROSS_TARGET:-i486-linux-musl}
${CROSS_TARGET:-i486-linux-musl}-emerge --oneshot --nodeps --verbose '"$ATOMS"'
mkdir -p /output/target/usr/bin
cp $SYS/usr/bin/rl144 $SYS/usr/bin/stele /output/target/usr/bin/
chmod -R a+rX /output/target'

echo "==> (c) smoke runs of the installed binaries"
$engine run --rm --network none -v "$STATE/output/target:/tgt:ro" "$BUILDER_REF" \
	/tgt/usr/bin/rl144 --render-frame </dev/null >"$STATE/rl144-frame.txt"
$engine run --rm --network none -v "$STATE/output/target:/tgt:ro" "$BUILDER_REF" \
	/tgt/usr/bin/stele </dev/null >"$STATE/stele-hello.txt"
echo "    rl144 --render-frame: $(wc -c <"$STATE/rl144-frame.txt") bytes"
cat "$STATE/stele-hello.txt"
grep -q 'i486 binary live' "$STATE/stele-hello.txt" || { echo "rust-offline: stele printed no 'i486 binary live' line" >&2; exit 1; }
echo "rust-offline: both packages built offline and run"
