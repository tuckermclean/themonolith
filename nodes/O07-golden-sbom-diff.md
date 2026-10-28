# O07 — golden-sbom-diff

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| O | S01, B04, I05 | X01 | MS3 | M |

**Owns:** `oracle/sbom_diff/` (`diff.py` CLI, `normalize.py`, `policy.py`, `report.py`, `version.py`), `oracle/golden/sbom/golden.yaml`, `oracle/golden/sbom/rc1.bom.cdx.json` (committed copy of the pinned asset), `oracle/golden/sbom/expected-differences.yaml`, `oracle/golden/rootfs/rc1.paths.txt`, `oracle/bin/fetch-golden-sbom`, `oracle/bin/extract-golden-paths`, `oracle/schemas/sbom-expected.schema.json`, `oracle/schemas/sbom-diff-report.schema.json`, `.github/workflows/oracle-sbom-diff.yml` (reusable), `tests/fast/test_sbom_diff_*.py`.
**Carries from linux-live-iso-factory@b9f533b:** nothing from code. The golden input is the published asset `bom.cdx.json` of release `v0.1.0-rc1` in `tuckermclean/linux-live-iso-factory`, produced by `scripts/enrich-sbom.py` (structure read at lines 480-580, 595-760, 795-910).
**Study refs:** supplychain.yaml `script.enrich-sbom` (output contract, lines 242-313), `release.yml:128-170,269-271` (release assets are the ISO, `SHA256SUMS`, `bom.cdx.json`); OD-6 (snapshot `gentoo-20260811` lost; rc1 epoch); doctrine.yaml D-two-epoch-pin-model, D-supply-chain-honesty, D-no-readding-removed-things; SPEC §7 "Equivalence", §6.

## Purpose
After this node "the same product as rc1" is a mechanical statement. The new SBOM is diffed against the one the predecessor shipped, and CI passes only when every added or removed package and every added or removed rootfs file is explained with a reason in a reviewed file. The new repository starts from a new `BUILD_EPOCH`, so most package versions will differ; the diff is therefore policy-aware: version movement under an epoch bump is summarized by rule, while a change in the package set is never silent.

## Scope
In:
- Pinning, fetching and committing the rc1 SBOM; a one-time extraction of the rc1 rootfs path list.
- The normaliser, the diff, the expected-differences format and its validation, the report, the CI job.
Out:
- Producing the SBOM (syft, enrichment, schema validation): S01. Licenses, CVEs, unowned files: S02-S04.
- The file manifest format B04 writes (this node consumes it as specified below).
- Choosing and bumping `BUILD_EPOCH` (I05, M01); the lost `gentoo-20260811` snapshot (OD-6).
- Verifying rc1's attestation (S05, X01 README steps).

## Design

### Golden pin and fetch
`oracle/golden/sbom/golden.yaml`:
```yaml
id: rc1
source:
  repo: tuckermclean/linux-live-iso-factory
  tag: v0.1.0-rc1
  asset: bom.cdx.json
  url: https://github.com/tuckermclean/linux-live-iso-factory/releases/download/v0.1.0-rc1/bom.cdx.json
  size: 271592
  sha256: "<64 hex>"            # computed on first fetch; unknown at spec time
committed_as: oracle/golden/sbom/rc1.bom.cdx.json
product:
  iso_sha256: "<from metadata.component.hashes[0]>"   # cross-check against rc1 SHA256SUMS
  build_epoch: 20260811          # per OD-6 text; confirm from the SBOM on first fetch
  spec_version: "1.6"            # confirm
paths:
  file: oracle/golden/rootfs/rc1.paths.txt
  sha256: "<64 hex>"
  derived_from_iso_sha256: "<same as product.iso_sha256>"
```
`oracle/bin/fetch-golden-sbom` runs `gh release download v0.1.0-rc1 --repo tuckermclean/linux-live-iso-factory --pattern bom.cdx.json` (or `curl -fL` on `url`), refuses a size other than 271,592 bytes, computes the sha256, and writes the file and the pin only when invoked with `--record` on a developer machine; without `--record` it verifies an existing copy against the pin and exits non-zero on mismatch. It also downloads `SHA256SUMS` from the same release and checks that the SBOM line matches and that the ISO hash in `metadata.component.hashes[0].content` equals the ISO line, which ties the SBOM to the attested ISO digest (`release.yml:157`).

