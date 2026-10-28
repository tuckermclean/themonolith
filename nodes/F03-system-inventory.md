# F03 — system-inventory

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| F | F01 | B06, I05 | — (feeds MS1) | M |

**Owns:** `docs/system.yaml`, `tools/system/system-check.py`, `tools/system/rules.yaml`, `tools/system/convert-study.py`, `tests/fast/system-*.test.sh`, `tests/fast/fixtures/system/`, the `system-check` Make target
**Carries from linux-live-iso-factory@b9f533b:** nothing as code. The seed is `docs/study/inventory.yaml` (125 components, id scheme from the study BRIEF), converted mechanically by `tools/system/convert-study.py`.
**Study refs:** inventory.yaml `components` (kinds: job 32, make-target 32, script 25, web 14, config 11, workflow 10, dockerfile-stage 1), `secrets_inventory` and `pins_summary` in workflows.yaml, every `ext.*` and `secret.*` id used there, contradictions about undocumented or orphaned parts (nightly CVE monitor "not wired into any scheduled job" but wired; `release.yml` called via `workflow_call` but not; `cve-gate.md` naming a `make grype-db-update` target nobody confirms), Principle 3.

## Purpose
After F03, `docs/system.yaml` lists every moving part of the factory with an owner, inputs and outputs, and CI fails when reality and the list diverge in either direction. The predecessor's parts were invisible until the study reconstructed them: an orphaned-looking nightly job that was in fact scheduled, `AWS_*` secrets read in five jobs, and a storage vendor hard-wired everywhere. The next time a script reads a new secret or fetches from a new host, the PR must say so in this file.

## Scope
In:
- The schema of `docs/system.yaml` and its validator.
- Discovery of workflows, jobs, scripts, make targets, secrets, external hosts and store classes, and the comparison against the declared set.
- A converter from `docs/study/inventory.yaml` to the schema, used once to seed the file and kept as a coverage test.
- The initial `docs/system.yaml`, listing the parts that exist at F03's merge.
- A `system-check` Make target, added to `make check`.

Out:
- Pins and versions (`pins:` in the study): I05's ledger. Evidence (`path:line`), notes and `s3_coupling` fields are study material and are dropped.
- Running the checker from the trusted base on PRs: F04. F03 guarantees `--root`.
- Keeping the file current as later nodes land: each node's PR updates `docs/system.yaml` for its own parts; the check enforces it. There is no separate owner.
- Inventorying recipes (ebuilds, patches, rootfs files): R01/R05 own those, and the unowned-files gate (S04) covers rootfs content. Tests are not parts either; `tests/fast/` is enumerated by its runner.
- Store-vendor lint (no provider CLI outside backends): F06.

## Design

### File format
`docs/system.yaml`:

```yaml
apiVersion: themonolith/v1
kind: SystemInventory
externals:                       # one entry per external service
  - id: ext.github-api
    purpose: "Releases, attestations, PR API"
    hosts: [api.github.com, github.com]    # exact names, or a leading "*." wildcard
    owner: F01
parts:
  - id: wf.verify                # <prefix>.<name>
    kind: workflow
    path: .github/workflows/verify.yml
    owner: F01                   # a node id from docs/graph.yaml, or "human"
    purpose: "Fast lane: lint and fast tests on every PR"
    triggers: [pull_request, push]
    invokes: [make.lint, make.test-fast]
    inputs:  [{what: "repository checkout", ref: "-"}]
    outputs: [{what: "out/test-fast/results.tsv artifact", ref: "-"}]
    secrets: []
    external: [ext.github-api]
    store: {reads: [], writes: []}
    env: []
```

Kinds and id prefixes: `workflow wf.<file-stem>`; `job job.<wf-stem>.<job-key>`; `script script.<basename-without-extension>`; `make-target make.<target>`; `secret secret.<NAME>`; `external ext.<service>` (in the `externals` list, not `parts`); `store-class store.<class>`; `config cfg.<name>`; `web web.<name>`; `image-stage image.<name>`; `agent agent.<name>`; `skill skill.<name>`.

Required keys per kind. All parts: `id kind owner purpose`; `purpose` is one line of at most 140 characters and must not be empty or contain `TODO`. Parts with a file: `path` (must exist; no `:line` suffix). Workflow, job, script, make-target: also `inputs`, `outputs` (lists, possibly empty, but present), `secrets`, `external`, `store` (`reads`/`writes` lists of `store.*` ids). Workflow: `triggers`. Job: `needs` (job ids). `invokes` and `env` optional. An input or output is `{what: <text>, ref: <id or "-">}`; `ref`, when not `-`, must resolve.

Rejected: keeping the study's free-text `from:`/`to:` strings (cannot be validated), and keeping `evidence:` and `notes:` (stale on the first edit).

