# M01 — pin-bump-automation

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| M | B06, O02, I05 | M02, M04, X01 | — | M |

**Owns:** `.github/workflows/pin-bump.yml`, `.github/workflows/pin-bump-report.yml`, `factory/bin/pin-check`, `factory/bin/pin-apply`, `factory/bin/lock-diff`, `docs/pin-bump.md`, `tests/fast/pin-check.test.sh`, `tests/fast/pin-apply.test.sh`, `tests/fast/lock-diff.test.sh`, `tests/fast/pin-bump-workflow.test.sh`, `tests/fast/pin-bump-fixtures/`.
**Carries from linux-live-iso-factory@b9f533b:** `.github/workflows/pin-bump.yml` (shape only: weekly cron, `target_epoch` dispatch input, concurrency group, `pins/bump-*` branch naming, PR body sections); `scripts/update-build-pins.sh` (`verify_portage_snapshot` idea, fail-closed sed read-back at :150-160, `cmd_update` flow); `docs/version-pinning.md` (two-pin model text, fixup loop at :330-356). Nothing from `scripts/update-versions.sh`; versions.lock regeneration is R02's.
**Study refs:** workflows.yaml `wf.pin-bump`, `job.pin-bump.check`, `job.pin-bump.bump-and-validate`, contradictions (docs vs `--admin` merge), open_questions (bypass grant never observed); doctrine.yaml T-pin-bump-false-green, T-pin-bump-root-owned-locks, T-builder-image-tag-not-pushed, T-workflow-push-needs-pat, T-canary-silence, T-nethack-5-from-epoch-bump, T-portage-snapshot-fetch, D-two-epoch-pin-model, DEC-pin-bump-auto-merge (superseded here), D-state-and-no-hidden-stderr; SPEC §8 "Humans merge".

## Purpose
After this node a scheduled workflow proposes `BUILD_EPOCH` bumps as pull requests that the ordinary PR checks (B06 build, O02 core oracle) validate, and a human merges. The predecessor merged its own bumps with `gh pr merge --squash --admin`, contradicted its own docs, and its two observed "green" runs were no-op checks. This node makes a bump visible, honestly validated and human-merged.

## Scope
In:
- Weekly freshness check for the next Gentoo snapshot epoch; no-op runs are reported as no-ops, never as validation.
- Mirroring the new snapshot into the store through I02's tool, then applying the bump to `pins/pins.yaml` and regenerating `pins/versions.lock` in the pinned builder image.
- Opening one PR per bump from a token that makes the PR's checks run; a draft PR when anything failed.
- A report job that posts the lock diff and per-check results on the PR.
- A fast test that no workflow can merge.
Out:
- The mirror tool and the store: I02, F06, I01. This node calls them.
- `versions.lock` regeneration and its format validator: R02. This node only runs R02's command and asserts a clean result.
- `TOOLCHAIN_EPOCH`, stage3, crossdev, builder image: M02.
- Action SHAs and tool versions: M04.
- The build workflow and oracle jobs themselves: B06, O02.
- Branch protection settings (a repository setting, not code): recorded as evidence in `docs/pin-bump.md`, see Risks.

## Design

### Flow
`pin-bump.yml` triggers: `schedule` Monday 06:00 UTC, `workflow_dispatch` with optional `target_epoch` (`YYYYMMDD`). `concurrency: pin-bump`, no cancel. Top-level `permissions: contents: read`; the `propose` job adds `contents: write`, `pull-requests: write`, `packages: read`.

