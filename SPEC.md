# The Monolith — Specification

Version 0.2 (draft, 2026-10-27; revised after the node-spec review). This document is the authority for the repository. Where a node
spec (`nodes/<id>.md`) and this document disagree, this document wins and the node spec is a defect.
The dependency graph is `docs/graph.yaml`. The study of the predecessor repository is frozen in
`docs/study/` and is evidence, not authority.

---

## 0. What this repository is

The Monolith is a bootable artifact from the future: one live ISO carrying a complete GNU/Linux
userland that boots on an i486 with a few MB of RAM and on a modern UEFI machine. It is built from
source against musl and attested end to end.

This repository is a rebuild. Its predecessor, `tuckermclean/linux-live-iso-factory` (frozen at
`b9f533b`, released `v0.1.0-rc1`), proved the product and accumulated the knowledge to build it. Its
factory — the workflows, scripts and storage around the recipes — grew piecemeal, hard-wired one
storage vendor into five jobs, and died when that vendor's account was disabled. The rebuild keeps
the **recipes** (the hard-won ebuilds, configs and patches), rebuilds the **factory** from the
principles below, and uses the predecessor's **tests** as the acceptance oracle.

### 0.1 The myth (and why it is load-bearing)

The Monolith is an object that arrives in a world whose clock never started. Its origin is
1970-01-01, the Unix epoch — "the truest image of a machine whose clock never started" — not Y2K,
which comes after the origin in the story. Its constituency is the kid's machine: a Socket-7
486-class board with a VIA, SiS or ALi southbridge, which is Tier 0 by definition. The prompt carries
a black square. These are not decoration: they decide test sentinels (§3, D-clock-origin-1970),
kernel tiering (D-486-tier-regime) and what may never be added (D-486-minimalism).

---

## 1. Product

- **Targets:** i486 and up (BIOS via ISOLINUX), x86_64 UEFI machines (GRUB EFI, i386 kernel),
  common hypervisors (QEMU/KVM, VirtualBox, Hyper-V per G03), USB and optical media (hybrid ISO).
- **Userland:** the world set inherited from the predecessor (99 atoms at `b9f533b`), cross-compiled
  `i486-linux-musl`, `-march=i486 -mtune=i486 -Os`.
- **GUI:** kdrive Xfbdev (TinyX), bitmap fonts only (Terminus default), dwm, st, Stele browser.
- **Services on the disc:** networking (`monolith-net`, `monolith-router`, nftables, dnsmasq,
  dhcpcd), persistence (`monolith-persist`), clock honesty (`monolith-time`, `monolith-time-check`),
  advisory check (`monolith-advisory-check`), the `monolith` help system.
- **Supply chain:** every release ships an ISO, CycloneDX SBOM, SHA256SUMS and a GitHub/Sigstore
  SLSA provenance attestation whose subject is the ISO digest.

What the product does is defined by the oracle (§7), not by prose. A behaviour the README promises
and no test proves is a gap (phase G) until it is tested or the promise is removed.

---

## 2. Principles

These come from what failed in the predecessor. Each is enforced by at least one node.

1. **Storage is an interface.** No workflow, script or page names a storage vendor. Everything goes
   through the `store` contract (§5); backends are swappable and pass one contract suite. (F06, I01, P01)
2. **Every input is pinned and mirrored under our control.** Portage snapshots, base images,
   toolchains, distfiles, tools and actions are pinned by digest or exact version and mirrored in the
   store. A build that would fetch an unpinned or unmirrored input fails. (I02–I05)
3. **The system is inventoried.** `docs/system.yaml` lists every moving part; CI fails on anything
   unlisted. (F03)
4. **Doctrines are executable.** A design rule that has no check is a wish. Every doctrine in §3 maps
   to a check node. (O06, R03, R04, S04)
5. **Success is honest.** A step reports success only for the exact thing it was asked to produce, in
   this run or from a cache entry keyed by the complete input hash. Fallbacks are loud; auth and
   network errors are failures, never misses; missing or empty inputs fail gates. (B01, I01, S03, S04)
6. **Two test tiers.** The fast tier (seconds, no build) carries RED for test-first work. The slow tier
   (build + boot) is GREEN evidence in CI. (F04, O01)
7. **Publish last.** Nothing public moves — no "latest" pointer, no release, no dashboard row — until
   the full oracle and attestation have passed for that exact digest. (P02, P03)
8. **The release path is small, separate and rarely changed.** It is a protected path with elevated
   review. (P02, §8)
9. **Authored and generated are never the same file.** Inputs we write and outputs the build resolves
   live apart; builds never write into tracked files. (R04, B02)
