# O06 — artifact-doctrine-checks

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| O | B02, B04, S01 | S05, P02 | MS3 | M |

**Owns:** `oracle/artifacts/check.py` (CLI) and `oracle/artifacts/` (`elf.py`, `squash.py`, `cpio.py`, `checks/*.py`), `oracle/policy/dynamic-allowlist.yaml`, `oracle/policy/required-modules.yaml`, `oracle/policy/kernel-forbidden-y.txt`, `oracle/policy/banned-paths.yaml`, `oracle/bin/check-allowlist-shrink`, `oracle/schemas/artifact-report.schema.json`, `.github/workflows/oracle-artifacts.yml` (reusable), `tests/fast/test_artifacts_*.py`.
**Carries from linux-live-iso-factory@b9f533b:** `scripts/static-audit.sh` (report-only, `--strict` never used), `scripts/verify-resolved-i2c-off.sh` (+ `scripts/tests/verify-resolved-i2c-off.test.sh`), `.github/workflows/build.yml:312-313` (resolved I2C), `:322-354` (23 NIC and netfilter module names), `:360-422` (27 fbdev modules, empty `modinfo -F firmware`), the readelf asserts in the xserver and rl144 ebuilds (`configs/overlay/x11-base/monolith-xserver/*:137-140`; recipe-side, stay with R01).
**Study refs:** doctrine.yaml D-all-static, D-no-dynamic-loading-no-dlopen, D-no-python-on-target, D-bitmap-fonts-no-freetype, D-486-minimalism (`proposed_check` of each); T-freetype-chain, T-resolved-kernel-config-vacuous, T-ddc-i2c-escalation, T-kernel-config-symbol-names, T-unowned-allowlist (shrink-only), D-state-and-no-hidden-stderr; contradictions: `ld-musl-i386.so.1` ships (`scripts/extract-packages.sh:147-157`, `build-packages.sh:384-385`) against "no dynamic loader on the disc"; README.md:127 vs AGENTS.md:24 on static; gaps "static-link claim not checked by boot"; OD-2.

## Purpose
After this node the built artifacts are inspected for the product doctrines that boot tests cannot see: the rootfs is static (or lists exactly which binaries are not), nothing can dlopen, no Python or freetype/fontconfig/Xft reached the disc, and the resolved kernel config has not silently grown I2C. The predecessor wrote the doctrines down and ran `static-audit.sh` as an informational report that never failed, which is why the dynamic util-linux binaries and a shipped musl loader went unnoticed against a doctrine that said the opposite. The check is built so that OD-2 can be answered either way: the allowlist file may be empty.

## Scope
In:
- A host-side checker (`python3 -I oracle/artifacts/check.py`) reading the rootfs squashfs (or an extracted tree), the initrd, the resolved kernel config, the SBOM and `pins/versions.lock`.
- Allowlist and policy file formats, the shrink-only rule, and the CI job.
- ELF analysis with the standard library (no `readelf`, no `file`).
Out:
- Making binaries static (fixing util-linux, iproute2, dhcpcd, procps, tar, gawk): decided by OD-2, executed in R01 recipes.
- Unowned-file gate: S04. Licenses: S02. CVEs: S03. SBOM generation: S01.
- Kernel config fragments and their fast checks (`verify-legacy-fbdev-config`, `verify-netfilter-config`, `verify-nic-zoo-config`): R04. This node checks the *resolved* config and the *built* modules.
- Boot-time proof that perl, sqlite, X and ppp run without dlopen: O02, O05 (runtime smokes).
- The `package.provided` drift check (freetype, mkfontscale, encodings versions equal to the pinned tree): needs the portage tree; no node owns it (see Spec defects).
- Size budgets (bzImage, initrd 6 MB, ISO): recorded in the report but not gated (no node owns the gate; see Spec defects).

## Design

