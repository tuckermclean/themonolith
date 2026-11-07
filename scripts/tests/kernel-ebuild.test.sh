#!/bin/sh
# Unit tests for the kernel config flow (B02): r9 ebuild (AC-1), menuconfig-kernel
# target (AC-4), scripts/verify-kernel-modules.sh fixture (AC-8), no tracked file
# naming the old kernel config path (AC-9). Every missing subject is a FAIL.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
cd "$REPO_ROOT" || exit 1
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }

EBUILD=configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-6.12.80-r9.ebuild
SAVED=configs/portage/savedconfig/sys-kernel/monolith-kernel

# --- B02-AC-1: r9 ebuild uses savedconfig, no allnoconfig, no CONFIGS_DIR ---
if [ ! -f "$EBUILD" ]; then
    fail "B02-AC-1 $EBUILD not found"
else
    if grep -Eq '^[[:space:]]*inherit[[:space:]].*\bsavedconfig\b' "$EBUILD"; then
        pass "B02-AC-1 ebuild inherits savedconfig"
    else
        fail "B02-AC-1 ebuild does not inherit savedconfig"
    fi
    if grep -Eq '^[[:space:]]*restore_config\b' "$EBUILD"; then
        pass "B02-AC-1 ebuild calls restore_config"
    else
        fail "B02-AC-1 ebuild does not call restore_config"
    fi
    if grep -q 'allnoconfig' "$EBUILD"; then
        fail "B02-AC-1 ebuild contains allnoconfig"
    else
        pass "B02-AC-1 ebuild has no allnoconfig"
    fi
    if grep -q 'CONFIGS_DIR' "$EBUILD"; then
        fail "B02-AC-1 ebuild contains CONFIGS_DIR"
    else
        pass "B02-AC-1 ebuild has no CONFIGS_DIR"
    fi
fi

# --- B02-AC-4: menuconfig-kernel writes only output/kernel.config.new ---
rec="$(awk '/^menuconfig-kernel:/ {on=1; print; next} on && /^[^[:space:]#]/ {exit} on {print}' Makefile 2>/dev/null)"
if [ -z "$rec" ]; then
    fail "B02-AC-4 Makefile has no menuconfig-kernel target"
else
    if printf '%s\n' "$rec" | grep -q 'output/kernel\.config\.new'; then
        pass "B02-AC-4 menuconfig-kernel writes output/kernel.config.new"
    else
        fail "B02-AC-4 menuconfig-kernel does not mention output/kernel.config.new"
    fi
    if printf '%s\n' "$rec" | grep -q 'allnoconfig'; then
        fail "B02-AC-4 menuconfig-kernel falls back to allnoconfig"
    else
        pass "B02-AC-4 menuconfig-kernel has no allnoconfig"
    fi
    # a write into configs/: redirection, tee, or cp/mv/install whose last argument is under configs/
    if printf '%s\n' "$rec" | grep -Eq '>[[:space:]]*"?[^ ]*configs/|tee[^|;&]*configs/|(cp|mv|install)[[:space:]][^;&|]*[[:space:]]"?[^ ]*configs/[^ ]*[[:space:]]*(;|&|\\|$)'; then
        fail "B02-AC-4 menuconfig-kernel writes under configs/"
    else
        pass "B02-AC-4 menuconfig-kernel writes nothing under configs/"
    fi
fi
if [ -f "$EBUILD" ]; then
    pc="$(awk '/^pkg_config\(\)/ {on=1} on {print} on && /^}/ {exit}' "$EBUILD")"
    if [ -z "$pc" ]; then
        fail "B02-AC-4 ebuild has no pkg_config"
    else
        if printf '%s\n' "$pc" | grep -q 'kernel\.config\.new'; then
            pass "B02-AC-4 pkg_config writes kernel.config.new"
        else
            fail "B02-AC-4 pkg_config does not write kernel.config.new"
        fi
        if printf '%s\n' "$pc" | grep -Eq 'allnoconfig|CONFIGS_DIR'; then
            fail "B02-AC-4 pkg_config uses allnoconfig/CONFIGS_DIR"
        else
            pass "B02-AC-4 pkg_config has no allnoconfig/CONFIGS_DIR"
        fi
    fi
