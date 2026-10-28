# P02 — release-workflow

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| P | S05, O02, O03, O04, O05, O06 | P03, X01 | MS4 | M |

**Owns:** `.github/workflows/release.yml`, `factory/bin/release-plan`, `factory/bin/release-verify`, `factory/bin/release-notes`, `factory/bin/release-evidence`, `supplychain/policy/release-required.yaml`, `docs/releasing.md`, `tests/fast/release-*.test.*`, `tests/fixtures/release/`.
**Carries from linux-live-iso-factory@b9f533b:** `.github/workflows/release.yml` (tag-to-commit check at `:77-114`, prerelease rule at `:242-271`, digest check at `:136-164`, changelog at `:180-195`), `docs/releasing.md` (versioning scheme, digest-chain trace, operator steps).
**Study refs:** workflows `job.release.publish`, `wf.release`; workflows contradiction "latest pointers copied before boot-test" (`build.yml:495-546` vs `:559`); workflows contradiction "tag builds still push the binpkg cache"; T-attest-entry-workflow, T-prerelease-never-latest, T-recovery-pattern; D-tag-builds-from-source, D-supply-chain-honesty; decisions DEC-build-yml-owns-tag, DEC-prerelease-never-latest, DEC-releases-immutable-tags, DEC-iso-naming; supplychain contradiction "release.yml verifies ISO == summary == SBOM only; `gh attestation verify` is manual"; SPEC §2 principles 5, 7, 8; SPEC §8.

## Purpose
After this node, pushing a `vX.Y.Z[-rcN|-betaN]` tag yields a GitHub release only if the same build passed the whole oracle, the supply-chain gates and attestation for the exact ISO digest, and the release workflow has itself verified that evidence and the Sigstore attestation. The old workflow trusted an S3 round trip and left `gh attestation verify` to a human. This one reads back artifacts of the tag's own Build run, re-checks every link, and publishes nothing else.

## Scope
In:
- `release.yml`: a `workflow_run` consumer of the Build workflow that creates the GitHub release.
- The checks it runs: event gate, tag-to-commit binding, required-evidence completeness, from-source proof, digest chain, `gh attestation verify`, immutability.
- Release-note generation, prerelease flags, asset set, deterministic attestation bundle.
- A `workflow_dispatch` recovery path with dry-run (formalises T-recovery-pattern).
- The `release-evidence` producer script and the list of required checks.

Out:
- The Build workflow, its jobs, and `actions/attest`: B06 and S05. This node asks B06 to host one terminal job (see defect 1).
- Boot modes and doctrine checks that produce the evidence: O01–O06. Gates: S02–S04.
- Writing anything to the `public` store, dashboard rows, "latest" pointers: P03. `release.yml` holds no public-store credentials.
- The status feed for revoked builds: P05.
- First production release (v0.2.0) and the README: X01.

## Design

### Pipeline split (unchanged shape, tighter checks)
```text
tag push ─▶ build.yml (entry, OIDC)
              build ─▶ oracle jobs (17 boot modes + doctrine) ─▶ gates + attest (S05)
                                                         └─▶ evidence job (tag and master runs)
workflow_run completed ─▶ release.yml: plan ─▶ publish
workflow_run completed ─▶ publish.yml (P03)  [after release.yml for tags]
```
`build.yml` owns the tag trigger and has no `workflow_call` (T-attest-entry-workflow, DEC-build-yml-owns-tag). `release.yml` never builds and never signs.

### The evidence job (hosted in build.yml, owned here)
`factory/bin/release-evidence --out release-evidence.json` runs as the last job of `build.yml` (`needs:` every oracle job and the attest job; no `if: always()`, so any failure upstream means no evidence). It uploads artifact `release-evidence`, and, on tag runs, the ISO, `bom.cdx.json`, the attestation directory and `slsa-provenance.json` as artifacts `release-iso` and `release-attestation` with `retention-days: 30`. On tag runs it also does `store put build builds/<version>/<file>` for each, so recovery after the artifacts expire reads the `build` class (SPEC §5: tags kept forever).

