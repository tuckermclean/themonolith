# F02 — graph-and-spec-tooling

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| F | F01 | F05 | — (feeds MS3) | M |

**Owns:** `tools/graph/graph-check.py`, `tools/graph/non-node-tokens.txt`, `docs/status.yaml` (SPEC §4.2), `tests/fast/graph-*.test.sh`, `tests/fast/fixtures/graph/`, the `graph-check` Make target
**Carries from linux-live-iso-factory@b9f533b:** nothing
**Study refs:** none of the T-* or D-* ids. Motivated by the drift the study found between prose and facts (workflows.yaml contradictions: stale `workflow_call` comments, wrong "current status" in `AGENTS.md`, package counts of 99 / 71 / 65 in README, version-pinning.md and RELEASE-READINESS). A node spec that names a missing node, a typo'd trap id or a wrong dependency is the same class of rot.

## Purpose
After F02, `docs/graph.yaml`, `SPEC.md` and every `nodes/*.md` are checked mechanically: the graph is a valid acyclic DAG whose `track` field is consistent with the path to P02, every node has a spec in the exact SPEC §9 shape, header tables agree with the graph, and acceptance criteria are well-formed with unique ids. The /node loop (F05) reads criteria through this tool instead of copying text by hand, so the criteria an agent builds against are byte-for-byte the criteria a human reviewed.

## Scope
In:
- `tools/graph/graph-check.py`: validator, plus the read modes `--dump-node` and `--ready` used by F05.
- Fast tests with good and bad fixture trees.
- A `graph-check` Make target, added to `make check`.

Out:
- Whether a node's gate has passed: the owner or the node's PR sets its entry in `docs/status.yaml`. F02 creates the file and reads it for `--ready`; F05's orchestrator writes entries.
- Running the trusted-base copy of the checker on PRs: F04 (`make trusted-check`). F02 only guarantees `--root` works.
- Checking that the `Verify:` paths of ACs exist: they do not exist before RED, so it cannot be checked at spec time. Each node's own RED/GREEN covers it (F04).
- Inventory of this tool as a system part: F03.
- Editing SPEC or the graph: protected paths; the tool only reads them.

## Design

### Command line
`python3 -I tools/graph/graph-check.py [--root DIR] [--json] [--strict]`. Host-side Python 3, standard library plus PyYAML (SPEC §4.3, OD-3). Offline, deterministic, no clock, under 2 s on the real tree. `--root` defaults to the git top level, so F04 can run base code on the PR tree.

Output: one line per finding, `path:line: CODE: message`, sorted by path then line. `--json` prints the findings as a JSON array. Exit 0 = no errors; 1 = findings; 2 = usage or I/O error (missing `--root`, unreadable file, PyYAML missing). Warnings are printed with code prefix `WARN_` and do not change the exit code unless `--strict`.

### Read modes
- `--dump-node ID` prints JSON `{id, name, phase, track, deps, unlocks, milestone, size, decisions, acs: [{id, text, verify, tier, when, withdrawn}]}` for one node, with `text` exactly as written in the spec (the full AC line). `when` is the milestone id from `*When:* after MS<n>` or null. Withdrawn ACs are listed with `withdrawn: true` and null `verify`, `tier` and `when`. Unknown id: exit 2.
- `--ready STATUS_FILE` prints, one per line, the ids whose deps are all `done` or `partial` in STATUS_FILE (a YAML mapping `nodes: {ID: {status: done|partial|in-progress}}`), that have no status of their own, and whose `decisions` (if any) are all settled. A decision is settled when `docs/decisions/` holds a file whose first lines include `Resolves: OD-n`. Order: all `critical` nodes, then `parallel`, then `deferred`; graph order inside a track (SPEC §11).
- Status values: `done` (every AC passed), `partial` (merged, but an AC marked `*When:* after MS<n>` has not passed yet; it satisfies dependents like `done`), `in-progress`. The checker rejects any other value and any id that is not a node (`STATUS_VALUE`).
- There is no phase or milestone rule in `--ready`: any node whose deps are done may start (SPEC §11). The agent loop (F05) is not a gate.

