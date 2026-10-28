# B02 — kernel-build

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| B | B01, R04 | B03, B04, B05 | — (feeds MS1) | M |

**Owns:** `factory/bin/build-kernel`, `factory/lib/kernel-assert.sh`, `factory/mk/kernel.mk`, `tests/fast/kernel-*.test.sh`,
`tests/fast/fixtures/kernel/`
**Carries from linux-live-iso-factory@b9f533b:** the export logic of `scripts/build-packages.sh:326-338,401-432`
(ported; the one forced change is that nothing is written into the tracked `configs/kernel.config`, B02-AC-1), `scripts/verify-resolved-i2c-off.sh` (moves to R04's assertion set). The kernel's cache logic is not carried: `scripts/savedconfig-cache.sh` and the kernel key are I06's, the module assertions inlined in
`.github/workflows/build.yml:323-423` (moved here as code with R04-owned lists). The predecessor's `CONFIGS_DIR`
read-write mount (`Makefile:318`) is dropped.
**Study refs:** build.yaml `script.build-packages` (config overwrite, FAILURE MASKING, kernel build mode),
`script.verify-resolved-i2c-off`, contradictions (mode label always `unknown`; kernel.config stale gcc 14 text);
workflows.yaml `job.build.build` ci_assertions `assert.i2c-off`, `assert.nic-modules`, `assert.fbdev-modules`;
D-486-tier-regime, Principles 5 and 9.

## Purpose
After B02 the kernel is built (or restored by I06 from its cache) from authored fragments only, and the resolved `.config`, `vmlinuz`
and module tree are emitted as artifacts under `out/kernel/`, never written into the repo. Every assertion the
predecessor ran in CI YAML runs here as code against the resolved config and the modules actually built, with the
build mode known rather than guessed from emerge's English output.

## Scope
In:
- Assembling the kernel input config from `recipes/kernel/frag/` with R04's `kconfig-check merge`.
- Building `sys-kernel/monolith-kernel`, or using the copy I06 restored when its fingerprint matches, and running every assertion on the result either way.
- Exporting `vmlinuz`, the resolved config, the `/lib/modules/<krel>` tree, `kernel.json`.
- Running R04's assertion scripts against the resolved config and the module-presence/firmware checks against the
  built modules.

Out:
- The kernel's cache key, restore and save: I06. Its per-package fingerprint covers `recipes/kernel/` through `factory/data/cache-inputs.yaml`, so a fragment edit rebuilds the kernel and nothing else changes it.
- Fragment content and format, tier lists, `kconfig-check` (merge, lint, resolved/drift), the assertion scripts and
  the module name lists: R04 (B02 consumes them).
- The ebuild and patch: R01 imports, R04 may revise (`-rN`, R03 gate).
- Tier-1 module selection into the initrd: B03. Module install into the rootfs: B04.
- Checking the I2C/DDC invariant on the shipped disc: O06 (B02 checks the build output, O06 the artifact set).

## Design

### Inputs and outputs
Inputs: `recipes/kernel/frag/*.config` (lexical order), `recipes/overlay/sys-kernel/monolith-kernel/`,
`pins/crossdev.lock`, `out/stage/packages.json` (toolchain versions), `out/cache/restore.tsv` and `out/cache/fingerprints.tsv` (I06).
Outputs under `out/kernel/`: `input.config`, `resolved-kernel.config`, `vmlinuz`, `modules/lib/modules/<krel>/`,
`config-drift.txt`, `kernel.json`; the kernel gpkg lands in `out/packages/` for B04. `kernel.json`:
```json
{"schema":1,"mode":"source|cache","fingerprint":"<I06 fingerprint of the kernel cpv>","blob_sha256":"<sha256 or null>","kver":"6.12.80-r8","krel":"6.12.80-i486-monolith",
 "cc_version_text":"…","bzimage_bytes":0,"resolved_sha256":"…","localversion":"-i486-monolith"}
```
Also writes the stage record `out/stage/kernel.json` per the B01 stage contract (exit codes, atomic write).

### Phases (`factory/bin/build-kernel`)
1. **assemble.** `recipes/kernel/tools/kconfig-check merge -o out/kernel/input.config` (R04). B02 adds no merger
   of its own: one merger, one format. Rejected: a B02-private `kconfig-merge.py`, which would drift from R04's.
2. **key.** Moved to I06. The kernel's fingerprint (`out/cache/fingerprints.tsv`, row `sys-kernel/monolith-kernel-*`)
   covers the ebuild, `files/`, any savedconfig and `recipes/kernel/` (the fragments, tier lists and assertions
   inputs), via `sys-kernel/monolith-kernel: [recipes/kernel/]` in `cache-inputs.yaml`. The merged-config hash
   the v0.2 key used is no longer separate: the fragments it is built from are hashed directly. B02 records
   the fingerprint in `kernel.json`. Rejected: a B02-private kernel key (v0.2 `kprofile`), which duplicates I06
   and bypasses its release guard and audit.
3. **restore or build.** B01's `cache restore` already placed the kernel gpkg in `out/packages/` if the
   fingerprint matched (`out/cache/restore.tsv` row `cache:<sha256>`). `iterate`: B02 runs
   `emerge --oneshot --buildpkg` with the `cache emerge-flags` set; the mode is `cache` iff the kernel's
   `restore.tsv` row is `cache:<sha256>` **and** the VDB shows the cpv installed from that binary, otherwise
   `source`. `release`: no restore, no flags, `mode=source`. B02 exports `MONOLITH_KERNEL_CONFIG=/work/kconfig/input.config`
   (a read-only copy); R04's `-r9` ebuild reads it, dies if it is missing, and writes nothing back. The mode is
   B02's own decision, not parsed from emerge output (`build-packages.sh:413-417` depended on English text and the
   label was always `unknown` in CI). After a source build in `iterate` (non-fork), B02 calls `cache save`
   again so the next set holds the new kernel (argument form as in B01 phase 8).