1. `check` job runs `factory/bin/pin-check build-epoch [--target YYYYMMDD]`.
2. `propose` job (only if `check` printed `action=bump`):
   a. Pull the builder image by `builder_image.repo@builder_image.digest` from `pins/pins.yaml`, never a tag (T-builder-image-tag-not-pushed).
   b. `factory/bin/snapshot-mirror --epoch NEW` (I02) fetches, GPG-verifies and puts `gentoo-NEW.tar.xz[.gpgsig]` into class `snapshot`. Exit non-zero aborts the run.
   c. `factory/bin/pin-apply build-epoch NEW`.
   d. Run R02's regeneration command inside the builder container (the builder ships no tree, so the command first stages the new snapshot with I02's `snapshot stage` and `snapshot webrsync`) with `--user "$(id -u):$(id -g)"`, bind-mounting `pins/`. The container never runs as root, so the files stay owned by the runner (T-pin-bump-root-owned-locks). Rejected: the predecessor's `sudo chown -R` after the fact.
   e. Run R02's validator on the new lock. A non-zero exit is a failure.
   f. Commit as the bot identity (OD-4 default `monolith-agent[bot]`), push `pins/build-epoch-OLD-NEW`, open the PR.

### `pin-check`
`factory/bin/pin-check build-epoch [--target YYYYMMDD]`, Python 3 stdlib + PyYAML. Reads `epochs.build` with I05's `pin get`. Candidate = `--target`, else the newest `gentoo-YYYYMMDD.tar.xz` listed at the snapshot index (`PIN_SNAPSHOT_BASE_URL`, default `https://distfiles.gentoo.org/snapshots/`). The candidate is valid only if both `.tar.xz` and `.tar.xz.gpgsig` answer HTTP 200. Output, one line each on stdout: `current=…`, `candidate=…`, `action=bump|noop`, `reason=…`.
- HTTP 404 on the candidate means "not published yet": `action=noop`, reason says so, exit 0.
- Any other HTTP status, DNS or TLS failure: exit 1, message on stderr. A network error is never a no-op (SPEC §2.5).
- Candidate <= current: `action=noop`.
- The Docker Hub stage3 tag is not consulted. Rejected: the predecessor used the stage3 date as the freshness signal (`scripts/update-build-pins.sh:30-77`), which coupled the routine pin to the toolchain pin and caused the false green.

A `noop` run ends with a job summary headed `NO-OP (nothing validated)`. No PR, no label, no status.

### `pin-apply`
`factory/bin/pin-apply build-epoch NEW SNAPSHOT_SHA256 GPGSIG_SHA256`: a scope-checking wrapper over I05's `pin set`. It sets `epochs.build` to NEW and adds `snapshots.NEW.{sha256,gpgsig_sha256}` (the digests printed by `snapshot-mirror`); `SOURCE_DATE_EPOCH` is derived by `pin sde` and never stored (I05), so there is nothing to keep in step. Then it runs `pin diff HEAD` and exits 1 unless exactly those keys changed, i.e. nothing under `epochs.toolchain`, `base_image`, `builder_image`, `tools`, `actions`, `rust` or `files` moved. It exits 1 if NEW is not eight digits, if NEW <= current, or if `epochs.build` is missing; `pin get epochs.build` must read back NEW. Exit 10 means "already at NEW" (idempotent no-op). Rejected: `sed` on a Dockerfile `ARG` line and on `SOURCE_DATE_EPOCH`, which failed silently when the format drifted (the predecessor needed a post-hoc read-back to compensate).

### `lock-diff`
`factory/bin/lock-diff OLD.lock NEW.lock` prints Markdown: counts (added, removed, changed), a table of changed atoms (`cat/pkg  old -> new`), and a bold **MAJOR** marker where the first version component changes or the package is `sys-kernel/monolith-kernel`, `sys-libs/musl`, or `sys-devel/gcc`. A bump that reaches nethack 5.x (T-nethack-5-from-epoch-bump) shows up as MAJOR in the PR body instead of in a failed build.

### Opening the PR
Push and PR creation use a token that is not `GITHUB_TOKEN`, because pushes and PRs made with `GITHUB_TOKEN` do not start `pull_request` workflows. The token is the secret `BUMP_TOKEN`: a fine-grained PAT or the OD-4 bot's App token, scoped to this repository with `contents:write`, `pull-requests:write`, `metadata:read`, and no `workflows` scope. Its rotation is the owner's (T-workflow-push-needs-pat); the token is passed through the environment (`GH_TOKEN`), never written to `.git/config`.

