# I03 — builder-image

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| I | I01, I02 | I04, I05, R02, B01, S03, M02 | — (needed for MS2) | L |

**Owns:** `image/Dockerfile`, `image/host-tools.list`, `image/hash-inputs.txt`, `image/checks/` (in-image check scripts), `image/install-tool` (pinned-binary installer), `factory/bin/builder-image` (`hash`, `build`, `push`, `ensure`, `check-pin`), `factory/bin/builder-inputs` (`stage3`, `tools`, `rust` ingest into the store), `.github/workflows/builder-image.yml`, `tests/fast/builder-*.test.sh`, `tests/fast/image-install-tool.test.sh`, the `base_image`, `builder_image`, `tools.*` and `rust` sections of `pins/pins.yaml` (format in I05).
**Carries from linux-live-iso-factory@b9f533b:** `Dockerfile` (whole: m32 check :55-64, toolchain tree :74, host tool list :99-122, syft/grype :128-142, xcb-proto :153, rustup nightly :167-170, portage overlay config :175-200, libatomic `EXTRA_ECONF` :191-202), `Makefile` `build-image`/`push-image`/`pull-image` (:255-345, tag logic :50-64, crossdev block :295-325), `configs/portage/crossdev.lock` (goes to I05).
**Study refs:** D-static-musl-cross-all-the-way, D-two-epoch-pin-model, T-libatomic-static, T-crossdev-query-empty, T-builder-image-tag-not-pushed, T-github-api-503-installs, T-glib-docutils-eigen-live, T-live-ebuild-and-host-keyword-skew, T-rust-i486-musl, T-xcb-proto-python, T-makewhatis-oom, recipes.yaml notes_general (hidden host-python need), build.yaml hazards (stage3 by tag; syft/grype from `main`; rustup init script unpinned; `docker commit` not reproducible; silent registry-pull fallback) and contradictions (GRUB "pinned to 2.12" claim; stale `gcc-14.4.9999` mask; comment/tag mismatch), `docker.base-tools`, `make.build-image`.

## Purpose
After this node the builder environment is defined by a Dockerfile whose every input is pinned and comes from the store: a GPG-verified stage3 tarball, a GPG-verified portage snapshot for the toolchain, checksummed tool binaries, a mirrored rust nightly, and `crossdev` driven by `crossdev.lock`. The result is published by digest. The predecessor could not rebuild its image once the toolchain snapshot was pruned and its tools came from `main`-branch install scripts; its image was also produced by `docker commit` from a hidden Makefile step.

## Scope
In:
- Single Dockerfile producing the full builder (host tools, crossdev i486-linux-musl toolchain, rust, syft, grype, oras).
- Ingest of non-portage image inputs into the store (stage3 tarball, tool binaries, rust dist components).
- Declaring and checking every host tool, including the hidden ones (python3, makewhatis, `gcc -m32`).
- Inputs hash, tag, digest publishing, pin check, `ensure` (pull by digest; no silent local rebuild).
- A manifest of what the image contains (`builder-manifest.json`).

Out:
- Snapshot ingest and webrsync mechanics: I02 (this node calls them).
- Distfiles for host tools and crossdev (gcc, binutils, musl, kernel headers): fetched online and unrecorded in this node; I04 makes them mirror-first and rebuilds this image with `--network none` for emerge.
- The pin ledger schema, `crossdev.lock` regeneration and bump PRs: I05, M02.
- Running package builds, runtime tree sync, host `package.mask` mirroring (T-glib-docutils-eigen-live): B01.
- Scanning the image for CVEs: S03. Attesting its digest: S05.
- ISO tools' use (xorriso, grub, mksquashfs invocations): B04, B05. Only their presence and versions are checked here.

