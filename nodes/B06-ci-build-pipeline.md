# B06 — ci-build-pipeline

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| B | B05, F03, I05 | B07, O02, S05, M01 | MS2 | L |

**Owns:** `.github/workflows/build.yml`, `factory/bin/plan-build`, `factory/bin/collect-manifest`,
`factory/bin/verify-artifacts`, `factory/bin/preflight`, `factory/lib/retry.sh`, `factory/data/budgets.yaml`
(runner entry), `factory/mk/iso.mk` aggregate (`iso`, `build-all`), `docs/system.yaml` rows for every B-node job,
script and target, `tests/fast/build-plan.test.sh`, `tests/fast/workflow-shape.test.sh`,
`tests/fast/workflow-publishes-nothing.test.sh`, `tests/fast/make-parity.test.sh`,
`tests/fast/artifacts-*.test.sh`, `tests/fast/retry.test.sh`, `tests/fast/preflight.test.sh`
**Carries from linux-live-iso-factory@b9f533b:** `.github/workflows/build.yml` jobs `changes` (dropped), `build`
(split in two), `boot-test` handoff (`:508-541,559-565`, replaced), the version rules (`:190-209`), the header
comment on why `build.yml` must be the OIDC entry point (`:3-17`), concurrency rules (`:41-46`), `Makefile:445`
(`all`).
**Study refs:** workflows.yaml `wf.build` and `job.build.changes/build/boot-test` (paths filter misses config
dirs, no timeouts, S3 hard coupling, `latest` written before boot-test, leftover disk monitor, cache handoff);
build.yaml `dataflow.run_order_for_make_all`; T-run-rerun-reuses-cache, T-runner-oom, T-github-api-503-installs;
D-tag-builds-from-source (mode plumbing), Principles 1, 2, 5, 7; SPEC §4.1, §8.

## Purpose
After B06 a push, a labelled PR, a manual dispatch or a `v*.*.*` tag runs the whole chain from pinned inputs to a
verified ISO in Actions artifacts, and `make iso` runs the same stages locally. The workflow publishes nothing.
It is the entry workflow, so later nodes (S05 attest, O02 boot jobs) join the same file and Sigstore binds to it.

## Scope
In:
- `build.yml` jobs `plan`, `packages`, `image`, the artifact contract between them and to downstream jobs.
- `make iso` and the stage targets as one sequence shared by CI and local use.
- The shared helpers: plan, collect-manifest, verify-artifacts, preflight, retry.
- The assertion that this workflow never publishes (Principle 7).

Out:
- Building the builder image: I03 (own workflow); B06 only pulls it by digest from the pins.
- Portage snapshot sync, distfile mirror, store backends: I02, I04, I01/F06 (B06 calls `make sync-portage`).
- Boot-test jobs: O02-O05. SBOM and gates: S01-S04. Attest/provenance job: S05. Release and publication: P02, P03.
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
`BUILD_VERSION=<BUILD_EPOCH>-<7-char sha>` (`build.yml:203-207`). `SOURCE_DATE_EPOCH` and `BUILD_EPOCH` come from
`pins/pins.yaml` through I05's reader. The builder image is referenced by digest from the pins, never by tag
(contradiction: the predecessor pulled `gentoo/stage3` and builder by tag).

### Jobs
All jobs: `runs-on: ubuntu-24.04` (a pinned runner label, not `latest`), `timeout-minutes` set, `permissions:
contents: read` at workflow level, every `uses:` pinned to a 40-hex SHA (F01 lint repeats the check).
1. **plan** (5 min). `make plan` writes outputs: `mode`, `build-version`, `source-date-epoch`, `builder-digest`,
   `run-build` (false for PRs without the label, which makes the other jobs skip). Runs `make preflight`
   (below) on the host runner image to record resources.
2. **packages** (`needs: plan`, 300 min). `permissions: packages: write` only when `mode=iterate` and the event is
   not a fork PR (the binpkg save in B01); otherwise `packages: read`. Steps: checkout; retry-wrapped
   `docker pull ...@<digest>`; `make sync-portage` (I02); `make packages kernel` (B01, B02); `git diff --exit-code`
   (nothing tracked was written); `make collect-packages`; upload artifact `packages-<run_id>` containing
   `out/packages/`, `out/kernel/`, `out/stage/`, `out/logs/`, `SHA256SUMS` (`compression-level: 0`,
   `overwrite: true`, `retention-days: 7`). On failure: upload `out/logs/` (name `logs-packages-<run_id>`).
