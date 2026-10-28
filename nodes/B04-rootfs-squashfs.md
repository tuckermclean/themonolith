# B04 — rootfs-squashfs

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| B | B01, B02, P06 | B05 | — (feeds MS1) | L |

**Owns:** `factory/bin/build-rootfs`, `factory/lib/rootfs_manifest.py`, `factory/lib/index-fonts.sh`,
`factory/lib/pcf-fontname.py`, `factory/lib/tree-contract.sh`, `factory/data/sysroot-exclude.txt`,
`factory/data/stamp-files.list`, `factory/data/stamp/` (version-stamped templates),
`factory/data/tree-contract.txt`, `factory/mk/rootfs.mk`, `tests/fast/rootfs-*.test.sh`,
`tests/fast/pcf-fontname.test.sh`, `tests/fast/fixtures/rootfs/`
**Carries from linux-live-iso-factory@b9f533b:** `scripts/build-rootfs.sh` (ported whole, including the ~500 lines of
`/etc` and `init.d` heredocs, which stay in B04 until R05 lands; B04-AC-14 then deletes the generators for the files R05
moved), `scripts/extract-packages.sh` (the
`--usepkgonly` install idea, `:56-135`), the sysroot rsync exclude list (`build-packages.sh:346-376`, duplicated in
`extract-packages.sh:114-135`), `scripts/pcf-fontname.py` and its test, `scripts/static-audit.sh` (replaced by
manifest columns, forced by B04-AC-4/AC-5), the musl loader block (`build-packages.sh:378-392`, `extract-packages.sh:141-157`).
**Study refs:** build.yaml `script.build-rootfs`, `script.extract-packages` (dnsmasq recovery, config drift
between the two scripts), `script.static-audit`, contradictions (static doctrine vs loader copy; stale `make extract`
hint; HOME_URL to S3); supplychain.yaml `script.check-unowned` (allowlist is a contract with this stage);
T-acct-user-dnsmasq-race, T-keep-going-hides-drops, T-makewhatis-oom, T-mksquashfs-sde, T-rcK-no-poweroff,
T-console-home; D-all-static, D-no-dynamic-loading-no-dlopen, D-hand-authored-rootfs-files-owned, OD-2.

