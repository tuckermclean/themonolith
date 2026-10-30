# O01 — boot-tests

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | F01 | B03, G01 | — | M |

**Owns:** `.github/workflows/boot-test.yml` (reusable), `.github/workflows/boot-test-rc1.yml` (caller for the rc1 lane), `scripts/boot-test-requirements.txt`, `scripts/tests/boot-test-workflow.test.sh`, the ported `scripts/tests/boot-test-retry.test.sh`, the `Makefile` targets `test-bios` and `test-uefi`.
**Ports from linux-live-iso-factory@b9f533b:** first the test `scripts/tests/boot-test-retry.test.sh`; then `scripts/boot-test.py` (2528 lines, 17 modes, `-cpu 486`, `MODE_DEFAULT_RAM`), `.github/workflows/boot-test.yml` (916 lines), the manual boot targets `test` (`Makefile:500`) and `test-uefi`. Carried unchanged except as listed below.
**Study refs:** oracle.yaml `bootmode.*`, `ci.boot-test.expected-kernel`, contradictions on clock-epoch (`boot-test.py:36-42`, `boot-test.yml:796-805`); T-run-rerun-reuses-cache; D-clock-origin-1970; D-486-minimalism; SPEC §1 constraints i486 and modest memory.

## Purpose
After this node the predecessor's 17 boot modes run in CI against any ISO, whether it came from this repository's build or from a URL. The rc1 lane runs them on `v0.1.0-rc1` before this repository builds anything. Every mode passes on the rc1 ISO.

## Standard mechanism
QEMU, OVMF and `pexpect` on a GitHub-hosted runner, as the predecessor. openQA was considered (SPEC §5): it is a service to run for 17 serial-console modes. No gap is recorded and no custom code is added. The harness is carried as it is: the milestone strings, the ISOLINUX `serial` label, the GRUB `(serial)` entry (SPEC §7), the sentinel protocol and the launch-retry rule.

## Tests
- **Ported first:** `boot-test-retry.test.sh`, with one harness adjustment: a missing `boot-test.py` is reported as `FAIL` instead of an uncaught traceback. `boot-test.py` is itself the predecessor's oracle; its 17 modes are ported unchanged and run in AC-4.
- **Added:** `scripts/tests/boot-test-workflow.test.sh` (AC-2, AC-3, AC-6).
- **Baseline:** the ported test passes on `b9f533b`'s `boot-test.py`; `b9f533b`'s `boot-test.yml` fails AC-2 (`actions/cache`, S3), as expected. The rc1 ISO passing the 17 modes (AC-4) is the baseline of the oracle itself.

