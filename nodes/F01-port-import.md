# F01 — port-import

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | none | B02, I01, O01, O02, R01, R04, S01 | — | M |

**Owns:** `.github/dependabot.yml`, `.github/CODEOWNERS`, the imported tree (`configs/`, `rootfs/`, `scripts/`, `Makefile`, `Dockerfile`, `.github/workflows/`, `docs/{releasing,version-pinning,cve-gate,kernel-tiers}.md`, `README.md`, `LICENSE`, `.gitignore`, `AGENTS.md`, `CLAUDE.md`), `IMPORT.md`, `scripts/tests/import.test.sh`, `scripts/tests/import-provenance.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** everything listed under Purpose, byte for byte, except the numbered changes below.
**Study refs:** D-supply-chain-honesty, T-run-rerun-reuses-cache (why build.yml stays off), AGENTS.md traps; `docs/study/inventory.yaml`.

## Purpose
This repository gains the predecessor's working tree at `b9f533b` (201 tracked files) with a record of what came across and what did not. After F01, `pr-validate.yml` and the 23 files in `scripts/tests/` pass here, and no workflow can reach AWS or need a secret. Nothing is rewritten. Later nodes change imported files one criterion at a time, and `IMPORT.md` records each change.

## Standard mechanism
None. `git` already records history, so the import is one commit with a manifest, not a subtree merge: the predecessor is archived and its history stays there. `IMPORT.md` is a table `path | sha256 | status`, where status is `verbatim`, `changed by <node>`, or `dropped (<reason>)`. The test below regenerates it from `git ls-tree` plus `sha256sum`. That is a shell loop, not a tool.

## Changes from the port
Importing is the port. Dropping and disabling are changes, so each is listed.

1. **Dropped: files that serve only removed things.** `scripts/s3-gc.sh`, `scripts/tests/s3-gc.test.sh`, `.github/workflows/gc.yml` (S3 retention; SPEC §6 deletes nothing automatically); `scripts/ghcr-gc.sh`, `scripts/tests/ghcr-gc.test.sh` (same reason: a retention job is added only if storage costs money); `scripts/generate-dashboard.py`, `web/` (11 files), `boot.html` (dashboard and in-browser demo, out of scope per SPEC §0); `docs/superpowers/` (18 plans and specs, agent planning history; most mention S3 and would trip I01's check; they stay readable in the archived predecessor); `RELEASE-READINESS.md` (333 lines, dated 2026-08-02, describes a state three months stale; AGENTS.md carries the live traps). *Proof:* F01-AC-3.
2. **Dependent edits of dropped files, and nothing else.** `Makefile` target `dashboard` and its `.PHONY`/help lines (`Makefile:198,483-492`), and the `generate-dashboard.py` call in `scripts/nightly-cve-monitor.py:229-234,298-308`, are removed because their target is gone. The `ghcr-gc` and `s3-gc` references, if any, go the same way. *Proof:* F01-AC-4.
3. **Disabled: workflows other than `pr-validate.yml` and `boot-test.yml`.** `on:` of `build.yml`, `release.yml`, `pin-bump.yml`, `regen-pins.yml`, `toolchain-bump.yml`, `nightly-cve-scan.yml` and `cve-gate-canary.yml` becomes `workflow_dispatch:` only, with a first-line comment `# disabled by F01 until <node>`. Bodies stay untouched. `boot-test.yml` is `workflow_call` only and has no AWS step, so it stays. Re-enable owners: build.yml and release.yml (B03, P01), pin-bump.yml (M01), toolchain-bump.yml (M02), nightly-cve-scan.yml (P03), cve-gate-canary.yml (S01). `regen-pins.yml` (pushes on `integration/**`, AWS step at `:110-115`) has no owner in the graph; see Risks. *Proof:* F01-AC-2.
4. **`make test` becomes the fast lane.** SPEC §7 defines `make test` as the fast tier, but the predecessor's `test` target (`Makefile:500`) boots an ISO in QEMU. Rename it `test-bios` and make `test` run `bash -n` over `scripts/*.sh` and `scripts/tests/*.sh`, `py_compile` over `scripts/*.py`, and every `scripts/tests/*.sh` with `sh`, the same commands as `pr-validate.yml:25-70` (actionlint and shellcheck stay CI-only). *Proof:* F01-AC-1.
5. **`IMPORT.md`** is new. *Proof:* F01-AC-3, F01-AC-8.
6. **Action references pinned; repository settings files added.** Every `uses:` in the imported workflows becomes a full commit SHA with the tag as a comment, and `pr-validate.yml` fetches a pinned actionlint release by version and sha256 instead of a branch URL. New: `.github/dependabot.yml` (GitHub Actions ecosystem, weekly) and `.github/CODEOWNERS` with the SPEC §8 paths. This is the one place SHA pinning happens; later nodes keep it true. *Proof:* F01-AC-7.

