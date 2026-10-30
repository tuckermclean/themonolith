# F01 — fast-lane

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | none | I01, O01, O02, R01, R04, S01 | — | S |

**Owns:** `Makefile` (created, with the `test` target and its file lists), `.github/workflows/pr-validate.yml`, `.github/dependabot.yml`, `.github/CODEOWNERS`, `.gitignore`, the predecessor's section of `AGENTS.md`, the architecture line of `CLAUDE.md`, `scripts/tests/fast-lane.test.sh` and its fixtures.
**Ports from linux-live-iso-factory@b9f533b:** the checks of `.github/workflows/pr-validate.yml:23-69`, `.gitignore`, `AGENTS.md` (the predecessor's guide), the architecture line of `CLAUDE.md:8-9`.
**Study refs:** T-pr-lint-gaps, T-workflow-push-needs-pat; workflows.yaml `wf.pr-validate`; SPEC §7 (CI parity), §8.

## Purpose
After F01, every pull request runs the predecessor's fast checks in the toolbox, offline, and runs them the same way locally and in CI. No predecessor code beyond those checks comes in here: each later node writes its tests and ports into this lane what they need (`docs/capabilities.md`). The predecessor's agent knowledge base is in `AGENTS.md` from the first node on.

## Standard mechanism
`make`, GitHub Actions, shellcheck, actionlint, PyYAML, Dependabot and CODEOWNERS, all from the toolbox or GitHub. Custom code: none. The `test` target is the predecessor's shell loops.

## Tests
- **Ported first:** none; the predecessor tested its fast lane only by running it. The checks of `pr-validate.yml:23-69` are what `make test` runs.
- **Added:** `scripts/tests/fast-lane.test.sh` (all criteria).
- **Baseline:** the predecessor's `pr-validate.yml` steps pass on a `b9f533b` checkout in the toolbox (checked 2026-10-29), and `make test` gives the same result there.

## Changes from the port
1. **`make test` is the fast tier.** A new `Makefile` with a `test` target that runs the commands of `pr-validate.yml:23-69`: `bash -n`, `py_compile` over `scripts/*.py`, YAML well-formedness over `configs/**/*.yaml` and `.github/workflows/*.yml`, `actionlint -shellcheck=`, `shellcheck --severity=error`, and every `scripts/tests/*.sh` with `sh`. Each check prints its name. The globs match what exists, so an empty glob is not an error. The predecessor's explicit overlay paths (`pr-validate.yml:27,59`) are added to the `bash -n` and shellcheck lists by R01 when it ports those files; a listed path that does not exist fails. The predecessor's `test` target (`Makefile:500`, a QEMU boot) is not ported here; O01 ports it as `test-bios`. *Proof:* F01-AC-1, F01-AC-2.
2. **`pr-validate.yml` in the parity form (SPEC §7).** One job on `ubuntu-24.04` with `timeout-minutes: 20`: the checkout, then `toolbox/run --network none -- make test` and `toolbox/run -- toolbox/ci lint`. The predecessor's inline steps become the Makefile target, and actionlint comes from the toolbox instead of a downloaded install script (`pr-validate.yml:53`). *Proof:* F01-AC-3, F01-AC-4.
3. **Action references pinned; repository settings files.** Every `uses:` in `.github/workflows/` is a full commit SHA with the tag as a comment, and no workflow fetches from `raw.githubusercontent.com` unless the ref in the URL is a 40-hex commit. The check is a standing fast test (SPEC §2), so each workflow a later node ports is pinned as it arrives. That includes the grype install script that `cve-gate-canary.yml:58` and `nightly-cve-scan.yml:43` fetch from `main`. New: `.github/dependabot.yml` (GitHub Actions ecosystem, weekly) and `.github/CODEOWNERS` with the SPEC §8 paths. *Proof:* F01-AC-5.
4. **`.gitignore`** is the predecessor's, with `out/` added (the `/node` skill's working files) and `.claude/` removed, because this repository tracks `.claude/`. *Proof:* F01-AC-6.
5. **The predecessor's agent guide.** `AGENTS.md` keeps this repository's section on top, and the predecessor's guide follows it: doctrines, how the maintainer wants work done (PAT handling for workflow pushes, debugging discipline), traps and recipes. Passages that describe only S3 storage or the dashboard are left out (`AGENTS.md:76-90,189-204,224-227` at `b9f533b`). Where a trap goes beyond storage, it is kept without the S3 wording (`:135`, always revbump an overlay change). Everything else is verbatim. `CLAUDE.md` gains the predecessor's architecture line, pointing at the docs as each node ports them. The orchestrator makes this change: role agents may not edit these files. *Proof:* F01-AC-7.

## Gate
- **F01-AC-1** — `make test` runs the six checks, names each in its output, and exits 0 with no network and no build. *Verify:* `toolbox/run --network none -- make test` on a clean checkout; `scripts/tests/fast-lane.test.sh` reads the output. *Tier:* fast.
- **F01-AC-2** — `make test` exits non-zero, one fixture at a time, for a shell syntax error, a Python syntax error, malformed YAML, a shellcheck error, a failing `scripts/tests/*.sh` and a listed path that does not exist. *Verify:* `scripts/tests/fast-lane.test.sh` runs the target against fixture trees in a temporary directory. *Tier:* fast.
- **F01-AC-3** — `pr-validate.yml` passes on the F01 pull request, and `toolbox/ci run pr-validate` passes locally on the same commit with the same steps reported `ok`. *Verify:* the PR's check run and the local `toolbox/ci` log. *Tier:* slow.
- **F01-AC-4** — `toolbox/ci lint` exits 0, and `pr-validate.yml` is the workflow it covers. *Verify:* `scripts/tests/fast-lane.test.sh` runs `toolbox/ci lint` and reads its count. *Tier:* fast.
- **F01-AC-5** — Every `uses:` in `.github/workflows/` is `owner/repo@<40 hex>` (local `./` references excepted), no workflow fetches a `raw.githubusercontent.com` URL whose ref is not 40 hex, and `.github/dependabot.yml` and `.github/CODEOWNERS` exist with the SPEC §8 paths. *Verify:* `scripts/tests/fast-lane.test.sh`. *Tier:* fast.
- **F01-AC-6** — `git check-ignore` ignores `out/x` and `output/x` and does not ignore `.claude/settings.json`. *Verify:* `scripts/tests/fast-lane.test.sh`. *Tier:* fast.
- **F01-AC-7** — Below this repository's section, `AGENTS.md` holds the predecessor's guide: its sha256 equals the value the test records, computed from `b9f533b`'s file with the change-5 edits. I01's pattern finds nothing in it. *Verify:* `scripts/tests/fast-lane.test.sh`. *Tier:* fast.

## Risks
- CI builds the toolbox image from `toolbox/Containerfile` on each run, which needs `snapshot.debian.org` to answer (about a minute here). If it proves slow or rate-limited, publish the image by digest and have `toolbox/run` pull it.
- `toolbox/run` on the runner uses the preinstalled rootless podman of `ubuntu-24.04` (unverified; set `MONOLITH_ENGINE=docker` in the workflow `env:` if it fails). The first CI run settles it.
- Pushing `.github/workflows/*` needs a token with the `workflow` scope (AGENTS.md traps).
