# R03 — revbump-gate

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| R | R01 | B01 | — | M |

**Owns:** `factory/bin/revbump-check`, `factory/lib/gentoo_version.py`, `recipes/cache-inputs.yaml`, `pins/config-digests.lock`, `.github/workflows/pr-recipes.yml`, `tests/fast/revbump-*.test.sh`, `tests/fast/gentoo-version.test.sh`, `tests/fast/fixtures/revbump/`.
**Carries from linux-live-iso-factory@b9f533b:** the logic (not the file) of `scripts/savedconfig-cache.sh` and its cases from `scripts/tests/savedconfig-cache.test.sh`; the proposed gate in `doctrine.yaml` D-revbump-on-overlay-change.
**Study refs:** T-binpkg-revbump; D-revbump-on-overlay-change; recipes.yaml `notes_general` (revbump is the only cache-buster), contradiction #5 (stale busybox binpkg), `cfg.portage/savedconfig/sys-apps/busybox`, the kernel ebuild entry (r7→r8); SPEC §5 (binpkg key), §8 (trusted base).

## Purpose
Portage reuses a cached binary package when version, USE and CHOST match; it does not look at ebuild contents, `files/`, patches or the configuration the build reads. After R03, a pull request that changes any such input without bumping the package version and its `pins/versions.lock` line fails CI, and the two cases a version bump cannot cover (a savedconfig for an upstream ebuild, and global build environment files) have an explicit mechanical key. The predecessor paid this cost three times with the same perl panic (T-binpkg-revbump).

## Scope
In:
- `revbump-check`: a base-vs-head git check of per-package inputs, run from the trusted base.
- `recipes/cache-inputs.yaml`: the one declaration of which files feed which package, which feed every package, and which feed none (with reasons).
- A digest lock for packages whose inputs live outside an ebuild we own (today: `sys-apps/busybox`).
- A profile-hash command that B01 uses so global environment edits invalidate the cache.
- A Gentoo version-comparison library (PMS 3.2) with a table test.

Out:
- Computing the binpkg key and reading/writing the cache: B01 (R03 supplies `profile-hash` and the digest lock; B01 puts them in the key).
- The version lock contents and completeness: R02 (R03 only checks that the lock line matches the bumped ebuild).
- Required-check configuration in branch protection: the maintainer, after R03 merges (protected path).
- Fragment contents and the kernel ebuild changes: R04. B02 owns the content-hash key that makes fragment edits safe without a bump; R03 only records that arrangement.
- Commit identity and RED/GREEN discipline: F04.

## Design

### Declaration: `recipes/cache-inputs.yaml`
```yaml
version: 1
overlay:                      # rule: every recipes/overlay/<cat>/<pn>/ is a package
  inputs: ["**"]              # all files in the package dir ...
  ignore: ["*.md"]            # ... except documentation
  comment_only_ebuild_ok: true
content_keyed:                # inputs whose edits need no bump because B02 puts their hash in the binpkg key
  - {atom: sys-kernel/monolith-kernel, inputs: ["recipes/kernel/frag/**"], keyed_by: "B02 kprofile = sha256(merged fragments) + ebuild + files/"}
packages: []                  # extra inputs outside a package dir that DO require a bump (none today; the kernel fragments move here if B02 drops its config-hash key)
digests:                      # inputs of a package we do not own; a digest line is the "bump"
  - atom: sys-apps/busybox
    inputs: ["recipes/portage/savedconfig/sys-apps/busybox"]
    lock: pins/config-digests.lock
profile:                      # a change invalidates every binpkg; B01 hashes exactly these
  inputs:
    - recipes/portage/make.conf
    - recipes/portage/bashrc
    - "recipes/portage/env/**"
    - "recipes/portage/package.env/**"
excluded:                     # every other file under recipes/ or pins/ and why it is not an input
  - {path: recipes/portage/world, reason: "set membership; binpkgs are keyed per cpv"}
  - {path: "recipes/portage/package.use/**", reason: "USE is part of portage's own binpkg match (version+USE+CHOST)"}
  - {path: "recipes/portage/package.mask/**", reason: "affects resolution only, not package content"}
  - {path: "recipes/portage/package.accept_keywords/**", reason: "version selection only"}
  - {path: "recipes/portage/profile/**", reason: "dependency selection only; drift is checked by R02"}
  - {path: "recipes/kernel/**", reason: "except frag/**, which is content-keyed above; tools, docs and invariants are not build inputs"}
  - {path: recipes/IMPORT.yaml, reason: "provenance"}
  # ...
```
Decision: four input classes (overlay-per-package revbump, digest, content-keyed, profile) over one declaration file. Rejected: key the binpkg on a content hash of ebuild+files+config and drop the `-rN` convention. SPEC §3 states D-revbump-on-overlay-change as a doctrine and §5 fixes the key as `<tree-hash>/<profile-hash>/<cpv>`; changing the key contract is out of R03's authority and a content key would silently rebuild on comment edits. Rejected: the predecessor's runtime marker file inside the cache (`savedconfig-cache.sh`): the invalidation was invisible to review and acted on hidden cache state. The digest lock makes the same invalidation a reviewed diff.

