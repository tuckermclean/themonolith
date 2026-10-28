# F01 — repo-skeleton

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| F | none | F02, F03, F04, F06, M04, O01, R01 | — (feeds MS1) | M |

**Owns:** `README.md`, `AGENTS.md`, `CLAUDE.md`, `LICENSE`, `Makefile`, `.gitignore`, `.github/workflows/verify.yml`, `tools/ci/run-fast`, `tools/ci/fetch-tool.sh`, `tools/ci/tools.lock`, `tools/ci/requirements.txt`, `tools/lint/` (all lint rules and `layout.allow`), `tests/fast/lib.sh`, `tests/fast/` tests for the above, `docs/traps.md`
**Carries from linux-live-iso-factory@b9f533b:** `LICENSE` (MIT, `LICENSE:1-3`), the doctrine and working-rule parts of `AGENTS.md:1-70` (not the Paperclip harness traps), the trap section of `AGENTS.md` into `docs/traps.md`, the intent of `.github/workflows/pr-validate.yml` (not its hard-coded file lists), `.gitignore` minus the `.claude/` line
**Study refs:** T-pr-lint-gaps, T-workflow-push-needs-pat, T-github-api-503-installs, D-state-and-no-hidden-stderr, D-no-python-on-target (host-only Python), workflows.yaml `pins_summary` (floating actions, `ubuntu-latest`, `curl | sh` of grype `main`, unpinned `pip install pyyaml`, oras tarball without checksum), workflows.yaml contradictions on stale workflow comments, doctrine.yaml `T-ntfs-case` (deferred, see Risks)

## Purpose
After F01 the repository has a layout that CI enforces, one Makefile entry point per activity, a fast-tier runner with a defined exit-code protocol, and a fast CI lane in which nothing floats: every action is pinned by SHA, every lint tool by version and sha256. Every later node gets its RED target (`make test-fast`) and its lint coverage for free, because both discover files with `git ls-files` instead of a hand-kept list. This fixes the predecessor's lint gap, where a new script was silently unchecked until someone edited `pr-validate.yml` (`pr-validate.yml:23-61`, T-pr-lint-gaps).

## Scope
In:
- Top-level layout from SPEC §4.2, plus `tools/` and the root files above, with `make layout-check` rejecting any other top-level path.
- `Makefile` with the entry points `help`, `lint`, `test-fast`, `check`, `tools`, `clean`, and stubs-by-convention for targets other nodes add (`graph-check`, `system-check`, `trusted-check`).
- The fast-tier runner `tools/ci/run-fast`, the test helper `tests/fast/lib.sh`, and the test naming and exit-code protocol.
- Lint rules: shell syntax and shellcheck, Python compile, strict YAML, actionlint, action pinning, workflow hygiene, banned fetch patterns, the stderr-hiding rule, layout.
- The fast CI workflow `.github/workflows/verify.yml`.
- `README.md`, `AGENTS.md`, `CLAUDE.md`, `LICENSE`, `docs/traps.md`.
- Interim tool pins in `tools/ci/tools.lock` with a retrying, checksum-verifying fetcher, and hash-pinned Python packages (PyYAML, pexpect) in `tools/ci/requirements.txt`.

Out:
- Graph and node-spec validation: F02. System inventory check: F03. Identity, TDD discipline, trusted-base execution, `CODEOWNERS`: F04. Agent files under `.claude/`: F05. The `store` CLI: F06.
- `pins/pins.yaml` and the pin ledger that replaces `tools/ci/tools.lock`: I05.
- Mirroring the lint tools in the store (Principle 2): I04/I05. F01 pins by checksum but still fetches from upstream.
- Recipe imports and their lint baseline entries: R01.
- The build workflow, `make iso`: B06. Dependency and action update PRs: M04.
- Branch protection, required-check settings, repository secrets: owner actions, listed in F04.

## Design

### Layout
Top-level entries allowed by `tools/lint/layout.allow` (one name per line): `.claude .github .gitignore AGENTS.md CLAUDE.md LICENSE Makefile README.md SPEC.md docs factory image nodes oracle pins recipes supplychain tests tools web`. F01 creates only the entries it owns (`.github`, `docs/traps.md`, `tests/fast`, `tools/ci`, `tools/lint`, root files). Other nodes create their own directories. Rejected: committing empty placeholder directories for every owner (dead `.gitkeep` files that nobody owns).

