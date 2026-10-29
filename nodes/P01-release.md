# P01 — release

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | P02 | M01, P03, X01 | MS2 | L |

**Owns:** `.github/workflows/release.yml`, the attestation and publish jobs of the tag pipeline (after P02's gate), `scripts/rc1-diff.sh`, `scripts/size-report.sh`, `docs/rc1-diff-reasons.tsv`, `docs/releasing.md`, `scripts/tests/release-*.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `.github/workflows/release.yml` (278 lines), `docs/releasing.md`. Removed: `scripts/generate-provenance.py` and its call in `scripts/attestation.sh`.
**Study refs:** T-attest-entry-workflow, T-prerelease-never-latest, D-supply-chain-honesty, D-tag-builds-from-source; Principle 7; OD-8, OD-16.

## Purpose
After this node, a tag whose ISO has passed P02's reproducibility gate, every boot mode, the artifact checks and the gates is attested by the platform, has its inputs archived and becomes a GitHub prerelease with reports attached. Nothing runs here for a tag that failed any of those. This completes MS2.

## Standard mechanism
- Provenance: `actions/attest-build-provenance` with the ISO as subject, and `actions/attest-sbom` for the CycloneDX SBOM. `gh attestation verify` checks them. Benefit over the ported `generate-provenance.py` plus `actions/attest@v2` (`build.yml:768-778`): the platform writes the predicate, not our 291-line script.
- Release: `gh release create`. Archive: `oras push` of P02's distfiles artifact to `${REGISTRY}/distfiles:<version>`.
- SBOM comparison was considered with `cyclonedx diff`. It lists differences but cannot require a reason per package. A 30-line shell script over `jq` and `comm` plus a reasons file does, so that stays custom.
- Size gate: `stat`. No standard tool needed.

## Changes from the port
Carried unchanged: the `workflow_run` trigger on `Build`, the tag-to-commit check (`release.yml:77-114`), the previous-tag changelog, the prerelease rule (`release.yml:242-271`: `--prerelease --latest=false` for any hyphenated tag).

1. **S3 replaced by artifacts.** The release job downloads the ISO, SBOM, `SHA256SUMS`, `release-inputs.json`, the distfiles archive and the reports from the tag pipeline run with `download-artifact` (`run-id`, `github-token`) instead of `aws s3 cp` (`release.yml:123-134`). The S3 upload of SHA256SUMS and the dashboard link in the notes (`:230`) go (I01 owns the global removal). *AC-1.*
2. **Provenance by the platform.** In `build.yml`'s attestation job, replace `generate-provenance.py`, the "Read SLSA predicate" step and `actions/attest@v2` with `actions/attest-build-provenance` (subject: the ISO) and `actions/attest-sbom` (subject: the ISO, SBOM: `bom.cdx.json`). Remove the provenance pillar from `attestation.sh`. S01 must not touch that part. Signing stays in `build.yml` because the certificate binds to the entry workflow (`build.yml:1-17`). *AC-2.*
3. **Digest chain checks the attestation.** The predecessor compared the ISO only with `attestation-summary.json` and the SBOM (`release.yml:136-164`) and generated `SHA256SUMS` at publish time (`:166-170`), from the file it was checking. Now `SHA256SUMS` is written once in the attestation job, before signing. The publish job requires `sha256(ISO) == SHA256SUMS == SBOM metadata.component hash == subject digest` taken from `gh attestation verify --format json`. *AC-3.*
4. **Publish only after everything passed.** The attestation job `needs` P02's `compare` job, the boot tests, the artifact checks and the gates (P02-AC-3), and the `workflow_run` condition stays `conclusion == success`. The predecessor uploaded "latest" copies before the boot tests ran (`build.yml:495-546` vs `:559`). With S3 gone there are no pointers, and nothing is written to a public place before the signing step. *AC-4.*
5. **The distfiles archive is pushed after the gate.** P02's `fetch` job made the archive and recorded its digest in `release-inputs.json`; both builds consumed it. P01 pushes the same bytes as `${REGISTRY}/distfiles:<version>` and fails if the pushed layer digest differs from the recorded one. The predecessor kept distfiles in a throwaway Docker volume. *AC-5.*
6. **New release assets.** `release-inputs.json` (written by P02); `source-audit.tsv` (B01, from build A); `rc1-diff.md`; `sizes.md`; `dynamic-allowlist.txt`. All are listed in `SHA256SUMS`. *AC-6, AC-7, AC-8.*
7. **Reports.**
   - `rc1-diff.sh` compares package name and version sets of the new `bom.cdx.json` and rc1's (fetched by sha256 `3cfc322a…75887`). The rc1 SBOM has no file components (`enrich-sbom.py:582`), so the file diff compares `unsquashfs -lls` path lists of the two ISOs' squashfs. Every added or removed package must have a line in `docs/rc1-diff-reasons.tsv`; a missing line fails the script, an unused line is reported. The owner reviews that file in the PR.
   - `size-report.sh` prints ISO, squashfs, kernel and initrd sizes against `ISO_BUDGET_BYTES` (Makefile variable, default 681,984,000, OD-16) and exits 1 if the ISO exceeds it. It runs on every build, before signing.
   - The allowlist report copies O02's dynamic-binary allowlist with its entry count.
8. **Release notes** drop the S3 dashboard link and print `gh attestation verify … --repo "$GITHUB_REPOSITORY" --signer-workflow …/build.yml` instead of `--owner tuckermclean` (`release.yml:216`). The `--owner` form accepts an attestation from any repository of the owner.
9. **Permissions.** `release.yml`: `contents: write`, `actions: read`. `build.yml` attestation job: `id-token: write`, `attestations: write`, `contents: read`, `packages: read`. The distfiles push needs `packages: write` in the build job only, on tags. *AC-9.*

## Gate
- **P01-AC-1** — `release.yml` has no `aws`, `s3` or `S3_BUCKET` text and gets its files from the Build run's artifacts. *Verify:* `scripts/tests/release-workflow.test.sh`. *Tier:* fast.
- **P01-AC-2** — `build.yml` uses `actions/attest-build-provenance` and `actions/attest-sbom` (SHA-pinned) and neither `actions/attest@` nor `generate-provenance.py`; `gh attestation verify <iso> --repo … --signer-workflow …` passes on the rc1 build's ISO. *Verify:* `scripts/tests/release-workflow.test.sh` (grep); the rc1 tag run. *Tier:* fast + slow.
- **P01-AC-3** — The publish job exits 1, without creating a release, when any of ISO hash, `SHA256SUMS` entry, SBOM component hash or attestation subject digest differs. *Verify:* `scripts/tests/release-digest-chain.test.sh` with a stubbed `gh` and four mutated fixtures. *Tier:* fast.
- **P01-AC-4** — In a tag run, the attestation, release and `oras push` steps all run after P02's `compare`, the boot-test, artifact-check and gate steps succeed; a red boot mode, or a `compare` mismatch, on a test tag publishes nothing. *Verify:* `scripts/tests/release-workflow.test.sh` (`needs:`); a throwaway `-test` tag with one failing mode, recorded in the PR. *Tier:* fast + slow.
- **P01-AC-5** — After the `v0.2.0-rc1` run, `oras manifest fetch ${REGISTRY}/distfiles:0.2.0-rc1` succeeds and its layer digest equals the distfiles digest in `release-inputs.json`. *Verify:* the release job, `oras manifest fetch --descriptor`. *Tier:* slow.
- **P01-AC-6** — The published ISO's SHA-256 equals both digests in P02's `compare` log and the attestation subject. *Verify:* `scripts/tests/release-digest-chain.test.sh` (fixture with a third, differing digest fails); the `v0.2.0-rc1` run. *Tier:* fast + slow.
- **P01-AC-7** — `rc1-diff.sh` fails on a package that is added or removed without a reason line and passes with one. *Verify:* `scripts/tests/rc1-diff.test.sh` with two small fixture SBOMs. *Tier:* fast.
- **P01-AC-8** — `size-report.sh` exits 1 for an ISO of 681,984,001 bytes and 0 for 681,984,000 with the default budget. *Verify:* `scripts/tests/size-report.test.sh`. *Tier:* fast.
- **P01-AC-9** — A `-rcN` tag creates a prerelease that is not Latest. The workflow `permissions:` match item 9. *Verify:* `gh release view v0.2.0-rc1 --json isPrerelease`; `scripts/tests/release-workflow.test.sh`. *Tier:* fast + slow.
- **P01-AC-10** — The release assets carry the SBOM, ISO, `SHA256SUMS`, `release-inputs.json`, `source-audit.tsv` and three reports. *Verify:* the `v0.2.0-rc1` run log and `gh release view --json assets`. *Tier:* slow.

Measured on the predecessor: attestation job about 4.7 minutes. The from-source builds are P02's.

## Risks
- `actions/attest-build-provenance` and `attest-sbom` behaviour on a user-owned repository, and that `gh attestation verify --format json` exposes the subject digest in the shape item 3 reads (unverified; the first slice checks).
- The rc1 SBOM can be fetched only by sha256 (O01's lane). Reasons for each package difference need the owner; expect the first list to be near empty with rc1's tree (OD-6).
- OD-8 (first version), OD-16 (budget share). The `workflow_run` workflow runs the default-branch copy of `release.yml`, not the tag's (unverified in this repository).
