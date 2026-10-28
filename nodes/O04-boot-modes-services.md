# O04 — boot-modes-services

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| O | O02 | S05, P02, G01, G04 | MS3 | L |

**Owns:** `oracle/modes/{nat,persist,clock_epoch,clock_1996}.py`, `oracle/lib/http_date_stub.py`, `oracle/lib/persist_disk.py`, `oracle/fixtures/argv/{nat-router,nat-client,persist,clock-epoch,clock-1996}.txt`, `oracle/fixtures/serial/` transcripts for these modes, matrix legs for these modes in `oracle/modes.yaml`.
**Carries from linux-live-iso-factory@b9f533b:** `scripts/boot-test.py` lines 463-631 (clock), 635-668 (nat argv), 670-730 (persist argv), 2038-2183 (nat), 2185-2300 (persist), `.github/workflows/boot-test.yml` jobs `nat-router` (:714-769), `clock-epoch` (:771-822), `clock-1996` (:824-874), `persist` (:876-); unit tests `scripts/tests/monolith-time.test.sh`, `monolith-time-check.test.sh` are recipe tests (R01/R05) and stay fast-tier there.
**Study refs:** oracle.yaml `bootmode.nat|persist|clock-epoch|clock-1996`, contradictions (boot-test.py:36-42 docstring vs `run_clock_epoch`; boot-test.yml:796-805 dead http.server step and step name "RTC at epoch + fixture server"; unused `epoch_close_to`), gaps (clock fetch-and-set never exercised in QEMU; persist boot 2 outside launch-flake discriminator; nat client outside discriminator; no test of the login hint 30-clock-hint.sh); T-nat-router-serial-starvation, T-router-link-local, T-nft-inet-and-readline, T-dnsmasq-build-and-dhcpcd-hostname, T-boot-test-wrong-cause-clock, T-persist-race, T-console-home, T-isolinux-timeout; D-clock-origin-1970, D-state-and-no-hidden-stderr.

## Purpose
After this node the disc's services are proved end to end under QEMU: a two-guest NAT/DHCP/DNS router with a negative control, persistence across an unclean power-off, and the clock-honesty behaviour in both directions. The clock-epoch mode finally tests what its docstring promised (a dead clock is judged ignorant and then corrected from a time source) while keeping the myth's origin sentinel at 1970-01-01. The harness-level retry now covers the second persist boot and the NAT client.

## Scope
In:
- `nat`, `persist`, `clock-epoch`, `clock-1996` with every assertion of the predecessor.
- The in-harness fixtures that replace the CI-job `http.server` steps.
- Additional clock legs for the 1980 and 2000 BIOS-reset sentinels.
Out:
- Harness engine, retry rule, `Guest` objects, `fixture_http.py`: O01.
- CI workflow and matrix plumbing: O02.
- The scripts under test (`monolith-router`, `monolith-time`, `monolith-time-check`, `monolith-persist`, `50-persist-history.bash`, `30-clock-hint.sh`) and their unit tests: R01/R05. Unit tests for `30-clock-hint.sh` and `40-advisory.sh` do not exist (oracle.yaml gap); not in this node.
- Persistence on a real disk created by `monolith-persist init`, the GRUB persistent entry, swap: G01.
- SLIP/PPP/dropbear: G04.

## Design

### clock-epoch (made to match its intent)
Predecessor reality: NIC removed (`-nic none`), asserts only that `/run/monolith-clock-ignorant` exists and `date +%Y` contains `1970` (`boot-test.py:543-585`). The docstring (`:36-42`) and the CI step name promise correction from a fixture server; that server was unreachable and the job started it for nothing. The correction half was covered only by a stubbed unit test (`oracle.yaml`: "fetch-and-set never exercised under QEMU").

Why a typed `monolith_time_url=` is not the answer: the predecessor's trap T-boot-test-wrong-cause-clock blamed the 1970 RTC when the real cause was a long label containing `://` typed at the ISOLINUX prompt (`doctrine.yaml` T-isolinux-timeout: "long APPEND labels containing '://' hang ISOLINUX"). The label for every clock leg stays the bare `serial`. Rejected: any URL in the boot label.

