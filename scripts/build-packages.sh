#!/bin/bash
#
# build-packages.sh - Cross-compile packages from the world file
#
# Continues on failure, logging errors for later review.
# Supports --resume to skip already-built packages.

set -o pipefail

CROSS_TARGET="${CROSS_TARGET:-i486-linux-musl}"
# The target root and the build host's /etc, overridable so the script can be tested unprivileged.
SYSROOT_IS_SEAM="${SYSROOT:+1}"
SYSROOT="${SYSROOT:-/usr/${CROSS_TARGET}}"
HOST_ETC="${HOST_ETC:-/etc}"
CONFIGS_DIR="${CONFIGS_DIR:-/configs}"
PORTAGE_DIR="${CONFIGS_DIR}/portage"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# The run's start: a release's source audit takes only packages built at or after it.
RUN_START="$(date +%s)"

# Parallelism settings (can be overridden via environment)
# Exported so Portage can use ${JOBS} in make.conf MAKEOPTS
export JOBS="${JOBS:-$(nproc)}"
export LOAD_AVG="${LOAD_AVG:-$(nproc)}"

WORLD_FILE="${PORTAGE_DIR}/world"
VERSIONS_FILE="${PORTAGE_DIR}/versions.lock"
LOGS_DIR="${OUTPUT_DIR}/logs"
BINPKG_DIR="${OUTPUT_DIR}/packages"
FAILED_FILE="${OUTPUT_DIR}/.failed-packages"
BUILT_FILE="${OUTPUT_DIR}/.built-packages"

# A release (tag) build compiles everything from source: its emerge log must hold no
# ">>> Emerging binary" line and at least one ">>> Emerging (" line.
check_source_log() {
    local log="$1"
    if [ ! -f "${log}" ]; then
        echo "ERROR: emerge log not found: ${log}"
        return 1
    fi
    if grep -q '^>>> Emerging binary ' "${log}"; then
        echo "ERROR: ${log} has '>>> Emerging binary' lines; a source-only build merged a binary package:"
        grep '^>>> Emerging binary ' "${log}"
        return 1
    fi
    if ! grep -q '^>>> Emerging (' "${log}"; then
        echo "ERROR: ${log} has no '>>> Emerging (' line; nothing was built from source"
        return 1
    fi
    return 0
}

# Parse arguments
RESUME=0
VERBOSE=0
FETCHONLY=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --check-source-log)
            if [ $# -lt 2 ]; then
                echo "Usage: $0 --check-source-log <logfile>"
                exit 1
            fi
            check_source_log "$2"
            exit $?
            ;;
        --resume)
            RESUME=1
            shift
            ;;
        --verbose|-v)
            VERBOSE=1
            shift
            ;;
        --fetchonly)
            FETCHONLY=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--resume] [--verbose] [--fetchonly] | --check-source-log <logfile>"
            exit 1
            ;;
    esac
done

# Create directories
mkdir -p "${LOGS_DIR}" "${BINPKG_DIR}"

# A release build (MONOLITH_USEPKG=n) must start with an empty PKGDIR, so that nothing
# restored from a cache can enter it.
if [ "${MONOLITH_USEPKG:-y}" = "n" ] && [ -n "$(find "${BINPKG_DIR}" -type f -print -quit)" ]; then
    echo "ERROR: MONOLITH_USEPKG=n needs an empty ${BINPKG_DIR}, which holds:"
    find "${BINPKG_DIR}" -type f | head -n 10
    exit 1
fi

