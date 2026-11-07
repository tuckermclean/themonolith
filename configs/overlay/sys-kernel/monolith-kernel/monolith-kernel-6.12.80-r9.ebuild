# Copyright 2024 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit savedconfig

DESCRIPTION="Linux kernel cross-compiled for i486 — The Monolith"
HOMEPAGE="https://kernel.org"
SRC_URI="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PV}.tar.xz"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64"
IUSE="+savedconfig"

S="${WORKDIR}/linux-${PV}"

BDEPEND="
	sys-devel/bc
	sys-devel/flex
	app-alternatives/lex
	sys-devel/bison
	dev-libs/elfutils
"

PATCHES=( "${FILESDIR}/linux-${PV%.*}-gcc15-std-gnu11.patch" )

src_configure() {
	# The pinned config is the package's savedconfig (configs/portage/savedconfig/
	# sys-kernel/monolith-kernel, synced into the target's /etc/portage). restore_config
	# only warns when it finds nothing, so a missing file is checked and fatal here.
	local saved="${PORTAGE_CONFIGROOT%/}/etc/portage/savedconfig/${CATEGORY}/${PN}"
	[[ -f ${saved} ]] || die "No kernel savedconfig at ${saved} — expected configs/portage/savedconfig/${CATEGORY}/${PN} in the checkout"
	restore_config .config || die "Failed to restore the kernel savedconfig"
	[[ -f .config ]] || die "restore_config left no .config (is USE=savedconfig set?)"
	einfo "Loaded kernel config from ${saved}"
	make ARCH=i386 CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig || die "olddefconfig failed"
}

src_compile() {
	# -j1: cross-gcc is memory-heavy; higher parallelism OOMs CI runners
	emake -j1 ARCH=i386 CROSS_COMPILE="${CROSS_COMPILE}" bzImage modules
}

src_install() {
	insinto /boot
	newins arch/x86/boot/bzImage vmlinuz-${PV}
	dosym vmlinuz-${PV} /boot/vmlinuz

	# Install loadable kernel modules into the target sysroot. They ride into the
	# rootfs squashfs via build-rootfs.sh's `rsync -a sysroot/ rootfs/`, so the
	# booted system's coldplug can load exactly the drivers each machine has.
	# INSTALL_MOD_STRIP=1 keeps them small (486 disk + gzip-decompress budget).
	emake ARCH=i386 CROSS_COMPILE="${CROSS_COMPILE}" \
		INSTALL_MOD_PATH="${D}" INSTALL_MOD_STRIP=1 modules_install

	# modules_install leaves build/ and source/ symlinks pointing at the
	# ephemeral build tree (dangling in the image). Drop them, then regenerate
	# modules.dep rooted at the image so on-target modprobe resolves deps.
	local krel
	krel="$(make -s ARCH=i386 kernelrelease)"
	rm -f "${D}/lib/modules/${krel}/build" "${D}/lib/modules/${krel}/source"
	depmod -b "${D}" "${krel}"

	# Ship the resolved (post-olddefconfig) .config as package content, gzipped
	# (486-minimalism — raw .config is ~100-250 KiB of dead weight on the ISO;
	# gzip -9 gets it down to kernel.org's own config.gz convention size).
	# Because it rides inside the binpkg's CONTENTS, it is installed identically
	# whether monolith-kernel is built from source or pulled from the binpkg
	# cache. This is what makes scripts/verify-resolved-i2c-off.sh a real assertion
	# on both CI paths instead of a vacuous pass on the common cache-hit path (DCX-99).
	insinto /usr/share/monolith-kernel
	gzip -9c .config > "${T}/resolved-kernel.config.gz" || die "Failed to gzip resolved kernel config"
	doins "${T}/resolved-kernel.config.gz"
}

pkg_config() {
	# Run menuconfig interactively, starting from the savedconfig, and write the result
	# to /output/kernel.config.new (the checkout's output/ in the builder container).
	# Nothing under /configs is written: review the result and copy it to the savedconfig by hand.
	local saved="${PORTAGE_CONFIGROOT%/}/etc/portage/savedconfig/${CATEGORY}/${PN}"
	[[ -f ${saved} ]] || die "No kernel savedconfig at ${saved}"
	[[ -d /output ]] || die "/output is not mounted; run this in the builder container with the checkout's output/ mounted at /output"

	# Re-extracts source into T to avoid needing the build workdir to persist
	einfo "Setting up kernel source for menuconfig..."
	local src="${T}/linux-${PV}"
	mkdir -p "${src}"
	local distfiles
	distfiles=$(portageq distdir || echo "/var/cache/distfiles")
	tar xf "${distfiles}/linux-${PV}.tar.xz" -C "${src}" --strip-components=1 || die "Failed to extract linux-${PV}"

	pushd "${src}" >/dev/null || die

	# Apply patches — use EBUILD path since FILESDIR/DISTDIR aren't populated for pkg_* phases
	eapply "${EBUILD%/*}/files/linux-${PV%.*}-gcc15-std-gnu11.patch"

	cp "${saved}" .config || die "Failed to load the kernel savedconfig"
	make ARCH=i386 CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig || die "olddefconfig failed"

	# Interactive menuconfig
	make ARCH=i386 CROSS_COMPILE="${CROSS_COMPILE}" menuconfig || die "menuconfig failed"

	cp .config /output/kernel.config.new || die "Failed to save kernel config"
	einfo "Kernel config saved to output/kernel.config.new"

	popd >/dev/null || die
}
