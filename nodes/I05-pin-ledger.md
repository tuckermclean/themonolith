# I05 — pin-ledger

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| I | F03, I03 | B01, B06, M01, M02, M04, O07, P06, S01, S03 | — (feeds MS1) | M |

**Owns:** `pins/pins.yaml` (schema and checks; sections seeded by I01, I02 and I03), `pins/pins.schema.json` (JSON Schema, validated with stdlib plus PyYAML code, not a third-party validator), `pins/crossdev.lock`, `pins/fetch-allow.yaml`, `pins/keys/` (shared with I02), `tests/fast/fixtures/expected-pin-keys.txt`, `factory/bin/pin` (`get`, `set`, `list`, `sde`, `diff`), `factory/bin/check-pins`, `factory/bin/check-fetches`, `tests/fast/pins-*.test.sh`, `tests/fast/fetches-*.test.sh`, `tests/fast/fixtures/unpinned/` (verbatim offenders from the predecessor), `tests/fast/fixtures/workflows/`.
**Carries from linux-live-iso-factory@b9f533b:** `configs/portage/crossdev.lock` (ported to `pins/crossdev.lock`; only a machine-readable header line is added, the two version lines are byte-identical: they are what the adopted rc1 builder was built with), the `ARG TOOLCHAIN_EPOCH`/`ARG BUILD_EPOCH`/`ENV SOURCE_DATE_EPOCH` triple (`Dockerfile:28-29,37`) as the concept; `scripts/update-build-pins.sh` is NOT carried (bump automation is M01, M02). `configs/portage/versions.lock` goes to R02.
**Study refs:** D-two-epoch-pin-model, D-static-musl-cross-all-the-way, T-pin-bump-false-green, T-builder-image-tag-not-pushed, Principle 2, SPEC §6, workflows.yaml `pins_summary` (actions, tools_fetched_at_runtime), build.yaml `pins` and `contradictions` (GRUB "pinned to 2.12"; `crossdev.lock` header lags `TOOLCHAIN_EPOCH`), supplychain.yaml (v86, jsDelivr and Google Fonts unpinned), recipes.yaml (RUST_NIGHTLY shared by rl144 and stele).

## Purpose
After this node there is one file, `pins/pins.yaml`, that holds every version, digest, epoch, commit and checksum the project depends on (GitHub Action SHAs excepted: their one home is the workflow `uses:` lines, SPEC §6), plus two checks that keep it honest: CI fails when a build or workflow fetches something the ledger does not pin, and when the ledger pins something nothing uses. In the predecessor, pins were scattered across a Dockerfile, a Makefile, workflow files and comments, several were wrong (GRUB), and about half of the tool installs followed `main` or a floating tag.

## Scope
In:
- The ledger format, reader/writer CLI, schema check, consumer (unused-pin) check.
- The unpinned-fetch scanner, its allowlist and its fixtures.
- Consistency assertions across pins (rust nightly vs ebuilds, `crossdev.lock` vs toolchain epoch, snapshot hashes, SDE derivation).
- Seeding the ledger with every pin that exists today and the pins that must be added.

Out:
- Choosing new values and the store/ingest of what they point at: I02 (tree), I03 (adopted image, runner tools), M02 (stage3, in-image tools, rust), I04 (distfiles).
- `versions.lock` content and generation: R02. Kernel fragments: R04.
- Bump automation (BUILD_EPOCH, TOOLCHAIN_EPOCH, tools): M01, M02, M04 (M04 also updates the `uses:` SHAs). This node provides `pin set` and `pin diff` for them.
- The grype DB version and the CVE policy: S03.
- Vendoring the v86 and web libraries: P03, P04 (their pins are listed here as reserved).
- Who may edit `pins/pins.yaml`: SPEC §8 (protected path).

## Design
**Format (`pins/pins.yaml`, schema 1).** YAML, two-space indent, keys in the fixed order below, no timestamps, no comments that carry data. `pin set` rewrites the file deterministically (round trip is byte-identical).

