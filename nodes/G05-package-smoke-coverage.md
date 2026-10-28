# G05 — package-smoke-coverage

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| G | O02 | X01 | — | L |

**Owns:** `oracle/smoke/manifest.yaml`, `oracle/smoke/schema.json`, `oracle/smoke/covered_by.yaml`, `oracle/smoke/lint.py`, `oracle/smoke/build_script.py` (manifest to guest script), `oracle/smoke/evaluate.py` (host-side step evaluation), `oracle/smoke/versions.py` (upstream version from `pins/versions.lock`), `oracle/modes/smoke.py` (mode `smoke`), `oracle/fixtures/argv/smoke.txt`, `oracle/fixtures/smoke/` (recorded guest outputs), `oracle/lib/fixture_whois.py` (host-side fixture for `whois`), entry `smoke` in `oracle/modes.yaml`, `tests/fast/test_smoke_manifest.py`, `tests/fast/test_smoke_evaluate.py`, `tests/fast/test_smoke_build_script.py`.
**Carries from linux-live-iso-factory@b9f533b:** the shape of `scripts/boot-test.py:844-880` (`run_check` sentinel protocol, O01 ports it) and the existing coverage list `harness.full_smoke_suite` (curl, sqlite3, perl, CGI, man, `monolith`; O02 owns those checks and this node does not duplicate their code). `configs/portage/world` (99 atoms; becomes `recipes/portage/world` via R01) is the list this node must cover.
**Study refs:** oracle.yaml gaps ("Package set (99 world atoms): smoke suite exercises only curl, sqlite3, perl/CGI, man, monolith tools, startx stack, stele, nft, dnsmasq, dhcpcd; no execution test of the other ~80 packages"); recipes.yaml `cfg.portage/world` (`world_atoms`, `special_handling`); doctrine.yaml T-keep-going-hides-drops (a package silently dropped from the build), D-state-and-no-hidden-stderr (tests must mean something), T-nethack-abi, T-gdb-static, T-perl-cross-static-musl, T-dbd-sqlite-static-ext, T-shared-module-with-static-ldflags.

## Purpose
After this node every package the world file installs is run at least once on the booted disc, prints a version that matches the lock, and does one real thing, and adding a world atom without a smoke entry fails CI. The predecessor proved about twenty of its 99 packages; `--keep-going` could drop one from the build and nothing noticed (T-keep-going-hides-drops). The suite is one boot, not ninety-nine.

## Scope
In:
- A manifest format with one entry per world atom, a linter that ties it to the world file, and a runner mode that executes the whole manifest in a single boot and reports each step.
- The seed manifest content: kind, version step, and one real action for each of the 99 atoms (table below).
- Fixtures the manifest needs: scratch disk, loopback services, host-side HTTP and whois stubs.
Out:
- The boot harness, QEMU setup, the existing full/reduced/storage suites: O01, O02. This node adds a mode; it does not change theirs.
- GUI behaviour (Xfbdev, dwm, st, Stele rendering): O05. The manifest delegates those atoms to the `gui` and `stele-acid2` modes by name.
- Serial protocols and SSH (`ppp`, `dropbear`): G04. Persistence and swap: G01. The manifest points to those modes.
- Static-link checks and no-Python/no-freetype checks on files: O06. A smoke test proves a binary runs, not how it is linked.
- Version-lock completeness: R02. This node reads `pins/versions.lock` and relies on R02's gate for gaps.

## Design