`tools/` is new relative to SPEC §4.2: host-side repo tooling that is neither a factory step nor an oracle part. Layout under it: `tools/ci/` (runner, fetcher, F04 checkers), `tools/lint/` (F01), `tools/graph/` (F02), `tools/system/` (F03), `tools/agent/` (F05). See Spec defects.

### Makefile
`SHELL := /bin/sh`. Every target is `.PHONY`, has a `## description` comment, and `make help` prints them (lint checks each target has one). Entry points owned here:

| Target | Behaviour |
|---|---|
| `help` | List targets and descriptions. Default goal. |
| `tools` | Run `tools/ci/fetch-tool.sh` for every entry in `tools/ci/tools.lock` into `.tools/bin` (gitignored). |
| `lint` | Run `tools/lint/run` (below). Exit 0 clean, 1 findings, 2 tool missing or internal error. |
| `test-fast` | Run `tools/ci/run-fast`. The RED target of every fast-tier test. |
| `check` | `lint` then `test-fast`. What a developer runs before pushing. |
| `layout-check` | Layout rule alone, for quick use. |
| `clean` | Remove `out/` and `.tools/`. |

Other nodes add targets by appending to the Makefile in their own PRs. The old repo's Docker-driven targets (`Makefile:165-617`) are not carried; B06 defines `make iso`.

### Fast-tier runner and test protocol
`tools/ci/run-fast [--root DIR]` runs, in sorted order, every `tests/fast/*.test.sh` (via its shebang, default `sh`) and `tests/fast/*.test.py` (via `python3 -I`) under DIR (default: the repository root). `TEST=<path>` restricts the run to one file. The `--root` option exists so that F04 can run a historical commit's tests with the trusted base's runner.

Per-test exit code: 0 = pass, 1 = assertion failure, anything else (2, 126, 127, signal, timeout) = error. Per-test timeout 20 s (`FAST_TEST_TIMEOUT`). Output: one line per test, `PASS|FAIL|ERROR <path> <seconds>`, then a totals line. A machine-readable copy goes to `out/test-fast/results.tsv` (`status<TAB>path<TAB>seconds`).

Runner exit code: 0 = all pass; 1 = at least one FAIL and no ERROR; 2 = any ERROR, or the total time exceeds `FAST_BUDGET_S` (default 60, SPEC §7), or zero tests were found. F04 depends on this protocol: a valid RED is exit 1, never 2. Rejected: a single combined exit 1 for failures and errors (it would let a syntax error pass as RED).

`tests/fast/lib.sh` (sourced by shell tests) provides `t_fail MSG`, `t_assert_eq EXPECT ACTUAL MSG`, `t_assert_file PATH`, `t_assert_exit CODE CMD...` (a command that exits 126 or 127 counts as an assertion failure, so a missing implementation is RED and not an error), `t_tmpdir` (removed on exit), and `t_done` (exit 1 if any assertion failed). `tests/fast/lib.py` offers the same for Python tests. A test never needs the network; `tests/fast/no-network.test.sh` greps `tests/fast/` for `curl|wget|git (clone|fetch|pull|ls-remote)|pip install|apt(-get)? ` and fails on unannotated hits (`# net-ok: <reason>`). Rejected: a network namespace in the runner, because unprivileged `unshare -n` is blocked on stock runners.

### Lint (`tools/lint/run`)
One driver, one rule per file, all discovering their inputs from `git ls-files` (a directory walk when `.git` is absent, for fixtures). `--root DIR` is supported. Output: `path:line: RULE: message`. Rules:

