# B02 — kernel-build

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| B | B01, R04 | B03, B04, B05, O06 | — (feeds MS2) | M |

**Owns:** `factory/bin/build-kernel`, `factory/lib/kernel-assert.sh`, `factory/mk/kernel.mk`, `tests/fast/kernel-*.test.sh`,
`tests/fast/fixtures/kernel/`
**Carries from linux-live-iso-factory@b9f533b:** the export logic of `scripts/build-packages.sh:326-338,401-432`
(rewritten), `scripts/verify-resolved-i2c-off.sh` (moves to R04's assertion set), the module assertions inlined in
`.github/workflows/build.yml:323-423` (moved here as code with R04-owned lists). The predecessor's `CONFIGS_DIR`
read-write mount (`Makefile:318`) is dropped.
**Study refs:** build.yaml `script.build-packages` (config overwrite, FAILURE MASKING, kernel build mode),
`script.verify-resolved-i2c-off`, contradictions (mode label always `unknown`; kernel.config stale gcc 14 text);
workflows.yaml `job.build.build` ci_assertions `assert.i2c-off`, `assert.nic-modules`, `assert.fbdev-modules`;
D-486-tier-regime, Principles 5 and 9.

## Purpose
After B02 the kernel is built (or restored) from authored fragments only, and the resolved `.config`, `vmlinuz`
and module tree are emitted as artifacts under `out/kernel/`, never written into the repo. Every assertion the
predecessor ran in CI YAML runs here as code against the resolved config and the modules actually built, with the
build mode known rather than guessed from emerge's English output.

## Scope
In:
- Assembling the kernel input config from `recipes/kernel/frag/` with R04's `kconfig-check merge`.
- Building or restoring `sys-kernel/monolith-kernel` with its own cache key.
- Exporting `vmlinuz`, the resolved config, the `/lib/modules/<krel>` tree, `kernel.json`.
- Running R04's assertion scripts against the resolved config and the module-presence/firmware checks against the
  built modules.

Out:
- Fragment content and format, tier lists, `kconfig-check` (merge, lint, resolved/drift), the assertion scripts and
  the module name lists: R04 (B02 consumes them).
- The ebuild and patch: R01 imports, R04 may revise (`-rN`, R03 gate).
- Tier-1 module selection into the initrd: B03. Module install into the rootfs: B04.
- Checking the I2C/DDC invariant on the shipped disc: O06 (B02 checks the build output, O06 the artifact set).

## Design

### Inputs and outputs
Inputs: `recipes/kernel/frag/*.config` (lexical order), `recipes/overlay/sys-kernel/monolith-kernel/`,
`pins/crossdev.lock`, `out/stage/packages.json` (for the profile hash and toolchain versions).
Outputs under `out/kernel/`: `input.config`, `resolved-kernel.config`, `vmlinuz`, `modules/lib/modules/<krel>/`,
`config-drift.txt`, `kernel.json`; the kernel gpkg lands in `out/packages/` for B04. `kernel.json`:
```json
{"schema":1,"mode":"source|cache","key":"<tree>/<kprofile>","kver":"6.12.80-r8","krel":"6.12.80-i486-monolith",
 "cc_version_text":"…","bzimage_bytes":0,"resolved_sha256":"…","localversion":"-i486-monolith"}
```
Also writes the stage record `out/stage/kernel.json` per the B01 stage contract (exit codes, atomic write).

### Phases (`factory/bin/build-kernel`)
1. **assemble.** `recipes/kernel/tools/kconfig-check merge -o out/kernel/input.config` (R04). B02 adds no merger
   of its own: one merger, one format. Rejected: a B02-private `kconfig-merge.py`, which would drift from R04's.
2. **key.** `kprofile = first16(sha256(profile_hash ‖ sha256(input.config) ‖ sha256(ebuild + files/) ‖ gcc ver ‖
   binutils ver ‖ SOURCE_DATE_EPOCH))`. Store key: `binpkg <tree>/<kprofile>/<cpv>.gpkg.tar`. Decision: the config
   hash is part of the key, replacing the predecessor's hand `-rN` revbump discipline for config-only edits
   (the stale-binpkg trap named in `savedconfig-cache.sh:9-10`). B01 never restores this prefix.
3. **restore or build.** `iterate`: `store get`; exit 3 is a miss, other non-zero is fatal; hit means
   `emerge --usepkgonly --oneshot`, `mode=cache`. Miss, or `release` mode, builds: `emerge --oneshot --buildpkg`
   (no `--usepkg`), `mode=source`. B02 exports `MONOLITH_KERNEL_CONFIG=/work/kconfig/input.config` (a read-only
   copy); R04's `-r9` ebuild reads it, dies if it is missing, and writes nothing back. The mode is
   B02's own decision, not parsed from emerge output (`build-packages.sh:413-417` depended on English text and the
   label was always `unknown` in CI). After a source build, save to the store (iterate, non-fork).
4. **reproducibility env.** B02 generates `etc/portage/env/kernel-repro.conf` and a `package.env` line in the
   sysroot portage dir (generated, not tracked) exporting `KBUILD_BUILD_TIMESTAMP` (UTC from
   `SOURCE_DATE_EPOCH`), `KBUILD_BUILD_USER=monolith`, `KBUILD_BUILD_HOST=monolith`. Kbuild takes these three, not
   `SOURCE_DATE_EPOCH`, for `UTS_VERSION` (unverified for 6.12; B07 will show it).
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
B02 keeps the merged-config hash in its cache key, which is why R03 treats the fragments as content-keyed inputs.

