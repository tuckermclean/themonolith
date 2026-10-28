# B03 — initrd-build

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| B | B02, O01 | B05 | — (feeds MS2) | M |

**Owns:** `factory/bin/build-initrd`, `factory/lib/newc.py`, `factory/lib/busybox_applets.py`,
`factory/lib/initrd_modules.py`, `factory/data/initrd/skel/` (files replacing the inline heredocs),
`factory/data/initrd-applets.required`, `factory/data/initrd-modules-allow-missing.txt`,
`factory/data/budgets.yaml` (initrd entry), `factory/mk/initrd.mk`, `tests/fast/initrd-*.test.sh`,
`tests/fast/init-contract.test.sh`
**Carries from linux-live-iso-factory@b9f533b:** `scripts/build-initrd.sh` (rewritten), the content of its inline
`/etc` heredocs (`:148-211`), `rootfs/init` and `rootfs/usr/share/udhcpc/default.script` (imported by R01; B03
packs them), `configs/initrd-modules.txt` (R04 owns the manifest).
**Study refs:** build.yaml `script.build-initrd` notes (applets executed on host, missing modules WARN,
`ls | head -1`, cpio without `--reproducible`, symlink mtimes, mknod `|| true`), `silent_fallbacks`,
`privileged_or_root_needs`; T-initrd-busybox-missing-applets, T-pivot-root-overlay, T-persist-race;
D-486-minimalism, D-all-static (initrd side), Principle 5.

## Purpose
After B03 the initramfs is produced from files and packages alone: no i486 binary is executed on the build host,
no root is needed, a missing storage driver or applet fails the build instead of a boot on someone's hardware,
and the archive is byte-identical for identical inputs. It stays gzip, a deliberate RAM decision.

## Scope
In:
- `out/themonolith-<ver>.initrd` and its file manifest.
- Deriving the busybox applet set without executing busybox.
- Static-kmod gate, module closure from the R04 manifest, `depmod`.
- A pure-Python deterministic newc cpio writer.
- A contract test on `init` for the milestone and race fixes the oracle depends on.

Out:
- The content and logic of `init` (R01 imports it; boot behaviour is proven by O02-O04).
- The Tier-1 manifest content and the kernel config behind it: R04.
- Kernel and modules: B02. Squashfs and its modules: B04. ISO packing: B05.
- Busybox `savedconfig` content: R01 (profile hash in B01 makes edits take effect).

## Design

### Inputs and outputs
Inputs: `out/kernel/modules/lib/modules/<krel>/` and `out/kernel/kernel.json` (B02); `out/packages/` gpkgs for
`sys-apps/busybox` and `sys-apps/kmod` (B01), installed into scratch `ROOT=/work/iroot` with
`emerge --usepkgonly --nodeps`; the `init` and `default.script` files from R01; `recipes/kernel/initrd-modules.txt`
(R04); `factory/data/initrd/skel/`. Output: `out/themonolith-<ver>.initrd`, `out/initrd.manifest.tsv`
(`path type mode size sha256 target`, sorted `LC_ALL=C`), `out/stage/initrd.json` (B01 stage contract).
Decision: B03 depends on B02 only and takes busybox and kmod from gpkgs, not from B04's sysroot, so it can run in
parallel with B04. Rejected: reading `out/sysroot/bin/busybox` as `build-initrd.sh:23` did.

### Build steps
1. **Gates.** `CONFIG_RD_GZIP=y` must be present in `out/kernel/resolved-kernel.config`, else exit 4: gzip, not
   xz, is chosen so the kernel's decompression window is 32 KB, not ~8 MB, on a 16 MB machine
   (`build-initrd.sh:334-346`). `readelf` must exist (exit 2 otherwise; the predecessor trusted the build when
   neither `readelf` nor `file` was present, `:116`).
2. **busybox.** Copy to `bin/busybox`. `busybox_applets.py` reads the packed `applet_names` string table from the
   ELF (NUL-separated, sorted, double-NUL terminated) and prints the applet list. Busybox is never executed.
   The parser checks the list is sorted and contains `sh`; otherwise exit 4. Symlinks: every applet except
   `busybox` in `bin/`; `init mount umount mdev` also in `sbin/` when present (same set as `:68-84`).
   Decision: parse the table, rejecting `busybox --list` (needs i386 execution on the host, SPEC "no host-executed
   i486 binaries") and rejecting `CONTENTS` symlinks (Gentoo's `make-symlinks` USE is off under `USE="-*"`,
   `make.conf:36`, so they may not exist).
