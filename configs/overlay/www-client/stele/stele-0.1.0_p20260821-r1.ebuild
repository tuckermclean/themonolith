# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

# The toolchain comes from the builder image via rustup, not dev-lang/rust, so
# the eclass must not add the rust BDEPEND (pkg_setup below skips rust_pkg_setup).
RUST_OPTIONAL=1

CRATES="
	addr2line@0.25.1
	adler2@2.0.1
	arrayvec@0.7.8
	bitflags@1.3.2
	bitflags@2.13.1
	cc@1.2.0
	cfg-if@1.0.4
	color_quant@1.1.0
	crc32fast@1.5.0
	dlmalloc@0.2.13
	errno@0.3.14
	fdeflate@0.3.7
	flate2@1.1.9
	foldhash@0.2.0
	fortanix-sgx-abi@0.6.1
	getopts@0.2.24
	gif@0.13.3
	gimli@0.32.3
	hashbrown@0.17.1
	hermit-abi@0.5.2
	jpeg-decoder@0.3.2
	libc@0.2.185
	libc@0.2.189
	linux-raw-sys@0.12.1
	memchr@2.7.6
	miniz_oxide@0.8.9
	moto-rt@0.16.0
	object@0.37.3
	png@0.17.16
	proc-macro2@1.0.107
	quote@1.0.47
	r-efi-alloc@2.1.0
	r-efi@5.3.0
	rand@0.9.2
	rand_core@0.9.3
	rand_xorshift@0.4.0
	rustc-demangle@0.1.28
	rustc-literal-escaper@0.0.8
	rustix@1.1.4
	serde@1.0.229
	serde_core@1.0.229
	serde_derive@1.0.229
	shlex@1.3.0
	simd-adler32@0.3.10
	slotmap@1.1.1
	smallvec@1.15.2
	syn@3.0.3
	taffy@0.13.0
	unicode-ident@1.0.24
	unwinding@0.2.8
	version_check@0.9.5
	vex-sdk@0.27.1
	wasip1@1.0.0
	wasip2@1.0.3+wasi-0.2.9
	wasip3@0.6.0+wasi-0.3.0-rc-2026-03-15
	weezl@0.1.12
	windows-link@0.2.1
	windows-sys@0.61.2
	wit-bindgen@0.57.1
"

inherit cargo

DESCRIPTION="Stele — a finished document-web browser for the 486 (Rust, static, no JavaScript, direct framebuffer)"
HOMEPAGE="https://github.com/tuckermclean/stele-browser"

# Stele is under ACTIVE development (a moving target): this is pinned to a
# specific HEAD commit, NOT a release tag. REPIN EACH BUILD while it churns —
# bump COMMIT + the _pYYYYMMDD date (and -rN if repinning the same day, to bust
# the S3 --usepkg binpkg cache, see [[overlay-ebuild-revbump-busts-binpkg-cache]])
# and regenerate the Manifest. GitHub per-commit archive is the DIST tarball,
# Manifest-pinned (games-roguelike/rl144 precedent; S3 only if GitHub's gzip
# drifts). Version tracks Cargo.toml (0.1.0) + the commit date.
COMMIT="0e4921bbb85c88899a7919a45415a8d749df3ec8"
SRC_URI="https://github.com/tuckermclean/stele-browser/archive/${COMMIT}.tar.gz -> ${P}.tar.gz ${CARGO_CRATE_URIS}"
S="${WORKDIR}/stele-browser-${COMMIT}"

# License: GPL-3 (owner's choice, 2026-08-14). GPL-3 is in portage's @FREE set,
# so this declaration is what actually satisfies the Monolith's ACCEPT_LICENSE
# gate (unset → @FREE) — the emerge accepts it regardless of a repo file. The
# owner is adding a matching GPL-3 LICENSE file to the stele-browser repo (for
# legal correctness + the dodoc below); until it lands, dodoc LICENSE is guarded.
# The compiled-in 8x8 glyph atlas (src/text/glyphs.rs) is separately public-domain.
LICENSE="GPL-3"
SLOT="0"
KEYWORDS="~amd64"

# build-std compiles Rust's std itself, so CRATES covers std's own crate deps
# (the nightly's rust-src library/Cargo.lock) as well as the project's
# Cargo.lock. cargo_src_unpack vendors them from DISTDIR and writes an offline
# cargo config, so the build needs no network. No cargo_src_compile: its
# cargo_env cross/linker handling does not fit the custom JSON target below.
RESTRICT="test"

# The Rust toolchain comes from the monolith-builder image via rustup (see
# Dockerfile), NOT portage. This pin MUST match rust-toolchain.toml in the repo
# AND the Dockerfile's RUST_NIGHTLY (shared with rl144).
RUST_NIGHTLY="nightly-2026-07-15"
RUST_TARGET="i486-monolith-linux-musl"

