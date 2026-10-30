# B03 — ci-build

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | B01, B02, R01, O01, O02, S01 | G01, P02, R03, R05 | MS1 | M |

**Owns:** `.github/workflows/build.yml`, `scripts/tests/build-workflow.test.sh`, `scripts/tests/pcf-fontname.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `.github/workflows/build.yml` (jobs `changes`, `build-image`, `build`, `boot-test`, `attestation`), `scripts/build-rootfs.sh`, `scripts/build-initrd.sh`, `scripts/build-iso.sh` and what they read: `scripts/pcf-fontname.py`, `rootfs/init`, `rootfs/usr/share/udhcpc/default.script`, `configs/initrd-modules.txt`, `configs/bootbg.png`, `configs/themonolith.ans`; the `Makefile` targets `build-rootfs`, `iso`, `all`, `attestation`. The three scripts are carried byte for byte except change 8. The predecessor's `scripts/tests/pcf-fontname.test.sh`, `verify-rootfs-net-wiring.sh` and `verify-router-wiring.sh` are where B03-AC-10 and -11 come from; they are not ported.
**Study refs:** T-run-rerun-reuses-cache, T-attest-entry-workflow, D-supply-chain-honesty, D-tag-builds-from-source; workflows.yaml `wf.build`; contradiction "latest pointers copied before boot-test" (`build.yml:495-546` vs `:559`).

## Purpose
After this node, a push or a labelled PR on this repository builds the ISO from pinned inputs and runs the ported oracle and gates on it, with no AWS step anywhere. This is MS1, the first goal: a working, testable ISO for iteration. It is not published and is not a release. Binary packages are allowed here, and `rl144` and `stele` are left out until R05. P02 and P01 add the tag-only steps on top.

## Standard mechanism
GitHub Actions, `actions/upload-artifact` and `download-artifact` for files that move between jobs of one run, and reusable workflows (`workflow_call`) for the boot tests. The Makefile stays the single definition of the steps, so a developer's `make all` runs what CI runs. Custom code: none. The one new test only reads the workflow file.

## Changes from the port
Everything else in `build.yml` and the three scripts is carried unchanged, including the `changes` path filter, the `full-ci` label gate on pull requests (`build.yml:58-60`) and the weekly schedule.

1. **In-run handoff uses artifacts, not `actions/cache`.** The squashfs and ISO are saved with `actions/cache/save` keyed on `run_id` (`build.yml:508-515`, `:536-540`) and restored with `fail-on-cache-miss` in `attestation` (`:625-640`) and in every boot-test job (`boot-test.yml:80-85` and the same pattern repeated). A re-run of a run reuses a cache entry written by the first attempt, so it can test an ISO this attempt did not build (T-run-rerun-reuses-cache, SPEC §4.1). Replace with `upload-artifact` (`compression-level: 0`, `if-no-files-found: error`) in `build` and `download-artifact` in the consumers. *AC-1, AC-2.*
2. **AWS and S3 steps removed.** `configure-aws-credentials`, every `aws s3` step, the `publish-latest` step and output, the S3 dashboard upload and the `S3_BUCKET` env into `make attestation`. B03 leaves them out as it ports `build.yml`, and I01's check holds the rule. The site generation step goes with them (dashboard out of scope, SPEC §0). *AC-3.*
3. **Builder pulled by digest.** `build-image` and the `Warm docker layer cache from :latest` steps are replaced by `make pull-image` on `BUILDER_DIGEST` (I03 owns the Makefile change), followed by I03's `scripts/builder-manifest.sh`, whose `builder-manifest.txt` is uploaded with `actions/upload-artifact`. The `build-image` job is removed; rebuilding the image is M02's. I03's standing test holds this file to the digest rule. *AC-4.*
4. **Boot tests call O01's reusable workflow** with the ISO artifact from item 1 instead of `build-version` plus the cache. O01 owns the interface. The call passes every mode except `stele-acid2`, because Stele is out of `world` until R05 (B01 change 11); R05 puts it back. *AC-2, AC-7.*
5. **Artifact checks (O02) and gates (S01) run on the same ISO,** in or before `attestation`. Their order in the job follows S01. They are `needs` of the signing step, so a red check blocks it. *AC-5.*
6. **Binary-package restore and push stay as ported** (`build.yml:267` pull, `:448` push) with the registry variable from B01. Tags do not use this development path. P02's tag pipeline runs the build job in its offline release mode (B01 release mode, no binpkg pull).
7. **B01's checks are wired in.** A `static-rebuild` job runs `make test-static-rebuild` in the pinned builder next to the package build, and a failure fails the run (B01 change 13). The attestation step passes `--provenance --package-tree` to the unowned gate, with the build's sysroot as an artifact (B01 change 12). *AC-7.*
8. **os-release names the advisory URL.** `build-rootfs.sh:266` sets `HOME_URL` to `themonolith.s3.us-west-2.amazonaws.com`. It takes the base URL that R01 set in `monolith-advisory-check`, so the disc names one place. *AC-8.*
9. **Kernel module checks.** The inline module assertions (`build.yml:312-420`) are not ported as YAML; the `build` job runs B02's `scripts/verify-kernel-modules.sh` on the sysroot. The `LOCALVERSION` greps (`build.yml:327,366`) read the savedconfig path (B02's test). *AC-9.*

**ISO size gates.** `build-iso.sh` has none. The script only logs kernel, initrd and ISO sizes (`build-iso.sh:379-385,490-499`), and `build-rootfs.sh:731-734` and `build-initrd.sh:356-359` only log too. B03 ports the logging as it is. The budget gate is new and belongs to P01 (SPEC §1).

## Gate
- **B03-AC-1** — `build.yml` and the workflows it calls contain no `actions/cache` step for squashfs or ISO and no `ci-artifacts-` key; the ISO and squashfs go through `upload-artifact` and `download-artifact`. *Verify:* `scripts/tests/build-workflow.test.sh` (grep and `actionlint`). *Tier:* fast.
- **B03-AC-2** — Re-running only the failed jobs of a finished run after deleting its artifact fails in `boot-test` and `attestation` instead of testing a stale ISO. *Verify:* CI: run on a PR, delete the artifact, `gh run rerun --failed`; record both run URLs. *Tier:* slow.
- **B03-AC-3** — `build.yml` has no `aws`, `s3`, `S3_BUCKET` or `AWS_` reference. *Verify:* `scripts/tests/build-workflow.test.sh`. *Tier:* fast.
- **B03-AC-4** — Every `docker pull` or `make pull-image` in `build.yml` resolves the builder by `@sha256:` digest, and none uses `:latest`. *Verify:* `scripts/tests/build-workflow.test.sh`. *Tier:* fast.
- **B03-AC-5** — The signing step (P01) and any later publishing step `need` the `boot-test` job, the artifact-check step and the gate steps (P02-AC-3 adds its `compare` job to the same rule). *Verify:* `scripts/tests/build-workflow.test.sh` parses `needs:` and `if:` of the attestation job. *Tier:* fast.
- **B03-AC-6** — Every `make` target that `build.yml` runs in `build` exists in the Makefile, and `make -n all` lists `build-packages`, `build-rootfs` and `iso` in that order. *Verify:* `scripts/tests/build-workflow.test.sh`. *Tier:* fast.
- **B03-AC-7** — MS1: a workflow run on `main` builds an ISO with binary packages restored, passes every boot mode except `stele-acid2` (16 of 17), the O02 checks and the S01 gates on it, and no job touches AWS. *Verify:* the run URL, recorded in the PR table. *Tier:* slow.
- **B03-AC-8** — `build-rootfs.sh` contains no `amazonaws`, and its os-release `HOME_URL` equals the default base URL of `monolith-advisory-check`. *Verify:* `scripts/tests/build-workflow.test.sh`. *Tier:* fast.
- **B03-AC-9** — The `build` job runs `scripts/verify-kernel-modules.sh`, and no `run:` step in `build.yml` names `lib/modules` itself. *Verify:* `scripts/tests/build-workflow.test.sh`. *Tier:* fast.
- **B03-AC-10** — `pcf-fontname.py`'s `font_xlfd` returns the exact `FONT` XLFD of a PCF in either byte order, for `-xos4-terminus-medium-r-normal--16-160-72-72-c-80-iso10646-1` and for a `-misc-fixed-` name, and raises an exception rather than return a name for input that is not a PCF. *Verify:* `scripts/tests/pcf-fontname.test.sh` (synthetic PCFs). *Tier:* fast.
- **B03-AC-11** — In the rootfs of the AC-7 run, `/etc/init.d/S35netprobe` runs `monolith-net autoprobe`, `/usr/bin/monolith-net` and `/usr/sbin/monolith-router` are owned by `app-misc/monolith-base` in the VDB, and neither is in the unowned allowlist. *Verify:* the AC-7 run's rootfs artifact and its unowned-gate log. *Tier:* slow.

Measured on the predecessor (to size expectations, not a gate): cache-hot `build` job about 13 minutes (packages about 7.5), cold about 78 minutes, boot modes about 10 minutes wall.

## Risks
- `upload-artifact` retention and the 10 GB per-repo artifact quota apply to a 200 MiB ISO plus a squashfs per run (unverified for this account).
- The attestation job derives `BUILD_VERSION` from the Dockerfile's `BUILD_EPOCH` (`build.yml:593-599`). I02 keeps `BUILD_EPOCH` as the version label until M01; the stage3 digest becomes `BUILDER_DIGEST` (I03 change 5).
- The S01 gates read a rootfs; the predecessor extracted it from the squashfs in the attestation job (`build.yml:632`). Whether to keep that or upload the sysroot is S01's call.
- The attestation job in `build.yml` must stay the entry workflow of a tag run (header comment, T-attest-entry-workflow). P01 relies on it.
