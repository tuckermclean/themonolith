# G04 — serial-network-protocols

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| G | O04 | X01 | — | M |

**Owns:** `oracle/modes/serial_net.py` (mode `serial-net`: SLIP, chat, PPP over a serial link between two guests), `oracle/modes/dropbear.py` (mode `dropbear`), `oracle/lib/serial_link.py` (QEMU `-chardev socket` pair and ordering), `oracle/lib/ssh_client.py` (host-side `ssh`/`ssh-keygen` wrapper, key lifecycle), `oracle/fixtures/argv/serial-net-{a,b}.txt`, `oracle/fixtures/argv/dropbear.txt`, `oracle/fixtures/serial/serial-net-*.txt`, `oracle/fixtures/serial/dropbear-*.txt`, entries `serial-net` and `dropbear` in `oracle/modes.yaml`, `tests/fast/test_serial_net.py`, `tests/fast/test_dropbear_mode.py`, `tests/fast/networking-claims.test.sh`. Edits to the README Networking section, `topics/network.txt`, `topics/tools.txt`, `50-dropbear-hint.sh` and the `S20keygen` text are made by this node's PR in R01's/R05's files.
**Carries from linux-live-iso-factory@b9f533b:** the claims at `README.md:93-94,280-298`, `configs/overlay/app-misc/monolith-base/files/topics/network.txt:23-24` and `topics/tools.txt:21`, `configs/portage/env/ppp-no-plugins.conf`, `configs/portage/package.env/cross-compile:37-39`, `configs/portage/world:132-137`, `scripts/build-rootfs.sh:297-322` (dropbear hint), `:593-612` (`S20keygen`), `RELEASE-READINESS.md:215-228` (dropbear never started), kernel symbols `SLIP=y`, `PPP=y`, `PPP_ASYNC=y`, `PPP_SYNC_TTY=y`, `PPPOE=y`, `PPP_DEFLATE`, `PPP_BSDCOMP` (`kernel.config:1692-1710`), `SERIAL_8250_NR_UARTS=4` (:1859), busybox `CONFIG_SLATTACH=y` (savedconfig:961).
**Study refs:** oracle.yaml gaps ("Networking promises (README:280-300): SLIP (slattach), PPP/pppd, dropbear SSH + S20keygen host key generation ... none exercised"); doctrine.yaml T-ppp-mutt-tinfo, D-no-dynamic-loading-no-dlopen, DEC-root-passwordless, T-unowned-allowlist (`50-dropbear-hint.sh`), T-console-home, T-nat-router-serial-starvation (two-guest harness rule), D-state-and-no-hidden-stderr; contradictions in `RELEASE-READINESS.md` (dropbear never started, still true) and README (RSA key, PPPoE).

## Purpose
After this node the Networking section of the README describes only what boots and works. SLIP and PPP links are brought up between two emulated machines over a virtual serial cable and carry traffic; `chat` dials a fake modem and hands the line to `pppd`; dropbear starts, presents the host key the boot script made, and accepts an SSH login. Where the README promised more (PPPoE, an RSA host key, root login with no password) the claim is removed or corrected, because the code cannot honour it.

## Scope
In:
- A two-guest mode over a serial link covering SLIP, `chat`, and PPP (with `chat` as the connect script).
- A one-guest mode covering `S20keygen`, manual dropbear start, public-key login from the host, and the password-login refusal.
- README, help topics and hint text corrected to what the modes prove.
- Removing the PPPoE claim.
Out:
- Automatic dropbear start. Not built (decision below).
- Smoke tests of the other networking tools (`iperf3`, `mtr`, `tcpdump`, `socat`, `whois`, `iftop`, `ethtool`, `wget`): G05, one manifest entry each.
- The initrd's BusyBox `slattach` and `udhcpc` applets: B03's required-applet list; a fast check here only asserts README's initrd sentence matches that list.
- NIC drivers and DHCP: O02/O03. NAT and the router: O04.
- The two-guest harness plumbing (continuous reader, retry): O04/O01. This node uses them.
- Kernel PPP/SLIP symbols: R04 (this node asserts them through its own check, see AC-9).

## Design

