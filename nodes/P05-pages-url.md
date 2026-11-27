# P05 — pages-url

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | R01, P03, P04, B01, B03 | B05 | — | S |

**Owns:** the default base URL in `configs/overlay/app-misc/monolith-base/files/monolith-advisory-check` and the package's revbump to `monolith-base-0.1.0-r8.ebuild` (R01 owns the rest of the package), the `HOME_URL` line of `scripts/build-rootfs.sh`, `DEFAULT_BASE_URL` in `scripts/nightly-cve-monitor.py`, `ADVISORY_BASE_URL` in `Makefile`, the `app-misc/monolith-base` line of `configs/portage/versions.lock`, the changed lines of `scripts/tests/advisory-check.test.sh` and `scripts/tests/advisory-feed.test.sh` (change 6), the OD-1 line of `docs/first-release.md`, the `P05` entries in `docs/migration.tsv` and the `monolith-base` row of `docs/capabilities.md`, the `monolith-base` lines of `docs/rc1-diff-reasons.tsv`, `scripts/tests/pages-url.test.sh`.
**Resolves:** #108
**Ports from linux-live-iso-factory@b9f533b:** none. R01, P03 and B03 ported the files; this node changes one value in each.
**Study refs:** OD-1; R01 change 1, P03 change 5, B03 change 8; D-revbump-on-overlay-change; advisory-feed runs 44085365372 and earlier (each fails in `Scan the releases`).

## Purpose
The OD-1 URL is `https://monolith.technomantics.com` in every place it is set, and that name does not resolve. `scripts/advisory-feed.sh:55-56` fetches the tag index from it first and exits 1 when it is unreachable, so every nightly advisory-feed run since P03 has failed before it scanned anything, and nothing has been published.

After this node the OD-1 URL is `https://tuckermclean.github.io/themonolith`, the GitHub Pages site the feed's deploy job already publishes to. The disc's advisory check reads it, and so does its os-release `HOME_URL`. The feed run fetches its prior state from it, and the monitor writes it into `details_url`. The nightly sweep runs to the end and publishes, and the status files and the dashboard answer at that URL. No release has been published from this repository yet, so no attested disc carries the old name.

## Standard mechanism
GitHub Pages, as P03 and P04 already use it, with no custom domain. A project site lives under `/themonolith/`. The feed and the disc build every URL from the base (`<base>/status/<tag>.json`), and the dashboard's links are relative (`scripts/dashboard.py:140,200,208,215`), so the subpath needs no code. The URL can be moved later without breaking discs that carry it: when a custom domain is set on the Pages site, GitHub redirects the `github.io` URL to it, and the disc follows redirects (`curl -fsSL`, and wget does by default). No custom code.

## Tests
- **Ported first:** none.
- **Frozen tests changed** (owner approval: the merge of this spec, issue #108): R01's `scripts/tests/advisory-check.test.sh` and P03's `scripts/tests/advisory-feed.test.sh` assert the old URL and the old revision. Only the lines change 6 lists change, each to the new value. No case is removed or weakened.
- **Kept unchanged:** B03's `scripts/tests/build-workflow.test.sh` (B03-AC-8 compares `HOME_URL` with the advisory check's default, whatever it is), `scripts/tests/versions-lock-complete.test.sh`, `scripts/tests/check-revbump.test.sh`, and the dashboard tests.
- **Added:** `scripts/tests/pages-url.test.sh` for AC-3 and AC-4, offline in the toolbox.
- **Baseline:** on `main`, the changed cases of change 6 and `pages-url.test.sh` fail on the old URL and on `r7`.

