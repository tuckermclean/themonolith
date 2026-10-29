# Capability ledger

Where each capability of The Monolith lives, and how it arrives. A node writes the tests for its
capabilities first (RED), then brings in, or writes, the code that passes them (GREEN). Predecessor
code comes in when a test needs it, not before, and with the edits that test requires.

**Mode:**
- **port**: the predecessor's code, brought in to pass the node's tests, carried unchanged.
- **port+fix**: ported, with the named criteria changing it.
- **build**: new; the predecessor had nothing.
- **replace**: a standard mechanism takes the place of predecessor code.
- **drop**: not ported. The code stays readable in the predecessor at `b9f533b`.

The **Source** column cites the predecessor at `b9f533b`. A capability has one porting node. Later
nodes may change it, listed under **Then**.

## Development and CI

| Capability | Source | Node | Mode | Then |
|---|---|---|---|---|
| Fast lane: `bash -n`, `py_compile`, YAML check, actionlint, shellcheck, run `scripts/tests/*` | `pr-validate.yml:23-69` | F01 | port | each node adds its tests |
| `make test` as the fast tier, run by `pr-validate.yml` in the parity form | — | F01 | build | |
| Action SHA pinning, Dependabot, CODEOWNERS | — | F01 | build | |
| Agent knowledge base: doctrines, traps, recipes, credential handling | `AGENTS.md`, `CLAUDE.md` | F01 | port | I01 (S3 prose) |
| `.gitignore` | `.gitignore` | F01 | port+fix (`out/`) | |
| Licence | `LICENSE` | — | already here, byte-identical | |
| README: what the disc is and how to use it | `README.md` | G01 | port (each promise with its test) | X01 ("Verify a release") |
| No storage vendor anywhere: repo-wide no-AWS check, the one `REGISTRY` variable | — | I01 | build | every porting node strips S3 as it ports |
| Revision bump on overlay change | — | R04 | build | R02 |
| `pkgcheck` over the overlay | — | R02 | build | |
| Workflow-push credential handling (PAT) | `AGENTS.md` | F01 | port | |
| Predecessor agent git helper | `scripts/agent-git-env.sh` | — | drop | `.claude/` replaces it |

## Build inputs

| Capability | Source | Node | Mode | Then |
|---|---|---|---|---|
| Gentoo tree pin: archive, restore by digest, fail loud | `scripts/sync-portage.sh`, `sync-portage.test.sh`, `make sync-portage` | I02 | port+fix | |
| One-time tree archive helper | — | I02 | build | |
| Builder image adopted by digest; `pull-image` | `Makefile` `pull-image`, `print-registry-tag` | I03 | port+fix | M02 |
| Builder image definition | `Dockerfile`, `configs/portage/crossdev.lock`, `Makefile` crossdev block | I03 | port | M02 (rebuild) |
| Builder tool manifest | — | I03 | build | |
| Builder rebuild and toolchain bump | `toolchain-bump.yml`, `make build-image`/`push-image`, `update-build-pins.sh:176-250,332-390` | M02 | port+fix | |
| Tree and version bumps | `pin-bump.yml`, `update-build-pins.sh`, `make update-build-pins`/`update-all`/`bump-pins`/`check-updates` | M01 | port+fix (no `--admin`) | |
| Pin documentation | `docs/version-pinning.md` | M01 | port | |
| Pin regeneration on integration branches | `regen-pins.yml` | — | drop | M01 covers bumps |

## Packages and distribution policy

| Capability | Source | Node | Mode | Then |
|---|---|---|---|---|
| World set (97 of 99 atoms) and `versions.lock` | `configs/portage/{world,versions.lock}`, `update-versions.sh`, `make update-versions` | B01 | port+fix | R05 (two atoms) |
| Distribution policy: `make.conf`, `bashrc`, `env/`, `package.*`, `profile/`, `package.accept_keywords` | `configs/portage/*` | B01 | port | R03 (static hooks) |
| Busybox config | `configs/portage/savedconfig/sys-apps/busybox`, `make menuconfig-busybox` | B01 | port | |
| Overlay repository and its packages: TinyX `monolith-xserver`, `libXfont`, `xcb-proto`, `monolith-st`, `monolith-dwm`, `monolith-perl`, `monolith-sqlite` | `configs/overlay/{metadata,profiles,x11-*,dev-*}` | B01 | port | R02 (QA) |
| Removed packages stay removed | `package.mask/problematic` | B01 | port | |
| Cross-compiling world, failure classification | `scripts/build-packages.sh`, `make build-packages`/`-resume`/`show-failed`/`list-packages`/`shell`/`clean` | B01 | port+fix | P02 (release mode) |
| Binary-package cache on GHCR | `binpkg-store.sh`, `savedconfig-cache.sh`, their tests | B01 | port+fix | |
| Cache tag over builder, tree and global config | — | B01 | build | |
| Sysroot from binary packages | `scripts/extract-packages.sh`, `make extract` | B01 | port | R03 |
| Source audit; unowned gate provenance mode | — | B01 | build | |
| nftables in world | `verify-nftables-pkg.sh` | B01 | port | |
| Static linking everywhere; loader not shipped | `bashrc`, `env/static.conf`, `package.use/static` | B01 | port | R03 (port+fix) |
| Rust packages `rl144`, `stele`, crates as distfiles | `configs/overlay/{games-roguelike,www-client}` | R05 | port+fix | |

## Kernel

