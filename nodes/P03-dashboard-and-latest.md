# P03 — dashboard-and-latest

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| P | P01, P02 | P04, X01 | — (feeds MS5) | L |

**Owns:** `web/index.html`, `web/styles.css`, `web/app/{model,data,ui,charts,router,view-landing,view-downloads,view-index,view-build,view-compare,view-package}.js`, `web/app/view-boot.js` (placeholder only; P04 replaces it), `factory/bin/build-index`, `factory/bin/publish-public`, `.github/workflows/publish.yml`, `docs/public-layout.md`, `tests/fast/web/*.test.mjs`, `tests/fast/publish-*.test.*`, `tests/support/dom-stub.mjs`, `tests/fixtures/dashboard/`.
**Carries from linux-live-iso-factory@b9f533b:** `web/index.html`, `web/styles.css`, `web/app/*.js` (ported, trimmed), `scripts/generate-dashboard.py` (rewritten as `build-index`), the publish steps of `.github/workflows/build.yml:783-822` (moved to `publish.yml`). Not carried: `boot.html` (duplicate of the SPA boot view), design-tool leftovers in `web/app/router.js:104-110`.
**Study refs:** supplychain `web.*` components and `script.generate-dashboard`; supplychain contradictions (hard-coded SBOM PASS `view-index.js:63`; revoked counted as FAIL `view-index.js:30`; rc1 labelled "CI build" `data.js:217`; Builder tab keys never set `view-build.js:587`; package view up to 72 requests `view-package.js`; v86 loaded on every page `index.html:16`; two S3 hostnames; "LATEST RELEASE" for any build `view-downloads.js`; unpinned CDN and Google Fonts, no SRI/CSP; landing claim "same commit always produces the same ISO" `view-landing.js:407`); workflows contradiction (latest pointers published before boot-test, `build.yml:495-546`); workflows `job.build.attestation` note (FAILED builds written to S3 and shown); T-dashboard-sort, T-dashboard-two-publishers, T-cve-gate-unfalsifiable; DEC-prerelease-never-latest, DEC-no-g-slash-shortcuts, DEC-s3-public-read; SPEC §2 principle 7.

## Purpose
After this node, the public site is built from one place: a single publisher workflow, running only after a build has passed the full oracle and attestation for its exact ISO digest, writes the dashboard data, the release ISO and the "latest" pointers to the `public` store. The dashboard shows what is true: real pillar statuses, revoked builds as revoked, prereleases as prereleases. It loads nothing from third parties.