pkg_setup() {
	# rust_pkg_setup would die: it looks for an installed dev-lang/rust(-bin).
	# This package uses the builder's rustup toolchain (RUST_NIGHTLY below).
	:
}

src_compile() {
	# Stele ships its own i486 floor target spec in-tree (targets/*.json) — no
	# need to stage one from FILESDIR (unlike rl144).
	local target_json="${S}/targets/${RUST_TARGET}.json"
	[[ -f "${target_json}" ]] || die "target spec missing: ${target_json}"

	export RUSTUP_HOME="${RUSTUP_HOME:-/opt/rustup}"
	export CARGO_HOME="${ECARGO_HOME}"
	export CARGO_TARGET_DIR="${WORKDIR}/cargo-target"
	export PATH="/opt/cargo/bin:${PATH}"

	# Link with the crossdev musl gcc (same toolchain as the rest of the ISO).
	# cargo derives the linker env-var name from the JSON target's filename stem
	# (i486-monolith-linux-musl → I486_MONOLITH_LINUX_MUSL).
	export "CARGO_TARGET_I486_MONOLITH_LINUX_MUSL_LINKER=${CHOST}-gcc"

	# Stele DECISIONS D7 (same fix rl144 needs): even with panic=abort, std's
	# musl unwind crate references the _Unwind_* API, so rustc still links
	# -lunwind. The crossdev musl/gcc toolchain has no standalone libunwind — the
	# unwinder lives in libgcc — so alias libgcc_eh.a (fallback libgcc.a) as
	# libunwind.a and add its dir to the link path. The target spec sets
	# self-contained linking off, so the gcc driver supplies crt objects itself.
	local _unwind
	_unwind=$("${CHOST}-gcc" -print-file-name=libgcc_eh.a)
	[[ -f "${_unwind}" ]] || _unwind=$("${CHOST}-gcc" -print-file-name=libgcc.a)
	mkdir -p "${T}/unwindshim"
	ln -sf "${_unwind}" "${T}/unwindshim/libunwind.a"
	einfo "aliased libunwind -> ${_unwind}"
	export RUSTFLAGS="-L ${T}/unwindshim ${RUSTFLAGS}"

	einfo "Cross-compiling Stele for ${RUST_TARGET} (nightly build-std)"
	cargo "+${RUST_NIGHTLY}" \
		-Z build-std=std,panic_abort \
		-Z json-target-spec \
		build --release --offline --frozen \
		--target "${target_json}" \
		--manifest-path "${S}/Cargo.toml" \
		|| die "cargo build failed"
}

src_install() {
	local bin="${CARGO_TARGET_DIR}/${RUST_TARGET}/release/stele"
	[[ -x "${bin}" ]] || die "stele binary not found at ${bin}"

	# All-static i486 rootfs: a dynamic or wrong-arch binary would fail at boot
	# (Stele acceptance check A1). Verify before shipping.
	if command -v readelf >/dev/null 2>&1; then
		readelf -l "${bin}" 2>/dev/null | grep -q 'INTERP' \
			&& die "stele is dynamically linked (crt-static did not stick)"
		readelf -h "${bin}" 2>/dev/null | grep -qE 'Intel 80386|:.*386' \
			|| ewarn "stele ELF machine is not Intel 80386 — check the target spec"
	fi

	exeinto /usr/bin
	doexe "${bin}"

	# Ship Stele's own Acid2 conformance page as a sample/demo the disc can
	# render fully offline (the page is self-contained — data: URIs, no external
	# fetches — which is exactly what Stele's data:-URI support was built for).
	# The boot-test `stele-acid2` mode renders this to the framebuffer and
	# screendumps it. Ebuild-owned -> auto-attested (no unowned-allowlist entry).
	if [[ -f "${S}/fixtures/acid2.html" ]]; then
		insinto /usr/share/stele
		doins "${S}/fixtures/acid2.html"
	else
		ewarn "fixtures/acid2.html missing in the stele-browser checkout — the stele-acid2 demo page will not ship"
	fi

	# EAPI-8 dodoc die()s on a missing file (|| can't catch its internal die),
	# so only ship docs that actually exist. LICENSE is picked up automatically
	# once the owner adds the GPL-3 file to the repo; Stele has REPORT.md, not a
	# README. (The repo's stele-charter.md / build-brief are dev docs, skipped.)
	local d
	for d in LICENSE REPORT.md DECISIONS.md JOURNAL.md; do
		[[ -f "${S}/${d}" ]] && dodoc "${S}/${d}"
	done
	[[ -f "${S}/LICENSE" ]] || ewarn "no LICENSE file in the stele-browser repo yet (LICENSE=GPL-3 declared) — owner to add it"
}
