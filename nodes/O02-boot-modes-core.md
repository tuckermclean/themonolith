# O02 — boot-modes-core

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| O | O01 | B06, G02, G03, G05, M01, O03, O04, O05, P02, S05 | MS1 | L |

**Owns:** `oracle/modes/{bios,uefi,toram,ahci,nvme,usb,virtio,nicless}.py`, `oracle/lib/smoke.py` (smoke suites shared by all modes), `oracle/bin/expected-kernel`, `.github/workflows/oracle.yml` (reusable `workflow_call`), `.github/workflows/oracle-rc1.yml` (caller; job `oracle-rc1`), `.github/actions/oracle-setup/action.yml`, `oracle/policy/rc1-expected.yaml` entries for the core modes, `oracle/fixtures/argv/{bios,uefi,toram,ahci,nvme,usb,virtio,nicless}.txt` (golden argv).
**Carries from linux-live-iso-factory@b9f533b (ported; changes only where an AC names one):** `scripts/boot-test.py` lines 191-245, 247-370 (argv builders), 953-1136 and 1140-1225 (smoke checks), 1338-1376 (suites), 1412-1435 (eject), 1602-1740 (runners); `.github/workflows/boot-test.yml` jobs `expected-kernel`, `bios`, `uefi`, `toram-eject`, `ahci`, `nvme`, `usb`, `virtio`, `nicless` (lines 41-400).
**Study refs:** oracle.yaml `bootmode.bios|uefi|toram|ahci|nvme|usb|virtio|nicless`, `harness.full_smoke_suite|reduced_smoke_suite|storage_smoke_suite`, `harness.ci_runner_environment`, `harness.ci_job_map`, `ci.boot-test.expected-kernel`, `ci.boot-test.iso-cache`, gaps (minimum RAM, BIOS-from-hybrid-disk, ~80 packages unexercised), contradictions (boot-test.yml:3-6 header, README Testing list); T-ahci-q35-nic, T-toram-ram, T-grub-initrd-same-line, T-isolinux-timeout, T-makewhatis-oom, D-486-minimalism (RAM floors), D-state-and-no-hidden-stderr; SPEC §7 (rc1 lane).

## Purpose
After this node the v0.1.0-rc1 ISO is booted in CI under BIOS/ISOLINUX, UEFI/GRUB, toram, and three storage-controller variants plus a no-NIC negative control, and each run proves the same things the predecessor proved. The first GREEN is the eight core modes passing against rc1 in the CI job `oracle-rc1`, before this repository builds anything. B06 later runs the same modes on every built ISO through its `oracle-gate` job. The node also lands the shared CI plumbing (one reusable workflow, one setup action, one expected-kernel step) so O03-O05 add modes by adding data, not copying 17 setup blocks. These are the "core" boots; nothing releases without them (P02).

## Scope
In:
- The eight runners above with their exact QEMU configuration and assertions.
- The shared smoke suites (full, reduced, storage) and the module-residency checks.
- `oracle.yml`: plan job (matrix from `oracle/modes.yaml`), boot matrix job, result aggregation, artifact upload.
- `expected-kernel`: derive and cross-check the expected `uname -r`.
- The oracle runner setup (QEMU, OVMF, pinned runner label, recorded tool versions, hash-pinned `pexpect`).
- `oracle-rc1.yml`: the caller that fetches the rc1 ISO (O01 fixtures) and runs `oracle.yml` against it with `--rc1`.
Out:
- Harness core, `pexpect` wrapper, retry, `modes.yaml` schema, rc1 fixtures and the expected-rc1-failures format: O01.
- nic/vga/fbdev-modprobe: O03. nat/persist/clock modes: O04. gui/stele-acid2: O05.
- The workflow that builds the ISO and calls `oracle.yml` from its `oracle-gate` job: B06. The oracle result cache (I06 `result-get/put`) is wired by B06, not here.
- Booting every ISOLINUX label and GRUB entry, `root=`, rescue: G02. Hyper-V: G03. Per-package smoke of the other ~80 packages: G05.
- Artifact checks on the built tree: O06.

## Design

