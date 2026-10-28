# I05 — pin-ledger

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| I | F03, I03 | B01, B06, O07, S01, S03, M01, M04 | — (needed for MS2) | M |

**Owns:** `pins/pins.yaml` (schema and checks; sections seeded by I01 and I03), `pins/pins.schema.json` (JSON Schema, validated with stdlib plus PyYAML code, not a third-party validator), `pins/crossdev.lock`, `pins/fetch-allow.yaml`, `pins/keys/` (shared with I02), `factory/bin/pin` (`get`, `set`, `list`, `sde`, `diff`), `factory/bin/check-pins`, `factory/bin/check-fetches`, `tests/fast/pins-*.test.sh`, `tests/fast/fetches-*.test.sh`, `tests/fast/fixtures/unpinned/` (verbatim offenders from the predecessor), `tests/fast/fixtures/workflows/`.
**Carries from linux-live-iso-factory@b9f533b:** `configs/portage/crossdev.lock` (to `pins/crossdev.lock`, with a machine-readable header added), the `ARG TOOLCHAIN_EPOCH`/`ARG BUILD_EPOCH`/`ENV SOURCE_DATE_EPOCH` triple (`Dockerfile:28-29,37`) as the concept; `scripts/update-build-pins.sh` is NOT carried (bump automation is M01, M02). `configs/portage/versions.lock` goes to R02.
**Study refs:** D-two-epoch-pin-model, D-static-musl-cross-all-the-way, T-pin-bump-false-green, T-builder-image-tag-not-pushed, Principle 2, SPEC §6, workflows.yaml `pins_summary` (actions, tools_fetched_at_runtime), build.yaml `pins` and `contradictions` (GRUB "pinned to 2.12"; `crossdev.lock` header lags `TOOLCHAIN_EPOCH`), supplychain.yaml (v86, jsDelivr and Google Fonts unpinned), recipes.yaml (RUST_NIGHTLY shared by rl144 and stele).

## Purpose
After this node there is one file, `pins/pins.yaml`, that holds every version, digest, epoch and checksum the project depends on, plus two checks that keep it honest: CI fails when a build or workflow fetches something the ledger does not pin, and when the ledger pins something nothing uses. In the predecessor, pins were scattered across a Dockerfile, a Makefile, workflow files and comments, several were wrong (GRUB), and about half of the tool installs followed `main` or a floating tag.

## Scope
In:
- The ledger format, reader/writer CLI, schema check, consumer (unused-pin) check.
- The unpinned-fetch scanner, its allowlist and its fixtures.
- Consistency assertions across pins (rust nightly vs ebuilds, `crossdev.lock` vs toolchain epoch, snapshot hashes, SDE derivation).
- Seeding the ledger with every pin that exists today and the pins that must be added.

Out:
- Choosing new values and the store/ingest of what they point at: I02 (snapshots), I03 (stage3, tools, rust), I04 (distfiles).
- `versions.lock` content and generation: R02. Kernel fragments: R04.
- Bump automation (BUILD_EPOCH, TOOLCHAIN_EPOCH, tools, actions): M01, M02, M04. This node provides `pin set` and `pin diff` for them.
- The grype DB version and the CVE policy: S03.
- Vendoring the v86 and web libraries: P03, P04 (their pins are listed here as reserved).
- Who may edit `pins/pins.yaml`: SPEC §8 (protected path).

## Design
**Format (`pins/pins.yaml`, schema 1).** YAML, two-space indent, keys in the fixed order below, no timestamps, no comments that carry data. `pin set` rewrites the file deterministically (round trip is byte-identical).

