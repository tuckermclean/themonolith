# F01 — port-import

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | none | B02, I01, O01, O02, R01, R04, S01 | — | M |

**Owns:** `.github/dependabot.yml`, `.github/CODEOWNERS`, the imported tree (`configs/`, `rootfs/`, `scripts/`, `Makefile`, `Dockerfile`, `.github/workflows/`, `docs/{releasing,version-pinning,cve-gate,kernel-tiers}.md`, `README.md`, `LICENSE`, `.gitignore`, `AGENTS.md`, `CLAUDE.md`), `IMPORT.md`, `scripts/tests/import.test.sh`, `scripts/tests/import-provenance.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** everything listed under Purpose, byte for byte, except the numbered changes below.
**Study refs:** D-supply-chain-honesty, T-run-rerun-reuses-cache (why build.yml stays off), AGENTS.md traps; `docs/study/inventory.yaml`; OD-11.

## Purpose
This repository gains the predecessor's working tree at `b9f533b` (201 tracked files) with a record of what came across and what did not. After F01, `pr-validate.yml` and the 23 files in `scripts/tests/` pass here, and no workflow can reach AWS or need a secret. Nothing is rewritten. Later nodes change imported files one criterion at a time, and `IMPORT.md` records each change.

## Standard mechanism
`git merge --allow-unrelated-histories`. Under OD-11's default the predecessor's history comes into this repository once, behind one migration-boundary commit:
- **The boundary commit** is a merge whose parents are this repository's `main` and `b9f533b740b1db7bf5658d2805603d84e9b1f185`. Its tree is the predecessor's tree plus this repository's files; where the two `README.md` files meet it keeps this repository's, and change 6 joins them. Its message names the predecessor, the commit and the reason. F01's numbered changes are ordinary commits after it, so `git diff b9f533b <boundary>` shows only this repository's own files.
- **What comes across** is `b9f533b` and its ancestors (230 commits, about 3.6 MiB packed). It is fetched with `--no-tags`, so `v0.0.1` and `v0.1.0-rc1` stay only in the predecessor, where rc1's attestation verifies. No other predecessor branch comes across.
- **Nothing is rewritten.** The predecessor's commits keep their recorded authors, including the inconsistent agent identities. A scan of that history for GitHub tokens, AWS keys and private keys found none, and the predecessor is already public, so importing it publishes nothing new.
- **What it buys.** `git log` and `git blame` on a ported script reach the commit that explains it, and the verbatim check needs no network.
- **What it costs.** The import PR shows the predecessor's commits, `git log --first-parent` is needed to see this repository's own line, and that one PR is merged as a merge commit (SPEC §11).

If OD-11 chooses a clean history instead, the import is one ordinary commit with the manifest below, and the history stays in the archived predecessor. Either way `IMPORT.md` is a table `path | sha256 | status`, where status is `verbatim`, `changed by <node>`, or `dropped (<reason>)`. The test below regenerates it from `git ls-tree` plus `sha256sum`. That is a shell loop, not a tool.

## Changes from the port
Importing is the port. Dropping and disabling are changes, so each is listed.

1. **Dropped: files that serve only removed things.** `scripts/s3-gc.sh`, `scripts/tests/s3-gc.test.sh`, `.github/workflows/gc.yml` (S3 retention; SPEC §6 deletes nothing automatically); `scripts/ghcr-gc.sh`, `scripts/tests/ghcr-gc.test.sh` (same reason: a retention job is added only if storage costs money); `scripts/generate-dashboard.py`, `web/` (11 files), `boot.html` (dashboard and in-browser demo, out of scope per SPEC §0); `docs/superpowers/` (18 plans and specs, agent planning history; most mention S3 and would trip I01's check; they stay readable in the archived predecessor); `RELEASE-READINESS.md` (333 lines, dated 2026-08-02, describes a state three months stale; AGENTS.md carries the live traps). *Proof:* F01-AC-3.
2. **Dependent edits of dropped files, and nothing else.** `Makefile` target `dashboard` and its `.PHONY`/help lines (`Makefile:198,483-492`), and the `generate-dashboard.py` call in `scripts/nightly-cve-monitor.py:229-234,298-308`, are removed because their target is gone. The `ghcr-gc` and `s3-gc` references, if any, go the same way. *Proof:* F01-AC-4.
3. **Disabled: workflows other than `pr-validate.yml` and `boot-test.yml`.** `on:` of `build.yml`, `release.yml`, `pin-bump.yml`, `regen-pins.yml`, `toolchain-bump.yml`, `nightly-cve-scan.yml` and `cve-gate-canary.yml` becomes `workflow_dispatch:` only, with a first-line comment `# disabled by F01 until <node>`. Bodies stay untouched. `boot-test.yml` is `workflow_call` only and has no AWS step, so it stays. Re-enable owners: build.yml and release.yml (B03, P01), pin-bump.yml (M01), toolchain-bump.yml (M02), nightly-cve-scan.yml (P03), cve-gate-canary.yml (S01). `regen-pins.yml` (pushes on `integration/**`, AWS step at `:110-115`) has no owner in the graph; see Risks. *Proof:* F01-AC-2.
4. **`make test` becomes the fast lane.** SPEC §7 defines `make test` as the fast tier, but the predecessor's `test` target (`Makefile:500`) boots an ISO in QEMU. Rename it `test-bios` and make `test` run `bash -n` over `scripts/*.sh` and `scripts/tests/*.sh`, `py_compile` over `scripts/*.py`, and every `scripts/tests/*.sh` with `sh`, the same commands as `pr-validate.yml:25-70` (actionlint and shellcheck stay CI-only). *Proof:* F01-AC-1.
5. **`IMPORT.md`** is new. *Proof:* F01-AC-3, F01-AC-8.
6. **`README.md` joins both.** It is the only path both sides have that differs (`LICENSE` is byte-identical). This repository's opening section stays on top and the predecessor's README follows it verbatim, so G01's `b9f533b` line references stay readable. `IMPORT.md` marks it `changed by F01`. *Proof:* F01-AC-3.
7. **Action references pinned; repository settings files added.** Every `uses:` in the imported workflows becomes a full commit SHA with the tag as a comment, and `pr-validate.yml` fetches a pinned actionlint release by version and sha256 instead of a branch URL. New: `.github/dependabot.yml` (GitHub Actions ecosystem, weekly) and `.github/CODEOWNERS` with the SPEC §8 paths. This is the one place SHA pinning happens; later nodes keep it true. *Proof:* F01-AC-7.

