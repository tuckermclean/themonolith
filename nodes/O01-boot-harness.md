# O01 — boot-harness

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| O | F01 | B03, B05, O02, O06 | — (feeds MS1) | L |

**Owns:** `oracle/boot.py` (CLI entry), `oracle/lib/` (`guest.py`, `milestones.py`, `bootloader.py`, `qemu.py`, `retry.py`, `qmp.py`, `ppm.py`, `report.py`, `fixture_http.py`, `modes.py` registry), `oracle/interfaces.yaml`, `oracle/modes.yaml` (schema, validator, all 17 entries), `oracle/tests/fakeqemu.py`, `oracle/fixtures/serial/*.log`, `oracle/fixtures/argv/` (golden-argv mechanism), `oracle/requirements.txt` (hash-pinned `pexpect`, `ptyprocess`), `oracle/fixtures/rc1.yaml` (rc1 asset URLs and sha256), `oracle/bin/fetch-rc1`, `oracle/bin/rc1-extract`, `oracle/lib/rc1.py` (expected-failure loader), `oracle/policy/rc1-expected.yaml` (format and loader owned here; entries added by O02-O06), `oracle/oracle.mk` (target `fixtures-rc1`), `tests/fast/test_oracle_*.py` (harness subjects), the generated mode table block in `README.md` between `<!-- oracle-modes:begin/end -->` markers.
**Carries from linux-live-iso-factory@b9f533b:** `scripts/boot-test.py` (2,528 lines; core only: lines 105-190, 732-882, 883-950, 1378-1442, 1444-1600, 2364-2528), `scripts/tests/boot-test-retry.test.sh`. All ported: pexpect usage (`boot-test.py:117`, `pexpect.spawn` at `:2458`), `wait_for_shell`, `run_check`, validators, QMP/PPM, poweroff and the retry loop move over unchanged except where an AC below names the change. Principle 11.
**Study refs:** oracle.yaml `harness.*`, `common.*`, gaps "boot-test.py has no unit tests besides should_retry_launch", "serial warmup race" open question, contradictions on stale docstrings (boot-test.py:5-14, 36-42, 100-102, 144-148), `ci.boot-test.expected-kernel` (no empty guard), `ci_runner_environment` (unpinned `pip install pexpect`, no job timeouts); T-nat-router-serial-starvation (kept as the predecessor's `drain_router`), T-boot-test-wrong-cause-clock, T-gui-boot-labels, T-nft-inet-and-readline, D-state-and-no-hidden-stderr, D-clock-origin-1970; SPEC §4.3, §7 (rc1 lane), §5 (`build` class, `fixtures/rc1/`).

## Purpose
After this node a QEMU-driven boot test is a library plus a CLI, with every piece that can be tested without a VM covered by fast tests on recorded serial transcripts. The predecessor's harness was one 2,528-line script with a single unit test; a regression in the retry rule, the sentinel protocol or the PPM parser surfaced only in a 30–60 minute CI cycle. The node is a port: the predecessor's core moves over with its `pexpect` engine and its explicit router drain. It changes only what an AC names: a retry rule that ignores second boots and the NAT client, a serial warmup wired into two modes, and an unguarded `--kernel-version`. It also lands the rc1 fixture set (the v0.1.0-rc1 ISO, SBOM, squashfs, kernel and initrd, fetched by digest) and the expected-rc1-failures file format, so O02-O06 can be made to pass on rc1 before this repository builds anything (SPEC §7, rc1 lane).

## Scope
In:
- QEMU launch, the serial console (`pexpect`, as the predecessor), milestone expectation, bootloader navigation (ISOLINUX prompt, GRUB serial entry), shell readiness, guest command protocol and validators, poweroff, QMP screendump client, PPM reader, result report, retry discriminator, timeouts, exit codes.
- `oracle/interfaces.yaml`: the single file naming serial milestones, ISOLINUX labels, GRUB entry order and clock sentinels.
- `oracle/modes.yaml`: schema, validator and an entry for each of the 17 modes (a `status` field says which are implemented).
- The fake-QEMU replay tool and recorded fixtures that let the whole harness run in the fast tier.
- The rc1 fixture set: `oracle/fixtures/rc1.yaml`, `make fixtures-rc1` (fetch by digest, never committed), the copy in the store `build` class under `fixtures/rc1/`, and extraction of squashfs, kernel and initrd from the ISO.
- The expected-rc1-failures file format and loader (`oracle/policy/rc1-expected.yaml`); the entries themselves are added by the node whose check fails on rc1.
Out:
- Any per-mode runner, QEMU argv profile or assertion set: O02 (bios, uefi, toram, ahci, nvme, usb, virtio, nicless), O03 (nic, vga, fbdev-modprobe), O04 (nat, persist, clock-epoch, clock-1996), O05 (gui, stele-acid2).
- The reusable CI workflow, job matrix and runner setup: O02.
- The ISO's bootloader config and init script that emit the interface strings: B03 (init), B05 (ISOLINUX/GRUB). They must conform to `oracle/interfaces.yaml`; their gates reference it.
- Artifact doctrine checks: O06. SBOM diff: O07 (it reads `fixtures/rc1/bom.cdx.json`, which this node fetches).
- The CI job that boots rc1 (`oracle-rc1`): O02.

## Design

### Language and dependencies
Python 3, standard library plus PyYAML plus `pexpect` (SPEC §4.3). The predecessor used `pexpect` and installed it unpinned in every job (`boot-test.yml:77-78`, repeated per job). Here it is pinned: `oracle/requirements.txt` lists `pexpect` and its one dependency `ptyprocess` with `==` versions and `--hash=sha256:` lines, installed by `pip install --require-hashes -r oracle/requirements.txt` (O02's `oracle-setup` action runs it). The versions are chosen when the file is written (4.9.0 for `pexpect` is the likely pick; unverified). I05 may later fold the pins into `pins/pins.yaml`; until then this file is the pin. Rejected: the v0.2 plan of a stdlib expect engine (about 150 lines to rewrite, and the semantics the modes rely on, `child.before`, `match.group`, `expect(EOF)`, `read_nonblocking`, would have to be re-proven in a real boot; it bought nothing).

### Layout
```
oracle/boot.py                 CLI. `python3 oracle/boot.py --mode <id> --iso <path> --kernel-version <str> [flags]`
oracle/interfaces.yaml         milestones, bootloader strings, clock sentinels (single source)
oracle/modes.yaml              one entry per mode (see below)
oracle/lib/guest.py            Guest (pexpect.spawn + reached_init + log + drain), wait_for_shell, run_check, capture, validators
oracle/lib/milestones.py       expect_boot_sequence(guest, variant)
oracle/lib/bootloader.py       select_isolinux_label, select_grub_serial_entry
oracle/lib/qemu.py             argv builder base (common flags), binary/OVMF discovery
oracle/lib/retry.py            should_retry_launch, run_with_retry
oracle/lib/qmp.py              qmp_screendump(sock, out_ppm)
oracle/lib/ppm.py              read_ppm, ppm_not_black (golden comparison is O05)
oracle/lib/report.py           Check results, console report, result JSON
oracle/lib/fixture_http.py     in-process HTTP fixture server used by O04 (nat, clock-epoch)
oracle/lib/modes.py            registry: @register("bios") on a runner + argv builder
oracle/lib/rc1.py              loads oracle/policy/rc1-expected.yaml, classifies failures as expected or not
oracle/bin/fetch-rc1           fetch + verify the rc1 assets by sha256 (make fixtures-rc1)
oracle/bin/rc1-extract         squashfs, kernel, initrd out of the rc1 ISO
oracle/tests/fakeqemu.py       replays a transcript on its stdout, honours stdin triggers
```

### CLI
Flags carried from `boot-test.py:2364-2420`: `--iso` (required), `--mode` (required, choices come from the registry), `--kernel-version` (required), `--ram-mb` (default from `modes.yaml`), `--qemu-i386`, `--qemu-x86_64`, `--ovmf-code` (auto-detect list as `boot-test.py:153-158`, now also reads `OVMF_CODE` env), `--boot-timeout` (default 300), `--cdrom-monitor-id` (default `ide1-cd0`), `--log-file`, `--nic-model`, `--vga-model`, `--gui-screendump`, `--rtc-date`, `--persist-disk`. New: `--max-attempts` (default 3), `--result-json PATH`, `--golden-dir PATH` (O05), `--list-modes` (prints `modes.yaml` ids, exit 0), `--rc1` (apply `oracle/policy/rc1-expected.yaml`; see Expected rc1 failures).

Exit codes. 0 PASS. 1 FAIL (a check failed, or the guest failed after reaching `/init`). 2 usage or environment error (ISO missing, empty or malformed `--kernel-version`, QEMU or OVMF not found, unknown mode). 3 INFRA: the guest never reached `/init` on every attempt (silent launch; CI should mark the job as infrastructure-suspect). The predecessor mapped case 3 to exit 1 (`boot-test.py:2519-2523`); the split costs nothing and lets `result.json` distinguish them. Rejected: keep 0/1/2 (CI could not tell a dead runner from a dead ISO).

### `--kernel-version` guard
The value must match `^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._+-]*$`. Empty, whitespace or a bare `-`-suffix exits 2 before QEMU starts. The `uname -r` check (`smoke_kernel_version`, `boot-test.py:953`) becomes an exact match of the trimmed last output line, not a substring (`contains`, `boot-test.py:883`). Rejected: keep substring (an empty expected string always passed, `ci.boot-test.expected-kernel` open question).

### Expect engine
`Guest` wraps `pexpect.spawn` exactly as `boot-test.py:2458-2462` does (UTF-8, `errors="replace"`, `logfile` to the log). `expect`, `expect_exact`, `sendline`, `pexpect.TIMEOUT` and `pexpect.EOF` are used as before; the `HarnessError` subclasses only wrap them for the report.

Multi-guest drain (T-nat-router-serial-starvation). `pexpect` reads on demand, so a guest the test is not currently driving fills its pty and QEMU's netdev pump freezes. The predecessor's answer is a small closure, `drain_router` (`boot-test.py:2083-2088`), called between steps of the NAT test. It is ported as `Guest.drain()` with one change: `except Exception: pass` becomes `except (pexpect.TIMEOUT, pexpect.EOF)` with a comment, because AC-14 forbids a bare swallow. Every multi-guest mode calls `drain()` on each idle guest before and after every wait on the active guest (O04 does this for the NAT router). A fast two-guest flood test (AC-16) proves the rule. Rejected: a background reader thread (v0.2 design; it changes how `expect` sees bytes and is a rewrite no criterion forces).

### Interfaces file
`oracle/interfaces.yaml`:
```yaml
milestones:            # order is the normal boot order; toram inserts one
  - {id: init_start,   text: "[init] Starting init..."}
  - {id: toram_eject,  text: "[init] Boot media can now be ejected", only: toram}
  - {id: overlay_ready, text: "[init] Overlay root ready"}
  - {id: exec_init,    text: "[init] Executing /sbin/init..."}
  - {id: rcs_start,    text: "Starting system initialization..."}
  - {id: rcs_complete, text: "System initialization complete."}
isolinux: {prompt: "boot:", prompt_timeout_s: 90}
grub: {serial_marker: "(serial)", serial_entry_index: 2, menu_timeout_s: 180,
       entries: [plain, framebuffer, serial, debug, rescue, toram, persistent]}
clock: {epoch_rtc: "1970-01-01T00:00:00", era_rtc: "1996-06-15T12:00:00"}
```
Values are those of `boot-test.py:135-149,463-464` and `build-iso.sh:305-344`. B03 and B05 gate on this file (their specs); the harness reads it at import time. A milestone text change is a breaking change to both sides (SPEC §7).

### Boot sequence and shell readiness
`expect_boot_sequence(guest, variant)` expects the milestones in order, each with `--boot-timeout`, and sets `guest.reached_init = True` the moment `init_start` is seen, comparing the matched `text` (not a description, `boot-test.py:806-807`). `wait_for_shell` is carried verbatim (`boot-test.py:810-841`): send an empty line to wake `monolith-console`, then loop `echo MONOLITH_SHELL_READY_<hex>` with a 3 s expect, 60 s total. New: `boot_to_shell(guest, bootloader_step)` always ends with the throwaway `true` warmup check (`boot-test.py:2030-2035`) for every mode and every guest, not only fbdev-modprobe and nat (O01-AC-23). Rejected: warmup in two modes only (the study could not tell whether bios/uefi were exposed to the race; it costs one command).

### Guest command protocol
`run_check(guest, name, cmd, validator, timeout=30)` is carried from `boot-test.py:844-880`: send `cmd; echo MONOLITH_CHECK_<hex>:$?`, expect `MARKER:(\d+)`, hand `(exit, output)` to the validator, never raise. New: before validators run the output is stripped of ANSI/CSI sequences including bracketed paste `ESC[?2004h/l` (T-nft-inet-and-readline: a line-anchored `^1` missed the value). The echoed command line is also removed from `output` (the predecessor handled that by hand at `boot-test.py:1998-2012`). Validators: `contains`, `contains_with_exit`, `regex_matches`, `regex_absent`, `exit_code_only`, `exact_value`, `epoch_close_to` (now used by O04). Results are `Check(name, ok, detail)` records.

### Retry discriminator
Pure function in `oracle/lib/retry.py`:
```python
def should_retry_launch(ok, failing_guest_reached_init, attempt, max_attempts) -> bool
```
Retry iff `not ok` and the guest that was active when the run failed never reached `/init` and `attempt < max_attempts`. This is the predecessor rule (`boot-test.py:2425-2442`) with one change: the input is the state of the guest that was active at failure, not of the first child. Every guest the harness spawns (persist boot 2, the NAT client) is a `Guest` with its own `reached_init`, and the failure is attributed to the guest in the `with active(guest)` scope. A silent second boot or silent client now relaunches the whole mode from a clean state (persist reformats the disk). A failure after any guest reached init, or an assertion failure, never retries. Each attempt is recorded (`reached_init`, error class, seconds).

### Timeouts
Carried from `harness.timeouts_s`: boot milestone 300, ISOLINUX prompt 90, GRUB menu 180, shell ready 60, check 30, poweroff 90 (twice with `poweroff -f`), QMP screendump 25, Stele render 180, NAT DHCP 45, NAT curl poll 120, router up 60, `monolith-net probe` 60. All live in one table (`oracle/lib/timeouts.py`) and are overridable by `--boot-timeout` only for the milestone value. Worst case for a silent runner with defaults is 3 x (90 + 5 x 300) s; `modes.yaml` carries a per-mode `job_timeout_minutes` so CI cannot run for the GitHub default of 360 minutes (`ci_runner_environment`: no job had `timeout-minutes`).

### Poweroff
`poweroff_and_wait` carried from `boot-test.py:1392-1409`: `poweroff`, expect EOF 90 s, else `poweroff -f`, expect EOF 90 s, else fail. A guest still alive at the end of the run is killed and the kill is logged and recorded in the result JSON (the predecessor swallowed errors with `except Exception: pass`, `boot-test.py:2466-2476`).

### QMP and PPM
`qmp_screendump` carried from `boot-test.py:1444-1514` (unix socket, capabilities handshake, `screendump` command, 25 s timeout). The socket path is `<screendump>.qmp.sock`; a stale socket is removed first. QMP, not HMP, so the serial mux is untouched. `read_ppm(path) -> (w, h, bytes)` and `ppm_not_black` are carried from `boot-test.py:1523-1599` with the same thresholds (channel > 16, > 0.5% of pixels). `read_ppm` is shared with O05's golden comparison.

### Result report
`--result-json` writes:
```json
{"mode":"bios","iso_sha256":"...","kernel_version":"...","qemu":"QEMU emulator version ...","ok":true,
 "exit":0,"attempts":[{"n":1,"reached_init":true,"error":null,"seconds":412.3}],
 "checks":[{"name":"...","ok":true,"detail":"..."}],"timings":{"milestones":{"init_start":38.1}}}
```
Console output keeps the predecessor's `[PASS]`/`[FAIL]` lines (`boot-test.py:1378-1385`) and final `RESULT: PASS|FAIL (<mode>)`. P02 and the dashboard (P03) consume the JSON; the field names are an interface once released.

### `modes.yaml`
```yaml
modes:
  - id: bios
    runner: bios            # python registry key in oracle/modes/
    status: planned         # planned | implemented
    node: O02
    boot: {firmware: bios, loader: isolinux, label: "serial"}
    ram_mb: 64
    legs: [{name: bios-64, ram_mb: 64}, {name: bios-256, ram_mb: 256}]
    needs: []               # ovmf | mkfs.ext4 | fixture-http | qmp
    job_timeout_minutes: 15
```
One entry per mode with the RAM defaults of `boot-test.py:2343-2362`. `oracle/bin/modes-table` renders a Markdown table (mode, what it proves, firmware, RAM, node). `tests/fast` asserts that the README block between the markers equals the render, and that the ids equal exactly the 17 in SPEC §7. This resolves the "README lists 8 of 17" contradiction.

### Fake QEMU and fixtures
`oracle/tests/fakeqemu.py` is an executable that takes `--transcript FILE` and emits its content to stdout with optional `@@wait <pattern>` and `@@send <text>` directives, so a replay can answer the harness's `echo` markers. It stands in for `--qemu-i386` / `--qemu-x86_64`. Fixtures live in `oracle/fixtures/serial/`: `boot-ok.log`, `boot-silent.log` (no output), `boot-stall-after-init.log`, `boot-oops-after-init.log`, `boot-persist-boot2-silent.log`, `grub-menu.log`, `isolinux-prompt.log`. The first rc1 run of O02 replaces the synthetic ones with real serial logs (uploaded as run artifacts); until then they are written by hand from the strings in `interfaces.yaml`. The predecessor's logs expired (14-day retention) and are not available.

### rc1 fixtures
`oracle/fixtures/rc1.yaml` is the only description of the rc1 assets; the assets themselves are never committed (`.gitignore` covers `.cache/`).
```yaml
id: rc1
release: {repo: tuckermclean/linux-live-iso-factory, tag: v0.1.0-rc1}
assets:
  iso:  {name: "<themonolith-<version>.iso; read from the release listing>", sha256: a96006596b13cc09fa951f54aadc0b816765d783e5d0e40895d7d0945edeb27a}
  sbom: {name: bom.cdx.json, size: 271592, sha256: 3cfc322a0e105638452baa6900552769a6ad5bfbf3be190a9808ac98ca575887}
  sums: {name: SHA256SUMS, sha256: "<recorded on first fetch>"}
url: "https://github.com/tuckermclean/linux-live-iso-factory/releases/download/v0.1.0-rc1/{name}"
store: {class: build, prefix: fixtures/rc1/}
extract:                       # paths inside the ISO, from build-iso.sh:105-107
  kernel: boot/vmlinuz
  initrd: boot/initrd.img
  squashfs: rootfs.squashfs
```
`make fixtures-rc1` (target in `oracle/oracle.mk`) runs `oracle/bin/fetch-rc1`. Order of sources: the store `build` class `fixtures/rc1/<name>` first (CI; no dependence on the archived predecessor), then the release URL. A file is accepted only if its sha256 equals the pin; a mismatch deletes the download and exits 2. With `--publish` (a one-off, owner or CI with store credentials) the verified files are copied to `fixtures/rc1/` in the store, which keeps them for ever (SPEC §5). The sha256 values above come from the plan (`docs/first-attested-build.md`); the file names and the `SHA256SUMS` hash are unverified until the first fetch.

`oracle/bin/rc1-extract` writes `<out>/rootfs.squashfs`, `<out>/vmlinuz` and `<out>/initrd.img` from the ISO and unpacks the squashfs to `<out>/rootfs/` with `unsquashfs -n -no-xattrs`. It uses `xorriso -osirrox on` (or `bsdtar`; whichever the runner has, recorded in the output), refuses an ISO whose sha256 is not the pin, and exits 2 when a path is missing. O06 and S01 consume the extracted tree. Layout of the ISO is the predecessor's (`build-iso.sh:103-107`); B05 must keep the same names or update `extract:` in its own fixture file.

### Expected rc1 failures
`oracle/policy/rc1-expected.yaml`:
```yaml
version: 1
expected_failures:
  - check: "artifact:elf-interp"      # <namespace>:<check id>; namespaces: boot:<mode>/<check name>, artifact:, sbom:, gate:
    study: "D-all-static"             # study id (T-*, D-*, a gap or contradiction id) that explains the failure
    reason: "util-linux, iproute2, dhcpcd, procps, tar and gawk ship as PIE; README.md:127"
    node: O06                         # node that added the entry
```
Rules, enforced by `oracle/lib/rc1.py`:
- With `--rc1`, a failing check whose id is listed is reported as `xfail` and does not fail the run. Every other failure still fails it.
- With `--rc1`, a listed check that passes is a failure of the run ("stale expected failure: fix the entry or remove it"). The file therefore cannot rot, and it states exactly which rc1 bugs we fixed.
- Without `--rc1` (every build of this repository) the file is not read. A strict check stays strict on our builds; there is no way to turn an expectation on by accident.
- Every entry needs `check`, `study`, `reason` (15+ characters) and `node`. No wildcards, no duplicates, `study` must not be `TODO`.
The result JSON gains `"rc1": true|false` and `"xfail": [{"check":...,"study":...}]`. O02-O06 each add the entries for their own checks; O01 ships the file empty plus a synthetic fixture for its tests.

## Traps and doctrines preserved
- **T-nat-router-serial-starvation:** a multi-QEMU test stalls when the parent stops reading one child. Prevented by the ported `Guest.drain()` rule and a two-guest flood test (O01-AC-16).
- **T-boot-test-wrong-cause-clock:** debugging sessions chased the RTC when the cause was a typed ISOLINUX label. Prevented by O01-AC-12 (the harness logs the exact label sent and every attempt's evidence) and by O04's bare-`serial` rule.
- **T-gui-boot-labels:** plain `serial` gives text mode. Prevented by `interfaces.yaml` carrying label names plus O01-AC-9 (labels are appended text, verified by the ISOLINUX fixture) and O05.
- **T-nft-inet-and-readline:** bracketed-paste escapes broke anchored regexes. Prevented by O01-AC-6.
- **D-state-and-no-hidden-stderr:** no swallowed failures on the paths that decide success; every test must mean something. Prevented by O01-AC-14 (lint) and O01-AC-1 (exit codes distinguish causes). The boolean retry stays bounded and only for silent launches.
- **D-clock-origin-1970:** the sentinel lives in `interfaces.yaml`; O01-AC-10 pins it.
- **D-state-and-no-hidden-stderr (kernel-version):** O01-AC-2 closes the empty-string pass.

## Gate
- **O01-AC-1** — `oracle/boot.py` exits 0 on PASS, 1 on a check failure or a failure after `/init`, 2 on usage or environment error (missing ISO, bad `--kernel-version`, QEMU or OVMF absent, unknown mode), and 3 when the guest never reached `/init` on every attempt. *Verify:* `tests/fast/test_oracle_cli.py` drives the CLI against `fakeqemu.py` with `boot-ok.log`, `boot-silent.log`, `boot-stall-after-init.log` and asserts the four codes. *Tier:* fast.
- **O01-AC-2** — `--kernel-version` that is empty, whitespace, or fails `^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._+-]*$` exits 2 before QEMU is spawned, and `uname -r` is compared as an exact trimmed match. *Verify:* `tests/fast/test_oracle_cli.py::test_kernel_version_guard` (empty, `" "`, `"6.12"`, `"-i486"`, and a guest returning `6.12.80-i486-monolith-extra` against `6.12.80-i486-monolith`). *Tier:* fast.
- **O01-AC-3** — *Withdrawn (v0.3):* the stdlib expect engine and its reader thread are not built; the harness keeps `pexpect` (SPEC §4.3). The starvation guarantee is now O01-AC-16.
- **O01-AC-4** — *Withdrawn (v0.3):* it tested the stdlib expect engine, which is not built; `pexpect` handles timeouts, EOF and split reads. The harness's own wrapping of them is covered by O01-AC-6 and O01-AC-15.
- **O01-AC-5** — The milestone sequence is read from `oracle/interfaces.yaml`; out-of-order, missing or duplicated milestones fail with the name of the missing milestone, `toram` inserts `toram_eject` between `init_start` and `overlay_ready`, and `reached_init` is set exactly when `init_start` text is matched. *Verify:* `tests/fast/test_oracle_milestones.py` on `boot-ok.log` and a toram variant. *Tier:* fast.
- **O01-AC-6** — `run_check` strips ANSI/CSI escapes including `ESC[?2004l` and the echoed command line before validation, parses the sentinel exit code, and never raises on timeout or EOF. *Verify:* `tests/fast/test_oracle_guest.py` with an output line `\x1b[?2004l1` validated by `exact_value("1")` and by a `^1$` regex. *Tier:* fast.
- **O01-AC-7** — All validators (`contains`, `contains_with_exit`, `regex_matches`, `regex_absent`, `exit_code_only`, `exact_value`, `epoch_close_to`) are unit-tested including the failure branches; `exact_value("0")` rejects `4096`. *Verify:* `tests/fast/test_oracle_validators.py`. *Tier:* fast.
- **O01-AC-8** — `should_retry_launch` returns True only when the run failed, the failing guest never reached `/init`, and attempts remain; the matrix includes second-boot-silent after a passed first boot and client-silent after a reached-init router. *Verify:* `tests/fast/test_oracle_retry.py` (replaces `scripts/tests/boot-test-retry.test.sh`; all 6 original cases kept) and an end-to-end run with `boot-persist-boot2-silent.log` asserting three attempts then exit 3. *Tier:* fast.
- **O01-AC-9** — `select_isolinux_label` waits for `boot:` (90 s), logs a warning and sends blindly on timeout, and sends the label text including appended parameters; `select_grub_serial_entry` waits for `(serial)` (180 s), sends `serial_entry_index` Down presses and CR, taking both the index and the marker from `interfaces.yaml`. *Verify:* `tests/fast/test_oracle_bootloader.py` with `isolinux-prompt.log` and `grub-menu.log`, asserting the exact bytes written to the fake QEMU's stdin. *Tier:* fast.
- **O01-AC-10** — `oracle/interfaces.yaml` carries the six milestone strings, ISOLINUX prompt, GRUB entry order and index 2, and the clock sentinels `1970-01-01T00:00:00` (origin) and `1996-06-15T12:00:00`; a test fails if the origin sentinel is anything but the Unix epoch. *Verify:* `tests/fast/test_oracle_interfaces.py`. *Tier:* fast.
- **O01-AC-11** — `qmp_screendump` completes the QMP handshake and `screendump`, and fails with a clear error on missing socket, bad greeting or timeout; `read_ppm`/`ppm_not_black` accept P6 with comments, reject truncated, non-P6 and zero-dimension files, and apply the 16/0.5% thresholds. *Verify:* `tests/fast/test_oracle_qmp_ppm.py` using a fake QMP server on a temp unix socket and synthetic PPMs. *Tier:* fast.
- **O01-AC-12** — `--result-json` is written on PASS and on every failure class with the schema in Design (mode, iso sha256, kernel version, QEMU version string, attempts, checks, milestone timings), and the console log records the exact bootloader label or keys sent. *Verify:* `tests/fast/test_oracle_report.py` validates the JSON against `oracle/schemas/result.schema.json` (owned here). *Tier:* fast.
- **O01-AC-13** — `oracle/modes.yaml` validates against its schema, contains the 17 inherited mode ids of SPEC §7 with RAM defaults equal to `boot-test.py:2343-2362`, and every other entry carries a `node:` field naming the G node that added it, has a `job_timeout_minutes` for every mode, and the README block between `<!-- oracle-modes:begin -->` and `<!-- oracle-modes:end -->` equals `oracle/bin/modes-table` output. *Verify:* `tests/fast/test_oracle_modes.py`. *Tier:* fast.
- **O01-AC-14** — `oracle/` contains no `2>/dev/null`, no bare `except:` and no `except Exception: pass` without a logged reason, and imports only the standard library, `yaml` and `pexpect`. *Verify:* `tests/fast/test_oracle_lint.py` (AST scan for imports and exception handlers, grep for `2>/dev/null`). *Tier:* fast.
- **O01-AC-15** — `poweroff_and_wait` falls back to `poweroff -f` after 90 s and fails after a further 90 s; a guest left alive at the end of a run is killed and the kill appears in the result JSON. *Verify:* `tests/fast/test_oracle_poweroff.py` with a fake guest that ignores `poweroff`. *Tier:* fast.
- **O01-AC-16** — With two fake guests, one flooding 2 MB of output while the test drives the other for 30 checks, the test calls `Guest.drain()` on the idle guest between steps, both transcripts are complete and in order, and a variant that never drains stalls (negative control). *Verify:* `tests/fast/test_oracle_drain.py::test_two_guest_flood`, `::test_no_drain_stalls`. *Tier:* fast.
- **O01-AC-17** — `oracle/requirements.txt` pins `pexpect` and `ptyprocess` with `==` and `--hash=sha256:` lines; no workflow or script under `oracle/` runs an unpinned `pip install`. *Verify:* `tests/fast/test_oracle_requirements.py` (parse the file; grep workflows and `oracle/` for `pip install` without `--require-hashes`). *Tier:* fast.
- **O01-AC-18** — `oracle/fixtures/rc1.yaml` validates against its schema, carries the rc1 ISO sha256 `a96006596b13cc09fa951f54aadc0b816765d783e5d0e40895d7d0945edeb27a` and SBOM sha256 `3cfc322a0e105638452baa6900552769a6ad5bfbf3be190a9808ac98ca575887`, and no rc1 ISO, squashfs or SBOM file is tracked by git or allowed past `.gitignore`. *Verify:* `tests/fast/test_oracle_rc1_fixtures.py::test_pins`, `::test_nothing_committed` (`git ls-files` scan for files over 1 MB under `oracle/fixtures/` and for `*.iso`, `*.squashfs`). *Tier:* fast.
- **O01-AC-19** — `oracle/bin/fetch-rc1` takes a file from the store path first, then the release URL; accepts it only when its sha256 equals the pin; on a mismatch, a short read or a missing file deletes the partial download and exits 2 without leaving a usable file. *Verify:* `tests/fast/test_oracle_rc1_fixtures.py::test_fetch_verifies` (local `file://` URLs and a fake store directory; correct, wrong-hash, truncated, missing). *Tier:* fast.
- **O01-AC-20** — On a CI runner, `make fixtures-rc1` fetches the real rc1 ISO and SBOM by digest, `--publish` places them in the store `build` class under `fixtures/rc1/`, and a second run restores them from the store without contacting GitHub. *Verify:* CI job `oracle-fixtures` (run once, then on every oracle job through its cache step); log shows the store path was used. *Tier:* slow.
- **O01-AC-21** — `oracle/bin/rc1-extract` refuses an ISO with the wrong sha256, extracts `rootfs.squashfs`, `vmlinuz` and `initrd.img` and unpacks the squashfs, and exits 2 when any of the three paths is absent. *Verify:* `tests/fast/test_oracle_rc1_fixtures.py::test_extract` (a tiny ISO built with `xorriso` in the test if present, else a stub; skipped tests are reported as skipped and counted by the lint) and, on rc1 itself, CI job `oracle-fixtures`. *Tier:* fast (stub), slow (real ISO).
- **O01-AC-22** — With `--rc1`, a failing check listed in `oracle/policy/rc1-expected.yaml` is reported `xfail` and does not fail the run, an unlisted failure fails it, and a listed check that passes fails the run as stale; without `--rc1` the file is not read and the same failure fails. *Verify:* `tests/fast/test_oracle_rc1_expected.py` (synthetic file and results: listed-fails, unlisted-fails, listed-passes, no-flag). *Tier:* fast.
- **O01-AC-23** — `boot_to_shell` sends the throwaway warmup check after the shell is ready for every mode and every guest, including the persist second boot and the NAT client; the shell-ready marker and the warmup are separate steps in the transcript. *Verify:* `tests/fast/test_oracle_guest.py::test_warmup_every_guest` (replay `boot-ok.log`; assert the bytes written for the first, a second and a third guest). *Tier:* fast.
- **O01-AC-24** — Every `oracle/policy/rc1-expected.yaml` entry has `check`, `study`, `reason` of 15+ characters and `node`; wildcards, duplicates and `study: TODO` are rejected. *Verify:* `tests/fast/test_oracle_rc1_expected.py::test_schema`. *Tier:* fast.

## RED plan
The tester writes, in this order, each as its own commit with `TDD-Red-Target: make test-fast`: `test_oracle_retry.py` (imports `oracle.lib.retry`, absent, so it fails on ImportError; first it ports the 6 old cases plus the new matrix), `test_oracle_drain.py` (fails: `Guest.drain` absent), `test_oracle_guest.py` (the escape-strip and warmup cases), `test_oracle_cli.py` (exit-code and kernel-version cases fail because `oracle/boot.py` does not exist), `test_oracle_modes.py` and `test_oracle_interfaces.py` (files absent), `test_oracle_rc1_expected.py` and `test_oracle_rc1_fixtures.py` (files and scripts absent), `test_oracle_requirements.py` (file absent), `test_oracle_lint.py` (fails first on any stub that uses `except Exception: pass`). Fixtures are committed with the RED commit; `fakeqemu.py` is part of the RED commit because tests cannot run without it, with its own self-test.

## Risks and open questions
- Hardest: none of the code is new, so the risk is the port itself. Slicing 600 lines out of a 2,528-line script can drop a helper that a later mode needs. Mitigation: the carried line ranges are listed; O02 runs the whole bios mode on rc1 in its first slice.
- The rc1 asset names and the `SHA256SUMS` hash are unverified until the first fetch. The ISO layout (`boot/vmlinuz`, `boot/initrd.img`, `rootfs.squashfs`) is read from `build-iso.sh:105-107`, not from the rc1 ISO itself; `rc1-extract` fails loudly if it differs.
- The rc1 assets live on a repository that will be archived (X01). The store copy under `fixtures/rc1/` is the durable one; take it before anything else (AC-20).
- `oracle/oracle.mk` needs one include line in the top-level Makefile, which F01 owns. If F01's Makefile does not include `oracle/*.mk`, the target is added there in this node's PR.
- Real serial transcripts do not exist until O02 runs on rc1; synthetic fixtures may encode the wrong CR/LF behaviour (QEMU serial emits `\r\n`). Replace on that run.
- The 3-attempt relaunch can hide a genuine intermittent early-boot kernel hang. The result JSON records every attempt so P03/M01 can alarm on a rising retry rate. A policy of "any attempt > 1 is annotated in the job summary" is part of O02.
- ISOLINUX/GRUB navigation depends on SeaBIOS VGA-text mirroring to serial and on the GRUB menu order. G02 widens this; the interface file is the contract.
- `pexpect` version: 4.9.0 is the likely pin and unverified; check that it works with the runner's Python (3.12 on ubuntu-24.04) before writing the hashes.

## Cost
Three agent slices: (1) interfaces, modes.yaml, fake QEMU, guest protocol, validators, milestones, bootloader; (2) retry, drain, report, QMP/PPM, CLI, lint, README table; (3) rc1 fixtures: `rc1.yaml`, fetch, extract, expected-failure loader, store publish. Fast tier only except AC-20 (one short CI job; the rc1 ISO download time is unmeasured). Boot-test cost context, measured on the predecessor: 17 modes take about 10 min wall in parallel, `nic-models` 9.1 min and the others 1-2 min each; this node adds no boots. Store: the rc1 ISO and SBOM are kept for ever in the `build` class. No recurring cost.

## Spec defects found
- None blocking. SPEC §4.3 (pexpect) and the B03/B05 edges to O01 are fixed in v0.3. Minor: SPEC §4.2 does not say which node owns `.gitignore` or Makefile includes; this node adds `oracle/oracle.mk` and expects F01 to include it.

