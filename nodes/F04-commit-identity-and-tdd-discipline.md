# F04 — commit-identity-and-tdd-discipline

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| F | F01 | F05 | — (feeds MS3) | L |

**Owns:** `tools/ci/identity-check.py`, `tools/ci/tdd-check.py`, `tools/ci/protected-check.py`, `tools/ci/policy.yaml`, `tools/ci/agent-env.sh`, `.github/workflows/discipline.yml`, `.github/CODEOWNERS`, `docs/repo-settings.md`, `tests/fast/identity-*.test.sh`, `tests/fast/tdd-*.test.sh`, `tests/fast/protected-*.test.sh`, `tests/fast/fixtures/discipline/`, the `trusted-check` Make target
**Carries from linux-live-iso-factory@b9f533b:** `scripts/agent-git-env.sh:50-60` (the `agent_git_clear_empty_identity` function) into `tools/ci/agent-env.sh`. Nothing else; the old repo had no discipline check.
**Study refs:** T-git-empty-identity (`AGENTS.md:75-110`, `scripts/agent-git-env.sh`), T-handoff-as-patch, the identity mess below, D-state-and-no-hidden-stderr; model: strange-company `verify.yaml` `tdd-discipline` job and `mode` job (CD-58, CD-62 in `plans/reviews/consolidation-decisions.md`), `.claude/hooks/guard.py:26-31,123-143`; SPEC Principles 6, 8, 10 and §8, §11; OD-4.

## Purpose
After F04, a PR that is not by an allowed identity, that mixes up RED and GREEN, that edits tests after they were frozen, or that touches a protected path as an agent, fails CI. The checks run from the PR's base revision, so the PR cannot change the rules that judge it. This is the mechanical half of the test-first process: F05's agents rely on it, and a human merging a PR reads one green or red status instead of auditing history by eye.

## Scope
In:
- Identity check: author, committer and co-author allowlist and trailer format, for PR commits and for commits landing on the default branch.
- TDD discipline check: RED commit validity, GREEN at head, frozen tests, slow-only declaration.
- Protected-path check for agent-authored PRs.
- The trusted-base execution pattern and `make trusted-check`.
- `.github/workflows/discipline.yml`, `.github/CODEOWNERS`, `docs/repo-settings.md` (the owner-side settings list).
- `tools/ci/agent-env.sh`: gives an agent session the bot identity and clears empty identity variables.

Out:
- The agents, skill and guard hook that follow these rules locally: F05.
- The fast runner and its exit codes: F01 (F04 relies on its protocol).
- Graph and inventory validators: F02, F03 (F04 only runs them from base).
- Setting branch protection, required checks, squash defaults, the bot account, the GitHub profile name: owner actions (listed in `docs/repo-settings.md`; OD-4 for the bot).
- Slow-tier evidence at GREEN: F05's skill collects it; F04 does not run builds.

## Design

### Why the old repo needs this
`git log` of the old repo at `b9f533b` shows these authors, none mechanically prevented: `Tucker McLean` (171 commits), `tuckermclean` (57; same email `me@tuckermclean.com`, committer `GitHub`; the squash-merge default when the profile name is empty), `Software Engineer <software-engineer@dcxxiv.local>` (1), `github-actions[bot]` (1). Co-author trailers across all commit bodies (`git log --format=%B | grep -i '^co-authored-by' | sort | uniq -c`): `Claude Opus 4.8 <noreply@anthropic.com>` (97), `Paperclip <noreply@paperclip.ing>` (5), `Tech Lead <tech-lead@dcxxiv.local>` (1), `Documentation Engineer <noreply@paperclip.ing>` (1), `monolith-ci[bot] <monolith-ci@users.noreply.github.com>` (1). Two key spellings coexist: `Co-Authored-By` (98) and GitHub's squash form `Co-authored-by` (7). The Claude form is the only one worth keeping.

