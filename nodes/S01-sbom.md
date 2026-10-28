# S01 — sbom

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| S | B05, I05, R02 | O06, O07, S02, S03, S04 | — (on the path to MS3 via O07, and to MS4 via S05) | L |

**Owns:**
- `supplychain/sbom.py` — subcommands `enrich`, `generate`, `validate`.
- `supplychain/common.py` — shared helpers for every S-node tool: policy loading with sha256, canonical JSON writer, report envelope, exit-code constants.
- `supplychain/data/cpe-overrides.yaml`, `supplychain/data/cpe-exclusions.yaml`, `supplychain/data/sbom-propagate.yaml`.
- `supplychain/policy/sbom-denylist.yaml`.
- `supplychain/schema/cyclonedx/` — vendored schemas plus `README`.
- `supplychain/schema/gaps-report.schema.json`.
- `tests/fast/test_sbom_*.py`, `tests/fixtures/supplychain/syft/` (Syft input fixtures).
- `oracle/supplychain/syft-smoke.sh`.
- `docs/sbom.md`.

**Carries from linux-live-iso-factory@b9f533b:**
- `scripts/enrich-sbom.py`, rewritten as `supplychain/sbom.py`.
- `configs/attestation/cpe-overrides.yaml`, `cpe-exclusions.yaml`.
- `configs/attestation/schemas/*` (bom-1.6, bom-1.7, spdx, jsf-0.82, cryptography-defs, README).
- Pillar 1 and the builder half of Pillar 5 from `scripts/attestation.sh:253-358, 507-575`.
- The schema step from `.github/workflows/build.yml` (~700-745).
- `configs/attestation/spdx-license-ids.txt` is dropped; see Design.

**Study refs:**
- Invariants: INV-SBOM-1..4, INV-CPE-1, INV-PIN-1, INV-DIGEST-1 (SBOM half).
- Traps: T-schema-validation-hang, T-syft-quirks.
- Doctrines: D-bitmap-fonts-no-freetype, D-no-python-on-target, D-supply-chain-honesty.
- Contradictions: ~50 vs 87 CPE overrides; `cpe-exclusions.json` overwritten by the builder pass and never surfaced; Syft/grype installed from unpinned `install.sh`.
- Components: `script.enrich-sbom`, `cfg.attestation/{cpe-overrides,cpe-exclusions,spdx-license-ids,schemas}`.
- Data contracts: `bom.cdx.json`, `builder-bom.cdx.json`, `sbom.cdx.json`, `cpe-gap-count.txt`, `cpe-exclusions.json`.

## Purpose

After this node, the sysroot of a built ISO turns into one validated, deterministic, package-level CycloneDX SBOM (`bom.cdx.json`). The SBOM carries the ISO hash, CPE mappings, normalised licenses, a dependency graph and the build-input formulation. It is checked for completeness against the Portage database, so a package Syft skipped is an error. S02, S03, S04 and the golden diff (O07) all read this one document.

## Scope

**In:**
- Run the pinned Syft on a sysroot (target) or a pinned builder image (builder kind).
- Enrich: product component, ISO binding, CPE overrides and exclusions, license normalisation, dependency graph, propagated builder components, formulation, tool identity.
- Integrity checks: vdb completeness, propagated components present, doctrine denylist.
- Offline CycloneDX schema validation.
- A per-SBOM gap report.

**Out:**
- License policy decisions: S02.
- CVE scanning and the grype DB: S03.
- File-ownership audit: S04. It walks the sysroot itself and no longer needs Syft's file cataloger.
- ISO hashing and the summary: S05. S01 receives the hash as an argument.
- The golden diff against rc1: O07. S01 lists the differences it expects to cause; see Design.
- The pins file and `versions.lock`: I05 and R02. S01 reads them.
- Dashboard rendering of gaps: P03.
- The full removed-packages denylist: R02 (see Spec defects).

## Design

### Layout and CLI

All S-node tools are Python 3, standard library plus PyYAML, run in the builder image (SPEC 4.3). Shared exit codes, defined in `common.py` and used by every S-node tool:

| Code | Meaning |
|---|---|
| 0 | check passed |
| 1 | the check ran and the answer is "fail" (policy or integrity violation) |
| 2 | input, config or tool error: missing, empty, unparseable or inconsistent input |

Code 2 is a failure for every caller (Principle 5). It is separate from 1 only so logs say which. Nothing is ever skipped with a warning.

```
sbom.py generate --kind target  --sysroot DIR            --out-dir DIR --build-tag T --iso-sha256 H --iso-name N [--ci]
sbom.py generate --kind builder --image REF@sha256:DIGEST --out-dir DIR --build-tag T
sbom.py enrich   --syft-cdx IN --out OUT.cdx.json --kind target|builder ...   (pure, no subprocess; what the tests call)
sbom.py validate --sbom FILE
```

- `generate` runs Syft, then `enrich`, then `validate`, stopping at the first non-zero exit.
- `--ci` is set whenever `GITHUB_ACTIONS=true` or by explicit flag. It makes every optional input below mandatory.
- Output files, for kind target and out-dir `D`:
  - `D/sbom.cdx.json` (raw Syft CycloneDX)
  - `D/sbom.syft.json` (raw Syft native, kept for debugging only)
  - `D/bom.cdx.json` (enriched, published)
  - `D/bom.gaps.json`
- For kind builder: `builder-sbom.cdx.json`, `builder-bom.cdx.json`, `builder-bom.gaps.json`. The gap file name derives from the `--out` stem, so the builder pass can never overwrite the target's (resolves the `cpe-exclusions.json` overwrite contradiction).

### Syft invocation (T-syft-quirks)

- Target: `syft dir:<sysroot> --override-default-catalogers portage-cataloger -o cyclonedx-json=… -o json=…`. The flag name is checked against the pinned Syft version in `syft-smoke.sh`.
- `SYFT_FILE_METADATA_SELECTION=all` is **dropped**. It existed only to populate `files[]` for the old Pillar 4 (`attestation.sh:259`). Dropping it removes the cause of the 16,553-file-component bloat (T-schema-validation-hang). S04 walks the filesystem itself.
- Builder: scan `registry:<image>@sha256:<digest>`, with the digest taken from `pins/pins.yaml` (I05). This replaces `syft dir:/` plus eleven `--exclude './x/**'` flags (`attestation.sh:517-530`). No excludes are needed, the bind-mount problem disappears, and the scanned digest is the recorded digest by construction.
  - Rejected: `dir:/` inside the running container. The excludes encode Syft's relative-path quirk and the image digest was never passed (`make attestation` omits `--builder-digest`, Makefile:450-458; `attest-builder` passes a local image ID or `unknown`, Makefile:475), so `builder.image_digest` was empty.
- The Syft version must equal the pin in `pins/pins.yaml`. `enrich` takes `--expect-syft-version`, compares it with `syft --version`, and exits 1 on mismatch. The old repo installed both tools from an unpinned `install.sh` (Dockerfile:124-131).

### Enrichment rules (carried from enrich-sbom.py)

1. `specVersion` floor 1.6, never downgraded. Accepted set is the vendored set (1.6, 1.7). Any other version fails `validate`, and the message names the file to vendor (`enrich-sbom.py` floors, build.yml schema step).
2. `metadata.component`:
   - type `operating-system`, `bom-ref: themonolith-<tag>`, name `themonolith`.
   - `hashes: [{alg: SHA-256, content: <iso-sha256>}]`, written only when `--iso-sha256` is given.
   - `externalReferences`: vcs, build-system, and `distribution` entries, one per URL passed as `--distribution-url` / `--release-url`. Each carries the same hash.
   - URLs are never fabricated and never name a storage vendor. The caller derives them from `store url` (P01) and the deterministic GitHub release URL.
   - Syft's auto-detected distro component is removed.
3. Package-SBOM shape (INV-SBOM-3):
   - drop `type: file` components;
   - drop binary-cataloger duplicates of portage entries and shell-quoted parse artifacts;
   - strip synthetic Portage-slug CPEs and `syft:cpe23*` properties;
   - ensure unique `bom-ref`s.
