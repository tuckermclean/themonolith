# O07 — golden-sbom-diff

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| O | S01, B06, I05 | X01 | MS4 | M |

**Owns:** `oracle/sbom_diff/` (`diff.py` CLI, `normalize.py`, `policy.py`, `report.py`, `version.py`), `oracle/golden/sbom/golden.yaml`, `oracle/golden/sbom/rc1.records.json` (normalised records derived from the rc1 SBOM fixture; the SBOM itself is never committed, SPEC §7), `oracle/golden/sbom/expected-differences.yaml`, `oracle/golden/rootfs/rc1.paths.txt` (derived from the rc1 squashfs), `oracle/bin/derive-golden-sbom`, `oracle/bin/extract-golden-paths`, `oracle/schemas/sbom-expected.schema.json`, `oracle/schemas/sbom-diff-report.schema.json`, `.github/workflows/oracle-sbom-diff.yml` (reusable), `tests/fast/test_sbom_diff_*.py`.
**Carries from linux-live-iso-factory@b9f533b:** nothing from code. The golden input is the rc1 fixture `bom.cdx.json` (sha256 `3cfc322a0e105638452baa6900552769a6ad5bfbf3be190a9808ac98ca575887`, fetched by O01's `make fixtures-rc1`), produced by `scripts/enrich-sbom.py` (structure read at lines 480-580, 595-760, 795-910).
**Study refs:** supplychain.yaml `script.enrich-sbom` (output contract, lines 242-313), `release.yml:128-170,269-271` (release assets are the ISO, `SHA256SUMS`, `bom.cdx.json`); OD-6 (first tree = rc1's tree recovered from gentoo-mirror; rc1 epoch `20260811`); doctrine.yaml D-two-epoch-pin-model, D-supply-chain-honesty, D-no-readding-removed-things; SPEC §7 "Equivalence", §6.

## Purpose
After this node "the same product as rc1" is a mechanical statement. The new SBOM is diffed against the one the predecessor shipped, and CI passes only when every added or removed package and every added or removed rootfs file is explained with a reason in a reviewed file. The first build pins rc1's own tree (OD-6 default), so the expected diff is small and explainable line by line: the fixes and nothing else. The diff stays policy-aware for the day M01 moves the tree and `BUILD_EPOCH` changes: version movement under an epoch bump is then summarized by rule, while a change in the package set is never silent. O07 is a parallel node (not on the critical path to MS2); it is the check behind milestone MS4, oracle-parity.

## Scope
In:
- Deriving the golden records from the rc1 SBOM fixture and the rc1 path list from the rc1 squashfs (both fixtures come from O01), and committing the derived files with pins.
- The normaliser, the diff, the expected-differences format and its validation, the report, the CI job.
Out:
- Producing the SBOM (syft, enrichment, schema validation): S01. Licenses, CVEs, unowned files: S02-S04.
- The file manifest format B04 writes (this node consumes it as specified below).
- Choosing and bumping `BUILD_EPOCH` (I05, M01); recovering rc1's tree (I02); fetching the rc1 SBOM, ISO and squashfs (O01).
- Verifying rc1's attestation (S05, X01 README steps).

## Design

### Golden pin and fetch
`oracle/golden/sbom/golden.yaml`:
```yaml
id: rc1
source:
  fixture: oracle/fixtures/rc1.yaml     # O01; asset "sbom"
  size: 271592
  sha256: 3cfc322a0e105638452baa6900552769a6ad5bfbf3be190a9808ac98ca575887
records:
  file: oracle/golden/sbom/rc1.records.json
  derived_from_sha256: 3cfc322a0e105638452baa6900552769a6ad5bfbf3be190a9808ac98ca575887
  records_sha256: "<64 hex; computed on first derivation>"
product:
  iso_sha256: a96006596b13cc09fa951f54aadc0b816765d783e5d0e40895d7d0945edeb27a   # cross-check against metadata.component.hashes[0]
  build_epoch: 20260811          # plan: rc1 binpkg cache BUILD_EPOCH; confirm from the SBOM on first derivation
  spec_version: "1.6"            # confirm
paths:
  file: oracle/golden/rootfs/rc1.paths.txt
  sha256: "<64 hex>"
  derived_from_iso_sha256: a96006596b13cc09fa951f54aadc0b816765d783e5d0e40895d7d0945edeb27a
```
`oracle/bin/derive-golden-sbom` reads the SBOM from O01's fixture path (it never downloads; `make fixtures-rc1` does, by digest), checks size and sha256 against `golden.yaml`, runs `normalize.py` and writes `rc1.records.json`. Without `--record` it re-derives and exits non-zero if the result differs from the committed file or the pins differ. It also checks that the ISO hash in `metadata.component.hashes[0].content` equals the ISO line of the fixture `SHA256SUMS`, which ties the SBOM to the attested ISO digest (`release.yml:157`).

Decision: the SBOM is not committed. SPEC §7 says rc1 fixtures are fetched by digest and never committed, and they live in the store `build` class (`fixtures/rc1/`, O01), which outlives the archived predecessor. What is committed is the derived, normalised records file (package keys, version sets, license sets, source split, world set; far smaller than the SBOM) with a pin to the SBOM it came from, so the fast tier runs the diff without network. Rejected: committing the 270 KB SBOM (contradicts SPEC §7); fetching at diff time (a false red on network failure).

### Rootfs path list (the "files" half)
`bom.cdx.json` carries no installed-file list: the enrichment drops `type: file` components (`enrich-sbom.py:582`) and the release assets are the ISO, `SHA256SUMS` and `bom.cdx.json` only (`release.yml:269-271`). A file-level comparison therefore needs rc1's rootfs. `oracle/bin/extract-golden-paths` reads the squashfs that O01's `rc1-extract` already unpacked (no second ISO download), checks the ISO sha256 recorded by `rc1-extract` against `product.iso_sha256`, runs `unsquashfs -ll`, and writes a sorted list of `<path>\t<type>` lines (no sizes, no owners: rc1 recorded no owners per file). The result is committed as `rc1.paths.txt` with its pin. This runs once on a developer machine or in the `oracle-fixtures` job, not in the diff job. Rejected: diffing against the live rc1 squashfs in CI (a large restore per run).

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

### What the first diff should contain
The first build pins rc1's tree (OD-6 default), builds the same recipes (R01 verbatim) and the same kernel config (R04 changes apart), and keeps `BUILD_EPOCH` `20260811`. Epochs are equal, so `follow-epoch` degrades to `exact` and every package version must match rc1 or carry a `version_exceptions` entry. Expected entries, from the plan and the study, to be confirmed by the first run:
- Package set: no additions or removals except those a named fix causes (a package an AC in R01/R02 adds or drops; each with an issue). Zero is the target.
- Versions: none, unless I02's recovered commit differs from rc1's lost snapshot for some package (I02 compares embedded ebuilds, and drops differing packages from the cache seed; those would show here as `version_exceptions` with the reason "recovered tree differs"). Overlay revbumps are invisible (see Risks).
- Files: `lib/ld-musl-i386.so.1` appears in `files.removed` only if OD-2 chose "make everything static" and R01 fixed the dynamic binaries; with OD-2's default (allowlist) the loader stays and no entry is needed. Hand-authored `/etc` and `/usr/sbin` files change only if a node fixes them; each change needs a `files.added`/`files.removed` glob or an owning explained package. Kernel module names under `lib/modules/<KVER>/` are normalised; module files added or removed by R04's fragments appear as globs with the R04 issue.
- SBOM metadata (serial number, timestamp, tool versions, `metadata.component`) is excluded and not listed.
When M01 later moves the tree, the epoch differs and the version moves are summarised by the `follow-epoch` rule; M01's PR updates `expected-differences.yaml` for the package-set changes it causes, and a human reviews it.

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
`oracle-sbom-diff.yml` (reusable) takes the SBOM and manifest artifacts from the B06 pipeline run and `BUILD_EPOCH` from `pins/pins.yaml`, runs the CLI, uploads the report, writes the summary. O07 depends on B06, so its PR adds the one `uses:` job to B06's workflow. The job is not part of P02's release gate (O07 is a parallel node); X01 requires it green. `expected-differences.yaml` is a reviewed file; changes to it follow the trusted-base rule (SPEC §8): the job reads the file from the PR's base revision when the PR only touches other paths, and from the PR head when the PR touches `oracle/golden/` (a human reviews that diff).

## Traps and doctrines preserved
- **D-two-epoch-pin-model:** a new `BUILD_EPOCH` moves versions; `TOOLCHAIN_EPOCH` moves builder components. Prevented from producing noise by the `follow-epoch` rule (O07-AC-4) once M01 changes the epoch, while exact-pinned classes stay exact (O07-AC-3) and, with equal epochs, everything is exact.
- **D-no-readding-removed-things:** a deliberately removed package returning shows as an addition. Prevented by O07-AC-5 (every added package needs a reason; the denylist check itself is R02's).
- **D-supply-chain-honesty:** the golden must be exactly what rc1 shipped. Prevented by O07-AC-1 (pinned size and sha256, tie to the attested ISO digest) and O07-AC-2.
- **D-state-and-no-hidden-stderr:** a diff that skips on missing input would pass vacuously. Prevented by O07-AC-8 (exit 2 on any missing input) and O07-AC-6 (stale expected entries fail).
- **D-hand-authored-rootfs-files-owned:** the files half relies on B04's ownership manifest; added files owned by an explained package need no entry (O07-AC-7).

## Gate
- **O07-AC-1** — `oracle/golden/sbom/golden.yaml` pins the rc1 SBOM (size 271,592, sha256 `3cfc322a0e105638452baa6900552769a6ad5bfbf3be190a9808ac98ca575887`, ISO sha256 `a96006596b13cc09fa951f54aadc0b816765d783e5d0e40895d7d0945edeb27a`) and `rc1.records.json`; the records file's sha256 equals `records_sha256`, and no raw rc1 SBOM, ISO or squashfs is tracked by git. *Verify:* `tests/fast/test_sbom_diff_golden.py::test_pin_matches_records`, `::test_no_raw_rc1_assets_committed`. *Tier:* fast.
- **O07-AC-2** — `oracle/bin/derive-golden-sbom` (without `--record`) exits non-zero on a missing fixture, a size or sha256 mismatch against `golden.yaml`, a re-derived records file that differs from the committed one, or an SBOM whose ISO hash differs from the fixture `SHA256SUMS` ISO line; with `--record` it writes the records file and pin. *Verify:* `tests/fast/test_sbom_diff_golden.py::test_derive_verifies` using a tiny synthetic fixture directory (no network in the fast tier). *Tier:* fast.
- **O07-AC-3** — `exact` classes (overlay packages `pkg:ebuild/*/monolith-*` and `monolith-kernel`) fail when the version set differs from rc1 and is not under `version_exceptions`. *Verify:* `tests/fast/test_sbom_diff_policy.py::test_exact_class`. *Tier:* fast.
- **O07-AC-4** — With a differing `--build-epoch`, version changes of other packages are accepted and summarized (counts and sorted list in the report); with an equal epoch the same changes fail. A downgrade fails unless listed under `downgrades`. *Verify:* `tests/fast/test_sbom_diff_policy.py::test_follow_epoch`, `::test_equal_epoch_is_exact`, `::test_downgrade_requires_reason`. *Tier:* fast.
- **O07-AC-5** — An added or removed package key, a world-set change, or a source change not listed in `expected-differences.yaml` fails the run; listed with a reason it passes. *Verify:* `tests/fast/test_sbom_diff_policy.py::test_unexplained_package`, `::test_world_set`. *Tier:* fast.
- **O07-AC-6** — Stale expected entries fail: a listed package that did not change, a file glob matching no path, a duplicate entry, an entry without `reason` of 15+ characters or without `issue`/`pr`/`decision`. *Verify:* `tests/fast/test_sbom_diff_policy.py::test_stale_entries`, and schema validation `::test_expected_schema`. *Tier:* fast.
- **O07-AC-7** — File differences: with `path_normalizers` applied, an added path owned by an explained added package passes without a per-file entry, an unowned added path needs a `files.added` glob, and every removed path needs a `files.removed` glob; an unexplained path fails and is listed. *Verify:* `tests/fast/test_sbom_diff_files.py`. *Tier:* fast.
- **O07-AC-8** — A missing, empty or unparsable new SBOM, manifest, expected file or golden exits 2 and never produces a pass verdict; a golden whose hash differs from `golden.yaml` exits 2. *Verify:* `tests/fast/test_sbom_diff_cli.py`. *Tier:* fast.
- **O07-AC-9** — The normaliser reads the committed records derived from the real rc1 SBOM: more than 50 package records, a non-empty world set, a `target`/`builder` split, every record has a key; two CycloneDX versions (1.6 and 1.7 synthetic variants) normalise identically. *Verify:* `tests/fast/test_sbom_diff_normalize.py`. *Tier:* fast.
- **O07-AC-10** — The report lists, for the run, counts per category, the full version-move table, every explained and unexplained difference, the golden id and sha256, the build epoch pair, and the exit verdict, and validates against `oracle/schemas/sbom-diff-report.schema.json`. *Verify:* `tests/fast/test_sbom_diff_report.py`. *Tier:* fast.
- **O07-AC-11** — `oracle/golden/rootfs/rc1.paths.txt` exists with a pinned sha256 and its `derived_from_iso_sha256` equals the rc1 ISO digest; `extract-golden-paths` refuses an unpacked tree whose recorded ISO digest differs. *Verify:* `tests/fast/test_sbom_diff_golden.py::test_paths_pin`; `::test_extract_script_checks_iso_hash` (stub squashfs listing, stub `unsquashfs`). *Tier:* fast.
- **O07-AC-12** — On the B06/S01 output of the first build from rc1's tree, the job exits 0 with a committed `expected-differences.yaml` in which every entry has a reason, and `$GITHUB_STEP_SUMMARY` shows the version-move table. *Verify:* CI job `oracle-sbom-diff / diff`. *Tier:* slow.
- **O07-AC-13** — In the `oracle-fixtures` CI job, re-deriving the records and the path list from the real rc1 fixtures reproduces the committed `rc1.records.json` and `rc1.paths.txt` byte for byte. *Verify:* CI job `oracle-fixtures` step `derive-golden-sbom` (no `--record`). *Tier:* slow.
- **O07-AC-14** — The first-diff expectations are enforced: with equal `BUILD_EPOCH` on both sides, `follow-epoch` is treated as `exact` and any version change not under `version_exceptions` fails. *Verify:* `tests/fast/test_sbom_diff_policy.py::test_equal_epoch_is_exact` (shared with O07-AC-4). *Tier:* fast.

## RED plan
Tester commits: synthetic mini-SBOM builders in `tests/fast/_sbomgen.py` (components with purls, builder-propagated components, root `dependsOn`, formulation files); `test_sbom_diff_policy.py` (exact, follow-epoch, equal epoch, downgrade, unexplained, stale), `test_sbom_diff_files.py`, `test_sbom_diff_cli.py`, `test_sbom_diff_report.py`, `test_sbom_diff_golden.py` (golden file and pin absent, so AC-1 fails until the first slice fetches it). The fetch of the real asset needs network, which the fast tier lacks; the implementer performs it once outside CI, commits the file, then AC-1 and AC-9 go green.

## Risks and open questions
- Hardest: the exact structure of the rc1 SBOM was inferred from `enrich-sbom.py` and not read. The purl shape, whether slot-versioned packages repeat keys, the `dependencies` layout and whether the rc1 file is CycloneDX 1.6 or 1.7 must be confirmed on the first derivation; the normaliser tests run on the records from the real file and take precedence over this document.
- rc1's `BUILD_EPOCH` `20260811` comes from the plan (`docs/first-attested-build.md`); confirm it from the SBOM. With rc1's tree pinned first, the epochs are equal, `follow-epoch` degrades to `exact`, and the diff is a strict reproducibility statement. The policy engine is exercised in earnest only after M01's bump, so its fast tests carry the load until then.
- The path list needs the rc1 squashfs from O01's fixtures. If the store copy is lost and the archived release is gone, the committed `rc1.paths.txt` still works (it is derived data), but AC-11 and AC-13 can no longer be re-verified.
- B04's manifest format is not yet specified; the TSV assumption above must be reconciled.
- Overlay revbumps are invisible in the SBOM (versions strip `-rN`); a changed overlay package at the same `PV` is not detected by this node (R03's revbump gate covers it).
- The first run should produce a short expected-differences file (see "What the first diff should contain"); a long one means the port drifted, not that the file should grow. The risk is rubber-stamping it. The staleness rule and the reason requirement are the mitigation; review burden falls on the human merger.

## Cost
Three agent slices: (1) derive records from the rc1 fixture, pin, normaliser; (2) policy engine, expected format, files half; (3) CI job and the first reviewed expected-differences file. One or two CI cycles on a B06 run plus S01 output (a cache-hot build job is about 13 min, measured on the predecessor). No separate download: the fixtures come from O01. Storage: a few hundred KB committed (records and path list). No paid services.

## Spec defects found
- None. SPEC §7 now says version movement is summarised by policy, and graph.yaml now has the edges to B06 and I05.

