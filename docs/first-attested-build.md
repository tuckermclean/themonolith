# Path to the first attested build

Status: plan, 2026-10-27. Milestone MS2 in `docs/graph.yaml`. The authority is SPEC.md v0.3; this
document explains the order of work and why it is fast.

## Definition of done

A tag `v0.2.0-rc1` on `tuckermclean/themonolith`:
- compiles every package from source with no cache (D-tag-builds-from-source);
- passes all 17 inherited boot modes, the artifact doctrine checks and the SBOM, license, CVE and
  unowned-files gates;
- carries a Sigstore SLSA provenance attestation whose subject is the ISO digest; the digest chain
  is checked mechanically;
- is published as a GitHub prerelease with the ISO, SBOM and SHA256SUMS.

No S3, no vendor name in any workflow, and every input is pinned and held in our own store.

## Why this is weeks, not months

The v0.2 plan treated the rebuild as new construction. Most of the predecessor works, and four of its
assets survived the AWS shutdown. Each one removes work from the critical path.

| Asset | Where | Identity | Removes |
|---|---|---|---|
| rc1 builder image (crossdev i486-musl toolchain, built from the now-pruned 20260810 tree) | `ghcr.io/tuckermclean/monolith-builder:20260810-d9d08d1c7422` (public) | `sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa`, 1.36 GB | Rebuilding the toolchain from a dead snapshot; I03 becomes adopt-and-declare |
| rc1 binpkg cache (every package at b9f533b, BUILD_EPOCH 20260811; pushed 2026-10-05) | `ghcr.io/tuckermclean/monolith-binpkgs:20260811` (public) | `sha256:d0a1838d7504d41c95c050e70d0d5399dbf546dd2e21fdd5f793df2ad700b92d`, 2.09 GB | The 75-minute package compile on every iteration |
| rc1's Gentoo tree | `github.com/gentoo-mirror/gentoo` history (the snapshot tarball is gone; the tree is not) | a commit near 2026-08-11 00:00 UTC; spot check: 25 of 25 sampled `versions.lock` entries exist at `d4d0b0c7` (2026-08-10T22:30Z) | The lost `gentoo-20260811.tar.xz`; keeps rc1's cache valid |
| v0.1.0-rc1 release | GitHub release on the predecessor | ISO `a9600659…eb27a`, SBOM `3cfc322a…75887` | Waiting for our own ISO before the oracle and gates can be ported |

Measured on the predecessor (GitHub Actions, run 37292535170 cache-hot and run 32507406633 for the
rc1 tag):

| Step | Cache-hot | From source |
|---|---|---|
| Build packages | 7.5 min | 74.6 min |
| Whole build job | 13 min | 78 min |
| 17 boot modes (parallel; nic-models is the longest) | ~10 min wall | same |
| Attestation job | 4.7 min | same |

So with the rc1 cache restored, an iteration is about 25 minutes wall time to a tested ISO, and the
one from-source release build is about 95 minutes.

## The five moves

1. **Rescue the assets now** (owner, an hour; Step 0 below). They are the only copies.
2. **Pin rc1's tree first** (OD-6 default). The first build changes the factory, not the packages. That
   keeps the cache valid, keeps the SBOM diff against rc1 small enough to explain line by line, and
   makes any oracle failure a factory bug rather than a package-version question. M01 moves to a
   current tree right after MS2, as its own measured change.
3. **Port first** (Principle 11). Scripts, workflows and recipes move over unchanged unless a criterion
   forces a change. R01 imports the recipes verbatim, so rc1's cache keys match. The study's verified
   bugs are fixed as separate, named criteria.
4. **Develop the oracle and gates against rc1** (the rc1 lane, SPEC §7). Boot harness, all 17 modes,
   doctrine checks, SBOM, license, CVE and unowned gates are ported and made to pass on rc1's own
   artifacts before this repo builds anything. They run in parallel with the build work and are ready
   when B06 produces the first ISO. Where rc1 fails a check because of a known bug (for example the
   shipped musl loader, OD-2), the check records an expected rc1 failure and is strict on our builds.