```yaml
schema: 1
epochs:
  toolchain: "YYYYMMDD"            # TOOLCHAIN_EPOCH: the date of the stage3 and tree the builder came from
  build: "YYYYMMDD"                # BUILD_EPOCH: names the runtime tree pin; SOURCE_DATE_EPOCH is derived, never stored
tree:                              # the runtime tree pin (I02); first value is rc1's tree
  commit: <40hex>                  # gentoo-mirror/gentoo commit
  sha256: <64hex>                  # of the compressed archive in the store (snapshot class)
  tar_sha256: <64hex>              # of the uncompressed tar
  signature: signed-commit | signed-manifest | unsigned-hash-pinned
gentoo_key:
  repo:     {fingerprint: <40hex>, file: pins/keys/gentoo-repo.asc}       # commit or Manifest signatures (I02); absent when signature is unsigned-hash-pinned
  snapshot: {fingerprint: <40hex>, file: pins/keys/gentoo-snapshot.asc}   # daily snapshots, later (I02)
  release:  {fingerprint: <40hex>, file: pins/keys/gentoo-release.asc}    # stage3 signing, M02
toolchain_tree:                    # reserved for M02: the tree the builder was built from (a commit, same shape as tree)
  commit: <40hex>
  sha256: <64hex>
base_image:                        # reserved for M02
  stage3: {image: gentoo/stage3, tag: amd64-openrc-20260810, digest: sha256:<64hex>}   # first rebuild; later epochs: {name, sha256, epoch} of the signed tarball
builder_image:                     # adopted rc1 image (I03); M02 replaces it
  repo: ghcr.io/tuckermclean/themonolith/builder
  digest: sha256:<64hex>
tools:                             # every downloaded binary: version, url template, sha256 per arch
  oras|syft|grype|actionlint|shellcheck|<...>:
    version: <exact>
    url: <template>
    sha256: {linux_amd64: <64hex>}
  rustup-init: {status: reserved, owner: M02}
rust: {nightly: nightly-YYYY-MM-DD, components: [rust-src], dist_sha256: reserved for M02}
python: {pyyaml: <exact>, check-jsonschema: <exact>, pexpect: <exact>}
asserted:                          # versions of packages inside the builder, asserted from I03's inventory JSON
  grub: <version>
  syslinux: <version>
  xorriso: <version>
  squashfs-tools: <version>
runners: {ubuntu: ubuntu-24.04}
store:
  oci:
    prefix: <registry path prefix>
    adopted:                       # rc1 objects read by digest (I01)
      builder: {repo: ghcr.io/tuckermclean/themonolith/builder, digest: sha256:<64hex>}
      binpkg-seed: {repo: ghcr.io/tuckermclean/themonolith/binpkg-seed, digest: sha256:<64hex>}
  registry_test_image: <repo>@sha256:<64hex>
web: {v86: {version: <exact>, sha256: {…}}, fonts: reserved}
floating:                          # allowed unpinned inputs, each with reason and owner node
  apt: {packages: [qemu-system-x86, ovmf, squashfs-tools, kmod], reason: <text>, owner: <node>}
files: {crossdev: pins/crossdev.lock, versions: pins/versions.lock}
```
`SOURCE_DATE_EPOCH = date -u -d "<epochs.build>" +%s`, computed by `pin sde`. Predecessor check value: 20260811 gives 1786406400 (`Dockerfile:37`).
**Why no `actions:` section.** v0.2 listed every Action `owner/repo`, SHA and version here. The workflow `uses: owner/repo@<40hex> # vX.Y.Z` line already carries all three, so the ledger copy was a second source of truth that dependabot (M04) would have to keep in step. SPEC §6 gives the `uses:` lines sole ownership; this node only checks them (AC-6, AC-10). Rejected: a generated mirror of the `uses:` lines in `pins.yaml`.
**Builder image.** The first `builder_image.digest` is the adopted rc1 image, a value given in Step 0, not a build output; `inputs_hash` is gone because rc1's image has no such label. M02 adds `inputs_hash` and the two-commit flow when it rebuilds.
Rejected: storing `SOURCE_DATE_EPOCH` as a key; it was a second source of truth that `update-build-pins.sh` had to keep in step by `sed`.
Rejected: separate pin files per area (the predecessor's state). One file is greppable and one review surface.

**CLI.** `pin get <dotted.path>` prints the scalar (exit 3 when absent, 2 on a non-scalar); `pin list` prints leaf paths; `pin set <path> <value>` validates the new value against the schema before writing; `pin sde`; `pin diff <base-ref> <head-ref>` prints a table for PR summaries (used by M01, M02, M04). Python 3 stdlib plus PyYAML (SPEC §4.3), host-side only.

**Consumers.** A pin is "used" when its dotted path appears in a repo file other than `pins/` and `docs/` as `pin get <path>`, or in a `# pin: <path>` annotation on the consuming line. A leaf may be marked `status: reserved, owner: <node>` while its consumer is not built yet; reserved pins expire when that node's PR merges (the check fails if the owner node's spec says it is done: the node list is in `docs/graph.yaml` plus a `done` file maintained by F02 tooling; unknown until F02, so the first implementation can only warn).

