# O01 — boot-harness

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| O | F01 | B03, B05, O02 | — | L |

**Owns:** `oracle/boot.py` (CLI entry), `oracle/lib/` (`expect.py`, `guest.py`, `milestones.py`, `bootloader.py`, `qemu.py`, `retry.py`, `qmp.py`, `ppm.py`, `report.py`, `fixture_http.py`, `modes.py` registry), `oracle/interfaces.yaml`, `oracle/modes.yaml` (schema, validator, all 17 entries), `oracle/tests/fakeqemu.py`, `oracle/fixtures/serial/*.log`, `oracle/fixtures/argv/` (golden-argv mechanism), `tests/fast/test_oracle_*.py` (harness subjects), the generated mode table block in `README.md` between `<!-- oracle-modes:begin/end -->` markers.
**Carries from linux-live-iso-factory@b9f533b:** `scripts/boot-test.py` (2,528 lines; core only: lines 135-190, 732-882, 883-950, 1378-1442, 1444-1600, 2364-2528), `scripts/tests/boot-test-retry.test.sh`.
**Study refs:** oracle.yaml `harness.*`, `common.*`, gaps "boot-test.py has no unit tests besides should_retry_launch", "serial warmup race" open question, contradictions on stale docstrings (boot-test.py:5-14, 36-42, 100-102, 144-148), `ci.boot-test.expected-kernel` (no empty guard), `ci_runner_environment` (unpinned `pip install pexpect`, no job timeouts); T-nat-router-serial-starvation, T-boot-test-wrong-cause-clock, T-gui-boot-labels, T-nft-inet-and-readline, D-state-and-no-hidden-stderr, D-clock-origin-1970; SPEC §4.3, §7.

## Purpose
After this node a QEMU-driven boot test is a library plus a CLI, with every piece that can be tested without a VM covered by fast tests on recorded serial transcripts. The predecessor's harness was one 2,528-line script with a single unit test; a regression in the retry rule, the sentinel protocol or the PPM parser surfaced only in a 30–60 minute CI cycle. This node also fixes the structural weaknesses the study found: a retry rule that ignores second boots and the NAT client, a serial warmup wired into two modes, a manual router drain, and an unguarded `--kernel-version`.

## Scope
In:
- QEMU launch, serial console engine, milestone expectation, bootloader navigation (ISOLINUX prompt, GRUB serial entry), shell readiness, guest command protocol and validators, poweroff, QMP screendump client, PPM reader, result report, retry discriminator, timeouts, exit codes.
- `oracle/interfaces.yaml`: the single file naming serial milestones, ISOLINUX labels, GRUB entry order and clock sentinels.
- `oracle/modes.yaml`: schema, validator and an entry for each of the 17 modes (a `status` field says which are implemented).
- The fake-QEMU replay tool and recorded fixtures that let the whole harness run in the fast tier.
Out:
- Any per-mode runner, QEMU argv profile or assertion set: O02 (bios, uefi, toram, ahci, nvme, usb, virtio, nicless), O03 (nic, vga, fbdev-modprobe), O04 (nat, persist, clock-epoch, clock-1996), O05 (gui, stele-acid2).
- The reusable CI workflow, job matrix and runner setup: O02.
- The ISO's bootloader config and init script that emit the interface strings: B03 (init), B05 (ISOLINUX/GRUB). They must conform to `oracle/interfaces.yaml`; their gates reference it.
- Artifact doctrine checks: O06. SBOM diff: O07.

## Design

### Language and dependencies
Python 3, standard library plus PyYAML (SPEC §4.3). `pexpect` is not stdlib. The harness implements its own expect engine on `pty` and `selectors` (about 150 lines). Rejected: pinning `pexpect` (a third dependency, the predecessor installed it unpinned at `boot-test.yml` setup steps, and its pty reads are the thing T-nat-router-serial-starvation hit). See Spec defects: SPEC §4.3 does not name pexpect either way.

