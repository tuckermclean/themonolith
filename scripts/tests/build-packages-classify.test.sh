#!/bin/sh
# B01 build-packages.sh policy, against the script with stub emerge, portageq, quickpkg, emaint, rsync.
#   B01-AC-3   with --usepkg on the emerge line has --binpkg-respect-use=y --binpkg-changed-deps=y
#              --rebuild-if-unbuilt; with MONOLITH_USEPKG=n it has no --usepkg
#   B01-AC-4   a stale gpkg + failing emerge => failed; installed at the locked version => built
#   B01-AC-7   source-only log check (fixture logs); a non-empty PKGDIR at start fails in release mode
#   B01-AC-10  release mode: no --usepkg, preinstalled target-VDB packages named cat/pn:slot with
#              --oneshot, quickpkg skipped, list printed; development mode as ported
#
# Interface under test (chosen for B01; defaults are the ported values, so builder behaviour is unchanged).
# Environment seams the script must add for the roots it writes (ruling 13):
#   SYSROOT    target root, default /usr/${CROSS_TARGET}   (sysroot config sync, accounts, VDB, quickpkg ROOT,
#                                                           portageq has_version root, rsync source, kernel)
#   HOST_ETC   host /etc, default /etc                      (host package.mask mirror, /etc/group)
#   plus the ported CONFIGS_DIR, OUTPUT_DIR (log dir, PKGDIR=$OUTPUT_DIR/packages, tracking files) and CROSS_TARGET.
# New argument:
#   build-packages.sh --check-source-log <logfile>
#       exit 0 iff the log has zero '>>> Emerging binary' lines and at least one '>>> Emerging (' line;
#       otherwise non-zero with the reason on stdout/stderr. Needs no toolchain, world file or roots.
# Release mode is MONOLITH_USEPKG=n (ported). The success branch is kept; on the failure branch a package
# is built iff `portageq has_version "$SYSROOT" =cat/pn-<locked version>` succeeds.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../build-packages.sh"
fails=0

fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }
# check <desc> <cmd...>: PASS when the command succeeds
check() { d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- stubs: each records its argv (one arg per line, "CALL" first) under $CALLS ---
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
for n in i486-linux-musl-emerge quickpkg emaint portageq i486-linux-musl-gcc; do
    cat > "$STUBS/$n" <<'STUB'
#!/bin/sh
n="$(basename "$0")"
{ echo CALL; printf '%s\n' "$@"; } >> "$CALLS/$n.argv"
case "$n" in
    i486-linux-musl-emerge)
        [ -n "${EMERGE_OUT:-}" ] && cat "$EMERGE_OUT"
        exit "${EMERGE_RC:-0}" ;;
    portageq)
        # has_version <root> <atom>: succeeds iff root is $SYSROOT and the atom is listed in $INSTALLED
        if [ "$1" = has_version ]; then
            [ "$2" = "$SYSROOT" ] || exit 1
            [ -f "${INSTALLED:-/nonexistent}" ] && grep -qxF -- "$3" "$INSTALLED"
            exit $?
        fi
        exit 1 ;;
esac
exit 0
STUB
    chmod +x "$STUBS/$n"
done
# rsync stub: copy source dir contents to the destination (last two args), ignoring options
cat > "$STUBS/rsync" <<'STUB'
#!/bin/sh
src=""; dst=""
for a in "$@"; do case "$a" in -*) ;; *) src="$dst"; dst="$a" ;; esac; done
mkdir -p "$dst"; cp -a "$src." "$dst" 2>/dev/null
exit 0
STUB
chmod +x "$STUBS/rsync"

