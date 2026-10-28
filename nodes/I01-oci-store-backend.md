# I01 — oci-store-backend

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| I | F06 | I02, I03, I04, P01, M03 | — (needed for MS2) | M |

**Owns:** `factory/lib/store/oci.sh` (the `oci` backend), `factory/bin/install-oras`, `tests/fast/store-oci.test.sh`, `tests/fast/install-oras.test.sh`, `tests/fast/store-vendor-isolation.test.sh`, `tests/fast/fixtures/fake-oras` (a directory-backed fake registry plus error injection), CI job `store-oci-registry` and `store-oci-live` (in the F01/B06 workflow files, listed in `docs/system.yaml`), the `store.oci` and `tools.oras` sections of `pins/pins.yaml` (format in I05).
**Carries from linux-live-iso-factory@b9f533b:** the oras usage pattern in `scripts/binpkg-store.sh` (push from the blob's directory at :415-424, pull at :437-455). The fail-open logic at :324-338 is deliberately NOT carried. The oras install snippet at `.github/workflows/build.yml:231-240` is carried and hardened (checksum added).
**Study refs:** T-binpkg-store-fail-open, D-supply-chain-honesty, Principle 1 and 5, `ext.ghcr`, `script.binpkg-store`, build.yaml silent_fallbacks ("binpkg-store.sh pull: missing oras, or 401/denied/404/etc -> empty cache, exit 0"), workflows.yaml pins_summary (oras 1.2.0 "pinned-version-no-checksum").

## Purpose
After this node the `store` CLI can keep durable bytes in GHCR through a pinned `oras`, and passes the same contract suite as the `fs` backend. The predecessor treated any 401 or "denied" from GHCR as "nothing published yet" and carried on with an empty cache. That behaviour hid auth failures and is the pattern SPEC §2.5 forbids. This backend separates "absent" (exit 3) from every other failure.

## Scope
In:
- Backend `oci` selected by `STORE_BACKEND=oci`: `put`, `get`, `has`, `ls`, plus `init <class>` (create repo, write sentinel).
- Key-to-tag encoding, manifest annotations, deterministic manifests, retry policy, error classification.
- A pinned, checksum-verified `oras` installer.
- A fake `oras` for the fast tier; a real-registry slow job (`registry:2` by digest) and a live GHCR smoke job.

Out:
- The contract suite itself, the `fs` backend and the CLI dispatcher: F06.
- `url` for the `public` class and any HTTP-served hosting: P01.
- Deleting objects (`rm`) and retention: M03. The contract has no delete operation (see Spec defects).
- Which keys exist per class (binpkg key layout, distfile index): B01, I02, I04.
- Docker image push of the builder image: I03.

## Design
**Configuration (environment).**
`STORE_BACKEND=oci`; `STORE_OCI_PREFIX` (default from `pins.yaml: store.oci.prefix`, e.g. `ghcr.io/tuckermclean/monolith-store`); `STORE_OCI_USER`, `STORE_OCI_TOKEN` (in Actions: `github.actor`, `GITHUB_TOKEN` with `packages: write`); `STORE_RETRY` (default 3), `STORE_RETRY_SLEEP` (default 5, doubling; tests set 0); `ORAS` (binary path, tests point it at the fake).
The workflow files name no registry. Only `factory/lib/store/oci.sh`, `factory/bin/builder-image` (image registry, I03), `pins/` and `docs/` may contain `ghcr.io` or `oras`.

**Repository layout.** One OCI repository per class: `${STORE_OCI_PREFIX}-<class>`, e.g. `…/monolith-store-snapshot`.
Rejected: one repository with the class in the tag. Visibility, retention (M03) and permissions are per repository.

**Key to tag.** OCI tags allow `[A-Za-z0-9_][A-Za-z0-9._-]{0,127}`; store keys contain `/` and run to 200+ characters (binpkg: `<tree>/<profile>/<cpv>.gpkg.tar`). Tag = `k-` + lowercase hex `sha256(key)` (66 characters). The original key is stored in the annotation `org.themonolith.store.key`.
Rejected: reversible escaping of the key into the tag; it breaks the 128-character limit for binpkg keys.

**Object shape.** `oras push --artifact-type application/vnd.themonolith.store.v1 <repo>:<tag> blob:application/octet-stream`, run from a temp directory where the body is hard-linked or copied as `blob` (no absolute paths, the T-binpkg-store-fail-open push bug). Annotations: `org.themonolith.store.key`, `.sha256` (of the body), `.size`, `.class`, and `org.opencontainers.image.created=1970-01-01T00:00:00Z` (fixed, so the same body yields the same manifest digest; the 1970 origin is the project's clock sentinel, D-clock-origin-1970). Whether oras lets an explicit `created` annotation override its default is to be proven by AC-9 against real oras.

**Operations.**
- `has <class> <key>`: `oras manifest fetch --descriptor <repo>:<tag>`. Exit 0 present, 3 absent, else per the table below.
- `put <class> <key> <file>`: `has`; if present, compare the `.sha256` annotation with `sha256(file)`: equal gives exit 0 with no push call; different gives exit 4 (immutability conflict) with both digests on stderr. If absent, push, then re-resolve the tag and fail (exit 1) if its manifest digest differs from the locally computed expectation (detects a lost race: GHCR has no conditional put).
- `get <class> <key> <dest>`: pull into a temp dir beside `dest`, verify `sha256(blob)` against the annotation (exit 5 on mismatch, nothing left at `dest`), for `distfile` keys `sha256/<hex>` also verify `<hex>`, then `mv` into place. `dest` never exists half-written.
- `ls <class> <prefix>`: `oras repo tags`, then fetch the key annotation of each `k-` tag (8 in parallel), print keys matching the prefix, sorted. O(n) manifest fetches; acceptable for M03 and `distfile`/`snapshot` sizes, unknown for `binpkg` (open question).
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

**Secrets.** Login uses `oras login --password-stdin`; the token is never an argument and never echoed; the script never runs with `set -x`. Credentials are never passed into build containers (the store runs on the runner).

**oras pin.** `factory/bin/install-oras` downloads `https://github.com/oras-project/oras/releases/download/v<ver>/oras_<ver>_linux_amd64.tar.gz`, verifies the sha256 from `pins.yaml: tools.oras` (predecessor used 1.2.0 with no checksum, `build.yml:234`), and installs to `$HOME/.local/bin`. Version choice at implementation time; 1.2.0 remains the known-good baseline.

**stdout.** Only requested data goes to stdout (`ls` keys). `put`, `has`, `get`, `init` print nothing to stdout. Diagnostics go to stderr and are never redirected to `/dev/null`.

**Fake registry for the fast tier.** `tests/fast/fixtures/fake-oras` is a POSIX sh script implementing `login`, `push`, `manifest fetch`, `pull`, `repo tags` over a directory, with `FAKE_ORAS_FAIL=<op>:<http-status>` injection and a call log (`FAKE_ORAS_LOG`). The contract suite (F06) runs against it with `ORAS=…/fake-oras`.

**GHCR facts to respect.** A package created by `oras push` is private and must be granted to the repository (Package settings, "Manage Actions access", write role) or `GITHUB_TOKEN` gets 403. This yields exit 1, never 3. Documented in the runbook section of `docs/decisions/` (ADR for the store layout).

## Traps and doctrines preserved
- **T-binpkg-store-fail-open** (401/denied treated as a miss, empty cache, green build): AC-4, AC-5, AC-6. The old oras absolute-path push bug: AC-8.
- **D-supply-chain-honesty / Principle 5**: auth and network errors are failures: AC-4, AC-6.
- **Principle 1** (storage is an interface): AC-1.
- **Principle 2** (tools pinned): AC-10.
- **D-state-and-no-hidden-stderr**: AC-13.

## Gate
- **I01-AC-1** — `ghcr.io` and `oras` appear only in the allowlisted files (`factory/lib/store/oci.sh`, `factory/bin/builder-image`, `pins/`, `docs/`, `tests/`). *Verify:* `tests/fast/store-vendor-isolation.test.sh` (greps the tree; a fixture with a stray `oras push` in a workflow makes it fail). *Tier:* fast.
- **I01-AC-2** — The F06 contract suite passes with `STORE_BACKEND=oci ORAS=tests/fast/fixtures/fake-oras`. *Verify:* `tests/fast/store-oci.test.sh` (invokes the suite entry point named by F06). *Tier:* fast.
- **I01-AC-3** — The same contract suite passes against real `oras` and a real registry (`registry:2` service container pinned by digest). *Verify:* CI job `store-oci-registry`. *Tier:* slow.
- **I01-AC-4** — With injected 401 or 403 on any request, `has`, `get` and `put` exit non-zero and not 3, for both an existing and a never-written key, and print the HTTP status to stderr. *Verify:* `tests/fast/store-oci.test.sh` cases `auth-*`. *Tier:* fast.
- **I01-AC-5** — A 404 on a key exits 3 only when the class sentinel was read in the same process; with the sentinel missing it exits 1 with "store not initialised". *Verify:* `tests/fast/store-oci.test.sh` cases `absent-*`. *Tier:* fast.
- **I01-AC-6** — Injected 5xx or timeout is retried `STORE_RETRY` times, then exits 1; the exit status is never 3 and the retry count is asserted from the call log. *Verify:* `tests/fast/store-oci.test.sh` cases `retry-*`. *Tier:* fast.
- **I01-AC-7** — `put` of a different body under an existing key exits 4 and leaves the stored object unchanged (tag digest identical before and after); `put` of the same body exits 0 and the call log contains no `push`. *Verify:* `tests/fast/store-oci.test.sh` cases `immutable-*`. *Tier:* fast.
- **I01-AC-8** — `get` of a corrupted blob exits 5 and leaves nothing at `dest`; `get` verifies `sha256/<hex>` keys against `<hex>`; push uses no absolute path. *Verify:* `tests/fast/store-oci.test.sh` cases `integrity-*`, `push-relpath`. *Tier:* fast.
- **I01-AC-9** — Two `put`s of the same body from different directories and times produce the same manifest digest. *Verify:* CI job `store-oci-registry` (`oras manifest fetch --descriptor` twice, compare). *Tier:* slow.
- **I01-AC-10** — `install-oras` installs only the version and sha256 in `pins.yaml: tools.oras`; a wrong checksum or a missing pin exits non-zero and installs nothing. *Verify:* `tests/fast/install-oras.test.sh` (local `file://` tarball override). *Tier:* fast.
- **I01-AC-11** — With `STORE_OCI_TOKEN=SECRET-TOKEN-SENTINEL`, the string appears nowhere in stdout, stderr or the fake's call log arguments. *Verify:* `tests/fast/store-oci.test.sh` case `no-secret-leak`. *Tier:* fast.
- **I01-AC-12** — A corpus of keys (200+ characters, slashes, `+`, uppercase, the §5 key shapes for all five classes) encodes to valid tags of at most 128 characters, injectively, and `ls <class> <prefix>` returns the original keys sorted. *Verify:* `tests/fast/store-oci.test.sh` cases `keys-*`. *Tier:* fast.
- **I01-AC-13** — `put`, `has`, `get`, `init` write nothing to stdout; no `2>/dev/null` or `|| true` in `oci.sh` outside lines annotated `# allow-silent: <reason>`. *Verify:* `tests/fast/store-oci.test.sh` case `stdout-clean` plus the F01 lint. *Tier:* fast.
- **I01-AC-14** — On master and manual dispatch, a 1 MiB body round-trips through real GHCR in class `build` under `ci-smoke/<run_id>`; on a fork PR (no token) the job reports "skipped" and the required-check script refuses to count that as success for a PR that changes `factory/lib/store/oci.sh`. *Verify:* CI job `store-oci-live`. *Tier:* slow.

## RED plan
Tester writes first, in `tests/fast/store-oci.test.sh`: the `auth-*`, `absent-*`, `retry-*`, `immutable-*`, `integrity-*` and `keys-*` cases, and `tests/fast/store-vendor-isolation.test.sh`, `tests/fast/install-oras.test.sh`. They fail because `factory/lib/store/oci.sh` and the fake registry do not exist (backend dispatch returns "unknown backend"). The `fake-oras` fixture is part of the RED commit (it is test infrastructure, protected after RED per F04). The slow jobs are added GREEN-side.

## Risks and open questions
- GHCR may answer 401 for a never-pushed repository even when authenticated; `init` removes the first-read case but a revoked-then-restored package could still look the same. Surfaces as exit 1, which is the safe side.
- GHCR layer and package size limits (a layer limit of 10 GB was reported in GitHub docs; unverified here). The ISO (tens of MB) fits; do not assume it for future classes.
- `ls` cost on `binpkg` (thousands of tags): M03 may need an index object. Defer to M03.
- GHCR storage billing: public packages have been free, private ones count against plan quota. Unverified; visibility is a decision tied to OD-1 and the distfile volume (I04, OD-5).
- Whether oras honours an explicit `created` annotation: proven only by AC-9.
- OD-7: if CI moves to Forgejo/Woodpecker the `oci` backend works against any OCI registry; only `install-oras` and auth wiring change.

## Cost
Two slices: (1) backend core, classification, fake registry, AC-1 to AC-8, AC-11 to AC-13; (2) installer, real-registry and live jobs, AC-9, AC-10, AC-14. CI cycles: about three short runs (minutes each), no 30 to 60 minute build. Money: GHCR storage (negligible for this node's tests; the `build`-class smoke objects expire under M03).

## Spec defects found
- The store contract (SPEC §5) has no delete operation, but M03 (deps: I01 only) must prune classes. GHCR deletes need the GitHub packages API, not OCI. A `store rm` operation must be added to F06 and to this backend, or M03 must own a provider-specific path in violation of Principle 1.
- SPEC §6 lists the `oras` pin in `pins/pins.yaml` (owner I05), but I05 depends on I03 and I01 needs the pin first. Resolution used here: I01 seeds its `tools.oras` section in the I05 format; I05 owns the schema and checks.
- SPEC §5 says "Nothing else may call a storage provider's CLI", yet §4.1 puts the builder image in GHCR by digest and I03 must `docker push`. Treated as a declared exception (images are derived data, rebuildable from the store); SPEC should say so.