## Scope
In:
- The public key layout and the JSON schemas the site reads.
- `build-index` (row, index, packages index, latest pointers) and `publish-public` (verify, upload, read back, move pointers).
- `publish.yml`, the only workflow with write access to the `public` store (besides P05's status writes, which end in a reindex dispatch here).
- The SPA port: trimmed, vendored-nothing, same-origin, with a CSP, and the bug fixes found by the study.
- Staleness display for the data and for the advisory feed.

Out:
- The backend, mutability rules, `PUBLIC_BASE_URL` pin: P01.
- The GitHub release and its verification script: P02. `publish.yml` calls P02's `release-verify`.
- The in-browser boot view, v86 and BIOS files: P04. This node leaves a placeholder and a lazy-load hook only.
- Status files and the nightly scan: P05.
- Retention of public keys: M03.
- Documentation of the verification steps in the README: X01.

## Design

### Public layout (keys are URL paths; see P01 for mutability)
| Key | Mutable | Written by | Content |
|---|---|---|---|
| `index.html`, `styles.css`, `app/*.js`, `vendor/**` | yes | `publish-public site` | the SPA (P04 adds `vendor/v86/*`) |
| `attestation/<id>/*` | no | `publish-public build` | every file of the build's attestation directory, plus `row.json` |
| `releases/<version>/themonolith-<version>.iso`, `releases/<version>/SHA256SUMS` | no | `publish-public build` (tags only) | the attested ISO |
| `builds-index.json` | yes | `build-index all` | all rows, newest first |
| `packages-index.json` | yes | `build-index all` | package to builds map |
| `latest.json` | yes | `build-index all` | newest row of any kind |
| `latest-release.json` | yes | `build-index all` | newest row with an ISO (a tag, prereleases included) |
| `status/<id>.json`, `status/_heartbeat.json` | yes | P05 (first copy `clean` by `publish-public`) | advisory state |

`<id>` is the version without `v` for tags (`0.2.0`, `0.2.0-rc1`, the same string as `/etc/monolith-release`) and `<BUILD_EPOCH>-<short-sha>` otherwise (DEC-iso-naming). Rejected: one `themonolith.iso` copied on every build (old `build.yml:540-546`): the store has no mutable copy and a bare "latest ISO" URL breaks digest-first verification. Users reach the newest ISO through `latest-release.json`, which carries its URL and sha256.

CI (non-tag) rows publish metadata only, not the ISO. Reason: a 212 MB ISO per weekly build is about 11 GB per year for rows nobody boots; their ISO stays an Actions artifact and in the `build` class. Rejected: ISO for every row, as the old bucket did.

### Row, index and pointer schemas (all `"schema": 1`)
`attestation/<id>/row.json`:
```json
{"schema":1,"id":"0.2.0-rc1","version":"0.2.0-rc1","kind":"prerelease",
 "timestamp":"2026-11-02T04:11:09Z","date":"2026-11-02","source_sha":"<40 hex>","ref":"refs/tags/v0.2.0-rc1","run_url":"...",
 "packages":107,"unmappedCPEs":0,"excludedCPEs":0,
 "pillars":{"sbom":"pass","licenses":"pass","cves":"pass","unowned":"pass","builder":"pass"},"overall":"pass",
 "cve":{"scanner":"grype","scannerVersion":"...","dbBuilt":"...","dbAgeWarning":false,"scanned":0,"matched":0,"clean":0,"unscanned":0,"totalFindings":0,"waivedFindings":0,"policyPath":"...","policySha256":"..."},
 "iso":{"path":"releases/0.2.0-rc1/themonolith-0.2.0-rc1.iso","sha256":"<64 hex>","bytes":222000000}}
```
`kind` is `release` for `vX.Y.Z`, `prerelease` for `-rcN|-betaN`, `ci` otherwise, computed from the tag only (fixes `data.js:217`, where any tag with `-` was "CI build"). `iso` is `null` for `ci`. `timestamp` is the attestation timestamp, never the publish time. Pillar values are lowercase `pass|fail|unknown`.

`builds-index.json`: `{"schema":1,"generated":"<ISO time>","repo":"owner/name","signerWorkflow":".github/workflows/build.yml","builds":[row,...]}`. `repo` comes from `GITHUB_REPOSITORY`, so no page hard-codes an owner. Each row gets two overlay fields at generation: `cpeDelta` (unmapped CPE count versus the chronologically previous row) and `advisory` (`clean|revoked|unknown` from `status/<id>.json`; `unknown` when absent).

`packages-index.json`: `{"schema":1,"packages":{"app-misc/monolith-base":[{"build":"0.2.0","version":"0.1.0-r7"},...]}}`, newest first, built from each build's `bom.cdx.json` at publish time. The package page fetches this one file instead of nine files for each of eight builds (about 72 requests).

`latest.json` and `latest-release.json`: a single row object. Selection: sort all rows by `(timestamp, id)` descending (T-dashboard-sort: tags and epochs do not lexsort; a pinned `BUILD_EPOCH` makes all CI ids share a prefix); `latest` is the first, `latest-release` the first with `kind` in `release|prerelease`. A revoked row stays eligible and shows its advisory.

### `factory/bin/build-index`
- `build-index row --attestation-dir D --evidence E --ref REF --run-url U [--iso FILE] > row.json`
- `build-index all --store public --out DIR [--now ISO]` lists `attestation/` with `store ls`, reads each `row.json` and `status/<id>.json`, and writes the four index files. It regenerates from rows every time, so it self-heals, and it is a pure function of store contents plus `--now`. Rejected: appending to the previous index (one bad run corrupts it forever); rglob over summaries from a synced mirror (old; copies every attestation directory).
- Output is canonical (sorted keys, two-space indent, trailing newline) so equal inputs give equal bytes and `store set` can skip unchanged files.

### `factory/bin/publish-public`
Subcommands `build` and `site`, orchestrated by `publish.yml`.

`publish-public build --run-id N | --tag T`:
1. Obtain inputs: for a tag, `gh release download` of the release assets (ISO, `SHA256SUMS`, `attestation-<version>.tar`, `release-evidence.json`) so the bytes are exactly what P02 published; for a CI row, the Build run's `release-attestation`-style artifacts. The ISO is downloaded in both cases to verify it.
2. `release-verify --dir D --ref REF --repo R` (P02). Any non-zero exit aborts before any store write. A build whose attestation or oracle failed never gets a row (principle 7; the old pipeline published FAILED builds by design).
3. Immutable uploads, in order: ISO and `SHA256SUMS` (tags), `attestation/<id>/*`, `row.json`. A retry finds the same bodies and no-ops.
4. `status/<id>.json` with `{"status":"clean",...}` through `set`, only if the key is absent (P05 owns it afterwards).
5. Read back: for a tag, download the ISO from `${PUBLIC_BASE_URL}/releases/...` and compare its sha256 with the attested digest; for every build, `HEAD` the key and check `Range: bytes=0-0` returns `206`.
6. `build-index all`, then `store set` in this order: `packages-index.json`, `builds-index.json`, `latest-release.json`, `latest.json`. Pointers move last. A failure at any earlier step leaves the old pointers untouched.

`publish-public site` uploads `web/**` with `set` (skips files whose sha256 sidecar already matches).

### `publish.yml`
Triggers: `workflow_run` of `Build` and of `Release` (completed); `push` to the default branch with paths `web/**` (site only); `workflow_dispatch` with inputs `tag`, `build_run_id`, `reindex`. `concurrency: publish-public`, `cancel-in-progress: false` (this serialises all writers, which P01's `HEAD`-then-`PUT` relies on). Rules:
- `Build` completed, success, `push` to the default branch: publish a CI row. `Build` on a tag: skip (the `Release` event handles it). `Release` completed and successful: read artifact `release-handoff` (tag; see defect 2) and publish the release row. Forks and non-default branches: skip.
- `reindex: true` (sent by P05's workflow after it changes statuses): run only `build-index all` and the pointer step. This keeps one index writer (T-dashboard-two-publishers).
- Secrets: `STORE_PUBLIC_*` only. Permissions: `contents: read`, `actions: read`. Actions pinned by SHA. Every workflow is an owner-review path (SPEC §8: `.github/**`).

### The SPA
Same-origin and vendor-free:
- All data URLs are relative (`builds-index.json`, `attestation/<id>/...`). No host string appears in `web/`. Local testing serves a fixture tree with `tests/support/range_server.py` (P01).
- No Google Fonts: the font stack is `system-ui` and `ui-monospace`. Rejected: vendoring Inter and JetBrains Mono woff2 files (size, licence notes, and it is decoration).
- No third-party script. v86 is loaded only when the user enters `#/boot`, by P04's view, from `vendor/v86/` (not on every page as `index.html:16` did).
- `<meta http-equiv="Content-Security-Policy">`: `default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'`. Inline event handlers and inline scripts are banned by it. (`'wasm-unsafe-eval'` is for v86; P04 confirms.) SRI is moot for same-origin files. The tested rule is "no external origin", and the CSP backs it.
- A pure `web/app/model.js` holds everything testable without a DOM: `kindOf`, `sortRows`, `statusCounts`, `pageMeta`, `BUILDER_KEYS`, `isPackageName`, `latestOf`. Views call it.
- Views kept: landing, downloads, builds (index), build (tabs Overview, SBOM, CVEs, Licenses, Unowned, Provenance, Builder, Verify), compare, package. Dropped: `postMessage('__edit_mode_*')` handlers, `TWEAKS.showBuilderCard`, density/accent tweaks, dead imports (`barList`, `normStatus` in `view-index.js`), the second copy of the boot page. The only keyboard shortcut is `t` (DEC-no-g-slash-shortcuts: do not re-add UI cruft).
- Fixes: pillar rows read `row.pillars.*` (no hard-coded SBOM PASS); revoked is its own count and colour; downloads hero uses `latest-release.json` and says "LATEST RELEASE" only for `release|prerelease`; Builder tab keys come from `BUILDER_KEYS` and each is set by `pageMeta`; Verify tab commands use `row.repo`, `--signer-workflow` and `--predicate-type`, with no `gh extension install` and no `.rekor.json` step; the package/compare name filter accepts digits and uppercase (`/^[a-z0-9][a-z0-9+_.-]*\/[A-Za-z0-9][A-Za-z0-9+_.-]*$/`); the SBOM tab paginates instead of cutting at 2,000 rows; the CVE tab shows scanner, version, DB build time and policy path and hash for every build, also with zero findings (T-cve-gate-unfalsifiable).
- Staleness: a banner if `builds-index.generated` is more than 10 days old, and one if `status/_heartbeat.json` is more than 3 days old or missing ("advisory feed not checked since ..."). Scheduled workflows go dark after 60 days of repo inactivity (T-canary-silence); the page says so instead of staying green.
- Landing copy makes no reproducibility claim (`view-landing.js:407` claimed it with no check). X01 may restore it when B07 passes.
- Legacy: a footer line links the `v0.1.0-rc1` release in the old repository. rc1 has no row, because its attestation summary is not a release asset (only ISO, SHA256SUMS, `bom.cdx.json`).

Tests use Node (`node --test`, no npm dependencies) over `model.js` and over views rendered against `tests/support/dom-stub.mjs`, a 60-line fake `document`. Node becomes a declared host tool in `pins/pins.yaml` (defect 3). Rejected: a headless browser in the fast tier (heavy, network).

## Traps and doctrines preserved
- **T-dashboard-sort:** AC-1 (index and pointer selection), AC-2 (JS model gives the same order).
- **T-dashboard-two-publishers:** AC-9 (one writer, golden key set), AC-11.
- **Principle 7, build.yml:495-546 latest-before-boot-test:** AC-5 (verify gate), AC-6 (pointers last, fault-injected), AC-10.
- **FAILED builds shown by design (workflows `job.build.attestation`):** AC-5. Failed runs are visible in Actions, not on the dashboard.
- **DEC-prerelease-never-latest:** the dashboard's LATEST is independent of GitHub's badge; AC-3.
- **DEC-no-g-slash-shortcuts:** AC-13.
- **T-cve-gate-unfalsifiable:** AC-12.
- **No-SRI/CSP, unpinned CDN, Google Fonts, hostname split:** AC-7, AC-8.
- **Study UI bugs:** AC-3 (rc1 kind), AC-4 (SBOM pillar, revoked), AC-14 (Builder keys), AC-15 (72 requests), AC-16 (name filter).
- **DEC-s3-public-read:** anyone verifies without credentials; AC-17 fetches with no credentials.

## Gate
- **P03-AC-1** — `build-index all` sorts rows by `(timestamp, id)` descending, and `latest.json` and `latest-release.json` select correctly for fixtures where all CI ids share the same `BUILD_EPOCH` prefix and a tag is older than a CI row. *Verify:* `tests/fast/build-index-sort.test.py`. *Tier:* fast.
- **P03-AC-2** — The JS `sortRows` and `latestOf` give the same order as `build-index` for the same fixtures. *Verify:* `tests/fast/web/model-sort.test.mjs`. *Tier:* fast.
- **P03-AC-3** — `kindOf` returns `release` for `0.2.0`, `prerelease` for `0.2.0-rc1` and `0.2.0-beta2`, `ci` for `20260601-abc1234`; `build-index row` and `model.js` agree; the downloads view labels only `release|prerelease` as "LATEST RELEASE" and a CI row is never a download hero. *Verify:* `tests/fast/web/model-kind.test.mjs`, `tests/fast/build-index-kind.test.py`. *Tier:* fast.
- **P03-AC-4** — Pillar rows come from `row.pillars`: a fixture with `sbom: "fail"` renders FAIL; `statusCounts` reports `pass`, `fail`, `revoked` separately and a revoked build is not in `fail`. *Verify:* `tests/fast/web/model-status.test.mjs`. *Tier:* fast.
- **P03-AC-5** — `publish-public build` performs no store write when `release-verify` exits non-zero, for each of its exit codes 10, 12, 13, 14, and for a summary with `overall != pass`. *Verify:* `tests/fast/publish-gate.test.sh` (stub `release-verify`, fs backend, empty-tree assertion). *Tier:* fast.
- **P03-AC-6** — If any immutable upload or read-back fails (fault injected at each step), none of `packages-index.json`, `builds-index.json`, `latest-release.json`, `latest.json` is changed, and a clean retry converges to the expected tree. *Verify:* `tests/fast/publish-order.test.sh` (fs backend with failure injection). *Tier:* fast.
- **P03-AC-7** — No file under `web/` contains `http://` or `https://` except an allowlisted set in `tests/fast/web/external-links.allow` (documentation links, each with a comment); none references `fonts.googleapis`, `gstatic`, `jsdelivr`, `unpkg`, `cdnjs`, `amazonaws`, or a literal repository owner. *Verify:* `tests/fast/web/no-external.test.sh`. *Tier:* fast.
- **P03-AC-8** — `web/index.html` carries the CSP meta with `connect-src 'self'` and no `unsafe-inline`/`unsafe-eval`, contains no inline script, and loads no script from another origin. *Verify:* `tests/fast/web/csp.test.sh`. *Tier:* fast.
- **P03-AC-9** — Running `publish-public build` and `site` against the fs backend for fixture runs produces exactly the key set in `tests/fixtures/dashboard/expected-keys.txt` (no `dashboard/` prefix, nothing under `attestation/` except `<id>/`), and `rg 'STORE_PUBLIC|store (set|put) public'` over `.github/` matches only `publish.yml`, `advisory.yml` (P05) and `public-smoke.yml` (P01). *Verify:* `tests/fast/publish-keys.test.sh`. *Tier:* fast.
- **P03-AC-10** — On a tag publish, the ISO is read back from `PUBLIC_BASE_URL` and its sha256 compared with the attested digest before any pointer moves; a corrupted read-back aborts. *Verify:* `tests/fast/publish-readback.test.sh` (local `range_server.py` serving a corrupted copy). *Tier:* fast.
- **P03-AC-11** — `publish.yml` has the concurrency group `publish-public` with `cancel-in-progress: false`, skips `Build` runs on tags, skips forks and non-default branches, handles `reindex`, has `permissions` limited to `contents: read` and `actions: read`, and pins every action by SHA. *Verify:* `tests/fast/publish-workflow.test.py`. *Tier:* fast.
- **P03-AC-12** — The CVE tab model exposes scanner name and version, DB build time, policy path and hash, and counts for every row, including a fixture with zero findings, and the view renders the banner for it. *Verify:* `tests/fast/web/view-cve.test.mjs`. *Tier:* fast.
- **P03-AC-13** — The only `keydown` handling in `web/` is the `t` theme toggle, and `__edit_mode`, `TWEAKS`, `postMessage` do not occur in `web/`. *Verify:* `tests/fast/web/no-cruft.test.sh`. *Tier:* fast.
- **P03-AC-14** — Every key in `BUILDER_KEYS` is set by `pageMeta` for a fixture summary, and the Builder view renders a row for each; the Verify tab output contains the fixture's `repo` and `signerWorkflow` and not `extension install` or `rekor`. *Verify:* `tests/fast/web/view-build.test.mjs`. *Tier:* fast.
- **P03-AC-15** — The package view completes with at most 2 `fetch` calls (`builds-index.json`, `packages-index.json`) for a fixture with 20 builds. *Verify:* `tests/fast/web/view-package.test.mjs` (counting `fetch` stub). *Tier:* fast.
- **P03-AC-16** — `isPackageName` accepts `sys-libs/zlib-ng`, `dev-libs/libx11`, `x11-libs/libXft`, `sys-apps/util-linux`, `dev-lang/lua`, and rejects empty names, names without a category, and names with spaces or `..`. *Verify:* `tests/fast/web/model-names.test.mjs`. *Tier:* fast.
- **P03-AC-17** — After the `v0.2.0-rc1` release, with no credentials: `builds-index.json` parses with schema 1 and contains a row `0.2.0-rc1` of kind `prerelease`; `latest-release.json` points to it; the ISO sha256 at its `iso.path` equals the attested digest; `GET /` serves the SPA. *Verify:* a `publish.yml` dispatch for the existing tag plus `tests/smoke/dashboard.sh "$PUBLIC_BASE_URL"` (curl, python3 json). *Tier:* slow.
- **P03-AC-18** — Each view (landing, downloads, builds, build, compare, package) renders without throwing for the fixture tree and contains its key text; the staleness banners appear for a fixture index older than 10 days and for a missing or 4-day-old heartbeat. *Verify:* `tests/fast/web/views-render.test.mjs`. *Tier:* fast.

## RED plan
Tester writes first: AC-1, 2, 3, 4, 16 (pure functions: they fail because `model.js` and `build-index` do not exist), then AC-5, 6, 10 with a stub `release-verify`, the fs backend and a fault-injecting wrapper (fail because `publish-public` does not exist). AC-7, 8, 13 are repository greps that fail against a copy of the old `web/` kept as a fixture (`tests/fixtures/dashboard/old-web/`: Google Fonts, jsDelivr, the `g` shortcut) so the tests are proven able to fail. AC-9 and AC-11 are written against the planned file names. AC-17 has no RED.

## Risks and open questions
- Size: a port of about 2,600 lines of untested JS. The old code has no tests (supplychain scope note). The `model.js` split is the mitigation; views stay thin.
- Summary schema is S-node territory. `build-index` reads keys of today's `attestation-summary.json` (`sbom_check`, `license_check`, `cve_check`, `unowned_check`, `overall`, `cve_coverage`, `cve_scanner`, `cve_db`, `cve_policy`, `package_count`, ...). If S03/S05 rename them, the fixtures and this node change. Unknown until those specs land.
- Per-row public size (about 5 MB assumed) drives cost and `build-index all` time; measure after the first publish. `build-index all` reads two small objects per row; fine to about 1,000 rows. M03 may thin old CI rows.
- OD-1 decides the host. If H6 (`/` serves `index.html`) cannot be met on the same origin, the SPA needs a data base URL, which this design avoids on purpose.
- The `Release`-event path depends on a handoff artifact that P02 must produce (defect 1).
- `publish.yml` and `web/` need the owner's PAT for the workflow file (T-workflow-push-needs-pat).
- Browser behaviour is not covered by the fast tier (DOM stub only). A manual check of the live site in a real browser is part of the PR checklist, stated as such.

## Cost
- Slices: 7 (model and build-index; publish-public with fault injection; publish.yml; SPA shell and landing/downloads/builds; build view; compare/package; polish and staleness). 18 ACs.
- CI build cycles: 0 of its own. P03 is `deferred`, so `v0.2.0-rc1` already exists at MS2; AC-17 dispatches `publish.yml --tag v0.2.0-rc1` against that release (`publish-public build --tag` downloads the published assets and re-verifies them). No rebuild.
- Money: public store about $0 on the recommended host (P01); egress of the read-back (212 MB) is free there.

## Spec defects found
1. **`Release` runs carry no tag in their payload.** Their `head_branch` is the default branch. P02's `release.yml` uploads artifact `release-handoff` (now in P02 Design and AC-15) and this node reads it.
2. **Graph: P03 reads attestation data from S01–S05 outputs.** The dependency is transitive through P02 so no edge is missing, but the summary schema (S05) should be frozen before P03's fixtures.
3. **The web tests need Node (OD-14, SPEC §4.3).** I05 must pin `node` for the CI host; until OD-14 is settled, the dashboard's tests cannot be required.
