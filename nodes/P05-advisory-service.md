# P05 — advisory-service

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| P | P01, S03, P06 | X01 | — (feeds MS5) | M |

**Owns:** `factory/bin/advisory-scan`, `.github/workflows/advisory.yml`, `.github/workflows/advisory-e2e.yml`, `supplychain/policy/advisory-legacy.yaml`, `docs/advisory.md` (the status-file contract), `tests/fast/advisory-*.test.*`, `tests/fixtures/advisory/`. The disc scripts and the `monolith-base` bump moved to P06.
**Carries from linux-live-iso-factory@b9f533b:** `scripts/nightly-cve-monitor.py` (idea and status-file shape, rewritten), `.github/workflows/nightly-cve-scan.yml` (schedule); the disc scripts are carried by P06.
**Study refs:** supplychain `script.nightly-cve-monitor` notes (revokes on ANY grype match ignoring `cve-policy.yaml`; `revoked` becomes `fail` the next night; a recovered build never leaves `revoked`/`fail`; rewrites `attestation-summary.json`; syncs `status/` and `dashboard/` into the `attestation/` prefix; scans every build and downloads the whole prefix nightly; `details_url` on `themonolith.org`); supplychain contradictions (monitor "orphaned" in docs but wired in workflow; monitor claims to honour the policy; waiver `expires` never compared); supplychain open question (who is `themonolith.org`); workflows `wf.nightly-cve-scan` (failing daily at AWS credentials since 2026-10-07); T-nightly-scan-old-sboms, T-cve-gate-unfalsifiable, T-canary-silence, T-github-api-503-installs; D-supply-chain-honesty; SPEC §2 principles 1, 5.

## Purpose
After this node, a released ISO that finds a new serious CVE after release says so on the console of a booted machine, and the dashboard says so too. The feed is `status/<tag>.json` on the stable domain, produced nightly by re-scanning each published SBOM against the current vulnerability database under the same policy the build gate used. The old monitor revoked builds for any match of any severity, flipped states, rewrote attested summaries, and depended on a dead vendor URL baked into the disc.

The disc side (the URL constant, the not-live behaviour, output sanitising, the `monolith-base` bump) is P06, which lands before MS2. This node is the service and can follow on the parallel track; the status files it writes must keep the shape P06's scripts read.

## Scope
In:
- `advisory-scan`: nightly re-scan, state machine, status files, heartbeat, canary.
- The status-file format as a versioned contract with the on-disc readers.
- `advisory.yml` (scheduled) and `advisory-e2e.yml` (boot-and-fetch check, non-gating).
- A legacy list so `0.1.0-rc1` can have a status file on the new host.

Out:
- The CVE policy, the grype wrapper and waiver logic: S03. This node calls S03's evaluator (defect 1).
- The `public` backend and key rules: P01. The index and its overlay of `advisory`: P03 (this node asks it to reindex).
- The release workflow and the decision about rc1 users: P02, X01.
- Network bring-up on the disc and `S50advisory`: unchanged recipes.
- Rewriting attested files: never. `attestation/<id>/*` is immutable (P01).

## Design

