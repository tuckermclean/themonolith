# I02 — tree-pin

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | I01 | B01, R02 | — | M |

**Owns:** `scripts/sync-portage.sh` (rewritten, see Changes), `scripts/tests/sync-portage.test.sh`, `scripts/seed-tree.sh` (one-time archive helper), the `TREE_COMMIT` and `TREE_DIGEST` pins in `Makefile`, `docs/tree-pin.md` (the recovery evidence: candidate range, match counts, signature result).
**Ports from linux-live-iso-factory@b9f533b:** `scripts/sync-portage.sh` (`_fetch_one` loop, `--source-only` detection at `:101-112`). The Makefile `sync-portage` target (`Makefile:380-389`) keeps its name.
**Study refs:** T-portage-snapshot-fetch, D-two-epoch-pin-model, OD-3; `sync-portage.sh:8-17` (why the predecessor served a local HTTP mirror).

## Purpose
rc1's Gentoo tree becomes a pin we can restore: a gentoo-mirror commit, archived once as an OCI artifact `${REGISTRY}/gentoo-tree:<commit40>` and referenced by digest. `sync-portage.sh` restores it into the portage volume with no upstream access, and fails loudly when the artifact is missing or the digest differs. The snapshot tarball `gentoo-20260811.tar.xz` no longer exists upstream (SPEC §0), so a tree commit from `github.com/gentoo-mirror/gentoo` is what survives.

## Standard mechanism
- Pin: a git commit of the gentoo-mirror repository. Portage's own `sync-type = git` pins by branch and cannot go back; we fetch a commit by hand once and archive it.
- Archive: `git archive <commit>` (tar, entries stamped with the commit time) compressed with `zstd`, pushed with `oras push` as one layer. Restore: `oras pull <ref>@<digest>` then `tar -x` into `/var/db/repos/gentoo`. This replaces `emerge-webrsync` plus a loopback HTTP server (`sync-portage.sh:80-99`), which existed only to feed a dated tarball to the webrsync fetcher.
- Signature: Portage's standard path is `sync-git-verify-commit-signature = yes` with `sync-openpgp-key-path` (git) or `gemato` over the Manifest tree. Both need a trusted key. Gentoo mirrors commits are expected to be signed by Gentoo's repository-mirror key (unverified). We use `git verify-commit` against the key shipped by Gentoo (`sec-keys/openpgp-keys-gentoo-release`, unverified to be the right key) once, at archive time, and record the result. No custom verifier.
- Custom code: `seed-tree.sh`, a ~30-line script (fetch, verify, archive, push). Gap: no standard tool archives an old commit into our registry. It runs by hand or by `workflow_dispatch`, never in the build.

