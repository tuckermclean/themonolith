---
name: node
description: Build one Monolith node (docs/graph.yaml, nodes/<ID>-*.md) test-first. Brief, then tester RED, verified RED, implementer GREEN, independent review, slow-tier evidence, and a PR with the criterion → evidence table. Use when asked to implement, build or start a node such as F01 or B01.
argument-hint: "<node-id, e.g. F01> [AC ids to limit the slice]"
---

# /node $ARGUMENTS

You are the **orchestrator**. You never write tests or implementation yourself. You prepare context, dispatch fresh role agents (`monolith-tester`, `monolith-implementer`, `monolith-reviewer`), check their evidence, run the slow tier, push, and open the PR. The owner merges.

Authority: `SPEC.md`, `docs/graph.yaml`, the node spec `nodes/<ID>-<name>.md`, then `AGENTS.md`.

## 0. Preconditions
- The working tree is clean and `main` is current (`git pull`).
- The node is in `docs/graph.yaml`. Each node in its `deps` has a merged PR: `gh pr list --state merged --search "head:node/<dep>-"`. If one is missing, stop and say which.
- Each open decision in the node's `decisions` is settled, or the owner said to take SPEC §10's default. If not, ask.
- `python3 -I .claude/skills/node/check-spec.py` reports `PROBLEMS 0`.
- `toolbox/run -- toolbox-selfcheck` passes.
- Create the branch `node/<ID>-<name>` from `main`.

## 1. Brief
Write `out/node/<ID>/brief.md`. Until F01 adds `out/` to `.gitignore`, add it to `.git/info/exclude`. The brief contains:
- the node id, name, deps and decisions, from the graph;
- **every acceptance criterion in scope, copied verbatim** from the node spec's Gate, with its *Verify* and *Tier*;
- for each criterion, the numbered "Changes from the port" item that produces it, as a pointer;
- the node's rows in `docs/capabilities.md`, and the predecessor files it ports or touches, as `path:line` at `b9f533b` (read them with `git show b9f533b:<path>` after the fetch in `AGENTS.md`), and the `AGENTS.md` traps and doctrines that apply;
- the red-target command form: `toolbox/run -- sh scripts/tests/<name>.test.sh`.

Split a large node into **slices** of 3–8 related criteria. Order them so earlier slices build what later tests need.

## 2. RED (per slice)
Dispatch a **new** `monolith-tester` with the brief path and the slice's criterion IDs. Never resume an old agent.

Verify the handoff yourself:
- `git show --stat <red>` touches only `scripts/tests/**` and fixture paths;
- the red target at `<red>` exits non-zero, and every failure is a test's own `FAIL` line, not a shell error (127, 126, a syntax error);
  the one exception is a predecessor test ported verbatim whose subject is not ported yet: its failure names that missing file (`No such file`), and the node ports that file;
- tests that passed before still pass;
- the subject is `test(<ID>): …` and the message has one `TDD-Red-Target:` trailer.

`already_satisfied`: record it and drop those criteria. `blocked`: go to step 7.

## 3. GREEN
Dispatch a **new** `monolith-implementer` with the brief path, the RED SHA, the red target and the failing tests. Check its handoff:
- the red target passes at head;
- `toolbox/ci run pr-validate` passes: the PR check exactly as CI runs it (before F01: every `scripts/tests/*.sh` under `toolbox/run`);
- if the slice touched a workflow, `toolbox/ci lint` passes;
- `git diff <red>..HEAD -- scripts/tests scripts/fixtures` modifies or deletes no RED test;
- every ported file is the `b9f533b` blob plus the node's numbered changes (`git diff b9f533b:<path> HEAD:<path>`), and the commit that ports it names each source as `path:line` at `b9f533b`.

Retries are bounded: **at most 4 implementer attempts per slice.** Attempts 1–3 use the agent's model. Attempt 4 uses the Agent tool's `model: "opus"` override and gets every earlier finding and failed diff SHA. After that, go to step 7.

## 4. Review
Dispatch a **new** `monolith-reviewer` with the brief path, the base, RED and head SHAs, and the evidence. On `request_changes`, give the findings to a new implementer (the retry budget applies). On `test_spec_conflict`, go to step 7. Never edit tests to satisfy a reviewer: a wrong test means a new RED commit from a new tester, and the owner approves that first.

## 5. Slow tier
For each slow criterion, in this order of preference:
1. **Locally, by running the CI job itself** when it is in a parity workflow: `toolbox/ci run <workflow> <job> [--matrix k=v]`. This is the preferred evidence: the same definition CI runs. Otherwise in the toolbox directly when it needs only an ISO and QEMU, or the predecessor's tools: boot modes (`toolbox/run -- python3 scripts/boot-test.py --iso … --mode … --kernel-version …`), artifact checks, rc1 lanes. Keep the log under `out/node/<ID>/`.
2. **Locally in the builder image** with podman when it needs Portage: package builds and the SBOM gates. Pull the builder by digest (`BUILDER_DIGEST`).
3. **In CI**, when it needs GitHub itself: GHCR pushes, attestations, tag pipelines, `workflow_dispatch` runs. Push, run, and record the run URL.

Record each command, exit code and log path or run URL. A slow criterion without a recorded run is not met. When a criterion ran both locally and in CI, record both; a step that passes in one and fails in the other is a parity bug, so stop and report it (step 7).

## 6. Pull request
Push with `git push -u origin HEAD`. A push that changes `.github/workflows/*` needs a token with the `workflow` scope, and the default `gh` token lacks it. Use a token the owner provides, transiently (the credential rules in `AGENTS.md`), or ask the owner to push the branch.

Open the PR with `gh pr create`. The body has:
- what the node delivers, in two or three sentences;
- the predecessor files ported, each with its `path` at `b9f533b` and the numbered changes applied;
- the criterion → evidence table (SPEC §11): criterion, test or command, where it ran (`toolbox/ci`, toolbox, builder, CI URL), result;
- the RED → GREEN → review SHAs for each slice;
- deviations and open questions.

Give the owner the PR URL. You never approve or merge.

## 7. Stop and ask the owner
Stop for:
- a false unverified claim in the node spec;
- an ambiguous or contradictory criterion;
- a `test_spec_conflict`;
- an exhausted retry budget;
- a needed change to SPEC, a node spec or the graph.

Propose the amendment. Do not continue on a guess. A spec change is the owner's, made on its own branch; run `check-spec.py` after it.

## Cost discipline
- Hand agents file paths and section pointers, not pasted documents.
- One fresh agent per role per attempt. Never resume long transcripts.
- At most 2–3 agents at a time, and only for independent slices.
