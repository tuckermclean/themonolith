# R02 — overlay-qa

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | I02, R04 | P01 | — | S |

**Owns:** the `test-overlay` Make target, part of `make test`, and its call in `.github/workflows/pr-validate.yml`, `docs/overlay-qa.md` (accepted warnings).
**Ports from linux-live-iso-factory@b9f533b:** none (the predecessor had no overlay check).
**Study refs:** T-binpkg-revbump; D-revbump-on-overlay-change; SPEC §4.3.

## Purpose
The overlay passes `pkgcheck scan` against the pinned tree, as any Gentoo repository should. The minimal revbump rule that the cache depends on is already enforced by R04 on the critical path; this node adds the full QA scan, which passes before the first release (P01 depends on it).

## Standard mechanism
`pkgcheck scan` with `--repo configs/overlay` and the pinned tree (I02) as master. Custom code: none. If `pkgcheck scan --commits` reports a missing revision for an overlay in a repository subdirectory (unverified), it replaces R04's script.

## Tests
- **Ported first:** none; the predecessor had no overlay check.
- **Added:** the tests the Gate names.
- **Baseline:** `pkgcheck` over `b9f533b`'s overlay records the warnings that `docs/overlay-qa.md` accepts.

## Changes from the port
1. **Scan.** Add `make test-overlay` to `make test`: `pkgcheck scan` of `configs/overlay` in the builder image, with the pinned tree restored from I02's archive (the target's prerequisite). `pr-validate.yml` runs it as a second step, `make test-overlay`, because it needs the network that `test-lint` and `test-unit` run without. Accepted warnings are listed in `docs/overlay-qa.md`, each with a reason. *AC-1.*
2. **Replace R04 if pkgcheck covers it.** Run `pkgcheck scan --commits` on R04's fixture cases. If it fails all the cases R04 fails, delete `check-revbump.sh` and fold `test-revbump` into `test-overlay`; if not, keep R04 and record why in `docs/overlay-qa.md`. *AC-2.*

## Gate
- **R02-AC-1** — `pkgcheck scan` of the overlay exits 0 apart from the warnings listed in `docs/overlay-qa.md`, and a new warning fails the job. *Verify:* `make test-overlay` locally and the pr-validate job; a throwaway PR adding a known warning.
- **R02-AC-2** — Either `check-revbump.sh` is gone and `pkgcheck --commits` fails every R04 fixture case, or `docs/overlay-qa.md` records which case pkgcheck misses. *Verify:* `scripts/tests/check-revbump.test.sh` run against pkgcheck; review of the doc.

## Risks
- pkgcheck git-check behaviour in a subdirectory repository is unverified.
- The tree pull adds time to every PR; it uses the I02 archive by digest.
- Whether `pkgcheck` is installed in the rc1 builder image is unverified; the first slice checks it.
