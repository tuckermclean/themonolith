# I01 — off-s3

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | F01 | I02, I03 | — | M |

**Owns:** edits to `Makefile`, `scripts/binpkg-store.sh`, `scripts/sync-portage.sh` (S3 tiers only), `scripts/attestation.sh`, `scripts/enrich-sbom.py`, `scripts/nightly-cve-monitor.py`, `.github/workflows/*.yml` (S3 and AWS steps only), `docs/{releasing,version-pinning,cve-gate}.md`, `README.md`, `AGENTS.md` (S3 prose only), `scripts/tests/no-aws.test.sh`, `scripts/tests/binpkg-store.test.sh` (new cases).
**Ports from linux-live-iso-factory@b9f533b:** `scripts/binpkg-store.sh` (GHCR and oras, already in place), `scripts/savedconfig-cache.sh` (already GHCR, no S3 call left; comment only).
**Study refs:** `ext.aws-s3`, build.yaml `s3_touch_points`, T-run-rerun-reuses-cache, SPEC principles 3 and 5. The 401 behaviour: `_bp_pull_is_benign_miss`, `scripts/binpkg-store.sh:330-338`.

## Purpose
After this node no file in the build path names AWS or S3. Durable bytes live in GHCR under one `REGISTRY` variable. Files that move between jobs of one run are Actions artifacts, and published files are GitHub Release assets. The predecessor already half did this for binary packages, so most work is deletion.