New design, one boot:
1. QEMU: `build_bios_cmd` argv (qemu-system-i386, `-cpu 486`, 64 MB) plus `-rtc base=1970-01-01T00:00:00` and `-netdev user,id=n0,restrict=on,guestfwd=tcp:10.0.2.100:8000-cmd:python3 -I <repo>/oracle/lib/http_date_stub.py 1788264000 -device e1000,netdev=n0`. `restrict=on` isolates the guest from the host and the internet; the guest still gets DHCP and reaches only the forwarded address. `http_date_stub.py` speaks HTTP/1.0 on stdin/stdout: it reads the request headers up to the blank line and replies `200 OK` with `Date: Tue, 01 Sep 2026 12:00:00 GMT` (epoch 1788264000), `Content-Length: 0`, `Connection: close`. QEMU's `guestfwd ... cmd:` runs it per connection over a socketpair. It needs no port, no thread and no CI step. Rejected: a host `http.server` on 8000 (needs a port and a CI step, and reached only through unrestricted SLIRP, which also lets the boot-time hook reach the real internet and race the test).
2. Boot with the bare `serial` label to the shell (all five milestones). The S45 boot hook has already run against the default URL (`http://example.com/`, `monolith-time:` `DEFAULT_URL`), failed because the guest is restricted, and written the flag.
3. Assert (detection, carried): `test -e /run/monolith-clock-ignorant` exits 0; `date +%Y` contains `1970` (no phantom correction without a source).
4. Assert (correction, new): run `MONOLITH_TIME_URL=http://10.0.2.100:8000/ monolith-time-check; echo rc=$?` (a caller-supplied variable wins over the command line, `monolith-time-check` comments). Expect `rc=0`; `date +%Y` contains `2026`; `date +%s` within 300 s of `1788264000` using `epoch_close_to` (live in O01, no longer dead code). This runs the real `monolith-time-check`, `monolith-time`, `curl -sI`, `date -s` and `hwclock -w` (if present) in the real guest.
5. Poweroff.

Not covered, stated plainly: the boot-time hook succeeding with a reachable source in the same boot (a kernel `monolith_time_url=` cannot be set on the ISOLINUX line; the parsing of `monolith_time_url=` is covered by the recipe unit test `monolith-time-check.test.sh`). Also `monolith-time-check` does not remove an existing flag after a later success, which contradicts the predecessor docstring's "ignorance flag clears" (`boot-test.py:36-42`). The mode does not assert flag clearing. See Risks.

`guestfwd=...-cmd:` is documented QEMU user-net behaviour but its `cmd:` form must be verified on the runner's QEMU. Fallback if it misbehaves: `guestfwd=tcp:10.0.2.100:8000-chardev:<id>` with a unix-socket chardev served by `fixture_http.py`; the assertions are unchanged. Both forms keep `restrict=on`.

Sentinel legs: the mode takes `--rtc-date`; the default is `interfaces.yaml: clock.epoch_rtc` (`1970-01-01T00:00:00`). Two added legs set `1980-01-01T00:00:00` and `2000-01-01T00:00:00` (the other two sentinels of `monolith-time-check`, `SENTINELS="0 315532800 946684800"`) and run steps 1-3 and 4; step 3 asserts the year `1980` / `2000` instead of `1970`. D-clock-origin-1970 is unchanged: the default leg and the name `clock-epoch` stay on the Unix epoch, never Y2K.

### clock-1996 (negative control)
`build_bios_cmd` argv plus `-rtc base=1996-06-15T12:00:00` and the same restricted NIC without any `guestfwd`. Assertions carried: `date +%Y` contains `1996`; `test ! -e /run/monolith-clock-ignorant`. New: `date +%s` within 3600 s of the RTC base (803217600), so a stomp toward any other date is caught by value, not only by year. `restrict=on` removes the dependence on whether CI runners reach the internet; the predecessor's two comments contradict each other (clock-1996: "CI runners DO have real internet", `boot-test.py:588+`; clock-epoch: "no route to the real internet", `:488+`).

