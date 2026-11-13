# M03 — builder-first-rebuild

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | M02 | none | — | M |

**Owns:** `docs/builder-rebuild.md`, `docs/builder-manifests/{rc1,rebuilt}.txt`, `scripts/tests/builder-first-rebuild.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** none. It runs M02's `toolchain-bump.yml`.
**Study refs:** T-libatomic-static, T-live-ebuild-and-host-keyword-skew, T-portage-snapshot-fetch, T-crossdev-query-empty; build.yaml hazards (`main`-branch installers, `docker commit` not reproducible).

## Purpose
rc1's builder image is rebuilt on GitHub from the 20260810 stage3 and tree by M02's workflow, and the rebuilt image's tool manifest sits beside rc1's with every difference explained. This retires the hand-copied digest from Step 0: the builder is then something we can make again, not only something we hold. GitHub runs `workflow_dispatch` only for workflow files on the default branch, so this runs after M02 merges. It is off the path to MS2.

## Standard mechanism
- Stage3: the digest M02 pins, mirrored at `${REGISTRY}/stage3:amd64-openrc-20260810`.
- Tree: the 20260810 gentoo-mirror commit, found exactly as I02 found rc1's (candidate = newest commit at or before the snapshot cut, confirmed against the package versions in `docs/builder-manifests/rc1.txt`), and passed as M02's `tree_commit` input; M02's archive job archives it with I02's `seed-tree.sh`.
- Build: M02's `toolchain-bump.yml`, dispatched on `main` in its first-rebuild mode. Manifests: I03's `builder-manifest.sh`.
- Custom code: none new.

## Tests
- **Ported first:** none; the predecessor had no test of the builder rebuild.
- **Added:** `scripts/tests/builder-first-rebuild.test.sh`, its own file, because it needs `docs/builder-manifests/rebuilt.txt`, which only the dispatch produces.
- **Baseline:** the rc1 builder's tool manifest (I03), committed as `rc1.txt`, is what the rebuilt image is compared with.

## Changes from the port
1. **Find the tree.** The 20260810 gentoo-mirror commit is found the way I02 found rc1's tree; the image manifest, not a timestamp, decides. `rc1.txt` is `make builder-manifest` on rc1's image (`BUILDER_REF` = `${REGISTRY}/builder@sha256:ab04002a…`). *Proof:* M03-AC-3.
2. **Dispatch the first rebuild.** `toolchain-bump.yml` is dispatched on `main` in its first-rebuild mode, with `TOOLCHAIN_EPOCH` 20260810 and that `tree_commit`. It archives the tree, rebuilds and pushes the image, dispatches `build.yml` on the bump branch and opens the bump PR. *Proof:* M03-AC-1, M03-AC-2, M03-AC-4.
3. **Compare.** The rebuilt image's `builder-manifest.txt` is committed as `rebuilt.txt` beside `rc1.txt`, and `docs/builder-rebuild.md` lists each difference with a cause. Byte identity is not expected: `docker commit`, `syft`/`grype` installed from `main` (`Dockerfile:128-142`), rustup's install script (`:167-170`) and distfiles fetched live all vary (unverified which differ). *Proof:* M03-AC-3.

## Gate
- **M03-AC-1** — The rebuilt image passes I03's in-image checks (`-march=i486 -static` 64-bit atomic link, `gcc -m32` `sizeof(long)==4`), and its digest is pushed to `${REGISTRY}/builder`. *Verify:* `toolchain-bump.yml` dispatch on `main` (mode: first rebuild).
- **M03-AC-2** — The first rebuild's build log has no `webrsync` line. *Verify:* the dispatch run log.
- **M03-AC-3** — `docs/builder-manifests/rc1.txt` and `rebuilt.txt` exist, and every line of `diff` between them appears in `docs/builder-rebuild.md` with a cause; an empty diff is stated as such. *Verify:* `scripts/tests/builder-first-rebuild.test.sh` (diff, then `grep -F` each differing package).
- **M03-AC-4** — A ci-build run (B03) using the rebuilt image resolves the same world versions as `versions.lock` and completes. *Verify:* `build.yml` run on the bump PR branch.

## Risks
- The 20260810 tree commit is not known. It is found the way I02 finds rc1's tree; the image manifest, not a timestamp, decides.
- Live distfiles for the host tools and crossdev may have vanished upstream since August (unverified). The rebuild then fails, which is a finding: the PR lists it and the adopted image stays pinned.
- The rebuilt image will not equal rc1's byte for byte (change 3). Whether the package set equals it is what AC-3 and AC-4 settle.
- A fault in M02's workflow that only a real dispatch shows needs its fix merged to `main` before the dispatch can run again.
- Merging the bump PR moves `BUILDER_DIGEST` off rc1's image. Whether to merge it is the owner's call, made with `docs/builder-rebuild.md`.
