# M03 — retention-and-gc

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| M | I01 | X01 | — | M |

**Owns:** `factory/retention.yaml`, `factory/bin/store-gc`, `factory/lib/retention.py`, `.github/workflows/gc.yml`, `docs/retention.md`, `tests/fast/store-gc.test.sh`, `tests/fast/test_retention.py`, `tests/fast/gc-workflow.test.sh`, `tests/fast/store-gc-fixtures/`, and the `rm` / `ls --long` additions to the F06 contract suite (`tests/contract/store/` or wherever F06 puts it; coordinated, see defects).
**Carries from linux-live-iso-factory@b9f533b:** `scripts/s3-gc.sh` (the abort-on-empty-keep-list guard, captured-listing loop, KEEP-first default, exit-0 rule at :70-77), `scripts/ghcr-gc.sh` (auth-versus-not-found error discrimination at :64-84, the zero-listing NOTE, multi-tag verdict at :19-33), `.github/workflows/gc.yml` (apply on schedule, dry-run on dispatch unless `apply`), `scripts/tests/s3-gc.test.sh`, `scripts/tests/ghcr-gc.test.sh` (cases only; the S3 half is dead).
**Study refs:** workflows.yaml `wf.gc`, `job.gc.gc`; doctrine.yaml T-gc-never-applied, T-binpkg-store-fail-open, T-run-rerun-reuses-cache, DEC-releases-immutable-tags; oracle.yaml open_questions (which tests die with S3); SPEC §5 retention table, Principle 5 and 7.

## Purpose
After this node the store has a written, machine-readable retention policy per class and a garbage collector that applies it. The collector is dry-run unless told otherwise, refuses to touch the classes whose loss would make a release unreproducible, and treats every listing or auth error as a failure rather than "nothing to delete". The predecessor's weekly GC printed `DELETE` lines for months and deleted nothing (T-gc-never-applied).

## Scope
In:
- `factory/retention.yaml`, a policy file with one rule per store class.
- `factory/bin/store-gc`: classifies keys, reports, and (with `--apply`) deletes through the store contract.
- Contract additions the GC needs: `store rm` and `store ls --long`.
- The weekly workflow with explicit apply on schedule and a report artifact.
- Tests with synthetic listings against the `fs` backend; no network.
Out:
- The store CLI itself and the `fs` backend: F06. The `oci` backend, including how a key deletion maps to a GHCR package-version delete: I01. The `public` backend: P01.
- Pruning distfiles by reference: no node owns it today (see defects); this node ships the class as protected.
- Actions artifacts, Actions caches and GHCR builder-image tags. Actions artifacts expire by their own `retention-days` set in B06; builder-image tag lifecycle is I03/M02.
- Deleting releases or tags. Never done by any automation.

## Design

### Interface additions (extension of SPEC §5)
Two additions to the store contract, to be added to the F06 suite and implemented by every backend: `store rm <class> <key>` (exit 0 deleted, 3 absent, other non-zero error) and `store ls --long <class> <prefix>`, which prints `<key>\t<size_bytes>\t<created_utc>` where `created_utc` is `YYYY-MM-DDTHH:MM:SSZ`. `store rm` refuses (exit 4, stderr message) classes marked `protected` in `factory/retention.yaml`; the refusal lives in the CLI wrapper, so no backend can bypass it. Rejected: giving the GC direct backend access (breaks SPEC §5 "nothing else may call a storage provider's CLI").

### `factory/retention.yaml`
```yaml
version: 1
classes:
  snapshot: {protected: true}                       # forever (SPEC §5)
  distfile: {protected: true}                       # forever while referenced; reference scan not built
  public:   {protected: true}                       # per P01; no automatic deletion
  binpkg:
    rule: tree-superseded
    grace_days: 30
    live_trees_from: [master, open-pin-prs]         # see below
  build:
    rule: age-unless-tag
    max_age_days: 30
    tag_pattern: '^v?[0-9]+\.[0-9]+\.[0-9]+(-(rc|beta)[0-9]+)?$'
limits:
  max_delete_fraction: 0.5      # per class per run
  max_delete_count: 2000        # per class per run
```
A class present in the store but absent from the file is `unclassified`: kept, reported, and makes `--apply` exit 1 after finishing (M03-AC-8). `distfile`, `snapshot`, `public` are protected; the YAML is the only place that says so and the CLI wrapper enforces it. A fast test also asserts the protected set is exactly these three, so removing `protected: true` from a release-input class is a visible test failure.