### Discovery (what the check finds on its own)
All discovery reads tracked files (`git ls-files`, or a directory walk when `.git` is absent, for fixtures), sorted, offline.
- **Workflows and jobs.** `.github/workflows/*.yml|*.yaml` give `wf.<stem>`; each key under `jobs:` gives `job.<stem>.<key>`. Per job and workflow, the set of `secrets.NAME` and `vars.NAME` references (regex `\b(secrets|vars)\.([A-Za-z_][A-Za-z0-9_]*)`) must equal the declared `secrets`. `secrets: inherit` or a bare `${{ toJSON(secrets) }}` is `SYS_SECRETS_OPAQUE`: it cannot be enumerated and is forbidden. `GITHUB_TOKEN` is declared like any other secret. Job `needs:` and workflow-call `uses: ./.github/workflows/x.yml` must equal declared `needs` and `invokes`.
- **Make targets.** Targets from the Makefile and any `*.mk` it includes: lines at column 0 matching `^([A-Za-z0-9][A-Za-z0-9_.-]*)\s*:` that are not variable assignments (`:=`, `::=`), not pattern rules (`%`), and not special targets (leading `.`). Targets named with a leading `_` are private and ignored. `make <target>` in a workflow `run:` or a script gives the `invokes` edge for workflows, jobs and scripts. Rejected: parsing `make -pn` output (format varies across make versions) — so generated targets (via `$(foreach)`/`eval`) are unsupported and the lint rule `make-docs` from F01 pushes authors to write targets explicitly.
- **Scripts.** Tracked files under `factory/`, `oracle/`, `supplychain/`, `tools/`, `.claude/hooks/`, `image/`, and any file elsewhere with an executable bit or a `#!` line, excluding `tests/`. The id is `script.<basename without extension>`. Two scripts with the same basename are `SYS_ID_COLLISION`; rename one. Rejected: path-derived ids, which would make the study's `script.*` ids unconvertible and the names unreadable.
- **Agents and skills.** `.claude/agents/<name>.md` gives `agent.<name>`; `.claude/skills/<name>/SKILL.md` gives `skill.<name>`.
- **Secrets.** Every distinct secret or var name found anywhere gets a `secret.<NAME>` part (`kind: secret`, `owner`, `purpose`, and `used_by` is derived, not declared). A declared secret nobody uses is `SYS_STALE`.
- **External hosts.** Hostnames in `https?://` and `ssh://`/`git://` URLs, and registry names (`ghcr.io`, `docker.io`, `quay.io`) appearing in tracked files of: workflows, `Makefile`, `factory/`, `oracle/`, `supplychain/`, `tools/`, `image/`, `recipes/portage/`, `web/` (excluding `web/vendor/**`, pinned by I05). Excluded: `docs/`, `nodes/`, `tests/`, `SPEC.md`, `README.md`, `AGENTS.md`, `.claude/`, and hosts in `tools/system/rules.yaml: ignore_hosts` (ships with `localhost`, `127.0.0.1`, `0.0.0.0`, `example.invalid`, `www.w3.org`, `json-schema.org`). Each host must match a `hosts` entry of some `externals[]`. The per-part `external` list must contain the external ids of the hosts found in that part's file (for jobs: the job's lines; for workflows: the lines outside any job). Ebuild `SRC_URI` hosts are R01/I04's concern (the study's `ext.git-*` open end).
- **Store classes.** The five SPEC §5 classes must each exist as `store.<class>` with an `owner` and a `retention` string. In scripts and workflow `run:` blocks the pattern `store\s+(put|get|has|ls|url)\s+(snapshot|distfile|binpkg|build|public)` gives the classes touched; `put` is a write; `get`, `has`, `ls`, `url` are reads. These must equal the declared `store.reads` and `store.writes` of the part. An unknown class name is `SYS_STORE_CLASS`.
- **Extension.** `tools/system/rules.yaml` may add `discover:` rules (kind, glob, id template, for example `cfg.{stem}` for `supplychain/policy/*.yaml`). A discover rule makes completeness mandatory for that glob. The rules file lives with the checker, not in `docs/system.yaml`, on purpose: F04 runs the checker and its rules from the PR's base revision, so a PR cannot widen `ignore_hosts` to hide a new host. `config`, `web`, `image-stage` parts without a discover rule are declared-only: the path must exist but unlisted files are not an error.

