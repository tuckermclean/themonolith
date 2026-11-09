# Sourced by Portage for every package (user profile).
# Zeroes the wall-clock stamps in gzip headers and ar armaps in the image before Portage computes CONTENTS.
# Strip rewrites every ar archive after src_install and stamps the armap again, so the image is normalised twice:
# at the end of src_install (binpkg contents) and just before the image is merged.
_monolith_normalize_image() {
	local nd="${PORTAGE_CONFIGROOT:-/}etc/portage/profile/normalize-d.sh"
	[[ -f ${nd} ]] || die "normalize-d.sh not found at ${nd}"
	sh "${nd}" "${D}" || die "normalize-d.sh failed on ${D}"
}

post_src_install() {
	_monolith_normalize_image
}

pre_pkg_preinst() {
	_monolith_normalize_image
}
