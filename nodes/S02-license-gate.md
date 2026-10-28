# S02 — license-gate

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| S | S01 | S05 | — (feeds MS2) | M |

**Owns:**
- `supplychain/license_gate.py` (CLI and importable module).
- `supplychain/policy/license-policy.yaml` (protected path).
- `supplychain/schema/license-policy.schema.json`, `supplychain/schema/license-report.schema.json`.
- `tests/fast/test_license_*.py`, `tests/fixtures/supplychain/license/`.

**Carries from linux-live-iso-factory@b9f533b:**
- `scripts/check-licenses.py` (366 lines), **ported** as `supplychain/license_gate.py`. Its CLI shape, component extraction (`:172-197`, `:307-317`), report fields and policy loader carry over. Only the expression parser (`:63-170`) and the unknown/empty handling (`:216-270`) are replaced, because AC-1 to AC-4 cannot hold on them.
- `configs/attestation/license-policy.yaml` (134 lines: 54 allowed entries incl. non-SPDX names, about 55 `gentoo_to_spdx` entries, empty `denied_spdx`).
- Pillar 2 from `scripts/attestation.sh:361-377`.

**Study refs:**
- Invariants: INV-LIC-1, INV-LIC-2, INV-LIC-3.
- Components: `script.check-licenses`, `cfg.attestation/license-policy.yaml`.
- Data contract: `license-report.json`.
- Principle 5 (success is honest).
- D-supply-chain-honesty.
- Verified defects, found by running the old parser:
  - the empty expression `""` and the empty group `|| ( )` both parse to `[[]]` and **pass** (`check-licenses.py:83-85, 237-256`);
  - `X WITH Y` is split into three "licenses" (`check-licenses.py:87`), which is why `GPL-2-with-font-exception` had to be added as a Gentoo alias;
  - unbalanced parentheses are silently repaired (`:91-96`);
  - `GPL-2` maps to `GPL-2.0-or-later` (`license-policy.yaml:77`).

## Purpose

After this node, every component of the SBOM, plus the product component, has a license that is provably acceptable under a versioned, hashed policy. It is developed and passing on rc1's SBOM (the rc1 lane, SPEC §7) before this repo builds anything, so the same code gates our first ISO unchanged. A license that is missing, malformed, empty or not in the policy fails the gate; the old gate let all three through as "pass" or "unknown". The policy file itself is validated, so it cannot allow a license id that is not real SPDX without a written reason.

## Scope

**In:**
- Expression parser for Portage (`|| ( )`, nesting) and SPDX (`AND`, `OR`, `WITH`, `+`) grammar.
- The policy schema and its self-validation.
- The report and exit codes.
- The corrected Gentoo-to-SPDX map.
- Importable evaluator for reuse.

**Out:**
- Producing the SBOM and normalising `license.id`/`name`: S01.
- Any license text bundling or NOTICE generation: not in the graph. The old repo did none.
- Deciding the verdict aggregate and signing: S05.
- Dashboard license tab: P03.
- Moving to a runtime-per-file license scan: not wanted; package metadata only, as before.

## Design

### CLI

```
license_gate.py --sbom bom.cdx.json --policy supplychain/policy/license-policy.yaml --output license-report.json
```

**Port first (Principle 11).** The slice order is: copy `check-licenses.py` and its policy, run it over the rc1 SBOM and record the result; then replace only what the ACs force.

| Change from the predecessor | Forced by |
|---|---|
| Recursive-descent parser, DNF, no regex repair, parse errors fail | S02-AC-1, AC-2 (empty `""` and `|| ( )` passed) |
| `X WITH Y` is one atom | S02-AC-3 (split into three licenses) |
| Unknown fails unless listed with a reason | S02-AC-4 (INV-LIC-2) |
| Zero-component SBOM is exit 2 | S02-AC-4 |
| Policy schema, SPDX enum check, `allowed_other` split | S02-AC-5 (fail-open `data.get(…, [])`) |
| `GPL-2` and friends map to `-only` | S02-AC-6 |
| `inputs.sbom_sha256` in the report | S02-AC-7 |

Exit codes follow the S01 table (`supplychain/common.py`): 0 pass; 1 at least one component fails; 2 input or policy error. Arguments are all required; no default paths. A missing or invalid file is exit 2 and no report claims a verdict.

### Input set

