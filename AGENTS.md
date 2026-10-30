# AGENTS.md

Working notes for agents and contributors. `SPEC.md` is the authority on what is built; this file is
about how to work on it. F01 appends the predecessor's guide below this section: doctrines, traps,
recipes and credential handling.

## Where things are

- `SPEC.md`: product, constraints, the standard-mechanism table (§5), pins, oracle, release rules,
  open decisions (§10), conventions (§11).
- `docs/graph.yaml`: the 22 nodes, their dependencies and the three milestones.
- `nodes/<ID>-<name>.md`: one spec per node, in the SPEC §9 template.
- `docs/first-release.md`: the plan, owner actions and measured timings.
- The port source is `tuckermclean/linux-live-iso-factory` at `b9f533b`. Cite it as `path:line` at that
  commit. `docs/capabilities.md` says which node ports or builds each capability; `docs/migration.tsv`
  lists every predecessor file with its blob, node, disposition and destination
  (`scripts/check-migration.py` checks it).
- `toolbox/` is the test image, `toolbox/run` and the workflow runner `toolbox/ci`; `.claude/` holds the
  `/node` skill, the role agents and the guard hook.
- Nothing builds yet. `make test` arrives with F01; each node then ports the code its tests need.

## Commands

- `toolbox/run -- <cmd>` runs a command in the test toolbox, with the checkout mounted at its own path.
  `toolbox/run` alone opens a shell; `--build` rebuilds the image; `--network none` cuts the network.
  The image rebuilds by itself when `toolbox/` changes.
  `-e NAME` forwards a variable; `CI`, `GITHUB_ACTIONS` and the `GITHUB_OUTPUT`-style files always pass.
- Read predecessor files with `git fetch --no-tags https://github.com/tuckermclean/linux-live-iso-factory
  b9f533b740b1db7bf5658d2805603d84e9b1f185`, then `git show b9f533b:<path>`. The fetch creates no branch
  or tag; never merge it.
- `toolbox/run -- toolbox-selfcheck` checks that every tool is present at its pinned version.
- Make is the build and test interface, run on the host; each target uses the toolbox or the builder
  image itself. `make test` runs every test once F01 has added the Makefile (SPEC §7), building what
  it needs. `make test-lint test-unit` is the PR check without a build; run it before pushing.
  `toolbox/run -- sh scripts/tests/<name>.test.sh` runs one test file.
- `toolbox/ci lint` checks the workflow rules (SPEC §7). `toolbox/ci run <workflow> [<job>...]` runs a
  workflow's `run:` steps in this checkout as a convenience (`--event`, `--input k=v`, `--matrix k=v`).
  It does not model separate runners or artifact and cache transfers: jobs share one checkout here, so
  anything that moves files between jobs is verified in CI.
- Boot a mode: `toolbox/run -- python3 scripts/boot-test.py --iso <iso> --mode bios --kernel-version
  <version>`. Read the version from the ISO with `xorriso -osirrox on -indev <iso> -extract /boot/vmlinuz
  /tmp/vmlinuz` and `file /tmp/vmlinuz`.
- Package builds and the SBOM gates run in the builder image, with podman, pulled by digest.
- `python3 -I .claude/skills/node/check-spec.py` checks the graph against the node specs; `--write`
  regenerates the header rows.
- `sh .claude/hooks/guard.test.sh` tests the guard hook; `sh toolbox/ci.test.sh` tests `toolbox/ci`.

## Building a node

- Use `/node <ID>`. It writes a brief, has a fresh tester commit failing tests (RED), checks them, has a
  fresh implementer make them pass (GREEN), gets an independent review, runs the criteria that need a build, an ISO or CI, and opens
  a PR with the criterion → evidence table.
- `make test` runs every test; its `test-*` targets run parts of it (SPEC §7). Tests come first. A
  criterion verified by a build, a boot or a CI run is met only by a recorded run: a local log or a CI
  URL.
- Role agents may not edit the spec, `AGENTS.md`, `CLAUDE.md`, `.claude/` or `toolbox/`; the guard hook
  blocks it. Spec changes go to the owner.

## Traps

- **Rootless podman without a systemd user session** fails with "Interactive authentication required".
  `toolbox/run` passes `--cgroup-manager=cgroupfs` in that case; do the same for direct podman calls.
  With cgroupfs, podman also leaves an empty `oom` file in the directory it starts from; `toolbox/run`
  starts it from a state directory. Never commit an `oom` file.
- **QEMU runs in software, here and in CI.** `boot-test.py` uses `-cpu 486`, which means something only
  under emulation (and even then is not a full post-486 instruction check), so `toolbox/run` passes no
  `/dev/kvm`. Boots take about a minute and the first in-guest check
  can hit its 30 s timeout. Re-run before suspecting the disc.
- **A step timeout must stop the container.** `toolbox/run` starts containers with `--init`, so SIGTERM
  reaches the command; without it a timed-out step leaves its container running.
- **Workflow files need the `workflow` scope to push.** The default `gh` token lacks it, so a branch that
  changes `.github/workflows/*` is rejected. Use a token the owner provides, transiently, or ask the owner
  to push.

## Constraints on every change

- i486, statically linked against musl, cross-compiled with crossdev. No Python and no freetype on the
  disc (SPEC §1, §3).
- The tested RAM floor is 64 MB. 8 MB is the aim; do not describe it as tested.
- Preserve proven code and its tests; test first, then port, and don't redesign. A node ports the
  predecessor's tests first (harness and path adjustments only), adds tests for uncovered criteria,
  establishes RED, then ports only the code those tests need (SPEC §2.2). Predecessor recipes,
  scripts and tests carry over unchanged unless a node spec lists the change.
- Use Portage and standard tools. Custom code only where SPEC §5 names a gap.
- Make is the interface (SPEC §7): operations are Make targets backed by `scripts/`, and workflows only
  call them. A workflow that can trigger passes `toolbox/ci lint`: each `run:` command is
  `make <target>`, or `toolbox/run -- <cmd>` for a step that is not a test, values reach `run:` through `env:`, and tools come
  from the toolbox, never `apt-get` or `setup-*`. Put logic in `scripts/`, not YAML.
- Provenance lives in `docs/migration.tsv` and Git history, not in source files: no "ported from"
  comments. A porting commit names the predecessor paths it lands; `scripts/check-migration.py` checks
  the ledger.
- MS1, a working ISO for iteration, comes first. Do not add work to its path; SPEC §10 lists the concerns
  tracked outside it.

## Editing the spec

- Change `docs/graph.yaml` first. A node's header row (track, deps, unlocks) must match it.
- Acceptance criteria are `<ID>-AC-<n>`, each with *Verify*. Open decisions are `OD-<n>`,
  numbered without gaps.
- Write specs, README, plan and PR descriptions as the current state, with no revision history ("v0.3
  had…", "withdrawn"). Change notes go in commit messages and `docs/reviews/`.
- Describe the project by what it is (`MYTH.md`), not as "a small Gentoo derivative".
- Branches and PRs: SPEC §11.

## Don't touch

- `docs/study/`: the frozen study of the predecessor.
- `docs/reviews/`: dated history. Append; don't edit old entries or link to them from reader-facing docs.
- The predecessor repository: never rename it (rc1's attestation names it) and don't push to it. X01
  archives it.
- The rc1 builder image and binary packages on GHCR: copy by digest, never retag or delete.

## Git conventions

Preserve existing history and attribution. Don't rewrite historical commits for cosmetic reasons. Use
the configured Git identity for new commits. AI assistance may be noted in commit messages or PR
descriptions, but doesn't require special attribution machinery.
