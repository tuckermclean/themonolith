# F01 — make-test

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | none | I01, O01, O02, R01, R04, S01 | — | S |

**Owns:** `Makefile` (created, with the `test`, `test-lint` and `test-unit` targets and their file lists), `scripts/test-lint.sh` (the lint checks behind `test-lint`), `.github/workflows/pr-validate.yml`, `.github/dependabot.yml`, `.github/CODEOWNERS`, `.gitignore`, the predecessor's section of `AGENTS.md`, the architecture line of `CLAUDE.md`, `scripts/tests/make-test.test.sh` and its fixtures.
**Ports from linux-live-iso-factory@b9f533b:** the checks of `.github/workflows/pr-validate.yml:23-69`, `.gitignore`, `AGENTS.md` (the predecessor's guide), the architecture line of `CLAUDE.md:8-9`.
**Study refs:** T-pr-lint-gaps, T-workflow-push-needs-pat; workflows.yaml `wf.pr-validate`; SPEC §7 (CI parity), §8.

## Purpose
After F01, `make test` is the one way to run the repository's tests, locally and in CI, and every pull request runs the predecessor's checks through it in the toolbox. No predecessor code beyond those checks comes in here: each later node ports its tests and code and adds its tests to a `make test` target (SPEC §7, `docs/capabilities.md`). The predecessor's agent knowledge base is in `AGENTS.md` from the first node on.

## Standard mechanism
`make`, GitHub Actions, shellcheck, actionlint, PyYAML, Dependabot and CODEOWNERS, all from the toolbox or GitHub. Custom code: none. `test-lint` and `test-unit` are the predecessor's shell loops.

## Tests
- **Ported first:** none; the predecessor tested its PR checks only by running them. The checks of `pr-validate.yml:23-69` are what `make test-lint` and `make test-unit` run.
- **Added:** `scripts/tests/make-test.test.sh` (all criteria).
- **Baseline:** the predecessor's `pr-validate.yml` steps pass on a `b9f533b` checkout in the toolbox (checked 2026-10-29), and `make test` gives the same result there.

## Changes from the port
1. **`make test` runs every test.** A new `Makefile` whose `test` target depends on every `test-*` target (SPEC §7); F01 creates two. `test-lint` runs the static checks of `pr-validate.yml:23-69`: `bash -n`, `py_compile` over `scripts/*.py`, YAML well-formedness over `configs/**/*.yaml` and `.github/workflows/*.yml`, `actionlint -shellcheck=` and `shellcheck --severity=error`, plus two checks of this repository: the migration ledger (`scripts/check-migration.py`) and the workflow rules (`toolbox/ci lint`). `test-unit` runs every `scripts/tests/*.sh` with `sh`. Each check prints its name, and a later node adds a target by adding it to `test`'s prerequisites. Make runs on the host, as the predecessor's builder targets do: `test-lint` and `test-unit` run their commands through `toolbox/run --network none`. The globs match what exists, so an empty glob is not an error. The predecessor's explicit overlay paths (`pr-validate.yml:27,59`) are added to the `bash -n` and shellcheck lists by R01 when it ports those files; a listed path that does not exist fails. The predecessor's `test` target (`Makefile:500`, an interactive QEMU boot, not a test) is not ported here; O01 ports it as `run-bios`. *Proof:* F01-AC-1, F01-AC-2.
2. **`pr-validate.yml` only calls Make (SPEC §7).** One job on `ubuntu-24.04` with `timeout-minutes: 20`: the checkout, then `make test-lint test-unit`. R04 and R02 add their targets to the same job; no step runs a check outside Make. The predecessor's inline steps become the Makefile target, and actionlint comes from the toolbox instead of a downloaded install script (`pr-validate.yml:53`). *Proof:* F01-AC-3, F01-AC-4.
3. **Action references pinned; repository settings files.** Every `uses:` in `.github/workflows/` is a full commit SHA with the tag as a comment, and no workflow fetches from `raw.githubusercontent.com` unless the ref in the URL is a 40-hex commit. The check is a standing test in `test-unit` (SPEC §2), so each workflow a later node ports is pinned as it arrives. That includes the grype install script that `cve-gate-canary.yml:58` and `nightly-cve-scan.yml:43` fetch from `main`. New: `.github/dependabot.yml` (GitHub Actions ecosystem, weekly) and `.github/CODEOWNERS` with the SPEC §8 paths. *Proof:* F01-AC-5.
4. **`.gitignore`** is the predecessor's, with `out/` added (the `/node` skill's working files) and `.claude/` removed, because this repository tracks `.claude/`. *Proof:* F01-AC-6.
5. **The predecessor's agent guide.** `AGENTS.md` keeps this repository's section on top, and the predecessor's guide follows it: doctrines, how the maintainer wants work done (PAT handling for workflow pushes, debugging discipline), traps and recipes. Passages that describe only S3 storage or the dashboard are left out (`AGENTS.md:76-91,188-204,223-228` at `b9f533b`, whole bullets). Where a trap goes beyond storage, it is kept without the S3 wording (`:135`, always revbump an overlay change). Everything else is verbatim. `CLAUDE.md` gains the predecessor's architecture line, pointing at the docs as each node ports them. The orchestrator makes this change: role agents may not edit these files. *Proof:* F01-AC-7.

