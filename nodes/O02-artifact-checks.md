# O02 — artifact-checks

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | F01 | B03, R03 | — | M |

**Owns:** `scripts/static-audit.sh` (extended), `configs/attestation/dynamic-allowlist.txt`, `configs/attestation/rc1-static-audit.expected`, `.github/workflows/artifact-checks.yml` (reusable), `.github/workflows/artifact-checks-rc1.yml` (caller), `scripts/tests/static-audit.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** `scripts/static-audit.sh` (124 lines; report-only, `--strict` never used), and its non-fatal call at `scripts/build-rootfs.sh:742-756`, which stays as it is.
**Study refs:** D-all-static, D-no-dynamic-loading-no-dlopen, D-no-python-on-target, D-bitmap-fonts-no-freetype, D-static-musl-cross-all-the-way, T-freetype-chain, T-unowned-allowlist (shrink-only lists); contradiction: the musl loader ships (`scripts/extract-packages.sh:147-157`) while the doctrine says it does not; RELEASE-READINESS.md:304 ("runs unconditionally, never fails the build"); OD-2.

## Purpose
After this node the doctrines that a boot test cannot see are checked on the shipped rootfs and can fail a build. The predecessor wrote the audit, ran it only as a report, and so never noticed that util-linux, iproute2, dhcpcd, procps, tar and gawk are dynamic, and that a musl loader ships. The check first runs on rc1's squashfs and records what rc1 gets wrong.

## Standard mechanism
`scanelf` from pax-utils reads `PT_INTERP`, `e_machine` and text relocations from ELF headers directly. It is installed on the runner (`apt-get install pax-utils`) or in the builder; this node adds no ELF parser. The Portage VDB (`var/db/pkg`) names the packages that were installed. Plain `find` covers file-name rules. `lddtree` and `readelf` were considered; `scanelf -R` already prints each of the three fields for a whole tree in one call.

Custom residue: the allowlist (`dynamic-allowlist.txt`) and the rc1 expected-findings file. Gap: no standard tool knows which dynamic binaries this project tolerates today. The smallest form is a text file of paths with a reason per line, shrunk by owner-reviewed PRs (`configs/attestation/` is CODEOWNERS-protected, SPEC §8).

## Changes from the port
1. **`file` is replaced by `scanelf`.** The ported loop runs `file -b` on each executable (`static-audit.sh:95`). It only visits files with the user-execute bit (`find -perm -u+x`, `:108`), so a non-executable shared object is never seen. `scanelf -R` visits every ELF. Proved by AC-2, AC-3.
2. **Findings are lines, and `--strict` is what CI runs.** Each finding is `FINDING <check> <path>` in the report. Checks: `interp` (PT_INTERP not allowlisted), `machine` (not `EM_386`), `loader` (see 3), `python`, `font`, `plugin`. Text relocations are listed as `INFO textrel <path>` and do not fail; no doctrine forbids them. `build-rootfs.sh` keeps calling the script without `--strict`, so the squashfs bytes cannot change. Proved by AC-2 to AC-6.
3. **Musl loader rule.** `lib/ld-musl-i386.so.1` must exist if and only if the allowlist has at least one entry. An empty allowlist with a loader fails; a non-empty allowlist without a loader fails (the listed binaries would not start). Proved by AC-3.
4. **Allowlist.** `dynamic-allowlist.txt` holds one rootfs-relative path per line followed by `# <issue> <reason>`. A line with no comment fails. An entry that matches no file, or a file that is no longer dynamic, fails as stale. The file is seeded from the rc1 findings (OD-2 default: prereleases may ship with entries). `--require-empty-allowlist` fails on any entry; P01 passes it for non-prerelease tags. Proved by AC-3, AC-4.
5. **Other doctrines** (all path-based, on the extracted tree):
   - no `*.so` or `*.so.*` file outside `lib/modules/` and not allowlisted. This covers perl XS, sqlite extensions, ppp plugins and X modules (`usr/lib/xorg/modules`);
   - no file named `python*`, `*.py` or `*.pyc`;
   - no `*libfreetype*`, `*libfontconfig*`, `*libXft*`, `etc/fonts`, `usr/share/fontconfig`, and no `var/db/pkg/*/freetype-*`, `fontconfig-*` or `libXft-*` (a static freetype leaves no `.so`, so the VDB entry is the only trace).
   Proved by AC-5, AC-6.
