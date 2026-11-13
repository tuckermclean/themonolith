# M02 — builder-rebuild

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | I03, M01 | M03 | — | L |

**Owns:** `Dockerfile` (two edits), `Makefile` `build-image`/`push-image` (registry name) and the pins `TREE_COMMIT_TOOLCHAIN`/`TREE_DIGEST_TOOLCHAIN`, `.github/workflows/toolchain-bump.yml`, `scripts/update-build-pins.sh` (`update-toolchain` verification), `scripts/tests/builder-rebuild.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `Makefile:50-64` (`REGISTRY_TAG`) and `:255-345` (the `build-image` and `push-image` targets: the `docker run` plus `docker commit` crossdev build), `.github/workflows/toolchain-bump.yml`, `scripts/update-build-pins.sh:176-250,332-390`, `docs/version-pinning.md` (M01 ports it). It changes the `Dockerfile` I03 ported.
**Study refs:** D-two-epoch-pin-model, T-crossdev-query-empty, T-live-ebuild-and-host-keyword-skew, T-libatomic-static, T-builder-image-tag-not-pushed, T-portage-snapshot-fetch; build.yaml hazards (stage3 by tag, `main`-branch installers, `docker commit` not reproducible).

## Purpose
The builder image can be rebuilt from inputs we hold, and a human can dispatch one workflow that archives the tree it builds from, rebuilds the image at a chosen `TOOLCHAIN_EPOCH` and opens a PR. GitHub runs `workflow_dispatch` only for workflow files on the default branch, so the workflow's first run, which rebuilds rc1's image and compares it, is M03, after this node merges. It is off the path to MS2.

## Standard mechanism
- Base: `gentoo/stage3:amd64-openrc-20260810` on Docker Hub, digest `sha256:806bbc0c87a3ac0f2640ed82ec6f509e042071639e52ba30a2acbc8c8026a278` (read 2026-11-12), pinned by that digest. It is copied by digest to `${REGISTRY}/stage3:amd64-openrc-20260810` (`registry-copy.yml` run 43365038180, 2026-11-13; the copy has the same digest and pulls anonymously) so Docker Hub pruning cannot break a rebuild. Gentoo's signed stage3 tarballs are the standard source for later epochs; that is not this node's work.
- Tree: a gentoo-mirror commit chosen at dispatch (`tree_commit`) and archived with I02's `seed-tree.sh` by the workflow's own archive job, as M01's `pin-bump.yml` does. No new tool. Finding the 20260810 commit is M03's.
- Build: the ported `Dockerfile` and `docker commit` crossdev step. crossdev's own documented flow stays. Rewriting it into one multi-stage Dockerfile was considered; no demonstrated benefit.
- Custom code: none new.

## Tests
- **Ported first:** none; the predecessor had no test of the builder rebuild.
- **Added:** `scripts/tests/builder-rebuild.test.sh`. It needs no rebuilt image and no `docs/builder-manifests/rebuilt.txt`; the tests that do are M03's.
- **Baseline:** not practical against `b9f533b`: every criterion here is a change from the port (the pinned `FROM`, the `COPY tree/`, the triggers, the empty-pin failure, the archive job), so each fails there by construction.

## Changes from the port
1. **Pin the stage3.** `FROM gentoo/stage3:amd64-openrc-${TOOLCHAIN_EPOCH}` (`Dockerfile:30`) gets `@sha256:<digest>` of the Docker Hub image (the digest above, mirrored to `${REGISTRY}/stage3`). A tag alone can be re-pushed. *Proof:* M02-AC-1.
2. **Take the tree from the archive.** `RUN emerge-webrsync --revert=${TOOLCHAIN_EPOCH}` (`Dockerfile:74`) becomes `COPY tree/ /var/db/repos/gentoo/`. `make build-image` first runs I02's restore of `gentoo-tree@${TREE_DIGEST_TOOLCHAIN}` into `./tree/`. The original also baked the tree into the image, so the shape is unchanged. The snapshot is no longer fetched from the network. The comments at `Dockerfile:67` and `:83` that say the tree comes from `emerge-webrsync` are corrected to say it comes from the archive. The `Makefile` carries two pins, `TREE_COMMIT_TOOLCHAIN` and `TREE_DIGEST_TOOLCHAIN`. They stay empty until the first dispatch's bump PR writes them, and while either is empty `make build-image` fails with a message naming it. *Proof:* M02-AC-1, M02-AC-2, M02-AC-4.
3. **Push under the shared name.** `REGISTRY_IMAGE` (`Makefile:48`) becomes `${REGISTRY}/builder`, so `make push-image` produces what I03's `pull-image` consumes. The build is followed by `builder-manifest.sh` (I03). The new digest goes into `BUILDER_DIGEST` through the bump PR only. *Proof:* M03-AC-1 (the first dispatch).
4. **`toolchain-bump.yml`: keep human-gated, re-point inputs.**
   - The predecessor workflow has no `--admin` and no merge step; its last step is `gh pr create` (`toolchain-bump.yml:309-316`). The `--admin` in `pin-bump.yml:396` is M01's. This workflow stays that way.
   - It pulls the current builder by `BUILDER_DIGEST`, not `:latest`.
   - It takes a `tree_commit` dispatch input. An `archive` job like `pin-bump.yml`'s, with `packages: write`, runs `seed-tree.sh` for that commit unless `gentoo-tree:<commit40>` exists. It runs before the job that runs `update-toolchain`.
   - The predecessor stops when the target epoch equals the current one (`toolchain-bump.yml:120-126`). A first-rebuild dispatch mode rebuilds at the current epoch instead, so M03 can rebuild rc1's image at 20260810.
   - `update-build-pins.sh update-toolchain` verified a webrsync snapshot exists for the date (`:364-370`). It now verifies that a `gentoo-tree` artifact exists for the chosen commit, fails if the lookup returns nothing or an error (T-crossdev-query-empty already needs this for `crossdev.lock`), and writes `TREE_COMMIT_TOOLCHAIN` and `TREE_DIGEST_TOOLCHAIN`.
   - `crossdev.lock` is still regenerated from the pre-bump image, the predecessor's documented one-cycle lag (`update-build-pins.sh:197`). Fixing it needs a rewrite and is not shown to be needed.
   - It dispatches `build.yml` on the branch and opens a PR that changes `TOOLCHAIN_EPOCH`, `BUILDER_DIGEST`, the two tree pins and `crossdev.lock`. A human merges.
   *Proof:* M02-AC-3, M02-AC-5.

## Gate
- **M02-AC-1** — Ignoring comment lines (`#`), `git diff b9f533b -- Dockerfile` shows exactly two changed hunks: the `FROM` line gains `@sha256:<64 hex>` and the `emerge-webrsync` `RUN` becomes `COPY tree/`. *Verify:* `scripts/tests/builder-rebuild.test.sh`.
- **M02-AC-2** — The rebuild runs with no request to `distfiles.gentoo.org` snapshots or `emerge-webrsync` for the tree: `grep -n webrsync Dockerfile Makefile` finds nothing. *Verify:* `scripts/tests/builder-rebuild.test.sh`. The first dispatch's build log is M03-AC-2.
- **M02-AC-3** — `toolchain-bump.yml` contains no `gh pr merge`, no `--admin` and no `schedule:`; its only triggers are `workflow_dispatch`. *Verify:* `scripts/tests/builder-rebuild.test.sh`.
- **M02-AC-4** — `make build-image` with `TREE_COMMIT_TOOLCHAIN` or `TREE_DIGEST_TOOLCHAIN` empty exits non-zero with a message naming the empty pin, before it restores a tree or runs `docker`. *Verify:* `scripts/tests/builder-rebuild.test.sh`.
- **M02-AC-5** — `toolchain-bump.yml` has a `tree_commit` input, a first-rebuild mode, and an `archive` job with `packages: write` that runs `scripts/seed-tree.sh` only when `gentoo-tree:<commit40>` is absent; the job that runs `update-build-pins.sh update-toolchain` needs it. *Verify:* `scripts/tests/builder-rebuild.test.sh`.

## Risks
- Nothing in this gate runs the workflow: GitHub dispatches only workflows on the default branch. A fault only a real dispatch shows surfaces at M03's dispatch, and its fix must reach `main` before the dispatch runs again.
- Live distfiles for the host tools and crossdev may have vanished upstream since August (unverified). A rebuild then fails, which is a finding: no bump PR is opened and the adopted image stays pinned.
- A bump to a new epoch needs a new stage3 digest and mirror (change 1 pins the 20260810 digest, and the workflow does not update it) and an update to M02-AC-1's test (the bump changes `ARG TOOLCHAIN_EPOCH`). No node does this yet.
- The workflow pushes with `GITHUB_TOKEN`; a PR opened that way does not trigger its own checks. The workflow dispatches `build.yml` itself instead. OD-6 (bump credential) concerns M01 and may simplify this later.
