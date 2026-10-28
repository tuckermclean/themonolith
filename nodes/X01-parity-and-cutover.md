# X01 — parity-and-cutover

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| X | P02, P03, P04, P05, O07, B07, M01, M03, G01, G02, G03, G04, G05 | none | MS5 | M |

**Owns:** `docs/cutover.md` (parity definition, runbook, evidence table), `docs/releases.yaml` (the one list of releases and where to verify each), `docs/verify.md`, `docs/legacy-rc1.md`, `docs/urls.md` (public URL inventory and the list of dead old URLs), `docs/releases/0.2.0.md` (hand-written release-notes section), `docs/decisions/0002-od-outcomes.md`, `docs/archive/OLD-REPO-BANNER.md` (text for the old repository), `factory/bin/verify-published`, `factory/bin/cutover-check`, `factory/bin/check-urls`, `.github/workflows/verify-published.yml`, `tests/fast/readme-*.test.*`, `tests/fast/urls-*.test.sh`, `tests/fast/cutover-*.test.*`; the final text of the "Try it", "Verify a release" and "Dashboard" sections of `README.md` (F01 creates the file).
**Carries from linux-live-iso-factory@b9f533b:** the README sections "Try it in your browser" (`README.md:16-22`), "Verify a release" (`:26-60`) and "Dashboard" (`:189-203`) as text to rewrite; `docs/releasing.md` is P02's.
**Study refs:** supplychain contradictions (two S3 hostnames; README says the nightly monitor is orphaned while a workflow runs it; README ISO "131 MB" vs UI "135 MB"); workflows `job.release.publish` notes (`--owner tuckermclean` hard-coded in the release notes, `release.yml:216`); T-attest-entry-workflow (attestation bound to the entry workflow and repo); T-recovery-pattern; workflows `wf.nightly-cve-scan` (failing daily since 2026-10-07); `monolith-advisory-check:17,29` (the rc1 disc fetches `https://themonolith.s3.amazonaws.com/status/<tag>.json`); `scripts/build-rootfs.sh:235-236,266` (`/etc/monolith-release`, `HOME_URL`); SPEC §0, §10 OD-1, OD-2, OD-6, OD-8; graph milestones MS3, MS4, MS5.

## Purpose
After this node, the new repository is the product's home: it has shipped its first release, `v0.2.0` (OD-8), through the full pipeline; its README tells a reader how to verify releases from either repository; and `linux-live-iso-factory` is archived with a pointer, unrenamed, so that `v0.1.0-rc1` stays verifiable. "Parity" stops being a feeling and becomes a table of CI runs.

## Scope
In:
- The definition of parity and the evidence table that proves it.
- The `v0.2.0` release: preconditions, steps, notes.
- Verification documentation and a script that follows it, for releases of both repositories.
- The archive runbook for the old repository, and the inventory of old URLs that stop working.
- The decision about what happens for people running the `v0.1.0-rc1` disc.
- Final README and documentation completeness checks.

Out:
- Release workflow, notes generator and `release-verify`: P02. The public site and data: P03. Demo: P04. Advisory feed: P05.
- The SBOM diff and its expected-differences file: O07. The reproducibility result: B07. This node reads their results.
- Hosting and domain setup: P01 and the owner (OD-1).
- Deleting old GHCR packages or the old S3 bucket: not done here (see runbook step 9).
- New features. A feature found missing during cutover becomes a gap node (G*), not scope here.

## Design

### What "parity" means
All of the following hold at one commit, the release commit `R`, and each is recorded as a CI run URL in `docs/cutover.md`.
| # | Criterion | Source |
|---|---|---|
| 1 | MS3: every boot mode (17, SPEC §7) and the artifact doctrine checks pass on the ISO built from `R`. | O02–O06 |
| 2 | MS3: the SBOM diff against `v0.1.0-rc1/bom.cdx.json` passes: every difference is listed with a reason in the expected-differences file. The package set is the 99-atom world of rc1 plus the listed differences. | O07 |
| 3 | MS4: a tag produced a signed GitHub release that `gh attestation verify --repo` accepts (`v0.2.0-rc1`), and `v0.2.0` did the same from `R`. | P02-AC-15 and this node |
| 4 | The supply-chain gates (SBOM schema, licence, CVE, unowned) pass for the `R` build with the CVE policy file in `supplychain/policy/`. | S02–S04 |
| 5 | Reproducibility: B07 ran; the release notes state either "two builds from the same inputs gave the same hash" or the list of known differences. No other claim is made. | B07 |
| 6 | Public surfaces work: dashboard row, `latest-release.json`, ISO range-readable, advisory feed live, boot demo reaches the prompt in a browser. | P03-AC-17, P04-AC-11/13, P05-AC-15/17 |
| 7 | Maintenance is alive: one pin-bump PR was opened by M01's automation and validated by build and core oracle (merged by a human); one GC run of M03 in dry-run on every class shows no release input or `public` release object marked for deletion. | M01, M03 |
| 8 | Every owner decision OD-1 to OD-8 has an outcome in `docs/decisions/0002-od-outcomes.md` (the default if unanswered, stated as such). | SPEC §10 |
Not required for parity: removing the dynamic-binary allowlist (OD-2 default keeps it, with issues to remove each entry), shipping new boot modes beyond rc1's 17, Hyper-V and serial-protocol claims (G03, G04).

