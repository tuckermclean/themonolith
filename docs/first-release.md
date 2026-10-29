# Path to the first reproducible release

Status: plan, 2026-10-28. This is milestone MS2 in `docs/graph.yaml`. SPEC.md v0.4 is the authority;
this document gives the order of work and the reasons for it.

## Definition of done

A tag `v0.2.0-rc1` on `tuckermclean/themonolith` (OD-8) that meets all of these:
- It compiles every package from source with no binary-package reuse (D-tag-builds-from-source).
- It passes the 17 inherited boot modes, the artifact doctrine checks, the SBOM and the licence, CVE and
  unowned gates.
- It carries a Sigstore SLSA provenance attestation from `actions/attest-build-provenance` whose subject
  is the ISO digest. The digest chain is re-verified before publishing.
- It is published as a GitHub prerelease with these assets: the ISO, the SBOM, SHA256SUMS,
  `release-inputs.json`, the SBOM diff against rc1 and the size report.
- Its distfiles, tree and builder image are archived on GHCR by digest.
- An independent rebuild from `release-inputs.json` has been compared with diffoscope. Every difference
  is listed in `docs/known-differences.md` with a cause.

No S3, no AWS credential, nothing unpinned.

## The approach: port, then fix

The predecessor builds this product today, except for storage. So the work is a port, not new
construction:
- Recipes, scripts, tests and workflows move over unchanged (F01).
- The S3 calls are replaced by GHCR and GitHub Releases (I01).
- The tree and builder are pinned by digest (I02, I03).
- The study's verified bugs are fixed one criterion at a time.

The oracle and gates are ported and made to pass against rc1's own artifacts first (the rc1 lane, SPEC
§7). They are therefore ready before the first ISO of our own exists.

What v0.4 does **not** build: a storage abstraction, a content-addressed build cache, a system
inventory, a graph validator, an agent loop or commit-identity CI. SPEC §5 records why each is
unnecessary. The review record `docs/reviews/2026-10-28-v0.4.md` maps every v0.3 node to its fate.

## Surviving assets

| Asset | Where | Identity | Use |
|---|---|---|---|
| rc1 builder image | `ghcr.io/tuckermclean/monolith-builder:20260810-d9d08d1c7422` (public) | `sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa`, 1.36 GB | Adopted by digest (I03); rebuilt later (M02) |
| rc1 binpkg cache | `ghcr.io/tuckermclean/monolith-binpkgs:20260811` (public) | `sha256:d0a1838d7504d41c95c050e70d0d5399dbf546dd2e21fdd5f793df2ad700b92d`, 2.09 GB | Preserved for comparison only. It is not restored: it was built across many commits under one epoch, so its entries need not match `b9f533b`'s config. One cold build (~78 min) replaces it. |
| rc1's Gentoo tree | `github.com/gentoo-mirror/gentoo` history | All 25 sampled `versions.lock` entries exist at `d4d0b0c7` (2026-08-10T22:30Z) | I02 picks the exact commit and archives it |
| v0.1.0-rc1 release | GitHub release on the predecessor | ISO `a96006596b13cc09fa951f54aadc0b816765d783e5d0e40895d7d0945edeb27a`, SBOM `3cfc322a0e105638452baa6900552769a6ad5bfbf3be190a9808ac98ca575887` | rc1 lane for O01, O02, S01; baseline for the SBOM diff |
| Gentoo stage3 for the builder | Docker Hub `gentoo/stage3:amd64-openrc-20260810` | pin by digest (M02) | Rebuilding the builder image |

## Measured timings

These come from the predecessor's GitHub Actions runs: run 37292535170 (cache-hot) and run 32507406633
(the rc1 tag).

| Step | Cache-hot | From source |
|---|---|---|
| Build packages | 7.5 min | 74.6 min |
| Whole build job | 13 min | 78 min |
| 17 boot modes (parallel; nic-models is the longest at 9.1 min) | ~10 min wall | same |
| Attestation job | 4.7 min | same |

| Change | What rebuilds | Approximate wall time to a tested ISO |
|---|---|---|
| A script, test, gate or policy | Nothing in Portage; the binpkgs are restored | ~25 min |
| An overlay ebuild (with its revbump) or a `package.use` line | That package, and its static dependents (`--rebuild-if-unbuilt`) | ~25–60 min |
| A savedconfig, such as the kernel or busybox | That package (ported savedconfig marker) | ~25–35 min |
| `make.conf`, `bashrc`, `env/`, `package.env`, the profile, the builder or the tree | Everything: a new cache tag | ~90 min once, then hot again |
| A release tag | Everything from source, then the rebuild check | ~95 min, plus ~80 min for P02 |

