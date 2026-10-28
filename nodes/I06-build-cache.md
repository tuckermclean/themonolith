# I06 — build-cache

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| I | I01, I02, I03, R01 | B01, M03 | — (feeds MS1) | L |

**Owns:** `factory/bin/cache` (`key`, `fingerprint`, `restore`, `save`, `promote`, `seed-rc1`, `memo-get`, `memo-put`,
`result-get`, `result-put`, `audit`), `factory/lib/cache/`, `factory/data/cache-inputs.yaml`,
`factory/data/build-env.yaml`, `tests/fast/cache-*.test.sh`, `tests/fast/fixtures/cache/`, CI job
`cache-seed` (workflow_dispatch, run once per seed).
**Carries from linux-live-iso-factory@b9f533b:** `scripts/binpkg-store.sh` (the oras transport idea and the
`prune-predicate` logic; the one-blob-per-epoch layout is replaced), `scripts/savedconfig-cache.sh` (its
recorded hashes are read once, by `seed-rc1`; the script itself is superseded by the fingerprint),
`scripts/tests/binpkg-store.test.sh` (cases ported: benign miss vs error, prune predicate).
**Study refs:** build.yaml `script.binpkg-store` (401 treated as a miss), `script.savedconfig-cache`,
`script.build-packages` (FAILURE MASKING 1, plain `--usepkg` at `build-packages.sh:221`); T-binpkg-revbump,
T-binpkg-store-fail-open, T-run-rerun-reuses-cache, T-resolved-kernel-config-vacuous,
T-portage-snapshot-fetch; D-tag-builds-from-source, D-all-static; Principles 5, 12; SPEC §5.1.

## Purpose
After I06 a development build restores every binary package whose complete inputs are unchanged and
rebuilds only what a change touches, plus the statically linked packages that embed it. A build whose
inputs are entirely unchanged is skipped and its ISO reused. The cache starts warm, seeded from rc1's
surviving binpkg cache, so the first B01 run in this repo takes minutes instead of 75. Release builds
never read the cache; they audit it.

## Scope
In:
- Global key and per-package fingerprint computation (SPEC §5.1).
- Restore and save of consistent package sets through the `store` CLI (class `binpkg`).
- The whole-build memo and the oracle result cache (class `build`, `memo/` prefix).
- The release audit: from-source payloads compared with cache entries of the same key.
- The one-time rc1 seed.
- `factory/data/build-env.yaml` and `factory/data/cache-inputs.yaml`, with checks that keep them honest.

Out:
- Calling restore/save inside the package stage and the release-mode guard: B01.
- Wiring restore, save, memo and audit into CI and choosing the namespace from the event: B06.
- Store backends and the GHCR transport: F06, I01. Copying the rc1 objects into our namespace: Step 0 in
  `docs/first-attested-build.md`, then I01.
- The tree pin and its commit: I02. The builder image digest: I03.
- Turning audit mismatches into a reproducibility gate: B07.
- Retention and deletion: M03.

## Design

