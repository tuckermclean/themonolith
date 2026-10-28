# The Monolith

A bootable artifact from the future: a complete GNU/Linux userland that runs on a 486 or a modern UEFI
machine, built from source against musl, statically linked, and attested end to end.

This repository rebuilds the factory of
[linux-live-iso-factory](https://github.com/tuckermclean/linux-live-iso-factory), which released
`v0.1.0-rc1`: it ports what works, fixes what the study found broken, and reuses rc1's surviving builder
image, package cache and release by digest. It is at the specification stage; nothing here builds an
ISO yet.

Licensed under the [MIT License](LICENSE).

## The specification

| Start here | What it is |
|---|---|
| [`SPEC.md`](SPEC.md) | The authority: product, principles, doctrines, architecture, store contract, oracle, trust model, open decisions |
| [`docs/first-attested-build.md`](docs/first-attested-build.md) | The plan to the first attested build: surviving assets, order of work, the build cache, measured timings |
| [`docs/graph.yaml`](docs/graph.yaml) | 52 nodes in 10 phases, their dependencies, tracks (critical, parallel, deferred) and five milestones |
| [`nodes/`](nodes/) | One spec per node, each with its acceptance criteria |
| [`docs/reviews/`](docs/reviews/) | What review changed in the drafts, and what is still open |
| [`docs/study/`](docs/study/) | The frozen study of the predecessor at `b9f533b`: inventory, recipes, oracle, doctrines and traps |

Milestones: **MS1** first ISO from pinned, self-hosted inputs · **MS2** first attested build (a
from-source, fully tested, attested prerelease) · **MS3** the test-first agent loop is online · **MS4**
full parity with rc1 and every README promise tested · **MS5** cutover.
