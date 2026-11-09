#!/bin/sh
# builder-versions.sh: run in the builder image; prints KEY=value lines for the tool versions and the Grype
# database build time that release-inputs.json records. A tool that cannot report fails the script.
set -eu

val() {
	[ -n "$2" ] || { echo "builder-versions: $1 is empty" >&2; exit 1; }
	echo "$1=$2"
}

pkg_version() {
	d=$(ls -d "/var/db/pkg/$1"-[0-9]* 2>/dev/null | head -n 1) || true
	[ -n "$d" ] || { echo "builder-versions: $1 is not installed" >&2; exit 1; }
	v=${d##*/}
	v=${v#"${1##*/}"-}
	echo "$v"
}

val "XORRISO_VERSION" "$(pkg_version dev-libs/libisoburn)"
val "SQUASHFS_TOOLS_VERSION" "$(pkg_version sys-fs/squashfs-tools)"
val "GRUB_VERSION" "$(pkg_version sys-boot/grub)"
val "SYSLINUX_VERSION" "$(pkg_version sys-boot/syslinux)"
val "SYFT_VERSION" "$(syft version | sed -n 's/^Version:[[:space:]]*//p')"
val "GRYPE_VERSION" "$(grype version | sed -n 's/^Version:[[:space:]]*//p')"
val "GRYPE_DB_BUILT" "$(grype db status | sed -n 's/^Built:[[:space:]]*//p')"
