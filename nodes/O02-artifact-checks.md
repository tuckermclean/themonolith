# O02 — artifact-checks

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | F01 | B03, R03 | — | M |

**Owns:** `scripts/static-audit.sh` (extended), `configs/attestation/dynamic-allowlist.txt`, `configs/attestation/rc1-static-audit.expected`, `.github/workflows/artifact-checks.yml` (reusable), `.github/workflows/artifact-checks-rc1.yml` (caller), the `test-artifact` Make target (part of `make test`), `scripts/tests/static-audit.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `scripts/static-audit.sh` (124 lines; report-only, `--strict` never used), and its non-fatal call at `scripts/build-rootfs.sh:742-756`, which stays as it is.
**Study refs:** D-all-static, D-no-dynamic-loading-no-dlopen, D-no-python-on-target, D-bitmap-fonts-no-freetype, D-static-musl-cross-all-the-way, T-freetype-chain, T-unowned-allowlist (shrink-only lists); the predecessor copies a musl loader into the sysroot (`scripts/extract-packages.sh:147-157`) for binaries it expected to be dynamic, but rc1 ships none; RELEASE-READINESS.md:304 ("runs unconditionally, never fails the build"); OD-2.

## Purpose
After this node the doctrines that a boot test cannot see are checked on the shipped rootfs and can fail a build. The predecessor wrote the audit and ran it only as a report, so its comments still expect util-linux, iproute2, dhcpcd, procps, tar and gawk to be dynamic and a loader to ship. O02's scan of rc1's squashfs (2026-10-30): 543 ELF files, all `EM_386`, 456 static `ET_EXEC` and 87 kernel modules; no `PT_INTERP`, no `ET_DYN`, no `ld-musl-i386.so.1`. What rc1 does ship against the doctrines is Python: 14 `.py` files (libevent's `event_rpcgen.py`, xcb-proto's `xcbgen`, glib's and gdb's scripts). The check first runs on rc1's squashfs and records those.

## Standard mechanism
`scanelf` from pax-utils reads `PT_INTERP`, `e_machine` and text relocations from ELF headers directly. It comes from the pinned toolbox (`pax-utils` in `toolbox/Containerfile`), never from `apt-get` on the runner; this node adds no ELF parser. The Portage VDB (`var/db/pkg`) names the packages that were installed. Plain `find` covers file-name rules. `lddtree` and `readelf` were considered; `scanelf -R` already prints each of the three fields for a whole tree in one call.

Custom residue: the allowlist (`dynamic-allowlist.txt`) and the rc1 expected-findings file. Gap: no standard tool knows which dynamic binaries this project tolerates today. The smallest form is a text file of paths with a reason per line, shrunk by owner-reviewed PRs (`configs/attestation/` is CODEOWNERS-protected, SPEC §8).

## Tests
- **Ported first:** none; `static-audit.sh` is itself a check and is ported as code.
- **Added:** `scripts/tests/static-audit.test.sh`.
- **Baseline:** `b9f533b`'s `static-audit.sh` on the rc1 rootfs gives the expected rc1 failures this node records.

## Changes from the port
1. **`file` is replaced by `scanelf`.** The ported loop runs `file -b` on each executable (`static-audit.sh:95`). It only visits files with the user-execute bit (`find -perm -u+x`, `:108`), so a non-executable shared object is never seen. `scanelf -R` visits every ELF. Proved by AC-2, AC-3.
2. **Findings are lines, and `--strict` is what CI runs.** Each finding is `FINDING <check> <path>` in the report. Checks: `interp` (PT_INTERP not allowlisted), `machine` (not `EM_386`), `loader` (see 3), `python`, `font`, `plugin`. Text relocations are listed as `INFO textrel <path>` and do not fail; no doctrine forbids them. `build-rootfs.sh` keeps calling the script without `--strict`, so the squashfs bytes cannot change. Proved by AC-2 to AC-6.
3. **Musl loader rule.** `lib/ld-musl-i386.so.1` must exist if and only if the allowlist has at least one entry. An empty allowlist with a loader fails; a non-empty allowlist without a loader fails (the listed binaries would not start). Proved by AC-3.
4. **Allowlist.** `dynamic-allowlist.txt` holds one rootfs-relative path per line followed by `# <issue> <reason>`. A line with no comment fails. An entry that matches no file, or a file that is no longer dynamic, fails as stale. The file starts empty, because rc1 has no dynamic binary; OD-2 (prereleases may ship with entries) governs later additions. `--require-empty-allowlist` fails on any entry; P01 passes it for non-prerelease tags. Proved by AC-3, AC-4.
5. **Other doctrines** (all path-based, on the extracted tree):
   - no ELF file named `*.so` or `*.so.*` outside `lib/modules/` and not allowlisted. This covers perl XS, sqlite extensions, ppp plugins and X modules (`usr/lib/xorg/modules`). Only ELF files count: rc1's man pages `ld.so.8` and `ld-linux.so.8` match the names;
   - no `*.py` or `*.pyc` file, and no file or directory named `python` or `python[0-9]*` under `bin`, `sbin`, `lib`, `usr/bin`, `usr/sbin` or `usr/lib` (an interpreter or its library). Data files elsewhere named after Python (rc1's vim scripts, bash completions, `usr/share/misc/magic/python`) are not findings;
   - no `*libfreetype*`, `*libfontconfig*`, `*libXft*`, `etc/fonts`, `usr/share/fontconfig`, and no `var/db/pkg/*/freetype-*`, `fontconfig-*` or `libXft-*` (a static freetype leaves no `.so`, so the VDB entry is the only trace).
   Proved by AC-5, AC-6.
6. **No hidden failures.** The ported script has `2>/dev/null` on `find` and `file` and a bare `|| continue` (`:95,:108`; the one at `:73` is dropped too, for a plain grep test), and exits 0 after scanning nothing (`:124`). Both are removed: a missing target, a missing `scanelf`, or zero ELF files scanned is exit 1. Proved by AC-1.
7. **`make test-artifact`.** Part of `make test`: it extracts the squashfs of `ISO` and runs `static-audit.sh --strict` through `toolbox/run`. Until B03 builds an ISO, the default `ISO` is rc1's behind its sha256, as for `test-boot`. When the ISO's sha256 is rc1's, the target instead runs change 8's comparison, as `test-boot` does for vga: rc1's Python files fail `--strict`, and no allowlist covers them. `artifact-checks.yml` and `artifact-checks-rc1.yml` call this target and nothing else for the check; neither installs a package. Proved by AC-8.
8. **rc1 lane.** `artifact-checks-rc1.yml` runs the script with `--no-allowlist` on rc1's squashfs and compares the findings, sorted, with `rc1-static-audit.expected`. Every line of that file carries a comment with its study id (`D-no-python-on-target` for rc1's 14 `.py` files). A differing finding set fails the lane, so an expected failure cannot hide a new one. Proved by AC-7.