### nat
Two concurrent guests from the same ISO, both ISOLINUX `serial` via the shared boot helper (with the warmup) and each a `Guest` with its own reader thread and `reached_init`.
- Router (`qemu-system-i386 -cpu 486 -m 256`, `-nic none -netdev user,id=wan -device e1000,netdev=wan -netdev socket,id=lan,udp=127.0.0.1:<R>,localaddr=127.0.0.1:<C> -device e1000,netdev=lan`) and client (same base, `udp=127.0.0.1:<C>,localaddr=127.0.0.1:<R>`) (`boot-test.py:639-668`). UDP socket netdev, because TCP listen/connect raced and left the link dead (`:628-634`). Ports `R=12420`, `C=12421` are defaults; the harness picks free UDP ports at start when running in parallel (flags `--nat-router-port`, `--nat-client-port`).
- Fixture: an in-process HTTP server (`fixture_http.py`) on `127.0.0.1:<ephemeral>` serving `probe.txt` = `NAT_OK_marker`; guests reach it as `10.0.2.2:<port>` through the router's SLIRP WAN. The CI job no longer starts an `http.server` (`boot-test.yml:739-744`).
- Router assertions: `monolith-router eth0 eth1 --dhcp --yes` output contains `DHCP+DNS up` (60 s); `nft list ruleset` contains `masquerade`; `echo ipfwd=$(cat /proc/sys/net/ipv4/ip_forward)` contains `ipfwd=1` (escape-tolerant); `netstat -lnu | grep ':53 '` contains `192.168.99.1:53` and `grep -c '0.0.0.0:53'` is 0 (LAN-only bind).
- Client: `busybox hostname natclient`; stop the boot `dhcpcd`; fresh `dhcpcd -1 -t 30 --hostname=natclient eth0` exits 0 within 45 s (T-dnsmasq-build-and-dhcpcd-hostname); leased address in `192.168.99.50-200`; `busybox nslookup monolith.home.arpa 192.168.99.1` contains `192.168.99.1`; `natclient.home.arpa` resolves into the lease range; `curl http://10.0.2.2:<port>/probe.txt` polled up to 20 times (4 s each, 120 s total) returns `NAT_OK_marker`; negative control: after `monolith-router down` (output `NAT down`) the curl exits 28.
- Diagnostics (non-gating) before and after: `ip addr`, `ip link`, ping of the gateway, `ip neigh`, `/proc/net/dev` on both nodes (`:2096-2155`). Kept: they localized the link-local bug.
- `drain_router()` is removed; the O01 reader thread drains both guests (T-nat-router-serial-starvation).
- Retry: a failure while the client is active and the client never reached init relaunches the whole mode (O01 retry rule).

### persist
`qemu-system-i386 -cdrom ISO -drive id=persist,if=none,format=raw,file=<disk> -device virtio-blk-pci,drive=persist -m 128 -cpu 486 -boot d -nographic -serial mon:stdio -no-reboot` (`boot-test.py:693-714`), label `serial persist`. The host creates a 64 MB sparse file and formats it with `mkfs.ext4 -F -q -L MONOLITH_PERSIST` (needs `mkfs.ext4` on PATH, else exit 2 with a clear message; `:673-690`). Boot 1: `/overlay` fstype is `ext4` (pure-shell `/proc/mounts` read printing `overlay_fstype=ext4`; busybox has no awk, `:472-475`); `echo MONOLITH_PERSIST_MARK_<hex>`; one blank prompt, 1 s, `sync`; then QEMU is SIGKILLed (unclean power-off; `sync` is the documented durability boundary because `history -a` only reaches the page cache). Boot 2 reuses the file without reformatting: `/overlay` is still `ext4`; `grep -qF <marker> /root/.bash_history` prints `FOUND_<marker>`. New: boot 2 is a `Guest` with its own `reached_init`; a silent second boot relaunches the mode from a fresh disk. The disk formatting happens inside the attempt scope, so a relaunch starts clean (`oracle.yaml`: build_persist_cmd re-runs make_persist_disk). New: the marker is random per attempt, so a stale history cannot satisfy a later attempt.

## Traps and doctrines preserved
- **T-nat-router-serial-starvation:** parent stops draining one child; pipe fills; netdev pump freezes. Prevented structurally by the always-on reader (O01-AC-3) and by O04-AC-2, which drives the client for a long step while the router prints.
- **T-router-link-local:** `monolith-router` skipped assigning the LAN CIDR when eth1 had a 169.254 link-local. The recipe's unit test (R01) holds the logic; the end-to-end proof is the client lease and gateway reachability in O04-AC-2.
- **T-nft-inet-and-readline:** `nft` `inet` fails with IPv6 off; bracketed-paste escapes broke `^1`. Prevented by `ipfwd=1` marker output, the `masquerade` check (O04-AC-1), and O01-AC-6.
- **T-dnsmasq-build-and-dhcpcd-hostname:** DNS-only dnsmasq; boot dhcpcd made `--hostname` inert. Prevented by the fresh `dhcpcd -1 --hostname` lease and the `natclient.home.arpa` lookup (O04-AC-1).
- **T-boot-test-wrong-cause-clock:** misdiagnosed hang caused by `://` in the typed label. Prevented by O04-AC-5 (label is the bare `serial`) and a test that fails on any `://` sent to ISOLINUX.
- **T-isolinux-timeout:** late keystroke lands in the shell; handled in O01-AC-9.
- **T-persist-race:** block enumeration raced init so the persist disk was missed and `/overlay` fell back to tmpfs. Prevented by O04-AC-7 (`/overlay` must be ext4 on both boots; the virtio disk probes about 0.2 s after the CD).
- **T-console-home:** `agetty -n` skips login(1), so HOME was `/` and history went to `//.bash_history`. Prevented by O04-AC-7 (the marker is read from `/root/.bash_history`).
- **D-clock-origin-1970:** the default clock-epoch RTC is the Unix epoch; Y2K is only an added sentinel leg. Prevented from drifting by O04-AC-4 and O01-AC-10.
- **D-state-and-no-hidden-stderr:** a dead CI step and an unused validator hid that the mode did not test its documented behaviour. Prevented by O04-AC-3/AC-4 and the lint in O01-AC-14.

