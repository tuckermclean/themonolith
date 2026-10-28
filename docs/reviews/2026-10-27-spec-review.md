# Spec review — 2026-10-27

The 50 node specs were drafted by eight parallel agents (Claude Sonnet), one per phase, from SPEC.md
v0.1, `docs/graph.yaml` and the study in `docs/study/`. This record says what the review changed, what
is still open, and how far to trust the drafts.

## How far to trust the drafts

- Claims about the predecessor cite `linux-live-iso-factory@b9f533b` `path:line`. The reviewer
  re-checked the load-bearing ones (dynamic loader shipped, `--keep-going` false success, unowned-gate
  skip, waiver expiry ignored, latest pointers published before boot tests, `pin-bump --admin`, kernel
  config/toolchain mismatch, advisory URL on the disc). The rest are cited but unchecked.
- Claims about third-party tools (kbuild `KBUILD_*` handling, busybox applet table layout, GHCR
  semantics, `actions/attest` input names, QEMU `guestfwd`, stage3 tarball vs Docker image equivalence)
  are written from memory and marked unverified in each spec. The first implementation slice of each
  node must verify them before relying on them.
- Size: the specs are heavier than "light". There are 646 acceptance criteria across 50 nodes (10–18
  each), 32 sized M and 18 sized L, and none S. Treat the AC lists as the complete scope; the
  implementation loop slices each node into 3–8 criteria at a time.

## Changes made in review

**Graph (`docs/graph.yaml`)** — 112 edges, acyclic, checked mechanically.
- B01, B06, S01, S03, O07, M01, M04 now depend on I05 (pins); M02 on I02; M04 on M01.
- B04 and B05 depend on B02 (they consume the kernel); B03 and B05 on O01 (the boot interfaces).
- S01 depends on B05 (the SBOM records the ISO digest) and on R02.
- S05 depends on O02–O06, so nothing is attested before the oracle passes (Principle 7).
- O03 depends on R04; O06 on S01.
- X01 depends on G01–G05, so cutover cannot happen with untested README promises.
- `decision:` became `decisions:` (a list); F04, F05, I04, O06, S03, M01, G03, R04, P01, P03 carry theirs.
- Summaries now place three unowned items: crate vendoring (I04), the `package.provided` drift check and
  removed-packages denylist (R02), size gates (B05); and B06 hosts the `oracle-gate` and `evidence` jobs.

**SPEC.md (v0.2)**
- §4.1: artifacts move between jobs as Actions artifacts only, never `actions/cache`
  (T-run-rerun-reuses-cache); SBOM after the ISO; diagram shows the oracle gating attestation.
- §4.2: added `tools/`, `factory/{mk,data,lib}`, `recipes/IMPORT.yaml`, `recipes/kernel/legacy/`,
  `oracle/{policy,golden,modes.yaml}`, `web/vendor/`, `docs/status.yaml`, CODEOWNERS, dependabot.yml.
- §4.3: no `pexpect` (the harness carries a stdlib expect engine); JS runtime for dashboard tests is OD-14.
- §5: store gains `ls --long`, `set public` (mutable keys from an explicit list), `rm --confirm`
  (refused for snapshots and release inputs); declared exceptions for OCI concurrent puts and the
  builder-image `docker push`; distfile sha512 index; attestation subpaths; precise retention.
- §6: boot-media tools, CI QEMU/OVMF and `PUBLIC_BASE_URL` pinned; stage3 pinned as a signed tarball;
  GitHub Action SHAs have one home, the workflow `uses:` lines; the image-digest two-commit rule.
- §7: modes registry includes phase-G modes; SBOM equivalence summarises version movement by policy.
- §8: "protected paths" became owner-review paths routed by CODEOWNERS, covering every workflow and
  judging tool; a node may edit an owner-review path it lists under Owns, with owner review. This
  resolves the conflicts where R05 must shrink the unowned allowlist and the bump bots must edit pins.
  `dependabot[bot]` joins the identity allowlist; the repository slug is fixed.
- §9: optional `## Spec defects found` section; Unlocks is derived.
- §10: OD-1 updated (`themonolith.org` belongs to a third party; default `monolith.technomantics.com`);
  new OD-9 to OD-14.
- §11: `TDD-Slow-Only` and `TDD-Test-Correction` trailers; non-F phases start after MS1.

**Node specs**
- B02 rewritten to consume R04's `kconfig-check merge`/`resolved`, `#@ derived-ok` annotations and the
  `MONOLITH_KERNEL_CONFIG` ebuild variable, instead of its own merger, drift tool and waiver file.
- O01-AC-13 accepts G-node modes in `oracle/modes.yaml`.
- F02's graph schema uses `decisions` (list).
- Every node's Deps/Unlocks header regenerated from the graph.
- P01, P05, X01: `themonolith.org` replaced by the OD-1 default.

The `## Spec defects found` sections in the node files are kept as the drafting record for this first
PR. Items fixed above are fixed; F02's first run clears the sections.

## Still open (not fixed in review)

- I05 and M04 drafts list Action SHAs in `pins.yaml`; SPEC §6 now says workflow `uses:` lines are the
  only home. Align the two specs when they are implemented.
- S04's allowlist schema must accept R05's extension keys (`kind`, `reducible_by`, `refs`).
- F04: a PR can edit its own `pull_request` workflow file. Trusted-base protection depends on
  CODEOWNERS plus branch-protection settings that the repo cannot prove were applied; the owner must
  configure and document them.
- If OD-2 chooses "make every rootfs binary static", no node owns that work yet; add one.
- Modified-after-install files (CONTENTS md5) are not checked by any node (raised by S04).
- The disc's curl/TLS/CA path for the advisory fetch is only covered by a non-gating check (P05).
- M03 needs I01 to define how a store key maps to a GHCR package version before `rm` is safe on `oci`.
- Many first-run unknowns: TCG boot runtimes, distfiles volume (OD-5), reproducibility of kernel, GRUB
  and xorriso output, golden screendumps. Each is named in its node's Risks section.