### Findings
`path:line: CODE: message`, sorted; `--json` prints an array. Exit 0 clean, 1 findings, 2 usage or unreadable input. Codes: `SYS_SCHEMA`, `SYS_ID_PREFIX`, `SYS_ID_DUP`, `SYS_ID_COLLISION`, `SYS_UNLISTED` (discovered, not declared), `SYS_STALE` (declared, no longer discovered or path missing), `SYS_OWNER` (not a graph node or `human`), `SYS_REF` (an `invokes`, `needs`, `ref`, `external` or `store` id does not resolve), `SYS_MISMATCH` (declared secret/external/store/needs set differs from discovered; the message shows both sets), `SYS_SECRETS_OPAQUE`, `SYS_STORE_CLASS`, `SYS_PURPOSE`. `--suggest` prints YAML stubs for every `SYS_UNLISTED` item with `owner: TODO` and `purpose: TODO`; because `TODO` fails `SYS_PURPOSE`, a pasted stub cannot pass without being filled in.

### Converter and seed
`tools/system/convert-study.py docs/study/inventory.yaml` writes a schema-valid draft to stdout. Rules, chosen so the 125 components convert without hand edits:
- Keep `id`, `kind` (`dockerfile-stage` becomes `image-stage`), `purpose` (first line, truncated to 140 characters), `triggers` (strings reduced to the event name before any space), `invokes`, `needs`.
- `path`: strip a trailing `:<digits>` (jobs carry `build.yml:559`).
- `inputs`/`outputs`: a dict entry gives `what` and `ref` (the first whitespace-separated token of `from`/`to` when it is a known-prefix id, else `-`). A bare string entry (one exists) gives `what` with `ref: -`.
- `secrets`: only entries that match `secret.<NAME>`; other free text ("AWS credentials (ambient)") is dropped and listed in the converter's stderr report. `external`: only `ext.*` entries.
- Dropped: `evidence`, `notes`, `rebuild_notes`, `s3_coupling*`, `pins`, `permissions`, `runner`, `timeout`, `commands`, `docker_flags`, `if`, `invoked_by` (derived), `artifacts`, `caches`, `ci_assertions`, and the rest.
- `owner` is `TODO`; the converter cannot know the new node. The seed `docs/system.yaml` therefore contains only parts that exist in this repo at merge (the old ids do not: no old workflows exist here), and the old inventory is used as a coverage test and as a checklist for B06, I01 and the S-nodes, which reuse its ids where the part survives.
The AWS-bound ids (`secret.AWS_*`, `ext.aws-s3`) are converted but never carried into `docs/system.yaml` (nothing here uses them), which also proves the check rejects stale entries.

### Initial content
At F03's merge: `wf.verify` and its job, F01's Make targets and scripts under `tools/`, F02's and F03's tools if landed, the five `store.*` classes (retention strings copied from SPEC §5; backends come with F06 and I01), `ext.github-api` and the hosts F01's fetcher uses, `secret.GITHUB_TOKEN` only if referenced. Merge order is set by CI: whichever of F02, F03, F04, F06 merges later adds its parts, because the check fails until it does.

## Traps and doctrines preserved
- Principle 3 (the system is inventoried): F03-AC-2 to F03-AC-6.
- Hard-wired storage vendor (five jobs, 24 hard-coupled components in the study): the store-class discovery makes any `store` use visible and keeps vendor hosts as explicit `externals`; absence of a vendor host outside the backend directory is enforced by F06-AC-11.
- Unlisted secrets (`AWS_*` in 5 jobs, `secret.S3_BUCKET` as a var): F03-AC-4.
- Orphan/ghost parts (nightly CVE job believed dead, `release.yml` believed to be `workflow_call`): F03-AC-2 (jobs and `invokes` come from the YAML), F03-AC-7 (stale entries fail).
- Floating externals: every new host needs an `externals` entry, a review-visible diff (F03-AC-5).
- Trust (SPEC §8): a PR must not widen the checker's own ignore lists: F03-AC-9.

