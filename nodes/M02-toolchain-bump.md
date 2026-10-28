# M02 — toolchain-bump

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| M | M01, I02, I03 | none | — | L |

**Owns:** `.github/workflows/toolchain-bump.yml`, `factory/bin/crossdev-lock-regen`, `factory/bin/pin-check` subcommand `toolchain` (file owned by M01; this node adds the subcommand), `factory/bin/pin-apply` subcommand `toolchain`, `docs/toolchain-bump.md`, `tests/fast/crossdev-lock-regen.test.sh`, `tests/fast/toolchain-bump-workflow.test.sh`, `tests/fast/toolchain-pin-apply.test.sh`, `tests/fast/toolchain-bump-fixtures/`.
**Carries from linux-live-iso-factory@b9f533b:** `.github/workflows/toolchain-bump.yml` (human-dispatch shape, label/PR body ideas), `.github/workflows/regen-pins.yml:56-107` (the stage3 `portageq best_visible` query with `*/* ~*` keywords and the musl/gcc/binutils lock writer), `scripts/update-build-pins.sh:176-250` (`query_portage_version`, `update_crossdev_lock` empty guard), `docs/version-pinning.md` (two-pin model). The rest of `regen-pins.yml` (branch-push trigger, S3 step) is dropped.
**Study refs:** workflows.yaml `wf.toolchain-bump`, `wf.regen-pins` (dormant, S3 step fails), `job.toolchain-bump.bump-and-validate`; doctrine.yaml D-two-epoch-pin-model, T-crossdev-query-empty, T-live-ebuild-and-host-keyword-skew, T-libatomic-static, T-builder-image-tag-not-pushed, T-resolved-kernel-config-vacuous, T-portage-snapshot-fetch, design_history "Decouple portage epoch" (open: toolchain tree and stage3 not self-hosted, no scheduled cadence); `configs/portage/crossdev.lock` header (generated from `20260727` while `TOOLCHAIN_EPOCH` is `20260810`: the one-cycle lag).

## Purpose
After this node a human can dispatch one workflow that moves `TOOLCHAIN_EPOCH`, re-derives `crossdev.lock` from the new inputs, rebuilds the builder image from mirrored inputs, and opens a PR whose checks include a full from-source build and the full oracle. A toolchain bump changes the compiler and libc of every package, so it is never scheduled and never merged by automation.

## Scope
In:
- Dispatch-only workflow; target discovery for stage3 and toolchain snapshot; mirroring of the new inputs; `crossdev.lock` derivation from the new stage3 plus snapshot (no lag); builder image rebuild and push by digest; PR with a builder/toolchain delta report.
- A "from source, no cache" validation requirement, enforced by what the PR's checks run.
Out:
- Builder image Dockerfile, host tool pins, image scan: I03 (this node calls its build entry point).
- Snapshot fetch, verification, store: I02, I01. Stage3 mirroring into the store or GHCR: I03.
- The routine `BUILD_EPOCH` path, PR helper conventions, token: M01.
- The PR build workflow and oracle jobs: B06, O02-O05.
- Staleness reporting for toolchain age: M04's pin-age report.

## Design