## Design
**Build shape.** One `image/Dockerfile` (BuildKit syntax pinned by digest in the first line), stages:
1. `FROM scratch`, `ADD stage3.tar.xz /` from a bind mount, then the minimal `ENV`/`CMD` that the Docker stage3 image sets. Rejected: `FROM gentoo/stage3:amd64-openrc-<epoch>` by digest. A digest pins content, not availability; Docker Hub already dropped `gentoo/portage:20260811` and may drop old stage3 tags. Rejected: `docker save` of the Hub image into the store (trust-on-first-use, about 1 GB). The stage3 tarball is signed, so ingest is verified (`builder-inputs stage3 <epoch>` fetches the signed tarball, `.asc` and `.sha256` from the Gentoo autobuilds area, verifies with `gpgverify.sh` against a second pinned key (`gentoo_key.release`), and `store put distfile sha256/<hex>`). Assumed, to be proven by AC-5 and AC-9: the Docker stage3 image is that tarball plus trivial config.
2. Toolchain tree: `RUN --mount=type=bind,source=build/image-inputs/snapshots,target=/mnt/snap --network=none snapshot webrsync <TOOLCHAIN_EPOCH> /mnt/snap`. The tarball never lands in a layer.
3. Host tools: `emerge --noreplace` of the atoms in `image/host-tools.list` (`GRUB_PLATFORMS="efi-32 efi-64"`), then `eix-update`.
4. Pinned binaries (`syft`, `grype`, `oras`, `rustup-init`, rust dist) installed by `image/install-tool` from `build/image-inputs/tools/` with `--network=none`; the installer verifies sha256 against the ledger. No `curl | sh`, no retry loop needed because there is no network (T-github-api-503-installs is removed by design; the retry now lives in the store ingest).
5. Rust: `rustup-init` with `RUSTUP_DIST_SERVER` set to a loopback mirror of the stored dist tree, toolchain `nightly-<date>` plus `rust-src`, profile minimal, installed to `/opt/rustup` and `/opt/cargo`. Whether rustup accepts a flat mirror laid out as `dist/<date>/…` is to be proven by AC-8; fallback is `rustup toolchain install` from local component tarballs via `rustup-init` offline mode.
6. Portage policy: crossdev and monolith repos, `*/* **` for crossdev, `FEATURES=-strict`, `cross-gcc-static.conf` with `EXTRA_ECONF="--disable-shared --enable-static"` for `cross-i486-linux-musl/gcc` (carried; this is T-libatomic-static).
7. Crossdev inside the Dockerfile (no `docker commit`): mask live ebuilds with a generated pattern (`cross-<target>/{musl,binutils,gcc,linux-headers}-9999`), unmask the pinned musl, then `crossdev --target i486-linux-musl --stable --gcc <lock> --libc <lock> --binutils <versions.lock> --kernel <versions.lock major.minor> --portage --verbose`, then `emerge --update --newuse cross-i486-linux-musl/gcc`. On failure, a shell trap prints the tail of the newest portage logs to the build output. Rejected: `docker run` plus `docker commit` (non-reproducible, hidden in the Makefile, needed a label hack for caching, `Makefile:295-325`). The stale `gcc-14.4.9999` mask (`Makefile:299`) is not carried.
8. Cleanup: `rm -rf /var/db/repos/gentoo /var/cache/distfiles/*`. The runtime tree is injected by B01 via I02; a build that forgets to inject it fails on a missing tree instead of silently using the toolchain tree. `portageq` therefore needs a tree: tools that query (M02 lock regeneration, T-crossdev-query-empty) call `snapshot webrsync` first.

**No epoch variables in the image.** The predecessor baked `SOURCE_DATE_EPOCH` and an `ARG BUILD_EPOCH` into the Dockerfile and then excluded those two lines from the tag hash (`Makefile:63-64`). Here neither exists: `SOURCE_DATE_EPOCH` is passed at `docker run` time (derived from `BUILD_EPOCH`, I05), so the image cannot depend on the build epoch (D-two-epoch-pin-model).

**Environment baked in the image config:** `CROSS_TARGET=i486-linux-musl`, `CROSS_COMPILE=i486-linux-musl-`, `BUILD_DIR=/build`, `CONFIGS_DIR=/configs`, `OUTPUT_DIR=/output`, `RUSTUP_HOME=/opt/rustup`, `PATH` with `/opt/cargo/bin` (from `Makefile:321-324`, `Dockerfile:158-160`; overlay ebuilds read `CONFIGS_DIR`/`CROSS_COMPILE`, recipes.yaml notes_general).