`AGENTS.md` and `CLAUDE.md` are ported verbatim, PAT-handling rules included. Their S3 prose (`AGENTS.md:76-90,135,189-204`) is I01's edit, not F01's. README S3 links are I01's too.

## Gate
- **F01-AC-1** — `make test` runs the syntax checks and all 23 files in `scripts/tests/` and exits 0 with no network, no Docker and no build. *Verify:* `make test` on a clean checkout. *Tier:* fast.
- **F01-AC-2** — Every file in `.github/workflows/` except `pr-validate.yml` and `boot-test.yml` has `workflow_dispatch` as its only trigger, and no workflow outside the disabled set has a `schedule:` trigger. *Verify:* `scripts/tests/import.test.sh` parses the YAML with PyYAML. *Tier:* fast.
- **F01-AC-3** — A `verbatim` row of `IMPORT.md` matches the working-tree sha256 of its file, a `dropped` row names a reason and its file is absent, and the only other files in the tree are on a short list in the test (SPEC, nodes, docs/study, docs/reviews, docs/graph.yaml, IMPORT.md, the tests). This needs no predecessor history; AC-8 ties `IMPORT.md` to the predecessor. *Verify:* `scripts/tests/import.test.sh`. *Tier:* fast.
- **F01-AC-4** — No remaining file refers to a dropped path: `grep -rnE 'generate-dashboard|s3-gc|ghcr-gc|web/app|boot\.html|docs/superpowers' ` over tracked files outside `IMPORT.md` and the spec directories finds nothing. *Verify:* `scripts/tests/import.test.sh`. *Tier:* fast.
- **F01-AC-5** — `pr-validate.yml` passes on the import PR, unmodified. *Verify:* the PR's check run. *Tier:* slow.
- **F01-AC-6** — The overlay and portage config are byte-identical to the predecessor: every file under `configs/overlay`, `configs/portage` and `rootfs` has a `verbatim` row in `IMPORT.md` whose sha256 matches. AC-8 ties those rows to the fetched predecessor commit. *Verify:* `scripts/tests/import.test.sh`. *Tier:* fast.
- **F01-AC-7** — Every `uses:` in `.github/workflows/` is `owner/repo@<40 hex>` (local `./` references excepted), no workflow downloads from a branch URL, and `.github/dependabot.yml` and `.github/CODEOWNERS` exist with the SPEC §8 paths. *Verify:* `scripts/tests/import.test.sh`. *Tier:* fast.
- **F01-AC-8** — This repository does not contain the predecessor's history. `IMPORT.md` records the predecessor commit `b9f533b740b1db7bf5658d2805603d84e9b1f185` and its tree id, and lists every file of that tree once with its sha256. The test fetches exactly that commit by full SHA (`git fetch --depth=1 https://github.com/tuckermclean/linux-live-iso-factory <sha>` into a temporary repository), checks the tree id, and requires `git ls-tree -r` plus sha256 to equal `IMPORT.md`'s rows. *Verify:* `scripts/tests/import-provenance.test.sh`. *Tier:* slow (network).

## Risks
- `regen-pins.yml` is not in the graph. It stays dispatch-only and dormant until M01 deletes it.
- `scripts/attestation.sh`, `generate-provenance.py` and `nightly-cve-monitor.py` are imported although P01 and P03 may replace them. Dropping early would be speculation.
- The predecessor's fast tests need `sh`, `bash`, `python3` with PyYAML and `zstd` (unverified for every file: all 17 `*.test.sh` and the 6 `verify-*.sh` pass when run from the repo root on this host with `sh`).
