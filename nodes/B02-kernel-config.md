# B02 — kernel-config

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | B01 | B03 | — | M |

**Owns:** `configs/portage/savedconfig/sys-kernel/monolith-kernel`, `configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-6.12.80-r9.ebuild` (replaces r8), `Makefile` targets `menuconfig-kernel` and `regen-manifest`, the kernel export block of `build-packages.sh`, `scripts/verify-kernel-modules.sh`, `scripts/tests/kernel-ebuild.test.sh`, the four ported tests.
**Ports from linux-live-iso-factory@b9f533b:** first the tests `scripts/tests/verify-legacy-fbdev-config.sh`, `verify-netfilter-config.sh`, `verify-nic-zoo-config.sh` and `verify-resolved-i2c-off.test.sh`; then `scripts/verify-resolved-i2c-off.sh`, the module checks in `build.yml:312-420` (into a script, change 8), `docs/kernel-tiers.md`, the `Makefile` targets `menuconfig-kernel` and `regen-manifest`. It changes the kernel package and `configs/kernel.config`, which B01 ported as they are so that `world` builds.
**Study refs:** T-resolved-kernel-config-vacuous, T-ddc-i2c-escalation, T-kernel-config-symbol-names; recipes.yaml contradictions (kernel.config not a faithful resolved config; `CONFIG_CC_VERSION_TEXT` gcc 14 vs `crossdev.lock` gcc 15); D-486-tier-regime; OD-8; SPEC §4.3.

## Purpose
The kernel config is an authored input read through the standard `savedconfig.eclass`, not a bind-mounted file that the build rewrites. A missing config stops the build instead of producing an allnoconfig kernel.

