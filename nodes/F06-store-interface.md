# F06 — store-interface

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| F | F01 | I01 | — (feeds MS1) | M |

**Owns:** `factory/bin/store`, `factory/lib/store/core.sh`, `factory/lib/store/fs.sh`, `factory/lib/store/README.md` (backend interface), `tests/fast/store-contract.lib.sh` (the contract suite), `tests/fast/store-fs.test.sh`, `tests/fast/store-cli.test.sh`, `tests/fast/store-keys.test.sh`, `tests/fast/store-vendor.test.sh`
**Carries from linux-live-iso-factory@b9f533b:** nothing as code. Lessons only: `scripts/binpkg-store.sh:337-339` (the fail-open classifier) and `scripts/sync-portage.sh:33,44` (error swallowing) are the anti-patterns this node exists to prevent.
**Study refs:** T-binpkg-store-fail-open, T-portage-snapshot-fetch, T-gc-never-applied (store side), D-state-and-no-hidden-stderr, D-s3-publish-only (superseded by Principles 1 and 7), SPEC Principles 1 and 5, §5. Inventory ids `script.binpkg-store`, `script.sync-portage`, `script.s3-gc`, `script.ghcr-gc`, `ext.aws-s3`, `ext.ghcr`.

## Purpose
After F06, every durable byte in the system has one door: `factory/bin/store`. Its contract is small and strict: immutable puts, verified gets, and a hard line between "absent" (exit 3) and "broken" (any other failure). A filesystem backend and a shared contract suite exist, so the OCI backend (I01) and the public backend (P01) are accepted by passing the same tests rather than by trust. This is the rebuild's answer to the account that died: no workflow will name a vendor again.

## Scope
In:
- The CLI `factory/bin/store`: operations, arguments, exit codes, stderr rules.
- Class and key validation for the five SPEC §5 classes.
- The backend plugin interface and the `fs` backend.
- The contract test suite, a reusable library every backend's test file calls.
- A vendor-name lint that keeps storage providers out of everything except backend code.
- The store-class parts of `docs/system.yaml` (with F03).

Out:
- The OCI backend and `oras` pinning: I01. The `public` backend, CORS and Range: P01 (OD-1).
- Retention and GC (a `delete` operation): M03 (see Spec defects).
- What goes in each class, the distfile name index, the binpkg tree hash: I02, I04, B01.
- Authentication setup in CI: each backend's node.
- Replacing Actions artifacts and caches used within one run (SPEC §4.1): B06.

## Design

### CLI
`factory/bin/store <op> <class> ...`, POSIX `sh` (tested under `dash` and `bash`), needing `sha256sum`, `mktemp`, `ln`, `mv`, `find`, `sort`. No other dependencies.

| Operation | Arguments | stdout | Success | Absent |
|---|---|---|---|---|
| `put` | `<class> <key> <file>` | nothing | exit 0; stores the file; same body already present is a no-op exit 0 | n/a |
| `get` | `<class> <key> <dest>` | nothing | exit 0; verified bytes written to `<dest>` | exit 3, `<dest>` untouched |
| `has` | `<class> <key>` | nothing | exit 0 if present | exit 3 |
| `ls` | `<class> <prefix>` | matching keys, one per line, sorted bytewise (`LC_ALL=C`) | exit 0, even when no key matches (empty output) | n/a |
| `url` | `<class> <key>` | the public URL | exit 0 for class `public` and present key | exit 3 if the key is absent; exit 6 for any other class |

`<prefix>` is a plain string prefix of the key, not a directory; `""` lists everything in the class. `has` and `get` never create anything. `put` refuses an empty file (exit 2); an empty body is nearly always a bug (Principle 5). Rejected: allowing empty bodies with a flag; no current class needs one.

Exit codes. 0 success. 3 absent (only `has`, `get`, `url`). 2 usage error or invalid class or key (nothing was touched). 4 integrity failure: a stored body does not match its recorded sha256, or a content-addressed key does not match the body. 5 immutability conflict: `put` of a different body under an existing key. 6 operation not supported for this class or backend. 1 any other failure (I/O, permissions, authentication, network, backend crash). Callers must treat only 3 as "absent" and everything else non-zero as an error. Rejected: a dedicated exit code per backend failure kind; callers need only absent versus broken.

