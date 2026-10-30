# R04 — revbump-check

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | F01 | B01, R02 | — | S |

**Owns:** `scripts/check-revbump.sh`, `scripts/tests/check-revbump.test.sh`, its step in `.github/workflows/pr-validate.yml`.
**Ports from linux-live-iso-factory@b9f533b:** nothing (the predecessor had no overlay check).
**Study refs:** T-binpkg-revbump (the same perl panic three times); D-revbump-on-overlay-change; SPEC §4.3, §5 "Binary cache".

## Purpose
The development cache reuses an overlay package's binary unless its version or revision changes (SPEC §5). After this node, a PR that edits an overlay ebuild or its `files/` without a new revision fails the fast lane, so B01's cache cannot silently keep the old binary. Full `pkgcheck` integration is R02, later.

## Standard mechanism
The Gentoo rule itself: a change to what an ebuild installs needs a revision bump. Portage does not enforce it; repositories enforce it in review or with `pkgcheck`. `pkgcheck` needs the pinned tree and its git checks are unverified for an overlay in a subdirectory (R02). Custom code: one short shell script over `git diff --name-status`. Gap: nothing in the fast lane enforces the rule today.

## Tests
- **Ported first:** none; the predecessor had no overlay check.
- **Added:** `scripts/tests/check-revbump.test.sh`.
- **Baseline:** not applicable; the check is new.

## Changes from the port
1. **The check.** `check-revbump.sh <base> <head>` lists the paths changed under `configs/overlay/<cat>/<pn>/`, grouped by package.
   - A package passes when the change adds at least one `*.ebuild` file that the base lacks: a new `-rN` or a new version.
   - It also passes when the only changed files are `metadata.xml`, or are `Manifest` changes made together with a new ebuild.
   - Anything else fails and names the package. This covers an edited ebuild, a change under `files/`, and a removed patch.
   - Comment-only ebuild edits are not exempt.

   *AC-1, AC-2, AC-3.*
2. **Where it runs.** A step in `pr-validate.yml` with `fetch-depth: 0`, comparing the PR base with its head. The script's own copy is taken from the base revision (`git show <base>:scripts/check-revbump.sh`), so a PR cannot weaken the check it is judged by. *AC-4.*
3. **Eclasses.** The overlay has no eclasses at `b9f533b`. If one is added, a change to it fails the check unless every overlay package that inherits it is revbumped in the same PR. *AC-3.*

## Gate
- **R04-AC-1** — A change to an ebuild, or to a file under `files/`, with no added ebuild fails and names `<cat>/<pn>`. *Verify:* `scripts/tests/check-revbump.test.sh` (temporary git repository with fixture commits). *Tier:* fast.
- **R04-AC-2** — The same changes with an added `-rN` ebuild pass, and a `metadata.xml`-only change passes. *Verify:* same test. *Tier:* fast.
- **R04-AC-3** — An eclass change passes only when every package that inherits it gains a new ebuild. *Verify:* same test. *Tier:* fast.
- **R04-AC-4** — `pr-validate.yml` runs the base revision's `check-revbump.sh` against the PR diff, and a PR that edits only `check-revbump.sh` to always exit 0 is still judged by the old copy. *Verify:* `scripts/tests/check-revbump.test.sh` (greps the workflow step); a throwaway PR recorded in this node's PR. *Tier:* fast + slow.

## Risks
- Renames and `git mv` of an ebuild without a new revision must be read as "no new ebuild". `--name-status` shows `R` entries, and the test covers one.
- If `pkgcheck --commits` later covers the same case (R02), this script is deleted, not kept beside it.