- All `components[]` except `type: file`, plus `metadata.component`, deduplicated by name with the metadata component winning (carried, `check-licenses.py:307-317`).
- An SBOM with zero package components is exit 2. An empty input must not pass (Principle 5).

### Expression grammar

One recursive-descent parser, no regex repair. Tokens: `||`, `(`, `)`, `AND`, `OR`, `WITH`, and license atoms. A trailing `+` stays part of the atom. It is expanded to DNF (a list of conjunctions). Precedence is `WITH` > `AND` (juxtaposition) > `OR`, so `A OR B AND C` is `[[A],[B,C]]`, as the old code produced.

Parse failures return an explicit error, and the component's status is `fail` with reason `parse-error: <detail>`. Parse failures are:
- empty or whitespace-only expression;
- empty group `|| ( )` or `( )`;
- unbalanced parentheses;
- `||` not followed by `(`;
- dangling operator;
- `WITH` without both sides.

**Decision:** parse failure fails the component. Rejected: the old "treat the whole string as one license and let the allowlist miss it" (`check-licenses.py:81, 95-96`). It hid empties as passes.

`X WITH Y` is one atom checked as: `X` is allowed (after mapping) **and** `Y` is in `allowed_exceptions`. This removes the need for the Gentoo alias hack `GPL-2-with-font-exception`.

### Component status

| Status | Condition |
|---|---|
| `pass` | at least one DNF alternative has every atom allowed and none denied |
| `fail` | parse error, a denied atom in every alternative, or no fully-allowed alternative |
| `fail` (reason `no-license-info`) | no `licenses` field, empty list, or an entry with no id/name/expression — unless listed in `unlicensed_allow` |

**Decision:** unknown fails. The old gate reported "unknown" and exited 0 (INV-LIC-2, `check-licenses.py:17-18, 227-235, 362`). That turns a silently missing license into an unreviewed one. Rejected: keep unknown as a warning. The graph summary for S02 says "unknown licenses fail".

`unlicensed_allow` is a list of `{name, reason}` in the policy: a package that genuinely has no declared license (for example a Gentoo `virtual/*` with `LICENSE=""`) is listed once with a written reason. Each entry that matches nothing in the current SBOM is listed in the report as `unused_exceptions`. It is informational so the list can shrink.

### Policy file (`supplychain/policy/license-policy.yaml`)

```yaml
schema: 1
allowed_spdx:        [MIT, BSD-2-Clause, …]        # every id must be in the SPDX enum
allowed_other:       [{name: curl, reason: "…"}, …]   # non-SPDX names the project accepts
allowed_exceptions:  [Font-exception-2.0]
denied_spdx:         []
gentoo_to_spdx:      {"GPL-2": "GPL-2.0-only", "GPL-2+": "GPL-2.0-or-later", …}
unlicensed_allow:    [{name: "virtual/…", reason: "…"}]
```

Policy validation (exit 2 if violated; schema `license-policy.schema.json`, unknown keys rejected):
1. Every `allowed_spdx` entry is a member of the enum in the vendored `supplychain/schema/cyclonedx/spdx.schema.json`. The enum must contain at least 500 ids, or the tool exits 2; this guards against an empty or truncated file.
2. Every `allowed_other` entry carries a non-empty `reason`. This is the "SPDX id validation" the graph asks for: the 20-odd non-SPDX names currently mixed into `allowed_spdx` (`license-policy.yaml:44-70`: `openssl`, `SSLeay`, `curl`, `netcat`, `lsof`, `Toyoda`, …) move here.
3. Every `gentoo_to_spdx` target is in `allowed_spdx ∪ allowed_other` or denied; a mapping to nothing known is an error.
4. `denied_spdx` takes precedence over allowed.

**Decision:** correct the mapping to Gentoo's real semantics. Gentoo `GPL-2`, `GPL-3`, `LGPL-2`, `LGPL-2.1`, `LGPL-3` mean "only" and the `+` forms mean "or later". The old table mapped the bare forms to `-or-later`. The gate result is the same, since both forms are allowed, but the SBOM and any future denial of "or later" would be wrong. This changes `license.id` values in `bom.cdx.json`. It must appear in S01's `deliberate` list (`rc1-sbom-diff.yaml`, S01-AC-14) and so in O07's expected-differences file. This rests on my reading of Gentoo's license-naming convention; verify against `licenses/` in the pinned snapshot in slice 1 before merging the table.

