# R01 — recipes-import

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| R | F01 | I06, P06, R02, R03, R04, R05 | — (feeds MS1) | M |

**Owns:** `recipes/README.md`, `recipes/IMPORT.yaml`, `recipes/lint-waivers.yaml`, `recipes/overlay/**` (except the files R05 adds to `app-misc/monolith-base`), `recipes/portage/**` (except `forbidden-atoms.txt`, owned by R02), `recipes/kernel/legacy/**` (frozen staging for R04), `pins/versions.lock` and `pins/crossdev.lock` (initial verbatim placement only; R02 and I05 own them afterwards), `factory/bin/recipes-lint`, `tests/fast/recipes-*.test.sh`, the nine carried `tests/fast/monolith-*.test.sh`.
**Carries from linux-live-iso-factory@b9f533b (ported verbatim, byte for byte):** `configs/overlay/**` (11 packages, 57 files), `configs/portage/{make.conf,bashrc,world,env/,package.env/,package.use/,package.mask/,package.accept_keywords/,profile/,savedconfig/,versions.lock,crossdev.lock}`, `configs/kernel.config`, `configs/initrd-modules.txt`, `docs/kernel-tiers.md` (staged only), `configs/themonolith.ans`, `scripts/tests/monolith*.test.sh` (9 files).
**Study refs:** recipes.yaml (all 11 `packages`, 26 `config` entries, `contradictions` #5, #8–#16, `open_questions` #1, #2, #6–#9, #11); traps T-overlay-keyword, T-freetype-chain, T-tmpfiles-systemd-utils-python, T-binpkg-revbump, T-glib-docutils-eigen-live, T-nethack-5-from-epoch-bump, T-perl-cross-static-musl, T-dbd-sqlite-static-ext, T-sqlite-autosetup, T-rust-i486-musl, T-tinyx-xfbdev, T-xcb-proto-python, T-suckless-xft, T-gdb-static, T-ppp-mutt-tinfo; doctrines D-all-static, D-bitmap-fonts-no-freetype, D-no-python-on-target, D-no-readding-removed-things, D-486-minimalism.

## Purpose
The recipes of the predecessor — overlay ebuilds, portage configuration, rootfs helper files — exist in this repository in the new layout, byte-identical to `b9f533b`, with `recipes/IMPORT.yaml` recording every file's hash. Everything downstream (R02–R05, B01–B04) edits these files, so the import must be exact and auditable offline. It must also be verbatim: I06's cache key hashes the global portage config, and its rc1 seed is valid only if that config is unchanged (Principle 11, port first). The import adds no behaviour and removes nothing. Dead-config removal, comment fixes and workaround tags are one later batched change (Design, "The deferred batch").

## Scope
In:
- Copy the files listed under **Carries** into the layout below, and record the mapping, source hash and edit class of every file in `recipes/IMPORT.yaml`.
- Record in `IMPORT.yaml` the sha256 of every imported file; I06's seed refuses to run if the global config differs from these hashes.
- Write `factory/bin/recipes-lint` (`import`, `layout`, `overlay` checks now; the checks for the deferred batch land with it) and the fast tests that keep the import true.
- Write the two READMEs (authored files, outside the cache inputs).
- Carry the nine rootfs-helper unit tests to `tests/fast/` with path fixes only.

Out:
- Dead-config removal, comment fixes, workaround tags, the stanza-comment rule and the path-reference lint: the deferred batch (below), landed after MS2 together with M01's first tree bump. Reason: every one of them changes a cache input, so doing them before MS2 would void the rc1 seed (I06) for no gain.
- Splitting `kernel.config` into fragments and the new kernel ebuild revision: R04.
- Completing `versions.lock`, the denylist, determinism: R02. Revbump gate: R03. Moving heredoc-generated `/etc` files into `monolith-base` and the allowlist: R05.
- Installing the recipes into the builder (`/usr/i486-linux-musl/etc/portage/`, repos.conf priority, host `package.mask` mirror, `cross-gcc-static.conf`, host python3/makewhatis/`-m32` gcc/rustup): B01, I03. R01 only documents the contract.
- `configs/attestation/**`: S01–S04. `configs/bootbg.png`: B05. `Dockerfile`, `scripts/**` other than the nine tests: owner nodes of those steps.
- Replacing the dead S3 default URL in `monolith-advisory-check`: P06. Mirroring the source tarballs the ebuilds fetch: I04.
- Re-verifying that the carried recipes still build: B01 (first full build).

## Design

### Layout mapping (SPEC §4.2)
| Old path (b9f533b) | New path |
|---|---|
| `configs/overlay/` | `recipes/overlay/` (same `category/pkg/` tree, `metadata/layout.conf`, `profiles/repo_name`) |
| `configs/portage/{make.conf,bashrc,world,savedconfig/}` | `recipes/portage/` (same names) |
| `configs/portage/{env,package.env,package.use,package.mask,package.accept_keywords,profile}/` | `recipes/portage/` (same names) |
| `configs/portage/{versions.lock,crossdev.lock}` | `pins/` (placed verbatim; handed to R02 / I05) |
| `configs/kernel.config`, `configs/initrd-modules.txt`, `docs/kernel-tiers.md` | `recipes/kernel/legacy/{kernel.config,initrd-modules.txt,kernel-tiers.md}`, frozen, read-only input for R04 |
| rootfs files `configs/overlay/app-misc/monolith-base/files/**` | unchanged relative to the ebuild: `recipes/overlay/app-misc/monolith-base/files/**` |
| `configs/themonolith.ans` | `recipes/overlay/app-misc/monolith-base/assets/themonolith.ans` (not under `files/`, so never installed; B04 reads it to build `/etc/motd`) |
| `scripts/tests/monolith*.test.sh` (9) | `tests/fast/` (same file names) |

Decision: `recipes/overlay` is the repository root of a portage repo, so the builder's `repos.conf` can point at it directly. Rejected: nesting under `recipes/overlay/monolith/` (an extra level for no benefit).

### Import method: verbatim copy with provenance
Decision: plain byte-for-byte copy of the b9f533b working tree files, plus `recipes/IMPORT.yaml`. The only files that differ from their source are the nine carried unit tests (path line) and the authored files. The overlay ebuilds and `files/`, the rootfs helper files, `make.conf`, `bashrc`, `profile/`, `env/`, `package.*`, `savedconfig/` and `world` are `verbatim`:
```yaml
source: {repo: tuckermclean/linux-live-iso-factory, commit: b9f533b}
files:
  - {dst: recipes/overlay/dev-lang/monolith-perl/monolith-perl-5.42.0-r5.ebuild,
     src: configs/overlay/dev-lang/monolith-perl/monolith-perl-5.42.0-r5.ebuild,
     class: verbatim, sha256_src: <64 hex>, sha256_dst: <64 hex>}      # the two hashes are equal
  - {dst: tests/fast/monolith-net.test.sh, src: scripts/tests/monolith-net.test.sh,
     class: edited, reason: "path only", sha256_src: <64 hex>, sha256_dst: <64 hex>}
```
Classes: `verbatim` (hashes equal), `edited` (needs `reason`; the nine tests only), `deferred` (needs `node`), `authored` (new in this repo, no `src`; `IMPORT.yaml` itself is exempt). The deferred batch adds the classes `comment-only` (equal after deleting `#` lines and blank lines, with a `sha256_src_nocomment`) and `dropped` (needs `reason`, `evidence`).
`IMPORT.yaml` also carries a top-level `global_config:` block with the sha256 of `recipes/portage/make.conf`, `bashrc`, and of the sorted path-and-bytes lists of `profile/**` and `env/**`, computed the same way as I06's `config` field. I06's `seed-rc1` compares against it.
Rejected: `git subtree` / `git filter-repo` with history. The history has 230 commits under four author identities (`Tucker McLean`, `tuckermclean`, `github-actions[bot]`, `Software Engineer <…@dcxxiv.local>`), which F04 would reject; it carries S3-era churn; and it defeats "one node = one PR, squash-merged". The old repo is archived by X01 with a pointer, so the history stays reachable by commit id.
The verbatim import keeps rc1's global key and package fingerprints, so I06 can seed rc1's binary packages. R03's gate applies from the first commit after R01.

### The deferred batch
Everything below changes bytes the cache hashes: the removals and `bashrc` tags change the global key (`env/`, `bashrc`), and ebuild comments change the package fingerprint of all 11 overlay packages. So it is one change, not several, and it is a full rebuild by design. It lands after MS2, in the same PR as M01's first tree bump or immediately before it, because that bump is already a full rebuild under a new global key (M01-AC-14). The ACs below marked `*When:* after MS2` belong to this batch; R01 keeps them (it owns the files), M01 schedules them. The batch must also satisfy R03 (comment-only ebuild edits need a documented exemption or `-rN`; see Spec defects).

### Removals (deferred batch; each recorded as `dropped` or `edited` with evidence)
1. `env/no-static-ldflags.conf`: referenced by no `package.env` line (recipes.yaml cfg entry; `git grep no-static-ldflags` at b9f533b finds only the file itself). Superseded by the `bashrc` meson/cmake/libtool hooks.
2. `package.use/static` `app-misc/gpm static` (line 306): world has `sys-libs/gpm`; the entry never matches. The global `*/* static static-libs` already applies.
3. `package.use/static` `sys-process/dcron static` (line 242) and `www-client/w3m static ssl -minimal -imlib` (line 261): neither atom is in world (D-no-readding-removed-things; w3m is also masked-by-doctrine).
Kept on purpose, with a note: `env/disable-stdbuf.conf` (belt-and-suspenders; the `bashrc` coreutils `sed` is the real fix — removing it would force a coreutils rebuild with no proof of neutrality); `savedconfig/sys-apps/busybox` modutils `=y` lines (Gentoo's ebuild drops those applets for kmod regardless, recipes.yaml open question #7; pruning changes the busybox digest for zero size gain); `libsqlite3.a` and headers from `monolith-sqlite` (consumed by nothing, `world:235-242`; removal is a B04 cleanup decision).

### Comment fixes (deferred batch)
- `package.use/static`: terminus-font block says `psf` only and `-pcf-unicode`, actual flags are `+pcf +pcf-unicode +psf` (contradiction #10); mutt block opening says "drop smtp+sasl", the atom enables `smtp sasl gsasl` (contradiction #11).
- `env/gdb-lowmem.conf`: "global MAKEOPTS=-j2" becomes "global MAKEOPTS is `-j${JOBS}`" (contradiction #13).
- `xcb-proto` ebuild: the "priority 20" claim is true only in the builder's `repos.conf` (`scripts/build-packages.sh:70`, `Dockerfile:183`); `layout.conf` has no priority. Comment now says so, and `recipes/overlay/README.md` states the contract (contradiction #14).
- `.batteries/reports/*.md` and `MEMORY.md` references in `world`, `package.use/static`, `package.mask/problematic`, `stele` ebuild: replaced by the reason text or "(report not carried)". The directory is not in the repo.
- "S3 `--usepkg` binpkg cache" in the `stele` ebuild: reworded to "binpkg cache". Fetch-fallback comments "host the tarball in the project's own S3" in `rl144` and `monolith-xserver` ebuilds: reworded to "the distfile mirror (I04)".
- `rl144` / `stele` ebuilds: add a comment pair stating the two recipes differ on purpose — `rl144` uses `-Clink-self-contained=no`, a `FILESDIR` target JSON and `--features backend-term`; `stele` uses the in-repo target JSON and default features (contradiction #15). AGENTS.md's "6 link fixes" wording belongs to F01.
- `monolith-perl` ebuild header gains the revbump history (`-r1` NO_LOCALE; `-r2` CGI 4.10, prune pass, guestbook test, DBI/DBD attempted and reverted; `-r3`–`-r5`: rationale **unknown** — the whole tree arrived in one squash commit `7926f71`). This text currently lives only as a comment in `versions.lock:90-108`, which R02 regenerates without comments.

### Workaround tags (deferred batch)
Every `build_hacks` entry in `docs/study/recipes.yaml` (62 across 11 packages) gets a comment in the package's ebuild, directly above the code it explains:
```
# WA monolith-perl#9: -DNO_LOCALE ... <reason, taken from the study's `why:`, shortened but not weakened>
```
`<pkg>` is the package name (`monolith-kernel`, `monolith-perl`, …), `#<n>` is the 1-based index of the entry in that package's `build_hacks` list. Thirteen `bashrc` entries get `# WA bashrc#<n>` the same way (index into `cfg.portage/bashrc.entries`). `recipes-lint workarounds` reads the study YAML and fails if any tag is missing, duplicated, or has no text after the colon. Rejected: a separate `WORKAROUNDS.md` — it drifts from the code, which is how `versions.lock:95` went stale.

### Stanza-comment rule for portage config (deferred batch)
In `env/*`, `package.env/*`, `package.use/*`, `package.mask/*`, `package.accept_keywords/*`, `profile/package.provided`: every blank-line-separated block containing a non-comment line must have at least one comment line directly above its first non-comment line. Exempt: a `package.use` line whose flags are only `static` and/or `static-libs` (documentation-only markers, recipes.yaml cfg `package.use/static` note).

### `factory/bin/recipes-lint`
`python3 -I`, standard library plus PyYAML. Usage: `recipes-lint [check ...]`; no argument runs all checks that are enabled. Before the batch only `import` and `layout` are enabled; `env-refs`, `stanza`, `workarounds`, `paths` and `dead` are switched on by the batch, because the verbatim files fail them. Output `path:line: CODE message`; exit 0 clean, 1 findings, 2 usage error. Checks:
- `import`: `IMPORT.yaml` covers every file under `recipes/`, `pins/{versions,crossdev}.lock`, `recipes/kernel/legacy/`; hashes match; class rules hold.
- `layout`: exactly one `*.ebuild` per overlay package dir; `Manifest` present and non-empty with a `DIST` line iff the ebuild has `SRC_URI`; `EAPI=8`; `KEYWORDS` set; every overlay package has a `<cat>/<pn> **` line in `package.accept_keywords/i486` (T-overlay-keyword); `profiles/repo_name` is `monolith`.
- `env-refs`: every `env/*.conf` is named by a `package.env` line, and every `package.env` line names an existing file.
- `stanza`: the rule above.
- `workarounds`: the tag rule above.
- `paths`: no `configs/`, `scripts/`, `.batteries`, `MEMORY.md`, `amazonaws`, `S3` in any file under `recipes/` unless `recipes/lint-waivers.yaml` has `{file, pattern, reason, node}` for it (initial waivers: `monolith-advisory-check` default URL, node P06; `build-rootfs.sh` mentions in `monolith-base` comments, node R05).
- `dead`: the three removed atoms and the removed file do not reappear (explicit list).

### Builder contract (documented, not implemented here)
`recipes/README.md` states where B01/I03 must install: `make.conf`, `bashrc`, `env/`, `package.*`, `savedconfig/`, `profile/` into `/usr/i486-linux-musl/etc/portage/` (`scripts/build-packages.sh:52-66`); `package.mask` additionally into the host `/etc/portage/` (`build-packages.sh:73-91`); overlay registered with `priority = 20`, `masters = gentoo`; `profile/package.provided` versions track the pinned snapshot (R02 checks). It also lists the host tools the recipes need (python3 in `bashrc` gpm/nethack hooks, host `makewhatis`, `-m32` gcc for `CFLAGS_FOR_BUILD`, rustup nightly-2026-07-15 under `/opt/rustup`) — owner I03 — and the unresolved question of which package supplies `libiconv.a` for `app-arch/tar` (`env/libiconv.conf`) — owner B01.

## Traps and doctrines preserved
- T-overlay-keyword (overlay ebuilds `~amd64`, global `~x86` misses them): R01-AC-8.
- T-freetype-chain, T-tmpfiles-systemd-utils-python, T-glib-docutils-eigen-live, T-nethack-5-from-epoch-bump (carried as lines in `package.provided`, `package.mask`, `world`): R01-AC-9 asserts the exact lines so a later edit cannot silently drop one.
- D-all-static, D-bitmap-fonts-no-freetype, D-no-python-on-target (carried mechanisms: `env/static.conf`, `libXfont --disable-freetype`, `xcb-proto` overlay, `monolith-st`/`dwm` patches): R01-AC-2 (verbatim or comment-only classes) and R01-AC-9.
- T-perl-cross-static-musl, T-dbd-sqlite-static-ext, T-sqlite-autosetup, T-rust-i486-musl, T-tinyx-xfbdev, T-xcb-proto-python, T-suckless-xft, T-gdb-static, T-ppp-mutt-tinfo: the reasons are the content of the workaround tags: R01-AC-5.
- D-no-readding-removed-things: the `package.mask` lines carry over (R01-AC-9); the full denylist is R02-AC-6.
- T-binpkg-revbump: not enforced here; the verbatim import changes no ebuild, so no stale binary can arise; the gate is R03 and the fingerprint is I06.
- D-486-minimalism: nothing may be added by the import (R01-AC-1: no unlisted file; R01-AC-14: nothing changed).

## Gate
- **R01-AC-1** — Every file under `recipes/`, `recipes/kernel/legacy/` and `pins/{versions,crossdev}.lock` has an `IMPORT.yaml` entry, every entry's `sha256_dst` matches the file, and `verbatim` entries have equal source and destination hashes. *Verify:* `tests/fast/recipes-import.test.sh` (runs `recipes-lint import`; includes a negative fixture with an unlisted file). *Tier:* fast.
- **R01-AC-2** — *Withdrawn (v0.3):* superseded by R01-AC-14. The import drops nothing; the removals move to the deferred batch (R01-AC-3).
- **R01-AC-3** — The dead entries are gone and cannot return: `env/no-static-ldflags.conf` is absent; no `package.use` line starts with `app-misc/gpm`, `sys-process/dcron` or `www-client/w3m`; every `env/*.conf` is named by `package.env`. *Verify:* `tests/fast/recipes-dead-config.test.sh`. *Tier:* fast. *When:* after MS2 (the deferred batch, landed with M01's first bump).
- **R01-AC-4** — The stale comments are corrected: none of `drop smtp+sasl`, `MAKEOPTS="-j2"`, `.batteries`, `MEMORY.md`, `S3 --usepkg` appears under `recipes/`; the terminus-font block names `pcf-unicode` and `psf` as enabled; `xcb-proto` and `recipes/overlay/README.md` state that priority is set in `repos.conf`. *Verify:* `tests/fast/recipes-comments.test.sh`. *Tier:* fast. *When:* after MS2 (the deferred batch, landed with M01's first bump).
- **R01-AC-5** — Each of the 62 study `build_hacks` and 13 `bashrc` hooks has exactly one `WA <pkg>#<n>:` tag with non-empty reason text in the owning file. *Verify:* `tests/fast/recipes-workarounds.test.sh` (reads `docs/study/recipes.yaml`; negative fixture removes one tag). *Tier:* fast. *When:* after MS2 (the deferred batch, landed with M01's first bump).
- **R01-AC-6** — The stanza-comment rule holds for every portage config file. *Verify:* `tests/fast/recipes-stanza.test.sh`. *Tier:* fast. *When:* after MS2 (the deferred batch, landed with M01's first bump).
- **R01-AC-7** — Path-reference lint is clean except for waivers, each with a reason and a named node. *Verify:* `tests/fast/recipes-paths.test.sh`. *Tier:* fast. *When:* after MS2 (the deferred batch, landed with M01's first bump).
- **R01-AC-8** — Overlay validity: one ebuild per package dir, `Manifest` rule, `EAPI=8`, `KEYWORDS`, an `**` accept-keywords line per overlay package, `repo_name` is `monolith`, `layout.conf` has `masters = gentoo` and `thin-manifests = true`. *Verify:* `tests/fast/recipes-overlay.test.sh`. *Tier:* fast.
- **R01-AC-9** — Doctrine lines survive: `profile/package.provided` has the four atoms (`virtual/tmpfiles-0-r7`, `media-libs/freetype-2.14.3`, `x11-apps/mkfontscale-1.2.4`, `media-fonts/encodings-1.1.0`); `package.mask/problematic` contains `sys-apps/man-db`, `dev-libs/libxml2`, `app-arch/zstd`, `>=dev-python/docutils-0.23`, `>=dev-cpp/eigen-9999`, `>=games-roguelike/nethack-5.0.0`; `env/static.conf` contains `-no-pie -static` and `--disable-shared --enable-static`; `world` contains `<sys-fs/ncdu-2` and `=games-roguelike/nethack-3.6.7-r1` and has 99 atoms. *Verify:* `tests/fast/recipes-doctrine-lines.test.sh`. *Tier:* fast.
- **R01-AC-10** — The nine carried rootfs-helper unit tests pass at their new paths, and each differs from its b9f533b source only in the `SCRIPT=`/`BASE=` path line. *Verify:* `make test-fast` runs `tests/fast/monolith{,-net,-persist,-persist-bashrc,-persist-profile,-router,-time,-time-check,-cnf}.test.sh`; `IMPORT.yaml` marks them `edited` with reason "path only". *Tier:* fast.
- **R01-AC-11** — `recipes/kernel/legacy/*` are byte-identical to b9f533b (hash recorded) and nothing outside `tests/fast/kernel-*` and R04's tools reads them. *Verify:* `tests/fast/recipes-import.test.sh`; `grep -r 'kernel/legacy' --include='*' . | grep -v tests/fast/kernel- ` is empty. *Tier:* fast.
- **R01-AC-12** — `recipes/README.md` and `recipes/overlay/README.md` state the layout mapping, the builder install contract (including `priority = 20`), the host-tool list, and each deferral with its owning node; `IMPORT.yaml` lists `configs/attestation/**`, `configs/bootbg.png`, `Dockerfile`, `scripts/**` (other than the nine tests) as `deferred` with node ids. *Verify:* `tests/fast/recipes-readme.test.sh` (greps required phrases; checks every `deferred` node id exists in `docs/graph.yaml`). *Tier:* fast.
- **R01-AC-13** — *Withdrawn (v0.3):* the comment-only rule is replaced by the stricter byte-identity of R01-AC-14. The comment-only class returns with the deferred batch, whose own hash rule is then R01-AC-3 and R01-AC-5.
- **R01-AC-14** — Every imported file under `recipes/overlay/**` and `recipes/portage/**`, `pins/versions.lock` and `pins/crossdev.lock` (all but the `authored` READMEs and R05's additions) is byte-identical to its b9f533b source (`sha256_src == sha256_dst` in `IMPORT.yaml`, and the recorded source hash equals the hash of the file at b9f533b). The only `edited` entries are the nine carried tests, so `IMPORT.yaml` has exactly 9. *Verify:* `tests/fast/recipes-import.test.sh` (counts classes; fails on a tenth `edited`; a fixture with one changed comment byte in an ebuild must fail). *Tier:* fast.
- **R01-AC-15** — `IMPORT.yaml` has a `global_config` block whose hashes equal the hashes of `make.conf`, `bashrc`, `profile/**` and `env/**` as computed by I06's `config` field rule, and `recipes-lint import` fails when the files differ from the block. *Verify:* `tests/fast/recipes-import.test.sh` (fixture with a changed `bashrc` byte); the I06 seed test consumes the same block (I06-AC-14). *Tier:* fast.

## RED plan
The tester writes, before any copy exists: `recipes-import.test.sh` (fails: no `IMPORT.yaml`), `recipes-overlay.test.sh`, `recipes-doctrine-lines.test.sh`, `recipes-readme.test.sh`. All fail at the RED commit because `recipes/` is empty. The tests for the deferred ACs (`recipes-dead-config`, `recipes-comments`, `recipes-workarounds`, `recipes-stanza`, `recipes-paths`) are written with the batch, not now. The nine carried unit tests fail because their targets do not exist. `recipes-lint` has its own negative fixtures under `tests/fast/fixtures/recipes-lint/` (each defect class once), created by the tester so the linter cannot pass vacuously. The expected hashes in `recipes-import.test.sh` come from the b9f533b tree (`git cat-file` at that commit) and are committed in the RED test (the test file is protected after RED).

## Risks and open questions
- The comment-only class (deferred batch) trusts a simple `#`-line stripper. A heredoc or shell string with a leading `#` inside code would be treated as a comment. The ebuilds were scanned by the study for none; the lint reports any such case as `edited` instead.
- Verbatim means the shipped recipes still say `S3`, `.batteries` and stale comments until the batch lands. That is accepted: it is documentation debt, not behaviour, and fixing it earlier would cost a 75-minute build for every iteration of MS1 and MS2.
- Whether R03's revbump gate accepts comment-only ebuild edits is unknown; the batch needs either an exemption or `-rN` bumps, both of which are full rebuilds anyway.
- Tagging 62 workarounds is mechanical but the `why:` text must be faithful. The reviewer samples five tags per package against the ebuild line numbers cited in the study.
- `monolith-perl` `-r3`–`-r5` rationale is unknown (single squash commit). Recorded as unknown; nothing blocks on it.
- The carried ebuilds fetch from upstream URLs and `crates.io`; nothing here proves they still resolve (first proof is B01 on a cold cache). I04 mirrors the distfiles.
- Cargo crate vendoring for `rl144`/`stele` (ebuild comments call it "future hardening") is open: I04 decides whether crates.io fetches are mirrored.
- No SPEC §10 decision is needed. A fixed `recipes/overlay` path assumes OD-3 stays at its default (bash + Python stdlib).

## Cost
Two slices before MS2: (1) verbatim copy + `IMPORT.yaml` with hashes + `recipes-lint import/layout` (AC-1, 8, 9, 11, 14, 15); (2) READMEs and carried unit tests (AC-10, 12). One slice after MS2: the deferred batch (AC-3–7: removals, comments, workaround tags, stanza and paths lint), which costs one full rebuild shared with M01's first bump. No CI build cycles of its own; the fast tier runs in seconds. No storage or hosting cost (the staged legacy kernel files add about 150 KB to the repo).

## Spec defects found
- Evidence correction, not a SPEC defect: `recipes.yaml` says `configs/themonolith.ans` is an empty 0-byte file. At b9f533b it is 1391 bytes (`git cat-file -s HEAD:configs/themonolith.ans`) and ends in a SAUCE00 record (`build-rootfs.sh:239` strips the last 128 bytes). The R01 import treats it as a real asset.
- SPEC §4.2 now lists `recipes/kernel/legacy/` and `recipes/IMPORT.yaml` but still has no home for non-installed rootfs assets (`themonolith.ans`). R01 places it under `recipes/overlay/app-misc/monolith-base/assets/` as above; the layout table should name it. The `monolith-base` ebuild directory is also a fingerprint input (I06), so adding `assets/` there changes that package's fingerprint only if the ebuild's `files/` rule includes it (it does not: `assets/` is outside `files/`).
- The unit tests for the rootfs helpers (`scripts/tests/monolith*.test.sh`) are owned by no node in `graph.yaml`. R01 carries them; the graph should say so.
