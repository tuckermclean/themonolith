# The Monolith — Specification

Version 0.4 (draft, 2026-10-28; two corrective passes the same day: verify before publishing, release
from source offline from archived inputs, and a bit-for-bit gate once the system is constituted). v0.4
replaces v0.3's factory design with the smallest port of the predecessor that reaches a release. `docs/reviews/2026-10-28-v0.4.md` says what was removed
and why. This document is the authority for the repository. Where a node spec (`nodes/<id>.md`) and this
document disagree, this document wins and the node spec is a defect. The dependency graph is
`docs/graph.yaml`, and the plan to the first release is `docs/first-release.md`. The study of the
predecessor in `docs/study/` is evidence, not authority.

---

## 0. What this repository is

The Monolith is a small, specialized Gentoo-derived Linux distribution. It is one live ISO carrying a
complete GNU/Linux userland, cross-compiled from source against musl for i486. It boots on a 486 with
64 MB of RAM and on a modern UEFI machine.

**We are building a distribution, not a distribution-building framework.** Portage, crossdev,
ebuilds, profiles, USE flags, `savedconfig` and binary packages do the work, together with the usual
kernel, ISO, QEMU, QA and supply-chain tools. Custom code exists only where §5 records a gap that a
standard mechanism leaves open, and it is the smallest code that closes it.

This repository continues `tuckermclean/linux-live-iso-factory`, frozen at `b9f533b`, which released
`v0.1.0-rc1`. The predecessor already built, tested and attested this product. It stopped when its
storage vendor disabled the account; AWS S3 was hard-wired into five jobs. The rebuild therefore
**ports** the predecessor:
- Its recipes, scripts, tests and workflows carry over unchanged.
- S3 is replaced by the GitHub-native storage the predecessor already half used.
- The bugs the study verified are fixed as named criteria.

These predecessor assets survive and are reused by digest:

| Asset | Where | Identity |
|---|---|---|
| rc1 builder image (crossdev i486-musl toolchain) | `ghcr.io/tuckermclean/monolith-builder:20260810-d9d08d1c7422` | `sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa` |
| rc1 binary packages (one PKGDIR archive, BUILD_EPOCH 20260811) | `ghcr.io/tuckermclean/monolith-binpkgs:20260811` | `sha256:d0a1838d7504d41c95c050e70d0d5399dbf546dd2e21fdd5f793df2ad700b92d` |
| rc1's Gentoo tree | `github.com/gentoo-mirror/gentoo` history (the snapshot tarball is gone) | A commit near 2026-08-11. All 25 sampled `versions.lock` entries exist at `d4d0b0c7`. |
| v0.1.0-rc1 release | GitHub release on the predecessor | ISO `a9600659…eb27a` (202 MiB), SBOM `3cfc322a…75887` |

**Out of scope.** The knowledge-content projects that may one day ship on the disc are separate
projects with their own specifications. This spec places no requirements on them. If they ship, they
arrive as ordinary packages in the overlay and count against the size budget (§1).

Also out of scope:
- the predecessor's dashboard and in-browser boot demo;
- any agent orchestration for building this repository.

### 0.1 The myth (and why it is load-bearing)

The Monolith is an object that arrives in a world whose clock never started. Its origin is
1970-01-01, the Unix epoch. Its constituency is the kid's machine: a Socket-7 486-class board with a
VIA, SiS or ALi southbridge, which is Tier 0 by definition. The prompt carries a black square. These
facts decide three things:
- the test sentinels (D-clock-origin-1970);
- kernel tiering (D-486-tier-regime);
- what may never be added (D-486-minimalism).

---

## 1. Product and constraints

- **Targets:**
  - i486 and up, booting by BIOS through ISOLINUX;
  - x86_64 UEFI machines, through GRUB EFI with the i386 kernel;
  - common hypervisors: QEMU/KVM, VirtualBox, and Hyper-V per OD-12;
  - USB and optical media (hybrid ISO).
- **Userland:** the predecessor's world set, 99 atoms at `b9f533b`, cross-compiled for
  `i486-linux-musl` with `-march=i486 -mtune=i486 -Os`.