### QEMU configuration carried forward
All modes: `-nographic -serial mon:stdio -no-reboot`, serial console is the only interaction (`boot-test.py:193-202`). RAM defaults and CI overrides as listed. Firmware for UEFI: `-drive if=pflash,format=raw,readonly=on,file=<OVMF_CODE>` with no VARS file (`boot-test.py:223-232`).

| Mode | Binary | Machine/CPU | Media and devices | Bootloader | RAM (MB) | Source |
|---|---|---|---|---|---|---|
| bios | qemu-system-i386 | default `pc`, `-cpu 486` | `-cdrom ISO -boot d`, default VGA, default NIC (e1000) | ISOLINUX `serial` | 64 and 256 (two legs) | `boot-test.py:191-212,1602` |
| uefi | qemu-system-x86_64 | default `pc`, no `-cpu` | pflash OVMF, `-cdrom ISO -boot d`, default NIC | GRUB `(serial)`, index 2 | 512 | `:214-234,1616` |
| toram | qemu-system-i386 | as bios | as bios; `--cdrom-monitor-id ide1-cd0` | ISOLINUX `serial toram` | 512 (128 OOMs, T-toram-ram) | `:1630` |
| ahci | qemu-system-x86_64 | `-machine q35` | pflash; `-device ich9-ahci,id=ahci -drive id=cd,if=none,media=cdrom,file=ISO -device ide-cd,bus=ahci.0,drive=cd -boot d`; q35 default NIC | GRUB `(serial)` | 512 | `:247-272,1682` |
| nvme | qemu-system-x86_64 | default `pc` | pflash; `-drive id=nvm,if=none,format=raw,file=ISO -device nvme,serial=cafe1234,drive=nvm -boot c` | GRUB `(serial)` | 512 | `:274-296,1689` |
| usb | qemu-system-x86_64 | default `pc` | pflash; `-device qemu-xhci,id=xhci -drive id=usbdisk,if=none,format=raw,file=ISO -device usb-storage,bus=xhci.0,drive=usbdisk -boot c` | GRUB `(serial)` | 512 | `:298-321,1696` |
| virtio | qemu-system-x86_64 | default `pc` | pflash; `-drive id=vblk,if=none,format=raw,file=ISO -device virtio-blk-pci,drive=vblk -boot c` | GRUB `(serial)` | 512 | `:323-344,1709` |
| nicless | qemu-system-i386 | as bios | as bios plus `-nic none` | ISOLINUX `serial` | 64 | `:346-370,1716` |

Golden argv files under `oracle/fixtures/argv/<mode>.txt` record the complete argv (ISO and OVMF paths replaced by `@ISO@`, `@OVMF@`). A fast test compares the builder output to them so a flag cannot change unnoticed.