NCASE=0
# newcase: fresh fixture roots; world = app-misc/hello locked at 1.0; resolved kernel config present
newcase() {
    NCASE=$((NCASE + 1))
    W="$TMP/case$NCASE"
    CFG="$W/configs"; OUT="$W/output"; SYS="$W/sysroot"; HETC="$W/hostetc"; CALLS="$W/calls"
    mkdir -p "$CFG/portage" "$OUT" "$SYS/etc/portage" "$HETC" "$CALLS" "$SYS/usr/share/monolith-kernel"
    : > "$HETC/group"
    printf 'app-misc/hello\n' > "$CFG/portage/world"
    printf 'app-misc/hello:1.0:0\n' > "$CFG/portage/versions.lock"
    echo 'CONFIG_I2C=n' | gzip -c > "$SYS/usr/share/monolith-kernel/resolved-kernel.config.gz"
    : > "$W/installed"
    BP_ARGS=""
}
# run_bp [VAR=val ...]: run the script in the fixture; $W/out.txt has its output, $RC its status
run_bp() {
    # shellcheck disable=SC2086
    env -u MONOLITH_USEPKG CONFIGS_DIR="$CFG" OUTPUT_DIR="$OUT" SYSROOT="$SYS" HOST_ETC="$HETC" \
        CALLS="$CALLS" INSTALLED="$W/installed" JOBS=2 LOAD_AVG=2 PATH="$STUBS:$PATH" "$@" \
        bash "$SCRIPT" $BP_ARGS > "$W/out.txt" 2>&1
    RC=$?
}
EARGV() { echo "$CALLS/i486-linux-musl-emerge.argv"; }
have_arg() { [ -f "$(EARGV)" ] && grep -qxF -- "$1" "$(EARGV)"; }
lacks_arg() { [ -f "$(EARGV)" ] && ! grep -qxF -- "$1" "$(EARGV)"; }
listed() { [ -f "$1" ] && grep -qxF -- "$2" "$1"; }
# nonzero/noemerge need the script to exist: a missing script is exit 127 and must not read as a rejection
nonzero() { [ -f "$SCRIPT" ] && [ "$RC" -ne 0 ] && [ "$RC" -ne 127 ]; }
noemerge() { [ -f "$SCRIPT" ] && [ ! -e "$(EARGV)" ]; }
rejects() { [ -f "$SCRIPT" ] || return 1; "$@"; r=$?; [ "$r" -ne 0 ] && [ "$r" -ne 127 ]; }
unlisted() { [ -f "$1" ] && ! grep -qxF -- "$2" "$1"; }

# ===== B01-AC-3: emerge flags =====
newcase
run_bp
for f in --binpkg-respect-use=y --binpkg-changed-deps=y --rebuild-if-unbuilt --usepkg --buildpkg --keep-going; do
    check "B01-AC-3: default build passes $f to emerge" have_arg "$f"
done
newcase
run_bp MONOLITH_USEPKG=n EMERGE_OUT="$TMP/src-ok.log"
check "B01-AC-3: MONOLITH_USEPKG=n still runs emerge" test -f "$(EARGV)"
check "B01-AC-3: MONOLITH_USEPKG=n has no --usepkg" lacks_arg --usepkg
check "B01-AC-3: MONOLITH_USEPKG=n keeps --buildpkg" have_arg --buildpkg

# ===== B01-AC-4: classification by installed set =====
newcase
printf 'app-misc/ok\napp-misc/hello\n' > "$CFG/portage/world"
printf 'app-misc/ok:2.0:0\napp-misc/hello:1.0:0\n' > "$CFG/portage/versions.lock"
mkdir -p "$OUT/packages/app-misc/hello" "$OUT/packages/app-misc/ok"
: > "$OUT/packages/app-misc/hello/hello-0.9-1.gpkg.tar"   # stale gpkg, another version
: > "$OUT/packages/app-misc/ok/ok-2.0-1.gpkg.tar"
printf '=app-misc/ok-2.0\n=app-misc/hello-0.9\n' > "$W/installed"   # hello installed, but not at the locked 1.0
run_bp EMERGE_RC=1
check "B01-AC-4: failing emerge, stale gpkg, not installed at lock => failed" listed "$OUT/.failed-packages" app-misc/hello
check "B01-AC-4: the stale gpkg does not make it built" unlisted "$OUT/.built-packages" app-misc/hello
check "B01-AC-4: installed at the locked version => built" listed "$OUT/.built-packages" app-misc/ok
check "B01-AC-4: the built package is not failed" unlisted "$OUT/.failed-packages" app-misc/ok
check "B01-AC-4: a failed package makes the script exit non-zero" nonzero
newcase
mkdir -p "$OUT/packages/app-misc/hello"
: > "$OUT/packages/app-misc/hello/hello-0.9-1.gpkg.tar"
printf '=app-misc/hello-1.0\n' > "$W/installed"
run_bp EMERGE_RC=1
check "B01-AC-4: stale gpkg + installed at the locked version => built" listed "$OUT/.built-packages" app-misc/hello
check "B01-AC-4: ... and not failed" unlisted "$OUT/.failed-packages" app-misc/hello
newcase
mkdir -p "$OUT/packages/app-misc/hello"
: > "$OUT/packages/app-misc/hello/hello-1.0-1.gpkg.tar"   # even a gpkg of the locked version
run_bp EMERGE_RC=1
check "B01-AC-4: a gpkg of the package alone never counts as built" listed "$OUT/.failed-packages" app-misc/hello
check "B01-AC-4: has_version was asked on the target root" \
    grep -qxF "$SYS" "$CALLS/portageq.argv"