10. **One identity per actor.** One human author identity, one agent bot identity, one trailer format;
    CI rejects others. (F04)

---

## 3. Doctrines

Hard rules about the product. Ids match `docs/study/doctrine.yaml`, which holds sources and history.

| Id | Rule | Enforced by |
|---|---|---|
| D-486-minimalism | Everything runs on an i486 with a few MB of RAM. Additions must justify themselves against that. | review checklist (F05); O02 RAM floors |
| D-all-static | The rootfs is statically linked. **Today untrue**: some binaries are dynamic and the musl loader ships. OD-2 decides how this becomes true. | O06 |
| D-no-dynamic-loading-no-dlopen | No loadable plugins, no perl XS `.so`, no sqlite load-extension, no X modules. | O06 |
| D-no-python-on-target | No Python in the rootfs. Python is a host/builder tool only. | O06 |
| D-bitmap-fonts-no-freetype | No freetype, fontconfig or Xft on the disc. | O06, S01 |
| D-no-readding-removed-things | Deliberately removed packages stay removed (list in doctrine.yaml). | R02 (denylist check) |
| D-clock-origin-1970 | The clock origin sentinel is 1970-01-01. | O04 |
| D-486-tier-regime | Kernel drivers: Tier 0 `=y` boot-critical, Tier 1 `=m` in initrd, Tier 2 `=m` on squashfs. | R04, B02 |
| D-static-musl-cross-all-the-way | i486-linux-musl via crossdev; host build tools are 32-bit-capable. | I03 |
| D-supply-chain-honesty | Releases come only through the verifiable pipeline; the digest chain holds. | S05, P02 |
| D-tag-builds-from-source | Release builds compile every package from source; no cached binary enters a signed release. | P02 |
| D-revbump-on-overlay-change | Changing an ebuild or its files requires `-rN` and a versions.lock bump. | R03 |
| D-hand-authored-rootfs-files-owned | Every rootfs file is owned by a package or a justified allowlist entry. | R05, S04 |
| D-state-and-no-hidden-stderr | No `2>/dev/null` on paths that decide success; every test must mean something. | F01 lint |
| D-two-epoch-pin-model | TOOLCHAIN_EPOCH (builder) and BUILD_EPOCH (runtime tree) are separate pins. | I05 |

`D-s3-publish-only` from the predecessor is superseded by Principle 1 and 7.

---

## 4. Architecture

### 4.1 Pipeline

```text
pins/pins.yaml ─┐
                ├─▶ [I02] snapshot (store: snapshot) ─┐
                ├─▶ [I03] builder image (GHCR by digest)
                └─▶ [I04] distfiles (store: distfile) ─┤
recipes/ ───────────────────────────────────────────────┤
                                                        ▼
            [B01] packages (store: binpkg cache, keyed by tree+profile hash)
                 ├─▶ [B02] kernel + modules ─▶ resolved .config (artifact)
                 │        └─▶ [B03] initrd
                 └─▶ [B04] rootfs ─▶ squashfs
                                   [B05] ISO ◀── initrd + squashfs + kernel
                                     ├─▶ [S01] SBOM ─▶ [S02-S04] gates
                                     └─▶ [O02-O06] oracle (CI, slow tier)
                                                  │  (oracle-gate job)
                                   [S05] provenance + attest ◀── gates + oracle
                                                  │
                              [P02] release ─▶ [P03] dashboard/latest, [P05] advisories
```

Within one CI run, artifacts move between jobs as Actions artifacts only. Never `actions/cache`: cache
entries are immutable per key, so a re-run silently reuses the first attempt's bytes
(T-run-rerun-reuses-cache). The store is for things that outlive a run. The SBOM is taken after
B05 because it records the ISO digest.

### 4.2 Repository layout

