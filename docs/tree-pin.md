# The pinned Gentoo tree

rc1's Gentoo tree is the gentoo-mirror commit below, archived once as `gentoo-tree:<commit>` in the
registry and restored by digest (`scripts/seed-tree.sh`, `scripts/sync-portage.sh`, the `TREE_COMMIT` and
`TREE_DIGEST` pins in the `Makefile`). The snapshot tarball rc1 used no longer exists upstream.

The pin (`github.com/gentoo-mirror/gentoo`, committer time 2026-08-11T23:00:56Z):

6e88ed01f3e97de8710efe1c333808dfbd05bf32

## Where it comes from

rc1's Portage VDB (`var/db/pkg`, 163 entries) has 152 entries with `repository = gentoo` and 11 with
`repository = monolith`. Every gentoo entry's `REPO_REVISIONS` is

    {"gentoo": "6622796b6162d6f41b6556041027f19e7964028e"}

That is gentoo.git commit `6622796b` (2026-08-11T22:55:37Z, "dev-util/cargo-tarpaulin: add 0.37.0"). The
mirror merges it at `ebecde92eb07df95e8385a7d33c1a68ba8da8ea9` (23:00:48Z, second parent `6622796b`). The next
commit, `6e88ed01` (23:00:56Z, "2026-08-11 23:00:56 UTC"), regenerates `metadata/md5-cache` and
`timestamp.chk`; it is the pin. The following merge, `c4b67600` (01:15Z), brings later gentoo.git commits.

## Cross-check of the ebuilds

The git blob id of each gentoo entry's `<pf>.ebuild` was compared with `<cat>/<pn>/<pf>.ebuild` at the pin:
152 of 152 match. The 152 entries compared:

- acct-group/dnsmasq-0-r3
- acct-group/gamestat-0-r3
- acct-group/mail-0-r3
- acct-group/root-0-r2
- acct-group/shadow-0
- acct-group/sshd-0-r3
- acct-user/dnsmasq-0-r3
- acct-user/mail-0-r3
- acct-user/postmaster-0-r3
- acct-user/root-0-r3
- acct-user/sshd-0-r3
- app-admin/eselect-1.4.32
- app-admin/sysklogd-2.7.2
- app-alternatives/bzip2-1
- app-alternatives/cpio-0
- app-alternatives/gzip-1
- app-alternatives/tar-0
- app-arch/bzip2-1.0.8-r5
- app-arch/cpio-2.15
- app-arch/gzip-1.14
- app-arch/tar-1.35-r1
- app-arch/unzip-6.0_p29-r2
- app-arch/xz-utils-5.8.3
- app-arch/zip-3.0-r7
- app-crypt/libmd-1.2.0
- app-editors/nano-9.2
- app-editors/vim-9.1.1652-r2
- app-editors/vim-core-9.1.1652-r3
- app-eselect/eselect-lua-4-r3
- app-eselect/eselect-vi-20221122
- app-misc/ca-certificates-20260601.3.112.5
- app-misc/cmatrix-2.0-r6
- app-misc/editor-wrapper-4-r1
- app-misc/figlet-2.2.5-r2
- app-misc/mime-types-2.1.54
- app-misc/sl-5.02-r1
- app-misc/tmux-3.6a
- app-shells/bash-5.3_p15
- app-shells/bash-completion-2.18.0
- app-shells/dash-0.5.13.5
- app-shells/gentoo-bashcomp-20250620
- app-shells/zsh-5.9.1
- app-text/mandoc-1.14.6-r1
- app-text/tree-2.3.2
- app-vim/gentoo-syntax-16
- dev-build/make-4.4.1-r102
- dev-debug/gdb-17.2
- dev-debug/strace-7.1
- dev-lang/lua-5.4.8
- dev-libs/cJSON-1.7.19
- dev-libs/expat-2.8.3
- dev-libs/glib-2.88.3
- dev-libs/gmp-6.3.0-r2
- dev-libs/jansson-2.15.1
- dev-libs/libbsd-0.11.8
- dev-libs/libevent-2.1.13
- dev-libs/libffi-3.7.1
- dev-libs/libiconv-1.18
- dev-libs/libintl-0.23.2
- dev-libs/libpcre-8.45-r4
- dev-libs/libpcre2-10.47
- dev-libs/mpfr-4.2.2
- dev-libs/openssl-3.6.3
- dev-libs/popt-1.19-r1
- dev-util/pkgconf-3.0.5
- dev-util/xxd-2025.08.24-r1
- games-misc/bsd-games-3.3
- games-roguelike/nethack-3.6.7-r1
- mail-client/mutt-2.4.1
- media-fonts/terminus-font-4.49.1-r3
- net-analyzer/iftop-1.0_pre4-r5
- net-analyzer/mtr-0.96-r1
- net-analyzer/netcat-110.20180111-r2
- net-analyzer/tcpdump-4.99.6
- net-analyzer/traceroute-2.1.5
- net-dialup/ppp-2.5.3
- net-dialup/ppp-scripts-0
- net-dns/dnsmasq-2.93
- net-firewall/nftables-1.1.6
- net-irc/irssi-1.4.5-r2
- net-libs/libmnl-1.0.5
- net-libs/libnftnl-1.3.1
- net-libs/libpcap-1.10.6
- net-mail/mailbase-1.8.1
- net-misc/curl-8.21.0-r1
- net-misc/dhcpcd-10.3.2
- net-misc/dropbear-2026.94
- net-misc/gsasl-2.2.4
- net-misc/iperf-3.21
- net-misc/iputils-20250605-r4
- net-misc/rsync-3.4.4
- net-misc/socat-1.8.1.3
- net-misc/wget-1.25.0-r2
- net-misc/whois-5.6.6
- sys-apps/busybox-1.36.1-r4
- sys-apps/coreutils-9.11-r1
- sys-apps/diffutils-3.12
- sys-apps/dmidecode-3.7
- sys-apps/ethtool-7.0
- sys-apps/file-5.48
- sys-apps/findutils-4.11.0
- sys-apps/gawk-5.4.1
- sys-apps/gentoo-functions-1.7.7
- sys-apps/grep-3.12
- sys-apps/hdparm-9.65-r2
- sys-apps/iproute2-7.0.0
- sys-apps/kbd-2.10.0
- sys-apps/kmod-34.2
- sys-apps/less-704
- sys-apps/man-pages-6.17-r1
- sys-apps/miscfiles-1.5-r4
- sys-apps/net-tools-2.10
- sys-apps/pv-1.10.4
- sys-apps/sed-4.10-r1
- sys-apps/shadow-4.20.0
- sys-apps/smartmontools-7.5-r1
- sys-apps/sysvinit-3.18
- sys-apps/the_silver_searcher-2.2.0_p20201217-r4
- sys-apps/util-linux-2.42.2
- sys-devel/binutils-2.46.1
- sys-devel/binutils-config-5.6
- sys-devel/patch-2.8-r1
- sys-fs/dosfstools-4.2
- sys-fs/e2fsprogs-1.47.4
- sys-fs/ncdu-1.22
- sys-fs/squashfs-tools-4.7.5
- sys-kernel/linux-headers-7.1
- sys-libs/gpm-1.20.7-r6
- sys-libs/ncurses-6.5_p20251220
- sys-libs/readline-8.3_p3
- sys-libs/zlib-1.3.2-r1
- sys-process/htop-3.5.2
- sys-process/lsof-4.99.7
- sys-process/procps-4.0.6
- sys-process/psmisc-23.7
- virtual/libcrypt-2-r1
- virtual/libiconv-0-r2
- virtual/libintl-0-r2
- virtual/man-0-r4
- virtual/os-headers-0-r2
- virtual/pkgconfig-3
- virtual/zlib-1.3.1-r1
- www-client/lynx-2.9.2
- x11-base/xorg-proto-2025.1
- x11-libs/libX11-1.8.13
- x11-libs/libXau-1.0.12
- x11-libs/libXdmcp-1.1.5
- x11-libs/libXext-1.3.7
- x11-libs/libfontenc-1.1.9
- x11-libs/libxcb-1.17.0
- x11-libs/xtrans-1.6.0
- x11-misc/compose-tables-1.8.13

