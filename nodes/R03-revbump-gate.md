# R03 — revbump-gate

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| R | R01 | none | — | M |

**Owns:** `factory/bin/revbump-check`, `factory/lib/gentoo_version.py`, `recipes/revbump-rules.yaml`, `.github/workflows/pr-recipes.yml`, `tests/fast/revbump-*.test.sh`, `tests/fast/gentoo-version.test.sh`, `tests/fast/fixtures/revbump/`.
**Carries from linux-live-iso-factory@b9f533b:** the proposed gate in `doctrine.yaml` D-revbump-on-overlay-change.
**Study refs:** T-binpkg-revbump; D-revbump-on-overlay-change; recipes.yaml `notes_general` (revbump is the only cache-buster), contradiction #5 (stale busybox binpkg), `cfg.portage/savedconfig/sys-apps/busybox`, the kernel ebuild entry (r7→r8); SPEC §5 (binpkg key), §8 (trusted base).

## Purpose
After R03, a pull request that changes an overlay package's ebuild, `files/` or patches without bumping the package version and its `pins/versions.lock` line fails CI. The predecessor paid for this omission three times with the same perl panic (T-binpkg-revbump), because portage reused a cached binary when version, USE and CHOST matched.

In v0.3 R03 is hygiene, not cache correctness. I06's per-package fingerprint covers the ebuild, `files/`, savedconfig, `package.env` and patches, so an overlay edit without a bump already misses the cache. I06's global key covers `make.conf`, `bashrc`, `profile/` and `env/`. R03 keeps the version lock honest: the lock line, the ebuild version and the shipped package version agree, and a changed recipe is visible in the version history and the SBOM. R03 is on the parallel track; nothing on the path to MS2 waits for it.

## Scope
In:
- `revbump-check`: a base-vs-head git check of per-package inputs, run from the trusted base.
- `recipes/revbump-rules.yaml`: the one declaration of which files need a bump when they change, which are covered by I06's cache keys instead, and which feed nothing (with reasons).
- A Gentoo version-comparison library (PMS 3.2) with a table test.

Out:
- Computing cache keys and fingerprints, and reading or writing the cache: I06 (global key, per-package fingerprint, `factory/data/cache-inputs.yaml`). R03 does not duplicate them. Savedconfig and global-config edits need no bump because I06 keys them.
- The version lock contents and completeness: R02 (R03 only checks that the lock line matches the bumped ebuild).
- Required-check configuration in branch protection: the maintainer, after R03 merges (protected path).
- Fragment contents and the kernel ebuild changes: R04. I06's fingerprint (`recipes/kernel/` listed in `factory/data/cache-inputs.yaml`) makes fragment edits safe without a bump; R03 only records that arrangement.
- Commit identity and RED/GREEN discipline: F04.

## Design

### Declaration: `recipes/revbump-rules.yaml`
```yaml
version: 1
overlay:                      # rule: every recipes/overlay/<cat>/<pn>/ is a package
  inputs: ["**"]              # all files in the package dir ...
  ignore: ["*.md"]            # ... except documentation
  comment_only_ebuild_ok: true
keyed_elsewhere:              # edits need no bump because I06 keys them (fingerprint or global key)
  - {path: "recipes/kernel/**", keyed_by: "I06 fingerprint of sys-kernel/monolith-kernel (factory/data/cache-inputs.yaml)"}
  - {path: "recipes/portage/savedconfig/**", keyed_by: "I06 fingerprint of the package"}
  - {path: "recipes/portage/package.env/**", keyed_by: "I06 fingerprint of the matching packages"}
  - {path: recipes/portage/make.conf, keyed_by: "I06 global key"}
  - {path: recipes/portage/bashrc, keyed_by: "I06 global key"}
  - {path: "recipes/portage/env/**", keyed_by: "I06 global key"}
  - {path: "recipes/portage/profile/**", keyed_by: "I06 global key"}
excluded:                     # every other file under recipes/ or pins/ and why it is not an input
  - {path: recipes/portage/world, reason: "set membership; R02 checks the lock"}
  - {path: "recipes/portage/package.use/**", reason: "USE is part of portage's own binpkg match (version+USE+CHOST)"}
  - {path: "recipes/portage/package.mask/**", reason: "affects resolution only, not package content"}
  - {path: "recipes/portage/package.accept_keywords/**", reason: "version selection only"}
  - {path: recipes/IMPORT.yaml, reason: "provenance"}
  # ...
```
Decision: three classes (overlay-per-package revbump, keyed elsewhere, excluded) over one declaration file. Rejected: the v0.2 design that also kept a digest lock for busybox's savedconfig and a `profile-hash` for B01's key. I06's fingerprint and global key now do both, and a second mechanism would diverge from them. Rejected: drop the `-rN` convention and rely on the fingerprint alone. SPEC §3 states D-revbump-on-overlay-change as a doctrine, and a bump is what makes a recipe change visible in the lock, the SBOM and the package version.

