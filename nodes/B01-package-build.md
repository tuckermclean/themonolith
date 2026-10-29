# B01 — package-build

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | I02, I03 | B03 | — | M |

**Owns:** `scripts/build-packages.sh`, `scripts/binpkg-store.sh`, `scripts/savedconfig-cache.sh`, `scripts/extract-packages.sh` (package half), `scripts/update-versions.sh`, `configs/portage/versions.lock`, `configs/portage/package.mask/`, `scripts/tests/versions-lock-complete.test.sh`, `scripts/tests/build-packages-classify.test.sh`, `scripts/tests/cache-tag.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `scripts/build-packages.sh`, `scripts/binpkg-store.sh`, `scripts/savedconfig-cache.sh`, `scripts/extract-packages.sh`, `scripts/update-versions.sh`, `scripts/tests/binpkg-store.test.sh`, `scripts/tests/savedconfig-cache.test.sh`, `configs/portage/{world,versions.lock,package.mask/}`. Carried unchanged unless listed below.
**Study refs:** build.yaml `script.build-packages` (failure masking); T-keep-going-hides-drops, T-binpkg-revbump, T-live-ebuild-and-host-keyword-skew; D-tag-builds-from-source, D-no-readding-removed-things; SPEC §5 rows "Versions", "Binary cache", "Static dependents".

## Purpose
The package build runs from this repository against GHCR and the pinned tree, with the predecessor's behaviour. Afterwards a package counts as built only if it is installed at its locked version, every world atom is locked, a tag build provably compiles from source, and the development cache is keyed on the inputs Portage cannot see.

## Standard mechanism
Portage `PKGDIR` with gpkg, `--usepkg`, `--binpkg-respect-use=y`, `--binpkg-changed-deps=y`, `--rebuild-if-unbuilt`, `portageq has_version`, `package.mask`. Custom code that remains, all ported:
- `binpkg-store.sh` (OCI transport of one `PKGDIR`): a binhost over HTTP needs a web host we lack (SPEC §5).
- `savedconfig-cache.sh`: Portage does not hash savedconfig contents (script header, `savedconfig-cache.sh:3-12`).
- `versions.lock` and `update-versions.sh`: SPEC §5 "Versions".
- New: the cache tag hashes `make.conf`, `bashrc`, `env/`, `package.env` and `profile/` because Portage cannot see them. This is a few lines of `sha256sum` in the existing script. A per-package fingerprint was considered and rejected (v0.3 I06).

## Changes from the port
1. **Cache tag.** `binpkg-store.sh` tags the artifact `binpkgs:<tag>` (SPEC §6), with `<tag>` the first 16 hex of sha256 over `BUILDER_DIGEST`, `TREE_COMMIT` and a hash of `make.conf`, `bashrc`, `env/`, `package.env/`, `profile/`. The predecessor keyed on `BUILD_EPOCH` alone (`binpkg-store.sh:59`, `build.yml:269`), so a `bashrc` edit reused stale binaries. Only `main` pushes; PRs pull; tags do neither (the predecessor pushed with `if: always()` and no ref condition, `build.yml:448-450`). The first `main` build is cold (~75 min measured). rc1's cache is not seeded. *AC-1, AC-2.*
2. **Emerge flags.** The predecessor passes only `--jobs --load-average --keep-going --buildpkg --usepkg --verbose` (`build-packages.sh:242-249`), and `make.conf` has no `EMERGE_DEFAULT_OPTS`. Add `--binpkg-respect-use=y --binpkg-changed-deps=y --rebuild-if-unbuilt` when `--usepkg` is on. Portage defaults for the first two are unverified, so passing them is free. *AC-3.*
3. **Success is the installed set, not a glob.** On the failure branch `compgen -G ".../${PKG_NAME}-*.gpkg.tar"` (`build-packages.sh:295`) counts any gpkg of the package, of any version, including one restored from the cache. A failed rebuild with `--keep-going` therefore counts as built. Replace it with `portageq has_version` on the target root for the locked `=cat/pkg-ver` atom. The success branch (`:253-259`) is kept, since a zero exit under `--keep-going` means nothing failed. *AC-4.*
4. **Locked or fail.** A world atom with no lock line currently queues as `(latest)` (`build-packages.sh:192-198`) and `update-versions.sh update` drops unresolvable atoms with a warning (`update-versions.sh:152-160`). Both now exit non-zero. Regenerate `versions.lock` with the ported `update-versions.sh` to close the 23-atom drift (99 world atoms, 77 lock lines at b9f533b). Atoms with operators or slots (`<sys-fs/ncdu-2`, `=games-roguelike/nethack-3.6.7-r1`, `net-misc/iperf:3`) are among the 23. *AC-5, AC-6.*
5. **Tag builds prove source.** The ported `MONOLITH_USEPKG=n` (`build-packages.sh:221-225`) stays. Add: with it set, `PKGDIR` must be empty at start, and the emerge log must contain no `>>> Emerging binary` line (the format the script already greps, `build-packages.sh:413`). *AC-7.*
6. **Removed things stay removed.** `package.mask` covers man-db, fortune-mod, usbutils and nmap. The doctrine list also names w3m, thttpd and on-target gcc, which are masked nowhere. Add `www-client/w3m`, `net-www/thttpd`, `sys-devel/gcc` (target root only, to be confirmed so the host toolchain is untouched) to `package.mask`. A fast test checks the doctrine.yaml list against `package.mask` and `world`. *AC-8.*
7. `savedconfig-cache.sh` TRACKED list gains the kernel (B02 owns that line).

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

## Risks
- Whether `--rebuild-if-unbuilt` works with a cross `ROOT` is unverified (SPEC §5). The first slice checks it; releases build from source, so a miss cannot reach one.
- The exact `portageq has_version` form against the cross root is unverified; `update-versions.sh:64` shows the `PORTAGE_CONFIGROOT` shape.
- Masking `sys-devel/gcc` may break the host toolchain if the mask is mirrored host-side (`build-packages.sh` mirrors `package.mask`). Check before adding it.
- Auth errors as cache misses are I01's change (`binpkg-store.sh:341-343`), not repeated here.