### Graph checks (`docs/graph.yaml`)
- `GRAPH_SCHEMA`: `apiVersion: themonolith/v1`, `kind: DependencyGraph`, `milestones` and `nodes` lists present. Node keys limited to `id phase track name deps summary decisions` (`decisions` is a list). Milestone keys limited to `id name after meaning`.
- `GRAPH_ID`: node id matches `^[FIRBOSPMGX][0-9]{2}$`; its first letter equals `phase`; ids unique; names match `^[a-z0-9]+(-[a-z0-9]+)*$` and are unique; `summary` non-empty.
- `GRAPH_DEP_MISSING`, `GRAPH_SELF_DEP`, `GRAPH_DEP_DUP`: deps name existing, distinct nodes other than self.
- `GRAPH_CYCLE`: the DAG is acyclic. The message prints one cycle, `A -> B -> C -> A`. Algorithm: Kahn's, then DFS on the remainder to name a cycle. Rejected: a single "graph has a cycle" message (useless to fix).
- `GRAPH_MILESTONE`: milestone ids match `^MS[0-9]+$` and are unique; every `after` entry is an existing node; `after` is non-empty. `WARN_MILESTONE_MULTI`: a node listed in more than one milestone.
- `GRAPH_TRACK`: every node has `track`, with value `critical`, `parallel` or `deferred`. The set of `critical` nodes equals exactly the ancestors of P02 (its transitive deps) plus P02 itself. The message names the nodes missing from or extra in the set. Rejected: trusting the field and checking nothing, because a stale `track` silently misorders the work.
- `GRAPH_DECISION`: every `decisions:` entry exists as an `OD-n` row in SPEC §10.
- `GRAPH_PHASE_ORDER` (warning): a dep in a later phase than the node, with F, I, R, B, O, S, P, M, G, X as the phase order. Graph edges legitimately go backwards (R02 depends on I03), so this is only advisory.

### Spec-file checks (`nodes/*.md`)
- `SPEC_MISSING`: every graph node has `nodes/<ID>-<name>.md`. `SPEC_ORPHAN`: every file in `nodes/` maps to a node, and names match `<ID>-<name>.md` with name equal to the graph's name.
- `SPEC_HEADINGS`: the file has, in this exact order and with no other `#`/`##` headings between them: `# <ID> — <name>`, then the header table, then the three bold lines `**Owns:**`, `**Carries from linux-live-iso-factory@b9f533b:**`, `**Study refs:**`, then `## Purpose`, `## Scope`, `## Design`, `## Traps and doctrines preserved`, `## Gate`, `## RED plan`, `## Risks and open questions`, `## Cost`, and optionally a final `## Spec defects found`. The em dash in the title is U+2014. Headings inside fenced code blocks are ignored.
- `SPEC_TABLE`: the table has the header `| Phase | Deps | Unlocks | Milestone | Size |` and one data row. Phase equals the graph's. Deps equals the graph's deps as a comma-separated set, or `none`. Unlocks equals the computed set of nodes whose deps include this node (`none` when empty; a trailing parenthetical note is allowed). Milestone equals the milestone whose `after` contains the node, else `—`. Size is `S`, `M` or `L`. The check parses ids, not prose.
- `SPEC_SCOPE`: the `## Scope` section contains lines beginning `In:` and `Out:`.
- `SPEC_GATE_EMPTY`: the Gate section has at least one AC.
- `WARN_AC_COUNT`: fewer than 3 or more than 30 ACs.
- `WARN_SIZE`: size `S` with more than 8 ACs, or `L` with fewer than 9.

### Acceptance-criterion checks
A live AC line in the Gate section matches `^- \*\*(<ID>)-AC-(\d+)\*\* — (.+)$`, and the text must contain `*Verify:*` followed by non-empty text and `*Tier:*` followed by `fast` or `slow`, in that order. A live AC may end with `*When:* after MS<n>`, written after the Tier. A withdrawn AC has exactly the form `- **<ID>-AC-<n>** — *Withdrawn (v0.3):* <reason>.` (SPEC §9); it needs no Verify or Tier.
- `AC_WHEN`: a `*When:*` marker that is not `after MS<n>`, names a milestone that is not in the graph, or is not the last element of the line.
- `AC_WITHDRAWN`: a line that starts `*Withdrawn` but does not match the SPEC §9 form (version tag, non-empty reason, final full stop). Withdrawn ACs keep their number for `AC_DUP` and `AC_ORDER` and do not count toward `WARN_AC_COUNT` or `WARN_SIZE`.
- `AC_FORMAT`: a Gate list item that is neither a live AC nor a withdrawn AC, or a live AC that lacks Verify or a valid Tier.
- `AC_PREFIX`: the id prefix equals the file's node id.
- `AC_DUP`: duplicate numbers. `AC_ORDER`: numbers must ascend in file order. Gaps are allowed, because ids are never reused after a criterion is retired (SPEC §9).
- `AC_VERIFY_PATH`: when a Verify names a path starting `tests/fast/` or `oracle/`, it must be a relative path without `..`; the file is not required to exist yet.
- `AC_TIER_VERIFY` (warning): a `fast` AC whose Verify names no `tests/fast/` path and no `make` target.