The file is named `revbump-rules.yaml` to avoid confusion with I06's `factory/data/cache-inputs.yaml`, which lists extra cache inputs per package. The two answer different questions. `classify` checks that every `keyed_elsewhere` path is also covered by I06's inputs (a global-key path or a `cache-inputs.yaml` entry), so the two files cannot drift.

Why `package.use` is excluded: portage compares USE when matching a binpkg. Whether `initrd-modules` is an input is B03's; R03 treats the rest of `recipes/kernel/` as keyed by I06.

### `factory/bin/revbump-check`
`python3 -I`, standard library plus PyYAML plus `git` on `PATH`.
```
revbump-check check   --repo DIR --base-rev REV --head-rev REV [--rules FILE]
revbump-check classify --repo DIR                 # every file classified; no git needed
```
`--rules` defaults to `<repo>/recipes/revbump-rules.yaml`; CI passes the file from the base checkout. Exit codes: 0 pass; 1 findings; 2 usage; 3 environment (git ref missing, rules unreadable). A missing base ref is an error, never a pass.

`check` algorithm, per package P (overlay dir, or extra-input package):
1. Inputs(P) = files of its dir (minus `ignore`), listed from `git ls-tree -r` at base and at head (blob ids, so renames need no heuristics).
2. An input counts as changed if its blob differs, it was added, or removed. An `.ebuild` whose blob differs but whose comment-stripped content (delete lines whose first non-blank character is `#`, and blank lines) is identical, counts as unchanged. A version rename of the ebuild with identical stripped content is a pure revbump (allowed).
3. If P is new at head: require a lock line `cat/pn:<ebuild version>:*` in `pins/versions.lock` at head (`NOLOCK`).
4. If P is removed at head: require the lock line absent (`ORPHANLOCK`).
5. If any input changed: let `vb`, `vh` be the ebuild versions at base and head. Require `vh > vb` by `gentoo_version.compare` (`NOBUMP` if equal, `DOWNGRADE` if lower) and the head lock line for `cat/pn` equal to `vh` (`LOCK`).
6. If no input changed but the lock line for an overlay package changed: `LOCKONLY` (a hand-edited pin, not a rebuild trigger).
7. If a path in a `keyed_elsewhere` class changed (global config, savedconfig, kernel files): print `NOTICE <path> is keyed by I06 (<keyed_by>): no bump needed; a global-config change opens a new cache namespace` and pass.
8. Print a summary table per package: `unchanged | revbumped vb -> vh | FAIL code`. A PR with no recipe changes prints `no recipe inputs changed` and exits 0.

No exemption mechanism (commit trailer or exempt-file). A pure comment edit is already free (step 2); anything else changes what gets built. Rejected: `Revbump-Exempt:` trailer — it moves the decision from a checked rule to an unchecked claim, and trailer parsing is F04's surface.

`classify` fails (`UNCLASSIFIED`) if a file under `recipes/` or `pins/` is covered by none of `overlay`, `keyed_elsewhere`, `excluded`. This forces anyone adding a new config directory to say whether it feeds the build.

### `factory/lib/gentoo_version.py`
PMS section 3.2 ordering: numeric components (components with a leading zero compare as strings with trailing zeros stripped), optional letter, suffix chain (`_alpha < _beta < _pre < _rc < (none) < _p`, each with optional number), then `-rN`. API: `parse(str)`, `compare(a, b)` returning -1/0/1, `ValueError` on malformed input. Table test covers every overlay version in the tree and PMS edge cases (see AC-9).