## Gate
- **O04-AC-1** — `nat` passes all router, client and negative-control assertions listed in Design (DHCP+DNS up, masquerade, `ipfwd=1`, LAN-only dnsmasq bind, hostname lease in `192.168.99.50-200`, `monolith.home.arpa` and `natclient.home.arpa` resolution, curl returns `NAT_OK_marker`, curl exits 28 after `monolith-router down`). *Verify:* CI leg `oracle / boot (nat)`. *Tier:* slow.
- **O04-AC-2** — In `nat`, both guests are driven through a harness that reads every guest's serial continuously, there is no `drain_router` call, and a fast test floods one fake guest while driving the other without losing either stream. *Verify:* `tests/fast/test_oracle_nat.py::test_both_guests_drained` (two `fakeqemu.py` guests, one emitting 2 MB while the other answers 30 checks); CI leg `oracle / boot (nat)`. *Tier:* fast and slow.
- **O04-AC-3** — `clock-epoch` boots with RTC `1970-01-01T00:00:00`, bare label `serial`, a restricted NIC with a `guestfwd` to `http_date_stub.py`, and asserts: flag `/run/monolith-clock-ignorant` present after boot; `date +%Y` contains `1970`; after `MONOLITH_TIME_URL=http://10.0.2.100:8000/ monolith-time-check` exits 0, `date +%Y` contains `2026` and `date +%s` is within 300 s of `1788264000`. *Verify:* CI leg `oracle / boot (clock-epoch)`; `tests/fast/test_oracle_clock.py` replays transcripts for (a) flag missing, (b) year not stomped but correction fails, (c) correction lands 400 s off, each of which must FAIL the mode. *Tier:* slow and fast.
- **O04-AC-4** — The default `--rtc-date` for `clock-epoch` equals `oracle/interfaces.yaml` `clock.epoch_rtc` (`1970-01-01T00:00:00`); a test fails if it is any Y2K/2000 value. Two extra legs with RTC `1980-01-01T00:00:00` and `2000-01-01T00:00:00` pass steps 1-4 with year assertions `1980` / `2000` before correction. *Verify:* `tests/fast/test_oracle_clock.py::test_default_rtc_is_unix_epoch`; CI legs `clock-epoch`, `clock-epoch-1980`, `clock-epoch-2000`. *Tier:* fast and slow.
- **O04-AC-5** — No clock leg sends anything but `serial` to the ISOLINUX prompt and no boot line sent by any O04 mode contains `://`. *Verify:* `tests/fast/test_oracle_clock.py::test_label_is_bare_serial`, `::test_no_url_in_bootloader_input` (scan the bytes the fake QEMU receives). *Tier:* fast.
- **O04-AC-6** — `clock-1996` boots with RTC `1996-06-15T12:00:00`, a restricted NIC and no forward, and asserts `date +%Y` contains `1996`, `date +%s` is within 3600 s of `803217600`, and `/run/monolith-clock-ignorant` is absent. *Verify:* CI leg `oracle / boot (clock-1996)`; replay test with a stomped clock (`2026`) fails. *Tier:* slow and fast.
- **O04-AC-7** — `persist` passes boot 1 (`/overlay` is ext4; marker command runs; `sync`; SIGKILL) and boot 2 on the same unreformatted disk (`/overlay` still ext4; `grep -qF` finds the marker in `/root/.bash_history`). *Verify:* CI leg `oracle / boot (persist)`. *Tier:* slow.
- **O04-AC-8** — A second boot or NAT client that never reaches `/init` relaunches the whole mode (fresh disk, fresh pair) up to `--max-attempts`, and a failure after `/init` on either guest does not retry. *Verify:* `tests/fast/test_oracle_retry.py::test_persist_boot2_silent`, `::test_nat_client_silent`, `::test_nat_client_fail_after_init_not_retried` using `fakeqemu.py` transcripts. *Tier:* fast.
- **O04-AC-9** — The CI workflow has no step that starts an HTTP server for these legs; fixtures are started inside the harness (`fixture_http.py` for nat, `guestfwd` stub for clock). *Verify:* `tests/fast/test_oracle_workflow.py::test_no_http_server_steps`. *Tier:* fast.
- **O04-AC-10** — `http_date_stub.py` answers a HEAD or GET request with `Date: Tue, 01 Sep 2026 12:00:00 GMT` for argument `1788264000`, handles a request without a trailing body and a closed stdin without a traceback, and uses only the standard library. *Verify:* `tests/fast/test_oracle_clock.py::test_http_date_stub` runs it with `curl -sI`-style input. *Tier:* fast.
- **O04-AC-11** — Golden argv files for `nat-router`, `nat-client`, `persist`, `clock-epoch`, `clock-1996` match the builders (including the UDP socket netdev, `restrict=on`, the persist `virtio-blk-pci` disk). *Verify:* `tests/fast/test_oracle_argv.py`. *Tier:* fast.