```yaml
schema: 1
epochs:
  toolchain: "YYYYMMDD"            # TOOLCHAIN_EPOCH
  build: "YYYYMMDD"                # BUILD_EPOCH; SOURCE_DATE_EPOCH is derived, never stored
snapshots:                         # keyed by epoch; the sha256 of the verified tarball in the store
  "YYYYMMDD": {sha256: <64hex>, gpgsig_sha256: <64hex>}
gentoo_key:
  snapshot: {fingerprint: <40hex>, file: pins/keys/gentoo-snapshot.asc}
  release:  {fingerprint: <40hex>, file: pins/keys/gentoo-release.asc}   # stage3 signing, used by I03
base_image:
  stage3: {name: <autobuilds file name>, sha256: <64hex>, epoch: "YYYYMMDD"}
builder_image:
  repo: <registry path>
  digest: sha256:<64hex>
  inputs_hash: <64hex>
tools:                             # every downloaded binary: version, url template, sha256 per arch
  oras|syft|grype|actionlint|shellcheck|rustup-init|<...>:
    version: <exact>
    url: <template>
    sha256: {linux_amd64: <64hex>}
rust: {nightly: nightly-YYYY-MM-DD, components: [rust-src], dist_sha256: {<file>: <64hex>}}
python: {pyyaml: <exact>, check-jsonschema: <exact>, pexpect: <exact>}
asserted:                          # versions of packages resolved by the toolchain tree, asserted from builder-manifest.json
  grub: <version>
  syslinux: <version>
  xorriso: <version>
  squashfs-tools: <version>
actions:                           # one entry per action used in .github/**
  <owner>/<repo>: {sha: <40hex>, version: vX.Y.Z}
runners: {ubuntu: ubuntu-24.04}
store: {oci: {prefix: <registry path prefix>}, registry_test_image: <repo>@sha256:<64hex>}
web: {v86: {version: <exact>, sha256: {…}}, fonts: reserved}
floating:                          # allowed unpinned inputs, each with reason and owner node
  apt: {packages: [qemu-system-x86, ovmf, squashfs-tools, kmod], reason: <text>, owner: <node>}
files: {crossdev: pins/crossdev.lock, versions: pins/versions.lock}
```
`SOURCE_DATE_EPOCH = date -u -d "<epochs.build>" +%s`, computed by `pin sde`. Predecessor check value: 20260811 gives 1786406400 (`Dockerfile:37`).
Rejected: storing `SOURCE_DATE_EPOCH` as a key; it was a second source of truth that `update-build-pins.sh` had to keep in step by `sed`.
Rejected: separate pin files per area (the predecessor's state). One file is greppable and one review surface.

**CLI.** `pin get <dotted.path>` prints the scalar (exit 3 when absent, 2 on a non-scalar); `pin list` prints leaf paths; `pin set <path> <value>` validates the new value against the schema before writing; `pin sde`; `pin diff <base-ref> <head-ref>` prints a table for PR summaries (used by M01, M02, M04). Python 3 stdlib plus PyYAML (SPEC §4.3), host-side only.

**Consumers.** A pin is "used" when its dotted path appears in a repo file other than `pins/` and `docs/` as `pin get <path>`, or in a `# pin: <path>` annotation on the consuming line, or (for `actions.*`) when a workflow `uses: <owner>/<repo>@<sha>` matches. A leaf may be marked `status: reserved, owner: <node>` while its consumer is not built yet; reserved pins expire when that node's PR merges (the check fails if the owner node's spec says it is done: the node list is in `docs/graph.yaml` plus a `done` file maintained by F02 tooling; unknown until F02, so the first implementation can only warn).

**Unpinned-fetch scanner (`check-fetches`).** Scans `.github/**`, `image/**`, `factory/**`, `Makefile`, `supplychain/**`, `oracle/**`, `web/**` (text only). Flags:
- `uses:` not followed by a 40-hex SHA (and a `# vX.Y.Z` comment equal to the ledger version);
- `curl`/`wget` piped to a shell; any `raw.githubusercontent.com/.../main/`;
- `pip install` without `==`; `apt-get install`/`apt install` of packages not in `floating.apt`;
- `FROM` or `image:` or `docker pull` without `@sha256:`; `runs-on: *-latest`;
- `npm`, `cargo install`, `go install`, `gem` without exact versions;
- `cdn.jsdelivr.net` or `fonts.googleapis.com` URLs in `web/` (until P03/P04 vendor them).
Each hit must be in `pins/fetch-allow.yaml` with `file`, `pattern`, `reason` and either `pin: <path>` or `floating: <key>`; an allowlist entry that matches nothing fails the check. This is text-level and heuristic; the runtime backstops are I04's offline mode and I03's `--network=none` build steps. Rejected: a network-egress sandbox for CI; it cannot see `uses:` and is not testable in the fast tier.

**Cross-checks (`check-pins`).**
- Schema: types, 64-hex and 40-hex lengths, real dates, `epochs.*` not in the future.
- `epochs.toolchain` and `epochs.build` are independent keys; the builder inputs list (`image/hash-inputs.txt`, I03) must not contain `epochs.build`.
- `snapshots` has an entry for both epochs; with `--store`, `store has snapshot gentoo-<E>.tar.xz` succeeds and its sha256 equals the ledger.
- `pins/crossdev.lock` has the header `# toolchain-epoch: <E>` and `<E> == epochs.toolchain`. This resolves the predecessor's lag (lock header said 20260727 while the epoch was 20260810, `crossdev.lock:3-4`, documented as "one cycle behind" at `update-build-pins.sh:196-198`).
- `rust.nightly` equals every `RUST_NIGHTLY=` in `recipes/overlay/**/*.ebuild` (rl144 and stele; predecessor value `nightly-2026-07-15`).
- `asserted.*` equals the versions in `builder-manifest.json` (I03) when `--manifest` is given. This replaces the unfounded claim "GRUB 2.12" in `build-iso.sh:264-267,503` with a check.
- `builder_image.digest` resolves (`--registry`), carries label `org.themonolith.inputs-hash` equal to `builder_image.inputs_hash` and to `builder-image hash`.

