# S05 — provenance-and-attestation

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| S | B06, S02, S03, S04, O02, O03, O04, O05, O06 | P02 | — (feeds MS2) | L |

**Owns:**
- `supplychain/attest.py` (orchestrator).
- `supplychain/provenance.py`.
- `supplychain/digest_chain.py` (subcommands `verify`, `sums`).
- `supplychain/policy/pillars.yaml` (protected path).
- `supplychain/schema/attestation-summary.schema.json`.
- The `attest` job in `.github/workflows/build.yml`. B06 owns the file; S05 owns this job's content and nothing else in it.
- The `make attest` target.
- `docs/attestation.md` (how a user verifies an ISO).
- `tests/fast/test_digest_chain*.py`, `test_attest_*.py`, `test_provenance*.py`, `test_workflow_attest*.py`.
- `tests/fixtures/supplychain/chain/` (a good fixture set and mutation helpers).

**Carries from linux-live-iso-factory@b9f533b:**
- `scripts/attestation.sh` (880 lines: orchestration, summary, pillar 6) -> `attest.py`. The pillar commands it runs are already ported by S01 to S04; what moves is the sequencing, the summary and the exit logic. Rewritten rather than ported because AC-5 needs per-pillar stub injection and AC-7 needs a summary built by `json.dump` (the shell heredoc at `attestation.sh:744-801` is the verified weakness).
- `scripts/generate-provenance.py` (291 lines), **ported** as `provenance.py`. Changed only where AC-8 and AC-9 force it: the `unknown/unknown` defaults (`:88-105`), the hard-coded workflow path (`:108`) and the snapshot download.
- The `attestation` job of `.github/workflows/build.yml` (~L575-822), the signing step in particular.
- The digest check of `.github/workflows/release.yml:136-164` -> `digest_chain.py`.
- `Makefile` `attestation`, `attest-builder` (440-480).

**Study refs:**
- Invariants: INV-DIGEST-1..4, INV-PILLAR-ALL, INV-PROV-1, INV-REL-2 (SHA256SUMS).
- Traps: T-attest-entry-workflow, T-syft-quirks (SLSA `buildType`), T-schema-validation-hang (via S01).
- Doctrine D-supply-chain-honesty; decision DEC-fail-closed-attestation.
- Principles 5 and 7.
- Verified weaknesses: no tests for any attestation script; the release step does not re-check the SLSA subject digest; `builder.image_digest` is likely empty in CI; provenance fetches the snapshot from the network to hash it; the summary is written after provenance but listed as a provenance byproduct.
- Components: `script.attestation`, `script.generate-provenance`, `job.build.attestation`, `data_contract` `attestation-summary.json`, `slsa-provenance.json`, `SHA256SUMS`.

## Purpose

After this node, the ISO leaves the build with one verifiable chain: the hash of the ISO bytes is the hash in the summary, the SBOM, the provenance and the signed Sigstore attestation, and a standalone script proves it mechanically. That script runs at attest time to decide whether to sign, and again at release (P02) on the downloaded files. All pillars always run and all artifacts are always written, but nothing is signed unless every gating pillar passed.

The chain checker is developed in the rc1 lane (SPEC §7), against rc1's own ISO, SBOM and `SHA256SUMS` (digests in `oracle/fixtures/rc1.yaml`, fetched by O01), before this repo builds anything. rc1's attestation is bound to the predecessor repository name (`tuckermclean/linux-live-iso-factory`), so it can exercise the checker and the `gh attestation verify` output parser, but it can never stand in for an attestation of our own ISO. The first attestation of our own build is the `v0.2.0-rc1` tag, which is MS2 (S05-AC-16).

## Scope

**In:**
- The orchestrator and the single list of pillars.
- The summary file and its schema.
- SLSA provenance generation (offline, from pins).
- The digest-chain script (`verify`, `sums`).
- The `attest` job: order, permissions, signing condition, post-sign verification.
- The cross-index of every study invariant and contradiction for the supply-chain area (below).

**Out:**
- The SBOM, gates and their reports: S01, S02, S03, S04. S05 calls them.
- Release workflow, GitHub Release creation, prerelease/Latest policy, `workflow_run` plumbing: P02. P02 must call `digest_chain.py`.
- Dashboard, `builds-index.json`, "latest" pointers, rendering failed builds: P03.
- Nightly re-scan and `status/<tag>.json`: P05.
- Pin file and `versions.lock` creation: I05, R02.
- Boot-test jobs and the `oracle-gate` aggregator job: O02 and B06.
- ISO assembly and its artifact hand-over: B05, B06.
- Reproducibility of the ISO: B07.
- Fetching rc1's ISO, SBOM and `SHA256SUMS` by digest: O01. Memo and cache handling of the ISO and the release-mode audit after the build: I06 and B06; the attest job only sees the ISO bytes it is given.