4. **reproducibility env.** Not ported and not added here: the predecessor set no `KBUILD_*` variables, and
   no criterion in this node requires them. B07 decides, from a measured `UTS_VERSION` difference, whether the
   kernel needs `KBUILD_BUILD_TIMESTAMP`, `KBUILD_BUILD_USER` and `KBUILD_BUILD_HOST`; that change would be
   a named fix there (Principle 11).
5. **export.** Install the gpkg into scratch `ROOT=/work/kroot`; copy `boot/vmlinuz` (`cp -L`), gunzip
   `usr/share/monolith-kernel/resolved-kernel.config.gz` to `resolved-kernel.config` (missing is exit 4, as
   `build-packages.sh:424`), copy `lib/modules/<krel>` to `out/kernel/modules/`. Exactly one `<krel>` directory
   must exist, else exit 4 (`build-initrd.sh:232` took `ls | head -1`).
6. **assert.** In order, all run, exit 4 if any fails, one summary line each:
   a. every executable in `recipes/kernel/assert/` is run as `<script> out/kernel/resolved-kernel.config`
      (R04 contract; includes the I2C `=y` check that replaced `verify-resolved-i2c-off.sh`);
   b. `kconfig-check resolved out/kernel/resolved-kernel.config --mode <mode> --expect-gcc <major>` (R04) runs the
      invariants, the Tier-0 ceiling and the authored-vs-resolved DRIFT check; a legitimate difference is waived
      only by an `#@ derived-ok: <reason>` annotation on the fragment line. Output goes to `config-drift.txt`.
      `olddefconfig` can silently flip a forced symbol; the predecessor never noticed;
   c. toolchain: `CONFIG_CC_VERSION_TEXT` must contain the gcc version from `pins/crossdev.lock`. The tracked
      `configs/kernel.config:5` still said gcc 14.3.1 while `crossdev.lock` pinned 15.3.1 — a stale generated file
      the new split makes impossible, and this check keeps it so;
   d. modules: each name in `recipes/kernel/required-modules.txt` (the 23 NIC and netfilter names of
      `build.yml:345`) exists as `<name>.ko*` under the built tree, `-` and `_` treated alike; each name in
      `recipes/kernel/legacy-fbdev-modules.txt` (the 27 of `build.yml:388`) exists, `modinfo -F firmware` exits 0 and
      prints nothing (no-blob doctrine). `KVER` and `LOCALVERSION` come from the built tree and resolved config, not
      from `versions.lock` and the tracked config as in `build.yml:326-327`.