### Manifest: `oracle/smoke/manifest.yaml`
```yaml
schema: 1
guest:                       # the one boot every step runs in
  ram_mb: 256
  label: serial
  disks: {scratch: 64M}      # /dev/vdb, zero-filled, writable
  net: {fixture_http: 10.0.2.2, fixture_whois: 10.0.2.2}
defaults: {timeout_s: 20}
packages:
  - atom: sys-apps/sed                  # category/package, normalised (below)
    kind: bin
    version: {cmd: "sed --version", regex: "GNU sed\\) {V}"}      # {V} = upstream version from the lock
    do:
      - {id: s, cmd: "echo hello | sed 's/h/j/'", expect: {equals: "jello"}}
  - atom: dev-lang/lua
    kind: bin
    version: {cmd: "lua -v", regex: "Lua {V}"}
    do:
      - {id: e, cmd: "lua -e 'print(6*7)'", expect: {equals: "42"}}
  - atom: x11-base/xorg-proto
    kind: buildtime
    version: {none: "headers only; installs no target files"}
    covered_by: {id: s04-unowned}
```
Entry fields:
- `atom` (required, unique): `category/package` as it appears in `recipes/portage/world` after normalisation: strip leading `<>=~!`, a `:slot` suffix, and a trailing `-<version>[-rN]`. The world's `<sys-fs/ncdu-2`, `=games-roguelike/nethack-3.6.7-r1`, `net-misc/iperf:3` become `sys-fs/ncdu`, `games-roguelike/nethack`, `net-misc/iperf`.
- `kind`: `bin` (runs), `lib` (no CLI; `consumer` names the binary that shows it in use), `data` (files only), `kernel`, `meta`, `initrd` (present only in the initramfs), `gui`, `buildtime` (installs nothing on the target).
- `version`: for `bin`/`lib`/`kernel`/`meta`/`gui`, either `{cmd, regex}` or `{none: <reason>}`. The regex must contain `{V}`, replaced at lint and run time by the escaped upstream version of the atom in `pins/versions.lock`: the lock version with a trailing `-rN` and any `_p…`, `_pre…`, `_rc…`, `_alpha…`, `_beta…` suffix removed. An entry may override with `v_regex: "<literal regex>"` and a one-line `v_reason` when the tool prints something else (gcc, perl, kernel). `{none: reason}` is allowed only for binaries with no version flag and is counted in the report.
- `do`: a list of steps `{id, cmd, expect, timeout_s?, needs?}`, at least one for `bin`/`lib`/`kernel`/`meta`. `expect` is one of `{equals: S}`, `{contains: S}`, `{regex: R}`, `{not_contains: S}`, or `{exit_only: true, reason: "..."}`. The exit status must be 0 unless `{exit: N}` is given.
- `covered_by: {id}`: delegates the "does one real thing" proof to a named check in `oracle/smoke/covered_by.yaml` (maps `id` to a mode id from `oracle/modes.yaml`, an O06 check name, or a fast test path). The linter verifies that the target exists. Allowed only for kinds `gui`, `initrd`, `buildtime`, and for atoms another G node proves (`net-misc/dropbear`, `net-dialup/ppp`); still requires `version` unless `kind: buildtime|data`.
- `waiver: {reason, issue, expires: YYYY-MM-DD}`: an explicit, expiring exception. The linter fails after the date. A maximum of 5 waivers may exist (set in `schema.json`); raising it is a visible diff.
- `needs`: `net`, `scratch`, `loopback`; documentation for the reader and the sharding tool, all satisfied by the one guest.