- **GUI:** kdrive Xfbdev (TinyX), bitmap fonts only (Terminus by default), dwm, st and the Stele browser.
- **Services on the disc:**
  - networking: `monolith-net`, `monolith-router`, nftables, dnsmasq, dhcpcd;
  - persistence: `monolith-persist`;
  - clock honesty: `monolith-time`, `monolith-time-check`;
  - advisory check: `monolith-advisory-check`;
  - the `monolith` help system.
- **Release assets:**
  - the ISO;
  - a CycloneDX SBOM;
  - SHA256SUMS;
  - `release-inputs.json` (§6);
  - `source-audit.tsv`: every shipped file with the package that built it in the release run, or its
    declared toolchain origin (B01);
  - a Sigstore SLSA provenance attestation whose subject is the ISO digest.

**Non-negotiable constraints.** Each has a check. None may be traded for factory convenience.

| Constraint | Meaning | Checked by |
|---|---|---|
| i486 | Every target binary runs on an i486. Boot tests run QEMU with `-cpu 486`. | O01 (ported), O02 (`EM_386`, no `EM_X86_64`) |
| Static musl | Every rootfs binary is statically linked against musl, and no dynamic loader ships on the disc. rc1 violates this (§3, D-all-static). The list of violations may only shrink, and it is empty before the first non-prerelease. | O02, R03 |
| Modest memory | The BIOS boot reaches a shell at 64 MB of RAM, the predecessor's floor. | O01 (ported `ram_mb: [64, 256]`) |
| Hardware compatibility | The predecessor's 17 boot modes pass, including the NIC, VGA and legacy fbdev matrices. `stele-acid2` waits for Stele's return (R05); the other 16 gate from MS1. | O01 |
| Reproducibility | Two stages. **From the first release:** every tag is built from source, offline, from pinned inputs fetched once and archived, and `release-inputs.json` records them, so the release can be rebuilt after upstream moves on. **From P02 on** (after the first release, before cutover): bit for bit, without exceptions. Two clean, separate builds from the same archived inputs produce ISOs with the same SHA-256, covering the whole ISO: kernel, initramfs, squashfs, bootloaders, ESP and filesystem metadata. A mismatch fails the tag, and nothing is published first. Attestations may differ between runs; the ISO bytes may not. | P01 and B01 (archived inputs, offline, source audit); P02 (equal digests) |
| CD-sized budget | The ISO fits on a 74-minute CD-R (681,984,000 bytes) now, and within the share the owner sets later (OD-16). | P01 (report and gate) |

The oracle (§7) defines what the product does. A README promise that no test proves is a gap (G01)
until it is tested or the promise is removed.

---

## 2. Principles

1. **A Gentoo derivative, not a framework.** Use the standard mechanism first. Write custom code only
   for a gap recorded in §5, naming the standard mechanism considered and why it falls short. Where no
   gap is recorded, use the standard approach or drop the feature.
2. **Port first, fix second.**
   - Predecessor code, recipes, tests and workflows carry over unchanged unless an acceptance criterion
     requires a change.
   - A replacement must name its demonstrated benefit.
   - Fixes for the study's verified bugs are separate, named criteria, so every behaviour change is
     visible.
3. **No storage vendor in the build path.**
   - Durable bytes live in an OCI registry (GHCR), reached with `oras` or `docker`, or in GitHub
     Releases.
   - The registry location is one variable. OCI is a standard protocol, so moving vendors means changing
     that variable and copying the data.
   - There is no storage abstraction layer.
4. **Every input is pinned, and a release's inputs are archived.** The tree commit, the builder image
   digest, tool versions and action SHAs are pinned. A release archives the distfiles it used and
   records every pin in `release-inputs.json`. That way it can be rebuilt after upstream has moved on.
5. **Success is honest.** A step reports success only for what it produced in this run, or for what it
   restored from a cache entry matching its inputs. Auth errors are failures, never cache misses. Missing
   or empty inputs fail gates.
6. **Iterate from binary packages; release from source.** Development builds reuse Portage binary
   packages. Tag builds compile every package that reaches the rootfs, in that run, and prove it with a
   file-by-file audit. The only exceptions are a declared list of toolchain files from the pinned
   builder image (D-tag-builds-from-source; B01).
7. **Publish last.** Nothing public moves until the full oracle and the gates (and, once P02 lands, the
   reproducibility gate) have passed for that exact digest. Attestation comes after them, then publication.