# ===== B01-AC-7: source-only log check =====
GOOD="$TMP/src-ok.log"
printf '%s\n' '>>> Emerging (1 of 2) app-misc/hello-1.0::gentoo' '>>> Emerging (2 of 2) sys-libs/x-1' > "$GOOD"
BAD="$TMP/binary.log"
printf '%s\n' '>>> Emerging (1 of 2) app-misc/hello-1.0::gentoo' '>>> Emerging binary (2 of 2) sys-libs/x-1' > "$BAD"
NONE="$TMP/none.log"
printf '%s\n' 'Nothing to merge' > "$NONE"
chk_log() { env PATH="$STUBS:$PATH" bash "$SCRIPT" --check-source-log "$1" > "$TMP/chk.out" 2>&1; }
check "B01-AC-7: source-only log passes the check" chk_log "$GOOD"
check "B01-AC-7: a log with a binary merge fails the check" rejects chk_log "$BAD"
check "B01-AC-7: a log with no '>>> Emerging (' line fails the check" rejects chk_log "$NONE"
check "B01-AC-7: the check on a missing log fails" rejects chk_log "$TMP/nonexistent.log"
# the check is part of a release build
newcase
run_bp MONOLITH_USEPKG=n EMERGE_OUT="$GOOD"
check "B01-AC-7: release build with a source-only log exits 0" test "$RC" -eq 0
newcase
run_bp MONOLITH_USEPKG=n EMERGE_OUT="$BAD"
check "B01-AC-7: release build whose log has a binary merge exits non-zero" nonzero
newcase
mkdir -p "$OUT/packages/app-misc/hello"
: > "$OUT/packages/app-misc/hello/hello-1.0-1.gpkg.tar"
run_bp MONOLITH_USEPKG=n EMERGE_OUT="$GOOD"
check "B01-AC-7: release build with a non-empty PKGDIR exits non-zero" nonzero
check "B01-AC-7: ... and runs no emerge" noemerge
newcase
mkdir -p "$OUT/packages/app-misc/hello"
: > "$OUT/packages/app-misc/hello/hello-1.0-1.gpkg.tar"
run_bp
check "B01-AC-7: development build with a non-empty PKGDIR still builds" test -f "$(EARGV)"

# ===== B01-AC-10: release mode reuses nothing =====
vdb_fixture() {
    mkdir -p "$SYS/var/db/pkg/acct-user/portage-0" "$SYS/var/db/pkg/dev-lang/foo-2.1-r3"
    echo 0 > "$SYS/var/db/pkg/acct-user/portage-0/SLOT"
    echo 2 > "$SYS/var/db/pkg/dev-lang/foo-2.1-r3/SLOT"
}
newcase
vdb_fixture
run_bp MONOLITH_USEPKG=n EMERGE_OUT="$GOOD"
check "B01-AC-10: release mode runs emerge" test -f "$(EARGV)"
check "B01-AC-10: release emerge line has no --usepkg" lacks_arg --usepkg
check "B01-AC-10: release emerge line has --oneshot" have_arg --oneshot
check "B01-AC-10: release emerge line names acct-user/portage:0" have_arg acct-user/portage:0
check "B01-AC-10: release emerge line names dev-lang/foo:2" have_arg dev-lang/foo:2
check "B01-AC-10: release emerge line still names the world atom" have_arg =app-misc/hello-1.0
check "B01-AC-10: release mode skips quickpkg" sh -c '[ -f "$1" ] && [ ! -e "$2" ]' _ "$(EARGV)" "$CALLS/quickpkg.argv"
check "B01-AC-10: the preinstalled list is printed (portage)" grep -q 'acct-user/portage:0' "$W/out.txt"
check "B01-AC-10: the preinstalled list is printed (foo)" grep -q 'dev-lang/foo:2' "$W/out.txt"
newcase
run_bp MONOLITH_USEPKG=n EMERGE_OUT="$GOOD"
check "B01-AC-10: release mode with no target VDB runs emerge, world atom only" \
    sh -c '[ -f "$1" ] && ! grep -qxF -- --oneshot "$1"' _ "$(EARGV)"
newcase
vdb_fixture
run_bp
check "B01-AC-10: development mode keeps --usepkg" have_arg --usepkg
check "B01-AC-10: development mode does not name VDB packages" lacks_arg acct-user/portage:0
check "B01-AC-10: development mode has no --oneshot" lacks_arg --oneshot
check "B01-AC-10: development mode runs quickpkg as ported" test -f "$CALLS/quickpkg.argv"
check "B01-AC-10: quickpkg is called with --include-config=y" \
    sh -c '[ -f "$1" ] && grep -qxF -- --include-config=y "$1"' _ "$CALLS/quickpkg.argv"

if [ "$fails" -gt 0 ]; then
    echo "$fails check(s) FAILED"
    exit 1
fi
echo "ALL PASS"