## Standard mechanism
GHCR through `oras` and `docker`, Actions artifacts, GitHub Releases. No store interface or backend layer (v0.3's F06 and I01 are removed). Changing vendor means changing `REGISTRY` and copying the data. Custom code: none. The one behavioural fix (change 3) is a regex edit.

## Changes from the port
Every S3/AWS use found by `grep -rniE 'aws|s3://|amazonaws|S3_BUCKET'` over the imported tree, with its replacement:

1. **One `REGISTRY` variable.** Default `ghcr.io/tuckermclean/themonolith`, lowercase, defined once in `Makefile` (`:47`, was `ghcr.io/tuckermclean`) and once in the workflow `env:` of each remaining workflow (`build.yml:49`). `binpkg-store.sh` builds its reference as `${REGISTRY}/binpkgs:<tag>` from that variable, replacing `ghcr.io/${owner}/monolith-binpkgs` and the `GHCR_OWNER` plumbing (`binpkg-store.sh:68-75`, `build.yml:199`). The tag argument stays `BUILD_EPOCH` until B01 defines the cache tag. *Proof:* I01-AC-1, I01-AC-2.
2. **Remove every S3 use**, by site:
   - `Makefile`: `S3_BUCKET` (`:66-67`), the `-e S3_BUCKET` pass-through (`:153`), and the `aws s3 sync` in `restore-cache` (`:376-377`; the target now runs `binpkg-store.sh pull`) are deleted or replaced.
   - `build.yml`: the AWS credential steps (`:211`, `:601`), `S3_BUCKET` env (`:252`, `:673`), and the S3 uploads of logs, kernel, squashfs, initrd and ISO (`:491-546`) are deleted. Logs become `actions/upload-artifact`. The "latest pointer" logic and the `publish-latest` output (`:468-490`) go with them. The attestation upload (`:779-786`) becomes `actions/upload-artifact`, and the "Generate and upload site" step (`:788-810`) is deleted with the dashboard. The `actions/cache` job hand-off stays until B03 replaces it.
   - `release.yml`: the AWS steps and S3 downloads (`:116-133`), the S3 URL in the notes (`:230`) and the SHA256SUMS upload (`:273-278`) are deleted. The release job downloads the ISO and attestation files from the build run's Actions artifacts. P01 finishes this workflow; I01 only removes S3 so the file contains no AWS.
   - `pin-bump.yml:159-205` (AWS step, "Archive new portage snapshot to S3"), `regen-pins.yml:110-115`, `nightly-cve-scan.yml:50-62`: AWS steps deleted. M01 and P03 own the replacements.
   - `scripts/attestation.sh:198-204` and `scripts/enrich-sbom.py:515-531,1154-1170`: the `s3://` distribution reference is removed; the GitHub Release `--release-url` reference stays as the only distribution link.
   - `scripts/nightly-cve-monitor.py:186-195,236-242,312-330`: `s3_sync`, `s3_cp` and `--s3-bucket` are deleted. The script then works on a local `--data-dir` only. P03 decides where the data lives.
   - `scripts/sync-portage.sh:33-49` and the S3 cases of `scripts/tests/sync-portage.test.sh`: the S3-first and archive-to-S3 branches are deleted. I02 replaces the rest of the script.
   - `scripts/build-rootfs.sh:266`: `HOME_URL` in `/etc/os-release` names S3. It is a disc change, so R01 sets it to the OD-1 URL, and I01 leaves it.
   - Docs: S3 passages in `docs/releasing.md`, `docs/version-pinning.md`, `docs/cve-gate.md`, README (dashboard, boot-demo and `attestation/` links) and `AGENTS.md` are rewritten to say GHCR, Actions artifacts or Releases. Secret rows `AWS_*` and `S3_BUCKET` in `docs/releasing.md:204-205` are removed.
   *Not changed here:* the advisory URL default in `monolith-advisory-check:17` is R01's. Three overlay ebuild comments say "own S3" (`rl144`, `monolith-xserver`, `stele`). Editing them would need a `-rN` bump for no gain, and they match none of the check's patterns. *Proof:* I01-AC-1.
3. **GHCR auth errors are fatal; only a missing manifest is a miss.** `_bp_pull_is_benign_miss` today treats `unauthorized|denied|401` as benign (`binpkg-store.sh:330-338`) because a never-pushed GHCR repository answers 401 (the predecessor's observation, test cases at `binpkg-store.test.sh:113-116`). That also hides an expired token or a private package, and the build then silently compiles from source (SPEC principle 5). Fix: the regex keeps `not found|manifest unknown|name unknown|404` and drops `unauthorized|denied|401`. To keep the first pull from failing, the package is created once: the owner pushes any artifact (Step 0 of the plan) before CI relies on it. The `.test.sh` `benign` cases at `:114-116` become `fatal` cases. *Proof:* I01-AC-3. The "Save binary package cache" step stays warn-only (the cache is an accelerator, SPEC §6), but a failed `pull` fails the job.
4. **Visibility is a manual owner action.** GHCR creates packages private. Making `binpkgs`, `builder`, `gentoo-tree`, `distfiles` public is done once in the package settings by the owner (unverified that a public package can be pulled without login from a fork's PR run; the first slice checks it). Anonymous `docker pull` / `oras pull` of each public package is the check. *Proof:* I01-AC-5.

## Gate
- **I01-AC-1** — No tracked file outside `IMPORT.md`, `SPEC.md`, `nodes/`, `docs/study/`, `docs/reviews/`, `docs/graph.yaml` and the test itself matches `aws |aws-actions|AWS_|amazonaws|s3://|S3_BUCKET|s3-gc`. Until R01 lands, two disc-side paths are excluded, `configs/overlay/app-misc/monolith-base/files/monolith-advisory-check` and the `HOME_URL` line of `scripts/build-rootfs.sh`, and R01 deletes the exclusions. *Verify:* `scripts/tests/no-aws.test.sh` (`git ls-files` plus `grep -E`). *Tier:* fast.
- **I01-AC-2** — The registry location appears in one Makefile assignment and one `env:` entry per workflow; `binpkg-store.sh` reads `REGISTRY`, and `ghcr.io/` appears in no script. *Verify:* `scripts/tests/no-aws.test.sh`. *Tier:* fast.
- **I01-AC-3** — `binpkg-store.sh pull` returns 0 with an empty PKGDIR for `manifest unknown`, `not found`, `name unknown` and `404`, and returns non-zero for `unauthorized`, `denied` and `401`. *Verify:* `scripts/tests/binpkg-store.test.sh` (stubbed `oras`). *Tier:* fast.
- **I01-AC-4** — `actionlint` accepts every workflow and none requires a secret other than `GITHUB_TOKEN`. *Verify:* `pr-validate.yml` plus `grep -rn 'secrets\.' .github/workflows` shows only `secrets.GITHUB_TOKEN`. *Tier:* fast.
- **I01-AC-5** — Anonymous pull works for `${REGISTRY}/binpkgs:20260811`-style references once public: `oras manifest fetch` without credentials exits 0 for the four packages that exist at that point. *Verify:* a `workflow_dispatch` job without `docker/login-action`. *Tier:* slow.
- **I01-AC-6** — `make restore-cache` and a `binpkg-store.sh push` then `pull` round trip use only GHCR. *Verify:* dispatch run on this repository with `GITHUB_TOKEN`. *Tier:* slow.

## Risks
- GHCR quirk (401 for a never-pushed package) is the predecessor's observation, not re-verified. If a first push is not possible before the first build, AC-3 makes the first pull fail loudly, which is the intended behaviour.
- Public visibility and anonymous pulls from PR runs are unverified (AC-5).
- The nightly CVE data store has no home until P03 (OD-1); the script works locally only until then.