`AGENTS.md` and `CLAUDE.md` are ported verbatim, PAT-handling rules included. Their S3 prose (`AGENTS.md:76-90,135,189-204`) is I01's edit, not F01's. README S3 links are I01's too.

## Gate
- **F01-AC-1** — `make test` runs the syntax checks and all 23 files in `scripts/tests/` and exits 0 with no network, no Docker and no build. *Verify:* `make test` on a clean checkout. *Tier:* fast.
- **F01-AC-2** — Every file in `.github/workflows/` except `pr-validate.yml` and `boot-test.yml` has `workflow_dispatch` as its only trigger, and no workflow outside the disabled set has a `schedule:` trigger. *Verify:* `scripts/tests/import.test.sh` parses the YAML with PyYAML. *Tier:* fast.
- **F01-AC-3** — A `verbatim` row of `IMPORT.md` matches the working-tree sha256 of its file, a `dropped` row names a reason and its file is absent, and the only other files in the tree are on a short list in the test (SPEC, MYTH.md, nodes, docs/study, docs/reviews, docs/graph.yaml, IMPORT.md, the tests). This check reads only the working tree; AC-8 ties `IMPORT.md` to the predecessor. *Verify:* `scripts/tests/import.test.sh`. *Tier:* fast.
- **F01-AC-4** — No remaining file refers to a dropped path: `grep -rnE 'generate-dashboard|s3-gc|ghcr-gc|web/app|boot\.html|docs/superpowers' ` over tracked files outside `IMPORT.md` and the spec directories finds nothing. *Verify:* `scripts/tests/import.test.sh`. *Tier:* fast.
- **F01-AC-5** — `pr-validate.yml` passes on the import PR, unmodified. *Verify:* the PR's check run. *Tier:* slow.
- **F01-AC-6** — The overlay and portage config are byte-identical to the predecessor: every file under `configs/overlay`, `configs/portage` and `rootfs` has a `verbatim` row in `IMPORT.md` whose sha256 matches. AC-8 ties those rows to the fetched predecessor commit. *Verify:* `scripts/tests/import.test.sh`. *Tier:* fast.
- **F01-AC-7** — Every `uses:` in `.github/workflows/` is `owner/repo@<40 hex>` (local `./` references excepted), no workflow downloads from a branch URL, and `.github/dependabot.yml` and `.github/CODEOWNERS` exist with the SPEC §8 paths. *Verify:* `scripts/tests/import.test.sh`. *Tier:* fast.
- **F01-AC-8** — `IMPORT.md` records the predecessor commit `b9f533b740b1db7bf5658d2805603d84e9b1f185` and its tree id, and lists every file of that tree once with its sha256. Under OD-11's default: exactly one commit on `main` has `b9f533b` as a parent, `git ls-tree -r b9f533b` plus sha256 equals `IMPORT.md`'s rows, no predecessor tag exists in this repository, and no commit in `b9f533b`'s ancestry differs from the predecessor's (same ids). With a clean history: the test fetches that commit by full SHA (`git fetch --depth=1 https://github.com/tuckermclean/linux-live-iso-factory <sha>` into a temporary repository), checks the tree id and requires the same equality, and no commit here has a predecessor parent. *Verify:* `scripts/tests/import-provenance.test.sh`. *Tier:* fast under the default (history is local), slow (network) with a clean history.

## Risks
- `regen-pins.yml` is not in the graph. It stays dispatch-only and dormant until M01 deletes it.
- `scripts/attestation.sh`, `generate-provenance.py` and `nightly-cve-monitor.py` are imported although P01 and P03 may replace them. Dropping early would be speculation.
- The predecessor's fast tests need `sh`, `bash`, `python3` with PyYAML and `zstd` (unverified for every file: all 17 `*.test.sh` and the 6 `verify-*.sh` pass when run from the repo root on this host with `sh`).