Why `package.use` is excluded: portage compares USE when matching a binpkg. Why `bashrc`, `env/*`, `package.env/*` and `make.conf` are in the profile set: they change how a package builds and are invisible to the matcher (every `bashrc` hook in the study is of this kind). Whether `initrd-modules` or the initrd are cached is B03's; R03 treats `recipes/kernel/**` outside `frag/` as not an input because the initramfs is assembled every run (`scripts/build-initrd.sh` has no cache), and flags the assumption for B03.

### `factory/bin/revbump-check`
`python3 -I`, standard library plus PyYAML plus `git` on `PATH`.
```
revbump-check check   --repo DIR --base-rev REV --head-rev REV [--rules FILE]
revbump-check classify --repo DIR                 # every file classified; no git needed
revbump-check digest  --repo DIR [update]         # verify / rewrite pins/config-digests.lock
revbump-check profile-hash --repo DIR             # sha256 of the profile inputs, stdout
```
`--rules` defaults to `<repo>/recipes/cache-inputs.yaml`; CI passes the file from the base checkout. Exit codes: 0 pass; 1 findings; 2 usage; 3 environment (git ref missing, rules unreadable). A missing base ref is an error, never a pass.

`check` algorithm, per package P (overlay dir, or extra-input package):
1. Inputs(P) = files of its dir (minus `ignore`) plus `extra_inputs`, listed from `git ls-tree -r` at base and at head (blob ids, so renames need no heuristics).
2. An input counts as changed if its blob differs, it was added, or removed. An `.ebuild` whose blob differs but whose comment-stripped content (delete lines whose first non-blank character is `#`, and blank lines) is identical, counts as unchanged. A version rename of the ebuild with identical stripped content is a pure revbump (allowed).
3. If P is new at head: require a lock line `cat/pn:<ebuild version>:*` in `pins/versions.lock` at head (`NOLOCK`).
4. If P is removed at head: require the lock line absent (`ORPHANLOCK`).
5. If any input changed: let `vb`, `vh` be the ebuild versions at base and head. Require `vh > vb` by `gentoo_version.compare` (`NOBUMP` if equal, `DOWNGRADE` if lower) and the head lock line for `cat/pn` equal to `vh` (`LOCK`).
6. If no input changed but the lock line for an overlay package changed: `LOCKONLY` (a hand-edited pin, not a rebuild trigger).
7. Digest packages: recomputed `sha256` of the concatenated inputs (path-sorted, `path\0content\0`) must equal the line in `pins/config-digests.lock` at head (`DIGEST`). `digest update` rewrites the file; line format `category/package sha256:<64 hex>`, sorted. If inputs changed between base and head and the digest line did not, that is the same `DIGEST` finding.
8. If a profile input changed: print `NOTICE profile inputs changed (<files>): every cached binpkg is invalidated; expect a full rebuild` and pass.
9. Print a summary table per package: `unchanged | revbumped vb -> vh | FAIL code`. A PR with no recipe changes prints `no recipe inputs changed` and exits 0.

No exemption mechanism (commit trailer or exempt-file). A pure comment edit is already free (step 2); anything else changes what gets built. Rejected: `Revbump-Exempt:` trailer — it moves the decision from a checked rule to an unchecked claim, and trailer parsing is F04's surface.

`classify` fails (`UNCLASSIFIED`) if a file under `recipes/` or `pins/` is covered by none of `overlay`, `packages`, `digests`, `profile`, `excluded`. This forces anyone adding a new config directory to say whether it feeds the build.

`profile-hash`: `sha256` over the sorted `(path, content)` pairs of the profile inputs; no dependence on checkout location, mtimes or permissions. B01 combines it with the tree hash (SPEC §5 `<profile-hash>`).

### `factory/lib/gentoo_version.py`
PMS section 3.2 ordering: numeric components (components with a leading zero compare as strings with trailing zeros stripped), optional letter, suffix chain (`_alpha < _beta < _pre < _rc < (none) < _p`, each with optional number), then `-rN`. API: `parse(str)`, `compare(a, b)` returning -1/0/1, `ValueError` on malformed input. Table test covers every overlay version in the tree and PMS edge cases (see AC-9).

