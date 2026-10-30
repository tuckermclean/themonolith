# I03 — builder-image

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | I01 | B01, M02 | — | S |

**Owns:** `BUILDER_DIGEST` and `pull-image` in `Makefile`, `scripts/builder-manifest.sh`, `scripts/tests/builder-pin.test.sh`. Its rules hold for `build.yml` (B03) and `attestation.sh` (S01) when they are ported.
**Ports from linux-live-iso-factory@b9f533b:** `Dockerfile` (unchanged, whole file; not built until M02), the crossdev block of `Makefile` (unchanged, unused until M02), the `pull-image` target, `configs/portage/crossdev.lock`.
**Study refs:** D-static-musl-cross-all-the-way, D-two-epoch-pin-model, T-libatomic-static, T-builder-image-tag-not-pushed.

## Purpose
The build uses rc1's builder image, taken by digest from our own namespace, with a recorded list of what is inside it. Adopting it avoids about 1.5 hours of crossdev compilation per cold run (estimated; not measured) and gives every later node a fixed digest. The image is not reproducible from source until M02.

## Standard mechanism
- Image distribution: an OCI registry and `docker pull <repo>@sha256:...`. Pinning by digest is the standard way to name an immutable image.
- Contents record: `qlist -Iv` (gentoolkit, already in the image, `Dockerfile:101`) lists every installed package, cross packages included. Nothing else is invented.
- Custom code: `builder-manifest.sh`, about ten lines that run `qlist -Iv`, `i486-linux-musl-gcc --version`, `syft --version`, `grype --version`, `rustup toolchain list` and `docker image inspect` inside the image and print them. Gap: the predecessor kept no record of what the image contained (`Dockerfile:81-98` pins host tools only through the dated tree). No standard tool answers this for a `docker commit` image.

## Tests
- **Ported first:** none; the predecessor had no test of the builder pin.
- **Added:** `scripts/tests/builder-pin.test.sh`.
- **Baseline:** `b9f533b`'s `Makefile` (`pull-image` on `:latest`) fails the digest criteria, as expected.

## Changes from the port
Step 0 (owner action, not CI): `oras cp ghcr.io/tuckermclean/monolith-builder@sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa ${REGISTRY}/builder:rc1`. `oras cp` keeps the digest. The `rc1` tag is a convenience; no code reads it.

1. **Pin by digest.** `Makefile` gains `BUILDER_DIGEST := sha256:ab04002a...`. `pull-image` becomes `docker pull ${REGISTRY}/builder@${BUILDER_DIGEST}` plus `docker tag ... monolith-builder`. The tag-based `REGISTRY_TAG` (`Makefile:50-64`) is not ported here; M02 ports it for the rebuild. *Proof:* I03-AC-1, I03-AC-3.
2. **No silent local rebuild.** The predecessor's `build-image` falls back to building when the pull fails (`Makefile:269,275`). `pull-image` has no fallback and exits non-zero naming the reference. `build-image` is not ported here (M02). *Proof:* I03-AC-2.
3. **CI pulls, never builds.** The predecessor's `build-image` job (`build.yml:79-165`: gate on tag, `docker buildx`, push) is not ported: B03 ports `build.yml` with a step that runs `make pull-image`, and this node's test holds every workflow and CI-called target to the digest as it arrives. A `Dockerfile` edit therefore rebuilds nothing until M02. *Proof:* I03-AC-3.
4. **Tool manifest.** `scripts/builder-manifest.sh` runs against the pulled image and prints `builder-manifest.txt`. B03's build job uploads it and P02 attaches it to the release inputs. *Proof:* I03-AC-5.

5. **Attestation names the builder by digest.** The predecessor's attestation job derives a stage3 digest from the Dockerfile's `BUILD_EPOCH` (`build.yml:593-599`, read at `attestation.sh:316,687`). Under the adopted image that value describes nothing we pin. S01 ports `attestation.sh` recording the `--builder-digest` it is given instead, and this node's test rejects `STAGE3_DIGEST` in it. *Proof:* I03-AC-3.

Everything else, including the `Dockerfile` and the `docker commit` crossdev block, is untouched. The baked `SOURCE_DATE_EPOCH=1786406400` (`Dockerfile:37`) stays; it equals 2026-08-11T00:00:00Z, rc1's value. Builds pass `SOURCE_DATE_EPOCH` explicitly (SPEC §6: the committer time of `TREE_COMMIT`), so the baked value is never relied on. M02 removes the ENV.

## Gate
- **I03-AC-1** — `Dockerfile` has sha256 `19a14861abd13739bf4c4380dea29fe3b028dc218181d43e01acb11a33f5f861`, and its hash with the `ARG BUILD_EPOCH=` and `ENV SOURCE_DATE_EPOCH=` lines removed starts with `d9d08d1c7422`, the tag suffix of rc1's image (checked on this host against `b9f533b`). *Verify:* `scripts/tests/builder-pin.test.sh`.
- **I03-AC-2** — `make pull-image` with a stub `docker` whose pull fails exits non-zero, prints the digest reference, and runs no `docker build`/`buildx`. *Verify:* `scripts/tests/builder-pin.test.sh`.
- **I03-AC-3** — No workflow or Makefile target used by CI references a builder tag (`:latest`, `REGISTRY_TAG`) or `docker buildx build`, `BUILDER_DIGEST` is the only builder reference, and `attestation.sh` reads no `STAGE3_DIGEST`. *Verify:* `scripts/tests/builder-pin.test.sh` (`grep` over `.github/workflows` and CI-called targets).
- **I03-AC-4** — `make pull-image` pulls `${REGISTRY}/builder@${BUILDER_DIGEST}` anonymously, `docker image inspect` reports that digest in `RepoDigests`, and the digest equals what `ghcr.io/tuckermclean/monolith-builder:20260810-d9d08d1c7422` resolves to (`docker buildx imagetools inspect`). *Verify:* `make pull-image` locally with podman after Step 0, with no registry login; log under `out/node/I03/`.
- **I03-AC-5** — `builder-manifest.txt` lists `cross-i486-linux-musl/gcc`, `cross-i486-linux-musl/musl`, `sys-boot/grub`, `sys-boot/syslinux`, `dev-libs/libisoburn`, `sys-fs/squashfs-tools`, with gcc and musl versions equal to those in `configs/portage/crossdev.lock`. *Verify:* `scripts/builder-manifest.sh` on the image pulled for AC-4, then `grep`.
- **I03-AC-6** — Inside the image: `-march=i486 -static` links a program using a 64-bit `__atomic_fetch_add` (needs `libatomic.a`, T-libatomic-static) and the result is `EM_386`; a `gcc -m32` program prints `sizeof(long)==4` (`Dockerfile:56-64`). *Verify:* `docker run` (or `podman run`) on the image pulled for AC-4.

## Risks
- The image is a `docker commit` product and carries unpinned `syft` and `grype` (`main` install scripts, `Dockerfile:128-142`) and an unpinned rustup script (`:167-170`). Their versions are recorded by AC-5, not fixed. M02 addresses it.
- It probably still carries the 20260810 toolchain tree under `/var/db/repos/gentoo` (unverified; the Dockerfile never removes it). B01 must mount the pinned tree over it. The manifest will show it.
- If GHCR loses `builder:rc1`, there is no second copy. The owner should keep a `docker save` elsewhere (unverified that the predecessor package outlives its account).
- 1.36 GB pull per job (unverified for the copy).