### Layout
```
oracle/boot.py                 CLI. `python3 oracle/boot.py --mode <id> --iso <path> --kernel-version <str> [flags]`
oracle/interfaces.yaml         milestones, bootloader strings, clock sentinels (single source)
oracle/modes.yaml              one entry per mode (see below)
oracle/lib/expect.py           Spawn, expect_exact, expect_regex, send, drain thread
oracle/lib/guest.py            Guest (spawn + reached_init + log), wait_for_shell, run_check, capture, validators
oracle/lib/milestones.py       expect_boot_sequence(guest, variant)
oracle/lib/bootloader.py       select_isolinux_label, select_grub_serial_entry
oracle/lib/qemu.py             argv builder base (common flags), binary/OVMF discovery
oracle/lib/retry.py            should_retry_launch, run_with_retry
oracle/lib/qmp.py              qmp_screendump(sock, out_ppm)
oracle/lib/ppm.py              read_ppm, ppm_not_black (golden comparison is O05)
oracle/lib/report.py           Check results, console report, result JSON
oracle/lib/fixture_http.py     in-process HTTP fixture server used by O04 (nat, clock-epoch)
oracle/lib/modes.py            registry: @register("bios") on a runner + argv builder
oracle/tests/fakeqemu.py       replays a transcript on its stdout, honours stdin triggers
```

### CLI
Flags carried from `boot-test.py:2364-2420`: `--iso` (required), `--mode` (required, choices come from the registry), `--kernel-version` (required), `--ram-mb` (default from `modes.yaml`), `--qemu-i386`, `--qemu-x86_64`, `--ovmf-code` (auto-detect list as `boot-test.py:153-158`, now also reads `OVMF_CODE` env), `--boot-timeout` (default 300), `--cdrom-monitor-id` (default `ide1-cd0`), `--log-file`, `--nic-model`, `--vga-model`, `--gui-screendump`, `--rtc-date`, `--persist-disk`. New: `--max-attempts` (default 3), `--result-json PATH`, `--golden-dir PATH` (O05), `--list-modes` (prints `modes.yaml` ids, exit 0).

Exit codes. 0 PASS. 1 FAIL (a check failed, or the guest failed after reaching `/init`). 2 usage or environment error (ISO missing, empty or malformed `--kernel-version`, QEMU or OVMF not found, unknown mode). 3 INFRA: the guest never reached `/init` on every attempt (silent launch; CI should mark the job as infrastructure-suspect). The predecessor mapped case 3 to exit 1 (`boot-test.py:2519-2523`); the split costs nothing and lets `result.json` distinguish them. Rejected: keep 0/1/2 (CI could not tell a dead runner from a dead ISO).

### `--kernel-version` guard
The value must match `^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._+-]*$`. Empty, whitespace or a bare `-`-suffix exits 2 before QEMU starts. The `uname -r` check (`smoke_kernel_version`, `boot-test.py:953`) becomes an exact match of the trimmed last output line, not a substring (`contains`, `boot-test.py:883`). Rejected: keep substring (an empty expected string always passed, `ci.boot-test.expected-kernel` open question).

### Expect engine
`Spawn(argv)` forks the child on a pty, and a daemon reader thread appends every byte to an in-memory buffer and to the log file at all times. `expect_exact(text, timeout)` and `expect(regex, timeout)` scan the buffer from a cursor; they return the text before the match. `send`/`sendline` write to the pty. EOF and timeout raise `ExpectTimeout` / `ExpectEOF` (subclasses of `HarnessError`). Because the reader thread never stops, a second guest can be driven while the first sits idle: the manual `drain_router()` of `boot-test.py:2083` disappears and T-nat-router-serial-starvation cannot recur by construction. Rejected: nonblocking reads on demand (the cause of that trap).

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
`expect_boot_sequence(guest, variant)` expects the milestones in order, each with `--boot-timeout`, and sets `guest.reached_init = True` the moment `init_start` is seen, comparing the matched `text` (not a description, `boot-test.py:806-807`). `wait_for_shell` is carried verbatim (`boot-test.py:810-841`): send an empty line to wake `monolith-console`, then loop `echo MONOLITH_SHELL_READY_<hex>` with a 3 s expect, 60 s total. New: `boot_to_shell(guest, bootloader_step)` always ends with the throwaway `true` warmup check (`boot-test.py:2030-2035`) for every mode and every guest, not only fbdev-modprobe and nat. Rejected: warmup in two modes only (the study could not tell whether bios/uefi were exposed to the race; it costs one command).

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
    job_timeout_minutes: 45
