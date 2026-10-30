# S01 — sbom-and-gates

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | F01 | B01, B03, P03 | — | M |

**Owns:** `scripts/attestation.sh`, `scripts/enrich-sbom.py`, `scripts/check-licenses.py`, `scripts/check-cves.sh`, `scripts/check-unowned.py`, `scripts/run-cve-canary.sh`, `scripts/fixtures/canary-sbom.cdx.json`, `configs/attestation/*` (all policies, allowlists, schemas), `configs/attestation/rc1-sbom-diff.txt`, `.github/workflows/sbom-gates-rc1.yml`, the `test-gates` Make target (part of `make test`), `scripts/tests/check-unowned.test.sh`, `scripts/tests/check-cves-waivers.test.sh`, `scripts/tests/attestation-static.test.sh`. B01 adds `check-unowned.py`'s `--provenance` mode and the allowlist's `source` fields on top; the ported default mode stays S01's.
**Ports from linux-live-iso-factory@b9f533b:** every file above, unchanged except as listed. Not ported: `scripts/generate-provenance.py` (P01 uses `actions/attest-build-provenance`) and `scripts/generate-dashboard.py` (out of scope).
**Study refs:** supplychain.yaml (pillars 1–5, `script.check-unowned`, `script.check-cves`), D-supply-chain-honesty, D-hand-authored-rootfs-files-owned, D-state-and-no-hidden-stderr, T-unowned-allowlist; contradictions: unowned pillar skipped when `sbom.syft.json` is absent, CVE waiver `expires` never compared, DB age only warned; OD-5, OD-9.

## Purpose
After this node a rootfs becomes one enriched CycloneDX SBOM and passes or fails three gates (licence, CVE, unowned) with the predecessor's logic. It is developed on rc1's rootfs first, and must regenerate rc1's `bom.cdx.json` (sha256 `3cfc322a0e105638452baa6900552769a6ad5bfbf3be190a9808ac98ca575887`) up to listed fields. Three verified fail-open paths are closed.

## Standard mechanism
syft with its Portage VDB cataloger makes the package list; grype with its DB makes the matches; Portage `ACCEPT_LICENSE` was considered for licences but rc1's release path uses the ported checker, and tightening it is a later change (SPEC §5). `jq` normalises and compares SBOMs for the rc1 reproduction. No new code is written. Custom code that remains is the ported `enrich-sbom.py` (syft lacks CPEs for many Gentoo packages and records host paths), `check-licenses.py`, `check-cves.sh` (waiver and fix-state policy) and `check-unowned.py`, all already in rc1's release path.

**Ordering.** `enrich-sbom.py` reads `license-policy.yaml` (Gentoo-to-SPDX map, `--license-policy` at `enrich-sbom.py:1115`) and `spdx-license-ids.txt` (`:213-218`). S01 owns both the scripts and the policy, and carries the policy unchanged, so nothing depends on another node and rc1 reproduces.

## Tests
- **Ported first:** the predecessor's CVE-gate canary, `scripts/run-cve-canary.sh` with `scripts/fixtures/canary-sbom.cdx.json` and `.github/workflows/cve-gate-canary.yml`, before the gate scripts it exercises.
- **Added:** `attestation-static.test.sh`, `check-cves-waivers.test.sh`, `check-unowned.test.sh`.
- **Baseline:** on `b9f533b`'s gate scripts the canary passes, and the criteria of the numbered changes fail (the unowned gate passes on missing input; waivers never expire), as expected. Reproducing rc1's SBOM on rc1's rootfs is the baseline of the SBOM.