4. CPE (INV-CPE-1): `data/cpe-overrides.yaml` is an exception list, keyed by bare package name. `-rN`, `_pN`, `_preN` are stripped before substitution. `acct-group/`, `acct-user/`, `app-alternatives/`, `virtual/` never get a CPE. Every other package without a CPE is a genuine gap; excluded ones are counted separately.
5. Licenses:
   - `license.id` holds only ids present in the vendored `spdx.schema.json` enum; anything else becomes `license.name`.
   - The Gentoo-to-SPDX map is read from S02's `supplychain/policy/license-policy.yaml`.
   - **Decision:** `configs/attestation/spdx-license-ids.txt` (810 ids) is dropped and the enum is read from the vendored `spdx.schema.json`, one source that cannot drift.
   - If the enum cannot be read the tool exits 2. The old code silently skipped sanitisation when the list was missing (`enrich-sbom.py:211-225`).
6. Dependency graph from vdb RDEPEND/DEPEND, rooted at the product with the world atoms.
7. PURL `?arch=…&distro=gentoo` qualifiers; supplier `Gentoo Linux`; upstream authors and homepage from `metadata.xml` and vdb, best-effort and never fabricated.
8. Propagation (INV-SBOM-4): musl (`cross-i486-linux-musl`), `sys-boot/grub` and `sys-boot/syslinux` are copied from the host vdb into the target SBOM. They are embedded in the ISO but absent from the sysroot vdb.
   - The list lives in `data/sbom-propagate.yaml`.
   - **Decision:** a listed package missing from the host vdb is exit 1. The old code skipped silently (`enrich-sbom.py:779-827`).
   - Rejected: warn only; the CVE and license gates would then silently stop covering musl and the bootloaders.
9. Formulation (INV-PIN-1): stage3 epoch and digest, snapshot sha256, builder image digest, `versions.lock` sha256, kernel and busybox tarball SHA-512. Sources are `pins/pins.yaml`, `pins/versions.lock` and the overlay `Manifest`s. In `--ci` any missing input is exit 2; locally it is omitted, never fabricated.
10. `metadata.tools` records Syft and grype versions. The grype DB identity is deliberately **not** in the SBOM; it is a scan result, and the DB is fetched after SBOM generation. It lives in the S03 report and the summary.
11. Determinism: `serialNumber` is `urn:uuid:` UUIDv5 of `<iso-sha256 or syft-cdx-sha256>`. `metadata.timestamp` is derived from `SOURCE_DATE_EPOCH` (required in `--ci`). Dependency and component order is sorted. Same inputs produce byte-identical `bom.cdx.json` (helps B07, and makes the hash in `SHA256SUMS` reproducible). This is a new property; rc1 SBOMs were not deterministic.

### Integrity checks (all exit 1 with the offending names listed)

- **Completeness:** every `<sysroot>/var/db/pkg/<cat>/<PF>/` directory maps to exactly one component by `cat/PN`, and every non-propagated component maps to a vdb directory. Counts are printed. This catches silent Syft under-reporting.
- **Propagated present:** every entry in `sbom-propagate.yaml` is a component.
- **Doctrine denylist** (`supplychain/policy/sbom-denylist.yaml`, target kind only): fails if the target SBOM contains:
  - `media-libs/freetype`, `media-libs/fontconfig`, `x11-libs/libXft` (D-bitmap-fonts-no-freetype);
  - `dev-lang/python` and `dev-python/*` (D-no-python-on-target).

  O06 checks the artifact bytes. This catches the same regression one stage earlier, from package metadata.

### Gap report (`bom.gaps.json`)

Replaces `cpe-gap-count.txt`, `cpe-exclusions-count.txt` and `cpe-exclusions.json` (fixed names, overwritten by the builder pass: `enrich-sbom.py:1301-1324`, `attestation.sh:549-574`). Schema `supplychain/schema/gaps-report.schema.json`:

```json
{"schema":1,"kind":"target","build_tag":"…","overrides_applied":87,
 "genuine_gaps":[{"name":"…","version":"…"}],
 "excluded":[{"name":"…","version":"…","pattern":"virtual/*","justification":"component_not_present"}]}
```

Counts are `len()` of the lists. The prose count "~50 overrides" (docs/cve-gate.md:25) becomes a computed `overrides_applied`; no doc states a number.

### Validation (T-schema-validation-hang)

- Schemas are vendored under `supplychain/schema/cyclonedx/`. The `$id` key is stripped from each, so relative `$ref`s resolve to the local files. A static test asserts this.
- `sbom.py validate` runs the pinned `check-jsonschema` (declared as a builder host tool; ask I03) with `--base-uri file://<dir>/` and `timeout 180`. Timeout is failure, never a skip.
- Validated: `bom.cdx.json` and `builder-bom.cdx.json`.
- "SPDX" in the graph summary is read as the SPDX license-id schema (`spdx.schema.json`, a `$ref` target of both CycloneDX schemas). No SPDX-format document is produced. Rejected: emitting an SPDX SBOM too; there is no consumer and it doubles validation. See Spec defects.

### Expected differences handed to O07

Changes versus rc1's `bom.cdx.json` caused by this node, so O07's expected-differences file can list them with reasons:
- deterministic `serialNumber` and `timestamp`;
- `GPL-2`, `GPL-3`, `LGPL-*` mapped to `-only` ids (S02 decision);
- `externalReferences` no longer carry a vendor `s3://` URL;
- the `formulation` block gains the builder image digest and snapshot sha256 from pins.

## Traps and doctrines preserved

- **T-schema-validation-hang.** If vendored schemas regain a network `$ref` or `$id`, or file components return, CI hangs for hours. Prevented by AC-7 (static closure plus `$id` check, timeout-is-failure), AC-2 (no file components) and AC-13 (size ceiling).
- **T-syft-quirks.**
  - Builder scan avoids excludes entirely, by registry digest (AC-12).
  - Syft's flag names are verified against the pinned version (AC-12).
  - The buildType quirk belongs to S05.
- **D-bitmap-fonts-no-freetype / D-no-python-on-target.** Denylist, AC-6; O06 checks bytes.
- **D-supply-chain-honesty.** The ISO hash enters the SBOM only from the one value S05 computes (AC-1). Nothing is fabricated; absent inputs fail in CI mode (AC-1, AC-10).
- **Principle 5, success is honest.** No "skip with warning" survives: missing propagated packages, missing SPDX enum, missing formulation inputs and Syft under-reporting are all errors (AC-4, AC-5, AC-10).
- **Principle 2, pinned inputs.** The Syft version is compared with the pin (AC-11).

### Invariant and contradiction disposition (this node)

| Item | Disposition |
|---|---|
| INV-SBOM-1 | AC-12, AC-13; S05-AC-5 turns enrich failure into a failed pillar |
| INV-SBOM-2 | AC-7 |
| INV-SBOM-3 | AC-2 |
| INV-SBOM-4 | AC-5; silent skip replaced by exit 1 |
| INV-CPE-1 | AC-3 |
| INV-PIN-1 | AC-10 |
| INV-DIGEST-1 (SBOM half) | AC-1 |
| Contradiction: 87 vs ~50 overrides | AC-3 (computed count, no prose number) |
| Contradiction: cpe-exclusions overwritten, never surfaced | AC-3 (per-SBOM gap file). Dashboard surfacing: P03 |
| Open question: syft/grype unpinned | AC-11. Pinning itself: I03/I05 |

## Gate