### Status contract (schema 1)
Key `status/<id>.json`, mutable, `<id>` as in P03. Written with two-space indent, one key per line (the disc parses with `grep`, no `jq`):
```json
{
  "schema": 1,
  "build_tag": "0.2.0",
  "status": "revoked",
  "checked": "2026-11-03T04:12:00Z",
  "first_revoked": "2026-11-02T04:10:00Z",
  "advisories": ["CVE-2026-12345"],
  "details_url": "https://monolith.technomantics.com/#/build/0.2.0",
  "policy_sha256": "<64 hex>",
  "grype": {"version": "<v>", "db_built": "<ISO time>"}
}
```
For a clean build: `schema`, `build_tag`, `status: "clean"`, `checked`, `policy_sha256`, `grype`. No other key contains the strings `"status"` or `"revoked"` as a whole quoted token. These constraints come from the shipped readers:
- `monolith-advisory-check` greps `'"status"[^"]*"revoked"'` (`monolith-advisory-check:52`) and copies the file to `/run/monolith-advisory`.
- `40-advisory.sh` greps `CVE-[0-9]{4}-[0-9]*` over the whole file, and extracts `details_url` with `grep -o '"details_url"[^"]*"[^"]*"'` (needs a quote-free value on one line).
`details_url` is `${PUBLIC_BASE_URL}/#/build/<id>` (the old value `https://themonolith.org/builds/<tag>` pointed at a domain the project never owned; it belongs to a third party). A heartbeat object `status/_heartbeat.json`: `{"schema":1,"checked":..., "scanned":N, "changed":N, "errors":N, "grype":{...}, "policy_sha256":...}`. Ids never start with `_`, so no build collides with it.

### State machine
`status` is a function of the scan result and the previous file, evaluated per build:
- Gating findings (S03 policy: `gating_severities` Critical, High, Unknown; unexpired waivers apply; expired waivers do not) present: `revoked`, `advisories` = sorted CVE ids, `first_revoked` kept from the previous file or set now. Immediate.
- No gating findings and previous `revoked`: stays `revoked` with `"clearing": 1` for one run, and becomes `clean` on the second consecutive empty scan. One bad database day must not tell users a revoked build is fine. Rejected: clearing immediately.
- No gating findings otherwise: `clean`.
There is no `fail` state. Informational findings (Medium, Low, Negligible) never revoke (the policy says they are shown, not gating). Rejected: the old rule "any match revokes", which contradicted the build gate. A build is never revoked for a finding the build-time policy would have waived.

