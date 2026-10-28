# The Monolith

A bootable artifact from the future: a complete GNU/Linux userland that runs on a 486 or a modern UEFI
machine, built from source against musl, statically linked, and attested end to end.

This repository is a from-first-principles rebuild of
[linux-live-iso-factory](https://github.com/tuckermclean/linux-live-iso-factory), which released
`v0.1.0-rc1`. It is at the specification stage; nothing here builds an ISO yet.

Licensed under the [MIT License](LICENSE).

## The specification

| Start here | What it is |
|---|---|
| [`SPEC.md`](SPEC.md) | The authority: product, principles, doctrines, architecture, store contract, oracle, trust model, open decisions |
| [`docs/graph.yaml`](docs/graph.yaml) | 50 nodes in 10 phases, their dependencies and five milestones |
| [`nodes/`](nodes/) | One spec per node, each with its acceptance criteria |
| [`docs/reviews/`](docs/reviews/) | What review changed in the drafts, and what is still open |
| [`docs/study/`](docs/study/) | The frozen study of the predecessor at `b9f533b`: inventory, recipes, oracle, doctrines and traps |

Milestones: **MS1** the test-first agent loop is online · **MS2** first ISO from pinned, self-hosted
inputs · **MS3** parity with rc1's oracle · **MS4** first attested release · **MS5** cutover.