### Workflow: `.github/workflows/pr-recipes.yml`
Trigger `pull_request` on paths `recipes/**`, `pins/**`, `factory/bin/revbump-check`. Job `revbump`: checkout base commit into `trusted/` (the PR's `base.sha`), checkout head into `head/` with full history for the merge base; run `python3 -I trusted/factory/bin/revbump-check check --repo head --base-rev $BASE --head-rev $HEAD --rules trusted/recipes/revbump-rules.yaml`. Checker and rules both come from the base revision (SPEC §8). All actions pinned by SHA (F01 rule). Permissions `contents: read`. Bootstrap: the PR that introduces the tool has no tool at base; the job is not a required check until the maintainer enables it after merge.

## Traps and doctrines preserved
- T-binpkg-revbump / D-revbump-on-overlay-change (edit without bump reuses a stale binary): R03-AC-1, R03-AC-2, R03-AC-4, R03-AC-5.
- Stale savedconfig-governed binpkg (busybox `findfs` incident, contradiction #5): no longer an R03 concern. I06's fingerprint covers the savedconfig (I06-AC-3); R03-AC-6 is withdrawn.
- Config that the matcher cannot see (`bashrc`, `env/*`): I06's global key covers it (I06-AC-1). R03-AC-7 is withdrawn; R03-AC-13 prints the notice and R03-AC-8 keeps `classify` complete.
- Kernel fragments as kernel inputs (otherwise a fragment edit reuses the old kernel and the resolved-config proof is vacuous, T-resolved-kernel-config-vacuous): the `keyed_elsewhere` class in R03-AC-5 records that I06's kernel fingerprint covers `recipes/kernel/`; the cache behaviour itself is I06-AC-3.
- SPEC §8 trusted base (a PR must not weaken the check that judges it): R03-AC-10.
- Honest success (a missing ref or unreadable rules is an error, not a pass): R03-AC-11.

## Gate
- **R03-AC-1** — Changing any non-comment byte of an overlay package's ebuild, `files/**` or `Manifest` with the same ebuild version fails with `NOBUMP`. *Verify:* `tests/fast/revbump-check.test.sh` (fixture repos built with `git init` in a temp dir; one case per input kind). *Tier:* fast.
- **R03-AC-2** — A bump (ebuild renamed to a higher version) plus the matching `pins/versions.lock` line passes; a bump without the lock line fails `LOCK`; a lock-only change fails `LOCKONLY`; a lower version fails `DOWNGRADE`. *Verify:* `tests/fast/revbump-check.test.sh`. *Tier:* fast.
- **R03-AC-3** — Comment-only ebuild edits and `*.md` edits in a package dir pass without a bump. *Verify:* `tests/fast/revbump-check.test.sh`. *Tier:* fast.
- **R03-AC-4** — A new overlay package requires a lock line (`NOLOCK`); a removed one requires the lock line removed (`ORPHANLOCK`). *Verify:* `tests/fast/revbump-check.test.sh`. *Tier:* fast.
- **R03-AC-5** — Kernel inputs are handled by class: a change to the `monolith-kernel` ebuild, patch or `files/` without a bump fails `NOBUMP`; a change under `recipes/kernel/` (fragments, docs, tools, lists) is classified `keyed_elsewhere`, passes without a bump and prints `NOTICE ... keyed by I06`. Removing the path from `keyed_elsewhere` and listing it as a package input makes the same change fail, which the test also exercises. *Verify:* `tests/fast/revbump-check.test.sh`. *Tier:* fast.
- **R03-AC-6** — *Withdrawn (v0.3):* the busybox digest lock duplicated I06's per-package fingerprint, which covers savedconfig files (I06-AC-3).
- **R03-AC-7** — *Withdrawn (v0.3):* `profile-hash` duplicated I06's global key over `make.conf`, `bashrc`, `profile/` and `env/` (I06-AC-1).
- **R03-AC-8** — Every file under `recipes/` and `pins/` in the repository is classified; adding a file in a new directory fails `UNCLASSIFIED`. *Verify:* `tests/fast/revbump-classify.test.sh` (runs on the real tree and on a fixture). *Tier:* fast.
- **R03-AC-9** — `gentoo_version.compare` orders at least 25 pairs correctly, including `6.12.80-r8 < 6.12.80-r9`, `0.1.0 < 0.1.0_p20260805`, `1.3_p20241113 < 1.3_p20241113-r1`, `3.53.4 < 3.53.10`, `5.42.0-r5 < 5.42.1`, `1.0_rc1 < 1.0`, `1.0_alpha < 1.0_beta < 1.0_pre < 1.0_rc < 1.0 < 1.0_p`, `1.0 < 1.0a`, `1.01 vs 1.1` per PMS, and rejects malformed strings. *Verify:* `tests/fast/gentoo-version.test.sh`. *Tier:* fast.
- **R03-AC-10** — The workflow checks out the base commit and runs the checker and `revbump-rules.yaml` from that checkout, not from the head; actions are SHA-pinned; `actionlint` passes. *Verify:* `tests/fast/revbump-workflow.test.sh` (parses the YAML: asserts `trusted/` is the base ref, the script path starts with `trusted/`, `--rules trusted/...`). *Tier:* fast.
- **R03-AC-11** — An unknown base ref, a missing `pins/versions.lock`, or an unreadable rules file exits 3 and never 0. *Verify:* `tests/fast/revbump-check.test.sh`. *Tier:* fast.
- **R03-AC-12** — Every finding line has the form `<code> <atom>: <what changed> -> <exact fix>` (for example `NOBUMP sys-kernel/monolith-kernel: recipes/overlay/sys-kernel/monolith-kernel/files/linux-6.12-gcc15-std-gnu11.patch changed -> git mv monolith-kernel-6.12.80-r9.ebuild monolith-kernel-6.12.80-r10.ebuild and update pins/versions.lock`), and the exit code is the count class (0/1/2/3 as specified), never a shell-pipeline artefact. *Verify:* `tests/fast/revbump-check.test.sh` (asserts the message grammar with a regex on each negative case). *Tier:* fast.
- **R03-AC-13** — A PR that changes only a `keyed_elsewhere` global-config path (`make.conf`, `bashrc`, `env/**`, `profile/**`) passes with `NOTICE <path> is keyed by I06 ...: a global-config change opens a new cache namespace`; `classify` fails when a `keyed_elsewhere` path is not covered by I06's inputs (`factory/data/cache-inputs.yaml` or the global-key paths). *Verify:* `tests/fast/revbump-keyed.test.sh`. *Tier:* fast.

## RED plan
The tester commits the fixture builder (`tests/fast/fixtures/revbump/make-repo.sh`, which creates base and head commits for each case) and these tests: `revbump-check.test.sh`, `revbump-keyed.test.sh`, `revbump-classify.test.sh`, `gentoo-version.test.sh`, `revbump-workflow.test.sh`. At RED none of `factory/bin/revbump-check`, `factory/lib/gentoo_version.py`, `recipes/revbump-rules.yaml` or the workflow exists, so each test fails with a missing file. Every defect case is also run against a deliberately wrong "always pass" stub in the test itself (the test asserts the stub fails the suite) so the tests cannot pass vacuously.

## Risks and open questions
- Whether `package.use` edits really bust binpkg matches depends on `--binpkg-respect-use`; the exclusion rests on the predecessor's statement "keys on version+USE+CHOST" (`doctrine.yaml` T-binpkg-revbump). I06-AC-7's fixture or B01 should assert it once with a USE flip on a cached package.
- Comment-only detection for `.ebuild` could hide a change in a comment-looking line inside a heredoc. Ebuilds in the tree contain none; `recipes-lint` (R01) does not check this. If one appears, the gate under-reports; the cost is a stale binary, the same failure we are preventing.
- Adding a new global config directory forces an edit to `revbump-rules.yaml` (by design, `UNCLASSIFIED`).
- R03 no longer protects the cache. If I06's fingerprint misses an input, the release audit is the backstop, not R03. A bump is still required for overlay edits so that the version lock stays honest.
- `classify` reads I06's `factory/data/cache-inputs.yaml` and the global-key path list. If I06 changes their format, AC-13 breaks loudly; both nodes should name the shared parser in `factory/lib/cache/`.
- A new human-judgement item: SPEC §10 has no OD for "revbump-exempt" cases; none is proposed.

## Cost
Two slices: (1) `gentoo_version`, `classify`, `check` core with fixtures (AC-1–5, 8, 9, 11, 12); (2) workflow and the keyed-elsewhere notice (AC-10, 13). AC-6 and AC-7 are withdrawn. No CI build cycles; the workflow runs in seconds. No storage or hosting cost.

## Spec defects found
- No node owns the trusted-base wiring for PR checks in general: F04 owns identity and RED/GREEN discipline, F01 the fast lane. R03 writes its own `pr-recipes.yml`; F04 should offer a shared reusable action so each gate does not hand-roll the base checkout.
- SPEC §3 says D-revbump-on-overlay-change covers "an ebuild or its files"; the predecessor's doctrine also named savedconfig and the kernel config. In v0.3 I06 keys those, so R03 requires a bump only for overlay packages. SPEC wording is consistent; no change needed.