Decision: the asset is committed in the repository (about 270 KB) and CI never fetches it. Reasons: SPEC principle 2 (inputs pinned and mirrored under our control) and the predecessor's repository will be archived at X01, and its account history shows that third-party storage disappears. Rejected: fetching at CI time from GitHub releases (an external dependency on the archived repository, network failure becomes a false red); mirroring it only in the store (a 270 KB file needs no store round trip and a fast-tier test can read it). The fast tier verifies the committed file's sha256 against `golden.yaml`.

### Rootfs path list (the "files" half)
`bom.cdx.json` carries no installed-file list: the enrichment drops `type: file` components (`enrich-sbom.py:582`) and the release assets are the ISO, `SHA256SUMS` and `bom.cdx.json` only (`release.yml:269-271`). A file-level comparison therefore needs rc1's rootfs. `oracle/bin/extract-golden-paths` downloads the rc1 ISO once (size unknown; expect hundreds of MB), checks its sha256 against `product.iso_sha256`, extracts the squashfs with `unsquashfs -ll`, and writes a sorted list of `<path>\t<type>` lines (no sizes, no owners: rc1 recorded no owners per file). The result is committed as `rc1.paths.txt` with its pin. This runs on a developer machine once, not in CI. Rejected: diffing against the live rc1 ISO in CI (a large external download per run).

The new side is B04's manifest, "every file with its owning package". The expected format, to be confirmed against B04's spec: TSV, first column the path relative to `/`, second the owning package `category/name`, extra columns ignored.

### Normalisation (`normalize.py`)
Both SBOMs are reduced to records. Component identity:
- Package key: the purl path without version and qualifiers when the purl starts with `pkg:ebuild/` (for example `pkg:ebuild/sys-apps/busybox`), else the lower-cased `name`. `add_purl_qualifiers` (`enrich-sbom.py:266`) appends `?arch=...&distro=gentoo`; qualifiers are stripped. If the exact purl shape of syft's portage cataloger differs from this, the normaliser's unit tests use the real rc1 file and are authoritative; this spec states the intent only.
- A key may carry several versions (slots); the record holds the sorted set.
- `source`: `builder` if the component has property `syft:monolith:source` = `builder` (propagated host-VDB components, `enrich-sbom.py:795-830`; bom-ref `propagated-<name>-<version>`), else `target`.
- Compared attributes: key, versions, `type`, normalised license set (ids and expression tokens), `cpe` (version part masked), `source`.
Excluded from the comparison: `serialNumber`, `metadata.timestamp`, `metadata.component` name/version/bom-ref/hashes (checked only for `type: operating-system` and a 64-hex hash present), tool versions, all `bom-ref` values.
- World set: from `dependencies` the entry whose `ref` is `metadata.component.bom-ref`, `dependsOn` resolved to package keys. This is the set of world atoms (`enrich-sbom.py:737-750`).
- Formulation: `file` components are classified by role from the name prefix (`linux-` kernel, `busybox-` busybox); `data` components `versions.lock` by name. Hashes are not compared.
Both CycloneDX 1.6 and 1.7 documents are accepted (S01 emits 1.6/1.7).

### Diff and policy (`policy.py`)
The diff reports, per class `target` and `builder`:

| Category | Rule |
|---|---|
| `added` package key | Must appear in `expected-differences.yaml` `packages.added` with a reason, else FAIL. |
| `removed` package key | Must appear in `packages.removed` with a reason, else FAIL. |
| version change | By `version_policy` (below). |
| license change | If the version also changed, informational; otherwise must be listed under `packages.changed`. |
| cpe change | Same as license. |
| source change (`target` <-> `builder`) | Must be listed under `packages.changed`. |
| world set | Keys added to or removed from `dependsOn` of the root must be listed under `world.added|removed`, else FAIL. |
| formulation | Role set must be equal; each role's file name must be `<prefix><version of that package in the new SBOM>` (internal consistency, not equality with rc1). |
| files added/removed | See below. |

