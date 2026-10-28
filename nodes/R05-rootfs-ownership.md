# R05 — rootfs-ownership

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| R | R01, S04 | none | — | M |

**Owns:** `recipes/overlay/app-misc/monolith-base/monolith-base-0.1.0-r7.ebuild` (replaces `-r6`), `recipes/overlay/app-misc/monolith-base/files/install.manifest`, `recipes/overlay/app-misc/monolith-base/files/rootfs/**` (new static rootfs files), `supplychain/policy/unowned-allowlist.yaml` (S04 creates it from the predecessor's 103 entries; R05 shrinks it to 61), `factory/bin/ownership-lint`, `factory/bin/ownership-collisions`, the `monolith-base` line of `pins/versions.lock`, `tests/fast/ownership-*.test.sh`, `tests/fast/fixtures/ownership/`.
**Carries from linux-live-iso-factory@b9f533b:** `configs/overlay/app-misc/monolith-base/monolith-base-0.1.0-r6.ebuild` (rewritten: the ownership change is the node's purpose, forced by R05-AC-1 and R05-AC-4; R01 imports `-r6` verbatim first), `configs/attestation/unowned-allowlist.yaml` (reclassified, starting from S04's migrated copy, not from the raw file), the `/etc` and `/root` heredocs in `scripts/build-rootfs.sh` (heredocs starting at lines 177, 216, 227, 273, 312, 329, 337, 345, 375, 448, 486, 514, 524, 575, 594, 615, 655; extracted, not copied as a script), `scripts/tests/verify-rootfs-net-wiring.sh` and `verify-router-wiring.sh` (intent, replaced by the manifest lint).
**Study refs:** recipes.yaml `ebuild.app-misc/monolith-base` (+ `contradictions_local`), `rootfs_files`; supplychain.yaml `script.check-unowned`, `cfg.attestation/unowned-allowlist.yaml`; T-unowned-allowlist, T-ntfs-case, T-crosssysroot-missing-accounts, T-acct-user-dnsmasq-race; D-hand-authored-rootfs-files-owned, D-486-minimalism, D-state-and-no-hidden-stderr.

## Purpose
Every file we write into the rootfs is installed by the `monolith-base` ebuild and so appears in a package's `CONTENTS`, and the unowned-files allowlist contains only paths that no ebuild can own, each with a stated reason and a way out. At b9f533b the ebuild owns 25 helper files, but `scripts/build-rootfs.sh` still writes 16 more by heredoc (`inittab`, `rcS`, `S40network`, …) plus `/etc` data files, and the allowlist carries 103 entries (102 unique; `etc/group-` twice) of which 41 are our own files or directories waiting for "proper ebuilds". README.md:79 already claims the migration is done; it is not.

## Scope
In:
- Table-driven `monolith-base` `-r7` that owns all static hand-authored rootfs files, directories and symlinks.
- Extraction of the static heredoc bodies into `files/rootfs/**`, byte-identical to what the script writes.
- The decision that the four release-tag files (`issue`, `os-release`, `monolith-release`, `motd`) stay generated, with the justification recorded in the allowlist.
- The reclassified allowlist: S04 creates `unowned-allowlist.yaml` from the predecessor's 103 entries with a reason per entry; R05 starts from that file and shrinks it to 61, adding a kind and a removal path per entry, under the shrink-only rule.
- Lint for manifest/ebuild/allowlist consistency and a collision check for the built sysroot.

Out:
- Stopping the ported `build-rootfs` from writing these files (B04, in a change after MS2; until then B04 generates them and the allowlist keeps its 103 entries), the stamp templates for the four release-tag files (B04 keeps them under `factory/data/stamp/`), deleting the cleanup candidates, running `mksquashfs`: B04.
- The unowned gate itself, its glob semantics, failing on empty or missing input, reporting unused allowlist entries: S04.
- The initramfs files `rootfs/init` and `rootfs/usr/share/udhcpc/default.script`: B03 (they never enter the squashfs).
- Whether the disc is fully static, which decides the `ld.so.*` entries: OD-2.
- Replacing the dead S3 default in `monolith-advisory-check` and the S3 `HOME_URL` in `os-release`: P06 (B04's stamp template takes `@HOME_URL@` from `MONOLITH_HOME_URL`).
- The `themonolith.ans` asset: R01 placed it at `recipes/overlay/app-misc/monolith-base/assets/`; B04 builds `/etc/motd` from it.
- Making the account database (`passwd`, `group`, `shadow`) package-owned: see Design; it stays allowlisted.

## Design

### Table-driven install
`files/install.manifest`, one entry per line, `#` comments and blank lines ignored, four whitespace-separated fields:
```
# kind  mode   destination                         source (file) | link target (sym)
file    0755   /usr/bin/monolith-net               monolith-net
file    0644   /etc/inittab                        rootfs/etc/inittab
dir     0755   /dev
sym     -      /usr/bin/more                       less
```
`src_install` is one loop over the manifest (`file` → `insinto`/`insopts -m`/`newins`; `dir` → `diropts -m`/`dodir`; `sym` → `dosym`), and `die`s if the manifest is missing or empty. Decision: a data table over the r6 style of one `doexe`/`doins` call per file. The table lets `ownership-lint` prove coverage without parsing bash, and the install set is reviewable as a diff. Rejected: parsing `doins` calls out of the ebuild text (fragile; the r6 ebuild already mixes `exeinto`, `insinto`, globs).

Modes copy what the current pipeline produces: executables and init scripts `0755`, data `0644`, `/etc/shadow` stays outside (allowlisted). Directories `0755` (umask 022 today), including `/root`; the faithful choice, flagged for the maintainer in Risks.

### What moves into the manifest (41 allowlist entries leave)
- Config files, bodies from quoted heredocs: `/etc/fstab`, `/etc/hosts`, `/etc/profile`, `/etc/securetty`, `/etc/shells`, `/etc/inittab`, `/etc/network/interfaces` (build-rootfs.sh:216, 227, 273, 329, 337, 345, 486), `/etc/hostname` (`monolith`, :233 `echo`), `/etc/resolv.conf` (empty, :269 `touch`).
- Init scripts: `/etc/init.d/{rcS,rcK,S20keygen,S30gpm,S35netprobe,S40network,S45monolith-time,S50advisory}` (build-rootfs.sh:375, 448, 594, 615, 514, 524, 575, 655), mode `0755`.
- `/etc/profile.d/50-dropbear-hint.sh` (build-rootfs.sh:312); fixes the "obeys the numeric slot but is generated elsewhere" split the r6 ebuild comment describes.
- Root dotfiles `/root/.bash_profile`, `/root/.bashrc`, `/root/.bash_logout`: today copied from `/etc/skel/.bash*` with a snippet appended (build-rootfs.sh:171–181). Authored minimally: `.bash_profile` sources `~/.bashrc`; `.bashrc` is the appended snippet (source `/etc/profile` once, guarded by `_MONOLITH_ENV`); `.bash_logout` is a comment. Decision: author, do not copy Gentoo's skel. Rejected: reading skel from the bash binpkg (needs the builder, which R05 does not depend on).
- Font alias directory: `/usr/share/fonts/monolith` (dir), `fonts.alias` (the four `printf` lines at build-rootfs.sh:137–140), `fonts.dir` (`0`, :144). The B04 check that each aliased XLFD exists in the generated `terminus/fonts.dir` stays in B04.
- Directories: `/dev /home /mnt /opt /proc /root /run /sys /tmp /etc/network /var/log /var/spool /var/tmp /var/cache`.
- Symlinks: `/bin/sh` → `dash` (the script prefers dash and falls back to bash, :683–689; dash is in world and `app-alternatives/sh dash` is set, so the static link is correct; if `app-alternatives/sh` already owns it, the collision check reports it and the manifest line is dropped), `/usr/bin/more` → `less`, `/var/run` → `/run`, `/var/lock` → `/run/lock`.
- The 25 files `-r6` installs (helpers, `which`, `startx`, `guestbook.cgi`, 8 topic texts, 3 `profile.d`, 3 `bashrc.d`) at identical paths and modes.
Manifest total: 25 existing + 41 moved + 1 (`fonts.dir`, which the old glob entry covered) = 67 entries; the test pins 67.

### Stays generated (release tag)
`/etc/issue`, `/etc/os-release` contain the release tag via unquoted heredocs (build-rootfs.sh:247, 257), `/etc/monolith-release` (:236) and `/etc/motd` (:239–240) the tag too. They cannot be package content because a release tag is a build input, not an ebuild input (every release would force a `monolith-base` revbump). B04 renders them from stamp templates it owns. They remain allowlisted as `generated` with that justification. Rejected: install templates into the rootfs and `sed` them in place — the package would own a path whose content differs from its recorded md5, which makes Portage's own verify fail and the ownership claim dishonest.

### Account database stays allowlisted
`/etc/passwd`, `/etc/group`, `/etc/shadow`, `/etc/gshadow` are mutated by `acct-user`/`acct-group` merges and the shadow tools during sysroot assembly (T-crosssysroot-missing-accounts, T-acct-user-dnsmasq-race), then overwritten by B04 with a fixed content. A package that installs them would race those merges for ownership and content. Decision: allowlist with `kind: mutated`, `reducible_by: null`. Rejected: ship them from `monolith-base` — merge order between `monolith-base` and the acct packages is not controlled and the outcome would depend on it.

### Allowlist: `supplychain/policy/unowned-allowlist.yaml`
S04 creates the file in the `schema: 1` shape it defines (S04 owns the schema and the matcher) and migrates the predecessor's 103 entries into it without dropping any (S04's migration test). R05 edits that file: it removes the 41 moved entries, reclassifies the rest and adds three extension keys:
```yaml
schema: 1
allowlist:
  - path: etc/passwd                 # pattern, relative to the rootfs, no leading slash
    reason: "mutated by acct-user/acct-group merges and shadow tools; final content written by B04"   # mandatory
    kind: mutated                    # extension: mutated | generated | postinst | scan-scope | pending-cleanup
    reducible_by: null               # extension: null | <node id> | <OD id>; null is a deliberate statement
    refs: [T-crosssysroot-missing-accounts]   # extension: trap/doctrine ids
  - {path: "var/db/pkg/**", reason: "Portage database itself", broad: true, kind: scan-scope, reducible_by: S04}
```
`broad: true` on every `**` pattern and non-empty `reason` follow S04. The old file had one comment per group and no per-entry reason, and five "pending proper ebuilds" entries were the oldest debt. S04's schema must accept `kind`, `reducible_by`, `refs` (listed under Spec defects). Reclassified result of the 102 unique old entries:

| Class | Count | Entries | `reducible_by` |
|---|---|---|---|
| Moved to `monolith-base` | 41 | the lists above | — (removed) |
| `mutated` (account DB) | 4 | `etc/passwd`, `etc/group`, `etc/shadow`, `etc/gshadow` | null |
| `generated` (release tag) | 4 | `etc/issue`, `etc/os-release`, `etc/monolith-release`, `etc/motd` | null |
| `generated` (host tools) | 2 | `usr/share/fonts/terminus/fonts.dir` (narrowed from `usr/share/fonts/*/fonts.dir`; the owned `monolith/fonts.dir` no longer needs it), `usr/share/terminfo/?` (NTFS case-collision symlinks, T-ntfs-case) | null; a later overlay `terminus-font` that writes `fonts.dir` itself would own it |
| `postinst` (Portage/eselect/ldconfig) | 28 | `etc/profile.env`, `etc/csh.env`, `etc/env.d/05binutils`, `etc/env.d/binutils/config-*`, `etc/environment.d`, `etc/environment.d/10-gentoo-env.conf`, `etc/.pwd.lock`, `etc/subgid`, `etc/subuid`, 17 `usr/bin/{addr2line,ar,as,c++filt,elfedit,gprof,ld,ld.bfd,ldd,nm,objcopy,objdump,ranlib,readelf,size,strings,strip}`; plus `etc/ld.so.conf`, `etc/ld.so.cache` | null; the two `ld.so.*` entries: OD-2 |
| `scan-scope` (Portage database) | 7 | `var/cache/edb`, `var/db`, `var/db/pkg`, `var/lib/portage`, `var/db/pkg/**`, `var/cache/edb/**`, `var/lib/portage/**` | S04 or B04 (the scan reads the sysroot, which contains the VDB; if the scan root excludes it these seven go) |
| `pending-cleanup` | 16 | `etc/passwd-`, `etc/group-`, `etc/shadow-`, `etc/gshadow-` (shadow backups), `usr/share/binutils-data/*/*/info/dir`, 4 `var/games/nethack/*`, `etc/runlevels`, `etc/runlevels/sysinit`, `etc/runlevels/sysinit/kmod-static-nodes`, 2 `var/lib/gentoo/news/*`, `var/lib/nftables`, `var/lib/nftables/rules-save` | B04 deletes them in rootfs cleanup (unused OpenRC state, install-info index, news markers, backups); each entry is removed in the same B04 PR |
Total retained: 4 + 4 + 2 + 28 + 7 + 16 = 61 (the `postinst` row counts 9 + 17 + 2 = 28). The `nethack` state files are listed as created on first run (the old comment), which means they should not exist at scan time; whether they do is unknown, and S04's unused-entry report settles it.

Decision on location: the file moves to `supplychain/policy/`, SPEC §4.2's home for policies, which is a protected path (SPEC §8). Rejected: `recipes/` — an allowlist is a gate-weakening policy, and the protected-path rule is the right review for growth. S04 independently chose the same path; see Spec defects for the §8 conflict.

Shrink-only rule: `ownership-lint allowlist --base-rev B --head-rev H` (run from the trusted base) fails if the entry count at `H` exceeds the count at `B`, if any entry lacks `reason`, `kind` or `reducible_by`, if two entries share a `path`, or if a `pending-cleanup` entry lacks `reducible_by: B04`. Narrowing one pattern into another passes (count unchanged). Rejected: set inclusion of path strings — it would block narrowing.

### `factory/bin/ownership-lint`
`python3 -I`, PyYAML. Exit 0 ok, 1 findings, 2 usage, 3 missing input.
- `manifest`: every file under `files/` except `install.manifest` is the source of exactly one entry; every source exists; no duplicate destination; destinations are absolute, no `..`; modes are four octal digits; the ebuild contains no install call outside the manifest loop and refers to `install.manifest`; every `sh`/`dash`-shebang file passes `dash -n`/`sh -n` and every bash file `bash -n`.
- `allowlist`: schema above (S04's JSON schema once it exists; until then the key set is checked by the tool itself); no entry's pattern (fnmatch, relative) matches a manifest destination; no destination of the 41 moved paths is allowlisted.
- `allowlist --base-rev/--head-rev`: shrink-only.

### `factory/bin/ownership-collisions` (slow)
Reads a built sysroot `var/db/pkg/**/CONTENTS`: fails if a path `app-misc/monolith-base` owns is also in another package's `CONTENTS`, if the file's md5 in the built tree differs from the md5 recorded in `monolith-base`'s `CONTENTS` (a later step overwrote it), if any `._cfg[0-9]*_*` file exists under `etc/`, or if a manifest destination is missing from the sysroot. This answers the real risk of owning `/etc` files that Gentoo packages (for example `sys-apps/sysvinit`'s `/etc/inittab`) also install: with `CONFIG_PROTECT`, a differing file is shunted into `._cfg0000_*` and silently leaves the old content in place. Not added speculatively: the `CONFIG_PROTECT_MASK` env file and `RDEPEND` ordering are the fix if this check fires.

### Timing
R05 is off the critical path (`track: parallel`) and B04 no longer depends on it. The first attested build ships with B04's ported `build-rootfs` heredocs and S04's 103-entry allowlist; both are honest because S04 starts from the predecessor's allowlist. R05 lands when a slot is free. It changes `monolith-base` only, so I06 rebuilds that one package (seconds, no compile) and the cache stays hot. When R05 merges, B04's follow-up change deletes the generators for the 41 moved files (B04-AC-14).

### Provenance
Extracted bodies are recorded in `recipes/IMPORT.yaml` as `authored` entries with `derived_from: scripts/build-rootfs.sh:<start>-<end>` and `sha256_body` of the old heredoc body; `ownership-lint manifest` verifies the file hash equals the recorded body hash (byte-identical extraction). Edits after that are ordinary changes, gated by R03.

## Traps and doctrines preserved
- T-unowned-allowlist / D-hand-authored-rootfs-files-owned (a new file with no owner fails the build one cycle later): R05-AC-1 (the manifest is the install set), R05-AC-6 (no moved path stays allowlisted), R05-AC-7 (every remaining entry justified, shrink-only), R05-AC-11 (end-to-end on the built rootfs).
- Directories created by `install -D` or `mkdir` are also unowned: `dir` entries in the manifest, R05-AC-2.
- Hidden regression when a file moves: bodies must stay byte-identical, or boot modes would change: R05-AC-3, R05-AC-12.
- T-ntfs-case (terminfo lowercase symlinks) and T-crosssysroot-missing-accounts: retained as justified allowlist entries: R05-AC-7.
- D-486-minimalism: no new dependency or package; added bytes bounded: R05-AC-9.
- D-state-and-no-hidden-stderr: the extracted init scripts get syntax checks for the first time (they were heredocs inside a bash script): R05-AC-1.
- T-binpkg-revbump: `-r7` and the lock bump are required by R03's gate: R05-AC-10.
- README.md:79 vs `build-rootfs.sh` contradiction (doctrine.yaml D-hand-authored-rootfs-files-owned): resolved by R05-AC-3 plus B04 removing the generators.

## Gate
- **R05-AC-1** — Every file under `monolith-base/files/` (except `install.manifest`) is installed by exactly one manifest entry; every entry's source exists; destinations are unique; the ebuild installs only via the manifest loop and dies on a missing or empty manifest; all shell files pass `sh -n`/`dash -n`/`bash -n` per shebang. *Verify:* `tests/fast/ownership-manifest.test.sh` (negative fixtures: orphan file, missing source, duplicate destination, stray `doins`). *Tier:* fast.
- **R05-AC-2** — The manifest contains the 14 FHS directories, the 4 symlinks and the font alias directory listed in Design with the stated modes. *Verify:* `tests/fast/ownership-manifest.test.sh` (expected table hard-coded in the test). *Tier:* fast.
- **R05-AC-3** — The 16 quoted-heredoc bodies, `hostname`, the empty `resolv.conf` and the `fonts.alias`/`fonts.dir` pair are byte-identical to what `build-rootfs.sh` at b9f533b writes (recorded sha256 of each old body in `IMPORT.yaml`); the three root dotfiles exist and `bash -n` passes. *Verify:* `tests/fast/ownership-extract.test.sh`. *Tier:* fast.
- **R05-AC-4** — The 25 paths `-r6` installed are installed by `-r7` at the same destination and mode. *Verify:* `tests/fast/ownership-manifest.test.sh` (hard-coded list from the r6 ebuild). *Tier:* fast.
- **R05-AC-5** — `etc/issue`, `etc/os-release`, `etc/monolith-release` and `etc/motd` are absent from the manifest and present in the allowlist with `kind: generated` and a reason naming the release tag. *Verify:* `tests/fast/ownership-allowlist.test.sh`. *Tier:* fast.
- **R05-AC-6** — No allowlist pattern matches a manifest destination, and none of the 41 moved paths (hard-coded in the test) is allowlisted. *Verify:* `tests/fast/ownership-allowlist.test.sh`. *Tier:* fast.
- **R05-AC-7** — `supplychain/policy/unowned-allowlist.yaml` has `schema: 1`, exactly 61 entries, unique paths, non-empty `reason`, `kind` and `reducible_by` keys on every entry, `broad: true` on exactly the three `**` entries, 16 `pending-cleanup` entries with `reducible_by: B04`, the two `ld.so.*` entries with `reducible_by: OD-2`; `etc/group-` appears once. *Verify:* `tests/fast/ownership-allowlist.test.sh`. *Tier:* fast.
- **R05-AC-8** — The shrink-only check fails when a head adds an entry, drops a field, or duplicates a path, and passes when a head narrows a pattern or removes entries. *Verify:* `tests/fast/ownership-shrink.test.sh` (git fixtures built in a temp repo). *Tier:* fast.
- **R05-AC-9** — The static files under `files/rootfs/` total at most 64 KiB, the ebuild adds no `RDEPEND`/`DEPEND` beyond what `-r6` declared, and no new package appears in `world`. *Verify:* `tests/fast/ownership-manifest.test.sh`. *Tier:* fast.
- **R05-AC-10** — `monolith-base-0.1.0-r7.ebuild` exists, `-r6` is removed, and `pins/versions.lock` names `-r7`. *Verify:* `tests/fast/ownership-manifest.test.sh` (file listing and lock line); R03's gate covers it from then on. *Tier:* fast.
- **R05-AC-11** — On the built sysroot and rootfs, `ownership-collisions` reports no double-owned path, no `._cfg*` file and no missing destination, and `check-unowned` (S04) reports zero unowned files with the reclassified allowlist. (The first build where R05 and the B04 follow-up are both in is the evidence run.) *Verify:* CI job `ownership` in the B06 pipeline (artifacts `ownership-collisions.txt`, `unowned-report.json`). *Tier:* slow (evidence first available at B06/S04; R05 merges on its fast ACs).
- **R05-AC-12** — The ISO built with `monolith-base` `-r7` passes the `bios`, `persist`, `nic` and `gui` boot modes unchanged from rc1 behaviour. *Verify:* oracle jobs O02 (`bios`), O04 (`persist`), O03 (`nic`), O05 (`gui`) on the first B06 ISO. *Tier:* slow.

## RED plan
The tester first writes `tests/fast/fixtures/ownership/` (minimal `files/` trees with one defect each, old-body hashes, a temp-repo builder for the shrink test, a fake sysroot with two CONTENTS files and a `._cfg0000_inittab`), then `ownership-manifest`, `ownership-extract`, `ownership-allowlist`, `ownership-shrink` tests. At RED the manifest, `files/rootfs/`, `ownership-lint` and the new allowlist path do not exist, so every test fails. The pinned old-body hashes are computed by running the b9f533b heredocs once and committed in the RED test, so the extraction cannot be graded against itself. `ownership-collisions` gets a fixture test (`tests/fast/ownership-collisions.test.sh`) so the slow tool is itself proven on a fake sysroot.

## Risks and open questions
- Hardest: owning `/etc/inittab`, `/etc/securetty`, `/etc/shells`, `/etc/hosts`, `/etc/fstab`, `/etc/profile` may collide with files Gentoo packages in the sysroot already install (the allowlist entries suggest at least some are unowned today, but ownership by `sysvinit` and others is unknown from the repo). Only the slow `ownership` job can answer; R05 may need `CONFIG_PROTECT_MASK` and `RDEPEND` ordering, and each such change is a cache-profile change (R03).
- `rcS`, `S40network` etc. become package content, so editing them now needs a revbump (R03). That is the intent but it changes the inner loop for boot-script work (a `monolith-base` rebuild is seconds, the revbump is the cost).
- Root dotfiles are authored, not Gentoo's skel. If the skel carried behaviour (aliases, `umask`), the `bios`/`gui` modes might notice; AC-12 is the test.
- `/root` mode: today `0755` (script default). A secure default would be `0700`. The faithful value is kept; the maintainer should decide (the live ISO has a passwordless root, `/etc/issue`).
- The `postinst` row (28) includes 17 binutils symlinks that exist only because `sys-devel/binutils` is on the disc. Whether it should be (D-486-minimalism) is out of scope; the symlink entries disappear if it is removed.
- `usr/share/terminfo/?` and `etc/ld.so.cache` depend on OD-2 and the squashfs/NTFS history; unverified whether they exist in the current image.
- No SPEC §10 decision blocks R05; OD-2 gates two entries' removal only.

## Cost
Three slices: (1) manifest design, ebuild `-r7`, lint, the 25 existing files (AC-1, 2, 4, 9, 10); (2) extraction of the heredocs, root dotfiles, fonts (AC-3, 5); (3) allowlist reclassification and shrink-only tooling, collision tool (AC-6, 7, 8, plus fixtures for 11). No CI build cycles in R05. I06 rebuilds `monolith-base` only (seconds, no compile) in the next cache-hot build (~25 min wall to a tested ISO, per `docs/first-attested-build.md`); the oracle cost for AC-12 is the four boot modes already in the pipeline. No storage or hosting cost; the files total under 64 KiB.

## Spec defects found
- Protected path conflict, also found by S04: SPEC §8 forbids agents from editing `supplychain/policy/`, yet R05's purpose is to author and then shrink `supplychain/policy/unowned-allowlist.yaml`. Needed from the owner: a deletion-only carve-out that F04 can check on the diff (R05's shrink-only check is the rule), or a different home for the file. R05 follows §4.2 and the first PR needs a human-authored commit.
- Schema ownership: S04 creates and R05 edits `unowned-allowlist.yaml`. R05 uses S04's `schema: 1` plus `kind`, `reducible_by`, `refs`; S04's JSON schema must allow those keys (S04-AC-4 rejects unknown keys today). The dependency R05 -> S04 now exists in the graph, so S04 can add the keys.
- Matcher semantics: `fnmatch` treats `*` as crossing `/` (`scripts/check-unowned.py:170-179`), so `**` means nothing special; the old header says otherwise. S04's spec makes `*` and `?` segment-local and `**` the only cross-segment glob. R05's 61 patterns are valid under both that rule and the old `fnmatch` behaviour: the wildcard entries are `etc/env.d/binutils/config-*`, `usr/share/binutils-data/*/*/info/dir`, `usr/share/terminfo/?` and the three `**`; none relies on `*` crossing `/`.
- B04 must stop generating the 41 moved files after R05 lands and keeps the four stamp templates. B04 no longer depends on R05, so the stop is a later B04 change (B04-AC-14). If B04 still writes `inittab` or `rcS` after R05 lands, R05's ownership claims are overwritten at assembly and the `ownership-collisions` content check (md5 against CONTENTS) would flag it.
- `unowned-allowlist.yaml` had a duplicate entry (`etc/group-`) that no check noticed; a fast uniqueness lint is part of R05-AC-7.
