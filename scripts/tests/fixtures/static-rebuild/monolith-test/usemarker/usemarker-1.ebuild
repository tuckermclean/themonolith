# Fixture for static-rebuild.itest.sh (B01-AC-16): a static consumer of libmarker.
# libmarker is in DEPEND only, as for every static consumer in the rootfs.
EAPI=8

inherit toolchain-funcs

DESCRIPTION="Test fixture: a static binary printing libmarker's string"
LICENSE="public-domain"
SLOT="0"
KEYWORDS="x86"

DEPEND="monolith-test/libmarker"

S="${WORKDIR}"

src_compile() {
	printf '#include <stdio.h>\n#include <libmarker.h>\nint main(void) { puts(libmarker()); return 0; }\n' > usemarker.c
	"$(tc-getCC)" ${CFLAGS} ${LDFLAGS} -static -I"${ESYSROOT}/usr/include" usemarker.c \
		-L"${ESYSROOT}/usr/lib" -lmarker -o usemarker || die
}

src_install() {
	dobin usemarker
}