**Every pin that exists today (predecessor), and what becomes of it.**
| Pin | Predecessor value and evidence | Ledger key |
|---|---|---|
| TOOLCHAIN_EPOCH | 20260810 (`Dockerfile:28`), stage3 by TAG | `epochs.toolchain` + `base_image.stage3.sha256` |
| BUILD_EPOCH | 20260811 (`Dockerfile:29`) | `epochs.build`, `snapshots.<E>` |
| SOURCE_DATE_EPOCH | 1786406400 hard-coded (`Dockerfile:37`) | derived by `pin sde` |
| crossdev.lock | musl 1.2.6, gcc 15.3.1_p20260717 (`crossdev.lock:8-9`) | `files.crossdev` |
| crossdev flags | binutils and headers from versions.lock (`Makefile:36-40`) | R02, read by I03 |
| versions.lock | 109 lines, lacks several world atoms (recipes.yaml coverage_gap) | `files.versions` (R02) |
| rust nightly | `nightly-2026-07-15` (`Dockerfile:167-170`, ebuilds) | `rust.nightly` |
| snapshot signing key | `DCD05B71…BF6D`, comment only (`Dockerfile:68-69`) | `gentoo_key.snapshot` |
| GHCR namespace | `ghcr.io/tuckermclean` (`Makefile:47`) | `builder_image.repo`, `store.oci.prefix` |
| builder image tag | `TOOLCHAIN_EPOCH-<hash12>` (`Makefile:63-64`) | tag derived; digest in `builder_image.digest` |
| oras | 1.2.0, no checksum (`build.yml:234`) | `tools.oras` + sha256 |
| actionlint | 1.7.7 (`pr-validate.yml:53`) | `tools.actionlint` |
| check-jsonschema | 0.38.0 (`build.yml:708`) | `python.check-jsonschema` |
| gpkg format | `BINPKG_FORMAT=gpkg`, xz (`make.conf:59,62`) | recipe config (R01), not a pin |
| actions (8 distinct) | `checkout@v4`, `setup-python@v5`, `upload-artifact@v4`, `cache@v4` (+`/restore`, `/save`), `attest@v2`, `docker/login-action@v3`, `dorny/paths-filter@v3`, `aws-actions/configure-aws-credentials@v4` (dropped with S3) | `actions.<owner>/<repo>` |

**Unpinned today; must become pinned (or declared floating with a reason).**
| Input | Predecessor state | Fix |
|---|---|---|
| syft, grype (image) | `install.sh` from anchore `main` (`Dockerfile:131`) | `tools.syft`, `tools.grype`, sha256, installed by I03 |
| grype (workflows) | `curl …/grype/main/install.sh \| sh` (`cve-gate-canary.yml:56-57`, `nightly-cve-scan.yml:43-44`) | `tools.grype`; workflows use the builder image or the pinned installer |
| stage3 | tag, not digest (`Dockerfile:30`); `STAGE3_DIGEST` forwarded but never set | `base_image.stage3.sha256` |
| GRUB | no pin; claimed 2.12 (`build-iso.sh:264-267`) | `asserted.grub` |
| rustup-init | `sh.rustup.rs` script (`Dockerfile:168`) | `tools.rustup-init` |
| all GitHub Actions | major tags (`@v4`, `@v5`, …) | `actions.*` SHAs |
| runner image | `ubuntu-latest` | `runners.ubuntu` |
| qemu, ovmf, squashfs-tools, kmod (apt) | latest of runner (`workflows.yaml:30`) | `floating.apt` with reason, owner O01/B06; versions recorded in the job summary |
| pexpect, pyyaml | pip unpinned (`cve-gate-canary.yml:61`) | `python.*` exact versions |
| host portage tools | by epoch (`Dockerfile:81-98`) | stays implicit by epoch; `asserted.*` for the ones that matter |
| v86, BIOS images | `cdn.jsdelivr.net/npm/v86/` unpinned, BIOS from `copy/v86@master` (supplychain.yaml:629-654) | `web.v86` reserved for P03/P04 |
| Google Fonts | external stylesheet | `web.fonts` reserved for P03 |
| Docker BuildKit frontend | unpinned `syntax` if used | digest in `image/Dockerfile` (checked by `check-fetches`) |
| registry:2 test image (I01) | not applicable in the predecessor | `store.registry_test_image` |

