# R05 — rust-crates

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | I02, I03 | P02 | — | M |

**Owns:** `configs/overlay/games-roguelike/rl144/` (new revision), `configs/overlay/www-client/stele/` (new revision), their Manifests and `versions.lock` lines, `scripts/tests/no-network-ebuilds.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `rl144-0.1.0_p20260805.ebuild`, `stele-0.1.0_p20260821.ebuild`, unchanged apart from the crate handling.
**Study refs:** D-supply-chain-honesty, D-revbump-on-overlay-change; SPEC §1 "Reproducibility", §5 "Distfiles".

## Purpose
`rl144` and `stele` fetch Rust crates while they build (`RESTRICT=network-sandbox`; `rl144-0.1.0_p20260805.ebuild:31`, `stele-0.1.0_p20260821.ebuild:34`). Those crates are in no archive, so the release could not be rebuilt offline. After this node both build from distfiles alone, and P02's offline builds can include them.

## Standard mechanism
`cargo.eclass` with a `CRATES` variable, the form Gentoo uses for every Rust package. Each crate becomes a `SRC_URI` entry, Portage fetches it into `DISTDIR` and checks it against the Manifest, and `cargo_src_unpack` sets up an offline vendor directory. The list is generated from the project's `Cargo.lock` with `pycargoebuild`, Gentoo's standard generator. Git dependencies use `GIT_CRATES`. Custom code: none.

## Changes from the port
1. **Crate lists, including std's.** Both ebuilds build with `nightly-2026-07-15` and `-Z build-std=std,panic_abort` for a custom JSON target (`rl144-0.1.0_p20260805.ebuild:26-37,96`, `stele-0.1.0_p20260821.ebuild:30-39,74`). build-std compiles the standard library, whose own crate dependencies come from the toolchain's `lib/rustlib/src/rust/library/Cargo.lock`, not from the project. So `CRATES` must cover two lock files: the project's and the pinned toolchain's `library/Cargo.lock`. Generate `CRATES` (and `GIT_CRATES` if needed) from both. `inherit cargo`, use `cargo_src_unpack` and `cargo_src_compile` (or the existing build commands with `--offline --frozen`), and remove `network-sandbox` from `RESTRICT`. Regenerate the Manifest. *AC-1, AC-2.*
2. **Toolchain.** The ebuilds keep the builder's rustup toolchain, a pinned input through `BUILDER_DIGEST` (I03). Whether `cargo.eclass` accepts it instead of `dev-lang/rust` from the tree is unverified. If not, the smallest fix is a `package.provided` entry for the matching rust version. *AC-2.*
3. **Revbumps** for both packages with their `versions.lock` lines (R04 enforces). *AC-3.*

## Gate
- **R05-AC-1** — No ebuild under `configs/overlay/` has `network-sandbox` in `RESTRICT` or calls `cargo` without `--offline` or `cargo.eclass`. *Verify:* `scripts/tests/no-network-ebuilds.test.sh`. *Tier:* fast.
- **R05-AC-2** — With `DISTDIR` filled only by `emerge --fetchonly` for the two packages, both build in the builder inside `docker run --network none` with `FETCHCOMMAND=/bin/false`, and the binaries run. A smoke run of `rl144 --version` and Stele's existing `stele-acid2` boot mode is enough. *Verify:* a CI dispatch job; O01's `stele-acid2` mode on the next built ISO. *Tier:* slow.
- **R05-AC-3** — Both packages have new revisions, Manifests that list every crate, and matching `versions.lock` lines. *Verify:* `scripts/tests/no-network-ebuilds.test.sh` (counts `CRATES` entries against Manifest `DIST` lines); R04's check. *Tier:* fast.
- **R05-AC-4** — The `CRATES` list covers every package in the builder toolchain's `library/Cargo.lock` as well as the project's, and the offline build in AC-2 compiles std with `-Z build-std` from those distfiles alone. *Verify:* `scripts/tests/no-network-ebuilds.test.sh` (lock-file entries against `CRATES`, with the library lock extracted from the builder image); the AC-2 job. *Tier:* fast + slow.

## Risks
- Unverified: `pycargoebuild` handles both lock files, and Stele's git dependencies (if any) map onto `GIT_CRATES`.
- Unverified: `cargo.eclass` works with the rustup toolchain in the cross builder.
- **Genuine obstacle, unverified either way: offline `-Z build-std`.** cargo must resolve std's dependencies from a vendored source instead of crates.io, and support for that under build-std has been incomplete in some cargo versions. The first slice tests it with `nightly-2026-07-15` and a `[source]` replacement pointing at `cargo_src_unpack`'s vendor directory. If it cannot work, the requirement does not weaken. The owner chooses one of three options before P02 can pass:
  - move the two packages to a toolchain where offline build-std works (a new pinned nightly, through M02);
  - build std for the custom target once, as its own package built from source distfiles;
  - drop `rl144` and `stele` from `world` for the release.
- A large `CRATES` list is long but ordinary. It is Gentoo's normal form, and Manifests check every crate.