`release-evidence.json` (schema 1):
```json
{
  "schema": 1,
  "ref": "refs/tags/v0.2.0",
  "source_sha": "<40 hex>",
  "run_id": 123, "run_attempt": 1,
  "iso_sha256": "<64 hex>",
  "build": {"mode": "from-source", "binpkg_cache_hits": 0},
  "checks": {
    "boot:bios": {"status": "pass", "iso_sha256": "<64 hex>"},
    "doctrine":  {"status": "pass", "iso_sha256": "<64 hex>"},
    "gate:cve":  {"status": "pass", "iso_sha256": "<64 hex>"}
  },
  "attestation": {"overall": "pass"}
}
```
Each oracle job leaves `oracle-result.json` (`mode`, `status`, `iso_sha256`) as an artifact; the evidence job collects them. That record is O01's output format (defect 2). `binpkg_cache_hits` is B01's counter; it is 0 on a tag run (D-tag-builds-from-source).

### Required checks
`supplychain/policy/release-required.yaml` (protected path, SPEC §8) lists every check id that must be `pass` for the ISO digest:
```yaml
schema: 1
checks:
  - boot:bios
  - boot:uefi
  # ... the 17 modes of SPEC §7: bios uefi toram ahci nvme usb virtio nicless nic vga
  #     fbdev-modprobe nat gui stele-acid2 clock-epoch clock-1996 persist
  - doctrine
  - gate:sbom
  - gate:license
  - gate:cve
  - gate:unowned
tag_build:
  mode: from-source
  binpkg_cache_hits: 0
```
`release-verify` fails on a check that is missing, not `pass`, or recorded for a different digest. Adding a boot mode without adding it here fails AC-6. Reproducibility (B07) is not a release gate; X01 reports its status in the notes.

### `factory/bin/release-plan`
Pure, no network. Two modes.
- `release-plan TAG` prints `key=value` lines: `tag`, `version` (tag without `v`, the ISO and `/etc/monolith-release` form), `prerelease` (`true|false`), `flags` (`--prerelease --latest=false` or empty), `title` (`The Monolith vX.Y.Z...`). Exit 2 on a tag that does not match `^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(rc|beta)[1-9][0-9]*)?$`. `v1.2.3-foo` triggers Build (`v*.*.*`) but is refused here, loudly, and nothing is published.
- `release-plan --event FILE --repo OWNER/NAME --tag-sha SHA` takes the `workflow_run` payload and decides: `conclusion == success`, `event == push`, `path == .github/workflows/build.yml`, `head_repository.full_name == --repo` (blocks fork runs), `head_branch` is a valid tag, and `--tag-sha` (resolved by the workflow from the fetched tag) equals `head_sha`. Rejected: the old `startsWith(head_branch, 'v')`, which accepts a branch named `vanilla`.

