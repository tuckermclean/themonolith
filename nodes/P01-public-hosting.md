# P01 — public-hosting

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| P | I01 | P03, P05 | — (feeds MS5) | M |

**Owns:** `factory/lib/store/public_s3.py` (S3-protocol client, SigV4, stdlib only), `factory/lib/store/public.sh` (the `public` backend adapter for `factory/bin/store`), `factory/lib/store/public-mutable.txt` (mutable key patterns), `tests/support/range_server.py` (range- and CORS-capable local server, also used by P03/P04), `tests/support/fake_s3.py` (fake S3 endpoint with failure modes), `tests/smoke/public-host.sh` (live host check), `docs/decisions/0001-public-hosting.md`, `docs/hosting.md` (host requirements and setup runbook), `.github/workflows/public-smoke.yml`.
**Carries from linux-live-iso-factory@b9f533b:** nothing. Only the knowledge of what the old bucket had to do (Range, CORS, public read; `web/app/view-boot.js:70`, `docs/study/supplychain.yaml` `web_runtime_fetches.cors_and_range_requirements`).
**Study refs:** supplychain `web_runtime_fetches` (CORS/Range, regional vs global host), supplychain open question "exact CORS configuration of the bucket", supplychain contradiction "two hostnames for the same bucket", workflows `secrets_inventory` (`AWS_*`, `S3_BUCKET`), D-s3-publish-only (superseded), SPEC §2 principle 1, SPEC §5, SPEC §10 OD-1.

## Purpose
After this node, anything the world reads — dashboard, ISO for the demo, status files — is served from one stable HTTPS origin, written only through `factory/bin/store` class `public`. No workflow, script or page names a storage vendor; the vendor appears only in a decision record and in repository secrets. Changing host later means changing four secrets and one pin, not code. The old bucket died with the AWS account, and its hostnames were baked into the shipped ISO; this node prevents a repeat. The name is the urgent part: OD-1 says the advisory URL is baked into every disc from the first attested build (MS2) on, so the domain and `PUBLIC_BASE_URL` must be fixed before MS2 even though the host and this node are on the parallel track and may follow it.

## Scope
In:
- The `public` backend for the F06 store contract, speaking the S3 wire protocol (works against R2, B2, MinIO, S3, Wasabi) plus the `fs` backend for tests.
- A written list of requirements any host must meet, a recommended default with cost, and the OD-1 decision record.
- Mutable vs immutable key rules for the `public` class, and the cache headers that follow from them.
- A live smoke test of a real host (Range, CORS, size, TLS) run on demand.
- A local test server so P03/P04 can test the SPA and demo without a host.

Out:
- What goes under which key (layout, index files, pointers): P03. Status files: P05.
- Who may write to `public` in CI (one publisher workflow): P03. Retention of `public` keys: M03.
- Store CLI dispatch, exit-code table and contract suite: F06. This node plugs into them.
- Registering or paying for the domain, DNS, account creation: the owner (OD-1). This node documents the steps.

## Design