### What is promised, and what happens to each promise
| Promise (source) | Disposition |
|---|---|
| `slattach -l -p slip /dev/ttyS0` gives a SLIP link (README:291-292) | Tested between two guests (AC-2). The example uses `ttyS0`, the console; the corrected example uses the second port and the tested flags. |
| `pppd /dev/ttyS0 115200 noauth` gives a PPP link (README:295) | The line as written sets no addresses and no `local`, so no IP link results on a bare UART. Replaced by the tested command (AC-3, AC-4). |
| `pppd` + `chat` for dial-up (README:93, topics) | Tested: `chat` against a fake modem, then PPP over the same line (AC-3, AC-4). |
| `ppp` "for serial/PPPoE WAN links" (README:282; `world:132`; topics) | PPPoE removed. `pppd` is built with `--disable-plugins` (`ppp-no-plugins.conf`), and PPP over Ethernet needs the `pppoe.so` plugin (listed in that file's own comment). Test shows plugin loading fails (AC-5). Rejected: shipping the `rp-pppoe` userspace client or enabling plugins; one adds a package, the other breaks D-no-dynamic-loading-no-dlopen. |
| "Dropbear SSH is available — start it with `dropbear`" (README:298) | True once the key and login behaviour are stated correctly; tested (AC-6, AC-7). |
| `S20keygen` "generates RSA and ECDSA host keys" (README:298) | False: the script generates only `dropbear_ecdsa_host_key` (`build-rootfs.sh:603-606`). README corrected to ECDSA (AC-6). |
| Dropbear hint "(root has no password)" (`50-dropbear-hint.sh`) | Misleading: dropbear refuses blank-password logins unless started with `-B`. Hint and README corrected to "log in with a public key or set a password with `passwd` first" (AC-7, AC-8). |
| "dropbear is never started" (`RELEASE-READINESS.md:215-228`) | Decided: stays manual. See below. |

### Decision: dropbear is not started at boot
Root has no password by design and the image can sit on any LAN (`build-rootfs.sh:245-252`; DEC-root-passwordless). A daemon that listens on port 22 by default turns that into a remote-access question the owner has not answered. The README already says "start it with `dropbear`". This node tests that statement and fixes the misleading hint. Rejected: an `S60dropbear` init script (the predecessor's proposed fix). If the owner wants SSH on boot, the smallest safe form is an opt-in kernel parameter (`ssh`) read by an init script, with key-only login; that is a new node with its own ACs, not a test gap.

### Mode `serial-net` (two guests, one serial cable)
- Topology: guest A (dialer, server side of the link) and guest B (answerer), each `qemu-system-i386 -cpu 486 -m 128 -cdrom ISO -boot d -nographic -nic none`, console on the first serial port (`-serial mon:stdio`), and the second serial port `-serial chardev:link`. The cable is a Unix socket: A gets `-chardev socket,id=link,path=S,server=on,wait=off`, B gets `-chardev socket,id=link,path=S`. `serial_link.py` starts A first and waits for the socket file before starting B. The guest sees the cable as `/dev/ttyS1` (`SERIAL_8250_NR_UARTS=4`; `inittab` runs a getty only on `ttyS0`, so `ttyS1` is free).
- Harness rules (T-nat-router-serial-starvation): both consoles are drained continuously by O01's reader; no `drain_*` calls; the retry discriminator treats a guest that never reached `/init` as a launch flake only.
- Label: `serial` on both (bare label, as O04's rule; no `://`).
- Baud rate is nominal: QEMU does not throttle a socket chardev, so `115200` tests option handling, not timing.
- Rejected: one guest with a `socat PTY PTY` pair. Both ends would sit in one network stack and local addresses short-circuit through `lo`, so a ping would pass without crossing the link.

Steps (each a `run_check` on the named guest; `|` marks parallel use of A and B):
1. **Line setup.** Both: `stty -F /dev/ttyS1 raw -echo 115200` exits 0.
2. **SLIP.** A: `slattach -p slip -s 115200 /dev/ttyS1 &`; `ifconfig sl0 10.7.0.1 pointopoint 10.7.0.2 up` (poll for `sl0` up to 10 s). B: the mirror with `10.7.0.2`/`10.7.0.1`. A: `ping -c 3 -W 5 10.7.0.2` exits 0; `ping -c 2 -s 1000 10.7.0.2` exits 0 (fragments over the 296-byte SLIP MTU); a TCP payload `SLIP_OK_<hex>` sent with `nc` from B to A arrives. Teardown: kill `slattach`, `ifconfig sl0 down` (both).
3. **chat.** B runs a modem emulator reading `/dev/ttyS1`: on a line starting `ATZ` it writes `OK`; on a line starting `ATD` it writes `CONNECT` and then `exec`s `pppd` (step 4). A: `chat -v -t 15 '' ATZ OK < /dev/ttyS1 > /dev/ttyS1` exits 0, and its verbose stderr shows the sent and expected strings. Negative control: A runs `chat -t 3 '' ATZ NEVER < /dev/ttyS1 > /dev/ttyS1` against the same emulator and exits non-zero (chat's timeout exit), proving the exit status is real.
4. **PPP via chat.** B's emulator, on `ATD`, replies `CONNECT` and runs `pppd /dev/ttyS1 115200 local noauth nodetach passive ipcp-accept-local ipcp-accept-remote noipdefault`. A runs `pppd /dev/ttyS1 115200 local noauth nodetach connect 'chat -v "" ATZ OK ATD5551212 CONNECT' 10.8.0.1:10.8.0.2 &`. Poll `ip -4 addr show ppp0` on both until up (max 40 s). A: `ping -c 3 -W 5 10.8.0.2` exits 0 and a `PPP_OK_<hex>` TCP payload crosses. A: `pppstats`-free check that `/proc/net/dev` shows non-zero `ppp0` rx and tx. Teardown: `kill` pppd (SIGTERM) and expect `ppp0` gone within 10 s.
5. **PPP without chat.** After teardown, restart both ends directly (`pppd /dev/ttyS1 115200 local noauth nodetach <local:remote>`) and ping once more: the README's corrected example, verbatim.
6. **No plugins.** On A: `pppd plugin pppoe.so ...` exits non-zero and does not hang; output is recorded. No `*.so` under `/usr/lib/pppd` exists (`find /usr/lib/pppd -name '*.so' | wc -l` prints 0 or the directory is absent).
7. **Poweroff** both.

### Mode `dropbear` (one guest, host SSH client)
- Argv: `qemu-system-i386 -cpu 486 -m 128 -cdrom ISO -boot d -nographic -serial mon:stdio -netdev user,id=n0,hostfwd=tcp:127.0.0.1:<port>-:22 -device e1000,netdev=n0`, label `serial`, `<port>` chosen free by the harness and logged.
- Host: `ssh-keygen -t ed25519 -N '' -f <tmp>/id`, `ssh` with `-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=<tmp>/known -o ConnectTimeout=10`. The key and known-hosts file live in a per-run temp directory, removed at the end.
- Steps: (1) `/etc/dropbear/dropbear_ecdsa_host_key` exists after boot and is the only `*_host_key` file; `dropbearkey -y -f ...` prints a fingerprint, captured as `FP`. (2) `pgrep -x dropbear` finds nothing (not running by default); the login hint text is present in `bash -l -c 'echo'` output. (3) In the guest: `mkdir -p /root/.ssh && chmod 700 /root/.ssh`, write the public key to `authorized_keys` with mode 600. (4) `dropbear` (README's exact command, background by default) and poll `netstat -ltn` until port 22 listens. (5) Host: `ssh ... root@127.0.0.1 -p <port> 'echo SSH_OK_<hex>; id -u'` prints the marker and `0`; the host-key fingerprint seen by `ssh -o FingerprintHash=sha256` via `ssh-keyscan` equals `FP`. (6) Negative: `ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password` fails with `Permission denied` (exit 255) while root's password is blank. (7) `pkill dropbear` and confirm port 22 closes.

### Documentation made exact
`tests/fast/networking-claims.test.sh` compares README, `topics/network.txt`, `topics/tools.txt`, the hint script text and the `S20keygen` heredoc with the facts above: no `PPPoE` outside a sentence that says it is not supported, no "RSA" host-key claim, no "root has no password" in the hint's SSH line, the SLIP/PPP examples equal the tested command lines (extracted from `oracle/modes/serial_net.py` constants), and the README's initrd-applet sentence (`slattach`, `udhcpc`, ...) matches B03's `initrd-applets.required`.

## Traps and doctrines preserved
- **D-no-dynamic-loading-no-dlopen / T-ppp-mutt-tinfo:** ppp plugins are dlopen'd and broke the static build; `--disable-plugins` is the fix. Prevented from being undone by G04-AC-5 (plugin load fails, no `.so`) and removes the PPPoE promise it implied (G04-AC-10).
- **DEC-root-passwordless:** a blank root password plus an auto-started SSH server would be an open door. Prevented by G04-AC-7 (password login refused) and the decision not to start dropbear at boot (G04-AC-6 step 2 asserts it is not running).
- **T-console-home:** `HOME=/` would put `~/.ssh` at `/.ssh` and dropbear would not find `authorized_keys`. Prevented by G04-AC-7 (key login works from `/root/.ssh`).
- **T-nat-router-serial-starvation:** two guests, one stalled reader. Prevented by G04-AC-1 (reader rules) and O04-AC-2.
- **T-unowned-allowlist:** the hint script and `S20keygen` are generated or hand-authored files; edits to their text keep their ownership entries. Prevented by G04-AC-10 only touching package-owned files (R05 owns the ownership check).
- **D-state-and-no-hidden-stderr:** `S20keygen` hides `dropbearkey` output (`> /dev/null 2>&1`) and `rcS` hides modprobe errors; a failing key generation would be silent. Prevented by G04-AC-6 (key file exists and fingerprint is read back) and the `S20keygen` message change in AC-8.
- **Promise-versus-test (SPEC §1):** Prevented by G04-AC-10.

## Gate
- **G04-AC-1** — `serial-net` starts guest A then B joined by a socket-chardev serial cable on the second port, both consoles drained continuously, no `drain_*` calls, and the generated argv equals the goldens (no NIC, second serial `chardev:link`, server side first). *Verify:* `tests/fast/test_serial_net.py::test_argv_golden`, `::test_start_order`, `::test_both_guests_drained` (two `fakeqemu.py` guests). *Tier:* fast.
- **G04-AC-2** — A SLIP link between the guests comes up with `slattach` and `ifconfig sl0 ... pointopoint`, carries `ping -c 3` and a 1000-byte-payload ping, and a TCP marker arrives on the other side. *Verify:* CI leg `oracle / boot (serial-net)` step "slip"; transcript replay `test_serial_net.py::test_slip_checks` (passing and failing transcripts: no `sl0`, ping loss, marker missing). *Tier:* slow + fast.
- **G04-AC-3** — `chat -v` completes an expect/send exchange with the fake modem (exit 0) and exits non-zero in the negative control where the expected string never arrives. *Verify:* CI leg `serial-net` step "chat"; replay `test_serial_net.py::test_chat_checks` (including a transcript where chat exits 0 for the negative control, which must fail the mode). *Tier:* slow + fast.
- **G04-AC-4** — `pppd` with `chat` as its connect script and the answerer started on `CONNECT` brings `ppp0` up on both ends with the assigned addresses, carries `ping` and a TCP marker, shows non-zero rx/tx counters, and terminates cleanly on SIGTERM; and the direct (no chat) form used in the README works verbatim. *Verify:* CI leg `serial-net` steps "ppp-chat" and "ppp-direct". *Tier:* slow.
- **G04-AC-5** — `pppd` rejects loading a plugin without hanging, and the rootfs has no `*.so` under the pppd plugin directory. *Verify:* CI leg `serial-net` step "no-plugins"; O06's `no-shared-objects` already covers the file side. *Tier:* slow.
- **G04-AC-6** — After boot `/etc/dropbear/dropbear_ecdsa_host_key` exists and is the only host key; dropbear is not running; after `dropbear` is started as in the README, port 22 listens within 10 s. *Verify:* CI leg `oracle / boot (dropbear)` steps 1, 2, 4. *Tier:* slow.
- **G04-AC-7** — A host `ssh` with the injected key logs in as root, prints the marker and uid `0`, and the host key it sees equals the guest's `dropbearkey -y` fingerprint; password authentication for root is refused. *Verify:* CI leg `dropbear` steps 3, 5, 6; fast replay in `tests/fast/test_dropbear_mode.py` (transcripts: key rejected, wrong fingerprint, password accepted, which must fail the mode). *Tier:* slow + fast.
- **G04-AC-8** — The dropbear hint text and README say to use a public key or set a password first, name only ECDSA as the generated host key type, and `S20keygen` reports a failed `dropbearkey` instead of hiding it. *Verify:* `tests/fast/networking-claims.test.sh` (hint, README, `S20keygen` heredoc: no `> /dev/null 2>&1` on `dropbearkey`, an error branch exists). *Tier:* fast.
- **G04-AC-9** — The resolved kernel config has `SLIP=y`, `PPP=y`, `PPP_ASYNC=y`, `PPP_SYNC_TTY=y`, `PPP_DEFLATE` and `PPP_BSDCOMP` as at b9f533b, and the 8250 driver supports at least two ports. *Verify:* R04's `recipes/kernel/invariants.yaml` `require:` group `serial-net` (this node adds the group), run by `kconfig-check`. *Tier:* fast.
- **G04-AC-10** — README, `topics/network.txt`, `topics/tools.txt` and `world`-adjacent comments contain no PPPoE claim, no RSA host-key claim and no untested example; the SLIP and PPP examples equal the command lines the mode runs; the initrd-applet sentence matches B03's list. *Verify:* `tests/fast/networking-claims.test.sh`. *Tier:* fast.
- **G04-AC-11** — Both modes are registered in `oracle/modes.yaml` (`node: G04`, `ram_mb`, `job_timeout_minutes`, `needs: [ssh]` for `dropbear`); the host key and temp directory of `dropbear` are removed after the run, even on failure. *Verify:* `tests/fast/test_dropbear_mode.py::test_registry`, `::test_tempdir_cleanup`. *Tier:* fast.

## RED plan
First `networking-claims.test.sh` (red on the current README: PPPoE and RSA text, `noauth` example without addresses, hint wording), then `test_dropbear_mode.py` and `test_serial_net.py` with failing-transcript fixtures that encode what a lying pass looks like (chat exit 0 on the negative control; password login accepted; ping passing with no `sl0`). The slow legs go red when the modes exist and the ISO does not behave as claimed; that is the intended signal.

## Risks and open questions
- Hardest: the SLIP and PPP userland may not behave over a QEMU chardev the way they do on a UART (no modem control lines, `slattach` wanting `-L`/carrier, `pppd` waiting for DCD). The `local` option and `stty raw` are the expected fixes; if SLIP needs a flag the README example gets it. A failure here corrects the README rather than weakening a check.
- Whether `net-tools` installs `slattach` in the rootfs is not established from the repo (`world:` has `sys-apps/net-tools`, `package.use/static:207` sets `static -nls`). If missing, the SLIP promise is removed from the rootfs text (the initrd BusyBox applet, `savedconfig:961`, stays) and AC-2 is replaced by the removal AC-10.
- `dropbear` may refuse the login for reasons outside this design (root shell not in `/etc/shells`, `/dev/pts` not mounted, ECDSA-only host key with an old client). Each is a real defect the mode would find.
- The ssh client is a runner package (`openssh-client`); it must be declared in I05's `floating.apt` list or pinned.
- Unknown: `pppd` option set accepted by the built version (`ipcp-accept-local` etc.); the first run decides final spellings. The README example is generated from the mode's constants, so they cannot drift.
- PPP/SLIP are a niche promise; if the owner prefers to drop the whole serial-protocol story (D-486-minimalism does not force it), the cheaper outcome is deleting the README text and the `ppp` atom; that is a recipes decision (R01) and would shrink G05's manifest by one.

## Cost
Three agent slices: (1) claims test, doc corrections, `serial_link`, mode skeletons with transcripts; (2) `serial-net` steps and fixes found; (3) `dropbear` mode, ssh wrapper, kernel invariant group. CI: two to three oracle cycles; `serial-net` is two 128 MB guests for about 10-15 minutes, `dropbear` about 8. No money.

## Spec defects found
- O01-AC-13 requires exactly 17 modes; this node adds `serial-net` and `dropbear` (see G01).
- graph.yaml: G04 depends on O04 for the two-guest harness; it also needs R04 (kernel invariant group) and B03 (applet list) for two of its fast checks. Both are earlier in the graph (via O02/B06); no cycle, but the edges are implicit.
- SPEC §1 lists networking services (`monolith-net`, `monolith-router`, nftables, dnsmasq, dhcpcd) and omits dial-up and SSH although the README markets them; this node keeps them as documented, tested features. If the owner drops them, SPEC §1 and the README change together.
- `RELEASE-READINESS.md` (dropbear never started) is stale evidence; the rebuild has no such file. Its open item is closed here by decision, not by code.
- X01 (graph.yaml) does not depend on G04 (see G01).
