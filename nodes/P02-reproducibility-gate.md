# P02 — reproducibility-gate

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | P01 | X01 | — | L |

**Owns:** the `build-b` and `compare` jobs of `build.yml`'s tag path, `scripts/tests/release-gate.test.sh`, and the determinism edits to `scripts/build-initrd.sh`, `scripts/build-rootfs.sh`, `scripts/build-iso.sh`, `scripts/build-packages.sh` and the kernel ebuild (each listed below).
**Ports from linux-live-iso-factory@b9f533b:** nothing as a whole. The predecessor never compared two builds. Its partial measures stay: timestamps clamped to `SOURCE_DATE_EPOCH` before the initrd cpio (`build-initrd.sh:343-353`), mksquashfs reading `SOURCE_DATE_EPOCH` (`build-rootfs.sh:721-723`), the binpkg pack (`binpkg-store.sh:391`).
**Study refs:** build.yaml hazards `nondeterminism` (initrd cpio, symlink mtimes, ISO date flags, parallel emerge, docker commit); T-mksquashfs-sde, T-run-rerun-reuses-cache; D-supply-chain-honesty, D-tag-builds-from-source; SPEC §1 "Reproducibility", §7, §8.

## Purpose
Strict determinism, after the system is constituted. The first release (MS2) is one offline build from archived inputs. After this node every tag is built twice from those same inputs, and it cannot be attested or published unless both ISOs have the same SHA-256. The comparison covers the whole ISO: kernel, initramfs, squashfs, bootloaders, ESP image and filesystem metadata. A mismatch fails the tag. There are no exceptions and no allowlist. It is required before cutover (X01).

## Standard mechanism
- **Reproducible-builds techniques at the source of each difference:** `SOURCE_DATE_EPOCH`, kbuild's `KBUILD_BUILD_TIMESTAMP`/`KBUILD_BUILD_USER`/`KBUILD_BUILD_HOST`, `cpio --reproducible` with sorted input and clamped mtimes, mksquashfs `SOURCE_DATE_EPOCH` support, xorriso `-volume_date`, `mkfs.vfat --invariant -i`, fixed locale, umask and time zone.
- **Second build:** the same offline release mode P01 uses (fetching disabled, `docker run --network none`), from the same `release-inputs.json` and distfiles artifact.
- **Comparison:** `sha256sum`. diffoscope runs only after a mismatch, to show where the bytes differ. It decides nothing.
- **Custom code:** none beyond the two jobs. The VDB normalisation in change 6 is a gap only if Portage does not honour `SOURCE_DATE_EPOCH` for its own metadata (unverified).

## Changes from the port
1. **Second build and comparison.** P01's tag path is `fetch` → `build` → oracle and gates → attestation → publish. This node adds two jobs:
   1. `build-b`: on a separate runner, the same offline release mode as P01's `build`, reading only the source commit, `release-inputs.json` and the distfiles artifact from `fetch`. It shares no Docker volume, binpkg cache, `actions/cache` entry or artifact with `build`, and neither job `needs` the other. *AC-1.*
   2. `compare`: `sha256sum` of both ISOs. Unequal digests fail the job and the tag pipeline. On a mismatch, diffoscope runs and its report is uploaded for diagnosis. The job still fails. *AC-2.*

   The attestation job gains `compare` in its `needs`, beside the boot modes, artifact checks and gates (B03-AC-5, P01-AC-4). *AC-3.*
2. **Build B differs where a build must not matter.** Build B uses a different container hostname and a different `--jobs` value from build A. This exposes host-name and build-order dependence instead of hiding it. *AC-4.*
3. **Kernel.** The kernel ebuild exports `KBUILD_BUILD_TIMESTAMP=@${SOURCE_DATE_EPOCH}`, `KBUILD_BUILD_USER=monolith`, `KBUILD_BUILD_HOST=monolith` and `KBUILD_BUILD_VERSION=1`, as a revbump. *AC-6.*
4. **Initrd.** `build-initrd.sh:352-353` skips symlinks when clamping mtimes, and its cpio has no `--reproducible`. Change it to `touch -h -d @${SOURCE_DATE_EPOCH}` for every entry and `cpio --reproducible`. The `${SOURCE_DATE_EPOCH:-0}` fallback becomes an error when the variable is unset. *AC-6.*
5. **ISO, ESP and squashfs.**
   - `build-iso.sh` passes xorriso `-volume_date all_file_dates =${SOURCE_DATE_EPOCH}`, `-volume_date uuid <derived from SOURCE_DATE_EPOCH>` and a fixed `-volid`.
   - The ESP is made with `mkfs.vfat --invariant -i <fixed id>`, and `mcopy` runs with clamped mtimes (`build-iso.sh:370-373`).
   - The `grub-mkstandalone` memdisk (`build-iso.sh:350`) gets clamped mtimes and sorted input.
   - `build-rootfs.sh` clamps every rootfs mtime to `SOURCE_DATE_EPOCH` before mksquashfs, and keeps mksquashfs's own `SOURCE_DATE_EPOCH` handling.
   - Each of these is the documented reproducible option of the tool. Where a tool has none (unverified for the grub memdisk), the input is normalised before the tool runs.

   *AC-6.*