## Standard mechanism
`savedconfig.eclass`: `restore_config` reads `/etc/portage/savedconfig/sys-kernel/monolith-kernel` (from `configs/portage/savedconfig/`, which the ported build syncs into the target's `/etc/portage`; busybox already works this way). Kbuild `olddefconfig` resolves it. The resolved config ships as package content (ported, `monolith-kernel-6.12.80-r8.ebuild:67-74`). Custom code: none new. The tier policy stays as `docs/kernel-tiers.md` plus the existing assertions.

## Tests
- **Ported first:** `verify-resolved-i2c-off.test.sh` unchanged; `verify-netfilter-config.sh`, `verify-nic-zoo-config.sh` and `verify-legacy-fbdev-config.sh` with their `cfg=` line pointed at the savedconfig path (change 7). They cover AC-7 and AC-10.
- **Added:** `kernel-ebuild.test.sh` (AC-1, AC-4, AC-8, AC-9) and the kernel case of `savedconfig-cache.test.sh` (AC-5).
- **Baseline:** with `b9f533b`'s `configs/kernel.config` copied to the savedconfig path, the ported tests pass; the r8 ebuild fails `kernel-ebuild.test.sh`, as expected.

## Changes from the port
1. **Savedconfig, no bind mount, no fallback.** r9 inherits `savedconfig`, calls `restore_config .config`, and dies if the file is missing. The r8 ebuild reads `${CONFIGS_DIR}/kernel.config` and falls back to allnoconfig with only a warning (`:26-35`). Move `configs/kernel.config` unchanged to the savedconfig path. *AC-1, AC-2.*
2. **No write-back.** Remove the `cp .config "${CONFIGS_DIR}/kernel.config"` in `src_install` (`:76-82`) and the matching export in `build-packages.sh:428-430`. The build exports the resolved config from the package to `output/kernel.resolved.config` and never to a tracked path. The tracked file was therefore not a faithful resolved config (FB_MATROX_I2C=m without FB_DDC; study contradictions). *AC-3.*
3. **menuconfig workflow.** `pkg_config` and `Makefile menuconfig-kernel` (`Makefile:406-423`) write to `output/kernel.config.new`; the developer copies it over the savedconfig. The target no longer falls back to allnoconfig. *AC-4.*
4. **Revbump.** `-r8` becomes `-r9` (D-revbump-on-overlay-change) with its `versions.lock` line and Manifest.
5. **Savedconfig marker.** Add `sys-kernel/monolith-kernel:configs/portage/savedconfig/sys-kernel/monolith-kernel` to the TRACKED list of the ported `savedconfig-cache.sh` (B01), so an edit rebuilds the kernel without a revbump. *AC-5.*
6. **Stale toolchain text.** `kernel.config:5-7` records gcc 14.3.1 while `crossdev.lock:10` pins gcc 15.3.1. `olddefconfig` recomputes these symbols on every build, so only the tracked file is stale. The first menuconfig run under the current builder replaces the header; a check that the resolved config's `CONFIG_GCC_VERSION` major equals the `crossdev.lock` gcc major runs on the exported config. *AC-6.*
7. **Consumers follow the file.** The ported tier tests (AC-7) read the savedconfig path: their `cfg=configs/kernel.config` line is a path adjustment. The `LOCALVERSION` greps (`build.yml:327,366`, `boot-test.yml:54`) are ported by B03 and O01; this node's test fails on any tracked file that names `configs/kernel.config`, so they arrive reading the savedconfig path. `verify-resolved-i2c-off.sh` is called with the exported resolved config and the build mode, which the predecessor never passed (mode always printed "unknown"; `build.yml:313`, script `:30-31`). *AC-7, AC-10.*

8. **Module checks become a script.** The inline NIC and legacy-fbdev module assertions (`build.yml:312-420`) move, unchanged in what they assert, into `scripts/verify-kernel-modules.sh <sysroot>`, because logic lives in `scripts/`, not YAML (SPEC §7). B03's `build.yml` calls it. *AC-8.*

Kept as is: the module lists, and the ported tier tests apart from their `cfg=` line. The undocumented Tier-0 `NET_9P`, `NET_9P_FD`, `NETFS_SUPPORT` stay, documented in `docs/kernel-tiers.md` (OD-8 default).

## Gate
- **B02-AC-1** — The r9 ebuild inherits `savedconfig`, calls `restore_config`, contains no `allnoconfig` and no `CONFIGS_DIR`. *Verify:* `scripts/tests/kernel-ebuild.test.sh`. *Tier:* fast.
- **B02-AC-2** — Building r9 without the savedconfig file fails with a clear error. *Verify:* the kernel emerge in the builder image (`make build-packages`, B01) with the file removed, run locally; log under `out/node/B02/`. *Tier:* slow.
- **B02-AC-3** — After a build, `git status` shows no change under `configs/`, and `output/kernel.resolved.config` exists. *Verify:* `git diff --exit-code configs/` after a local kernel build in the builder image. *Tier:* slow.
- **B02-AC-4** — `make menuconfig-kernel` writes only `output/kernel.config.new`. *Verify:* `scripts/tests/kernel-ebuild.test.sh` greps the target. *Tier:* fast.
- **B02-AC-5** — Editing the kernel savedconfig purges the cached kernel binpkg. *Verify:* `scripts/tests/savedconfig-cache.test.sh` (kernel case added). *Tier:* fast.
- **B02-AC-6** — The resolved config's `CONFIG_GCC_VERSION` major equals the `crossdev.lock` gcc major. *Verify:* a check on `output/kernel.resolved.config` after a local kernel build in the builder image. *Tier:* slow.
- **B02-AC-7** — The kernel savedconfig keeps the predecessor's driver tiers. Netfilter: `NETFILTER`, `NETFILTER_ADVANCED`, `NF_TABLES_IPV4` are `=y`; `NF_CONNTRACK`, `NF_NAT`, `NF_TABLES`, `NFT_CT`, `NFT_NAT`, `NFT_MASQ`, `NF_DEFRAG_IPV4` are `=m`. NICs: `NE2000`, `WD80x3`, `ULTRA`, `EL3`, `LANCE`, `NE2K_PCI`, `PCNET32`, `TULIP`, `8139TOO`, `8139CP`, `E100`, `VIA_RHINE`, `NATSEMI`, `SIS900`, `E1000`, `E1000E`, `IGB`, `R8169`, `SKY2`, `VIRTIO_NET`, `VMXNET3`, `HYPERV_NET` are `=m`, and the vendor gates `NET_VENDOR_{8390,AMD,3COM,INTEL,REALTEK,NATSEMI,SIS,VIA,MARVELL}` are `=y`. Legacy fbdev: `FB_{CIRRUS,PM2,PM3,CYBER2000,VGA16,HGA,NVIDIA,RIVA,I740,MATROX,RADEON,ATY128,ATY,S3,SAVAGE,SIS,NEOMAGIC,KYRO,3DFX,VOODOO1,VT8623,TRIDENT,ARK,SM712,GEODE_LX,GEODE_GX,GEODE_GX1}` and `FB_MATROX_I2C` are `=m`; `FB_GEODE` and the chip options `FB_MATROX_{MILLENIUM,MYSTIQUE,G}`, `FB_ATY_{CT,GX}`, `FB_SIS_{300,315}` are `=y`; the DDC options `FB_RADEON_I2C`, `FB_3DFX_I2C`, `FB_CYBER2000_DDC`, `FB_NVIDIA_I2C`, `FB_SAVAGE_I2C` (which would make `I2C` built in) and the excluded `FB_{ASILIANT,IMSTT,VIRTUAL,ARC,N411,METRONOME,IBM_GXT4500,CARMINE,MB862XX,OPENCORES,S1D13XXX,UDL,SMSCUFX}` are not set. `CONFIG_EXTRA_FIRMWARE` is not set. *Verify:* the ported `scripts/tests/verify-netfilter-config.sh`, `verify-nic-zoo-config.sh`, `verify-legacy-fbdev-config.sh`. *Tier:* fast.
- **B02-AC-8** — `scripts/verify-kernel-modules.sh` passes on the sysroot of a local build in the builder image and fails on a fixture sysroot missing one asserted module. *Verify:* the local build log; `scripts/tests/kernel-ebuild.test.sh` for the fixture. *Tier:* slow.
- **B02-AC-9** — No tracked file outside the spec names `configs/kernel.config`. *Verify:* `scripts/tests/kernel-ebuild.test.sh`. *Tier:* fast.
- **B02-AC-10** — `verify-resolved-i2c-off.sh CONFIG MODE` exits 1 with `FAIL: <CONFIG> not found` for a missing file and with `FAIL: CONFIG_I2C=y` for an escalation, and exits 0 with `PASS: CONFIG_I2C not =y` on a clean config, plain or gzipped. Each result line states `kernel build mode: MODE`. *Verify:* `scripts/tests/verify-resolved-i2c-off.test.sh`. *Tier:* fast.

## Risks
- Whether the builder's `savedconfig.eclass` reads `/etc/portage/savedconfig/<cat>/<pn>` for the cross ROOT is unverified; busybox's working savedconfig suggests yes.
- AC-6 assumes the exported config's `CONFIG_GCC_VERSION` is `150301`-style (unverified format for 15.3.1).
- OD-8 is open; the default keeps the symbols.
