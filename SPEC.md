# The Monolith — Specification

Version 0.5, draft of 2026-10-29. This document is the authority for the repository. Where a node spec (`nodes/<id>.md`) and this
document disagree, this document wins and the node spec is a defect. The dependency graph is
`docs/graph.yaml`, the capability ledger (where each capability lives, and whether it is ported or
built) is `docs/capabilities.md`, and the plan to the first release is `docs/first-release.md`. The study of the
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
**ports** the predecessor, test first:
- Each node ports the predecessor's tests for its capabilities first, adds tests for what its
  criteria cover and those tests do not, and then ports the predecessor code that passes them, or
  writes new code where the predecessor had none. Nothing is imported ahead of a test that needs it.
- Proven code and its tests are kept, not rewritten. Ported recipes, scripts, tests and workflows
  carry over unchanged unless a criterion requires a change.
- S3 is replaced by the GitHub-native storage the predecessor already half used.
- The bugs the study verified are fixed as named criteria.
- `docs/capabilities.md` records, for every capability, the node that owns it and whether it is ported,
  fixed, built, replaced or dropped.

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

The story is in [`MYTH.md`](MYTH.md): a disc handed to a ten-year-old at a 486 in 1996, a portal to
the future that is a full modern userland, and is built so that the whole system can be understood
and explained.

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
  - common hypervisors: QEMU/KVM, VirtualBox, and Hyper-V per OD-7;
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
  - `source-audit.tsv`: every sysroot file with the package that built it in the release run, or its
    declared toolchain origin (B01);
  - `rootfs-provenance.tsv`: every file of the final root filesystem as an unchanged package file, a
    file generated by a named step, a declared modification or a toolchain file (B01);
  - a Sigstore SLSA provenance attestation whose subject is the ISO digest.

**Non-negotiable constraints.** Each has a check. None may be traded for factory convenience.

| Constraint | Meaning | Checked by |
|---|---|---|
| i486 | Every target binary runs on an i486. Boot tests run QEMU with `-cpu 486`. | O01 (ported), O02 (`EM_386`, no `EM_X86_64`) |
| Static musl | Every rootfs binary is statically linked against musl, and no dynamic loader ships on the disc. rc1 violates this (§3, D-all-static). The list of violations may only shrink, and it is empty before the first non-prerelease. | O02, R03 |
| Modest memory | The BIOS boot reaches a shell at 64 MB of RAM, the predecessor's floor. | O01 (ported `ram_mb: [64, 256]`) |
| Hardware compatibility | The predecessor's 17 boot modes pass, including the NIC, VGA and legacy fbdev matrices. MS1 iteration ISOs run the other 16; `stele-acid2` needs Stele (R05). All 17 pass before the first release. | O01 |
| Reproducibility | Bit for bit, without exceptions, for every release. Two clean, separate builds from the same pinned and archived inputs produce ISOs with the same SHA-256. This covers the whole ISO: kernel, initramfs, squashfs, bootloaders, ESP and filesystem metadata. A mismatch fails the tag, and nothing is published first. Attestations may differ between runs; the ISO bytes may not. MS1 iteration ISOs need only be built from pinned inputs. | P02 (gate), B01 |
| Package set | Every release ships all 99 of the predecessor's `world` packages, `rl144` and `stele` included. MS1 iteration ISOs may leave out those two Rust packages until R05. | B01, R05, P01 (package-set check) |
| CD-sized budget | The ISO fits on a 74-minute CD-R (681,984,000 bytes) now, and within the share the owner sets later (OD-10). | P01 (report and gate) |

The oracle (§7) defines what the product does. A README promise that no test proves is a gap (G01)
until it is tested or the promise is removed.

---

## 2. Principles

1. **A Gentoo derivative, not a framework.** Use the standard mechanism first. Write custom code only
   for a gap recorded in §5, naming the standard mechanism considered and why it falls short. Where no
   gap is recorded, use the standard approach or drop the feature.