Streams. stdout carries only the data in the table. Every diagnostic goes to stderr as one line `store: <op> <class>/<key>: <message>` (key omitted when not yet parsed). `factory/bin/store` and the backends never redirect a command's stderr to `/dev/null` (F01's `stderr-hiding` rule applies without a baseline). A backend's own tool output is passed through to stderr.

Environment. `STORE_BACKEND` names the backend (`fs`, later `oci`, `public`); unset is exit 2 with a message (no silent default). `STORE_BACKEND_<CLASS>` (class upper-cased, for example `STORE_BACKEND_PUBLIC=public`) overrides it for one class, which is how `public` lives on a different host from `binpkg`. `STORE_ROOT` is the `fs` backend's directory (required for `fs`; created on first `put`, must be absolute). `STORE_TRACE=1` prints each backend call to stderr. Rejected: a config file (one more input to pin and review; a handful of variables is enough).

### Classes and keys
Classes: `snapshot distfile binpkg build public`. An unknown class is exit 2. Keys are validated before any backend call:
- Common: 1 to 512 bytes; segments separated by single `/`; no leading or trailing `/`; no empty, `.` or `..` segment; each segment matches `[A-Za-z0-9._@+=-]+` and does not start with `.`. This blocks traversal and keeps every backend's key space portable. Case-insensitive collision is not detected here (the fs backend refuses a key whose lower-cased form already exists with a different spelling; exit 5).
- `snapshot`: `gentoo-<8 digits>.tar.xz` or the same with `.gpgsig` appended.
- `distfile`: `sha256/<64 lowercase hex>` (content-addressed) or `names/<name>` (a pointer file; I04 defines its body). For `sha256/<hex>` keys `put` and `get` check that the body's sha256 equals `<hex>` (exit 4 otherwise). Content-addressed means the key is the proof.
- `binpkg`: `<tree-hash>/<profile-hash>/<cpv>.gpkg.tar` where both hashes are 12 to 64 lowercase hex and `<cpv>` may contain `/` (a Portage category and name).
- `build`: `builds/<version>/<file>`.
- `public`: free-form under the common rules.
Rejected: accepting any key in every class (typos then become silent new keys; a shape check costs little).

### Integrity and immutability
The core (`core.sh`), not the backend, computes and verifies hashes, so a backend cannot forget. `put` computes the sha256 of the file once, asks the backend `stat` for the key, and: absent, store; present with the same sha256, succeed without writing; present with a different sha256, exit 5. `get` fetches to a temporary file beside `<dest>`, computes its sha256, compares with the backend's recorded sha256 (and with the key for content-addressed keys), and only then renames onto `<dest>`. On mismatch: exit 4 and nothing at `<dest>`, and the temporary file is removed. A failed or interrupted `get` never leaves a partial `<dest>`. Rejected: trusting an ETag or size (size equality does not detect corruption; ETag is not always a sha256).

### Backend plugin interface
A backend is a shell file `factory/lib/store/<name>.sh` defining these functions. The core sources it after parsing the arguments. A function returns the exit code classes above (3 for absent only where noted), writes diagnostics to stderr, and writes to stdout only where noted.

| Function | Contract |
|---|---|
| `backend_init` | Validate configuration (for example `STORE_ROOT`); return 1 with a message if unusable. Called once. |
| `backend_stat CLASS KEY` | Print `<sha256> <size>` of the stored body and return 0; return 3 if the key is absent; any other failure returns 1. |
| `backend_put CLASS KEY FILE SHA256` | Store atomically, immutably: it must not replace an existing key. If the key appeared concurrently with the same sha256, return 0; with a different one, return 5. |
| `backend_get CLASS KEY DEST` | Copy the stored body to `DEST` (a new temp path). Return 3 if absent, 1 on any other error. Does not verify. |
| `backend_ls CLASS PREFIX` | Print keys, one per line, in any order (the core sorts); return 0 with no output when none match. |
| `backend_url CLASS KEY` | Print the URL, or return 6 when the class has none. |
| `backend_caps` | Print the supported optional faults for the contract suite (below), one per line. |

A backend must classify authentication, network and permission errors as return 1, never 3. For a backend whose tool reports "not found" and "denied" with the same text, it must disambiguate (for example by a separate existence call) or return 1; guessing "absent" is a contract violation. The old `oras pull` classifier (`scripts/binpkg-store.sh:337-339`) treats `unauthorized|denied|401` as a benign miss; it is the counter-example (T-binpkg-store-fail-open).

