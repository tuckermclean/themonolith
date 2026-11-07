#!/bin/sh
# Guards the DDC-trap invariant (docs/kernel-tiers.md, AGENTS.md's DDC-trap
# note): the five FB_*_I2C/FB_*_DDC bools forced off in the kernel savedconfig
# exist solely to keep CONFIG_I2C from being escalated to =y by
# `olddefconfig` (which would pull i2c-core into bzImage as a silent Tier-0
# growth). scripts/tests/verify-legacy-fbdev-config.sh only checks the
# pinned, pre-build config, which has no CONFIG_I2C line at all by design and
# can never catch an escalation.
#
# This script checks a *resolved* post-olddefconfig .config instead. That
# config is shipped as package content by the monolith-kernel ebuild
# (/usr/share/monolith-kernel/resolved-kernel.config.gz in src_install), so it
# is populated identically whether the kernel is built from source or pulled
# from the binpkg cache — there is no vacuous-pass mode where this file exists
# but reflects a stale/unresolved config (DCX-99). scripts/build-packages.sh
# exports that artifact to output/kernel.resolved.config after every kernel
# build, source or binpkg, and hard-fails the build itself if the artifact is
# missing — so by the time this script runs, a missing file here means
# build-packages.sh's own guard was bypassed, not that the assertion should
# skip.
#
# Usage: verify-resolved-i2c-off.sh CONFIG [build-mode]
#   CONFIG     path to the resolved config, plain text or gzip (.gz). Required.
#   build-mode optional free-text label (e.g. "source"/"binpkg"/"unknown") the
#              caller supplies so the PASS/FAIL line states which CI path
#              produced the artifact it just checked, instead of both modes
#              printing the same indistinguishable line. Defaults to "unknown".
set -u
cfg="${1:?usage: verify-resolved-i2c-off.sh CONFIG [build-mode]}"
mode="${2:-unknown}"

if [ ! -f "$cfg" ]; then
    echo "FAIL: $cfg not found (kernel build mode: $mode) — resolved-config artifact missing, invariant not proven this run"
    exit 1
fi

case "$cfg" in
    *.gz) reader="gunzip -c" ;;
    *)    reader="cat" ;;
esac

if $reader "$cfg" | grep -q "^CONFIG_I2C=y$"; then
    echo "FAIL: CONFIG_I2C=y in $cfg (kernel build mode: $mode) — a DDC trap escalated I2C into bzImage"
    exit 1
fi

echo "PASS: CONFIG_I2C not =y in $cfg (kernel build mode: $mode)"
