# B07 — reproducibility-check

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| B | B06 | X01 | — (evidence for MS5) | M |

**Owns:** `factory/bin/repro-compare`, `factory/lib/repro_lib.py`, `factory/bin/repro-known-check`,
`docs/repro/known-differences.yaml`, `docs/repro/README.md` (format and policy, one page), `.github/workflows/repro.yml`,
`factory/mk/repro.mk` (`make repro`), `tests/fast/repro-*.test.sh`, `tests/fast/fixtures/repro/`
**Carries from linux-live-iso-factory@b9f533b:** nothing as code. Ideas only: `scripts/binpkg-store.sh` pack
(`--sort=name --numeric-owner --mtime`, `:306-310`) and `build-initrd.sh:342-353` as the predecessor's partial
reproducibility measures.
**Study refs:** build.yaml hazards `nondeterminism` (no date flags in ISO, cpio, symlink mtimes, parallel emerge
changes build ids, `versions.lock` timestamp, docker commit), open_questions (does xorriso/mkfs.vfat/grub honour
`SOURCE_DATE_EPOCH`; is reproducibility required or only digest-chain consistency); T-mksquashfs-sde;
Principle 5; SPEC §6 (`SOURCE_DATE_EPOCH` derivation).

## Purpose
After B07 the project can state, with a recorded comparison, whether two builds from identical inputs give the
same kernel, initrd, squashfs and ISO, and exactly which files differ if not. The predecessor only required
consistency of the digest chain inside one build. B07 turns reproducibility into a ratchet: the list of known
differences can shrink and cannot grow silently.

## Scope
In:
- A comparer over two unpacked `iso-<run_id>` artifact sets, with a hash list per layer and a file-level drill-down.
- The known-differences file, its schema, and the checks on it (coverage, staleness, expiry, ratchet).
- `repro.yml` (dispatch a comparison of two existing release builds) and `make repro` locally.
- The first committed list of differences found, with causes.

Out:
- Making each stage deterministic: B03-B05 own their stage-level fixes and twice-run checks; B01/B02 own
  package and kernel causes. B07 reports and tracks; it does not patch builds.
- Upstream package reproducibility fixes beyond recording them as entries with issues.
- Attestation digest chain: S05. Building the artifacts: B06.

## Design

### What is compared
Two builds are comparable only when their `build-manifest.json` (B06) agree on: `git_sha`, `source_date_epoch`,
`mode == release`, builder image digest, and the snapshot and distfile hashes recorded in the stage records;
`run` and `layers` are excluded. Otherwise `repro-compare` exits 2 naming the first mismatching field. Release
mode (all packages built from source) is the meaningful case; a `cache` comparison only proves the stages after
packages. Decision: compare two separate from-source builds on separate runners, in addition to the in-job
twice-run checks of B03-B05. Rejected: comparing a build against its own cached rerun (proves nothing about the
compile).

### Layers and hash list
The comparer reads `layers` from each manifest and prints one `sha256sum`-format line per layer and build:
```
kernel    <sha-a>  <sha-b>  identical|known|new|derived
initrd    …
squashfs  …
iso       …
```
Layer sources: `kernel` = `out/kernel/vmlinuz`; `initrd`, `squashfs`, `iso` as named. Also compared and reported
(not layers): `resolved-kernel.config`.
Drill-down when a layer differs:
- `squashfs`: diff `rootfs.manifest.tsv` row by row (key = path; compared fields: type, mode, uid, gid, size,
  sha256, target). If every row is equal but the image hash differs, the difference is key `container` (squashfs
  metadata, inode or time).