### Host requirements (any host must meet all)
| # | Requirement | Why |
|---|---|---|
| H1 | HTTPS on the stable domain, valid public certificate, TLS 1.2+. | The disc fetches `status/<tag>.json` over HTTPS; browsers block mixed content. |
| H2 | Anonymous `GET` and `HEAD` of every key; no signed URLs. | Verification must need no credentials (old DEC-s3-public-read). |
| H3 | HTTP Range: `Accept-Ranges: bytes`, `206` with `Content-Range` for single ranges, correct `Content-Length`. | v86 streams the ISO in chunks (`web/app/view-boot.js`). |
| H4 | CORS on all keys: `Access-Control-Allow-Origin` (the site origin; `*` is acceptable for these public objects), `Access-Control-Allow-Methods: GET, HEAD`, `Access-Control-Allow-Headers: Range`, `Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges, ETag`, and a valid answer to `OPTIONS` preflight. | `Range` is a non-simple header, so the browser preflights. Needed only if site and ISO are on different origins; required anyway for the `file://`/localhost dev case. |
| H5 | Objects of at least 300 MB (ISO is about 212 MB; the maintainer's figure, README says 131 MB and is stale). Single `PUT` up to 1 GiB. | GitHub Pages caps files at 100 MB, so it cannot serve the ISO. |
| H6 | `GET /` returns the site's `index.html` on the same origin as data and ISO. | The SPA uses relative URLs and needs no CORS for its own JSON. |
| H7 | Per-object `Cache-Control` set at upload. | Immutable keys cache forever; mutable keys must not go stale. |
| H8 | An S3-compatible write API (`PUT`, `HEAD`, `GET`, `ListObjectsV2`) with a scoped key pair. | The `public` backend speaks only this. A host without it needs a new backend; the contract suite still applies. |
| H9 | Egress cost is flat or zero. | A 212 MB ISO downloaded 1,000 times is 212 GB. |
| H10 | Domain under owner control, with a path to move DNS to another host. | The domain is baked into every disc from the first attested build on (P05). It outlives any host. |

### Recommended default (OD-1 default, restated)
Cloudflare R2 bucket, custom domain `monolith.technomantics.com` (OD-1 default) (zone on Cloudflare DNS, which R2 custom domains require). Reasons: no egress fee, S3-compatible API, CORS settings, free tier covers this project.

Gaps to verify when OD-1 is settled (not assumed): whether an R2 custom domain serves `index.html` for `/` (H6). If not, add a URL-rewrite rule `/` to `/index.html` on the zone. If neither works, serve the site from the host's static-site product on the apex and the bucket on `dl.<domain>`; that makes CORS (H4) mandatory and needs `<meta>` base in the SPA, which P03 deliberately does not have, so this is the fallback of last resort.

Approximate cost (verify against current price lists before relying on them):
| Item | Basis | Approx. cost |
|---|---|---|
| Storage | about $0.015 per GB-month, first 10 GB free | $0 for years |
| Stored data | releases: 212 MB x about 6 per year = 1.3 GB/yr; CI rows: about 5 MB x 52/yr = 0.3 GB/yr (5 MB per row is an assumption; measure after the first publish) | under 2 GB/yr |
| Egress | $0 | $0 |
| Operations | Class A (writes/lists) about $4.50 per million, Class B (reads) about $0.36 per million; free allowances of 1 M and 10 M per month | $0 at this volume |
| Domain | `technomantics.com` is already owned; renewal only (price unverified) | the only real cost |
| Plan | R2 may require a card on file even inside the free tier | verify |

Alternatives, rejected as default:
- S3 + CloudFront: egress about $0.085–0.09 per GB, so 1,000 ISO downloads is about $18–19. The failure mode we just lived through (vendor account loss) is the same account model.
- Backblaze B2 behind Cloudflare: cheap, free egress through the Cloudflare link, but two vendors in the path and more setup.
- GitHub Pages: fails H5. GitHub release assets: serve the ISO but a browser Range fetch goes through a redirect to another origin; CORS on that path is unverified, so not relied on for the demo.
- Self-hosted VPS: fixed cost, but we then own TLS, uptime and DDoS exposure. Revisit only with OD-7 (strange-company).

### Store `public` class
Keys are URL paths: the object at key `K` is served at `${PUBLIC_BASE_URL}/K`. `PUBLIC_BASE_URL` is a pin in `pins/pins.yaml` (no trailing slash, `https`). `store url public K` returns exactly that and fails for any other class.

Selection and configuration (names are vendor-free by design; F06 owns the dispatch mechanism and exit-code table):
| Variable | Kind | Meaning |
|---|---|---|
| `STORE_PUBLIC_BACKEND` | env | `s3` (CI) or `fs` (tests, default for `make test-fast`). |
| `STORE_PUBLIC_ENDPOINT` | secret | S3 API endpoint URL. |
| `STORE_PUBLIC_BUCKET` | secret | bucket name. |
| `STORE_PUBLIC_ACCESS_KEY_ID`, `STORE_PUBLIC_SECRET_ACCESS_KEY` | secret | key pair scoped to read/write on the one bucket. |
| `STORE_PUBLIC_REGION` | secret | defaults to `auto`. |
| `PUBLIC_BASE_URL` | pin | the public origin. |

Operations (SPEC §5 defines `set public`):
- `put public K FILE`: immutable. Same body is a no-op. A different body fails. Sets `Cache-Control: public, max-age=31536000, immutable`.
- `set public K FILE`: overwrite, allowed only when `K` matches `factory/lib/store/public-mutable.txt`; any other key fails with a usage error. Sets `Cache-Control: no-cache` (always revalidate; the ETag makes that cheap).
- `get public K DEST`, `has public K`, `ls public PREFIX`, `url public K` per SPEC §5.

Mutable patterns (the whole mutable surface, one per line, glob): `index.html`, `styles.css`, `app/*`, `vendor/*`, `builds-index.json`, `packages-index.json`, `latest.json`, `latest-release.json`, `status/*`. Everything else (`attestation/*`, `releases/*`, `smoke/*`) is immutable. P03 and P05 may add patterns only by editing this file in a PR that names them.

Integrity: each object `K` is accompanied by a sidecar `K.sha256` holding the lowercase hex digest and a newline, written after the body. Rejected: reading the digest from `x-amz-meta-*` headers, because not every host exposes user metadata on public GET. `get` downloads the body, then the sidecar, and fails on mismatch. A body without a sidecar is an error ("incomplete put"), never "absent". `put` retried after a crash finds body-without-sidecar, hashes the body, compares it to the new file and writes the sidecar if equal. `has` is true only if both exist.

Error mapping (the point of the contract): `404` on a credentialed `HEAD`/`GET` is absent (exit 3). `401`, `403` (S3 returns 403 for a missing key when the key pair lacks list permission, so 403 is never absence), `5xx`, connect and read timeouts, DNS and TLS failures are errors with the exit codes F06 assigns, and the message goes to stderr unredacted except secrets. No `2>/dev/null` anywhere in the adapter (D-state-and-no-hidden-stderr). Requests retry twice on connection errors and `5xx`, never on `4xx`.

Implementation: Python 3 stdlib (`http.client`, `hashlib`, `hmac`, `xml.etree`) in `public_s3.py` with AWS Signature V4 for `s3`. `public.sh` is a thin adapter. Rejected: `aws` CLI (large, another pinned tool, hides errors in output parsing), `rclone`/`mc` (same), `curl --aws-sigv4` (no `ListObjectsV2` parsing, awkward retries). A 200-line client fits the 486-minimal spirit for the factory too and can be tested against `fake_s3.py`.

Uploads stream from disk; no multipart (ISO is under the 1 GiB bound; H5). A body over that bound fails loudly with the key and size.

### OD-1 before MS2
The decision has two parts with different deadlines.
- **The name** (before MS2): the owner settles OD-1, `docs/decisions/0001-public-hosting.md` gets its first lines (`Resolves: OD-1`, the domain, the URL, who owns the registration), and `PUBLIC_BASE_URL` is pinned (I05). P05's `monolith-advisory-check` reads that name. None of this needs a running host or the `s3` backend.
- **The host** (any time after, on the parallel track): the S3 backend, the live smoke and the full decision table (H1–H10). Until the host answers, the disc must not report a clean advisory state; P05 defines that behaviour.

### Fake and local servers
`tests/support/fake_s3.py`: in-memory S3 subset with switchable faults (`404`, `403`-for-absent, `500`, slow, truncated body, wrong digest sidecar). `tests/support/range_server.py`: serves a directory with `Accept-Ranges`, `206`, CORS and preflight, so SPA and demo tests need no network.

### Live smoke
`tests/smoke/public-host.sh BASE_URL` (no credentials, read-only) checks H1–H7 with `curl`: certificate, `GET /` is HTML, `Range: bytes=0-1023` on `smoke/range-probe-256M.bin` gives `206` and a correct `Content-Range`, a preflight from `Origin: https://example.invalid` is answered with the H4 headers, a full `HEAD` reports `Content-Length` 268435456, and `http://` does not serve content. The probe object is uploaded once through `store put public` with a deterministic body (256 MiB of a repeating counter) so the check also proves H5 and the immutable no-op. `public-smoke.yml` runs it on `workflow_dispatch` only, with the store secrets, so forks never see them.

## Traps and doctrines preserved
- Principle 1 / D-s3-publish-only superseded: vendor named in code. AC-7 greps for vendor strings.
- Auth treated as absence (SPEC §5; the old `sync-portage.sh` `aws s3 cp ... >/dev/null 2>&1` pattern, workflows secrets list): AC-2.
- Overwrite of a published artifact by mistake (old `themonolith.iso` server-side copy): AC-3, AC-5.
- Two hostnames for one bucket, regional vs global (supplychain contradiction): single pin, AC-11.
- Unknown CORS rule that "lives in the console" (supplychain open question): CORS is a tested requirement, AC-9, and the setup is a runbook in `docs/hosting.md`.
- D-state-and-no-hidden-stderr: AC-8.
- T-workflow-push-needs-pat: `public-smoke.yml` is a workflow file; the owner's PAT is needed to push it (see Risks).

## Gate
- **P01-AC-1** — The `public` backend with `STORE_PUBLIC_BACKEND=s3` passes the whole F06 contract suite against `fake_s3.py`. *Verify:* `tests/fast/public-backend-contract.test.sh`. *Tier:* fast.
- **P01-AC-2** — `404` maps to exit 3 for `has`/`get`; `401`, `403`, `500`, timeout, DNS failure and TLS failure each map to a non-zero code other than 3 with a stderr message naming the key and cause. *Verify:* `tests/fast/public-backend-errors.test.sh` (fault switches in `fake_s3.py`, including "403 for absent key"). *Tier:* fast.
- **P01-AC-3** — `put` of an existing key with the same body sends no body and exits 0; with a different body exits non-zero and leaves the stored object and sidecar unchanged. *Verify:* `tests/fast/public-backend-immutable.test.sh`. *Tier:* fast.
- **P01-AC-4** — `get` fails on a body whose digest differs from its sidecar, fails (not "absent") on a body without sidecar, and a crashed-put retry completes the sidecar only when the bodies match. *Verify:* `tests/fast/public-backend-integrity.test.sh`. *Tier:* fast.
- **P01-AC-5** — `set` succeeds only for keys matching `public-mutable.txt`, fails with a usage error for any other key, and `put` of a mutable key twice with different bodies fails. *Verify:* `tests/fast/public-backend-mutable.test.sh`. *Tier:* fast.
- **P01-AC-6** — Uploads carry `Cache-Control: public, max-age=31536000, immutable` for immutable keys and `no-cache` for mutable keys, and the sidecar carries the same as its body. *Verify:* `tests/fast/public-backend-headers.test.sh` (headers recorded by `fake_s3.py`). *Tier:* fast.
- **P01-AC-7** — No file under `factory/`, `web/`, `.github/`, `tests/`, `README.md`, `docs/` (except `docs/decisions/0001-public-hosting.md`, `docs/hosting.md` and `docs/study/`) contains a storage-vendor name or host pattern (`amazonaws`, `cloudflare`, `r2.dev`, `r2.cloudflarestorage`, `backblaze`, `wasabi`). *Verify:* `tests/fast/no-vendor-names.test.sh`. *Tier:* fast.
- **P01-AC-8** — On every failure path of the backend, neither stdout nor stderr contains the secret access key or a full `Authorization` header, and the adapter source contains no `2>/dev/null` and no `|| true`. *Verify:* `tests/fast/public-backend-secrets.test.sh`. *Tier:* fast.
- **P01-AC-9** — SigV4 signing reproduces the signatures in AWS's published SigV4 example requests, and signs `Host`, `x-amz-content-sha256` and `x-amz-date`. *Verify:* `tests/fast/public-sigv4.test.py` (known-answer vectors recorded in the test). *Tier:* fast.
- **P01-AC-10** — `tests/support/range_server.py` passes `tests/smoke/public-host.sh` (the same script used on the live host), so the smoke script is itself tested and the `fs` backend path proves nothing in the check depends on a vendor. *Verify:* `tests/fast/public-smoke-local.test.sh`. *Tier:* fast.
- **P01-AC-11** — `pins/pins.yaml` contains `PUBLIC_BASE_URL` as an `https://` URL with no trailing slash and no path, and `store url public K` equals `${PUBLIC_BASE_URL}/K` and fails for classes other than `public`. *Verify:* `tests/fast/public-url.test.sh`. *Tier:* fast.
- **P01-AC-12** — The decision record states the OD-1 outcome (host, domain, who owns the registration), a table that marks each of H1–H10 as met with the evidence, the approximate monthly cost, and an exit plan (how to move host without a new ISO). *Verify:* `tests/fast/decision-record-0001.test.sh` (required headings and a row per requirement). *Tier:* fast.
- **P01-AC-13** — On the live host the smoke test passes: `206` with a correct `Content-Range` for a 256 MiB object, preflight headers per H4, `GET /` is HTML, `http://` serves no content, certificate valid. *Verify:* `public-smoke.yml` run on the chosen host (workflow_dispatch), log linked in the PR. *Tier:* slow.
- **P01-AC-14** — A 256 MiB object round-trips through `store put public` / `store get public` on the live host with matching sha256, and a second `put` of the same body is a no-op. *Verify:* `public-smoke.yml` (same run, second job). *Tier:* slow.
- **P01-AC-15** — `docs/decisions/0001-public-hosting.md` begins with `Resolves: OD-1` and names the domain and the full `PUBLIC_BASE_URL`, and the pin in `pins/pins.yaml` equals that URL. This is the only part of OD-1 needed before MS2; AC-12 to AC-14 may follow. *Verify:* `tests/fast/decision-record-0001.test.sh` (first lines and pin equality). *Tier:* fast.

## RED plan
The tester writes AC-1 to AC-9 first, all in `tests/fast/`, using `fake_s3.py` and the recorded SigV4 vectors. They fail because `factory/lib/store/public_s3.py` and `public.sh` do not exist (the test scripts exit non-zero on "command not found", asserted by checking for the specific message so RED is not accidental). AC-10 depends on the smoke script and range server, written in the same slice. AC-12 fails because the decision record is absent. AC-13/14 are written last and run only after the owner supplies secrets.

## Risks and open questions
- **OD-1 blocks the live ACs, and its name blocks MS2.** AC-1 to AC-11 do not need it; AC-12 to AC-15 do. Until it is settled, the node can reach "fast tier green" only. The name must be settled before the first attested build, because the disc bakes the advisory URL in (see "OD-1 before MS2").
- `themonolith.org` is a third party's live site, so it is ruled out; OD-1 defaults to `monolith.technomantics.com`, a subdomain of a domain the owner holds and does not use. The domain is baked into every ISO from the first attested build on (P05); losing it orphans every ISO's advisory check. Set auto-renew and a multi-year term.
- R2 custom-domain behaviour for `/` (H6) and conditional `PUT` are unverified. The adapter uses `HEAD` then `PUT`, which is safe only because P03 serialises all writers in one concurrency group.
- Workflow files (`public-smoke.yml`) can be pushed only with the owner's PAT (T-workflow-push-needs-pat). Agents hand off a patch.
- Scheduled workflows are disabled after 60 days of repo inactivity (supplychain, T-canary-silence). The smoke check is on-demand by design; P03 shows a staleness banner instead of relying on a schedule.
- 5 MB per CI row is an assumption; measure after the first publish and update the cost table.

## Cost
- Slices: 3 (backend and fakes; smoke and range server; decision record and live checks). About 14 live ACs.
- CI build cycles: 0 full builds. One manual workflow run on the live host.
- Money: domain renewal only if the owner's existing domain is used; hosting about $0 on the recommended default at this volume (approximate, see table).