### Policy file
`tools/ci/policy.yaml` (one file, read by all three checkers and by F05's guard, always from the revision the checker was started from):

```yaml
identity:
  humans:  ["Tucker McLean <me@tuckermclean.com>"]
  agents:  ["monolith-agent[bot] <*+monolith-agent[bot]@users.noreply.github.com>"]   # OD-4 default
  committers_extra: ["GitHub <noreply@github.com>"]      # web-flow squash merges only
  coauthors_extra:
    - "Claude <*> <noreply@anthropic.com>"
  trailer_key: "Co-Authored-By"
  allowed_trailers: [Co-Authored-By, TDD-Red-Target, TDD-Slow-Only, TDD-Test-Correction, Claude-Session]
tdd:
  subject_types: [test, feat, fix, docs, chore]
  red_targets: [test-fast]
  test_paths: ["tests/**", "oracle/fixtures/**", "oracle/tests/**"]
  slow_test_paths: ["oracle/**"]
protected_paths:
  - SPEC.md
  - docs/graph.yaml
  - ".github/workflows/release*.yml"
  - supplychain/policy/**
  - pins/pins.yaml
  - ".claude/**"
  - AGENTS.md
  - ".github/workflows/verify.yml"
  - ".github/workflows/discipline.yml"
  - ".github/CODEOWNERS"
  - tools/ci/**
  - tools/lint/**
  - tools/graph/**
  - tools/system/**
```

The first seven protected entries are the original core of SPEC §8's owner-review list; SPEC §8 now also names `.github/**`, `tools/ci/`, `tools/graph/`, `tools/system/`, `oracle/policy/` and `recipes/kernel/tier0-ceiling.txt`, and the implementer adds them to the policy so the two lists agree (F04-AC-11 compares them). The rest are additions argued under Spec defects. `*` in an identity pattern matches any run of characters except `<`, `>` and newline. Glob semantics for paths: `**` matches across `/`, `*` and `?` do not match `/`, and a newline in a path is an ordinary character matched by `*` (strange-company CD-68 found that Go's `.` missed `\n` and let `.github/x\ny` escape `.github/**`; the tests include a newline path).