### Linter: `oracle/smoke/lint.py` (fast tier)
Runs in `make test-fast` and as the PR check for every change. It fails with the exact missing name:
1. **Coverage.** The normalised atom set of `recipes/portage/world` equals the manifest atom set. `world atom X has no smoke entry (add it to oracle/smoke/manifest.yaml)` and `manifest atom X is not in the world (remove it)`. Duplicates are errors.
2. **Schema.** Keys, kinds, step ids unique per atom, `{V}` present in every `version.regex`, no unknown fields.
3. **Non-vacuous expectations.** Every `expect` has `equals`, `contains`, `regex` or `not_contains`, or an `exit_only` with a reason (at most 8 across the manifest). An `equals`/`contains` string must not appear verbatim in the same step's `cmd` (an echoing command would pass trivially); a regex must not match the empty string.
4. **No hidden failures.** No `2>/dev/null`, `|| true`, `|| :` or `; true` in a `cmd` (D-state-and-no-hidden-stderr). `2>&1` is required when the interesting output is on stderr.
5. **Delegations resolve.** Every `covered_by.id` exists in `covered_by.yaml` and its target exists (mode in `oracle/modes.yaml`, test file path, or O06 check name).
6. **Waivers.** Present, with reason and issue, not expired, at most 5.
7. **Version templating.** `versions.py` can compute `{V}` for every atom that has one (the lock has the atom, R02's gate); a missing lock line is `lock has no entry for X (R02)`.
8. **Evaluation sanity.** The 'vacuity probe': for every step the evaluator rejects each of {empty output, `sh: <cmd>: not found` with rc 127, `Segmentation fault` with rc 139, and rc 0 with the output "ok"}. A step that any of these satisfies is vacuous and fails the lint.

### Runner: mode `smoke`
`oracle/modes/smoke.py` boots the ISO once (BIOS, ISOLINUX `serial`, 256 MB, the 64 MB scratch virtio-blk disk, an e1000 user-mode NIC for the fixture servers) with a third virtio-blk disk carrying the generated script.
- `build_script.py` turns the manifest into `smoke.sh`, one `run <atom> <id> <timeout> <cmd>` call per step. `run` executes `timeout <n> sh -c '<cmd>' >/tmp/o 2>&1; rc=$?` and prints `SMOKE|<atom>|<id>|<rc>|<base64 of the first 2048 bytes of output>`. The guest does no matching; it needs only POSIX `sh`, `timeout` and `base64` from coreutils (both are in the base). Rejected: typing 230 commands one by one through the serial protocol (each round trip costs seconds under TCG) and sending the script over the console (slow, fragile). The script is read from the raw disk with `head -c <N> /dev/vdc > /tmp/smoke.sh` (N is known to the host) and run as `sh /tmp/smoke.sh`.
- `evaluate.py` runs on the host: it decodes each line, applies `version`/`expect`, and records `ok|fail|missing|extra` for every manifest step. A manifest step with no `SMOKE|` line is `missing`; a line for an unknown step is `extra`. The mode passes only if every step is `ok` (or its atom is delegated or waived) and the final `SMOKE|summary|steps=<N>` line equals the manifest's step count computed on the host (T-keep-going-hides-drops, in the test harness: a script that dies halfway cannot look like success).
- Output: `smoke-results.json` (per atom: steps, status, rc, first 200 bytes of output, duration) uploaded as a CI artifact, and a Markdown table in the job summary listing failures first.
- Fixtures: the scratch disk for `e2fsprogs`, `dosfstools`, `smartmontools`, `hdparm`; loopback listeners started by steps themselves (`socat`, `nc`, `iperf3 -s`); a host HTTP fixture (O01's `fixture_http`) serving `probe.txt` (`SMOKE_HTTP_<hex>`) and `page.html` for `curl`/`wget`/`lynx`; `oracle/lib/fixture_whois.py`, a host TCP server answering one canned line, for `whois`. Fixture ports are chosen by the host and substituted into the script as `$HTTP_PORT` and `$WHOIS_PORT`.
- Sharding: the manifest carries an optional `shard: a|b|c` per atom (default `a`); `--shard` selects. The initial setting is one shard. If the first real run takes more than 20 minutes, the implementer splits by moving the slowest atoms (gdb, vim, perl, nethack) to shard `b`; the mode, workflow and lint support sharding from day one so the split changes only data. Estimate: about 230 steps at 0.2-10 s each under TCG is 10-20 minutes; unknown until measured.
- RAM 256 MB. The mode records `free -m` at start and end into the result JSON so a RAM regression is visible. Smaller RAM is O02's job (`bios` at 64 MB).

### Seed manifest content
This table is the starting point for the implementer. The commands are proposals, written without access to the built disc; each must be confirmed on the first run, and a flag that does not exist gets replaced, not skipped. `none` in the version column means the tool has no version flag; the entry then needs `version: {none: reason}`. Rows marked `covered_by` delegate the action to the named mode or check.

| Atom | Kind | Version step | One real thing |
|---|---|---|---|
| `sys-kernel/monolith-kernel` | kernel | uname -r | test -s /lib/modules/$(uname -r)/modules.dep && lsmod \| head -1 |
| `app-misc/monolith-base` | meta | cat /etc/monolith-release | monolith tools \| head -3; monolith-persist --help |
| `sys-apps/busybox` | initrd | n/a (initrd only) | covered_by B03 required-applet list |
| `app-shells/bash` | bin | bash --version | bash -c "a=(1 2 3); echo ${#a[@]}" |
| `app-shells/dash` | bin | none (no version flag) | dash -c "echo $((6*7))" |
| `sys-apps/sysvinit` | bin | none (see note) | runlevel; telinit q |
| `sys-apps/coreutils` | bin | ls --version | printf abc \| sha256sum |
| `sys-apps/util-linux` | bin | mount --version | lsblk -n -o NAME; cal 1 1970 |
| `sys-apps/findutils` | bin | find --version | find /etc -maxdepth 1 -name hostname -o -name passwd |
| `sys-apps/grep` | bin | grep -V | echo abc \| grep -o "b." |
| `sys-apps/sed` | bin | sed --version | echo hello \| sed "s/h/j/" |
| `sys-apps/gawk` | bin | gawk --version | echo "a b" \| gawk "{print \$2}" |
| `sys-apps/diffutils` | bin | diff --version | diff of two small files exits 1 and shows the changed line |
| `app-arch/tar` | bin | tar --version | create, list and extract a two-file archive round trip |
| `app-text/tree` | bin | tree --version | tree -L 1 /etc \| head |
| `sys-libs/readline` | lib | via bash | bash -ic "bind -P \| head -1" shows readline in use |
| `sys-libs/ncurses` | lib | via tput | tput cols; infocmp linux \| head -1 |
| `sys-libs/zlib` | lib | via curl -V | curl -V lists libz; gzip-free check: zip a file, unzip -t |
| `dev-libs/libpcre2` | lib | via grep | echo ab \| grep -P "a(?=b)" |
| `dev-libs/openssl` | lib | openssl version | curl -V lists OpenSSL; sha256 via openssl dgst |
| `sys-apps/file` | bin | file --version | file /bin/sh identifies ELF 32-bit |
| `sys-apps/less` | bin | less --version | printf "a\nb\n" \| less -F |
| `app-editors/vim` | bin | vim --version \| head -1 | vim -es -c "normal ione" -c "w! /tmp/v" -c q; cat /tmp/v |
| `app-editors/nano` | bin | nano --version | nano --help \| head -1 (editor itself is interactive) |
| `sys-apps/man-pages` | data | n/a (data) | man 2 open renders a SYNOPSIS section |
| `app-text/mandoc` | bin | mandoc -V | render a one-line mdoc fixture; apropos finds ls |
| `sys-devel/binutils` | bin | ld --version | ar rc /tmp/a.a /etc/hostname; ar t /tmp/a.a |
| `dev-build/make` | bin | make --version | make -f a two-line Makefile writes a file |
| `dev-debug/strace` | bin | strace -V | strace -c -o /tmp/s true; head -1 /tmp/s |
| `sys-devel/patch` | bin | patch --version | apply a three-line patch and compare |
| `dev-debug/gdb` | bin | gdb --version \| head -1 | gdb -batch -ex "print 6*7" |
| `dev-lang/lua` | bin | lua -v | lua -e "print(6*7)" |
| `dev-lang/monolith-perl` | bin | perl -v | perl -e "printf q(%d), 6*7" (O02 full smoke overlaps) |
| `app-arch/xz-utils` | bin | xz --version | xz round trip of a 1 KB file |
| `app-arch/bzip2` | bin | bzip2 --help 2>&1 \| head -1 | bzip2 round trip |
| `app-arch/gzip` | bin | gzip --version | gzip round trip |
| `sys-apps/iproute2` | bin | ip -V | ip -4 addr show lo |
| `sys-apps/net-tools` | bin | ifconfig --version | ifconfig lo; route -n |
| `net-misc/iputils` | bin | ping -V | ping -c 1 127.0.0.1 |
| `net-misc/dhcpcd` | bin | dhcpcd --version | dhcpcd -T lo (test mode, no lease change) |
| `sys-apps/ethtool` | bin | ethtool --version | ethtool -i eth0 driver line |
| `net-firewall/nftables` | bin | nft --version | nft add table inet t; nft list tables |
| `net-dns/dnsmasq` | bin | dnsmasq --version \| head -1 | dnsmasq --test (config syntax check) |
| `net-misc/dropbear` | bin | dropbear -V 2>&1 | G04 dropbear mode (covered_by); dropbearkey -t ecdsa to a temp file |
| `net-misc/curl` | bin | curl --version | curl http://10.0.2.2:PORT/probe.txt returns the fixture marker |
| `net-misc/wget` | bin | wget --version \| head -1 | wget -qO- http://10.0.2.2:PORT/probe.txt |
| `net-misc/whois` | bin | whois --version | whois -h 10.0.2.2 -p FIXTURE_PORT example (host-side stub answers) |
| `net-analyzer/netcat` | bin | netcat -h 2>&1 \| head -1 | TCP echo to loopback listener |
| `net-analyzer/traceroute` | bin | traceroute --version 2>&1 | traceroute -n -m 1 127.0.0.1 |
| `net-misc/iperf` | bin | iperf3 --version | iperf3 -s -1 & iperf3 -c 127.0.0.1 -t 1 reports bits/sec |
| `net-dialup/ppp` | bin | pppd --version 2>&1 | G04 serial-net mode (covered_by); chat --version-free: chat -V |
| `www-client/lynx` | bin | lynx -version \| head -1 | lynx -dump http://10.0.2.2:PORT/page.html |
| `mail-client/mutt` | bin | mutt -v \| head -1 | mutt -D \| head -1 (dump config) |
| `net-irc/irssi` | bin | irssi --version | irssi --help \| head -1 |
| `app-misc/tmux` | bin | tmux -V | tmux new -d "echo T > /tmp/t"; sleep 1; cat /tmp/t |
| `sys-apps/shadow` | bin | none (see note) | useradd smoketest; id smoketest; userdel smoketest |
| `sys-process/procps` | bin | ps --version | ps -e \| head -2; free -m \| head -2 |
| `sys-process/htop` | bin | htop --version | htop -C -d 1 under a pty is interactive: htop --help |
| `sys-process/lsof` | bin | lsof -v 2>&1 \| head -2 | lsof -p $$ \| head -2 |
| `app-admin/sysklogd` | bin | syslogd -v 2>&1 | logger smoke-<hex>; grep it in /var/log/messages |
| `sys-process/psmisc` | bin | killall -V 2>&1 | pstree -p 1 |
| `app-arch/cpio` | bin | cpio --version | cpio -o \| cpio -t round trip |
| `sys-fs/ncdu` | bin | ncdu -v | ncdu -0 -o /dev/null /etc (non-interactive export) |
| `sys-apps/pv` | bin | pv -V \| head -1 | head -c 1000 /dev/zero \| pv -q \| wc -c |
| `sys-fs/e2fsprogs` | bin | mke2fs -V 2>&1 \| head -1 | mke2fs -q on the scratch disk, e2fsck -n, tune2fs -l label |
| `sys-fs/dosfstools` | bin | mkfs.fat --help 2>&1 \| head -1 | mkfs.fat on scratch disk; fsck.fat -n |
| `sys-fs/squashfs-tools` | bin | mksquashfs -version \| head -1 | mksquashfs /etc/issue /tmp/s.sq; unsquashfs -l |
| `app-shells/zsh` | bin | zsh --version | zsh -c "print $((6*7))" |
| `app-shells/bash-completion` | data | n/a (data) | source /usr/share/bash-completion/bash_completion; type _init_completion |
| `net-misc/rsync` | bin | rsync --version \| head -1 | rsync -a a/ b/ on a two-file tree |
| `sys-apps/the_silver_searcher` | bin | ag --version \| head -1 | ag needle over a one-file tree |
| `app-arch/zip` | bin | zip -v \| head -2 | zip then unzip -t round trip |
| `app-arch/unzip` | bin | unzip -v \| head -1 | covered by the zip round trip; unzip -l |
| `net-misc/socat` | bin | socat -V \| head -2 | socat TCP-LISTEN + TCP-CONNECT echo on loopback |
| `net-analyzer/iftop` | bin | iftop -h 2>&1 \| head -1 | iftop -t -s 1 -i lo (text mode) |
| `net-analyzer/tcpdump` | bin | tcpdump --version 2>&1 \| head -1 | tcpdump -i lo -c 1 icmp while pinging |
| `net-analyzer/mtr` | bin | mtr --version | mtr -r -c 1 127.0.0.1 |
| `sys-apps/smartmontools` | bin | smartctl --version \| head -1 | smartctl -i on the scratch disk reports a device line or "Unavailable" |
| `sys-apps/hdparm` | bin | hdparm -V | hdparm -i /dev/vdb (expected to report the lack of an IDE device) |
| `sys-apps/dmidecode` | bin | dmidecode --version | dmidecode -s system-manufacturer (QEMU) |
| `sys-apps/kbd` | bin | loadkeys -V | showkey -V; setfont ter-116n.psf.gz succeeds |
| `media-fonts/terminus-font` | data | n/a (data) | ls /usr/share/consolefonts/ter-116n.psf.gz; setfont it |
| `dev-db/monolith-sqlite` | bin | sqlite3 --version | sqlite3 :memory: "select 41+1" (O02 overlaps) |
| `sys-libs/gpm` | bin | gpm -V | gpm -t help \| head -1 (mouse types list) |
| `games-misc/bsd-games` | bin | none (see note) | factor 42 prints "42: 2 3 7"; number 42 |
| `app-misc/figlet` | bin | figlet -I3 | figlet hi produces five output lines |
| `app-misc/cmatrix` | bin | cmatrix -V | covered by version (interactive otherwise) |
| `app-misc/sl` | bin | none (see note) | sl -h exits and prints usage |
| `games-roguelike/rl144` | bin | unknown (read the ebuild) | unknown; implementer finds a non-interactive flag or uses a pty keypress |
| `x11-base/monolith-xserver` | gui | Xfbdev -help (first line) | covered_by gui mode (Xfbdev starts and draws) |
| `x11-base/xorg-proto` | buildtime | n/a (headers) | covered_by S04: no unowned files |
| `x11-libs/libxcb` | lib | via st -v | covered_by gui mode (dwm and st link it) |
| `x11-libs/libX11` | lib | via st -v | covered_by gui mode |
| `x11-libs/libXext` | lib | via Xfbdev | covered_by gui mode |
| `x11-terms/monolith-st` | gui | st -v | covered_by gui mode (a terminal is drawn) |
| `x11-wm/monolith-dwm` | gui | dwm -v | covered_by gui mode (bar drawn) |
| `www-client/stele` | gui | stele --version (verify flag) | covered_by stele-acid2 mode |
| `games-roguelike/nethack` | bin | nethack --version | nethack -s (score list, non-interactive) |
| `sys-apps/kmod` | bin | kmod --version | modprobe -n -v ext4; lsmod |
Notes on specific rows:
- Packages with no known version flag (`dash`, `sysvinit`, `shadow`, `bsd-games`, `sl`): each uses `version: {none: reason}`; that makes five of the 99, reported in the job summary.
- `games-roguelike/rl144`: the CLI is not documented in the repository; the implementer reads the ebuild and source before choosing a step. If it has no non-interactive path, the action is a pty keypress sequence in a dedicated step with a 10-second timeout.
- `sys-apps/busybox` ships only in the initramfs (`world` comment); its proof is the B03 required-applet check, referenced through `covered_by`.
- Libraries have no CLI; each uses a consumer that shows the library in use (for example `curl -V` lists zlib and OpenSSL).
- `net-misc/dropbear` and `net-dialup/ppp` are delegated to G04 for the real action but keep their version steps here.
- `x11-*` and `www-client/stele` keep a version step where a flag exists and delegate the action to `gui` and `stele-acid2`.

### How a new world atom fails CI
1. A change to `recipes/portage/world` (R01's file) adds `net-misc/foo`.
2. `make test-fast` runs `tests/fast/test_smoke_manifest.py`, which calls `lint.py`; it exits 1 with `world atom net-misc/foo has no smoke entry (add it to oracle/smoke/manifest.yaml)`.
3. The PR cannot merge: the fast lane is required (F01), and F04 protects the test file from edits in the same PR after RED.
4. The author adds the entry; lint now also checks the version regex against `pins/versions.lock` (R02 requires the lock line for the new atom) and the vacuity probe.
5. The slow tier then runs the step in the `smoke` mode on the built ISO.
The lint, the schema and the vacuity probe are the part of the check that could be weakened by the same PR that adds an atom; they belong in the trusted-base list of SPEC §8 (see defects).

## Traps and doctrines preserved
- **T-keep-going-hides-drops:** a package missing from the build looked fine because nothing ran it. Prevented by G05-AC-1 (every atom has an entry), G05-AC-4 (a step per atom executes) and G05-AC-6 (missing steps fail).
- **D-state-and-no-hidden-stderr / "every test must mean something":** a version step satisfied by `command not found` or an echo. Prevented by G05-AC-3 (vacuity probe, no echoing expectations, no `2>/dev/null`).
- **T-nethack-abi / T-nethack-5-from-epoch-bump:** a version float to 5.x must be caught. Prevented by G05-AC-5 (version printed equals the lock's version).
- **T-gdb-static, T-perl-cross-static-musl, T-dbd-sqlite-static-ext, T-shared-module-with-static-ldflags:** packages that build but do not run when static. Prevented by G05-AC-4 (each runs and does a real thing on the disc).
- **D-all-static (SPEC §3):** not enforced here (O06), but a dynamic binary without its loader shows up as `not found` in a smoke step; the runner records rc 127 and the message in the result JSON for the O06 owner.
- **Promise-versus-test (SPEC §1):** the README's package table. Prevented by G05-AC-9 (README package list equals the manifest).

## Gate
- **G05-AC-1** — `oracle/smoke/manifest.yaml` has exactly one entry per normalised world atom (99 at b9f533b) and no others; adding a world atom without an entry, or removing one without deleting its entry, fails with the atom named. *Verify:* `tests/fast/test_smoke_manifest.py::test_covers_world`, `::test_new_atom_fails` (fixture world and manifest pairs; the second adds `net-misc/foo` and expects exit 1 with the message above). *Tier:* fast.
- **G05-AC-2** — The normaliser maps every world line shape correctly: operators, slots, versions, revisions (`<sys-fs/ncdu-2`, `=games-roguelike/nethack-3.6.7-r1`, `net-misc/iperf:3`). *Verify:* `tests/fast/test_smoke_manifest.py::test_normalise` over the real world file from b9f533b (committed as a fixture) producing exactly the 99 expected names. *Tier:* fast.
- **G05-AC-3** — The linter rejects: a step with no matching condition, an `equals` literal that appears in its own `cmd`, a regex matching the empty string, `2>/dev/null` or `|| true` in any command, an unresolved `covered_by`, an expired or over-limit waiver, and any step the vacuity probe satisfies. *Verify:* `tests/fast/test_smoke_manifest.py::test_lint_rules` (one fixture manifest per rule); `::test_vacuity_probe` over the real manifest. *Tier:* fast.
- **G05-AC-4** — In one boot of the built ISO, every non-delegated, non-waived manifest step runs and passes, and the result JSON lists all 99 atoms. *Verify:* CI leg `oracle / boot (smoke)`; `smoke-results.json` schema check; transcript replay `tests/fast/test_smoke_evaluate.py::test_all_ok`. *Tier:* slow + fast.
- **G05-AC-5** — For every atom with a `version` step, the printed version matches the regex built from the upstream version in `pins/versions.lock`; a package whose installed version differs from the lock fails with both values. *Verify:* CI leg `smoke`; `tests/fast/test_smoke_manifest.py::test_version_templating` (lock suffix stripping: `-r5`, `_p20260717`, `_rc1`), `tests/fast/test_smoke_evaluate.py::test_version_mismatch`. *Tier:* slow + fast.
- **G05-AC-6** — The mode fails when any step is missing (no `SMOKE|` line), when a line names an unknown step, when the summary step count differs from the manifest's, and when the script dies before the summary. *Verify:* `tests/fast/test_smoke_evaluate.py::test_missing_extra_truncated` (recorded transcripts: normal, cut at 40%, extra step). *Tier:* fast.
- **G05-AC-7** — A step that hangs is killed by its timeout, recorded as a failure with rc 124, and does not block the following steps; the whole mode ends within its `job_timeout_minutes`. *Verify:* `tests/fast/test_smoke_build_script.py::test_timeout_wrapper` (shell run of the generated script with a `sleep 30` step and `timeout_s: 1`); CI leg `smoke`. *Tier:* fast + slow.
- **G05-AC-8** — The generated guest script uses only POSIX `sh` plus `timeout`, `base64` and `head`, contains no manifest-specific matching logic, and its size stays under 64 KiB for the full manifest. *Verify:* `tests/fast/test_smoke_build_script.py::test_script_shape` (`sh -n`, command whitelist scan, size). *Tier:* fast.
- **G05-AC-9** — The README's package list (if it keeps one) and the SBOM-visible package set match the manifest: no README package name is absent from the manifest, and the manifest has no atom the world lacks. *Verify:* `tests/fast/test_smoke_manifest.py::test_readme_matches_world`. *Tier:* fast.
- **G05-AC-10** — Delegations are real: each `covered_by.id` resolves to an existing mode in `oracle/modes.yaml`, test file or O06 check, and the delegated atoms are exactly those listed as allowed (`gui`, `initrd`, `buildtime` kinds plus `net-misc/dropbear`, `net-dialup/ppp`). *Verify:* `tests/fast/test_smoke_manifest.py::test_covered_by`. *Tier:* fast.
- **G05-AC-11** — `smoke` is registered in `oracle/modes.yaml` (`node: G05`, `ram_mb: 256`, `needs: [fixture-http]`, `job_timeout_minutes`, shard legs), the argv golden matches, and the result JSON records free memory at start and end and the per-shard duration. *Verify:* `tests/fast/test_smoke_build_script.py::test_registry`, `::test_argv_golden`. *Tier:* fast.
- **G05-AC-12** — A planted regression is caught: removing one binary from a test ISO's rootfs (or setting a step to a wrong expectation in a fixture) turns the leg red naming the atom. *Verify:* CI job `smoke-canary` (dispatch; runs the mode against an ISO with `/usr/bin/sed` replaced by a stub that prints `GNU sed) 0.0`, expects failure naming `sys-apps/sed`) and `tests/fast/test_smoke_evaluate.py::test_canary_transcript`. *Tier:* slow + fast.

## RED plan
First `test_smoke_manifest.py` with the real b9f533b world file as a fixture and an empty manifest, so `test_covers_world` fails with 99 missing atoms, followed by the rule-by-rule lint fixtures and `test_normalise`. Then `test_smoke_evaluate.py` (recorded transcripts for normal, truncated, mismatched version, canary) and `test_smoke_build_script.py` (generator absent). Committing the failing manifest tests first proves the "new atom fails CI" path before any manifest exists. Slow legs come last.

## Risks and open questions
- Hardest: the seed commands are unverified guesses against a disc nobody has booted in this task. Expect a third of them to need a different flag or a pty. The AC wording makes a wrong command a manifest fix, never a weaker `expect`. Packages whose only interface is interactive (`htop`, `nano`, `tmux` attach, `rl144`, `cmatrix`, `sl`) need either a flag or a pty keypress step; the manifest has the `needs` and `timeout_s` fields for that but no pty primitive of its own. If a pty is needed, O01's guest helpers should provide it; list it as a dependency risk.
- Runtime is unmeasured. A single boot with about 230 steps on i486 TCG could be 10-20 minutes or an hour; the shard field exists to cut that without redesign.
- `base64` and `timeout` come from coreutils; `coreutils` is in the world but its static status is unknown. The script falls back to nothing: if they are missing the whole mode fails loudly (that is also a finding).
- Version-regex templating is fragile for packages with odd version output (`gcc`, perl `5.42.0` vs `v5.42.0`, kernel with local version). `v_regex` overrides exist; a growing override list is a smell to watch.
- Mixing trust: the guest script computes nothing; the host evaluates. A compromised package could print expected strings, but this suite is a regression net, not a security gate (S0x covers integrity).
- The `kind: lib` rows are weak proofs (a consumer shows the library is linked in, not that the library is correct). Accepting that is deliberate; a library without a consumer on the disc is a candidate for removal from the world (R01).
- Each added world atom adds roughly one second to one minute to the boot. Over time the suite is bounded by the slow-tier timeout; the owner may decide to cap the world (D-486-minimalism also argues for it).

## Cost
Five agent slices: (1) manifest schema, normaliser, linter and fast tests with the world fixture; (2) evaluator, script generator, transcript tests; (3) the 99-entry manifest content written against real package help (without the disc, so every row marked provisional); (4) the `smoke` mode, fixtures, workflow leg; (5) first-run triage: correct wrong commands, set shards. CI: three to five oracle cycles (each build plus a smoke run of 15-60 minutes); the first real run will fail on many rows, by design. No money beyond runner minutes.

## Spec defects found
- O01-AC-13 requires exactly 17 modes; this node adds `smoke` (see G01).
- SPEC §8 "trusted base" lists F04, F02/F03 validators and release gates; the smoke lint and its schema are a gate that a PR adding a world atom could weaken in the same diff. Add `oracle/smoke/lint.py` and `oracle/smoke/schema.json` to the trusted-base checker list (or rely on F04's protected-test rule, which covers tests but not tools).
- graph.yaml: G05 depends on O02 but also reads R01's world file, R02's `versions.lock` and uses O01's HTTP fixture; R01 and R02 are reachable through B06/O02, so no edge is missing, but R02's completeness gate is a precondition (a missing lock line is an error here).
- SPEC §1 says "99 atoms at b9f533b"; the world file has 99 lines but only 77 lines in `versions.lock` at b9f533b (recipes.yaml coverage_gap, I05 table). Until R02 lands, `{V}` templating cannot run for the 23 atoms the lock lacks (76 of 99 are present). G05's gate presumes R02.
- X01 (graph.yaml) does not depend on G05 (see G01).