## Traps and doctrines preserved
- **D-486-tier-regime:** tier assertions run on the resolved config, where kconfig dependencies can flip a Tier 0
  `=y`. AC-4, AC-5.
- **Principle 9:** no tracked file is written; resolved config is an artifact. AC-1.
- **Principle 5 / DCX-99 (cache hit makes the assertion vacuous):** the resolved config always comes from the
  package content, in both modes, and `mode` is recorded truthfully. AC-3.
- **No-blob firmware doctrine:** `modinfo -F firmware` empty. AC-6.
- **T-runner-oom:** kernel compile stays `-j1` (ebuild `src_compile`); B02 passes no `MAKEOPTS` or `-j`. AC-1
  asserts the captured emerge command carries neither.
- **D-state-and-no-hidden-stderr:** `modinfo` stderr is shown on failure, as `build.yml:404-413`. AC-6.

## Gate
- **B02-AC-1** — `build-kernel` writes nothing outside `out/` and the scratch `/work`; `git status --porcelain` is empty after the stage. *Verify:* `tests/fast/kernel-no-tracked-writes.test.sh` (dry-run command capture asserts `MONOLITH_KERNEL_CONFIG` points into `/work`, the `:ro` mount, and no `MAKEOPTS` or `-j` in the emerge command); CI `git diff --exit-code` after the stage. *Tier:* fast and slow.
- **B02-AC-2** — `build-kernel` produces `input.config` only through `kconfig-check merge`, and the file is byte-identical on rerun. *Verify:* `tests/fast/kernel-merge.test.sh` (stub `kconfig-check` records its argv; rerun compares bytes). *Tier:* fast.
- **B02-AC-3** — `kernel.json.mode` is `cache` iff a gpkg was restored from the store and `source` otherwise; `release` mode never reads the store; an absent resolved-config artifact exits 4 in both modes. *Verify:* `tests/fast/kernel-mode.test.sh` (stub `store`, stub `emerge`). *Tier:* fast.
- **B02-AC-4** — Each executable in `recipes/kernel/assert/` is run against `resolved-kernel.config`; any non-zero exit makes the stage exit 4 after all have run. *Verify:* `tests/fast/kernel-assert-runner.test.sh` (two passing, one failing fixture script). *Tier:* fast.
- **B02-AC-5** — The stage fails when `kconfig-check resolved` reports DRIFT, and runs it with the recorded `mode` and the `crossdev.lock` gcc major. *Verify:* `tests/fast/kernel-drift.test.sh` (stub `kconfig-check` exiting 1, then 0; argv asserted). *Tier:* fast.
- **B02-AC-6** — The module check fails on a missing required module, a missing legacy fbdev module, a module whose `modinfo -F firmware` is non-empty, and a failing `modinfo`; it treats `smc-ultra` and `smc_ultra` alike. *Verify:* `tests/fast/kernel-modules.test.sh` (fixture trees with stub `modinfo`). *Tier:* fast.
- **B02-AC-7** — More than one `lib/modules/<krel>` directory, or none, exits 4. *Verify:* `tests/fast/kernel-modules.test.sh`. *Tier:* fast.
- **B02-AC-8** — The toolchain check fails when `CONFIG_CC_VERSION_TEXT` lacks the `crossdev.lock` gcc version; the cache key changes when any of: one fragment byte, the ebuild, the patch, the gcc version, `SOURCE_DATE_EPOCH` changes. *Verify:* `tests/fast/kernel-key.test.sh`. *Tier:* fast.
- **B02-AC-9** — In a full run on the pinned builder the stage passes with `mode=source`, then a second run against the saved cache passes with `mode=cache` and identical `resolved_sha256` and `vmlinuz` sha256. *Verify:* CI job `packages`, steps "kernel (cold)" and "kernel (warm)" comparing `out/kernel/kernel.json`. *Tier:* slow.
- **B02-AC-10** — Two `source` builds of the same inputs produce the same `resolved_sha256`; any differing `vmlinuz` bytes are reported to B07 as a known difference with the cause. *Verify:* B07 compare job layer `kernel`. *Tier:* slow.

## RED plan
Tester writes first, all failing for want of the scripts: `kernel-merge` (stub `kconfig-check`, byte-identical
rerun), `kernel-drift` (stub `kconfig-check resolved` reporting DRIFT), `kernel-modules` (fake module tree with one
module declaring firmware), `kernel-mode` (stub store returning 3, 0 and 5), `kernel-assert-runner`.
All run without a kernel tree or Docker.

## Risks and open questions
- Drift check strictness: the first slow run may list many legitimate kconfig flips; each needs an
  `#@ derived-ok` reason in R04's fragments. Expect one repair cycle.
- `KBUILD_*` handling in 6.12.80 is from memory of kbuild docs, not verified here; B07 is the arbiter.
- Whether `ROOT=/work/kroot emerge --usepkgonly --nodeps` works with the crossdev wrapper without the full
  sysroot config is unknown; fallback is untarring `image.tar.xz` from the gpkg directly.
- OD-2 does not affect B02.
- A kernel gcc bump (M02) changes every kernel key by design.

## Cost
Slices: (1) merge call, drift call, key; (2) restore/build/export with stub store; (3) assertion runner and module checks.
About 3 slices. CI cycles: 2 (cold, warm); the cold kernel compile at `-j1` is part of the B01 job length
(duration unmeasured in the study). Money: one gpkg (a few MB) per kernel key in the store.