`version_policy` (ordered, first match wins), in `expected-differences.yaml`:
```yaml
version_policy:
  - {match: {key_glob: "pkg:ebuild/*/monolith-*"}, rule: exact}        # overlay packages we own
  - {match: {key: "pkg:ebuild/sys-kernel/monolith-kernel"}, rule: exact}
  - {match: {key_glob: "*"}, rule: follow-epoch}
```
- `exact`: new version set must equal rc1's, unless the key appears under `version_exceptions` with `from`, `to` and `reason` (an overlay revbump is not visible: versions are stripped of `-rN`).
- `follow-epoch`: any change is accepted *iff* the new run's `BUILD_EPOCH` (read from `pins/pins.yaml` by the CI job and passed as `--build-epoch`) differs from `golden.yaml: product.build_epoch`; if the epochs are equal, the rule degrades to `exact`. This is the "same package set, versions may move inside the epoch-bump PR" policy. It does not list versions by hand.
- Downgrade guard: a change to a lower version under `follow-epoch` is reported and fails unless listed under `downgrades` with a reason (a downgrade across an epoch bump is unusual and worth a sentence). Versions compare with a Gentoo-style comparator (`version.py`: dotted numbers, letter suffix, `_alpha|_beta|_pre|_rc|_p`); incomparable pairs are reported as incomparable and treated as changes, not downgrades.
- Reporting only, not failing: counts of unchanged / upgraded / major-changed (first numeric component differs) / downgraded; the full list of version moves appears in `sbom-diff-report.json` and the job summary, sorted by key. A reviewer reads the summary; nobody lists 90 versions in YAML.

Files. Both path sets are normalised first by `path_normalizers` (for example `{glob: "lib/modules/*", regex: "^lib/modules/[^/]+", replace: "lib/modules/<KVER>"}` and a perl version directory rule) so version-named directories do not appear as additions and removals. After normalisation:
- A file added in the new manifest is explained if its owning package is an explained added package (no per-file entry needed), or matches a `files.added` glob with a reason.
- A removed file (rc1 has no owner) must match a `files.removed` glob with a reason.
Every glob entry must match at least one path (otherwise it is stale and FAILS).

Staleness and strictness: an expected-differences entry that matches nothing (a listed package that did not change) FAILS; the file must stay honest and shrink as the rebuild converges. Every entry needs `reason` (at least 15 characters) and one of `issue` or `pr` or `decision` (for example `D-no-readding-removed-things`, `OD-2`).

### Expected-differences format
`oracle/golden/sbom/expected-differences.yaml`:
```yaml
version: 1
golden: rc1
version_policy: [...]            # as above
version_exceptions:
  - {key: "pkg:ebuild/dev-lang/perl", from: ["5.40.1"], to: ["5.40.2"], reason: "..."}
downgrades:
  - {key: "...", from: [...], to: [...], reason: "...", issue: "..."}
packages:
  added:   [{key: "pkg:ebuild/app-misc/foo", source: target, reason: "...", issue: "#12"}]
  removed: [{key: "pkg:ebuild/net-misc/bar", source: target, reason: "...", decision: OD-2}]
  changed: [{key: "...", what: [license, cpe, source], reason: "..."}]
world:
  added: [...]
  removed: [...]
files:
  added:   [{glob: "usr/share/doc/foo/**", reason: "..."}]
  removed: [{glob: "usr/share/doc/old/**", reason: "..."}]
path_normalizers: [...]
```
`oracle/schemas/sbom-expected.schema.json` validates it in the fast tier.

### CLI
```
python3 -I oracle/sbom_diff/diff.py \
  --golden oracle/golden/sbom/golden.yaml \
  --new bom.cdx.json --build-epoch 20260901 \
  --manifest rootfs-manifest.tsv \
  --expected oracle/golden/sbom/expected-differences.yaml \
  --report sbom-diff-report.json [--markdown $GITHUB_STEP_SUMMARY]
```
Exit 0: no unexplained differences and no stale entries. 1: unexplained difference or stale entry. 2: input missing, empty, malformed, pin mismatch, or golden file hash different from `golden.yaml`. Missing `--manifest` is exit 2, not a skip. The first run against the new ISO has an empty expected file and fails with a complete list: that failure *is* the work list.

### CI
`oracle-sbom-diff.yml` (reusable) takes the SBOM and manifest artifacts from the B06 pipeline run and `BUILD_EPOCH` from `pins/pins.yaml`, runs the CLI, uploads the report, writes the summary. The hook into the pipeline is the same one-line `uses:` addition as O02's (see O02 Spec defects). `expected-differences.yaml` is a reviewed file; changes to it follow the trusted-base rule (SPEC §8): the job reads the file from the PR's base revision when the PR only touches other paths, and from the PR head when the PR touches `oracle/golden/` (a human reviews that diff).

