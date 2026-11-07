#!/bin/sh
# Asserts the kernel modules the tier docs promise were built and shipped in a sysroot.
# Usage: verify-kernel-modules.sh SYSROOT   (SYSROOT is the output/sysroot of a build)
#
# Covers the `=m` NIC and netfilter drivers (an ISA driver or nf_* module silently dropped by
# olddefconfig is caught here, not by boot tests) and the legacy fbdev drivers, which must
# also declare no firmware blob (the no-blob doctrine).
set -eu

SYSROOT="${1:?usage: verify-kernel-modules.sh SYSROOT}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SAVED="${REPO_ROOT}/configs/portage/savedconfig/sys-kernel/monolith-kernel"
LOCK="${REPO_ROOT}/configs/portage/versions.lock"

KVER=$(grep '^sys-kernel/monolith-kernel:' "$LOCK" | cut -d: -f2 | sed -E 's/-r[0-9]+$//')
LOCALVERSION=$(grep '^CONFIG_LOCALVERSION=' "$SAVED" | sed -E 's/^CONFIG_LOCALVERSION="(.*)"$/\1/')
MODDIR="${SYSROOT}/lib/modules/${KVER}${LOCALVERSION}"

if [ -z "$KVER" ]; then
    echo "::error::No sys-kernel/monolith-kernel version in ${LOCK}"
    exit 1
fi
if [ ! -d "$MODDIR" ]; then
    echo "::error::Module directory not found: $MODDIR"
    exit 1
fi
if ! command -v modinfo >/dev/null 2>&1; then
    echo "::error::modinfo not found (kmod is part of the toolbox)"
    exit 1
fi

# The `=m` NIC and netfilter symbols: the risky ISA drivers first, then the PCI zoo, then
# the netfilter/nftables modules.
NIC_MODULES="
ne wd smc-ultra lance 3c509
pcnet32 tulip via-rhine natsemi sis900
e1000 e1000e igb sky2 r8169 vmxnet3
nf_conntrack nf_nat nf_tables nft_ct nft_nat nft_masq nf_defrag_ipv4
"

# All 27 .ko names for the 24 Tier-2 fbdev symbols + 3 Geode drivers, resolved from the
# per-driver Makefiles at v6.12.80: matroxfb_base (not matroxfb), neofb (not neomagicfb),
# sstfb (for FB_VOODOO1).
FBDEV_MODULES="
cirrusfb pm2fb pm3fb cyber2000fb vga16fb hgafb
nvidiafb rivafb i740fb matroxfb_base radeonfb aty128fb atyfb
s3fb savagefb sisfb neofb kyrofb tdfxfb sstfb vt8623fb
tridentfb arkfb sm712fb lxfb gxfb gx1fb
"

count() { echo $#; }

# check_present LABEL MODULES: fails naming every missing module; sets FOUND to the paths.
check_present() {
    label="$1"
    mods="$2"
    missing=""
    FOUND=""
    for m in $mods; do
        path=$(find "$MODDIR" -name "${m}.ko*" -print -quit)
        if [ -z "$path" ]; then
            missing="${missing:+$missing }$m"
        else
            FOUND="${FOUND:+$FOUND
}$path"
        fi
    done
    if [ -n "$missing" ]; then
        echo "::error::Missing ${label} kernel modules under ${MODDIR}: ${missing}"
        exit 1
    fi
    echo "==> All $(count $mods) ${label} modules present under ${MODDIR}"
}

echo "==> Checking for NIC .ko modules under ${MODDIR}"
check_present "NIC" "$NIC_MODULES"

echo "==> Checking for legacy fbdev .ko modules under ${MODDIR}"
check_present "legacy fbdev" "$FBDEV_MODULES"

hits=""
fw_err=$(mktemp)
trap 'rm -f "$fw_err"' EXIT
for path in $FOUND; do
    if fw=$(modinfo -F firmware "$path" 2>"$fw_err"); then
        status=0
    else
        status=$?
    fi
    if [ "$status" -ne 0 ]; then
        echo "::error::modinfo failed on ${path} (exit ${status}): $(cat "$fw_err")"
        exit 1
    fi
    if [ -n "$fw" ]; then
        hits="${hits:+$hits; }$(basename "$path"): $fw"
    fi
done
if [ -n "$hits" ]; then
    echo "::error::Legacy fbdev modules declaring firmware (violates the no-blob doctrine): ${hits}"
    exit 1
fi
echo "==> No firmware requirements declared across $(count $FBDEV_MODULES) legacy fbdev modules"