### Rules
- `build`, key `builds/<version>/<file>`: the `<version>` path segment matching `tag_pattern` is a release build and is kept forever (SPEC §5, DEC-releases-immutable-tags). Any other version segment older than `max_age_days` by `created_utc` is deleted. A segment that is neither (cannot be parsed) is kept and reported. Age uses the object's creation time, not the date in its name. Rejected: the predecessor's name-shape `case` (epoch-sha means delete), which cannot express age.
- `binpkg`, key `<tree-hash>/<profile-hash>/<cpv>.gpkg.tar`: a tree hash is live if it is the tree hash derived from `pins/pins.yaml` on `master` or from any open PR whose head branch matches `pins/*`. Objects under a live tree are kept. Objects under a non-live tree are deleted once their `created_utc` is older than `grace_days`. This reads SPEC §5 "until tree superseded + 30 d" as "not live and 30 days old". Rejected: tracking the moment of supersession, which needs mutable state in the store. The live set comes from `factory/bin/live-trees` (reads pins via `git show`/`gh pr list`); if it cannot be computed (gh error, missing pins file), the binpkg class is skipped with an error and the run exits 1.
- Tree-hash derivation is B01's `factory/lib/cachekey` (prints `tree=<16 hex> profile=<16 hex>`); `live-trees` calls it with each ref's `pins/pins.yaml`. Since the `profile` part also changes with the builder digest, only the `tree` part decides liveness; every profile under a live tree is kept.

### `store-gc`
`factory/bin/store-gc [--apply] [--class C]... [--policy FILE] [--report FILE] [--now ISO8601]`. Python 3 stdlib + PyYAML. Default is dry-run: it prints one line per object (`KEEP|DELETE|SKIP class key reason`), a per-class summary, and writes `--report` JSON (default `gc-report.json`: mode, per-class counts and bytes, unclassified count, errors, policy sha256). `--now` exists so tests control time.

Safety, all enforced before the first delete and again per class:
1. Listing errors (`store ls --long` exit other than 0, any parse failure) abort the class and the run exits 1. An empty listing is reported loudly (`NOTE: 0 objects in class C`), not treated as success silently; for `build` and `binpkg` on a store known to have objects it is exit 1 only if `--expect-nonempty` is passed (the workflow passes it for `build`).
2. If the KEEP set of a class is empty while the class has objects, abort that class (mis-set policy or clock).
3. Fraction and count limits from the policy; exceeding either aborts the class with the numbers.
4. `--apply` is required for any `store rm` call. Without it, no `rm` is invoked (the tests count invocations).
5. Each delete goes through `store rm`; a non-zero other than 3 is an error; the run continues with the next object, then exits 1.
6. Exit codes: 0 completed with no errors; 1 any error, abort or unclassified object under `--apply`; 2 usage.

### `gc.yml`
Triggers: `schedule` Sunday 04:00 UTC and `workflow_dispatch` with boolean `apply` (default false). The schedule invocation includes `--apply` explicitly, the dispatch only when `inputs.apply` is true; the apply decision is one expression, `${{ github.event_name == 'schedule' || inputs.apply }}`, asserted by a fast test (T-gc-never-applied). The job writes the report as a step summary and uploads `gc-report.json`. `permissions: contents: read, packages: write`. Credentials for the `oci` backend come from I01. The workflow also prints the first line `MODE: APPLY` or `MODE: DRY-RUN` so a log reader cannot mistake one for the other.

Rejected: dry-run on schedule with a human applying. That is what the predecessor believed it did; the failure was that `--apply` was wired to dispatch only and nobody noticed for months. The CLI is safe by default; the schedule is the explicit opt-in.

