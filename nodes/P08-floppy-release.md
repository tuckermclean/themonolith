# P08 — floppy-release

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | B06, P01, P02 | none | — | M |

**Owns:** the floppy extraction in the `Makefile`'s `release-assets` target (change 1; P01 owns the target), the `floppy-attestation` job of `.github/workflows/build.yml`'s tag path (change 3; P01 owns the file and its `attestation` job), the floppy in `scripts/release-sums.sh` and `scripts/release-create.sh` (P01 owns the scripts; P06 and P07 own their parts of `release-create.sh`), `scripts/release-floppy-chain.sh`, its Make target `release-floppy-chain` and its step in the publish job of `.github/workflows/release.yml` (change 4; P01 owns the job), lines 106-107 of `scripts/tests/dashboard-workflow.test.sh` (P04's frozen test; see Tests), the floppy lines of `docs/releasing.md`, `scripts/tests/floppy-release.test.sh`, `scripts/fixtures/P08/`, the P08 row of `docs/capabilities.md`.
**Resolves:** #130
**Ports from linux-live-iso-factory@b9f533b:** none. P01 wrote the release path; this node adds one asset to it.
**Study refs:** D-supply-chain-honesty, P01 (the digest chain, SHA256SUMS, the ISO's attestation), P02 (two offline builds, equal ISO digests), B06 (`/boot/floppy.img`), T-attest-entry-workflow, T-workflow-push-needs-pat; the owner's answer on issue #130 (2026-11-27): the floppy is a release asset of its own and is on the CD, and the ISO stays the definitive artifact.

## Purpose
B06 puts the boot floppy on the CD as `/boot/floppy.img`. The owner also wants it published on its own, for someone who has a 486 and no way to boot a CD, while the ISO stays the definitive artifact that carries everything. After this node every release has a `themonolith-<version>-floppy.img` asset, byte for byte the `/boot/floppy.img` of the ISO that passed P02's gate, so the gate's equal ISO digests cover it too. It is listed in SHA256SUMS and has a provenance attestation of its own beside the ISO's. The publish job checks it against the ISO's copy, its SHA256SUMS line and that attestation. The ISO's attestation and its digest chain are P01's, unchanged.

## Standard mechanism
- `xorriso -osirrox on -indev <iso> -extract /boot/floppy.img <file>` takes the asset from the gated ISO; nothing rebuilds it.
- `actions/attest-build-provenance` with the floppy as its one `subject-path`, in its own job of `build.yml` (the entry workflow, T-attest-entry-workflow); `gh attestation verify` checks it.
- SHA256SUMS and the release upload are P01's scripts, each extended by one file.
- Custom code: `scripts/release-floppy-chain.sh`, the floppy's digest check in the publish job, in the form of P01's `release-digest-chain.sh`. One test, `scripts/tests/floppy-release.test.sh`.

## Tests
- **Ported first:** none.
- **Frozen tests changed:** P04's `scripts/tests/dashboard-workflow.test.sh`, lines 106-107 only: `mk_rel`'s file list gains `themonolith-0.2.0-floppy.img`. Its release directory has no floppy, and `:110` requires `release-sums.sh` to succeed on it, which fails once `release-sums.sh` requires the floppy (change 2). Every check of the file stays the same. The line changes only with the owner's approval, asked on PR #131; until it is given, the node does not start.
- **Kept unchanged:**
  - P01's `scripts/tests/release-workflow.test.sh`: the `attestation` job keeps its two attest steps with the ISO as their only subject (`:27-28`, `:481`, `:508`, `:513-515`); the floppy's attestation is in another job. Its SHA256SUMS case (`:446-461`) wants the step that writes SHA256SUMS before the first attest step of that job, which `release-assets` still is. Its publish-order case (`:336-350`) passes with the floppy check after `make release-digest-chain` and before `oras push`.
  - P01's `scripts/release-digest-chain.sh` and `scripts/tests/release-digest-chain.test.sh`: the ISO's rule that every subject of its attestation equals the ISO digest (`:25-28`, the test's `:92-93`) stands, because the floppy is not a subject of that attestation.
  - P06's `scripts/tests/release-recovery.test.sh`: its `files_in` wants each of today's files on the create or upload call, not only them, and `release-create.sh` names the floppy with no check of its own, so the test's release directory needs no floppy.
  - P07's `scripts/tests/prerelease-cve.test.sh`.
- **Added:** `scripts/tests/floppy-release.test.sh`, offline in the toolbox, with fixtures in `scripts/fixtures/P08/`:
  - the extraction from a fixture ISO, with and without `/boot/floppy.img` (AC-1);
  - `release-sums.sh` on a release directory with and without the floppy (AC-2);
  - the `floppy-attestation` job, read from `build.yml` (AC-3);
  - `release-floppy-chain.sh` with a stub `gh`, on a floppy that differs from the ISO's copy, from its SHA256SUMS line or from its attestation's subject, each failing (AC-4).
- **Baseline:** on `main` the release has no floppy asset, so AC-1 to AC-4 fail.

## Changes from the port
1. **The asset.** In the tag path's `attestation` job, after P02's gate, the `release-assets` Make target extracts `/boot/floppy.img` from the gated ISO into `$(RELEASE_DIR)/themonolith-<version>-floppy.img`, before it runs `release-sums.sh`. It fails when the ISO has no `/boot/floppy.img`. The file travels with the other release files in the attestation job's release artifact. *AC-1.*
2. **SHA256SUMS.** `release-sums.sh` lists the floppy beside the ISO and fails when it is missing. *AC-2.*
3. **The attestation.** A `floppy-attestation` job of `build.yml`, which `needs` the `attestation` job and runs only on a tag (`if:` with `github.ref_type == 'tag'`). It downloads the attestation job's release artifact, checks the floppy against its SHA256SUMS line (`make release-sums-check`), and runs `actions/attest-build-provenance`, SHA-pinned, with `subject-path` the floppy alone. Its permissions are those of the `attestation` job: `id-token: write`, `attestations: write`, `contents: read`. The ISO's two attestations and their job are unchanged. *AC-3.*
4. **The floppy check.** `scripts/release-floppy-chain.sh <floppy> <iso> <SHA256SUMS> <repo> <signer-workflow>` checks that the floppy's sha256 equals:
   - that of the ISO's `/boot/floppy.img`;
   - its SHA256SUMS entry;
   - every subject of its own attestation (`gh attestation verify <floppy> --repo <repo> --signer-workflow <repo>/.github/workflows/build.yml`).

   It exits 1 naming the floppy when one differs, and 2 on a usage error or an unreadable input, as `release-digest-chain.sh` does. Its Make target `release-floppy-chain` is a step of `release.yml`'s publish job, right after `make release-digest-chain` and before `oras push`, so nothing publishes if it fails. `release-create.sh` uploads the floppy with the other assets on both its create and its upload path. *AC-4.*
5. **Docs.** `docs/releasing.md` lists the asset and how to verify it (`sha256sum -c SHA256SUMS`, `gh attestation verify themonolith-<version>-floppy.img --repo <repo> --signer-workflow <repo>/.github/workflows/build.yml`). `docs/capabilities.md` gains a P08 row. *AC-5.*

## Gate
- **P08-AC-1** — The tag path's `release-assets` target writes `themonolith-<version>-floppy.img` into the release directory before SHA256SUMS. The file is extracted from the gated ISO, byte for byte its `/boot/floppy.img`, and the target fails on an ISO with no `/boot/floppy.img`. No job builds the floppy for the release. *Verify:* `scripts/tests/floppy-release.test.sh` (a fixture ISO with and without the file; `make -n release-assets` and the workflow read).
- **P08-AC-2** — `release-sums.sh` writes a SHA256SUMS that lists the floppy and fails when the floppy is missing from the release directory. *Verify:* `scripts/tests/floppy-release.test.sh`; `scripts/tests/dashboard-workflow.test.sh`.
- **P08-AC-3** — `build.yml` has a `floppy-attestation` job, which `needs` `attestation` and runs only on a tag. It has a SHA-pinned `actions/attest-build-provenance` step whose one `subject-path` is the floppy, and the permissions of change 3. The `attestation` job's attest steps keep the ISO as their only subject. *Verify:* `scripts/tests/floppy-release.test.sh` (the job read from `build.yml`); `scripts/tests/release-workflow.test.sh`; the tag run of AC-6.
- **P08-AC-4** — With a stub `gh`, `release-floppy-chain.sh` passes on a floppy that equals the ISO's `/boot/floppy.img`, its SHA256SUMS entry and its attestation's subject. It fails, naming the floppy, when the floppy differs from any one of them or the attestation has no subject. The publish job runs `make release-floppy-chain` after `make release-digest-chain` and before `oras push`. `release-create.sh` uploads the floppy. *Verify:* `scripts/tests/floppy-release.test.sh` with `scripts/fixtures/P08/`; `scripts/tests/release-workflow.test.sh` (the publish order).
- **P08-AC-5** — `docs/releasing.md` lists the floppy asset and its two verify commands. P01's, P04's, P06's and P07's release tests pass. *Verify:* `scripts/tests/floppy-release.test.sh` (the doc lines); `make test-unit`.
- **P08-AC-6** — The first tag after the merge publishes a release with the floppy asset. Its sha256 equals the released ISO's `/boot/floppy.img` and its SHA256SUMS line, and `gh attestation verify` passes for it. *Verify:* the tag's Build and Release run URLs and the release URL, in a comment on the node PR.

## Risks
- **Release path.** `build.yml`'s tag path and `release.yml` are high-stakes (SPEC §8). The node PR says what changes in them. Nothing publishes earlier than before: the floppy is extracted after P02's gate, its attestation job runs after the ISO's, and the publish job checks it before anything is pushed.
- **Workflow push.** The change touches `.github/workflows/build.yml` and `release.yml`, which needs a token with the `workflow` scope to push (T-workflow-push-needs-pat).
- **Publish trigger.** `release.yml` starts on `workflow_run` of `build.yml`, so it runs once every job of the tag's Build run, `floppy-attestation` included, has finished. The publish job runs only on a `success` conclusion, so a failed `floppy-attestation` publishes nothing, and P06's "Re-run failed jobs" path retries it.
- **AC-6 waits for a tag**, which the owner pushes; until then the node's other criteria stand on their tests.
