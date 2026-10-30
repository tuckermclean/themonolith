# P03 — advisory-feed

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | P01, S01 | X01 | — | M |

**Owns:** `scripts/nightly-cve-monitor.py` (modified), `.github/workflows/advisory-feed.yml` (replaces `nightly-cve-scan.yml`), `scripts/tests/advisory-feed.test.sh`, `scripts/tests/advisory-feed-workflow.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `scripts/nightly-cve-monitor.py` (359 lines), `.github/workflows/nightly-cve-scan.yml`. The disc side (`monolith-advisory-check` and its URL) is R01's and is read here, not changed. Not ported: `generate-dashboard.py`.
**Study refs:** supplychain.yaml `script.nightly-cve-monitor`; contradictions: the monitor revokes on any grype match of any severity and ignores `cve-policy.yaml`; a revoked build becomes `fail` the next night; the DB update failure is ignored; `details_url` names `themonolith.org`, a third party's domain (OD-1); T-cve-gate-unfalsifiable, T-canary-silence; OD-1.

## Purpose
After this node a released ISO that acquires a serious CVE says so at boot. The disc fetches `<OD-1 URL>/status/<BUILD_TAG>.json` (`monolith-advisory-check:17,29`), and a nightly job keeps that file current. The file is static JSON. A scan that could not run never produces a "clean" file.

## Standard mechanism
grype with its DB re-scans each release's published SBOM; the CVE policy is S01's `check-cves.sh` and `cve-policy.yaml`; the release SBOMs come from GitHub Releases (`gh release download`); the schedule is GitHub Actions `schedule:`. The monitor already exists. The only new piece is where the files are hosted.

**Hosting (OD-1).** This is the only node that needs a host outside GitHub. The advisory URL is a dedicated name baked into every disc (default `https://monolith.technomantics.com/`), so it must be a static host the owner can repoint. The OD-1 default is GitHub Pages with that custom domain: it keeps everything on GitHub and needs no stored key (SPEC §8). The publish step (`actions/upload-pages-artifact` and `actions/deploy-pages`, permissions `pages: write`, `id-token: write`) is the one host-specific step; the monitor does not know the host. Another static host would change only that step.

