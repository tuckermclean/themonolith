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
- Nothing builds yet. `make test` and the build arrive with F01.

## Constraints on every change

- i486, statically linked against musl, cross-compiled with crossdev. No Python and no freetype on the
  disc (SPEC §1, §3).
- The tested RAM floor is 64 MB. 8 MB is the aim; do not describe it as tested.
- Port, don't redesign. Predecessor recipes, scripts and tests carry over unchanged unless a node spec
  lists the change.
- Use Portage and standard tools. Custom code only where SPEC §5 names a gap.
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
