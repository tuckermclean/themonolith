# I03 — builder-image

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | I01 | B01, M02, R05 | — | S |

**Owns:** `BUILDER_DIGEST` and `pull-image` in `Makefile`, the builder-digest lines of `scripts/attestation.sh` (`:316,687`), the builder step of `.github/workflows/build.yml` (build-image job replaced by a pull), `scripts/builder-manifest.sh`, `scripts/tests/builder-pin.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `Dockerfile` (unchanged, whole file; not built until M02), the crossdev block of `Makefile` (unchanged, unused until M02), `configs/portage/crossdev.lock`.
**Study refs:** D-static-musl-cross-all-the-way, D-two-epoch-pin-model, T-libatomic-static, T-builder-image-tag-not-pushed.

## Purpose
The build uses rc1's builder image, taken by digest from our own namespace, with a recorded list of what is inside it. Adopting it avoids about 1.5 hours of crossdev compilation per cold run (the v0.3 estimate; not re-measured) and gives every later node a fixed digest. The image is not reproducible from source until M02.

## Standard mechanism
- Image distribution: an OCI registry and `docker pull <repo>@sha256:...`. Pinning by digest is the standard way to name an immutable image.
- Contents record: `qlist -Iv` (gentoolkit, already in the image, `Dockerfile:101`) lists every installed package, cross packages included. Nothing else is invented.
- Custom code: `builder-manifest.sh`, about ten lines that run `qlist -Iv`, `i486-linux-musl-gcc --version`, `syft --version`, `grype --version`, `rustup toolchain list` and `docker image inspect` inside the image and print them. Gap: the predecessor kept no record of what the image contained (`Dockerfile:81-98` pins host tools only through the dated tree). No standard tool answers this for a `docker commit` image.

## Changes from the port
Step 0 (owner action, not CI): `oras cp ghcr.io/tuckermclean/monolith-builder@sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa ${REGISTRY}/builder:rc1`. `oras cp` keeps the digest. The `rc1` tag is a convenience; no code reads it.

1. **Pin by digest.** `Makefile` gains `BUILDER_DIGEST := sha256:ab04002a...`. `pull-image` becomes `docker pull ${REGISTRY}/builder@${BUILDER_DIGEST}` plus `docker tag ... monolith-builder`. The tag-based `REGISTRY_TAG` (`Makefile:50-64`) stays only for M02's rebuild. *Proof:* I03-AC-1, I03-AC-3.
2. **No silent local rebuild.** `build-image` falls back to building when the pull fails (`Makefile:269,275`). `pull-image` has no fallback and exits non-zero naming the reference. `build-image` is not called by CI. *Proof:* I03-AC-2.
3. **CI pulls, never builds.** The `build-image` job (`build.yml:79-165`: gate on tag, `docker buildx`, push) is replaced by a step that runs `make pull-image`. A `Dockerfile` edit therefore no longer rebuilds anything until M02. *Proof:* I03-AC-3.
4. **Tool manifest.** A step runs `scripts/builder-manifest.sh` against the pulled image and uploads `builder-manifest.txt` with `actions/upload-artifact`. B03 attaches it to the release inputs. *Proof:* I03-AC-4.

5. **Attestation names the builder by digest.** The attestation job derives a stage3 digest from the Dockerfile's `BUILD_EPOCH` (`build.yml:593-599`, read at `attestation.sh:316,687`). Under the adopted image that value describes nothing we pin. Those lines record `BUILDER_DIGEST` instead. *Proof:* I03-AC-3.

Everything else, including the `Dockerfile` and the `docker commit` crossdev block, is untouched. The baked `SOURCE_DATE_EPOCH=1786406400` (`Dockerfile:37`) stays; it equals 2026-08-11T00:00:00Z, rc1's value. Builds pass `SOURCE_DATE_EPOCH` explicitly (SPEC §6: the committer time of `TREE_COMMIT`), so the baked value is never relied on. M02 removes the ENV.

## Gate
- **I03-AC-1** — `Dockerfile` has sha256 `19a14861abd13739bf4c4380dea29fe3b028dc218181d43e01acb11a33f5f861`, and its hash with the `ARG BUILD_EPOCH=` and `ENV SOURCE_DATE_EPOCH=` lines removed starts with `d9d08d1c7422`, the tag suffix of rc1's image (checked on this host against `b9f533b`). *Verify:* `scripts/tests/builder-pin.test.sh`. *Tier:* fast.
- **I03-AC-2** — `make pull-image` with a stub `docker` whose pull fails exits non-zero, prints the digest reference, and runs no `docker build`/`buildx`. *Verify:* `scripts/tests/builder-pin.test.sh`. *Tier:* fast.
- **I03-AC-3** — No workflow or Makefile target used by CI references a builder tag (`:latest`, `REGISTRY_TAG`) or `docker buildx build`, `BUILDER_DIGEST` is the only builder reference, and `attestation.sh` reads no `STAGE3_DIGEST`. *Verify:* `scripts/tests/builder-pin.test.sh` (`grep` over `.github/workflows` and CI-called targets). *Tier:* fast.
- **I03-AC-4** — A CI run pulls `${REGISTRY}/builder@${BUILDER_DIGEST}` anonymously, `docker image inspect` reports that digest in `RepoDigests`, and the digest equals what `ghcr.io/tuckermclean/monolith-builder:20260810-d9d08d1c7422` resolves to (`docker buildx imagetools inspect`). *Verify:* `workflow_dispatch` job after Step 0. *Tier:* slow.
- **I03-AC-5** — `builder-manifest.txt` is uploaded and lists `cross-i486-linux-musl/gcc`, `cross-i486-linux-musl/musl`, `sys-boot/grub`, `sys-boot/syslinux`, `dev-libs/libisoburn`, `sys-fs/squashfs-tools`, with gcc and musl versions equal to those in `configs/portage/crossdev.lock`. *Verify:* the same job, then `grep`. *Tier:* slow.
- **I03-AC-6** — Inside the image: `-march=i486 -static` links a program using a 64-bit `__atomic_fetch_add` (needs `libatomic.a`, T-libatomic-static) and the result is `EM_386`; a `gcc -m32` program prints `sizeof(long)==4` (`Dockerfile:56-64`). *Verify:* the same job via `docker run`. *Tier:* slow.

## Risks
- The image is a `docker commit` product and carries unpinned `syft` and `grype` (`main` install scripts, `Dockerfile:128-142`) and an unpinned rustup script (`:167-170`). Their versions are recorded by AC-5, not fixed. M02 addresses it.
- It probably still carries the 20260810 toolchain tree under `/var/db/repos/gentoo` (unverified; the Dockerfile never removes it). B01 must mount the pinned tree over it. The manifest will show it.
- If GHCR loses `builder:rc1`, there is no second copy. The owner should keep a `docker save` elsewhere (unverified that the predecessor package outlives its account).
- 1.36 GB pull per job (v0.3 figure, unverified for the copy).
