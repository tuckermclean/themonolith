# B01 — package-build

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| B | I02, I03, I04, I05, I06, R02 | B02, B04 | — (feeds MS1) | L |

**Owns:** `factory/bin/build-packages`, `factory/bin/run-in-builder`, `factory/lib/common.sh`,
`factory/lib/verify_complete.py`, `factory/lib/sysroot-seed.sh`,
`factory/lib/plan_parse.py`, `factory/data/stage-provided.txt`, `factory/data/network-exceptions.txt`,
`factory/mk/packages.mk`, `tests/fast/package-*.test.sh`,
`tests/fast/stage-contract.test.sh`, `tests/fast/run-in-builder.test.sh`
**Carries from linux-live-iso-factory@b9f533b:** `scripts/build-packages.sh` (ported: the structure, the emerge
invocations, the `MONOLITH_USEPKG=n` release switch at `:215-225` and the sysroot seeding are kept; each change is
forced by a named AC, see Design "Port first"), `Makefile:75-110` (DOCKER_RUN mounts, ported with `:ro` added by
B01-AC-8). `scripts/binpkg-store.sh` and `scripts/savedconfig-cache.sh` are not carried: the cache moved to I06.
**Study refs:** build.yaml `script.build-packages` notes FAILURE MASKING 1-3; `script.binpkg-store` (401 as miss);
`script.savedconfig-cache`; hazards `silent_fallbacks`, `hidden_errors_2_dev_null`, `nondeterminism`;
contradictions (cp does not delete; kernel build mode `unknown`); T-keep-going-hides-drops,
T-acct-user-dnsmasq-race, T-runner-oom, D-tag-builds-from-source, D-state-and-no-hidden-stderr,
D-static-musl-cross-all-the-way, Principles 2, 5, 9.

## Purpose
After B01 a single command cross-compiles the locked world for `i486-linux-musl` and proves, per package, that
it is installed at its locked version and where it came from: built in this run, restored from a cache entry
whose key I06 matched, or supplied by the builder image. The predecessor decided success
by globbing for any `.gpkg.tar`, so a stale binary hid a failing rebuild. B01 ports the predecessor's script and
fixes that, plus the three failure-masking sites and the acct race, as named criteria. It calls I06 for restore and
save, and keeps the release-mode guard that makes a tag build compile everything from source.

## Scope
In:
- The builder-container runner `factory/bin/run-in-builder` (mounts, env, uid fix-up) used by every stage.
- The package stage: config sync, calls to I06's `cache restore`, plan, emerge, completeness proof, call to `cache save`, report.
- The release-mode guard: no cache call, empty `PKGDIR`, no `binary` plan line.
- The shared stage contract (`out/stage/<stage>.json`, exit codes, `common.sh`) all B-nodes follow.

Out:
- The cache key, per-package fingerprint, restore, save, memo and audit: I06 (B01 only calls them). B01 no longer reads or writes the `binpkg` class itself.
- Kernel build and its config: B02 (B01 excludes `sys-kernel/monolith-kernel` via `stage-provided.txt`).
- Sysroot export, rootfs, squashfs: B04. The old live-ROOT `rsync` export is dropped from this stage.
- Portage snapshot fetch/serve: I02. Distfile mirror and fetch hooks: I04. Builder image contents: I03.
- `store` CLI and backends: F06, I01. Pins reader and `pins/pins.yaml`: I05. `versions.lock` generation: R02.
- Workflow wiring and artifact handoff: B06.

## Design

