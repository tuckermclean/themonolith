# R04 — kernel-config-split

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| R | R01 | B02, O03 | — | L |

**Owns:** `recipes/kernel/README.md`, `recipes/kernel/frag/*.config`, `recipes/kernel/invariants.yaml`, `recipes/kernel/tier0-ceiling.txt`, `recipes/kernel/import-notes.yaml`, `recipes/kernel/initrd-modules.txt`, `recipes/kernel/required-modules.txt`, `recipes/kernel/legacy-fbdev-modules.txt`, `recipes/kernel/assert/*`, `recipes/kernel/tools/kconfig-check`, `recipes/overlay/sys-kernel/monolith-kernel/monolith-kernel-6.12.80-r9.ebuild` (replaces `-r8`), the `monolith-kernel` line of `pins/versions.lock`, the `kconfig-check` make target, `tests/fast/kconfig-*.test.sh`, `tests/fast/kernel-*.test.sh`, `tests/fast/fixtures/kconfig/`. Reads (frozen, staged by R01): `recipes/kernel/legacy/{kernel.config,initrd-modules.txt,kernel-tiers.md}`.
**Carries from linux-live-iso-factory@b9f533b:** `configs/kernel.config` (split, not copied), `configs/initrd-modules.txt` (kept as an authored list, cross-checked against Tier-1 annotations), the module-name lists inlined in `.github/workflows/build.yml:336-342` (23 NIC and netfilter modules) and `:370-390` (27 legacy fbdev modules), `docs/kernel-tiers.md` (policy, rewritten as `recipes/kernel/README.md`), `scripts/tests/verify-legacy-fbdev-config.sh`, `verify-nic-zoo-config.sh`, `verify-netfilter-config.sh`, `scripts/verify-resolved-i2c-off.sh` and `scripts/tests/verify-resolved-i2c-off.test.sh` (logic and cases), the copy-back and export logic at `scripts/build-packages.sh:401-431` (removed), the `monolith-kernel` ebuild.
**Study refs:** recipes.yaml `kernel` (tiers, `forced_settings`, `initrd_modules`, `tier1_config_tail`), `cfg.kernel.config`, `cfg.initrd-modules.txt`, contradictions #1, #2, #3, #4, #6, #7, open_questions #3, #4; traps T-ddc-i2c-escalation, T-resolved-kernel-config-vacuous, T-kernel-config-comments-erased, T-kernel-config-symbol-names, T-initrd-busybox-missing-applets (module side); doctrines D-486-tier-regime, D-486-minimalism, DEC-no-firmware-blobs, DEC-tier1-broad, DEC-fbdev-tier2; SPEC principle 9.

## Purpose
The kernel configuration we author lives in small, annotated fragments split by tier. The configuration the build resolves is a build artifact that no build writes into a tracked file. At b9f533b `configs/kernel.config` is both: a 3600-line machine-written file that the kernel ebuild overwrites on every source build, that has hand-appended lines after it, and that is not a faithful resolved config (below). After R04, intent is reviewable symbol by symbol with a reason, the D-486 ceiling and the I2C/DDC, NIC, netfilter and fbdev invariants are fast checks on the fragments, and the same checks run on the resolved artifact in B02.

Evidence that the predecessor's file is unreliable (all at b9f533b, `configs/kernel.config`):
- `CONFIG_CC_VERSION_TEXT` names gcc 14.3.1 (line 5) while `crossdev.lock:10` pins gcc 15.3.1.
- `CONFIG_FB_MATROX_I2C=m` (line 2146) next to `# CONFIG_I2C is not set` (line 1928) and no `FB_DDC`: `FB_MATROX_I2C` selects `FB_DDC`, which selects `I2C`, so a true resolution would have both `=m`.
- `# CONFIG_FB_TILEBLITTING is not set` (line 2193) while `FB_S3` is `=m` (line 2153) and `docs/kernel-tiers.md` says `=y`.
- Nine lines appended after `# end of Kernel hacking` (lines 3591–3600) in a different order: `CONFIG_VIRTIO_SCSI=m` (a symbol that is not the real one; the real symbol `SCSI_VIRTIO` is `=y` at line 1348) and `CONFIG_FUSION_SPI=m` / `FUSION_SAS=m` while `SCSI_SPI_ATTRS` and `SCSI_SAS_ATTRS` are `# ... is not set` (lines 1280, 1283), which those drivers depend on in mainline Kconfig (to be confirmed by the first resolved config).