### Cross-reference checks
- `REF_NODE`: every token matching `\b[FIRBOSPMGX][0-9]{2}\b` in SPEC.md and in `nodes/*.md` (excluding fenced code and the tokens in `tools/graph/non-node-tokens.txt`, which ships with `X11`) must be an existing node id. This catches `Out:` lines that name a node that does not exist.
- `REF_OD`: every `OD-n` token exists in SPEC §10.
- `REF_STUDY`: every `T-*` and `D-*` id (regex `\b[TD]-[a-z0-9][a-z0-9-]*\b`) in a node spec exists in `docs/study/doctrine.yaml`. SPEC §3's `D-*` ids must also all exist there, except those in a short `SPEC-only` list inside the tool (empty at start). `D-s3-publish-only` appears in the study but not in the SPEC table; that is allowed (study is a superset).
- `REF_SPEC_ENFORCER`: node ids in the "Enforced by" column of SPEC §3 exist.
- `REF_DEFECT_SECTION`: if any `## Spec defects found` section exists it is the last section and non-empty.

### Make integration
`make graph-check` runs the checker on the working tree; `make check` includes it. `tests/fast/graph-realtree.test.sh` runs the checker on the real repository, so a bad edit to the graph or any node spec fails the fast tier. Rejected: a separate CI job for the real tree (the fast tier already runs it).

## Traps and doctrines preserved
No product trap applies. The process failures prevented:
- Dependency typos and cycles making the loop deadlock or skip prerequisites: F02-AC-1 to F02-AC-3.
- Criteria copied wrongly into briefs: F02-AC-9 (`--dump-node` is byte-exact), consumed by F05.
- A node spec citing a non-existent trap or doctrine, so the "traps are preserved by a named AC" rule silently rots: F02-AC-8.
- SPEC §9 template drift ("F02 validates the headings"): F02-AC-4 to F02-AC-6.

## Gate
- **F02-AC-1** — On a fixture graph with a duplicate id, a bad id shape, a phase letter that does not match the id, or a missing `summary`, the checker exits 1 and prints `GRAPH_ID` or `GRAPH_SCHEMA` with the offending line. *Verify:* `tests/fast/graph-schema.test.sh` with `tests/fast/fixtures/graph/bad-*`. *Tier:* fast.
- **F02-AC-2** — A dep that names a missing node, itself, or a duplicate is reported (`GRAPH_DEP_MISSING`, `GRAPH_SELF_DEP`, `GRAPH_DEP_DUP`). *Verify:* `tests/fast/graph-deps.test.sh`. *Tier:* fast.
- **F02-AC-3** — A cycle of two or more nodes is reported as `GRAPH_CYCLE` and the message lists the cycle path; an acyclic fixture passes. *Verify:* `tests/fast/graph-cycle.test.sh`. *Tier:* fast.
- **F02-AC-4** — A graph node with no spec file is `SPEC_MISSING`; a file in `nodes/` that maps to no node, or whose name differs from the graph's, is `SPEC_ORPHAN`. *Verify:* `tests/fast/graph-specfiles.test.sh`. *Tier:* fast.
- **F02-AC-5** — Missing, misordered, renamed or extra top-level headings in a node spec yield `SPEC_HEADINGS`; headings inside code fences are ignored; the optional final `## Spec defects found` is accepted. *Verify:* `tests/fast/graph-headings.test.sh`. *Tier:* fast.
- **F02-AC-6** — The header table is checked against the graph: wrong phase, deps, computed unlocks, milestone or size yields `SPEC_TABLE`; correct tables pass. *Verify:* `tests/fast/graph-table.test.sh`. *Tier:* fast.
- **F02-AC-7** — AC lines are validated: bad shape, missing Verify, tier not `fast`/`slow`, wrong node prefix, duplicate or descending numbers are errors; gaps are accepted. *Verify:* `tests/fast/graph-ac.test.sh`. *Tier:* fast.
- **F02-AC-8** — Unknown node ids, `OD-n`, `T-*` and `D-*` ids in specs and SPEC.md are reported (`REF_NODE`, `REF_OD`, `REF_STUDY`); tokens in `non-node-tokens.txt` and inside code fences are ignored. *Verify:* `tests/fast/graph-refs.test.sh`. *Tier:* fast.
- **F02-AC-9** — `--dump-node F02` on the real tree prints JSON whose `acs[].text` equals the spec's AC lines byte for byte and whose `unlocks` and `milestone` equal the computed values; an unknown id exits 2. *Verify:* `tests/fast/graph-dump.test.sh`. *Tier:* fast.
- **F02-AC-10** — `--ready STATUS` lists exactly the nodes whose deps are all done, excluding done and in-progress nodes and nodes with any `decisions` entry lacking a `Resolves: OD-n` record. *Verify:* `tests/fast/graph-ready.test.sh`. *Tier:* fast.
- **F02-AC-11** — The checker exits 0 on the real repository (graph, SPEC, all specs), is deterministic (two runs byte-identical), finishes in under 2 s, honours `--root`, and uses exit 2 for unreadable input. *Verify:* `tests/fast/graph-realtree.test.sh`. *Tier:* fast.
- **F02-AC-12** — `make graph-check` exists, is part of `make check`, and warnings do not fail the build unless `--strict`. *Verify:* `tests/fast/graph-make.test.sh`. *Tier:* fast.
- **F02-AC-13** — `GRAPH_TRACK` rejects a node with no `track` or a value other than `critical|parallel|deferred`, and rejects a `critical` set that differs from the ancestors of P02 plus P02 (a critical node that is not an ancestor, an ancestor marked `parallel`, and P02 itself marked `deferred` each fail with the node named); the real graph passes. *Verify:* `tests/fast/graph-track.test.sh`. *Tier:* fast.
- **F02-AC-14** — `AC_WHEN` accepts `*Tier:* slow. *When:* after MS2` and rejects `after MS9` (no such milestone), `after MS2` before the Tier, and free text; `AC_WITHDRAWN` accepts the SPEC §9 withdrawn form and rejects a missing reason or version tag; a withdrawn AC keeps its number against `AC_DUP` and `AC_ORDER`. *Verify:* `tests/fast/graph-ac-when.test.sh`. *Tier:* fast.
- **F02-AC-15** — `--ready STATUS` lists ready nodes ordered `critical`, then `parallel`, then `deferred`, graph order within a track; treats `partial` as satisfying dependents but does not list a `partial` node; applies no phase or milestone rule (a non-F node whose deps are done is listed before F05 is done); an unknown status value is `STATUS_VALUE`. *Verify:* `tests/fast/graph-ready-order.test.sh`. *Tier:* fast.