Validation is the PR's own required checks (B06 build plus O02 core oracle), which run because the PR was opened by a non-`GITHUB_TOKEN` actor. The workflow does not dispatch `build.yml`, poll, or wait. Rejected: the predecessor's `gh workflow run build.yml --ref …` plus a 240-minute poll inside a 280-minute job, which burned a runner for the whole build, could be killed by the 360-minute cap, and produced a `validated` label that could go stale.

Failure paths. If `snapshot-mirror`, `pin-apply`, the lock regeneration or the validator fails, the job pushes the branch with whatever was produced, opens a **draft** PR labelled `pin-bump,needs-fixup` with the failing step and log excerpt, and exits 1. A draft PR cannot be merged until a human marks it ready. Rejected: the predecessor's non-draft `needs-fixup` PR.

Deduplication. If an open PR from a branch matching `pins/build-epoch-*` exists, `propose` prints a notice naming it and exits 0 without creating another. One bump in flight at a time.

### `pin-bump-report.yml`
Triggered by `workflow_run` of `build.yml` (completed) where `head_branch` starts with `pins/build-epoch-`. Reads the run's job conclusions with the API, then edits the PR: comment with a table (check name, conclusion, link), label `validated` only when every required job concluded `success` and the head SHA of the run equals the PR head SHA, else `needs-fixup`. It never merges, approves or enables auto-merge. Rejected: encoding results in the PR body at creation time (the body is stale the moment a fixup commit lands).

### PR body
Sections: pin delta (`BUILD_EPOCH OLD -> NEW`, snapshot sha256 from the store), `lock-diff` output (first 200 changed lines, link to full diff), what is validated by which required checks, and the fixup loop (push to the same branch; the PR checks re-run on push, no manual dispatch needed). `docs/pin-bump.md` replaces the predecessor's `docs/version-pinning.md` sections on automation and states in its first paragraph: bumps are never merged by automation.

### No-merge guard
`tests/fast/pin-bump-workflow.test.sh` greps every file under `.github/workflows/` and `factory/` for `gh pr merge`, `--admin`, `--auto`, `enableAutoMerge`, `merge_pull_request`, `pulls/*/merge` and `gh pr review --approve`, and fails on any hit. It also asserts `pin-bump.yml` and `pin-bump-report.yml` declare `permissions:` at workflow level with no `pull-requests: write` outside `propose` and `report`.

## Traps and doctrines preserved
- **T-pin-bump-false-green:** a bump PR that changed nothing validated green. Prevented by M01-AC-2 (404 and error semantics), M01-AC-3 (read-back, no-change refusal) and M01-AC-4 (no-op reported as no-op).
- **T-pin-bump-root-owned-locks:** `git add` failed on root-owned locks. Prevented by M01-AC-6 (runner-owned files, non-root container).
- **T-builder-image-tag-not-pushed:** a tag that was never pushed gave 404. Prevented by M01-AC-7 (pull by digest from pins).
- **T-workflow-push-needs-pat:** `GITHUB_TOKEN` pushes start no workflows, default PATs cannot push workflow files. Prevented by M01-AC-8 and the no-`workflows`-scope rule (the bump never touches workflow files; `pin-apply` refuses other paths).
- **D-two-epoch-pin-model:** a `BUILD_EPOCH` bump must not rebuild or re-pin the builder. Prevented by M01-AC-3 (only `epochs.build` and the new `snapshots` entry may change) and M01-AC-7.
- **D-state-and-no-hidden-stderr:** the predecessor piped the bump step through `tee` and hid exit codes. Prevented by M01-AC-9 (lint: no `| tee` or `2>/dev/null` on deciding steps, `set -euo pipefail`).
- **SPEC §8 "Humans merge":** Prevented by M01-AC-1.
- **T-nethack-5-from-epoch-bump:** an epoch bump silently pulled a major version. Prevented by M01-AC-5 (MAJOR marker in the PR).
- **T-canary-silence:** GitHub disables `schedule` after 60 idle days. A weekly bump PR keeps the repo active; M01-AC-10 makes a silent schedule visible.