## Changes from the port
1. **The disc.** `monolith-advisory-check:24` defaults `ADVISORY_BASE_URL` to `https://tuckermclean.github.io/themonolith`. Nothing else in the script changes. `monolith-base` is revbumped: `monolith-base-0.1.0-r7.ebuild` becomes `-r8.ebuild` with the same content (R04's rule for a `files/` change), and `configs/portage/versions.lock:9` becomes `app-misc/monolith-base:0.1.0-r8:0`. *AC-1, AC-2.*
2. **os-release.** `scripts/build-rootfs.sh:272` sets `HOME_URL="https://tuckermclean.github.io/themonolith"`, the same value as change 1 (B03 change 8). *AC-3.*
3. **The feed.** `Makefile:621` sets `ADVISORY_BASE_URL ?= https://tuckermclean.github.io/themonolith`, and `scripts/nightly-cve-monitor.py:38` sets `DEFAULT_BASE_URL` to the same value, so `details_url` is `https://tuckermclean.github.io/themonolith/<tag>`, the tag's dashboard page. `advisory-feed.sh` and `advisory-feed.yml` do not change. *AC-3, AC-5, AC-6.*
4. **Docs.** `docs/first-release.md:118` names the new URL as OD-1's value. In `docs/migration.tsv`, the `then` column of the rows for `monolith-advisory-check` (line 46), `build-rootfs.sh` (line 149) and `nightly-cve-monitor.py` (line 159) gains `P05`, and the `monolith-base-0.1.0-r6.ebuild` row (line 63) gains `P05:configs/overlay/app-misc/monolith-base/monolith-base-0.1.0-r8.ebuild`. `docs/capabilities.md` names `r8` for the ebuild. `scripts/check-migration.py --node P05` and `--all` pass. *AC-4.*
5. **No old name.** After changes 1–4, `monolith.technomantics.com` remains only in history: `nodes/` (merged specs), `docs/study/`, `docs/reviews/` and `docs/evidence/`. *AC-4.*
6. **Frozen test lines.** In `advisory-check.test.sh`, the URL in the header comment (`:12-13`) and in the three AC-1 lines that check the default (`:78`, `:84-86`) becomes `https://tuckermclean.github.io/themonolith`. The AC-5 case (`:128-129`) checks for `monolith-base-0.1.0-r8.ebuild`. In `advisory-feed.test.sh`, the URL in the header comment (`:11`) and in the default `details_url` case (`:207-209`) becomes the new URL. *AC-1, AC-2, AC-5.*

## Gate
- **P05-AC-1** — `monolith-advisory-check` contains no `technomantics`, its default base URL is `https://tuckermclean.github.io/themonolith`, and, with `ADVISORY_BASE_URL` unset and a stub `curl`, it fetches `https://tuckermclean.github.io/themonolith/status/<tag>.json`. R01-AC-2 to R01-AC-4 still pass. *Verify:* `scripts/tests/advisory-check.test.sh`.
- **P05-AC-2** — `monolith-base` has exactly one ebuild, `monolith-base-0.1.0-r8.ebuild`; `versions.lock` locks `app-misc/monolith-base:0.1.0-r8:0`; `make test-revbump` passes on the node's branch against `main`. *Verify:* `scripts/tests/advisory-check.test.sh`, `scripts/tests/versions-lock-complete.test.sh`, `make test-revbump`.
- **P05-AC-3** — `build-rootfs.sh`'s `HOME_URL`, the Makefile's `ADVISORY_BASE_URL` and `nightly-cve-monitor.py`'s `DEFAULT_BASE_URL` each equal `monolith-advisory-check`'s default base URL, and that URL is `https://tuckermclean.github.io/themonolith`. *Verify:* `scripts/tests/pages-url.test.sh`; `scripts/tests/build-workflow.test.sh` (B03-AC-8, unchanged).
- **P05-AC-4** — No file of the tree outside `nodes/`, `docs/study/`, `docs/reviews/` and `docs/evidence/` contains `technomantics`, with a planted file outside them failing the check; `scripts/check-migration.py --node P05` and `--all` pass. *Verify:* `scripts/tests/pages-url.test.sh`; `make test-lint`.
- **P05-AC-5** — Without `--base-url`, a revoked status file's `details_url` starts with `https://tuckermclean.github.io/themonolith/` and names the tag. *Verify:* `scripts/tests/advisory-feed.test.sh`.
- **P05-AC-6** — A dispatched `advisory-feed.yml` run on `main` after the merge fetches from the new URL: its log shows `==> tag index from https://tuckermclean.github.io/themonolith` and no `unreachable` or `answered HTTP` line, and its scan and deploy jobs succeed. Then, from outside the runner, `curl -fsS https://tuckermclean.github.io/themonolith/status/index.txt` lists `v0.1.0-rc1`, `curl -fsS https://tuckermclean.github.io/themonolith/status/v0.1.0-rc1.json | python3 -m json.tool` succeeds, and `curl -fsS https://tuckermclean.github.io/themonolith/` lists `v0.1.0-rc1`. If the run fetches from the new URL but fails at a later step for a cause the URL does not explain, the record is that run, its failing step and log line, and an issue for that cause; the curl checks then wait for that issue's fix. *Verify:* the recorded run and the curl output, in the node PR.

## Risks
- **Pages setup is the owner's.** The deploy job needs the repository's Pages source set to GitHub Actions, with no custom domain. `https://api.github.com/repos/tuckermclean/themonolith/pages` answered 404 on 2026-11-17, so Pages may not be enabled yet. A custom domain set on the site now would make the `github.io` URL redirect, and `advisory-feed.sh` fetches without `-L`, so its index fetch would answer HTTP 301 and fail.
- **Moving the URL later.** OD-1 asks for a name that can be repointed for decades. This URL can be moved only through a custom domain on this repository's Pages site, which GitHub then redirects to. Renaming the repository, moving it to another account or disabling Pages breaks every disc that carries the URL. A disc treats silence as `unknown`, never `clean` (R01).
- **Redirects.** That `github.io` redirects to a custom domain, keeping the path, is GitHub's documented behaviour but unverified here. The disc's `curl -L` and wget follow it; an HTTPS redirect from the i486 userland is unverified, like the TLS chain itself (P03 Risks).
- **Other causes.** Only the `Scan the releases` step is known to fail. Its log was not read here; the name not resolving (checked on 2026-11-17) and `advisory-feed.sh:55-56` explain it. A second cause behind it is what AC-6's way out is for.
