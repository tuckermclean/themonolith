# I02 — tree-pin

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | I01 | B01, R02 | — | M |

**Owns:** `scripts/sync-portage.sh` (rewritten, see Changes), `scripts/tests/sync-portage.test.sh`, `scripts/seed-tree.sh` (one-time archive helper), the `TREE_COMMIT` and `TREE_DIGEST` pins in `Makefile`, `docs/tree-pin.md` (the recovery evidence: candidate range, match counts, signature result).
**Ports from linux-live-iso-factory@b9f533b:** first the test `scripts/tests/sync-portage.test.sh`; then `scripts/sync-portage.sh` (`_fetch_one` loop, `--source-only` detection at `:101-112`). The Makefile `sync-portage` target (`Makefile:380-389`) keeps its name.
**Study refs:** T-portage-snapshot-fetch, D-two-epoch-pin-model, OD-3; `sync-portage.sh:8-17` (why the predecessor served a local HTTP mirror).

## Purpose
rc1's Gentoo tree becomes a pin we can restore: a gentoo-mirror commit, archived once as an OCI artifact `${REGISTRY}/gentoo-tree:<commit40>` and referenced by digest. `sync-portage.sh` restores it into the portage volume with no upstream access, and fails loudly when the artifact is missing or the digest differs. The snapshot tarball `gentoo-20260811.tar.xz` no longer exists upstream (SPEC §0), so a tree commit from `github.com/gentoo-mirror/gentoo` is what survives.

## Standard mechanism
- Pin: a git commit of the gentoo-mirror repository. Portage's own `sync-type = git` pins by branch and cannot go back; we fetch a commit by hand once and archive it.
- Archive: `git archive <commit>` (tar, entries stamped with the commit time) compressed with `zstd`, pushed with `oras push` as one layer. Restore: `oras pull <ref>@<digest>` then `tar -x` into `/var/db/repos/gentoo`. This replaces `emerge-webrsync` plus a loopback HTTP server (`sync-portage.sh:80-99`), which existed only to feed a dated tarball to the webrsync fetcher.
- Signature: Portage's standard path is `sync-git-verify-commit-signature = yes` with `sync-openpgp-key-path` (git) or `gemato` over the Manifest tree. Both need a trusted key. Gentoo mirrors commits are expected to be signed by Gentoo's repository-mirror key (unverified). We use `git verify-commit` against the key shipped by Gentoo (`sec-keys/openpgp-keys-gentoo-release`, unverified to be the right key) once, at archive time, and record the result. No custom verifier.
- Custom code: `seed-tree.sh`, a ~30-line script (fetch, verify, archive, push). Gap: no standard tool archives an old commit into our registry. It runs by hand or by `workflow_dispatch`, never in the build.

## Tests
- **Ported first:** `scripts/tests/sync-portage.test.sh`, its cases changed only as change 4 requires.
- **Added:** `scripts/tests/tree-pin.test.sh` (AC-1) and the AC-6 cases of `seed-tree.sh`.
- **Baseline:** not practical: the restore by digest replaces the predecessor's S3 and webrsync fetch. Case 3 (no source, hard error) still fails loudly on `b9f533b`'s script.

## Changes from the port
1. **Recover rc1's commit.** Steps, recorded in `docs/tree-pin.md`:
   a. Read the tree commit rc1 recorded. Each package in rc1's Portage VDB (`var/db/pkg/<cat>/<pf>/` in rc1's rootfs, which O02's `make rootfs` extracts) has a `REPO_REVISIONS` file that Portage writes from the tree's `metadata/timestamp.commit`. All 152 `repository = gentoo` entries name the same gentoo.git commit, `6622796b6162d6f41b6556041027f19e7964028e` (2026-08-11T22:55Z), checked on this host. Overlay entries (11, `repository = monolith`) are excepted and listed.
   b. Map it to gentoo-mirror: the pin is the mirror commit whose tree is gentoo.git at that commit plus its regenerated `metadata/md5-cache`. That is `6e88ed01f3e97de8710efe1c333808dfbd05bf32` (2026-08-11T23:00:56Z, the cache commit right after the merge `ebecde92`, whose second parent is `6622796b`); the next merge, `c4b67600`, brings later gentoo.git commits. Checked on this host.
   c. Cross-check the ebuilds: the git blob id of each gentoo VDB entry's `<pf>.ebuild` equals `git cat-file` of `<cat>/<pn>/<pf>.ebuild` at the pin (152 of 152 on this host). The check does not single out a commit: 61 mirror commits from 2026-08-11T06:15Z onward match all 152, and the earlier candidate `d4d0b0c7` (2026-08-10T22:30Z) matches 151 (it predates `expat-2.8.3`). `REPO_REVISIONS` decides; the blob match only rules out a wrong mapping.
   d. Confirm with Portage itself: inside the rc1 builder with the restored tree and rc1's binpkgs, `emerge -pv --usepkgonly` of the world lists every package as `[binary` and `portageq best_visible` equals `versions.lock` for a sample. The tree is accepted on that result.
   *Proof:* I02-AC-1, I02-AC-2.