| Capability | Source | Node | Mode | Then |
|---|---|---|---|---|
| Kernel package, gcc15 patch | `configs/overlay/sys-kernel/monolith-kernel/` (r8) | B02 | port+fix (r9) | P02 (reproducibility) |
| Kernel config through `savedconfig` | `configs/kernel.config` (moved), `make menuconfig-kernel`, `make regen-manifest` | B02 | port+fix | |
| Driver tiers and their config checks | `docs/kernel-tiers.md`, `scripts/verify-resolved-i2c-off.sh`, `scripts/tests/verify-*-config.sh`, `build.yml:312-420` | B02 | port | |

## Disc userland (`monolith-base`)

| Capability | Source | Node | Mode | Then |
|---|---|---|---|---|
| Help system `monolith` and its topics | `files/monolith`, `files/topics/*`, `monolith.test.sh` | R01 | port | G01 |
| Networking `monolith-net` | `files/monolith-net`, `monolith-net.test.sh` | R01 | port | |
| NAT router `monolith-router` | `files/monolith-router`, `monolith-router.test.sh` | R01 | port | |
| Persistence `monolith-persist` | `files/monolith-persist`, `20-persist.sh`, `50-persist-history.bash`, three `monolith-persist*.test.sh` | R01 | port | G01 |
| Clock honesty `monolith-time`, `monolith-time-check` | `files/monolith-time*`, `30-clock-hint.sh`, two tests | R01 | port | |
| Advisory check | `files/monolith-advisory-check`, `40-advisory.sh` | R01 | port+fix | P03 (the service) |
| Command-not-found, console, prompt square, `which`, `startx`, guestbook | `60-monolith-cnf.bash`, `monolith-console`, `99-monolith-square.bash`, `which`, `startx`, `guestbook.cgi`, `monolith-cnf.test.sh` | R01 | port | |
| The `monolith-base` ebuild | `monolith-base-0.1.0-r6.ebuild` | R01 | port+fix (r7) | |

## Image assembly

| Capability | Source | Node | Mode | Then |
|---|---|---|---|---|
| Root filesystem: generated `/etc`, inittab, init scripts, font index, whatis, os-release | `scripts/build-rootfs.sh`, `scripts/pcf-fontname.py`, `pcf-fontname.test.sh`, `make build-rootfs` | B03 | port+fix (os-release URL, from R01) | P02, R03 |
| Network and router wiring in the rootfs | `verify-rootfs-net-wiring.sh`, `verify-router-wiring.sh` | B03 | port | |
| Initramfs | `scripts/build-initrd.sh`, `rootfs/init`, `rootfs/usr/share/udhcpc/default.script`, `configs/initrd-modules.txt` | B03 | port | P02 |
| Hybrid ISO, boot menus and art | `scripts/build-iso.sh`, `configs/bootbg.png`, `configs/themonolith.ans`, `make iso` | B03 | port | P02 |
| CI build: packages → rootfs → ISO → oracle and gates, files handed over as Actions artifacts | `build.yml` (`changes`, `build`, `boot-test` jobs), `make all` | B03 | port+fix | I03, P02, P01 |

## Oracle and gates

| Capability | Source | Node | Mode | Then |
|---|---|---|---|---|
| 17 boot modes, `-cpu 486`, 64 MB floor; reusable workflow | `scripts/boot-test.py`, `boot-test.yml`, `boot-test-retry.test.sh` | O01 | port | G01 (4 modes) |
| Manual QEMU boots | `make test` (renamed `test-bios`), `make test-uefi` | O01 | port | |
| rc1 lane for the boot tests | — | O01 | build | |
| Doctrine checks on the artifact: static, no loader, `EM_386`, no Python, no freetype, no X modules | `scripts/static-audit.sh` | O02 | port+fix (`scanelf`) | R03 |
| SBOM and its enrichment | `scripts/attestation.sh`, `enrich-sbom.py`, `configs/attestation/{cpe-*,spdx-license-ids.txt,schemas/}`, `make attestation`/`attest-builder` | S01 | port+fix | P01 |
| Licence gate | `check-licenses.py`, `license-policy.yaml` | S01 | port | |
| CVE gate with expiring waivers; canary | `check-cves.sh`, `cve-policy.yaml`, `run-cve-canary.sh`, `canary-sbom.cdx.json`, `cve-gate-canary.yml`, `make grype-db-update`, `docs/cve-gate.md` | S01 | port+fix | |
| Unowned-file gate | `check-unowned.py`, `unowned-allowlist.yaml` | S01 | port+fix | B01 |
| README promises tested or removed | README | G01 | build | |

## Release and after

| Capability | Source | Node | Mode | Then |
|---|---|---|---|---|
| Reproducibility gate: distfile archive, two offline builds, equal digests | `build-initrd.sh:343-353`, `build-rootfs.sh:721-723` (partial) | P02 | build | |
| Attestation | `generate-provenance.py` | P01 | replace (`actions/attest`) | |
| Release: digest chain, SHA256SUMS, prerelease, reports | `release.yml`, `docs/releasing.md` | P01 | port+fix | X01 |
| rc1 diff and size reports | — | P01 | build | |
| Advisory feed on GitHub Pages | `nightly-cve-monitor.py`, `nightly-cve-scan.yml` | P03 | port+fix | |
| Cutover and archive of the predecessor | README "Verify a release" | X01 | build | |

## Dropped

| What | Source | Why |
|---|---|---|
| Dashboard and in-browser boot demo | `web/` (11 files), `boot.html`, `generate-dashboard.py`, `make dashboard` | Out of scope (SPEC §0) |
| Storage retention | `s3-gc.sh`, `ghcr-gc.sh`, their tests, `gc.yml`, `make restore-cache` | Nothing is deleted automatically (SPEC §6); S3 is gone |
| Planning history and a stale readiness report | `docs/superpowers/` (18 files), `RELEASE-READINESS.md` | Not code; readable in the predecessor |