## Changes from the port
1. **Provenance pillar removed.** Delete `PROVENANCE_*`, the `generate-provenance.py` call and its summary field from `attestation.sh` (`:57,179-181,231,674-694,702,711,775,824`). The ISO sha256 computation stays: the SBOM records it. Reason: P01 replaces the script. Proved by AC-5.
2. **S3 distribution URL:** `attestation.sh:196-204` builds an `s3://` URL, and `enrich-sbom.py:515-531,1154-1170` carries it into the SBOM. Both are left out as S01 ports the files (I01's check holds the rule); the GitHub release URL logic at `:206` onward stays. The SBOM difference is listed under `deliberate` in `rc1-sbom-diff.txt`. Proved by AC-7.
3. **Unowned gate fails closed.** Three paths pass today: `sbom.syft.json` missing skips the pillar with a warning and leaves `UNOWNED_RC=0` (`attestation.sh:462-473`; the warning is `:472`); empty `files[]` warns and passes (`check-unowned.py:246-250`); a missing allowlist warns and continues empty (`:209-215`, and `[[ -f ]] &&` at `attestation.sh:469`). Each becomes a non-zero exit, and a sysroot with no owned paths (no `var/db/pkg`) also fails. Proved by AC-1, AC-2.
4. **CVE waiver expiry is enforced.** `waiver_for` (`check-cves.sh:256-264`) never reads `expires`, although the policy requires it (`cve-policy.yaml:90`). A waiver with no parseable `expires`, or one on or before today (UTC), does not waive: the finding gates and is listed under `expired_waivers` in the coverage report. Proved by AC-3.
5. **Grype DB build time is required.** The coverage report already records `db.built` (`check-cves.sh:271,362`) and the summary carries it. When `grype db status` yields no parseable `Built` the script now exits non-zero instead of printing a warning (`:298-303`), so P01 can write the value to `release-inputs.json`. A stale DB stays a warning (see Risks). Proved by AC-4.
6. **Builder scan is report-only (OD-5).** `BUILDER_SBOM_RC` and `BUILDER_CVE_RC` no longer set `OVERALL_STATUS` to fail (`attestation.sh:716-717`); the builder findings stay in the summary. The builder digest is passed by B03 (`--builder-digest`; `make attestation` omits it today, `Makefile:452-458`), and `attestation.sh` records it instead of a stage3 digest derived from `BUILD_EPOCH` (`attestation.sh:316,687`; I03's test rejects `STAGE3_DIGEST`). Proved by AC-5.
7. **OD-9.** Waivers for rc1's 2026-08 tree are `allowlist` entries in `cve-policy.yaml` with `approved_by` and a 30-day `expires`, added by the owner after the rc1 run lists the findings. No code.
8. **rc1 lane.** `sbom-gates-rc1.yml` runs `attestation.sh` in the adopted rc1 builder image on rc1's extracted squashfs, with the rc1 ISO for the hash, then compares the SBOM with rc1's. `rc1-sbom-diff.txt` lists `volatile` jq paths (`serialNumber`, `metadata.timestamp`, `metadata.tools`) and `deliberate` ones. Proved by AC-6, AC-7.
9. **`make test-gates`.** Part of `make test`: `attestation.sh` and the licence, CVE and unowned gates in the builder image, on the rootfs of `ISO` (rc1's behind its sha256 until B03 builds one, as for `test-boot`). `sbom-gates-rc1.yml` and B03's `build.yml` call this target for the gates. *AC-8.*

## Gate
- **S01-AC-1** — `check-unowned.py` exits non-zero for: a missing Syft JSON, an empty `files[]`, a missing allowlist file, and a sysroot with no owned paths. A fixture with one unowned file also exits non-zero; a fixture with all files owned exits 0. *Verify:* `bash scripts/tests/check-unowned.test.sh`.
- **S01-AC-2** — `attestation.sh` no longer skips Pillar 4: the skip warning is gone, the missing-JSON branch sets `UNOWNED_RC` non-zero, and the allowlist is always passed. *Verify:* `bash scripts/tests/attestation-static.test.sh` (a source check; the behaviour is exercised end to end by AC-6).
- **S01-AC-3** — With a stub `grype` returning two Critical matches, `check-cves.sh` treats a waiver dated in the future as waived, a waiver dated in the past as not waived (finding gates, listed in `expired_waivers`), and a waiver with no `expires` as not waived. *Verify:* `bash scripts/tests/check-cves-waivers.test.sh`.
- **S01-AC-4** — With a stub `grype db status` printing a `Built:` line, the coverage report's `db.built` equals it; with no `Built:` line the script exits non-zero. *Verify:* `bash scripts/tests/check-cves-waivers.test.sh`.
- **S01-AC-5** — `attestation.sh` has no `PROVENANCE` or `generate-provenance` text, `generate-provenance.py` is absent from the repository, and a failing builder scan does not set `OVERALL_STATUS`. *Verify:* `bash scripts/tests/attestation-static.test.sh`.
- **S01-AC-6** — On rc1's rootfs in the rc1 builder image, `attestation.sh` runs to completion and writes `bom.cdx.json`; the licence and unowned gates exit 0 (unowned with the ported allowlist, and any file it newly reports added with a reason); the CVE gate runs, writes a coverage report with non-null `db.built`, and its gating findings are posted in the job summary for OD-9. *Verify:* `sbom-gates-rc1.yml` dispatch.
- **S01-AC-7** — After removing the `volatile` paths from both, `jq -S` of the regenerated `bom.cdx.json` and of rc1's differs only in paths listed under `deliberate`. *Verify:* `sbom-gates-rc1.yml` (final step, `diff` of the two normalised files).
- **S01-AC-8** — `make test` depends on `test-gates`, and `sbom-gates-rc1.yml` runs the gates only through `make` targets, with no `apt-get`, `pip` or `setup-*` step. *Verify:* `scripts/tests/attestation-static.test.sh` (`make -n` and a grep of the workflow).

## Risks
- Whether rc1's SBOM came from exactly `b9f533b`'s `enrich-sbom.py` is unverified. If not, AC-7's `deliberate` list absorbs the differences and each gets a reason.
- Unowned and propagation steps need `var/db/pkg` in the extracted squashfs and a host VDB with musl, grub and syslinux; the adopted rc1 builder is that host (unverified).
- `grype db status` text format (`Built:`) is parsed as the ported code does; the pinned grype may print it differently (unverified). Prefer `-o json` only if the text parse fails on the first run.
- A stale DB still only warns (`check-cves.sh:290-296`). Not changed: no demonstrated failure yet, and the DB time is now recorded.
- A missing CVE policy still falls back to the built-in default (`:112-118`). The default is stricter, so it is left alone.
- Multi-entry `licenses[]` is joined as AND (`check-licenses.py:172-197`); this may over-fail dual-licensed packages (unverified). The rc1 run shows it.
- OD-5, OD-9 decide what the owner waives; the mechanism here only makes expiry real.
