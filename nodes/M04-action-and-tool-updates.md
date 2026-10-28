# M04 — action-and-tool-updates

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| M | F01, I05, M01 | none | — | M |

**Owns:** `pins/tool-sources.yaml`, `tests/fast/tool-sources.test.sh`, `.github/dependabot.yml`, `.github/workflows/tool-bump.yml`, `.github/workflows/pin-age.yml`, `factory/bin/tool-latest`, `factory/bin/tool-apply`, `factory/bin/pin-age`, `docs/action-and-tool-updates.md`, `tests/fast/dependabot-config.test.sh`, `tests/fast/tool-latest.test.sh`, `tests/fast/tool-apply.test.sh`, `tests/fast/pin-age.test.sh`, `tests/fast/tool-bump-workflow.test.sh`, `tests/fast/tool-bump-fixtures/`.
**Carries from linux-live-iso-factory@b9f533b:** nothing as code. Facts only: the predecessor pinned actions to floating major tags (31x `actions/checkout@v4`, `actions/attest@v2` and others; workflows.yaml `pins_summary.actions`), fetched `oras` 1.2.0 with no checksum (`build.yml:234`), ran `curl | sh` of the grype installer from `main` (`cve-gate-canary.yml:56-57`, `nightly-cve-scan.yml:43-44`), pinned actionlint 1.7.7 and check-jsonschema 0.38.0, and had no update path for any of them.
**Study refs:** workflows.yaml `pins_summary.actions`, `pins_summary.tools_fetched_at_runtime`; supplychain.yaml (grype/syft/oras fetch entries); doctrine.yaml T-github-api-503-installs, T-attest-entry-workflow, T-workflow-push-needs-pat; SPEC §2.2, §3 D-supply-chain-honesty, §6, §8.

## Purpose
After this node every SHA-pinned Action and every pinned tool has a defined way to be updated: a weekly pull request with the upstream changelog link and CI evidence, reviewed and merged by a human. Pins that never move turn into unpatched CVEs; pins that move silently defeat the point of pinning. This node makes movement visible and slow.

## Scope
In:
- Dependabot configuration for the `github-actions` ecosystem.
- `tool-bump.yml`: a scheduled in-repo workflow that proposes bumps for GitHub-release tools recorded in `pins/pins.yaml`, with verified checksums.
- `pin-age`: a report of every pin's age and bump path, including pins this node does not auto-bump.
- Policy: which pins are auto-proposed, which are manual, and the cooldown.
Out:
- The schema of `pins/pins.yaml` and the "unpinned fetch / unused pin" check: I05. This node writes entries conforming to I05's schema (assumed keys below).
- Epoch pins (`BUILD_EPOCH`, `TOOLCHAIN_EPOCH`), stage3 and builder image digest: M01, M02.
- Python/pip pins inside the builder image, and Gentoo package versions: I03, R02.
- Adding the SHA pins to workflows and the lint that rejects unpinned `uses:`: F01.
- Merge decisions: always human (SPEC §8).

## Design

### Decision: Dependabot for Actions, a small in-repo workflow for tools
- **Actions:** `.github/dependabot.yml` with `package-ecosystem: github-actions`, `directory: "/"`, weekly (Monday 05:00 UTC), `open-pull-requests-limit: 5`, `cooldown: {default-days: 7}`, one `groups:` entry `actions-minor-patch` for minor and patch updates, major updates ungrouped (one PR each), `commit-message: {prefix: "chore(actions)"}`, labels `dependencies`, `actions`. Dependabot natively rewrites `uses: owner/repo@<sha> # v4.1.2` pairs: it updates the SHA and the version comment together, and its PR body carries release notes and a changelog link. F01 requires every `uses:` to be `@<40-hex> # vX.Y.Z`; that is exactly the shape Dependabot maintains.
- **Tools:** a workflow of about 150 lines in this repo, because no off-the-shelf updater reads `pins/pins.yaml`.
- **Rejected: Renovate for both.** It could read `pins.yaml` through a regex manager and would be one tool, but it is either a third-party GitHub App with write access to a repository that builds a signed artifact (a new trust boundary against SPEC §8), or a self-hosted runner job with its own pinned container and config (a new moving part to inventory under F03). Dependabot is first-party and needs no extra credential. Revisit if tool pins outgrow the in-repo workflow.
- **Rejected: Dependabot `docker` ecosystem** for the stage3 or builder base. Tag-following contradicts the digest/epoch model (D-two-epoch-pin-model); those pins belong to M01/M02, and `dependabot.yml` carries an explicit `ignore` for any Dockerfile under `image/`.

### Cooldown and review
All Dependabot version updates wait 7 days after upstream release before a PR is opened (`cooldown`), so a compromised release that is yanked within a week never reaches a PR. Tool bumps use the same rule inside `tool-latest` (release `published_at` at least 7 days old). The security-update path of Dependabot (CVE-driven) is left on and ignores cooldown by design.