2. **Test first, then port; fix second.**
   - Preserve proven code and its tests; apply test-first development to the port and to every change.
     Nothing the predecessor built and verified is reinvented. Each node works in six steps:
     1. **Port the tests.** The predecessor's tests of the node's capabilities come over first, with
        only the harness and path adjustments the new repository needs, each one listed. Where a
        criterion changes behaviour a ported case asserts, that case changes to assert the criterion,
        and is listed too.
     2. **Fill the gaps.** Compare their coverage with the node's acceptance criteria and add tests for
        what is missing. Existing coverage stays, also where it is more detailed than the criteria.
     3. **RED.** The tests run in the new repository and fail. A missing implementation is a valid
        failure when the harness runs to its end and reports it in its own `FAIL` lines; a crash of
        the harness itself (a syntax error, an uncaught exception, a missing test tool) is not.
     4. **Port the code.** The predecessor's implementation comes over, changed only where a criterion
        requires it.
     5. **GREEN.** The tests pass, and no test accepted at RED was changed.
     6. **Review.** Someone independent checks coverage, the changes to ported code and that the RED
        tests are unchanged.
   - **Baseline.** Where practical, the RED tests also run against the predecessor's implementation:
     the RED commit with the node's ported paths checked out from `b9f533b`. Inherited behaviour passes
     there. The criteria a numbered change produces test known defects, and fail there as expected. Any
     other failure is investigated before GREEN. Each node's **Tests** section says what to expect, or
     why a baseline is not practical.
   - Ported code, recipes, tests and workflows carry over unchanged unless an acceptance criterion
     requires a change.
   - A node's fast tests stay in the fast lane. A later node that ports a file into their scope passes
     them, so a rule set by an early node holds for code that arrives after it.
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
   builder image (D-tag-builds-from-source; B01). MS1's ISO is for iteration: it is never published and
   never called a release.