## Design

### Order inside the attest job

```
checkout -> restore ISO + squashfs -> unsquashfs -> grype_db.py fetch
 -> make attest  (attest.py, in the builder image)
      1  sha256(ISO) once                       -> iso_sha256
      2  S01 generate (target)  + validate      -> pillar sbom
      3  S02 license gate                       -> pillar license
      4  S03 canary, then CVE gate (target)     -> pillar cve
      5  S04 unowned gate                       -> pillar unowned
      6  S01 generate (builder) + S03 report    -> pillars builder_sbom, builder_cve
      7  provenance.py                          -> pillar provenance
      8  summary draft; digest_chain verify     -> pillar digest_chain
      9  final summary; exit 1 iff a gating pillar is not "pass"
 -> upload artifacts (if: always())
 -> actions/attest   (if: attest.outputs.overall == 'pass' and push event)
 -> gh attestation verify + digest_chain verify --attested
```

**Decision:** `continue-on-error: true` plus a later "read verdict" step (`build.yml` ~663-668, 673-693, 820-830) is replaced by plain step ordering: `attest.py` exits 1 on a gating failure, an `if: always()` upload step runs next, and the signing step is skipped by the default `success()` condition and by an explicit `overall == 'pass'` check. Rejected: keep `continue-on-error`; it forces three extra steps to re-derive what the exit code already says.

Only step 1 hashes the ISO bytes. S01 and `provenance.py` receive `--iso-sha256`. `digest_chain.py` re-hashes independently in step 8 and at release. This is INV-DIGEST-1, kept as "computed once, verified independently", with a static test.

The pillars run in the order above. If an earlier pillar produced no input for a later one (for example SBOM generation failed), the dependent pillars record `error` with reason `no-input`; they are not skipped silently. Independent pillars (unowned, builder) still run. "Every red light visible at once" (INV-PILLAR-ALL) is kept.

### Pillars (`supplychain/policy/pillars.yaml`)

The single declared list. The orchestrator, the summary schema and the tests all read it. Rc1 documented five pillars and ran six, and called the whole thing "three-pillar" in the Makefile (`attestation.sh:3-9`, `Makefile:447`). The file replaces those comments.

```yaml
schema: 1
pillars:
  sbom:         {gating: true,  summary_key: sbom_check}
  license:      {gating: true,  summary_key: license_check}
  cve:          {gating: true,  summary_key: cve_check}
  unowned:      {gating: true,  summary_key: unowned_check}
  provenance:   {gating: true,  summary_key: provenance_check}
  digest_chain: {gating: true,  summary_key: digest_chain_check}
  builder_sbom: {gating: true,  summary_key: builder.sbom_check}
  builder_cve:  {gating: false, summary_key: builder.cve_check,
                 reason: "Builder is not shipped; findings are fixed by a builder bump (M02), not an ISO respin. See S03."}
```

Values: `pass`, `fail`, `error`, `not_run`. `overall = pass` iff every gating pillar is `pass`. A gating pillar with `fail`, `error`, `not_run` or **absent** fails overall. `not_run` is legal only for non-gating pillars. A non-gating pillar may be `fail` without failing overall; it may not be `error` or absent without failing overall (S03 decision).

### Summary (`attestation-summary.json`, schema `attestation-summary.schema.json`)

Written by `json.dump` from a dict and validated against the schema before writing. The old file was assembled by a Python heredoc with shell interpolation, so an empty variable or a quote could break it (`attestation.sh:744-801`).

Keys kept from v1, so rc1-era consumers (release, dashboard) keep working: `build_tag`, `timestamp`, `iso_sha256`, `package_count`, `unmapped_cpe_count`, `excluded_cpe_count`, `sbom_check`, `license_check`, `cve_check`, `unowned_check`, `provenance_check`, `overall`, `cve_scanner`, `cve_db`, `cve_policy`, `cve_coverage`, `unowned_count`, `cve_failures`, `license_failures`, `unowned_files`, `builder{…}`. The `cve_db.age_warning` key is kept and is null on any passing run.

