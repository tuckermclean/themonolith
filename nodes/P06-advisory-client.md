# P06 — advisory-client

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| P | R01, I05 | B04, P05 | — (feeds MS1) | S |

**Owns:** edits to `recipes/overlay/app-misc/monolith-base/files/monolith-advisory-check` and `.../40-advisory.sh` (after R01 imports them), the `monolith-base` revision bump and its `pins/versions.lock` line, `tests/fast/advisory-check-script.test.sh`, `tests/fast/advisory-banner-sanitize.test.sh`, `tests/fast/public-url-single-source.test.sh`, `tests/fast/advisory-revbump.test.sh`, `tests/fast/advisory-not-live.test.sh`.
**Carries from linux-live-iso-factory@b9f533b:** `configs/overlay/app-misc/monolith-base/files/monolith-advisory-check` and `40-advisory.sh` (ported; the changes below are each forced by an AC).
**Study refs:** supplychain `script.nightly-cve-monitor` (status-file shape read by the disc); build/recipes notes on `monolith-advisory-check:17,29` (default `ADVISORY_BASE_URL` is the dead S3 bucket); D-revbump-on-overlay-change; D-supply-chain-honesty; SPEC §10 OD-1. Split out of P05 in v0.3 (P05 spec defect 0).

## Purpose
The disc side of the advisory feed, split out of P05 because it must be in the first attested ISO. After
P06 the disc asks the OD-1 name, never S3, for `status/<tag>.json`; it never implies "no advisories" when
the service cannot be reached; and a hostile status file cannot inject terminal escapes. The service that
writes the status files (P05) and the host (P01) can come later without another disc change.

## Scope
In:
- The default base URL and `HOME_URL` equal to the `PUBLIC_BASE_URL` pin (the OD-1 name).
- The not-live behaviour and the one-word state file.
- Output sanitising in `40-advisory.sh`.
- The `monolith-base` revision bump and lock line.

Out:
- The status-file writer, nightly scan, workflows and the status-file contract document: P05. P06 keeps
  the predecessor's file shape, and P05 must stay compatible with it.
- The host and DNS: P01. The pin itself: I05 (`PUBLIC_BASE_URL`).
- An end-to-end fetch from a booted disc against the live host: P05 (`advisory-e2e.yml`, non-gating).

## Design
- `monolith-advisory-check` keeps its logic (POSIX sh, 5 s timeout, silent on every failure, curl then wget). Its default `ADVISORY_BASE_URL` becomes the literal `PUBLIC_BASE_URL` pin value, which is the OD-1 name (P01 records it). The constant is correct before the service is live; the pin and this constant land before MS2. A test asserts equality with the pin; build-time templating was rejected (more moving parts for a one-line constant). `HOME_URL` in os-release (old `scripts/build-rootfs.sh:266`, B04's) is covered by the same test.
- **When the service is not live** (DNS fails, the host answers `404`, TLS fails, the request times out), the disc must not suggest the build is clean. The shipped script is already silent on failure (`monolith-advisory-check:46-48`), and silence reads as "no advisories". P06 keeps the console silent about advisories and adds a one-word state file `/run/monolith-advisory-state`: `revoked`, `clean` (a status file was fetched and says clean) or `unreachable` (anything else). No text on the console says "no advisories", "clean" or "up to date" in any state except a fetched `clean`, and none is added here. `docs/advisory.md` states that no banner means unknown, not safe. Rejected: printing "advisory service unavailable" at every boot (noise for offline machines, which are the normal case on an i486).
- `40-advisory.sh` prints the CVE ids (already regex-filtered) and `details_url`. The URL is filtered through `tr -cd 'A-Za-z0-9:/#._?=&%~+-'` before printing, so a hostile or corrupted status file cannot inject terminal escape sequences. rc1 does not have this filter.
- Both files change, so `monolith-base` gets a revision bump and a `pins/versions.lock` line (D-revbump-on-overlay-change; AC-4).

## Traps and doctrines preserved
- **Dead vendor URL in the ISO** (`monolith-advisory-check` defaults to the S3 bucket): AC-3.
- **Silence read as "clean"** when the service is unreachable: AC-5.
- **Shipped reader compatibility** with the predecessor's status-file shape: AC-1, AC-2.
- **D-revbump-on-overlay-change:** AC-4. (I06's fingerprint would catch the edit anyway; the bump keeps
  `versions.lock` honest.)

## Gate
- **P06-AC-1** — The real `monolith-advisory-check`, run with a stub `curl` (and separately a stub `wget`), under `dash` and busybox `ash` when present: requests exactly `${BASE}/status/${TAG}.json`; writes the runtime file only for `revoked`; exits 0 silently on fetch failure, missing `/etc/monolith-release`, empty tag and missing `mktemp`. `shellcheck -s sh` passes. *Verify:* `tests/fast/advisory-check-script.test.sh` (paths rewritten into a temp copy). *Tier:* fast.
- **P06-AC-2** — A status fixture whose `details_url` and `advisories` contain ESC (0x1b) and other control bytes produces no control byte in the output of `40-advisory.sh`. *Verify:* `tests/fast/advisory-banner-sanitize.test.sh`. *Tier:* fast.
- **P06-AC-3** — The default `ADVISORY_BASE_URL` in `monolith-advisory-check` and the `HOME_URL` baked into os-release equal `PUBLIC_BASE_URL` from `pins/pins.yaml` (the OD-1 name), whether or not the service is live; no file under `recipes/` or `factory/` contains `amazonaws`. *Verify:* `tests/fast/public-url-single-source.test.sh`. *Tier:* fast.
- **P06-AC-4** — The `monolith-base` ebuild revision is bumped and `pins/versions.lock` has the matching line (D-revbump-on-overlay-change; R03 enforces this generally once it lands). *Verify:* `tests/fast/advisory-revbump.test.sh` (compares the ebuild `-rN` with the lock line). *Tier:* fast.
- **P06-AC-5** — With the service not live (stub `curl`/`wget` failing for DNS, TLS and timeout, and returning `404`), the real `monolith-advisory-check` creates no `/run/monolith-advisory`, writes `unreachable` to `/run/monolith-advisory-state`, exits 0, and prints nothing; a fetched `clean` status file writes `clean`; a `revoked` one writes `revoked` and the banner path as before. In no state do stdout, stderr or the login output contain "no advisories", "up to date" or "clean" (except the state file). `docs/advisory.md` says that no banner means unknown. *Verify:* `tests/fast/advisory-not-live.test.sh`. *Tier:* fast.

## RED plan
The tester writes the five fast tests first, running the real scripts (copied to a temp dir with paths
rewritten) against stub `curl` and `wget` and status fixtures under `tests/fixtures/advisory/`. They fail
because the imported scripts still default to the S3 URL, print the URL unfiltered, and write no state
file.

## Risks and open questions
- OD-1 must be settled before this node merges: the name is permanent once an attested ISO carries it.
- TLS from the i486 userland against the real host is unproven; P05's non-gating e2e test is the first
  real check. A failure there needs a recipe fix (CA bundle) and a new ISO, not a P06 change.

## Cost
One slice, five fast ACs, under a day. No CI build cycle of its own; the change rides in the next B06
build and costs one `monolith-base` rebuild (the package's fingerprint changes; nothing links it).