The 11 overlay entries (`repository = monolith`) are excepted: app-misc/monolith-base-0.1.0-r6,
dev-db/monolith-sqlite-3.53.4, dev-lang/monolith-perl-5.42.0-r5, games-roguelike/rl144-0.1.0_p20260805,
sys-kernel/monolith-kernel-6.12.80-r6, www-client/stele-0.1.0_p20260821, x11-base/monolith-xserver-1.3_p20241113-r1,
x11-base/xcb-proto-1.17.0, x11-libs/libXfont-1.5.4-r1, x11-terms/monolith-st-0.9.2-r2,
x11-wm/monolith-dwm-6.5-r2.

The blob match does not single out a commit. Over the 157 first-parent mirror commits from 2026-08-09 to
2026-08-12T06:00Z, 61 match all 152 entries, 86 match 151 and 10 match 150; full matches start at
2026-08-11T06:15:46Z. The earlier candidate `d4d0b0c7` matches 151: it lacks
`dev-libs/expat/expat-2.8.3.ebuild`, added in gentoo.git `3702b1b3`. `REPO_REVISIONS` decides; the blob match only
rules out a wrong mapping.

## Signature

The pin carries a `gpgsig`. `git verify-commit` against `/usr/share/openpgp-keys/gentoo-release.asc`:

- in the rc1 builder: signature good, "Good signature from Gentoo repository mirrors (automated git signing
  key) <repomirrorci@gentoo.org>", key `F748E9B3C47E393CC24C8FAF7C2AC09CD98F2EDF` (not certified by a trusted
  signature, as expected without a web of trust);
- in the toolbox, which has no `gpg`: `signature: key-missing`.

## The archive

`git archive --format=tar 6e88ed01f3e97de8710efe1c333808dfbd05bf32 | zstd -q -19 -T1` gives
`gentoo-tree-6e88ed01f3e97de8710efe1c333808dfbd05bf32.tar.zst`, 32093134 bytes (130089 files), sha256
`017cff6b6140c51c283c003d2d4629b84ae901ad315ebd64a17c08358b72b7bc`. It is byte-reproducible in the toolbox
(zstd 1.5.7). It is pushed as one layer of media type `application/vnd.themonolith.gentoo-tree.layer.v1.tar+zstd`,
artifact type `application/vnd.themonolith.gentoo-tree.v1`, annotation `org.opencontainers.image.created` =
2026-08-11T23:00:56Z, tag `6e88ed01f3e97de8710efe1c333808dfbd05bf32`. The manifest digest, computed with oras 1.2.0
into an OCI layout before any push and the same on every run:

    TREE_DIGEST = sha256:b01bbe7a886fa869a4018a5f711e11fae8fb783b30878216b0f8f408ad2a70bd

A change to the file name, media types, annotation or compression level changes the digest.

## Acceptance with Portage (I02-AC-2)

In the rc1 builder, with the pinned tree, rc1's binary packages and `b9f533b`'s `configs/portage` and overlay,
`emerge -pv --usepkgonly` of the 99 world atoms lists 151 `[binary` and 0 `[ebuild`, exit 0. The 142 gentoo
packages it chose equal rc1's VDB versions exactly. Overlay packages resolve from rc1's binary packages
(`::monolith`). rc1's other 10 gentoo entries are build-time or overlay-pulled dependencies: acct-group/mail,
acct-user/mail, acct-user/postmaster, dev-util/pkgconf, net-mail/mailbase, sys-kernel/linux-headers,
virtual/os-headers, virtual/pkgconfig, x11-libs/libfontenc, x11-libs/xtrans.

## Recording

The `tree-accept` workflow (`workflow_dispatch`) archives the tree when the tag is absent, checks the registry's
manifest digest against `TREE_DIGEST` and the restored file count against the archive (I02-AC-3), then extracts
the archive with no network and compares (I02-AC-5).