## Gate
- **O02-AC-1** — `static-audit.sh` exits non-zero when the target is missing, when `scanelf` is not on PATH, and when no ELF file is found; none of the three is reported as a clean audit. *Verify:* `bash scripts/tests/static-audit.test.sh` (stub `scanelf`, temp trees).
- **O02-AC-2** — A non-executable file with a `PT_INTERP`, and an `EM_X86_64` file, each produce a failing `FINDING` under `--strict`; a clean `EM_386` tree passes. *Verify:* `bash scripts/tests/static-audit.test.sh` (stub `scanelf` output).
- **O02-AC-3** — Allowlist rules: an allowlisted dynamic file passes; a stale entry, an entry without an issue comment, and the loader present with an empty list (or absent with a non-empty list) each fail. *Verify:* `bash scripts/tests/static-audit.test.sh`.
- **O02-AC-4** — `--require-empty-allowlist` fails on a one-entry file and passes on an empty one. *Verify:* `bash scripts/tests/static-audit.test.sh`.
- **O02-AC-5** — An ELF `.so` outside `lib/modules/`, a `usr/bin/python3` file, a `.py` file, a `libfreetype` file and a `var/db/pkg/media-libs/freetype-2.13` directory each fail under `--strict`; a non-ELF `usr/share/man/man8/ld.so.8` and a `usr/share/bash-completion/completions/python3.bash` do not. *Verify:* `bash scripts/tests/static-audit.test.sh`.
- **O02-AC-6** — `static-audit.sh` contains no `2>/dev/null`, and `build-rootfs.sh` still calls it without `--strict`. *Verify:* `bash scripts/tests/static-audit.test.sh` (grep).
- **O02-AC-7** — On rc1's squashfs, with real `scanelf` and `--no-allowlist`, the sorted findings equal `rc1-static-audit.expected`, and the lane is green. The file holds only `python` findings, and the allowlist is empty. *Verify:* `artifact-checks-rc1.yml`, on its pull request and by dispatch after merge.
- **O02-AC-8** — `make test` depends on `test-artifact`, which runs `static-audit.sh` through `toolbox/run` on the default `ISO`'s squashfs, with `--strict` unless the ISO's sha256 is rc1's (then change 8's comparison); `artifact-checks.yml` and `artifact-checks-rc1.yml` contain no `apt-get`, `pip` or `setup-*` step, and their check step is a `make` target. *Verify:* `bash scripts/tests/static-audit.test.sh` (`make -n` and a grep of the workflows).

## Risks
- Verified on rc1 in the toolbox (2026-10-30): `scanelf` (pax-utils) has `-R`, `-B`, `-i`, `-t`, `-F` with `%a`, `%i`, `%o`, `%t`, `%F`; the ISO holds `/rootfs.squashfs` at its root (`xorriso -osirrox on -extract`); non-root `unsquashfs -no-xattrs` extracts it (rc1 has no device nodes); `var/db/pkg` is kept (43 categories).
- A stripped static binary linking `dlopen` leaves no symbol; this check relies on "no loader, no `.so`" and does not prove absence of the call.
- The rc1 expected-findings file is generated by the first run and reviewed once; the review is a human task.