## Changes from the port
1. **S3 and dashboard removed** (left out as P03 ports the script; I01's check holds the rule). Delete `s3_sync`, `s3_cp`, `--s3-bucket` and the dashboard step (`nightly-cve-monitor.py:186-196,231-242,310-330`). The workflow populates `data/<tag>/bom.cdx.json` with `gh release download` for each release of this repository, and for rc1 from the predecessor release with a pinned sha256. It fetches existing `status/*.json` from the host with `curl`. The monitor keeps its `--data-dir` layout (`find_sboms`, `:54-78`). Proved by AC-5.
2. **The CVE policy decides.** Today any grype match of any severity revokes (`run_grype`, `extract_cve_ids`, `:81-118,:274-281`). Each SBOM is scanned with `check-cves.sh --policy configs/attestation/cve-policy.yaml`; the status comes from its coverage report: `verdict` and the `findings` where `gating` is true. Medium, Low and waived findings never revoke, and an expired waiver (S01 change 4) does. Proved by AC-3.
3. **No flip-flop.** The only statuses are `revoked` and `clean`. `revoked` is set at once. A revoked build returns to `clean` only after two consecutive passing scans (`"clearing": 1` after the first), so one bad DB day does not tell users a revoked ISO is fine. The `revoked` to `fail` rewrite of `attestation-summary.json` (`update_attestation_summary`, `:153-185`, `:291`) is deleted: attested files are never rewritten. Proved by AC-1.
4. **Unreachable is never clean.**
   - `update_grype_db()` ignores a failed `grype db update` and scans with the old DB (`:246`). Failure now exits 3 before any scan or write.
   - The canary runs first: S01's ported `run-cve-canary.sh` must report CVE-2014-0160. If not, exit 4 and write nothing.
   - A scan error for one SBOM, or a missing or old coverage report, leaves that build's file unchanged and makes the run exit non-zero. The old code exits 0 when anything else scanned (`:346-355`).
   Proved by AC-4.
5. **Status file shape.** `details_url` becomes `<OD-1 URL>/` plus the tag instead of `themonolith.org` (`:143`). Added keys: `checked`, `policy_sha256`, `grype_db_built` (S01 change 5). The disc greps `'"status"[^"]*"revoked"'` (`monolith-advisory-check:52`), so no other key may contain the whole tokens `"status"` or `"revoked"`. Proved by AC-2.
6. **Workflow.** `advisory-feed.yml` keeps the 04:00 UTC cron and `workflow_dispatch`, and drops the AWS credentials step. grype is a pinned release verified by sha256, not `install.sh` from `main` (`nightly-cve-scan.yml`). Actions are SHA-pinned, `permissions` are `contents: read` plus `pages: write` and `id-token: write` for the deploy job, and a `concurrency` group serialises runs. Proved by AC-6.

## Gate
- **P03-AC-1** — From per-night results (F = a gating finding, E = none) the statuses are: F,F,E,E gives revoked, revoked, revoked (clearing), clean; E,F gives clean, revoked; F,E,F gives revoked, revoked, revoked. No sequence yields a status other than `clean` or `revoked`, and no `attestation-summary.json` is modified. *Verify:* `bash scripts/tests/advisory-feed.test.sh`. *Tier:* fast.
- **P03-AC-2** — A generated revoked file matches `grep -q '"status"[^"]*"revoked"'` and a clean file does not; no other key contains those tokens; `details_url` starts with the configured base URL and never contains `themonolith.org`. *Verify:* `bash scripts/tests/advisory-feed.test.sh`. *Tier:* fast.
- **P03-AC-3** — With a stub `grype`, a SBOM whose only matches are Medium or Low yields `clean`; one High yields `revoked` with its CVE id; a High under a valid waiver yields `clean`; the same waiver past `expires` yields `revoked`. *Verify:* `bash scripts/tests/advisory-feed.test.sh`. *Tier:* fast.
- **P03-AC-4** — A failing `grype db update` exits non-zero with no file written; a failing canary exits non-zero with no file written; one corrupt SBOM among three leaves its file unchanged, updates the other two, and exits non-zero. *Verify:* `bash scripts/tests/advisory-feed.test.sh`. *Tier:* fast.
- **P03-AC-5** — `nightly-cve-monitor.py` and `advisory-feed.yml` contain none of `aws`, `s3`, `themonolith.org`, `generate-dashboard`. *Verify:* `bash scripts/tests/advisory-feed-workflow.test.sh`. *Tier:* fast.
- **P03-AC-6** — `advisory-feed.yml` has the cron schedule, `permissions` of `contents: read` plus the Pages deploy permissions only, SHA-pinned actions, a concurrency group, and fetches grype by a pinned sha256 without `install.sh`. *Verify:* `bash scripts/tests/advisory-feed-workflow.test.sh`. *Tier:* fast.
- **P03-AC-7** — A dispatched run publishes a valid `status/<tag>.json` for each release, the canary line is in its log, and `curl -fsS <OD-1 URL>/status/<tag>.json | python3 -m json.tool` succeeds from outside the runner. *Verify:* `advisory-feed.yml` dispatch, then the curl. *Tier:* slow.

## Risks
- OD-1: the name and the host are the owner's. If the name lapses, every disc's check goes silent, and the disc treats silence as "no advisory". R01 owns the disc-side handling.
- If the owner picks a host other than GitHub Pages under OD-1, its upload credential conflicts with SPEC §8 ("no long-lived cloud keys") and must be settled before this node starts.
- `monolith-advisory-check` calls `curl` against an HTTPS name; whether the i486 userland validates a modern certificate chain (TLS 1.3, CA bundle) is unverified. The first release's manual check is the first real test.
- The `Built:` text of `grype db status` is S01's dependency (unverified).
- GitHub disables scheduled workflows after 60 days without repository activity; the per-file `checked` time makes a stale feed visible but does not prevent it.
- The disc reads the tag from `/etc/monolith-release` (`monolith-advisory-check:24`); the file names must equal that tag format (unverified; checked on the first release).
- The status of rc1 is published only for people who opt in by setting `ADVISORY_BASE_URL`; rc1's built-in URL is the dead S3 host.