3. **required applets.** `factory/data/initrd-applets.required` lists what `init` and rescue need. Seed from the
   predecessor trap: `dd uname basename tr grep find findfs cat mount umount mkdir mdev wc head tail sleep sed
   switch_root pivot_root`, plus anything `init` calls (the list is hand-maintained; AC-5 fails if a name is
   missing from the derived set, and a second guard checks the name occurs as `\0name\0` in the binary).
4. **kmod.** Copy `bin/kmod` (or `usr/bin/kmod`) from the gpkg root. Static check: no `PT_INTERP` in
   `readelf -lW`; dynamic means exit 4 with the ELF details. Symlink `modprobe depmod insmod rmmod lsmod modinfo`
   to `kmod` (Gentoo busybox ships no modutils applets, T-initrd-busybox-missing-applets).
5. **skeleton.** Copy `factory/data/initrd/skel/` (`etc/passwd group fstab inittab hosts resolv.conf
   iproute2/rt_tables`, the former heredocs), `init` (0755), `usr/share/udhcpc/default.script` (0755, exit 3 if
   absent; the predecessor only warned, `:201`). Directories as `:57` plus `lib/modules`. Device nodes
   `console c5:1 0622`, `null c1:3 0666`, `zero c1:5 0666`, `tty c5:0 0666` are emitted as cpio entries, so no
   `mknod` and no root (the predecessor used `mknod … || true`, `:219-222`).
6. **modules.** `initrd_modules.py` resolves each manifest name (`-` equals `_`) to its closure through
   `modules.dep`. A name found in neither `modules.dep` nor `modules.builtin` is fatal (exit 4) unless listed with
   a reason in `initrd-modules-allow-missing.txt`; a name in `modules.builtin` counts as satisfied (Tier 0).
   Replaces the predecessor's WARN-and-continue (`:294-300`), which let a typo drop a driver silently. The
   `krel` comes from `kernel.json`, not `ls | head -1`. Copy `modules.builtin`, `.builtin.modinfo`, `.order`, run
   the host `depmod -b <initrd-root> <krel>` (kmod index format is stable across versions; the target `depmod`
   is an i486 binary and not executed), ship the manifest as `etc/initrd-modules`. Print module count and the
   number of `pci:` aliases.
7. **archive.** `newc.py` takes the entry list and writes a `070701` archive: entries sorted by path (byte order),
   inode numbers sequential from 1, `nlink` 1 (2 for directories), uid and gid 0, mtime `SOURCE_DATE_EPOCH` for
   every entry including symlinks, devmajor/minor 0, `TRAILER!!!`. Compress with `gzip -9 -n`. Decision: write
   cpio in Python, rejecting GNU cpio `--reproducible` (needs cpio >= 2.14 in the builder, behaviour of inode
   renumbering unverified) and `touch` pre-passes (symlink mtimes were skipped at `:352`).
8. **budget.** Compare the compressed size to `factory/data/budgets.yaml: initrd_compressed_max_bytes`; exceed =
   exit 4. The initial value is the first green build's size + 10 %, set by the implementer with the measurement
   in the PR. Raising it needs a justification line (F05 review checklist). The predecessor documents only
   "~3 MB payload" (`build-initrd.sh:339`) with no gate.

## Traps and doctrines preserved
- **T-initrd-busybox-missing-applets:** required-applet list plus binary-table guard; kmod provides module tools;
  static gate. AC-4, AC-5, AC-6.
- **T-pivot-root-overlay:** the `[init] Executing …` milestone is printed on both the `pivot_root` and the
  `switch_root` path; the oracle matches that string. AC-9.
- **T-persist-race:** `init` keeps the bounded media poll (8 attempts) and the persist device wait. AC-9.
- **D-486-minimalism:** gzip, budget gate, Tier-1 modules only from the manifest. AC-7, AC-8.
- **D-all-static (initrd):** kmod must be static; the initrd has no loader. AC-6.
- **Principle 5:** missing module or input is a failure, not a WARN. AC-3, AC-7, AC-11.
- **No host-executed i486 binaries (SPEC B03 line):** AC-3.