5. **Cache everything that is content-addressable** (I06, SPEC §5.1). Details below.

## Step 0 — owner actions (before any node)

1. Stop the predecessor's schedules so nothing prunes or rewrites the rc1 assets. `S3 GC` also runs the
   GHCR GC, which deletes binpkg epochs other than the current one; `Pin Bump` can move the current
   epoch and auto-merges with `--admin`.
   ```sh
   R=tuckermclean/linux-live-iso-factory
   for w in "S3 GC" "Pin Bump" "Toolchain Bump" "Nightly CVE re-scan" "CVE Gate Canary" "Build"; do
     gh workflow disable "$w" -R "$R"
   done
   ```
2. Copy the two GHCR objects into the new repo's namespace by digest. This needs a token with
   `write:packages`; use it transiently, as AGENTS.md requires for workflow-scoped tokens.
   ```sh
   oras cp ghcr.io/tuckermclean/monolith-builder@sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa \
           ghcr.io/tuckermclean/themonolith/builder:rc1
   oras cp ghcr.io/tuckermclean/monolith-binpkgs@sha256:d0a1838d7504d41c95c050e70d0d5399dbf546dd2e21fdd5f793df2ad700b92d \
           ghcr.io/tuckermclean/themonolith/binpkg-seed:rc1
   ```
   A copy keeps the digest, so every pin stays valid whichever name it is pulled by.
3. Settle or accept the defaults for the decisions on the critical path: OD-1 (the advisory URL baked
   into the disc by P06), OD-2 (static truth; O06 needs it), OD-6 (first tree), OD-9 and OD-15 (CVE gate on a
   2026-08 tree), OD-13 (Tier-0 9P symbols). OD-4 and OD-10 block only the agent loop, which is no
   longer a gate.

## Order of work

Thirty-one nodes are on the critical path (`track: critical`); most are ports. The longest chain is twelve
nodes:

```text
F01 ─▶ F06 ─▶ I01 ─▶ I03 ─▶ I04 ─▶ B01 ─▶ B02 ─▶ B03 ─▶ B05 ─▶ B06 ─▶ S05 ─▶ P02
```

Everything else runs in four streams beside it:

| Stream | Nodes | Works against | Ready for |
|---|---|---|---|
| Inputs | I02 (tree), I05 (pins), I06 (cache + rc1 seed) | GHCR, gentoo-mirror | B01 |
| Recipes | R01 (verbatim), R02 (lock), R04 (kernel fragments), P06 (disc advisory URL → OD-1 name) | predecessor at `b9f533b` | I06 seed, B01, B02, B04 |
| Oracle | O01 harness, O02–O05 modes, O06 doctrine checks | rc1 ISO and squashfs | B06 `oracle-gate`, S05 |
| Supply chain | S01 SBOM (must reproduce rc1's `bom.cdx.json`), S02–S04 gates | rc1 rootfs and SBOM | S05 |

Rough calendar, a planning guess for one owner with agent help, not a measurement:

| Week | Done |
|---|---|
| 1 | Step 0; F01, F06, I01, R01, O01; I03 adopted; O02 passing on rc1 |
| 2 | I02 tree recovered; I05, R02, R04; I06 with the seed restoring; S01 reproducing rc1's SBOM; O03–O06 on rc1 |
| 3 | B01–B05 ports, cache-hot (~25 min per cycle); B06 → **MS1, first ISO** |
| 4 | S02–S05; P02; tag `v0.2.0-rc1`, one from-source build → **MS2** |

The slack is in week 4: the first from-source build may expose a distfile that vanished upstream since
August (I04 mirrors on fetch and records it) or a CVE that needs OD-15.

## The build cache (I06)

What iterating costs once I06 is in place:

| Change | What rebuilds | Approximate wall time |
|---|---|---|
| Docs, oracle code, a gate, a policy file | Nothing; the memo returns the ISO; only affected modes or gates re-run | 2–10 min |
| One leaf package's recipe (ebuild, savedconfig, env) | That package | ~15 min to a tested ISO |
| A statically linked library (openssl, ncurses, zlib) | The library and every package that links it (`--rebuild-if-unbuilt`) | 20–60 min |
| Kernel fragments | The kernel package, initrd, ISO | ~15–20 min |
| Global config (`make.conf`, `bashrc`, profile), the builder image, the tree pin | Everything: new namespace | ~95 min, once; then hot again |
| A release tag | Everything from source, no cache read; the cache is audited | ~95 min |

Design summary (SPEC §5.1 is normative; `nodes/I06-build-cache.md` has the criteria):

- **Three layers.** The builder image by digest; binary packages by global key and per-package
  fingerprint; the whole build by input hash (the memo).
- **Global key:** builder digest, tree commit, global portage config, overlay eclasses,
  `factory/data/build-env.yaml`. A change here can touch every package, so it opens an empty namespace.
- **Per-package fingerprint:** the inputs portage cannot see — the ebuild and `files/` of overlay
  packages, savedconfig, matching `package.env` lines and their env files, user patches and paths listed
  in `factory/data/cache-inputs.yaml`. Version and USE are left to portage (`--binpkg-respect-use=y`,
  `--binpkg-changed-deps=y`). An overlay edit without a revbump still misses the cache, which ends
  T-binpkg-revbump ("the fix does nothing").
- **Consistent sets:** blobs are stored by content hash; each run writes one immutable set (cpv →
  fingerprint, blob) describing its final sysroot. Restore takes the newest set and keeps the entries
  whose fingerprint still matches. Keying blobs per package alone would break when a rebuild cascade
  produces new bytes for a package whose own inputs did not change.
- **Static linking:** a dependent embeds its libraries, so restore runs with `--rebuild-if-unbuilt=y`.
  The predecessor did not (`scripts/build-packages.sh:221`), so its cached dependents could embed stale
  libraries; rc1 itself was built from source and is not affected.
- **Honesty:** only matching entries enter `PKGDIR`; each atom is reported `built` or
  `cache:<sha256>`; store errors fail the run (the predecessor's pull treated 401 as a miss).
- **Trust:** `main` writes the shared namespace; PRs write `pr-<n>/`. Releases never read the cache
  and compare their from-source payloads against it, which is the backstop for any input the keys miss.
- **Seed:** rc1's 2.09 GB cache is split into per-package entries under the global key the verbatim
  import produces. A package is kept only if its embedded ebuild matches the pinned tree byte for byte.
- Not `actions/cache` (T-run-rerun-reuses-cache) and not ccache. ccache would help only while iterating
  on one failing package and is left as a later option.

## Deferred until after MS2

B07 (reproducibility; the cache audit feeds it), P03 (dashboard), P04 (boot demo), M02 (builder rebuild
from a mirrored stage3), M04, G01–G05, X01. Parallel, wanted soon: F02, F04, F05 (loop), R03, R05, O07,
P01, P05, M01 (first tree bump), M03.

## Risks

- **Tree recovery** may not match rc1's snapshot exactly. I02 picks the commit by comparing the
  ebuilds embedded in rc1's binary packages; packages that differ are dropped from the seed and rebuild.
  Unverified: whether gentoo-mirror commit signatures can be checked against a published Gentoo key.
- **The rc1 seed** was built without the rebuild cascade, so a seeded dependent could embed a stale
  library. The release build is from source and audits the cache, so this cannot reach a release.
- **CVE gate** on a 2026-08 tree may fail on fixable criticals (OD-15).
- **The adopted builder image** cannot be rebuilt until M02 mirrors a stage3 and the 20260810 tree;
  until then its digest is the pin and its contents are declared, not reproduced.
- **Unverified portage behaviour:** the exact semantics of `--rebuild-if-unbuilt` with a cross
  `ROOT`/sysroot, and of `--binpkg-changed-deps` for gpkg. I06's first slice tests both on a
  two-package fixture before anything relies on them.
- The calendar is a guess. The measured numbers are the build and boot timings above.