## Scope
In:
- Fragment files, their format, lint, merge and the `kconfig-check` tool.
- Tier-0 ceiling file and the invariants file.
- The Tier-1 module list (authored, with a bijection check against the fragments) and the two module-name lists B02 asserts on the built tree.
- Thin executables in `recipes/kernel/assert/` that B02 runs against the resolved config.
- The fast tests that replace the three `verify-*-config.sh` scripts and the resolved-I2C script.
- `recipes/kernel/README.md` (policy home replacing `docs/kernel-tiers.md`).
- Kernel ebuild `-r9`: reads the merged config from the environment, ships the resolved config as package content, writes nothing into tracked files.

Out:
- Running the real kernel build, `olddefconfig`, extracting the resolved artifact, comparing `CONFIG_GCC_VERSION` to `crossdev.lock`, size records for `bzImage`: B02. R04 provides `kconfig-check resolved` and the contract.
- Initramfs assembly, reading `initrd-modules.txt`, the 6 MiB review budget, failing on a requested-but-missing module: B03.
- `.ko`-ship assertions (NIC, fbdev modules present in the squashfs) and the `Unknown symbol` / taint checks after a modprobe: O06 and O03 (`fbdev-modprobe`).
- Cache invalidation when a fragment changes: B02 keys the kernel binpkg on `sha256(merged config)`; R03 classifies `recipes/kernel/frag/**` as content-keyed. R03 still requires a bump for ebuild and `files/` changes.
- Pins, builder image, kernel tarball mirroring: I03, I04, R02.
- Whether `NET_9P=y`, `NET_9P_FD=y`, `NETFS_SUPPORT=y` belong in Tier 0 (open_questions #4): carried unchanged and marked; no OD exists, so a new OD is proposed under Spec defects.

## Design

### Files
```
recipes/kernel/
  README.md                     policy: tiers, rules, how to change config (replaces docs/kernel-tiers.md)
  frag/
    00-platform.config          imported non-policy symbols (CPU, mm, general, crypto, debug ...)
    10-tier0.config             =y boot-critical (the 486 contract)
    20-tier1.config             =m storage/bus modules for the initramfs; carry '#@ initrd:' names
    30-tier2.config             =m everything else: NIC zoo, netfilter, legacy fbdev, Hyper-V, input
    90-forced.config            symbols that must be set explicitly (off-switches, chip sub-options, gates)
  invariants.yaml               forbid / unset / require / implies / derived_prefixes
  tier0-ceiling.txt             allowed '=y' symbols (one 'CONFIG_X' per line), reviewed on growth
  import-notes.yaml             record of every symbol the import changed or dropped, with reason
  initrd-modules.txt            Tier-1 module names, authored (format of the legacy file); B03 reads it
  required-modules.txt          23 NIC + netfilter module names B02 asserts exist as .ko (from build.yml:336-342)
  legacy-fbdev-modules.txt      27 fbdev module names B02 asserts exist and carry no firmware (from build.yml:370-390)
  assert/                       executables taking a resolved config path as $1: i2c-off, features, firmware, ceiling
  tools/kconfig-check           python3 -I; lint, merge, resolved, ceiling-update, stats
  legacy/                       frozen b9f533b inputs (R01), read only by the import-fidelity test
```
Fragments are numbered; merge order is filename order. Each symbol is defined in exactly one fragment (single-definition rule, enforced by lint), so no override semantics are needed.

### Fragment format (decision)
Plain kernel `.config` syntax, one line per symbol: `CONFIG_X=y|m|"str"|123|0x1f` or `# CONFIG_X is not set`. `=n` is invalid. Reasons and metadata go on `#@ key: value` lines, which apply to all config lines up to the next blank line:
```
#@ tier: 2
#@ feature: fbdev
#@ why: legacy framebuffer drivers are modules; bool chip gates below
CONFIG_FB_CIRRUS=m
CONFIG_FB_PM2=m
```
Keys: `why` (text or trap/doctrine id), `feature` (`nic-zoo`, `netfilter`, `fbdev`, `hyperv`, `input`, `boot-media`, ...), `initrd` (comma-separated module names), `gate` (reason a `=y` is allowed in Tier 1/2), `derived-ok` (resolved value may differ; reason). `#@` lines are ignored by the kernel's `merge_config.sh` and `olddefconfig` (they are plain comments), and `kconfig-check merge` strips them. Trailing comments on a config line are forbidden: `merge_config.sh` would read them as part of the value.

Lint rules (`kconfig-check lint`), each with a code:
- `FORMAT`: line matches neither a config line, a `#@` line, a plain comment nor blank.
- `DUP`: a symbol appears twice in the whole fragment set.
- `TIER0`: `10-tier0.config` has a value other than `y` or `is not set`, or a `=y` symbol not in `tier0-ceiling.txt` (`GROWTH`).
- `TIER1`: a `20-tier1.config` symbol is not `=m`, or lacks `#@ initrd:`.
- `TIER2`: a `30-tier2.config` `=y` has no `#@ gate:`.
- `FORCED`: a `90-forced.config` line has no `#@ why:`.
- `TIER1MAP`: the set of `#@ initrd:` module names in `20-tier1.config` differs from `initrd-modules.txt` (either direction).
- `MODMAP`: a name in `required-modules.txt` or `legacy-fbdev-modules.txt` has no `#@ module:` annotation in `20-tier1.config` or `30-tier2.config`, or an annotated NIC/netfilter/fbdev module is in neither list.
- `INVARIANT`: any fragment sets a symbol to a `forbid`den value or sets an `unset` symbol.
- `DERIVED`: a fragment defines a symbol matching `derived_prefixes` (toolchain-evaluated: `CC_*`, `GCC_VERSION`, `CLANG_VERSION`, `AS_*`, `LD_*`, `LLD_VERSION`, `RUSTC_*`, `PAHOLE_VERSION`, `TOOLS_SUPPORT_RELR`).

Decision: separate tier files over one annotated defconfig. A tier is then a property of a path, so a PR that touches `10-tier0.config` is visibly a Tier-0 change and can be routed to the review the D-486 doctrine demands; lint rules differ per file; and a symbol has one home. Rejected: one `savedefconfig`-style file with `# tier:` comments, because tier membership becomes a comment convention that nothing can enforce per line (the predecessor's doctrine lived in a doc for exactly that reason, T-kernel-config-comments-erased). Rejected: the kernel tree's `merge_config.sh` as the tool of record: it needs a kernel source tree, which the fast tier does not have. `kconfig-check merge` is a small subset (concatenate in order, no overrides); B02 may additionally run the real `merge_config.sh -m` and diff for equality as a belt check.

The tracked base is deliberately not a `defconfig`: the build is `merged fragments → make olddefconfig`, the same semantics as rc1, so unlisted symbols take Kconfig defaults exactly as before. That is why default-`y` bool traps (below) need explicit `is not set` lines.

### Merge and the resolved artifact
`kconfig-check merge -o OUT [--frag-dir recipes/kernel/frag]` writes `OUT` deterministically: header lines `# merged by kconfig-check` and one `# frag <name> sha256:<hex>` per input, then the config lines in fragment order, annotations stripped, no timestamp. B02 runs `olddefconfig` on it inside the kernel ebuild. The resolved `.config` is never written to a tracked path: it exists as (a) `/usr/share/monolith-kernel/resolved-kernel.config.gz` inside the binpkg (kept from DCX-99, so a cache hit still proves the invariants) and (b) `out/kernel/resolved-kernel.config`, a CI artifact B02 extracts from (a). `out/` is untracked.

### `kconfig-check`
`python3 -I`, standard library plus PyYAML. Exit codes: 0 ok; 1 findings; 2 usage; 3 required input missing (a missing resolved artifact is an error, never a skip: DCX-99).
```
kconfig-check lint   [--frag-dir D]
kconfig-check merge  -o OUT [--frag-dir D]
kconfig-check resolved CONFIG[.gz] [--mode LABEL] [--expect-gcc MAJOR] [--strict] [--frag-dir D]
kconfig-check ceiling-update CONFIG[.gz]            # rewrite tier0-ceiling.txt from a resolved config
kconfig-check stats  [--frag-dir D]                 # counts per tier/feature; the only place counts are stated
```
`resolved` checks, in order, and prints `PASS`/`FAIL` with the mode label (`source`, `binpkg`, `unknown`) in every line, as `verify-resolved-i2c-off.sh` did:
1. `forbid` / `unset` invariants against the resolved values (`CONFIG_I2C=y`, `CONFIG_FB_DDC=y`, any `CONFIG_EXTRA_FIRMWARE=` assignment fail).
2. `require` invariants (the Tier-0 boot-critical set).
3. `implies` rules (`FB_TILEBLITTING` must be `y` when any of `FB_S3`, `FB_ARK`, `FB_VT8623`, `FB_MATROX` is `y` or `m`).
4. Ceiling: every `=y` symbol in the resolved config is in `tier0-ceiling.txt` (`GROWTH`).
5. Authored-vs-resolved: every setting in `10-tier0`, `20-tier1`, `30-tier2`, `90-forced` equals the resolved value (`DRIFT`, fatal). The same for `00-platform` is reported but fatal only with `--strict`; B02 turns `--strict` on once the first green build has cleaned it. A dropped or renamed symbol therefore fails here instead of vanishing under `olddefconfig` (T-kernel-config-symbol-names).
6. `--expect-gcc N`: `CONFIG_GCC_VERSION` major equals `N` (B02 passes the major from `crossdev.lock`). This is the check the stale gcc-14 text in the committed file would have failed.

`tier0-ceiling.txt` is the D-486-minimalism mechanism: a new `=y` anywhere, in a fragment (fast) or in the resolved config (slow), fails until someone adds the symbol to the file in a reviewed change. Its initial content is the `=y` set of the legacy file minus derived symbols, flagged unverified in its header: the first B02 run on a real kernel tree reconciles it with `ceiling-update` in a reviewed PR. Selected symbols that the legacy file lacked (for example `FB_TILEBLITTING`) appear then.

### Tier-1 module list stays an authored file
`recipes/kernel/initrd-modules.txt` is the list B03 bundles, in the legacy format (one name per line, `-`/`_` interchangeable, `#` comments), because SPEC §4.2 names "initrd module list" among R04's authored files. `20-tier1.config` carries `#@ initrd: <module>[,<module>]` on the lines that build those modules, and lint `TIER1MAP` makes the two agree in both directions. At b9f533b the list (`configs/initrd-modules.txt`, 31 modules) and the symbols (`kernel.config:3591-3600` plus scattered lines) had no link, and a mismatch only produced a build-log warning (`scripts/build-initrd.sh`, "requested but not bundled"). Rejected: derive the list from the annotations at build time (one source) — SPEC §4.2 and B03 expect the file; the bijection check gives the same protection. The other 30 module names are preserved; the exception is `virtio_scsi`, dropped with the reason in `import-notes.yaml`: its driver is built in through `SCSI_VIRTIO=y` (legacy line 1348), so no `virtio_scsi.ko` exists, and `CONFIG_VIRTIO_SCSI` (legacy line 3593) is not the symbol that builds it (to be confirmed by the first resolved config). Behaviour is unchanged (it was never bundled). `SCSI_SPI_ATTRS=m` and `SCSI_SAS_ATTRS=m` are added to Tier 1 with `#@ why: dependency of FUSION_SPI/SAS`; if rc1 never built `mptspi`/`mptsas`, this fixes a silent gap and is a stated difference for O07.

`required-modules.txt` and `legacy-fbdev-modules.txt` replace the module arrays inlined in `build.yml`; each name is tied to a symbol by a `#@ module:` annotation (lint `MODMAP`), so a renamed or dropped symbol cannot leave a stale name behind. B02 asserts that each listed module exists in the built tree.

### `recipes/kernel/assert/`
Four small POSIX-sh executables, each taking the resolved config path as `$1` and an optional mode label as `$2`, exit 0/1/3 as `kconfig-check`: `i2c-off` (invariants on `I2C`, `FB_DDC`), `features` (runs `tests/fast/kconfig-features.test.sh "$1"`), `firmware` (`EXTRA_FIRMWARE`, `WIRELESS`), `ceiling` (`GROWTH`). They exist so B02 can run them in order without knowing `kconfig-check`'s subcommands; `kconfig-check resolved` runs the same checks in one call.

### Import (one-off, recorded)
A throwaway script (not kept) classifies each symbol of `recipes/kernel/legacy/kernel.config`: toolchain-derived symbols are excluded; symbols named in `README`'s Tier-0 table plus `PATA_*`, `ATA_*` boot media go to `10-tier0`; the 31 initrd modules' symbols to `20-tier1`; `NET_VENDOR_*` gates, NIC zoo, netfilter, legacy fbdev `=m`, Hyper-V, `INPUT_EVDEV`, `MOUSE_PS2` to `30-tier2`; the five DDC off-switches, chip sub-options, `FB_GEODE`, scope-excluded fbdev symbols to `90-forced`; everything else to `00-platform`. `import-notes.yaml` lists every deviation as `{symbol, action: dropped|added|changed, reason, evidence}`; the fidelity test requires `legacy symbols − derived = fragment symbols − added + dropped`.

### Forced settings carried (`90-forced.config`, each with `#@ why:`)
`FB_RADEON_I2C`, `FB_3DFX_I2C`, `FB_CYBER2000_DDC`, `FB_NVIDIA_I2C`, `FB_SAVAGE_I2C` `is not set` (default-`y` bools escalate `FB_DDC` to `y`, which selects `I2C=y`, T-ddc-i2c-escalation); `FB_MATROX_I2C=m` (so its select of `FB_DDC` stays modular); `FB_MATROX_MILLENIUM`/`MYSTIQUE`/`G`, `FB_ATY_CT`/`GX`, `FB_SIS_300`/`315` `=y` (otherwise the `.ko` is empty); `FB_GEODE=y` (bool gate with no object); `FB_ASILIANT`, `FB_IMSTT` (bool, `depends on FB=y`, no `=m` form) and the scope-excluded `FB_VIRTUAL`, `FB_ARC`, `FB_N411`, `FB_METRONOME`, `FB_IBM_GXT4500`, `FB_CARMINE`, `FB_MB862XX`, `FB_OPENCORES`, `FB_S1D13XXX`, `FB_UDL`, `FB_SMSCUFX` `is not set`. `CONFIG_I2C` and `FB_TILEBLITTING` are not authored at all: they are derived, and the invariants constrain the result. This resolves contradiction #1 (the doc says `=y`, the file said unset: the rule is now `implies`, checked on the resolved config) and #2 (`verify-legacy-fbdev-config.sh` claimed no `CONFIG_I2C` line exists while line 1928 has one): the invariant is "`I2C` is never `y`", not "absent". `I2C=m` is acceptable and expected once `FB_MATROX_I2C=m` is honoured.

### Kernel ebuild `-r9`
Changes from `-r8` (R03 requires the bump; `pins/versions.lock` line becomes `sys-kernel/monolith-kernel:6.12.80-r9:0`):
- `src_configure` copies `${MONOLITH_KERNEL_CONFIG}` to `.config` and runs `olddefconfig`; `[[ -f ${MONOLITH_KERNEL_CONFIG} ]] || die` replaces the silent `allnoconfig` fallback (Principle 5: a fallback that builds a useless kernel is a lie). B02/B01 export the variable.
- `src_install` no longer copies `.config` to `${CONFIGS_DIR}/kernel.config`; it still ships `resolved-kernel.config.gz` as package content.
- `pkg_config` (interactive `menuconfig`) writes to `${KERNEL_SCRATCH_DIR:-${T}}/menuconfig.config` and prints `scripts/diffconfig <merged> <result>` as the way to port a change into a fragment. Rejected: auto-writing fragments from `menuconfig` output (it would re-create the machine-managed file).
- The seven `WA monolith-kernel#n` tags from R01 stay, with the copy-back one (#6) rewritten.
- `BDEPEND`, the GCC-15 patch, `-j1`, `INSTALL_MOD_STRIP=1`, the `depmod` rerun are unchanged.

## Traps and doctrines preserved
- T-ddc-i2c-escalation (default-`y` I2C/DDC bools): R04-AC-5 (off-switches present, `I2C`/`FB_DDC` forbidden at `y` in fragments and resolved).
- T-resolved-kernel-config-vacuous (assertion that passes on a cache hit without checking anything): R04-AC-6 (missing artifact exits 3; gz input; mode label) and R04-AC-13 (artifact still ships as package content).
- T-kernel-config-comments-erased (machine rewriting removes reasons): R04-AC-1, R04-AC-12 (no build writes a tracked kernel file; reasons live in `#@` lines).
- T-kernel-config-symbol-names (retired or wrong names silently dropped; `TRIM_UNUSED_KSYMS`): R04-AC-7 (resolved drift is fatal for tiers 0–2 and forced), R04-AC-9 (the `VIRTIO_SCSI` and `FUSION_*` cases, and the list/annotation bijection); the `TRIM_UNUSED_KSYMS` "Unknown symbol" watch item is documented in the README and exercised by O03/O02 (named, not claimed here).
- D-486-tier-regime: tier files and lint (R04-AC-1), Tier-0 `require` set including the VIA/SiS/ALi PATA audit item that the old doc left "tracked separately" (R04-AC-8), NIC/netfilter/fbdev feature sets (R04-AC-4), firmware covenant (R04-AC-6).
- D-486-minimalism: ceiling file and `GROWTH` (R04-AC-3). Size budgets are B02/B03.
- SPEC principle 9 (authored vs generated): R04-AC-12.
- DEC-no-firmware-blobs: `EXTRA_FIRMWARE` unset, `WIRELESS` unset: R04-AC-6.

## Gate
- **R04-AC-1** — `kconfig-check lint` passes on the committed fragments and fails, with the stated code, on each fixture: bad format, duplicate symbol, Tier-0 non-`y`, Tier-1 non-`m` or missing `#@ initrd:`, Tier-2 `=y` without `#@ gate:`, forced line without `#@ why:`, derived-prefix symbol, forbidden value. *Verify:* `tests/fast/kconfig-fragments.test.sh`. *Tier:* fast.
- **R04-AC-2** — `kconfig-check merge` is deterministic (two runs, different working directories, byte-identical), strips `#@` lines, orders by filename, records per-input sha256, contains no timestamp, and leaves `git status --porcelain` clean when writing outside the tree. *Verify:* `tests/fast/kconfig-merge.test.sh`. *Tier:* fast.
- **R04-AC-3** — Every `=y` symbol in the fragments is in `tier0-ceiling.txt`; adding a `=y` to any fragment without a ceiling edit fails `GROWTH`; the ceiling file has no duplicates and is sorted. *Verify:* `tests/fast/kconfig-fragments.test.sh`. *Tier:* fast.
- **R04-AC-4** — The merged fragments satisfy the three feature sets carried verbatim from the predecessor: 27 fbdev `=m` drivers, `FB_GEODE=y`, seven chip `=y` bools, `FB_MATROX_I2C=m`, five DDC `is not set`, thirteen scope-excluded `is not set` (from `verify-legacy-fbdev-config.sh`); 22 NIC `=m` and nine `NET_VENDOR_*=y` gates (`verify-nic-zoo-config.sh`); three `=y` and seven `=m` netfilter symbols (`verify-netfilter-config.sh`). The same test accepts a resolved `.config` path so B02 reuses it. *Verify:* `tests/fast/kconfig-features.test.sh [config]` (the symbol lists are hard-coded in the test file, which is protected after RED). *Tier:* fast.
- **R04-AC-5** — The five DDC/I2C off-switches are `is not set` in `90-forced.config`; `invariants.yaml` forbids `I2C=y` and `FB_DDC=y`; a fragment that sets either to `y` fails lint. *Verify:* `tests/fast/kconfig-fragments.test.sh`, `tests/fast/kconfig-features.test.sh`. *Tier:* fast.
- **R04-AC-6** — `kconfig-check resolved` ports the five cases of `verify-resolved-i2c-off.test.sh`: missing artifact exits 3 and prints `FAIL ... not found (kernel build mode: <label>)`; `CONFIG_I2C=y` fails; `CONFIG_I2C=m` and `# CONFIG_I2C is not set` pass; gzip input is read; the mode label is echoed in every `PASS`/`FAIL` line. It also fails on any `CONFIG_EXTRA_FIRMWARE=` assignment and on `--expect-gcc 15` against a config with `CONFIG_GCC_VERSION=140301`. *Verify:* `tests/fast/kconfig-resolved.test.sh` (fixtures under `tests/fast/fixtures/kconfig/`). *Tier:* fast.
- **R04-AC-7** — `resolved` reports `DRIFT` (fatal) when a symbol authored in tiers 0–2 or forced differs from or is missing in the resolved config, and reports `00-platform` drift non-fatally unless `--strict`; reports `GROWTH` for a resolved `=y` outside the ceiling; evaluates `implies` (`FB_TILEBLITTING`) only on resolved input. *Verify:* `tests/fast/kconfig-resolved.test.sh` (a fixture that drops `CONFIG_FUSION_SPI`, one that adds `CONFIG_I2C=y`, one with `FB_S3=m` and `FB_TILEBLITTING` unset). *Tier:* fast.
- **R04-AC-8** — The Tier-0 `require` set is satisfied by `10-tier0.config`: `ATA`, `ATA_PIIX`, `BLK_DEV_SR`, `CDROM`, `ISO9660_FS`, `SQUASHFS`, `OVERLAY_FS`, `TMPFS`, `VFAT_FS`, `BLK_DEV_INITRD`, `DEVTMPFS`, `DEVTMPFS_MOUNT`, `SERIAL_8250`, `SERIAL_8250_CONSOLE`, `FB`, `FB_EFI`, `ACPI`, `EFI`, `MODULES`, `MODULE_UNLOAD`, and the Socket-7 southbridge PATA set `PATA_LEGACY`, `ATA_GENERIC`, `PATA_VIA`, `PATA_SIS`, `PATA_ALI` are all `=y`. *Verify:* `tests/fast/kconfig-features.test.sh`. *Tier:* fast.
- **R04-AC-9** — `recipes/kernel/initrd-modules.txt` lists the 30 legacy modules that remain after dropping `virtio_scsi`, in the legacy format; lint `TIER1MAP` fails on a fixture where a listed module has no annotation and on one where an annotation has no list entry; every `20-tier1` symbol is `=m`; `SCSI_SPI_ATTRS` and `SCSI_SAS_ATTRS` are `=m` there; `import-notes.yaml` records the `virtio_scsi` drop and the two additions with the legacy line numbers. `required-modules.txt` (23 names) and `legacy-fbdev-modules.txt` (27 names) pass lint `MODMAP`. *Verify:* `tests/fast/kconfig-tier1.test.sh`. *Tier:* fast.
- **R04-AC-10** — Import fidelity: every symbol of `recipes/kernel/legacy/kernel.config` that is not toolchain-derived appears in exactly one fragment, or in `import-notes.yaml` as dropped, and every fragment symbol is in the legacy file or recorded as added; values are equal except where `import-notes.yaml` records a change. *Verify:* `tests/fast/kernel-import-fidelity.test.sh`. *Tier:* fast.
- **R04-AC-11** — `recipes/kernel/README.md` states tiers, rules and the change procedure; every `CONFIG_*` token in it exists in a fragment or `invariants.yaml`; it quotes no module or symbol counts (they live in `kconfig-check stats`) and has no Tier-1 module table; the audit item about VIA/SiS/ALi is marked done and points at AC-8. *Verify:* `tests/fast/kernel-readme.test.sh`. *Tier:* fast.
- **R04-AC-12** — No script, ebuild or make target writes into `recipes/kernel/` or any tracked kernel config at build time: the `-r9` ebuild contains no `cp .config` to a path outside `${T}`/`${D}`; `grep -rn "recipes/kernel" factory/ Makefile` finds only read uses and `kconfig-check`. *Verify:* `tests/fast/kernel-ebuild.test.sh`. *Tier:* fast.
- **R04-AC-13** — The `-r9` ebuild exists, `-r8` is removed, it dies without `MONOLITH_KERNEL_CONFIG`, still installs `/usr/share/monolith-kernel/resolved-kernel.config.gz`, keeps the GCC-15 patch and the seven `WA monolith-kernel#` tags, and `pins/versions.lock` names `-r9`. *Verify:* `tests/fast/kernel-ebuild.test.sh`. *Tier:* fast.
- **R04-AC-14** — On a real build (source and binpkg-hit paths), `kconfig-check resolved <artifact> --mode <mode> --expect-gcc <major from crossdev.lock>` passes with zero fatal `DRIFT` in tiers 0–2 and forced, and `tier0-ceiling.txt` has been reconciled by a reviewed `ceiling-update`. *Verify:* CI job `kernel-resolved` in the B02 pipeline (artifact `out/kernel/resolved-kernel.config`, log with the mode label). *Tier:* slow (evidence first available at B02; R04 merges on the fast ACs).
- **R04-AC-15** — Each executable in `recipes/kernel/assert/` exits 0 on a clean resolved fixture, 1 with a `FAIL` line naming the symbol on a violating fixture, and 3 when the path argument does not exist; the mode label appears in every output line. *Verify:* `tests/fast/kconfig-assert.test.sh`. *Tier:* fast.

## RED plan
The tester commits fixtures under `tests/fast/fixtures/kconfig/` (a minimal fragment set; one defect per fixture; resolved configs for clean, `I2C=y`, `I2C=m`, `EXTRA_FIRMWARE`, `GCC_VERSION=140301`, dropped-symbol and growth cases, plain and gzipped) and these tests: `kconfig-fragments`, `kconfig-merge`, `kconfig-resolved`, `kconfig-features`, `kconfig-tier1`, `kconfig-assert`, `kernel-import-fidelity`, `kernel-readme`, `kernel-ebuild`. At RED, `recipes/kernel/frag/` and `tools/kconfig-check` do not exist, so all fail. `kconfig-features.test.sh` is the sharpest RED: its symbol lists are the three old scripts' lists (the oracle), and it fails until the split is faithful. `kernel-import-fidelity` fails until `import-notes.yaml` accounts for every deviation, including the `VIRTIO_SCSI` and `FUSION_*` cases.

## Risks and open questions
- No kernel tree is available offline, so Kconfig facts here (`FB_MATROX_I2C → FB_DDC → I2C`; `FUSION_SPI depends on SCSI_SPI_ATTRS`; a bool selected by a `=m` symbol resolves to `y`; `VIRTIO_SCSI` not being a real symbol) are from the predecessor's own analysis and memory of mainline. The `resolved` check is the safety net: a wrong belief fails loudly at the first B02 run instead of passing quietly. `import-notes.yaml` marks each such claim `unverified-until-b02`.
- `tier0-ceiling.txt` starts unverified and needs a reviewed reconciliation after the first real resolve; if growth beyond a handful of symbols appears, the maintainer decides what is Tier 0.
- `00-platform.config` still holds roughly 3000 imported lines (a platform baseline nobody curated). The `DRIFT` report in B02 is the cleaning mechanism; deleting symbols that equal their Kconfig default is a follow-up, not a gate.
- `NET_9P=y`, `NET_9P_FD=y`, `NETFS_SUPPORT=y` in Tier 0 are carried with `#@ why: UNJUSTIFIED at b9f533b (purpose undocumented; likely QEMU 9p debugging)`. They count against D-486-minimalism; the owner should confirm or demote them.
- `MONOLITH_KERNEL_CONFIG` is a new cross-node interface: B01/B02 must export it and B02 must run `merge` first. If B02 prefers the real `merge_config.sh`, the fast `merge` remains the reference.
- The README replaces `docs/kernel-tiers.md`; the escape hatch "two initrds" described there is not built and stays out.
- Depends on OD-3 only insofar as `kconfig-check` is Python; with OD-3 = Go it would be rewritten, the file formats would not change.

## Cost
Four slices: (1) `kconfig-check` core, invariants, resolved-check fixtures and the ported I2C cases (AC-1, 2, 6, 7); (2) the import, fragments, `import-notes.yaml`, ceiling (AC-3, 4, 5, 8, 9, 10); (3) README and doc cross-check (AC-11); (4) ebuild `-r9` and lock bump (AC-12, 13). Slice 2 is the large one (about 3600 lines classified). No CI build cycles in R04. B02 spends the first cold kernel build (build time unknown; the ebuild uses `-j1` because cross-gcc OOMs runners) and expects 2–3 cycles to reconcile ceiling and drift (AC-14). No storage or hosting cost; the legacy file adds about 130 KB to the repo.

## Spec defects found
- SPEC §10 has no decision for Tier-0 growth that the predecessor carried without justification (`NET_9P`, `NETFS_SUPPORT`). Proposed: a new OD "keep or demote the undocumented Tier-0 symbols", default keep.
- `graph.yaml` R04 summary says "fast checks for I2C/DDC, NIC, netfilter and fbdev tiers". The resolved-config half of those checks (the part that matters for T-resolved-kernel-config-vacuous) can only run in B02. B02's gate must name `kconfig-check resolved` and the mode label explicitly; R04-AC-14 is the handoff.
- Cross-node interface mismatches seen in the parallel specs (reconciled in review on 2026-10-27: B02 now consumes `kconfig-check merge`/`resolved`, `#@ derived-ok` and `MONOLITH_KERNEL_CONFIG`, and keeps the merged-config hash in its key): (1) B02 plans its own `factory/lib/kconfig-merge.py` and `kconfig-drift.py`; R04's `kconfig-check merge` and `resolved` (DRIFT) cover both, and two mergers would drift apart. (2) B02 sets `CONFIGS_DIR=/work/kconfig` and relies on the ebuild reading and writing `kernel.config` there; R04's `-r9` reads `${MONOLITH_KERNEL_CONFIG}` and writes nothing back, so B02 should export that variable instead. (3) B02 expects `recipes/kernel/drift-waivers.txt`; R04 expresses a waiver as `#@ derived-ok: <reason>` on the fragment line, which keeps the reason beside the symbol. (4) B02 keys the kernel binpkg on the merged-config hash, which is why R03 treats the fragments as content-keyed; if B02 drops that, R03 must move them back to revbump inputs.
- `docs/kernel-tiers.md` is not in any node's carry list in `graph.yaml`; R04 takes it.