Every `.github/**` path is an owner-review path (SPEC §8), so each Dependabot PR is routed to the owner by CODEOWNERS and gets the label `protected-path` from a path-filter step in the F04 lane; Dependabot cannot approve or merge, and the repository has no auto-merge rule for it. `dependabot.yml` sets no `auto-merge` behaviour (none exists in the file; the merge is a repo setting that the owner keeps off).

### Where action pins live
SPEC §6 gives Action SHAs exactly one home: the `uses:` lines of the workflows. I05 checks that each is a full 40-hex SHA with a `# vX.Y.Z` comment; M04 updates them. Dependabot edits exactly those lines (SHA and version comment together), so no sync job is needed. The v0.2 design kept a second copy in `pins/pins.yaml` (`actions.*`) and a `pull_request_target` job, `actions-pins-sync.yml`, to keep the copies equal. That job is dropped: it held a secret in the one workflow type that must never run PR content, and SPEC §6 removed the reason for it. M04-AC-14 is withdrawn.

### Tool pins
I05 stores `tools.<name>: {version, url (template), sha256: {linux_amd64}}` plus `rust.nightly` and `python.*`. It stores nothing about where releases come from. This node adds a sidecar, `pins/tool-sources.yaml`, owned here:
```yaml
oras:        {repo: oras-project/oras, bump: auto, checksums_asset: "oras_${v}_checksums.txt"}
syft:        {repo: anchore/syft,      bump: auto, checksums_asset: "syft_${v}_checksums.txt"}
grype:       {repo: anchore/grype,     bump: auto, checksums_asset: "grype_${v}_checksums.txt"}
actionlint:  {repo: rhysd/actionlint,  bump: auto, checksums_asset: "actionlint_${v}_checksums.txt"}
shellcheck:  {repo: koalaman/shellcheck, bump: auto}
rustup-init: {bump: manual, reason: "installer follows rust.nightly"}
```
Asset names above are illustrative; the implementer reads each project's real release assets and records them (unknown here, no network). A fast check fails if any `tools.*` key lacks an entry, or an entry has no matching `tools` key (the two-way rule I05 applies to pins). `rust.nightly`, `python.*` and `asserted.*` are `manual`: `rust.nightly` drifts and is tied to T-rust-i486-musl; Python pins ride the builder image (I03). Rejected: adding `bump:` and `repo:` keys inside `pins.yaml`, which would change I05's schema and put policy in a protected file.

`factory/bin/tool-latest [--tool NAME] [--min-age-days 7] [--json]` reads `pins.yaml`, calls `GET /repos/<repo>/releases/latest` (and `/releases` when prereleases exist to skip them), drops draft and prerelease entries, drops releases younger than `--min-age-days`, and prints `name current latest published_at url` per tool needing a bump. API errors and rate limits exit 1 with the status on stderr (T-github-api-503-installs: a 503 is a failure, retried a bounded three times with backoff, then fatal; never "no update").

`factory/bin/tool-apply NAME VERSION`: expands the `url` template for the new version, downloads it, computes sha256, and, when the sidecar names a `checksums_asset`, requires the computed digest to equal the upstream-published one. Mismatch exits 1 and changes nothing. On success sets `tools.<name>.version` and every `tools.<name>.sha256.*` with `pin set`, reads them back with `pin get`, and exits 1 if `pin diff` shows any other key changed. `v86` is P03/P04's (`web.v86`, reserved in I05) and is not handled here. A tool with no upstream checksums file is accepted (digest recorded from first download) but the PR body says `checksum: self-computed (no upstream digest)` so a reviewer sees the weaker case. Rejected: updating the version only and leaving `sha256` stale, or fetching a `curl | sh` installer.