## Step 0: owner actions (before any node)

1. **Stop the predecessor's schedules,** so nothing prunes or rewrites the rc1 assets. `S3 GC` also runs
   the GHCR GC, which deletes binpkg epochs other than the current one. `Pin Bump` merges with `--admin`.
   ```sh
   R=tuckermclean/linux-live-iso-factory
   for w in "S3 GC" "Pin Bump" "Toolchain Bump" "Nightly CVE re-scan" "CVE Gate Canary" "Build"; do
     gh workflow disable "$w" -R "$R"
   done
   ```
2. **Copy the two GHCR objects into the new namespace by digest.** This needs a token with
   `write:packages`. Use it transiently, as AGENTS.md requires.
   ```sh
   oras cp ghcr.io/tuckermclean/monolith-builder@sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa \
           ghcr.io/tuckermclean/themonolith/builder:rc1
   oras cp ghcr.io/tuckermclean/monolith-binpkgs@sha256:d0a1838d7504d41c95c050e70d0d5399dbf546dd2e21fdd5f793df2ad700b92d \
           ghcr.io/tuckermclean/themonolith/rc1-binpkgs:20260811
   ```
   A copy keeps the digest. Then set both packages, and every later one, to public in the package
   settings. GHCR creates packages private.
3. **Settle the decisions on the path, or accept the defaults:**
   - OD-1: the advisory URL baked into the disc; default `https://monolith.technomantics.com/`.
   - OD-2: whether a prerelease may ship dynamic binaries; default yes, with a shrinking list.
   - OD-6: the first tree; default rc1's.
   - OD-8: the version; default `v0.2.0-rc1`.
   - OD-15: CVE waivers on the August tree; default a 30-day expiry.
   - OD-16: the CD budget; default the whole 74-minute CD-R.

   OD-9 and OD-13 have defaults that need no action.
4. **Protect `main`:** require the fast-tier check and owner review, and add CODEOWNERS (SPEC §8).

## Order of work

Thirteen nodes are on the critical path. The longest chain has seven:

```text
F01 ─▶ I01 ─▶ I02 ─▶ B01 ─▶ B03 ─▶ P01 ─▶ P02
```

Once F01 lands, the rest run beside that chain:

| Stream | Nodes | Works against | Ready for |
|---|---|---|---|
| Inputs | I01, then I02 and I03 | GHCR, gentoo-mirror | B01 |
| Recipes | B02 (kernel savedconfig and bugs), R01 (advisory URL) | the ported tree | B03 |
| Oracle | O01 (17 modes), O02 (artifact checks) | the rc1 ISO and squashfs | B03 |
| Supply chain | S01 (SBOM and gates; must reproduce rc1's SBOM) | rc1's rootfs and SBOM | B03 |

A rough calendar for one owner with agent help. This is a planning guess, not a measurement:

| Week | Done |
|---|---|
| 1 | Step 0; F01; I01; I03; B02 and R01; O01 passing on rc1 |
| 2 | I02 tree recovered; B01 with the first cold build (~78 min); O02 and S01 passing on rc1 |
| 3 | B03 → **MS1** (first ISO, full oracle green); P01; tag `v0.2.0-rc1`; P02 → **MS2** |

The slack is in week 3. The first from-source build may expose a distfile that has vanished upstream
since August; P01 archives what it fetched, so this happens once. The CVE gate may also need OD-15.

## After MS2

These nodes are in the `later` track:
- R02: overlay QA with `pkgcheck` and the revbump check.
- R03: an empty dynamic allowlist.
- M01: tree bumps, the first one off rc1's tree.
- M02: rebuilding the builder from a stage3.
- P03: the advisory feed behind the OD-1 URL.
- G01: README claims tested or removed.
- X01: cutover, the first non-prerelease.

## Risks

- **Tree recovery** may not match rc1's snapshot exactly. I02 picks the commit by comparing
  `versions.lock` and the ebuilds against candidates. A mismatch only changes package versions, which
  the SBOM diff against rc1 then shows.
- **Unverified:** whether gentoo-mirror commit signatures can be checked against a published Gentoo key
  (I02).
- **Unverified:** how `--rebuild-if-unbuilt` behaves with a cross `ROOT` (B01). Releases build from
  source, so a wrong answer only affects development ISOs.
- **The CVE gate** may block a 2026-08 tree on fixable criticals (OD-15).
- **The adopted builder image** is pinned by digest but not yet reproduced. M02 rebuilds it.
- **Reproducibility:** the predecessor never compared two builds, so the first known-differences list may
  be long. MS2 requires it to be complete, not empty.
- **The calendar is a guess.** The measured numbers are the build and boot timings above.
