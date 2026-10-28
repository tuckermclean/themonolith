# M03 — retention-and-gc

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| M | I01, I06 | X01 | — (feeds MS5) | M |

**Owns:** `factory/retention.yaml`, `factory/bin/store-gc`, `factory/lib/retention.py`, `.github/workflows/gc.yml`, `docs/retention.md`, `tests/fast/store-gc.test.sh`, `tests/fast/test_retention.py`, `tests/fast/gc-workflow.test.sh`, `tests/fast/store-gc-fixtures/`, and the `rm` / `ls --long` cases of the F06 contract suite (`tests/contract/store/` or wherever F06 puts it; SPEC §5 now lists both operations, I01 implements them for `oci`).
**Carries from linux-live-iso-factory@b9f533b:** ported: `scripts/s3-gc.sh` (the abort-on-empty-keep-list guard, captured-listing loop, KEEP-first default, exit-0 rule at :70-77), `scripts/ghcr-gc.sh` (auth-versus-not-found error discrimination at :64-84, the zero-listing NOTE, multi-tag verdict at :19-33), `.github/workflows/gc.yml` (apply on schedule, dry-run on dispatch unless `apply`), `scripts/tests/s3-gc.test.sh`, `scripts/tests/ghcr-gc.test.sh` (cases only; the S3 half is dead).
**Study refs:** workflows.yaml `wf.gc`, `job.gc.gc`; doctrine.yaml T-gc-never-applied, T-binpkg-store-fail-open, T-run-rerun-reuses-cache, DEC-releases-immutable-tags; oracle.yaml open_questions (which tests die with S3); SPEC §5 retention table and §5.1 (cache sets and blobs), Principle 5 and 7; I01 (key to GHCR package version), I06 (set format).

## Purpose
After this node the store has a written, machine-readable retention policy per class and a garbage collector that applies it. The collector is dry-run unless told otherwise, refuses to touch the classes whose loss would make a release unreproducible, and treats every listing or auth error as a failure rather than "nothing to delete". The predecessor's weekly GC printed `DELETE` lines for months and deleted nothing (T-gc-never-applied).

## Scope
In:
- `factory/retention.yaml`, a policy file with one rule per store class.
- `factory/bin/store-gc`: classifies keys, reports, and (with `--apply`) deletes through the store contract.
- The CLI-wrapper protection for `store rm` (SPEC §5: refused for `snapshot` and for any key a release references) and the `--long` listing the policy reads.
- The weekly workflow with explicit apply on schedule and a report artifact.
- Tests with synthetic listings against the `fs` backend; no network.
Out:
- The store CLI itself and the `fs` backend: F06. The `oci` backend, including how a key maps to a GHCR package version and how `rm` deletes it (`locate`, `rm`, `ls --long`): I01. The `public` backend: P01.
- Pruning distfiles by reference: no node owns it today (see defects); this node ships the class as protected.
- The format of cache sets and the global key: I06. This node reads them.
- The adopted rc1 objects (`builder:rc1`, `binpkg-seed:rc1` in our GHCR namespace): not store keys, never touched by `store-gc`. The seed's entries that I06 imported into the `binpkg` class are, and follow the rc1-seed rule below.
- Actions artifacts, Actions caches and GHCR builder-image tags. Actions artifacts expire by their own `retention-days` set in B06; builder-image tag lifecycle is I03/M02.
- Deleting releases or tags. Never done by any automation.

## Design