6. **No hidden failures.** The ported script has `2>/dev/null` on `find` and `file` and a bare `|| continue` (`:95,:108`; the one at `:73` is dropped too, for a plain grep test), and exits 0 after scanning nothing (`:124`). Both are removed: a missing target, a missing `scanelf`, or zero ELF files scanned is exit 1. Proved by AC-1.
7. **rc1 lane.** `artifact-checks-rc1.yml` runs the script with `--no-allowlist` on rc1's squashfs and compares the findings, sorted, with `rc1-static-audit.expected`. Every line of that file carries a comment with its study id (`D-all-static` for dynamic binaries, the loader contradiction for `loader`). A differing finding set fails the lane, so an expected failure cannot hide a new one. Proved by AC-7.

## Gate
- **O02-AC-1** — `static-audit.sh` exits non-zero when the target is missing, when `scanelf` is not on PATH, and when no ELF file is found; none of the three is reported as a clean audit. *Verify:* `bash scripts/tests/static-audit.test.sh` (stub `scanelf`, temp trees). *Tier:* fast.
- **O02-AC-2** — A non-executable file with a `PT_INTERP`, and an `EM_X86_64` file, each produce a failing `FINDING` under `--strict`; a clean `EM_386` tree passes. *Verify:* `bash scripts/tests/static-audit.test.sh` (stub `scanelf` output). *Tier:* fast.
- **O02-AC-3** — Allowlist rules: an allowlisted dynamic file passes; a stale entry, an entry without an issue comment, and the loader present with an empty list (or absent with a non-empty list) each fail. *Verify:* `bash scripts/tests/static-audit.test.sh`. *Tier:* fast.
- **O02-AC-4** — `--require-empty-allowlist` fails on a one-entry file and passes on an empty one. *Verify:* `bash scripts/tests/static-audit.test.sh`. *Tier:* fast.
- **O02-AC-5** — A `.so` outside `lib/modules/`, a `python3` file, a `.py` file, a `libfreetype` file and a `var/db/pkg/media-libs/freetype-2.13` directory each fail under `--strict`. *Verify:* `bash scripts/tests/static-audit.test.sh`. *Tier:* fast.
- **O02-AC-6** — `static-audit.sh` contains no `2>/dev/null`, and `build-rootfs.sh` still calls it without `--strict`. *Verify:* `bash scripts/tests/static-audit.test.sh` (grep). *Tier:* fast.
- **O02-AC-7** — On rc1's squashfs, with real `scanelf` and `--no-allowlist`, the sorted findings equal `rc1-static-audit.expected`, and the lane is green. The same file, as the seeded allowlist, makes `--strict` pass on rc1. *Verify:* `artifact-checks-rc1.yml` dispatch. *Tier:* slow.

## Risks
- `scanelf` flag spellings (`-R`, `-F` with the interp, arch and textrel fields) are from memory and unverified; the first slice reads `scanelf --help` on the runner and fixes the stub to match.
- How to get rc1's `rootfs.squashfs` out of the ISO (layout read from `build-iso.sh`, not the ISO) and whether non-root `unsquashfs` copes with device nodes are unverified. `unsquashfs -no-xattrs` plus listing the errors it prints is the fallback.
- Whether the squashfs keeps `var/db/pkg` is unverified; S01's unowned gate needs it too. If it does not, the VDB half of change 5 reads the SBOM instead.
- A stripped static binary linking `dlopen` leaves no symbol; this check relies on "no loader, no `.so`" and does not prove absence of the call.
- OD-2: if the owner answers "no entries even in prereleases", the allowlist is seeded empty and rc1-based builds fail at once; the check logic is the same.
- The rc1 expected-findings file is generated by the first run and reviewed once; the review is a human task.