else
    fail "B02-AC-4 $EBUILD not found (pkg_config)"
fi

# --- B02-AC-8 (fixture half): verify-kernel-modules.sh <sysroot> ---
VKM=scripts/verify-kernel-modules.sh
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ ! -f "$VKM" ]; then
    fail "B02-AC-8 $VKM not found (passes on a complete fixture sysroot)"
    fail "B02-AC-8 $VKM not found (fails on a fixture sysroot missing one module)"
else
    KVER="$(grep '^sys-kernel/monolith-kernel:' configs/portage/versions.lock | cut -d: -f2 | sed -E 's/-r[0-9]+$//')"
    LV=""
    [ -f "$SAVED" ] && LV="$(grep '^CONFIG_LOCALVERSION=' "$SAVED" | sed -E 's/^CONFIG_LOCALVERSION="(.*)"$/\1/')"
    mkdir -p "$TMP/bin"
    # modinfo stub: no module declares firmware
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/modinfo"
    chmod +x "$TMP/bin/modinfo"
    MODS="ne wd smc-ultra lance 3c509 pcnet32 tulip via-rhine natsemi sis900 e1000 e1000e igb sky2 r8169 vmxnet3
nf_conntrack nf_nat nf_tables nft_ct nft_nat nft_masq nf_defrag_ipv4
cirrusfb pm2fb pm3fb cyber2000fb vga16fb hgafb nvidiafb rivafb i740fb matroxfb_base radeonfb aty128fb atyfb
s3fb savagefb sisfb neofb kyrofb tdfxfb sstfb vt8623fb tridentfb arkfb sm712fb lxfb gxfb gx1fb"
    mk_sysroot() { # $1 = dir, $2 = module to omit
        d="$1/lib/modules/${KVER}${LV}/kernel/drivers"
        mkdir -p "$d"
        for m in $MODS; do
            [ "$m" = "${2:-}" ] && continue
            : > "$d/$m.ko"
        done
    }
    mk_sysroot "$TMP/full" ""
    PATH="$TMP/bin:$PATH" sh "$VKM" "$TMP/full" >"$TMP/full.out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "B02-AC-8 verify-kernel-modules.sh passes on a complete fixture sysroot"
    else
        fail "B02-AC-8 verify-kernel-modules.sh exit $rc on a complete fixture sysroot: $(tail -n 3 "$TMP/full.out" | tr '\n' ' ')"
    fi
    for omit in e1000e cirrusfb; do
        mk_sysroot "$TMP/miss-$omit" "$omit"
        PATH="$TMP/bin:$PATH" sh "$VKM" "$TMP/miss-$omit" >"$TMP/miss.out" 2>&1
        rc=$?
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ] && grep -q "$omit" "$TMP/miss.out"; then
            pass "B02-AC-8 verify-kernel-modules.sh fails naming $omit when it is missing"
        else
            fail "B02-AC-8 verify-kernel-modules.sh exit $rc without $omit (want non-zero naming it)"
        fi
    done
fi

# --- B02-AC-9: no tracked file outside SPEC.md, nodes/, docs/ names the old path ---
# Needle built from pieces so this file does not match itself. git ls-files works in
# commit-less `git init && git add -A` copies; find is the fallback outside a repo.
needle="configs/kernel""\\.config"
list="$TMP/files"
if [ -d .git ] || git rev-parse --git-dir >/dev/null 2>&1; then
    git ls-files > "$list" 2>/dev/null
fi
if [ ! -s "$list" ]; then
    find . -path ./.git -prune -o -path ./output -prune -o -type f -print | sed 's#^\./##' > "$list"
fi
hits="$(grep -v -e '^SPEC\.md$' -e '^nodes/' -e '^docs/' "$list" | while IFS= read -r f; do
    [ -f "$f" ] && grep -Il -e "$needle" "$f"
done)"
if [ -z "$hits" ]; then
    pass "B02-AC-9 no tracked file outside SPEC.md, nodes/, docs/ names the old kernel config path"
else
    fail "B02-AC-9 files naming the old kernel config path: $(echo $hits)"
fi

[ "$fails" -eq 0 ] && echo ALL PASS || { echo "$fails FAILED"; exit 1; }