### Report (`license-report.json`)

Schema `license-report.schema.json`. Fields: `schema`, `gate: "license"`, `verdict` (`pass|fail`), `verdict_reasons[]`, `build_tag`, `inputs{sbom_path, sbom_sha256}`, `policy{path, sha256}`, `summary{total, pass, fail}`, `components[{name, version, raw_license, normalized[], status, reason}]`, `unused_exceptions[]`. There is no `unknown` count and no `unknown` status.

`inputs.sbom_sha256` is new. S05 checks it equals the hash of the published `bom.cdx.json`, so a report cannot be attached to a different SBOM (INV-LIC-3 extended). `policy.sha256` is carried.

### Reuse

`license_gate.evaluate(sbom: dict, policy: dict) -> Report` is a pure function with no I/O. S05 and any later per-PR SBOM diff (O07) can call it.

## Traps and doctrines preserved

- **Principle 5 / D-supply-chain-honesty.** A pass must mean every component was evaluated against a real rule. Empty-expression and empty-group passes are closed by AC-2. "Unknown means pass" is closed by AC-4. An empty SBOM passing is closed by AC-4.
- **Fail-open policy loading.** The old tool read `data.get("allowed_spdx", [])` and ran with a half-empty policy if keys were missing. AC-5 makes unknown or missing keys errors.
- **Report bound to its input.** AC-7 (`inputs.sbom_sha256`).
- No T-* trap touches this node directly. The Syft quirks that would corrupt license data (non-SPDX ids in `license.id`) are handled in S01-AC-2.

### Invariant and contradiction disposition (this node)

| Item | Disposition |
|---|---|
| INV-LIC-1 | AC-1, AC-3. DNF satisfiability carried; parser rewritten |
| INV-LIC-2 (unknown is warn only) | **Deliberately dropped.** Replaced by AC-4: unknown fails unless listed with a reason |
| INV-LIC-3 | AC-7 |
| Verified parser defects (empty passes, WITH split, silent repair) | AC-2, AC-3 |
| `GPL-2` mapped to or-later | AC-6, with O07 hand-off |
| Contradictions: none recorded for this component in the study | — |

## Gate

- **S02-AC-1** — The parser yields the DNF in this table, checked by a truth-table test over allowed sets:
  - `MIT` is `[[MIT]]`;
  - `MIT BSD-2-Clause` is `[[MIT,BSD-2-Clause]]`;
  - `|| ( MIT ISC )` is `[[MIT],[ISC]]`;
  - `MIT || ( ISC BSD )` is `[[MIT,ISC],[MIT,BSD]]`;
  - `A OR B AND C` is `[[A],[B,C]]`;
  - nested groups and `( A B )` are handled.

  *Verify:* `tests/fast/test_license_parser.py`. *Tier:* fast.
- **S02-AC-2** — Each of these makes the component `fail` with reason starting `parse-error`: `""`, `"  "`, `|| ( )`, `( )`, `( MIT`, `MIT )`, `|| MIT`, `MIT OR`, `GPL-2.0-only WITH`. None passes. *Verify:* `tests/fast/test_license_parser.py::test_malformed_fails`. *Tier:* fast.
- **S02-AC-3** — `GPL-2.0-only WITH Font-exception-2.0` passes when the base is allowed and the exception is in `allowed_exceptions`. It fails when the exception is not listed, and when the base is not allowed. *Verify:* `tests/fast/test_license_parser.py::test_with_exception`. *Tier:* fast.
- **S02-AC-4** — A component with no license info (missing field, empty list, entry with no id, name or expression) fails with reason `no-license-info`, unless listed in `unlicensed_allow`. An SBOM with zero package components exits 2. *Verify:* `tests/fast/test_license_gate.py::test_unknown_fails`, `::test_empty_sbom`. *Tier:* fast.
- **S02-AC-5** — Policy self-validation, each case exit 2:
  - an `allowed_spdx` entry not in the SPDX enum;
  - an `allowed_other` entry without a reason;
  - a `gentoo_to_spdx` target outside the allowed set;
  - an unknown or missing top-level key;
  - an SPDX enum with fewer than 500 ids;
  - a missing policy file.

  The shipped `license-policy.yaml` passes validation. *Verify:* `tests/fast/test_license_policy.py`. *Tier:* fast.