### `fs` backend
Layout under `$STORE_ROOT`: `data/<class>/<key>` (the body) and `meta/<class>/<key>.sha256` (one line, `<sha256> <size>`). `put` writes the body to `tmp/<unique>` on the same filesystem, then publishes the body with `ln` (hard link; `EEXIST` is the atomic immutability check), then publishes the meta file the same way; the meta link is the commit point. `backend_stat` reads the meta file; a body without meta is "not committed" (absent for `has`), and a later `put` completes or compares it. A meta file whose body is missing is an integrity error (exit 4 from the core when `get` finds no body for a committed key, not exit 3). `ls` walks `data/<class>/` and lists only keys with a meta file, so partial puts are invisible. Directory creation is idempotent. File mode `0444`; directories `0755`. Concurrent identical puts both succeed; concurrent different puts: exactly one wins and the other gets exit 5. Rejected: sidecar next to the body in one tree (a key named `x.sha256` would collide); a database (a dependency).

### Contract suite
`tests/fast/store-contract.lib.sh` defines `run_store_contract`, which a backend's test file sources and calls after defining the hooks below. The suite runs every case against `factory/bin/store` as a black box (so the CLI and the backend are both under test), and prints one `PASS|FAIL <case>` per case. Hooks:
- `contract_setup`: prepare an empty store and export the `STORE_*` environment.
- `contract_teardown`.
- `contract_inject FAULT`: put the backend into a fault state for the next calls; `FAULT` is one of `corrupt` (alter a stored body at rest), `auth` (credentials rejected), `network` (endpoint unreachable), `permission` (read or write denied). `contract_clear` removes the fault.
- `backend_caps` lists the faults the backend can inject. `corrupt` and `permission` are mandatory for any backend that stores bytes; `auth` and `network` are mandatory for every backend that talks over a network. A backend that cannot inject a mandatory fault fails the suite; "skipped" is reported as `FAIL`, never silently passed. I01 supplies a fake `oras` that can produce 401 and connection refused.

Cases (each also asserts that stdout is empty where the table says so, and that stderr is non-empty on every failure):
1. put/get round trip is byte-identical (binary data with NUL and a 5 MiB body); `has` returns 0; `ls` shows the key.
2. `has`, `get` and `url` on an absent key return exactly 3; `ls` of a missing prefix returns 0 with empty output; `get` leaves `<dest>` untouched.
3. Putting the same body twice returns 0 both times.
4. Putting a different body under an existing key returns 5, and the stored body is unchanged.
5. `get` after `corrupt` returns 4 and `<dest>` does not exist; the corrupt object is not returned by a retry.
6. A content-addressed distfile key with the wrong body is rejected on `put` (4) and on `get`.
7. Under `auth`, `network` and `permission` faults, `has`, `get` and `put` each return a non-zero code that is not 3 and print a message (never a hit, never a miss).
8. Invalid class, invalid keys (`..`, leading `/`, empty segment, over 512 bytes), wrong binpkg shape: exit 2 with no backend call (checked by tracing).
9. `put` of an empty or missing file: exit 2.
10. `ls` returns bytewise-sorted keys and honours the prefix.
11. A failed `get` (injected mid-copy) leaves no partial `<dest>` and no stray temp file.
12. Concurrent `put` of the same key, same body, from 8 processes: all succeed; with 8 different bodies: exactly one succeeds, seven return 5.
13. `url` on a non-public class returns 6.
14. The CLI never writes to stdout for `put`, `has`, `get`, and prints no output at all when `STORE_TRACE` is unset.

`tests/fast/store-fs.test.sh` calls the suite with the `fs` hooks (`contract_inject corrupt` rewrites a body with `chmod u+w`; `permission` uses `chmod 000` on the data directory, skipped with a failure if the test runs as root — the test refuses to run as root). A new backend's node adds `tests/fast/store-<name>.test.sh` of the same shape, and F03's inventory lists it.