## Gate
- **F03-AC-1** — `docs/system.yaml` validates against the schema: required keys per kind, id prefix matches kind, ids unique, `purpose` one line of at most 140 characters with no `TODO`, `path` exists, `owner` is a node id in `docs/graph.yaml` or `human`. *Verify:* `tests/fast/system-schema.test.sh` (good and bad fixtures). *Tier:* fast.
- **F03-AC-2** — Every workflow file and every job key under it is discovered; an undeclared one is `SYS_UNLISTED`; a declared one whose file or job is gone is `SYS_STALE`; declared `needs`/`invokes` must equal the YAML's `needs:` and local `uses:`. *Verify:* `tests/fast/system-workflows.test.sh`. *Tier:* fast.
- **F03-AC-3** — Make targets (explicit, non-pattern, non-special, non-private) are discovered from the Makefile and included `*.mk`; undeclared targets are `SYS_UNLISTED`. Scripts under the discovery directories are discovered; duplicate basenames are `SYS_ID_COLLISION`. *Verify:* `tests/fast/system-targets-scripts.test.sh`. *Tier:* fast.
- **F03-AC-4** — Every `secrets.X`/`vars.X` reference is a declared `secret.X`, the per-job and per-workflow declared set equals the discovered set (`SYS_MISMATCH` otherwise), and `secrets: inherit` is `SYS_SECRETS_OPAQUE`. *Verify:* `tests/fast/system-secrets.test.sh`. *Tier:* fast.
- **F03-AC-5** — Every host in URLs in the covered files maps to an `externals[].hosts` entry (exact or `*.` wildcard); excluded paths and `ignore_hosts` are skipped; the part's `external` list equals the externals found in it. *Verify:* `tests/fast/system-externals.test.sh`. *Tier:* fast.
- **F03-AC-6** — The five SPEC §5 classes exist as `store.*` parts; `store put|get|has|ls|url <class>` uses are mapped to the declared `store.reads`/`store.writes`; an unknown class is `SYS_STORE_CLASS`. *Verify:* `tests/fast/system-store.test.sh`. *Tier:* fast.
- **F03-AC-7** — `tools/system/convert-study.py` converts all 125 components of `docs/study/inventory.yaml` without error; the output validates against the schema (path existence waived with `--no-fs`); the stderr report lists every dropped free-text secret/external entry. *Verify:* `tests/fast/system-convert.test.sh`. *Tier:* fast.
- **F03-AC-8** — `--suggest` prints a stub for each unlisted part, and a stub pasted unchanged fails `SYS_PURPOSE`. *Verify:* `tests/fast/system-suggest.test.sh`. *Tier:* fast.
- **F03-AC-9** — The checker reads `ignore_hosts` and `discover` rules only from `tools/system/rules.yaml` under the checker's own directory, never from the inventory or the scanned root; a fixture that adds `ignore_hosts` inside `docs/system.yaml` is `SYS_SCHEMA`. *Verify:* `tests/fast/system-rules-source.test.sh`. *Tier:* fast.
- **F03-AC-10** — On the real repository the checker exits 0, is byte-deterministic across two runs, finishes in under 3 s, honours `--root`, and exits 2 on unreadable input. *Verify:* `tests/fast/system-realtree.test.sh`. *Tier:* fast.
- **F03-AC-11** — `make system-check` exists and is part of `make check`; the check's own script appears in `docs/system.yaml` as `script.system-check` with owner F03 (self-inventory). *Verify:* `tests/fast/system-make.test.sh`. *Tier:* fast.

## RED plan
Fixtures are tiny trees under `tests/fast/fixtures/system/<case>/` (a Makefile, one workflow, one script, one `system.yaml`), so the tests need no git history. The tester writes each `system-*.test.sh` to run `python3 -I tools/system/system-check.py --root <fixture>` and assert the exit code and a `CODE` substring; with no checker the call fails with 2 or 127, an assertion failure under `t_assert_exit`. Slices: (1) schema and workflows, AC-1, AC-2; (2) targets, scripts, secrets, AC-3, AC-4; (3) externals, store, rules source, AC-5, AC-6, AC-9; (4) converter, suggest, real tree, make, AC-7, AC-8, AC-10, AC-11. The real-tree test is written last and is the only one that depends on the seed `docs/system.yaml`.

## Risks and open questions
- Merge coupling: F02, F03, F04 and F06 are parallel. Whoever merges second must add its parts; accept the rebase cost rather than a second inventory file.
- Regex discovery of URLs will flag hosts inside comments and strings. The cure is an `externals` entry or an `ignore_hosts` line in the checker's rules; both are reviewed.
- `owner` is a node id, which loses meaning after the node is done. Acceptable: "owner" means the node whose spec first built the part.
- Make parsing is regex-based. A `include` of generated `.mk` files is not followed; F01's `make-docs` and this check treat that as unsupported.
- Whether `vars.*` should be their own kind (`var.NAME`) is not decided. Folded into `secret.*` because the study did (`secret.S3_BUCKET`), but `S3_BUCKET` was a variable. Revisit when a non-secret variable appears.

## Cost
Four slices, 11 ACs, all fast tier; the one human step is reviewing the seed file. No CI build cycles. No money.

## Spec defects found
- Nothing in the graph makes later nodes responsible for updating `docs/system.yaml`; the check enforces it, but SPEC §9 should add "updates `docs/system.yaml`" to the Owns line convention, or each node spec's Gate will not mention it.
- SPEC §2 Principle 3 says "CI fails on anything unlisted"; the reverse (listed but gone) is not stated. F03 enforces both.
- The `ext.*` and `secret.*` vocabulary comes from the study BRIEF, not from SPEC. Naming them in SPEC §4.2's `docs/system.yaml` row would stop each node inventing a new scheme.
