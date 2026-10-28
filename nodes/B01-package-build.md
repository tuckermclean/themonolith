# B01 — package-build

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| B | I02, I03, I04, I05, R02, R03 | B02, B04 | — (feeds MS2) | L |

**Owns:** `factory/bin/build-packages`, `factory/bin/run-in-builder`, `factory/lib/common.sh`,
`factory/lib/cachekey`, `factory/lib/verify_complete.py`, `factory/lib/sysroot-seed.sh`,
`factory/lib/plan_parse.py`, `factory/data/stage-provided.txt`, `factory/data/network-exceptions.txt`,
`factory/mk/packages.mk`, `tests/fast/package-*.test.sh`, `tests/fast/cachekey.test.sh`,
`tests/fast/stage-contract.test.sh`, `tests/fast/run-in-builder.test.sh`
**Carries from linux-live-iso-factory@b9f533b:** `scripts/build-packages.sh` (rewritten, not copied),
`scripts/binpkg-store.sh` (cache idea only; transport becomes the `store` CLI), `scripts/savedconfig-cache.sh`
(deleted; superseded by the profile hash), `Makefile:75-110` (DOCKER_RUN mounts, rewritten with `:ro`).
**Study refs:** build.yaml `script.build-packages` notes FAILURE MASKING 1-3; `script.binpkg-store` (401 as miss);
`script.savedconfig-cache`; hazards `silent_fallbacks`, `hidden_errors_2_dev_null`, `nondeterminism`;
contradictions (cp does not delete; kernel build mode `unknown`); T-keep-going-hides-drops,
T-acct-user-dnsmasq-race, T-runner-oom, D-tag-builds-from-source, D-state-and-no-hidden-stderr,
D-static-musl-cross-all-the-way, Principles 2, 5, 9.

## Purpose
After B01 a single command cross-compiles the locked world for `i486-linux-musl` and proves, per package, that
it is installed at its locked version and where it came from: built in this run, restored from a cache entry
whose key covers the whole tree and profile, or supplied by the builder image. The predecessor decided success
by globbing for any `.gpkg.tar`, so a stale binary hid a failing rebuild. B01 also gives releases a real
from-source mode.

## Scope
In:
- The builder-container runner `factory/bin/run-in-builder` (mounts, env, uid fix-up) used by every stage.
- The package stage: config sync, cache restore, plan, emerge, completeness proof, cache save, report.
- The binpkg cache key and its use of the `store` CLI (class `binpkg`).
- The shared stage contract (`out/stage/<stage>.json`, exit codes, `common.sh`) all B-nodes follow.

Out:
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
2. **key.** `factory/lib/cachekey` prints `tree=<16 hex> profile=<16 hex>`.
   `tree` = first 16 hex of the sha256 of the pinned snapshot tarball (the value I02 records).
   `profile` = sha256 over, in sorted-path order, the bytes of: `recipes/portage/{make.conf,bashrc}`,
   `env/**`, `package.{env,use,accept_keywords,mask}/**`, `savedconfig/**`, `profile/**`, `pins/crossdev.lock`,
   plus the builder image digest. `versions.lock`, `world` and the overlay are excluded.
   Rationale: portage's own reuse test already keys on cpv and USE; the overlay is sound under R03 (any
   ebuild or `files/` change forces a new `-rN` cpv); `versions.lock` is the cpv list. Everything portage does
   not hash (env files, savedconfig, bashrc, CFLAGS) is in `profile`, which retires `savedconfig-cache.sh`.
   Rejected: hashing the overlay (every ebuild edit would cost a full 30-60 min rebuild); per-package
   dependency hashes (complexity; revisit if rebuild cost bites).
3. **restore** (`iterate` only). `store ls binpkg <tree>/<profile>/` then `store get` each into
   `out/packages/<cat>/<pn>/`. `store` exit 3 on the prefix means miss: print `CACHE MISS <tree>/<profile>`
   and continue with an empty `out/packages`. Any other non-zero exit is fatal (exit 1); a 401 is an
   error, not a miss (fixes `binpkg-store.sh:338`). Then `emaint binhost --fix`.
   In `release` mode `out/packages` must be empty at start (exit 4 if not) and the store is neither read nor
   written. Rejected: pushing release-built binpkgs; a signed release must not depend on or influence the cache.