| Path | Contents | Owner node |
|---|---|---|
| `SPEC.md`, `docs/graph.yaml`, `nodes/` | Specification, graph, node specs | F02 |
| `docs/system.yaml` | System inventory | F03 |
| `docs/study/` | Frozen study of the predecessor (read-only) | — |
| `docs/decisions/` | Short decision records (`NNNN-title.md`) | any |
| `pins/` | `pins.yaml`, `versions.lock`, `crossdev.lock` | I05, R02 |
| `recipes/overlay/` | Overlay ebuilds and their `files/` | R01 |
| `recipes/portage/` | make.conf, bashrc, env, package.*, profile, savedconfig, world | R01 |
| `recipes/kernel/` | Authored kernel config fragments, tier lists, initrd module list | R04 |
| `image/` | Builder image definition | I03 |
| `factory/` | Build steps (`factory/bin/*`) and the `store` CLI (`factory/bin/store`) | F06, B0x |
| `oracle/` | Boot harness, modes, fixtures, artifact checks | O0x |
| `supplychain/` | SBOM, gates, provenance; policies under `supplychain/policy/` | S0x |
| `web/` | Dashboard and boot demo | P03, P04 |
| `tests/fast/` | Fast-tier tests (one file per subject) | every node |
| `.github/workflows/` | CI | F01, B06, P02, M0x |
| `.claude/` | Agent loop | F05 |
| `tools/` | Host tooling that judges the repo: `tools/graph/` (F02), `tools/system/` (F03), `tools/ci/` (F01, F04) | F0x |
| `factory/mk/`, `factory/data/`, `factory/lib/` | Make fragments included by the root `Makefile`; build data (e.g. `boot/boot-contract.yaml`); shared libraries incl. `factory/lib/store/` backends | B0x, F06 |
| `recipes/IMPORT.yaml`, `recipes/kernel/legacy/` | Import provenance (hashes at `b9f533b`); the predecessor's kernel files, frozen, read-only | R01, R04 |
| `oracle/policy/`, `oracle/golden/`, `oracle/modes.yaml` | Oracle policy (allowlists, expected differences), golden images, mode registry | O0x |
| `web/vendor/` | Vendored, pinned front-end libraries (`VENDOR.lock`) | P03, P04 |
| `docs/status.yaml` | Node status (`done`, `in-progress`) read by `tools/graph --ready` | F02 |
| `.github/CODEOWNERS`, `.github/dependabot.yml` | Owner-review routing; action updates | F04, M04 |

### 4.3 Languages

Factory steps are POSIX `sh` or `bash`. Host-side tools (oracle harness, supply-chain gates,
validators) are Python 3, standard library plus PyYAML only, running on the host or builder — never
on the target (D-no-python-on-target). That rules out `pexpect`: the boot harness carries its own
small expect engine (O01). The dashboard's tests are the one place another runtime may be needed
(OD-14). OD-3 records the alternative language choice.

---

## 5. The store contract

All durable bytes go through `factory/bin/store`. Nothing else may call a storage provider's CLI.

**Classes** (each with its own retention, M03):

| Class | Contents | Key | Retention |
|---|---|---|---|
| `snapshot` | Gentoo portage snapshots + signatures | `gentoo-<epoch>.tar.xz[.gpgsig]` | forever |
| `distfile` | Source tarballs, archived git sources, vendored crates | `sha256/<hex>` (+ `index/sha512/<hex>`, since Manifests carry SHA512) | while referenced by a live tree or any release |
| `binpkg` | Binary package cache | `<tree-hash>/<profile-hash>/<cpv>.gpkg.tar` | not referenced by a live tree and older than 30 d |
| `build` | Per-build outputs worth keeping (ISO, SBOM, attestation files, logs) | `builds/<version>/<file>` and `builds/<version>/attestation/<file>` | tags forever; others 30 d |
| `public` | Anything served to the world (dashboard, ISO for demo, status) | stable path | per P01 |

**Operations:** `put <class> <key> <file>`, `get <class> <key> <dest>`, `has <class> <key>`,
`ls [--long] <class> <prefix>` (`--long` adds size and creation time, for M03),
`url <class> <key>` (public only), `set public <key> <file>` (the only mutable write: allowed only for
keys matching `factory/data/public-mutable.txt`, e.g. `latest.json`, indexes, `status/*`), and
`rm <class> <key> --confirm` (M03 only; refused for `snapshot` and for any key referenced by a release).

**Guarantees every backend must pass (F06 contract suite):**
- `put` is immutable: putting a different body under an existing key fails; the same body is a no-op.
- `get` verifies the stored sha256 and fails on mismatch.
- `has`/`get` distinguish *absent* (exit 3) from *error* (any other non-zero). Auth, network and
  permission errors are errors, never absence.
- No backend writes to stdout except data requested; diagnostics go to stderr, never suppressed.
- Declared exceptions: the `oci` backend cannot make two concurrent `put`s of one key atomic, so the
  contract suite's concurrency case is documented as a known deviation for `oci` (I01); and the builder
  image is pushed to GHCR by `docker push` (I03), the one storage write outside `store`.

**Backends:** `fs` (tests, local dev), `oci` (GHCR via pinned `oras`, I01), `public` (P01, OD-1).

---

## 6. Pins and inputs