### Workflow: `.github/workflows/pr-recipes.yml`
Trigger `pull_request` on paths `recipes/**`, `pins/**`, `factory/bin/revbump-check`. Job `revbump`: checkout base commit into `trusted/` (the PR's `base.sha`), checkout head into `head/` with full history for the merge base; run `python3 -I trusted/factory/bin/revbump-check check --repo head --base-rev $BASE --head-rev $HEAD --rules trusted/recipes/cache-inputs.yaml`. Checker and rules both come from the base revision (SPEC §8). All actions pinned by SHA (F01 rule). Permissions `contents: read`. Bootstrap: the PR that introduces the tool has no tool at base; the job is not a required check until the maintainer enables it after merge.

## Traps and doctrines preserved
- T-binpkg-revbump / D-revbump-on-overlay-change (edit without bump reuses a stale binary): R03-AC-1, R03-AC-2, R03-AC-4, R03-AC-5.
- Stale savedconfig-governed binpkg (busybox `findfs` incident, contradiction #5): R03-AC-6.
- Config that the matcher cannot see (`bashrc`, `env/*`): R03-AC-7 and the `classify` completeness rule R03-AC-8.
- Kernel fragments as kernel inputs (otherwise a fragment edit reuses the old kernel and the resolved-config proof is vacuous, T-resolved-kernel-config-vacuous): R03-AC-5, via the content-keyed class that B02's binpkg key implements.
- SPEC §8 trusted base (a PR must not weaken the check that judges it): R03-AC-10.
- Honest success (a missing ref or unreadable rules is an error, not a pass): R03-AC-11.

## Gate
- **R03-AC-1** — Changing any non-comment byte of an overlay package's ebuild, `files/**` or `Manifest` with the same ebuild version fails with `NOBUMP`. *Verify:* `tests/fast/revbump-check.test.sh` (fixture repos built with `git init` in a temp dir; one case per input kind). *Tier:* fast.
- **R03-AC-2** — A bump (ebuild renamed to a higher version) plus the matching `pins/versions.lock` line passes; a bump without the lock line fails `LOCK`; a lock-only change fails `LOCKONLY`; a lower version fails `DOWNGRADE`. *Verify:* `tests/fast/revbump-check.test.sh`. *Tier:* fast.
- **R03-AC-3** — Comment-only ebuild edits and `*.md` edits in a package dir pass without a bump. *Verify:* `tests/fast/revbump-check.test.sh`. *Tier:* fast.
- **R03-AC-4** — A new overlay package requires a lock line (`NOLOCK`); a removed one requires the lock line removed (`ORPHANLOCK`). *Verify:* `tests/fast/revbump-check.test.sh`. *Tier:* fast.
- **R03-AC-5** — Kernel inputs are handled by class: a change to the `monolith-kernel` ebuild, patch or `files/` without a bump fails `NOBUMP`; a change under `recipes/kernel/frag/**` is classified `content_keyed`, passes without a bump and prints `NOTICE content-keyed by B02`; a change elsewhere under `recipes/kernel/` (docs, tools, invariants, lists) passes silently. Moving the fragments into `packages.extra_inputs` makes the same change fail, which the test also exercises. *Verify:* `tests/fast/revbump-check.test.sh`. *Tier:* fast.
- **R03-AC-6** — The busybox savedconfig has a digest line in `pins/config-digests.lock`; editing the savedconfig without `digest update` fails `DIGEST`; running `digest update` then passes; the three cases of `savedconfig-cache.test.sh` (changed, unchanged, no marker) are ported as digest-mismatch, match, and missing-line. *Verify:* `tests/fast/revbump-digest.test.sh`. *Tier:* fast.
- **R03-AC-7** — `profile-hash` is stable across two checkouts at different paths, changes when `bashrc` or any `env/*` or `package.env/*` file changes, and does not change when `world`, `package.use` or `package.mask` changes; a PR touching a profile input passes with the `NOTICE` line. *Verify:* `tests/fast/revbump-profile.test.sh`. *Tier:* fast.
- **R03-AC-8** — Every file under `recipes/` and `pins/` in the repository is classified; adding a file in a new directory fails `UNCLASSIFIED`. *Verify:* `tests/fast/revbump-classify.test.sh` (runs on the real tree and on a fixture). *Tier:* fast.
- **R03-AC-9** — `gentoo_version.compare` orders at least 25 pairs correctly, including `6.12.80-r8 < 6.12.80-r9`, `0.1.0 < 0.1.0_p20260805`, `1.3_p20241113 < 1.3_p20241113-r1`, `3.53.4 < 3.53.10`, `5.42.0-r5 < 5.42.1`, `1.0_rc1 < 1.0`, `1.0_alpha < 1.0_beta < 1.0_pre < 1.0_rc < 1.0 < 1.0_p`, `1.0 < 1.0a`, `1.01 vs 1.1` per PMS, and rejects malformed strings. *Verify:* `tests/fast/gentoo-version.test.sh`. *Tier:* fast.
- **R03-AC-10** — The workflow checks out the base commit and runs the checker and `cache-inputs.yaml` from that checkout, not from the head; actions are SHA-pinned; `actionlint` passes. *Verify:* `tests/fast/revbump-workflow.test.sh` (parses the YAML: asserts `trusted/` is the base ref, the script path starts with `trusted/`, `--rules trusted/...`). *Tier:* fast.
- **R03-AC-11** — An unknown base ref, a missing `pins/versions.lock`, or an unreadable rules file exits 3 and never 0. *Verify:* `tests/fast/revbump-check.test.sh`. *Tier:* fast.
- **R03-AC-12** — Every finding line has the form `<code> <atom>: <what changed> -> <exact fix>` (for example `NOBUMP sys-kernel/monolith-kernel: recipes/overlay/sys-kernel/monolith-kernel/files/linux-6.12-gcc15-std-gnu11.patch changed -> git mv monolith-kernel-6.12.80-r9.ebuild monolith-kernel-6.12.80-r10.ebuild and update pins/versions.lock`), and the exit code is the count class (0/1/2/3 as specified), never a shell-pipeline artefact. *Verify:* `tests/fast/revbump-check.test.sh` (asserts the message grammar with a regex on each negative case). *Tier:* fast.

## RED plan
The tester commits the fixture builder (`tests/fast/fixtures/revbump/make-repo.sh`, which creates base and head commits for each case) and these tests: `revbump-check.test.sh`, `revbump-digest.test.sh`, `revbump-profile.test.sh`, `revbump-classify.test.sh`, `gentoo-version.test.sh`, `revbump-workflow.test.sh`. At RED none of `factory/bin/revbump-check`, `factory/lib/gentoo_version.py`, `recipes/cache-inputs.yaml` or the workflow exists, so each test fails with a missing file. Every defect case is also run against a deliberately wrong "always pass" stub in the test itself (the test asserts the stub fails the suite) so the tests cannot pass vacuously.

## Risks and open questions
- Whether `package.use` edits really bust binpkg matches depends on `--binpkg-respect-use`; the exclusion rests on the predecessor's statement "keys on version+USE+CHOST" (`doctrine.yaml` T-binpkg-revbump). B01 should assert it once with a USE flip on a cached package.
- Comment-only detection for `.ebuild` could hide a change in a comment-looking line inside a heredoc. Ebuilds in the tree contain none; `recipes-lint` (R01) does not check this. If one appears, the gate under-reports; the cost is a stale binary, the same failure we are preventing.
- Adding a new global config directory forces an edit to `cache-inputs.yaml` (by design, `UNCLASSIFIED`).
- Profile-set breadth: editing `bashrc` for one package rebuilds everything (30–60 minutes). Narrowing needs per-package attribution of `bashrc` hooks; deferred. A `# WA bashrc#n` tag (R01) names the package per hook, so a later refinement is possible.
- B02's kernel key (`kprofile`, B02 spec) includes the merged-config hash, which is why fragments are content-keyed here; if that is not implemented, a fragment edit silently reuses the old kernel. B01 must put `profile-hash` and the digest into its key. If B01 chooses not to, R03's busybox and `bashrc` coverage is nominal. Recorded as a B01 acceptance requirement.
- A new human-judgement item: SPEC §10 has no OD for "revbump-exempt" cases; none is proposed.

## Cost
Two slices: (1) `gentoo_version`, `classify`, `check` core with fixtures (AC-1–5, 8, 9, 11, 12); (2) digest, profile-hash, workflow (AC-6, 7, 10). No CI build cycles; the workflow runs in seconds. No storage or hosting cost.

## Spec defects found
- No node owns the trusted-base wiring for PR checks in general: F04 owns identity and RED/GREEN discipline, F01 the fast lane. R03 writes its own `pr-recipes.yml`; F04 should offer a shared reusable action so each gate does not hand-roll the base checkout.
- SPEC §3 says D-revbump-on-overlay-change covers "an ebuild or its files"; the predecessor's doctrine also named savedconfig and the kernel config. R03 extends the gate to those via the digest and fragment rules; SPEC wording could be updated.