2. **Archive and pin.** `seed-tree.sh <commit40>` fetches only that commit, runs `git verify-commit` and logs the outcome (a signed, unsigned or key-missing result is written to `docs/tree-pin.md` either way), archives, and pushes `gentoo-tree:<commit40>`. The Makefile gains `TREE_COMMIT` and `TREE_DIGEST` in place of `BUILD_EPOCH` for the tree; `BUILD_EPOCH` remains only where B01 still reads it for the version label until M01. *Proof:* I02-AC-3.
3. **Restore by digest, fail loud.** `sync-portage.sh` is replaced by: `oras pull "${REGISTRY}/gentoo-tree@${TREE_DIGEST}"`, check the pulled file's name matches `TREE_COMMIT`, extract into the volume. It has no network fallback, no S3, no webrsync. A missing artifact, a failed pull or a digest mismatch exits non-zero with the ref in the message. Upstream is never contacted, which is the point of D-two-epoch-pin-model's runtime pin. *Proof:* I02-AC-4, I02-AC-5.
4. **Test cases.** The ported `sync-portage.test.sh` stubs `aws` and `wget` for S3 and webrsync, which this node replaces. Its cases change only as far as the replacement requires: case 3 (no source has the tree, a hard error) becomes the missing-artifact case; cases 1, 2 and 4 (S3 hit, S3 miss and archive, no bucket) and case 5 (optional `.md5sum`) test sources that no longer exist, so they become a restore with a stub `oras` serving a fixture archive, a pull of a different file failing, and `--source-only` sourcing without side effects. *Proof:* I02-AC-4.

## Gate
- **I02-AC-1** — `docs/tree-pin.md` names one commit, the `REPO_REVISIONS` value it maps from, the list of gentoo VDB entries compared, the count that matched, and any unmatched package with the reason. *Verify:* review of the PR; `grep -E '^[0-9a-f]{40}$'` in the doc by `scripts/tests/tree-pin.test.sh`.
- **I02-AC-2** — With the restored tree in the rc1 builder, `emerge -pv --usepkgonly` of `configs/portage/world` against rc1's binpkgs shows no package to be built from source (overlay packages excepted and listed). *Verify:* locally in the rc1 builder pulled by digest, with `b9f533b`'s `configs/portage/` (B01 ports it; until then it is not in this repository, so no job here can read it), log under `out/node/I02/`. B03's build reruns the same check on every build once B01 has landed.
- **I02-AC-3** — `gentoo-tree:<commit40>` exists on GHCR, `TREE_DIGEST` equals its manifest digest, and `git archive` of the commit listed by `git ls-tree -r` has the same file count as the extracted tarball. *Verify:* `seed-tree.sh` output in the `tree-accept` job; `oras manifest fetch`.
- **I02-AC-4** — `sync-portage.sh` with a stub `oras` restores the fixture tree; it exits non-zero for a missing artifact, a digest mismatch or an empty archive, and never calls `wget`, `curl` or `aws`. Sourced with `--source-only`, it defines its functions and runs nothing. *Verify:* `scripts/tests/sync-portage.test.sh`.
- **I02-AC-5** — A build job restores the tree from the digest with network access to `distfiles.gentoo.org` and `rsync.gentoo.org` blocked, and `/var/db/repos/gentoo` equals the archive. *Verify:* the `tree-accept` job (`unshare -n` after pulling, or `--network none` container).
- **I02-AC-6** — `seed-tree.sh` refuses a commit that is not 40 hex digits and refuses to overwrite an existing `gentoo-tree:<commit40>`. *Verify:* `scripts/tests/sync-portage.test.sh` (stubbed `git`, `oras`).

## Risks
- Several commits match all ebuilds (61 do); `REPO_REVISIONS` names the one rc1 used, and AC-2 tests the effect. The archive of a mirror commit has no `metadata/timestamp.commit` (the snapshot tarball had one), so a build from it records a different `REPO_REVISIONS`; nothing reads it.
- Checked: the pin carries a `gpgsig`, and `git verify-commit` against `/usr/share/openpgp-keys/gentoo-release.asc` in the rc1 builder reports a good signature from "Gentoo repository mirrors (automated git signing key)", key `F748E9B3C47E393CC24C8FAF7C2AC09CD98F2EDF`. The toolbox has no `gpg`, so `seed-tree.sh` verifies where `gpg` and that key exist and records `key-missing` otherwise.
- Unverified: GitHub serves a fetch of one commit by SHA (`git fetch --depth 1 origin <sha>`) for this repository. Checked: `metadata/md5-cache` is present at the pin.
- OD-3: if the owner answers "current tree", step 1 shrinks to choosing a commit and AC-2 is not run.
- A tree archive is tens of MB (estimate). GHCR keeps it; nothing deletes it.