### Stage contract (shared by B01-B05)
Each stage is `factory/bin/<stage>`, run inside the builder as `run-in-builder <stage> [args]`. Required env,
checked first, exit 2 if unset or empty (no defaults; the predecessor built `themonolith-.squashfs` from an
empty `BUILD_VERSION`, `build-rootfs.sh:23`): `BUILD_VERSION`, `SOURCE_DATE_EPOCH`, `MONOLITH_BUILD_MODE`
(`iterate` or `release`). Exit codes: 0 ok; 1 failure; 2 usage or env; 3 required input absent or empty;
4 honesty gate failed (completeness, determinism, assertion). Success writes `out/stage/<stage>.json`
atomically (tmp + `mv`) and only on success:
```json
{"schema":1,"stage":"packages","build_version":"…","source_date_epoch":1786406400,
 "inputs":{"<name>":{"sha256":"…"}},"outputs":{"<name>":{"path":"out/…","sha256":"…","bytes":123}},
 "tools":{"emerge":"3.0.x","gcc":"…"}}
```
A stage given a missing or zero-byte input from an earlier stage exits 3, naming the file. Logs go to stderr;
stdout carries only requested data. `2>/dev/null` is banned on any path that decides success unless the line
carries `# allow-devnull: <reason>` (lint in AC-16).

### `run-in-builder`
`docker run --rm` with: repo at `/src` **read-only**; `out/` at `/out` read-write; named volumes for
`/var/db/repos` and `/var/cache/distfiles` (as `Makefile:97-101`); `--user root`, `--network` per phase (below);
env passthrough of the contract variables. After the stage, `chown -R "$HOST_UID:$HOST_GID" /out` so outputs
are not root-owned on the host (the predecessor's `chown output/packages` CI step, `build.yml:425`, existed
because of this). Decision: repo mounted `:ro`, rejecting the predecessor's rw `/configs` mount that let
`build-packages.sh:429` overwrite tracked `configs/kernel.config`.

### Package stage phases (`factory/bin/build-packages`)
1. **sync-config.** Copy `recipes/portage/**` to `/usr/i486-linux-musl/etc/portage` with
   `rsync -a --delete` (fatal on error; predecessor used `cp … 2>/dev/null || true`, which neither failed nor
   deleted removed files, `build-packages.sh:59-66`). Register the overlay at `/src/recipes/overlay` in
   `repos.conf`. Mirror **only** `package.mask` to the host `/etc/portage` (BDEPEND resolution; reason kept from
   `build-packages.sh:73-91`). `factory/lib/sysroot-seed.sh` seeds host `games`/`gamestat` groups and sysroot
   `root`/`portage` (uid/gid 250)/`games`/`gamestat` entries, idempotently (`build-packages.sh:94-117`).
