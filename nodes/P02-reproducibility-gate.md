# P02 — reproducibility-gate

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | B03 | P01 | — | L |

**Owns:** the tag path of `.github/workflows/build.yml` up to, not including, attestation (the `fetch`, `build-a`, `build-b` and `compare` jobs and the offline release mode of the build job), `scripts/fetch-distfiles.sh`, `scripts/release-inputs.sh`, `scripts/tests/release-gate.test.sh`, `scripts/tests/release-inputs.test.sh`, and the reproducibility edits to `scripts/build-initrd.sh`, `scripts/build-rootfs.sh`, `scripts/build-iso.sh`, `scripts/build-packages.sh` and the kernel ebuild (each listed below).
**Ports from linux-live-iso-factory@b9f533b:** nothing as a whole. The predecessor never compared two builds. Its partial measures stay: timestamps clamped to `SOURCE_DATE_EPOCH` before the initrd cpio (`build-initrd.sh:343-353`), mksquashfs reading `SOURCE_DATE_EPOCH` (`build-rootfs.sh:721-723`), the binpkg pack (`binpkg-store.sh:391`).
**Study refs:** build.yaml hazards `nondeterminism` (initrd cpio, symlink mtimes, ISO date flags, parallel emerge, docker commit); T-mksquashfs-sde, T-run-rerun-reuses-cache; D-supply-chain-honesty, D-tag-builds-from-source; SPEC §1 "Reproducibility", §7, §8.

## Purpose
MS1's ISO is for iteration and is never published. After this node a tag cannot be published unless two clean, separate builds from the same pinned and archived inputs produce an ISO with the same SHA-256. The comparison covers the whole ISO: kernel, initramfs, squashfs, bootloaders, ESP image and filesystem metadata. A mismatch fails the tag. There are no exceptions and no allowlist. P01, the first release, runs only after this gate and R05.

## Standard mechanism
- **Reproducible-builds techniques at the source of each difference:** `SOURCE_DATE_EPOCH`, kbuild's `KBUILD_BUILD_TIMESTAMP`/`KBUILD_BUILD_USER`/`KBUILD_BUILD_HOST`, `cpio --reproducible` with sorted input and clamped mtimes, mksquashfs `SOURCE_DATE_EPOCH` support, xorriso `-volume_date`, `mkfs.vfat --invariant -i`, fixed locale, umask and time zone.
- **Offline builds:** Portage's own `DISTDIR` and Manifest checks, with `FETCHCOMMAND`/`RESUMECOMMAND` set to `/bin/false`. The build container runs with `docker run --network none`, the standard way to make "no network" a property of the environment rather than of each script.
- **Comparison:** `sha256sum`. diffoscope runs only after a mismatch, to show where the bytes differ. It decides nothing.
- **Custom code:** two short scripts. `fetch-distfiles.sh` runs `emerge --fetchonly` and tars `DISTDIR`. `release-inputs.sh` writes the SPEC §6 file with `jq`. Gap: no standard tool archives a Portage build's distfiles or records our pins. The VDB normalisation in change 6 is a gap only if Portage does not honour `SOURCE_DATE_EPOCH` for its own metadata (unverified).