## Changes from the port
1. **Reusable workflow takes the ISO by artifact or by URL.** The predecessor's only input is `build-version`, and every job restores the ISO with `actions/cache/restore` keyed on the run id (`boot-test.yml:23-26,80-85`). Inputs become `iso-artifact` (an Actions artifact name) or `iso-url` plus `iso-sha256`, and optional `kernel-version` and `modes` (a list; default all 17, so a caller can leave out a mode whose package is not on the disc). A `fetch-iso` job downloads and `sha256sum -c`-verifies a URL ISO, then uploads it as an artifact; in artifact mode it does nothing. Every mode job uses `actions/download-artifact`. Reason: SPEC §4.1 forbids `actions/cache` between jobs, and the rc1 lane needs a URL. Proved by AC-2, AC-4.
2. **`boot-test-rc1.yml`** calls the workflow with the rc1 release URL, sha256 `a96006596b13cc09fa951f54aadc0b816765d783e5d0e40895d7d0945edeb27a` and kernel version `6.12.80-i486-monolith` (from `versions.lock:8` and `kernel.config:36` at b9f533b; not yet checked against the ISO). Proved by AC-4.
3. **`pexpect` is pinned.** The 17 `pip install pexpect` steps (for example `boot-test.yml:77-78`) become `pip install -r scripts/boot-test-requirements.txt` with `pexpect` and `ptyprocess` at `==` versions. The version (4.9.0 is likely; unverified) is checked against the runner's Python first. Proved by AC-2.
4. **QEMU and OVMF versions are recorded.** Each job writes `qemu-system-i386 --version`, `qemu-system-x86_64 --version` and `dpkg-query -W qemu-system-x86 ovmf` to `output/tool-versions.txt`, uploaded with the serial log. Reason: SPEC §6 needs the QEMU version in `release-inputs.json`, and apt gives no pin. Proved by AC-5.
5. **`expected-kernel` fails on an empty result.** Today an empty `KVER` or `LOCALVERSION` gives `--kernel-version ""`, and `smoke_kernel_version` passes trivially (oracle.yaml `ci.boot-test.expected-kernel`). The step adds `test -n` guards and uses the `kernel-version` input when given. The computing step reads `CONFIG_LOCALVERSION` from the savedconfig path B02 defines (`configs/portage/savedconfig/sys-kernel/monolith-kernel`; B02's test rejects the old one). Until B01 and B02 have ported the kernel config, only the `kernel-version` input works, and the guard fails loudly without it. Proved by AC-2.
6. **Action references are full commit SHAs** (SPEC §6). F01's standing test requires it, so this file is pinned as it is ported; AC-2 keeps it true.
7. **clock-epoch stale text removed.** The module docstring (`boot-test.py:36-42`) says clock-epoch uses a fixture server and checks that the hook corrects the clock. `run_clock_epoch` (`:543-585`) tests the opposite (flag raised, clock left at 1970, `-nic none`), and the workflow still starts an `http.server` the guest can never reach (`boot-test.yml:796-805`). The docstring is corrected and the dead start and stop steps of the `clock-epoch` job are deleted (`nat-router`'s are live and stay). The correction path stays covered by `scripts/tests/monolith-time.test.sh`; no new mode is added. Proved by AC-2.
8. **S3/AWS:** `boot-test.yml` and `boot-test.py` contain no S3 or AWS reference (checked by grep), so nothing is removed here. I01 owns the repository-wide removal; AC-2 keeps it true for this file.
9. **Manual boots.** The predecessor's `make test` (`Makefile:500`, a BIOS boot in QEMU with `-cpu 486 -m 64M`) and `make test-uefi` come in as `test-bios` and `test-uefi`, because `make test` is the fast tier (F01). *AC-6.*

## Gate
- **O01-AC-1** — `boot-test.py`'s `should_retry_launch` relaunches a guest that never reached `/init` while attempts remain, stops on the last attempt and reports the failure, and never relaunches after a success or after a failure that came once `/init` was reached. The module imports with `pexpect` stubbed, without running a boot. *Verify:* `scripts/tests/boot-test-retry.test.sh`. *Tier:* fast.
- **O01-AC-2** — `boot-test.yml` is a `workflow_call` with the inputs of change 1; has no `actions/cache`, `aws` or `s3` text and no `http.server` in the `clock-epoch` job (`nat-router` keeps its own, which the guest does reach); uses only SHA-pinned actions; installs `pexpect` only from the requirements file whose entries are all `==`; and its `expected-kernel` step has a `test -n` guard. *Verify:* `bash scripts/tests/boot-test-workflow.test.sh`. *Tier:* fast.
- **O01-AC-3** — `boot-test.py` still has the six `-cpu 486` argument pairs of b9f533b and `MODE_DEFAULT_RAM["bios"] == 64`; the workflow keeps `ram_mb: [64, 256]`. *Verify:* `bash scripts/tests/boot-test-workflow.test.sh`. *Tier:* fast.
- **O01-AC-4** — `boot-test-rc1.yml` runs all 17 modes (bios at 64 and 256 MB, and the nic and vga model loops) on the rc1 ISO fetched by URL and sha256, and every job is green. A wrong `iso-sha256` fails the `fetch-iso` job before any mode runs. *Verify:* workflow_dispatch of `boot-test-rc1.yml`, once with the right and once with a wrong digest. *Tier:* slow.
- **O01-AC-5** — Each mode job's uploaded artifact contains `tool-versions.txt` with the QEMU version lines and the `ovmf` package version. *Verify:* download an artifact from the AC-4 run and `grep -c 'QEMU emulator version'`. *Tier:* slow.
- **O01-AC-6** — `make -n test-bios` runs `qemu-system-i386` with `-cpu 486` and `-m 64M` on the ISO, and `make -n test-uefi` runs `qemu-system-x86_64` with OVMF; neither is named `test`. *Verify:* `scripts/tests/boot-test-workflow.test.sh`. *Tier:* fast.

## Risks
- Measured in the predecessor: modes take about 1–2 minutes each, `nic-models` 9.1 minutes, about 10 minutes wall in parallel. Not re-measured here.
- Artifact mode (`iso-artifact`) has no caller until B03; its first proof is B03's build. The URL path is proved here.
- The ISO's kernel version string for the rc1 caller is derived from predecessor files, not from the ISO. A mismatch would fail `uname -r` in every mode at the first run.
- QEMU and OVMF come from apt on `ubuntu-latest`, so a runner image update can change them. They are recorded, not pinned (unverified whether older packages remain installable).
- The "serial warmup" race in `_boot_isolinux_to_shell` (oracle.yaml, open question) is not investigated. Modes that flake get the existing retry rule only.
- Not done here: golden screendumps, second-child retry attribution, and modes beyond the predecessor's. They would change behaviour without a demonstrated failure.