`pins/pins.yaml` (I05) is the single source of versions: `TOOLCHAIN_EPOCH`, `BUILD_EPOCH`,
`SOURCE_DATE_EPOCH` derivation, the stage3 tarball (sha256 of the signed autobuild, I03), builder image
digest, crossdev versions (via `crossdev.lock`), rust toolchain, syft, grype, oras, actionlint,
shellcheck, the boot-media tools (grub, syslinux, xorriso, mtools, dosfstools, squashfs-tools), the
CI-host QEMU and OVMF, v86, and `PUBLIC_BASE_URL`. GitHub Action SHAs have exactly one home: the
`uses:` lines of the workflows; I05 checks every one is a full SHA and M04 updates them (node specs that
also list them in `pins.yaml` follow this rule when implemented). Package versions live in
`pins/versions.lock` (R02). A pin bump is a PR (M01, M02, M04). The builder image digest is an output of
building `image/`, so an image change lands as two commits: the change, then the recorded digest.

---

## 7. Oracle and test tiers

- **Fast tier** (`make test-fast`, < 60 s total, no network, no build): unit tests of scripts and
  tools, recipe lints, kernel-fragment assertions, graph/inventory validators, boot-harness tests on
  recorded serial fixtures. Every behaviour change starts with a fast-tier RED where one is possible.
- **Slow tier** (CI): build, the 17 boot modes inherited from the predecessor (bios, uefi, toram,
  ahci, nvme, usb, virtio, nicless, nic, vga, fbdev-modprobe, nat, gui, stele-acid2, clock-epoch,
  clock-1996, persist) plus the modes phase G adds, all registered in `oracle/modes.yaml`, artifact doctrine checks (O06), supply-chain gates (S0x), golden SBOM diff (O07).
- **Equivalence:** "the same product as rc1" means every slow-tier check passes and, against
  `v0.1.0-rc1/bom.cdx.json`, every added or removed package and file is listed with a reason. Version
  movement inside packages present in both is summarised by policy, because a new `BUILD_EPOCH` moves
  most versions (O07).
- Serial milestones, the ISOLINUX `serial` label and GRUB entry `(serial)` are interfaces between the
  harness and the disc; changing them is a breaking change to both (O01, B05).

---

## 8. CI, trust and release

- **Trusted base.** Checks that judge a PR (F04 discipline, F02/F03 validators, release gates) run
  the checker and its rules from the PR's base revision, never from the PR's tree.
- **Owner-review paths** (CODEOWNERS routes them to the owner; the guard hook blocks role agents from
  editing them unless the node being built lists the path under **Owns**; bots may open PRs that touch
  them, and the owner reviews and merges): `SPEC.md`, `docs/graph.yaml`, `AGENTS.md`, `.claude/`,
  `.github/**` (every workflow, CODEOWNERS, dependabot.yml), `tools/ci/`, `tools/graph/`,
  `tools/system/`, `pins/`, `supplychain/policy/`, `oracle/policy/`, `recipes/kernel/tier0-ceiling.txt`.
  A PR that touches a judging file (a workflow, a `tools/` checker, a policy) is judged by the base
  revision's copy (trusted base, above).
- **Merging.** Humans merge. Bots and agents open PRs and post statuses; they never merge, approve,
  or use `--admin`.
- **Release.** A `vX.Y.Z[-rcN|-betaN]` tag triggers the build workflow as the entry point (Sigstore
  binds the certificate to the entry workflow); a separate workflow publishes on `workflow_run`.
  Release builds compile from source. A suffixed tag is a prerelease and never "Latest".
- **Identity.** Commits are authored by `Tucker McLean <me@tuckermclean.com>`, the agent bot (OD-4),
  or `dependabot[bot]` (M04). Co-author trailers use one format. F04 enforces both.