8. **Authored and generated are never the same file.** Builds never write into tracked files.
9. **Humans merge.** Bots and agents may open PRs. They never merge, approve or use `--admin`.

---

## 3. Doctrines

Hard rules about the product. Ids match `docs/study/doctrine.yaml`, which holds sources and history.

| Id | Rule | Enforced by |
|---|---|---|
| D-486-minimalism | Everything runs on an i486 with a few MB of RAM. Additions must justify themselves against that. | review; O01 RAM floor |
| D-all-static | The rootfs is statically linked. **Untrue in rc1**: util-linux, iproute2, dhcpcd, procps, tar, gawk and others are dynamic, and the musl loader ships. O02 enforces a shrinking allowlist, and R03 empties it. | O02, R03 |
| D-no-dynamic-loading-no-dlopen | No loadable plugins, no perl XS `.so`, no sqlite load-extension, no X modules. | O02 |
| D-no-python-on-target | No Python in the rootfs. Python is a host and builder tool only. | O02 |
| D-bitmap-fonts-no-freetype | No freetype, fontconfig or Xft on the disc. | O02 |
| D-no-readding-removed-things | Deliberately removed packages stay removed, through `package.mask`. The list is in doctrine.yaml. | B01 |
| D-clock-origin-1970 | The clock origin sentinel is 1970-01-01. | O01 |
| D-486-tier-regime | Kernel drivers are tiered: Tier 0 is `=y` and boot-critical, Tier 1 is `=m` in the initrd, Tier 2 is `=m` on the squashfs. | B02 |
| D-static-musl-cross-all-the-way | i486-linux-musl via crossdev. Host build tools are 32-bit-capable. | I03 |
| D-supply-chain-honesty | Releases come only through the verifiable pipeline, and the digest chain holds. | P01 |
| D-tag-builds-from-source | Tag builds compile every package in the rootfs from source in that run (empty `PKGDIR`, the image's preinstalled target packages re-merged, no `quickpkg`). No cached or preinstalled binary enters a release, except declared toolchain files from the pinned builder image. | B01 (source audit), P01 |
| D-revbump-on-overlay-change | Changing an overlay ebuild or its `files/` requires a `-rN` bump. | R04 (fast lane, before B01); R02 later (pkgcheck) |
| D-hand-authored-rootfs-files-owned | Every rootfs file is owned by a package or by a justified allowlist entry. | S01 |
| D-state-and-no-hidden-stderr | No `2>/dev/null` on paths that decide success. | review; S01 for the gates |
| D-two-epoch-pin-model | The builder pin and the runtime tree pin are separate. | I02, I03 |

---

## 4. Architecture

### 4.1 Pipeline (the predecessor's, ported)

```text
tree pin (gentoo-mirror commit, archived on GHCR) ─┐
builder image (GHCR, by digest) ───────────────────┤
configs/overlay  (the `monolith` Portage repository)┤
configs/portage  (distribution configuration) ─────┤
                                                   ▼
      build-packages.sh: cross-emerge world into the sysroot
        (dev: binpkgs restored from GHCR; tag: offline, no binpkgs, preinstalled re-merged)
        incl. sys-kernel/monolith-kernel (config from savedconfig)
                                                   ▼
      extract-packages.sh / build-rootfs.sh ─▶ squashfs
      build-initrd.sh ─▶ initrd
      build-iso.sh ─▶ hybrid ISO (ISOLINUX + GRUB EFI)
                                                   ▼
      boot tests (17 modes; 16 until R05)   artifact checks   SBOM ─▶ license, CVE, unowned gates

  tag only (P01; P02 adds build B and the comparison after MS2):
      fetch distfiles once ─▶ distfiles.tar + release-inputs.json   (only job with network)
          ├─▶ build A (runner 1, --network none) ─┐
          └─▶ build B (runner 2, --network none) ─┴─▶ sha256(A) == sha256(B) or fail   (P02)
      oracle + gates on build A's ISO ─▶ attest ─▶ push distfiles ─▶ GitHub prerelease
```

Within one CI run, files move between jobs with `actions/upload-artifact` and `download-artifact`, never
with `actions/cache` (T-run-rerun-reuses-cache). The predecessor used `actions/cache` for this
(`.github/workflows/build.yml:508-540`).

### 4.2 Repository layout

The predecessor's layout is kept, so ported scripts keep their paths.

| Path | Contents | Owner node |
|---|---|---|
| `configs/overlay/` | The `monolith` Portage repository: ebuilds, their `files/`, `metadata/`, `profiles/` (§4.3) | F01, R02 |
| `configs/portage/` | Distribution configuration, installed as the target's `/etc/portage`: `make.conf`, `bashrc`, `env/`, `package.*`, `profile/`, `savedconfig/`, `world`, `versions.lock`, `crossdev.lock` | F01, B01, B02 |
| `configs/attestation/` | Supply-chain policies: licence, CVE, CPE, unowned allowlist, schemas | S01 |
| `configs/` (other files) | `initrd-modules.txt`, boot art | F01 |
| `rootfs/` | Hand-authored files not yet owned by a package. It shrinks and is covered by S01's allowlist. | F01 |
| `scripts/`, `scripts/tests/` | Ported build, check and test scripts | every node |
| `Makefile`, `Dockerfile` | Ported entry points; the builder image definition | F01, I03 |
| `.github/workflows/` | Ported CI | F01, B03, P01 |
| `docs/` | Ported predecessor docs (`releasing.md`, `version-pinning.md`, `cve-gate.md`, `kernel-tiers.md`), plus this spec's graph, plan, reviews and study | F01 |
| `SPEC.md`, `nodes/` | Specification and node specs | owner |
| `AGENTS.md`, `CLAUDE.md`, `README.md`, `LICENSE` | Ported. AGENTS.md keeps the traps-and-recipes knowledge base. | F01 |
| `IMPORT.md` | What was ported from `b9f533b`, with a sha256 per file, and what has changed since | F01 |

### 4.3 The overlay is a conventional Portage repository

`configs/overlay/` is the `monolith` repository: `profiles/repo_name`, `metadata/layout.conf` with
`masters = gentoo`, and thin Manifests. It stays in this repository until there is a real maintenance
reason to extract it. Extraction must then be `git subtree split --prefix=configs/overlay` with no other
change. To keep that true:

- The overlay holds only what a Gentoo repository holds: ebuilds, `files/`, eclasses, metadata and
  profiles. Distribution policy lives in `configs/portage/`: USE, keywords, masks, env, savedconfig and
  world.
- No ebuild reads a path outside its own repository or the standard Portage locations.
  - Today the predecessor's kernel ebuild breaks this rule
    (`monolith-kernel-6.12.80-r8.ebuild:28-33,76-82`).
  - It reads and writes `${CONFIGS_DIR}/kernel.config` from a bind mount.
  - It falls back silently to `allnoconfig` when that file is missing.
  - B02 moves the file to the standard `savedconfig` location.
- Nothing outside the overlay writes into it, except Manifest generation (`ebuild … manifest` or
  `pkgdev manifest`).
- The overlay passes `pkgcheck scan` (R02), and any accepted warnings are listed.

### 4.4 Languages

These are ported as they are:
- build steps in POSIX `sh` or `bash`;
- host-side tools in Python 3 with PyYAML;
- the boot harness with `pexpect`, pinned on the CI host.

Python never runs on the target (D-no-python-on-target).

---

## 5. Standard mechanisms and the custom residue

This table lists every subsystem of the factory, the standard mechanism it uses and the custom code
that remains. A custom row must name the gap. Anything v0.3 specified that has no gap here is removed
(see `docs/reviews/2026-10-28-v0.4.md`).

| Area | Standard mechanism | Custom residue: gap → smallest solution |
|---|---|---|
| Toolchain | crossdev `i486-linux-musl`, in a Docker image built from a Gentoo stage3 | None new. The ported `Dockerfile`; rc1's image is adopted by digest (I03). |
| Packages | Gentoo ebuilds from the pinned tree; the `monolith` overlay for packages Gentoo lacks or that must be patched | None new. The ported `scripts/build-packages.sh` drives `${CHOST}-emerge`. |
| Distribution policy | `make.conf`, `package.use`/`.mask`/`.env`/`.accept_keywords`, `env/`, `bashrc`, a profile | None new. The ported `configs/portage/`; rc1's working static-link workarounds live in `bashrc` and `env/`. Policy is not moved into an overlay profile: no demonstrated benefit yet. |
| Versions | The pinned tree fixes every version; `package.mask` holds back removed packages | `versions.lock` (ported). Gap: the predecessor emerges world as `=cat/pkg-ver` atoms (`build-packages.sh:180-197`), so a tree bump moves no world version unreviewed. The ported `update-versions.sh` regenerates the file, and B01 fixes its 23-atom drift. |
| Binary cache | Portage `PKGDIR` with gpkg, `--usepkg`, `--binpkg-respect-use=y`, `--binpkg-changed-deps=y`, `--rebuild-if-unbuilt` | Gap: Portage cannot see edits to `make.conf`, `bashrc`, `env/`, `package.env` or the profile, nor to `savedconfig` contents. The smallest solution has three parts: (a) the cache tag includes a hash of those files, so changing one starts a cold cache; (b) the ported `savedconfig-cache.sh` marker handles savedconfig; (c) an overlay edit needs a revbump, the standard Gentoo rule, enforced in the fast lane by R04 before B01 relies on the cache. Transport: the ported `binpkg-store.sh` pushes the whole `PKGDIR` as one OCI artifact. A Portage binhost over HTTP (`binrepos.conf`) was considered. It needs a web host for about 2 GB, and GitHub Pages (P03) is sized for far less, so it waits until a host exists. Removed: v0.3's per-package fingerprints, sets, memo and seeding (I06). |
| Static dependents | `--rebuild-if-unbuilt` rebuilds the build-time reverse dependencies of anything built from source | None; it is one flag. Its behaviour with a cross `ROOT` is unverified, and B01's first slice checks it. Releases build from source, so a miss cannot reach a release. |
| Gentoo tree | A gentoo-mirror git commit (Portage `sync-type = git`); signed daily snapshots for later epochs | Gap: upstream prunes snapshots, and rc1's 20260810/11 snapshots now return 404. I02 archives the pinned tree as one OCI artifact, and the ported `sync-portage.sh` reads it by digest. |
| Distfiles | `DISTDIR`, Manifest checksums, `emerge --fetchonly`, `FETCHCOMMAND`; `cargo.eclass` `CRATES` for Rust packages | Gap: upstream URLs disappear, so an old release could not be rebuilt. P01 fetches every distfile once per tag into one archive, the release build uses only that archive with the network off, and P01 pushes it as one OCI artifact. There is no mirror service. `rl144` and `stele` fetch crates at build time today (`RESTRICT=network-sandbox`), so they leave `world` for the first release (B01). R05 moves them to `CRATES`, including the standard library's crates that `-Z build-std` needs, and brings them back before cutover. |
| Kernel | kbuild with a `savedconfig` (`savedconfig.eclass`) and `olddefconfig` | None new. The ported `verify-*.sh` assertions. v0.3's fragment split and tier tooling are removed. |
| Initrd | dracut and genkernel were considered | Gap: both assume a glibc, udev or systemd-style userland and are far larger than the 486 budget. The ported `build-initrd.sh` (busybox, deterministic cpio) stays. |
| Rootfs and ISO | Portage `ROOT` and VDB, squashfs-tools, xorriso, ISOLINUX, `grub-mkimage` | None new. The ported `extract-packages.sh`, `build-rootfs.sh` and `build-iso.sh`. |
| Boot tests | QEMU, OVMF, `pexpect`. openQA was considered, but it is a service to run and maintain for 17 serial-console modes. | The ported `boot-test.py` and `boot-test.yml`, unchanged. |
| Artifact doctrine checks | `scanelf` (pax-utils), the Portage VDB | The ported `static-audit.sh`, extended in O02 with `scanelf` for PT_INTERP, machine type and textrels. |
| SBOM | syft over the rootfs (Portage VDB cataloger) | The ported `enrich-sbom.py`. Gap: syft lacks CPEs for many Gentoo packages and records host paths. |
| Licences | Portage `ACCEPT_LICENSE` | The ported `check-licenses.py` over the SBOM, because it is in rc1's release path. Tightening `ACCEPT_LICENSE` to the same allowlist is a later, separate change. |
| CVEs | grype with its DB | The ported `check-cves.sh` policy (waivers, fix states); S01 fixes waiver expiry. |
| Unowned files | Portage VDB `CONTENTS` (`qfile -o` considered) | The ported `check-unowned.py`; S01 fixes its fail-open paths. |
| Provenance | `actions/attest-build-provenance`, `actions/attest-sbom`, `gh attestation verify` | None. These replace the ported `generate-provenance.py` with `actions/attest`. Benefit: the platform writes the provenance, not our script. |
| Source provenance | `--usepkg` off with an empty `PKGDIR`; the builder image's preinstalled target packages named on the emerge command line with `--oneshot`, which Portage always re-merges; the Portage VDB (`CONTENTS`, `BUILD_TIME`) | Gap: the predecessor `quickpkg`ed every installed sysroot package and shipped the whole sysroot, so nothing proved that shipped files were built in the release run. → B01's `source-audit.sh` maps every shipped file to a package merged from source in this run, or to a declared toolchain file. |
| Reproducibility | `SOURCE_DATE_EPOCH`, `KBUILD_BUILD_*`, `cpio --reproducible`, mksquashfs and xorriso date options, `mkfs.vfat --invariant`, `docker run --network none`; `sha256sum` decides; diffoscope only diagnoses a mismatch | Each nondeterminism is fixed at its source (P02, after the first release). There is no known-differences list. The one possible custom step is normalising Portage's VDB metadata on the disc, if Portage does not honour `SOURCE_DATE_EPOCH` for it (unverified). |
| CI | GitHub Actions, Dependabot for action SHAs, CODEOWNERS and branch protection | The ported workflows, without the AWS steps. |
| Storage | An OCI registry (GHCR) via `oras` or `docker`; GitHub Releases; Actions artifacts | None. No store interface, contract suite or backends; v0.3's F06 and I01 are removed. |
| Publishing | GitHub Releases, as the download page; GitHub Pages for the advisory feed | The advisory feed later (P03): static JSON on GitHub Pages under the OD-1 name, so no cloud key is stored. The dashboard and boot demo are out of scope. |
| Process | Branch protection, CODEOWNERS, PR review | None. v0.3's agent loop, identity CI, graph tooling and system inventory are removed. |

---

## 6. Pins and inputs

Pins stay where the predecessor kept them, and the ported `update-build-pins.sh` maintains them:
- `Makefile`;
- `Dockerfile` ARGs;
- workflow `env:`;
- `configs/portage/versions.lock`;
- `configs/portage/crossdev.lock`.

v0.4 changes three pins:

- **Tree:** `TREE_COMMIT` (a 40-hex gentoo-mirror commit) and `TREE_DIGEST` (the archived tree
  artifact). They replace the dated `BUILD_EPOCH` snapshot. The first pin is rc1's tree (OD-6).
- **Build time:** `SOURCE_DATE_EPOCH` is the committer time of `TREE_COMMIT`, so it moves only when the
  tree moves. Builds pass it explicitly; the value baked into the adopted builder image
  (`Dockerfile:37`) is not relied on.
- **Builder:** `BUILDER_DIGEST`, which is `sha256:ab04002a…` until M02 rebuilds the image. The toolchain
  code linked into every static binary (musl `libc.a`, `libgcc.a`, `libatomic.a`) and the few
  crossdev-owned sysroot files in B01's `bootstrap-exceptions.txt` come from this image. They are pinned by
  its digest, not rebuilt per release. Both of P02's builds use the same digest, so this does not affect
  ISO reproducibility.
- **Registry:** `REGISTRY`, by default `ghcr.io/tuckermclean/themonolith`. It is the only place the
  storage location appears.

GitHub Action references are full commit SHAs in the workflow `uses:` lines, and Dependabot updates them.

**Registry objects** (all under `${REGISTRY}`):

| Name | Contents | Mutability |
|---|---|---|
| `builder@sha256:…` | The builder image; rc1's adopted copy is tagged `rc1` | immutable |
| `gentoo-tree:<commit40>` | A `git archive` of the pinned tree, as one layer | immutable |
| `binpkgs:<cache-tag>` | The development `PKGDIR`, as one layer in the ported format. `<cache-tag>` is the first 16 hex digits of a sha256 over `BUILDER_DIGEST`, `TREE_COMMIT` and the global config files listed in §5. | overwritten by `main` builds only |
| `distfiles:<version>` | The archive the release build used, pushed after the gates | immutable |
| `rc1-binpkgs:20260811` | A preserved copy of rc1's cache, for comparison only; never restored | immutable |

**`release-inputs.json`** is written by P01's fetch job before the release build starts, and it is
published as a release asset. Together with the source commit and the distfiles archive, it is everything a
release build reads. It records:
- the version and the source commit;
- `TREE_COMMIT` and `TREE_DIGEST`;
- `BUILDER_DIGEST`;
- the digest of the `distfiles` artifact;
- `SOURCE_DATE_EPOCH`;
- the versions of the host tools that touch the ISO: xorriso, squashfs-tools, grub, syslinux, syft,
  grype, QEMU;
- the grype DB build time.

Nothing is deleted from the registry automatically. Public GHCR packages cost nothing today, so a
retention job is added only if storage starts to cost money.

---

## 7. Oracle and test tiers

The release oracle is the predecessor's, ported, plus the checks the study showed were missing.

- **Fast tier** (`make test`: seconds, no build, no network):
  - the ported `scripts/tests/` (23 files);
  - `bash -n`, shellcheck, `py_compile` and actionlint from `pr-validate.yml`;
  - each node's new fast tests.
- **Slow tier** (CI):
  - the build;
  - the 17 boot modes inherited from the predecessor (`stele-acid2` from R05 on): bios (at 64 and
    256 MB), uefi, toram, ahci, nvme, usb, virtio, nicless, nic, vga, fbdev-modprobe, nat, gui,
    stele-acid2, clock-epoch, clock-1996 and persist;
  - the artifact doctrine checks (O02);
  - the SBOM and the licence, CVE and unowned gates (S01).
- **rc1 lane.**
  - The boot tests, artifact checks and gates first run against the v0.1.0-rc1 ISO and SBOM, fetched by
    sha256, before this repository builds anything.
  - rc1 may fail a check because of a verified predecessor bug, for example the shipped musl loader. The
    check then records that as an expected rc1 failure with its study id.
  - That way the same check passes on rc1 and is strict on our builds.
- **Release reports** (assets of every release, P01):
  - the package and file difference against rc1's SBOM, with a reason for each added or removed package;
  - the ISO, squashfs, kernel and initrd sizes against the budget (§1);
  - the dynamic-binary allowlist with its remaining entries.
- **Reproducibility gate** (P02: after the first release, required before cutover; then every tag,
  before attestation):
  - Two from-source builds run on separate, clean runners, offline (`--network none`). They read only
    the source commit, `release-inputs.json` and the distfiles archive.
  - Their ISO SHA-256 digests must be equal, or the tag fails.
  - diffoscope runs only after a mismatch, to show where the bytes differ.
  - The same pipeline can be dispatched on any commit without publishing, so nondeterminism is found
    and fixed before a tag.
- **Harness interfaces.** Serial milestones, the ISOLINUX `serial` label and the GRUB entry `(serial)`
  are interfaces between the harness and the disc. Changing one means changing both.

---

## 8. CI, trust and release

- **Owner review.**
  - CODEOWNERS routes these paths to the owner: `.github/**`, `SPEC.md`, `docs/graph.yaml`,
    `configs/attestation/`, `Dockerfile` and the release scripts.
  - Branch protection requires the fast tier and owner review.
  - Together they replace v0.3's trusted-base checker and identity allowlist.
- **Merging.** Humans merge. Bots open PRs; they never merge, approve or use `--admin`. The
  predecessor's `pin-bump.yml` used `--admin`, and M01 removes it.
- **Release.**
  - A `vX.Y.Z[-rcN]` tag runs one fetch job, then an offline from-source build from what it fetched
    (P01). Once P02 lands, a second build runs beside it and the two ISOs must have equal SHA-256.
  - Attestation and the GitHub release (P01) are created only after every boot mode, check and gate on
    that ISO (and P02's comparison, once it lands) have passed. Nothing is pushed or published before
    that.
  - A suffixed tag is a prerelease and never "Latest".
  - The publish step re-verifies the digest chain: `sha256(ISO)` must equal the build's recorded digest
    (both builds' digests, once P02 lands), the SHA256SUMS entry, the SBOM's recorded ISO hash and the
    attestation subject (`gh attestation verify`).
- **Credentials.**
  - Workflows use `GITHUB_TOKEN` with the fewest `permissions:` they need.
  - There are no long-lived cloud keys.
  - The owner uses a personal token only transiently, in Step 0 of the plan.
- **Repository.**
  - This repository is `tuckermclean/themonolith`.
  - The predecessor is never renamed, because rc1's attestation names it.
  - At cutover the predecessor gets a pointer commit and is archived (X01).

---

## 9. Node spec template

Every `nodes/<ID>-<name>.md` follows this template.

```markdown
# <ID> — <name>

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical / later | <deps or none> | <nodes that depend on this> | <MSn or —> | S / M / L |

**Owns:** <paths this node creates or changes>
**Ports from linux-live-iso-factory@b9f533b:** <paths, carried unchanged unless a criterion says otherwise>
**Study refs:** <trap ids T-*, doctrine ids D-*, verified bugs>

## Purpose
2–4 sentences: what exists afterwards that did not before.

## Standard mechanism
What Gentoo or the ecosystem already provides here, and what this node uses. For any custom code:
the gap, and why the standard mechanism is not enough. "None" is the expected answer.

## Changes from the port
Each change to ported code, with the criterion that requires it. Everything else is carried unchanged.

## Gate
- **<ID>-AC-1** — <one testable statement>. *Verify:* <command or test>. *Tier:* fast | slow.

## Risks
Bullets: unverified third-party behaviour, open decisions (§10).
```

- AC ids are `<ID>-AC-<n>`, numbered from 1 and never reused.
- Sizes: S is under a day, M is two or three days, L is more.
- A node is done when every AC passes in CI on `main`.

---

## 10. Open decisions

These are owner decisions. A node that names one does not start until it is settled. Ids are stable,
and withdrawn ones are listed so that old references still resolve.

| Id | Question | Default if unanswered |
|---|---|---|
| OD-1 | The advisory URL is baked into every disc from the first release on. It must be a dedicated name that can be repointed for decades. The service behind it (P03) can come later. `themonolith.org` belongs to a third party, so it is out. Where is the name hosted? | `https://monolith.technomantics.com/`, served by GitHub Pages (a custom domain needs no stored cloud key, SPEC §8) |
| OD-2 | May a prerelease ship with a non-empty dynamic-binary allowlist? | Yes for prereleases, each entry with an issue. The list is empty before the first non-prerelease (R03). |
| OD-6 | First tree pin: rc1's tree, recovered from gentoo-mirror git, or a current tree? | rc1's tree; M01 bumps it after MS2 |
| OD-8 | First release version from this repository. | `v0.2.0-rc1` |
| OD-9 | Does a CVE in the builder image block a release? | Report-only; the owner reviews it at release |
| OD-11 | Bump PRs (M01) need a credential other than `GITHUB_TOKEN` so their checks run. Fine-grained PAT or GitHub App? | GitHub App |
| OD-12 | Hyper-V: provide manual evidence on real Hyper-V, or drop the README claim? | A dated manual evidence file |
| OD-13 | Keep the undocumented Tier-0 `NET_9P`, `NET_9P_FD` and `NETFS_SUPPORT` symbols? | Keep them, documented |
| OD-15 | If the CVE gate blocks the first release on rc1's 2026-08 tree: waive with an expiry, or bump the tree first? | Waive with a 30-day expiry; M01 follows |
| OD-16 | The distribution's share of the CD, once content projects claim space. | The whole 74-minute CD-R (681,984,000 bytes) until set |

Withdrawn in v0.4:
- OD-3 (language): settled by the port.
- OD-4 (bot identity): no bot commits.
- OD-5 (distfile scope): release `DISTDIR` only.
- OD-7 (CI): GitHub Actions.
- OD-10 (agent-loop licence): no loop in this repository.
- OD-14 (dashboard tests): no dashboard.

---

## 11. Conventions

- **Branches and PRs.** Use `node/<ID>-<name>` branches, one node per PR, squash-merged. The PR body has
  an AC → evidence table with CI run links.
- **Tests first.** Write the fast test first where one is possible. CI does not police commit order.
- **Authorship.** Commits are authored by `Tucker McLean <me@tuckermclean.com>`. Agent-assisted commits
  carry a `Co-Authored-By:` trailer.
- **Order of work.** `track: critical` nodes, the ancestors of P01, come first. `later` nodes start when
  their deps are done and a slot is free.