- **S02-AC-6** — The map sends `GPL-2`, `GPL-3`, `LGPL-2`, `LGPL-2.1`, `LGPL-3` to their `-only` ids and `GPL-2+`, `GPL-3+`, `LGPL-2+`, `LGPL-2.1+`, `LGPL-3+` to `-or-later`. *Verify:* `tests/fast/test_license_policy.py::test_gentoo_map_semantics`. *Tier:* fast.
- **S02-AC-7** — The report validates against `license-report.schema.json`. It records `policy.sha256` equal to the sha256 of the policy file, `inputs.sbom_sha256` equal to the sha256 of the SBOM, and has no `unknown` status. Exit codes are 0, 1, 2 per the table above. *Verify:* `tests/fast/test_license_gate.py::test_report_identity`. *Tier:* fast.
- **S02-AC-8** — A denied license appearing in every alternative fails, and denial beats allow if an id is in both lists. A `||` group passes if one alternative is fully allowed even when another is denied. *Verify:* `tests/fast/test_license_gate.py::test_denied`. *Tier:* fast.
- **S02-AC-9** — The gate over the rc1 SBOM (sha256 `3cfc322a…75887`, fetched by digest by O01) reports zero fails. Every package with no license is listed in `unlicensed_allow` with a reason. The test fails, and does not skip, if the fixture is absent. *Verify:* `tests/slow/test_license_rc1.py`, run by the rc1-lane CI job; no build. *Tier:* slow.
- **S02-AC-10** — On the SBOM of our first ISO the gate exits 0 and the report is stored with the other attestation outputs. *Verify:* the `attest` job step "License gate" in `build.yml`; verdict read by S05. *Tier:* slow.

## RED plan

- The port lands first with `scripts/tests`-style baseline cases run against it: the empty-expression and empty-group cases are recorded as passing today, which is the defect.
- Tester then writes `tests/fast/test_license_{parser,gate,policy}.py`. They fail against the port (empty passes, `WITH` is split, unknown exits 0).
- Truth-table cases for AC-2 are written from the verified-defect list above, so each corresponds to an observed old pass.
- AC-9's fixture is rc1's SBOM from O01's fixture set. If O01 has not landed, AC-9 follows in a later commit; AC-1 to AC-8 are not blocked.

## Risks and open questions

- Making unknown fail may list several rc1 packages (the study does not say how many have no license). AC-9 enumerates them; each needs a decision between "fix the ebuild LICENSE" (R01) and an `unlicensed_allow` entry.
- Multiple entries in a component's `licenses[]` are joined as a conjunction (carried from `extract_license_string`, `check-licenses.py:172-197`). Whether the CycloneDX spec intends AND or OR for repeated `license` entries is not settled here. If Syft emits repeated entries for dual-licensed packages, this over-fails. The rc1 fixture will show. Unknown.
- The corrected GPL map changes SBOM bytes versus rc1; the gate result is unchanged only because both forms are allowed today.
- `allowed_other` carries about 25 entries that nobody has legally reviewed; the old policy comments call them "permissive" without a source. The project owner, not this node, decides whether `nethack` (NGPL), `BEER-WARE` and `CC-BY-SA-*` belong on a disc. No OD exists. This is the weakest part of the policy and should be raised as a new OD if the owner cares.
- No SPEC OD applies.

## Cost

- Slices: 2.
  1. Parser, component status, policy validation, report (AC-1 to AC-8).
  2. rc1 fixture run and policy reconciliation, CI wiring (AC-9, AC-10).
- CI build cycles: 0 for the rc1 lane (AC-9). AC-10 rides the attest job of B06's first ISO (MS1), shared with S01 to S04.
- Money: none.

## Spec defects found

1. **S01 reads S02's policy file, but S02 depends on S01.** S01's `gentoo_to_spdx` and enum handling need `license-policy.yaml` to exist. Proposed order: S01's port slice carries the b9f533b policy file unchanged to `supplychain/policy/license-policy.yaml`, so S01-AC-14 reproduces rc1. S02 then corrects the map (AC-6) and adds the resulting `license.id` changes to S01's `deliberate` list in the same PR. Owner to confirm, since S01 would touch a protected path in its port slice.

S02's ownership of `license-policy.yaml` in a protected path is intended: loosening the license policy should need elevated review.