# Sync runtime-mounted configs into the sysroot's portage directory.
# The crossdev emerge wrapper reads from /usr/${CROSS_TARGET}/etc/portage/
# (via PORTAGE_CONFIGROOT), but the runtime -v mount only updates
# /configs/portage/. Without this sync, config changes made after
# 'make build-image' (or mounted at runtime) would be invisible to emerge.
SYSROOT_PORTAGE="${SYSROOT}/etc/portage"
if [ -d "${PORTAGE_DIR}" ] && [ -d "${SYSROOT_PORTAGE}" ]; then
    echo "==> Syncing configs from ${PORTAGE_DIR} to ${SYSROOT_PORTAGE}"
    cp "${PORTAGE_DIR}/make.conf" "${SYSROOT_PORTAGE}/make.conf" 2>/dev/null || true
    cp "${PORTAGE_DIR}/bashrc" "${SYSROOT_PORTAGE}/bashrc" 2>/dev/null || true
    for dir in package.use package.accept_keywords package.mask package.env env savedconfig profile; do
        if [ -d "${PORTAGE_DIR}/${dir}" ]; then
            mkdir -p "${SYSROOT_PORTAGE}/${dir}"
            cp -r "${PORTAGE_DIR}/${dir}"/* "${SYSROOT_PORTAGE}/${dir}/" 2>/dev/null || true
        fi
    done
    # Register the monolith overlay in the sysroot repos.conf so cross-emerge
    # can find ebuilds from /configs/overlay (bind-mounted at runtime).
    mkdir -p "${SYSROOT_PORTAGE}/repos.conf"
    printf '[monolith]\nlocation = /configs/overlay\npriority = 20\nmasters = gentoo\nauto-sync = no\n' \
        > "${SYSROOT_PORTAGE}/repos.conf/monolith.conf"
    # Repositories the config tree declares (the test seam's fixture overlay).
    if compgen -G "${CONFIGS_DIR}/portage/repos.conf/*" >/dev/null; then
        cp "${CONFIGS_DIR}"/portage/repos.conf/* "${SYSROOT_PORTAGE}/repos.conf/"
    fi

    # ALSO mirror package.mask onto the BUILD HOST's /etc/portage. Cross-emerge
    # resolves TARGET packages against the sysroot config above, but a package's
    # BDEPEND (host build tools — docutils/rst2man for glib's man pages, cmake,
    # etc.) is resolved for BROOT=/ against the HOST config. A mask that lives
    # only in the sysroot is invisible to that half of the graph, so a broken or
    # drifting host build-dep (e.g. the live dev-cpp/eigen-9999 pulled via
    # glib->docutils->pillow->pybind11, or docutils>=0.23's hard pillow dep) can
    # never be masked away — the symptom that turned full builds red even after
    # the tree was pinned. package.mask is purely SUBTRACTIVE, and everything we
    # mask (man-db, mc, nmap, fortune, nethack, eigen-9999, docutils>=0.23) is a
    # target package or a broken host tool we explicitly do not want built, so
    # applying the same masks host-side is safe. We sync ONLY package.mask —
    # never package.use/accept_keywords — so we can't accidentally enable or
    # reconfigure a host tool, only forbid versions.
    if [ -d "${PORTAGE_DIR}/package.mask" ]; then
        echo "==> Mirroring package.mask to the build host /etc/portage (host BDEPEND resolution)"
        mkdir -p "${HOST_ETC}/portage/package.mask"
        cp -r "${PORTAGE_DIR}/package.mask"/* "${HOST_ETC}/portage/package.mask/" 2>/dev/null || true
    fi
fi

# Ensure groups required by game package preinst phases exist on the BUILD HOST.
# The nethack ebuild calls fowners root:gamestat, which runs chown on the host
# during preinst — it needs the group in the host /etc/group, not the sysroot.
grep -q "^games:"    "${HOST_ETC}/group" || echo "games:x:35:"    >> "${HOST_ETC}/group"
grep -q "^gamestat:" "${HOST_ETC}/group" || echo "gamestat:x:36:" >> "${HOST_ETC}/group"

# Seed baseline accounts/groups in the TARGET SYSROOT so package install phases
# that call `fowners` can resolve the ids there (ROOT=${SYSROOT}). The
# crossdev sysroot is minimal and lacks even root in /etc/passwd until baselayout
# / acct-* build, so early installs die with "invalid user/group ... root:portage".
# Observed needs: root:portage (eselect/vim/lua), root:gamestat (bsd-games).
# portage id is 250 (Gentoo standard); grep guards keep this idempotent and
# non-destructive if baselayout later provides the real entries.
# These seeded files are build scaffolding: build-rootfs.sh overwrites /etc/passwd and /etc/group in
# full, and the sysroot export below leaves them out.
SYSROOT_ETC="${SYSROOT}/etc"
mkdir -p "${SYSROOT_ETC}"
touch "${SYSROOT_ETC}/group" "${SYSROOT_ETC}/passwd"
sysroot_group() { grep -q "^$1:" "${SYSROOT_ETC}/group"  || echo "$2" >> "${SYSROOT_ETC}/group";  }
sysroot_user()  { grep -q "^$1:" "${SYSROOT_ETC}/passwd" || echo "$2" >> "${SYSROOT_ETC}/passwd"; }
sysroot_group root     "root:x:0:"
sysroot_group portage  "portage:x:250:portage"
sysroot_group games    "games:x:35:"
sysroot_group gamestat "gamestat:x:36:"
sysroot_user  root     "root:x:0:0:root:/root:/bin/sh"
sysroot_user  portage  "portage:x:250:250:portage:/var/tmp/portage:/sbin/nologin"

# Regenerate binpkg index so it matches whatever .gpkg.tar files actually
# exist on disk. Prevents "non-existent binary" errors after partial cleanup.
echo "==> Regenerating binpkg index"
PKGDIR="${BINPKG_DIR}" emaint binhost --fix

# Initialize tracking files
if [ $RESUME -eq 0 ]; then
    > "${FAILED_FILE}"
    > "${BUILT_FILE}"
fi

echo "==> Building packages for ${CROSS_TARGET}"
echo "    World file: ${WORLD_FILE}"
echo "    Logs: ${LOGS_DIR}"
echo "    Parallel jobs: ${JOBS}"
echo "    Load average limit: ${LOAD_AVG}"
echo "    Resume mode: $([ $RESUME -eq 1 ] && echo 'yes' || echo 'no')"
echo ""

# Verify toolchain exists
if ! command -v "${CROSS_TARGET}-gcc" &>/dev/null; then
    echo "ERROR: Toolchain not found. Rebuild the image with 'make build-image'."
    exit 1
fi

# Read packages from world file
if [ ! -f "${WORLD_FILE}" ]; then
    echo "ERROR: World file not found: ${WORLD_FILE}"
    exit 1
fi

# Parse world file, skip comments and blank lines
mapfile -t PACKAGES < <(grep -v '^#' "${WORLD_FILE}" | grep -v '^$')

if [ ${#PACKAGES[@]} -eq 0 ]; then
    echo "WARNING: No packages in world file"
    exit 0
fi

echo "==> Found ${#PACKAGES[@]} packages to build"

# category/package of a world atom: without operator, version, :slot or ::repo
# (<sys-fs/ncdu-2, net-misc/iperf:3 and =games-roguelike/nethack-3.6.7-r1 are world atoms).
atom_key() {
    echo "$1" | sed -e 's/::.*$//' -e 's/:.*$//' \
        -e '/^[<>=~!]/{s/^[<>=~!]*//;s/-[0-9][^/]*$//;}' -e 's/\*$//'
}