## RED plan
Tester commits: `test_oracle_clock.py` (default RTC, bare label, no `://`, stub behaviour, three failing-transcript replays), `test_oracle_nat.py` (two-guest flood), additions to `test_oracle_retry.py` (second boot, client), `test_oracle_workflow.py::test_no_http_server_steps`, golden argv. They fail on missing modules. The slow ACs have GREEN only in CI.

## Risks and open questions
- Hardest: whether QEMU's `guestfwd=...-cmd:` works in the runner's QEMU for an HTTP exchange and how the guest's `curl --connect-timeout 5 --max-time 8` copes with a slow per-connection Python start under TCG host load. Fallback above (chardev). A residual unknown is whether `restrict=on` still delivers DHCP to the guest; if not, drop `restrict=on` and block the internet with `guestfwd` only plus a short-circuit of the default URL.
- The ignorance flag is not cleared after a later successful `monolith-time-check`; the old docstring claimed it was. If the login hint (`30-clock-hint.sh`) keys on that flag, a user who fixes the clock still sees the hint. That is a recipe question for R01, not asserted here.
- The 1980 and 2000 legs assume the kernel reads those RTC values as written; if QEMU `-rtc base=` plus the kernel's RTC-as-localtime handling shifts by hours, the 2-day slack in `monolith-time-check` covers it, but the year assertion might read 1979 on a UTC-offset error. Calibrate on the first run.
- A NAT leg has more moving parts than any other (two QEMUs, UDP link, SLIRP, dnsmasq, timing). The predecessor's flake history is six commits; the end-to-end proof remains slow-tier only.
- `mkfs.ext4` must exist on the runner (`e2fsprogs`, added by `oracle-setup`).
- Time budget: nat boots two 256 MB guests under TCG; plan the largest `job_timeout_minutes` (initial guess 75).
- Unknown: whether the persist label `serial persist` and the `MONOLITH_PERSIST` label detection survive B03's init; the interface is `oracle/interfaces.yaml` plus B03's gate.

## Cost
Four to five agent slices: (1) clock mode, stub, tests; (2) nat port with the new harness; (3) persist and retry attribution; (4) argv goldens and workflow lint; (5) first-run calibration. Two to four CI cycles on the oracle workflow (nat is the long pole). No paid services.

## Spec defects found
- graph.yaml describes O04 as "clock-epoch made to match its documented intent (the fetch-and-set path tested for real)". The documented intent in the code docstring is partly unattainable as written: the boot hook cannot be pointed at a fixture via the boot label (ISOLINUX hangs on `://`), so "tested for real" here means the real script run by hand in the guest, not the S45 hook succeeding. Accept this wording or specify a different injection path (for example a recipe change letting `monolith-time` read a URL from a file on a second virtual disk, owned by R01).
- graph.yaml: O04 unlocks G01 and G04 only through the harness; G04 (SLIP/PPP) additionally needs a serial-link topology that this node's harness does not provide. Not a defect in O04, but G04's dependency on O04 is thin.