`tool-bump.yml`: `schedule` Monday 05:30 UTC and `workflow_dispatch` with optional `tool`. For each tool needing a bump, one branch `pins/tool-<name>-<old>-<new>` and one PR, opened with `BUMP_TOKEN` (M01's secret; if M01 is not yet merged, the job fails with a message naming the missing secret). The workflow uses `gh pr create` directly (about ten lines); it does not depend on M01's code. The PR's required checks provide the evidence: the fast lane, and a `tool-smoke` job (owned here) that fetches the tool by the I05 mechanism at the new version and runs its `--version` and one functional command (`syft --version` and an SBOM of a one-file fixture; `grype --version` and `grype db status` offline; `actionlint` on a fixture workflow with a known error and a known-good one; `shellcheck` on two fixture scripts; `oras version`). PR body: tool, old and new version, upstream release URL, release `published_at`, checksum mode, and the `tool-smoke` run link.

Open-PR deduplication: if a PR for the same tool is open, skip it with a notice.

### `pin-age`
`factory/bin/pin-age` prints a table `pin  kind  version  age_days  bump_path  status` for every entry in `pins.yaml` (epochs included, using the date encoded in the epoch; digests via the registry creation time when known, else `unknown`) and every `uses:` in the workflows (using the version comment and the release date from the API). `status` is `ok`, `stale` (older than 90 days for tools and actions, 180 for `TOOLCHAIN_EPOCH`, 45 for `BUILD_EPOCH`), or `unknown`. `pin-age.yml` runs it weekly after the bumps and writes the table to the job summary; it fails the job when any pin is `stale` and its `bump_path` is `manual` or its auto-PR has been open longer than 21 days, so a stuck bump produces a red scheduled run instead of silence. This also exercises the schedule, softening T-canary-silence.

## Traps and doctrines preserved
- **SPEC §2.2 / D-supply-chain-honesty:** an unpinned or unverified tool entering CI. Prevented by M04-AC-4 (checksum verification) and M04-AC-5 (no installer scripts).
- **T-github-api-503-installs:** a transient API error read as success. Prevented by M04-AC-3.
- **T-attest-entry-workflow:** a bump of `actions/attest` or `upload-artifact` can break the attestation only on a tag. Prevented by M04-AC-8 (those bumps force a full build on the PR; a tag-only check is left to P02's dry-run and flagged in the PR body).
- **D-two-epoch-pin-model:** tool bumps cannot touch epoch or builder keys. Prevented by M04-AC-6.
- **SPEC §8 Humans merge:** Prevented by M04-AC-9.
- **T-canary-silence:** scheduled workflows go silent. Prevented by M04-AC-10.
- **T-workflow-push-needs-pat:** token scope. The tool-bump PRs never edit workflow files, so the token needs no `workflows` scope; Dependabot edits workflow files under its own identity.

## Gate
- **M04-AC-1** — `.github/dependabot.yml` is valid, covers `github-actions` at `/`, weekly, with `cooldown.default-days: 7`, a `groups` entry for minor and patch, a `commit-message.prefix`, no `docker` ecosystem and no auto-merge settings, and every `uses:` in `.github/workflows` and `.github/actions` is `@<40-hex>` followed by a `# vX.Y.Z` comment. *Verify:* `tests/fast/dependabot-config.test.sh` (YAML schema keys, regex over workflow files). *Tier:* fast.
- **M04-AC-2** — `tool-latest` lists exactly the tools whose latest non-draft, non-prerelease, at-least-7-days-old release is newer than the pin, and none whose latest release is younger than the cooldown. *Verify:* `tests/fast/tool-latest.test.sh` against fixture API JSON (`file://` base URL override) with a prerelease, a draft, a 3-day-old and a 10-day-old release. *Tier:* fast.
- **M04-AC-3** — `tool-latest` exits 1 on HTTP 403 rate limit, 5xx after three bounded retries, malformed JSON, or a missing repo; it never prints "up to date" for an error. *Verify:* `tests/fast/tool-latest.test.sh` with a fixture server returning each failure. *Tier:* fast.
- **M04-AC-4** — `tool-apply` fails with no change to `pins.yaml` when a downloaded asset's sha256 differs from the upstream checksums file, and on success rewrites `version` and all `sha256` values for the tool and no other key; a tool without an upstream checksums file is accepted and flagged `self-computed`. *Verify:* `tests/fast/tool-apply.test.sh` with local fixture assets, a good and a tampered checksums file, and a `pin diff` scope assertion. *Tier:* fast.
- **M04-AC-5** — No workflow, script or Dockerfile fetches a tool through an installer script, `curl … | sh`, an unversioned `latest` URL, or `main` branch raw content. *Verify:* `tests/fast/dependabot-config.test.sh` (grep set over `.github/`, `factory/`, `image/`, `oracle/`, `supplychain/`). *Tier:* fast.
- **M04-AC-6** — `tool-apply` refuses tools whose sidecar `bump` is `manual` or `none` and any key outside `tools.<name>`; `pins/tool-sources.yaml` and `tools.*` agree in both directions. *Verify:* `tests/fast/tool-apply.test.sh` and `tests/fast/tool-sources.test.sh`. *Tier:* fast.
- **M04-AC-7** — Each tool-bump PR body contains the tool, old and new version, the upstream release URL, the release `published_at`, the checksum mode and the `tool-smoke` run link. *Verify:* `tests/fast/tool-apply.test.sh` renders the body from fixtures and asserts each field; `tests/fast/tool-bump-workflow.test.sh` asserts the workflow passes `--body-file`. *Tier:* fast.
- **M04-AC-8** — A Dependabot or tool-bump PR that changes `actions/attest`, `actions/upload-artifact`, `actions/download-artifact`, `actions/cache`, `docker/login-action` or any pin used in `build.yml`/`release*.yml` triggers the B06 full build as a PR check, and the PR body or label (`needs-full-build`) says so. *Verify:* `tests/fast/dependabot-config.test.sh` parses B06's `pull_request.paths` and the label rule; CI evidence from the first real Dependabot PR recorded in the node PR table. *Tier:* fast + slow.
- **M04-AC-9** — No file merges, approves or enables auto-merge for bump PRs; `tool-bump.yml` declares `permissions: contents: read` at workflow level and elevates only the job that opens PRs. *Verify:* M01's no-merge grep (`tests/fast/pin-bump-workflow.test.sh`) extended to `tool-bump.yml`, and `tests/fast/tool-bump-workflow.test.sh` for the permissions. *Tier:* fast.
- **M04-AC-10** — `pin-age` reports every `pins.yaml` entry and every workflow `uses:`, marks `stale` per the thresholds, and exits 1 when a stale pin has `bump_path: manual` or an auto-PR open more than 21 days; `pin-age.yml` runs on a weekly schedule. *Verify:* `tests/fast/pin-age.test.sh` with a fixture `pins.yaml`, a fixture workflow and a fixed `--now`. *Tier:* fast.
- **M04-AC-11** — `tool-smoke` runs on every PR that changes the `tools:` section, passes for the current pins, and fails when the tool binary is replaced by a stub that prints the right version but does nothing. *Verify:* CI job `tool-smoke` on a PR with the stub fixture (expected red), plus the current-pins run (expected green). *Tier:* slow.
- **M04-AC-12** — One real Dependabot PR and one real tool-bump PR (dispatch) are opened and show changelog link, cooldown honoured, and passing evidence; both are left unmerged by automation. *Verify:* recorded in the node PR table with links. *Tier:* slow.
- **M04-AC-13** — `docs/action-and-tool-updates.md` states the Dependabot-versus-Renovate decision with the rejected alternative, the cooldown, the manual-pin list and the human-merge rule. *Verify:* `tests/fast/dependabot-config.test.sh` greps the four statements. *Tier:* fast.
- **M04-AC-14** — *Withdrawn (v0.3):* the `actions-pins-sync` job existed to keep `pins/pins.yaml` copies of Action SHAs equal to the workflows; SPEC §6 now gives the `uses:` lines the only home, so there is nothing to sync.

## RED plan
`dependabot-config.test.sh` first (no `dependabot.yml`, and its SHA-pin regex runs over the workflows F01 created, so it is red until Dependabot config and any straggler pins are fixed). Then `tool-latest.test.sh` and `tool-apply.test.sh` (tools absent), `pin-age.test.sh`, `tool-bump-workflow.test.sh`. Fixtures (fake API JSON, tampered checksums) are committed with the RED commits.

## Risks and open questions
- Hardest: the interface to I05's schema. `tool-apply` rewrites a structured file whose layout I05 owns. If I05 changes key names, M04's tests fail; the fixture `pins.yaml` copies I05's published example and F02-style validation should be added to catch drift.
- Dependabot opens PRs as `dependabot[bot]`. SPEC §8 allows that identity; F04's allowlist and trailer format must accept it, and tool-bump PRs from `BUMP_TOKEN` use the agent bot identity.
- Any script that reads a Dependabot PR's head must treat it as text, never run it. This node has no such job after v0.3, so there is no `pull_request_target` workflow here.
- Dependabot runs with a read-only token and no repository secrets, so the PR's slow checks that need secrets may not run on its branches. B06's PR lane for Dependabot must work with that limit, or a human re-runs the build from a branch.
- A cooldown delays CVE fixes by up to 7 days for non-security updates. Dependabot security updates skip the cooldown; accept.
- Unknown: the exact release asset names and checksum files of oras, syft, grype, actionlint and shellcheck (no network here); the implementer records them in `pins/tool-sources.yaml`, and a tool with no checksums file is accepted only as `self-computed`.
- `actions/attest` behaviour is verified only by a tagged release; a bump is un-testable before P02. The PR body warns; P02 owns a dry-run.

## Cost
Three agent slices: (1) `dependabot.yml`, SHA-pin check, docs; (2) `tool-latest`, `tool-apply`, fixtures; (3) `tool-bump.yml`, `tool-smoke`, `pin-age` and its workflow. CI: no build cycle for the gate except the `tool-smoke` job (minutes) and one real run each of Dependabot and tool-bump. Ongoing: about five small PRs per month, each a fast-lane run and, for release-path actions, a cache-hot build cycle (about 25 minutes wall time, `docs/first-attested-build.md`). No money beyond runner minutes.

## Spec defects found
- I05 reserves `web.v86` for P03/P04 and does not say who bumps it; this node excludes it.