7. **log.** Print the `vmlinuz` size in bytes (the Tier-regime "refund" signal, `build-packages.sh:335`) and record it.

### Interfaces consumed from R04
`recipes/kernel/frag/`, `recipes/kernel/tools/kconfig-check` (`merge`, `resolved`), the `MONOLITH_KERNEL_CONFIG`
ebuild variable, `recipes/kernel/assert/` (executables taking a config path as `$1`), and the list files above.
The fragments are cache inputs through I06's fingerprint, which is why R03 treats them as content-keyed inputs.

## Traps and doctrines preserved
- **D-486-tier-regime:** tier assertions run on the resolved config, where kconfig dependencies can flip a Tier 0
  `=y`. AC-4, AC-5.
- **Principle 9:** no tracked file is written; resolved config is an artifact. AC-1.
- **Principle 5 / DCX-99 / T-resolved-kernel-config-vacuous (cache hit makes the assertion vacuous):** the resolved
  config always comes from the package content, which I06 restores whole, so every assertion runs on a cache hit
  exactly as on a source build; `mode` is recorded truthfully. AC-3, AC-11.
- **No-blob firmware doctrine:** `modinfo -F firmware` empty. AC-6.
- **T-runner-oom:** kernel compile stays `-j1` (ebuild `src_compile`); B02 passes no `MAKEOPTS` or `-j`. AC-1
  asserts the captured emerge command carries neither.
- **D-state-and-no-hidden-stderr:** `modinfo` stderr is shown on failure, as `build.yml:404-413`. AC-6.

## Gate
- **B02-AC-1** — `build-kernel` writes nothing outside `out/` and the scratch `/work`; `git status --porcelain` is empty after the stage. *Verify:* `tests/fast/kernel-no-tracked-writes.test.sh` (dry-run command capture asserts `MONOLITH_KERNEL_CONFIG` points into `/work`, the `:ro` mount, and no `MAKEOPTS` or `-j` in the emerge command); CI `git diff --exit-code` after the stage. *Tier:* fast and slow.
- **B02-AC-2** — `build-kernel` produces `input.config` only through `kconfig-check merge`, and the file is byte-identical on rerun. *Verify:* `tests/fast/kernel-merge.test.sh` (stub `kconfig-check` records its argv; rerun compares bytes). *Tier:* fast.
- **B02-AC-3** — `kernel.json.mode` is `cache` iff `restore.tsv` has a `cache:<sha256>` row for the kernel cpv and the VDB shows it installed from that binary, and `source` otherwise; `release` mode never reads `restore.tsv` or calls `cache`; an absent resolved-config artifact exits 4 in both modes. *Verify:* `tests/fast/kernel-mode.test.sh` (fixture `restore.tsv`, stub `emerge`, stub `cache`). *Tier:* fast.
- **B02-AC-4** — Each executable in `recipes/kernel/assert/` is run against `resolved-kernel.config`; any non-zero exit makes the stage exit 4 after all have run. *Verify:* `tests/fast/kernel-assert-runner.test.sh` (two passing, one failing fixture script). *Tier:* fast.
- **B02-AC-5** — The stage fails when `kconfig-check resolved` reports DRIFT, and runs it with the recorded `mode` and the `crossdev.lock` gcc major. *Verify:* `tests/fast/kernel-drift.test.sh` (stub `kconfig-check` exiting 1, then 0; argv asserted). *Tier:* fast.
- **B02-AC-6** — The module check fails on a missing required module, a missing legacy fbdev module, a module whose `modinfo -F firmware` is non-empty, and a failing `modinfo`; it treats `smc-ultra` and `smc_ultra` alike. *Verify:* `tests/fast/kernel-modules.test.sh` (fixture trees with stub `modinfo`). *Tier:* fast.
- **B02-AC-7** — More than one `lib/modules/<krel>` directory, or none, exits 4. *Verify:* `tests/fast/kernel-modules.test.sh`. *Tier:* fast.
- **B02-AC-8** — *Withdrawn (v0.3):* the key half moved to I06 (I06-AC-3: fingerprint); the toolchain half is B02-AC-12; the check that the kernel's fingerprint covers the fragments is B02-AC-13.
- **B02-AC-9** — In a full run on the pinned builder the stage passes with `mode=source`, then a second run against the cache I06 saved passes with `mode=cache` and identical `resolved_sha256` and `vmlinuz` sha256. *Verify:* CI job `packages`, steps "kernel (cold)" and "kernel (warm)" comparing `out/kernel/kernel.json`. *Tier:* slow.
- **B02-AC-10** — Two `source` builds of the same inputs produce the same `resolved_sha256`; any differing `vmlinuz` bytes are reported to B07 as a known difference with the cause. *Verify:* B07 compare job layer `kernel`. *Tier:* slow.
- **B02-AC-11** — On a cache hit the assertions still judge the restored package: with a fixture where the restored gpkg's resolved config violates an `assert/` script (or lacks `CONFIG_CC_VERSION_TEXT` for the pinned gcc), the stage exits 4 with `mode=cache`; the same gpkg passes when the config is valid. *Verify:* `tests/fast/kernel-cache-hit.test.sh` (fixture `restore.tsv`, stub `emerge`, fixture gpkg contents). *Tier:* fast.
- **B02-AC-12** — The toolchain check fails when `CONFIG_CC_VERSION_TEXT` lacks the `crossdev.lock` gcc version and passes when it has it. *Verify:* `tests/fast/kernel-toolchain.test.sh`. *Tier:* fast.
- **B02-AC-13** — `factory/data/cache-inputs.yaml` lists `recipes/kernel/` for `sys-kernel/monolith-kernel`, and I06's `cache fingerprint` on a fixture changes when one fragment byte changes and not when an unrelated recipe changes. *Verify:* `tests/fast/kernel-fingerprint.test.sh` (calls `cache fingerprint` on a fixture tree). *Tier:* fast.