**Unpinned-fetch scanner (`check-fetches`).** Scans `.github/**`, `image/**`, `factory/**`, `Makefile`, `supplychain/**`, `oracle/**`, `web/**` (text only). Flags:
- `uses:` not followed by a 40-hex SHA and a trailing `# vX.Y.Z` comment (the SHA and comment are the pin; nothing in `pins.yaml` is compared);
- `curl`/`wget` piped to a shell; any `raw.githubusercontent.com/.../main/`;
- `pip install` without `==`; `apt-get install`/`apt install` of packages not in `floating.apt`;
- `FROM` or `image:` or `docker pull` without `@sha256:`; `runs-on: *-latest`;
- `npm`, `cargo install`, `go install`, `gem` without exact versions;
- `cdn.jsdelivr.net` or `fonts.googleapis.com` URLs in `web/` (until P03/P04 vendor them).
The verbatim predecessor `image/Dockerfile` and `image/legacy/` (I03) contain several of these idioms (`curl … | sh` at `Dockerfile:131,168`, a tag-only `FROM`). They are allowlisted as `floating`-style entries with `owner: M02` and `reason: imported verbatim, rewritten by M02-AC-14`; the allowlist entry is removed when M02 rewrites the file, and the check fails if the owner node is done and the entry remains (the same rule as reserved pins). Each hit must be in `pins/fetch-allow.yaml` with `file`, `pattern`, `reason` and either `pin: <path>` or `floating: <key>`; an allowlist entry that matches nothing fails the check. This is text-level and heuristic; the runtime backstops are I04's offline mode and I03's `--network=none` build steps. Rejected: a network-egress sandbox for CI; it cannot see `uses:` and is not testable in the fast tier.

**Cross-checks (`check-pins`).**
- Schema: types, 64-hex and 40-hex lengths, real dates, `epochs.*` not in the future, and `tree.signature` present (so an unsigned tree pin is always a visible, reviewed value).
- `epochs.toolchain` and `epochs.build` are independent keys; the builder inputs list (`image/hash-inputs.txt`, M02) must not contain `epochs.build` or `tree.*`.
- `tree.commit` is 40 hex; with `--store`, `store has snapshot gentoo-<commit>.tar.xz` succeeds and its sha256 equals `tree.sha256`.
- `pins/crossdev.lock` has the header `# toolchain-epoch: <E>` and `<E> == epochs.toolchain`. This resolves the predecessor's lag (lock header said 20260727 while the epoch was 20260810, `crossdev.lock:3-4`, documented as "one cycle behind" at `update-build-pins.sh:196-198`). The imported lock keeps its two version lines unchanged (they are what the adopted image was built with) and gains `# toolchain-epoch: 20260810` plus a comment saying so; M02's regeneration (no lag) makes the header literally true.
- `rust.nightly` equals every `RUST_NIGHTLY=` in `recipes/overlay/**/*.ebuild` (rl144 and stele; predecessor value `nightly-2026-07-15`).
- `asserted.*` equals the versions in the builder inventory JSON (I03 `inventory`) when `--inventory` is given. This replaces the unfounded claim "GRUB 2.12" in `build-iso.sh:264-267,503` with a check.
- `builder_image.digest` resolves (`--registry`) and equals `store.oci.adopted.builder.digest` while the adopted image is in use; from M02 on it also carries label `org.themonolith.inputs-hash` equal to `builder_image.inputs_hash`.