- **S01-AC-1** — `sbom.py enrich` binds the ISO. Given `--iso-sha256`, `metadata.component.hashes` holds that SHA-256, and every `distribution` externalReference passed in carries it. Without `--iso-sha256` in `--ci` mode the exit is 2. No URL appears unless passed in, and the source contains no storage-vendor hostname. *Verify:* `tests/fast/test_sbom_enrich.py::test_iso_binding`. *Tier:* fast.
- **S01-AC-2** — The enriched SBOM is package-shaped: no `type: file` component, no synthetic slug CPE, no `syft:cpe23*` property, no binary-cataloger duplicate, no quoted-name component. Every `license.id` is in the vendored SPDX enum and everything else is a `license.name`. *Verify:* `tests/fast/test_sbom_enrich.py::test_package_shape`, `::test_license_ids`. *Tier:* fast.
- **S01-AC-3** — CPE accounting is correct:
  - an override applies with `-rN`/`_pN` stripped;
  - `acct-*`, `virtual/*` and `app-alternatives/*` never get a CPE;
  - `bom.gaps.json` lists genuine and excluded packages separately;
  - a builder run writes `builder-bom.gaps.json` and leaves the target's gap file byte-identical. *Verify:* `tests/fast/test_sbom_gaps.py`. *Tier:* fast.
- **S01-AC-4** — Completeness: a fake sysroot whose vdb has a package absent from the Syft fixture makes `enrich` exit 1 naming that package, and the reverse case fails too. A matching pair passes. *Verify:* `tests/fast/test_sbom_completeness.py`. *Tier:* fast.
- **S01-AC-5** — Propagation: with a host vdb containing musl, grub and syslinux, the three components appear with the `host-vdb-propagate` property and a CPE where an override exists. Removing any of them from the host vdb gives exit 1. *Verify:* `tests/fast/test_sbom_propagate.py`. *Tier:* fast.
- **S01-AC-6** — Doctrine denylist: a target SBOM containing `media-libs/freetype`, `media-libs/fontconfig`, `x11-libs/libXft` or `dev-lang/python` exits 1 naming the package. A clean fixture exits 0. A builder-kind run is not subject to it. *Verify:* `tests/fast/test_sbom_denylist.py`. *Tier:* fast.
- **S01-AC-7** — Offline validation:
  - every file under `supplychain/schema/cyclonedx/` has no `$id`;
  - the `$ref` closure resolves entirely inside that directory;
  - a valid fixture passes;
  - a fixture with a bad `license.id` fails;
  - a `specVersion` with no vendored schema fails and names the missing file;
  - a validator exceeding `timeout` fails rather than skips.

  *Verify:* `tests/fast/test_sbom_schema.py` (the test fails, not skips, if `check_jsonschema` is absent). *Tier:* fast.
- **S01-AC-8** — `sbom.py validate` also runs on the builder SBOM in the attest job, and the step fails the job on any non-zero exit including timeout. *Verify:* `tests/fast/test_workflow_sbom_validate.py` (static check of the attest job in `build.yml`). *Tier:* fast.
- **S01-AC-9** — Determinism: two `enrich` runs on the same inputs with the same `SOURCE_DATE_EPOCH` produce byte-identical `bom.cdx.json`. `serialNumber` is a function of the input hash. *Verify:* `tests/fast/test_sbom_determinism.py`. *Tier:* fast.
- **S01-AC-10** — Formulation: with pins and lock fixtures, the stage3 digest, snapshot sha256, builder digest, `versions.lock` sha256 and kernel SHA-512 are recorded. In `--ci`, removing any one input is exit 2. Locally it is omitted, not invented. *Verify:* `tests/fast/test_sbom_formulation.py`. *Tier:* fast.
- **S01-AC-11** — Tool identity: `enrich --expect-syft-version X` exits 1 when the stub `syft --version` differs. `metadata.tools` records the actual Syft and grype versions. *Verify:* `tests/fast/test_sbom_tools.py` (stub binaries on `PATH`). *Tier:* fast.
- **S01-AC-12** — The pinned Syft runs on a fixture sysroot (two vdb entries) and on the pinned builder image by digest, with the flags the tool uses, and emits the expected components. *Verify:* `oracle/supplychain/syft-smoke.sh`, run in the builder image by the I03/B06 job. *Tier:* slow.
- **S01-AC-13** — On the real CI sysroot, `sbom.py generate` exits 0, `bom.cdx.json` validates, completeness holds, and the file is under 4 MiB (a guard against file components returning). *Verify:* the `attest` job step "SBOM" in `build.yml` (size asserted by `sbom.py generate`). *Tier:* slow.