### Identity rules (`tools/ci/identity-check.py`)
`python3 -I tools/ci/identity-check.py --root DIR --base REV --head REV [--mode pr|push] [--policy FILE]`. For every non-merge commit in `base..head`:
- `ID_AUTHOR`: author `Name <email>` matches `humans` or `agents`. One spelling per actor: `tuckermclean <me@tuckermclean.com>` fails.
- `ID_COMMITTER`: committer matches the same lists or `committers_extra`. Rejected: allowing any committer (the old `GitHub` committer then hides who rewrote a commit); allowing `GitHub` only in `--mode push`, which would break amended rebases in a PR, so it is allowed in both and the author rule is what binds.
- `ID_COAUTHOR_FORMAT`: every co-author trailer uses the key exactly `Co-Authored-By` (PR mode; push mode compares case-insensitively because GitHub's squash message writes `Co-authored-by`) and the value `Name <email>` with no trailing text.
- `ID_COAUTHOR_NOT_ALLOWED`: the value matches `humans`, `agents` or `coauthors_extra`, and is not repeated in the same commit. `Claude <model words> <noreply@anthropic.com>` is the only model form; `@dcxxiv.local` and `paperclip.ing` identities are rejected.
- `ID_TRAILER_UNKNOWN`: any trailer key outside `allowed_trailers` (so a stray `Signed-off-by` or `Reviewed-by` is a conscious change to the policy).
- `ID_SUBJECT`: the subject matches `^(test|feat|fix|docs|chore)(\([A-Z][0-9]{2}\))?: .+` with a node id present for `test`, `feat`, `fix`; at most 72 characters. SPEC §11 conventions.
- In `--mode pr`, the PR title and body are checked too, because a squash merge copies them into the commit message: the title must satisfy `ID_SUBJECT`, and any `Co-Authored-By` line in the body satisfies the co-author rules. `--pr-title` and `--pr-body-file` carry them.
Output and exit codes: `path-or-sha: CODE: message` lines, exit 0/1/2 (2 = bad input, unreadable policy, unknown revision). `--mode push` is run by `discipline.yml` on pushes to the default branch against `before..after`, so a drifted squash identity turns master red loudly. Owner action to avoid that: set the GitHub profile name to `Tucker McLean` (the lowercase `tuckermclean` author on 57 old commits is the empty-profile-name default).

### TDD rules (`tools/ci/tdd-check.py`)
`python3 -I tools/ci/tdd-check.py --root DIR --base REV --head REV --runner PATH [--report DIR]`. `DIR` is the PR's tree; `PATH` is the trusted base's `tools/ci/run-fast`. Commits are classified by subject type, linear history required (`TDD_MERGE_COMMIT`).

Commit kinds:
- `test(<ID>)` with trailer `TDD-Red-Target: <target> [TEST=<path>]` (RED). `<target>` must be in `red_targets` (`test-fast`). `TEST=` is optional, must be a path under `tests/fast/` ending `.test.sh` or `.test.py`, and the value charset is `[A-Za-z0-9_./-]`; anything else is `TDD_RED_TARGET_INVALID` (the lesson of strange-company CD-58c: trailer values must never reach a shell unvalidated; the checker passes them as arguments, never through a shell). Exactly one such line (`TDD_RED_TARGET_MISSING`, `TDD_RED_TARGET_DUP`).
- `test(<ID>)` with trailer `TDD-Slow-Only: <AC-id>[,<AC-id>...]` (slow-only test). Used when an AC's tier is slow and no fast RED can exist (for example an `oracle/` boot mode). Every listed AC must exist in `nodes/<ID>-*.md` at the PR head with `*Tier:* slow` (`TDD_SLOW_ONLY_INVALID`), and the fast tier must still pass at the commit.
- `feat(<ID>)`, `fix(<ID>)`: GREEN work.
- `docs`, `chore`: neither RED nor GREEN; may not touch frozen test files.

Checks:
1. `TDD_RED_NOT_TEST_ONLY`: a RED or slow-only commit changes only files matching `test_paths` (or `slow_test_paths` for slow-only). Rejected: strange-company's declared stubs (`SC-STUB`), because shell and Python tests report a missing implementation as exit 127, which the helper library turns into an assertion failure; no non-test file is ever needed to make a RED.
2. RED is a real failure. For each RED commit R, a scratch worktree at R runs `<runner> --root <worktree>` (with `TEST=` if given). Required exit code is exactly 1. Exit 0 is `TDD_RED_PASSED`; exit 2 (syntax error, timeout, no tests, budget) is `TDD_RED_ERROR`. The failing set from `out/test-fast/results.tsv` must be a subset of the test files added or changed in R, else `TDD_RED_FOREIGN_FAILURE` (a pre-existing test broke). It must be non-empty. Using the base's runner, not R's, means a PR cannot rig the runner to call everything RED.
3. `TDD_HEAD_NOT_GREEN`: at head the trusted runner exits 0.
4. `TDD_NO_RED`: a `feat(<ID>)` or `fix(<ID>)` commit needs an earlier valid RED or slow-only commit with the same node id in the PR. Rejected: requiring one RED per commit (too strict; a node has slices).
5. Frozen tests. For each RED or slow-only commit R, the test-path files it added or changed are frozen from R onward. A later commit of kind `feat`, `fix`, `docs` or `chore` may not modify, delete, rename or truncate a frozen file (`TDD_TEST_MODIFIED`, `TDD_TEST_DELETED`). New files in test paths are fine (helper tests). A later `test(<ID>)` RED commit may change a frozen file, and is itself checked under rule 2. A correction that makes a wrong test pass (no RED possible) uses `chore(<ID>)` with `TDD-Test-Correction: <reason>`; that is accepted only when the commit's author is in `humans`, because agents may not rewrite the spec they were given (`TDD_CORRECTION_AUTHOR`). It is listed in the report.
6. `TDD_SKIP_MARKER`: a commit that adds `skip`, `xfail`, `exit 0` as the first statement, or `t_done` commented out to a frozen test is rejected (a small regex list, not a proof; the human reviewer sees the list in the report).

The report (`out/tdd/report.json`) records `checker_source`, `policy_source`, `runner_source` (`base` or `head`), every commit with its kind, exit code and failing set, and the corrections. Rejected: only printing to the log (reviewers want to open one file).

### Protected-path rule (`tools/ci/protected-check.py`)
`--root --base --head --author LOGIN_OR_IDENTITY`. If the PR's commits are authored by an identity in `agents` and the diff `base...head` touches any `protected_paths` glob, it fails with `PROT_PATH` and lists each file. Human-authored PRs may touch them; elevated review is `CODEOWNERS` (every protected glob owned by `@tuckermclean`) plus the owner's required-review setting (`docs/repo-settings.md`). Mixed authorship fails if any agent commit touches a protected file (check per commit, not per PR).

### Trusted-base execution
`.github/workflows/discipline.yml` triggers on `pull_request` (types opened, reopened, synchronize, edited) and on `push` to the default branch. One job `discipline` (`timeout-minutes: 15`, `permissions: contents: read`, pinned actions as F01). Steps:
1. Checkout the PR head into `pr/` (`ref: github.event.pull_request.head.sha`, `fetch-depth: 0`, `persist-credentials: false`) and the PR base revision into `base/` (`ref: github.event.pull_request.base.sha`). A step fails the job if either checkout is missing a Makefile.
2. From `base/`: `make -C base trusted-check ROOT=$PWD/pr BASE=<sha> HEAD=<sha> RUNNER=$PWD/base/tools/ci/run-fast`. `trusted-check` is a base Make target that runs, in order: `tools/lint/run --root`, `tools/graph/graph-check.py --root`, `tools/system/system-check.py --root`, `identity-check.py`, `protected-check.py`, `tdd-check.py`. Everything executed comes from `base/`; only data comes from `pr/`.
3. Upload `out/tdd/` as an artifact.
Bootstrap: when `base/` has no `trusted-check` target (before F04 merges), the job uses `pr/` and records `checker_source: head` in the report; the first F04 PR is therefore judged by its own head and must be reviewed by a human with that in mind. After merge, every later PR is judged by base. This mirrors strange-company CD-58(a) ("policy and checker come from the merge base; the PR head only when the base lacks them").
Residual weakness, acknowledged as in strange-company CD-62: on `pull_request` GitHub runs the workflow file from the PR. A PR editing `discipline.yml` can weaken the gate. That is why `.github/workflows/discipline.yml`, `verify.yml` and `CODEOWNERS` are protected paths and why `docs/repo-settings.md` requires an owner review on them. Rejected: `pull_request_target` (runs with a write token in the base context; checking out PR code there is the classic injection hole). Rejected: a "mode" switch read from the tree (strange-company issue #149: a PR could select its own verifier).

### Agent environment
`tools/ci/agent-env.sh` is sourced by an agent session. It sets `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_*` to the first `agents` entry in the policy (OD-4 default `monolith-agent[bot]`; the noreply email needs the bot's numeric id and stays a placeholder until OD-4 is answered), and unsets empty identity variables first (T-git-empty-identity: an empty `GIT_AUTHOR_NAME` outranks `git -c user.name=`). It keeps the old repo's `GIT_CONFIG_COUNT` repair for the workspace that exports an empty count (`scripts/agent-git-env.sh:20-45`). Rejected: configuring identity in `.git/config` (does not survive fresh clones, and an env override outranks it).

### `docs/repo-settings.md`
The checklist the owner applies, each item matched to something the checks assume: required status checks named exactly `fast` (F01 job) and `discipline` (this job); squash merge only, with "default to PR title and body"; linear history; no force pushes to the default branch; require review from code owners; the GitHub profile name `Tucker McLean`; the agent bot account (OD-4) with write access but no admin and no bypass; a workflow-scoped token held by the human for pushing `.github/workflows/**` (T-workflow-push-needs-pat). The doc is cross-checked by test against the workflow job names.

## Traps and doctrines preserved
- Principle 10, one identity per actor: F04-AC-1 to F04-AC-4.
- T-git-empty-identity: F04-AC-13.
- RED passing by accident or by a broken runner (strange-company `TDD_RED_PASSED`, build-failure variants): F04-AC-6, F04-AC-7.
- Tests edited to fit the implementation: F04-AC-9.
- A PR choosing its own judge (strange-company CD-58, CD-62, issue #149): F04-AC-11, F04-AC-12.
- Agents editing the rules or specs (SPEC §8): F04-AC-10.
- T-workflow-push-needs-pat: documented in `docs/repo-settings.md`, checked by F04-AC-14.
- D-state-and-no-hidden-stderr: the checkers print every subprocess stderr; their own code passes F01's `stderr-hiding` rule.

## Gate
- **F04-AC-1** — Given fixture commits, an author outside the allowlist (`tuckermclean <me@tuckermclean.com>`, `Software Engineer <software-engineer@dcxxiv.local>`) is `ID_AUTHOR`; `Tucker McLean <me@tuckermclean.com>` and `monolith-agent[bot] <1+monolith-agent[bot]@users.noreply.github.com>` pass. *Verify:* `tests/fast/identity-author.test.sh` with fixtures built by `git commit` in scratch repos. *Tier:* fast.
- **F04-AC-2** — Committer rule: `GitHub <noreply@github.com>` passes, any other unlisted committer is `ID_COMMITTER`. *Verify:* `tests/fast/identity-committer.test.sh`. *Tier:* fast.
- **F04-AC-3** — Co-author trailers: the old repo's `Tech Lead <tech-lead@dcxxiv.local>`, `Paperclip <noreply@paperclip.ing>`, `Documentation Engineer <noreply@paperclip.ing>` and `monolith-ci[bot] <...>` are `ID_COAUTHOR_NOT_ALLOWED`; `Claude Opus 4.8 <noreply@anthropic.com>` passes; a lowercase key `Co-authored-by` is `ID_COAUTHOR_FORMAT` in PR mode and accepted in push mode; duplicates are rejected. *Verify:* `tests/fast/identity-coauthor.test.sh`. *Tier:* fast.
- **F04-AC-4** — Subject and trailer checks: a bad subject type, a missing node id on `feat`, a subject over 72 characters, an unknown trailer key, and a PR title or body that would produce a bad squash message each fail with the named code. *Verify:* `tests/fast/identity-subject.test.sh`. *Tier:* fast.
- **F04-AC-5** — Exit codes and output of every F04 checker: 0 clean, 1 findings, 2 bad input, findings on stdout as `ref: CODE: message`, subprocess stderr never discarded. *Verify:* `tests/fast/discipline-cli.test.sh`. *Tier:* fast.
- **F04-AC-6** — A valid RED commit (test files added, `TDD-Red-Target: test-fast`, runner exits 1 at that commit with only added tests failing) passes. A RED where the runner exits 0 is `TDD_RED_PASSED`; exit 2 is `TDD_RED_ERROR`; a failing test that R did not add or change is `TDD_RED_FOREIGN_FAILURE`; a RED that changes a non-test file is `TDD_RED_NOT_TEST_ONLY`. *Verify:* `tests/fast/tdd-red.test.sh`. *Tier:* fast.
- **F04-AC-7** — Trailer validation: missing, duplicate, non-allowlisted target, and a value containing shell metacharacters (`;`, `$(`, backtick, space-separated extra words, `..`) are rejected, and a marker file proves the value was never executed. *Verify:* `tests/fast/tdd-trailer.test.sh`. *Tier:* fast.
- **F04-AC-8** — At head the trusted runner must exit 0 (`TDD_HEAD_NOT_GREEN`); a `feat(<ID>)` or `fix(<ID>)` commit with no earlier RED or slow-only commit for the same node is `TDD_NO_RED`; a merge commit is `TDD_MERGE_COMMIT`. *Verify:* `tests/fast/tdd-green.test.sh`. *Tier:* fast.
- **F04-AC-9** — Frozen tests: after a RED, a `feat`, `fix`, `docs` or `chore` commit that modifies, deletes or renames a RED-added test file is `TDD_TEST_MODIFIED`/`TDD_TEST_DELETED`; adding a new test file passes; a later `test(<ID>)` RED may change it; a `skip` marker is `TDD_SKIP_MARKER`; `TDD-Test-Correction` passes only when authored by a human identity. *Verify:* `tests/fast/tdd-frozen.test.sh`. *Tier:* fast.
- **F04-AC-10** — `TDD-Slow-Only` commits are accepted only when every listed AC exists with tier slow in the node spec, the files are within `slow_test_paths`, and the fast tier still passes; frozen-file rules then apply to them. *Verify:* `tests/fast/tdd-slowonly.test.sh`. *Tier:* fast.
- **F04-AC-11** — `protected-check` fails an agent-authored commit touching any `protected_paths` glob (including a path containing a newline) and passes a human-authored one; `protected_paths` contains every path listed in SPEC §8's protected-paths bullet. *Verify:* `tests/fast/protected-paths.test.sh` (parses SPEC §8). *Tier:* fast.
- **F04-AC-12** — Trusted-base execution: `make -C base trusted-check ROOT=pr ...` judges `pr/` using only files from `base/`: with a fixture whose PR tree replaces `tools/ci/tdd-check.py` and `policy.yaml` with always-pass versions, the check still fails the bad commits; when `base/` lacks the target the report says `checker_source: head`. *Verify:* `tests/fast/trusted-base.test.sh`. *Tier:* fast.
- **F04-AC-13** — `tools/ci/agent-env.sh` unsets empty `GIT_AUTHOR_*`/`GIT_COMMITTER_*`, exports the bot identity from the policy, repairs an empty `GIT_CONFIG_COUNT`, and a `git commit` made afterwards passes `identity-check`. *Verify:* `tests/fast/agent-env.test.sh`. *Tier:* fast.
- **F04-AC-14** — `docs/repo-settings.md` lists required checks `fast` and `discipline`, and both names equal job ids in `verify.yml` and `discipline.yml`; `.github/CODEOWNERS` covers every `protected_paths` glob; `discipline.yml` passes F01's lint (pinned actions, permissions, timeouts) and does not use `pull_request_target`. *Verify:* `tests/fast/discipline-workflow.test.sh`. *Tier:* fast.
- **F04-AC-15** — On GitHub, an intentionally bad PR (wrong co-author, edited frozen test, agent-edited `SPEC.md`) fails the `discipline` job, and a conforming PR passes. *Verify:* CI job `discipline` on two scratch PRs; run links in the PR body. *Tier:* slow.

## RED plan
All checkers are tested against scratch git repositories built in `t_tmpdir` by `tests/fast/lib.sh` helpers (`t_commit AUTHOR COMMITTER SUBJECT BODY FILES`), so fixtures are reproducible and need no network. Before implementation the `tools/ci/*.py` files do not exist, so each call fails with 2 or 127, an assertion failure under `t_assert_exit`. Slices, each `test(F04)` RED with `TDD-Red-Target: test-fast`:
1. Identity: AC-1 to AC-5.
2. RED/GREEN core: AC-6 to AC-8.
3. Frozen tests, slow-only: AC-9, AC-10.
4. Protected paths, trusted base, agent env: AC-11 to AC-13.
5. Workflow and settings: AC-14, then AC-15 as slow evidence.
Bootstrap note: F04's own PR cannot be judged by F04 (base lacks it). Its commits still follow the RED/GREEN pattern by hand, and the PR body says the check ran in `head` mode.

## Risks and open questions
- OD-4: the agent bot's name and noreply email are not known. The policy holds the default `monolith-agent[bot]` with a wildcard id; it needs one edit once the account exists. The graph lists `decisions: [OD-4]` on F04 and F05, so neither starts until it is settled or the default is accepted in `docs/decisions/`.
- Replaying RED commits runs PR code (the tests) in CI. It already does in `verify.yml`, with the same read-only token. A malicious test can still exhaust time: per-test timeout 20 s and a 15-minute job cap.
- A fixed `red_targets: [test-fast]` means slow-tier-only work has no RED. The `TDD-Slow-Only` form covers it but lets a tester claim slow-only for an AC that could have a fast test; the reviewer (F05) checks this by judgement.
- Squash-merge identity depends on the owner's GitHub profile name and the bot account's profile; an unexpected `ID_AUTHOR` on master after merge is possible until they are set.
- The `GitHub <noreply@github.com>` committer is allowed on PR commits too; a tighter rule (only on the merge result) cannot be checked pre-merge.
- Branch protection is not in the repo; nothing mechanical proves `docs/repo-settings.md` was applied. An owner-run `gh api` audit script is a possible follow-up; it needs a token this node does not assume.

## Cost
Five slices, 15 ACs, size L because of the trusted-base harness and git-fixture tests. About three fast-lane runs per slice. The slow AC needs two scratch PRs on GitHub (CI minutes only, a minute or two each). No builds. No storage or hosting cost. The human owner spends time on `docs/repo-settings.md` and OD-4.

## Spec defects found
- SPEC §8's owner-review list now covers the files that judge PRs (`.github/**`, `tools/ci/`, `tools/graph/`, `tools/system/`) but still omits `tools/lint/`. F04's policy includes it; SPEC §8 should too.
- SPEC §8 says bots may open PRs that touch owner-review paths and the owner merges them, while F04's `protected-check` fails an agent-authored commit that touches a protected path (`PROT_PATH`). Reconcile: either `PROT_PATH` becomes a required-owner-review signal for bot PRs, or SPEC §8 says agent commits there fail CI unless the node's **Owns** line lists the path (as the guard hook does). Owner's call.
- SPEC §8 allows `dependabot[bot]` as an author (M04). The policy's `identity` block has humans and agents only; the implementer adds a `bots` entry for Dependabot and its trailer format, tested under F04-AC-1.
- SPEC §8 says F04's checks run "from the PR's base revision" but F01-F03 validators are listed with them; the SPEC does not say which Make target runs them. F04 defines `make trusted-check` for this.