1. `shell-syntax`: `bash -n` (for `#!/bin/bash` or `#!/usr/bin/env bash`) or `dash -n` (for `#!/bin/sh`) on every tracked file with a shell shebang or `.sh` extension, including extensionless executables.
2. `shellcheck`: pinned shellcheck at `--severity=warning`, `-x`. Findings may be baselined only in `tools/lint/shellcheck-baseline.txt` (`path CODE # reason`). Rejected: the old `--severity=error` (`pr-validate.yml:60`), which passes unquoted expansions.
3. `python-compile`: `python3 -I -m py_compile` on every tracked `.py` and Python-shebang file.
4. `yaml-strict`: parse every tracked `.yaml`/`.yml` with PyYAML `safe_load_all` using a loader that raises on duplicate keys (stock PyYAML keeps the last duplicate silently). The old check covered only `configs/**/*.yaml` and workflows (`pr-validate.yml:35-37`).
5. `actionlint`: pinned actionlint with its shellcheck integration on, so `run:` blocks are linted. The old run disabled it with `-shellcheck=` (`pr-validate.yml:55`).
6. `actions-pinned`: every `uses:` in a workflow must be `owner/repo[/path]@<40-hex-sha>` followed by a `# vX.Y.Z` comment, or a local `./` path. `runs-on` must not be `*-latest`.
7. `workflow-hygiene`: each workflow declares top-level `permissions:`; each job declares `timeout-minutes` (the old jobs ran with the 360-minute default); each `actions/checkout` sets `persist-credentials: false`.
8. `no-floating-fetch`: no `curl ... | sh|bash`, no `pip install` without `==`, no `npm install` without an exact version, in workflows or scripts (old: `cve-gate-canary.yml:56-57`, `nightly-cve-scan.yml:43-47`, `cve-gate-canary.yml:61`).
9. `stderr-hiding` (D-state-and-no-hidden-stderr): flag `2>/dev/null`, `2>&-`, `&>/dev/null`, and `>/dev/null 2>&1` in tracked shell and Python files unless the same or preceding line carries `# stderr-ok: <reason of at least 10 characters>`. Pre-existing debt from imports is allowed only through `tools/lint/stderr-baseline.txt` (`path COUNT`); the count may fall but never rise, and a baseline higher than the actual count fails (ratchet). At `b9f533b` a grep for the literal `2>/dev/null` finds 84 lines in 13 files under `scripts/`, plus 24 in `rootfs/init`; R01 annotates or baselines them.
10. `layout`: top-level names must be in `layout.allow`.
11. `make-docs`: every Makefile target has a `##` description.

Tools missing on the host make `lint` exit 2 with the install hint (`make tools`). It never skips a rule silently (Principle 5).

### Tool pinning (interim)
`tools/ci/tools.lock` lines: `name version sha256 url` for shellcheck, actionlint, and (via `requirements.txt` with `--require-hashes`) PyYAML. `fetch-tool.sh <name>` downloads with up to 6 attempts, 30 s apart (the retry shape of the old Dockerfile fix for transient GitHub 503s, T-github-api-503-installs), verifies the sha256 before extracting, and fails closed on a mismatch. I05 moves these pins into `pins/pins.yaml` and deletes `tools.lock`; until then Principle 2 is only half met (pinned, not mirrored).

`pexpect` is the one third-party Python package besides PyYAML that SPEC §4.3 allows. O01's fast tests replay recorded serial fixtures through the ported harness, so the fast lane needs it. Until I05, it is pinned in `tools/ci/requirements.txt` with `--require-hashes`, next to PyYAML (O01's PR adds the line; F01 owns the file). After I05 it is `python.pexpect` in `pins/pins.yaml`. CI-host setup for the slow tier installs it from the same pin.