**Global key.** `cache key` writes `out/cache/key.json` (canonical JSON, sorted keys) and prints
`global=<64 hex>` (the sha256 of that file). Fields:
`builder` (image digest from `pins/pins.yaml`), `tree` (gentoo-mirror commit from I02),
`config` (sha256 over sorted relative paths and bytes of `recipes/portage/make.conf`, `bashrc`,
`profile/**`), `eclass` (same over `recipes/overlay/eclass/**`), `build_env` (sha256 of
`factory/data/build-env.yaml`), `schema` (`1`; bump to invalidate everything on a format change).
`package.use`, `package.accept_keywords`, `package.mask` and `versions.lock` are not in the key: portage
checks version and USE itself. Rejected: one key over all of `recipes/portage/` (v0.2's B01 design),
which turns any USE edit into a 75-minute rebuild.

**`build-env.yaml`** lists the environment variables and emerge options that change package bytes
(for example `CFLAGS` overrides passed through `run-in-builder`, and `SOURCE_DATE_EPOCH`, which
embeds into kernel and archive outputs; its value comes from `pins/pins.yaml`). Options that do not change bytes
(`--jobs`, `--keep-going`, restore flags) are not listed. B01 reads build options from this file, so an
output-shaping option cannot be added without changing the key.

**Per-package fingerprint.** `cache fingerprint` runs in the builder (it needs portage's atom matching)
and writes `out/cache/fingerprints.tsv` (`cpv<TAB>fp`) for every cpv in `versions.lock` plus overlay
packages. Inputs, each recorded by relative path and sha256 before hashing:
- overlay packages: `<pf>.ebuild` and `files/**` (not other versions' ebuilds, not `metadata.xml`);
- `recipes/portage/savedconfig/<cat>/<pn>*`;
- each `package.env` line whose atom matches the cpv, and the bytes of the env files it names;
- `recipes/portage/patches/<cat>/<pn>*` and `<pf>*` (if present);
- every path listed for the package's atom in `cache-inputs.yaml`; initially
  `sys-kernel/monolith-kernel: [recipes/kernel/]` and any rootfs paths `monolith-base` installs from
  outside its own directory.
`cache check-inputs` fails when an overlay ebuild reads a repo path through `/src/` or a `MONOLITH_*`
variable that `cache-inputs.yaml` does not list for it.

**Consistent sets.** Blobs: `binpkg <ns><global>/blobs/<sha256>.gpkg.tar`. Sets:
`binpkg <ns><global>/sets/<YYYYmmddTHHMMSSZ>-<run>.json` with `{global, run, complete: bool,
packages: {cpv: {fp, sha256}}}`. `<ns>` is empty for `main` and `pr-<n>/` for pull requests.
- `cache restore <pkgdir>`: requires an empty `pkgdir` (exit 4 otherwise). Lists sets under its own
  namespace, then `main`'s; takes the newest by name. For each entry whose `fp` equals today's
  fingerprint, gets the blob (store verifies sha256) into `pkgdir/<cat>/<pn>/`, reading blobs from the namespace of the set
  it chose (a PR set's blobs live under `pr-<n>/`, a `main` set's under `main`'s). Then runs
  `emaint binhost --fix`. Writes `out/cache/restore.tsv` (`cpv fp sha256|miss reason`), where reason is
  `no-set`, `absent` or `fp-changed`. No set at all is a loud miss (`CACHE MISS <global>` on stderr, exit 0).
  Any `store` error other than absent (exit 3) is exit 1, and `pkgdir` is emptied.
- B01 then runs emerge with `--usepkg --binpkg-respect-use=y --binpkg-changed-deps=y
  --rebuild-if-unbuilt=y` (the flags are emitted by `cache emerge-flags`, so B01 does not restate them).
- `cache save <pkgdir> <sysroot>`: puts every gpkg present in `pkgdir` whose cpv is installed in the
  sysroot VDB at the same version, then writes one set naming them. `complete` is true only if every
  locked atom is installed (B01's completeness verdict, passed in). A failed run may still save a
  partial set: every package in it was built against the others, so it is consistent. Put of an
  existing blob is a no-op (content-addressed). Rejected: per-package keys `<cpv>/<fp>` — a cascade
  rebuild produces new bytes for an unchanged fingerprint, which collides with immutable put.

**Promotion on merge.** Squash-merging a PR puts its tree on `main` unchanged, so `main` would
otherwise rebuild what the PR already built. `cache promote <pr>` (run by B06 on the `push` to `main`)
copies the PR's newest set and memo into the `main` namespace only when the PR's head tree hash equals
the merge commit's tree hash; otherwise it does nothing and `main` builds normally. The blobs are
content-addressed, so only the set and memo manifests are written. The PR was reviewed and merged by a
human, so its outputs carry the same trust as a `main` build of the same tree.

**Memo.** `cache memo-key` prints the ISO input hash: sha256 over `key.json`, `fingerprints.tsv`, and
the sorted path+sha256 list of tracked files under `factory/`, `recipes/`, `pins/`, `image/`,
`.github/workflows/`. B06 calls `memo-put <dir>` after the SBOM step, so a memo entry is complete; it stores `iso`, `sbom`, `iso.sha256` and `manifest.json` (run id,
commit, key fields) at `build <ns>memo/<hash>/<run>/`; `memo-get` returns the newest under the run's
own namespace (and `main`'s, for `main` only). Oracle results: `result-put/result-get` at
`build <ns>memo/results/<iso-sha256>/<mode>/<mode-hash>-<harness-hash>.json`, where `mode-hash` is the
sha256 of the mode's entry in `oracle/modes.yaml` plus any files it names, and `harness-hash` covers
`oracle/` minus `oracle/modes.yaml` and `oracle/golden/`.

**Audit.** `cache audit <pkgdir>` (release mode only, after the from-source build) compares, per cpv,
the payload tarball inside each gpkg (not the metadata, which carries build time) with the payload of
the newest `main` set entry for the same global key and fingerprint. It writes
`out/cache/audit.tsv` (`cpv same|differs|absent`) and never fails the build. B07 consumes it.

**Seed.** `cache seed-rc1` (CI job `cache-seed`, run once): gets
`binpkg-seed@sha256:d0a1838d7504d41c95c050e70d0d5399dbf546dd2e21fdd5f793df2ad700b92d` through the
store's OCI backend, verifies the digest, unpacks it in a scratch dir, and for each gpkg keeps it only if:
its cpv is in this repo's `versions.lock`; the ebuild embedded in its metadata is byte-identical to the
pinned tree's (or the imported overlay's) ebuild; and, for packages the predecessor tracked in
`.savedconfig.sha256` markers (`savedconfig-cache.sh:73,92`), the marker equals today's savedconfig hash.
Fingerprints are today's. The result is one set `sets/20261005T100305Z-rc1-seed.json`
(`complete: false`), with `out/cache/seed-report.tsv` (`cpv kept|dropped reason`) uploaded as evidence.
The seed is valid only if today's global key equals the key rc1's packages were built under; that holds
when R01 is verbatim, I03 adopts the rc1 builder digest, and I02 pins rc1's tree. The job refuses to run
if `recipes/portage/{make.conf,bashrc,profile}` differ from the hashes recorded in
`recipes/IMPORT.yaml` (R01).

## Traps and doctrines preserved
- **T-binpkg-revbump** (an edit without a revbump silently reuses the old binary): the fingerprint
  covers the ebuild and `files/`. AC-3.
- **T-binpkg-store-fail-open** (401 read as a miss, empty cache, exit 0): AC-5.
- **T-run-rerun-reuses-cache**: keys are complete content hashes and not `actions/cache`; a re-run with the
  same inputs gets bytes its inputs name. AC-1, AC-11.
- **T-resolved-kernel-config-vacuous** (kernel checks passing vacuously on a cache hit): the resolved
  config travels inside the kernel package (DCX-99 at `b9f533b`), and the kernel fingerprint covers
  `recipes/kernel/`. AC-3; B02 owns the check itself.
- **D-all-static** (static dependents embed libraries): `--rebuild-if-unbuilt=y`. AC-7.
- **D-tag-builds-from-source**: restore refuses release mode; audit only reads after the build. AC-10.
- **Principle 5** (honest success): per-atom provenance in `restore.tsv`; partial sets labelled. AC-4, AC-6.

## Gate
- **I06-AC-1** — `cache key` is deterministic across two runs and across file-listing order, and changes when one byte of `make.conf`, `bashrc`, a `profile/` file, an eclass, `build-env.yaml`, the builder digest or the tree commit changes; it does not change when `package.use/`, `versions.lock` or an overlay ebuild changes. *Verify:* `tests/fast/cache-key.test.sh`. *Tier:* fast.
- **I06-AC-2** — `key.json` has exactly the fields `builder, tree, config, eclass, build_env, schema`, and an unknown field or a missing pin fails with exit 2. *Verify:* `tests/fast/cache-key.test.sh`. *Tier:* fast.
- **I06-AC-3** — A package's fingerprint changes when its ebuild, a file under its `files/`, its savedconfig, a matching `package.env` line or the env file it names, a matching patch, or a `cache-inputs.yaml` path changes; it does not change when another package's inputs or another version's ebuild change. *Verify:* `tests/fast/cache-fingerprint.test.sh` (fixture overlay; atom matching via a recorded portage fixture). *Tier:* fast.
- **I06-AC-4** — `restore` places only entries whose fingerprint matches, writes `restore.tsv` with `cache:<sha256>` or `miss <reason>` for every locked cpv, and exits 4 on a non-empty `pkgdir`. *Verify:* `tests/fast/cache-restore.test.sh` with the `fs` backend. *Tier:* fast.
- **I06-AC-5** — A `store` error other than absent (stubs for exit 1, auth 401 and network) makes `restore` exit 1 and leaves `pkgdir` empty; absent everywhere prints `CACHE MISS` and exits 0. *Verify:* `tests/fast/cache-restore.test.sh` (stub store). *Tier:* fast.
- **I06-AC-6** — `save` writes one set naming only gpkgs installed in the sysroot VDB at the same version, sets `complete` from the passed verdict, and a second save of identical blobs puts nothing new. *Verify:* `tests/fast/cache-save.test.sh`. *Tier:* fast.
- **I06-AC-7** — With a two-package fixture (static library L, dependent D), changing L's inputs makes a restored build rebuild both L and D, and changing only D rebuilds only D. *Verify:* CI job `cache-cascade` in the builder (fixture overlay with two tiny packages). *Tier:* slow.
- **I06-AC-8** — `restore` prefers the newest set in the run's namespace, falls back to `main`'s, and a `main` run never reads `pr-*`. *Verify:* `tests/fast/cache-namespace.test.sh`. *Tier:* fast.
- **I06-AC-9** — `memo-key` changes when any tracked file under `factory/`, `recipes/`, `pins/`, `image/` or `.github/workflows/` changes, or the key or a fingerprint changes, and not when a file under `docs/`, `oracle/` or `tests/` changes. *Verify:* `tests/fast/cache-memo.test.sh`. *Tier:* fast.
- **I06-AC-10** — With `MONOLITH_BUILD_MODE=release` (B01's variable), `restore`, `memo-get` and `result-get` exit 4 without calling `store`; `audit` refuses to run outside release mode. *Verify:* `tests/fast/cache-release.test.sh` (stub store that fails if called). *Tier:* fast.
- **I06-AC-11** — `result-get` returns a result only for the same ISO sha256, mode hash and harness hash; changing one byte of the mode entry or of a harness file misses. *Verify:* `tests/fast/cache-results.test.sh`. *Tier:* fast.
- **I06-AC-12** — `audit` compares payloads, not gpkg bytes: two gpkgs with the same payload and different build-time metadata are `same`. *Verify:* `tests/fast/cache-audit.test.sh` (fixture gpkgs). *Tier:* fast.
- **I06-AC-13** — `check-inputs` fails on a fixture overlay ebuild that reads `/src/recipes/kernel` when `cache-inputs.yaml` does not list it, and passes when it does. *Verify:* `tests/fast/cache-inputs.test.sh`. *Tier:* fast.
- **I06-AC-14** — `seed-rc1` drops a gpkg whose embedded ebuild differs from the pinned tree, whose cpv is not locked, or whose savedconfig marker differs, records the reason, and refuses to run when the imported global config differs from `recipes/IMPORT.yaml`. *Verify:* `tests/fast/cache-seed.test.sh` (fixture tarball of three gpkgs). *Tier:* fast.
- **I06-AC-15** — The `cache-seed` job on the real rc1 seed produces a set and a `seed-report.tsv`; the job summary states kept and dropped counts. *Verify:* CI job `cache-seed` run log and uploaded report. *Tier:* slow.
- **I06-AC-16** — After the seed, a B01 `iterate` build reports at least 90% of locked cpvs as `cache:` and completes; a second run with no changes hits the memo and skips the build. *Verify:* two `workflow_dispatch` runs of the build workflow; `restore.tsv` and the memo step log. *Tier:* slow. *When:* after MS1.
- **I06-AC-17** — `promote` copies a PR's newest set and memo into `main` when the PR head tree equals the merge commit tree, and does nothing (exit 0, logged) when they differ. *Verify:* `tests/fast/cache-promote.test.sh` (fixture git repo, `fs` store). *Tier:* fast.

## RED plan
The tester writes `cache-key`, `cache-fingerprint`, `cache-restore`, `cache-save`, `cache-namespace`,
`cache-memo`, `cache-release`, `cache-results`, `cache-audit`, `cache-inputs` and `cache-seed` tests
first, against the `fs` store backend from F06 and fixture overlays under `tests/fast/fixtures/cache/`.
They fail because `factory/bin/cache` does not exist. Fingerprint tests need portage's atom matching;
the fixture records `portageq`-style match results so the fast tier runs without the builder, and one
slow case (AC-7) runs the real thing. AC-7 also settles the two unverified portage behaviours.

## Risks and open questions
- Unverified from memory: how `--rebuild-if-unbuilt` and `--binpkg-changed-deps` behave for a crossdev
  `ROOT`/sysroot with gpkg. AC-7 is the first slice for that reason; if the cascade does not work, the
  fallback is to treat a rebuilt library's reverse dependencies (from `equery`-style VDB data) as
  fingerprint-changed.
- The global key cannot see everything that shapes bytes (for example, a factory script that changes
  `ROOT` handling without touching `build-env.yaml`). The release audit is the backstop; review keeps
  `build-env.yaml` honest.
- rc1's seed was built without the cascade, so a seeded dependent may embed a stale library. It cannot
  reach a release (AC-10), and the first full rebuild under a new global key replaces it.
- Assumed, unverified: a gpkg's metadata carries the ebuild it was built from, as xpak did; the seed's
  ebuild match depends on it. AC-14's fixture is built from a real rc1 gpkg to settle it.
- Payload comparison in the audit will report many `differs` until builds are reproducible (B07).
- Unknown: how many GHCR API calls a ~300-blob restore takes and whether it hits rate limits; the
  predecessor pulled one 2 GB blob instead. If needed, the oci backend can batch with `oras` copy of a set
  index; the store contract does not change.

## Cost
Four slices: (1) key, fingerprint, check-inputs (AC-1 to AC-3, AC-13); (2) restore, save, namespaces,
release guard (AC-4 to AC-6, AC-8, AC-10); (3) memo, results, audit (AC-9, AC-11, AC-12); (4) cascade,
seed, warm build, promotion (AC-7, AC-14 to AC-17). CI: one cascade job (~10 min), one seed run (~15 min, 2 GB
download), two warm build runs (~15 min each). Money: GHCR storage for public packages is free today;
private would bill. Expected footprint: ~2 GB per global key in use, plus memo ISOs (~0.2 GB each) for
30 days.
