# Copyright 2026 the-monolith
# Distributed under the terms of the GNU General Public License v2

EAPI=8

# The toolchain comes from the builder image via rustup, not dev-lang/rust, so
# the eclass must not add the rust BDEPEND (pkg_setup below skips rust_pkg_setup).
RUST_OPTIONAL=1

CRATES="
	addr2line@0.25.1
	adler2@2.0.1
	bitflags@1.3.2
	bitflags@2.13.1
	bumpalo@3.20.3
	cc@1.2.0
	cc@1.3.0
	cfg-if@1.0.4
	cty@0.2.2
	dlmalloc@0.2.13
	find-msvc-tools@0.1.9
	foldhash@0.2.0
	font8x8@0.3.1
	fortanix-sgx-abi@0.6.1
	futures-channel@0.3.33
	futures-core@0.3.33
	futures-executor@0.3.33
	futures-io@0.3.33
	futures-macro@0.3.33
	futures-sink@0.3.33
	futures-task@0.3.33
	futures-util@0.3.33
	futures@0.3.33
	getopts@0.2.24
	gimli@0.32.3
	hashbrown@0.17.1
	hermit-abi@0.5.2
	instant@0.1.13
	js-sys@0.3.103
	lazy_static@1.5.0
	libc@0.2.185
	libc@0.2.186
	libredox@0.1.18
	memchr@2.7.6
	memchr@2.8.3
	minifb@0.25.0
	miniz_oxide@0.8.9
	moto-rt@0.16.0
	object@0.37.3
	once_cell@1.21.4
	orbclient@0.3.55
	pin-project-lite@0.2.17
	pkg-config@0.3.33
	plain@0.2.3
	proc-macro2@1.0.106
	quote@1.0.46
	r-efi-alloc@2.1.0
	r-efi@5.3.0
	rand@0.9.2
	rand_core@0.9.3
	rand_xorshift@0.4.0
	raw-window-handle@0.4.3
	redox_syscall@0.9.0
	rustc-demangle@0.1.28
	rustc-literal-escaper@0.0.8
	rustversion@1.0.23
	sdl2-sys@0.38.0
	sdl2@0.38.0
	serde@1.0.228
	serde_core@1.0.228
	serde_derive@1.0.228
	shlex@1.3.0
	shlex@2.0.1
	slab@0.4.12
	syn@2.0.119
	unicode-ident@1.0.24
	unwinding@0.2.8
	version-compare@0.1.1
	vex-sdk@0.27.1
	wasip1@1.0.0
	wasip2@1.0.3+wasi-0.2.9
	wasip3@0.6.0+wasi-0.3.0-rc-2026-03-15
	wasm-bindgen-futures@0.4.76
	wasm-bindgen-macro-support@0.2.126
	wasm-bindgen-macro@0.2.126
	wasm-bindgen-shared@0.2.126
	wasm-bindgen@0.2.126
	web-sys@0.3.103
	winapi-i686-pc-windows-gnu@0.4.0
	winapi-x86_64-pc-windows-gnu@0.4.0
	winapi@0.3.9
	wit-bindgen@0.57.1
	x11-dl@2.21.0
"

inherit cargo

DESCRIPTION="rl144 — a deterministic, integer-only roguelike built for the 486DX"
HOMEPAGE="https://github.com/tuckermclean/rl144"

# Pinned to a specific commit (no release tag yet). As of this sync master and
# feature/happy-valley have converged, so this HEAD carries both the 486 target
# spec/design docs AND the LICENSE. GitHub's per-commit archive is the DIST
# tarball; the Manifest pins its exact bytes. If GitHub's archive gzip ever
# drifts and the hash mismatches, host the tarball in the project's own S3 and
# repoint SRC_URI.
COMMIT="f33a80efc4b0b02ce72e708182594b84695e742d"
SRC_URI="https://github.com/tuckermclean/rl144/archive/${COMMIT}.tar.gz -> ${P}.tar.gz ${CARGO_CRATE_URIS}"
S="${WORKDIR}/rl144-${COMMIT}"

# rl144 is MIT-licensed; the LICENSE file is present in this commit's tree (the
# earlier happy-valley/master split is resolved now that they've converged), so
# the shipped source carries it and src_install dodoc's it below.
LICENSE="MIT"

# Licences of the crates linked into the binary (CRATES above, project and std).
# Names are Gentoo names; each dependency's choice of licence is an || group.
LICENSE+="
	BSD
	MIT
	MPL-2.0
	Unicode-3.0
	ZLIB
	|| ( 0BSD Apache-2.0 MIT )
	|| ( Apache-2.0 Apache-2.0-with-LLVM-exceptions MIT )
	|| ( Apache-2.0 LGPL-2.1+ MIT )
	|| ( Apache-2.0 MIT )
	|| ( Apache-2.0 MIT ZLIB )
	|| ( MIT Unlicense )
"
SLOT="0"
KEYWORDS="~amd64"

# build-std compiles Rust's std itself, so CRATES covers std's own crate deps
# (the nightly's rust-src library/Cargo.lock) as well as the project's
# Cargo.lock. cargo_src_unpack vendors them from DISTDIR and writes an offline
# cargo config, so the build needs no network. No cargo_src_compile: its
# cargo_env cross/linker handling does not fit the custom JSON target below.
RESTRICT="test"

# The Rust toolchain is provided by the builder image via rustup (see Dockerfile),
# NOT by portage: nightly + -Zbuild-std for a custom JSON target is a rustup
# workflow, and i486 has no prebuilt Rust std. This pin MUST match the
# Dockerfile's RUST_NIGHTLY.
RUST_NIGHTLY="nightly-2026-07-15"
RUST_TARGET="i486-unknown-linux-musl"

