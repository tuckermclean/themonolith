# B02 — kernel-config

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | F01 | B03 | — | M |

**Owns:** `configs/portage/savedconfig/sys-kernel/monolith-kernel`, `configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-6.12.80-r9.ebuild` (replaces r8), `Makefile` target `menuconfig-kernel`, the kernel export block of `build-packages.sh`, `scripts/tests/kernel-ebuild.test.sh`, `scripts/tests/verify-*.sh` paths.
**Ports from linux-live-iso-factory@b9f533b:** `configs/kernel.config` (moved, not rewritten), `configs/overlay/sys-kernel/monolith-kernel/` (r8), `scripts/verify-resolved-i2c-off.sh`, `scripts/tests/verify-*.sh`, `scripts/tests/verify-resolved-i2c-off.test.sh`, the module checks in `build.yml:312-420`, `docs/kernel-tiers.md`.
**Study refs:** T-resolved-kernel-config-vacuous, T-ddc-i2c-escalation, T-kernel-config-symbol-names; recipes.yaml contradictions (kernel.config not a faithful resolved config; `CONFIG_CC_VERSION_TEXT` gcc 14 vs `crossdev.lock` gcc 15); D-486-tier-regime; OD-13; SPEC §4.3.

## Purpose
The kernel config is an authored input read through the standard `savedconfig.eclass`, not a bind-mounted file that the build rewrites. A missing config stops the build instead of producing an allnoconfig kernel.

## Standard mechanism
`savedconfig.eclass`: `restore_config` reads `/etc/portage/savedconfig/sys-kernel/monolith-kernel` (from `configs/portage/savedconfig/`, which the ported build syncs into the target's `/etc/portage`; busybox already works this way). Kbuild `olddefconfig` resolves it. The resolved config ships as package content (ported, `monolith-kernel-6.12.80-r8.ebuild:67-74`). Custom code: none new. The fragment split and tier tooling of v0.3 are removed; the tier policy stays as `docs/kernel-tiers.md` plus the existing assertions.

## Changes from the port
1. **Savedconfig, no bind mount, no fallback.** r9 inherits `savedconfig`, calls `restore_config .config`, and dies if the file is missing. The r8 ebuild reads `${CONFIGS_DIR}/kernel.config` and falls back to allnoconfig with only a warning (`:26-35`). Move `configs/kernel.config` unchanged to the savedconfig path. *AC-1, AC-2.*
2. **No write-back.** Remove the `cp .config "${CONFIGS_DIR}/kernel.config"` in `src_install` (`:76-82`) and the matching export in `build-packages.sh:428-430`. The build exports the resolved config from the package to `output/kernel.resolved.config` and never to a tracked path. The tracked file was therefore not a faithful resolved config (FB_MATROX_I2C=m without FB_DDC; study contradictions). *AC-3.*
3. **menuconfig workflow.** `pkg_config` and `Makefile menuconfig-kernel` (`Makefile:406-423`) write to `output/kernel.config.new`; the developer copies it over the savedconfig. The target no longer falls back to allnoconfig. *AC-4.*
4. **Revbump.** `-r8` becomes `-r9` (D-revbump-on-overlay-change) with its `versions.lock` line and Manifest.
5. **Savedconfig marker.** Add `sys-kernel/monolith-kernel:configs/portage/savedconfig/sys-kernel/monolith-kernel` to the TRACKED list of the ported `savedconfig-cache.sh` (B01), so an edit rebuilds the kernel without a revbump. *AC-5.*
6. **Stale toolchain text.** `kernel.config:5-7` records gcc 14.3.1 while `crossdev.lock:10` pins gcc 15.3.1. `olddefconfig` recomputes these symbols on every build, so only the tracked file is stale. The first menuconfig run under the current builder replaces the header; a check that the resolved config's `CONFIG_GCC_VERSION` major equals the `crossdev.lock` gcc major runs on the exported config. *AC-6.*
7. **Consumers follow the file.** `verify-*.sh` (`cfg=configs/kernel.config`) and the `LOCALVERSION` greps (`build.yml:327,366`, `boot-test.yml:54`) read the savedconfig path. `verify-resolved-i2c-off.sh` is called with the exported resolved config and the build mode, which the predecessor never passed (mode always printed "unknown"; `build.yml:313`, script `:30-31`). *AC-7.*

Kept as is: the inline NIC and legacy-fbdev module lists (`build.yml:320-420`) and the seven `verify-*` scripts. They assert real drivers and already run (`pr-validate.yml:65` runs `scripts/tests/*.sh`). The undocumented Tier-0 `NET_9P`, `NET_9P_FD`, `NETFS_SUPPORT` stay, documented in `docs/kernel-tiers.md` (OD-13 default).

## Gate
- **B02-AC-1** — The r9 ebuild inherits `savedconfig`, calls `restore_config`, contains no `allnoconfig` and no `CONFIGS_DIR`. *Verify:* `scripts/tests/kernel-ebuild.test.sh`. *Tier:* fast.
- **B02-AC-2** — Building r9 without the savedconfig file fails with a clear error. *Verify:* CI step that runs the emerge with the file removed. *Tier:* slow.
- **B02-AC-3** — After a build, `git status` shows no change under `configs/`, and `output/kernel.resolved.config` exists. *Verify:* CI step `git diff --exit-code configs/`. *Tier:* slow.
- **B02-AC-4** — `make menuconfig-kernel` writes only `output/kernel.config.new`. *Verify:* `scripts/tests/kernel-ebuild.test.sh` greps the target. *Tier:* fast.
- **B02-AC-5** — Editing the kernel savedconfig purges the cached kernel binpkg. *Verify:* `scripts/tests/savedconfig-cache.test.sh` (kernel case added). *Tier:* fast.
- **B02-AC-6** — The resolved config's `CONFIG_GCC_VERSION` major equals the `crossdev.lock` gcc major. *Verify:* CI step on `output/kernel.resolved.config`. *Tier:* slow.
- **B02-AC-7** — All ported `verify-*` tests pass against the savedconfig path, and `verify-resolved-i2c-off.sh` echoes the real build mode. *Verify:* `make test`. *Tier:* fast.
- **B02-AC-8** — The ported NIC and fbdev module assertions pass on the built sysroot. *Verify:* build.yml steps. *Tier:* slow.

## Risks
- Whether the builder's `savedconfig.eclass` reads `/etc/portage/savedconfig/<cat>/<pn>` for the cross ROOT is unverified; busybox's working savedconfig suggests yes.
- AC-6 assumes the exported config's `CONFIG_GCC_VERSION` is `150301`-style (unverified format for 15.3.1).
- OD-13 is open; the default keeps the symbols.
