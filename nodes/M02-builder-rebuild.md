# M02 — builder-rebuild

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | I03, M01 | none | — | L |

**Owns:** `Dockerfile` (two edits), `Makefile` `build-image`/`push-image` (registry name), `.github/workflows/toolchain-bump.yml`, `scripts/update-build-pins.sh` (`update-toolchain` verification), `docs/builder-rebuild.md`, `docs/builder-manifests/{rc1,rebuilt}.txt`, `scripts/tests/builder-rebuild.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `Makefile:50-64` (`REGISTRY_TAG`) and `:255-345` (the `build-image` and `push-image` targets: the `docker run` plus `docker commit` crossdev build), `.github/workflows/toolchain-bump.yml`, `scripts/update-build-pins.sh:176-250,332-390`, `docs/version-pinning.md` (M01 ports it). It changes the `Dockerfile` I03 ported.
**Study refs:** D-two-epoch-pin-model, T-crossdev-query-empty, T-live-ebuild-and-host-keyword-skew, T-libatomic-static, T-builder-image-tag-not-pushed, T-portage-snapshot-fetch; build.yaml hazards (stage3 by tag, `main`-branch installers, `docker commit` not reproducible).

## Purpose
The builder image can be rebuilt from inputs we hold, and a human can dispatch one workflow that rebuilds it at a new `TOOLCHAIN_EPOCH` and opens a PR. The first run is not a bump. It rebuilds rc1's image from the stage3 and tree the predecessor used and either reproduces it or lists every difference. This retires the hand-copied digest from Step 0. It is off the path to MS2.

## Standard mechanism
- Base: `gentoo/stage3:amd64-openrc-20260810`, still on Docker Hub (the lead's report; unverified here), pinned by digest and copied into `${REGISTRY}/stage3` so Docker Hub pruning cannot break a rebuild. Gentoo's signed stage3 tarballs are the standard source for later epochs; that is not this node's work.
- Tree: the 20260810 gentoo-mirror commit, recovered and archived exactly as I02 does (candidate = newest commit at or before the snapshot cut, confirmed against the package versions in `docs/builder-manifests/rc1.txt`). No new tool: I02's `seed-tree.sh`.
- Build: the ported `Dockerfile` and `docker commit` crossdev step. crossdev's own documented flow stays. Rewriting it into one multi-stage Dockerfile was considered; no demonstrated benefit.
- Custom code: none new.

## Tests
- **Ported first:** none; the predecessor had no test of the builder rebuild.
- **Added:** `scripts/tests/builder-rebuild.test.sh`.
- **Baseline:** the rc1 builder's tool manifest (I03) is what the rebuilt image is compared with.

## Changes from the port
1. **Pin the stage3.** `FROM gentoo/stage3:amd64-openrc-${TOOLCHAIN_EPOCH}` (`Dockerfile:30`) gets `@sha256:<digest>` of the Docker Hub image (the digest is read at implementation time and mirrored with `oras cp` to `${REGISTRY}/stage3@<digest>`). A tag alone can be re-pushed. *Proof:* M02-AC-1.
2. **Take the tree from the archive.** `RUN emerge-webrsync --revert=${TOOLCHAIN_EPOCH}` (`Dockerfile:74`) becomes `COPY tree/ /var/db/repos/gentoo/`. `make build-image` first runs I02's restore of `gentoo-tree@${TREE_DIGEST_TOOLCHAIN}` into `./tree/`. The original also baked the tree into the image, so the shape is unchanged. The snapshot is no longer fetched from the network. *Proof:* M02-AC-1, M02-AC-2.
3. **Push under the shared name.** `REGISTRY_IMAGE` (`Makefile:48`) becomes `${REGISTRY}/builder`, so `make push-image` produces what I03's `pull-image` consumes. The build is followed by `builder-manifest.sh` (I03). The new digest goes into `BUILDER_DIGEST` through the bump PR only. *Proof:* M02-AC-4.
4. **`toolchain-bump.yml`: keep human-gated, re-point inputs.**
   - The predecessor workflow has no `--admin` and no merge step; its last step is `gh pr create` (`toolchain-bump.yml:309-316`). The `--admin` in `pin-bump.yml:396` is M01's. This workflow stays that way.
   - It pulls the current builder by `BUILDER_DIGEST`, not `:latest`.
   - `update-build-pins.sh update-toolchain` verified a webrsync snapshot exists for the date (`:364-370`). It now verifies that a `gentoo-tree` artifact exists for the chosen commit, and it fails if the lookup returns nothing or an error (T-crossdev-query-empty already needs this for `crossdev.lock`).
   - `crossdev.lock` is still regenerated from the pre-bump image, the predecessor's documented one-cycle lag (`update-build-pins.sh:197`). Fixing it needs a rewrite and is not shown to be needed.
   - It dispatches `build.yml` on the branch and opens a PR that changes `TOOLCHAIN_EPOCH`, `BUILDER_DIGEST` and `crossdev.lock`. A human merges.
   *Proof:* M02-AC-5.
5. **First run: reproduce rc1's image.** Dispatch with the 20260810 stage3 and tree. Commit the rebuilt image's `builder-manifest.txt` beside rc1's, and `docs/builder-rebuild.md` lists each difference with a cause. Byte identity is not expected: `docker commit`, `syft`/`grype` installed from `main` (`Dockerfile:128-142`), rustup's install script (`:167-170`) and distfiles fetched live all vary (unverified which differ). *Proof:* M02-AC-3.

## Gate
- **M02-AC-1** — `git diff b9f533b -- Dockerfile` shows exactly two changed hunks: the `FROM` line gains `@sha256:<64 hex>` and the `emerge-webrsync` `RUN` becomes `COPY tree/`. *Verify:* `scripts/tests/builder-rebuild.test.sh`.
- **M02-AC-2** — The rebuild runs with no request to `distfiles.gentoo.org` snapshots or `emerge-webrsync` for the tree: `grep -n webrsync Dockerfile Makefile` finds nothing, and the build log has no `webrsync` line. *Verify:* `scripts/tests/builder-rebuild.test.sh` and the dispatch run log.
- **M02-AC-3** — `docs/builder-manifests/rc1.txt` and `rebuilt.txt` exist, and every line of `diff` between them appears in `docs/builder-rebuild.md` with a cause; an empty diff is stated as such. *Verify:* `scripts/tests/builder-rebuild.test.sh` (diff, then `grep -F` each differing package).
- **M02-AC-4** — The rebuilt image passes I03's in-image checks (`-march=i486 -static` 64-bit atomic link, `gcc -m32` `sizeof(long)==4`), and its digest is pushed to `${REGISTRY}/builder`. *Verify:* `toolchain-bump.yml` dispatch (mode: first rebuild).
- **M02-AC-5** — `toolchain-bump.yml` contains no `gh pr merge`, no `--admin` and no `schedule:`; its only triggers are `workflow_dispatch`. *Verify:* `scripts/tests/builder-rebuild.test.sh`.
- **M02-AC-6** — A ci-build run (B03) using the rebuilt image resolves the same world versions as `versions.lock` and completes. *Verify:* `build.yml` run on the bump PR branch.

## Risks
- The 20260810 tree commit is not known. It is found the way I02 finds rc1's tree; the image manifest, not a timestamp, decides.
- Live distfiles for the host tools and crossdev may have vanished upstream since August (unverified). The rebuild then fails, which is a finding: the PR lists it and the adopted image stays pinned.
- The rebuilt image will not equal rc1's byte for byte (change 5). Whether the package set equals it is what AC-3 and AC-6 settle.
- The workflow pushes with `GITHUB_TOKEN`; a PR opened that way does not trigger its own checks. The workflow dispatches `build.yml` itself instead. OD-6 (bump credential) concerns M01 and may simplify this later.
- Docker Hub may drop `gentoo/stage3:amd64-openrc-20260810`; mirroring it in change 1 is the answer, and must happen before the tag is pruned.