## Traps and doctrines preserved
- **D-two-epoch-pin-model**: two keys, disjoint consumers, SDE derived from the build epoch only: AC-3, AC-4.
- **T-pin-bump-false-green** (a bump validated while nothing changed or the input was missing): `check-pins --store` proves the snapshot exists with the ledger hash; `pin diff` shows what changed: AC-5, AC-13.
- **T-builder-image-tag-not-pushed**: the ledger digest must resolve: AC-9.
- **D-static-musl-cross-all-the-way** and **T-rust-i486-musl**: rust nightly consistency with ebuilds: AC-8.
- **Principle 2**: unpinned fetch fails CI: AC-6, AC-7, AC-10.
- **build.yaml contradictions**: GRUB claim: AC-12; `crossdev.lock` lag: AC-11; nondeterministic `# Updated:` header (`update-versions.sh:137`): AC-2.

## Gate
- **I05-AC-1** — `check-pins` rejects a ledger with a missing required key, a wrong-length hash, an impossible date, a future epoch, or an `actions` entry whose `sha` is not 40 hex; the committed `pins/pins.yaml` passes. *Verify:* `tests/fast/pins-schema.test.sh` (one fixture per rejection). *Tier:* fast.
- **I05-AC-2** — `pin set` then `pin get` round-trips, and writing a value equal to the current one leaves the file byte-identical; the file contains no timestamp. *Verify:* `tests/fast/pins-cli.test.sh`. *Tier:* fast.
- **I05-AC-3** — `pin sde` prints `1786406400` for `epochs.build: "20260811"` and refuses a non-date; `pins.yaml` has no `SOURCE_DATE_EPOCH` key. *Verify:* `tests/fast/pins-cli.test.sh` case `sde`. *Tier:* fast.
- **I05-AC-4** — The builder inputs list (`image/hash-inputs.txt`) names `epochs.toolchain` and no `epochs.build` or build-snapshot key; `check-pins` fails when it does. *Verify:* `tests/fast/pins-epochs.test.sh`. *Tier:* fast.
- **I05-AC-5** — With `--store`, `check-pins` fails when a `snapshots.<E>` object is absent from the store or its sha256 differs from the ledger, and treats store errors as failures (not as absent). *Verify:* `tests/fast/pins-store.test.sh` (fs-backed store, fake errors); nightly CI job `pins-live`. *Tier:* fast + slow.
- **I05-AC-6** — `check-fetches` fails on each of: unpinned `uses:`, `curl … | sh`, `raw.githubusercontent.com/…/main/`, tag-only `FROM`/`image:`/`docker pull`, `pip install` without `==`, `runs-on: ubuntu-latest`, unallowlisted `apt-get install`. Fixtures are verbatim predecessor lines (`actions/checkout@v4`, the grype `install.sh` pipe, `Dockerfile:131`). *Verify:* `tests/fast/fetches-scan.test.sh` (one RED fixture per idiom under `tests/fast/fixtures/unpinned/`). *Tier:* fast.
- **I05-AC-7** — Allowlist entries are valid only with `reason` and `pin` or `floating`; an entry that matches no line fails; an allowlisted line whose `pin:` path is not in the ledger fails. *Verify:* `tests/fast/fetches-allowlist.test.sh`. *Tier:* fast.
- **I05-AC-8** — `rust.nightly` equals every `RUST_NIGHTLY=` in the overlay ebuilds that define it; with no overlay yet (`recipes/` absent) the test runs on copied predecessor ebuild fixtures. *Verify:* `tests/fast/pins-rust.test.sh`. *Tier:* fast.
- **I05-AC-9** — `check-pins --registry` fails when `builder_image.digest` does not resolve, or its `org.themonolith.inputs-hash` label differs from `builder_image.inputs_hash` or from `builder-image hash`. *Verify:* `tests/fast/pins-builder.test.sh` (fake `docker`); CI job `builder-image-pin` (I03-AC-13). *Tier:* fast + slow.
- **I05-AC-10** — A leaf pin with no consumer fails `check-pins` unless marked `status: reserved` with an `owner` node id existing in `docs/graph.yaml`; every `actions.*` entry matches at least one `uses:` SHA in `.github/**`, and every `uses:` SHA matches a ledger entry with the same `# vX.Y.Z` comment. *Verify:* `tests/fast/pins-consumers.test.sh` with `tests/fast/fixtures/workflows/`. *Tier:* fast.
- **I05-AC-11** — `pins/crossdev.lock` begins with `# toolchain-epoch: <E>` and `check-pins` fails when `<E>` differs from `epochs.toolchain`. *Verify:* `tests/fast/pins-crossdev.test.sh`. *Tier:* fast.
- **I05-AC-12** — `check-pins --manifest builder-manifest.json` fails when grub, syslinux, xorriso or squashfs-tools differ from `asserted.*`, or when an asserted key is missing in the manifest. *Verify:* `tests/fast/pins-asserted.test.sh` (fixture manifest); CI job `builder-image` (real manifest). *Tier:* fast + slow.
- **I05-AC-13** — `pin diff <base> <head>` prints a Markdown table of changed leaf paths with old and new value, and exits non-zero on a change to a key that is not in the schema; M01, M02, M04 use it in PR summaries. *Verify:* `tests/fast/pins-diff.test.sh`. *Tier:* fast.
- **I05-AC-14** — Every pin in the "exists today" and "unpinned today" tables above that applies to this repository has a ledger key or an explicit `floating`/`reserved` entry, checked against a table in `tests/fast/fixtures/expected-pin-keys.txt`. *Verify:* `tests/fast/pins-coverage.test.sh`. *Tier:* fast.