### Interface (SPEC §5, as extended in v0.3)
The store contract has `ls [--long] <class> <prefix>` (`--long` prints `<key>\t<size_bytes>\t<created_utc>`, `created_utc` as `YYYY-MM-DDTHH:MM:SSZ`) and `rm <class> <key> --confirm` (exit 0 deleted, 3 absent, other non-zero error). `rm` refuses (exit 4, stderr message) classes marked `protected` in `factory/retention.yaml`, and keys under `builds/<tag>/` for a tag build; the refusal lives in the CLI wrapper, so no backend can bypass it. Rejected: giving the GC direct backend access (breaks SPEC §5 "nothing else may call a storage provider's CLI").
On `oci`, I01 defines the mapping this node relies on: key, then tag `k-<dir16>-<key64>`, then exactly one GHCR package version; `rm` deletes that version and refuses when it carries another tag. `created_utc` is the version's `created_at`. This resolves the v0.2 open item "M03 needs I01 to define how a store key maps to a GHCR package version".

### `factory/retention.yaml`
```yaml
version: 2
classes:
  snapshot: {protected: true}                       # forever (SPEC §5)
  distfile: {protected: true}                       # forever while referenced; reference scan not built
  public:   {protected: true}                       # per P01; no automatic deletion
  binpkg:
    rule: cache-sets
    global_key_idle_days: 30      # a main global key whose newest set is older, and which is not the current key, goes
    set_max_age_days: 30          # within a kept key: sets older than this go, except the newest set
    pr_days: 14                   # every object under pr-<n>/ older than this goes
    blob_grace_days: 2            # a blob younger than this is never collected (a save writes blobs before its set)
    keep_until:
      rc1-seed: MS4               # the set named *-rc1-seed.json and the blobs it names
    apply: true                   # set false to report only, per class (see Risks)
  build:
    rule: age-unless-keep
    max_age_days: 30              # memo/ and non-tag builds/<version>/
    pr_days: 14                   # pr-<n>/memo/
    tag_pattern: '^v?[0-9]+\.[0-9]+\.[0-9]+(-(rc|beta)[0-9]+)?$'
    keep_forever: ['fixtures/']   # rc1 fixtures (O01) and any later fixture set
limits:
  max_delete_fraction: 0.5      # per class per run
  max_delete_count: 2000        # per class per run
```
A class present in the store but absent from the file is `unclassified`: kept, reported, and makes `--apply` exit 1 after finishing (M03-AC-8). `distfile`, `snapshot`, `public` are protected; the YAML is the only place that says so and the CLI wrapper enforces it. A fast test also asserts the protected set is exactly these three, so removing `protected: true` from a release-input class is a visible test failure.

### Rules
- `build`, key `builds/<version>/<file>`: the `<version>` path segment matching `tag_pattern` is a release build and is kept forever (SPEC §5, DEC-releases-immutable-tags). Any other version segment older than `max_age_days` by `created_utc` is deleted. A segment that is neither (cannot be parsed) is kept and reported. Age uses the object's creation time, not the date in its name. Rejected: the predecessor's name-shape `case` (epoch-sha means delete), which cannot express age.
- `build`, key `memo/<input-hash>/…` and `memo/results/…`: deleted when older than `max_age_days` (the whole-build memo and oracle result cache, I06; both are re-creatable). Under `pr-<n>/` the age is `pr_days`.
- `build`, key `fixtures/…`: kept forever.
- `binpkg` (I06 layout). A key is `<ns><global>/blobs/<sha256>.gpkg.tar` or `<ns><global>/sets/<utc>-<run>.json`; `<ns>` is empty for `main` or `pr-<n>/`. Rules apply in this order and each step uses the result of the one before:
  1. **Namespaces.** Every object under `pr-<n>/` older than `pr_days` by `created_utc` is deleted, sets and blobs alike, after step 4's reference check applied inside that namespace.
  2. **Global keys.** For each `main` global key `G`: retained if it equals the current key (`cache key` run on a checkout of `master`, so the key is the live one), or its newest set is younger than `global_key_idle_days`, or it holds the rc1 seed set before `MS4`. Otherwise every set and blob under `G` is deleted. Restore does not write, so "unused" means "no run has saved for 30 days"; a key that is only restored from is still the current key if anything runs, and a key nobody saves to for 30 days is no longer being built. Rejected: tracking last restore, which needs mutable state in the store.
  3. **Sets.** In a retained key, a set is kept if it is the newest set of its namespace and key, or younger than `set_max_age_days`, or the rc1 seed set before `MS4`. Other sets are deleted.
  4. **Blobs.** The retained sets are fetched and parsed to give the referenced sha256 values (`packages.*.sha256`). A blob is collectable only when no retained set references it (a set in any namespace under the same global key counts, because a PR set may name `main` blobs) and it is older than `blob_grace_days`. Any set that cannot be fetched or parsed aborts the class: references cannot be known, so nothing is deleted.
  5. **Order.** Sets are deleted before blobs, so a crash leaves orphan blobs, never a set that names missing blobs. A rerun collects the orphans.