### `factory/bin/release-verify`
`release-verify --dir DIR --ref REF --repo OWNER/NAME [--sha SHA]` (`REF` is `refs/tags/<tag>` for releases or `refs/heads/<branch>` for CI rows; P03's publisher uses the same script) where `DIR` holds the downloaded ISO, `release-evidence.json`, `attestation-summary.json`, `bom.cdx.json`, `slsa-provenance.json`. In order:
1. Evidence completeness against `release-required.yaml` and `source_sha == SHA` (the tag commit, or the run's head commit). Exit 10 (missing/failing/foreign-digest check).
2. Build mode: `from-source` and zero cache hits when `REF` is a tag. Exit 14.
3. Digest chain: `sha256(ISO) == evidence.iso_sha256 == summary.iso_sha256 == bom.metadata.component.hashes[0].content == subject digest`. Exit 12. The checker is S05's digest-chain function, imported, not copied (see defect 3).
4. `gh attestation verify ISO --repo R --signer-workflow R/.github/workflows/build.yml --source-ref REF --predicate-type https://slsa.dev/provenance/v1 --format json`; the subject digest in its output must equal the ISO digest. Exit 13. `--owner` is never used (it accepts any repo of the owner). The `gh` binary is replaceable via `GH_BIN` so tests stub it.
Exit codes: 0 ok, 2 usage, 10, 11 (reserved: malformed input), 12, 13, 14.

### `release.yml`
Triggers: `workflow_run` (`workflows: [Build]`, `types: [completed]`) and `workflow_dispatch` (inputs `build_run_id`, required; `dry_run`, default `true`). Top-level `permissions: {}`; job permissions `contents: write`, `actions: read`. `concurrency: release-<head_branch>`, `cancel-in-progress: false`. Every action pinned by SHA (F01 lint); only `actions/checkout` and `actions/download-artifact`.

Jobs:
1. `plan`: checks out the default branch (the trusted tools run from master, as `workflow_run` does anyway, SPEC §8), fetches tags, runs `release-plan --event`. If the gate fails the job fails for a tag-like `head_branch`, and exits success-skipped for ordinary master builds (otherwise every master Build shows a red Release run).
2. `publish` (`needs: plan`): downloads `release-iso`, `release-attestation`, `release-evidence` from `run-id` (falls back to `store get build builds/<version>/...` if expired), runs `release-verify`, builds `SHA256SUMS`, the attestation bundle and notes, then:
   - If the release already exists: compare every asset digest with the local file; equal means success without writing; any difference fails. `--clobber` appears nowhere (DEC-releases-immutable-tags).
   - Otherwise `gh release create TAG $flags --verify-tag --title ... --notes-file ... <assets>`. `$flags` comes only from `release-plan` output.
   - With `dry_run: true` everything runs except the create.
   - Last step, on a real publish only: upload artifact `release-handoff` (`tag.txt`, `version.txt`, release URL). P03's publisher reads it, because a `Release` run's `head_branch` is the default branch, not the tag.

Assets: `themonolith-<version>.iso`, `SHA256SUMS` (covers every other asset), `bom.cdx.json`, `attestation-<version>.tar` (all files of the attestation directory in a deterministic tar: sorted names, `--mtime=@0`, numeric owner 0, `--format=ustar`), `release-evidence.json`. The tar is what P03's publisher unpacks; users get one file to inspect.

Release notes (`release-notes`, deterministic, golden-tested): kernel and BusyBox versions from `pins/versions.lock` at the tag (`git show TAG:pins/versions.lock`), a Verify block using `--repo $GITHUB_REPOSITORY` and `--signer-workflow`, the ISO digest, the dashboard link `${PUBLIC_BASE_URL}/#/build/<version>` (pin, P01), and the commit log since the previous tag. If the tag's tree has `docs/releases/<version>.md`, its text is appended (X01 uses this for `0.2.0`). The owner and repo are never literals.

Recovery (T-recovery-pattern): Build green, release failed: dispatch `release.yml` with the Build run id and `dry_run: false`. It runs the same code path as the automatic trigger, including the verification the old manual recipe did by hand.

### Rejected alternatives
- Attest inside `release.yml` by calling Build via `workflow_call`: Sigstore binds to the entry workflow (T-attest-entry-workflow).
- Download the ISO from the public host: reintroduces a storage hop between attested and published bytes. Artifacts of the attested run are the source.
- `gh release create --generate-notes`: not reproducible and omits the digest block.

## Traps and doctrines preserved
- **T-attest-entry-workflow:** a signer split between workflows fails only on a real tag. AC-3 asserts the workflow shape statically; AC-15 exercises a real tag.
- **T-prerelease-never-latest:** AC-1 and AC-2.
- **T-recovery-pattern:** AC-10, AC-14.
- **D-tag-builds-from-source:** AC-7. The old workflow only skipped the pull; tag builds still pushed cache (workflows contradiction), so the check is on the recorded hit count.
- **D-supply-chain-honesty:** AC-8, AC-9 (the old release workflow never verified the attestation).
- **Principle 7 (publish last):** the old Build copied "latest" ISO/squashfs/vmlinuz/initrd to S3 in the build job before boot-test ran (`build.yml:495-546`). AC-5 requires passing oracle evidence; AC-13 forbids store credentials here; AC-16 requires the evidence job to depend on every oracle job.
- **DEC-releases-immutable-tags:** AC-10.
- **DEC-iso-naming:** ISO name `themonolith-<version>.iso` with no `v`, asserted in AC-1/AC-12.
- **T-workflow-push-needs-pat:** `release.yml` is a workflow file; the owner pushes it (Risks).

## Gate
- **P02-AC-1** — `release-plan TAG` maps `v0.2.0`, `v0.2.0-rc1`, `v0.2.0-beta3` to correct `version`, `prerelease`, `flags`, and exits 2 for `v0.2`, `v0.2.0-rc`, `v0.2.0-rc0`, `v0.2.0-foo`, `v01.2.3`, `v0.2.0-rc1+x`, `0.2.0`, and branch-like names. *Verify:* `tests/fast/release-plan.test.sh`. *Tier:* fast.
- **P02-AC-2** — Every prerelease tag yields exactly `--prerelease --latest=false`; a final tag yields neither; `release.yml` contains `gh release create` only with `flags` taken from `release-plan` output. *Verify:* `tests/fast/release-flags.test.sh` (table test plus grep of the workflow). *Tier:* fast.
- **P02-AC-3** — `build.yml` has `push.tags` for `v*.*.*`, has no `workflow_call`, and contains the `actions/attest` step in a job of its own; `release.yml` has `workflow_run` on `Build`, no `uses:` of a local workflow and no attest step. *Verify:* `tests/fast/release-workflow-shape.test.py` (PyYAML parse). *Tier:* fast.
- **P02-AC-4** — `release-plan --event` rejects payloads with a non-success conclusion, `event != push`, a different workflow path, a foreign `head_repository`, a non-tag `head_branch`, a missing tag, or a tag whose commit differs from `head_sha`; it accepts only a valid payload. *Verify:* `tests/fast/release-event-gate.test.sh` with payload fixtures in `tests/fixtures/release/events/`. *Tier:* fast.
- **P02-AC-5** — `release-verify` exits 10 when any check from `release-required.yaml` is missing, `fail`, or recorded for another digest, parametrised over every listed check. *Verify:* `tests/fast/release-evidence-complete.test.py`. *Tier:* fast.
- **P02-AC-6** — `release-required.yaml` contains exactly the 17 boot modes of SPEC §7, `doctrine`, and the four gates; adding a mode to the oracle without adding it here fails. *Verify:* `tests/fast/release-required.test.py` (compares to the oracle's mode list). *Tier:* fast.
- **P02-AC-7** — On a tag, `release-verify` exits 14 when `build.mode != from-source` or `binpkg_cache_hits > 0`; the same evidence passes on a non-tag ref. *Verify:* `tests/fast/release-from-source.test.sh`. *Tier:* fast.
- **P02-AC-8** — `release-verify` exits 12 for each single broken link of the digest chain (ISO vs evidence, vs summary, vs SBOM hash, vs attestation subject). *Verify:* `tests/fast/release-digest-chain.test.py` (five fixtures, one per link). *Tier:* fast.
- **P02-AC-9** — `release-verify` calls `gh attestation verify` with `--repo`, `--signer-workflow`, `--source-ref refs/tags/<tag>` and `--predicate-type`, never with `--owner`, and exits 13 when the call fails or its subject differs. *Verify:* `tests/fast/release-attest-verify.test.sh` (`GH_BIN` stub records its arguments). *Tier:* fast.
- **P02-AC-10** — Re-running the publish step against an existing release with identical assets exits 0 and writes nothing; with any differing asset it fails; `--clobber` occurs nowhere in the repository. *Verify:* `tests/fast/release-immutable.test.sh` (stub `gh`, plus `grep -r -- --clobber`). *Tier:* fast.
- **P02-AC-11** — `release-notes` output equals the golden file for fixed inputs, contains `--repo` and `--signer-workflow` verification, the ISO digest and the dashboard link built from `PUBLIC_BASE_URL`, and contains no `amazonaws`, no `--owner` and no literal owner name. *Verify:* `tests/fast/release-notes.test.sh` against `tests/fixtures/release/notes.golden.md`. *Tier:* fast.
- **P02-AC-12** — `SHA256SUMS` lists every other asset, `sha256sum -c` passes, and the attestation tar is byte-identical across two runs on the same inputs. *Verify:* `tests/fast/release-assets.test.sh`. *Tier:* fast.
- **P02-AC-13** — `release.yml` references no `STORE_PUBLIC_*` secret, no `store set`/`store put public`, and its permissions are exactly `contents: write` and `actions: read`; every `uses:` is pinned to a 40-hex SHA. *Verify:* `tests/fast/release-least-privilege.test.py`. *Tier:* fast.
- **P02-AC-14** — A dispatch with `dry_run: true` on a green master Build run completes: it downloads that run's artifacts, `release-verify` passes including the real `gh attestation verify`, and no release is created. *Verify:* CI run of `release.yml` dispatched manually with a master `build_run_id`, link in the PR. *Tier:* slow.
- **P02-AC-15** — Pushing `v0.2.0-rc1` produces a GitHub release that is a prerelease and not Latest, with all five assets, a `release-handoff` artifact on the Release run, and `gh attestation verify --repo` on the ISO downloaded from the release passes. This is the MS4 evidence. *Verify:* Build and Release runs for the tag; `gh release view v0.2.0-rc1 --json isPrerelease,assets` and the verify command. *Tier:* slow.
- **P02-AC-16** — In `build.yml` the `evidence` job's `needs` contains every oracle job and the attest job, and has no `if:` that lets it run after a failure. *Verify:* `tests/fast/release-evidence-needs.test.py`. *Tier:* fast.

## RED plan
The tester writes AC-1, 2, 4, 5, 7, 8, 9, 10 as shell/Python tests over fixtures first. They fail because `factory/bin/release-plan` and `release-verify` do not exist. AC-3 and AC-16 parse the workflows from B06/S05; they are RED only if those workflows lack the shape, so the tester also adds a fixture of the *old* `release.yml` (with `startsWith(head_branch,'v')` and `workflow_call` variants) that the tests must reject. AC-11 and AC-12 need golden files written before the implementation. Slow ACs (14, 15) have no RED; they are the GREEN evidence.

## Risks and open questions
- The tag run is the only real exercise of the entry-workflow rule (T-attest-entry-workflow). AC-14 reduces risk because a master Build is also attested by `build.yml`, but only AC-15 proves the tag path. Budget one failed rc.
- `workflow_run` workflows execute `release.yml` from the default branch, not the tag. A release workflow change takes effect for the next tag; document in `docs/releasing.md`.
- Artifact retention: if recovery is attempted after 30 days, the `build` store class fallback is used. If I01 is not yet populated for tags, recovery fails; AC-14 does not cover that path.
- Workflow changes need the owner's PAT (T-workflow-push-needs-pat). The agent hands over a patch for `release.yml` and for the `evidence` job in `build.yml`.
- Required-check drift: any new boot mode must be added to `release-required.yaml` (protected path, human review). Intended friction.
- Does a `gh` version difference change `--format json` output of `gh attestation verify`? Unknown; the pinned `gh` version comes from I05 and the stub test must be refreshed on a bump.

## Cost
- Slices: 3 (plan and verify scripts with fixtures; notes, assets, workflow; evidence job and docs). 16 ACs.
- CI build cycles: 1 full tag build for `v0.2.0-rc1` (30–60 min build plus the oracle), plus 1 contingency for a first-try failure. AC-14 needs one existing green master Build run; it adds no build.
- Money: none beyond Actions minutes.

## Spec defects found
1. **No node owns the terminal evidence job or the `build` class write for tag runs.** B06 says "no publishing", S05 attests, but nothing assembles the evidence or stores tag outputs in `build`. This node owns the script and asks B06 to host the job (`needs:` all oracle jobs and attest).
2. **O01 defines no result record.** Required evidence needs a per-mode `oracle-result.json` (`mode`, `status`, `iso_sha256`). O01 should own the format.
3. **S05's digest-chain checker has no named interface.** P02 assumes an importable function (path to be fixed by S05, e.g. `supplychain/lib/digest_chain.py`). If S05 only exposes a CLI, P02 calls that instead.
4. **SPEC §8 protected paths** should include `supplychain/policy/release-required.yaml` explicitly (it is under `supplychain/policy/`, so already covered) and the publisher workflows (see P01 defect 2).