### Fast CI lane
`.github/workflows/verify.yml`: trigger `pull_request` and `push` to the default branch. `runs-on: ubuntu-24.04`, `permissions: contents: read`, one job `fast` with `timeout-minutes: 10`, steps: pinned `actions/checkout` (SHAs known good in strange-company's `verify.yaml`: checkout `3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`; the implementer re-resolves the tag), `make tools`, `make lint`, `make test-fast`, upload `out/test-fast/` as an artifact. Concurrency cancels superseded PR runs only. Other fast validators join by adding a Make target to `check`, never by growing the YAML. Job name `fast` is a required-check name that F04's settings doc cites.

### Documents
- `README.md`: what the repo is (SPEC §0 in five lines), `make check`, layout table, pointer to SPEC and `docs/`. No claims about a built ISO until X01.
- `AGENTS.md` (protected path): points to SPEC for doctrines instead of restating them, lists every `D-*` id from SPEC §3 with a one-line reminder, then carries the maintainer working rules: the PAT rule (workflow-file pushes need a `workflow`-scoped token used transiently, never written to `.git/config` or `gh auth`, T-workflow-push-needs-pat), capture stderr before theorizing, recovery from a verified artifact instead of a rebuild, "would this run on a 486". Drops the Paperclip workspace traps (`AGENTS.md:75-125`), which are harness-specific.
- `CLAUDE.md`: pointer to AGENTS.md, as in the old repo.
- `docs/traps.md`: the packaging, static-build, boot and CI trap section of the old AGENTS.md, each bullet tagged with its `T-*` id where doctrine.yaml has one. Later nodes append.
- `.gitignore`: `out/`, `.tools/`, `output/`, `__pycache__/`, editor files. It does not ignore `.claude/` (the old file did, `.gitignore:5`), because F05's files are tracked.

## Traps and doctrines preserved
- T-pr-lint-gaps: a new script was not linted. Prevented by F01-AC-3 (discovery by `git ls-files`).
- D-state-and-no-hidden-stderr: F01-AC-6.
- T-workflow-push-needs-pat: documented in AGENTS.md and checked by F01-AC-10; enforced for agents by F05's guard.
- T-github-api-503-installs: F01-AC-8 (retrying fetcher).
- Floating inputs (`checkout@v4` x31, `ubuntu-latest`, `curl | sh`, unpinned pip): F01-AC-4, F01-AC-5.
- D-no-python-on-target: AGENTS.md and README state that Python is host-only; the layout has no Python under `recipes/`. Enforced on artifacts by O06.
- D-486-minimalism: reminder in AGENTS.md; mechanical enforcement is O02 (RAM floors) and F05's review checklist.

## Gate
- **F01-AC-1** — `make help` exits 0 and prints every target; `make lint`, `make test-fast`, `make check`, `make layout-check`, `make tools`, `make clean` exist and each target has a `##` description. *Verify:* `tests/fast/makefile.test.sh`. *Tier:* fast.
- **F01-AC-2** — `tools/ci/run-fast` exits 0 when all tests pass, 1 when at least one test exits 1 and none errors, 2 when any test exits other than 0/1, when no tests are found, or when total time exceeds `FAST_BUDGET_S`; `TEST=` selects one file; it writes `out/test-fast/results.tsv`. *Verify:* `tests/fast/run-fast.test.sh` using fixtures in `tests/fast/fixtures/run-fast/`. *Tier:* fast.
- **F01-AC-3** — Lint discovers files with `git ls-files`: a new shell script, Python file or YAML file in a directory no rule mentions is checked, and a syntax error in it fails `make lint` with `path:line: RULE`. *Verify:* `tests/fast/lint-discovery.test.sh` builds a scratch git repo with a bad file in a new directory. *Tier:* fast.
- **F01-AC-4** — `actions-pinned` rejects a `uses:` ref that is a tag or branch, a missing `# vX` comment, and `runs-on: ubuntu-latest`; it accepts a 40-hex SHA with a comment and `./` local refs. `verify.yml` itself passes. *Verify:* `tests/fast/lint-actions-pinned.test.sh`. *Tier:* fast.
- **F01-AC-5** — `workflow-hygiene` and `no-floating-fetch` reject a workflow without top-level `permissions`, a job without `timeout-minutes`, a checkout without `persist-credentials: false`, `curl ... | sh`, and `pip install pkg` without `==`. *Verify:* `tests/fast/lint-workflow-hygiene.test.sh`. *Tier:* fast.
- **F01-AC-6** — `stderr-hiding` rejects an unannotated `2>/dev/null`, `&>/dev/null` and `>/dev/null 2>&1`, accepts one with `# stderr-ok: <10+ chars>`, and enforces the ratchet: count above baseline fails, baseline above count fails. *Verify:* `tests/fast/lint-stderr.test.sh`. *Tier:* fast.
- **F01-AC-7** — `layout` fails on a top-level name not in `layout.allow` and passes on the allowed set; every directory named in SPEC §4.2's table appears in `layout.allow`. *Verify:* `tests/fast/layout.test.sh` (parses SPEC §4.2). *Tier:* fast.
- **F01-AC-8** — `tools/ci/fetch-tool.sh` retries a failing download up to 6 times (sleep injectable for the test), fails closed on a sha256 mismatch without leaving the binary on `PATH`, and succeeds on a good file URL. `tools.lock` names shellcheck and actionlint with 64-hex checksums. *Verify:* `tests/fast/fetch-tool.test.sh` with `file://` fixtures. *Tier:* fast.
- **F01-AC-9** — `yaml-strict` fails on duplicate mapping keys and on a malformed document, and passes on a valid multi-document file. *Verify:* `tests/fast/lint-yaml.test.sh`. *Tier:* fast.
- **F01-AC-10** — `AGENTS.md` names every `D-*` id in SPEC §3 and states the PAT rule; `CLAUDE.md` points to AGENTS.md; `LICENSE` is MIT with the holder line `Tucker McLean`; `.gitignore` does not ignore `.claude/`; every `T-*` id in `docs/traps.md` exists in `docs/study/doctrine.yaml`. *Verify:* `tests/fast/docs.test.sh`. *Tier:* fast.
- **F01-AC-11** — Fast tests contain no unannotated network commands. *Verify:* `tests/fast/no-network.test.sh`. *Tier:* fast.
- **F01-AC-12** — The `fast` job runs on every PR to the default branch, in under 5 minutes, executes `make lint` and `make test-fast`, and fails when either fails. *Verify:* CI job `verify / fast`, plus a deliberately broken scratch PR recorded in the PR body (run link). *Tier:* slow.
- **F01-AC-13** — `make check` passes at head of the F01 PR with every F01 test included and `make test-fast` finishes in under 60 s locally. *Verify:* `make check` (exit code and time in the PR body). *Tier:* fast.

## RED plan
Bootstrap order matters: the runner cannot be RED-tested through itself. Slice 0 (Makefile skeleton, `run-fast`, `lib.sh`, and the tests for AC-1, AC-2) is written implementation-first as `chore(F01)` commits, with the runner's own tests added right after; F04 does not exist yet, so nothing mechanical objects, and the PR body states this exception. Slices 1 to 3 are test-first. Their RED commits carry `TDD-Red-Target: test-fast`, and all fail by assertion because the lint rules, fetcher and documents do not exist:
- Slice 1 (lint core): AC-3, AC-6, AC-9, AC-11 in `tests/fast/lint-*.test.sh`. Scratch-repo fixtures call `tools/lint/run`; the call returns 127, which `t_assert_exit` turns into an assertion failure.
- Slice 2 (pinning and workflow rules): AC-4, AC-5, AC-7, AC-8.
- Slice 3 (docs and CI): AC-10, then AC-12 and AC-13 as the final slow and full-suite evidence.

## Risks and open questions
- Tool fetches still hit upstream (GitHub releases). If an upstream asset disappears, `make tools` fails loudly; I04/I05 close this by mirroring.
- Action SHAs cannot be resolved offline. The implementer resolves each tag to a commit with `gh api` and records tag and SHA in the PR body; annotated tags need the dereferenced commit SHA.
- `shellcheck --severity=warning` will flag many old scripts when R01 imports them; R01 uses the baseline file, which must shrink.
- Case-insensitive checkout collisions (T-ntfs-case, commit `affe3d6`, unknown detail): not handled. A `case-collision` lint rule is cheap; deferred until a collision appears.
- Whether the owner wants `CODEOWNERS` entries for `tools/lint/` is F04's call.

## Cost
Four agent slices (slice 0 plus three), about 13 ACs. One or two runs of the fast lane per slice (about 2 minutes each). No build cycles. No money: no storage, no hosting. Human time: resolve action SHAs, review `AGENTS.md`.

## Spec defects found
- SPEC §4.2 still omits the root files (`Makefile`, `README.md`, `AGENTS.md`, `CLAUDE.md`, `LICENSE`) and `docs/traps.md`. Proposed: add the rows. (`tools/`, `docs/status.yaml` and `CODEOWNERS` were added in v0.3.)
- SPEC §6 says `pins/pins.yaml` (I05) holds actionlint and shellcheck, but F01 has no dependencies and needs them first. F01 uses the interim `tools/ci/tools.lock`; I05 should migrate and delete the lock.
