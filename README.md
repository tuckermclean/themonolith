# The Monolith

A small, specialized Gentoo-derived Linux distribution: one live ISO with a complete GNU/Linux
userland that runs on a 486 with 64 MB of RAM or on a modern UEFI machine. It is cross-compiled from
source against musl, statically linked, and attested end to end.

This repository continues
[linux-live-iso-factory](https://github.com/tuckermclean/linux-live-iso-factory), which released
`v0.1.0-rc1`. It ports the predecessor's working recipes, scripts, tests and workflows, replaces the dead
S3 storage with GHCR and GitHub Releases, and fixes the bugs a study of the predecessor verified. It
uses Portage, crossdev and the standard kernel, ISO, QEMU and supply-chain tools, and writes custom code
only where they leave a gap. It is at the specification stage: nothing here builds an ISO yet.

Licensed under the [MIT License](LICENSE).

## The specification

| Start here | What it is |
|---|---|
| [`SPEC.md`](SPEC.md) | The authority: product and constraints, principles, doctrines, architecture, the standard-mechanism table (§5), pins, oracle, release, open decisions |
| [`docs/first-release.md`](docs/first-release.md) | The plan: a working ISO for iteration first, then the first release; surviving assets, owner actions, order of work, measured timings |
| [`docs/graph.yaml`](docs/graph.yaml) | 22 nodes, their dependencies and three milestones |
| [`nodes/`](nodes/) | One spec per node, each with its acceptance criteria |
| [`docs/reviews/`](docs/reviews/) | What each revision changed; `2026-10-28-v0.4.md` maps every v0.3 node to its v0.4 fate |
| [`docs/study/`](docs/study/) | The frozen study of the predecessor at `b9f533b`: inventory, recipes, oracle, doctrines and traps |

Milestones:
- **MS1:** a working, testable ISO for iteration, built by CI from pinned inputs with the oracle green.
  It may leave out the two Rust packages, `rl144` and `stele`. It is not a release and is never
  published.
- **MS2:** the first release. Two clean offline builds produce the same ISO SHA-256, the ISO ships all
  99 of the predecessor's packages including `rl144` and `stele`, and only then is it tested, attested
  and published as a prerelease.
- **MS3:** cutover to the first non-prerelease.