## RED plan
The tester writes `tests/fast/graph-*.test.sh` and the fixture trees under `tests/fast/fixtures/graph/` first. Each test builds an arguments list, runs `python3 -I tools/graph/graph-check.py --root <fixture>`, and asserts exit code and a substring of the finding line. Before implementation `tools/graph/graph-check.py` does not exist, so the call exits 2 or 127, which `t_assert_exit` reports as an assertion failure (RED valid; no stub file is allowed). Slices: (1) graph checks, AC-1 to AC-3; (2) spec files and headings, AC-4 to AC-6; (3) ACs and references, AC-7, AC-8; (4) read modes and real tree, AC-9 to AC-12; (5) track, `When` and `--ready` order, AC-13 to AC-15. `tests/fast/graph-realtree.test.sh` is written last because it needs the other specs to be valid.

## Risks and open questions
- The real tree is edited by many parallel authors writing specs; a `REF_NODE` false positive on an ordinary word (for example a hex fragment like `B01` inside a hash) breaks the fast tier. The token must be a whole word and the ignore list is explicit. Protected: the list file is under `tools/`.
- Unlocks parsing allows a trailing parenthetical; if specs start writing prose there, the check must stay strict on ids only.
- Whether `Verify:` text should be required to name a runnable command is deliberately not enforced; a free-form description would pass. F05's reviewer checks real coverage.
- F05 will want AC text with Markdown inside backticks containing `|` or `—`; the AC regex uses the first ` — ` after the id.

## Cost
Five slices, 15 ACs, all fast tier. No CI build cycles; one fast-lane run per slice. No money.

## Spec defects found
- SPEC §9 does not list `## Spec defects found
- SPEC §9 mentions `## Spec defects found` only in prose after the template. F02 accepts it as an optional last section; the template block could show it.
- Unlocks is a derived column; SPEC §9 says F02 regenerates it. F02 as specified only checks it (`SPEC_TABLE`). Regenerating needs a `--fix-tables` mode, which is not in scope here.
- SPEC §11 does not say whether a `partial` node satisfies its dependents. F02 treats it as satisfying them, since the unfinished AC is off the path by definition. Owner to confirm.