## Purpose
After B04 the root filesystem is assembled from the package set plus the predecessor's hand-written files (ported, until R05 moves them into a package), in a clean root, so the same gpkgs always
give the same tree. It ships as a deterministic squashfs plus a manifest recording every path with its owning
package (or the named stamp that wrote it, or `unowned` for a ported hand-written file that S04's allowlist covers) and the linkage facts of every ELF. That manifest is what S01, S04 and
O06 judge, whichever way OD-2 is decided.

## Scope
In:
- Installing the locked set from `out/packages/` (B01 gpkgs plus the B02 kernel gpkg) into a clean root.
- Cleanup (one exclude list), version-stamped files, font index, whatis database, VDB normalisation.
- The deterministic `themonolith-<ver>.squashfs` and `out/rootfs.manifest.tsv`.
- A tree contract check for rc, inittab and console content that the oracle depends on.

Out:
- Moving the content of `/etc`, `init.d`, inittab, `monolith-console`, profile scripts into `monolith-base`: R05.
  B04 does not depend on R05; it writes these files itself as the predecessor did and carries the predecessor's
  allowlist (S04 migrates it, 103 entries), recording each such file as `unowned`. After R05 merges, B04-AC-14
  removes the generators.
- The unowned allowlist and the gate: S04 creates the allowlist and owns the gate; R05 shrinks the list.
- Judging static linkage and the loader allowlist: O06. SBOM: S01.
- Kernel modules content: B02 builds them, B04 only installs the kernel gpkg.
- Initrd: B03. ISO: B05.

## Design

### Inputs and outputs
Inputs: `out/packages/` (read, rw mount because portage rewrites the index), `out/stage/packages.cpv.tsv`,
`out/kernel/kernel.json`, `recipes/portage/{world}`, `pins/versions.lock`, `supplychain/policy/unowned-allowlist.yaml` (S04's; read only for the stamp cross-check).
Outputs: `out/themonolith-<ver>.squashfs` (mode 0644), `out/rootfs.manifest.tsv`, `out/stage/rootfs.json`
(B01 stage contract; includes `unowned` count and `dynamic_elf` count). The unpacked tree `out/rootfs/` is kept
for local use and not uploaded by CI.

### Steps (`factory/bin/build-rootfs`)
1. **seed.** `factory/lib/sysroot-seed.sh` (B01) into the clean root `/work/sysroot` (`root`, `portage`, `games`,
   `gamestat`), as the predecessor seeded `build-packages.sh:100-117`.
2. **install.** Pass 1: `acct-group/*` and `acct-user/*` with `--jobs=1`. Pass 2: the atom set (world atoms at locked
   versions, plus `sys-kernel/monolith-kernel` at `kernel.json.kver`) with
   `emerge --usepkgonly --root=/work/sysroot --root-deps=rdeps --with-bdeps=n`. **No `--keep-going`**; no
   `--nodeps` force-install (the dnsmasq patch at `extract-packages.sh:91-107`, which only warned, is gone). Then
   `verify_complete.py` (B01) against the new root's VDB; missing or wrong-version atom is exit 4.
   Decision: install from gpkgs into a clean root, rejecting the predecessor's default path of rsyncing the live
   build ROOT (`build-packages.sh:340-376`). The live ROOT cannot cross a CI job boundary and carries state from
   crossdev and prior runs; a clean root depends on the gpkg set only. `extract-packages.sh` proved this path
   works (CI used it before the optimisation), so this is a port of that path; the switch from the default path is
   forced by the `packages`/`image` job split in B06 and by AC-1.
3. **cleanup.** `rsync -a --exclude-from=factory/data/sysroot-exclude.txt /work/sysroot/ /work/rootfs/`. The list is
   the single source of truth (the predecessor kept two copies "in sync" by comment): `usr/include/`,
   `usr/i486-linux-musl/`, `usr/bin/i486-linux-musl-*`, `etc/portage/`, `usr/lib/pkgconfig/`,
   `usr/lib/lib{c,m,pthread,dl,rt,resolv,util,xnet,crypt}.a`, `usr/lib/{crt1,Scrt1,rcrt1,crti,crtn}.o`,
   `lib/libssp_nonshared.a`, and `usr/share/monolith-kernel/` (the resolved-config proof now lives in B02's
   artifact, `build-rootfs.sh:72`). Decompress `*.bz2` man pages with `bunzip2`; failure is fatal (mandoc is built
   without bz2, `build-packages.sh:391-395` hid errors).
4. **hand-written files (ported).** The heredoc blocks of `build-rootfs.sh` that write `/etc`, `init.d` and `/root` files run as in the predecessor, from a single function per file group, and their output rows are `unowned` in the manifest. This step is deleted file by file as R05 moves each one (B04-AC-14). Rejected: waiting for R05 (the first attested build must not depend on a parallel node).
5. **stamps.** For each path in `factory/data/stamp-files.list`, render `factory/data/stamp/<path>` replacing
   `@BUILD_VERSION@` and `@HOME_URL@`: initial list `etc/monolith-release`, `etc/os-release`, `etc/issue`,
   `etc/motd`. These four are release-tag files and stay generated even after R05 (R05, "Stays generated"). `HOME_URL` comes from env `MONOLITH_HOME_URL`; no vendor host may appear (the
   predecessor hard-coded the S3 bucket, `build-rootfs.sh:266`). Its value waits on OD-1.
6. **fonts.** `index-fonts.sh` reads each Terminus PCF's `FONT` property via `pcf-fontname.py`, writes `fonts.dir`,
   writes the `fonts/monolith` alias dir (`fixed variable fixed-bold heading` to Terminus XLFDs,
   `build-rootfs.sh:~120-145`), and fails if any aliased XLFD is missing from `fonts.dir`. Unlike the predecessor,
   an unreadable PCF, a missing fonts dir or a missing script is exit 4, not a warning (`:117`), and per-file stderr is
   shown. Bitmap-only; no freetype involved (D-bitmap-fonts-no-freetype).
7. **whatis.** Host `makewhatis <rootfs>/usr/share/man` after all packages are in; failure is exit 4 (was a
   warning, `:714`). It runs at build time only; `etc/init.d/*` must not call it (T-makewhatis-oom).
8. **VDB normalisation** (implemented after MS2, B04-AC-11; no reproducibility claim is made before B07). Under `var/db/pkg/*/*/`, set `BUILD_TIME` to `SOURCE_DATE_EPOCH` and `COUNTER` to the
   1-based index in sorted-cpv order. Everything else in the VDB is left as installed (S01 and S04 read it).
   Anything still volatile is a B07 known difference.
9. **loader rule (OD-2 neutral).** After the tree is final, `rootfs_manifest.py` finds every ELF with `PT_INTERP`.
   If there is one or more, replace the loader symlink (`lib/ld-musl-i386.so.1`, dangling to a crossdev path in the
   predecessor) with a regular copy of `usr/lib/libc.so`. If there are none, delete `lib/ld-musl-i386.so.1` and
   `usr/lib/libc.so`. The loader ships if and only if something needs it, so the choice made under OD-2 never needs
   a B04 change, and the manifest names every dependent.
10. **clamp.** `find <tree> -exec touch -h -d @$SOURCE_DATE_EPOCH {} +` so `mandoc.db` and pages share an mtime.
11. **manifest.** `rootfs.manifest.tsv`, header line `#schema=1`, then one row per path, sorted `LC_ALL=C`:
    `path type mode uid gid size sha256 target owner etype interp needed`. `type` is `f d l`; `sha256` for regular
    files; `target` for symlinks; `owner` is the cpv from the VDB `CONTENTS` (`obj sym dir` lines), else
    `stamp:<path>`, else `unowned`. For every ELF, regardless of exec bit (the predecessor's `find -perm -u+x` missed
    `.so` files, `static-audit.sh:107`): `etype` is `EXEC` or `DYN`, `interp` the `PT_INTERP` string or `-`, `needed`
    the comma-joined `DT_NEEDED` list or `-`. Parsed from `readelf -lW -dW` (host binutils reads i386 ELF).
12. **squashfs.** Require `mksquashfs -version` >= 4.5 (exit 2 otherwise), export `SOURCE_DATE_EPOCH`, run
    `mksquashfs <tree> <out> -comp gzip -b 131072 -no-xattrs -noappend -quiet`. Never pass `-all-time` or
    `-mkfs-time` (4.5+ takes both from the environment; passing them is an error, T-mksquashfs-sde). gzip stays: low
    memory on the i486. `chmod 0644`.
13. **tree contract.** `tree-contract.sh` checks `factory/data/tree-contract.txt` lines `path|contains|regex` or
    `path|absent|regex` against the final tree. Initial lines: `etc/init.d/rcK|contains|reboot -f`,
    `etc/init.d/rcK|contains|poweroff -f`, `etc/inittab|contains|^l6:6:wait:/etc/init.d/rcK`,
    `etc/inittab|contains|^l0:0:wait:/etc/init.d/rcK`, `usr/sbin/monolith-console|contains|export HOME=/root USER=root LOGNAME=root`,
    `etc/init.d/rcS|absent|makewhatis`. These files come from the ported heredocs until R05 moves them into `monolith-base`; B04 only proves they arrived.
14. The predecessor's `static-audit.sh` is dropped (informational only, `date -Iseconds` made it irreproducible,
    `static-audit.sh:19-23` documented the doctrine violation). The manifest columns replace it; O06 is the gate.

## Traps and doctrines preserved
- **T-keep-going-hides-drops / T-acct-user-dnsmasq-race:** no `--keep-going`, serial acct pass, VDB completeness,
  no silent force-install. AC-1.
- **T-mksquashfs-sde:** version gate and flag ban. AC-6.
- **T-makewhatis-oom:** build-time only, fatal, rc scripts free of it. AC-9, AC-10.
- **T-rcK-no-poweroff / T-console-home:** tree contract on the shipped files. AC-10.
- **D-all-static / D-no-dynamic-loading-no-dlopen:** manifest exposes interp, needed, every ELF (incl. `.so`) for
  O06; loader ships only if needed. AC-5, AC-7.
- **D-hand-authored-rootfs-files-owned:** B04 writes the ported hand-written files and the closed stamp list; every
  other file is owned. Ported files are recorded `unowned` and must be on S04's allowlist (the predecessor's, carried
  unchanged); R05 shrinks both and B04-AC-14 removes the generators. AC-3, AC-4, AC-14.