## Gate
- **B03-AC-1** — `newc.py` output is byte-identical for the same entries regardless of input order, source file mtimes, uid/gid or inode numbers, and every header has mtime `SOURCE_DATE_EPOCH`, uid 0, gid 0, sequential inodes. *Verify:* `tests/fast/initrd-newc.test.sh`. *Tier:* fast.
- **B03-AC-2** — The archive decodes with a reference parser and, when `cpio` exists, `gzip -dc | cpio -it` lists every entry; device nodes carry the right major/minor and mode; the stream starts with gzip magic and has no embedded name or mtime. *Verify:* `tests/fast/initrd-newc.test.sh`. *Tier:* fast.
- **B03-AC-3** — `build-initrd` completes on a fixture whose `busybox` and `kmod` are non-executable files (any execution attempt fails the test); a missing busybox, kmod, `init` or `default.script` exits 3. *Verify:* `tests/fast/initrd-no-exec.test.sh`. *Tier:* fast.
- **B03-AC-4** — `busybox_applets.py` extracts the applet list from a synthetic ELF-like blob with the packed table, rejects an unsorted or `sh`-less table with exit 4, and never uses `exec`. *Verify:* `tests/fast/initrd-applets.test.sh`. *Tier:* fast.
- **B03-AC-5** — Every name in `initrd-applets.required` is in the derived applet set and occurs as `\0name\0` in the binary; a fixture without `findfs` exits 4 naming it. *Verify:* `tests/fast/initrd-applets.test.sh`; on the real binary, CI step "initrd gates". *Tier:* fast and slow.
- **B03-AC-6** — A dynamic `kmod` (has `PT_INTERP`) exits 4 and a missing `readelf` exits 2; a static kmod passes and `modprobe depmod insmod rmmod lsmod modinfo` link to it. *Verify:* `tests/fast/initrd-kmod.test.sh` (stub `readelf`); real ELF in CI. *Tier:* fast and slow.
- **B03-AC-7** — A manifest module absent from both `modules.dep` and `modules.builtin` exits 4 and names it; a built-in module and an allow-missing entry with a reason pass; the dependency closure is copied; `krel` from `kernel.json`, and two `lib/modules` dirs do not change the result. *Verify:* `tests/fast/initrd-modules.test.sh` (synthetic `modules.dep`, stub `depmod`). *Tier:* fast.
- **B03-AC-8** — `CONFIG_RD_GZIP` not `y` in the resolved config exits 4; compressed size above `initrd_compressed_max_bytes` exits 4. *Verify:* `tests/fast/initrd-gates.test.sh`. *Tier:* fast.
- **B03-AC-9** — `init` prints `[init] Executing` on both the `pivot_root` success path and the `switch_root` fallback, keeps the bounded boot-media retry loop and the persist `wait_for_device`. *Verify:* `tests/fast/init-contract.test.sh` (greps the imported `init`). *Tier:* fast.
- **B03-AC-10** — Two `build-initrd` runs on the same inputs in separate containers yield the same sha256, and `initrd.manifest.tsv` contains `bin/kmod`, `sbin/modprobe` (target `kmod`), every manifest module's closure, and `init`. *Verify:* CI job `image`, steps "initrd" twice then `cmp`. *Tier:* slow.
- **B03-AC-11** — `build-initrd` needs no root: it passes as an unprivileged user on the fixture. *Verify:* `tests/fast/initrd-no-exec.test.sh` run under `unshare -r` or a non-root runner uid. *Tier:* fast.

## RED plan
Tester writes first (all fail, no implementation exists): `initrd-newc` (two orderings of the same entries must
match; the predecessor `cpio` pipeline cannot be the oracle, so assert header fields directly), `initrd-applets`
(synthetic table, missing `findfs`), `initrd-kmod` (stub `readelf` printing an `INTERP` line), `initrd-modules`
(typo name), `init-contract` (can already pass on the imported `init`; its RED is a mutated copy with the second
`Executing` removed). The synthetic busybox table in `tests/fast/fixtures/initrd/` is built by a tiny generator
script, no binaries committed.

## Risks and open questions
- The packed `applet_names` layout is recalled from busybox sources, not verified against the shipped 6.12-era
  busybox build in this study. If the real binary disagrees, AC-4 passes on the fixture but AC-5 fails in CI;
  fallback is the `busybox-links.tar` Gentoo may install (existence unknown here) or enabling `make-symlinks`.
- Where R01 places `init` and `default.script` is not fixed in SPEC §4.2; `INITRD_SKEL` env points at them.
- `factory/data/initrd-modules-allow-missing.txt` may start non-empty if the broad Tier-1 manifest names modules
  the resolved kernel does not build; each needs a reason.
- Budget has no baseline until the first build.
- Open question for O02: whether `udhcpc` default.script is used at all (build.yaml open question); B03 keeps it.
- OD-2 does not affect the initrd (it is static by construction).

## Cost
Slices: (1) `newc.py` and archive determinism; (2) applets and kmod gates; (3) module closure, skeleton, gates and
contract test. About 3 slices. CI cycles: 2 (the stage runs in the `image` job after B04 inputs exist; it is
seconds of work, so cycles are dominated by the B01 build). No money beyond runner minutes.