### Trigger
`workflow_dispatch` only, input `target_epoch` (`YYYYMMDD`, optional). No `schedule`. Rejected: a scheduled bump; each run costs an image build (50-100 minutes per the predecessor's comments in `toolchain-bump.yml`) plus a cold build and the full oracle, and the result is consequential. Concurrency group `toolchain-bump`, no cancel. Token and bot identity as M01 (`BUMP_TOKEN`).

### Inputs and derivation
`pin-check toolchain [--target D]` finds the newest date that has all three upstream inputs: a published stage3 `stage3-amd64-openrc-D*.tar.xz` on Gentoo autobuilds (via `latest-stage3-amd64-openrc.txt`, a clearsigned file verified against `gentoo_key.release`), a Gentoo snapshot `gentoo-D.tar.xz` and its `.gpgsig` (I02's `snapshot latest` rule). Missing any of them: exit 0 `action=noop` on HTTP 404, exit 1 on any other error, as in M01. A stage3 is a tarball in this design (I03 rejected `FROM gentoo/stage3` by digest), so the pin is the tarball sha256 in `base_image.stage3`, not a registry digest.

Ingest is I03's and I02's: `factory/bin/snapshot seed D` (snapshot into the store), `factory/bin/builder-inputs stage3` (download, verify signature and sha256, put under `sha256/<hex>` in class `distfile`). M02 calls them and reads back the digests they print.

`pin-apply toolchain NEW` is a scope-checking wrapper over I05's `pin set`. It sets `epochs.toolchain`, `base_image.stage3.{name,sha256,epoch}` and adds `snapshots.NEW`; it exits 1 if `pin diff` shows any other key changed (in particular `epochs.build`), if NEW is malformed or not newer, or a key is missing. `builder_image.{digest,inputs_hash}` are written by a second call, `pin-apply toolchain-image DIGEST INPUTS_HASH`, after the image build. Rejected: one combined write before the build, which would leave a PR with a digest of an image that never existed.

### `crossdev-lock-regen`
`factory/bin/crossdev-lock-regen --epoch E --out pins/crossdev.lock` runs in a throwaway container of a stage3-only image built from the new `base_image.stage3` tarball (not the builder image: it ships no tree and would lag) and calls `snapshot webrsync E <dir>` (I02: loopback HTTP, no Gentoo mirror), writes `*/* ~*` into `package.accept_keywords/zz-regen` so live `9999` ebuilds are excluded (T-live-ebuild-and-host-keyword-skew, the gcc-15.3.9999 incident), and queries `portageq best_visible / sys-libs/musl`, `=sys-devel/gcc-<major>*` (major from the current lock), and `sys-devel/binutils`.
- An empty or non-version answer for any of the three exits 1. The predecessor printed a warning and left the lock unchanged (`update-build-pins.sh:131-136`, T-crossdev-query-empty).
- The output header carries `# toolchain-epoch: <E>` (the line I05's `check-pins` requires), `# stage3-sha256: <hex>`, `# snapshot-sha256: <hex>` and the `*/* ~*` keyword rule, and no timestamp, so equal inputs give equal bytes.
- No `2>/dev/null` around `docker run` or `portageq`; stderr goes to the job log.
Rejected: querying the pre-bump builder image (the predecessor's `update_crossdev_lock`), which is why `crossdev.lock` lagged one epoch behind the pin it claims to serve.

### Image rebuild
After the lock regeneration, the job runs `factory/bin/builder-image build` and `push` (I03). `push` publishes `<TOOLCHAIN_EPOCH>-<hash12>` on every invocation and writes `build/builder.digest`; `pin-apply toolchain-image` records the digest and `builder-image hash` in the ledger. Consumers pull by digest (T-builder-image-tag-not-pushed). If the build or push fails, no digest is written. `builder-image check-pin` (I03-AC-13) must then pass on the result.

The libatomic fix (T-libatomic-static) and other I03 workarounds are I03's; its in-image checks (`image/checks/`) run in the build and a failure fails this job.

### Pull request
Branch `pins/toolchain-OLD-NEW`. The commit changes `pins/pins.yaml`, `pins/crossdev.lock`, and nothing else. If `versions.lock` has entries tied to the toolchain (binutils is a world atom), the job runs R02's regeneration with the new builder and includes the result.

PR body: old and new `TOOLCHAIN_EPOCH`; stage3 tarball sha256; snapshot sha256; `crossdev.lock` diff (musl, gcc, binutils, linux-headers if present); old and new builder image digest; link to the S03 builder-image scan result for the new digest when it exists; a bold statement that this PR rebuilds every package. Labels `toolchain-bump`. The PR is opened normal, not draft, if the image built; draft with `needs-fixup` otherwise (same rule as M01).

### Validation: from source, full oracle
The PR's checks must, for a branch named `pins/toolchain-*`, run B06's build with the binpkg cache bypassed and the complete oracle (every mode of O02-O05 and O06). This is B06's and O02's trigger rule; M02 asserts it (M02-AC-8) and does not implement it. Rationale: a cached binpkg built by the old compiler would let a toolchain bump pass without exercising the new one. B01-AC-3 already puts the builder digest into the binpkg `profile` hash, so a new builder cannot hit old entries even without the bypass; the bypass is the explicit second guard.

The report job of M01 (`pin-bump-report.yml`) is generalised to also handle head branches starting `pins/toolchain-` and requires the full job list rather than the core list; M02 owns that change (it edits M01's file, in the same PR as the first toolchain-bump use).

### Time budget
Two separate jobs, never one: `rebuild-image` (timeout 180 minutes) and the PR checks (separate runs). The predecessor put image build and a 240-minute wait in one job with a 355-minute timeout; one slow run would hit the 360-minute hosted cap.

## Traps and doctrines preserved
- **D-two-epoch-pin-model:** a toolchain bump changes toolchain pins only. Prevented by M02-AC-2 (key scope) and M02-AC-9 (BUILD_EPOCH unchanged).
- **T-crossdev-query-empty:** empty query silently kept stale pins. Prevented by M02-AC-3.
- **One-cycle lag:** lock derived from the old image. Prevented by M02-AC-4 (lock header equals the pins it was derived from).
- **T-live-ebuild-and-host-keyword-skew:** `9999` ebuilds chosen. Prevented by M02-AC-5.
- **T-builder-image-tag-not-pushed:** consumers pull by digest; digest recorded only after push and `check-pin`. Prevented by M02-AC-6.
- **T-libatomic-static / T-resolved-kernel-config-vacuous:** a new gcc can drop a fix or change the resolved kernel config. Prevented by M02-AC-8 (full oracle, including O06 and the resolved-config checks of B02, runs on the PR).
- **Mirrored inputs (SPEC §2.2):** the build reads the snapshot from the store. Prevented by M02-AC-7.
- **SPEC §8 Humans merge:** M01-AC-1's grep covers this workflow; M02-AC-10 asserts it names `toolchain-bump.yml`.

## Gate
- **M02-AC-1** — `toolchain-bump.yml` triggers on `workflow_dispatch` only and no workflow file merges, approves or enables auto-merge for it. *Verify:* `tests/fast/toolchain-bump-workflow.test.sh` (trigger keys) and M01's no-merge grep. *Tier:* fast.
- **M02-AC-2** — `pin-apply toolchain` changes only `epochs.toolchain`, `base_image.stage3.*` and the new `snapshots` entry, reads them back with `pin get`, and exits 1 on any other key differing per `pin diff` (notably `epochs.build`), a missing key, a non-increasing or malformed epoch. *Verify:* `tests/fast/toolchain-pin-apply.test.sh` on a fixture `pins.yaml` (I05 schema 1). *Tier:* fast.
- **M02-AC-3** — `crossdev-lock-regen` exits 1 and leaves the output file untouched when `portageq` returns empty or a non-version string for musl, gcc or binutils. *Verify:* `tests/fast/crossdev-lock-regen.test.sh` with a stub `docker`/`portageq` returning empty, garbage and a valid answer. *Tier:* fast.
- **M02-AC-4** — The generated `pins/crossdev.lock` header carries `# toolchain-epoch:` equal to `epochs.toolchain` and `# stage3-sha256:` equal to `base_image.stage3.sha256`, contains no date or time of generation, and two runs with equal stub output are byte-identical. *Verify:* `tests/fast/crossdev-lock-regen.test.sh` (header equality, double run `cmp`) and I05's `check-pins` on the result. *Tier:* fast.
- **M02-AC-5** — The keyword file written for the query is exactly `*/* ~*` and the stub query run never receives `**` keywords; a fixture where the best visible answer is a `9999` ebuild fails the tool. *Verify:* `tests/fast/crossdev-lock-regen.test.sh`. *Tier:* fast.
- **M02-AC-6** — The image-rebuild job writes `builder_image.digest` and `builder_image.inputs_hash` to `pins/pins.yaml` only after `builder-image push` succeeded and `builder-image check-pin` passes, and the job fails (no ready PR) when the push, the digest read-back or the check fails. *Verify:* `tests/fast/toolchain-bump-workflow.test.sh` (stubbed `docker`/`oras` failure injection) and the slow check in M02-AC-11. *Tier:* fast + slow.
- **M02-AC-7** — Neither job reads package data from Gentoo mirrors: the snapshot comes from the store through `snapshot webrsync`, and the workflow contains no bare `emerge-webrsync`; `distfiles.gentoo.org` appears only in `pin-check` and the ingest tools. *Verify:* `tests/fast/toolchain-bump-workflow.test.sh` (grep set). *Tier:* fast.
- **M02-AC-8** — For a branch named `pins/toolchain-*`, the PR checks run the build with the binpkg cache bypassed and every oracle mode (O02-O05) plus O06, and the report job requires all of them before it applies `validated`. *Verify:* `tests/fast/toolchain-bump-workflow.test.sh` parses B06's `build.yml` `if:` conditions and the report job's required-job list from `oracle/modes.yaml`. *Tier:* fast.
- **M02-AC-9** — A toolchain bump leaves `BUILD_EPOCH` and `versions.lock` package versions (other than ones R02 attributes to the toolchain) unchanged: the PR diff touches only `pins/pins.yaml`, `pins/crossdev.lock` and, when needed, regenerated lock lines for toolchain-tied atoms. *Verify:* `tests/fast/toolchain-pin-apply.test.sh` (diff scope) and the report job's file-scope check. *Tier:* fast.
- **M02-AC-10** — Failure at any stage (stage3 resolve, mirror, lock regen, image build, push) opens a draft PR labelled `needs-fixup` or exits non-zero with no PR when nothing was produced, and never opens a ready PR with an empty or stale digest. *Verify:* `tests/fast/toolchain-bump-workflow.test.sh` with failure injection per stage. *Tier:* fast.
- **M02-AC-11** — One real dispatch produces a PR whose builder image digest resolves in the registry, whose rebuilt image passes I03's smoke checks, and whose from-source build and full oracle checks ran and passed or are linked with their failures. *Verify:* CI job `toolchain-bump-e2e` (dispatch only, once at node acceptance, result recorded in the PR table; PR left unmerged). *Tier:* slow.
- **M02-AC-12** — `docs/toolchain-bump.md` states that bumps are manual, lists the expected cost, and describes the fixup loop (push to the PR branch; checks re-run). *Verify:* `tests/fast/toolchain-bump-workflow.test.sh` greps the three statements. *Tier:* fast.

## RED plan
`toolchain-bump-workflow.test.sh` first (workflow absent; includes failure-injection harness and the dispatch-only assertion), then `crossdev-lock-regen.test.sh` (tool absent; empty-output and header cases), then `toolchain-pin-apply.test.sh` and `pins-consistency.test.sh`. All fixtures committed with the RED commits.

## Risks and open questions
- Hardest: the builder image is not bit-reproducible, so each rebuild yields a new digest even for equal inputs; the digest in the PR is whatever the single build produced. The PR must be merged with that digest or the build repeated. Accept: digest is evidence, not an input hash.
- Stage3 comes from Gentoo autobuilds at bump time; I03's `builder-inputs stage3` verifies signature and sha256, and M02 fails if the ingest tool does.
- A toolchain bump can break `emerge` for reasons unrelated to the toolchain (new ebuild versions, T-glib-docutils-eigen-live). The fixup loop is human work; the PR cannot be auto-fixed.
- `crossdev.lock` today holds musl and gcc only (`crossdev.lock:8-9`); binutils and kernel headers come from `versions.lock` (I03 `crossdev` call). M02 therefore writes musl and gcc into the lock and leaves binutils to R02's regeneration, which M02 triggers.
- Cost of the full oracle on every toolchain bump is intentional; if the owner wants a cheaper path, relax M02-AC-8 explicitly.

## Cost
Four agent slices: (1) `pin-check toolchain`, `pin-apply toolchain`, tests; (2) `crossdev-lock-regen` and tests; (3) workflow and failure-injection tests; (4) docs plus generalising M01's report job. CI: the one real dispatch at acceptance is an image build (about 1-2 hours) plus a cold from-source build (30-60 minutes) plus the full oracle: roughly three to four hours of runner time, three CI cycles counting one fixup. Each later bump costs the same. Store: one new stage3 digest (if mirrored) and one builder image per bump, kept forever when referenced by a tag (M03).

## Spec defects found
- graph.yaml: M02 lacks I02 (snapshot mirror) and I05 (pins schema, `pin set`, `check-pins`) as direct deps; I02 arrives through I03, I05 not at all.
- SPEC §6 and the M02 summary say "stage3 digest" and "builder-image rebuild from mirrored inputs"; I03 and I05 made the stage3 a signed tarball with a sha256 (`base_image.stage3.sha256`), not an image digest. SPEC §6 wording should follow.
- The predecessor's `crossdev.lock` header claimed "regenerated ... from gentoo/stage3:amd64-openrc-20260727" while `TOOLCHAIN_EPOCH` was `20260810` (the one-cycle lag); I05's `check-pins` now owns the header equality, this node supplies the tool that makes it true.
- I03 says `portageq` queries need a tree and "tools that query (M02 lock regeneration) call `snapshot webrsync` first"; that is implemented here, but nothing in graph.yaml connects M02 to I02 explicitly.