# Function to get pinned version for a package
get_pinned_version() {
    local key
    key=$(atom_key "$1")
    if [ -f "${VERSIONS_FILE}" ]; then
        # Format: category/package:version:slot
        grep "^${key}:" "${VERSIONS_FILE}" 2>/dev/null | cut -d: -f2 | head -1
    fi
}

# Function to check if package was already built
is_built() {
    local pkg="$1"
    if [ $RESUME -eq 1 ] && [ -f "${BUILT_FILE}" ]; then
        grep -q "^${pkg}$" "${BUILT_FILE}" 2>/dev/null
        return $?
    fi
    return 1
}

# Every world atom must be locked: an unlocked one would build whatever is newest.
UNLOCKED=0
for pkg in "${PACKAGES[@]}"; do
    if [ -z "$(get_pinned_version "${pkg}")" ]; then
        echo "ERROR: ${pkg} has no line in ${VERSIONS_FILE} (run: make update-versions)"
        ((UNLOCKED++))
    fi
done
if [ ${UNLOCKED} -gt 0 ]; then
    echo "ERROR: ${UNLOCKED} world atom(s) are not locked; nothing was built"
    exit 1
fi

# Build atoms list, respecting version pins and resume mode
ATOMS=()
SKIP_COUNT=0

for pkg in "${PACKAGES[@]}"; do
    # Skip if already built in resume mode
    if is_built "${pkg}"; then
        echo "[SKIP] ${pkg} (already built)"
        ((SKIP_COUNT++))
        continue
    fi

    # Get pinned version if available
    VERSION=$(get_pinned_version "${pkg}")
    ATOMS+=("=$(atom_key "${pkg}")-${VERSION}")
    echo "[QUEUE] ${pkg} (pinned: ${VERSION})"