## Gate
- **F01-AC-1** — `make test` depends on `test-lint` and `test-unit`; together they run the eight checks, name each in the output, and exit 0 with no network and no build. *Verify:* `make test` on a clean checkout; `scripts/tests/make-test.test.sh` reads the output.
- **F01-AC-2** — `make test` exits non-zero, one fixture at a time, for a shell syntax error, a Python syntax error, malformed YAML, a shellcheck error, a failing `scripts/tests/*.sh`, a listed path that does not exist, a migration ledger with one row removed, a ported file whose mode or blob differs from its `port` row, and a workflow `run:` step with `${{ }}` in it. *Verify:* `scripts/tests/make-test.test.sh` runs the target against fixture trees in a temporary directory.
- **F01-AC-3** — `pr-validate.yml` passes on the F01 pull request, and its only `run:` step is `make test-lint test-unit`, which passes locally on the same commit, as does `make test`. *Verify:* the PR's check run, the local log and `scripts/tests/make-test.test.sh` for the step.
- **F01-AC-4** — `toolbox/ci lint` exits 0 inside `make test-lint`, and `pr-validate.yml` is the workflow it covers; `scripts/check-migration.py` exits 0 inside `make test-lint`. *Verify:* `scripts/tests/make-test.test.sh` reads the output.
- **F01-AC-5** — Every `uses:` in `.github/workflows/` is `owner/repo@<40 hex>` (local `./` references excepted), no workflow fetches a `raw.githubusercontent.com` URL whose ref is not 40 hex, and `.github/dependabot.yml` and `.github/CODEOWNERS` exist with the SPEC §8 paths. *Verify:* `scripts/tests/make-test.test.sh`.
- **F01-AC-6** — `git check-ignore` ignores `out/x` and `output/x` and does not ignore `.claude/settings.json`. *Verify:* `scripts/tests/make-test.test.sh`.
- **F01-AC-7** — Below this repository's section, `AGENTS.md` holds the predecessor's guide: its sha256 equals the value the test records, computed from `b9f533b`'s file with the change-5 edits. I01's pattern finds nothing in it. *Verify:* `scripts/tests/make-test.test.sh`.

## Risks
- CI builds the toolbox image from `toolbox/Containerfile` on each run, which needs `snapshot.debian.org` to answer (about a minute here). If it proves slow or rate-limited, publish the image by digest and have `toolbox/run` pull it.
- `toolbox/run` on the runner uses the preinstalled rootless podman of `ubuntu-24.04` (unverified; set `MONOLITH_ENGINE=docker` in the workflow `env:` if it fails). The first CI run settles it.
- Pushing `.github/workflows/*` needs a token with the `workflow` scope (AGENTS.md traps).
