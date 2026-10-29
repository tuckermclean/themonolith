# B01 — package-build

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | I02, I03, R04 | B03 | — | M |

**Owns:** `scripts/source-audit.sh`, `scripts/tests/source-audit.test.sh`, `configs/attestation/bootstrap-exceptions.txt`, `scripts/build-packages.sh`, `scripts/binpkg-store.sh`, `scripts/savedconfig-cache.sh`, `scripts/extract-packages.sh` (package half), `scripts/update-versions.sh`, `configs/portage/world` (R05 restores two lines), `configs/portage/versions.lock`, `configs/portage/package.mask/`, `scripts/tests/versions-lock-complete.test.sh`, `scripts/tests/build-packages-classify.test.sh`, `scripts/tests/cache-tag.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `scripts/build-packages.sh`, `scripts/binpkg-store.sh`, `scripts/savedconfig-cache.sh`, `scripts/extract-packages.sh`, `scripts/update-versions.sh`, `scripts/tests/binpkg-store.test.sh`, `scripts/tests/savedconfig-cache.test.sh`, `configs/portage/{world,versions.lock,package.mask/}`. Carried unchanged unless listed below.
**Study refs:** build.yaml `script.build-packages` (failure masking); T-keep-going-hides-drops, T-binpkg-revbump, T-live-ebuild-and-host-keyword-skew; D-tag-builds-from-source, D-no-readding-removed-things; SPEC §5 rows "Versions", "Binary cache", "Static dependents".

## Purpose
The package build runs from this repository against GHCR and the pinned tree, with the predecessor's behaviour. Afterwards a package counts as built only if it is installed at its locked version, and every world atom is locked. The development cache is keyed on the inputs Portage cannot see. A release build compiles every package that reaches the rootfs in that run, and proves it, except a short declared list of toolchain files.

## Standard mechanism
Portage `PKGDIR` with gpkg, `--usepkg`, `--binpkg-respect-use=y`, `--binpkg-changed-deps=y`, `--rebuild-if-unbuilt`, `portageq has_version`, `package.mask`. Custom code that remains, all ported:
- `binpkg-store.sh` (OCI transport of one `PKGDIR`): a binhost over HTTP needs a web host we lack (SPEC §5).
- `savedconfig-cache.sh`: Portage does not hash savedconfig contents (script header, `savedconfig-cache.sh:3-12`).
- `versions.lock` and `update-versions.sh`: SPEC §5 "Versions".
- New: the cache tag hashes `make.conf`, `bashrc`, `env/`, `package.env` and `profile/` because Portage cannot see them. This is a few lines of `sha256sum` in the existing script. A per-package fingerprint was considered; the cache tag is enough.

## Changes from the port
1. **Cache tag.** `binpkg-store.sh` tags the artifact `binpkgs:<tag>` (SPEC §6), with `<tag>` the first 16 hex of sha256 over `BUILDER_DIGEST`, `TREE_COMMIT` and a hash of `make.conf`, `bashrc`, `env/`, `package.env/`, `profile/`. The predecessor keyed on `BUILD_EPOCH` alone (`binpkg-store.sh:59`, `build.yml:269`), so a `bashrc` edit reused stale binaries. Only `main` pushes; PRs pull; tags do neither (the predecessor pushed with `if: always()` and no ref condition, `build.yml:448-450`). The first `main` build is cold (~75 min measured). rc1's cache is not seeded. *AC-1, AC-2.*
2. **Emerge flags.** The predecessor passes only `--jobs --load-average --keep-going --buildpkg --usepkg --verbose` (`build-packages.sh:242-249`), and `make.conf` has no `EMERGE_DEFAULT_OPTS`. Add `--binpkg-respect-use=y --binpkg-changed-deps=y --rebuild-if-unbuilt` when `--usepkg` is on. Portage defaults for the first two are unverified, so passing them is free. *AC-3.*
3. **Success is the installed set, not a glob.** On the failure branch `compgen -G ".../${PKG_NAME}-*.gpkg.tar"` (`build-packages.sh:295`) counts any gpkg of the package, of any version, including one restored from the cache. A failed rebuild with `--keep-going` therefore counts as built. Replace it with `portageq has_version` on the target root for the locked `=cat/pkg-ver` atom. The success branch (`:253-259`) is kept, since a zero exit under `--keep-going` means nothing failed. *AC-4.*
4. **Locked or fail.** A world atom with no lock line currently queues as `(latest)` (`build-packages.sh:192-198`) and `update-versions.sh update` drops unresolvable atoms with a warning (`update-versions.sh:152-160`). Both now exit non-zero. Regenerate `versions.lock` with the ported `update-versions.sh` to close the 23-atom drift (99 world atoms, 77 lock lines at b9f533b). Atoms with operators or slots (`<sys-fs/ncdu-2`, `=games-roguelike/nethack-3.6.7-r1`, `net-misc/iperf:3`) are among the 23. *AC-5, AC-6.*
5. **Tag builds prove source.** The ported `MONOLITH_USEPKG=n` (`build-packages.sh:221-225`) stays. Add: with it set, `PKGDIR` must be empty at start, and the emerge log must contain no `>>> Emerging binary` line (the format the script already greps, `build-packages.sh:413`). *AC-7.*
6. **Removed things stay removed.** `package.mask` covers man-db, fortune-mod, usbutils and nmap. The doctrine list also names w3m, thttpd and on-target gcc, which are masked nowhere. Add `www-client/w3m`, `net-www/thttpd`, `sys-devel/gcc` (target root only, to be confirmed so the host toolchain is untouched) to `package.mask`. A fast test checks the doctrine.yaml list against `package.mask` and `world`. *AC-8.*
7. `savedconfig-cache.sh` TRACKED list gains the kernel (B02 owns that line).
8. **Release mode reuses nothing.** With `MONOLITH_USEPKG=n` the predecessor emerges only the world atoms (`build-packages.sh:221-250`). Dependencies already installed in the builder image's target root are therefore skipped, not rebuilt. `quickpkg --include-config=y "*/*"` then repackages every installed sysroot package without compiling it (`build-packages.sh:319-324`, with `2>/dev/null || true` at `:323`). The whole sysroot is rsynced into the rootfs (`build-packages.sh:342-376`). So a release could ship binaries that were never built in that run. In release mode:
   - `PKGDIR` starts empty and `--usepkg` is off (change 5);
   - the `quickpkg` step does not run;
   - before the emerge, `build-packages.sh` lists the target VDB that the builder image ships (`/usr/${CROSS_TARGET}/var/db/pkg`) and adds each package found there to the emerge command line as `cat/pn:slot` with `--oneshot`. Portage always re-merges a package named on the command line, so each one is compiled again in this run; `--oneshot` keeps it out of the world file. The list is printed in the build log.

   A release build starts in a fresh container from the builder image, so everything else in the graph is compiled anyway. The preinstalled packages are the only ones that could be reused. `--emptytree` was considered and rejected: it re-merges the same set, plus anything crossdev placed in the target root, and in a cross build it may also pull build-host dependencies into the graph (unverified). Naming the preinstalled packages rebuilds exactly the set that would otherwise be reused, and the source audit (change 9) proves the result.

   Development mode keeps the ported behaviour. *AC-10.*
9. **Source audit of what ships.** After the sysroot export (`build-packages.sh:342-376`), `scripts/source-audit.sh` assigns every file in `output/sysroot/` to its owner in the target VDB (`/usr/${CROSS_TARGET}/var/db/pkg/*/CONTENTS`). It then fails in any of three cases:
   - a file's owning cpv was not merged from source in this run, judged from emerge's own `>>> Emerging (N of M) <cpv>` lines in this run's log, cross-checked with `BUILD_TIME` at or after the run's start;
   - a file has no owner and is not in `configs/attestation/bootstrap-exceptions.txt`;
   - an exception entry matches no file.

   The report, `source-audit.tsv` (`path`, `owner`, `built-this-run`|`bootstrap`), is a release asset. *AC-11, AC-12.*
10. **Declared bootstrap exceptions.** The crossdev toolchain installs some files into the sysroot from host-side `cross-i486-linux-musl/*` packages. They are owned in the host VDB, not the target VDB. The known case is the musl `libc.so` copied to `/lib/ld-musl-i386.so.1` (`build-packages.sh:380-389`; R03 removes it).
    - `bootstrap-exceptions.txt` lists each such path with its host owner, found with `qfile` on the host root. Every line names a cpv whose version equals `crossdev.lock`.
    - The pinned `BUILDER_DIGEST` is the provenance of these files.
    - Code that the toolchain links into every static binary (musl `libc.a`, `libgcc.a`, `libatomic.a`, `libssp_nonshared.a`) is not a rootfs file. Its provenance is also `BUILDER_DIGEST`, and SPEC §6 says so.
    - Nothing else may be listed. A preinstalled package that cannot be re-merged in the sysroot is a finding to fix, not an exception. *AC-12.*
11. **`rl144` and `stele` are left out of `world` for MS1.** They fetch Rust crates while they build, so they cannot build in the offline release mode (P02). Leaving them out lets the iteration ISO land without waiting for R05, which restores them and is mandatory before the first release (P01-AC-11). Remove their `world` lines (`world:253-256`, `:295-300`) and their `versions.lock` lines. Their ebuilds stay in the overlay unchanged. Add two lines to `docs/rc1-diff-reasons.tsv` (P01) naming R05 as the reason. B03 runs every boot mode except `stele-acid2` until R05 restores it. *AC-13.*

## Gate
- **B01-AC-1** — The cache tag changes when `bashrc`, `make.conf`, a file in `env/`, `package.env/` or `profile/`, `TREE_COMMIT` or `BUILDER_DIGEST` changes, and does not change for an unrelated file. *Verify:* `scripts/tests/cache-tag.test.sh`. *Tier:* fast.
- **B01-AC-2** — CI pushes the cache only on `main`, pulls on PRs, and does neither on tags. *Verify:* `scripts/tests/cache-tag.test.sh` greps the workflow conditions. *Tier:* fast.
- **B01-AC-3** — With `--usepkg` on, the emerge command line contains the three flags; with `MONOLITH_USEPKG=n` it contains no `--usepkg`. *Verify:* `scripts/tests/build-packages-classify.test.sh` (stub `emerge`). *Tier:* fast.
- **B01-AC-4** — With a stale gpkg of the package on disk and a stub `emerge` that fails, the package is classified failed; with it installed at the locked version it is built. *Verify:* `scripts/tests/build-packages-classify.test.sh`. *Tier:* fast.
- **B01-AC-5** — Every `world` atom, normalised to `category/package`, has a `versions.lock` line, and `build-packages.sh` exits non-zero on a world atom without one. *Verify:* `scripts/tests/versions-lock-complete.test.sh`. *Tier:* fast.
- **B01-AC-6** — `update-versions.sh update` exits non-zero when an atom does not resolve. *Verify:* `scripts/tests/versions-lock-complete.test.sh` (stub `portageq`). *Tier:* fast.
- **B01-AC-7** — A tag build's log has zero `>>> Emerging binary` lines and at least one `>>> Emerging (` line; the check fails on a fixture log with a binary merge. *Verify:* `scripts/tests/build-packages-classify.test.sh`; the tag CI job. *Tier:* fast for the fixture, slow for the real log.
- **B01-AC-8** — Every package named in doctrine.yaml D-no-readding-removed-things is absent from `world` and masked. *Verify:* `scripts/tests/versions-lock-complete.test.sh`. *Tier:* fast.
- **B01-AC-9** — The ported `binpkg-store.test.sh` and `savedconfig-cache.test.sh` pass, and a `main` build on the new registry completes (cold) and a second run restores from the cache. *Verify:* `make test`; two CI runs of build.yml. *Tier:* fast and slow.
- **B01-AC-10** — In release mode, with a fixture target VDB holding two packages, the emerge command line has no `--usepkg`, names both packages with `--oneshot`, and the `quickpkg` step is skipped. In development mode both are as ported. *Verify:* `scripts/tests/build-packages-classify.test.sh` (stub `emerge`, `quickpkg`). *Tier:* fast.
- **B01-AC-11** — `source-audit.sh` fails on a fixture sysroot in each of four cases and passes on a clean one. The failing cases are: a file owned by a cpv absent from the run's `Emerging` lines; a file owned by a cpv with `BUILD_TIME` before the run start; an unowned file not in the exceptions list; a stale exception. *Verify:* `scripts/tests/source-audit.test.sh`. *Tier:* fast.
- **B01-AC-12** — On a real release-mode build, `source-audit.sh` passes. Every `bootstrap` row in `source-audit.tsv` names a host cpv at its `crossdev.lock` version, and every other row is `built-this-run`. *Verify:* P02's `build-a` job log and its `source-audit.tsv` artifact. *Tier:* slow.
- **B01-AC-13** — `world` has neither `games-roguelike/rl144` nor `www-client/stele` until R05, and no overlay ebuild with `network-sandbox` in `RESTRICT` is named in `world`. *Verify:* `scripts/tests/versions-lock-complete.test.sh`. *Tier:* fast.

## Risks
- Whether `--rebuild-if-unbuilt` works with a cross `ROOT` is unverified (SPEC §5). The first slice checks it; releases build from source, so a miss cannot reach one.
- The exact `portageq has_version` form against the cross root is unverified; `update-versions.sh:64` shows the `PORTAGE_CONFIGROOT` shape.
- Masking `sys-devel/gcc` may break the host toolchain if the mask is mirrored host-side (`build-packages.sh` mirrors `package.mask`). Check before adding it.
- What the builder image's target VDB holds is unknown. The predecessor's comment names `acct-user/*` (`build-packages.sh:319-320`). If it also holds crossdev-placed packages (for example `sys-kernel/linux-headers` or `sys-libs/musl`), re-merging one with the cross compiler may fail. The owner then decides before release: fix the rebuild, or justify the files as toolchain files in `bootstrap-exceptions.txt` with their host owner. Silent reuse is not an option.
- `monolith-base`'s help topics still name rl144 (`topics/games.txt:11`, `topics/tools.txt:40`) on MS1 iteration ISOs, before R05. They are left as they are: R05 makes them true again, and editing them needs a `monolith-base` revbump.
- Auth errors as cache misses are I01's change (`binpkg-store.sh:341-343`), not repeated here.
