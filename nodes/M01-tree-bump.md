# M01 — tree-bump

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | P02 | M02, X01 | — | M |

**Owns:** `.github/workflows/pin-bump.yml`, the deletion of `.github/workflows/regen-pins.yml`, `scripts/update-build-pins.sh`, `scripts/update-versions.sh`, `scripts/tests/pin-bump.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `.github/workflows/pin-bump.yml` (396 lines), `scripts/update-build-pins.sh` (400), `scripts/update-versions.sh` (221), `docs/version-pinning.md`.
**Study refs:** workflows.yaml `wf.pin-bump`; T-pin-bump-root-owned-locks, T-workflow-push-needs-pat, D-two-epoch-pin-model; Principle 9; SPEC §8.

## Purpose
After this node a weekly workflow proposes a new Gentoo tree as a pull request. The PR moves `TREE_COMMIT` and `TREE_DIGEST` and regenerates `versions.lock`. The ordinary Build workflow validates it and a human merges it. The first such bump moves the project off rc1's tree (OD-6).

## Standard mechanism
- Dependabot and Renovate update action SHAs and file-pinned versions. Neither can archive a tree to the registry or regenerate `versions.lock` inside the builder, so they cannot do this bump. Dependabot stays for action SHAs.
- `actions/create-github-app-token` yields a token that is not `GITHUB_TOKEN`, so PR checks run (OD-11).
- Branch protection and CODEOWNERS control merging.
- Custom code: the ported scripts, edited. Gap: the tree pin is a commit, not a dated snapshot, and the ported `update-build-pins.sh` finds the next snapshot on `distfiles.gentoo.org` and Docker Hub (`update-build-pins.sh:122-160`). The snapshot tarballs are gone (SPEC §0).

## Changes from the port
Carried unchanged: the weekly cron and `workflow_dispatch` input shape, `concurrency: pin-bump`, the branch-per-bump naming, label creation, the PR body, the `sudo chown -R` that fixes root-owned lock files (`pin-bump.yml:221`, T-pin-bump-root-owned-locks), and `update-versions.sh` (the 23-atom drift fix is B01's).

1. **No `--admin` merge.** Remove the "Auto-merge on fully-green validation" step (`pin-bump.yml:380-396`, `gh pr merge --squash --admin --delete-branch`). The header comments that describe auto-merge (`:32`, `:376-379`) go too. Bots never merge (SPEC §2.9). *AC-1.*
2. **Credential.** The checkout push and `gh pr create` use an App installation token (OD-11 default), minted in the job with `actions/create-github-app-token`. The predecessor used `github.token` (`pin-bump.yml:134`). A PR opened with `GITHUB_TOKEN` starts no `pull_request` workflows. *AC-2.*
3. **Validation by the PR, not by dispatch and polling.** Replace `gh workflow run build.yml` (`:245`) and the 240-minute wait in a 280-minute job (`:131`) with: open the PR with the `full-ci` label, so `build.yml` runs through its existing pull-request gate (`build.yml:58-60`). The job ends when the PR exists. *AC-3.*
4. **Tree pin instead of epoch.** `update-build-pins.sh update` resolves the newest commit of `gentoo-mirror/gentoo` (default branch, or the `target_commit` dispatch input), archives it with I02's tool, and writes `TREE_COMMIT`, `TREE_DIGEST` and `SOURCE_DATE_EPOCH` (the commit's committer time, SPEC §6) in I02's format. It no longer touches `BUILD_EPOCH` or stage3. The builder pin is M02's. *AC-4.*
5. **S3 steps removed.** "Archive new portage snapshot to S3", the AWS login and `S3_BUCKET` env (`:160-205`). I01 owns this globally. The builder is pulled by digest (I03).
6. **No-PR runs say so.** When the newest commit equals `TREE_COMMIT`, the job summary starts with `NO-OP`, and no branch, label or PR is created. A failed `gh pr create` fails the job. The predecessor's 2026-10-26 run succeeded and opened no PR; I did not establish why (Actions history of the old repository, unverified). *AC-5.*
7. **`regen-pins.yml` deleted.** It regenerated lock files on `integration/**` pushes and carried an AWS step (`regen-pins.yml:110-115`); F01 left it dispatch-only. `update-versions.sh` run by this workflow and by B01 covers it. *AC-1.*
8. **Permissions.** Workflow level `contents: read`. The bump job adds `contents: write` and `pull-requests: write`. `actions: write` and `issues: write` (`:132-137`) go, since nothing dispatches or comments. *AC-6.*

## Gate
- **M01-AC-1** — `regen-pins.yml` is gone, and no workflow contains `gh pr merge`, `--admin`, `--auto`, `enableAutoMerge` or `gh pr review --approve`. *Verify:* `scripts/tests/pin-bump.test.sh` (grep of `.github/workflows/` with a planted-violation fixture that must fail). *Tier:* fast.
- **M01-AC-2** — `pin-bump.yml` creates its PR with a token from `actions/create-github-app-token`, and `GITHUB_TOKEN` is not used for push or `gh pr create`. *Verify:* `scripts/tests/pin-bump.test.sh`. *Tier:* fast.
- **M01-AC-3** — A bump PR carries the `full-ci` label and its Build run starts without a manual dispatch. `pin-bump.yml` has no `gh workflow run` and no polling loop. *Verify:* grep in the fast test; the e2e dispatch below. *Tier:* fast + slow.
- **M01-AC-4** — The changed files of a bump are within the tree pin (I02's files), `versions.lock` and the labels; `BUILD_EPOCH`, stage3 and builder pins are untouched. `update-build-pins.sh` makes no request to `distfiles.gentoo.org` or Docker Hub. *Verify:* `scripts/tests/pin-bump.test.sh` against a fixture repository and a stubbed `git ls-remote`, `curl` and archive tool. *Tier:* fast.
- **M01-AC-5** — With the newest commit equal to `TREE_COMMIT`, the script exits 0, prints `NO-OP`, and creates no branch. *Verify:* `scripts/tests/pin-bump.test.sh`. *Tier:* fast.
- **M01-AC-6** — Declared permissions are `contents: read` at workflow level and at most `contents: write`, `pull-requests: write`, `packages: read` in the bump job. *Verify:* `scripts/tests/pin-bump.test.sh`. *Tier:* fast.
- **M01-AC-7** — A real dispatch opens a PR that moves `TREE_COMMIT` off rc1's tree, whose Build run passes B03's checks, and which a human merges. *Verify:* the PR and its Build run URL. This is the first bump, after MS2. *Tier:* slow.

## Risks
- OD-11: GitHub App or fine-grained PAT. App is the default; the owner creates it. Workflow-file changes still need the owner's token (T-workflow-push-needs-pat); a bump touches none.
- OD-15: the CVE gate on a new tree may need waiver changes in the same PR.
- A tree move is a full rebuild: the cache tag includes `TREE_COMMIT` (SPEC §6), so the PR's run is cold (about 78 minutes for `build`, predecessor measurement), and `master` pays another after the merge.
- Whether `gentoo-mirror/gentoo` HEAD is always a coherent tree (unverified).