### CLI
```
python3 -I oracle/artifacts/check.py \
  --squashfs rootfs.squashfs | --rootfs DIR \
  [--initrd initrd.img] \
  --kernel-config resolved-kernel.config.gz \
  --expected-kernel 6.12.80-i486-monolith \
  [--sbom bom.cdx.json] [--versions-lock pins/versions.lock] \
  --policy-dir oracle/policy --report artifact-report.json
```
Exit 0: every check passed. 1: at least one finding. 2: missing or unreadable input, malformed policy, or an unreadable compressed module. Every check runs even when an earlier one fails (the predecessor's run-all-then-fail semantics in `attestation.sh`); the report lists all findings.

`--squashfs` extracts to a temp directory with `unsquashfs -n -no-xattrs -d <tmp>`. Device-node and ownership warnings that need root are recorded in the report; any other `unsquashfs` error is exit 2. Rejected: listing-only (cannot read ELF headers); `--rootfs` stays for local use and for B04's tests.

### ELF analysis (`elf.py`)
Stdlib `struct` parser for ELF32/ELF64, little endian: `e_type`, `e_machine`, program headers (`PT_INTERP` path, `PT_DYNAMIC`), the dynamic section (`DT_NEEDED`), section headers when present (`.dynsym`/`.symtab` undefined symbol names, `.modinfo`). A file is ELF if it starts with `\x7fELF`. Rejected: `readelf`/`file` (not guaranteed on the CI host; text parsing is brittle; the predecessor's `file` approach also skipped files without the execute bit). The scan covers every regular file, not only executables, so shared objects and kernel modules are seen.

### Checks
| Check id | Doctrine | Rule |
|---|---|---|
| `elf-machine` | D-static-musl-cross | Every ELF is `EM_386`. No x86-64 host leakage. |
| `elf-interp` | D-all-static | No `PT_INTERP` unless the path is in `dynamic-allowlist.yaml` `interp`. |
| `elf-needed` | D-all-static | Any `DT_NEEDED` must be listed for that file in the allowlist (`needed`, default `libc.so`). |
| `no-shared-objects` | D-all-static, D-no-dynamic-loading | No `*.so`/`*.so.*` file outside `lib/modules/` unless listed under `files`. |
| `musl-loader` | D-all-static | `lib/ld-musl-i386.so.1` exists if and only if at least one `interp` entry exists. An empty allowlist plus a loader is a failure; a non-empty allowlist without the loader is a failure. |
| `no-dlopen` | D-no-dynamic-loading-no-dlopen | No ELF has `dlopen`/`dlsym` among undefined symbols in `.dynsym` or `.symtab`, and no ELF contains the string `libdl`. Combined effect with `no-shared-objects` and `musl-loader`: with no loader and no `.so` nothing can load code. A stripped static binary exposes no symbols; the check says so in the report (`"stripped_static_elves": N`) and relies on the other two. |
| `no-python` | D-no-python-on-target | No file named `python*`, no `usr/lib/python*`, no `*.pyc`, no executable whose `#!` line names `python`; SBOM has no component named `python`, matching `dev-python/*`, or `systemd-utils`; `versions.lock` has no `dev-lang/python:` or `dev-python/` line. Host-side Python (xcbgen, `pcf-fontname`) is not in the rootfs and so is out of scope by construction (`doctrine.yaml` D-no-python-on-target `contradicted_by`). |
| `no-freetype` | D-bitmap-fonts-no-freetype | No file matching `libfreetype*`, `libfontconfig*`, `libXft*`, `libXrender*`, `fonts.conf`; no scalable-font files (`*.ttf`, `*.otf`, `*.pfa`, `*.pfb`); no ELF containing `FT_Init_FreeType`; SBOM has none of `media-libs/freetype`, `media-libs/fontconfig`, `x11-libs/libXft`, `x11-libs/libXrender`, `x11-apps/mkfontscale`, `media-fonts/font-misc-misc`, `media-fonts/font-cursor-misc`. The scalable-font and `libXrender` entries follow `doctrine.yaml` proposed check and "Bitmap-only fonts" statement; both patterns live in `banned-paths.yaml` so a reviewer can change them. |
| `kernel-i2c` | D-486-minimalism, T-ddc-i2c-escalation | In the resolved config none of the symbols in `kernel-forbidden-y.txt` is `=y`; initial list `CONFIG_I2C`, `CONFIG_FB_DDC`, `CONFIG_I2C_ALGOBIT`; and each of `FB_RADEON_I2C`, `FB_3DFX_I2C`, `FB_CYBER2000_DDC`, `FB_NVIDIA_I2C`, `FB_SAVAGE_I2C` is `# ... is not set`; `CONFIG_EXTRA_FIRMWARE` is unset. Missing input is a failure, never a skip (T-resolved-kernel-config-vacuous). |
| `modules-shipped` | T-kernel-config-symbol-names | Every name in `required-modules.yaml` exists as `*.ko`, `*.ko.gz` or `*.ko.xz` under `lib/modules/<expected-kernel>/`, and that directory name equals `--expected-kernel`. The initial list is the 23 NIC and netfilter names of `build.yml:337-341` and the 27 fbdev names of `build.yml:360-422`. Compressed zstd modules are exit 2 (no stdlib decompressor) unless R04 changes the compression. |
| `modules-no-firmware` | (no-blob doctrine) | For every fbdev module in the list, `.modinfo` has no `firmware=` entry (the predecessor's `modinfo -F firmware` empty check). |
| `allowlist-fresh` | T-unowned-allowlist | Every allowlist entry matches a file that exists and is still dynamic (or, for `files`, exists); a stale entry fails with "remove it". An entry whose `expires` date is past fails. |

Findings carry `check`, `path`, `detail`, `doctrine`. The report adds counts, the sizes of bzImage (if `--kernel` is given), initrd and squashfs for information, and the list of stripped static ELFs.

### Allowlist (`oracle/policy/dynamic-allowlist.yaml`)
```yaml
version: 1
interp:                       # files allowed to have PT_INTERP
  - path: usr/bin/mount
    package: sys-apps/util-linux
    needed: [libc.so]         # optional, default [libc.so]
    reason: "upstream ebuild has no static flag for client utilities"
    issue: "https://github.com/<owner>/themonolith/issues/<n>"
    expires: 2027-06-30       # optional; past date fails
files:                        # non-module .so files allowed (the loader itself)
  - path: lib/ld-musl-i386.so.1
    package: sys-libs/musl
    reason: "dynamic loader for the entries above"
    issue: "..."
```
The file may be empty (`interp: []`, `files: []`). OD-2 decides: "make everything static" means the file is empty and `musl-loader` then requires the loader to be absent; "allowlist now" (the SPEC §10 default) means it lists each dynamic binary with a removal issue. The check logic is identical in both cases. `oracle/bin/check-allowlist-shrink --base <path-to-base-file> --head oracle/policy/dynamic-allowlist.yaml` fails when the head adds an entry that the base does not have, or an entry without `reason` and `issue`; it runs in CI from the trusted base revision (SPEC §8). `reason: TODO` or an empty reason is invalid. A helper `check.py --suggest-allowlist` prints candidate entries (path, package from the SBOM, needed) with `reason: TODO` so an implementer never types the list by hand; it exits 1 on purpose.

Initial content is unknown until a built tree is scanned. Evidence for what to expect: README.md:127 names util-linux, iproute2, dhcpcd, procps, tar and gawk as dynamic PIE; `static-audit.sh` names util-linux `mount`, `agetty`, `mountpoint`; RELEASE-READINESS.md:108-118 says `/etc/inittab` spawns util-linux `agetty`. Whether the squashfs currently contains zero dynamic ELFs is unknown from the repository alone (`doctrine.yaml` D-all-static).

### CI
`oracle-artifacts.yml` (reusable, `workflow_call`) downloads the squashfs, initrd, resolved kernel config and SBOM from B06's run artifacts, runs `check.py` on the pinned runner label with `squashfs-tools`, uploads `artifact-report.json` and writes a summary table. A second job `allowlist-shrink` runs the shrink check on PRs from the base revision. The hook into the B06 pipeline is the same one-line `uses:` addition as O02 (see its Spec defects).

## Traps and doctrines preserved
- **D-all-static:** the rootfs is declared static but some binaries are PIE and the loader ships. Prevented by O06-AC-1/AC-2/AC-3 (no `PT_INTERP` outside the allowlist, loader iff allowlisted, stale entries fail) and by O06-AC-4 (the allowlist can only shrink).
- **D-no-dynamic-loading-no-dlopen:** perl XS `.so`, sqlite extensions, X modules, ppp plugins. Prevented by O06-AC-5 (no `.so` outside `lib/modules`, no `dlopen` symbols, no `libdl`) and by the loader rule; the runtime smokes in O02/O05 are the second line.
- **D-no-python-on-target:** python can enter via `systemd-utils[tmpfiles]`, nmap, man-db, usbutils or xcb-proto. Prevented by O06-AC-6.
- **D-bitmap-fonts-no-freetype / T-freetype-chain:** font.eclass pulls mkfontscale which pulls freetype. Prevented by O06-AC-7 (files and SBOM). The version-drift half of the trap (package.provided versions equal the pinned tree) is not covered here.
- **D-486-minimalism / T-ddc-i2c-escalation:** FB_DDC `select` escalates I2C into bzImage. Prevented by O06-AC-8.
- **T-resolved-kernel-config-vacuous:** the check read a stale file on binpkg cache hits. Prevented by consuming the B02 build artifact named by `--kernel-config` and failing when it is missing or empty (O06-AC-8, AC-10).
- **T-kernel-config-symbol-names:** symbols silently dropped by `olddefconfig` leave no `.ko`. Prevented by O06-AC-9.
- **T-unowned-allowlist:** allowlists drift upward. Prevented by O06-AC-4 for this node's allowlist.
- **D-state-and-no-hidden-stderr:** `static-audit.sh` reported and exited 0; its `find ... 2>/dev/null` and `file ... || continue` could drop files silently. Prevented by O06-AC-10 (missing/empty input is exit 2; checker never skips unreadable files without a finding).

## Gate
- **O06-AC-1** — `elf-interp` fails on any ELF with `PT_INTERP` whose path is not an `interp` entry, passes with an empty allowlist on a tree of static ELFs, and reports the offending path and `DT_NEEDED` list. *Verify:* `tests/fast/test_artifacts_elf.py` builds ELF files in a temp tree with `struct` (static, PIE with interp, ET_DYN with no interp) and runs the check. *Tier:* fast.
- **O06-AC-2** — `musl-loader` fails when `lib/ld-musl-i386.so.1` exists and the `interp` list is empty, and when the list is non-empty and the loader is absent; passes in the two consistent states. *Verify:* `tests/fast/test_artifacts_checks.py::test_loader_matrix` (four cases). *Tier:* fast.
- **O06-AC-3** — `allowlist-fresh` fails on an `interp`/`files` entry whose path is absent or no longer dynamic, and on an `expires` date earlier than today (the check takes `--today` for tests). *Verify:* `tests/fast/test_artifacts_checks.py::test_stale_entries`, `::test_expired_entry`. *Tier:* fast.
- **O06-AC-4** — `oracle/bin/check-allowlist-shrink` fails when head has an entry base lacks, when an entry lacks `reason` or `issue`, or when `reason` is `TODO`/empty; it passes when head is a subset of base; the CI job runs it from the PR's base revision. *Verify:* `tests/fast/test_artifacts_allowlist.py`; `tests/fast/test_oracle_workflow.py::test_allowlist_job_uses_base`. *Tier:* fast.
- **O06-AC-5** — `no-shared-objects` fails on a `*.so*` outside `lib/modules/` that is not under `files`; `no-dlopen` fails on an ELF whose `.dynsym` or `.symtab` has an undefined `dlopen` or `dlsym` and on any ELF containing `libdl`; stripped static ELFs are counted in the report. *Verify:* `tests/fast/test_artifacts_checks.py::test_so_and_dlopen` with synthetic ELFs and a negative control that must fail. *Tier:* fast.
- **O06-AC-6** — `no-python` fails on a `python3` binary, a `usr/lib/python3.12/` directory, a `*.pyc`, an executable whose first line is `#!/usr/bin/env python3`, an SBOM component `dev-python/xcb-proto` or `systemd-utils`, and a `versions.lock` line `dev-lang/python:3.12:...`; passes on a tree with a perl script and a host-only Python tool absent. *Verify:* `tests/fast/test_artifacts_checks.py::test_no_python`. *Tier:* fast.
- **O06-AC-7** — `no-freetype` fails on `libfreetype.a`, `libXft.so`, `fonts.conf`, a `.ttf` file, an ELF containing `FT_Init_FreeType`, and an SBOM component `media-libs/freetype` or `x11-apps/mkfontscale`; passes on a tree with `terminus` PCF fonts, `fonts.dir` and `fonts.alias`. *Verify:* `tests/fast/test_artifacts_checks.py::test_no_freetype`. *Tier:* fast.
- **O06-AC-8** — `kernel-i2c` fails when the resolved config (plain or gzip) has `CONFIG_I2C=y`, `CONFIG_FB_DDC=y`, `CONFIG_I2C_ALGOBIT=y`, any of the five DDC/I2C bools set to `y` or `m`, or `CONFIG_EXTRA_FIRMWARE` set; passes on a clean config; a missing, empty or unreadable file is exit 2 with a message that names the artifact and states the invariant was not proven. *Verify:* `tests/fast/test_artifacts_kernel.py` (ports the 16 assertions of `scripts/tests/verify-resolved-i2c-off.test.sh`: missing artifact, `I2C=y` plain and gz, clean plain and gz, mode label). *Tier:* fast.
- **O06-AC-9** — `modules-shipped` passes only when every name in `required-modules.yaml` exists under `lib/modules/<expected-kernel>/` (plain, `.gz`, `.xz`) and the directory name equals `--expected-kernel`; `modules-no-firmware` fails on a module whose `.modinfo` has `firmware=`. *Verify:* `tests/fast/test_artifacts_kernel.py::test_modules_shipped`, `::test_firmware_blob` with generated ET_REL files containing a `.modinfo` section. *Tier:* fast.
- **O06-AC-10** — Input errors cannot pass: no `--squashfs`/`--rootfs`, an empty tree, a zero-byte SBOM or config, a zstd-compressed module, or an `unsquashfs` failure other than root-only warnings exits 2 and writes no `pass` verdict; a tree with zero ELF files is an error, not a pass. *Verify:* `tests/fast/test_artifacts_cli.py`. *Tier:* fast.
- **O06-AC-11** — `elf-machine` fails on an `EM_X86_64` ELF anywhere in the rootfs or initrd and `elf-interp` also scans the unpacked initrd (gzip/xz newc cpio via the standard library). *Verify:* `tests/fast/test_artifacts_cpio.py` (a generated newc archive with an x86-64 ELF and an interp ELF). *Tier:* fast.
- **O06-AC-12** — The checker uses only the standard library plus PyYAML, never shells out except `unsquashfs`, and `oracle/artifacts/` contains no `2>/dev/null`. *Verify:* O01's lint test extended to `oracle/artifacts/` (`tests/fast/test_oracle_lint.py`). *Tier:* fast.
- **O06-AC-13** — On the B06 ISO's rootfs, `check.py` exits 0 with the committed allowlist; the report lists every dynamic ELF found (equal to the allowlist) and the loader state. *Verify:* CI job `oracle-artifacts / check` on a B06 run. *Tier:* slow.

## RED plan
Tester commits (all failing because the modules and policy files do not exist): `test_artifacts_elf.py` and a shared `tests/fast/_elfgen.py` that writes minimal ELF32 files with `struct`; `test_artifacts_checks.py` (loader matrix, stale and expired entries, `.so`/dlopen, python, freetype); `test_artifacts_kernel.py` (the 16 ported I2C assertions plus modules/firmware); `test_artifacts_allowlist.py`; `test_artifacts_cli.py` (input errors); `test_artifacts_cpio.py`. Each check has a negative control that must fail, so a check that always passes cannot satisfy the RED-to-GREEN transition.

## Risks and open questions
- Hardest: OD-2 and the initial allowlist. The default is "allowlist now, each entry with an issue to remove it"; entries and issues cannot be written before a rootfs is scanned (`--suggest-allowlist`). If the answer is "zero", util-linux, iproute2, dhcpcd, procps, tar and gawk must first be fixed in R01 or the check fails MS3.
- A stripped static binary hides `dlopen`. The check says so and leans on loader and `.so` absence; that is a real limit, not a proof. A truly static musl binary linking `dlopen` is a stub that fails at runtime.
- Sqlite load-extension: no ELF-level signal is certain. Whether the rc1 `sqlite3` binary contains the string `load_extension` was not verified from the study; a guest-side check (`sqlite3 :memory: "select load_extension('x')"` must say not authorized / no such function) belongs in the O02 smoke suite or G05. Left open.
- Scalable-font and `libXrender` bans are this spec's reading of the doctrine, not statements in the study beyond `proposed_check`. Reviewer may narrow `banned-paths.yaml`.
- `unsquashfs` needs `squashfs-tools` on the runner and extracts the full tree (size unknown; likely tens of MB).
- The `required-modules.yaml` list duplicates R04's lists; the two should be generated from one source. Until R04 defines one, this file wins for the oracle.
- Whether Tier-1 modules appear both in the initrd and the squashfs is not established; the check is on the squashfs path (as the predecessor's was on the sysroot) and optionally the initrd.

## Cost
Three to four agent slices: (1) ELF/cpio/squashfs libraries and fakes; (2) static, dlopen, python, freetype checks; (3) kernel and module checks, policy files, shrink check; (4) CI job, first-run allowlist generation. One or two CI cycles on a B06 ISO. Runner time is seconds to a minute. No paid services.

## Spec defects found
- graph.yaml O06 deps `[B02, B04]` omit S01: the python and freetype checks use the SBOM component list. Either S01 is added as a dependency, or the SBOM checks are optional when `--sbom` is absent (this design makes them skipped *and reported as skipped*, not passed).
- SPEC §3 assigns D-bitmap-fonts-no-freetype to "O06, S01" and D-no-python-on-target to O06 only; no node owns the `package.provided` drift check (`doctrine.yaml` T-freetype-chain `proposed_regression_check`), nor the bzImage/initrd size-growth gates of D-486-minimalism. Suggest R01 or I05 for the drift check and B05 for sizes.
- SPEC §8 protected paths do not include `oracle/policy/`. The dynamic allowlist and banned-paths file define what the oracle accepts; consider adding `oracle/policy/` to the protected list, mirroring `supplychain/policy/`.
- SPEC §3 states D-all-static is "today untrue" and OD-2 decides; the graph has no node that makes it true. If OD-2 chooses "make everything static", a recipe node or phase-R work item is missing.
