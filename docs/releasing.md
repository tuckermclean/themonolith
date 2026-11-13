# Cutting a release

This document covers the versioning scheme, what a tagged release actually
is (versus the iteration builds this repository produces continuously), and
the exact operator steps to cut one. The machinery itself lives in
`.github/workflows/build.yml` (build, gate and sign) and
`.github/workflows/release.yml` (publish); this doc explains it, it doesn't
define it.

## Versioning scheme

Tags follow `vMAJOR.MINOR.PATCH` ([SemVer](https://semver.org/)). **`v0.2.0-rc1`
is the first release of this repository** and the first tag cut through
`release.yml`: a reproducible build behind it, all boot modes, the artifact
checks and gates, the whole predecessor package set, and platform
attestations of the ISO and its SBOM. The predecessor's `v0.1.0-rc1` stays
what it was (see "Verifying a release").

- **Patch (`0.2.0` → `0.2.1`)**: no change to what ships, only how it was
  built or verified: a pinned dependency bump that doesn't change kernel
  config or the world package list, a CI/attestation fix, a doc fix, a
  reproducibility fix. Nothing a user booting the ISO would notice.
- **Minor (`0.2.0` → `0.3.0`)**: the ISO itself changed in a
  backward-compatible way: packages added to `configs/portage/world`, a
  kernel config change that adds capability without removing any, new boot
  modes, a new architecture variant. Existing use cases keep working.
- **Major (`0.x.y` → `1.0.0`)**: a breaking change to what "The Monolith"
  is or how it's used: dropping i486 support, changing the init system,
  removing a package class users may depend on, restructuring the ISO
  layout (partition scheme, boot loader) in a way that breaks existing
  boot media/scripts built against it. `1.0.0` itself should mark the point
  where the project considers its interface (boot behavior, package set
  shape, attestation artifact schema) stable enough to commit to not
  breaking casually.

Not every build gets a version tag, and that's by design.

### Prerelease / RC tags

A tag carrying a `-rcN` or `-betaN` suffix (e.g. `v0.2.0-rc1`) is published
as a GitHub **prerelease**: `scripts/release-create.sh`, which the publish
job runs, passes `--prerelease --latest=false` for any hyphenated tag.
GitHub's API forbids a prerelease from also holding the "Latest" badge
(`HTTP 422: Latest release cannot be draft or prerelease`), so the
`--latest=false` is mandatory, not cosmetic. A final `vX.Y.Z` tag with no
suffix becomes GitHub's "Latest".

### Iteration builds vs. tagged releases

Every push to `main` that changes a build input, a labeled pull request, the
weekly schedule and a manual dispatch run `build.yml` directly and produce a
build identified as `<BUILD_EPOCH>-<short-sha>`. They use binary packages
from the cache, run the same boot modes, artifact checks and gates, report
sizes, and are never signed or published as a release.

A tagged release (`vMAJOR.MINOR.PATCH`) takes a different path through the
same workflow: fetch the distfiles once, build the ISO twice offline on two
runners from the recorded pins only (P02), and require the two ISOs to have
the same SHA-256. Only then are the checks only a release needs run, the
files written, and the ISO and SBOM attested. The ISO is named
`themonolith-<version>.iso` (e.g. `themonolith-0.2.0-rc1.iso`).

A `workflow_dispatch` with gate=true takes the gate path (fetch, two offline
builds, compare) and runs the non-signing release steps (package set,
release-mode rootfs provenance, rc1-diff, allowlist report, release assets and
SHA256SUMS). Nothing is signed (the attest steps are tag-only) and nothing is
published (`release.yml` acts only on a tag push).

## How `build.yml` builds and `release.yml` publishes

`build.yml` is the single definition of how The Monolith is built, gated and
signed. It triggers **directly** on a release tag (`push: tags: ['v*.*.*']`)
and runs the chain itself. On a tag it skips the iteration `build` job and
runs `fetch`, `build-a`, `build-b` and `compare`, alongside `overlay`
(`make test-overlay`), `static-rebuild` and `boot-test`. The `attestation`
job `needs` all of them, and its `if:` requires each result to be
`success`. A red boot mode (any of the 17 boot modes, `persist-init`, every
`entry` leg, `smoke`), a `compare` mismatch, a failed overlay scan or a
failed gate stops the run before anything is signed, pushed or published.

`release.yml` does **not** build. It fires after a Build run finishes, via
`workflow_run`, and does only what is specific to a release:

- `resolve` runs for a successful Build run that a push started. It checks
  that `head_branch` is a real tag that points at the exact commit the Build
  ran on, and finds the previous tag for the changelog. A branch push
  produces `publish=false` and nothing else.
- `publish` runs only if `github.event.workflow_run.conclusion == 'success'`.
  It downloads the files from the Build run's artifacts (`download-artifact`
  with `run-id` and `github-token`), checks them (below), pushes the
  distfiles archive, and creates the release.

**Why `build.yml` owns the tag trigger.** GitHub binds a Sigstore attestation
to the workflow that *entered* the run. Signing in a `workflow_call` library
fails to persist (`values do not match: build.yml != release.yml`). So the
attestation steps are in `build.yml`'s own `attestation` job, entered by its
own tag push, and `release.yml` waits for that run.

## The digest chain, traced

**Invariant:** `sha256(ISO)` == the `SHA256SUMS` entry == the SBOM's
`metadata.component.hashes[0].content` == both digests in the compare log ==
the subject digest of the platform attestation.

1. `fetch`, `build-a` and `build-b` (P02) produce the ISOs; `compare` runs
   `scripts/compare-isos.sh`, which prints `<sha256>  <path>` for each ISO
   and fails if they differ. `make compare` keeps that output, and only that,
   in `output/compare.log`; the job uploads it as `compare-log-<run id>`.
2. In the `attestation` job, `scripts/attestation.sh` (via `make test-gates`)
   computes the ISO's SHA-256 once and writes it into `bom.cdx.json`'s
   `metadata.component.hashes[0]`.
3. `make release-assets` copies the ISO to `themonolith-<version>.iso`, the
   SBOM, `release-inputs.json`, `source-audit.tsv` and
   `rootfs-provenance.tsv` next to the three reports, and
   `scripts/release-sums.sh` writes `SHA256SUMS` once, over all of them but
   itself, before signing.
4. `actions/attest-build-provenance` signs the ISO (its only subject);
   `actions/attest-sbom` attaches the SBOM to the same subject. The platform,
   not a script of ours, writes the predicates.
5. The `publish` job downloads everything, runs `sha256sum -c SHA256SUMS`
   (`make release-sums-check`), then `make release-digest-chain`
   (`scripts/release-digest-chain.sh`): the ISO, its `SHA256SUMS` entry, the
   SBOM hash, both compare digests and the subject digest from
   `gh attestation verify <iso> --repo "$GITHUB_REPOSITORY" --signer-workflow
   "$GITHUB_REPOSITORY"/.github/workflows/build.yml --format json` must all
   be equal. Any difference exits 1, and no release is created.

## The distfiles archive

P02's `fetch` job made the distfiles archive and recorded its digest as
`DISTFILES_DIGEST` in `release-inputs.json`; both builds consumed those
bytes. After the digest chain and before the release, the `publish` job runs
`make push-distfiles`: it checks that the archive hashes to
`DISTFILES_DIGEST`, pushes it with `oras push` to
`${REGISTRY}/distfiles:<version>`, fetches the manifest back, and fails if
the layer digest differs. In `release.yml` only `publish` has
`packages: write`; in `build.yml` only `build` has it (for the binary package
cache). The `attestation` job has none.

To check it later:

```sh
oras manifest fetch ghcr.io/tuckermclean/themonolith/distfiles:0.2.0-rc1 | jq -r '.layers[0].digest'
jq -r .DISTFILES_DIGEST release-inputs.json
```

The two digests must be equal. (`--descriptor` would print the manifest's own
digest, not the layer's.)

## The package set and the reports

Before signing, a tag's `attestation` job fails unless:

- all 99 atoms of the predecessor's world (`configs/release/world-b9f533b.txt`)
  are in the tag's `configs/portage/world`, installed in the rootfs VDB and
  `built-this-run` in `source-audit.tsv` (`make release-package-set`;
  `rl144` and `stele` included). Removing an atom needs a SPEC change;
- `rootfs-provenance.tsv` holds in release mode (`make rootfs-provenance`);
- the SBOM validates against the vendored CycloneDX schema
  (`make check-cyclonedx`, offline);
- the ISO is within `ISO_BUDGET_BYTES` (681,984,000, the 74-minute CD-R).
  `make size-report` runs on every build and writes `sizes.md`;
- every package added or removed since rc1 has a reason line in
  `docs/rc1-diff-reasons.tsv` (`make rc1-diff`, which also lists the added
  and removed squashfs paths).

The release assets are: the ISO, `bom.cdx.json`, `SHA256SUMS`,
`release-inputs.json`, `source-audit.tsv`, `rootfs-provenance.tsv`,
`rc1-diff.md`, `sizes.md` and `dynamic-allowlist.txt`.

## Verifying a release

An ISO from this repository:

```sh
gh attestation verify themonolith-0.2.0-rc1.iso \
  --repo tuckermclean/themonolith \
  --signer-workflow tuckermclean/themonolith/.github/workflows/build.yml
```

`--owner` alone accepts an attestation from any repository of the owner;
always name the repository and the signer workflow.

The predecessor's `v0.1.0-rc1` ISO (sha256 `a9600659…eb27a`) was signed by
the predecessor's workflow and keeps verifying against that repository, and
not against this one:

```sh
gh attestation verify themonolith-0.1.0-rc1.iso \
  --repo tuckermclean/linux-live-iso-factory \
  --signer-workflow tuckermclean/linux-live-iso-factory/.github/workflows/build.yml
```

`make verify-rc1-attestation` runs both against rc1's ISO and passes only if
the first verifies and the second fails. The negative check passes when `gh`
reports a verification failure or an HTTP 404 from the attestations lookup (no
attestation in this repository); any other HTTP, network or authentication
error fails the target; `rc1-attestation.yml`
runs it on pull requests that touch the release or signing paths, and on
`workflow_dispatch`.

**GitHub Release URL in the SBOM:** GitHub Release asset download URLs are
deterministic: `<server>/<owner>/<repo>/releases/download/<tag>/<asset>`.
`scripts/attestation.sh` computes
`https://github.com/tuckermclean/themonolith/releases/download/v<version>/themonolith-<version>.iso`
from `GITHUB_REF`/`GITHUB_REPOSITORY` alone, *before* `gh release create`
ever runs, and passes it to `enrich-sbom.py --release-url`. This is why the
SBOM can point at the release asset without an ordering dependency on the
release existing yet: by the time `gh release create` runs and makes that URL
resolve, the SBOM already named it correctly. On a build that is not a tag
the URL stays empty; none is fabricated.

## Cutover

These steps need the owner's credentials: pushing the tag, deleting
secrets and archiving a repository. They run in this order.

**Preconditions** (each proven by its own node): the allowlist report shows 0
entries; the tree bump is merged and the tag's `TREE_COMMIT` differs from
rc1's; the advisory feed answers at its published URL; the CVE gate passes
with no expired waiver; G01 is done (each claim in the README is tested or removed).

1. **Release.** Push the final tag, `v0.2.0` (confirm the number), with no
   suffix. It goes through the whole tag pipeline, not a promotion of an
   `-rc` tag. The release is not a prerelease and is Latest. Evidence:
   ```sh
   gh release view v0.2.0 --repo tuckermclean/themonolith --json isPrerelease,assets
   gh api repos/tuckermclean/themonolith/releases/latest --jq .tag_name
   gh release download v0.2.0 --repo tuckermclean/themonolith \
     --pattern 'themonolith-0.2.0.iso' --pattern SHA256SUMS \
     --pattern release-inputs.json --pattern dynamic-allowlist.txt
   sha256sum -c SHA256SUMS --ignore-missing
   gh attestation verify themonolith-0.2.0.iso \
     --repo tuckermclean/themonolith \
     --signer-workflow tuckermclean/themonolith/.github/workflows/build.yml
   jq -r .TREE_COMMIT release-inputs.json   # differs from rc1's
   ```
   `dynamic-allowlist.txt` has 0 entries and the Build run's gate verdict is
   green; record the Build run URL.
2. **Verify rc1 (baseline).** Run the README's rc1 commands on a clean
   machine and record the output.
3. **Pointer.** One docs commit to the predecessor's default branch adds a
   README banner pointing here. Edit the `v0.1.0-rc1` release notes to point
   here; leave its assets untouched.
4. **Retire the predecessor.** Disable its workflows, remove its AWS secrets,
   set its description, then archive the repository (the repository's Settings page, Danger Zone, or the `gh repo` subcommand). Never rename, transfer
   or delete it: rc1's attestation names it.
5. **Verify rc1 again** with the same commands and record the output. If
   verification fails, unarchive the repository and record why.
6. **Evidence for the archive:**
   ```sh
   gh api repos/tuckermclean/linux-live-iso-factory --jq '[.full_name,.archived]'
   gh release view v0.1.0-rc1 --repo tuckermclean/linux-live-iso-factory --json assets
   ```

## Permissions

| Permission | Scope | Why |
|---|---|---|
| `contents: write`, `actions: read` | `release.yml`, workflow level | Create the release; download the Build run's artifacts |
| `packages: write` | `release.yml`'s `publish` job only | Push the distfiles archive |
| `id-token: write`, `attestations: write`, `contents: read` | `build.yml`'s `attestation` job | Sign the ISO and SBOM through Sigstore and GitHub OIDC |
| `packages: write` | `build.yml`'s `build` job only | Push the binary package cache |

No secrets are used besides the automatic `GITHUB_TOKEN`.

## Operator steps to cut a release

Once the version to release is decided (see the scheme above):

1. **Confirm `main` is in the state you want released.** This pins the
   commit; there is no separate release branch.
2. **Tag it:**
   ```sh
   git tag v0.2.0-rc1
   ```
3. **Push the tag.** This starts the **Build** workflow on the tag; once it
   succeeds, `release.yml` publishes automatically via `workflow_run`:
   ```sh
   git push origin v0.2.0-rc1
   ```
4. **Watch the Build run.** All the work, and any gate failure, happens here:
   ```sh
   gh run watch --repo tuckermclean/themonolith \
     $(gh run list --repo tuckermclean/themonolith \
         --workflow=build.yml --branch v0.2.0-rc1 --limit 1 --json databaseId --jq '.[0].databaseId')
   ```
   When it succeeds, the **Release** workflow runs (its run is attributed to
   `main`, not the tag, because `workflow_run` runs on the default branch):
   ```sh
   gh run list --repo tuckermclean/themonolith --workflow=release.yml --limit 3
   ```
5. **Verify the published release:**
   ```sh
   gh release view v0.2.0-rc1 --repo tuckermclean/themonolith --json isPrerelease,assets
   gh release download v0.2.0-rc1 --repo tuckermclean/themonolith \
     --pattern 'themonolith-0.2.0-rc1.iso'
   gh attestation verify themonolith-0.2.0-rc1.iso \
     --repo tuckermclean/themonolith \
     --signer-workflow tuckermclean/themonolith/.github/workflows/build.yml
   sha256sum themonolith-0.2.0-rc1.iso   # must match SHA256SUMS and the release notes
   ```
6. If the run fails at a boot mode, the compare or a gate, **do not re-push
   the same tag** (git tags are meant to be immutable, and a force-push
   re-triggers the whole pipeline from a confusing state). Nothing was
   signed, pushed or published, so fix forward on `main`, delete the
   local/remote tag (`git tag -d v0.2.0-rc1 && git push origin :refs/tags/v0.2.0-rc1`),
   and re-tag once the fix is in.

There is no rollback automation: a bad release is superseded by cutting a
new patch version, not by deleting the old one (deleting a published
release with real download counts/links out in the wild is a judgment
call for the operator, not something this pipeline does for you).
