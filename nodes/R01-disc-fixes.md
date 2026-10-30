# R01 — disc-fixes

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | F01 | B01, B03 | — | S |

**Owns:** `configs/overlay/app-misc/monolith-base/` (r6 becomes r7), its tests, its paths in the fast lane's `bash -n` and shellcheck lists, `scripts/tests/advisory-check.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** the whole `configs/overlay/app-misc/monolith-base/` package (`monolith-base-0.1.0-r6.ebuild` and its 25 `files/`: the `monolith` help system and its topics, `monolith-net`, `monolith-router`, `monolith-persist`, `monolith-time`, `monolith-time-check`, `monolith-advisory-check`, `monolith-console`, the `profile.d` scripts, `which`, `startx`, `guestbook.cgi`) with its tests: `scripts/tests/monolith.test.sh`, `monolith-net.test.sh`, `monolith-router.test.sh`, `monolith-persist.test.sh`, `monolith-persist-bashrc.test.sh`, `monolith-persist-profile.test.sh`, `monolith-time.test.sh`, `monolith-time-check.test.sh`, `monolith-cnf.test.sh`. The overlay's `metadata/layout.conf` and `profiles/repo_name` come with it, so the package sits in a valid repository.
**Study refs:** D-revbump-on-overlay-change, D-supply-chain-honesty; OD-1.

## Purpose
`monolith-base` is the disc's own userland: help, networking, the NAT router, persistence, clock honesty and the advisory check. It arrives first among the recipes, because its tests need no build. The first attested ISO from this repository must not carry the dead S3 URL or read silence as safety. The service behind the OD-1 name can come later.

## Standard mechanism
None. Plain POSIX sh; the overlay revbump is the standard Gentoo rule.

The ported tests come first: they pass against the ported files as they are, and the new advisory test fails until changes 1–3.

## Changes from the port
0. **Fast lane.** The `files/` scripts the predecessor linted (`pr-validate.yml:27,59`: `monolith-net`, `monolith-router`, `monolith`, `monolith-time`, `monolith-time-check`, `monolith-persist`) join F01's `bash -n` and shellcheck lists. *AC-6.*
1. **Base URL.** `monolith-advisory-check:17` defaults to `https://themonolith.s3.amazonaws.com`. Replace it with the OD-1 URL (default `https://monolith.technomantics.com`), one variable in this one file. The os-release `HOME_URL` (`build-rootfs.sh:266`) takes the same value when B03 ports that script. (`scripts/nightly-cve-monitor.py:143` names `themonolith.org`; that is P03's.) *AC-1.*
2. **Unknown, never clean.** The script exits silently on every failure (`:46-48`) and writes nothing unless the body contains `"revoked"` (`:51`), so a 404 page, an empty body or no network all look like "no advisory". It writes one word to `/run/monolith-advisory-state`: `revoked`, `clean` (body is a status file with `"status"` equal to `clean`), or `unknown` (anything else). The banner appears only for `revoked`, as before. No console text says "clean". *AC-2, AC-3.*
3. **Sanitise.** `40-advisory.sh` prints `details_url` with only `tr -d '"'`. Pass it through `tr -cd 'A-Za-z0-9:/#._?=&%~+-'`. CVE ids are already regex-filtered. *AC-4.*
4. **Revbump** `monolith-base` to `-r7`. B01 ports `versions.lock` with the r7 line. *AC-5.*

## Gate
- **R01-AC-1** — The advisory script contains no `amazonaws`, and its default base URL is the OD-1 URL. *Verify:* `scripts/tests/advisory-check.test.sh`. *Tier:* fast.
- **R01-AC-2** — With stub `curl`, a 404, an empty body, HTML and a failed fetch each write `unknown`; a valid clean file writes `clean`; a revoked file writes `revoked` and `/run/monolith-advisory`. *Verify:* `scripts/tests/advisory-check.test.sh`. *Tier:* fast.
- **R01-AC-3** — The script prints nothing in any state and exits 0. *Verify:* same test. *Tier:* fast.
- **R01-AC-4** — A status fixture with ESC bytes in `details_url` yields no control byte from `40-advisory.sh`. *Verify:* `scripts/tests/advisory-check.test.sh`. *Tier:* fast.
- **R01-AC-5** — `monolith-base` has exactly one ebuild, `-r7`. *Verify:* `scripts/tests/advisory-check.test.sh`. *Tier:* fast.
- **R01-AC-6** — The nine ported `monolith*` tests pass, and `make test` runs `bash -n` and shellcheck on the six `files/` scripts of change 0. *Verify:* `toolbox/run --network none -- make test`. *Tier:* fast.

## Risks
- OD-1 must be settled before merge; the name is permanent once an attested ISO carries it.
- TLS and CA trust from the i486 userland against the real host are unverified; P03's service is the first real test.
