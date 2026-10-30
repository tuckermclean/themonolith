# I01 — off-s3

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | F01 | I02, I03 | — | S |

**Owns:** `scripts/tests/no-aws.test.sh`, the `REGISTRY` assignment in `Makefile`.
**Ports from linux-live-iso-factory@b9f533b:** nothing. Each node that ports a file removes its S3 and AWS uses as it ports it; this node's check makes that hold.
**Study refs:** `ext.aws-s3`, build.yaml `s3_touch_points`, T-run-rerun-reuses-cache, SPEC principles 3 and 5.

## Purpose
No file in this repository names AWS or S3, and none ever will: a test in `make test` rejects any reference, so code ported later arrives without it. Durable bytes live in GHCR under one `REGISTRY` variable. Files that move between jobs of one run are Actions artifacts, and published files are GitHub Release assets.

## Standard mechanism
GHCR through `oras` and `docker`, Actions artifacts, GitHub Releases. No store interface or backend layer. Changing vendor means changing `REGISTRY` and copying the data. Custom code: none beyond a grep.

## Tests
- **Ported first:** none; the predecessor had no such check.
- **Added:** `scripts/tests/no-aws.test.sh` (AC-1 to AC-3).
- **Baseline:** run on a `b9f533b` checkout, the test fails and lists the S3 sites of the table in *Changes*, as expected.

## Changes from the port
The predecessor's S3 and AWS uses (`grep -rniE 'aws|s3://|amazonaws|S3_BUCKET'` at `b9f533b`) are removed by the node that ports each file. This table is where each goes:

| Predecessor site | Removed by |
|---|---|
| `Makefile` `S3_BUCKET` (`:66-67`, `:153`); `restore-cache` (`:376-377`) | B01 (target dropped, `docs/capabilities.md`) |
| `build.yml`: AWS credential steps (`:211`, `:601`), `S3_BUCKET` env (`:252`, `:673`), S3 uploads and the latest pointer (`:468-546`), the site step (`:788-810`) | B03 |
| `release.yml:116-133,230,273-278` | P01 |
| `pin-bump.yml:159-205` | M01 |
| `nightly-cve-scan.yml:50-62`, `nightly-cve-monitor.py:186-195,236-242,312-330` | P03 |
| `attestation.sh:198-204`, `enrich-sbom.py:515-531,1154-1170` | S01 |
| `sync-portage.sh:33-49` and its S3 test cases | I02 |
| `monolith-advisory-check:17` | R01 |
| `build-rootfs.sh:266` (`HOME_URL`) | B03, set to R01's URL |
| S3 passages of `docs/releasing.md`, `docs/version-pinning.md`, `docs/cve-gate.md` | P01, M01, S01 |
| S3 passages of `AGENTS.md` | F01 |
| `gc.yml`, `regen-pins.yml`, `s3-gc.sh` | not ported |

Three overlay ebuild comments say "own S3" (`rl144`, `monolith-xserver`, `stele`). They match none of the check's patterns, and editing them would need a revbump for no gain, so their porting nodes keep them.

1. **One `REGISTRY` variable.** Default `ghcr.io/tuckermclean/themonolith`, lowercase, assigned once in `Makefile` and once in the workflow `env:` of each workflow that names the registry. Ported scripts read `REGISTRY`; `ghcr.io/` appears in no script. *Proof:* I01-AC-2.
2. **The repository-wide check.** `scripts/tests/no-aws.test.sh` greps every tracked file for `aws |aws-actions|AWS_|amazonaws|s3://|S3_BUCKET|s3-gc`, outside the spec (`SPEC.md`, `nodes/`, `docs/study/`, `docs/reviews/`, `docs/graph.yaml`, `docs/capabilities.md`, `docs/first-release.md`, and `docs/migration.tsv`, whose rows name the dropped `s3-gc` files), the test itself and `scripts/tests/make-test.test.sh`, whose F01-AC-7 case applies this pattern. It runs in `make test-unit`, so it holds for every later port. *Proof:* I01-AC-1.
3. **Visibility is a manual owner action.** GHCR creates packages private. The owner makes `builder`, `rc1-binpkgs`, and each later package (`gentoo-tree`, `binpkgs`, `distfiles`) public once in the package settings. Anonymous `oras manifest fetch` of each is the check. *Proof:* I01-AC-4.

## Gate
- **I01-AC-1** — No tracked file outside the spec paths of change 2 and the test itself matches `aws |aws-actions|AWS_|amazonaws|s3://|S3_BUCKET|s3-gc`, and the test fails on a fixture file that does. *Verify:* `scripts/tests/no-aws.test.sh` (`git ls-files` plus `grep -E`).
- **I01-AC-2** — The registry location is assigned once in the Makefile and once in the `env:` of each workflow that names it, and `ghcr.io/` appears in no file under `scripts/` except the test. *Verify:* `scripts/tests/no-aws.test.sh`.
- **I01-AC-3** — No workflow requires a secret other than `GITHUB_TOKEN`. *Verify:* `scripts/tests/no-aws.test.sh` (`grep -rn 'secrets\.' .github/workflows` shows only `secrets.GITHUB_TOKEN`).
- **I01-AC-4** — Anonymous pull works for each package under `${REGISTRY}` that exists when this node lands (after Step 0, `builder` and `rc1-binpkgs`): `oras manifest fetch` without credentials exits 0. *Verify:* `toolbox/run -- oras manifest fetch …` with no login, log kept under `out/node/I01/`.

## Risks
- Whether a public GHCR package can be pulled without login from a fork's pull-request run is unverified; AC-4 checks it from outside GitHub only. B03's first run on a pull request settles it.
- The nightly CVE data store has no home until P03 (OD-1).