## Traps and doctrines preserved
- **D-two-epoch-pin-model:** a new `BUILD_EPOCH` moves versions; `TOOLCHAIN_EPOCH` moves builder components. Prevented from producing noise by the `follow-epoch` rule (O07-AC-4) while exact-pinned classes stay exact (O07-AC-3).
- **D-no-readding-removed-things:** a deliberately removed package returning shows as an addition. Prevented by O07-AC-5 (every added package needs a reason; the denylist check itself is R02's).
- **D-supply-chain-honesty:** the golden must be exactly what rc1 shipped. Prevented by O07-AC-1 (pinned size and sha256, tie to the attested ISO digest) and O07-AC-2.
- **D-state-and-no-hidden-stderr:** a diff that skips on missing input would pass vacuously. Prevented by O07-AC-8 (exit 2 on any missing input) and O07-AC-6 (stale expected entries fail).
- **D-hand-authored-rootfs-files-owned:** the files half relies on B04's ownership manifest; added files owned by an explained package need no entry (O07-AC-7).

## Gate
- **O07-AC-1** — The rc1 SBOM is committed at `oracle/golden/sbom/rc1.bom.cdx.json`, is 271,592 bytes, its sha256 equals `golden.yaml: source.sha256`, and `product.iso_sha256` equals `metadata.component.hashes[0].content` of that file. *Verify:* `tests/fast/test_sbom_diff_golden.py::test_pin_matches_file`. *Tier:* fast.
- **O07-AC-2** — `oracle/bin/fetch-golden-sbom` (without `--record`) exits non-zero on a size mismatch, a sha256 mismatch, a missing file, or an SBOM whose ISO hash differs from the `SHA256SUMS` ISO line; with `--record` it writes the pin. *Verify:* `tests/fast/test_sbom_diff_golden.py::test_fetch_script_verifies` using local `file://` fixtures and a stub `gh` on `PATH` (no network in the fast tier). *Tier:* fast.
- **O07-AC-3** — `exact` classes (overlay packages `pkg:ebuild/*/monolith-*` and `monolith-kernel`) fail when the version set differs from rc1 and is not under `version_exceptions`. *Verify:* `tests/fast/test_sbom_diff_policy.py::test_exact_class`. *Tier:* fast.
- **O07-AC-4** — With a differing `--build-epoch`, version changes of other packages are accepted and summarized (counts and sorted list in the report); with an equal epoch the same changes fail. A downgrade fails unless listed under `downgrades`. *Verify:* `tests/fast/test_sbom_diff_policy.py::test_follow_epoch`, `::test_equal_epoch_is_exact`, `::test_downgrade_requires_reason`. *Tier:* fast.
- **O07-AC-5** — An added or removed package key, a world-set change, or a source change not listed in `expected-differences.yaml` fails the run; listed with a reason it passes. *Verify:* `tests/fast/test_sbom_diff_policy.py::test_unexplained_package`, `::test_world_set`. *Tier:* fast.
- **O07-AC-6** — Stale expected entries fail: a listed package that did not change, a file glob matching no path, a duplicate entry, an entry without `reason` of 15+ characters or without `issue`/`pr`/`decision`. *Verify:* `tests/fast/test_sbom_diff_policy.py::test_stale_entries`, and schema validation `::test_expected_schema`. *Tier:* fast.
- **O07-AC-7** — File differences: with `path_normalizers` applied, an added path owned by an explained added package passes without a per-file entry, an unowned added path needs a `files.added` glob, and every removed path needs a `files.removed` glob; an unexplained path fails and is listed. *Verify:* `tests/fast/test_sbom_diff_files.py`. *Tier:* fast.
- **O07-AC-8** — A missing, empty or unparsable new SBOM, manifest, expected file or golden exits 2 and never produces a pass verdict; a golden whose hash differs from `golden.yaml` exits 2. *Verify:* `tests/fast/test_sbom_diff_cli.py`. *Tier:* fast.
- **O07-AC-9** — The normaliser reads the real committed rc1 SBOM: it produces more than 50 package records, a non-empty world set, a `target`/`builder` split, and every record has a key; two CycloneDX versions (1.6 and 1.7 synthetic variants) normalise identically. *Verify:* `tests/fast/test_sbom_diff_normalize.py`. *Tier:* fast.
- **O07-AC-10** — The report lists, for the run, counts per category, the full version-move table, every explained and unexplained difference, the golden id and sha256, the build epoch pair, and the exit verdict, and validates against `oracle/schemas/sbom-diff-report.schema.json`. *Verify:* `tests/fast/test_sbom_diff_report.py`. *Tier:* fast.
- **O07-AC-11** — `oracle/golden/rootfs/rc1.paths.txt` exists with a pinned sha256 and its `derived_from_iso_sha256` equals the rc1 ISO digest; `extract-golden-paths` verifies the ISO digest before extracting. *Verify:* `tests/fast/test_sbom_diff_golden.py::test_paths_pin`; `::test_extract_script_checks_iso_hash` (stub ISO, stub `unsquashfs`). *Tier:* fast.
- **O07-AC-12** — On the B06/S01 output for the first parity candidate, the job exits 0 with a committed `expected-differences.yaml` in which every entry has a reason, and `$GITHUB_STEP_SUMMARY` shows the version-move table. *Verify:* CI job `oracle-sbom-diff / diff`. *Tier:* slow.

## RED plan
Tester commits: synthetic mini-SBOM builders in `tests/fast/_sbomgen.py` (components with purls, builder-propagated components, root `dependsOn`, formulation files); `test_sbom_diff_policy.py` (exact, follow-epoch, equal epoch, downgrade, unexplained, stale), `test_sbom_diff_files.py`, `test_sbom_diff_cli.py`, `test_sbom_diff_report.py`, `test_sbom_diff_golden.py` (golden file and pin absent, so AC-1 fails until the first slice fetches it). The fetch of the real asset needs network, which the fast tier lacks; the implementer performs it once outside CI, commits the file, then AC-1 and AC-9 go green.

## Risks and open questions
- Hardest: the exact structure of the rc1 SBOM was inferred from `enrich-sbom.py` and not read. The purl shape, whether slot-versioned packages repeat keys, the `dependencies` layout and whether the rc1 file is CycloneDX 1.6 or 1.7 must be confirmed on the first fetch; the normaliser tests run on the real file and take precedence over this document.
- rc1's `BUILD_EPOCH` is not stated in the study; `20260811` comes from OD-6's snapshot name. If rc1 and the first new build share an epoch (OD-6 recovers the snapshot), the `follow-epoch` rule degrades to `exact` and the diff becomes a strict reproducibility statement, which is a better outcome.
- The path list requires downloading the rc1 ISO once; its size and continued availability on the archived repository are unknown. If it is unavailable, the files half degrades to the SBOM-only diff and the files AC is deferred with an owner decision.
- B04's manifest format is not yet specified; the TSV assumption above must be reconciled.
- Overlay revbumps are invisible in the SBOM (versions strip `-rN`); a changed overlay package at the same `PV` is not detected by this node (R03's revbump gate covers it).
- The first run will produce a long expected-differences file; the risk is rubber-stamping it. The staleness rule and the reason requirement are the mitigation; review burden falls on the human merger.

## Cost
Three agent slices: (1) golden fetch, pin, normaliser against the real file; (2) policy engine, expected format, files half; (3) CI job and the first reviewed expected-differences file. One network step by a developer (SBOM about 270 KB, rc1 ISO once, size unknown). One or two CI cycles on a B06 run plus S01 output. Storage: about 300 KB committed. No paid services.

## Spec defects found
- graph.yaml O07 deps `[S01]` omit B04: the file half needs B04's per-file ownership manifest. Add B04 (S01 already depends on it, so the hard dependency is transitive, but the format contract is not).
- SPEC §7 says every SBOM difference "is listed with a reason"; with a new `BUILD_EPOCH` that is impractical for versions. This spec implements "listed" for set changes and "policy-summarized" for version movement, and needs SPEC §7 to say so.
- SPEC §7 and graph.yaml speak of files, but `bom.cdx.json` has none; the file-level equivalence needs the one-time rc1 ISO extraction above, which is not in any node's scope.
- graph.yaml has no edge from O07 to I05: `BUILD_EPOCH` for the policy comes from `pins/pins.yaml`.