## Gate
- **M01-AC-1** — No workflow or factory script can merge, approve or auto-merge a PR or use `--admin`. *Verify:* `tests/fast/pin-bump-workflow.test.sh` (grep set above, plus a planted-violation fixture that must fail the check). *Tier:* fast.
- **M01-AC-2** — `pin-check build-epoch` returns `action=noop` exit 0 when the candidate is unpublished (404 on tarball or signature) or not newer, and exits 1 with a stderr message on 5xx, timeout, DNS or TLS failure. *Verify:* `tests/fast/pin-check.test.sh` against `file://` fixture trees and a fixture server returning 404, 500 and a dropped connection. *Tier:* fast.
- **M01-AC-3** — `pin-apply build-epoch NEW` changes only `epochs.build` and adds `snapshots.NEW`, reads the value back with `pin get`, exits 1 on a missing key, a malformed or non-increasing NEW, or any other key differing per `pin diff`, and exits 10 when already at NEW. *Verify:* `tests/fast/pin-apply.test.sh` with a fixture `pins.yaml` (I05 schema 1) and a `pin diff` assertion. *Tier:* fast.
- **M01-AC-4** — A run with no newer snapshot ends with the summary heading `NO-OP (nothing validated)`, creates no branch, PR or label, and a run that created a PR never carries that heading. *Verify:* `tests/fast/pin-bump-workflow.test.sh` runs the `propose` step script with `PIN_CHECK_ACTION=noop` under stubbed `git` and `gh` and asserts zero calls to either. *Tier:* fast.
- **M01-AC-5** — `lock-diff` reports added, removed and changed counts and marks a first-component version change, and any change of the kernel, musl or gcc, as **MAJOR**. *Verify:* `tests/fast/lock-diff.test.sh` with two fixture locks including a 3.6.7 -> 5.0.0 change. *Tier:* fast.
- **M01-AC-6** — After the regeneration step, every file in `git status --porcelain` is owned by the invoking uid, and the container ran with `--user`. *Verify:* `tests/fast/pin-bump-workflow.test.sh` asserts the `docker run`/`podman run` line carries `--user "$(id -u):$(id -g)"` and no `sudo`; the slow run in M01-AC-11 checks ownership with `find . -not -user "$(id -u)"` and fails on any output. *Tier:* fast + slow.
- **M01-AC-7** — The propose job pulls the builder image as `…@sha256:<digest>` taken from `pins/pins.yaml`, and the diff of a `BUILD_EPOCH` bump touches no `builder_image`, `base_image`, `epochs.toolchain` or `files` key. *Verify:* `tests/fast/pin-bump-workflow.test.sh` (no `:latest`, no `${REGISTRY_TAG}` in the pull step) and `tests/fast/pin-apply.test.sh` (diff scope). *Tier:* fast.
- **M01-AC-8** — The workflow pushes and opens the PR with `BUMP_TOKEN` in `GH_TOKEN`, declares no `workflows` permission, runs no `gh workflow run` or polling loop, and a failure at any step opens a **draft** PR labelled `needs-fixup` and exits non-zero. *Verify:* `tests/fast/pin-bump-workflow.test.sh` with stubbed `gh` recording `pr create --draft` for each injected failure (mirror, apply, regenerate, validate). *Tier:* fast.
- **M01-AC-9** — Every `run:` block in `pin-bump.yml` starts with `set -euo pipefail`; none contains `| tee`, `2>/dev/null` or `|| true`; `actionlint` and `shellcheck` pass. *Verify:* `tests/fast/pin-bump-workflow.test.sh` plus the F01 lint lane. *Tier:* fast.
- **M01-AC-10** — The schedule is present and a dispatch with `target_epoch` bypasses discovery but not the snapshot-published check. *Verify:* `tests/fast/pin-bump-workflow.test.sh` (cron string, input name) and `tests/fast/pin-check.test.sh --target` case. *Tier:* fast.
- **M01-AC-11** — A real dispatch with a known-published older-than-latest `target_epoch` on a throwaway branch produces a PR whose diff contains the intended epoch and a regenerated `versions.lock`, whose build and core-oracle checks ran as PR checks, and whose report comment and label match those checks. *Verify:* CI job `pin-bump-e2e` (`workflow_dispatch` only, run once at node acceptance and recorded in the PR table); the PR stays unmerged. *Tier:* slow.
- **M01-AC-12** — Only one bump PR is open at a time: a second run with an open `pins/build-epoch-*` PR exits 0 with a notice naming it and creates nothing. *Verify:* `tests/fast/pin-bump-workflow.test.sh` with stubbed `gh pr list` output. *Tier:* fast.
- **M01-AC-13** — `docs/pin-bump.md` states that automation never merges, names `BUMP_TOKEN` and its scopes, and the repo contains no remaining text claiming auto-merge. *Verify:* `tests/fast/pin-bump-workflow.test.sh` (grep for `auto-merge` outside quoted history, and for the three required statements). *Tier:* fast.