**Every pin that exists today (predecessor), and what becomes of it.**
| Pin | Predecessor value and evidence | Ledger key |
|---|---|---|
| TOOLCHAIN_EPOCH | 20260810 (`Dockerfile:28`), stage3 by TAG | `epochs.toolchain` + `base_image.stage3.sha256` |
| BUILD_EPOCH | 20260811 (`Dockerfile:29`); the tarball is gone, the tree is a gentoo-mirror commit | `epochs.build`, `tree.*` (I02) |
| SOURCE_DATE_EPOCH | 1786406400 hard-coded (`Dockerfile:37`) | derived by `pin sde` |
| crossdev.lock | musl 1.2.6, gcc 15.3.1_p20260717 (`crossdev.lock:8-9`) | `files.crossdev` |
| crossdev flags | binutils and headers from versions.lock (`Makefile:36-40`) | R02, read by I03 |
| versions.lock | 109 lines, lacks several world atoms (recipes.yaml coverage_gap) | `files.versions` (R02) |
| rust nightly | `nightly-2026-07-15` (`Dockerfile:167-170`, ebuilds) | `rust.nightly` |
| snapshot signing key | `DCD05B71…BF6D`, comment only (`Dockerfile:68-69`); daily snapshots only | `gentoo_key.snapshot` (later); repository key `gentoo_key.repo` is new (I02) |
| GHCR namespace | `ghcr.io/tuckermclean` (`Makefile:47`) | `builder_image.repo`, `store.oci.prefix` |
| builder image tag | `20260810-d9d08d1c7422` (`Makefile:63-64`) | adopted by digest `sha256:ab04002a…` in `builder_image.digest` and `store.oci.adopted.builder` |
| binpkg cache | `monolith-binpkgs:20260811`, digest `sha256:d0a1838d…` | `store.oci.adopted.binpkg-seed` |
| oras | 1.2.0, no checksum (`build.yml:234`) | `tools.oras` + sha256 |
| actionlint | 1.7.7 (`pr-validate.yml:53`) | `tools.actionlint` |
| check-jsonschema | 0.38.0 (`build.yml:708`) | `python.check-jsonschema` |
| gpkg format | `BINPKG_FORMAT=gpkg`, xz (`make.conf:59,62`) | recipe config (R01), not a pin |
| actions (8 distinct) | `checkout@v4`, `setup-python@v5`, `upload-artifact@v4`, `cache@v4` (+`/restore`, `/save`), `attest@v2`, `docker/login-action@v3`, `dorny/paths-filter@v3`, `aws-actions/configure-aws-credentials@v4` (dropped with S3) | not in the ledger: SHA and `# vX.Y.Z` on each workflow `uses:` line, checked by `check-fetches` |

**Unpinned today; must become pinned (or declared floating with a reason).**
| Input | Predecessor state | Fix |
|---|---|---|
| syft, grype (image) | `install.sh` from anchore `main` (`Dockerfile:131`) | `tools.syft`, `tools.grype`, sha256, installed on the runner by I03's `install-tool`; the image's copies are not used |
| grype (workflows) | `curl …/grype/main/install.sh \| sh` (`cve-gate-canary.yml:56-57`, `nightly-cve-scan.yml:43-44`) | `tools.grype`; workflows use the builder image or the pinned installer |
| stage3 | tag, not digest (`Dockerfile:30`); `STAGE3_DIGEST` forwarded but never set | `base_image.stage3` (digest; reserved for M02) |
| GRUB | no pin; claimed 2.12 (`build-iso.sh:264-267`) | `asserted.grub` |
| rustup-init | `sh.rustup.rs` script (`Dockerfile:168`) | `tools.rustup-init` (reserved for M02; the adopted image already contains nightly-2026-07-15) |
| all GitHub Actions | major tags (`@v4`, `@v5`, …) | full SHAs on the `uses:` lines (SPEC §6), checked by `check-fetches` |
| runner image | `ubuntu-latest` | `runners.ubuntu` |
| qemu, ovmf, squashfs-tools, kmod (apt) | latest of runner (`workflows.yaml:30`) | `floating.apt` with reason, owner O01/B06; versions recorded in the job summary |
| pexpect, pyyaml | pip unpinned (`cve-gate-canary.yml:61`) | `python.*` exact versions |
| host portage tools | by epoch (`Dockerfile:81-98`) | stays implicit by epoch; `asserted.*` for the ones that matter |
| v86, BIOS images | `cdn.jsdelivr.net/npm/v86/` unpinned, BIOS from `copy/v86@master` (supplychain.yaml:629-654) | `web.v86` reserved for P03/P04 |
| Google Fonts | external stylesheet | `web.fonts` reserved for P03 |
| Docker BuildKit frontend | unpinned `syntax` if used | digest in `image/Dockerfile` (checked by `check-fetches`) |
| registry:2 test image (I01) | not applicable in the predecessor | `store.registry_test_image` |

## Traps and doctrines preserved
- **D-two-epoch-pin-model**: two keys, disjoint consumers, SDE derived from the build epoch only: AC-3, AC-4 (after MS2).
- **T-pin-bump-false-green** (a bump validated while nothing changed or the input was missing): `check-pins --store` proves the tree archive exists with the ledger hash; `pin diff` shows what changed: AC-5, AC-13.
- **T-builder-image-tag-not-pushed**: the ledger digest must resolve and match the adopted rc1 digest: AC-9.
- **D-static-musl-cross-all-the-way** and **T-rust-i486-musl**: rust nightly consistency with ebuilds: AC-8.
- **Principle 2**: unpinned fetch fails CI: AC-6, AC-7, AC-10.
- **build.yaml contradictions**: GRUB claim: AC-12; `crossdev.lock` lag: AC-11; nondeterministic `# Updated:` header (`update-versions.sh:137`): AC-2.