- **D-bitmap-fonts-no-freetype:** font index is PCF-only and fails on unreadable input. AC-8.
- **Principle 1:** no vendor host in stamps. AC-3.

## Gate
- **B04-AC-1** — The install uses `--usepkgonly` into a clean root, has no `--keep-going` and no `--nodeps` except for the kernel gpkg, runs `acct-*` in a first `--jobs=1` pass, and a missing atom exits 4 even if its gpkg exists. *Verify:* `tests/fast/rootfs-install.test.sh` (stub `emerge` capturing argv; fixture VDB). *Tier:* fast.
- **B04-AC-2** — The cleanup applies `sysroot-exclude.txt` (the only copy of the list) and removes every pattern in it, including `usr/share/monolith-kernel/`, while keeping all else; `bunzip2` failure exits 4. *Verify:* `tests/fast/rootfs-cleanup.test.sh` (fixture tree). *Tier:* fast.
- **B04-AC-3** — Stamp rendering replaces `@BUILD_VERSION@` and `@HOME_URL@`, leaves no `@…@`, and no template or rendered file contains `amazonaws`, `s3.`, or any hostname not equal to `MONOLITH_HOME_URL`'s. *Verify:* `tests/fast/rootfs-stamps.test.sh`. *Tier:* fast.
- **B04-AC-4** — `rootfs.manifest.tsv` has the `#schema=1` header, is `LC_ALL=C` sorted, has exactly one row per file, directory and symlink in the tree, and `owner` is the VDB cpv, `stamp:<path>` for the stamp list, or `unowned`; the stage record carries the `unowned` count. *Verify:* `tests/fast/rootfs-manifest.test.sh` (fixture tree + `CONTENTS`). *Tier:* fast.
- **B04-AC-5** — For every ELF, including a `.so` without the exec bit, the manifest records `etype`, `interp` and `needed`; non-ELF rows carry `-`. *Verify:* `tests/fast/rootfs-manifest.test.sh` (stub `readelf` outputs). *Tier:* fast.
- **B04-AC-6** — The stage exits 2 if `mksquashfs -version` is below 4.5, runs `mksquashfs` with `SOURCE_DATE_EPOCH` in its environment and without `-all-time` or `-mkfs-time`, and leaves the image mode 0644. *Verify:* `tests/fast/rootfs-squashfs.test.sh` (stub `mksquashfs` recording argv/env). *Tier:* fast.
- **B04-AC-7** — The musl loader is a regular file iff some manifest row has `interp != -`; otherwise `lib/ld-musl-i386.so.1` and `usr/lib/libc.so` are absent; a dangling loader symlink never reaches the image. *Verify:* `tests/fast/rootfs-loader.test.sh` (two fixture trees). *Tier:* fast.
- **B04-AC-8** — `index-fonts.sh` writes `fonts.dir` for every PCF, exits 4 on an unreadable PCF, a missing fonts dir or an aliased XLFD absent from `fonts.dir`; `pcf-fontname.py` keeps its existing test. *Verify:* `tests/fast/rootfs-fonts.test.sh`, `tests/fast/pcf-fontname.test.sh`. *Tier:* fast.
- **B04-AC-9** — A failing `makewhatis` exits 4; with a working one `usr/share/man/mandoc.db` exists, is non-empty, and has the same mtime as the pages after the clamp. *Verify:* `tests/fast/rootfs-whatis.test.sh` (stub `makewhatis`). *Tier:* fast.
- **B04-AC-10** — Every line of `tree-contract.txt` holds in the built tree; a fixture tree missing `poweroff -f` or the console `HOME` export, or whose `rcS` mentions `makewhatis`, fails. *Verify:* `tests/fast/rootfs-contract.test.sh` (fixtures); CI step "tree contract" on the real tree. *Tier:* fast and slow.
- **B04-AC-11** — VDB `BUILD_TIME` equals `SOURCE_DATE_EPOCH` and `COUNTER` is the sorted-cpv index for every package after the stage. *Verify:* `tests/fast/rootfs-vdb.test.sh`. *Tier:* fast. *When:* after MS2 (reproducibility work; fixes no verified predecessor bug and guards no release path).
- **B04-AC-12** — Running the stage twice on the same gpkg set and `SOURCE_DATE_EPOCH` gives identical `rootfs.manifest.tsv` and squashfs sha256; each differing manifest path is entered in B07's known-differences file with a cause. *Verify:* CI job `image`, steps "rootfs" twice then `cmp`. *Tier:* slow. *When:* after MS2 (B07 is deferred; B04-AC-6 already guards the squashfs date flags).
- **B04-AC-13** — On the real build every world atom at its locked version and the kernel are in the VDB, and the stage record shows the `unowned` and `dynamic_elf` counts for S04 and O06. *Verify:* CI job `image`, step "assert completeness" (reads `out/stage/rootfs.json`). *Tier:* slow.
- **B04-AC-14** — Every `rootfs.manifest.tsv` row with `owner=unowned` is a path in `supplychain/policy/unowned-allowlist.yaml` (S04's gate agrees), and after R05 merges the stage generates none of R05's 41 moved files: a fixture with R05's `install.manifest` fails if `build-rootfs` still writes one of them, and passes when only the four stamps remain. *Verify:* `tests/fast/rootfs-handwritten.test.sh` (fixture manifest and allowlist). *Tier:* fast. *When:* after MS2 (lands with or after R05, which is parallel and not on the path to MS2).

## RED plan
Tester writes first: `rootfs-install` (stub `emerge` whose argv must not contain `--keep-going`),
`rootfs-manifest` (the predecessor's `find -perm -u+x` view would miss the exec-bit-less `.so` row), `rootfs-loader`
(both fixtures), `rootfs-squashfs` (stub rejects `-all-time`), `rootfs-contract` (fixture lacking `poweroff -f`),
`rootfs-stamps` (template containing an S3 URL). Fixtures are tiny hand-made trees under
`tests/fast/fixtures/rootfs/`; `readelf` and `mksquashfs` are stubs on `PATH`. No Docker.

## Risks and open questions
- OD-2 (static truth) decides what O06 allows, not what B04 emits; the loader rule and manifest columns hold either way.
- Whether `/boot/vmlinuz-<ver>` (installed by the kernel gpkg) ends up in the squashfs and wastes several MB is
  unknown from the study; the kernel already sits on the ISO. Candidate for `sysroot-exclude.txt` after the first
  build lists its size; excluding it needs a check that no rootfs script reads it.
- Remaining VDB volatility (`environment.bz2`, `*.ebuild`, `repository` files) is untested; expect B07 entries.
- The acct-first serial pass is unproven as the dnsmasq fix; AC-1 makes any recurrence loud.
- Until R05 lands the manifest shows the ported hand-written files as `unowned`; S04 passes only because the predecessor's allowlist is carried unchanged (S04-AC-8). When R05 merges, a stale B04 generator would overwrite package content; B04-AC-14 and R05's `ownership-collisions` catch it.
- `MONOLITH_HOME_URL` default waits on OD-1.
- Interaction with `etc/os-release` content tests in other nodes is unknown.

## Cost
Slices: (1) install + cleanup + seed; (2) manifest and ELF columns; (3) ported hand-written files, stamps, fonts, whatis; (4) squashfs
gate, contract, loader rule. After MS2: VDB normalisation, the twice-run check, the R05 follow-up (AC-14). About 4 slices before MS2. CI cycles: 2 before MS2 (first clean-root install from real gpkgs, a repair); the `image` job's share of the measured 78 min tag job is small (the predecessor's rootfs and ISO steps are minutes; not separately measured). The twice-run determinism check waits for B07. No extra money; the squashfs and
manifest are uploaded as build outputs.

## Spec defects found
- S01 and S04 consume `out/rootfs.manifest.tsv`; its column set is defined here. If S01 expects a different
  shape, reconcile before S01 starts.