```
One entry per mode with the RAM defaults of `boot-test.py:2343-2362`. `oracle/bin/modes-table` renders a Markdown table (mode, what it proves, firmware, RAM, node). `tests/fast` asserts that the README block between the markers equals the render, and that the ids equal exactly the 17 in SPEC §7. This resolves the "README lists 8 of 17" contradiction.

### Fake QEMU and fixtures
`oracle/tests/fakeqemu.py` is an executable that takes `--transcript FILE` and emits its content to stdout with optional `@@wait <pattern>` and `@@send <text>` directives, so a replay can answer the harness's `echo` markers. It stands in for `--qemu-i386` / `--qemu-x86_64`. Fixtures live in `oracle/fixtures/serial/`: `boot-ok.log`, `boot-silent.log` (no output), `boot-stall-after-init.log`, `boot-oops-after-init.log`, `boot-persist-boot2-silent.log`, `grub-menu.log`, `isolinux-prompt.log`. The first CI run of O02 replaces the synthetic ones with real serial logs (uploaded as run artifacts); until then they are written by hand from the strings in `interfaces.yaml`. The predecessor's logs expired (14-day retention) and are not available.

## Traps and doctrines preserved
- **T-nat-router-serial-starvation:** a multi-QEMU test stalls when the parent stops reading one child. Prevented by the always-on reader thread (O01-AC-3) and a two-guest flood test.
- **T-boot-test-wrong-cause-clock:** debugging sessions chased the RTC when the cause was a typed ISOLINUX label. Prevented by O01-AC-12 (the harness logs the exact label sent and every attempt's evidence) and by O04's bare-`serial` rule.
- **T-gui-boot-labels:** plain `serial` gives text mode. Prevented by `interfaces.yaml` carrying label names plus O01-AC-9 (labels are appended text, verified by the ISOLINUX fixture) and O05.
- **T-nft-inet-and-readline:** bracketed-paste escapes broke anchored regexes. Prevented by O01-AC-6.
- **D-state-and-no-hidden-stderr:** no swallowed failures on the paths that decide success; every test must mean something. Prevented by O01-AC-14 (lint) and O01-AC-1 (exit codes distinguish causes). The boolean retry stays bounded and only for silent launches.
- **D-clock-origin-1970:** the sentinel lives in `interfaces.yaml`; O01-AC-10 pins it.
- **D-state-and-no-hidden-stderr (kernel-version):** O01-AC-2 closes the empty-string pass.

## Gate
- **O01-AC-1** — `oracle/boot.py` exits 0 on PASS, 1 on a check failure or a failure after `/init`, 2 on usage or environment error (missing ISO, bad `--kernel-version`, QEMU or OVMF absent, unknown mode), and 3 when the guest never reached `/init` on every attempt. *Verify:* `tests/fast/test_oracle_cli.py` drives the CLI against `fakeqemu.py` with `boot-ok.log`, `boot-silent.log`, `boot-stall-after-init.log` and asserts the four codes. *Tier:* fast.
- **O01-AC-2** — `--kernel-version` that is empty, whitespace, or fails `^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._+-]*$` exits 2 before QEMU is spawned, and `uname -r` is compared as an exact trimmed match. *Verify:* `tests/fast/test_oracle_cli.py::test_kernel_version_guard` (empty, `" "`, `"6.12"`, `"-i486"`, and a guest returning `6.12.80-i486-monolith-extra` against `6.12.80-i486-monolith`). *Tier:* fast.
- **O01-AC-3** — The expect engine has a reader thread that drains the pty continuously: with two fake guests, one flooding output while the test drives the other for 5 s, the second guest's expectations succeed and the flooded guest's full output is retained in order. *Verify:* `tests/fast/test_oracle_expect.py::test_two_guest_flood`. *Tier:* fast.
- **O01-AC-4** — `expect_exact`/`expect` honour timeouts and EOF with distinct exceptions and do not lose bytes split across reads (a marker split over three writes still matches). *Verify:* `tests/fast/test_oracle_expect.py`. *Tier:* fast.
- **O01-AC-5** — The milestone sequence is read from `oracle/interfaces.yaml`; out-of-order, missing or duplicated milestones fail with the name of the missing milestone, `toram` inserts `toram_eject` between `init_start` and `overlay_ready`, and `reached_init` is set exactly when `init_start` text is matched. *Verify:* `tests/fast/test_oracle_milestones.py` on `boot-ok.log` and a toram variant. *Tier:* fast.
- **O01-AC-6** — `run_check` strips ANSI/CSI escapes including `ESC[?2004l` and the echoed command line before validation, parses the sentinel exit code, and never raises on timeout or EOF. *Verify:* `tests/fast/test_oracle_guest.py` with an output line `\x1b[?2004l1` validated by `exact_value("1")` and by a `^1$` regex. *Tier:* fast.
- **O01-AC-7** — All validators (`contains`, `contains_with_exit`, `regex_matches`, `regex_absent`, `exit_code_only`, `exact_value`, `epoch_close_to`) are unit-tested including the failure branches; `exact_value("0")` rejects `4096`. *Verify:* `tests/fast/test_oracle_validators.py`. *Tier:* fast.
- **O01-AC-8** — `should_retry_launch` returns True only when the run failed, the failing guest never reached `/init`, and attempts remain; the matrix includes second-boot-silent after a passed first boot and client-silent after a reached-init router. *Verify:* `tests/fast/test_oracle_retry.py` (replaces `scripts/tests/boot-test-retry.test.sh`; all 6 original cases kept) and an end-to-end run with `boot-persist-boot2-silent.log` asserting three attempts then exit 3. *Tier:* fast.
- **O01-AC-9** — `select_isolinux_label` waits for `boot:` (90 s), logs a warning and sends blindly on timeout, and sends the label text including appended parameters; `select_grub_serial_entry` waits for `(serial)` (180 s), sends `serial_entry_index` Down presses and CR, taking both the index and the marker from `interfaces.yaml`. *Verify:* `tests/fast/test_oracle_bootloader.py` with `isolinux-prompt.log` and `grub-menu.log`, asserting the exact bytes written to the fake QEMU's stdin. *Tier:* fast.
- **O01-AC-10** — `oracle/interfaces.yaml` carries the six milestone strings, ISOLINUX prompt, GRUB entry order and index 2, and the clock sentinels `1970-01-01T00:00:00` (origin) and `1996-06-15T12:00:00`; a test fails if the origin sentinel is anything but the Unix epoch. *Verify:* `tests/fast/test_oracle_interfaces.py`. *Tier:* fast.
- **O01-AC-11** — `qmp_screendump` completes the QMP handshake and `screendump`, and fails with a clear error on missing socket, bad greeting or timeout; `read_ppm`/`ppm_not_black` accept P6 with comments, reject truncated, non-P6 and zero-dimension files, and apply the 16/0.5% thresholds. *Verify:* `tests/fast/test_oracle_qmp_ppm.py` using a fake QMP server on a temp unix socket and synthetic PPMs. *Tier:* fast.
- **O01-AC-12** — `--result-json` is written on PASS and on every failure class with the schema in Design (mode, iso sha256, kernel version, QEMU version string, attempts, checks, milestone timings), and the console log records the exact bootloader label or keys sent. *Verify:* `tests/fast/test_oracle_report.py` validates the JSON against `oracle/schemas/result.schema.json` (owned here). *Tier:* fast.
- **O01-AC-13** — `oracle/modes.yaml` validates against its schema, contains the 17 inherited mode ids of SPEC §7 with RAM defaults equal to `boot-test.py:2343-2362`, and every other entry carries a `node:` field naming the G node that added it, has a `job_timeout_minutes` for every mode, and the README block between `<!-- oracle-modes:begin -->` and `<!-- oracle-modes:end -->` equals `oracle/bin/modes-table` output. *Verify:* `tests/fast/test_oracle_modes.py`. *Tier:* fast.
- **O01-AC-14** — `oracle/` contains no `2>/dev/null`, no bare `except:` and no `except Exception: pass` without a logged reason, and imports only the standard library and `yaml`. *Verify:* `tests/fast/test_oracle_lint.py` (AST scan for imports and exception handlers, grep for `2>/dev/null`). *Tier:* fast.
- **O01-AC-15** — `poweroff_and_wait` falls back to `poweroff -f` after 90 s and fails after a further 90 s; a guest left alive at the end of a run is killed and the kill appears in the result JSON. *Verify:* `tests/fast/test_oracle_poweroff.py` with a fake guest that ignores `poweroff`. *Tier:* fast.

## RED plan
The tester writes, in this order, each as its own commit with `TDD-Red-Target: make test-fast`: `test_oracle_retry.py` (imports `oracle.lib.retry`, absent, so it fails on ImportError; first it ports the 6 old cases plus the new matrix), `test_oracle_expect.py` (reader-thread flood test fails with any on-demand reader), `test_oracle_guest.py` (the escape-strip case), `test_oracle_cli.py` (exit-code and kernel-version cases fail because `oracle/boot.py` does not exist), `test_oracle_modes.py` and `test_oracle_interfaces.py` (files absent), `test_oracle_lint.py` (fails first on any stub that uses `except Exception: pass`). Fixtures are committed with the RED commit; `fakeqemu.py` is part of the RED commit because tests cannot run without it, with its own self-test.

## Risks and open questions
- Hardest: the stdlib expect engine must reproduce pexpect semantics the old modes rely on (`child.before` after a regex match, `match.group`, `expect(EOF)` with a closed pty, `read_nonblocking`). Missing a semantic shows up only in a real boot. Mitigation: O02's first CI cycle runs the whole bios mode; keep a one-line fallback to pinned `pexpect` behind the same `Spawn` interface if the engine proves unreliable.
- Spec question: SPEC §4.3 forbids third-party Python except PyYAML. If the owner prefers pexpect, amend §4.3 and I05 pins it; the engine is then a thin wrapper.
- Real serial transcripts do not exist until O02 runs; synthetic fixtures may encode the wrong CR/LF behaviour (QEMU serial emits `\r\n`). Replace on first CI.
- The 3-attempt relaunch can hide a genuine intermittent early-boot kernel hang. The result JSON records every attempt so P03/M01 can alarm on a rising retry rate. A policy of "any attempt > 1 is annotated in the job summary" is part of O02.
- ISOLINUX/GRUB navigation depends on SeaBIOS VGA-text mirroring to serial and on the GRUB menu order. G02 widens this; the interface file is the contract.
- Unknown: wall-clock per mode on GitHub-hosted TCG runners (`oracle.yaml` open question). Per-mode `job_timeout_minutes` defaults are guesses (see O02).

## Cost
Three to four agent slices: (1) interfaces, modes.yaml, expect engine, fake QEMU; (2) guest protocol, validators, milestones, bootloader; (3) retry, report, QMP/PPM, CLI; (4) lint, README table, fixtures. No CI build cycles are needed to pass this gate (fast tier only). No recurring cost.

## Spec defects found
- SPEC §4.3 / §7 do not say how the harness gets a pty expect engine; the predecessor used non-stdlib `pexpect`. Proposed: stdlib engine (this node), or amend §4.3.
- graph.yaml: O01 is listed to unlock only O02, but `oracle/interfaces.yaml` is also consumed by B03 (init milestones) and B05 (labels, GRUB order). Add edges B03 -> O01 and B05 -> O01 (no cycle: O01 depends only on F01), so their gates can parse `oracle/interfaces.yaml`.