## Gate
- **I05-AC-1** — `check-pins` rejects a ledger with a missing required key, a wrong-length hash, an impossible date, a future epoch, a `tree.commit` that is not 40 hex, a missing `tree.signature`, or an `actions` key (the section no longer exists); the committed `pins/pins.yaml` passes. *Verify:* `tests/fast/pins-schema.test.sh` (one fixture per rejection). *Tier:* fast.
- **I05-AC-2** — `pin set` then `pin get` round-trips, and writing a value equal to the current one leaves the file byte-identical; the file contains no timestamp. *Verify:* `tests/fast/pins-cli.test.sh`. *Tier:* fast.
- **I05-AC-3** — `pin sde` prints `1786406400` for `epochs.build: "20260811"` and refuses a non-date; `pins.yaml` has no `SOURCE_DATE_EPOCH` key. *Verify:* `tests/fast/pins-cli.test.sh` case `sde`. *Tier:* fast.
- **I05-AC-4** — The builder inputs list (`image/hash-inputs.txt`, written by M02) names `epochs.toolchain` and no `epochs.build` or `tree.*` key; `check-pins` fails when it does and skips with a notice while the file does not exist. *Verify:* `tests/fast/pins-epochs.test.sh`. *Tier:* fast. *When:* after MS2.
- **I05-AC-5** — With `--store`, `check-pins` fails when the `snapshot` object `gentoo-<tree.commit>.tar.xz` is absent from the store or its sha256 differs from `tree.sha256`, and treats store errors as failures (not as absent). *Verify:* `tests/fast/pins-store.test.sh` (fs-backed store, fake errors); nightly CI job `pins-live`. *Tier:* fast + slow.
- **I05-AC-6** — `check-fetches` fails on each of: unpinned `uses:`, `curl … | sh`, `raw.githubusercontent.com/…/main/`, tag-only `FROM`/`image:`/`docker pull`, `pip install` without `==`, `runs-on: ubuntu-latest`, unallowlisted `apt-get install`. Fixtures are verbatim predecessor lines (`actions/checkout@v4`, the grype `install.sh` pipe, `Dockerfile:131`). *Verify:* `tests/fast/fetches-scan.test.sh` (one RED fixture per idiom under `tests/fast/fixtures/unpinned/`). *Tier:* fast.
- **I05-AC-7** — Allowlist entries are valid only with `reason` and `pin` or `floating`; an entry that matches no line fails; an allowlisted line whose `pin:` path is not in the ledger fails. *Verify:* `tests/fast/fetches-allowlist.test.sh`. *Tier:* fast.
- **I05-AC-8** — `rust.nightly` equals every `RUST_NIGHTLY=` in the overlay ebuilds that define it; with no overlay yet (`recipes/` absent) the test runs on copied predecessor ebuild fixtures. *Verify:* `tests/fast/pins-rust.test.sh`. *Tier:* fast.
- **I05-AC-9** — `check-pins --registry` fails when `builder_image.digest` does not resolve or, while the adopted image is in use, differs from `store.oci.adopted.builder.digest`; once `builder_image.inputs_hash` exists (M02) it also fails when the image's `org.themonolith.inputs-hash` label differs. *Verify:* `tests/fast/pins-builder.test.sh` (fake `docker`); CI job `builder-image-adopt` (I03-AC-13). *Tier:* fast + slow.
- **I05-AC-10** — A leaf pin with no consumer fails `check-pins` unless marked `status: reserved` with an `owner` node id existing in `docs/graph.yaml`; every `uses:` line in `.github/**` has a 40-hex SHA and a `# vX.Y.Z` comment, and `pins.yaml` holds no copy of either. *Verify:* `tests/fast/pins-consumers.test.sh` with `tests/fast/fixtures/workflows/`. *Tier:* fast.
- **I05-AC-11** — `pins/crossdev.lock` begins with `# toolchain-epoch: <E>` and `check-pins` fails when `<E>` differs from `epochs.toolchain`. *Verify:* `tests/fast/pins-crossdev.test.sh`. *Tier:* fast.
- **I05-AC-12** — `check-pins --inventory inventory.json` fails when grub, syslinux, xorriso or squashfs-tools differ from `asserted.*`, or when an asserted key is missing in the inventory. *Verify:* `tests/fast/pins-asserted.test.sh` (fixture inventory); CI job `builder-image-adopt` (real inventory, I03-AC-17). *Tier:* fast + slow.
- **I05-AC-13** — `pin diff <base> <head>` prints a Markdown table of changed leaf paths with old and new value, and exits non-zero on a change to a key that is not in the schema; M01, M02, M04 use it in PR summaries. *Verify:* `tests/fast/pins-diff.test.sh`. *Tier:* fast.
- **I05-AC-14** — Every pin in the "exists today" and "unpinned today" tables above that applies to this repository has a ledger key or an explicit `floating`/`reserved` entry, or is marked as living in the `uses:` lines, checked against a table in `tests/fast/fixtures/expected-pin-keys.txt`. *Verify:* `tests/fast/pins-coverage.test.sh`. *Tier:* fast.