### Assertions carried forward
Every mode first expects the five boot milestones in order (toram: six, with `[init] Boot media can now be ejected` between init-start and overlay-ready), then the shell, then its checks, then poweroff.
- **Full smoke suite (bios, uefi)** — the 14 checks of `boot-test.py:1338-1354`: `uname -r` equals expected; `lsmod` matches `^e1000\b`; `ip link show eth0` matches `eth0:.*\bUP\b`; DHCP (udhcpc if present, else `ip -4 addr show eth0` has an IPv4 inet, `:984-1013`); `curl --version`; `sqlite3 :memory: 'select 41+1;'` prints 42; `perl -e 'print $];'` contains `5.0`; perl strict+warnings program; perl `-Mutf8 -CS` uc of e-acute (unicore tables survived pruning); `CGI->new('x=42')->param('x')` is 42; `guestbook.cgi` GET returns `Ada` / `Hello from 1996` and an independent `sqlite3 -list -separator '|'` re-query returns the same row (`:1059-1099`); `mount` shows `type overlay`; `man ls | head -5` matches `LS|ls` via mandoc; `monolith` exits 0, `monolith tools` contains `monolith-router`, `notacommand` exits 127 with "not on the disc".
- **Reduced suite (toram)** — uname, e1000 resident, eth0 UP, overlay mounted (`:1357-1363`).
- **Storage suite (ahci, nvme, usb, virtio)** — uname, overlay mounted, no networking (`:1366-1375`, T-ahci-q35-nic: the predecessor believed q35's default e1000e is not carried, so no eth0 assertions; `CONFIG_E1000E=m` is in fact set at `configs/kernel.config:1547`, so the premise is stale but the network-free suite stays and e1000e is covered by O03). Driver checks run first: ahci `^ahci\b`, nvme `^nvme\b`, usb `^xhci_hcd\b` and `^usb_storage\b`, virtio `^virtio_blk\b` (`:1140-1208`).
- **toram** adds eject survival: Ctrl-A c, expect `(qemu)`, `eject -f ide1-cd0`, Ctrl-A c back, then a check (`:1412-1435`). New: after the eject the guest also runs two binaries the run has not executed yet (`perl -e 'print 42'`, `sqlite3 :memory: 'select 1;'`) with the output asserted. `uname -r` alone can pass from the page cache even if the squashfs were still read from the ejected CD. This is an observation from reading the predecessor, not a study finding.
- **nicless** — `^e1000\b` absent in `lsmod` (negative control: modalias coldplug loads only for present hardware), uname, overlay (`:1716-1737`).

### `expected-kernel`
`oracle/bin/expected-kernel --resolved-config resolved-kernel.config.gz --versions-lock pins/versions.lock` prints the expected `uname -r`. Version = the first line `# Linux/x86 <ver> Kernel Configuration` of the resolved config; suffix = its `CONFIG_LOCALVERSION`. It then cross-checks against `sys-kernel/monolith-kernel` in `pins/versions.lock` (revision stripped); disagreement or an empty result exits non-zero and fails the job. The predecessor derived the value from `versions.lock` plus the tracked `kernel.config` and had no empty guard (`boot-test.yml:41-56`). The resolved config is B02's build artifact (`resolved-kernel.config.gz`); rejected: reading the authored fragment (it does not contain the resolved LOCALVERSION default).

rc1 has no resolved-config artifact. For the rc1 lane, `expected-kernel --rc1-rootfs <dir>` takes the extracted squashfs (O01 `rc1-extract`) and prints the name of the single directory under `lib/modules/`; zero or several directories exit non-zero. This is weaker than the cross-check (it trusts the image), but the guest's `uname -r` still has to equal it, which catches a kernel/modules mismatch inside rc1. Built ISOs always use the resolved-config form.

### `oracle.yml`
Inputs: `iso-source` (`artifact` or `rc1`), `iso-artifact` (Actions artifact name; `artifact` only), `iso-name`, `resolved-config-artifact` (`artifact` only). With `iso-source: rc1` the `plan` and `boot` jobs run `make fixtures-rc1` (store first, O01-AC-19), pass `--rc1` to `oracle/boot.py` so listed failures in `oracle/policy/rc1-expected.yaml` are `xfail`, and derive the expected kernel from the rc1 squashfs (below). With `artifact` nothing changes and `--rc1` is never passed, so every check is strict. Jobs:
1. `plan`: runs `python3 -I oracle/boot.py --list-modes --json`, emits the matrix of legs from `oracle/modes.yaml` (22 legs once all nodes land: bios x2, uefi, toram, ahci, nvme, usb, virtio, nicless, nic x5, vga x1, fbdev-modprobe, nat, gui, stele-acid2, clock-epoch, clock-1996, persist — O03/O04/O05 add theirs by flipping `status` to `implemented`; later nodes also add legs), and runs `expected-kernel`.
2. `boot` (matrix over legs, `fail-fast: false`, `timeout-minutes` from `modes.yaml`): `oracle-setup`, download the ISO artifact (or the rc1 ISO), run `python3 oracle/boot.py --mode ... --result-json`, upload log, result JSON (and PPM for GUI legs) with `if: always()`, retention 14 days.
3. `gate`: needs `boot`; fails if any leg is not `success`, if the set of result JSONs is not exactly the planned legs (a missing leg is a failure, not a pass), and writes `$GITHUB_STEP_SUMMARY` with a table including retry counts (any attempt > 1 is annotated).
On the `artifact` path the ISO travels between jobs as an Actions artifact, not the Actions cache with `fail-on-cache-miss` (`ci.boot-test.iso-cache`) because artifacts are per-run and visible. Rejected: one job per mode written by hand (17 copies of six setup steps in the predecessor, `harness.ci_runner_environment`).

### `oracle-setup` action
Runs on `ubuntu-24.04` (pinned label, rejected: `ubuntu-latest`). Installs `qemu-system-x86 ovmf e2fsprogs squashfs-tools` from apt without KVM (TCG only), checks `/dev/kvm` is not used, records `qemu-system-i386 --version` and the OVMF package version into the job summary and into every result JSON. Versions are not pinned because the apt archive drops old versions; see Risks. The predecessor ran an unpinned `pip install pexpect` in every job (`boot-test.yml:77-78`); the action instead runs `pip install --require-hashes -r oracle/requirements.txt` (O01-AC-17). PyYAML comes from the runner's Python via `python3 -I -c "import yaml"` and the job fails if it is absent.

## Traps and doctrines preserved
- **T-ahci-q35-nic:** the AHCI variant failed on `eth0` because q35's NIC is not carried. Prevented by O02-AC-6 (storage suite has no network assertions).
- **T-toram-ram:** toram at 128 MB OOMs (copies the squashfs to RAM plus a 50% tmpfs overlay). Prevented by O02-AC-5 (512 MB default, golden argv).
- **T-grub-initrd-same-line:** only the `(serial)` entry is ever booted, so a broken plain/framebuffer/toram entry goes unseen. O02 boots only that entry; the other entries are G02's, and the static parse of the generated `grub.cfg` is B05's. Deferred, named.
- **T-isolinux-timeout:** ISOLINUX auto-boots the default after its timeout, so a late keystroke lands in the shell. Prevented by the `boot:` prompt wait with a blind fallback and a logged warning (O01-AC-9); the `TIMEOUT 300` setting is B05's.
- **T-makewhatis-oom:** mandoc's `makewhatis` OOM at 64 MB. Prevented by O02-AC-1 running `man ls` in the full suite at 64 MB.
- **D-486-minimalism:** bios at 64 MB and nicless at 64 MB are the RAM floors the oracle holds (the only tested RAM floor; the study gap "no test below 64 MB" stays with G02/G05). The floors are kept unchanged in `modes.yaml` and the golden argv. Prevented from regressing by O02-AC-1 and O02-AC-4.
- **D-state-and-no-hidden-stderr:** a missing or empty expected kernel makes every `uname` check vacuous. Prevented by O02-AC-9 and O01-AC-2. The `gate` job fails on a missing leg result (O02-AC-11).
- **D-clock-origin-1970:** not touched here (O04).

## Gate
- **O02-AC-1** — `bios` boots the ISO with `qemu-system-i386 -cpu 486 -cdrom ISO -boot d -nographic -serial mon:stdio -no-reboot` at 64 MB and at 256 MB, reaches all five milestones and a shell, and passes the 14-check full smoke suite with `uname -r` equal to the expected kernel. *Verify:* CI job `oracle / boot (bios-64)` and `(bios-256)`; argv equality by `tests/fast/test_oracle_argv.py::test_bios`. *Tier:* slow (argv test fast).
- **O02-AC-2** — `uefi` boots under OVMF via the GRUB `(serial)` entry (two Down presses) at 512 MB with the same full smoke suite. *Verify:* CI job `oracle / boot (uefi)`; `test_oracle_argv.py::test_uefi`. *Tier:* slow.
- **O02-AC-3** — `ahci`, `nvme`, `usb`, `virtio` each boot the ISO through the stated controller (q35+ich9-ahci CD, NVMe namespace, xHCI usb-storage, virtio-blk) at 512 MB, and the driver-residency checks (`ahci`; `nvme`; `xhci_hcd` and `usb_storage`; `virtio_blk`) pass before the storage suite. *Verify:* CI jobs `oracle / boot (ahci|nvme|usb|virtio)`; golden argv tests. *Tier:* slow.
- **O02-AC-4** — `nicless` boots with `-nic none` at 64 MB; `^e1000\b` is absent from `lsmod`; uname and overlay checks pass. *Verify:* CI job `oracle / boot (nicless)`. *Tier:* slow.
- **O02-AC-5** — `toram` boots with `serial toram` at 512 MB, sees the `Boot media can now be ejected` milestone between init-start and overlay-ready, passes the reduced suite, survives `eject -f ide1-cd0`, and after the eject runs a perl and a sqlite3 command not run earlier in the boot with correct output. *Verify:* CI job `oracle / boot (toram)`; `tests/fast/test_oracle_toram.py` replays a transcript in which the eject succeeds but `perl` fails with I/O error and asserts the mode fails. *Tier:* slow (replay test fast).
- **O02-AC-6** — The storage suite contains no network assertion and runs on q35 without any NIC assertion; a fast test fails if `smoke.storage_suite` references `eth0`, `e1000` or `dhcp`. *Verify:* `tests/fast/test_oracle_smoke.py::test_storage_suite_is_network_free`. *Tier:* fast.
- **O02-AC-7** — Every mode builds its argv from the table above; golden argv files exist for the eight modes and match the builder output byte for byte (ISO and OVMF paths templated). *Verify:* `tests/fast/test_oracle_argv.py`. *Tier:* fast.
- **O02-AC-8** — Every smoke check in the full suite has a unit test with a passing and a failing transcript (kernel mismatch, e1000 missing, eth0 down, no DHCP address, perl missing, guestbook row mismatch, no overlay, man empty, `notacommand` exit 0). *Verify:* `tests/fast/test_oracle_smoke.py`. *Tier:* fast.
- **O02-AC-9** — `oracle/bin/expected-kernel` prints `<kernel version><LOCALVERSION>` from the resolved config, exits non-zero on an empty version, a missing LOCALVERSION line, or disagreement with `pins/versions.lock` for `sys-kernel/monolith-kernel`, and the `plan` job fails when it fails. *Verify:* `tests/fast/test_oracle_expected_kernel.py` with synthetic gz configs (match, mismatch, empty). *Tier:* fast.
- **O02-AC-10** — `oracle.yml` is reusable (`workflow_call`), contains no job per mode, builds its matrix from `oracle/modes.yaml` legs, sets `timeout-minutes` on every job, uses a pinned runner label, uploads logs and result JSON with `if: always()`, and actionlint passes. *Verify:* `tests/fast/test_oracle_workflow.py` (parse YAML, assert no `ubuntu-latest`, every job has `timeout-minutes`, matrix source is the plan job) plus the F01 actionlint lane. *Tier:* fast.
- **O02-AC-11** — The `gate` job fails when a planned leg produced no result JSON, when a leg's JSON says `ok: false`, or when `exit` is 3, and succeeds only when the result set equals the plan. *Verify:* `tests/fast/test_oracle_gate.py` runs `oracle/bin/oracle-gate` on three synthetic result directories; CI job `oracle / gate`. *Tier:* fast (script), slow (job).
- **O02-AC-12** — `oracle-setup` records the QEMU and OVMF versions into the job summary and into each result JSON, and the job fails if `/dev/kvm` is requested. *Verify:* `tests/fast/test_oracle_workflow.py` (action file content) and the `qemu` field in result JSON in CI. *Tier:* fast.
- **O02-AC-13** — *Withdrawn (v0.3):* B06 depends on O02, so a B06 ISO cannot gate O02. The first GREEN is the rc1 run (O02-AC-14); B06's `oracle-gate` runs the same modes on built ISOs and P02 on tags.
- **O02-AC-14** — The CI job `oracle-rc1` boots the pinned v0.1.0-rc1 ISO through `oracle.yml` with `--rc1` and the `bios-64`, `bios-256`, `uefi`, `toram`, `ahci`, `nvme`, `usb`, `virtio` and `nicless` legs are green: each leg passes, or fails only on checks listed in `oracle/policy/rc1-expected.yaml` with a study id; the `gate` summary lists retry counts and every `xfail`. *Verify:* CI run of `oracle-rc1` linked in the node PR. *Tier:* slow.
- **O02-AC-15** — `oracle/bin/expected-kernel --rc1-rootfs DIR` prints the single directory name under `lib/modules/` and exits non-zero for zero or several; the resolved-config form is unchanged and is the only form `oracle.yml` uses when `iso-source` is `artifact`. *Verify:* `tests/fast/test_oracle_expected_kernel.py::test_rc1_rootfs`, `::test_artifact_path_rejects_rc1_flag`. *Tier:* fast.
- **O02-AC-16** — `oracle.yml` passes `--rc1` only when `iso-source` is `rc1`; a workflow test fails if any job reachable from B06's `oracle-gate` can receive the flag. *Verify:* `tests/fast/test_oracle_workflow.py::test_rc1_flag_only_for_rc1_source`. *Tier:* fast.

## RED plan
Tester commits, all failing before implementation: `test_oracle_argv.py` and the eight golden argv files (builders absent), `test_oracle_smoke.py` (suites absent; includes the network-free storage assertion), `test_oracle_expected_kernel.py` (script absent; includes the rc1 form), `test_oracle_toram.py` (replay transcripts under `oracle/fixtures/serial/` — eject OK but perl I/O error), `test_oracle_workflow.py` (workflow absent; includes the `--rc1` flag rule), `test_oracle_gate.py`. The slow ACs have no RED; their GREEN is the `oracle-rc1` run of the node PR.

## Risks and open questions
- Hardest: runtimes and TCG flakiness. The predecessor set no job timeouts and recorded no runtimes (`oracle.yaml` open question). The predecessor's boot legs took about 1-2 min each on GitHub-hosted TCG runners (17 modes in about 10 min wall in parallel; only `nic-models` was longer, 9.1 min; measured). Initial `job_timeout_minutes`: 15 for the core legs, a ten-fold margin that still stops a hung runner. Calibrate from the first `oracle-rc1` run and change `modes.yaml`. (O01's `modes.yaml` example shows the same field.)
- apt-installed QEMU/OVMF versions drift with the runner image. A QEMU upgrade can change 486 TCG behaviour. Pinning belongs to I05 (pins.yaml has no apt section today); alternative is a container with a digest-pinned QEMU, which needs a node that does not exist. Decision requested.
- rc1 passed the predecessor's own 17 modes when it was tagged, so the ports should pass on it unchanged. The strengthened assertions (exact `uname -r`, post-eject binaries in toram) are the only new things rc1 might fail; any such failure is a finding about rc1, recorded in `rc1-expected.yaml` with a study id, and the assertion stays strict on our builds. The first run may also fail for reasons that predate this rebuild (perl version string, `man` output, guestbook path). The expected guest paths (`/usr/lib/cgi-bin/guestbook.cgi`, `/usr/sbin/monolith-console`) come from R01's recipes; any rename there breaks smoke checks.
- `perl $]` containing `5.0` is loose (the predecessor's own comment says tighten). Left loose; tightening needs the perl version from `pins/versions.lock`.
- A ~80-package set is untested in these modes; G05 owns it.
- Contradiction from the study left to the first rc1 run: whether the CI guest can reach the internet (clock-1996 comment says yes, clock-epoch comment says no). Does not affect the core modes (the full suite needs only SLIRP DHCP), but record the answer in the first run's log.
- Disk budget: one ISO download per leg, 22 legs, size per ISO unknown. The rc1 legs restore the ISO from the store (or the Actions cache of the fixture job), not from GitHub, per leg.

## Cost
Four agent slices: (1) builders, golden argv, suites with fast tests; (2) toram eject strengthening and replay tests; (3) expected-kernel (both forms); (4) `oracle.yml`, `oracle-rc1.yml`, setup action, gate, first-run fixes. Expect two or three CI cycles on `oracle-rc1`; each takes the longest core leg plus setup (measured on the predecessor: about 1-2 min per boot leg, about 10 min wall for all 17 modes in parallel, so a core-only run is a few minutes). No build is needed, because rc1 is a downloaded fixture. Later runs on built ISOs are B06's cost. No paid services; GitHub-hosted minutes only.

## Spec defects found
- SPEC §4.2 has no owner for `.github/actions/`; this node creates `.github/actions/oracle-setup/`.

