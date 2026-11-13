# The Monolith

An artifact from the future: one live CD with a complete, modern Linux userland, in text mode or in
X (TinyX with dwm and st), that boots on a 486 and on a modern UEFI machine. It is a Gentoo-derived
distribution, cross-compiled from source for i486 against musl, statically linked, and attested end to
end. The aim is a 486 with 8 MB of RAM; the floor tested today is 64 MB.

Why it exists: [`MYTH.md`](MYTH.md).

This repository continues
[linux-live-iso-factory](https://github.com/tuckermclean/linux-live-iso-factory), which released
`v0.1.0-rc1`. It ports the predecessor's working recipes, scripts, tests and workflows, replaces the dead
S3 storage with GHCR and GitHub Releases, and fixes the bugs a study of the predecessor verified. It
uses Portage, crossdev and the standard kernel, ISO, QEMU and supply-chain tools, and writes custom code
only where they leave a gap. The build workflow builds an ISO from this repository and the boot tests run on it.

Licensed under the [MIT License](LICENSE).

## The specification

| Start here | What it is |
|---|---|
| [`SPEC.md`](SPEC.md) | The authority: product and constraints, principles, doctrines, architecture, the standard-mechanism table (§5), pins, oracle, release, open decisions |
| [`docs/first-release.md`](docs/first-release.md) | The plan: a working ISO for iteration first, then the first release; surviving assets, owner actions, order of work, measured timings |
| [`docs/graph.yaml`](docs/graph.yaml) | 25 nodes, their dependencies and three milestones |
| [`nodes/`](nodes/) | One spec per node, each with its acceptance criteria |
| [`AGENTS.md`](AGENTS.md), [`CLAUDE.md`](CLAUDE.md) | Working notes for agents: layout, constraints, spec editing, what not to touch |
| [`docs/study/`](docs/study/) | The frozen study of the predecessor at `b9f533b`: inventory, recipes, oracle, doctrines and traps |

Milestones:
- **MS1:** a working, testable ISO for iteration, built by CI from pinned inputs with the oracle green.
  It may leave out the two Rust packages, `rl144` and `stele`. It is not a release and is never
  published.
- **MS2:** the first release. Two clean offline builds produce the same ISO SHA-256, the ISO ships all
  99 of the predecessor's packages including `rl144` and `stele`, and only then is it tested, attested
  and published as a prerelease.
- **MS3:** cutover to the first non-prerelease.

## What is on the disc

The [world file](configs/portage/world) lists 99 top-level atoms, cross-compiled for `i486-linux-musl`.
Every one has a row in `scripts/smoke-checks.txt`: the `smoke` boot mode runs most, and the rest are covered by a named mode (the kernel by `bios`, the X server, `st` and `dwm` by `gui`, `stele` by `stele-acid2`). Some are overlay
ebuilds (`monolith-*`: the kernel, the base `/etc` and helper scripts, perl, sqlite, the X server, `st`, `dwm`),
two are Rust (`rl144`, `stele`), and the rest come from the pinned Gentoo tree.

| Category | Packages |
|---|---|
| Kernel / init | `sys-kernel/monolith-kernel`, `sys-apps/sysvinit`, `sys-apps/busybox` (initrd) |
| Base system | `app-misc/monolith-base` (`/etc`, init scripts, `monolith-net`, `monolith-router`, `monolith-persist`) |
| Shells | `app-shells/bash`, `app-shells/dash`, `app-shells/zsh`, `app-shells/bash-completion` |
| GNU userland | `sys-apps/coreutils`, `sys-apps/util-linux`, `sys-apps/findutils`, `sys-apps/grep`, `sys-apps/sed`, `sys-apps/gawk`, `sys-apps/diffutils`, `app-arch/tar`, `app-text/tree` |
| Libraries | `sys-libs/readline`, `sys-libs/ncurses`, `sys-libs/zlib`, `dev-libs/libpcre2`, `dev-libs/openssl` |
| Files and editors | `sys-apps/file`, `sys-apps/less`, `app-editors/vim`, `app-editors/nano` |
| Man pages | `sys-apps/man-pages`, `app-text/mandoc` |
| Dev tools | `sys-devel/binutils`, `dev-build/make`, `dev-debug/strace`, `sys-devel/patch`, `dev-debug/gdb` |
| Scripting and databases | `dev-lang/lua`, `dev-lang/monolith-perl`, `dev-db/monolith-sqlite` |
| Compression | `app-arch/xz-utils`, `app-arch/bzip2`, `app-arch/gzip`, `app-arch/zip`, `app-arch/unzip`, `app-arch/cpio` |
| Network configuration | `sys-apps/iproute2`, `sys-apps/net-tools`, `net-misc/iputils`, `net-misc/dhcpcd`, `sys-apps/ethtool` |
| Router | `net-firewall/nftables`, `net-dns/dnsmasq` |
| Serial links and remote access | `net-dialup/ppp`, `net-misc/dropbear` |
| Network clients | `net-misc/curl`, `net-misc/wget`, `net-misc/whois`, `net-analyzer/netcat`, `net-analyzer/traceroute`, `www-client/lynx`, `mail-client/mutt`, `net-irc/irssi` |
| Network analysis | `net-misc/socat`, `net-analyzer/iftop`, `net-analyzer/tcpdump`, `net-analyzer/mtr`, `net-misc/iperf:3` |
| Terminal and users | `app-misc/tmux`, `sys-apps/shadow` |
| System utilities | `sys-process/procps`, `sys-process/htop`, `sys-process/lsof`, `sys-process/psmisc`, `app-admin/sysklogd`, `sys-apps/pv`, `<sys-fs/ncdu-2` |
| Modules and filesystems | `sys-apps/kmod`, `sys-fs/e2fsprogs`, `sys-fs/dosfstools`, `sys-fs/squashfs-tools` |
| Search and sync | `net-misc/rsync`, `sys-apps/the_silver_searcher` |
| Hardware info | `sys-apps/smartmontools`, `sys-apps/hdparm`, `sys-apps/dmidecode` |
| Console | `sys-apps/kbd`, `media-fonts/terminus-font`, `sys-libs/gpm` |
| X (bitmap fonts only, no freetype) | `x11-base/monolith-xserver`, `x11-base/xorg-proto`, `x11-libs/libxcb`, `x11-libs/libX11`, `x11-libs/libXext`, `x11-terms/monolith-st`, `x11-wm/monolith-dwm` |
| Browser | `www-client/stele` |
| Amusements | `games-misc/bsd-games`, `app-misc/figlet`, `app-misc/cmatrix`, `app-misc/sl`, `games-roguelike/rl144`, `=games-roguelike/nethack-3.6.7-r1` |

There is no native compiler on the disc (`sys-devel/gcc` is not in the world file).

## Booting

The ISO boots by BIOS (ISOLINUX) and by 64-bit UEFI (GRUB). The `bios` mode boots it at 64 MB of RAM under
QEMU with `-cpu 486`; the `uefi` mode boots it under OVMF.

ISOLINUX labels, typed at the `boot:` prompt. The default is `fb800`. The `entry` mode
boots each label and checks that the kernel command line has the parameters shown.

| Label | Kernel command line (checked by `entry`) |
|---|---|
| `linux` | No extra parameters |
| `fb` | `quiet vga=791` (1024x768) |
| `fb800` | `quiet vga=788` (800x600), the default |
| `fb640` | `quiet vga=785` (640x480) |
| `vga` | `vga=ask` |
| `serial` | `console=ttyS0,115200n8` |
| `debug` | `debug` |
| `persist` | `persist` |
| `rescue` | `rescue` |

The GRUB menu has seven entries, in order: normal, framebuffer, serial, debug, rescue shell, `toram` and
persistent. The `entry` mode boots each. The `toram` kernel parameter copies the root filesystem into RAM
so the boot medium can be ejected; the `toram` mode ejects the CD and checks that the system survives.

## Persistence

`monolith-persist init <dev> [--swap N] [--yes]` makes `<dev>` an ext4 filesystem labelled
`MONOLITH_PERSIST`, which erases it, and optionally creates an N MB swapfile in it. Boot with the `persist`
label to use it as the overlay. The swapfile is not enabled
automatically: run `swapon /overlay/swapfile`. Without such a partition the overlay is in RAM and the boot
prints a warning. The `persist-init` mode runs this whole sequence, including a file that survives an
unclean shutdown.

## Networking

The initrd's BusyBox and the packages above provide `ip`, `ifconfig`, `dhcpcd`, `curl`, `wget`,
`tcpdump` and the rest of the network tools. `monolith-router` turns the disc into a NAT router with DHCP and
DNS for a LAN (the `nat` mode). The `nic` mode boots with the emulated `pcnet`, `rtl8139`, `tulip`,
`ne2k_pci` and `ne2k_isa` cards.

Boot starts `dhcpcd` on `eth0` by itself; the `bios` and `uefi` modes check that `eth0` has a DHCP-assigned address.

The `serial-net` mode joins two guests with a serial line on `ttyS1` and runs these between them. `ttyS0`
is the console. The disc has no standalone `slattach`; use BusyBox's.

```
busybox slattach -p slip /dev/ttyS1
pppd /dev/ttyS1 115200 noauth local logfile /tmp/pppd.log 10.2.2.1:10.2.2.2 connect "chat -t 60 '' AT OK ATD5551212 CONNECT"
```

SSH: start the server with `dropbear`. The first boot creates one host key, an ECDSA one
(`/etc/init.d/S20keygen`). The `serial-net` mode logs in with a key over a forwarded port.

## Graphical environment

The X stack uses bitmap fonts only: no freetype, fontconfig or Xft. `startx` starts the TinyX `Xfbdev`
server on the framebuffer, the `dwm` window manager and an `st` terminal. Boot a framebuffer label such as
`fb800` first. The `gui` mode runs `startx` and checks that the server and `st` run and the screen is not
blank. The `stele-acid2` mode renders the Acid2 page with `stele`, the document-web browser.

## Verify a release

Download the ISO and `SHA256SUMS` from the release, check the digest, then verify the attestation. An
ISO from this repository (replace `<ver>` with the release version, for example `0.2.0`):

```sh
gh release download v<ver> --repo tuckermclean/themonolith \
  --pattern 'themonolith-<ver>.iso' --pattern SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify themonolith-<ver>.iso \
  --repo tuckermclean/themonolith \
  --signer-workflow tuckermclean/themonolith/.github/workflows/build.yml
```

The predecessor's `v0.1.0-rc1` ISO was signed by the predecessor's workflow, so it verifies against
that repository and not against this one:

```sh
gh release download v0.1.0-rc1 --repo tuckermclean/linux-live-iso-factory \
  --pattern 'themonolith-0.1.0-rc1.iso' --pattern SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify themonolith-0.1.0-rc1.iso \
  --repo tuckermclean/linux-live-iso-factory \
  --signer-workflow tuckermclean/linux-live-iso-factory/.github/workflows/build.yml
```

The commands name the repository and the signer workflow. `--owner` alone is not used, because it
accepts an attestation from any repository of the owner.

Each release carries a report of what changed since rc1 among its assets, `rc1-diff.md`.
The link points at the latest final release:
[`rc1-diff.md`](https://github.com/tuckermclean/themonolith/releases/latest/download/rc1-diff.md).

## Testing

The tests run in the [toolbox](toolbox/) (`toolbox/run`). The checks that need no ISO:

```
make test-lint test-unit
```

`test-unit` runs every `scripts/tests/*.sh`, including three that check this README. They check the platform-support wording against dated evidence and the kernel's paravirtual driver symbols, the names of the boot tests, the SLIP and PPP command lines, the SSH key type, the boot menu default and the verification commands. They do not check every other sentence.
The ISO is booted in QEMU under TCG by `scripts/boot-test.py`:

```
make test-boot MODE=<mode>
```

The boot modes are `bios`, `uefi`, `toram`, `ahci`, `nvme`, `usb`, `virtio`, `nicless`, `nic`, `vga`,
`fbdev-modprobe`, `nat`, `gui`, `stele-acid2`, `clock-epoch`, `clock-1996`, `persist`, `persist-init`,
`entry`, `serial-net` and `smoke`. `MODES="bios uefi"` runs several. The disc is not tested on Hyper-V.