pkg_setup() {
	# rust_pkg_setup would die: it looks for an installed dev-lang/rust(-bin).
	# This package uses the builder's rustup toolchain (RUST_NIGHTLY below).
	:
}

src_compile() {
	local target_json="${FILESDIR}/${RUST_TARGET}.json"
	[[ -f "${target_json}" ]] || die "target spec missing: ${target_json}"

	# The rustup toolchain lives system-wide in the builder image; give cargo its
	# own writable CARGO_HOME/target inside the build dir. Re-export RUSTUP_HOME
	# and PATH here in case portage's env filtering dropped them.
	export RUSTUP_HOME="${RUSTUP_HOME:-/opt/rustup}"
	export CARGO_HOME="${ECARGO_HOME}"
	export CARGO_TARGET_DIR="${WORKDIR}/cargo-target"
	export PATH="/opt/cargo/bin:${PATH}"

	# Link the custom i486 target with the crossdev musl gcc — the same toolchain
	# that builds the rest of the ISO. CHOST is i486-linux-musl under cross-emerge,
	# so ${CHOST}-gcc is i486-linux-musl-gcc. cargo derives the env-var target name
	# from the JSON filename stem (i486-unknown-linux-musl).
	export "CARGO_TARGET_I486_UNKNOWN_LINUX_MUSL_LINKER=${CHOST}-gcc"

	# Diagnostics: confirm CHOST/linker resolve as expected and show where the
	# crossdev musl gcc driver actually finds its crt objects (crtend.o/crtn.o),
	# in case the crossdev sysroot layout is nonstandard.
	einfo "CHOST=${CHOST}  linker=${CARGO_TARGET_I486_UNKNOWN_LINUX_MUSL_LINKER}"
	i486-linux-musl-gcc -print-file-name=crtn.o || true
	i486-linux-musl-gcc -print-file-name=crtend.o || true
	i486-linux-musl-gcc -print-search-dirs || true

	# link-self-contained=no: by default rustc links "self-contained" —
	# passes -nostartfiles -nodefaultlibs, supplies its own bare
	# crt1.o/crti.o/crtbegin.o/crtend.o/crtn.o, and only -L's its own
	# rustlib self-contained dir (empty for this custom target; those
	# objects live in the crossdev toolchain, not rustc's sysroot). This
	# was the source of "cannot find crtend.o/crtn.o". Disabling
	# self-contained linking lets the i486-linux-musl-gcc driver supply
	# its own crt objects/libs from paths it already knows (confirmed via
	# -print-file-name above: crtn.o under /usr/i486-linux-musl/usr/lib/,
	# crtend.o under /usr/lib/gcc/i486-linux-musl/15/).
	#
	# The target spec itself now sets "panic-strategy": "abort" (see
	# files/i486-unknown-linux-musl.json), matching rl144's Cargo.toml
	# profile.release panic="abort" all the way down through build-std.
	# That does NOT remove the -lunwind reference on its own — std's
	# backtrace support still references _Unwind_* symbols regardless of
	# panic strategy, so rustc still links -lunwind. The crossdev
	# musl/gcc toolchain has no standalone libunwind at all; the unwinder
	# lives in libgcc. Alias libgcc's unwinder archive as libunwind.a so
	# the link resolves against the real _Unwind_* symbols it provides.
	local _unwind
	_unwind=$("${CHOST}-gcc" -print-file-name=libgcc_eh.a)
	[[ -f "${_unwind}" ]] || _unwind=$("${CHOST}-gcc" -print-file-name=libgcc.a)
	mkdir -p "${T}/unwindlib"
	ln -sf "${_unwind}" "${T}/unwindlib/libunwind.a"
	einfo "aliased libunwind -> ${_unwind}"
	export RUSTFLAGS="-Clink-self-contained=no -Clink-arg=-L${T}/unwindlib ${RUSTFLAGS}"

	einfo "Cross-compiling rl144 for ${RUST_TARGET} (nightly build-std, backend-term)"
	cargo "+${RUST_NIGHTLY}" \
		-Z build-std=std,panic_abort \
		-Z json-target-spec \
		build --release --offline --frozen \
		--no-default-features --features backend-term \
		--target "${target_json}" \
		--manifest-path "${S}/Cargo.toml" \
		|| die "cargo build failed"
}

src_install() {
	local bin="${CARGO_TARGET_DIR}/${RUST_TARGET}/release/rl144"
	[[ -x "${bin}" ]] || die "rl144 binary not found at ${bin}"

	# The rootfs is all-static and i486: a dynamic or wrong-arch binary would
	# fail at boot. Verify before shipping (readelf reads the ELF header
	# arch-independently on the x86_64 host).
	if command -v readelf >/dev/null 2>&1; then
		readelf -l "${bin}" 2>/dev/null | grep -q 'INTERP' \
			&& die "rl144 is dynamically linked (needs crt-static)"
		readelf -h "${bin}" 2>/dev/null | grep -qE 'Intel 80386|:.*386' \
			|| ewarn "rl144 ELF machine is not Intel 80386 — check the target spec"
	fi

	# Install to /usr/bin (on the default PATH) rather than /usr/games/bin,
	# which the rootfs does not add to PATH — mirrors where games-misc/bsd-games
	# land so `rl144` is runnable straight from the shell like the other games.
	exeinto /usr/bin
	doexe "${bin}"

	dodoc "${S}/LICENSE"
	dodoc "${S}/docs/design/486/2026-08-04-boot-on-a-486-scope.md" 2>/dev/null || true
}