**Host tools declared (`image/host-tools.list`).** One line per tool: `kind  name  pin  check  reason`. `kind` is `portage`, `binary` or `rustup`. For `portage`, the pin is the toolchain epoch (immutable tree in the store plus the stage3 digest), not a per-atom version; the resolved versions are written to `builder-manifest.json` and asserted by I05 where they matter (grub, syslinux, xorriso, mksquashfs). Rejected: per-atom `=cat/pkg-ver` pins; they fight the epoch model that the predecessor argued at `Dockerfile:81-98`. `check` is a command run inside the built image. Required entries with their reasons (hidden needs included):
- `python3` — gpm and nethack Makefile surgery in `configs/portage/bashrc:115,282`; also `snapshot webrsync`'s http server. Host-only (D-no-python-on-target).
- `dev-python/pyyaml`, `x11-base/xcb-proto` — host codegen (T-xcb-proto-python, `Dockerfile:153`).
- `gcc` with `-m32` — `CFLAGS_FOR_BUILD="-O2 -m32"` (`make.conf:25`) for nethack's DLB tools; check: compile and run a 32-bit program, then a `sizeof(long)==4` assertion (carried from `Dockerfile:55-64`).
- `app-text/mandoc` — host `makewhatis` for `bashrc:344-357` (T-makewhatis-oom: 60 s timeout lives in the hook, B01).
- `sys-libs/ncurses` host `tic`, `dev-build/cmake` (keeps cmake-9999 out of BDEPEND), `sys-devel/{crossdev,flex,bison,bc}`, `dev-libs/elfutils`, `sys-boot/{syslinux,grub}`, `dev-libs/libisoburn` (xorriso), `sys-fs/{mtools,dosfstools,squashfs-tools}`, `app-arch/{xz-utils,cpio,zstd}`, `net-misc/rsync`, `sys-apps/file`, `dev-vcs/git`, `app-portage/{gentoolkit,eix}`.
- `binary` entries: `syft`, `grype`, `oras`; `rustup` entry: `nightly-<date>` + `rust-src` (the date also appears in the rl144 and stele ebuilds as `RUST_NIGHTLY`; I05 checks equality).

**Inputs hash and tag.** `builder-image hash` = sha256 over the sorted `path sha256` list of `image/hash-inputs.txt` entries (all of `image/**`, `pins/crossdev.lock`, `pins/versions.lock` kernel line) plus the ledger values `epochs.toolchain`, `base_image.*`, `tools.*`, `rust.*`, `gentoo_key.*`. It excludes `epochs.build` and the build snapshot entry. Tag = `<TOOLCHAIN_EPOCH>-<first 12 hex of hash>`.

**Publish and pin.** `builder-image push` tags the image with the tag above and pushes it unconditionally on every run, including when the build was skipped by cache (T-builder-image-tag-not-pushed), then writes the manifest digest to `build/builder.digest`. Consumers use `image: <repo>@sha256:<digest>` from `pins.yaml: builder_image.digest`. A digest is an output of the build, so the sequence is: PR changes `image/`, job `builder-image` builds and pushes, a human (or M02) copies digest and inputs hash into the ledger, and `builder-image check-pin` then passes. Rejected: pulling by tag only (mutable, and the tag is derived from inputs, not content).

**ensure.** `builder-image ensure` pulls by ledger digest and fails with a message naming repo and digest if the pull fails. A rebuild from inputs happens only with the explicit `--rebuild`. Rejected: the predecessor's pull-or-silently-rebuild (`Makefile:269,275`).

**Manifest.** `/usr/share/monolith-builder/manifest.json` (and a CI artifact): `qlist -Iv` of all installed host packages, versions of every `binary`/`rustup` entry, `i486-linux-musl-gcc --version`, musl version, path of `libatomic.a`, GRUB platforms, the toolchain epoch, and inputs hash. Labels: `org.themonolith.inputs-hash`, `org.themonolith.toolchain-epoch`, `org.opencontainers.image.revision`.

**Registry.** The image is derived data, rebuildable from the store, so a registry copy is a cache, not a source of truth. `factory/bin/builder-image` is the only file besides the `oci` backend allowed to name a registry (pin `builder_image.repo`).

## Traps and doctrines preserved
- **T-libatomic-static** (no `libatomic.a` makes iperf3, irssi/glib, w3m fail at static link; cost a 2 h rebuild): AC-6, AC-7.
- **D-static-musl-cross-all-the-way** (crossdev toolchain, host tools 32-bit capable): AC-6, AC-8 (m32 check) and crossdev lock check AC-10.
- **D-two-epoch-pin-model / T-builder-image-tag-not-pushed**: the image never depends on the build epoch and is pushed on every run: AC-3, AC-12.
- **T-crossdev-query-empty**: the toolchain tree is removed, so a query that needs a tree is explicit; AC-9.
- **T-glib-docutils-eigen-live / T-live-ebuild-and-host-keyword-skew**: the image ships an empty host `package.mask` and masks live cross ebuilds by pattern; the host-side mirroring itself is B01. AC-10.
- **T-github-api-503-installs**: removed by pinning and mirroring tool binaries: AC-2, AC-4.
- **Hidden host-tool needs** (python3, makewhatis, `-m32`): AC-1, AC-8.
- **Principle 2**: no unpinned fetch in the image: AC-2, AC-4.
- **D-state-and-no-hidden-stderr**: no silent registry fallback, no `2>/dev/null` on deciding steps: AC-11.

