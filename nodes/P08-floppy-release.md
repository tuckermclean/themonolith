# P08 — floppy-release

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | B06, P01, P02 | none | — | M |

**Owns:** the floppy step of the `attestation` job of `.github/workflows/build.yml`'s tag path and the floppy image as a second `subject-path` of its provenance attestation (P01 owns the job), the floppy asset in `scripts/release-sums.sh`, `scripts/release-digest-chain.sh` and `scripts/release-create.sh` (P01 owns the scripts; P06 and P07 own their parts of `release-create.sh`), the Make target that extracts the floppy (change 1), the floppy lines of `docs/releasing.md`, `scripts/tests/floppy-release.test.sh`, `scripts/fixtures/P08/`, the P08 row of `docs/capabilities.md`.
**Resolves:** #130
**Ports from linux-live-iso-factory@b9f533b:** none. P01 wrote the release path; this node adds one asset to it.
**Study refs:** D-supply-chain-honesty, P01 (the digest chain, SHA256SUMS, the attestation subject), P02 (two offline builds, equal ISO digests), B06 (`/boot/floppy.img`), T-attest-entry-workflow; the owner's answer on issue #130 (2026-11-27): the floppy is a release asset of its own and is on the CD, and the ISO stays the definitive artifact.

## Purpose
B06 puts the boot floppy on the CD as `/boot/floppy.img`. The owner also wants it published on its own, for someone who has a 486 and no way to boot a CD, while the ISO stays the definitive artifact that carries everything. After this node every release has a `themonolith-<version>-floppy.img` asset, byte for byte the `/boot/floppy.img` of the ISO that passed P02's gate, so the gate's equal ISO digests cover it too. It is listed in SHA256SUMS, it is a subject of the provenance attestation beside the ISO, and the publish step's digest chain checks it.

## Standard mechanism
- `xorriso -osirrox on -indev <iso> -extract /boot/floppy.img <file>` takes the asset from the gated ISO; nothing rebuilds it.
- `actions/attest-build-provenance` takes several `subject-path` lines; `gh attestation verify` checks each file.
- SHA256SUMS, the digest chain and the release upload are P01's scripts, each extended by one file.
- Custom code: none new.

## Tests
- **Ported first:** none.
- **Frozen tests:** P01's `scripts/tests/release-*.test.sh` and P06's and P07's tests check the release files. If one asserts the exact asset list (`release-sums.sh` counts nine files), the node stops and asks the owner before changing it, naming the lines, as M04 did. Otherwise they pass unchanged.
- **Added:** `scripts/tests/floppy-release.test.sh`, offline in the toolbox, with fixtures in `scripts/fixtures/P08/`: the extraction from a fixture ISO (AC-1), `release-sums.sh` on a release directory with and without the floppy (AC-2), the workflow's subjects (AC-3), and `release-digest-chain.sh` with a stub `gh` on a floppy that differs from the ISO's copy, from its SHA256SUMS line and from its attestation subject, each failing (AC-4).
- **Baseline:** on `main` the release has no floppy asset, so AC-1 to AC-4 fail.

## Changes from the port
1. **The asset.** After P02's gate, the `attestation` job extracts `/boot/floppy.img` from the gated ISO into `output/release/themonolith-<version>-floppy.img`, through a Make target. It fails when the ISO has no `/boot/floppy.img`. *AC-1.*
2. **SHA256SUMS.** `release-sums.sh` lists the floppy beside the ISO and fails when it is missing. *AC-2.*
3. **The attestation.** The provenance attestation has two subjects, the ISO and the floppy image. *AC-3.*
4. **The digest chain.** `release-digest-chain.sh` also checks that the floppy's sha256 equals that of the ISO's `/boot/floppy.img`, its SHA256SUMS entry and its attestation subject (`gh attestation verify`). `release-create.sh` uploads it with the other assets. *AC-4.*
5. **Docs.** `docs/releasing.md` lists the asset and how to verify it (`sha256sum -c SHA256SUMS`, `gh attestation verify themonolith-<version>-floppy.img`). `docs/capabilities.md` gains a P08 row. *AC-5.*

## Gate
- **P08-AC-1** — The tag path's `attestation` job writes `themonolith-<version>-floppy.img`, extracted from the gated ISO and byte for byte its `/boot/floppy.img`, and fails on an ISO with no `/boot/floppy.img`. No job builds the floppy for the release. *Verify:* `scripts/tests/floppy-release.test.sh` (a fixture ISO with and without the file; the workflow and Make target read).
- **P08-AC-2** — `release-sums.sh` writes a SHA256SUMS that lists the floppy and fails when the floppy is missing from the release directory. *Verify:* `scripts/tests/floppy-release.test.sh`.
- **P08-AC-3** — The provenance attestation step has the ISO and the floppy as its subjects. *Verify:* `scripts/tests/floppy-release.test.sh` (the step's `subject-path` lines); the tag run of AC-6.
- **P08-AC-4** — With a stub `gh`, `release-digest-chain.sh` passes on a release whose floppy equals the ISO's `/boot/floppy.img`, its SHA256SUMS entry and its attestation subject, and fails, naming the floppy, when it differs from any one of them. `release-create.sh` uploads the floppy. *Verify:* `scripts/tests/floppy-release.test.sh` with `scripts/fixtures/P08/`.
- **P08-AC-5** — `docs/releasing.md` lists the floppy asset and its two verify commands. P01's, P06's and P07's release tests pass. *Verify:* `scripts/tests/floppy-release.test.sh` (the doc lines); `make test-unit`.
- **P08-AC-6** — The first tag after the merge publishes a release with the floppy asset; its sha256 equals the released ISO's `/boot/floppy.img` and its SHA256SUMS line, and `gh attestation verify` passes for it. *Verify:* the tag's Build and Release run URLs and the release URL, in a comment on the node PR.

## Risks
- **Release path.** `build.yml`'s tag path and `release.yml` are high-stakes (SPEC §8): the node PR says what changes in them, and nothing publishes earlier than before (the floppy step runs after P02's gate, inside the attestation job).
- **Workflow push.** The change touches `.github/workflows/build.yml`, which needs a token with the `workflow` scope to push (T-workflow-push-needs-pat).
- **AC-6 waits for a tag**, which the owner pushes; until then the node's other criteria stand on their tests.
