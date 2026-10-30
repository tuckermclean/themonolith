# R03 — all-static

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | O02, B03 | X01 | — | L |

**Owns:** `configs/portage/env/`, `configs/portage/package.env/`, `configs/portage/package.use/static`, `configs/portage/bashrc` (static-link hooks), O02's allowlist file (shrinking only), edits to `extract-packages.sh:147-157` and `build-packages.sh:384-385`.
**Ports from linux-live-iso-factory@b9f533b:** nothing new. It changes the static mechanism B01 ported in `configs/portage/{make.conf,bashrc,env/static.conf,env/no-static-ldflags.conf,package.env/cross-compile,package.use/static}`.
**Study refs:** D-all-static (contradicted_by: README.md:127, RELEASE-READINESS.md:108-118, `extract-packages.sh:147-157`, `build-packages.sh:384-385`); D-no-dynamic-loading-no-dlopen; OD-2.

## Purpose
The dynamic-binary allowlist is empty and no musl loader ships. This is required before the first non-prerelease (OD-2 default).

## Standard mechanism
Gentoo gives, in order: a `static` or `static-libs` USE flag if the ebuild has one; a `package.env` entry with `LDFLAGS=-static` (rc1 already applies `*/* static.conf`, `package.env/cross-compile`); build-system patches in `bashrc` (rc1 patches libtool, meson, gpm, kmod there, `bashrc:6-170`); or dropping the package from `world`. Custom code: none new.

## Tests
- **Ported first:** none. B01's ported tests and O02's checks stay in the lane and must keep passing.
- **Added:** the tests the Gate names.
- **Baseline:** O02's checks on the rc1 rootfs give the starting allowlist this node shrinks.

## Changes from the port
1. **Per-binary fixes.** rc1 lists these as dynamic PIE: util-linux (`mount`, `agetty`, `mountpoint`; no `static` USE flag, per `RELEASE-READINESS.md:108-118`), iproute2, dhcpcd, procps, tar, gawk, "and a few others" (`README.md:127`). The exact set is unknown until O02 scans rc1; use that list. `static.conf` already sets `-static` globally, so for each binary the first step is to find why it did not reach the link line (libtool, a plain Makefile that overrides `LDFLAGS`, or `--enable-pie`) from the package build log. Then, in order of preference:
   - a `package.env` entry for a plain-Makefile package that passes `LDFLAGS=-static` through `emake` (as `bashrc` does for gpm; candidates: iproute2, procps, tar, gawk; unverified);
   - an ebuild configure option or USE flag, found with `equery uses` (candidates: dhcpcd, util-linux; unverified);
   - for `agetty`, a static replacement: busybox `getty` has `CONFIG_GETTY` unset in its savedconfig (`savedconfig/sys-apps/busybox:539`), and `/etc/inittab` spawns `agetty` (`build-rootfs.sh:356-360`); enabling it would need an initrd-vs-rootfs decision, because README says busybox is initrd-only;
   - dropping the package, if nothing on the disc needs it.
   Each fix is a revbump-free config edit covered by B01's cache tag. *AC-1.*
2. **Loader.** When the allowlist is empty, delete the musl `libc.so` copy to `/lib/ld-musl-i386.so.1` (`extract-packages.sh:147-157`, `build-packages.sh:384-385`, and its warning). O02's `musl-loader` rule then holds. *AC-2.*
3. **Allowlist entries removed one at a time**, each in its own PR, so a boot regression names its cause. *AC-3.*

## Gate
- **R03-AC-1** — O02's check passes with an empty dynamic-binary allowlist on a built ISO. *Verify:* the `artifact-checks` job in build.yml. *Tier:* slow.
- **R03-AC-2** — No `ld-musl-i386.so.1` in the squashfs, and neither script copies it. *Verify:* O02 `musl-loader` rule; `grep -r 'ld-musl-i386' scripts/` returns nothing outside tests. *Tier:* slow, fast.
- **R03-AC-3** — All 17 boot modes pass on the all-static ISO. *Verify:* boot-test.yml. *Tier:* slow.
- **R03-AC-4** — The allowlist file only shrinks across the node's PRs. *Verify:* O02's shrink check. *Tier:* fast.

## Risks
- The dynamic set is unknown until O02 scans rc1 (OD-2). The candidate fixes above are unverified guesses from rc1's comments, not tested.
- util-linux `mount` and `agetty` are boot-critical (`inittab`); a failure shows only in the boot tests.
- Static dhcpcd and iproute2 may need patches that outweigh keeping them (D-486-minimalism review).