## RED plan
In order, each a `test(M01)` commit with `TDD-Red-Target: make test-fast`: `pin-bump-workflow.test.sh` first (fails because the workflow does not exist; it carries the planted no-merge violation fixture), then `pin-apply.test.sh` and `pin-check.test.sh` (fail: the tools are absent), then `lock-diff.test.sh`. Fixtures under `tests/fast/pin-bump-fixtures/` are committed with the tests so the implementer cannot weaken them (F04 protects them after RED).

## Risks and open questions
- Hardest: the PR's required checks only run if B06 triggers `build.yml` on `pull_request` for `pins/**` branches and O02 jobs are required. B06 owns that trigger; if it chooses `workflow_dispatch` only, this node has no validation to report. See defects.
- `BUMP_TOKEN` is a long-lived credential with write access. Owner decision: PAT with expiry versus a GitHub App (OD-4). Default: fine-grained PAT, 90-day expiry, rotation noted in `docs/pin-bump.md`.
- Branch protection must forbid bypass for bots and require human review; that is a repository setting this node cannot test from code. `docs/pin-bump.md` records the expected settings and the date the owner confirmed them. Unknown today: whether the predecessor's `--admin` ever succeeded (workflows.yaml open_questions).
- A cold build per bump (weekly): the tree hash changes, so the binpkg cache misses. One build is 30-60 minutes and one core oracle pass; see Cost.
- Weekly cadence is inherited; a monthly cadence halves cost. Owner may change the cron without a spec change.
- Unknown: how I02's mirror tool is invoked (`snapshot-mirror` is the name assumed here).

## Cost
Two to three agent slices: (1) `pin-check`, `pin-apply`, `lock-diff` with fast tests; (2) `pin-bump.yml`, `pin-bump-report.yml`, the workflow test; (3) docs and the one-time `pin-bump-e2e` run. CI: one build + core oracle cycle per real bump (about 1-1.5 hours of runner time); one cycle at acceptance. Money: runner minutes only (free on a public repository; unknown whether this repository is public). Store: one snapshot (about 150 MB, kept forever by M03).

## Spec defects found
- graph.yaml: M01 does not depend on I05 (`pins/pins.yaml` writer and schema), I02 (snapshot mirror) or R02 (lock regeneration) directly. I02 and R02 are reachable through B06; I05 is not reachable from B06 at all. Add M01 -> I05.
- graph.yaml: M02 and M04 also edit `pins/pins.yaml` and lack the I05 edge (M02 gets it only through M01 if the edge is added).
- SPEC §8 protects `pins/pins.yaml` ("agents may not edit"). A bot-authored bump PR edits it. Clarify that the workflow bot may open PRs touching it and that CODEOWNERS review is the control.
- SPEC §8 "Bots ... post statuses": the report job sets a label and a PR comment, not a status. Harmless, but state which is meant.
- B06 summary says "no publishing" and does not say it runs on `pull_request`; M01 requires it for `pins/**` branches.