done

# Exit early if nothing to build
if [ ${#ATOMS[@]} -eq 0 ]; then
    echo ""
    echo "==> Nothing to build (all packages skipped)"
    exit 0
fi

echo ""
echo "==> Building ${#ATOMS[@]} packages with ${JOBS} parallel jobs"

# Uses the cross-emerge wrapper created by crossdev
EMERGE_CMD="${CROSS_TARGET}-emerge"

# Release / clean-room builds compile EVERY package from source: set
# MONOLITH_USEPKG=n to drop --usepkg, so no cached binary package can enter the
# ISO artifact you're about to sign and publish (still --buildpkg, so PKGDIR is
# populated for extract-packages.sh). Default 'y' reuses the binpkg cache on
# iteration builds for speed. The release workflow (tag builds) sets it to n and
# also skips the GHCR cache pull.
# With --usepkg on, the binary package flags go with it: respect USE, rebuild on changed
# dependencies, and rebuild a consumer whose dependency was rebuilt.
# --with-bdeps=y: a DEPEND-only static library must enter a binary consumer's graph so that --rebuild-if-unbuilt can see it.
USEPKG_FLAGS=(--usepkg --binpkg-respect-use=y --binpkg-changed-deps=y --rebuild-if-unbuilt --with-bdeps=y)
RELEASE=0
PREINSTALLED=()
EXTRA_FLAGS=()
if [ "${MONOLITH_USEPKG:-y}" = "n" ]; then
    RELEASE=1
    USEPKG_FLAGS=()
    echo "==> MONOLITH_USEPKG=n: building ALL packages FROM SOURCE (binpkg cache NOT used)"

    # Packages already installed in the target root would be skipped, not rebuilt, and then
    # shipped. Name each one (cat/pn:slot) so Portage merges it again in this run; --oneshot
    # keeps these dependency atoms out of the sysroot's world file, and with them the world
    # atoms of this command line (nothing reads that file).
    for vdb in "${SYSROOT}"/var/db/pkg/*/*/; do
        [ -f "${vdb}SLOT" ] || continue
        pf=$(basename "${vdb}")
        cat=$(basename "$(dirname "${vdb}")")
        pn=$(echo "${pf}" | sed -E 's/-[0-9][0-9.]*[a-z]?(_(alpha|beta|pre|rc|p)[0-9]*)*(-r[0-9]+)?$//')
        slot=$(cut -d/ -f1 "${vdb}SLOT")
        PREINSTALLED+=("${cat}/${pn}:${slot}")
    done
    echo "==> Packages preinstalled in ${SYSROOT}, rebuilt in this run: ${#PREINSTALLED[@]}"
    for p in "${PREINSTALLED[@]}"; do
        echo "    ${p}"
    done
    if [ ${#PREINSTALLED[@]} -gt 0 ]; then
        ATOMS+=("${PREINSTALLED[@]}")
        EXTRA_FLAGS=(--oneshot)
    fi
fi

# Combined log for the parallel build
LOGFILE="${LOGS_DIR}/emerge-parallel.log"

# --fetchonly: download the distfiles of the same dependency graph and build nothing (the reproducibility
# gate's fetch job; the offline builds then run with fetching disabled).
if [ ${FETCHONLY} -eq 1 ]; then
    echo "==> Fetching the distfiles of ${#ATOMS[@]} atoms"
    unset BUILD_DIR
    # A live (9999) ebuild has no distfile: the fetch would archive nothing for it and the offline build would fail.
    # Resolve the graph first (the same atoms and flags, host and target side) and stop on any live package.
    PRETEND_OUT="${LOGS_DIR}/emerge-pretend.txt"
    if ! ${EMERGE_CMD} --pretend --color=n "${USEPKG_FLAGS[@]}" "${EXTRA_FLAGS[@]}" "${ATOMS[@]}" > "${PRETEND_OUT}" 2>&1; then
        cat "${PRETEND_OUT}"
        echo "ERROR: the dependency resolution failed"
        exit 1
    fi
    cat "${PRETEND_OUT}"
    sh "${SCRIPTS_DIR}/check-no-live.sh" "${PRETEND_OUT}" || exit 1
    exec ${EMERGE_CMD} --fetchonly "${USEPKG_FLAGS[@]}" "${EXTRA_FLAGS[@]}" "${ATOMS[@]}"
fi

if [ $VERBOSE -eq 1 ]; then
    echo "  Running: ${EMERGE_CMD} --jobs=${JOBS} --load-average=${LOAD_AVG} --keep-going --buildpkg ${USEPKG_FLAGS[*]} ${EXTRA_FLAGS[*]} ${ATOMS[*]}"
fi

# Build all packages in one emerge call with parallel jobs
# --jobs: build N packages in parallel (Portage handles dependency ordering)
# --load-average: cap system load to prevent oversubscription
# --keep-going: continue building other packages when one fails
# Unset BUILD_DIR: Portage's multilib-minimal.eclass uses it internally to
# construct per-ABI build paths. If set (e.g. from Dockerfile ENV), it creates
# invalid paths like /build-abi_x86_64.amd64 that the sandbox blocks.
unset BUILD_DIR
if ${EMERGE_CMD} \
    --jobs=${JOBS} \
    --load-average=${LOAD_AVG} \
    --keep-going \
    --buildpkg \
    "${USEPKG_FLAGS[@]}" \
    "${EXTRA_FLAGS[@]}" \
    --verbose \
    "${ATOMS[@]}" \
    2>&1 | tee "${LOGFILE}"; then

    # All packages succeeded
    SUCCESS_COUNT=${#ATOMS[@]}
    FAIL_COUNT=0
    for pkg in "${PACKAGES[@]}"; do
        if ! is_built "${pkg}"; then
            echo "${pkg}" >> "${BUILT_FILE}"
        fi
    done
else
    # Some packages may have failed; parse the log to determine which
    # Portage logs failures with "emerge: there are remaining packages"
    # and lists failed packages. We'll mark all as potentially failed
    # and let the user check the log.
    echo ""
    echo "==> Some packages failed to build"

    # Save individual build logs for failed packages before they disappear
    # with the ephemeral container. Portage stores them at:
    #   /var/tmp/portage/category/name-version/temp/build.log
    echo "==> Saving failed package build logs to ${LOGS_DIR}/"
    for build_log in /var/tmp/portage/*/*/temp/build.log; do
        [ -f "${build_log}" ] || continue
        # Extract category/name-version from path
        pkg_ver=$(echo "${build_log}" | sed 's|/var/tmp/portage/\(.*\)/temp/build.log|\1|')
        pkg_slug=$(echo "${pkg_ver}" | tr '/' '_')
        cp "${build_log}" "${LOGS_DIR}/${pkg_slug}.build.log" 2>/dev/null && \
            chmod 644 "${LOGS_DIR}/${pkg_slug}.build.log" 2>/dev/null || true
    done

    # Count successes and failures from emerge output
    # Portage shows ">>> Emerging (N of M)" for each package
    SUCCESS_COUNT=0
    FAIL_COUNT=0

    # Check each package for a successful binpkg
    for pkg in "${PACKAGES[@]}"; do
        if is_built "${pkg}"; then
            continue
        fi

        # Built means installed in the target root at the locked version; a gpkg on disk
        # (of any version, or restored from the cache) proves nothing.
        if PORTAGE_CONFIGROOT="${SYSROOT}" portageq has_version "${SYSROOT}" "=$(atom_key "${pkg}")-$(get_pinned_version "${pkg}")"; then
            echo "${pkg}" >> "${BUILT_FILE}"
            ((SUCCESS_COUNT++))
        else
            echo "${pkg}" >> "${FAILED_FILE}"
            ((FAIL_COUNT++))
        fi
    done
fi

# A release build must have compiled everything: no binary merge in its log.
if [ ${RELEASE} -eq 1 ] && ! check_source_log "${LOGFILE}"; then
    echo "ERROR: the release build did not compile every package from source"
    exit 1
fi

echo ""
echo "==> Build complete"
echo "    Success: ${SUCCESS_COUNT}"
echo "    Failed: ${FAIL_COUNT}"
echo "    Skipped: ${SKIP_COUNT}"

if [ ${FAIL_COUNT} -gt 0 ]; then
    echo ""
    echo "==> Failed packages:"
    cat "${FAILED_FILE}"
    echo ""
    echo "    Check logs in: ${LOGS_DIR}/"
fi

# Create binpkgs for any installed sysroot packages that emerge skipped because
# they were already present (e.g. acct-user/* installed by crossdev setup).
# quickpkg tarballs installed files without recompiling — fast and idempotent.
# A release build reuses nothing: it does not repackage what it did not build.
if [ ${RELEASE} -eq 1 ]; then
    echo "==> MONOLITH_USEPKG=n: not creating binpkgs for pre-installed sysroot packages"
else
    echo "==> Creating binpkgs for pre-installed sysroot packages"
    ROOT="${SYSROOT}" PKGDIR="${BINPKG_DIR}" quickpkg --include-config=y "*/*" 2>/dev/null || true
fi
PKGDIR="${BINPKG_DIR}" emaint binhost --fix

# Copy kernel image to OUTPUT_DIR so it escapes the container.
# monolith-kernel installs vmlinuz-${PV} + vmlinuz symlink to /boot in the sysroot.
KERNEL_STAGED="${SYSROOT}/boot/vmlinuz"
if [ -f "${KERNEL_STAGED}" ] || [ -L "${KERNEL_STAGED}" ]; then
    echo "==> Copying kernel image to ${OUTPUT_DIR}/vmlinuz"
    cp -L "${KERNEL_STAGED}" "${OUTPUT_DIR}/vmlinuz"
    # Log the bzImage size. The kernel-module regime's "refund" is a smaller
    # monolith as drivers move to loadable .ko; this makes the delta visible in
    # every build log (compare across builds) instead of only via S3.
    echo "==> bzImage size: $(du -h "${OUTPUT_DIR}/vmlinuz" | cut -f1) ($(stat -c%s "${OUTPUT_DIR}/vmlinuz") bytes)"
else
    echo "WARNING: Kernel image not found at ${KERNEL_STAGED} — vmlinuz will not be saved"
fi

# Export the live sysroot to output/sysroot/ while packages are already installed.
# This avoids a second emerge --usepkgonly pass in extract-packages.sh.
SYSROOT_DIR="${OUTPUT_DIR}/sysroot"
echo "==> Populating ${SYSROOT_DIR} from live sysroot"
rm -rf "${SYSROOT_DIR}"
mkdir -p "${SYSROOT_DIR}"
# Exclude crossdev build infrastructure — these are toolchain inputs, not runtime content:
#   usr/include/         kernel UAPI + musl + package dev headers (linux-headers, musl crossdev pkgs)
#   usr/i486-linux-musl/ nested crossdev sysroot created by some packages (e.g. binutils)
#   usr/bin/i486-linux-musl-* crossdev wrapper symlinks (binutils-config eselect, not runtime tools)
#   etc/portage/         portage build config synced into crossdev sysroot by build-packages.sh
#   etc/passwd, etc/group  seeded accounts for the install phases; build-rootfs.sh writes both in full
#   usr/lib/pkgconfig/   .pc files — needed to compile against libs, not to run them
#   usr/lib/lib{c,m,pthread,dl,rt,resolv,util,xnet,crypt}.a  musl static stubs
#   usr/lib/{crt1,Scrt1,rcrt1,crti,crtn}.o  musl CRT startup objects
#   lib/libssp_nonshared.a  GCC stack-smashing protection static lib (crossdev GCC artifact)
rsync -a \
    --exclude='/usr/include/' \
    --exclude='/usr/i486-linux-musl/' \
    --exclude='/usr/bin/i486-linux-musl-*' \
    --exclude='/etc/portage/' \
    --exclude='/etc/passwd' \
    --exclude='/etc/group' \
    --exclude='/usr/lib/pkgconfig/' \
    --exclude='/usr/lib/libc.a' \
    --exclude='/usr/lib/libm.a' \
    --exclude='/usr/lib/libpthread.a' \
    --exclude='/usr/lib/libdl.a' \
    --exclude='/usr/lib/librt.a' \
    --exclude='/usr/lib/libresolv.a' \
    --exclude='/usr/lib/libutil.a' \
    --exclude='/usr/lib/libxnet.a' \
    --exclude='/usr/lib/libcrypt.a' \
    --exclude='/usr/lib/crt1.o' \
    --exclude='/usr/lib/Scrt1.o' \
    --exclude='/usr/lib/rcrt1.o' \
    --exclude='/usr/lib/crti.o' \
    --exclude='/usr/lib/crtn.o' \
    --exclude='/lib/libssp_nonshared.a' \
    "${SYSROOT}/" "${SYSROOT_DIR}/"

# Fix the musl dynamic linker. The crossdev sysroot installs it as a symlink
# pointing to an absolute crossdev path (/usr/i486-linux-musl/usr/lib/libc.so)
# which is dangling on the live system. Replace with the actual binary.
echo "==> Installing musl dynamic linker..."
MUSL_LIBC="${SYSROOT}/usr/lib/libc.so"
if [ -f "${MUSL_LIBC}" ]; then
    rm -f "${SYSROOT_DIR}/lib/ld-musl-i386.so.1"
    cp "${MUSL_LIBC}" "${SYSROOT_DIR}/lib/ld-musl-i386.so.1"
else
    echo "WARNING: musl libc not found at ${MUSL_LIBC}"
    echo "  Dynamically-linked binaries will fail to execute at runtime!"
fi

# Decompress bzip2-compressed man pages.
# Gentoo installs man pages as .bz2; mandoc is built without libbz2 support.
echo "==> Decompressing bzip2 man pages..."
find "${SYSROOT_DIR}/usr/share/man" -name "*.bz2" -print0 2>/dev/null | \
    xargs -0 -r bunzip2 2>/dev/null || true

# Release: every file shipped must come from a package merged from source in this run.
BOOTSTRAP_EXCEPTIONS="${CONFIGS_DIR}/attestation/bootstrap-exceptions.txt"
if [ "${RELEASE}" -eq 1 ] && [ ! -f "${BOOTSTRAP_EXCEPTIONS}" ]; then
    if [ -n "${SYSROOT_IS_SEAM}" ]; then
        # SYSROOT set by the caller is the test seam, whose CONFIGS_DIR is a fixture without this file.
        echo "::warning::Source audit NOT run: ${BOOTSTRAP_EXCEPTIONS} not found (test seam SYSROOT)"
    else
        echo "::error::Source audit cannot run: ${BOOTSTRAP_EXCEPTIONS} not found"
        exit 1
    fi
elif [ "${RELEASE}" -eq 1 ]; then
    echo "==> Source audit of ${SYSROOT_DIR}"
    if ! sh "${SCRIPTS_DIR}/source-audit.sh" \
            --sysroot "${SYSROOT_DIR}" \
            --vdb "${SYSROOT}/var/db/pkg" \
            --log "${LOGFILE}" \
            --start "${RUN_START}" \
            --exceptions "${BOOTSTRAP_EXCEPTIONS}" \
            --output "${OUTPUT_DIR}/source-audit.tsv"; then
        echo "::error::Source audit failed: the sysroot holds files not built from source in this run"
        exit 1
    fi
else
    echo "==> Source audit skipped: development mode (MONOLITH_USEPKG=y) ships cached packages by design"
fi

TOTAL_SIZE=$(du -sh "${SYSROOT_DIR}" | cut -f1)
TOTAL_FILES=$(find "${SYSROOT_DIR}" -type f | wc -l)
echo "==> Sysroot: ${TOTAL_SIZE} across ${TOTAL_FILES} files → ${SYSROOT_DIR}"

# Export the resolved (post-olddefconfig) kernel config that scripts/verify-
# resolved-i2c-off.sh asserts against (DCX-99). The config rides as
# *package content* (/usr/share/monolith-kernel/resolved-kernel.config.gz,
# installed by the monolith-kernel ebuild's src_install), so it is populated
# identically whether monolith-kernel was built from source this run or
# restored from the binpkg cache. Re-deriving ${OUTPUT_DIR}/kernel.resolved.config
# from the package artifact here, unconditionally and on every run, is what makes
# the downstream assertion real on both the source and binpkg paths instead of
# vacuously re-checking a stale file. Nothing under ${CONFIGS_DIR} is written:
# the kernel savedconfig is an input, never an output.
KERNEL_BUILD_MODE="unknown"
if grep -qE '^>>> Emerging binary \([0-9]+ of [0-9]+\) sys-kernel/monolith-kernel-' "${LOGFILE}"; then
    KERNEL_BUILD_MODE="binpkg"
elif grep -qE '^>>> Emerging \([0-9]+ of [0-9]+\) sys-kernel/monolith-kernel-' "${LOGFILE}"; then
    KERNEL_BUILD_MODE="source"
fi
echo "==> monolith-kernel build mode this run: ${KERNEL_BUILD_MODE}"
if [ "${KERNEL_BUILD_MODE}" = "unknown" ]; then
    echo "::warning::Could not classify monolith-kernel build mode from ${LOGFILE} (no '>>> Emerging ... sys-kernel/monolith-kernel-' line found)"
fi

RESOLVED_KERNEL_CONFIG_GZ="${SYSROOT_DIR}/usr/share/monolith-kernel/resolved-kernel.config.gz"
if [ ! -f "${RESOLVED_KERNEL_CONFIG_GZ}" ]; then
    echo "::error::Resolved kernel config artifact missing at ${RESOLVED_KERNEL_CONFIG_GZ} (build mode: ${KERNEL_BUILD_MODE}) — scripts/verify-resolved-i2c-off.sh cannot prove the CONFIG_I2C invariant this run"
    exit 1
fi
RESOLVED_KERNEL_CONFIG="${OUTPUT_DIR}/kernel.resolved.config"
echo "==> Exporting resolved kernel config to ${RESOLVED_KERNEL_CONFIG} (build mode: ${KERNEL_BUILD_MODE})"
if ! gunzip -c "${RESOLVED_KERNEL_CONFIG_GZ}" > "${RESOLVED_KERNEL_CONFIG}"; then
    echo "::error::Failed to export resolved kernel config from ${RESOLVED_KERNEL_CONFIG_GZ} to ${RESOLVED_KERNEL_CONFIG}"
    exit 1
fi
if ! sh "${SCRIPTS_DIR}/verify-resolved-i2c-off.sh" "${RESOLVED_KERNEL_CONFIG}" "${KERNEL_BUILD_MODE}"; then
    echo "::error::Resolved kernel config failed the CONFIG_I2C check (build mode: ${KERNEL_BUILD_MODE})"
    exit 1
fi

# Exit with error if any packages failed
[ ${FAIL_COUNT} -eq 0 ]