3. **image** (`needs: packages`, 60 min). Download `packages-<run_id>`; `verify-artifacts` (hashes against
   `SHA256SUMS`); `make rootfs initrd iso-image` (B04, B03, B05); `make collect-manifest`; write `SHA256SUMS`;
   upload artifact `iso-<run_id>` (same settings, `retention-days: 14`) with: the ISO, squashfs, initrd,
   `vmlinuz`, `resolved-kernel.config`, `rootfs.manifest.tsv`, `initrd.manifest.tsv`, `build-manifest.json`,
   `out/stage/*.json`, `SHA256SUMS`. Job outputs: `iso-sha256`, `squashfs-sha256`, `build-version`, `mode`.
   Failure logs uploaded as above.
Downstream jobs (O02..., S01..., S05 in this file) declare `needs: image`, download `iso-<run_id>`, and run
`verify-artifacts --expect-iso-sha256 ${{ needs.image.outputs.iso-sha256 }}`; a mismatch is exit 4.
Decision: Actions artifacts for the in-run handoff, with `overwrite: true` and a content hash passed as a job
output. Rejected: `actions/cache` keyed by run id (the predecessor's `ci-artifacts-<run_id>-iso`). A cache entry is
immutable, so re-running a job restored the bad ISO (T-run-rerun-reuses-cache). Rejected: the store `build` class
(persists an unvetted ISO under a stable key; P02 owns that after the oracle).
Two heavy jobs, not one: `image` can be re-run in minutes without recompiling, and its gate runs on the gpkg set
alone. Rejected: the predecessor's single job (a failure in `iso` cost a full-job re-run).

### Publishes nothing
No job in `build.yml` that B06 owns writes the store classes `public` or `build`, creates a release or tag, writes
a pages or dashboard path, moves a `latest` pointer, or holds `id-token` or `attestations` permission. The only
store write is the `binpkg` cache in `packages` (iterate, non-fork). The predecessor uploaded `latest` kernel,
squashfs, initrd and ISO before boot-test ran (`build.yml:495-546`, workflows.yaml note); that is the shape this
rule forbids. S05 adds an attest job to this same file later with its own permissions; the shape test treats the
three B06 jobs as the checked set.

### Local parity
`make iso` = `sync-portage`, `packages`, `kernel`, `rootfs`, `initrd`, `iso-image`, in that order, each target a
`run-in-builder <stage>` call; `make build-all` adds the collect steps. CI `run:` lines are `make <target>` only
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
- **D-tag-builds-from-source:** tag gives `mode=release`; the job asserts B01's provenance TSV. AC-1, AC-9.
- **Principle 7 (publish last):** this workflow publishes nothing. AC-2.
- **Principle 1 (no vendor in workflows):** no `aws`, `oras` or `curl` in `run:`; store via `make`. AC-4.
- **Principle 5:** hashes verified at every hand-off; failed checks exit non-zero. AC-3, AC-5.
- **SPEC §8 entry workflow:** tags trigger `build.yml`; the header comment from `:3-17` is kept. AC-4.

## Gate
- **B06-AC-1** — `plan-build` maps `refs/tags/v1.2.3` to `mode=release, BUILD_VERSION=1.2.3`, `refs/tags/v1.2.3-rc1` to `1.2.3-rc1`, a malformed tag to exit 2, master and PR refs to `iterate` with `<BUILD_EPOCH>-<sha7>`, and honours the dispatch `mode` input. *Verify:* `tests/fast/build-plan.test.sh`. *Tier:* fast.
- **B06-AC-2** — `build.yml` contains no step that writes the store classes `public` or `build`, creates a release or tag, calls `gh release`, pushes to pages, or moves `latest`; jobs `plan`, `packages`, `image` hold neither `id-token` nor `attestations`, and `packages: write` appears only in `packages`. *Verify:* `tests/fast/workflow-publishes-nothing.test.sh`. *Tier:* fast.
- **B06-AC-3** — `verify-artifacts` exits 0 on a consistent directory, 3 on a missing or zero-byte listed file, 4 on a changed byte or on an ISO hash different from `--expect-iso-sha256`; both upload steps set `overwrite: true`; no `actions/cache` handoff exists. *Verify:* `tests/fast/artifacts-verify.test.sh`, `tests/fast/workflow-shape.test.sh`. *Tier:* fast.
- **B06-AC-4** — Every `run:` line in `build.yml` is on the allowed list (`make`, `sha256sum`, `git`, `docker pull|login`, `echo|printf … >> $GITHUB_OUTPUT`); no `curl`, `wget`, `aws`, `oras`, `docker run`, or `factory/bin/*` call; every `uses:` is a 40-hex SHA; every job has `timeout-minutes`; the entry-workflow header comment is present. *Verify:* `tests/fast/workflow-shape.test.sh`. *Tier:* fast.
- **B06-AC-5** — `collect-manifest` output is byte-identical for identical stage records, contains `layers.{kernel,initrd,squashfs,iso}` and a separate `run` object, and fails (exit 3) if any stage record is missing. *Verify:* `tests/fast/artifacts-manifest.test.sh`. *Tier:* fast.
- **B06-AC-6** — `retry` succeeds when the command passes on attempt 3 of 6, returns the last status after exhausting attempts, and sleeps the configured delay (via `RETRY_SLEEP`). *Verify:* `tests/fast/retry.test.sh`. *Tier:* fast.
- **B06-AC-7** — Builder pull, tool installation and any network `make` target used by the workflow call `retry`; the pull uses `@sha256:` from the pins and never a tag. *Verify:* `tests/fast/workflow-shape.test.sh`, `tests/fast/make-parity.test.sh`. *Tier:* fast.
- **B06-AC-8** — `preflight` exits 4 when MemTotal or free disk is below `budgets.yaml`, 0 otherwise, and prints both values. *Verify:* `tests/fast/preflight.test.sh` (fake meminfo and df). *Tier:* fast.
- **B06-AC-9** — Stage sequence parity: the targets in `build.yml` `run:` lines, in job order, equal the sequence `make -n iso` expands to (ignoring plan and collect steps); `docs/system.yaml` lists the new workflow, jobs, scripts and targets. *Verify:* `tests/fast/make-parity.test.sh`; F03 inventory check in the fast lane. *Tier:* fast.
- **B06-AC-10** — A `full-ci` PR run yields artifact `iso-<run_id>` whose downloaded ISO has the sha256 in `needs.image.outputs.iso-sha256`, the `image` job re-run alone succeeds and replaces the artifact, and the downstream `verify-artifacts` accepts only the new hash. *Verify:* CI run on a labelled PR plus a manual "re-run job: image", recorded in the PR table. *Tier:* slow.
- **B06-AC-11** — A tag or `mode=release` dispatch run passes B01-AC-7 (no `cache` rows) and the log shows the binpkg store was neither read nor written. *Verify:* CI job `packages` on a `v0.0.0-ci` style dispatch, assertion step. *Tier:* slow.
- **B06-AC-12** — `make iso` on a clean checkout with a seeded `fs` store produces an ISO whose `layers.*` hashes equal those of the CI run for the same commit and pins, or each difference is a B07 known difference. *Verify:* B07 compare job (local vs CI layer lists). *Tier:* slow.

## RED plan
Tester writes first, failing because nothing exists: `build-plan` (tag and ref table), `workflow-shape` and
`workflow-publishes-nothing` (parse YAML with PyYAML; first fixture is a copy of the predecessor `build.yml`
excerpt with `actions/cache` and `aws s3 cp`, which must fail), `artifacts-verify` (tamper one byte),
`retry`, `preflight`, `make-parity` (compares YAML `run:` targets with `make -n iso`; fails until both exist).
No Docker or network.

## Risks and open questions
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
Slices: (1) plan-build, retry, preflight, verify-artifacts, collect-manifest with tests; (2) `build.yml` skeleton +
shape/publishes-nothing/parity tests; (3) `packages` job end to end; (4) `image` job and handoff; (5) release-mode
run and local parity. About 5 slices. CI cycles: 4 or more slow runs, each cold-ish 30-60 min for `packages` until
the cache exists, then minutes. Money: Actions artifact storage (about the size of `packages` plus the ISO, 7-14 day
retention, unmeasured) and runner minutes; free tier on a public repo, unknown otherwise.

## Spec defects found
- graph.yaml gives B06 deps `[B05, F03]` but the workflow reads pins (I05) and calls `make sync-portage` (I02);
  add `I05` to B06 (and B01).
- SPEC §4.1 says artifacts move as "Actions artifacts or cache entries keyed by run id". Cache entries are
  immutable and caused T-run-rerun-reuses-cache; the SPEC should say Actions artifacts only.
- graph.yaml's M01 depends on B06 and O02 but `build.yml` here has no schedule; M01 must own its own
  workflow that dispatches `build.yml`.