### The v0.2.0 release (OD-8)
`docs/cutover.md` has the single line `release_version: 0.2.0`; README and the notes are checked against it, so a different OD-8 answer is one edit.
1. Preconditions: parity criteria 1, 2, 4, 6 (for the rc), 7 and 8 recorded; `PUBLIC_BASE_URL` serving; README and docs complete.
2. The commit `R` is on the default branch with a green fast tier. `docs/releases/0.2.0.md` exists.
3. The owner pushes tag `v0.2.0`. It is a fresh from-source build of `R`; `v0.2.0-rc1` is not promoted (D-tag-builds-from-source: nothing from a cache enters a signed release; one version, one build). If the rc differed from `R`, the evidence for criterion 3 is the final tag.
4. Build, oracle, attest, Release workflow (P02) and publisher (P03) run. `verify-published 0.2.0` passes. The release is a normal release, so GitHub marks it Latest (no suffix; T-prerelease-never-latest does not apply).
5. Release notes (P02's generator) append `docs/releases/0.2.0.md`: what changed from rc1 with a link to the expected-differences file, the B07 statement, the allowlist (OD-2) pointer, and the legacy-rc1 pointer.
Rejected: tagging `v0.1.0` or promoting rc1's artifacts; the old repo owns `0.1.x`, and its attestation is bound to the old repository.

### Verification for releases of both repositories
Rule: attestation identity is the repository and the entry workflow that built the ISO. Releases made by the old repository must be verified against the old repository, forever. Therefore **the old repository is never renamed, transferred or deleted** (the certificate and the GitHub attestation record carry its name).

`docs/releases.yaml` (schema 1) is the only list; `verify-published` and the README table read it:
```yaml
schema: 1
releases:
  - version: "0.1.0-rc1"
    repo: "tuckermclean/linux-live-iso-factory"
    signer_workflow: ".github/workflows/build.yml"
    release_url: "https://github.com/tuckermclean/linux-live-iso-factory/releases/tag/v0.1.0-rc1"
    iso_name: "themonolith-0.1.0-rc1.iso"
    iso_sha256: "<from that release's SHA256SUMS>"
    prerelease: true
    public_copy: null
  - version: "0.2.0"
    repo: "<new repo slug>"
    signer_workflow: ".github/workflows/build.yml"
    release_url: "..."
    iso_name: "themonolith-0.2.0.iso"
    iso_sha256: "<64 hex>"
    prerelease: false
    public_copy: "releases/0.2.0/themonolith-0.2.0.iso"
```
The new repository slug is not fixed by the study or SPEC; `tuckermclean/themonolith` is the likely name (Risks).

README "Verify a release" shows, for the new repository:
```bash
gh release download v0.2.0 --repo <new-repo> --pattern 'themonolith-0.2.0.iso' --pattern SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS
gh attestation verify themonolith-0.2.0.iso --repo <new-repo> \
  --signer-workflow <new-repo>/.github/workflows/build.yml
```
and, for rc1, the same with `--repo tuckermclean/linux-live-iso-factory` and its signer workflow. It states that `--owner` alone is not used, because it would accept an attestation from any repository of the owner. It names `gh`'s minimum version once `verify-published` has been run with a pinned `gh` (unknown today). The old worked example (build `20260406-1149887`, S3 URL) is dropped; it can no longer be fetched.

`factory/bin/verify-published VERSION [--dir DIR]`: looks up `docs/releases.yaml`; downloads the ISO from the GitHub release; checks its sha256 against the recorded one and against the release `SHA256SUMS`; runs `gh attestation verify` with the recorded repo and signer workflow, checking the subject digest; if `public_copy` is set, downloads it from `${PUBLIC_BASE_URL}` and requires the same digest. Exit codes: 0 ok, 2 usage, 3 unknown version, 4 digest mismatch, 5 attestation failed, 6 public copy missing or different. `gh` is replaceable by `GH_BIN` for tests.

### The rc1 disc and its runtime dependency
Fact: the rc1 disc runs `monolith-advisory-check` after the network is up. It fetches `https://themonolith.s3.amazonaws.com/status/0.1.0-rc1.json` (`monolith-advisory-check:17,29`; the tag in `/etc/monolith-release` is the version without `v`, `build-rootfs.sh:236`). The AWS account is disabled, so the fetch fails silently (`:42,47-49`: all failures `exit 0`). rc1 media cannot be changed.
Decisions (recorded in `docs/legacy-rc1.md`):
1. The automatic advisory check on rc1 is dead. README and `docs/legacy-rc1.md` say so plainly; no claim is made that rc1 warns users.
2. P05 serves `status/0.1.0-rc1.json` on the new host from rc1's published SBOM (legacy entry), so a user can opt in: `ADVISORY_BASE_URL=<PUBLIC_BASE_URL> monolith-advisory-check`, which the rc1 script already honours.
3. Residual risk, stated: S3 bucket names are global. If the old bucket name is released and re-registered by someone else, that party can serve `status/0.1.0-rc1.json` to every rc1 disc that is online. The effect is limited to a "revoked" banner and an unfiltered `details_url` printed on the console (rc1's `40-advisory.sh` does not strip control characters; P05's does). Mitigation for readers: upgrade to `v0.2.0`; for the paranoid, run the disc offline or `chmod -x /usr/sbin/monolith-advisory-check` in the live session. If OD-6 recovers the AWS account, the owner can park a frozen `status/0.1.0-rc1.json` there; that is optional and cheap.
Rejected: DNS or proxy tricks (the host `s3.amazonaws.com` is not ours); re-releasing rc1 (new digest, new attestation, a different thing); deleting the rc1 release (users lose the only way to verify what they hold).

### Archive runbook for `linux-live-iso-factory` (owner executes; evidence recorded in `docs/cutover.md`)
1. Preconditions: `v0.2.0` verified (`verify-published 0.2.0`), `PUBLIC_BASE_URL` serving, `docs/legacy-rc1.md` published in the new repo.
2. Run `verify-published 0.1.0-rc1` and record the result (baseline before archiving).
3. Disable every workflow in the old repo (`gh workflow disable`) — the nightly scan fails daily, the scheduled build, pin-bump, GC and canary hit dead S3 or burn minutes. Delete the secrets `AWS_ACCESS_KEY_ID`, `AWS_ACCESS_KEY_SECRET`, `AWS_REGION`, `S3_BUCKET`. Close open PRs and issues with a comment linking the new repository.
4. One docs commit to the old default branch, text from `docs/archive/OLD-REPO-BANNER.md`: a banner at the top of README ("Archived. Development moved to <new repo>. Releases `>= 0.2.0` are verified against that repository; `v0.1.0-rc1` against this one. The dashboard and S3 links below no longer work."). This is the one exception to SPEC §0's "frozen at `b9f533b`"; the study's commit remains in history. Rejected: leave the README untouched (visitors land on dead badges and links); force-push or squash history.
5. Edit the notes of the `v0.1.0-rc1` release in the old repository: append a pointer to `v0.2.0` and to `docs/legacy-rc1.md`. Assets are not touched.
6. Set the repository description and homepage to the new repository.
7. `gh repo archive tuckermclean/linux-live-iso-factory`. Do not rename, transfer or delete.
8. Run `verify-published 0.1.0-rc1` again. If attestation verification fails on an archived repository, `gh repo unarchive`, record the finding, and leave it unarchived until understood. (That archiving keeps attestations verifiable is expected, not confirmed by the study.)
9. Later, not part of this node: delete or retag old GHCR packages only after 90 days, and only if the new builder image and caches are used by the new repo (they are rebuilt from mirrored inputs by I03).
Pointers elsewhere: GitHub profile and any external page that links the old dashboard; owner's task, listed in the cutover doc.

### Old public URLs that stop working
Listed in `docs/urls.md` with the replacement or "none":
| Old URL | Replacement |
|---|---|
| `https://themonolith.s3.amazonaws.com/` (dashboard, README badge, rc1 release notes `#/build/0.1.0-rc1`) | `${PUBLIC_BASE_URL}/` |
| `https://themonolith.s3.amazonaws.com/#/boot` and the regional host `themonolith.s3.us-west-2.amazonaws.com` (the SPA's data root and `ISO_URL`) | `${PUBLIC_BASE_URL}/#/boot` |
| `.../themonolith.iso`, `.../themonolith-<tag>.iso`, `.../themonolith.squashfs`, `.vmlinuz`, `.initrd` (latest pointers and versioned copies) | releases: `${PUBLIC_BASE_URL}/releases/<ver>/themonolith-<ver>.iso`; newest: `latest-release.json`; squashfs/vmlinuz/initrd: none |
| `.../attestation/<tag>/*` (documented in the old README) | `${PUBLIC_BASE_URL}/attestation/<id>/*`; rc1's files: none, except `bom.cdx.json` and `SHA256SUMS` on the GitHub release |
| `.../builds-index.json`, `.../latest-build.json` | `${PUBLIC_BASE_URL}/builds-index.json`; `latest.json` replaces `latest-build.json` (schema changed) |
| `.../status/<tag>.json` read by the rc1 disc | `${PUBLIC_BASE_URL}/status/<id>.json` for new builds; rc1: see above |
| `.../builds/<ver>/logs/`, `.../portage-snapshots/`, `.../packages/` (internal) | none |
| `HOME_URL` in rc1's `/etc/os-release` (`themonolith.s3.us-west-2.amazonaws.com`, `build-rootfs.sh:266`) | new ISOs: `${PUBLIC_BASE_URL}` |
| rc1 SBOM `externalReferences` of type `distribution` pointing at `s3://themonolith/...` | none; the GitHub release URL in the same SBOM stays valid |
| `https://themonolith.org/builds/<tag>` (`details_url` in old status files) | a third party's domain, never the project's; new: `${PUBLIC_BASE_URL}/#/build/<id>` |
Still valid after archiving: the GitHub release `v0.1.0-rc1` and its assets, `gh attestation verify --repo tuckermclean/linux-live-iso-factory`, source links to files in the old repo, the old build badge (frozen, red).

### Mechanical checks
- `factory/bin/cutover-check --evidence` reads the run URLs in the table of `docs/cutover.md` and asks `gh run view` that each run concluded `success` on head commit `R` (criteria 1–4, 6) and that the pin-bump PR is merged (criterion 7).
- `factory/bin/cutover-check --archive` asks `gh api`: old repository `full_name` unchanged, `archived: true`, description names the new repository, workflows disabled, no `AWS_*` secrets, release `v0.1.0-rc1` has its three assets.
- `factory/bin/check-urls` extracts every URL from `README.md` and `docs/` (outside `docs/study/` and the "dead" table of `docs/urls.md`) and requests it; every URL must answer 2xx or 3xx.

## Traps and doctrines preserved
- **T-attest-entry-workflow, repo-bound identity:** AC-2, AC-6, AC-13 (verify by `--repo` and signer workflow; old repo never renamed).
- **T-recovery-pattern:** AC-4 (`verify-published` is the user-side form of the same checks).
- **D-supply-chain-honesty / D-tag-builds-from-source:** AC-9 (final tag is its own from-source build, with attestation).
- **T-prerelease-never-latest:** AC-9 (final release is Latest, rc1 and the new rc stay prereleases).
- **Dead vendor URLs in shipped artifacts:** AC-3, AC-11, AC-12.
- **README promises without a test (SPEC §1 / phase G):** AC-2 (every command in the README verification section is parsed; claims are limited to what the tests prove); AC-10 (no reproducibility claim unless B07 passed).
- **DEC-no-g-slash-shortcuts and UI cruft:** the README's dashboard section lists only routes that exist in P03 and the single shortcut `t`; AC-14.
- **Principle 1:** AC-3 (no storage vendor name outside the dead-URL table and the decision record).
- **T-workflow-push-needs-pat:** `verify-published.yml` is a workflow file (Risks).

## Gate
- **X01-AC-1** — `docs/releases.yaml` validates: schema 1, unique versions, `repo` as `owner/name`, 64-hex `iso_sha256`, `signer_workflow` ending `.github/workflows/build.yml`, entries for `0.1.0-rc1` (old repository, `prerelease: true`) and the `release_version` from `docs/cutover.md` (new repository, `prerelease: false`). *Verify:* `tests/fast/releases-yaml.test.py`. *Tier:* fast.
- **X01-AC-2** — Every `gh attestation verify` in `README.md` and `docs/verify.md` has `--repo` and `--signer-workflow`, none uses `--owner` alone; the README release table equals `docs/releases.yaml`; commands for both repositories are present. *Verify:* `tests/fast/readme-verify.test.py`. *Tier:* fast.
- **X01-AC-3** — `rg` over the tree (excluding `docs/study/`, the dead-URL table in `docs/urls.md`, `docs/legacy-rc1.md`, `docs/decisions/`, and `docs/releases.yaml`) finds no `amazonaws`, no `s3://`, and `linux-live-iso-factory` only in lines allowlisted in `tests/fast/urls.allow` with a comment each. *Verify:* `tests/fast/urls-dead.test.sh`. *Tier:* fast.
- **X01-AC-4** — `verify-published` exits 0 on a consistent fixture, and exactly 3 (unknown version), 4 (digest mismatch with the recorded value or with `SHA256SUMS`), 5 (attestation failure, subject mismatch), 6 (public copy missing or different) in the matching fixtures. *Verify:* `tests/fast/verify-published.test.sh` (stub `GH_BIN`, local `range_server.py`). *Tier:* fast.
- **X01-AC-5** — `docs/cutover.md` states `release_version`, defines the eight parity criteria, and in `status: complete` every criterion row carries a run URL or PR URL, a date and a name; no `TBD`. *Verify:* `tests/fast/cutover-doc.test.py`. *Tier:* fast.
- **X01-AC-6** — `verify-published 0.1.0-rc1` passes against the old repository's release, and passes again after the old repository is archived. *Verify:* `verify-published.yml` dispatch runs before and after archiving, both logs linked in `docs/cutover.md`. *Tier:* slow.
- **X01-AC-7** — `verify-published 0.2.0` passes: ISO from the GitHub release and from `${PUBLIC_BASE_URL}` have the recorded digest and `gh attestation verify --repo <new repo>` accepts it. *Verify:* `verify-published.yml` run. *Tier:* slow.
- **X01-AC-8** — `cutover-check --evidence` passes: every run in the table concluded `success` on commit `R`, the M01 pin-bump PR is merged, and the M03 dry-run log shows zero `public` release or snapshot deletions. *Verify:* `factory/bin/cutover-check --evidence` output attached to the PR. *Tier:* slow.
- **X01-AC-9** — The `v0.2.0` release is not a prerelease, is the repository's Latest release, its tag commit equals `R`, its asset set equals P02's five assets, and the `v0.2.0-rc1` release is still a prerelease and not Latest. *Verify:* `gh release view v0.2.0 --json isPrerelease,targetCommitish,assets`, `gh api repos/<new repo>/releases/latest --jq .tag_name`. *Tier:* slow.
- **X01-AC-10** — The `v0.2.0` notes contain the verification block, the link to the expected-differences file, the reproducibility statement (one of the two allowed forms from B07's result), the OD-2 allowlist pointer and the legacy pointer; the phrase "always produces the same ISO" is absent from the repository unless `docs/cutover.md` records B07 as passing. *Verify:* `tests/fast/release-notes-0.2.0.test.sh` on `docs/releases/0.2.0.md` and a grep; the published notes are compared in AC-9's run. *Tier:* fast.
- **X01-AC-11** — `docs/urls.md` lists each old URL class of the table above with a replacement or "none", and `check-urls` reports every URL outside its dead table as 2xx or 3xx. *Verify:* `tests/fast/urls-inventory.test.py` (structure) and `factory/bin/check-urls` in `verify-published.yml` (live). *Tier:* slow.
- **X01-AC-12** — `docs/legacy-rc1.md` states the three decisions (check is dead; opt-in command; bucket-name risk), the README links it, and `curl -fsS ${PUBLIC_BASE_URL}/status/0.1.0-rc1.json` returns a valid status file. *Verify:* `tests/fast/legacy-rc1.test.sh` (headings, link, command text equal to P05's documented command) and the P05-AC-15 run. *Tier:* fast.
- **X01-AC-13** — Archive evidence: the old repository's `full_name` is unchanged, `archived` is true, the description names the new repository, its workflows are disabled, no `AWS_*` or `S3_BUCKET` secret remains, its README begins with the banner text of `docs/archive/OLD-REPO-BANNER.md`, and the `v0.1.0-rc1` release keeps its assets. *Verify:* `factory/bin/cutover-check --archive`. *Tier:* slow.
- **X01-AC-14** — The README is complete: no `TBD`, `TODO` or `FIXME` in `README.md`, `docs/verify.md`, `docs/cutover.md`, `docs/releasing.md`, `docs/urls.md`; its dashboard section lists only routes that exist in `web/app/router.js` and states `t` as the only shortcut; its demo link is `${PUBLIC_BASE_URL}/#/boot`; it states no ISO size. *Verify:* `tests/fast/readme-complete.test.py`. *Tier:* fast.
- **X01-AC-15** — `docs/decisions/0002-od-outcomes.md` has one row per OD-1 to OD-8 with outcome, date and either "owner" or "default"; the `docs/system.yaml` check (F03) passes with no unlisted workflow, secret or external URL. *Verify:* `tests/fast/od-outcomes.test.py` and F03's check inside `make test-fast`. *Tier:* fast.

## RED plan
Tester writes first, in `tests/fast/`: AC-1 (fixture with a missing rc1 entry), AC-2 and AC-3 (they run against a copy of the old README and old release notes kept in `tests/fixtures/cutover/old/`, which contain `--owner tuckermclean`, `amazonaws.com` and the S3 dashboard URL, so they must fail on it), AC-4 (stubbed `gh`; fails because `verify-published` does not exist), AC-5 (fails while `docs/cutover.md` is absent or incomplete; it is the node's progress meter), AC-14 and AC-15. AC-10, AC-12 fail until the notes and legacy doc exist. Slow ACs have no RED; they are the GREEN evidence, recorded in `docs/cutover.md`.

## Risks and open questions
- **New repository slug.** The SPEC and graph never name it. Directory name suggests `tuckermclean/themonolith`. Confirm before the first tag; every `--repo` in docs derives from `docs/releases.yaml`, so a change is one edit plus the pinned signer path.
- **OD-1 gates the public parts** (criteria 6 and URLs). Without the domain, the node can finish only a GitHub-only release, which is not parity.
- **Does archiving keep `gh attestation verify` working?** Expected yes; not confirmed by the study. Runbook step 8 is the test and has a rollback (`gh repo unarchive`).
- **Is the rc1 ISO still downloadable?** The release assets are on GitHub, not S3 (`release.yml:265-271`), so yes unless removed. Not checked here (no network).
- **TLS on the disc** (P05 risk) decides whether `v0.2.0` users get advisories at all; AC-7 and P05-AC-17 are separate evidence.
- **Cost of the final tag:** one more full from-source build and oracle. If the final build fails, the rule is fix forward and re-tag (`docs/releasing.md`, P02); a failed `v0.2.0` tag is deleted only before a release exists.
- **Owner-only steps.** Pushing tags, workflow files, secrets deletion and archiving need the owner (PAT for workflows, T-workflow-push-needs-pat). Agents prepare the commands and verify results.
- **The old README text refers to an unnamed "`v0.0.1`" tag** and a first public release "v0.1.0"; neither is carried forward.

## Cost
- Slices: 3 (docs and `releases.yaml` with `verify-published` and tests; cutover tooling and URL checks; release and archive runbook execution with evidence). 15 ACs.
- CI build cycles: 1 for the `v0.2.0` from-source build (30–60 min) plus the oracle, 1 contingency. The rc (`v0.2.0-rc1`) is P02's cycle, not counted here.
- Money: none beyond the domain and hosting already costed in P01. Owner time: a few hours for the runbook.

## Spec defects found
1. **SPEC §0 calls the predecessor "frozen at `b9f533b`"** but cutover requires a README banner commit, release-note edit and archive flag on it. The exception is stated in the runbook; SPEC should say "frozen except for the archival pointer".
2. **No node produces `docs/releases.yaml`-style release metadata for old releases**, and the graph has no node for "legacy compatibility". X01 and P05 carry it; consider a short SPEC §8 note that old-repository attestations are verified by repo name.
3. **Graph: X01 lists O07 and B07 but not O02–O06, S01–S05, P01.** They are transitive through P02/P03, so no edge is missing; criteria 1 and 4 re-check them by run URL.
4. **SPEC §10 has no OD for the new repository's name**, though the verification story depends on it (Risks). Add one or record it in SPEC §0.
5. **README is owned by F01 (skeleton) and X01 (final sections)** with no rule on conflicts. P02 and P03 also edit `docs/releasing.md` and README links. Suggest: F01 creates, X01 is the only later writer.
