# Study brief: The Monolith rebuild (read this first)

## Context
Repo under study: `/home/debian/gitrepos/linux-live-iso-factory` (git, branch master, HEAD b9f533b).
It builds "The Monolith": one live ISO for i486 → modern UEFI, Gentoo crossdev, musl, all-static,
with an SLSA/SBOM/CVE-gated supply chain. Read `AGENTS.md` (design doctrines) and skim `README.md`
before your area.

The owner is rebuilding the **factory** (workflows, scripts, Makefile, Dockerfile) from first
principles in a new repo, carrying the **recipes** (overlay ebuilds, portage config, kernel config,
rootfs files) forward, and using the **tests** (boot-test modes, scripts/tests, CI assertions) as
the acceptance oracle. The AWS account behind S3 is disabled, so everything S3-touching is dead
today — record those dependencies precisely; they must be redesigned.

Your job is a **precise, evidence-backed inventory** of one area. It becomes the spec for the
rebuild, so completeness and accuracy beat prose. Do not propose the new design beyond the
`rebuild_notes` fields.

## Rules
- **Read-only.** Do not edit, commit, push, or run builds/docker/network. Running `scripts/tests/*`
  or grep/sed/awk is fine. No `gh` writes.
- Read the files in your scope **in full**, not excerpts. Cite evidence as `path:line`.
- When docs and code disagree, the code is the fact; record the disagreement in `contradictions`.
- Unknown = say unknown. Never guess a value.
- Write ONE output file: `/tmp/claude-1000/-home-debian-gitrepos-linux-live-iso-factory/7aa133ca-4c16-4951-9ede-3a623cc44b92/scratchpad/study/<area>.yaml`
  (your area name is given in your prompt). Valid YAML. Check it parses:
  `ruby -ryaml -e 'YAML.load_file(ARGV[0])' FILE` or `python3 -I -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' FILE`
  (whichever exists; if neither, be careful by hand).
- Final message (your handoff): ≤ 25 lines — counts, the 5 most important findings, and anything
  you could not determine. The detail lives in the file.

## Shared ids (so outputs can be merged)
Use these id prefixes exactly; refer to other areas' components by id even if you don't own them:
- `wf.<file-stem>` workflow, `job.<wf-stem>.<job>` job
- `script.<filename-without-ext>` (e.g. `script.build-packages`, `script.boot-test`)
- `make.<target>`, `docker.<stage>` (Dockerfile stage; `docker.final` if unnamed)
- `ebuild.<category>/<pkg>`, `cfg.<path-under-configs>` (e.g. `cfg.portage/make.conf`)
- `web.<file>`, `test.<filename-without-ext>`, `bootmode.<mode>`
- `ext.<service>` external service: use `ext.aws-s3`, `ext.ghcr`, `ext.dockerhub`,
  `ext.gentoo-distfiles`, `ext.gentoo-mirrors`, `ext.kernel-org`, `ext.rustup`, `ext.github-api`,
  `ext.github-attestations`, `ext.sigstore`, `ext.grype-db`, `ext.nvd`, `ext.jsdelivr`,
  `ext.google-fonts`, `ext.git-<host>` for source fetches; add new ones as needed.
- `secret.<NAME>` for GitHub secrets/vars.

## Output schema (factory areas: workflows, build, supplychain)
```yaml
area: <area>
components:
  - id: script.sync-portage
    kind: workflow | job | script | make-target | dockerfile-stage | web | config
    path: scripts/sync-portage.sh
    purpose: one line
    triggers: []          # workflows/jobs: push/pr/tag/schedule "cron"/workflow_run/dispatch
    invokes: []           # ids it calls
    invoked_by: []        # ids that call it (as far as visible from your scope)
    inputs:  [{what: "portage snapshot gentoo-$BUILD_EPOCH.tar.xz", from: "ext.aws-s3 s3://$S3_BUCKET/portage-snapshots/", evidence: "scripts/sync-portage.sh:34"}]
    outputs: [{what: ..., to: ..., evidence: ...}]
    secrets: []           # secret ids
    external: []          # ext ids
    pins: [{thing: ..., value: "v4 / sha / date", evidence: ...}]   # versions, digests, epochs
    env: []               # env vars it requires or honours (name + default)
    s3_coupling: none | soft | hard   # hard = fails without S3
    notes: []             # smells, dead code, duplication, flakiness, workarounds, with path:line
    rebuild_notes: []     # optional: what the rebuild must preserve / can drop
contradictions: [{claim: ..., where: "README.md:123", fact: ..., evidence: ...}]
open_questions: []
```
Other areas (recipes, oracle, doctrine) have their own schema in their prompt but keep the
`contradictions` and `open_questions` keys.