## Changes from the port
1. **Tag pipeline.** On `v*` tags `build.yml` runs, in this order (it stays the entry workflow of a tag run, because the signing certificate binds to it, `build.yml:1-17`):
   1. `fetch`: in the pinned builder with the pinned tree, `emerge --fetchonly` for the full release dependency graph (B01's release mode). This is the only job with network access to upstream. Its output is `distfiles.tar` (sorted, mtimes clamped) and `release-inputs.json`, uploaded as Actions artifacts. The archive's digest is recorded in `release-inputs.json`.
   2. `build-a` and `build-b`: two jobs on separate runners. Each calls `build.yml`'s build job in offline release mode (change 2). Neither shares a Docker volume, binpkg cache, `actions/cache` entry or artifact with the other, apart from the two inputs above. *AC-1.*
   3. `compare`: `sha256sum` of both ISOs. Unequal digests fail the job and the tag pipeline. On a mismatch, diffoscope runs and its report is uploaded for diagnosis. The job still fails. *AC-2.*
   4. The O01 boot modes, O02 artifact checks and S01 gates run on build A's ISO and may start before `compare` finishes.
   5. P01's attestation and publication `need` `compare`, the boot modes, the artifact checks and the gates.
   Nothing is pushed to the registry or to a public place before step 5. *AC-3.*
2. **Offline release mode** of `build.yml`'s build job. Its inputs are the source commit, `release-inputs.json` and the distfiles artifact. It does the following:
   - checks out the recorded source commit;
   - pulls the builder by `BUILDER_DIGEST` and the tree by `TREE_DIGEST`;
   - fills `DISTDIR` from the archive after checking its digest;
   - sets `SOURCE_DATE_EPOCH` from the file;
   - runs B01 in release mode;
   - runs every step that builds or writes the ISO inside `docker run --network none`;
   - sets `FETCHCOMMAND=/bin/false` and `RESUMECOMMAND=/bin/false`.

   A missing distfile fails and names the file. Build B uses a different container hostname and a different `--jobs` value from build A. This exposes host-name and build-order dependence instead of hiding it. *AC-4, AC-5.*
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

## Gate
- **P02-AC-1** — `build.yml`'s tag path has `build-a` and `build-b` as separate jobs. Each takes only the source commit, `release-inputs.json` and the distfiles artifact as inputs, with no shared volume, `actions/cache`, binpkg pull or artifact between them. Neither job has a `needs:` on the other. *Verify:* `scripts/tests/release-gate.test.sh` (parses the workflow with PyYAML). *Tier:* fast.
- **P02-AC-2** — `compare` exits 1 when the two ISO digests differ and 0 only when they are equal. No file, variable or input can make a mismatch pass, and no `known-differences` file exists. *Verify:* `scripts/tests/release-gate.test.sh` (fixture ISOs differing by one byte, and identical ones; grep for an allowlist). *Tier:* fast.
- **P02-AC-3** — In the tag pipeline, no step before `compare`, the boot modes, the artifact checks and the gates have all succeeded does any of the following: runs `oras push`, `docker push`, `gh release`, `actions/attest*`, Pages deploy or any registry write. *Verify:* `scripts/tests/release-gate.test.sh` (`needs:` graph of every job and step with a write). *Tier:* fast.
- **P02-AC-4** — The offline build runs every ISO-producing step in a container with `--network none`, and Portage fetching is disabled. With one file removed from the distfiles archive, the build fails, names that file, and makes no network attempt. *Verify:* `scripts/tests/release-gate.test.sh` (grep of the docker run lines); a CI dispatch on a copy of the archive with one file deleted. *Tier:* fast + slow.
- **P02-AC-5** — `release-inputs.json` has every SPEC §6 field, and a missing or empty field fails the script. Build B reads its pins only from this file and the source checkout, not from a runner, volume or cache. *Verify:* `scripts/tests/release-inputs.test.sh`. *Tier:* fast.
- **P02-AC-6** — For a dispatch of the gate on a development commit (`workflow_dispatch`, same pipeline without publishing), the two builds produce ISOs with equal SHA-256. The kernel, initrd, squashfs and ESP extracted from each are also byte-identical. *Verify:* the dispatch run's `compare` job log; record the run URL. *Tier:* slow.
- **P02-AC-7** — The `v0.2.0-rc1` tag pipeline passes `compare` with equal digests, and that digest is the one P01 attests and publishes. *Verify:* the tag run URL; `sha256sum` of the published ISO equals both build digests in the `compare` log. *Tier:* slow.

## Risks
- **The size of the work is the main schedule risk.** The predecessor never built twice, so how many packages are nondeterministic is unknown until AC-6 first runs. Known suspects come from the study: the initrd cpio, symlink mtimes, ISO dates, the grub memdisk, ESP serial and timestamps, parallel emerge and the VDB. Unknown ones would be in individual packages: embedded build paths, timestamps, `__DATE__`, randomness in perl's or rust's build output. Each must be fixed in its recipe. That is the honest cost of the requirement. The gate does not relax.
- The adopted builder image is not itself reproducible (M02). Both builds use the same digest, so this does not affect ISO reproducibility. It does mean the toolchain is trusted by digest, not rebuilt.
- Both builds run on GitHub-hosted runners with the same image family. That is two clean environments, not two organisations. An outside rebuilder can later use `release-inputs.json` and the archived inputs.
- Unverified: whether Portage honours `SOURCE_DATE_EPOCH` for `BUILD_TIME`; whether `mkfs.vfat --invariant` exists in the builder's dosfstools; whether xorriso's `-volume_date uuid` covers every date field in the hybrid image; diffoscope's memory on a hosted runner (it is diagnostic only, so a failure there does not affect the gate).
- Cost per tag: two from-source builds in parallel (~78 min each, measured on the predecessor), plus the fetch job and the oracle.