## Traps and doctrines preserved
- **T-gc-never-applied:** a GC that only prints. Prevented by M03-AC-1 (schedule applies), M03-AC-9 (log line and report show `mode: apply` and the counts, so a dry-run is never mistaken for an applied run), and M03-AC-11 (a real apply run followed by an empty dry-run).
- **Protected classes (SPEC §5):** snapshot, distfile and public are never deleted. Prevented by M03-AC-2, M03-AC-3.
- **T-binpkg-store-fail-open / SPEC §5 absent-versus-error:** a 401 treated as "nothing there". Prevented by M03-AC-6.
- **DEC-releases-immutable-tags:** release builds live forever. Prevented by M03-AC-4.
- **T-run-rerun-reuses-cache:** a PR under validation must not lose its binpkgs mid-run. Prevented by M03-AC-5 (open `pins/*` PRs keep their trees live).
- **Principle 5 (loud fallbacks):** unknown keys and empty listings are reported. Prevented by M03-AC-8.

## Gate
- **M03-AC-1** — `gc.yml` invokes `store-gc --apply` for `schedule` events, and for `workflow_dispatch` only when `inputs.apply` is true; there is exactly one such expression and no other `--apply` source. *Verify:* `tests/fast/gc-workflow.test.sh` (parse the YAML, evaluate the expression for event matrix schedule, dispatch true, dispatch false). *Tier:* fast.
- **M03-AC-2** — `store-gc` without `--apply` never calls `store rm`, for every class and rule, including when the listing contains deletable objects. *Verify:* `tests/fast/store-gc.test.sh` with a stub `store` counting `rm` calls (expects 0) over a mixed fixture, then with `--apply` (expects exactly the DELETE set). *Tier:* fast.
- **M03-AC-3** — No code path deletes from `snapshot`, `distfile` or `public`: `store rm` exits 4 for those classes, `store-gc` classifies every object in them `KEEP`, and passing `--class snapshot --apply` deletes nothing and exits 0 with `protected` in the report. The protected set in `factory/retention.yaml` equals `{snapshot, distfile, public}`. *Verify:* `tests/fast/store-gc.test.sh` and `tests/fast/test_retention.py::test_protected_set` on the `fs` backend. *Tier:* fast.
- **M03-AC-4** — In class `build`, versions matching the tag pattern (`v0.2.0`, `0.2.0-rc1`, `v1.0.0-beta3`) are kept at any age, non-tag versions older than 30 days by `created_utc` are deleted, younger ones kept, and an unparseable version is kept and reported. *Verify:* `tests/fast/test_retention.py::test_build_rule` with `--now` fixed and fixture listings at ages 29, 30, 31 days and 400 days. *Tier:* fast.
- **M03-AC-5** — In class `binpkg`, objects under a live tree hash are kept at any age; objects under a non-live tree are kept before 30 days and deleted after; if the live set cannot be computed, the class is skipped and the run exits 1. *Verify:* `tests/fast/test_retention.py::test_binpkg_rule` with a stub `live-trees` (live, empty, error). *Tier:* fast.
- **M03-AC-6** — Listing failures, auth errors and unparseable output abort the affected class and exit 1; they are never reported as zero objects. A real "absent key" from `store rm` (exit 3) is not an error. *Verify:* `tests/fast/store-gc.test.sh` with a stub `store ls` exiting 1 with a 401-like message, one exiting 3, one returning garbage, and the `fs` backend contract tests for `rm` and `ls --long` exit codes. *Tier:* fast.
- **M03-AC-7** — Limits hold: a fixture where the policy would delete more than 50% of a class, or more than 2000 objects, aborts that class with the numbers in stderr and deletes nothing from it. *Verify:* `tests/fast/store-gc.test.sh`. *Tier:* fast.
- **M03-AC-8** — Objects in a class without a policy rule are kept and listed as `unclassified` in the report and stderr; under `--apply` the run exits 1 after finishing other classes; an empty `build` listing with `--expect-nonempty` exits 1. *Verify:* `tests/fast/store-gc.test.sh`. *Tier:* fast.
- **M03-AC-9** — The report JSON contains `mode`, per-class `kept`, `deleted`, `bytes_freed`, `errors`, `unclassified` and `policy_sha256`, and `gc.yml` prints `MODE: APPLY` or `MODE: DRY-RUN` first and uploads the report. *Verify:* `tests/fast/store-gc.test.sh` (JSON schema check) and `tests/fast/gc-workflow.test.sh` (log-line step, upload step). *Tier:* fast.
- **M03-AC-10** — `store rm` and `store ls --long` pass the contract suite on `fs` and on `oci`: absent returns 3, protected class returns 4, listing format matches the regex, deleting the object a `has` found makes `has` return 3. *Verify:* F06 contract suite run (`make test-contract` or F06's equivalent) in fast tier for `fs`; CI job in I01's workflow for `oci`. *Tier:* fast + slow.
- **M03-AC-11** — One real scheduled-style run on the live store in apply mode completes, deletes at least one expired `build` object or reports `0 expired` with a non-empty listing, and a subsequent dry-run lists zero deletions. *Verify:* CI dispatch `gc.yml` with `apply=true`, once at acceptance, recorded in the PR table. *Tier:* slow.
- **M03-AC-12** — `docs/retention.md` is generated from `factory/retention.yaml` (class, rule, parameters) and a fast test fails when the committed doc differs from the render. *Verify:* `tests/fast/test_retention.py::test_doc_in_sync`. *Tier:* fast.

## RED plan
`tests/fast/store-gc.test.sh` and `tests/fast/test_retention.py` first: they invoke `factory/bin/store-gc` and `factory/lib/retention.py` (absent) against the `fs` backend and a stub `store`. Then `gc-workflow.test.sh` (workflow absent). Fixtures include ports of the useful predecessor cases (`s3-gc.test.sh`, `ghcr-gc.test.sh`: multi-tag verdict, abort on zero-keep, auth versus not-found) re-expressed against the new classes. They fail before implementation because the binaries do not exist; once the binaries stub out, the protected-class and no-`rm`-without-apply cases keep them failing until the logic is real.

## Risks and open questions
- Hardest: `oci` deletion semantics. GHCR deletes package versions by id, and one version can carry several tags; deleting a "key" can delete siblings. I01 must define the key-to-version mapping and make `rm` refuse when a version is shared. Until it does, `binpkg` apply on the `oci` backend is not safe; the weekly job can ship in dry-run for `binpkg` (policy flag `apply: false` per class, default true) and flip later.
- `created_utc` from GHCR is the version creation time; a re-pushed object resets it. For the 30-day grace that errs on the safe side.
- The `distfile` protection means storage grows without bound; under OD-5 "every distfile" this is a real cost, size unknown. A reference scan (keep distfiles referenced by any tag's lock) needs I04's manifest and a new node.
- Clock skew on the runner against `created_utc`: a 30-day window makes this immaterial.
- The live-tree computation couples GC to B01's hashing and to the GitHub API; a failure skips binpkg GC rather than guessing.

## Cost
Three agent slices: (1) policy file, `retention.py`, classification tests; (2) `store-gc` CLI, safety rails, contract additions for `fs`; (3) workflow, report, docs, and the `oci` run. CI cycles: none beyond fast tier, plus one real apply run at acceptance. Money: none to run; GHCR storage is believed free for public packages (unverified for this repository) and the policy is what keeps `build` and `binpkg` bounded.

## Spec defects found
- SPEC §5 operations are `put get has ls url`. Retention needs a delete and `ls` with size and creation time. F06 must add `rm` and `ls --long` (this node supplies the tests); otherwise M03 cannot be implemented without calling a provider directly.
- SPEC §5 `distfile` retention "forever while referenced" has no owner: no node builds the reference scan. Either assign it to I04 or accept "forever" and state the storage consequence under OD-5.
- SPEC §5 binpkg "until tree superseded + 30 d" is ambiguous (supersession time is not recorded). This node uses "not live and older than 30 days".
- graph.yaml: M03 depends only on I01. It needs F06 (new operations) and B01 (tree-hash function for the live set) and benefits from I04's manifest; F06 arrives through I01, B01 does not.
- SPEC §5 does not classify GHCR builder-image tags or Actions artifacts; this node excludes them and names their owners (I03/M02 and B06).
