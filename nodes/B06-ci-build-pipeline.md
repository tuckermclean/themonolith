# B06 — ci-build-pipeline

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| B | B05, F03, I05, O02 | B07, M01, O07, S05 | MS1 | L |

**Owns:** `.github/workflows/build.yml`, `factory/bin/plan-build`, `factory/bin/collect-manifest`,
`factory/bin/verify-artifacts`, `factory/bin/preflight`, `factory/lib/retry.sh`, `factory/data/budgets.yaml`
(runner entry), `factory/mk/cache.mk` (`cache-key`, `memo-get`, `memo-put`, `oracle-cache-lookup`, `oracle-cache-save`, `cache-audit`: thin `make` wrappers over I06's `factory/bin/cache`), `factory/mk/iso.mk` aggregate (`iso`, `build-all`), `docs/system.yaml` rows for every B-node job,
script and target, `tests/fast/build-plan.test.sh`, `tests/fast/workflow-shape.test.sh`,
`tests/fast/workflow-publishes-nothing.test.sh`, `tests/fast/make-parity.test.sh`,
`tests/fast/artifacts-*.test.sh`, `tests/fast/retry.test.sh`, `tests/fast/preflight.test.sh`,
`tests/fast/cache-wiring.test.sh`
**Carries from linux-live-iso-factory@b9f533b:** `.github/workflows/build.yml` jobs `changes` (dropped), `build`
(split in two), `boot-test` handoff (`:508-541,559-565`, replaced by a call to O02's `oracle.yml`), the steps "Pull binary package cache from GHCR" and "Save binary package cache to GHCR" (`:267,448`, replaced by I06), the version rules (`:190-209`), the header
comment on why `build.yml` must be the OIDC entry point (`:3-17`), concurrency rules (`:41-46`), `Makefile:445`
(`all`).
**Study refs:** workflows.yaml `wf.build` and `job.build.changes/build/boot-test` (paths filter misses config
dirs, no timeouts, S3 hard coupling, `latest` written before boot-test, leftover disk monitor, cache handoff);
build.yaml `dataflow.run_order_for_make_all`; T-run-rerun-reuses-cache, T-runner-oom, T-github-api-503-installs;
D-tag-builds-from-source (mode plumbing), Principles 1, 2, 5, 7; SPEC §4.1, §8.

## Purpose
After B06 a push, a labelled PR, a manual dispatch or a `v*.*.*` tag runs the whole chain from pinned inputs to an
ISO that has passed every registered boot mode, and `make iso` runs the same stages locally. This is MS1 (first ISO).
Development runs restore from I06's cache and skip an unchanged build entirely; tag runs read no cache. The workflow
publishes nothing public. It is the entry workflow, so later nodes (S05 attest, P02 evidence) join the same file and
Sigstore binds to it.

## Scope
In:
- `build.yml` jobs `plan`, `memo`, `packages`, `image`, `oracle-gate`, the artifact contract between them and to downstream jobs.
- Wiring I06 into those jobs: restore and save per run, the namespace from the event, the memo skip, the oracle result cache, and `cache audit` after a release build.
- `make iso` and the stage targets as one sequence shared by CI and local use.
- The shared helpers: plan, collect-manifest, verify-artifacts, preflight, retry.
- The assertion that this workflow never publishes (Principle 7).

Out:
- Building the builder image: I03 (own workflow); B06 only pulls it by digest from the pins.
- Portage snapshot sync, distfile mirror, store backends: I02, I04, I01/F06 (B06 calls `make sync-portage`).
- The boot modes and `oracle.yml` itself: O02-O05 (B06 calls `oracle.yml` and names no mode). SBOM and gates: S01-S04. Attest/provenance job: S05. The `evidence` job (hosted in this file): P02. Release and publication: P02, P03.
- The cache logic (keys, sets, memo, result cache, audit): I06. B06 only calls it.
- Pin bump automation: M01. Retention of Actions artifacts beyond the settings below: M03 covers the store only.

## Design

### Triggers and mode
```yaml
on:
  push:
    branches: [master]
    tags: ['v[0-9]+.[0-9]+.[0-9]+*']      # path filters are not evaluated for tag pushes
    paths-ignore: ['docs/**', 'nodes/**', '**/*.md', 'SPEC.md']
  pull_request: {types: [opened, reopened, synchronize, labeled]}   # runs only with label full-ci
  workflow_dispatch: {inputs: {mode: {type: choice, options: [iterate, release], default: iterate}}}
```
No `schedule`: every input is pinned and mirrored, so a weekly rebuild proves nothing the pins do not (the
predecessor ran Mondays 03:00, `build.yml:31`). No allow-list path filter: the predecessor's `dorny/paths-filter`
omitted `configs/kernel.config`, `make.conf`, `package.*` and `savedconfig`, so config-only pushes built nothing
(workflows.yaml `job.build.changes`); a short `paths-ignore` list is subtractive and fails safe.
Concurrency: PRs `build-pr-<n>` cancel-in-progress; everything else a unique `build-<run_id>` (as `:41-46`).
`plan-build` decides: tag `refs/tags/vX.Y.Z[-suffix]` gives `mode=release`, `BUILD_VERSION=X.Y.Z[-suffix]`; a ref
tag that is not semver-shaped exits 2; everything else `mode=iterate` (or the dispatch input) and
`BUILD_VERSION=<BUILD_EPOCH>-<7-char sha>` (`build.yml:203-207`). It also decides the cache role (I06, SPEC §5.1):
`cache-ns` is empty (the shared `main` namespace) for a push to `master`, `pr-<n>/` for a pull request, and `none` for
a dispatch on another branch (read `main`, write nothing); `cache-write` is `false` for forks and for `mode=release`;
in `release` mode no cache is read at all. `SOURCE_DATE_EPOCH` and `BUILD_EPOCH` come from
`pins/pins.yaml` through I05's reader. The builder image is referenced by digest from the pins, never by tag
(contradiction: the predecessor pulled `gentoo/stage3` and builder by tag).

### Jobs
All jobs: `runs-on: ubuntu-24.04` (a pinned runner label, not `latest`), `timeout-minutes` set, `permissions:
contents: read` at workflow level, every `uses:` pinned to a 40-hex SHA (F01 lint repeats the check).
1. **plan** (5 min). `make plan` writes outputs: `mode`, `build-version`, `source-date-epoch`, `builder-digest`,
   `cache-ns`, `cache-write`, `run-build` (false for PRs without the label, which makes the other jobs skip). Runs
   `make preflight` (below) on the host runner image to record resources.
2. **memo** (`needs: plan`; skipped when `mode=release`; 15 min). Pulls the builder by digest, runs `make cache-key`
   (I06 `cache key` and `cache fingerprint`, which need portage in the builder) and `make memo-get` for the run's
   namespace. Outputs `hit` and `memo-key`. On a hit it downloads the memoised ISO, SBOM and `manifest.json` and
   uploads them as the same artifact `iso-<run_id>` that `image` would have produced, with the same names and
   `SHA256SUMS`; `packages` and `image` are then skipped (`if: needs.memo.outputs.hit != 'true'`). A memo hit is
   not a pass: `oracle-gate` and the gates still judge the ISO. `permissions: packages: read`.
3. **packages** (`needs: [plan, memo]`, 150 min: about twice the measured 78 min from-source tag job, to be
   recalibrated from the first run). `permissions: packages: write` only when `mode=iterate`, `cache-write=true`; otherwise `packages: read`.
   Steps: checkout; retry-wrapped `docker pull ...@<digest>`; `make sync-portage` (I02); `make packages kernel` (B01,
   B02; B01 calls I06's `cache restore`/`cache save`, B02 uses the restored kernel; in `release` mode neither calls the cache);
   in `release` mode only, `make cache-audit` after the build (I06 `cache audit`; it never fails the build); `git diff --exit-code`
   (nothing tracked was written); `make collect-packages`; upload artifact `packages-<run_id>` containing
   `out/packages/`, `out/kernel/`, `out/stage/`, `out/cache/` (`key.json`, `fingerprints.tsv`, `restore.tsv`, and in
   release mode `audit.tsv`), `out/logs/`, `SHA256SUMS` (`compression-level: 0`, `overwrite: true`,
   `retention-days: 7`). On failure: upload `out/logs/` (name `logs-packages-<run_id>`).
4. **image** (`needs: [memo, packages]`, 60 min, skipped on a memo hit). Download `packages-<run_id>`; `verify-artifacts`
   (hashes against `SHA256SUMS`); `make rootfs initrd iso-image` (B04, B03, B05); `make collect-manifest`; write
   `SHA256SUMS`; upload artifact `iso-<run_id>` (same settings, `retention-days: 14`) with: the ISO, squashfs, initrd,
   `vmlinuz`, `resolved-kernel.config`, `rootfs.manifest.tsv`, `initrd.manifest.tsv`, `build-manifest.json`,
   `out/stage/*.json`, `SHA256SUMS`. Job outputs: `iso-sha256`, `squashfs-sha256`, `build-version`, `mode`.
   Failure logs uploaded as above.
5. **memo-save** (`needs: image`; `iterate` with `cache-write=true` only; 10 min). `make memo-put` stores the ISO,
   `iso.sha256` and `manifest.json` under the memo key. The SBOM is taken after B05 (S01), so S01 adds its job to this job's
   `needs` and `memo-put` then includes it; until S01 lands the entry has no SBOM and a hit does not skip S01. Writes only
   `build <ns>memo/`.
6. **oracle-gate** (`needs: [plan, memo, image]`, runs on a memo hit too). Calls O02's reusable `oracle.yml`
   (`uses: ./.github/workflows/oracle.yml`, `iso-source: artifact`). B06 names no mode: the plan job in `oracle.yml` builds
   its matrix from every `implemented` leg in `oracle/modes.yaml`, so a mode added there joins the gate with no
   change to `build.yml`. Result cache: before the matrix, `make oracle-cache-lookup` asks I06 `result-get` for each
   (ISO sha256, mode hash, harness hash). A cached `ok` result is fed to O02's `gate` as a result JSON marked
   `cached: true` with the run that produced it, so the gate's "result set equals the plan" rule still holds and a
   cached pass is visible in the summary. After a green gate, `make oracle-cache-save` writes `result-put` for the legs
   that actually ran (`iterate`, `cache-write=true`, successes only; a failure is never cached). In `release` mode
   no lookup happens: every leg runs.
Downstream jobs (S01..., S05, P02's evidence in this file) declare `needs: image` (or `oracle-gate` where they need
its verdict), download `iso-<run_id>`, and run `verify-artifacts --expect-iso-sha256 ${{ needs.image.outputs.iso-sha256 }}`;
a mismatch is exit 4. On a memo hit `needs.image` is skipped, so `plan` exposes the same outputs from the memo
manifest (`iso-sha256` is read from the memoised `iso.sha256` and re-verified against the downloaded bytes).
Decision: Actions artifacts for the in-run handoff, with `overwrite: true` and a content hash passed as a job
output. Rejected: `actions/cache` keyed by run id (the predecessor's `ci-artifacts-<run_id>-iso`). A cache entry is
immutable, so re-running a job restored the bad ISO (T-run-rerun-reuses-cache). The memo is different: its key is the
complete input hash, so a re-run can only get the bytes its inputs name (SPEC §4.1, §5.1). v0.2 also rejected the store
`build` class for the handoff because it persisted an unvetted ISO under a stable key; the memo does not
(hash-keyed, 30-day retention, never read by a release, and its ISO is judged by `oracle-gate` and the gates on
every use).
Two heavy jobs, not one: `image` can be re-run in minutes without recompiling, and its gate runs on the gpkg set
alone. Rejected: the predecessor's single job (a failure in `iso` cost a full-job re-run).

### Publishes nothing
No job in `build.yml` that B06 owns writes the store class `public`, writes the `build` class outside the `memo/`
prefix (so never `builds/<version>/…`, which is P02's), creates a release or tag, writes a pages or dashboard path,
moves a `latest` pointer, or holds `id-token` or `attestations` permission. The only store writes are cache writes:
the `binpkg` class in `packages` (I06 `cache save`), and `build memo/` in `memo-save` and `oracle-gate` (I06 memo and
result entries), all `iterate`, non-fork, namespaced by `cache-ns`. A release run writes none of them. The predecessor uploaded `latest` kernel,
squashfs, initrd and ISO before boot-test ran (`build.yml:495-546`, workflows.yaml note); that is the shape this
rule forbids. S05 adds an attest job to this same file later with its own permissions; the shape test treats the
three B06 jobs as the checked set.

### Local parity
`make iso` = `sync-portage`, `packages`, `kernel`, `rootfs`, `initrd`, `iso-image`, in that order, each target a
`run-in-builder <stage>` call; `make build-all` adds the collect steps. `packages` calls I06's restore and save against
the `fs` store, so local runs iterate from cache too. The memo skip, the oracle result cache and the audit are CI-only
steps around that sequence (they save or skip whole stages and do not change what a stage does). CI `run:` lines are `make <target>` only
(plus `sha256sum`, `git`, `docker pull|login`, and writes to `$GITHUB_OUTPUT`). Local differences are exactly: store
backend `fs` at `.cache/store` (via `STORE_BACKEND=fs`) instead of `oci`, and `MONOLITH_BUILD_MODE` defaults to
`iterate`. `make iso MODE=release` reproduces a tag build offline except for the snapshot and distfiles, which
must already be in the store.

### Helpers
- `plan-build`: pure function of `GITHUB_REF`, `GITHUB_EVENT_NAME`, dispatch inputs, pins, `git rev-parse`.
- `collect-manifest`: merges `out/stage/*.json` into `out/build-manifest.json`:
  `{"schema":1,"build_version","mode","source_date_epoch","git_sha","layers":{"kernel","initrd","squashfs","iso"},
  "stages":{…},"run":{"id","attempt","workflow","ref"}}`. Only `run` is run-specific; B07 compares everything
  else. Keys sorted, no timestamps.
- `verify-artifacts <dir> [--expect-iso-sha256 H]`: checks `SHA256SUMS`, non-empty files, required names; exit 3
  missing/empty, 4 mismatch.
- `preflight`: reads MemTotal and free disk, compares to `factory/data/budgets.yaml: runner.{min_mem_gib,min_disk_gib}`;
  exit 4 below. Initial values are set from the first measured run (predecessor: 16 GiB runner, JOBS=2, disk
  unknown). Replaces the leftover `while true; df; free` loop (`build.yml:287`).
- `retry.sh`: `retry <attempts> <delay-s> cmd…`, default 6 and 30, `RETRY_SLEEP` injectable. All network steps in
  workflows go through `make` targets that use it, including image pull and tool installs
  (T-github-api-503-installs: one-shot downloads cost a 2 h rebuild).

## Traps and doctrines preserved
- **T-run-rerun-reuses-cache:** no `actions/cache` handoff; overwrite plus hash check. AC-3, AC-10.
- **T-runner-oom:** `preflight` resource gate and `JOBS` derivation (B01) with a job `timeout-minutes`. AC-8.
- **T-github-api-503-installs:** retry wrapper for every download; no bare `curl` in workflows. AC-6, AC-7.
- **D-tag-builds-from-source:** tag gives `mode=release`; the job asserts B01's provenance TSV; no cache read of any kind (restore, memo, results) happens in release mode, and the audit runs only there. AC-1, AC-11, AC-13, AC-15, AC-16.
- **Principle 12 (iterate from cache, release from source):** namespace from the event, memo skip, result cache. AC-13, AC-14, AC-15.
- **Principle 7 (publish last):** this workflow publishes nothing. AC-2.
- **Principle 1 (no vendor in workflows):** no `aws`, `oras` or `curl` in `run:`; store via `make`. AC-4.
- **Principle 5:** hashes verified at every hand-off; failed checks exit non-zero. AC-3, AC-5.
- **SPEC §8 entry workflow:** tags trigger `build.yml`; the header comment from `:3-17` is kept. AC-4.

## Gate
- **B06-AC-1** — `plan-build` maps `refs/tags/v1.2.3` to `mode=release, BUILD_VERSION=1.2.3`, `refs/tags/v1.2.3-rc1` to `1.2.3-rc1`, a malformed tag to exit 2, master and PR refs to `iterate` with `<BUILD_EPOCH>-<sha7>`, and honours the dispatch `mode` input. *Verify:* `tests/fast/build-plan.test.sh`. *Tier:* fast.
- **B06-AC-2** — `build.yml` contains no step that writes the store class `public`, writes `build` outside `memo/`, creates a release or tag, calls `gh release`, pushes to pages, or moves `latest`; jobs `plan`, `memo`, `packages`, `image`, `memo-save`, `oracle-gate` hold neither `id-token` nor `attestations`, and `packages: write` appears only in `packages`, `memo-save` and `oracle-gate`, each guarded by `mode == iterate` and `cache-write`. *Verify:* `tests/fast/workflow-publishes-nothing.test.sh`. *Tier:* fast.
- **B06-AC-3** — `verify-artifacts` exits 0 on a consistent directory, 3 on a missing or zero-byte listed file, 4 on a changed byte or on an ISO hash different from `--expect-iso-sha256`; both upload steps set `overwrite: true`; no `actions/cache` handoff exists. *Verify:* `tests/fast/artifacts-verify.test.sh`, `tests/fast/workflow-shape.test.sh`. *Tier:* fast.
- **B06-AC-4** — Every `run:` line in `build.yml` is on the allowed list (`make`, `sha256sum`, `git`, `docker pull|login`, `echo|printf … >> $GITHUB_OUTPUT`); no `curl`, `wget`, `aws`, `oras`, `docker run`, or `factory/bin/*` call; every `uses:` is a 40-hex SHA; every job has `timeout-minutes`; the entry-workflow header comment is present. *Verify:* `tests/fast/workflow-shape.test.sh`. *Tier:* fast.
- **B06-AC-5** — `collect-manifest` output is byte-identical for identical stage records, contains `layers.{kernel,initrd,squashfs,iso}` and a separate `run` object, and fails (exit 3) if any stage record is missing. *Verify:* `tests/fast/artifacts-manifest.test.sh`. *Tier:* fast.
- **B06-AC-6** — `retry` succeeds when the command passes on attempt 3 of 6, returns the last status after exhausting attempts, and sleeps the configured delay (via `RETRY_SLEEP`). *Verify:* `tests/fast/retry.test.sh`. *Tier:* fast.
- **B06-AC-7** — Builder pull, tool installation and any network `make` target used by the workflow call `retry`; the pull uses `@sha256:` from the pins and never a tag. *Verify:* `tests/fast/workflow-shape.test.sh`, `tests/fast/make-parity.test.sh`. *Tier:* fast.
- **B06-AC-8** — `preflight` exits 4 when MemTotal or free disk is below `budgets.yaml`, 0 otherwise, and prints both values. *Verify:* `tests/fast/preflight.test.sh` (fake meminfo and df). *Tier:* fast.
- **B06-AC-9** — Stage sequence parity: the targets in `build.yml` `run:` lines, in job order, equal the sequence `make -n iso` expands to (ignoring plan, collect and cache steps); `docs/system.yaml` lists the new workflow, jobs, scripts and targets. *Verify:* `tests/fast/make-parity.test.sh`; F03 inventory check in the fast lane. *Tier:* fast.
- **B06-AC-10** — A `full-ci` PR run yields artifact `iso-<run_id>` whose downloaded ISO has the sha256 in `needs.image.outputs.iso-sha256`, the `image` job re-run alone succeeds and replaces the artifact, and the downstream `verify-artifacts` accepts only the new hash. *Verify:* CI run on a labelled PR plus a manual "re-run job: image", recorded in the PR table. *Tier:* slow.
- **B06-AC-11** — A tag or `mode=release` dispatch run passes B01-AC-7 (no `cache` rows), the `memo` job and the oracle result lookup are skipped, every oracle leg ran (none `cached: true`), and the log shows no `cache` command other than `audit`. *Verify:* CI job `packages` on a `v0.0.0-ci` style dispatch, assertion step; the `oracle-gate` summary. *Tier:* slow.
- **B06-AC-12** — `make iso` on a clean checkout with a seeded `fs` store produces an ISO whose `layers.*` hashes equal those of the CI run for the same commit and pins, or each difference is a B07 known difference. *Verify:* B07 compare job (local vs CI layer lists). *Tier:* slow.
- **B06-AC-13** — `plan-build` maps events to cache roles: push to `master` gives `cache-ns` empty and `cache-write=true`; a pull request gives `pr-<n>/` and `true` (`false` for a fork); a dispatch on another branch gives `none` and `false`; any tag or `mode=release` gives `cache-write=false`. `build.yml` grants `packages: write` only where `cache-write` is true. *Verify:* `tests/fast/build-plan.test.sh` (event table), `tests/fast/workflow-shape.test.sh`. *Tier:* fast.
- **B06-AC-14** — A `memo` hit skips `packages` and `image` and still runs `oracle-gate`: `packages` and `image` carry the `memo.outputs.hit != 'true'` condition, `memo` is skipped when `mode == release`, `iso-<run_id>` is uploaded by the `memo` job on a hit, and downstream jobs verify the ISO hash against the memoised `iso.sha256`. A second run of an unchanged commit reports the memo hit and a passing `oracle-gate` in under 15 min. *Verify:* `tests/fast/workflow-shape.test.sh` (conditions); CI: two `workflow_dispatch` runs of one commit, recorded in the PR table. *Tier:* fast and slow.
- **B06-AC-15** — `oracle-gate` calls `oracle.yml` and `build.yml` contains no mode name; a mode added to `oracle/modes.yaml` appears in the gate's plan with no `build.yml` change; a cached result is reused only for the same (ISO sha256, mode hash, harness hash) and appears in the summary as `cached`; a failed leg is never written to the result cache; in `release` mode every leg runs. *Verify:* `tests/fast/cache-wiring.test.sh` (fixture `modes.yaml` with an extra mode; stub `cache result-get/result-put`; `oracle-cache-save` called only for successful, uncached legs); CI `oracle-gate` summary on two runs. *Tier:* fast and slow.
- **B06-AC-16** — A release run calls `cache audit` after `make packages kernel`, uploads `out/cache/audit.tsv` in `packages-<run_id>`, and a nonzero audit result does not fail the job; an `iterate` run never calls `audit`. *Verify:* `tests/fast/cache-wiring.test.sh` (stub `cache`; workflow shape); CI release dry run. *Tier:* fast and slow.
- **B06-AC-17** — The `packages` step budget is recorded: the first cold run, the first cache-hot run and the first memo-hit run each write their wall time per job into the PR table, and `timeout-minutes` for `packages` is reset to at most twice the measured cold time. *Verify:* PR table with run ids; `tests/fast/workflow-shape.test.sh` (timeout present). *Tier:* slow. *When:* after MS2 (calibration only; the initial 150 min is safe).

## RED plan
Tester writes first, failing because nothing exists: `build-plan` (tag and ref table), `workflow-shape` and
`workflow-publishes-nothing` (parse YAML with PyYAML; first fixture is a copy of the predecessor `build.yml`
excerpt with `actions/cache` and `aws s3 cp`, which must fail), `artifacts-verify` (tamper one byte),
`retry`, `preflight`, `make-parity` (compares YAML `run:` targets with `make -n iso`; fails until both exist),
`cache-wiring` (stub `cache`; event table for namespaces, memo conditions, release-mode silence, result-cache rules).
No Docker or network.

## Risks and open questions
- The B06 cache wiring assumes interfaces on O02 (`oracle.yml` accepts pre-supplied cached results, see Spec defects) and on I06 (`memo-put` without an SBOM, `cache save --complete`). Reconcile at integration.
- Size of the `packages` artifact is unknown; a large set could hit Actions artifact quotas. Fallback: hand off the
  gpkg set through the store `binpkg` class by key list (still honest: B04 verifies hashes). Measure in cycle 1.
- Disk on `ubuntu-24.04`: free space may be below what the cold build needs; `preflight` will tell. A larger runner
  would cost money (not needed for a public repo's standard runner, unknown for larger ones).
- `workflow_run` consumers (P02) must fetch artifacts by `run-id` with a token; not testable until P02.
- Forked-PR behaviour: `packages: read`, no store write; the `full-ci` label gates cost. A malicious PR with the
  label reaches `make` on the PR tree, so recipes are code; the label must only be applied by maintainers (F04/§8).
- `docs/system.yaml` schema comes from F03; rows are added in F03's format when it lands.
- OD-7 (moving CI to Forgejo/Woodpecker): the `make`-only `run:` rule keeps workflows thin enough to port.

## Cost
Slices: (1) plan-build (with cache roles), retry, preflight, verify-artifacts, collect-manifest with tests; (2) `build.yml`
skeleton + shape/publishes-nothing/parity tests; (3) `packages` job end to end with I06 restore/save; (4) `image` job
and handoff, `oracle-gate` call; (5) memo skip, result cache, release run with audit, local parity. About 5 slices.
CI cycles, from the predecessor's measurements on GitHub Actions: a cache-hot build job took 13 min (packages 7.5 min);
a from-source tag build job took 78 min (packages 74.6 min); the 17 boot modes took about 10 min wall in parallel
(nic-models 9.1 min, the rest 1-2 min each); the attestation job 4.7 min (S05). So an iterate run with a warm cache costs
about 25 min wall to a tested ISO, a memo hit about 12 min (the oracle gate with cached results is less), and the one
release run about 95 min. Plan on one cold run, three or four warm runs and one release dry run for this node. Money:
Actions artifact storage (about the size of `packages` plus the ISO, 7-14 day retention, unmeasured) and runner
minutes; free tier on a public repo, unknown otherwise. Cache storage (about 2 GB per global key, plus memo ISOs for
30 days) is I06's.

## Spec defects found
- O02 (`oracle.yml`) has no input for pre-supplied results. The result cache (I06, B06-AC-15) needs either an input listing cached results to merge into `gate`, or a `skip-modes` input plus a gate that accepts `cached: true` results. Decide in O02.
- I06 `memo-put` stores `iso` and `sbom` together, but the SBOM exists only after S01 (post-B05). B06's `memo-save` runs before S01 lands, so `memo-put` must accept a missing SBOM until then.
- SPEC §5 puts the memo in the `build` class, while v0.2's B06 forbade any `build` write. B06-AC-2 now allows `build memo/` only; SPEC §8 and P02 should state that `builds/<version>/` is P02's alone.
- graph.yaml's M01 depends on B06 and O02 but `build.yml` here has no schedule; M01 must own its own workflow, and B06 must trigger on `pull_request` for `pins/**` branches; the `full-ci` label gate would block bump PRs unless M01 applies the label or B06 exempts `pins/**`.
- B01 and I06 disagree on the release-mode variable (`MONOLITH_BUILD_MODE` vs `MONOLITH_MODE`); B06 exports whichever SPEC settles on (see B01).
