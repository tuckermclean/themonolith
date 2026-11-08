#!/bin/sh
# builder-versions.sh: run in the builder image; prints KEY=value lines for the tool versions and the Grype
# database build time that release-inputs.json records. A tool that cannot report fails the script.
set -eu

pkg_version() {
	d=$(ls -d "/var/db/pkg/$1"-[0-9]* 2>/dev/null | head -n 1) || true
	[ -n "$d" ] || { echo "builder-versions: $1 is not installed" >&2; exit 1; }
	v=${d##*/}
	v=${v#"${1##*/}"-}
	echo "$v"
}

echo "XORRISO_VERSION=$(pkg_version dev-libs/libisoburn)"
echo "SQUASHFS_TOOLS_VERSION=$(pkg_version sys-fs/squashfs-tools)"
echo "GRUB_VERSION=$(pkg_version sys-boot/grub)"
echo "SYSLINUX_VERSION=$(pkg_version sys-boot/syslinux)"
echo "SYFT_VERSION=$(syft version | sed -n 's/^Version:[[:space:]]*//p')"
echo "GRYPE_VERSION=$(grype version | sed -n 's/^Version:[[:space:]]*//p')"
echo "GRYPE_DB_BUILT=$(grype db status | sed -n 's/^Built:[[:space:]]*//p')"