## RED plan
Tester writes first: `pins-schema`, `pins-cli`, `pins-epochs`, `pins-crossdev`, `fetches-scan`, `fetches-allowlist` and `pins-coverage` tests, with the predecessor's offending lines as fixtures (workflow files with `@v4`, the grype `install.sh` pipe, a Dockerfile `FROM` by tag). They fail because `factory/bin/pin`, `check-pins`, `check-fetches` and the schema do not exist; `pins/pins.yaml` is committed by I01/I03 in a state the schema test initially rejects (missing required sections).

## Risks and open questions
- Hardest: the unpinned-fetch scanner is text-level. It will miss a fetch hidden in a script variable or a third-party action's internals (a SHA-pinned action may still download unpinned things). Backstops are I03 `--network=none` and I04 offline mode; the residual risk is in actions' own code. A reviewed allowlist of actions (SHA only) is the limit of this node.
- The ledger builder digest is an output of a 60 to 100 minute build (I03), so every image change needs two commits. Acceptable; the alternative (tag pull) was rejected in I03.
- The "reserved pin" rule depends on knowing which nodes are done; F02 may provide it. Until then the first implementation warns.
- Protected path conflict: SPEC §8 forbids agents editing `pins/pins.yaml`, yet M01, M02 and M04 are bots opening PRs that edit it, and I01 and I03 seed it. This node assumes bots may open the PR and humans merge (§8 "Merging"); SPEC should say "agents may not merge changes to protected paths" rather than "may not edit".
- Apt packages stay floating (qemu, ovmf). A pinned CI-tools image digest for the oracle (O01) would remove them; not decided here.
- Unknown how many `uses:` and tools the new repo will end up with; the table lists the predecessor's set only.

## Cost
Three slices: (1) schema, CLI, SDE, round-trip, coverage (AC-1 to AC-3, AC-13, AC-14); (2) fetch scanner, allowlist, consumers (AC-6, AC-7, AC-10); (3) cross-checks against store, registry, rust, crossdev.lock and manifest (AC-4, AC-5, AC-8, AC-9, AC-11, AC-12). No full build cycles of its own; AC-9 and AC-12 ride on the I03 CI job, AC-5 on a nightly job. Money: none.

## Spec defects found
- Nothing depends on I05 in `docs/graph.yaml`, although SPEC §2.2 and §6 make `pins/pins.yaml` the single source for B01, M01, M02 and M04. B01, M01, M02 and M04 should list I05 as a dependency, or the ledger can be ignored without any gate failing.
- I05 depends on I03, but I01 (oras) and I03 (stage3, tools, rust) must write pins first, and I02 reads the key pin. Either I05 should precede them (dependencies F03 only; the "unused pin" check can be activated per section as nodes land) or the pin sections should be explicitly owned by the nodes that introduce them. This spec follows the second reading: I01, I02 and I03 seed their sections in the format defined here.
- SPEC §8 lists `pins/pins.yaml` as a protected path agents may not edit, which conflicts with the bump nodes (M01, M02, M04). See Risks.
- SPEC §3 D-two-epoch-pin-model and §6 say the stage3 is pinned by digest; with the tarball base chosen in I03 it is pinned by sha256 of the signed tarball.
- SPEC §6 lists `shellcheck` and `v86` as pins; no node installs `shellcheck` with a checksum (F01 uses the runner's copy). F01 should pin it through `tools.shellcheck`.