### `factory/bin/advisory-scan`
`advisory-scan [--store public] [--grype PATH] [--policy FILE] [--legacy FILE] [--ci-limit 10] [--now ISO] [--dry-run]`
1. Canary first: scan `supplychain/fixtures/canary-sbom.cdx.json` (S03's fixture, openssl 1.0.1) and require CVE-2014-0160 in the raw result. Absent means the scanner is blind: exit 5, no writes (T-canary-silence, T-cve-gate-unfalsifiable).
2. `grype db update`; failure exits 3 before any scan or write. Record DB build time and grype version.
3. Targets: `store ls public attestation/`, read each `row.json`; all `release`/`prerelease` rows, the newest `--ci-limit` CI rows (older CI rows keep their last status), plus `advisory-legacy.yaml` entries. Ids starting `_` are ignored. Only `attestation/<id>/bom.cdx.json` is downloaded per target (not the whole prefix, as the old monitor did).
4. Scan with `grype sbom:<file> -o json`, evaluate with S03's policy evaluator, apply the state machine.
5. Write `status/<id>.json` through `store set` only when status, advisories, clearing flag or policy hash changed (the `checked` field alone does not trigger a write; the heartbeat carries freshness).
6. One build failing to scan (bad SBOM, download error) leaves its status untouched, is counted, and the run continues; at the end exit 1. All in-scope SBOMs come from this pipeline and are schema-validated by S01, so a failure is a defect, not an expected old format (T-nightly-scan-old-sboms was about pre-schema SBOMs of the predecessor; they are not in scope). Rejected: exit 0 unless nothing scanned.
7. Write `status/_heartbeat.json` after a completed loop, also with errors (its `errors` field says so). A DB failure writes none, so staleness shows on the dashboard.
8. Exit codes: 0 ok, 1 scan errors, 2 usage, 3 DB update failed, 4 store error (any non-3 store failure, F06 codes), 5 canary failed.
The attestation summary and every `attestation/` object are read-only to this tool. Nothing is synced into the `attestation/` prefix (the old script put `status/` and `dashboard/` there, `nightly-cve-monitor.py:319`).

### Legacy entries
`supplychain/policy/advisory-legacy.yaml`:
```yaml
schema: 1
legacy:
  - id: "0.1.0-rc1"
    sbom_url: "https://github.com/tuckermclean/linux-live-iso-factory/releases/download/v0.1.0-rc1/bom.cdx.json"
    sbom_sha256: "<from that release's SHA256SUMS>"
    details_url: "https://github.com/tuckermclean/linux-live-iso-factory/releases/tag/v0.1.0-rc1"
```
The SBOM is downloaded, its digest checked against the pin, and scanned like any other. The rc1 ISO cannot be changed and looks at the old S3 host by default, so its automatic check is dead (X01 explains). A user can still opt in: `ADVISORY_BASE_URL=${PUBLIC_BASE_URL} monolith-advisory-check`, which the shipped script supports through its environment variable.

### `advisory.yml`
`schedule: cron '0 4 * * *'` plus `workflow_dispatch`. `permissions: contents: read, actions: write`. `concurrency: publish-public` (the same group as P03's publisher, so index and statuses never race), `cancel-in-progress: false`. Steps: checkout; fetch the pinned `grype` binary by sha256 from the `distfile` store class (pin from I05; mirror by I04) and verify it; run `advisory-scan`; if `changed > 0`, `gh workflow run publish.yml -f reindex=true` (P03 regenerates the index with the new `advisory` overlay; one index writer, T-dashboard-two-publishers). Secrets: `STORE_PUBLIC_*` only. Rejected: `curl .../grype/main/install.sh | sh` (old; unpinned, and a transient GitHub 503 killed a base-tools build, T-github-api-503-installs); running inside the multi-GB builder image every night.

### `advisory-e2e.yml` (non-gating)
Trigger: `workflow_run` of `Release` and dispatch. Boots the released ISO under QEMU with user networking using O01's harness, writes `_selftest-revoked` into `/etc/monolith-release` over the serial shell, runs `ADVISORY_BASE_URL=${PUBLIC_BASE_URL} monolith-advisory-check` and asserts `/run/monolith-advisory` appears and contains the fixture CVE. This is the only test of curl, TLS, CA bundle and DNS from the i486 userland against the real host. `advisory-scan` writes the fixed fixture `status/_selftest-revoked.json` (a revoked file with a reserved CVE-style id) once, via `set`. It does not gate publishing: it needs the live network and the public host.

### Disc side
Owned by P06 (advisory-client) since v0.3. P05 writes status files in the shape P06's scripts read.

## Traps and doctrines preserved
- **Revoke ignoring policy:** AC-3. **Flip-flop `revoked` to `fail`:** AC-2. **Recovered build stays revoked/fail:** AC-2.
- **Rewriting attested summaries; junk objects under `attestation/`:** AC-4.
- **T-nightly-scan-old-sboms:** AC-5, AC-6 (scope is defined; failures are loud rather than skipped silently).
- **T-cve-gate-unfalsifiable and T-canary-silence:** AC-7, AC-16 (scanner proven alive before every run; heartbeat shows silence).
- **Whole-prefix sync / egress:** AC-6 (only needed SBOMs are read).
- **Shipped reader compatibility:** AC-1 (P06 tests the readers).
- **Dead vendor URL in the ISO; D-revbump-on-overlay-change:** P06.
- **Principle 5 (honest success):** AC-5, AC-9, AC-10.
- **T-workflow-push-needs-pat:** both workflow files are pushed by the owner (Risks).

## Gate
- **P05-AC-1** — Status files produced by `advisory-scan` for clean, revoked and clearing builds satisfy the contract: valid JSON, schema 1, two-space indent, one key per line, no whole-token `"status"`/`"revoked"` outside the `status` key, and the unmodified `monolith-advisory-check` and `40-advisory.sh` produce the expected banner from each. *Verify:* `tests/fast/advisory-status-contract.test.sh`. *Tier:* fast.
- **P05-AC-2** — The state machine yields these sequences from per-night results (F = gating findings, E = none): F,F,E,E gives revoked, revoked, revoked (clearing), clean; E,F gives clean, revoked; F,E,F gives revoked, revoked, revoked; no sequence produces any status other than `clean` or `revoked`; `first_revoked` is kept across nights. *Verify:* `tests/fast/advisory-state.test.py`. *Tier:* fast.
- **P05-AC-3** — With the policy fixture, Medium/Low/Negligible findings give `clean`; Critical, High and Unknown give `revoked`; an unexpired waiver gives `clean`; the same waiver past `expires` gives `revoked`. *Verify:* `tests/fast/advisory-policy.test.py` (stub grype output, S03 evaluator). *Tier:* fast.
- **P05-AC-4** — A full run against the fs backend writes only keys under `status/`, never changes any `attestation/` object, and never writes `dashboard/`. *Verify:* `tests/fast/advisory-writes.test.sh` (key listing before and after). *Tier:* fast.
- **P05-AC-5** — Failure handling: a failed `grype db update` exits 3 with zero writes; one corrupt SBOM among three leaves that build's status unchanged, the others updated, exit 1; a store `403` exits 4; none of these exit 0. *Verify:* `tests/fast/advisory-failures.test.sh`. *Tier:* fast.
- **P05-AC-6** — Target selection: all release and prerelease rows, the newest 10 CI rows (11th and older untouched), legacy entries, ids beginning `_` skipped; only `bom.cdx.json` objects are fetched (request log). *Verify:* `tests/fast/advisory-targets.test.sh`. *Tier:* fast.
- **P05-AC-7** — If the canary scan does not report CVE-2014-0160, `advisory-scan` exits 5 and writes nothing, including no heartbeat. *Verify:* `tests/fast/advisory-canary.test.sh` (stub grype returning no matches). *Tier:* fast.
- **P05-AC-8** — A status object is written only when status, advisories, clearing flag or policy hash changed; the heartbeat is written on every completed loop, with `errors` set; `publish.yml` reindex is dispatched only when `changed > 0`. *Verify:* `tests/fast/advisory-changes.test.sh` (stub `gh`). *Tier:* fast.
- **P05-AC-9** — A legacy entry whose downloaded SBOM digest differs from `sbom_sha256` is an error (exit 1) and writes nothing for it. *Verify:* `tests/fast/advisory-legacy.test.sh`. *Tier:* fast.
- **P05-AC-10** — `advisory.yml` has the cron schedule, `permissions` exactly `contents: read` and `actions: write`, the `publish-public` concurrency group, only `STORE_PUBLIC_*` secrets, a grype fetched by sha256 (no `install.sh`, no `curl | sh`), and SHA-pinned actions. *Verify:* `tests/fast/advisory-workflow.test.py`. *Tier:* fast.
- **P05-AC-11** — *Withdrawn (v0.3):* moved to P06 (advisory-client), which must land before MS2.
- **P05-AC-12** — *Withdrawn (v0.3):* moved to P06 (advisory-client), which must land before MS2.
- **P05-AC-13** — *Withdrawn (v0.3):* moved to P06 (advisory-client), which must land before MS2.
- **P05-AC-14** — *Withdrawn (v0.3):* moved to P06 (advisory-client), which must land before MS2.
- **P05-AC-15** — `advisory-scan` against the live store (dispatch of `advisory.yml`) completes, writes `status/_heartbeat.json` less than 10 minutes old, and `status/0.1.0-rc1.json` is served at `${PUBLIC_BASE_URL}/status/0.1.0-rc1.json` with valid JSON. *Verify:* `advisory.yml` dispatch run, then `curl -fsS` and `python3 -m json.tool`. *Tier:* slow.
- **P05-AC-16** — A real nightly run's canary passes with the live grype database (CVE-2014-0160 reported). *Verify:* the log of the AC-15 run. *Tier:* slow.
- **P05-AC-17** — From a booted `v0.2.0-rc1` ISO in QEMU, the shipped `monolith-advisory-check` over the real network fetches `_selftest-revoked` from the public host and creates `/run/monolith-advisory`. *Verify:* `advisory-e2e.yml` run after the Release run. *Tier:* slow.
- **P05-AC-18** — *Withdrawn (v0.3):* moved to P06 (advisory-client), which must land before MS2.

## RED plan
Tester writes AC-1, 2, 3, 5, 7 first with a stub `grype` script (JSON fixtures in `tests/fixtures/advisory/`), an fs backend and a stub S03 evaluator; they fail because `advisory-scan` does not exist. AC-11, 12, 13 run the imported rc1 scripts: AC-11 passes on today's script for most cases, so the tester adds the cases that fail on it: the new base URL (AC-13), control bytes (AC-12), and `shellcheck` findings if any. AC-4, 6, 8, 9 are written with request and key logs from the fake store. AC-10 fails until the workflow exists. AC-14 fails until the ebuild is bumped. AC-15 to AC-17 have no RED.

## Risks and open questions
- **TLS from the i486 userland is unproven.** Whether the disc's curl or wget validates a modern Cloudflare-style certificate (TLS 1.3, a current CA bundle, SNI) is unknown. AC-17 is the first real test. If it fails, the options are a plain-HTTP advisory (spoofable, so rejected unless the file is signed) or fixing the CA bundle in the recipe.
- **S03 interface.** `advisory-scan` needs an evaluator callable outside a build (`evaluate(grype_json, policy, today)` returning gating findings, waived, expired). If S03 ships only a shell script around the build, this node adds a thin adapter and the ACs stay.
- **Domain risk.** The domain (OD-1; default `monolith.technomantics.com`) is the owner's, but only for as long as it is renewed. The domain is baked into every ISO from the first attested build (`v0.2.0-rc1`) on; losing it silences all advisories. Use long registration and auto-renew.
- **Expired waivers revoke builds.** By design (fail closed); the dashboard shows why. A calendar reminder for waiver expiry belongs to S03.
- **Dormancy.** GitHub disables scheduled workflows after 60 days without repo activity. The heartbeat and P03's banner make this visible; they do not prevent it.
- **Secrets on a schedule** run only on the default branch; forks never get them.
- **Workflow files** are pushed by the owner's PAT (T-workflow-push-needs-pat).
- **Grype DB is live data.** Two runs on one day can differ. The status records the DB build time so a revocation can be explained.
- If the owner ever recovers the AWS account, a single frozen `status/0.1.0-rc1.json` on the old host would make rc1's built-in check work again. That is a separate owner action; this node does not depend on it.

## Cost
- Slices: 4 (scan core and state machine; targets and failures; workflows; status contract). 13 live ACs; five moved to P06 in v0.3.
- CI build cycles: 0 of its own. The recipe change rides the next full build (it is already needed for `v0.2.0-rc1`). AC-17 needs one existing release ISO.
- Money: nightly run downloads a few SBOMs; at the assumed 1–2 MB each, well under 100 MB per night, free egress on the recommended host (P01). Actions minutes: a few per night.

## Spec defects found
0. Fixed in v0.3: the disc slice is now P06 (critical).
1. **S03 has no stated entry point for re-scans.** The graph lists P05 depending on S03 but SPEC never says S03's policy evaluator is a library usable outside the build. S03 must expose it.
2. **No node tests the advisory path end to end from the disc.** P05 adds `advisory-e2e.yml` as non-gating. A real oracle mode would belong to O04 (services) and would put a live-network check in the release gate, which this spec avoids; the owner may decide otherwise.
3. **SPEC §3 has no doctrine for "ISOs must not depend on a vendor host".** The advisory URL and `HOME_URL` are runtime dependencies of the shipped artifact. AC-13 enforces single-sourcing; consider a D-* entry.