- **Repository.** `tuckermclean/themonolith`. The predecessor `tuckermclean/linux-live-iso-factory` is
  never renamed (rc1's attestation names it); at cutover it gets a pointer commit and is archived (X01).

---

## 9. Node spec template

Every `nodes/<ID>-<name>.md` follows this template exactly (F02 validates the headings).

```markdown
# <ID> — <name>

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| <phase> | <deps or none> | <nodes that depend on this> | <MSn or —> | S / M / L |

**Owns:** <paths in this repo this node creates or is the owner of>
**Carries from linux-live-iso-factory@b9f533b:** <old paths, or "nothing">
**Study refs:** <inventory ids, trap ids T-*, doctrine ids D-*, gaps, contradictions it resolves>

## Purpose
2–4 sentences: what exists after this node that did not before, and why it matters.

## Scope
In: bullet list. Out: bullet list (name the node that owns each excluded thing).

## Design
Interfaces, files, commands, data formats, behaviour. Concrete enough that two implementers would
build compatible things. Decisions taken here, each with the rejected alternative in one line.

## Traps and doctrines preserved
For each relevant T-*/D-*: what goes wrong if forgotten, and which AC prevents it.

## Gate
- **<ID>-AC-1** — <one testable statement>. *Verify:* <command or test file>. *Tier:* fast | slow.
- ...

## RED plan
Which tests the tester writes first, where they live, and why they fail before implementation.

## Risks and open questions
Bullets. Reference SPEC §10 open decisions where relevant.

## Cost
Agent slices (3–8 ACs each), expected CI build cycles, anything that costs money.
```

A node spec may end with an optional `## Spec defects found` section listing defects in SPEC or the
graph that it found; the section is emptied when they are fixed. The **Unlocks** column is derived
from the graph and regenerated by F02. AC ids are `<NODE>-AC-<n>`, numbered from 1, never reused. Sizes: S ≈ one slice, under a day;
M ≈ 2–3 slices; L ≈ 4+ slices or more than three slow CI cycles.

---

## 10. Open decisions

Owner decisions. A node that names one in `decision:` does not start until it is settled.

| Id | Question | Default if unanswered |
|---|---|---|
| OD-1 | Public hosting and domain. `themonolith.org` belongs to a third party (it serves a live site), so it is out. The owner's unused domains are `technomantics.com` and `oracube.com`; `tuckermclean.com` is the personal site and `dcxxiv.com` the infra domain. The URL is baked into every ISO's advisory check, so it must be a dedicated name that can be repointed for decades. Host: Cloudflare R2 (S3-compatible, no egress fees, CORS) or another? | `monolith.technomantics.com` on R2 |
| OD-2 | Static truth: make every rootfs binary static (fix util-linux, iproute2, dhcpcd, procps, tar, gawk), or keep a small dynamic allowlist and change the doctrine? | Allowlist now, each entry with an issue to remove it |
| OD-3 | Factory language: bash + Python stdlib (as predecessor), or Go like strange-company? | bash + Python stdlib |
| OD-4 | Agent bot identity name and account. | `monolith-agent[bot]` |
| OD-5 | Distfiles mirror scope: every distfile (storage cost, GB) or only those upstream may lose (git snapshots, unversioned URLs)? | every distfile |
| OD-6 | Is the AWS account recoverable? If so, rescue `gentoo-20260811.tar.xz` into the snapshot store so rc1 stays reproducible. | treat as lost; first epoch is current |
| OD-7 | Long-term CI: stay on GitHub Actions, or onboard to strange-company (Forgejo/Woodpecker) at its S01? | GitHub Actions; keep layout compatible |
| OD-8 | First release version from this repo. | v0.2.0 |
| OD-9 | Does a CVE in the builder image block a release? (S03 makes the builder scan report-only by default.) | report-only; the owner reviews it at release |
| OD-10 | The `.claude/` loop files adapted from strange-company are AGPL-3.0; this repo is MIT. Relicense your own files in writing, or write the loop clean-room? | relicense in writing (`docs/decisions/`) |
| OD-11 | Bump PRs (M01, M02, M04) need a non-`GITHUB_TOKEN` credential so PR checks run on them: a fine-grained PAT or a GitHub App? | GitHub App |
| OD-12 | Hyper-V: provide manual evidence on real Hyper-V, fund a cloud run, or drop the claim? | CI proxies + dated manual evidence files |
| OD-13 | Keep the undocumented Tier-0 `NET_9P`, `NET_9P_FD`, `NETFS_SUPPORT` symbols? | keep, documented |
| OD-14 | Dashboard tests need a JS runtime: allow Node on the CI host only, or test the SPA through Python-driven fixtures? | Node on the CI host only, pinned |

---

## 11. Conventions

- Branches: `node/<ID>-<name>` for node work, `pins/<what>-<from>-<to>` for bumps.
- Commits: `test(<ID>): …` (RED, carries `TDD-Red-Target: <make target>` as a trailer),
  `feat(<ID>): …`, `fix(<ID>): …`, `docs(<ID>): …`, `chore: …`. One node = one PR, squash-merged.
- Further trailers (F04): `TDD-Slow-Only: <reason>` for a change whose only meaningful test is slow-tier,
  `TDD-Test-Correction: <AC id>` for an owner-approved fix to a RED test.
- Every PR body has the criterion → test → result table and the CI run links.
- Phases other than F start only after MS1 (the loop is online); `tools/graph --ready` enforces it.
