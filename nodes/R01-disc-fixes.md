# R01 — disc-fixes

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | F01 | B03 | — | S |

**Owns:** `configs/overlay/app-misc/monolith-base/` (r6 becomes r7), `scripts/build-rootfs.sh` os-release block, `scripts/tests/advisory-check.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `configs/overlay/app-misc/monolith-base/files/monolith-advisory-check`, `files/40-advisory.sh`, `monolith-base-0.1.0-r6.ebuild`.
**Study refs:** D-revbump-on-overlay-change, D-supply-chain-honesty; OD-1.

## Purpose
The first attested ISO from this repository must not carry the dead S3 URL or read silence as safety. The service behind the OD-1 name can come later.

## Standard mechanism
None. Plain POSIX sh; the overlay revbump is the standard Gentoo rule.

## Changes from the port
1. **Base URL.** `monolith-advisory-check:17` defaults to `https://themonolith.s3.amazonaws.com`. Replace it with the OD-1 URL (default `https://monolith.technomantics.com`), one variable in this one file. `build-rootfs.sh:266` sets os-release `HOME_URL` to `themonolith.s3.us-west-2.amazonaws.com`; set it to the same value. A test asserts the two match. (`scripts/nightly-cve-monitor.py:143` names `themonolith.org`; that is P03's.) *AC-1.*
2. **Unknown, never clean.** The script exits silently on every failure (`:46-48`) and writes nothing unless the body contains `"revoked"` (`:51`), so a 404 page, an empty body or no network all look like "no advisory". It writes one word to `/run/monolith-advisory-state`: `revoked`, `clean` (body is a status file with `"status"` equal to `clean`), or `unknown` (anything else). The banner appears only for `revoked`, as before. No console text says "clean". *AC-2, AC-3.*
3. **Sanitise.** `40-advisory.sh` prints `details_url` with only `tr -d '"'`. Pass it through `tr -cd 'A-Za-z0-9:/#._?=&%~+-'`. CVE ids are already regex-filtered. *AC-4.*
4. **Revbump** `monolith-base` to `-r7` with its `versions.lock` line and Manifest. *AC-5.*

## Gate
- **R01-AC-1** — The advisory script and `build-rootfs.sh` contain no `amazonaws`, and the script default and `HOME_URL` are the same URL. *Verify:* `scripts/tests/advisory-check.test.sh`. *Tier:* fast.
- **R01-AC-2** — With stub `curl`, a 404, an empty body, HTML and a failed fetch each write `unknown`; a valid clean file writes `clean`; a revoked file writes `revoked` and `/run/monolith-advisory`. *Verify:* `scripts/tests/advisory-check.test.sh`. *Tier:* fast.
- **R01-AC-3** — The script prints nothing in any state and exits 0. *Verify:* same test. *Tier:* fast.
- **R01-AC-4** — A status fixture with ESC bytes in `details_url` yields no control byte from `40-advisory.sh`. *Verify:* `scripts/tests/advisory-check.test.sh`. *Tier:* fast.
- **R01-AC-5** — `monolith-base` is r7 and `versions.lock` matches. *Verify:* the same test compares ebuild name and lock. *Tier:* fast.

## Risks
- OD-1 must be settled before merge; the name is permanent once an attested ISO carries it.
- TLS and CA trust from the i486 userland against the real host are unverified; P03's service is the first real test.