2. **key.** Moved to I06. The stage runs `cache key` and `cache fingerprint` (I06) and records `key.json` and
   `fingerprints.tsv` under `out/cache/`. B01 holds no key logic. Rejected: a B01-private hash (v0.2's `cachekey`),
   which the per-package fingerprint replaces.
3. **restore** (`iterate` only). `cache restore out/packages` (I06). It places only entries whose fingerprint
   matches, writes `out/cache/restore.tsv`, prints `CACHE MISS <global>` on a missing set (exit 0) and exits 1 on
   any store error other than absent, with `out/packages` emptied. B01 treats exit 1 as fatal and runs no
   emerge. Then `cache emerge-flags` supplies the `--usepkg --binpkg-respect-use=y --binpkg-changed-deps=y
   --rebuild-if-unbuilt=y` set, so B01 does not restate it. Emerge output-shaping options come from
   `factory/data/build-env.yaml` (I06), so they cannot change without changing the key.
   In `release` mode the stage calls neither `cache` nor `store`, `out/packages` must be empty at start (exit 4
   if not), and no `--usepkg` is passed. Rejected: pushing release-built binpkgs; a signed release must not
   depend on or influence the cache. I06 audits release payloads against the cache after the build instead.
4. **plan.** `i486-linux-musl-emerge --pretend --verbose --usepkg[=n] <atoms>` parsed by `plan_parse.py` into
   `out/stage/packages.plan.tsv` (`cpv<TAB>binary|ebuild`). Atoms are `=<cat>/<pn>-<ver>` for every world line;
   a world atom with no `versions.lock` line is exit 2 before any compile (22 of 99 world atoms lacked one at
   b9f533b: 99 world lines vs 77 lock lines). Atoms listed in `stage-provided.txt` (initially
   `sys-kernel/monolith-kernel B02`) are removed from the set and recorded as `provided-by`.
5. **emerge.** Pass 1: `acct-group/*` and `acct-user/*` found in the plan, `--jobs=1 --oneshot` (serialises the
   uid auto-allocation that dropped `net-dns/dnsmasq`, T-acct-user-dnsmasq-race). Pass 2: all remaining atoms with
   `--jobs=$JOBS --load-average=$JOBS --keep-going --buildpkg` plus the `cache emerge-flags` set (`iterate` only;
   `release` passes none of them).
   `--keep-going` is kept for diagnostics on a 30-60 min run, but its exit status and its output no longer
   decide success. `JOBS = min(nproc, floor(MemAvailable_GiB / 6))`, at least 1, overridable by `JOBS=`;
   6 GiB per job reproduces the predecessor's CI choice of 2 on a 16 GiB runner (`build.yml:288`).
   `unset BUILD_DIR` (multilib-minimal.eclass, `build-packages.sh:241`) is kept. A memory/disk sampler runs in the
   background and is killed by a `trap` on exit (the predecessor's `while true` monitor was never killed).
   Network: the predecessor's compile pass had network access. B01-AC-11 (after MS2) adds `emerge --fetchonly`
   first (mirror-first, I04) and a `--network none` compile pass except for atoms listed with a reason in
   `factory/data/network-exceptions.txt`. Until then the pass is ported as is.
6. **verify-complete.** `verify_complete.py` takes the atom set, `versions.lock`, and the installed set read from
   the VDB under `/usr/i486-linux-musl/var/db/pkg` (not from gpkg files). It exits 4 and prints every atom
   missing or installed at a different version. An older gpkg on disk has no influence.
7. **quickpkg-missing.** For every installed cpv lacking a gpkg (crossdev-provided: musl, linux-headers, libgcc,
   `acct-*` seeded by the image) run `quickpkg --include-config=y =<cpv>`. Errors are fatal and visible (the
   predecessor used `"*/*" 2>/dev/null || true`, `build-packages.sh:323`). These cpvs get `source=builder-image`.
8. **save** (`iterate` only, not on forks). `cache save out/packages /usr/i486-linux-musl --complete=<true|false>`
   (I06; argument form to be reconciled with I06). `complete` is the verdict of step 6, passed in. B01 saves even
   when step 6 failed, because a partial set is internally consistent (I06), and then exits 4. A `cache save`
   failure is exit 1. B01 holds no `store put` logic.
9. **report.** `out/stage/packages.cpv.tsv`: `cpv<TAB>source<TAB>gpkg_path<TAB>sha256` with `source` in
   `built | cache | builder-image`. `source` comes from the plan (`binary` means `cache`, `ebuild` means
   `built`), cross-checked against `out/cache/restore.tsv` from step 3, whose `cache:<sha256>` rows must equal the
   `binary` plan lines. Failed-package logs
   (`/var/tmp/portage/*/*/temp/build.log`) are copied to `out/logs/` on any failure, as the predecessor did.

Outputs: `out/packages/` (the PKGDIR, `BINPKG_FORMAT=gpkg`, `BINPKG_COMPRESS=xz`), `out/logs/`,
`out/stage/packages.json`, `packages.cpv.tsv`, `packages.plan.tsv`.

### Port first
`build-packages` starts as `scripts/build-packages.sh` at b9f533b (435 lines) moved to `factory/bin/build-packages`
with path changes only. Each change after that is forced by one criterion; nothing else is rewritten.

| Predecessor behaviour | Change | Forced by |
|---|---|---|
| FAILURE MASKING 1: success by `compgen -G ...gpkg.tar` (`:286-300`) | completeness from the VDB at the locked version | AC-1 |
| FAILURE MASKING 2: `quickpkg "*/*" 2>/dev/null \|\| true` (`:323`) | only cpvs without a gpkg; errors fatal | AC-10 |
| FAILURE MASKING 3: config sync `cp ... 2>/dev/null \|\| true` (`:59-66,90`) | `rsync -a --delete`, fatal | AC-12 |
| acct-user race (`net-dns/dnsmasq` dropped) | serial first pass for `acct-*` | AC-5 |
| `MONOLITH_USEPKG=n` release switch (`:215-225`) | kept; guard hardened (empty `PKGDIR`, no `binary` line, no cache call) | AC-6 |
| Rw `/configs` mount; kernel config overwritten (`:429`) | `:ro` mount | AC-8 |
| Fixed `-j2` in CI | memory-derived `JOBS` | AC-9 |
| Env defaults (`build-rootfs.sh:23` built `themonolith-.squashfs`) | required contract env | AC-14 |
| Disk monitor never killed | trap | AC-9 |
| Pull and push of one 2 GB epoch blob (`binpkg-store.sh`) | I06 | I06-AC-4..6 |

### Interfaces assumed from other nodes (reconcile at integration)
I02: pinned tree already at `/var/db/repos/gentoo`; the tree commit is read by I06's `cache key` from the pins.
I06: `cache key|fingerprint|restore|emerge-flags|save` as described above. I03: builder provides `rsync`, `qlist`, `quickpkg`, `emaint`, python3,
`CONFIGS_DIR=/configs` baked as ENV (`Makefile:318`). I05: `BUILD_EPOCH`, `SOURCE_DATE_EPOCH` supplied by
`make` from `pins/pins.yaml`.

## Traps and doctrines preserved
- **T-keep-going-hides-drops:** the stale-gpkg glob (`build-packages.sh:295`) is gone; success is VDB completeness
  at the locked version. AC-1, AC-2.
- **T-acct-user-dnsmasq-race:** acct-* merge serially first; any dropped dnsmasq is a completeness failure. AC-5.
- **T-runner-oom:** memory-derived `JOBS`, per-package `gdb-lowmem.conf` kept by R01, sampler cleaned up. AC-9.
- **D-tag-builds-from-source:** `release` mode starts empty, never calls `cache` or `store`, and every cpv must be
  `built` or `builder-image`. AC-6, AC-7.
- **D-state-and-no-hidden-stderr:** lint on `factory/`. AC-16.
- **Principle 9 (authored vs generated):** repo mounted read-only; `git status` clean after the stage. AC-8.
- **Principle 5 (honest success):** cache provenance per cpv from I06's `restore.tsv`; store absent vs error is I06's (I06-AC-4, I06-AC-5); B01 fails on a cache error. AC-10, AC-18, AC-19.
- **Principle 2 (pinned inputs):** compile phase offline. AC-11 (after MS2).

## Gate
- **B01-AC-1** — (Fixes FAILURE MASKING 1.) `verify_complete.py` exits 4 when any locked atom is missing from the VDB or installed at another version, even if a gpkg for that package exists. *Verify:* `tests/fast/package-completeness.test.sh` (fixture VDB, world, lock, stale gpkg). *Tier:* fast.
- **B01-AC-2** — A world atom without a `versions.lock` line makes `build-packages` exit 2 before any emerge; atoms in `stage-provided.txt` are excluded and recorded. *Verify:* `tests/fast/package-atoms.test.sh`. *Tier:* fast.
- **B01-AC-3** — *Withdrawn (v0.3):* the cache key moved to I06 (I06-AC-1, I06-AC-2 for the global key; I06-AC-3 for the per-package fingerprint).
- **B01-AC-4** — *Withdrawn (v0.3):* restore semantics (loud miss, store errors are failures) moved to I06 (I06-AC-4, I06-AC-5). B01's side is B01-AC-18.
- **B01-AC-5** — (Fixes the acct race.) Pass 1 of emerge contains exactly the `acct-group/*` and `acct-user/*` entries of the plan and runs with `--jobs=1`. *Verify:* `tests/fast/package-passes.test.sh` against `plan_parse.py` fixtures. *Tier:* fast.
- **B01-AC-6** — In `release` mode a non-empty `out/packages` at start exits 4, neither `cache` nor `store` is invoked, no `--usepkg` flag is passed, and a plan containing any `binary` line exits 4. *Verify:* `tests/fast/package-release-mode.test.sh` (stub `cache` and `store` that fail if called). *Tier:* fast.
- **B01-AC-7** — A tag-triggered CI build produces `packages.cpv.tsv` with every `source` in `{built, builder-image}`, none `cache`. *Verify:* CI job `packages` on a `v*` ref (or `workflow_dispatch` with `mode=release`), step "assert provenance" (awk over the TSV). *Tier:* slow.
- **B01-AC-8** — `run-in-builder` mounts the repo read-only and `git status --porcelain` is empty after a complete `make packages`. *Verify:* `tests/fast/run-in-builder.test.sh` (parses the generated `docker run` line, `--dry-run`); CI step `git diff --exit-code` after the stage. *Tier:* fast and slow.
- **B01-AC-9** — `JOBS` equals `min(nproc, floor(MemAvailable_GiB/6))` (minimum 1), an explicit `JOBS=` wins, and the background sampler is not running after `build-packages` exits on success or failure. *Verify:* `tests/fast/package-jobs.test.sh`. *Tier:* fast.
- **B01-AC-10** — (Fixes FAILURE MASKING 2.) `quickpkg` failure is fatal (exit 1) and its stderr is shown; only cpvs without a gpkg are packaged. *Verify:* `tests/fast/package-quickpkg.test.sh` with a failing stub. *Tier:* fast.
- **B01-AC-11** — The compile pass runs with `--network none` for every atom not listed in `network-exceptions.txt`; each exception line has a reason. *Verify:* `tests/fast/run-in-builder.test.sh` (dry-run network flag per phase, exceptions-file format); CI `packages` job log. *Tier:* fast and slow. *When:* after MS2 (a hardening of Principle 2 that fixes no verified predecessor bug and may break cargo-fetching ebuilds; the predecessor's network-open compile pass is ported until then).
- **B01-AC-12** — (Fixes FAILURE MASKING 3.) Removing a file from `recipes/portage/package.use/` removes it from the sysroot `etc/portage`, and a failed sync exits 1. *Verify:* `tests/fast/package-sync-config.test.sh` (temp roots). *Tier:* fast.
- **B01-AC-13** — `sysroot-seed.sh` is idempotent and does not overwrite an existing `root`, `portage`, `games` or `gamestat` entry. *Verify:* `tests/fast/sysroot-seed.test.sh`. *Tier:* fast.
- **B01-AC-14** — A stage given a missing or zero-byte input exits 3; a missing contract env var exits 2; `out/stage/<stage>.json` is absent after any failure. *Verify:* `tests/fast/stage-contract.test.sh`. *Tier:* fast.
- **B01-AC-15** — On failure every `build.log` under `/var/tmp/portage` is copied to `out/logs/` and uploaded by CI. *Verify:* `tests/fast/package-faillogs.test.sh` (fake tree); CI `if: failure()` upload step present (checked by `tests/fast/workflow-shape.test.sh`, B06). *Tier:* fast.
- **B01-AC-16** — No `2>/dev/null` appears under `factory/bin` or `factory/lib` without an `# allow-devnull: <reason>` marker on the same line. *Verify:* `tests/fast/no-hidden-stderr.test.sh`. *Tier:* fast.
- **B01-AC-17** — *Withdrawn (v0.3):* the warm-build measurement is I06-AC-16 (after the rc1 seed). B01's cold-build evidence is B01-AC-7 and the first B06 run.
- **B01-AC-18** — In `iterate` mode the stage calls `cache restore out/packages` before the plan and `cache emerge-flags` for its usepkg flags, runs no emerge and exits 1 when `cache restore` exits 1, and takes the `cache:` provenance in `packages.cpv.tsv` from `out/cache/restore.tsv`. *Verify:* `tests/fast/package-cache-calls.test.sh` (stub `cache` with exits 0 and 1, recorded argv, fixture `restore.tsv`). *Tier:* fast.
- **B01-AC-19** — After the completeness check, `iterate` mode calls `cache save` with the verdict (`--complete=true` when `verify_complete.py` exited 0, `false` otherwise), also when completeness failed, then exits 4; forks do not call `cache save`. *Verify:* `tests/fast/package-cache-calls.test.sh`. *Tier:* fast.
- **B01-AC-20** — Output-shaping emerge options in `build-packages` are read from `factory/data/build-env.yaml`: a fixture that adds an option to the script but not to the file fails. *Verify:* `tests/fast/package-build-env.test.sh`. *Tier:* fast.

## RED plan
The tester writes first, all failing because the scripts do not exist: `package-completeness` (fixture with a
stale gpkg of the right name and a VDB lacking the atom; the predecessor logic would pass it),
`package-atoms` (world 99 / lock 77 fixture), `package-cache-calls` (stub `cache` exiting 0 and 1),
`package-release-mode`, `stage-contract`, `no-hidden-stderr` (fails on the first copied-over `|| true`).
Fixtures are small directories under `tests/fast/fixtures/packages/`. No Docker needed.

## Risks and open questions
- Compile-phase `--network none` may break cargo (`games-roguelike/rl144`) or git-sourced ebuilds. Unknown until
  the first run; `network-exceptions.txt` is the escape hatch and must shrink (I04 owns the mirroring fix).
- The acct-* serial pass is a hypothesis for the dnsmasq race (cause recorded in doctrine.yaml, not reproduced).
  If it still drops dnsmasq, AC-1 turns it into a loud failure and the fallback is fixed ids via `package.env`.
- Cache effectiveness is I06's risk (I06-AC-16 measures it). B01 only has to call it correctly.
- `cache save`'s argument for the completeness verdict is assumed; reconcile with I06 at integration.
- Artifact size of `out/packages` for the B06 handoff is unknown (no measurement in the study).
- Interfaces assumed from I02, I03, I05 above; whoever merges second reconciles.
- OD-2 does not affect B01. OD-5 (distfile scope) affects only whether `--network none` can hold.

## Cost
Slices: (1) port the script, stage contract, `common.sh`, `run-in-builder`, lint; (2) the cache calls with a stub
`cache` (AC-18 to AC-20); (3) plan parser, passes, completeness (the named fixes); (4) report, release mode, quickpkg.
About 4 slices. CI cycles, using the predecessor's measured timings: a cache-hot packages step took 7.5 min (whole
build job 13 min); a from-source tag build took 74.6 min (job 78 min). Expect one from-source run (the release
dry run, B01-AC-7) and two or three cache-hot runs once I06's seed is in. Money: runner minutes only; the cache's
storage is I06's.

## Spec defects found
- Env name mismatch: B01's stage contract requires `MONOLITH_BUILD_MODE` (`iterate|release`); I06-AC-10 keys its release guard on `MONOLITH_MODE=release`. One name must win; B01 will export both until SPEC or I06 settles it.
- SPEC §4.2 does not say how the root `Makefile` composes per-node targets. This spec assumes F01's Makefile does
  `include factory/mk/*.mk`; F01 should confirm.
- SPEC §4.1 draws the kernel after B01, but `sys-kernel/monolith-kernel` is a world atom in `versions.lock`.
  This spec resolves it by exclusion (`stage-provided.txt`); the graph text for B01 ("each world atom") should
  say "each world atom except those provided by B02".
