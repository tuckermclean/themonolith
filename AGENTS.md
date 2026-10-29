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
  commit.
- `toolbox/` is the test image, `toolbox/run` and the workflow runner `toolbox/ci`; `.claude/` holds the
  `/node` skill, the role agents and the guard hook.
- Nothing builds yet. `make test` and the build arrive with F01.

## Commands

- `toolbox/run -- <cmd>` runs a command in the test toolbox, with the checkout mounted at its own path.
  `toolbox/run` alone opens a shell; `--build` rebuilds the image; `--network none` cuts the network.
  The image rebuilds by itself when `toolbox/` changes.
  `-e NAME` forwards a variable; `CI`, `GITHUB_ACTIONS` and the `GITHUB_OUTPUT`-style files always pass.
- `toolbox/run -- toolbox-selfcheck` checks that every tool is present at its pinned version.
- `toolbox/ci run <workflow> [<job>...]` runs a workflow's jobs locally, as CI runs them. `--event`,
  `--input k=v` and `--matrix k=v` set the trigger, inputs and one matrix combination. The report marks
  each step `ok`, `FAIL`, `skip` or `ci-only`. `toolbox/ci lint` checks the parity rules (SPEC §7).
- `toolbox/ci run pr-validate` is the whole PR check, once F01 has imported it. Run it before pushing.
- `toolbox/run -- sh scripts/tests/<name>.test.sh` runs one fast test; `toolbox/run -- make test` runs the
  fast tier once F01 has imported the Makefile.
- Boot a mode: `toolbox/run -- python3 scripts/boot-test.py --iso <iso> --mode bios --kernel-version
  <version>`. Read the version from the ISO with `xorriso -osirrox on -indev <iso> -extract /boot/vmlinuz
  /tmp/vmlinuz` and `file /tmp/vmlinuz`.
- Package builds and the SBOM gates run in the builder image, with podman, pulled by digest.
- `python3 -I .claude/skills/node/check-spec.py` checks the graph against the node specs; `--write`
  regenerates the header rows.
- `sh .claude/hooks/guard.test.sh` tests the guard hook; `sh toolbox/ci.test.sh` tests `toolbox/ci`.

## Building a node

- Use `/node <ID>`. It writes a brief, has a fresh tester commit failing tests (RED), checks them, has a
  fresh implementer make them pass (GREEN), gets an independent review, runs the slow criteria, and opens
  a PR with the criterion → evidence table.
- Tests come first wherever a criterion has a fast check. A slow criterion is met only by a recorded run:
  a local log or a CI URL.
- Role agents may not edit the spec, `AGENTS.md`, `CLAUDE.md`, `.claude/` or `toolbox/`; the guard hook
  blocks it. Spec changes go to the owner.

## Traps

- **Rootless podman without a systemd user session** fails with "Interactive authentication required".
  `toolbox/run` passes `--cgroup-manager=cgroupfs` in that case; do the same for direct podman calls.
  With cgroupfs, podman also leaves an empty `oom` file in the directory it starts from; `toolbox/run`
  starts it from a state directory. Never commit an `oom` file.
- **QEMU runs in software, here and in CI.** `boot-test.py` uses `-cpu 486`, which only emulation
  enforces, so `toolbox/run` passes no `/dev/kvm`. Boots take about a minute and the first in-guest check
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
- Port, don't redesign. Predecessor recipes, scripts and tests carry over unchanged unless a node spec
  lists the change.
- Use Portage and standard tools. Custom code only where SPEC §5 names a gap.
- CI parity (SPEC §7): a workflow that can trigger passes `toolbox/ci lint`. Each `run:` command is
  `toolbox/run -- <cmd>` or a builder `make` target, values reach `run:` through `env:`, and tools come
  from the toolbox, never `apt-get` or `setup-*`. Put logic in `scripts/`, not YAML.
- MS1, a working ISO for iteration, comes first. Do not add work to its path; SPEC §10 lists the concerns
  tracked outside it.

## Editing the spec

- Change `docs/graph.yaml` first. A node's header row (track, deps, unlocks) must match it.
- Acceptance criteria are `<ID>-AC-<n>`, each with *Verify* and *Tier*. Open decisions are `OD-<n>`,
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
