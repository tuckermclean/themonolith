# X01 — cutover

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | P01, R03, M01, P03, G01 | none | MS3 | S |

**Owns:** `README.md` (verification section), `docs/releasing.md` (cutover steps), `scripts/tests/readme-verify.test.sh`. The pointer commit in the predecessor is the owner's.
**Ports from linux-live-iso-factory@b9f533b:** README "Verify a release" section as text to rewrite; `docs/releasing.md`.
**Study refs:** T-attest-entry-workflow, T-prerelease-never-latest, D-all-static, D-supply-chain-honesty; OD-2, OD-8; `release.yml:216` (`--owner tuckermclean` in the old release notes).

## Purpose
After this node the first non-prerelease has shipped from this repository with an empty dynamic-binary allowlist. The README tells a reader how to verify releases from both repositories. The predecessor carries a pointer and is archived under its own name.

## Standard mechanism
`gh attestation verify` with `--repo` and `--signer-workflow`; `gh release`; `gh repo archive`. Custom code: none beyond one grep test of the README.

## Changes from the port
This node is a release plus documentation. There is no ported code to change.

1. **Preconditions** (each already proven by its own node, not re-tested here): R03's allowlist is empty (the O02 report shows 0 entries); M01's bump is merged and the tag's `TREE_COMMIT` differs from rc1's; P03's feed answers at the OD-1 URL; G01 is done; the CVE gate passes with no expired waiver.
2. **The release.** The owner pushes the final tag, `v0.2.0` per OD-8's sequence (confirm the number). It goes through the whole tag pipeline (P02's reproducibility gate, then P01), not a promotion of `-rc1`. The release is not a prerelease and is Latest, because the tag has no suffix.
3. **README verification section.** Two blocks:
   - for this repository: `gh attestation verify themonolith-<ver>.iso --repo tuckermclean/themonolith --signer-workflow tuckermclean/themonolith/.github/workflows/build.yml`;
   - for rc1: the same with `--repo tuckermclean/linux-live-iso-factory` and its `build.yml`.
   Both are preceded by `sha256sum -c SHA256SUMS`. `--owner` alone is not used; it accepts any repository of the owner (`release.yml:216` did). The README also links P01's rc1 diff report. Whether rc1's attestation still verifies after the account moved off S3 is unverified: the attestation lives on GitHub, not S3. *AC-1, AC-2.*
4. **Predecessor.** In order: verify rc1 (baseline); one docs commit to the predecessor's default branch with a README banner pointing here; edit the `v0.1.0-rc1` release notes to point here (assets untouched); disable workflows and remove the AWS secrets; set the repository description; `gh repo archive`; verify rc1 again. The repository is never renamed, transferred or deleted, because rc1's attestation names it. If verification fails after archiving, `gh repo unarchive` and record why. *AC-3, AC-4.*

## Gate
- **X01-AC-1** — Every `gh attestation verify` in `README.md` has `--repo` and `--signer-workflow`, none uses `--owner` alone, and commands for both repositories are present. *Verify:* `scripts/tests/readme-verify.test.sh`. *Tier:* fast.
- **X01-AC-2** — Following the README, the rc1 ISO verifies against `tuckermclean/linux-live-iso-factory` before the archive step, and again after it. *Verify:* run the README commands on a clean machine; record both outputs in the PR. *Tier:* slow.
- **X01-AC-3** — The first non-prerelease release exists in this repository: `isPrerelease` is false, it is Latest, its ISO verifies with the README command, and its `release-inputs.json` shows a `TREE_COMMIT` different from rc1's. *Verify:* `gh release view v0.2.0 --json isPrerelease,assets`, `gh api repos/tuckermclean/themonolith/releases/latest --jq .tag_name`. *Tier:* slow.
- **X01-AC-4** — The release's allowlist report has 0 entries and the gate verdict in the Build run is green. *Verify:* the release asset `dynamic-allowlist.txt` and the Build run URL. *Tier:* slow.
- **X01-AC-5** — The predecessor is archived under its original name, its `v0.1.0-rc1` release keeps its assets, and its default branch has the pointer commit. *Verify:* `gh api repos/tuckermclean/linux-live-iso-factory --jq '[.full_name,.archived]'`, `gh release view v0.1.0-rc1 --repo tuckermclean/linux-live-iso-factory --json assets`. *Tier:* slow.

## Risks
- Does archiving keep `gh attestation verify` working? Expected yes; unverified. The runbook verifies before and after and can unarchive.
- Is the rc1 ISO still downloadable? Its assets are on GitHub (`release.yml:265-271` per v0.3, unchecked here).
- The rc1 disc's advisory URL is baked in and cannot change; v0.3 records it as an S3 address (`monolith-advisory-check:17,29`, unchecked here). The README should say plainly that rc1's advisory check no longer works. That text is the owner's decision.
- OD-2 (allowlist), OD-8 (version number), OD-1 (advisory host), OD-12 (Hyper-V claim, via G01).
- Pushing the tag, deleting secrets and archiving need the owner's credentials.