## RED plan
Tester writes first, all failing for want of the scripts: `kernel-merge` (stub `kconfig-check`, byte-identical
rerun), `kernel-drift` (stub `kconfig-check resolved` reporting DRIFT), `kernel-modules` (fake module tree with one
module declaring firmware), `kernel-mode` (fixture `restore.tsv` rows), `kernel-cache-hit`, `kernel-fingerprint`, `kernel-assert-runner`.
All run without a kernel tree or Docker.

## Risks and open questions
- Drift check strictness: the first slow run may list many legitimate kconfig flips; each needs an
  `#@ derived-ok` reason in R04's fragments. Expect one repair cycle.
- `KBUILD_*` handling in 6.12.80 is from memory of kbuild docs, not verified here; B07 is the arbiter.
- Whether `ROOT=/work/kroot emerge --usepkgonly --nodeps` works with the crossdev wrapper without the full
  sysroot config is unknown; fallback is untarring `image.tar.xz` from the gpkg directly.
- OD-2 does not affect B02.
- A kernel gcc bump (M02) changes the builder digest, hence the global key, by design.
- `SOURCE_DATE_EPOCH` shaped the v0.2 key. It is not in I06's key unless `build-env.yaml` lists it. The kernel embeds a build timestamp, so I06 should list it (or the kernel fingerprint should); unverified, reconcile with I06.
- Two `cache save` calls per run (B01's, then B02's) write two sets. The second is a superset; the first is harmless. B06 may prefer a single save at the end of the job.

## Cost
Slices: (1) merge call, drift call, toolchain check; (2) mode decision, build/export, cache-hit assertions; (3) assertion runner and module checks.
About 3 slices. CI cycles: 2 (cold, warm). The kernel compile at `-j1` sits inside the packages step (74.6 min of the 78 min tag job, measured on the predecessor; the kernel's own share was not measured). On a cache hit the kernel costs the restore plus the assertions, seconds. Money: one gpkg (a few MB) per kernel fingerprint in the cache (I06).
