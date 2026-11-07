# Fixture for static-rebuild.itest.sh (B01-AC-16): a static library that carries a marker string.
EAPI=8

inherit toolchain-funcs

DESCRIPTION="Test fixture: a static library returning LIBMARKER-PVR"
LICENSE="public-domain"
SLOT="0"
KEYWORDS="x86"
IUSE="alt"

S="${WORKDIR}"

src_compile() {
	local marker="LIBMARKER-${PVR}"
	use alt && marker+="-alt"
	printf 'const char *libmarker(void) { return "%s"; }\n' "${marker}" > libmarker.c
	printf 'const char *libmarker(void);\n' > libmarker.h
	"$(tc-getCC)" ${CFLAGS} -c libmarker.c -o libmarker.o || die
	"$(tc-getAR)" rcs libmarker.a libmarker.o || die
}

src_install() {
	insinto /usr/include
	doins libmarker.h
	dolib.a libmarker.a
}
