# R02 — overlay-qa

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | I02 | none | — | M |

**Owns:** `configs/overlay/games-roguelike/rl144/`, `configs/overlay/www-client/stele/` (crate lists), a `pkgcheck` step in `.github/workflows/pr-validate.yml`, `scripts/check-revbump.sh` (only if needed), `scripts/tests/check-revbump.test.sh`, an accepted-warnings list in `docs/overlay-qa.md`.
**Ports from linux-live-iso-factory@b9f533b:** none (the predecessor had no overlay check).
**Study refs:** T-binpkg-revbump (the same perl panic three times, v0.3 R03); D-revbump-on-overlay-change; SPEC §4.3.

## Purpose
The overlay passes `pkgcheck scan` against the pinned tree, and a changed ebuild or `files/` without a new `-rN` fails the PR.

## Standard mechanism
`pkgcheck scan` with `--repo configs/overlay` and the pinned tree as master (I02). pkgcheck is not installed here, so its coverage of "ebuild changed without revbump" is unverified. From memory its git checks (`--commits`) include a missing-revision result, which needs the repository root to be the overlay root; ours is a subdirectory (unverified). The first slice runs `pkgcheck scan --commits` on a throwaway commit that edits `files/` only.

## Changes from the port
1. **Scan.** Add `pkgcheck scan` of `configs/overlay` to the fast lane. Accepted warnings are listed in `docs/overlay-qa.md`. *AC-1.*
2. **Revbump.** If pkgcheck flags it, use that. If not, add the smallest git-diff check: for each overlay package directory with changes between the PR base and head, fail unless a new `*-rN.ebuild` file exists that the base lacks. No version-comparison library (v0.3's PMS comparison is dropped). Comment-only ebuild edits are not exempted; bump anyway. *AC-2, AC-3.*
3. **Crates as distfiles.** `rl144` and `stele` build with `RESTRICT=network-sandbox` and fetch crates at build time (`rl144-0.1.0_p20260805.ebuild:31`, `stele-0.1.0_p20260821.ebuild:34`), so P01's `DISTDIR` archive misses them and P02 cannot rebuild offline. The standard Gentoo form is `cargo.eclass` with a `CRATES` list generated from `Cargo.lock` (`pycargoebuild` or `cargo ebuild`). Both ebuilds move to it, with revbumps, and the restriction goes. P02's known input gap then closes. *AC-4.*

## Gate
- **R02-AC-1** — `pkgcheck scan` of the overlay exits 0 apart from the listed warnings. *Verify:* the pr-validate job. *Tier:* fast.
- **R02-AC-2** — A change under `files/` or to an ebuild with no new revision fails. *Verify:* `scripts/tests/check-revbump.test.sh` on a temp git repo, or the pkgcheck run if it covers this. *Tier:* fast.
- **R02-AC-3** — The same change with a new `-rN` ebuild passes. *Verify:* same test. *Tier:* fast.
- **R02-AC-4** — No overlay ebuild sets `RESTRICT` containing `network-sandbox`, and a build of `rl144` and `stele` with `FETCHCOMMAND=/bin/false` and a pre-filled `DISTDIR` succeeds. *Verify:* `grep -rn network-sandbox configs/overlay` in the fast lane; a CI emerge of the two packages. *Tier:* fast + slow.

## Risks
- pkgcheck git-check behaviour in a subdirectory repository is unverified.
- A pinned-tree checkout adds time to the fast lane; use the I02 archive.
- Whether both crates' `Cargo.lock` resolve with the tools above, and how long the `CRATES` lists get, is unverified. Stele may vendor git dependencies, which `CRATES` handles through `GIT_CRATES`.
