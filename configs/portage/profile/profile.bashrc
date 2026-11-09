# Sourced by Portage for every package (user profile).
# Zeroes the wall-clock stamps in gzip headers and ar armaps in the image before Portage computes CONTENTS.
# The image is normalised twice. The first pass is at the end of src_install, so the binpkg carries normalised files
# (estrip restamps armaps after post_src_install, so the binpkg keeps those). The second pass is
# in post_pkg_preinst, the last point before the merge, so the merged image has them zeroed again.
# A binpkg carries these functions in its saved environment, so a binary merge on a system without
# normalize-d.sh warns and skips instead of dying; a source build without it dies.
_monolith_normalize_image() {
	local nd="" d
	for d in "${PORTAGE_CONFIGROOT:-/}etc/portage/profile" /configs/portage/profile; do
		if [[ -f ${d}/normalize-d.sh ]]; then
			nd="${d}/normalize-d.sh"
			break
		fi
	done
	if [[ -z ${nd} ]]; then
		if [[ ${EMERGE_FROM} == binary ]]; then
			ewarn "normalize-d.sh not found; the binary package is merged as built"
			return 0
		fi
		die "normalize-d.sh not found under ${PORTAGE_CONFIGROOT:-/}etc/portage/profile or /configs/portage/profile"
	fi
	sh "${nd}" "${D}" || die "normalize-d.sh failed on ${D}"
}

post_src_install() {
	_monolith_normalize_image
}

post_pkg_preinst() {
	_monolith_normalize_image
}
