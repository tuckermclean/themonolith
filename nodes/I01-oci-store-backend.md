# I01 — oci-store-backend

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| I | F06 | I02, I03, I04, I06, M03, P01 | — (feeds MS1) | M |

**Owns:** `factory/lib/store/oci.sh` (the `oci` backend, including `locate`, `rm`, `ls --long` and the adopted-object read), `factory/bin/store-adopted` (thin wrapper over the backend's adopted-object read), `factory/bin/install-oras`, `tests/fast/store-oci.test.sh`, `tests/fast/install-oras.test.sh`, `tests/fast/store-vendor-isolation.test.sh`, `tests/fast/fixtures/fake-oras` (a directory-backed fake registry plus error injection), CI job `store-oci-registry` and `store-oci-live` (in the F01/B06 workflow files, listed in `docs/system.yaml`), the `store.oci` (prefix, adopted objects) and `tools.oras` sections of `pins/pins.yaml` (format in I05).
**Carries from linux-live-iso-factory@b9f533b:** ported: the oras usage in `scripts/binpkg-store.sh` (push from the blob's own directory with a relative name, `:415-424`; pull into a temp work dir and locate the layer by name, `:437-455`) and the oras install snippet at `.github/workflows/build.yml:231-240`. Changed, each forced by a named AC: the fail-open classifier at `:324-338` is not carried (AC-4, AC-5); the install gains a checksum (AC-10); one-blob-per-epoch push becomes one object per key (AC-12, the F06 contract).
**Study refs:** T-binpkg-store-fail-open, D-supply-chain-honesty, Principle 1 and 5, `ext.ghcr`, `script.binpkg-store`, build.yaml silent_fallbacks ("binpkg-store.sh pull: missing oras, or 401/denied/404/etc -> empty cache, exit 0"), workflows.yaml pins_summary (oras 1.2.0 "pinned-version-no-checksum").

## Purpose
After this node the `store` CLI can keep durable bytes in GHCR through a pinned `oras`, and passes the same contract suite as the `fs` backend. It also defines how a store key maps to a GHCR package version, so listing, deleting (M03) and the build cache's set lookups (I06) are well-defined, and it holds the two rescued rc1 objects (builder image, binpkg seed) by digest. The predecessor treated any 401 or "denied" from GHCR as "nothing published yet" and carried on with an empty cache. That behaviour hid auth failures and is the pattern SPEC §2.5 forbids. This backend separates "absent" (exit 3) from every other failure.

## Scope
In:
- Backend `oci` selected by `STORE_BACKEND=oci`: `put`, `get`, `has`, `ls [--long]`, `rm`, plus `init <class>` (create repo, write sentinel).
- Key-to-tag encoding (directory-grouped, so a prefix lists cheaply), key-to-package-version mapping, manifest annotations, deterministic manifests, retry policy, error classification.
- Anonymous read of public packages, for local builds.
- Read by digest of the adopted rc1 objects (`store-adopted`).
- A pinned, checksum-verified `oras` installer.
- A fake `oras` for the fast tier; a real-registry slow job (`registry:2` by digest) and a live GHCR smoke job.

Out:
- The contract suite itself, the `fs` backend and the CLI dispatcher: F06.
- `url` for the `public` class and any HTTP-served hosting: P01.
- Retention policy and the decision what to delete: M03. This node supplies only the mechanism (`rm`, `ls --long`).
- Which keys exist per class (binpkg blobs and sets, memo, distfile index): I06, I02, I04. This node guarantees their shapes map and list well.
- Copying the rc1 objects into our namespace (owner action, Step 0 in `docs/first-attested-build.md`).
- Docker image push of the builder image: I03.

## Design
**Configuration (environment).**
`STORE_BACKEND=oci`; `STORE_OCI_PREFIX` (default from `pins.yaml: store.oci.prefix`: `ghcr.io/tuckermclean/themonolith/store`); `STORE_OCI_USER`, `STORE_OCI_TOKEN` (in Actions: `github.actor`, `GITHUB_TOKEN` with `packages: write`; both unset means anonymous, below); `STORE_RETRY` (default 3), `STORE_RETRY_SLEEP` (default 5, doubling; tests set 0); `ORAS` (binary path, tests point it at the fake).
The workflow files name no registry. Only `factory/lib/store/oci.sh`, `factory/bin/builder-image` (image registry, I03), `pins/` and `docs/` may contain `ghcr.io` or `oras`.

**Repository layout.** One OCI repository per class: `${STORE_OCI_PREFIX}/<class>`, e.g. `ghcr.io/tuckermclean/themonolith/store/binpkg`. GHCR names the package `themonolith/store/binpkg` under the owner.
Rejected: one repository with the class in the tag. Visibility, retention (M03) and permissions are per repository.

**Key to tag.** OCI tags allow `[A-Za-z0-9_][A-Za-z0-9._-]{0,127}`; store keys contain `/` and reach 512 characters. I06's blob key `<64 hex>/blobs/<64 hex>.gpkg.tar` is already 144, so the key cannot be the tag. Tag = `k-<d>-<h>` where `h` is the lowercase hex `sha256(key)` (64 characters) and `d` is the first 16 hex of `sha256(dir)`, with `dir` the key up to its last `/` (empty for a top-level key). The tag is 83 characters. The original key is stored in the annotation `org.themonolith.store.key`.
Rejected: reversible escaping of the key into the tag; it breaks the 128-character limit. Rejected: a bare hash tag (v0.2): a prefix listing then needs one manifest fetch per tag in the repository.

**Key to package version (the mapping M03 needs).** In GHCR every tag points at one manifest, and a manifest is one *package version* with a numeric id. So a store key maps to exactly one version: key, then tag, then the version in the GHCR versions list (`GET /users/{owner}/packages/container/{name}/versions`, one paginated call) whose `metadata.container.tags` contains the tag. `locate <class> <key>` prints `tag`, `version_id`, `manifest_digest` and any other tags on that version. The key is an annotation, so two different keys never share a manifest and so never share a version; a version with more than one tag is a fault (a lost put race or a manual retag). `rm <class> <key> --confirm` calls `DELETE /user/packages/container/{name}/versions/{id}` (the `/orgs/` form when `STORE_OCI_OWNER_KIND=org`) and refuses with exit 1 when the version carries any tag other than this key's. Deleting the version removes the tag. It needs a token with `delete:packages`; without one it exits 1. GitHub documents a download-count limit on deleting versions of public packages; the number is unverified, so M03 treats an `rm` failure as an error and reports it.

**Object shape.** `oras push --artifact-type application/vnd.themonolith.store.v1 <repo>:<tag> blob:application/octet-stream`, run from a temp directory where the body is hard-linked or copied as `blob` (no absolute paths, the T-binpkg-store-fail-open push bug). Annotations: `org.themonolith.store.key`, `.sha256` (of the body), `.size`, `.class`, and `org.opencontainers.image.created=1970-01-01T00:00:00Z` (fixed, so the same body yields the same manifest digest; the 1970 origin is the project's clock sentinel, D-clock-origin-1970). Whether oras lets an explicit `created` annotation override its default is to be proven by AC-9 against real oras.

**Operations.**
- `has <class> <key>`: `oras manifest fetch --descriptor <repo>:<tag>`. Exit 0 present, 3 absent, else per the table below.
- `put <class> <key> <file>`: `has`; if present, compare the `.sha256` annotation with `sha256(file)`: equal gives exit 0 with no push call; different gives exit 4 (immutability conflict) with both digests on stderr. If absent, push, then re-resolve the tag and fail (exit 1) if its manifest digest differs from the locally computed expectation (detects a lost race: GHCR has no conditional put).
- `get <class> <key> <dest>`: pull into a temp dir beside `dest`, verify `sha256(blob)` against the annotation (exit 5 on mismatch, nothing left at `dest`), for `distfile` keys `sha256/<hex>` also verify `<hex>`, then `mv` into place. `dest` never exists half-written.
- `ls [--long] <class> <prefix>`: `dir` is the prefix cut at its last `/` (so `<global>/sets/` and `<global>/sets/2026` both give `<global>/sets`). One `oras repo tags` call lists the repository's tags. Tags whose `d` equals the hash of `dir` are selected, their key annotations are fetched (8 in parallel), and keys that start with the prefix are printed, sorted. Cost: one tag listing plus one manifest fetch per object *in that directory*. This is what I06 needs to find the newest set under `<global>/sets/` without touching the hundreds of blobs under `<global>/blobs/`. A prefix that spans directories (for example `<global>/`) is the slow path: all tags are fetched, O(n). `--long` adds `size` (the `.size` annotation) and `created_utc` (from the versions list; the manifest `created` annotation is fixed at 1970, so it cannot give age) and needs a token with `read:packages`; plain `ls` does not.
- `rm <class> <key> --confirm`: see the mapping above. Exit 3 when the key is absent. Class protection (snapshot, release inputs) lives in the CLI wrapper (M03), not here.
- `store-adopted get <name> <dest>`: see Adopted objects.
- `init <class>`: pushes the sentinel `_sentinel/v1` (body `monolith-store v1\n`). Idempotent. Creating a repository requires write credentials; this is the only place a repo is created.

**Error classification (the T-binpkg-store-fail-open fix).** Input is the `oras` exit status and stderr.
| Condition | Exit |
|---|---|
| 404 / `MANIFEST_UNKNOWN` / `NAME_UNKNOWN` AND the class sentinel was read successfully with the same credentials in this process | 3 (absent) |
| Same, but the sentinel is missing | 1, message "store not initialised: run store init <class>" |
| 401, 403, "unauthorized", "denied" (any key, any class) | 1, HTTP status echoed to stderr |
| 5xx, timeout, DNS, connection reset | retry `STORE_RETRY` times with doubling sleep, then 1 |
| Digest or size mismatch | 5 |
Rejected: classifying 401 as "absent" because GHCR answers 401 for a repository that was never pushed. That bootstrap case is removed instead by `init`, which makes the repository exist before the first read. Exit codes 4 and 5 are proposed here; the F06 table wins if it differs.

**Anonymous read.** The store's GHCR packages are public. GHCR creates packages private; making one public is a package-settings action by the owner, and whether it can be scripted is unverified. With `STORE_OCI_USER` and `STORE_OCI_TOKEN` both unset the backend runs no `oras login`. `has`, `get`, `ls` and `store-adopted get` then work against public packages; `put`, `init`, `rm` and `ls --long` exit 1 with "credentials required". Local builds read the shared cache this way and write to the `fs` backend. A 401 or 403 on an anonymous read is still exit 1 (private or missing package), never 3.

**Adopted objects (rc1).** The rc1 builder image (`sha256:ab04002a…`) and binpkg cache (`sha256:d0a1838d…`) are not store objects: the predecessor pushed them as plain OCI artifacts, and the owner copied them to `ghcr.io/tuckermclean/themonolith/{builder:rc1,binpkg-seed:rc1}` (Step 0; `oras cp` keeps the digest). `pins/pins.yaml: store.oci.adopted` lists each as `{repo, digest}`. `store-adopted get <name> <dest>` runs `oras pull <repo>@<digest>` into a temp dir, checks that the manifest digest equals the pin (exit 5 otherwise) and moves the files to `dest`. It reads by digest only; a tag is never resolved. The seed layer is the predecessor's `binpkgs.tar.zst` (`binpkg-store.sh:415-424`). I06 `seed-rc1` uses this tool. The builder image is pulled by `docker pull <repo>@<digest>` (I03), not through it. The tool is a declared exception to the store contract (see Spec defects).

**Secrets.** Login uses `oras login --password-stdin`; the token is never an argument and never echoed; the script never runs with `set -x`. Credentials are never passed into build containers (the store runs on the runner).

**oras pin.** `factory/bin/install-oras` downloads `https://github.com/oras-project/oras/releases/download/v<ver>/oras_<ver>_linux_amd64.tar.gz`, verifies the sha256 from `pins.yaml: tools.oras` (predecessor used 1.2.0 with no checksum, `build.yml:234`), and installs to `$HOME/.local/bin`. Version choice at implementation time; 1.2.0 remains the known-good baseline.

**stdout.** Only requested data goes to stdout (`ls` keys). `put`, `has`, `get`, `init` print nothing to stdout. Diagnostics go to stderr and are never redirected to `/dev/null`.

**Fake registry for the fast tier.** `tests/fast/fixtures/fake-oras` is a POSIX sh script implementing `login`, `push`, `manifest fetch`, `pull`, `repo tags` over a directory, with `FAKE_ORAS_FAIL=<op>:<http-status>` injection and a call log (`FAKE_ORAS_LOG`). The contract suite (F06) runs against it with `ORAS=…/fake-oras`.

**GHCR facts to respect.** A package created by `oras push` is private (anonymous reads fail with exit 1 until the owner makes it public) and must be granted to the repository (Package settings, "Manage Actions access", write role) or `GITHUB_TOKEN` gets 403. This yields exit 1, never 3. Documented in the runbook section of `docs/decisions/` (ADR for the store layout).

## Traps and doctrines preserved
- **T-binpkg-store-fail-open** (401/denied treated as a miss, empty cache, green build): AC-4, AC-5, AC-6. The old oras absolute-path push bug: AC-8.
- **D-supply-chain-honesty / Principle 5**: auth and network errors are failures: AC-4, AC-6.
- **Principle 1** (storage is an interface): AC-1.
- **Principle 2** (tools pinned): AC-10, AC-19 (adopted objects by digest only).
- **M03 safe deletion** (a key must map to one version): AC-16, AC-17. **I06 cheap set lookup**: AC-15. **Local builds without secrets**: AC-18.
- **D-state-and-no-hidden-stderr**: AC-13.

## Gate
- **I01-AC-1** — `ghcr.io`, `oras` and the GitHub packages API (`/packages/container`) appear only in the allowlisted files (`factory/lib/store/oci.sh`, `factory/bin/builder-image`, `pins/`, `docs/`, `tests/`). *Verify:* `tests/fast/store-vendor-isolation.test.sh` (greps the tree; a fixture with a stray `oras push` in a workflow makes it fail). *Tier:* fast.
- **I01-AC-2** — The F06 contract suite passes with `STORE_BACKEND=oci ORAS=tests/fast/fixtures/fake-oras`. *Verify:* `tests/fast/store-oci.test.sh` (invokes the suite entry point named by F06). *Tier:* fast.
- **I01-AC-3** — The same contract suite passes against real `oras` and a real registry (`registry:2` service container pinned by digest). *Verify:* CI job `store-oci-registry`. *Tier:* slow.
- **I01-AC-4** — With injected 401 or 403 on any request, `has`, `get` and `put` exit non-zero and not 3, for both an existing and a never-written key, and print the HTTP status to stderr. *Verify:* `tests/fast/store-oci.test.sh` cases `auth-*`. *Tier:* fast.
- **I01-AC-5** — A 404 on a key exits 3 only when the class sentinel was read in the same process; with the sentinel missing it exits 1 with "store not initialised". *Verify:* `tests/fast/store-oci.test.sh` cases `absent-*`. *Tier:* fast.
- **I01-AC-6** — Injected 5xx or timeout is retried `STORE_RETRY` times, then exits 1; the exit status is never 3 and the retry count is asserted from the call log. *Verify:* `tests/fast/store-oci.test.sh` cases `retry-*`. *Tier:* fast.
- **I01-AC-7** — `put` of a different body under an existing key exits 4 and leaves the stored object unchanged (tag digest identical before and after); `put` of the same body exits 0 and the call log contains no `push`. *Verify:* `tests/fast/store-oci.test.sh` cases `immutable-*`. *Tier:* fast.
- **I01-AC-8** — `get` of a corrupted blob exits 5 and leaves nothing at `dest`; `get` verifies `sha256/<hex>` keys against `<hex>`; push uses no absolute path. *Verify:* `tests/fast/store-oci.test.sh` cases `integrity-*`, `push-relpath`. *Tier:* fast.
- **I01-AC-9** — Two `put`s of the same body from different directories and times produce the same manifest digest. *Verify:* CI job `store-oci-registry` (`oras manifest fetch --descriptor` twice, compare). *Tier:* slow. *When:* after MS2.
- **I01-AC-10** — `install-oras` installs only the version and sha256 in `pins.yaml: tools.oras`; a wrong checksum or a missing pin exits non-zero and installs nothing. *Verify:* `tests/fast/install-oras.test.sh` (local `file://` tarball override). *Tier:* fast.
- **I01-AC-11** — With `STORE_OCI_TOKEN=SECRET-TOKEN-SENTINEL`, the string appears nowhere in stdout, stderr or the fake's call log arguments. *Verify:* `tests/fast/store-oci.test.sh` case `no-secret-leak`. *Tier:* fast.
- **I01-AC-12** — A corpus of keys (200+ characters, slashes, `+`, uppercase, the §5 key shapes for all five classes) encodes to valid tags of at most 128 characters, injectively, and `ls <class> <prefix>` returns the original keys sorted. The corpus includes I06's `<64 hex>/blobs/<64 hex>.gpkg.tar` and `<64 hex>/sets/<utc>-<run>.json` and `pr-<n>/` variants. *Verify:* `tests/fast/store-oci.test.sh` cases `keys-*`. *Tier:* fast.
- **I01-AC-13** — `put`, `has`, `get`, `init` write nothing to stdout; no `2>/dev/null` or `|| true` in `oci.sh` outside lines annotated `# allow-silent: <reason>`. *Verify:* `tests/fast/store-oci.test.sh` case `stdout-clean` plus the F01 lint. *Tier:* fast.
- **I01-AC-14** — On master and manual dispatch, a 1 MiB body round-trips through real GHCR in class `build` under `ci-smoke/<run_id>`; on a fork PR (no token) the job reports "skipped" and the required-check script refuses to count that as success for a PR that changes `factory/lib/store/oci.sh`. *Verify:* CI job `store-oci-live`. *Tier:* slow.
- **I01-AC-15** — `ls <class> <global>/sets/` on a repository holding 3 sets and 200 blobs performs one tag listing and manifest fetches only for the 3 sets (asserted from the call log), returns the set keys sorted, and a prefix `<global>/sets/2026` returns only the matching sets. A prefix spanning directories still returns all matching keys. *Verify:* `tests/fast/store-oci.test.sh` cases `ls-dir-*`. *Tier:* fast.
- **I01-AC-16** — `locate <class> <key>` prints the tag, version id and manifest digest from a fake versions list and fails with exit 1 when the version carries a second tag. *Verify:* `tests/fast/store-oci.test.sh` cases `locate-*` (the fake serves the GHCR versions-list JSON shape recorded from the real API). *Tier:* fast.
- **I01-AC-17** — `rm <class> <key> --confirm` deletes exactly the version `locate` names, exits 3 on an absent key, exits 1 without `--confirm`, without a token, on a shared version and on an API error, and afterwards `has` exits 3. `ls --long` prints size and a `created_utc` matching `YYYY-MM-DDTHH:MM:SSZ`. *Verify:* `tests/fast/store-oci.test.sh` cases `rm-*`, `long-*`; the real round trip is in `store-oci-live` (AC-14's job deletes its own smoke object). *Tier:* fast + slow.
- **I01-AC-18** — With `STORE_OCI_USER` and `STORE_OCI_TOKEN` unset, `has`, `get`, `ls` and `store-adopted get` make no `login` call and succeed on a fixture registry; `put`, `init`, `rm` and `ls --long` exit 1 naming missing credentials without calling `push`; an anonymous 401 exits 1. *Verify:* `tests/fast/store-oci.test.sh` cases `anon-*`. *Tier:* fast.
- **I01-AC-19** — `store-adopted get builder|binpkg-seed` pulls by the digests in `pins.yaml: store.oci.adopted`, exits 5 and leaves nothing at `dest` when the registry answers a different digest, and never resolves a tag. *Verify:* `tests/fast/store-oci.test.sh` cases `adopted-*`. *Tier:* fast.
- **I01-AC-20** — The rc1 objects are present and readable anonymously: `oras manifest fetch --descriptor ghcr.io/tuckermclean/themonolith/builder@sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa` and the `binpkg-seed` digest `sha256:d0a1838d7504d41c95c050e70d0d5399dbf546dd2e21fdd5f793df2ad700b92d` resolve with no login, and the pulled seed layer is the predecessor's zstd tarball. *Verify:* CI job `store-oci-live`, step `adopted-rc1` (needs Step 0 done; fails with the missing digest named if it is not). *Tier:* slow.

## RED plan
Tester writes first, in `tests/fast/store-oci.test.sh`: the `auth-*`, `absent-*`, `retry-*`, `immutable-*`, `integrity-*` and `keys-*` cases, and `tests/fast/store-vendor-isolation.test.sh`, `tests/fast/install-oras.test.sh`, and the `ls-dir-*`, `locate-*`, `rm-*`, `long-*`, `anon-*` and `adopted-*` cases. They fail because `factory/lib/store/oci.sh` and the fake registry do not exist (backend dispatch returns "unknown backend"). The `fake-oras` fixture is part of the RED commit (it is test infrastructure, protected after RED per F04). The slow jobs are added GREEN-side.

## Risks and open questions
- GHCR may answer 401 for a never-pushed repository even when authenticated; `init` removes the first-read case but a revoked-then-restored package could still look the same. Surfaces as exit 1, which is the safe side.
- GHCR layer and package size limits (a layer limit of 10 GB was reported in GitHub docs; unverified here). The ISO (tens of MB) fits; do not assume it for future classes.
- `ls` on a whole `binpkg` global key (M03) fetches every blob manifest: about 300 per key, a few seconds with 8 in parallel (estimate). Directory-grouped tags make I06's set lookup cheap; M03 can avoid the slow path by listing sets and diffing against `repo tags`. Unverified: GHCR's tag-list page size and whether oras follows its pagination fully.
- `rm` and GHCR's limits on deleting versions of public packages are unverified (AC-17 live round trip settles them). Sharing a version across keys is excluded by the key annotation, but a manual retag could create it; `rm` refuses.
- Anonymous pull of a public GHCR package through oras needs a token exchange that oras performs itself; unverified here, settled by AC-20.
- Package visibility: the first push of each class repository creates a private package; the owner must make `store/*` public (and keep the Actions access grant). Listed in the runbook with `init`.
- GHCR storage billing: public packages have been free, private ones count against plan quota. Unverified; visibility is a decision tied to OD-1 and the distfile volume (I04, OD-5).
- Whether oras honours an explicit `created` annotation: proven only by AC-9.
- OD-7: if CI moves to Forgejo/Woodpecker the `oci` backend works against any OCI registry; only `install-oras` and auth wiring change.

## Cost
Three slices: (1) backend core, classification, fake registry, AC-1 to AC-8, AC-11 to AC-13; (2) directory tags, locate, rm, long, anonymous, adopted (AC-15 to AC-19); (3) installer, real-registry and live jobs, AC-3, AC-10, AC-14, AC-17 live, AC-20 (AC-9 later). CI cycles: about three short runs (minutes each), no 30 to 60 minute build. Money: GHCR storage (negligible for this node's tests; the `build`-class smoke objects expire under M03).

## Spec defects found
- SPEC §6 lists the `oras` pin in `pins/pins.yaml` (owner I05), but I05 depends on I03 and I01 needs the pin first. Resolution used here: I01 seeds its `tools.oras` and `store.oci` sections in the I05 format; I05 owns the schema and checks.
- SPEC §5 has no operation to read an object by digest, but I06 (seed) and I03 (adopted builder) must read the rc1 objects, which are plain OCI artifacts. This node adds `store-adopted get` as a backend-specific tool. SPEC §5 should list it as a declared exception next to the builder-image `docker push`.
- SPEC §5 says `ls --long` returns creation time. On `oci` the manifest `created` annotation is fixed (determinism), so the time comes from the GHCR versions API and needs `read:packages`. F06's contract must allow a backend to need credentials for `--long`.