- `initrd`: same with `initrd.manifest.tsv`.
- `kernel`: key `vmlinuz` plus `resolved-config` if the resolved config differs.
- `iso`: if kernel, initrd and squashfs are identical, compare the components recorded in `iso.json` (`BOOTX64.EFI`,
  `efi.img`, rendered configs) and name the first differing; if none, key `container` (xorriso metadata, GPT GUIDs,
  dates). If an input layer differs the ISO layer is `derived` (explained by that layer's entries) and needs no
  entry of its own.
Decision: gate on hash lists and the existing manifests, which cost seconds and need no extra tools. Rejected:
diffoscope as the gate (very slow and memory-hungry on a half-gigabyte squashfs, drags in unpinned tools).
diffoscope is a diagnostic only: when present (pinned by I03/I05 if the owner wants it), a `new` difference runs it
with a size cap and `repro.yml` uploads `repro-diff-<run_id>`; absence never changes the verdict.

### Known-differences file
`docs/repro/known-differences.yaml`:
```yaml
schema: 1
differences:
  - id: KD-001                  # unique, never reused
    layer: squashfs             # kernel | initrd | squashfs | iso
    match: "var/db/pkg/*/*/environment.bz2"   # glob over the layer's key space; * stays within a path
                                              # segment, ** crosses; keys: path, vmlinuz, resolved-config, container
    kind: content               # content | metadata | presence
    reason: "portage environment dump embeds the build host's variables"   # required, one sentence
    cause: "sys-apps/portage"   # optional: package or tool
    issue: "https://github.com/<owner>/<repo>/issues/NN"                    # required
    added: 2026-11-01
    expires: 2027-01-30         # required, at most 90 days after added
```
Checks (`repro-compare` on every run, `repro-known-check` in the fast lane):
1. Every observed difference is covered by at least one entry for its layer, key and kind; otherwise exit 4 with
   path, both hashes and, if known, the owner package from the manifest.
2. Every entry matched at least one difference in a full comparison; unused ones are `stale` and exit 4 (the list
   must shrink as causes are fixed).
3. `expires` not in the past (relative to `--today`, injectable); `issue` and `reason` present; ids unique.
4. Ratchet: `repro-known-check --base <file at the PR base> --head <file>` fails if the head has more entries than
   the base, unless a head commit has the trailer `Known-Differences-Increase: <reason>`. The first PR (this node)
   establishes the baseline and is exempt. The base file comes from the trusted base revision (SPEC §8).
5. Glob semantics are path-segment aware by construction (the predecessor's `fnmatch` allowlist let `*` match `/`,
   supplychain.yaml `script.check-unowned` notes).

### Report
`out/repro/report.json` and `out/repro/report.md` (also written to the step summary):
```json
{"schema":1,"comparable":true,"a":{"run":"…","git_sha":"…"},"b":{"run":"…","git_sha":"…"},
 "layers":[{"layer":"kernel","a":"…","b":"…","status":"identical|known|derived|new"}],
 "differences":[{"layer":"squashfs","key":"var/db/pkg/x/y/BUILD_TIME","kind":"content","a":"…","b":"…","entry":"KD-003"}],
 "stale_entries":[],"expired_entries":[]}
```
Sorted, no timestamps: the same pair gives byte-identical reports. Exit codes: 0 all covered; 2 not comparable;
3 an input file missing; 4 uncovered, stale or expired.

### Workflow and local
`repro.yml`: `workflow_dispatch` with inputs `run_a` and `run_b` (two `build.yml` runs, both `mode=release`, same
commit). Steps: download `iso-<run>` for each (`gh run download`, token `actions: read`), `make repro A=… B=…`,
upload report, fail on exit 4. The operator produces the two builds by dispatching `build.yml` twice. It publishes
nothing and has no write permissions. Decision: two dispatched builds plus a cheap compare, rejecting a workflow
that re-runs the whole pipeline twice itself (duplicates B06 and couples the cost). Locally `make repro A=out-a B=out-b`
compares two `out/` trees; `make iso MODE=release OUT=out-a` builds one.

### Expected first findings (to be confirmed, not asserted)
Likely candidates for the first list, from the predecessor's hazards: portage VDB leftovers beyond `BUILD_TIME` and
`COUNTER` (B04 normalises those), package build paths and timestamps embedded in binaries, `UTS_VERSION` in the
kernel if `KBUILD_*` is not honoured (B02), `grub-mkstandalone` and `mcopy` directory times (B05), xorriso GPT GUIDs.
Each real one becomes an entry with an issue.

## Traps and doctrines preserved
- **T-mksquashfs-sde:** B04 gate lives in B04; B07 reports any residual squashfs `container` difference. AC-3, AC-9.
- **Principle 5 (honest success):** a covered difference is listed, not hidden; an unlisted one fails the run;
  a listed one that no longer occurs fails too. AC-3, AC-4.
- **Principle 2 / D-two-epoch-pin-model:** only runs with identical pins and inputs are comparable. AC-1.
- **Principle 7:** `repro.yml` publishes nothing. AC-8.
- **D-state-and-no-hidden-stderr:** diffoscope absence is reported, not swallowed. AC-7.

## Gate
- **B07-AC-1** — `repro-compare` exits 2 when `git_sha`, `source_date_epoch`, `mode`, builder digest or input hashes differ between the two manifests (naming the field) and exits 3 on a missing manifest; `run` and `layers` differences do not matter. *Verify:* `tests/fast/repro-comparable.test.sh`. *Tier:* fast.
- **B07-AC-2** — For two fixture builds with identical layers the report lists four `identical` rows and the command exits 0 with an empty known-differences file. *Verify:* `tests/fast/repro-layers.test.sh`. *Tier:* fast.
- **B07-AC-3** — A differing squashfs or initrd row in the manifests that no entry covers exits 4 and prints layer, path, kind and both hashes; with a matching entry the same pair exits 0 with status `known`. *Verify:* `tests/fast/repro-drilldown.test.sh`. *Tier:* fast.
- **B07-AC-4** — An entry that matches no observed difference is reported `stale` and exits 4; an entry past `expires` exits 4; an entry missing `reason` or `issue`, with `expires` more than 90 days after `added`, or with a duplicate id fails validation. *Verify:* `tests/fast/repro-known.test.sh`. *Tier:* fast.
- **B07-AC-5** — Globs: `var/db/pkg/*/*/BUILD_TIME` matches `var/db/pkg/a/b/BUILD_TIME` and not `var/db/pkg/a/b/c/BUILD_TIME`; `**` crosses `/`. *Verify:* `tests/fast/repro-known.test.sh`. *Tier:* fast.
- **B07-AC-6** — `repro-known-check --base --head` fails when the head list is longer than the base without the `Known-Differences-Increase:` trailer and passes when equal, shorter, or with the trailer. *Verify:* `tests/fast/repro-ratchet.test.sh`. *Tier:* fast.
- **B07-AC-7** — If kernel, initrd and squashfs are identical and the ISO differs, the report names the first differing `iso.json` component or `container` and requires its own entry; if any input layer differs the ISO row is `derived` and needs none; with `diffoscope` missing the verdict is unchanged and a message says so. *Verify:* `tests/fast/repro-iso.test.sh` (stub `diffoscope`). *Tier:* fast.
- **B07-AC-8** — `repro.yml` has `permissions: {contents: read, actions: read}` only, no store write, no release, and takes only `workflow_dispatch`; `make repro` uses the same `repro-compare`. *Verify:* `tests/fast/workflow-publishes-nothing.test.sh` (extended to `repro.yml`), `tests/fast/repro-make.test.sh` (`make -n repro`). *Tier:* fast.
- **B07-AC-9** — `report.json` and `report.md` are byte-identical across repeated runs of the same pair, sorted, with no timestamps. *Verify:* `tests/fast/repro-layers.test.sh`. *Tier:* fast.
- **B07-AC-10** — Two release builds of one commit on separate runners, compared by `repro.yml`, exit 0, and `docs/repro/known-differences.yaml` at head lists every difference found with reason, cause and issue (possibly empty). *Verify:* `repro.yml` run ids recorded in the PR table. *Tier:* slow.
- **B07-AC-11** — At the X01 cutover commit the same comparison passes and every entry has at least 14 days left to expire. *Verify:* `repro.yml` run in X01's evidence; `repro-known-check --min-remaining-days 14`. *Tier:* slow.

## RED plan
Tester writes first, all failing for want of the tools: fixture pairs under `tests/fast/fixtures/repro/` (a
build-manifest and two small TSV manifests per side, built by a generator script, no real images): identical;
one `BUILD_TIME` row differing; an unlisted path differing; an expired entry; a stale entry; an ISO-only difference.
`repro-known` cases for the glob rule and the schema. `repro-ratchet` uses two small YAML files and a fake commit
log for the trailer. None needs Docker or network.

## Risks and open questions
- Whether reproducibility is achievable at all for all layers is open (build.yaml question). The ratchet makes
  partial progress safe; X01 requires only a pass, not an empty list.
- Parallel emerge changes build order and gpkg metadata but not installed file content; the comparison reads
  installed files, so this is only a risk if a package embeds ordering-dependent data.
- 90-day expiry and the "shrinking" rule are decisions of this spec; the owner may prefer a different cadence.
- Runner variance (CPU model, kernel) can change some build outputs (`-march` autodetect, `native` flags). Unknown
  here; a difference with that cause belongs in the list with a pinned fix target.
- The comparison needs `rootfs.manifest.tsv` and `initrd.manifest.tsv` to include a per-file sha256; those are B04
  and B03 requirements already stated in their specs.
- diffoscope availability depends on I03/I05; it is optional by design.

## Cost
Slices: (1) comparer and layer report; (2) known-differences schema, coverage, glob, ratchet; (3) `repro.yml`,
`make repro`, first real comparison and baseline list. About 3 slices. CI cycles: 2 cold from-source builds per
real comparison (30-60 min each, run in parallel on separate runners), at least 2 comparisons (baseline, after
fixes), so about 4 cold builds in total. Money: runner minutes and short-lived artifact storage; nothing else.

## Spec defects found
- graph.yaml gives B07 only `B06`. It reads manifests that B03 and B04 are required to emit; this is satisfied
  transitively, but the dependency on the manifest formats should be named in B06's summary.
- SPEC §6 mentions the `SOURCE_DATE_EPOCH` derivation but says nothing about which tools must honour it;
  reproducibility cannot be asserted for grub, xorriso, mtools and dosfstools until I03/I05 pin them (see B05).