## RED plan
Tester writes first: `pins-schema`, `pins-cli`, `pins-epochs`, `pins-crossdev`, `fetches-scan`, `fetches-allowlist` and `pins-coverage` tests, with the predecessor's offending lines as fixtures (workflow files with `@v4`, the grype `install.sh` pipe, a Dockerfile `FROM` by tag). They fail because `factory/bin/pin`, `check-pins`, `check-fetches` and the schema do not exist; `pins/pins.yaml` is committed by I01/I03 in a state the schema test initially rejects (missing required sections).

## Risks and open questions
- Hardest: the unpinned-fetch scanner is text-level. It will miss a fetch hidden in a script variable or a third-party action's internals (a SHA-pinned action may still download unpinned things). Backstops are I03 `--network=none` and I04 offline mode; the residual risk is in actions' own code. A reviewed allowlist of actions (SHA only) is the limit of this node.
- From M02 on, the ledger builder digest is an output of a 60 to 100 minute build, so every image change needs two commits. Acceptable; the alternative (tag pull) was rejected. The adopted rc1 digest has no such step.
- The "reserved pin" rule depends on knowing which nodes are done; F02 may provide it. Until then the first implementation warns.
- Protected path conflict: SPEC §8 forbids agents editing `pins/pins.yaml`, yet M01, M02 and M04 are bots opening PRs that edit it, and I01 and I03 seed it. This node assumes bots may open the PR and humans merge (§8 "Merging"); SPEC should say "agents may not merge changes to protected paths" rather than "may not edit".
- Apt packages stay floating (qemu, ovmf). A pinned CI-tools image digest for the oracle (O01) would remove them; not decided here.
- Unknown how many tools the new repo will end up with; the table lists the predecessor's set only.
- An unsigned tree pin (I02 may find that gentoo-mirror commits cannot be verified) is allowed but must be named in `tree.signature`; the ledger cannot make it safer, only visible.

## Cost
Three slices: (1) schema, CLI, SDE, round-trip, coverage (AC-1 to AC-3, AC-13, AC-14); (2) fetch scanner, allowlist, consumers (AC-6, AC-7, AC-10); (3) cross-checks against store, registry, rust, crossdev.lock and manifest (AC-4, AC-5, AC-8, AC-9, AC-11, AC-12). No full build cycles of its own; AC-9 and AC-12 ride on the I03 CI job, AC-5 on a nightly job. Money: none.

## Spec defects found
- Nothing depends on I05 in `docs/graph.yaml`, although SPEC §2.2 and §6 make `pins/pins.yaml` the single source for B01, M01, M02 and M04. B01, M01, M02 and M04 should list I05 as a dependency, or the ledger can be ignored without any gate failing.
- I05 depends on I03, but I01 (oras), I02 (tree) and I03 (tools) must write pins first. This spec follows the second reading: the pin sections are owned by the nodes that introduce them (I01, I02, I03) in the format defined here, and I05 checks them.
- SPEC §6 lists `shellcheck` and `v86` as pins; no node installs `shellcheck` with a checksum (F01 uses the runner's copy). F01 should pin it through `tools.shellcheck`.
- SPEC §6 says the stage3 is "the stage3 tarball (sha256 of the signed autobuild, I03)". The first stage3 use is M02's rebuild from the Docker Hub image `gentoo/stage3:amd64-openrc-20260810` pinned by digest; the signed-tarball form is for later epochs. SPEC §6 should say so.
- M04's draft still lists Action SHAs in `pins.yaml`; it should follow SPEC §6 (the `uses:` lines). Not edited here.
