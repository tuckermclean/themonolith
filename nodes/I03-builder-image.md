# I03 — builder-image

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| I | I01 | B01, I04, I05, I06, M02, R02, S03 | — (feeds MS1) | L |

**Owns:** `image/Dockerfile` (the predecessor's, verbatim, unused until M02), `image/legacy/build-image.mk` (verbatim excerpt of `Makefile:255-345`, unused until M02), `image/IMPORT` (source commit and sha256 of both), `image/host-tools.list`, `image/required-host-tools.txt`, `image/checks/` (in-image check scripts: `cross-toolchain.sh`, `host-tools.sh`, `inventory.sh`, `env.sh`), `factory/bin/builder-image` (`ensure`, `inventory`, `declared-check`, `check-pin`), `factory/bin/install-tool` (host-side installer of pinned binaries: syft, grype), `.github/workflows/builder-image.yml` (adoption checks, no build), `tests/fast/builder-*.test.sh`, `tests/fast/image-install-tool.test.sh`, the `builder_image` and `tools.syft`, `tools.grype` sections of `pins/pins.yaml` (format in I05).
**Carries from linux-live-iso-factory@b9f533b:** the built image itself, by digest (`ghcr.io/tuckermclean/monolith-builder@sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa`, tag `20260810-d9d08d1c7422`, copied to `ghcr.io/tuckermclean/themonolith/builder:rc1` in Step 0). The `Dockerfile` (whole, 209 lines) and the `Makefile` `build-image` block (`:255-345`, crossdev block `:295-325`) are imported verbatim for M02, not rebuilt here. `configs/portage/crossdev.lock` goes to I05.
**Study refs:** D-static-musl-cross-all-the-way, D-two-epoch-pin-model, T-libatomic-static, T-builder-image-tag-not-pushed, T-rust-i486-musl, T-xcb-proto-python, T-makewhatis-oom, recipes.yaml notes_general (hidden host-python need), build.yaml hazards (stage3 by tag; syft/grype from `main`; rustup init script unpinned; `docker commit` not reproducible) and contradictions (GRUB "pinned to 2.12" claim; stale `gcc-14.4.9999` mask), `docker.base-tools`, `make.build-image`; `docs/first-attested-build.md` (the rc1 builder row, Risks).

## Purpose
After this node the build uses rc1's builder image, taken by digest from our own namespace, and a declared list says what is inside it. A slow test proves the declared list equals what the image actually contains. The image's toolchain was built from a Gentoo tree that is now gone, and the Dockerfile cannot yet be rebuilt (it pulls `main`-branch install scripts and a stage3 by tag). Rebuilding is M02's work and is not on the path to the first attested build. Adopting the image removes about 1.5 hours of crossdev build from every first run and gives the rest of the pipeline a fixed digest to pin.

## Scope
In:
- Pin and pull the adopted image by digest; no tag is ever trusted.
- Import the predecessor's `Dockerfile` and build-image make block verbatim, with their sha256, for M02.
- Inventory what the image contains and declare it in `image/host-tools.list`; check declared against actual.
- Checks that the adopted image has the cross toolchain, the hidden host tools and the environment the recipes need.
- Host-side pinned installs of `syft` and `grype` (and, in I01, `oras`): these run on the runner, outside the image.

Out:
- Building or rebuilding the image, stage3 ingest, in-image pinned installs, the rust mirror, image labels, pushing: M02.
- Tree ingest and extraction: I02. The image carries no runtime tree; B01 mounts it.
- Distfiles for host tools and crossdev: I04 (fetch-on-record), M02 (offline image rebuild).
- The pin ledger schema and `crossdev.lock` regeneration: I05, M02.
- Running package builds, host `package.mask` mirroring (T-glib-docutils-eigen-live): B01.
- Scanning the image for CVEs: S03. Attesting its digest: S05.
- ISO tools' use (xorriso, grub, mksquashfs invocations): B04, B05. Only their presence and versions are checked here.

## Design
**Adoption.** The image was built by the predecessor from `b9f533b`'s `Dockerfile` and `docker commit` of a crossdev container. The registry tag `20260810-d9d08d1c7422` is the predecessor's `TOOLCHAIN_EPOCH-<hash12>`, and the hash reproduces here: `git show b9f533b:Dockerfile | grep -vE '^ARG BUILD_EPOCH=|^ENV SOURCE_DATE_EPOCH=' | sha256sum | cut -c1-12` prints `d9d08d1c7422`. So the image is what that Dockerfile and `crossdev.lock` produced, to the extent `docker commit` allows. Step 0 copies it with `oras cp`, which keeps the digest. `pins/pins.yaml` records `builder_image: {repo: ghcr.io/tuckermclean/themonolith/builder, digest: sha256:ab04002a…}`. Consumers use `<repo>@<digest>`; the `:rc1` tag is a convenience that no code reads. Rejected: rebuilding now. The toolchain tree it was built from is pruned upstream, and a rebuild from a current tree would change every compiled byte and void rc1's cache.

**`builder-image` CLI (POSIX sh).**
- `ensure`: `docker pull <repo>@<digest>` and confirm `docker image inspect` reports that digest in `RepoDigests`. A failed pull exits 1 naming repo and digest. There is no local-rebuild fallback (the predecessor silently rebuilt, `Makefile:269,275`). The pull is anonymous when the package is public (I01).
- `check-pin`: the pinned digest resolves in the registry (`docker manifest inspect`), and the image's config still has the expected `Env` (AC-14).
- `inventory`: runs `image/checks/inventory.sh` in the image and prints JSON: world atoms (`/var/lib/portage/world`), `qlist -Iv` of everything installed, the cross packages (`cross-i486-linux-musl/*`), files in `/usr/local/bin` and `/opt/cargo/bin` with `--version` output, the rustup toolchains, python modules importable by `python3`, `gcc -m32` result, the Docker `Env`, and whether `/var/db/repos/gentoo` exists.
- `declared-check <inventory.json>`: compares the inventory with `image/host-tools.list`; lists undeclared and missing entries and exits 1 on any.

**Declared list (`image/host-tools.list`).** One line per entry: `kind  name  pin  check  reason`. `kind` is one of `portage` (an atom we rely on), `stage3` (in the stage3 base world; present, not relied on), `cross` (a crossdev package), `binary` (a file outside portage), `rustup`, `python` (a module). For `portage` the pin is "the toolchain tree of 20260810", not a per-atom version: the image fixes the versions, and the inventory records them. Rejected: per-atom pins; they fight the epoch model argued at `Dockerfile:81-98`. `check` is a command run inside the image. The first slice builds the list from the inventory and the predecessor's Dockerfile atoms (`Dockerfile:99-122`), then a human reviews each `reason`. Required entries (`image/required-host-tools.txt`), including the hidden ones:
- `python3` for gpm and nethack Makefile surgery in `configs/portage/bashrc:115,282`; host only (D-no-python-on-target).
- `dev-python/pyyaml`, `x11-base/xcb-proto` for host codegen (T-xcb-proto-python, `Dockerfile:153`).
- `gcc` with `-m32` for `CFLAGS_FOR_BUILD="-O2 -m32"` (`make.conf:25`) used by nethack's DLB tools; check: compile and run a 32-bit program and assert `sizeof(long)==4` (`Dockerfile:55-64`).
- `app-text/mandoc` for host `makewhatis` in `bashrc:344-357` (T-makewhatis-oom; the 60 s timeout lives in the hook, B01).
- `sys-libs/ncurses` (host `tic`), `dev-build/cmake`, `sys-devel/{crossdev,flex,bison,bc}`, `dev-libs/elfutils`, `sys-boot/{syslinux,grub}`, `dev-libs/libisoburn` (xorriso), `sys-fs/{mtools,dosfstools,squashfs-tools}`, `app-arch/{xz-utils,cpio,zstd}`, `net-misc/rsync`, `sys-apps/file`, `dev-vcs/git`, `app-portage/{gentoolkit,eix}`.
- `binary`: `syft`, `grype` (installed by `main`-branch scripts at `Dockerfile:128-142`; present in the image, not relied on, see Host tools). `rustup`: `nightly-2026-07-15` with `rust-src` (the date also appears as `RUST_NIGHTLY` in the rl144 and stele ebuilds; I05 checks equality). `cross`: `cross-i486-linux-musl/{gcc,binutils,musl,linux-headers}`.

**Host tools run outside the image.** The pipeline uses `oras` (I01), `syft` and `grype` from pinned, sha256-checked binaries installed on the runner by `factory/bin/install-tool` (`install-oras` for oras), with `version`, `url` and `sha256` in `pins.yaml: tools.*` (I05). It never runs the image's copies, which came from unpinned `main` scripts. To keep S01's SBOM comparable with rc1's `bom.cdx.json`, the first `tools.syft` and `tools.grype` versions are the ones the inventory finds in the image; moving them later is a deliberate S01 or S03 change. Rejected: using the image's copies (their provenance is `main` of 2026-08 and nothing pins them) and rebuilding the image to pin them (M02).

**Environment baked in the image config** (from `Dockerfile:158-160` and `Makefile:321-324`): `CROSS_TARGET=i486-linux-musl`, `CROSS_COMPILE=i486-linux-musl-`, `BUILD_DIR=/build`, `CONFIGS_DIR=/configs`, `OUTPUT_DIR=/output`, `RUSTUP_HOME=/opt/rustup`, `PATH` with `/opt/cargo/bin`. Overlay ebuilds read `CONFIGS_DIR` and `CROSS_COMPILE` (recipes.yaml notes_general). **Known deviation:** the image also bakes `SOURCE_DATE_EPOCH=1786406400` (`Dockerfile:37`). Because the first tree pin is rc1's (build epoch 20260811, which derives that value), it is correct for now; B01 must still pass `SOURCE_DATE_EPOCH` at `docker run` so a later `BUILD_EPOCH` bump is not silently ignored. M02 removes the ENV.

**Trap in the adopted image (unverified).** The predecessor Dockerfile ran `emerge-webrsync --revert=20260810` and never removed `/var/db/repos/gentoo`, so the image likely carries the toolchain tree. B01 mounts the runtime tree over it, and the inventory records which it is (AC-17). Until M02 removes it, a build that forgets to mount the runtime tree would silently use the 20260810 tree; B01-level checks (tree commit printed in the build log) guard that.

## Traps and doctrines preserved
- **T-libatomic-static** (no `libatomic.a` makes iperf3, irssi/glib, w3m fail at static link; cost a 2 h rebuild): AC-6 checks the adopted image still has it. The fix itself (`EXTRA_ECONF`, `Dockerfile:191-202`) is carried verbatim for M02.
- **D-static-musl-cross-all-the-way** (crossdev toolchain, host tools 32-bit capable): AC-6, AC-8.
- **T-builder-image-tag-not-pushed**: consumers pull by digest only, and the digest is known and fixed: AC-13, AC-16.
- **Hidden host-tool needs** (python3, makewhatis, `-m32`): AC-1, AC-8, AC-17.
- **Principle 2** (no unpinned input): the image is pinned by digest and the runner tools by sha256: AC-16, AC-21. The image's own unpinned installs are a recorded debt for M02.
- **Principle 5 / D-state-and-no-hidden-stderr**: no silent registry fallback: AC-11.
- **Principle 11** (port first): the Dockerfile is imported byte for byte: AC-20.

## Gate
- **I03-AC-1** — Every binary the recipes require on the host is declared in `image/host-tools.list` with a `check` and a `reason`: at minimum python3, makewhatis (mandoc), gcc `-m32`, tic, xorriso, mksquashfs, grub-mkstandalone, mformat/mcopy, mkfs.vfat, cpio, rsync, flex, bison, bc, file, git, cmake, zstd. *Verify:* `tests/fast/builder-host-tools.test.sh` against `image/required-host-tools.txt` (authored from `bashrc:115,282,344` and `make.conf:25`; R01 later adds a live scan of `recipes/`). *Tier:* fast.
- **I03-AC-2** — *Withdrawn (v0.3):* the verbatim predecessor Dockerfile contains `curl | sh` and tag-only `FROM` (`Dockerfile:131,168`), so a lint over it fails by design. M02 owns the rewrite and the lint (M02-AC-14).
- **I03-AC-3** — *Withdrawn (v0.3):* the verbatim Dockerfile contains `ARG BUILD_EPOCH` and `ENV SOURCE_DATE_EPOCH`; the inputs hash and its exclusions belong to the rebuilt image (M02-AC-15).
- **I03-AC-4** — *Withdrawn (v0.3):* the in-image pinned-binary installer and the tool ingest are part of rebuilding the image (M02-AC-16). The host-side installer is I03-AC-21.
- **I03-AC-5** — *Withdrawn (v0.3):* stage3 ingest and signature verification are needed only to rebuild the image (M02-AC-17).
- **I03-AC-6** — The adopted image has `i486-linux-musl-gcc`, musl and gcc versions equal to `pins/crossdev.lock`, a `libatomic.a` under the cross sysroot, and a `-march=i486 -static` program using `__atomic_fetch_add` on a 64-bit value links and is EM_386. *Verify:* `image/checks/cross-toolchain.sh` run by CI job `builder-image-adopt`. *Tier:* slow.
- **I03-AC-7** — *Withdrawn (v0.3):* the baked-tree absence and the GPG-verified webrsync belong to the rebuilt image (M02-AC-18); I02 no longer has a webrsync. What the adopted image contains is recorded by AC-17.
- **I03-AC-8** — Every `check` command in `image/host-tools.list` passes inside the adopted image, including a 32-bit program with `sizeof(long)==4`, `makewhatis` on a sample man tree, `python3 -c 'import yaml'`, and `rustc +nightly-2026-07-15 --print sysroot`. *Verify:* `image/checks/host-tools.sh`. *Tier:* slow.
- **I03-AC-9** — *Withdrawn (v0.3):* replaced by the inventory (AC-17, AC-18), which covers the same ground (host packages with versions; the grub, syslinux, xorriso, squashfs-tools and cross gcc versions that I05 asserts). The in-image `builder-manifest.json` belongs to M02.
- **I03-AC-10** — *Withdrawn (v0.3):* generated crossdev mask lines are a Dockerfile rewrite (the stale `gcc-14.4.9999` mask is at `Makefile:299`); M02-AC-19.
- **I03-AC-11** — `builder-image ensure` with a failing pull exits non-zero naming repo and digest and builds nothing; there is no rebuild option; no `2>/dev/null`/`|| true` on deciding commands in `factory/bin/builder-image`. *Verify:* `tests/fast/builder-image-cli.test.sh` (fake `docker`). *Tier:* fast.
- **I03-AC-12** — *Withdrawn (v0.3):* pushing `<TOOLCHAIN_EPOCH>-<hash12>` on every run is part of rebuilding (M02-AC-20). Adoption pushes nothing.
- **I03-AC-13** — `builder-image check-pin` fails when the pinned digest does not resolve, when `ensure` yields a different digest in `RepoDigests`, or when the image config lacks an environment entry of AC-14. *Verify:* `tests/fast/builder-image-cli.test.sh` cases `pin-*`; CI job `builder-image-adopt`. *Tier:* fast + slow.
- **I03-AC-14** — The adopted image config carries `CROSS_TARGET`, `CROSS_COMPILE`, `CONFIGS_DIR`, `BUILD_DIR`, `OUTPUT_DIR`, `RUSTUP_HOME`, `/opt/cargo/bin` on `PATH`, and `SOURCE_DATE_EPOCH=1786406400` (recorded as the known deviation). *Verify:* `image/checks/env.sh`. *Tier:* slow.
- **I03-AC-15** — *Withdrawn (v0.3):* installing the nightly from a loopback mirror is part of rebuilding the image (M02-AC-21). That the adopted image has the pinned nightly is checked by AC-8.
- **I03-AC-16** — `ensure` pulls `ghcr.io/tuckermclean/themonolith/builder@sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa` without credentials, and the digest equals the one the predecessor's `ghcr.io/tuckermclean/monolith-builder:20260810-d9d08d1c7422` resolves to, so the copy is the same image. *Verify:* CI job `builder-image-adopt` (needs Step 0; fails naming the missing digest otherwise). *Tier:* slow.
- **I03-AC-17** — `inventory` run on the adopted image emits JSON with the sections listed in Design, including whether `/var/db/repos/gentoo` exists, the versions of grub, syslinux, xorriso, squashfs-tools and the cross gcc, and the in-image syft and grype versions. *Verify:* `image/checks/inventory.sh` via CI job `builder-image-adopt`; the JSON is uploaded as an artifact. *Tier:* slow.
- **I03-AC-18** — Declared equals actual: `declared-check` on the adopted image's inventory reports no undeclared entry (world atoms, `/usr/local/bin` and `/opt/cargo/bin` files, rustup toolchains, cross packages, python modules) and no declared entry that is absent. *Verify:* CI job `builder-image-adopt`. *Tier:* slow. *When:* after MS2.
- **I03-AC-19** — `declared-check` logic: on fixture inventories it fails for an undeclared world atom, an undeclared binary, a declared-but-missing package and a missing check, and passes for an equal pair. *Verify:* `tests/fast/builder-declared-check.test.sh`. *Tier:* fast.
- **I03-AC-20** — `image/Dockerfile` is byte-identical to `b9f533b:Dockerfile` (sha256 `19a14861abd13739bf4c4380dea29fe3b028dc218181d43e01acb11a33f5f861`, recorded in `image/IMPORT`), and its hash with the two epoch lines excluded starts with `d9d08d1c7422`; no workflow builds it. *Verify:* `tests/fast/builder-import.test.sh`. *Tier:* fast.
- **I03-AC-21** — `install-tool syft|grype` installs only the version and sha256 in `pins.yaml: tools.*` from the pinned URL; a wrong checksum or a missing pin exits non-zero and installs nothing; the pinned syft and grype versions equal the versions in the adopted image's inventory. *Verify:* `tests/fast/image-install-tool.test.sh` (local `file://` override); the version equality in CI job `builder-image-adopt`. *Tier:* fast + slow.

## RED plan
Tester writes first: `builder-host-tools.test.sh` (with `required-host-tools.txt`), `builder-image-cli.test.sh` with a fake `docker`, `builder-declared-check.test.sh` with fixture inventories, `builder-import.test.sh` and `image-install-tool.test.sh`. All fail because `image/` and `factory/bin/builder-image` do not exist. The slow checks under `image/checks/` are written by the implementer and are the GREEN evidence; `host-tools.list` is built from the first real inventory.

## Risks and open questions
- Hardest: **declared == actual** on a `docker commit` image with a full stage3 base. The stage3 world is large and unlisted. The `stage3` kind exists so the baseline can be declared in one reviewed block; if the first inventory shows more surprises than a day's review can justify, restrict AC-18 to the explicit atoms and the files outside portage, and say so here.
- The adopted image may carry a baked 20260810 tree and an unpinned `syft` and `grype`; both are findings recorded by AC-17, not defects of this node.
- The image is not reproducible from source until M02. If GHCR deletes or corrupts `builder:rc1`, there is no second copy; the owner should also keep a `docker save` of it outside GHCR (Step 0 suggestion). Unverified: whether the predecessor's GHCR package keeps it alive independent of our copy.
- Image size is 1.36 GB; GHCR storage is free for public packages today (unverified for this repository).
- Docker host must run i386 binaries (IA32 emulation) for nethack DLB tools and `busybox --list` (build.yaml open_questions); the CI runner is the check, in B06.
- D-all-static (OD-2) may later require more static tools in the builder. Not affected.

## Cost
Four slices: (1) import, `required-host-tools`, declared-check logic, AC-1, AC-11, AC-19, AC-20; (2) `ensure`, `check-pin`, inventory, the adoption job, AC-6, AC-8, AC-13, AC-14, AC-16, AC-17; (3) declared list review and AC-18 (after MS2; AC-17's inventory and the list itself stay on the path); (4) `install-tool` and its pins, AC-21. CI: one adoption job (a 1.36 GB pull plus short checks, about 10 minutes), run two or three times. No image build. Money: GHCR storage for the copy.

## Spec defects found
- graph.yaml still lists I02 as a dependency of I03 in the header row; the adopted image needs no tree, so the dependency on I02 is not used by this node (v0.3 summary says deps `[I01]`). The header is regenerated from the graph.
- SPEC §6 pins the stage3 "tarball (sha256 of the signed autobuild, I03)". The stage3 is now needed only by M02, which mirrors `gentoo/stage3:amd64-openrc-20260810` by digest for the first rebuild. SPEC §6 should say M02, and allow a digest for that first rebuild.
- SPEC §6 says the builder digest is an output of building `image/`, with a two-commit flow. For the adopted image the digest is an input fixed in Step 0; the two-commit flow applies from M02 on.
- R02 (versions.lock regeneration) queries portage from the builder, which carries the toolchain tree, not the runtime tree. R02's spec must run `snapshot stage` for the pinned commit and mount it first (T-crossdev-query-empty, T-live-ebuild-and-host-keyword-skew); nothing names that step.
- S01 and S03 should state that they run the runner-installed `syft` and `grype` (I03-AC-21), not the image's copies.