Keys added: `schema_version: 2`, `digest_chain_check`, `iso_name`, `cve_waivers[]` (copied from S03's `waivers_applied[]`, so the release evidence names every waiver, OD-15), `cve_canary{found, cve, db_checksum}`, `reports{<file>: <sha256>}` for every report and the SBOM, `inputs{builder_image_digest, stage3_digest, snapshot_sha256, versions_lock_sha256, pins_sha256, source_sha}`, `policies{<file>: <sha256>}` for the four policy files and the allowlist, and `builder.cve_verdict` (the report-only verdict, which can be `fail` without failing `overall`).

Values `error` and `not_run` join `pass|fail` for the `*_check` keys; P03 must render them. `builds-index.json` is P03's.

### Provenance (`provenance.py`)

Inputs come from arguments and from the repository, with no network access:

```
provenance.py --iso-sha256 H --iso-name N --build-tag T --pins pins/pins.yaml
              --versions-lock pins/versions.lock --reports-dir D
              --build-started-on TS --build-finished-on TS
              --out D/slsa-provenance.json --predicate-out D/predicate.json [--ci]
```

- The statement is in-toto v1 with predicate `https://slsa.dev/provenance/v1`. `buildType` is exactly `https://actions.github.io/buildtypes/workflow/v1`, the only value GitHub's attestations API accepts (T-syft-quirks).
- `externalParameters.workflow.path` is parsed from `GITHUB_WORKFLOW_REF`, not hard-coded (it was hard-coded at `generate-provenance.py:108`). In `--ci` it must be `.github/workflows/build.yml`, which is the entry workflow.
- `resolvedDependencies`: git commit; `gentoo-stage3` with digest; `gentoo-portage-snapshot` with sha256; `linux-kernel-source` with sha512; `monolith-builder` with digest; `versions.lock` with sha256. **Snapshot and builder digests come from `pins/pins.yaml`** (I05, populated by I02/I03). The old code downloaded the whole snapshot tarball from the Gentoo mirror to hash it, and used the unmirrored URL (`attestation.sh:645-661`); that is gone. The provenance URI for the snapshot is the pinned identity, not a mirror URL.
- `byproducts`: the SBOMs, CVE reports, license and unowned reports that exist, each with sha256. **`attestation-summary.json` is removed from the list.** It is written after provenance (`attestation.sh:674-694` versus `:744`), so the old entry could only ever hash a stale file from an earlier run. The summary instead records `reports{}`, and the digest chain ties everything together.
- `--ci` (set when `GITHUB_ACTIONS=true`) makes every item above mandatory: a missing environment variable, pin, report or digest is exit 2. The old defaults of `unknown/unknown`, ref `refs/heads/master` and sha `unknown` (`generate-provenance.py:88-105`) are dropped. Without `--ci` the output carries `internalParameters.local: true` and `digest_chain.py` and `attest.py --ci` reject it.
- `started <= finished`, both RFC 3339 UTC. `--build-started-on` is required in `--ci`.
- **Decision:** keep the self-built predicate and sign it with `actions/attest`. Rejected: `actions/attest-build-provenance`; it generates GitHub's own predicate without our resolved dependencies, and rc1's custom predicate is the shape already verified green.
- `predicate.json` holds the predicate alone. The workflow passes it with `predicate-path`, not through a step output (`build.yml` ~751-763), which avoids output quoting and size limits. The action input name is to be confirmed against the pinned action version in the first run.

### Digest chain (`digest_chain.py`)

**Decision:** the chain check is a standalone script with no knowledge of CI, used at attest time and at release, and in the rc1 lane against rc1's artifacts. Every flag except `--iso` and `--sbom` is optional, so a partial artifact set (rc1 has no summary or SLSA statement of this shape) can be checked; absent means `skipped` in `--json`. P02 passes all of them. Rejected: inline shell in `release.yml` (rc1), which could not be tested and omitted the SLSA subject.

```
digest_chain.py verify --iso ISO --sbom bom.cdx.json [--summary S.json]
                       [--provenance slsa-provenance.json] [--sums SHA256SUMS]
                       [--attested attestation-verify.json] [--reports-dir D]
                       [--policy-dir supplychain/policy] [--json]
digest_chain.py sums   --iso ISO --sbom bom.cdx.json            > SHA256SUMS
```

Exit codes: 0 every check passed; 1 at least one check failed; 2 a needed input is missing, empty or unparseable. With `--json`, a list of `{check, ok, detail}`. Checks:

| # | Check |
|---|---|
| 1 | sha256 of the ISO file bytes equals `summary.iso_sha256` |
| 2 | equals the SBOM's `metadata.component.hashes` SHA-256 entry, found **by `alg`**, not by index, and every `distribution` externalReference hash in the SBOM |
| 3 | equals `provenance.subject[0].digest.sha256`, and `subject[0].name` equals the ISO file name |
| 4 | if `--attested` is given: equals the subject digest in the `gh attestation verify --format json` output, and the signer workflow is `.github/workflows/build.yml` |
| 5 | if `--sums` is given: its ISO line equals the ISO hash, its `bom.cdx.json` line equals the sha256 of the SBOM file |
| 6 | `summary.reports{}` hashes equal the files in `--reports-dir`; each gate report's `inputs.sbom_sha256` (S02, S03) equals sha256 of the SBOM |
| 7 | `summary.policies{}` hashes equal the files in `--policy-dir`; `summary.cve_policy.sha256` equals the sha256 of `cve-policy.yaml` |
| 8 | `summary.overall` equals the recomputation from `pillars.yaml` and the `*_check` values (excluding `digest_chain_check` itself, which is expected `pass`) |
| 9 | `summary.cve_canary.found` is true and `cve_canary.db_checksum` equals `summary.cve_db.checksum` |
| 10 | the provenance is not marked `local` and `summary.inputs.builder_image_digest` is a non-empty `sha256:` value equal to the provenance `monolith-builder` digest |

A check whose optional flag is absent is reported `skipped` in `--json`, and P02 must pass all of `--provenance`, `--sums`, `--attested`, `--reports-dir`, `--policy-dir`. The "skipped" status exists so callers can see the difference; it never counts as pass inside `verify` when a flag was given but the file is missing (that is exit 2).

`sums` writes two lines in fixed order, `<iso sha>  <iso name>` then `<bom sha>  bom.cdx.json`, in `sha256sum -c` format. P02 uses it instead of `sha256sum *.iso bom.cdx.json` (`release.yml:166-170`) so the generated and verified formats cannot drift.

### The `attest` job in `build.yml`

- **Entry workflow (T-attest-entry-workflow).** `build.yml` is triggered directly by `push` on `tags: ['v*.*.*']` and has no `workflow_call` trigger. Sigstore binds the certificate to the workflow that ran, and GitHub's persist API validates the entry workflow. Signing succeeds only when both are the same. B06 keeps this property; S05 tests it. `release.yml` runs on `workflow_run` and contains no `actions/attest`.
- **Permissions.** The workflow default is `contents: read`. Only the `attest` job adds `id-token: write`, `attestations: write` and `packages: read` (builder image pull).
- **Gating on the oracle.** `needs:` includes the oracle aggregate job (`oracle-gate`, defined by O02 and B06). See Spec defects: Sigstore attestations are public the moment they are made, so Principle 7 requires the oracle to have passed first, as rc1 did with `needs: boot-test`.
- **Signing.** `actions/attest` (pinned by SHA from `pins/pins.yaml`; rc1 used `@v2`) with `subject-path: <iso>`, `predicate-type: https://slsa.dev/provenance/v1`, `predicate-path: …/predicate.json`. Condition: `steps.attest.outputs.overall == 'pass'` and `github.event_name == 'push'`. Pull-request builds run every pillar and do not sign, since fork PRs have no OIDC token and PR builds should not write to the attestation store. `subject-path` makes the action hash the file itself, an independent computation (INV-DIGEST-4).
- **Post-sign verification.** `gh attestation verify "$ISO" --repo "$GITHUB_REPOSITORY" --signer-workflow "$GITHUB_REPOSITORY/.github/workflows/build.yml" --predicate-type https://slsa.dev/provenance/v1 --format json > attestation-verify.json` with up to three attempts and a short pause, then `digest_chain.py verify --attested attestation-verify.json …`. The exact JSON shape of `--format json` is read by one function in `digest_chain.py` and pinned by a recorded fixture from the first real run; until then the parser is written to the documented shape and flagged unverified.
- **Outputs.** `output/attestation/**` is uploaded as an Actions artifact with `if: always()` and written to the store with `store put build builds/<version>/attestation/<file>` (never the `public` class; publishing is P02/P03). A failing build still leaves its reports behind for diagnosis (resolves the study contradiction about FAILED builds reaching the dashboard: here they reach private storage only; whether P03 shows failed rows is P03's decision).
- No vendor CLI, no `aws`, no `S3_BUCKET`. Distribution URLs for the SBOM come from `store url` (P01) for public builds.

### Cross-index of study invariants (all 28)

| Invariant | Disposition |
|---|---|
| INV-DIGEST-1 | S05-AC-4. ISO hashed once at step 1; independent re-hash in `digest_chain` |
| INV-DIGEST-2 | S05-AC-8, S05-AC-9. No provenance without a real hash (exit 2, no placeholder) |
| INV-DIGEST-3 | S05-AC-1, S05-AC-14. Release re-verification via `digest_chain.py verify`; adds the SLSA subject check the old step lacked |
| INV-DIGEST-4 | S05-AC-11, S05-AC-13 |
| INV-PILLAR-ALL | S05-AC-5 |
| INV-SBOM-1 | S01-AC-12, S01-AC-13; S05-AC-5 (a failed SBOM makes dependent pillars `error`) |
| INV-SBOM-2 | S01-AC-7, S01-AC-8 |
| INV-SBOM-3 | S01-AC-2 |
| INV-SBOM-4 | S01-AC-5 (silent skip becomes exit 1) |
| INV-CPE-1 | S01-AC-3 |
| INV-LIC-1 | S02-AC-1, S02-AC-4 |
| INV-LIC-2 | **Deliberately dropped**; replaced by S02-AC-4 (unknown fails) |
| INV-LIC-3 | S02-AC-7; S05-AC-2 (policy hash in the chain) |
| INV-CVE-1 | S03-AC-2 |
| INV-CVE-2 | S03-AC-3 (expiry enforced) |
| INV-CVE-3 | S03-AC-6 |
| INV-CVE-4 | S03-AC-6, S03-AC-7; `age_warning` becomes a failure |
| INV-CVE-5 | S03-AC-9, 10, 11; S05-AC-2 (canary in the chain) |
| INV-CVE-6 | S03-AC-7 |
| INV-CVE-7 | **Deferred to P05** |
| INV-OWN-1 | S04-AC-2 |
| INV-OWN-2 | **Replaced**: S04 walks the disk (S04-AC-1) |
| INV-OWN-3 | **Replaced**: S04-AC-1, S05-AC-6 (a missing pillar report fails) |
| INV-PROV-1 | S05-AC-8 |
| INV-PIN-1 | S01-AC-10 |
| INV-DASH-1 | **Deferred to P03** (`builds-index.json`) |
| INV-REL-1 | **Deferred to P02** (workflow_run gate, tag-to-SHA check) |
| INV-REL-2 | S05-AC-14 (`sums`); publishing it is P02 |

### Cross-index of study contradictions (all 19) and open questions

| # | Contradiction | Disposition |
|---|---|---|
| 1 | `--include-builder` is a no-op, default 1 | S03 (builder pillar declared, flag removed); S05-AC-6 |
| 2 | five pillars documented, six run | S05-AC-6 (`pillars.yaml`, test that code and file agree) |
| 3 | nightly monitor "orphaned" in docs | **P05** (docs); S03 corrects `docs/cve-gate.md` |
| 4 | nightly revokes on any match, ignores policy | **P05**, with S03's library (S03-AC-14) |
| 5 | waiver `expires` not enforced | S03-AC-3 |
| 6 | `fix_state_gates` never read | S03-AC-5 |
| 7 | unowned `*` crosses `/` | S04-AC-3 |
| 8 | ~50 vs 87 CPE overrides | S01-AC-3 (computed count) |
| 9 | `cve-coverage.json` vs actual names | S03-AC-13 |
| 10 | two S3 hostnames for the dashboard | **P01/P03** (no vendor hostnames; S01-AC-1 forbids them in the SBOM tool and S05-AC-11 in the attest job) |
| 11 | release does not re-check the SLSA subject | S05-AC-1, S05-AC-2, S05-AC-14 |
| 12 | per-release S3 prefix and ISO naming | **B06/P02**. S05 only fixes attestation file names and the `builds/<version>/attestation/` key layout |
| 13 | dashboard findings table hidden at zero findings | **P03** |
| 14 | v86 "loaded once" | **P04** |
| 15 | dashboard SBOM pillar hard-coded PASS | **P03** (summary now has `sbom_check` incl. `error`) |
| 16 | `Build Type` label wrong for prerelease tags | **P03**, **P02** |
| 17 | provenance snapshot sha source | S05-AC-8 (from pins, no download) |
| 18 | `cpe-exclusions.json` overwritten, never surfaced | S01-AC-3; surfacing is **P03** |
| 19 | `continue-on-error`, failing builds reach S3 | S05-AC-11 (ordering, always-upload to private store only); **P03** for dashboard policy |

| Open question | Disposition |
|---|---|
| builder-image pillar wanted? | S03: yes, report-only |
| mocked-grype harness never committed | S03 RED plan ships a stub grype |
| `builder.image_digest` empty in CI | S05-AC-8, S05-AC-15 |
| SBOM specVersion 1.8 | S01-AC-7 (fails by design, names the file to vendor) |
| grype/syft unpinned | S01-AC-11, S03-AC-6 (compare with pin); pinning is I03/I05 |
| SOURCE_DATE_EPOCH reproducibility checked? | **B07**; S01-AC-9 makes the SBOM deterministic |
| dashboard location/hosting; `themonolith.org` identity | **P01/P03**, OD-1 |
| CORS config | **P01** |

## Traps and doctrines preserved

- **T-attest-entry-workflow.** If `build.yml` ever becomes a `workflow_call` target, or signing moves to another workflow, the failure appears only on a real tag after the whole build and boot suite passed. Prevented by S05-AC-10 (static test) and S05-AC-13 (a non-tag push build must sign and verify, because with direct entry any push build exercises the same path).
- **T-syft-quirks (SLSA buildType).** Wrong `buildType` is rejected by GitHub only at persist time. S05-AC-8 pins the exact string.
- **T-schema-validation-hang.** Schema validation stays in the attest job with a timeout, owned by S01-AC-7/8. S05-AC-11 asserts the validate step exists in the job.
- **T-cve-gate-unfalsifiable / T-canary-silence.** The canary result and DB checksum are bound into the chain (S05-AC-2, check 9), so a PASS with no canary cannot be signed.
- **D-supply-chain-honesty.** The chain itself: AC-1, AC-2, AC-4, AC-14. "Releases only through the verifiable pipeline" is enforced at release by P02 using AC-14's interface.
- **DEC-fail-closed-attestation.** Sign only on pass: AC-11. Run all pillars: AC-5.
- **Principle 5.** No pillar silently skipped (AC-6), no placeholder in provenance (AC-9), no `unknown/unknown` defaults, a missing input is exit 2 (AC-3).
- **Principle 7.** Attest after the oracle (AC-12), nothing public written by the attest job (AC-11).
- **Principle 1.** No vendor names in S-node code or the attest job (AC-11).

## Gate

- **S05-AC-1** — `digest_chain.py verify` exits 0 on the good fixture set (ISO, summary, SBOM, provenance, SHA256SUMS, attested JSON, reports, policy dir) and the `--json` output lists checks 1 to 10 each `ok: true`. *Verify:* `tests/fast/test_digest_chain.py::test_good_set`. *Tier:* fast.
- **S05-AC-2** — Mutation matrix, each exit 1 and naming the failed check: flip one ISO byte; change `summary.iso_sha256`; change the SBOM component hash; change a `distribution` reference hash; change the provenance subject digest; change the provenance subject name; change the attested subject digest; change the SHA256SUMS ISO line; change the SHA256SUMS bom line; change a report file after hashing; change a policy file; set `overall: pass` while a gating `*_check` is `fail`; set `cve_canary.found` false; make the canary DB checksum differ; set `local: true` in the provenance. *Verify:* `tests/fast/test_digest_chain.py::test_mutations` (one parametrised case per mutation). *Tier:* fast.
- **S05-AC-3** — Missing, empty or unparseable input is exit 2, never pass: absent ISO, summary or SBOM; `iso_sha256` equal to `(not computed)` or empty; SBOM without a SHA-256 hash; a given flag whose file is missing. The SBOM hash is found by `alg` even when `hashes` has another entry first. *Verify:* `tests/fast/test_digest_chain.py::test_missing_inputs`, `::test_hash_by_alg`. *Tier:* fast.
- **S05-AC-4** — The ISO is hashed once. `sbom.py` and `provenance.py` never open the ISO path; `attest.py` hashes it exactly once and passes the value to both; `digest_chain.py` re-hashes. *Verify:* `tests/fast/test_attest_hash_once.py` (AST search for ISO reads, stub-run of `attest.py` counting `sha256` calls). *Tier:* fast. *When:* after MS2.
- **S05-AC-5** — The orchestrator runs every pillar and writes every artifact even when pillars fail. With stub tools injected to fail each of the eight pillars one at a time, `attest.py` runs all the others, writes `attestation-summary.json` and the reports it could produce, and exits 1. Dependent pillars of a failed SBOM record `error` with reason `no-input`. With all stubs passing the exit is 0. *Verify:* `tests/fast/test_attest_orchestrator.py`. *Tier:* fast.
- **S05-AC-6** — `pillars.yaml` is the single pillar list: the set of pillar names in `attest.py`, the summary schema and the file are equal. `overall` is `pass` iff every gating pillar is `pass`; `fail`, `error`, `not_run` and absent each fail a gating pillar; a non-gating `fail` does not fail overall; a non-gating `error` does. *Verify:* `tests/fast/test_attest_pillars.py`. *Tier:* fast.
- **S05-AC-7** — The summary validates against its schema on write. Its key set contains every v1 key from `tests/fixtures/supplychain/summary-v1-keys.txt`. `reports{}` and `policies{}` hashes equal the files. `cve_policy.sha256` equals the sha256 of `cve-policy.yaml`. `cve_waivers[]` equals the `waivers_applied[]` of the CVE report. *Verify:* `tests/fast/test_attest_summary.py`. *Tier:* fast.
- **S05-AC-8** — Provenance in `--ci` mode: `buildType` equals the canonical string; the subject is the ISO name and hash; `resolvedDependencies` contains the commit, stage3, snapshot, kernel, builder and `versions.lock` entries with digests; `started <= finished`; the byproducts list excludes `attestation-summary.json`; `workflow.path` is parsed from `GITHUB_WORKFLOW_REF` and is `.github/workflows/build.yml`. The tool opens no sockets (test runs it with the socket module disabled) and `provenance.py` and `attest.py` contain no `curl` or `urllib`. A missing pin, digest or required environment variable is exit 2. *Verify:* `tests/fast/test_provenance.py`. *Tier:* fast.
- **S05-AC-9** — Without `--ci` the provenance carries `internalParameters.local: true`. `digest_chain.py` check 10 and `attest.py --ci` reject it. A missing or `(not computed)` ISO hash gives exit 2 and no file. *Verify:* `tests/fast/test_provenance.py::test_local_mode_not_attestable`. *Tier:* fast.
- **S05-AC-10** — Entry-workflow invariants hold in the workflow files: `build.yml` has `on.push.tags` matching `v*.*.*`, no `workflow_call`, and contains the `attest` job with the `actions/attest` step; no other workflow file contains `actions/attest`; `release*.yml` triggers only on `workflow_run`. *Verify:* `tests/fast/test_workflow_attest_entry.py`. *Tier:* fast.
- **S05-AC-11** — Attest job hygiene, by static check of `build.yml`: the signing step's `if` contains `overall == 'pass'`; `id-token: write` and `attestations: write` appear only in the `attest` job; there is no `continue-on-error` on the attest step; the upload step has `if: always()`; the S01 validate step is present; no step in the job names a storage vendor CLI or writes to the store `public` class; every `uses:` is pinned by SHA (F01's check, re-asserted for this job). *Verify:* `tests/fast/test_workflow_attest_job.py`. *Tier:* fast.
- **S05-AC-12** — The `attest` job's `needs` includes the oracle aggregate job. *Verify:* `tests/fast/test_workflow_attest_job.py::test_needs_oracle_gate`. *Tier:* fast.
- **S05-AC-13** — On a non-tag push to the default branch, the attest job signs, then `gh attestation verify` with the signer workflow `build.yml` succeeds, and `digest_chain.py verify --attested` exits 0. *Verify:* CI run on the default branch; job steps "Sign" and "Verify attestation". *Tier:* slow.
- **S05-AC-14** — The release interface is frozen: `digest_chain.py sums` output is deterministic, ends with a newline, and passes `sha256sum -c` against the same files; `verify --help` lists every flag in the Design table; `docs/attestation.md` shows the exact `verify` and `sums` invocations P02 and users run, and a user-side `gh attestation verify` command. *Verify:* `tests/fast/test_digest_chain_cli.py`. *Tier:* fast.
- **S05-AC-15** — In CI, `summary.builder.image_digest` is non-empty, equals the digest in `pins/pins.yaml`, equals the provenance `monolith-builder` digest, and equals the digest `docker inspect` reports for the image the job pulled. *Verify:* `build.yml` attest job step "Builder digest cross-check", then `digest_chain.py` check 10. *Tier:* slow.
- **S05-AC-16** — On the first real tag build, `v0.2.0-rc1` (MS2, executed by P02), the attestation persists, `gh attestation verify` passes, and `digest_chain.py verify` with all flags passes on the files downloaded as P02 downloads them. *Verify:* P02's release run; S05 provides the script and the evidence table. *Tier:* slow.
- **S05-AC-17** — The rc1 lane. On rc1's ISO, SBOM and `SHA256SUMS` (fetched by O01, digests `a9600659…eb27a` and `3cfc322a…75887`), `digest_chain.py verify --iso … --sbom … --sums …` exits 0: checks 2 and 5 pass and the checks that need other files are `skipped`. `gh attestation verify` of rc1's ISO is run with `--repo tuckermclean/linux-live-iso-factory` and the signer workflow `tuckermclean/linux-live-iso-factory/.github/workflows/build.yml`, because rc1's attestation is bound to that name. Repository and signer workflow are arguments, never literals in the script. The real `--format json` output is saved as the fixture the `--attested` parser reads. If rc1's attestation no longer verifies, the PR records that and the hand-written fixture stays. The test fails, not skips, if the rc1 files are absent. *Verify:* `tests/slow/test_digest_chain_rc1.py`, run by the rc1-lane CI job; no build. *Tier:* slow.

## RED plan

- Tester writes first: `test_digest_chain.py`, `test_digest_chain_cli.py`, `test_attest_{hash_once,orchestrator,pillars,summary}.py`, `test_provenance.py`, `test_workflow_attest_{entry,job}.py`. They import `supplychain.digest_chain` and parse `.github/workflows/build.yml`. The modules do not exist and the workflow has no `attest` job, so all fail.
- The good fixture set `tests/fixtures/supplychain/chain/` is generated by a helper `make_chain_fixture.py` in the RED commit: a small fake ISO (a few KiB), and consistent summary, SBOM, provenance, sums, attested JSON, reports and policy dir. Mutation tests start from it.
- Orchestrator tests use stub executables for `syft`, `grype` and the gate commands on `PATH` that exit as instructed by environment variables. The stubs are part of the RED commit.
- `build.yml` is written by B06. The workflow tests parse whatever `build.yml` is at the commit, so they stay red until B06's skeleton has an `attest` job. Coordinate: B06 lands the job skeleton (empty `run`) first; S05 fills it.

## Risks and open questions

- **`gh attestation verify --format json` shape** is not in the study and not verified here. The parser is isolated and pinned by a recorded fixture. The first real output comes from verifying rc1's attestation in the rc1 lane (AC-17), if it still verifies; otherwise from the first default-branch run (AC-13). Until then AC-1/AC-2 use a hand-written fixture of the documented shape. Whether the output format is the same for a repository other than the predecessor is unverified.
- **Attestation store propagation delay** after `actions/attest` is unknown; the three-attempt retry is a guess. AC-13 shows whether it is needed.
- **`actions/attest` input names** (`predicate-path`) and its current major version are assumed from memory of the action's interface and must be confirmed against the SHA pinned by I05/M04.
- **Sign on every push to the default branch** puts one attestation per master build into GitHub's store. rc1 did the same (`if: verdict == pass`). If the volume matters, restrict signing to tags and run the attested-verify path on tags only; then AC-13 becomes a tag-only slow check and a dry-run path is needed for earlier confidence. Owner's call; not an OD in SPEC section 10.
- **Cost of the builder image scan in every attest** is unmeasured (registry pull of a Gentoo toolchain image, probably several GB; not measured).
- **Oracle gate coupling** (see Spec defects) is the one cross-node assumption: if O02/B06 name or shape the aggregate job differently, AC-12 changes.
- OD-4 (agent bot identity) does not touch this node. OD-1 touches only P01/P03 URLs that S05 must not hard-code.

## Cost

- Slices: 5.
  1. `digest_chain.py` verify and sums with the fixture helper (AC-1, 2, 3, 14).
  2. `provenance.py` offline, CI and local modes (AC-8, 9).
  3. `attest.py` orchestrator, `pillars.yaml`, summary schema (AC-4, 5, 6, 7).
  4. `attest` job in `build.yml`, static workflow tests (AC-10, 11, 12).
  5. Slow verification and docs (AC-13, 15, 16, `docs/attestation.md`).
- CI build cycles: 0 for the rc1 lane (AC-17). 2 attest-job runs on B06's pipeline once the first ISO exists (MS1): one end to end on the default branch (AC-13), one to fix what that finds (action inputs, digest cross-check, AC-15). The tag run (AC-16) is P02's from-source build and is counted there.
- Time: the predecessor's attestation job took 4.7 min on GitHub Actions (measured, run 37292535170); with the builder-image scan by digest this may grow, unmeasured.
- Money: attest job minutes (SBOM generation for two images, one grype fetch, two scans, one registry pull): unmeasured beyond the 4.7 min above. Storage: the attestation set per build is small if the SBOM is package-only (S01 guards 4 MiB) plus reports; no large files. No paid services.

## Spec defects found

1. **Pipeline order versus SPEC 4.1.** The diagram feeds the SBOM from the squashfs but the SBOM must carry the ISO hash, so it runs after B05. S01 already notes this; S05 fixes the order in the job.
2. **Oracle aggregate name.** S05 now depends on O02 to O06 directly. AC-12 still assumes B06 names its aggregate job `oracle-gate`; if B06 names it otherwise, AC-12 changes.
3. **Store key layout.** SPEC section 5 says `build` keys are `builds/<version>/<file>`. Attestation outputs are about 15 files, so this spec uses `builds/<version>/attestation/<file>`. Confirm that subpaths under `builds/<version>/` are allowed.