## RED plan

- Tester writes `tests/fast/test_sbom_{enrich,gaps,completeness,propagate,denylist,schema,determinism,formulation,tools}.py` first. They import `supplychain.sbom`, which does not exist, so every one fails at import. The commit carries `TDD-Red-Target: test-fast`.
- The Syft fixtures `tests/fixtures/supplychain/syft/*.json` are hand-reduced from a real Syft run. Until a real run exists (MS2), a minimal hand-written CycloneDX with the fields S01 reads is used: name, version, licenses, cpe, purl, type, properties, bom-ref. Slice 0 replaces it with a reduced capture from the first CI run.
- Vendored schemas are moved verbatim from the old repo in the RED commit's parent, so AC-7's closure test is meaningful.

## Risks and open questions

- Pinned `check-jsonschema` must be in the builder image; fast tests need it too. Ask I03 to declare it as a host tool.
- The rc1 SBOM (`bom.cdx.json` attached to the GitHub release v0.1.0-rc1) is the best real fixture for S01 through S03 and for O07. Fetching it needs network. Owner of the fixture path `tests/fixtures/rc1/bom.cdx.json` is O07; whichever node runs first fetches it and verifies it against the release's `SHA256SUMS`. Not verified here.
- `grype`'s and `syft`'s CLI flags can change between versions. The smoke test (AC-12) is what catches this after a pin bump (M04).
- Whether Syft on a registry image digest produces portage components identically to `dir:/` is unknown. AC-12 decides it; fallback is `docker save` plus `syft docker-archive:`.
- The completeness check assumes Syft names equal vdb `cat/PN`. rc1's `bare_name` handling (`enrich-sbom.py:66-84`) suggests Syft sometimes emits other forms. Slice 0 measures this on the first real capture.
- No OD applies. OD-3 (language) is assumed at its default.

## Cost

- Slices: 4.
  1. Port plus package shape plus CPE and gaps (AC-1, 2, 3).
  2. Integrity checks (AC-4, 5, 6).
  3. Schema, determinism, formulation (AC-7, 9, 10).
  4. Tool pin, smoke script, attest-job wiring (AC-8, 11, 12, 13).
- CI build cycles: 2. One to capture real Syft output and run the smoke script, one to confirm AC-13 on the real sysroot. Both need the MS2 ISO pipeline, so slow ACs wait for B06. Fast ACs do not.
- Money: none beyond CI minutes. The Syft registry scan reads the builder image from the registry (egress within GitHub, free).

## Spec defects found

1. **Pipeline order.** SPEC 4.1 draws S01 fed only by the squashfs, but the SBOM must carry the ISO hash, so it runs after B05. The graph dependency (B04) is enough for the code, but B06/S05 must order the attest job after the ISO exists. S05 owns the ordering; stated here so it is not missed.
2. **Missing deps.** S01's formulation reads `pins/pins.yaml` (I05) and `pins/versions.lock` (R02). In `--ci` mode AC-10 cannot go green before those exist. Either add S01 -> I05, R02 or accept that AC-10 runs against fixtures until then. Recommend adding both edges; neither creates a cycle.
3. **D-no-readding-removed-things.** SPEC section 3 names R02 as the enforcer, but R02's graph summary is version-lock completeness and says nothing of a denylist. S01's denylist covers only the two S01-named doctrines. Someone must own the full removed-packages list.
4. **"SPDX" in S01's summary** is ambiguous (SPDX-format SBOM versus SPDX license-id schema). Read here as the latter. Owner to confirm.
5. **Protected paths.** SPEC section 8 protects `supplychain/policy/` from agents. `cpe-overrides.yaml`, `cpe-exclusions.yaml` and `sbom-propagate.yaml` are data that agents must be able to edit, so they live in `supplychain/data/`. The denylist tightens the build and sits in `policy/`. Confirm this split.