## Gate
- **I03-AC-1** — Every binary the recipes require on the host is declared in `image/host-tools.list` with a `check` and a `reason`: at minimum python3, makewhatis (mandoc), gcc `-m32`, tic, xorriso, mksquashfs, grub-mkstandalone, mformat/mcopy, mkfs.vfat, cpio, rsync, flex, bison, bc, file, git, cmake, zstd. *Verify:* `tests/fast/builder-host-tools.test.sh` against `tests/fast/fixtures/required-host-tools.txt` (authored from `bashrc:115,282,344` and `make.conf:25`; R01 later adds a live scan of `recipes/`). *Tier:* fast.
- **I03-AC-2** — `image/Dockerfile` contains no `curl`/`wget` piped to a shell, no `raw.githubusercontent.com`, no `:latest` or tag-only `FROM`, and every download-style `RUN` uses `--network=none`, except the lines carrying `# net-allowed: distfiles (I04)`. *Verify:* `tests/fast/builder-dockerfile-lint.test.sh` (RED fixtures are the predecessor's offending lines). *Tier:* fast.
- **I03-AC-3** — `builder-image hash` changes when any file under `image/`, `crossdev.lock`, `epochs.toolchain`, a tool pin or the stage3 pin changes, and does not change when `epochs.build` or the build snapshot entry changes. The Dockerfile contains no `BUILD_EPOCH` or `SOURCE_DATE_EPOCH`. *Verify:* `tests/fast/builder-inputs-hash.test.sh`. *Tier:* fast.
- **I03-AC-4** — `image/install-tool` installs a binary only if its sha256 matches the ledger and the file came from the staged directory; a mismatch or missing pin exits non-zero and installs nothing. `builder-inputs tools` verifies upstream bytes against the ledger sha256 before `store put`. *Verify:* `tests/fast/image-install-tool.test.sh`. *Tier:* fast.
- **I03-AC-5** — `builder-inputs stage3` rejects a stage3 tarball with a bad or wrong-signer signature or a sha256 differing from the ledger, and stores accepted tarballs under `sha256/<hex>` in class `distfile`. *Verify:* `tests/fast/builder-stage3.test.sh` (throwaway-key fixtures from I02). *Tier:* fast.
- **I03-AC-6** — The built image has `i486-linux-musl-gcc`, musl and gcc versions equal to `pins/crossdev.lock`, a `libatomic.a` under the cross sysroot, and a `-march=i486 -static` program using `__atomic_fetch_add` on a 64-bit value links and is EM_386. *Verify:* `image/checks/cross-toolchain.sh` run by CI job `builder-image`. *Tier:* slow.
- **I03-AC-7** — The build consumed the toolchain snapshot only from the store (`snapshot webrsync` with GPG), `/var/db/repos/gentoo` is absent in the final image, and `portageq` reports a missing tree rather than answering. *Verify:* `image/checks/no-baked-tree.sh`; the build log contains the webrsync GPG line. *Tier:* slow. (Also satisfies I02-AC-12.)
- **I03-AC-8** — Every `check` command in `image/host-tools.list` passes inside the image, including a 32-bit program with `sizeof(long)==4`, `makewhatis` on a sample man tree, `python3 -c 'import yaml'`, and `rustc +nightly-<date> --print sysroot`. *Verify:* `image/checks/host-tools.sh`. *Tier:* slow.
- **I03-AC-9** — `builder-manifest.json` exists in the image and as a CI artifact, lists every host package with version, and records grub, syslinux, xorriso, squashfs-tools and cross gcc versions; the Docker-image-vs-tarball stage3 assumption is checked by `emerge --info` succeeding with the expected profile. *Verify:* `image/checks/manifest.sh`. *Tier:* slow.
- **I03-AC-10** — The crossdev mask lines are generated for `-9999` of musl, binutils, gcc and linux-headers and contain no hard-coded gcc minor version; the host `/etc/portage/package.mask` ships empty. *Verify:* `tests/fast/builder-dockerfile-lint.test.sh` case `masks`. *Tier:* fast.
- **I03-AC-11** — `builder-image ensure` with a failing pull exits non-zero naming repo and digest and does not start a build unless `--rebuild` is given; no `2>/dev/null`/`|| true` on deciding commands in `factory/bin/builder-image`. *Verify:* `tests/fast/builder-image-cli.test.sh` (fake `docker`). *Tier:* fast.
- **I03-AC-12** — `builder-image push` pushes `<TOOLCHAIN_EPOCH>-<hash12>` on every invocation, including when the image was found unchanged, and writes `build/builder.digest`; after a CI run, `docker manifest inspect <repo>@<digest>` succeeds. *Verify:* `tests/fast/builder-image-cli.test.sh` case `push-always` (fast); CI job `builder-image` (slow). *Tier:* fast + slow.
- **I03-AC-13** — `builder-image check-pin` fails when the ledger digest does not resolve, when its `org.themonolith.inputs-hash` label differs from the current hash, or when the tag no longer points at the ledger digest. *Verify:* `tests/fast/builder-image-cli.test.sh` cases `pin-*`; CI job `builder-image-pin`. *Tier:* fast + slow.
- **I03-AC-14** — The image config carries `CROSS_TARGET`, `CROSS_COMPILE`, `CONFIGS_DIR`, `BUILD_DIR`, `OUTPUT_DIR`, `RUSTUP_HOME`, and the three labels. *Verify:* `image/checks/env.sh`. *Tier:* slow.
- **I03-AC-15** — The nightly installed by rustup is exactly the ledger `rust.nightly` and was installed from the loopback mirror of stored components, not the network. *Verify:* `image/checks/rust.sh` plus `--network=none` on the install step (AC-2). *Tier:* slow.

## RED plan
Tester writes first: `builder-host-tools.test.sh` (with the fixture list), `builder-dockerfile-lint.test.sh` (feeds the predecessor's Dockerfile snippets and expects failures), `builder-inputs-hash.test.sh`, `image-install-tool.test.sh`, `builder-stage3.test.sh`, `builder-image-cli.test.sh` with a fake `docker`. All fail because `image/` and `factory/bin/builder-image` do not exist. Slow checks under `image/checks/` are written by the implementer alongside the Dockerfile and are the GREEN evidence.

## Risks and open questions
- Hardest: the rust nightly mirror. `static.rust-lang.org` retention of old nightlies is unknown to this spec, and rustup's mirror layout must work offline. If it does not, the nightly must be installed from stored component tarballs with a custom script, which is more code than estimated.
- Docker stage3 equals the autobuilds tarball: assumed, not verified (no network in this task). AC-9 and a smoke build catch differences; a mismatch would force the `docker save` alternative.
- The builder build itself still downloads host-tool and crossdev distfiles from Gentoo mirrors until I04 lands. The image is therefore not yet rebuildable offline after this node alone; I04-AC-8 closes that.
- Build time: crossdev plus host tools took 52 to 100+ minutes in the predecessor (workflows/commit evidence; exact figure unknown). BuildKit cache (`type=registry`) of the host-tools layers needs a store-compatible cache location; cache is optional and never trusted for correctness.
- Image size is unmeasured; GHCR storage cost is open (see I01). Layers should be squashed only if size forces it.
- D-all-static (OD-2) may later require more static tools in the builder (none today). Not affected.
- Docker host must run i386 binaries (IA32 emulation) for nethack DLB tools and `busybox --list` (build.yaml open_questions); the CI runner is the check, in B06.

## Cost
Five slices: (1) hash, lint, host-tools list and checks (AC-1 to AC-3, AC-10); (2) installer and stage3/tool/rust ingest (AC-4, AC-5); (3) Dockerfile stages 1 to 6 and 8 (AC-7, AC-8, AC-14, AC-15); (4) crossdev stage and toolchain checks (AC-6, AC-9); (5) publish, ensure, pin checks (AC-11 to AC-13). CI build cycles: expect 3 full builder builds at 60 to 100 minutes each (first build, one fix, final confirmation), then cache. Money: GHCR image storage (a few GB, unmeasured), store space for stage3 (about 250 to 300 MB compressed estimate), tool binaries and rust components (about 150 MB estimate); about 3 to 5 CI hours.

## Spec defects found
- graph.yaml has I05 depend on I03, but I03 needs the tool, stage3 and rust pins. This node writes those sections of `pins/pins.yaml` in the format fixed by I05; ownership and dependency order should be fixed in SPEC §4.2/§6 (see I05 defects).
- SPEC §6 pins a "stage3 digest" and D-two-epoch-pin-model says `TOOLCHAIN_EPOCH` pins the stage3 base. With a tarball base the pin is the tarball sha256 (ledger key `base_image.stage3.sha256`), not an image digest. SPEC wording should follow.
- SPEC §6 pins a "builder image digest" in `pins.yaml`, but the digest is produced by the build; a PR that changes `image/` cannot be green in one commit. This node documents the two-step flow; SPEC §8 protected-path rules for `pins/pins.yaml` must permit that bot or human follow-up.
- R02 (versions.lock regeneration) queries portage from the builder, but I03 deliberately ships no tree. R02's spec must say that the query runs `snapshot webrsync` for `BUILD_EPOCH` first (T-crossdev-query-empty, T-live-ebuild-and-host-keyword-skew); it is transitively allowed by its dependency on I03, but nothing names the step.