4. **plan.** `i486-linux-musl-emerge --pretend --verbose --usepkg[=n] <atoms>` parsed by `plan_parse.py` into
   `out/stage/packages.plan.tsv` (`cpv<TAB>binary|ebuild`). Atoms are `=<cat>/<pn>-<ver>` for every world line;
   a world atom with no `versions.lock` line is exit 2 before any compile (22 of 99 world atoms lacked one at
   b9f533b: 99 world lines vs 77 lock lines). Atoms listed in `stage-provided.txt` (initially
   `sys-kernel/monolith-kernel B02`) are removed from the set and recorded as `provided-by`.
5. **emerge.** Pass 1: `acct-group/*` and `acct-user/*` found in the plan, `--jobs=1 --oneshot` (serialises the
   uid auto-allocation that dropped `net-dns/dnsmasq`, T-acct-user-dnsmasq-race). Pass 2: all remaining atoms with
   `--jobs=$JOBS --load-average=$JOBS --keep-going --buildpkg [--usepkg]` (`--usepkg` only in `iterate`).
   `--keep-going` is kept for diagnostics on a 30-60 min run, but its exit status and its output no longer
   decide success. `JOBS = min(nproc, floor(MemAvailable_GiB / 6))`, at least 1, overridable by `JOBS=`;
   6 GiB per job reproduces the predecessor's CI choice of 2 on a 16 GiB runner (`build.yml:288`).
   `unset BUILD_DIR` (multilib-minimal.eclass, `build-packages.sh:241`) is kept. A memory/disk sampler runs in the
   background and is killed by a `trap` on exit (the predecessor's `while true` monitor was never killed).
   Network: `emerge --fetchonly` first (mirror-first, I04); the compile pass runs with `--network none` except
   for atoms listed with a reason in `factory/data/network-exceptions.txt`.
6. **verify-complete.** `verify_complete.py` takes the atom set, `versions.lock`, and the installed set read from
   the VDB under `/usr/i486-linux-musl/var/db/pkg` (not from gpkg files). It exits 4 and prints every atom
   missing or installed at a different version. An older gpkg on disk has no influence.
7. **quickpkg-missing.** For every installed cpv lacking a gpkg (crossdev-provided: musl, linux-headers, libgcc,
   `acct-*` seeded by the image) run `quickpkg --include-config=y =<cpv>`. Errors are fatal and visible (the
   predecessor used `"*/*" 2>/dev/null || true`, `build-packages.sh:323`). These cpvs get `source=builder-image`.
8. **save** (`iterate` only, not on forks). For each gpkg not already present, `store has binpkg <key>`; if
   absent, `store put binpkg <tree>/<profile>/<cpv>.gpkg.tar <file>`. A failed `put` is re-checked with `has`: if the key now
   exists (concurrent run) warn loudly and continue, otherwise exit 1.
9. **report.** `out/stage/packages.cpv.tsv`: `cpv<TAB>source<TAB>gpkg_path<TAB>sha256` with `source` in
   `built | cache | builder-image`. `source` comes from the plan (`binary` means `cache`, `ebuild` means
   `built`), cross-checked against the gpkg set restored in step 3. Failed-package logs
   (`/var/tmp/portage/*/*/temp/build.log`) are copied to `out/logs/` on any failure, as the predecessor did.

Outputs: `out/packages/` (the PKGDIR, `BINPKG_FORMAT=gpkg`, `BINPKG_COMPRESS=xz`), `out/logs/`,
`out/stage/packages.json`, `packages.cpv.tsv`, `packages.plan.tsv`.

### Interfaces assumed from other nodes (reconcile at integration)
I02: pinned tree already at `/var/db/repos/gentoo`, snapshot sha256 readable as `out/stage/snapshot.json`
(`outputs.snapshot.sha256`). I03: builder provides `rsync`, `qlist`, `quickpkg`, `emaint`, python3,
`CONFIGS_DIR=/configs` baked as ENV (`Makefile:318`). I05: `BUILD_EPOCH`, `SOURCE_DATE_EPOCH` supplied by
`make` from `pins/pins.yaml`.

## Traps and doctrines preserved
- **T-keep-going-hides-drops:** the stale-gpkg glob (`build-packages.sh:295`) is gone; success is VDB completeness
  at the locked version. AC-1, AC-2.
- **T-acct-user-dnsmasq-race:** acct-* merge serially first; any dropped dnsmasq is a completeness failure. AC-5.
- **T-runner-oom:** memory-derived `JOBS`, per-package `gdb-lowmem.conf` kept by R01, sampler cleaned up. AC-9.
- **D-tag-builds-from-source:** `release` mode starts empty, never touches the store, and every cpv must be
  `built` or `builder-image`. AC-6, AC-7.
- **D-state-and-no-hidden-stderr:** lint on `factory/`. AC-16.
- **Principle 9 (authored vs generated):** repo mounted read-only; `git status` clean after the stage. AC-8.
- **Principle 5 (honest success):** store absent vs error; cache provenance per cpv. AC-3, AC-4, AC-10.
- **Principle 2 (pinned inputs):** compile phase offline. AC-11.

## Gate
- **B01-AC-1** — `verify_complete.py` exits 4 when any locked atom is missing from the VDB or installed at another version, even if a gpkg for that package exists. *Verify:* `tests/fast/package-completeness.test.sh` (fixture VDB, world, lock, stale gpkg). *Tier:* fast.
- **B01-AC-2** — A world atom without a `versions.lock` line makes `build-packages` exit 2 before any emerge; atoms in `stage-provided.txt` are excluded and recorded. *Verify:* `tests/fast/package-atoms.test.sh`. *Tier:* fast.
- **B01-AC-3** — `cachekey` is deterministic; changing one byte of `savedconfig/sys-apps/busybox`, `make.conf`, `crossdev.lock` or the builder digest changes `profile`; changing the snapshot hash changes `tree`; editing the overlay or `versions.lock` changes neither. *Verify:* `tests/fast/cachekey.test.sh`. *Tier:* fast.
- **B01-AC-4** — Restore treats `store` exit 3 on the prefix as a loud miss and any other non-zero exit (including auth and network stubs) as exit 1 with no partial `out/packages` use. *Verify:* `tests/fast/package-restore.test.sh` with a stub `store`. *Tier:* fast.
- **B01-AC-5** — Pass 1 of emerge contains exactly the `acct-group/*` and `acct-user/*` entries of the plan and runs with `--jobs=1`. *Verify:* `tests/fast/package-passes.test.sh` against `plan_parse.py` fixtures. *Tier:* fast.
- **B01-AC-6** — In `release` mode a non-empty `out/packages` at start exits 4, `store` is never invoked, and a plan containing any `binary` line exits 4. *Verify:* `tests/fast/package-release-mode.test.sh` (stub `store` that fails if called). *Tier:* fast.
- **B01-AC-7** — A tag-triggered CI build produces `packages.cpv.tsv` with every `source` in `{built, builder-image}`, none `cache`. *Verify:* CI job `packages` on a `v*` ref (or `workflow_dispatch` with `mode=release`), step "assert provenance" (awk over the TSV). *Tier:* slow.
- **B01-AC-8** — `run-in-builder` mounts the repo read-only and `git status --porcelain` is empty after a complete `make packages`. *Verify:* `tests/fast/run-in-builder.test.sh` (parses the generated `docker run` line, `--dry-run`); CI step `git diff --exit-code` after the stage. *Tier:* fast and slow.
- **B01-AC-9** — `JOBS` equals `min(nproc, floor(MemAvailable_GiB/6))` (minimum 1), an explicit `JOBS=` wins, and the background sampler is not running after `build-packages` exits on success or failure. *Verify:* `tests/fast/package-jobs.test.sh`. *Tier:* fast.
- **B01-AC-10** — `quickpkg` failure is fatal (exit 1) and its stderr is shown; only cpvs without a gpkg are packaged. *Verify:* `tests/fast/package-quickpkg.test.sh` with a failing stub. *Tier:* fast.
- **B01-AC-11** — The compile pass runs with `--network none` for every atom not listed in `network-exceptions.txt`; each exception line has a reason. *Verify:* `tests/fast/run-in-builder.test.sh` (dry-run network flag per phase, exceptions-file format); CI `packages` job log. *Tier:* fast and slow.
- **B01-AC-12** — Removing a file from `recipes/portage/package.use/` removes it from the sysroot `etc/portage`, and a failed sync exits 1. *Verify:* `tests/fast/package-sync-config.test.sh` (temp roots). *Tier:* fast.
- **B01-AC-13** — `sysroot-seed.sh` is idempotent and does not overwrite an existing `root`, `portage`, `games` or `gamestat` entry. *Verify:* `tests/fast/sysroot-seed.test.sh`. *Tier:* fast.
- **B01-AC-14** — A stage given a missing or zero-byte input exits 3; a missing contract env var exits 2; `out/stage/<stage>.json` is absent after any failure. *Verify:* `tests/fast/stage-contract.test.sh`. *Tier:* fast.
- **B01-AC-15** — On failure every `build.log` under `/var/tmp/portage` is copied to `out/logs/` and uploaded by CI. *Verify:* `tests/fast/package-faillogs.test.sh` (fake tree); CI `if: failure()` upload step present (checked by `tests/fast/workflow-shape.test.sh`, B06). *Tier:* fast.
- **B01-AC-16** — No `2>/dev/null` appears under `factory/bin` or `factory/lib` without an `# allow-devnull: <reason>` marker on the same line. *Verify:* `tests/fast/no-hidden-stderr.test.sh`. *Tier:* fast.
- **B01-AC-17** — A cold `iterate` build on a runner completes with every locked atom present and a second run with the cache saved by the first reports every non-builder cpv as `cache`. *Verify:* CI job `packages` run twice (workflow_dispatch). *Tier:* slow.

## RED plan
The tester writes first, all failing because the scripts do not exist: `package-completeness` (fixture with a
stale gpkg of the right name and a VDB lacking the atom; the predecessor logic would pass it),
`package-atoms` (world 99 / lock 77 fixture), `cachekey`, `package-restore` (stub `store` exiting 3, 4, 5),
`package-release-mode`, `stage-contract`, `no-hidden-stderr` (fails on the first copied-over `|| true`).
Fixtures are small directories under `tests/fast/fixtures/packages/`. No Docker needed.

## Risks and open questions
- Compile-phase `--network none` may break cargo (`games-roguelike/rl144`) or git-sourced ebuilds. Unknown until
  the first run; `network-exceptions.txt` is the escape hatch and must shrink (I04 owns the mirroring fix).
- The acct-* serial pass is a hypothesis for the dnsmasq race (cause recorded in doctrine.yaml, not reproduced).
  If it still drops dnsmasq, AC-1 turns it into a loud failure and the fallback is fixed ids via `package.env`.
- Whether a coarse profile hash makes iteration too slow. Measure in the first two slow runs; B01-AC-17 gives the data.
- Artifact size of `out/packages` for the B06 handoff is unknown (no measurement in the study).
- Interfaces assumed from I02, I03, I05 above; whoever merges second reconciles.
- OD-2 does not affect B01. OD-5 (distfile scope) affects only whether `--network none` can hold.

## Cost
Slices: (1) stage contract, `common.sh`, `run-in-builder`, lint; (2) cachekey, restore/save with stub store;
(3) plan parser, passes, completeness; (4) report, release mode, quickpkg. About 4 slices. CI cycles: 3-4 cold
builds at 30-60 min (first green, cached rerun, release dry run, one repair). Money: binpkg class storage in the
store, order of hundreds of MB per tree/profile pair (unmeasured); runner minutes only.

## Spec defects found
- B01 needs `BUILD_EPOCH`, `SOURCE_DATE_EPOCH` and the snapshot hash from the pin ledger, but graph.yaml gives B01
  no dependency on I05 (and B06 none either). Add `I05` to B01 and B06 deps.
- SPEC §4.2 does not say how the root `Makefile` composes per-node targets. This spec assumes F01's Makefile does
  `include factory/mk/*.mk`; F01 should confirm.
- SPEC §4.1 draws the kernel after B01, but `sys-kernel/monolith-kernel` is a world atom in `versions.lock`.
  This spec resolves it by exclusion (`stage-provided.txt`); the graph text for B01 ("each world atom") should
  say "each world atom except those provided by B02".