- **rc1 seed.** The set named `<G>/sets/*-rc1-seed.json` (I06 `seed-rc1`) and the blobs it names are kept until milestone MS4 is reached. MS4 is reached when every node in its `after` list in `docs/graph.yaml` is `done` in `docs/status.yaml`; `store-gc` reads both files. If either cannot be read, the seed is kept. Rejected: a fixed date; the milestone is what makes the seed unnecessary (the oracle-parity SBOM diff against rc1 is explained, so rc1's packages are no longer a baseline for anything).
- The live key comes from I06's `cache key`. If it cannot be computed (missing checkout, pin error), the `binpkg` class is skipped with an error and the run exits 1.

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
- **T-run-rerun-reuses-cache / a PR losing its blobs mid-run:** a PR under validation must not lose blobs a retained set names. Prevented by M03-AC-5 and M03-AC-13 (reference rule, grace period, sets deleted before blobs).
- **Cache poisoning by absence:** deleting a blob a set still names would make I06's restore report `absent`, not an error. Prevented by M03-AC-13, M03-AC-14.
- **The rc1 seed expiring early:** Prevented by M03-AC-15.
- **Principle 5 (loud fallbacks):** unknown keys and empty listings are reported. Prevented by M03-AC-8.

## Gate
- **M03-AC-1** — `gc.yml` invokes `store-gc --apply` for `schedule` events, and for `workflow_dispatch` only when `inputs.apply` is true; there is exactly one such expression and no other `--apply` source. *Verify:* `tests/fast/gc-workflow.test.sh` (parse the YAML, evaluate the expression for event matrix schedule, dispatch true, dispatch false). *Tier:* fast.
- **M03-AC-2** — `store-gc` without `--apply` never calls `store rm`, for every class and rule, including when the listing contains deletable objects. *Verify:* `tests/fast/store-gc.test.sh` with a stub `store` counting `rm` calls (expects 0) over a mixed fixture, then with `--apply` (expects exactly the DELETE set). *Tier:* fast.
- **M03-AC-3** — No code path deletes from `snapshot`, `distfile` or `public`: `store rm` exits 4 for those classes, `store-gc` classifies every object in them `KEEP`, and passing `--class snapshot --apply` deletes nothing and exits 0 with `protected` in the report. The protected set in `factory/retention.yaml` equals `{snapshot, distfile, public}`. *Verify:* `tests/fast/store-gc.test.sh` and `tests/fast/test_retention.py::test_protected_set` on the `fs` backend. *Tier:* fast.
- **M03-AC-4** — In class `build`, versions matching the tag pattern (`v0.2.0`, `0.2.0-rc1`, `v1.0.0-beta3`) are kept at any age, non-tag versions older than 30 days by `created_utc` are deleted, younger ones kept, an unparseable version is kept and reported, `memo/` objects follow the 30-day rule (`pr-<n>/memo/` 14 days), and `fixtures/rc1/` objects are kept at any age. *Verify:* `tests/fast/test_retention.py::test_build_rule` with `--now` fixed and fixture listings at ages 29, 30, 31 days and 400 days. *Tier:* fast.
- **M03-AC-5** — In class `binpkg`, a `main` global key is kept when it is the current key or its newest set is under 30 days old, and deleted (sets and blobs) otherwise; objects under `pr-<n>/` older than 14 days are deleted and younger ones kept; if the current key cannot be computed, the class is skipped and the run exits 1. *Verify:* `tests/fast/test_retention.py::test_binpkg_rule` with fixture listings at ages 13, 15, 29 and 31 days and a stub `cache key` (current, other, error). *Tier:* fast.
- **M03-AC-6** — Listing failures, auth errors and unparseable output abort the affected class and exit 1; they are never reported as zero objects. A real "absent key" from `store rm` (exit 3) is not an error. *Verify:* `tests/fast/store-gc.test.sh` with a stub `store ls` exiting 1 with a 401-like message, one exiting 3, one returning garbage, and the `fs` backend contract tests for `rm` and `ls --long` exit codes. *Tier:* fast.
- **M03-AC-7** — Limits hold: a fixture where the policy would delete more than 50% of a class, or more than 2000 objects, aborts that class with the numbers in stderr and deletes nothing from it. *Verify:* `tests/fast/store-gc.test.sh`. *Tier:* fast.
- **M03-AC-8** — Objects in a class without a policy rule are kept and listed as `unclassified` in the report and stderr; under `--apply` the run exits 1 after finishing other classes; an empty `build` listing with `--expect-nonempty` exits 1. *Verify:* `tests/fast/store-gc.test.sh`. *Tier:* fast.
- **M03-AC-9** — The report JSON contains `mode`, per-class `kept`, `deleted`, `bytes_freed`, `errors`, `unclassified` and `policy_sha256`, and `gc.yml` prints `MODE: APPLY` or `MODE: DRY-RUN` first and uploads the report. *Verify:* `tests/fast/store-gc.test.sh` (JSON schema check) and `tests/fast/gc-workflow.test.sh` (log-line step, upload step). *Tier:* fast.
- **M03-AC-10** — `store rm` and `store ls --long` pass the contract suite on `fs` and on `oci`: absent returns 3, protected class returns 4, listing format matches the regex, deleting the object a `has` found makes `has` return 3. *Verify:* F06 contract suite run (`make test-contract` or F06's equivalent) in fast tier for `fs`; CI job in I01's workflow for `oci`. *Tier:* fast + slow.
- **M03-AC-11** — One real scheduled-style run on the live store in apply mode completes, deletes at least one expired `build` object or reports `0 expired` with a non-empty listing, and a subsequent dry-run lists zero deletions. *Verify:* CI dispatch `gc.yml` with `apply=true`, once at acceptance, recorded in the PR table. *Tier:* slow.
- **M03-AC-12** — `docs/retention.md` is generated from `factory/retention.yaml` (class, rule, parameters) and a fast test fails when the committed doc differs from the render. *Verify:* `tests/fast/test_retention.py::test_doc_in_sync`. *Tier:* fast.
- **M03-AC-13** — A blob is deleted only when no retained set names its sha256 and it is older than 2 days: a blob named by a retained `main` set, by a retained PR set under the same global key, or younger than the grace period survives; a blob named only by deleted sets is deleted. *Verify:* `tests/fast/test_retention.py::test_blob_reference` (fixture sets and blobs). *Tier:* fast.
- **M03-AC-14** — If any retained set cannot be fetched or parsed, the `binpkg` class deletes nothing and the run exits 1; within a run, every set `rm` is issued before any blob `rm` (asserted from the stub's call log). *Verify:* `tests/fast/store-gc.test.sh` cases `bad-set`, `order`. *Tier:* fast.
- **M03-AC-15** — The set named `*-rc1-seed.json` and the blobs it names are kept at any age until every node of MS4's `after` list is `done` in `docs/status.yaml`, then become ordinary objects; an unreadable `status.yaml` keeps them. *Verify:* `tests/fast/test_retention.py::test_rc1_seed` with fixture `graph.yaml` and `status.yaml`. *Tier:* fast.
- **M03-AC-16** — On `oci`, `rm` of a blob key deletes exactly its package version, and `store-gc --apply` against the real registry removes an expired fixture object created for the test and nothing else. *Verify:* CI dispatch `gc.yml` with `apply=true` against objects under `ci-smoke/` in class `build` (shares I01-AC-17's live round trip). *Tier:* slow.

## RED plan
`tests/fast/store-gc.test.sh` and `tests/fast/test_retention.py` first: they invoke `factory/bin/store-gc` and `factory/lib/retention.py` (absent) against the `fs` backend and a stub `store`. Then `gc-workflow.test.sh` (workflow absent). Fixtures include ports of the useful predecessor cases (`s3-gc.test.sh`, `ghcr-gc.test.sh`: multi-tag verdict, abort on zero-keep, auth versus not-found) re-expressed against the new classes. They fail before implementation because the binaries do not exist; once the binaries stub out, the protected-class and no-`rm`-without-apply cases keep them failing until the logic is real.

## Risks and open questions
- Hardest: `oci` deletion semantics. GHCR deletes package versions by id. I01 now defines the key-to-version mapping and makes `rm` refuse when a version is shared. Unverified: GitHub's limit on deleting versions of public packages with many downloads (I01 risk). Until I01's live round trip passes, `binpkg` apply on the `oci` backend is not proven; the weekly job can ship with `apply: false` for `binpkg` (policy flag per class) and flip it after AC-16.
- Listing the whole `binpkg` class costs one manifest fetch per object (I01's slow path), a few hundred to a few thousand fetches weekly. Acceptable; the alternative is a per-key index object, which I06 does not write.
- `created_utc` from GHCR is the version creation time; a re-pushed object resets it. For the 30-day grace that errs on the safe side.
- The `distfile` protection means storage grows without bound; under OD-5 "every distfile" this is a real cost, size unknown. A reference scan (keep distfiles referenced by any tag's lock) needs I04's manifest and a new node.
- Clock skew on the runner against `created_utc`: a 30-day window makes this immaterial.
- The live-key computation couples GC to I06's `cache key` and to a master checkout; a failure skips binpkg GC rather than guessing.
- Blob grace of 2 days assumes a `save` finishes within that time; a stalled run could have its blobs collected before its set lands. The set is then missing blobs, which restore reports as `absent` entries (a loud miss), never a wrong binary.

## Cost
Three agent slices: (1) policy file, `retention.py`, classification tests including the cache-set rules (AC-4, AC-5, AC-13, AC-15); (2) `store-gc` CLI, safety rails, contract cases for `fs` (AC-2, AC-3, AC-6 to AC-8, AC-14); (3) workflow, report, docs, and the `oci` run (AC-1, AC-9 to AC-12, AC-16). CI cycles: none beyond fast tier, plus one real apply run at acceptance. Money: none to run; GHCR storage is believed free for public packages (unverified for this repository) and the policy is what keeps `build` and `binpkg` bounded.

## Spec defects found
- SPEC §5 `distfile` retention "while referenced by a live tree or any release" has no owner: no node builds the reference scan. Either assign it to I04 or accept "forever" and state the storage consequence under OD-5.
- SPEC §5 binpkg retention says "global key unused for 30 d". Restore leaves no record in the store, so this node reads it as "no set saved under that key for 30 days, and not the current key". SPEC should say so.
- graph.yaml: M03 depends only on I01. It reads I06's global key and set format and benefits from I04's manifest; I06 should be a dependency. B01 (the v0.2 tree-hash function) is no longer needed.
- I06 does not say where a PR run's `save` puts blobs it restored from `main` (copied into `pr-<n>/` or referenced in place). This node treats a `main` blob as referenced by any retained set naming its sha256 under the same global key, which is safe for both. I06 should state the rule.
- SPEC §5 does not classify GHCR builder-image tags or Actions artifacts; this node excludes them and names their owners (I03/M02 and B06).