7. **Publish last.** Nothing public moves until the reproducibility gate, the full oracle and the gates
   have passed for that exact digest. Attestation comes after them, then publication.
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
| D-tag-builds-from-source | Tag builds compile every package in the rootfs from source in that run (empty `PKGDIR`, the image's preinstalled target packages re-merged, no `quickpkg`). No cached or preinstalled binary enters a release, except declared toolchain files from the pinned builder image. | B01 (source audit), P02 |
| D-revbump-on-overlay-change | Changing an overlay ebuild or its `files/` requires a `-rN` bump. | R04 (fast lane, before B01); R02 later (pkgcheck) |
| D-hand-authored-rootfs-files-owned | Every rootfs file is owned by a package or by a justified allowlist entry. | S01; B01 (provenance mode: owned files unchanged, each entry names its source) |
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
      boot tests (17 modes; 16 on MS1 ISOs)   artifact checks   SBOM ─▶ license, CVE, unowned gates

  tag only (P02, then P01):
      fetch distfiles once ─▶ distfiles.tar + release-inputs.json   (only job with network)
          ├─▶ build A (runner 1, --network none) ─┐
          └─▶ build B (runner 2, --network none) ─┴─▶ sha256(A) == sha256(B) or fail
      oracle + gates on build A's ISO ─▶ attest ─▶ push distfiles ─▶ GitHub prerelease
```

Within one CI run, files move between jobs with `actions/upload-artifact` and `download-artifact`, never
with `actions/cache` (T-run-rerun-reuses-cache). The predecessor used `actions/cache` for this
(`.github/workflows/build.yml:508-540`).

### 4.2 Repository layout

The predecessor's layout is kept, so ported scripts keep their paths.

| Path | Contents | Owner node |
|---|---|---|
| `configs/overlay/` | The `monolith` Portage repository: ebuilds, their `files/`, `metadata/`, `profiles/` (§4.3) | B01, R01 (`monolith-base`), B02 (kernel), R05 (Rust packages), R02 |
| `configs/portage/` | Distribution configuration, installed as the target's `/etc/portage`: `make.conf`, `bashrc`, `env/`, `package.*`, `profile/`, `savedconfig/`, `world`, `versions.lock`, `crossdev.lock` | B01, B02, I03, R03 |
| `configs/attestation/` | Supply-chain policies: licence, CVE, CPE, unowned allowlist, schemas | S01 |
| `configs/` (other files) | `initrd-modules.txt`, boot art | B03 |
| `rootfs/` | Hand-authored files not yet owned by a package. It shrinks and is covered by S01's allowlist. | B03 |
| `scripts/`, `scripts/tests/` | Ported build, check and test scripts | every node |
| `Makefile` | Ported entry points. F01 creates it with the fast tier; each node ports the targets its tests need. | every node |
| `Dockerfile` | The builder image definition | I03, M02 |
| `.github/workflows/` | Ported CI | F01, O01, S01, B03, P02, P01, M01, M02, P03 |
| `docs/` | Ported predecessor docs, each with its node (`kernel-tiers.md` B02, `cve-gate.md` S01, `version-pinning.md` M01, `releasing.md` P01), plus this spec's graph, capability ledger, plan, reviews and study | as listed |
| `SPEC.md`, `nodes/`, `docs/capabilities.md` | Specification, node specs and the capability ledger | owner |
| `AGENTS.md`, `CLAUDE.md` | `AGENTS.md` opens with this repository's working notes (layout, constraints, spec editing, what not to touch, Git conventions), followed by the predecessor's traps-and-recipes knowledge base (F01). `CLAUDE.md` points agents to it. | owner, F01 |
| `README.md`, `LICENSE` | This repository's README; the predecessor's promises arrive with the tests that prove them (G01). `LICENSE` is the predecessor's, byte for byte. | owner, G01, X01 |
| `toolbox/` | The test toolbox image; `toolbox/run`, which runs any test tier locally; `toolbox/ci`, which runs and lints the workflows | owner |
| `.claude/` | Agent tooling: the `/node` skill, role agents, guard hook, spec checker | owner |

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

This table lists every subsystem, the standard mechanism it uses and the custom code that remains. A
custom row must name the gap. Anything with no gap here is not built.

| Area | Standard mechanism | Custom residue: gap → smallest solution |
|---|---|---|
| Toolchain | crossdev `i486-linux-musl`, in a Docker image built from a Gentoo stage3 | None new. The ported `Dockerfile`; rc1's image is adopted by digest (I03). |
| Packages | Gentoo ebuilds from the pinned tree; the `monolith` overlay for packages Gentoo lacks or that must be patched | None new. The ported `scripts/build-packages.sh` drives `${CHOST}-emerge`. |
| Distribution policy | `make.conf`, `package.use`/`.mask`/`.env`/`.accept_keywords`, `env/`, `bashrc`, a profile | None new. The ported `configs/portage/`; rc1's working static-link workarounds live in `bashrc` and `env/`. Policy is not moved into an overlay profile: no demonstrated benefit yet. |
| Versions | The pinned tree fixes every version; `package.mask` holds back removed packages | `versions.lock` (ported). Gap: the predecessor emerges world as `=cat/pkg-ver` atoms (`build-packages.sh:180-197`), so a tree bump moves no world version unreviewed. The ported `update-versions.sh` regenerates the file, and B01 fixes its 23-atom drift. |
| Binary cache | Portage `PKGDIR` with gpkg, `--usepkg`, `--binpkg-respect-use=y`, `--binpkg-changed-deps=y`, `--rebuild-if-unbuilt` | Gap: Portage cannot see edits to `make.conf`, `bashrc`, `env/`, `package.env` or the profile, nor to `savedconfig` contents. The smallest solution has three parts: (a) the cache tag includes a hash of those files, so changing one starts a cold cache; (b) the ported `savedconfig-cache.sh` marker handles savedconfig; (c) an overlay edit needs a revbump, the standard Gentoo rule, enforced in the fast lane by R04 before B01 relies on the cache. Transport: the ported `binpkg-store.sh` pushes the whole `PKGDIR` as one OCI artifact. A Portage binhost over HTTP (`binrepos.conf`) was considered. It needs a web host for about 2 GB, and GitHub Pages (P03) is sized for far less, so it waits until a host exists. |
| Static dependents | `--rebuild-if-unbuilt` rebuilds the build-time reverse dependencies of anything built from source | None in the build; it is one flag. Its behaviour with a cross `ROOT` and a restored cache is unverified, so B01's integration test (`static-rebuild.itest.sh`, a two-package fixture overlay built in the pinned builder) proves a revbump or `package.use` change rebuilds the cached consumer. Releases build from source, so a miss cannot reach a release. |
| Gentoo tree | A gentoo-mirror git commit (Portage `sync-type = git`); signed daily snapshots for later epochs | Gap: upstream prunes snapshots, and rc1's 20260810/11 snapshots now return 404. I02 archives the pinned tree as one OCI artifact, and the ported `sync-portage.sh` reads it by digest. |
| Distfiles | `DISTDIR`, Manifest checksums, `emerge --fetchonly`, `FETCHCOMMAND`; `cargo.eclass` `CRATES` for Rust packages | Gap: upstream URLs disappear, so an old release could not be rebuilt. P02 fetches every distfile once per tag into one archive, both release builds use only that archive with the network off, and P01 pushes it as one OCI artifact. There is no mirror service. `rl144` and `stele` fetch crates at build time today (`RESTRICT=network-sandbox`), so MS1 iteration ISOs leave them out (B01). R05 moves them to `CRATES`, including the standard library's crates that `-Z build-std` needs, and brings them back before the first release. |
| Kernel | kbuild with a `savedconfig` (`savedconfig.eclass`) and `olddefconfig` | None new. The ported `verify-*.sh` assertions. |
| Initrd | dracut and genkernel were considered | Gap: both assume a glibc, udev or systemd-style userland and are far larger than the 486 budget. The ported `build-initrd.sh` (busybox, deterministic cpio) stays. |
| Rootfs and ISO | Portage `ROOT` and VDB, squashfs-tools, xorriso, ISOLINUX, `grub-mkimage` | None new. The ported `extract-packages.sh`, `build-rootfs.sh` and `build-iso.sh`. |
| Boot tests | QEMU, OVMF, `pexpect`. openQA was considered, but it is a service to run and maintain for 17 serial-console modes. | The ported `boot-test.py` and `boot-test.yml`, unchanged. |
| Artifact doctrine checks | `scanelf` (pax-utils), the Portage VDB | The ported `static-audit.sh`, extended in O02 with `scanelf` for PT_INTERP, machine type and textrels. |
| SBOM | syft over the rootfs (Portage VDB cataloger) | The ported `enrich-sbom.py`. Gap: syft lacks CPEs for many Gentoo packages and records host paths. |
| Licences | Portage `ACCEPT_LICENSE` | The ported `check-licenses.py` over the SBOM, because it is in rc1's release path. Tightening `ACCEPT_LICENSE` to the same allowlist is a later, separate change. |
| CVEs | grype with its DB | The ported `check-cves.sh` policy (waivers, fix states); S01 fixes waiver expiry. |
| Unowned files | Portage VDB `CONTENTS` (`qfile -o` considered) | The ported `check-unowned.py`; S01 fixes its fail-open paths. B01 adds its provenance mode: owned files must match their `CONTENTS` MD5, and each allowlist entry names the step that generates it. |
| Provenance | `actions/attest-build-provenance`, `actions/attest-sbom`, `gh attestation verify` | None. These replace the ported `generate-provenance.py` with `actions/attest`. Benefit: the platform writes the provenance, not our script. |
| Source provenance | `--usepkg` off with an empty `PKGDIR`; the builder image's preinstalled target packages named on the emerge command line with `--oneshot`, which Portage always re-merges; the Portage VDB (`CONTENTS`, `BUILD_TIME`) | Gap: the predecessor `quickpkg`ed every installed sysroot package and shipped the whole sysroot, so nothing proved that shipped files were built in the release run. → B01's `source-audit.sh` maps every sysroot file to a package merged from source in this run, or to a declared toolchain file, and the unowned gate's provenance mode accounts for every file of the final root filesystem. |
| Reproducibility | `SOURCE_DATE_EPOCH`, `KBUILD_BUILD_*`, `cpio --reproducible`, mksquashfs and xorriso date options, `mkfs.vfat --invariant`, `docker run --network none`; `sha256sum` decides; diffoscope only diagnoses a mismatch | Each nondeterminism is fixed at its source (P02). There is no known-differences list. The one possible custom step is normalising Portage's VDB metadata on the disc, if Portage does not honour `SOURCE_DATE_EPOCH` for it (unverified). |
| CI | GitHub Actions, Dependabot for action SHAs, CODEOWNERS and branch protection | The ported workflows, without the AWS steps. |
| Storage | An OCI registry (GHCR) via `oras` or `docker`; GitHub Releases; Actions artifacts | None. No store interface, contract suite or backends. |
| Publishing | GitHub Releases, as the download page; GitHub Pages for the advisory feed | The advisory feed later (P03): static JSON on GitHub Pages under the OD-1 name, so no cloud key is stored. The dashboard and boot demo are out of scope. |
| Process | Branch protection, CODEOWNERS, PR review; Claude Code skills, subagents and hooks | Development tooling, outside the product: the `/node` skill, three role agents (tester, implementer, reviewer), a guard hook and the spec checker in `.claude/`, adapted from strange-company. No agent platform, identity CI or system inventory. |

---

## 6. Pins and inputs

Pins stay where the predecessor kept them, and the ported `update-build-pins.sh` maintains them:
- `Makefile`;
- `Dockerfile` ARGs;
- workflow `env:`;
- `configs/portage/versions.lock`;
- `configs/portage/crossdev.lock`.

Three pins differ from the predecessor's:

- **Tree:** `TREE_COMMIT` (a 40-hex gentoo-mirror commit) and `TREE_DIGEST` (the archived tree
  artifact). They replace the dated `BUILD_EPOCH` snapshot. The first pin is rc1's tree (OD-3).
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
| `distfiles:<version>` | The archive both release builds used, pushed after the gate | immutable |
| `rc1-binpkgs:20260811` | A preserved copy of rc1's cache, for comparison only; never restored | immutable |

**`release-inputs.json`** is written by P02's fetch job before either release build starts, and it is
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
  - the predecessor's `scripts/tests/` (21 files once ported; its two storage-retention tests are
    dropped), each ported first by the node that ports the code it tests;
  - each node's new tests for criteria the ported tests do not cover;
  - `bash -n`, shellcheck, `py_compile`, YAML well-formedness and actionlint from `pr-validate.yml`;
- **Slow tier** (locally, and in CI):
  - the build, in the builder image;
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
- **Reproducibility gate** (P02, every tag, before attestation):
  - Two from-source builds run on separate, clean runners, offline (`--network none`). They read only
    the source commit, `release-inputs.json` and the distfiles archive.
  - Their ISO SHA-256 digests must be equal, or the tag fails.
  - diffoscope runs only after a mismatch, to show where the bytes differ.
  - The same pipeline can be dispatched on any commit without publishing, so nondeterminism is found
    and fixed before a tag.
- **Where tests run.** Every tier runs locally. `toolbox/run` runs a command in the test toolbox
  (`toolbox/Containerfile`: Debian by digest and snapshot date, QEMU, OVMF, pexpect, PyYAML,
  shellcheck, actionlint, oras, squashfs-tools, xorriso, scanelf), with the checkout mounted. Package
  builds and the SBOM gates run in the builder image, pulled by digest. CI runs the same commands, and
  only what needs GitHub itself (registry pushes, attestation, tag pipelines) is CI-only.
- **CI parity.** A workflow file is the one definition of its jobs, and `toolbox/ci run <workflow> [<job>]`
  runs it locally with the same shells, `env:`, step outputs, `if:` conditions, `needs` order, matrix
  and timeouts. To make that hold, every workflow that can trigger (any trigger but `workflow_dispatch`,
  and what those call) passes `toolbox/ci lint`, which `pr-validate.yml` runs:
  - each command in a `run:` step is `toolbox/run -- <cmd>`, or `make <target>` for a target that runs
    the builder image; logic lives in `scripts/`, not in YAML;
  - no `${{ }}` inside `run:` (values come through `env:`), and expressions elsewhere are plain context
    paths; `if:` uses status functions and `==`/`!=` comparisons;
  - GitHub-hosted ubuntu runners, no job containers or services, no `apt-get`, `pip` or `setup-*`
    actions: the toolbox carries every tool;
  - `uses:` only from the short list `toolbox/ci` knows. Checkout and artifact or cache transfer are
    local no-ops, since jobs share the checkout; attestation, registry logins and anything reading a
    secret are reported as CI-only and skipped.
  - QEMU runs under TCG in both places. `-cpu 486` is enforced only by emulation, so `toolbox/run` passes
    no `/dev/kvm`.

  A node that re-enables or changes a workflow brings it into this form. What still differs is the host
  around the container (runner kernel, CPU speed, docker or podman for the builder image) and the
  CI-only steps; a test that depends on speed carries a timeout with margin for the slower of the two.
- **Harness interfaces.** Serial milestones, the ISOLINUX `serial` label and the GRUB entry `(serial)`
  are interfaces between the harness and the disc. Changing one means changing both.

---

## 8. CI, trust and release

- **Owner review.**
  - CODEOWNERS routes these paths to the owner: `.github/**`, `SPEC.md`, `docs/graph.yaml`,
    `configs/attestation/`, `Dockerfile` and the release scripts.
  - Branch protection requires the fast tier and owner review.
- **Merging.** Humans merge. Bots open PRs; they never merge, approve or use `--admin`. The
  predecessor's `pin-bump.yml` used `--admin`, and M01 removes it.
- **Release.**
  - A `vX.Y.Z[-rcN]` tag runs P02's gate: one fetch job, then two offline from-source builds whose ISOs
    must have equal SHA-256.
  - Attestation and the GitHub release (P01) are created only after the gate, every boot mode, check
    and gate on that ISO, and P01's package-set check have passed. Nothing is pushed or published before
    that.
  - A suffixed tag is a prerelease and never "Latest".
  - The publish step re-verifies the digest chain: `sha256(ISO)` must equal the build's recorded digest
    (both builds' digests), the SHA256SUMS entry, the SBOM's recorded ISO hash and the
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
**Ports from linux-live-iso-factory@b9f533b:** <the predecessor tests this node ports first, then the paths it brings in to pass them; carried unchanged unless a criterion says otherwise. Each matches a `docs/capabilities.md` row.>
**Study refs:** <trap ids T-*, doctrine ids D-*, verified bugs>

## Purpose
2–4 sentences: what exists afterwards that did not before.

## Standard mechanism
What Gentoo or the ecosystem already provides here, and what this node uses. For any custom code:
the gap, and why the standard mechanism is not enough. "None" is the expected answer.

## Tests
- **Ported first:** the predecessor tests this node ports, with each harness or path adjustment and
  each case a criterion changes; or none, and why.
- **Added:** the new tests for criteria the ported tests do not cover.
- **Baseline:** what the RED tests show against `b9f533b`'s implementation, or why that is not
  practical.

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

These are owner decisions. A node that names one does not start until it is settled.

| Id | Question | Default if unanswered |
|---|---|---|
| OD-1 | The advisory URL is baked into every disc from the first release on. It must be a dedicated name that can be repointed for decades. The service behind it (P03) can come later. `themonolith.org` belongs to a third party, so it is out. Where is the name hosted? | `https://monolith.technomantics.com/`, served by GitHub Pages (a custom domain needs no stored cloud key, SPEC §8) |
| OD-2 | May a prerelease ship with a non-empty dynamic-binary allowlist? | Yes for prereleases, each entry with an issue. The list is empty before the first non-prerelease (R03). |
| OD-3 | First tree pin: rc1's tree, recovered from gentoo-mirror git, or a current tree? | rc1's tree; M01 bumps it after MS2 |
| OD-4 | First release version from this repository. | `v0.2.0-rc1` |
| OD-5 | Does a CVE in the builder image block a release? | Report-only; the owner reviews it at release |
| OD-6 | Bump PRs (M01) need a credential other than `GITHUB_TOKEN` so their checks run. Fine-grained PAT or GitHub App? | GitHub App |
| OD-7 | Hyper-V: provide manual evidence on real Hyper-V, or drop the README claim? | A dated manual evidence file |
| OD-8 | Keep the undocumented Tier-0 `NET_9P`, `NET_9P_FD` and `NETFS_SUPPORT` symbols? | Keep them, documented |
| OD-9 | If the CVE gate blocks the first release on rc1's 2026-08 tree: waive with an expiry, or bump the tree first? | Waive with a 30-day expiry; M01 follows |
| OD-10 | The distribution's share of the CD, once content projects claim space. | The whole 74-minute CD-R (681,984,000 bytes) until set |

**Tracked, outside MS1.** These stay open on purpose. None is a gate for MS1, and none adds a node.

| Concern | Checked today | Where it is tracked |
|---|---|---|
| i486 instruction set | `-march=i486` (§1), QEMU `-cpu 486` boots (O01), `EM_386` (O02), I03's in-image link check. `EM_386` does not tell i486 code from i686 code, and a boot runs only the code it reaches. | G01 (the README's 486 claim); a scan for post-486 instructions is the candidate test. |
| 8 MB of RAM | The aim (MYTH.md). The tested floor is 64 MB (§1). | After MS2. Making it a constraint is a §1 change plus an O01 `ram_mb` mode. |
| Behavioural parity with rc1 | O01 runs the 17 modes on rc1 first; S01 reproduces rc1's SBOM; P01's `rc1-diff.md`. | G01 for README promises no mode tests. |
| Toolchain reproducibility | The builder is trusted by digest (I03); both P02 builds use the same digest. | M02 rebuilds the image from pinned inputs. |

---

## 11. Conventions

- **Branches and PRs.** Use `node/<ID>-<name>` branches, one node per PR, squash-merged. The PR body has
  an AC → evidence table with CI run links.
- **Porting.** The predecessor's history stays in the predecessor; nothing here has a predecessor
  commit as a parent. A commit that ports predecessor code names each source as `path:line` at
  `b9f533b` in its message, and the PR body lists them. A ported file is copied from
  `git show b9f533b:<path>`, then changed only by the node's numbered changes, so `git diff` against
  that blob shows exactly the changes. A ported test differs from its blob only by the harness and
  path adjustments its RED commit lists.
- **Tests first.** The RED commit (ported tests plus new tests) comes before the code, following the
  six steps of §2.2. Write the fast test first where one is possible. CI does not police commit order.
- **Git.** Existing history and attribution are preserved; historical commits are not rewritten for
  cosmetic reasons. New commits use the configured Git identity. AI assistance may be noted in commit
  messages or PR descriptions.
- **Order of work.** MS1's nodes (B03 and its ancestors) come first, then the rest of the
  `track: critical` nodes, the ancestors of P01. `later` nodes start when their deps are done and a slot
  is free.