6. **Portage VDB on the disc.** The rootfs carries `var/db/pkg` (S01's SBOM and unowned gate read it). It records `BUILD_TIME`, merge `COUNTER` values and saved environments. With parallel emerge these vary between builds. First check whether Portage takes `BUILD_TIME` from `SOURCE_DATE_EPOCH` (unverified). If it does not, `build-rootfs.sh` normalises the shipped copy after extraction:
   - `BUILD_TIME` is set to `SOURCE_DATE_EPOCH`;
   - `COUNTER` is renumbered in sorted cpv order;
   - known volatile lines are dropped from `environment.bz2`, which is recompressed with `bzip2 -9`.

   The builder's own VDB is untouched. B01's source audit reads the builder's VDB, not the shipped copy, so it is unaffected. *AC-6.*
7. **No difference list.** v0.3's `docs/known-differences.md` is gone. A difference is a defect: fix it at its source with one of the techniques above. If a fix needs a recipe change, it is a revbump in the overlay or a `configs/portage` edit, owned here. *AC-2.*
8. **Dispatch without publishing.** `build.yml`'s `workflow_dispatch` runs `fetch`, `build`, `build-b` and `compare` on any commit, with no attestation or publication, so nondeterminism is found and fixed before this node's gate goes onto tags. *AC-6.*

## Gate
- **P02-AC-1** — `build.yml`'s tag path has `build` and `build-b` as separate jobs. Each takes only the source commit, `release-inputs.json` and the distfiles artifact as inputs, with no shared volume, `actions/cache`, binpkg pull or artifact between them. Neither job has a `needs:` on the other. *Verify:* `scripts/tests/release-gate.test.sh` (parses the workflow with PyYAML). *Tier:* fast.
- **P02-AC-2** — `compare` exits 1 when the two ISO digests differ and 0 only when they are equal. No file, variable or input can make a mismatch pass, and no `known-differences` file exists. *Verify:* `scripts/tests/release-gate.test.sh` (fixture ISOs differing by one byte, and identical ones; grep for an allowlist). *Tier:* fast.
- **P02-AC-3** — On a tag, the attestation job and every later write (`oras push`, `docker push`, `gh release`, `actions/attest*`) `need` `compare`. *Verify:* `scripts/tests/release-gate.test.sh` (`needs:` graph). *Tier:* fast.
- **P02-AC-4** — `build-b` runs in the same offline release mode as `build` (P01-AC-11), with a different container hostname and `--jobs` value. *Verify:* `scripts/tests/release-gate.test.sh` (greps both jobs' `docker run` lines and arguments). *Tier:* fast.
- **P02-AC-5** — Build B reads its pins only from `release-inputs.json` and the source checkout, not from a runner, volume or cache. *Verify:* `scripts/tests/release-gate.test.sh` (the job's `env:` and inputs); P01's `release-inputs.test.sh` for the file's fields. *Tier:* fast.
- **P02-AC-6** — For a dispatch on a development commit (change 8), the two builds produce ISOs with equal SHA-256. The kernel, initrd, squashfs and ESP extracted from each are also byte-identical. *Verify:* the dispatch run's `compare` job log; record the run URL. *Tier:* slow.
- **P02-AC-7** — The first tag after this node merges passes `compare` with equal digests, and that digest is the one P01 attests and publishes. *Verify:* the tag run URL; `sha256sum` of the published ISO equals both build digests in the `compare` log. *Tier:* slow.

## Risks
- **The size of the work is the main schedule risk.** The predecessor never built twice, so how many packages are nondeterministic is unknown until AC-6 first runs. Known suspects come from the study: the initrd cpio, symlink mtimes, ISO dates, the grub memdisk, ESP serial and timestamps, parallel emerge and the VDB. Unknown ones would be in individual packages: embedded build paths, timestamps, `__DATE__`, randomness in perl's or rust's build output. Each must be fixed in its recipe. That is the honest cost of the requirement. The gate does not relax.
- The adopted builder image is not itself reproducible (M02). Both builds use the same digest, so this does not affect ISO reproducibility. It does mean the toolchain is trusted by digest, not rebuilt.
- Both builds run on GitHub-hosted runners with the same image family. That is two clean environments, not two organisations. An outside rebuilder can later use `release-inputs.json` and the archived inputs.
- Unverified: whether Portage honours `SOURCE_DATE_EPOCH` for `BUILD_TIME`; whether `mkfs.vfat --invariant` exists in the builder's dosfstools; whether xorriso's `-volume_date uuid` covers every date field in the hybrid image; diffoscope's memory on a hosted runner (it is diagnostic only, so a failure there does not affect the gate).
- Cost per tag after this node: a second from-source build in parallel (~78 min, measured on the predecessor).