### Vendor lint
`tests/fast/store-vendor.test.sh` fails if any tracked file other than `factory/lib/store/*.sh`, `docs/**`, `nodes/**`, `SPEC.md`, `tests/**`, `tools/system/rules.yaml` and `docs/study/**` contains a provider-specific storage invocation: `aws s3`, `s3://`, `oras `, `gh release upload`, `gh release download`, `rclone`, `r2.cloudflarestorage`, `amazonaws.com`. Allowed exceptions are listed in `factory/lib/store/vendor-allow.txt` with a reason (for example I03 pulling a builder image with `docker pull ghcr.io/...`, which is an image registry and not the store; B06's `gh release create` belongs to P02, whose workflow path is added to the allow list by that node). Principle 1 depends on this.

## Traps and doctrines preserved
- T-binpkg-store-fail-open: `oras pull` treated 401/denied as a benign miss and the build silently lost the cache (`scripts/binpkg-store.sh:337-339`, `:451`). Prevented by F06-AC-5 and F06-AC-9 (auth is never absence) and carried into I01 by the contract suite.
- Silent S3 error handling: `aws s3 cp ... >/dev/null 2>&1` made any S3 error look like a miss, then fell back to upstream and quietly skipped archiving (`scripts/sync-portage.sh:33,44`; study: "Auth failures on a disabled account would look like 'not in S3'"). Prevented by F06-AC-5, F06-AC-7 and the stderr rule.
- T-portage-snapshot-fetch: a missing pinned snapshot must be loud. F06 provides the exit code (3 vs other); I02 uses it to fail the build rather than fall back.
- Principle 1 (no vendor names): F06-AC-11.
- Principle 5 (honest success): get verifies; empty input rejected: F06-AC-3, F06-AC-4.
- D-state-and-no-hidden-stderr: F06-AC-10.
- T-gc-never-applied (printing DELETE lines without deleting): no delete operation is in this node; M03 designs it with the same contract suite style. See defects.

## Gate
- **F06-AC-1** — The CLI implements `put`, `get`, `has`, `ls`, `url` with the argument shapes, stdout rules and exit codes (0, 2, 3, 4, 5, 6, 1) in the table; a missing `STORE_BACKEND` or unknown backend exits 2 with a message. *Verify:* `tests/fast/store-cli.test.sh`. *Tier:* fast.
- **F06-AC-2** — Class and key validation: the five classes, the common key rules, and per-class shapes (snapshot, distfile `sha256/` and `names/`, binpkg, build) accept valid keys and reject invalid ones with exit 2 before any backend call. *Verify:* `tests/fast/store-keys.test.sh`. *Tier:* fast.
- **F06-AC-3** — `put` is immutable: same body is a no-op (exit 0), a different body under an existing key exits 5 and leaves the stored body unchanged; an empty or missing file exits 2; a distfile `sha256/<hex>` key must match the body. *Verify:* contract cases 3, 4, 6, 9 via `tests/fast/store-fs.test.sh`. *Tier:* fast.
- **F06-AC-4** — `get` verifies the recorded sha256 and the content-addressed key: a body altered at rest exits 4 and leaves nothing at `<dest>`; a failed `get` leaves no partial `<dest>` or temp file. *Verify:* contract cases 5, 6, 11 via `tests/fast/store-fs.test.sh`. *Tier:* fast.
- **F06-AC-5** — `has`, `get` and `url` return exactly 3 for an absent key, and permission, auth or network faults never return 3 nor 0 (a message on stderr, non-zero other than 3). *Verify:* contract cases 2 and 7. *Tier:* fast.
- **F06-AC-6** — The `fs` backend implements the plugin interface (`backend_init`, `stat`, `put`, `get`, `ls`, `url`, `caps`), is atomic (hard-link publish, meta file as commit point), hides partial puts from `has` and `ls`, and survives 8 concurrent puts as specified. *Verify:* contract case 12 and `tests/fast/store-fs.test.sh` partial-put cases. *Tier:* fast.
- **F06-AC-7** — The contract suite `tests/fast/store-contract.lib.sh` exists, runs all 14 cases, takes its backend through the hooks, reports an unsupported mandatory fault as FAIL, and is the only acceptance test a new backend needs. *Verify:* `tests/fast/store-fs.test.sh` plus `tests/fast/store-contract-meta.test.sh` (a deliberately broken fake backend that returns 3 on auth errors must fail the suite). *Tier:* fast.
- **F06-AC-8** — `ls` returns bytewise-sorted keys with prefix semantics, exits 0 with empty output for no match, and `url` on a non-public class exits 6. *Verify:* contract cases 10 and 13. *Tier:* fast.
- **F06-AC-9** — A fake backend that maps "denied" to absent is rejected by the suite (case 7), and `docs`/comment text in `factory/lib/store/README.md` states that rule. *Verify:* `tests/fast/store-contract-meta.test.sh`. *Tier:* fast.
- **F06-AC-10** — stdout carries only requested data and stderr is never suppressed: `put`, `has`, `get` print nothing on stdout; every failure prints a `store: ...` line; `factory/bin/store`, `core.sh` and `fs.sh` contain no stderr redirect to `/dev/null` and pass F01's `stderr-hiding` rule with no baseline; the tool runs under `dash` and `bash`. *Verify:* contract case 14 and `tests/fast/store-cli.test.sh`. *Tier:* fast.
- **F06-AC-11** — No tracked file outside the backend directory, docs, tests and listed exceptions names a storage provider tool or host. *Verify:* `tests/fast/store-vendor.test.sh`. *Tier:* fast.
- **F06-AC-12** — `docs/system.yaml` lists the five `store.*` classes and `script.store`; the F03 check passes with F06 present; `factory/lib/store/README.md` documents the interface and tells a backend author to add `tests/fast/store-<name>.test.sh`. *Verify:* `make system-check` and `tests/fast/store-docs.test.sh`. *Tier:* fast.

## RED plan
The tester first writes `tests/fast/store-contract.lib.sh` as a library with its cases, `store-fs.test.sh` that sets up the `fs` hooks and calls it, and the CLI and key tests. Before implementation `factory/bin/store` does not exist: every case's invocation returns 127, which the helper counts as an assertion failure, so the first RED lists every case as failed (valid RED, no stubs). `store-contract-meta.test.sh` ships a fake broken backend inside `tests/fast/fixtures/store/` and asserts that the suite fails on it; it is part of the same RED because it also needs the implemented core to run. Slices: (1) CLI, keys, core, AC-1, AC-2; (2) fs backend and contract cases, AC-3 to AC-6, AC-8; (3) suite quality, vendor lint, docs, AC-7, AC-9 to AC-12. Concurrency case 12 is the likeliest to flake; it runs 8 processes with a bounded wait and no sleeps.

## Risks and open questions
- Hard-link publish needs one filesystem for `tmp/` and `data/`; the fs backend refuses to start if `STORE_ROOT` spans mounts (checked in `backend_init`). NFS and some FUSE mounts weaken `ln` atomicity; the fs backend is for tests and local dev (SPEC §5), not CI storage.
- OCI cannot offer `ln`-style atomic create. I01 must use a conditional push (tag by digest, check existence first) and accept a small race on same-key different-body puts, or use content-addressed tags. The contract case 12 for the OCI backend may need a weaker form for the "different body" race; that decision is I01's and must be recorded as a SPEC exception, not a quiet skip.
- Key shape rules fix I02, I04 and B01 formats early. If a class shape is wrong, change the shape here, with the failing consumer's test.
- `distfile names/<name>` pointers conflict with immutability if a name's target changes. I04 must make names versioned or accept that a pinned name never repoints.
- Whether `get` should support `--range` or streaming to stdout (for big ISOs) is deferred; the ISO demo (P04) uses the public URL, not the CLI.
- POSIX `sh` limits (no arrays, no `local` in strict dash): acceptable at this size; OD-3 allows a Python store CLI if the shell version proves unmaintainable. Not recommended: Python would be an extra dependency on every runner step that touches the store.

## Cost
Three slices, 12 ACs; size M because of the shared contract suite and concurrency tests. Fast lane only, about two runs per slice. No build cycles. No storage or hosting cost: the fs backend writes to a temp directory. I01 and P01 will cost money (GHCR/R2 storage); not this node.

## Spec defects found
- SPEC §5 has no `delete` operation and `ls` returns no age, but M03 (retention and GC) must remove objects and apply "until tree superseded + 30 d", and Principle 1 says nothing else may call a provider CLI. Proposal: add `delete <class> <key>` and `ls --long` (key, size, mtime) to the SPEC §5 contract and to the contract suite before I01, so that I01 implements them once. M03 would otherwise need a backdoor.
- SPEC §5 says "`url <class> <key>` (public only)" but does not say what a `has`-style absent key returns for `url`. F06 decides: exit 3.
- SPEC §5 `binpkg` key `<tree-hash>/<profile-hash>/<cpv>.gpkg.tar` and the `distfile` "name index" are not precise (hash length, index body). F06 fixed the hash length range and left the index body to I04.
- SPEC §4.2 puts the store CLI at `factory/bin/store`; backends need a home. F06 uses `factory/lib/store/`, which SPEC §4.2 should list.
- Graph: P01 depends on I01 but F06 is the node that defines the `public` class semantics (`url`). OD-1 does not block F06. No change needed, noted for completeness.