## Changes from the port
1. **Recover rc1's commit.** Steps, recorded in `docs/tree-pin.md`:
   a. Get rc1's binpkgs (`ghcr.io/tuckermclean/monolith-binpkgs:20260811`, digest in SPEC §0).
   b. For each non-overlay gpkg, extract the embedded ebuild (a gpkg's metadata archive is expected to carry `<pf>.ebuild`; unverified) and compare its git blob id with `git cat-file` of `<cat>/<pn>/<pf>.ebuild` at each commit from 2026-08-10T00:00Z to 2026-08-11T06:00Z.
   c. Candidates are commits where every ebuild matches. Take the newest candidate at or before 2026-08-11T00:00Z (the snapshot cut time is unverified). The lead's sampling found `d4d0b0c78bd9a3b0b81434268dd96e6f97b294cb` (2026-08-10T22:30Z) matched 25 of 25 `versions.lock` entries; it is the starting candidate, not yet the answer.
   d. Confirm with Portage itself: inside the rc1 builder with the restored tree and rc1's binpkgs, `emerge -pv --usepkgonly` of the world lists every package as `[binary` and `portageq best_visible` equals `versions.lock` for a sample. The tree is accepted on that result.
   *Proof:* I02-AC-1, I02-AC-2.
2. **Archive and pin.** `seed-tree.sh <commit40>` fetches only that commit, runs `git verify-commit` and logs the outcome (a signed, unsigned or key-missing result is written to `docs/tree-pin.md` either way), archives, and pushes `gentoo-tree:<commit40>`. The Makefile gains `TREE_COMMIT` and `TREE_DIGEST` in place of `BUILD_EPOCH` for the tree; `BUILD_EPOCH` remains only where B01 still reads it for the version label until M01. *Proof:* I02-AC-3.
3. **Restore by digest, fail loud.** `sync-portage.sh` is replaced by: `oras pull "${REGISTRY}/gentoo-tree@${TREE_DIGEST}"`, check the pulled file's name matches `TREE_COMMIT`, extract into the volume. It has no network fallback, no S3, no webrsync. A missing artifact, a failed pull or a digest mismatch exits non-zero with the ref in the message. Upstream is never contacted, which is the point of D-two-epoch-pin-model's runtime pin. *Proof:* I02-AC-4, I02-AC-5.
4. **Tests.** The predecessor's `sync-portage.test.sh` tests S3 and webrsync, which are gone, so it is not ported. `sync-portage.test.sh` is written from I02-AC-4 and -6. *Proof:* I02-AC-4.

## Gate
- **I02-AC-1** — `docs/tree-pin.md` names one commit, the list of non-overlay gpkgs compared, the count that matched, and any unmatched package with the reason. *Verify:* review of the PR; `grep -E '^[0-9a-f]{40}$'` in the doc by `scripts/tests/tree-pin.test.sh`. *Tier:* fast.
- **I02-AC-2** — With the restored tree in the rc1 builder, `emerge -pv --usepkgonly` of `configs/portage/world` against rc1's binpkgs shows no package to be built from source (overlay packages excepted and listed). *Verify:* a `workflow_dispatch` job `tree-accept`. *Tier:* slow.
- **I02-AC-3** — `gentoo-tree:<commit40>` exists on GHCR, `TREE_DIGEST` equals its manifest digest, and `git archive` of the commit listed by `git ls-tree -r` has the same file count as the extracted tarball. *Verify:* `seed-tree.sh` output in the `tree-accept` job; `oras manifest fetch`. *Tier:* slow.
- **I02-AC-4** — `sync-portage.sh` with a stub `oras` restores the fixture tree; it exits non-zero for a missing artifact, a digest mismatch or an empty archive, and never calls `wget`, `curl` or `aws`. Sourced with `--source-only`, it defines its functions and runs nothing. *Verify:* `scripts/tests/sync-portage.test.sh`. *Tier:* fast.
- **I02-AC-5** — A build job restores the tree from the digest with network access to `distfiles.gentoo.org` and `rsync.gentoo.org` blocked, and `/var/db/repos/gentoo` equals the archive. *Verify:* the `tree-accept` job (`unshare -n` after pulling, or `--network none` container). *Tier:* slow.
- **I02-AC-6** — `seed-tree.sh` refuses a commit that is not 40 hex digits and refuses to overwrite an existing `gentoo-tree:<commit40>`. *Verify:* `scripts/tests/sync-portage.test.sh` (stubbed `git`, `oras`). *Tier:* fast.

## Risks
- Several commits may match all ebuilds. The tree snapshot was cut at an instant we do not know; eclass or profile differences between candidates would be seen only by AC-2, which tests the actual effect.
- Gentoo may not sign mirror commits, or the key may not be where expected (unverified). If unsigned, the pin rests on the commit hash, the ebuild match and AC-2; the owner accepts that in the PR. No new open decision id is raised.
- Unverified: GitHub serves a fetch by commit SHA for this repository; `metadata/md5-cache` is present in the mirror (without it the first emerge regenerates metadata slowly); the gpkg embeds its ebuild.
- OD-3: if the owner answers "current tree", step 1 shrinks to choosing a commit and AC-2 is not run.
- A tree archive is tens of MB (estimate). GHCR keeps it; nothing deletes it.
