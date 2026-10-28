# S04 — unowned-gate

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| S | S01 | R05, S05 | — (feeds MS2) | M |

**Owns:**
- `supplychain/unowned_gate.py` (CLI and importable module).
- `supplychain/policy/unowned-allowlist.yaml` (protected path; see Spec defects).
- `supplychain/schema/unowned-allowlist.schema.json`, `supplychain/schema/unowned-report.schema.json`.
- `tests/fast/test_unowned_*.py`, `tests/fixtures/supplychain/unowned/` (includes the b9f533b allowlist copy used by the migration test).

**Carries from linux-live-iso-factory@b9f533b:**
- `scripts/check-unowned.py` (312 lines), **ported** as `supplychain/unowned_gate.py`. Kept: the CONTENTS reader (`:58-82`, with the `split()` bug fixed), the allowlist matcher (`:170-179`, with the glob fixed), `main` flow and report fields. Replaced: the three Syft-`files[]` functions (`:85-168`), because AC-1 and AC-9 remove Syft as an input.
- `configs/attestation/unowned-allowlist.yaml` (192 lines, 103 entries). **S04 starts from this file**: it is copied in the first slice with every entry intact, then converted to the structured format (AC-4, AC-8). R05 later shrinks it; S04 never does.
- Pillar 4 from `scripts/attestation.sh:460-496`.

**Study refs:**
- Invariants: INV-OWN-1, INV-OWN-2, INV-OWN-3.
- Doctrine: D-hand-authored-rootfs-files-owned.
- Principle 5.
- Contradiction: allowlist comment says `*` stays within a path segment and `**` crosses, but `fnmatch` makes `*` cross `/` and `**` equal `*` (`check-unowned.py:170-179`).
- Verified weaknesses:
  - Pillar 4 is skipped with a warning and counts as PASS when `sbom.syft.json` is missing (`attestation.sh:462-473`);
  - it passes with a warning when Syft's `files[]` is empty (`check-unowned.py:246-250`);
  - a missing allowlist file is a warning and the gate continues with an empty list (`:209-215`);
  - CONTENTS lines are parsed with `line.split()`, which breaks on names with spaces (`:77-79`).
- Components: `script.check-unowned`, `cfg.attestation/unowned-allowlist.yaml`.
- Data contract: `unowned-report.json`.

## Purpose

After this node, a file on the shipped rootfs that no package owns and no justified allowlist entry covers fails the build, and the gate cannot pass by having nothing to look at. It is developed in the rc1 lane (SPEC §7): its first real input is rc1's extracted squashfs (the O01 fixture), where it must pass with the ported allowlist before this repo builds anything. The gate walks the extracted sysroot itself instead of trusting Syft's file catalogue, so an empty or missing input is an error. The allowlist becomes a structured file in which every entry has a written reason and a reviewer can see how many files each glob hides.

## Scope

**In:**
- The walker, the CONTENTS parser, the allowlist schema and glob engine, the report, the exit codes.
- Conversion of the 103 old entries into the new format with reasons.

**Out:**
- Making hand-authored files owned by the `monolith-base` ebuild so the allowlist shrinks: R05 (which depends on S04). S04 provides the mechanism and the per-entry counts R05 uses.
- Fetching rc1's squashfs: O01. S04 reads the extracted directory.
- Extracting the squashfs to a sysroot directory and recording the file-to-package manifest: B04. S04 only needs a directory.
- Verifying that owned files still match their CONTENTS md5 or have not been modified after install: not in the old gate; named in Risks, no node owns it.
- SBOM and Syft: S01.
- Verdict aggregation and signing: S05.
- Dashboard "Unowned" tab: P03.

## Design

### CLI

```
unowned_gate.py --sysroot DIR --allowlist supplychain/policy/unowned-allowlist.yaml --output unowned-report.json
```

Exit codes and the report envelope come from S01's `supplychain/common.py`. That shared module is why S04 depends on S01: the gate reads no SBOM. 0 pass; 1 at least one unowned entry; 2 input or policy error. All three arguments are required.

**Port first (Principle 11).** The first slice copies `check-unowned.py` and the b9f533b allowlist and runs them unchanged. Then only what the ACs force changes.

| Change from the predecessor | Forced by |
|---|---|
| Walk the disk, no Syft input; empty or missing input is exit 2 | S04-AC-1, AC-9 (INV-OWN-2, INV-OWN-3) |
| Missing allowlist is exit 2 | S04-AC-1 |
| CONTENTS parsed by line type | S04-AC-5 (`split()` breaks on spaces) |
| Glob compiled to an anchored regex | S04-AC-3 (`fnmatch` makes `*` cross `/`) |
| Structured allowlist, mandatory reasons, `broad` flag | S04-AC-4, AC-8 |
| Per-entry counts and invariants in the report | S04-AC-7 |
| `.bz2` alias scoped by path (`decompressed_aliases`) | S04-AC-6 (*When:* after MS2; the port keeps the unconditional alias until then) |

### Why the walker replaces Syft `files[]`

**Decision:** the gate enumerates the sysroot with `os.walk` (do not follow symlinks), recording files, symlinks and directories, excluding the root itself. Ownership comes from a direct parse of `<sysroot>/var/db/pkg/*/*/CONTENTS`. Syft is no longer an input.
- Rejected: keep Syft `files[]`. It required `SYFT_FILE_METADATA_SELECTION=all`, which bloated the CycloneDX output with file components (T-schema-validation-hang, fixed in `enrich-sbom.py`), and an empty list passed silently (INV-OWN-2).
- Rejected: use B04's file-to-package manifest as the file list. It would make the gate verify B04's claim with B04's data. The gate must look at the bytes on disk independently.
- The old code already read CONTENTS directly for symlinks and directories because Syft's portage cataloger records only regular-file entries (`check-unowned.py:58-82, 233-237`), so the directly parsed set was already the real source of truth.

### CONTENTS parsing

Portage CONTENTS line types:

```
dir <path>
obj <path> <md5> <mtime>
sym <path> -> <target> <mtime>
```

Parsed by type, not with `split()`:
- `obj`: strip the last two whitespace-separated fields (`rsplit(None, 2)`); the remainder after `obj ` is the path.
- `sym`: split on ` -> `; the left side after `sym ` is the path.
- `dir`: the remainder after `dir `.

Paths are rooted at `/`. A line with an unknown type is exit 2. Reading errors on a CONTENTS file are exit 2; the old code ignored `OSError` and `UnicodeDecodeError` per file (`check-unowned.py:80-81`), which could silently drop a package's files from the owned set and so only ever add failures, but also masks corruption.

### Input sanity (INV-OWN-2, INV-OWN-3)

Exit 2 if any holds:
- `--sysroot` is not a directory;
- `<sysroot>/var/db/pkg` is absent;
- the walk finds zero entries;
- the parsed owned set is zero entries;
- the allowlist file is missing, unparseable or fails its schema (resolves "missing allowlist is a warning").

Pillar 4 can no longer be skipped: S05's `pillars.yaml` declares it `gating: true`, and a pillar that did not produce a report is a failure (S05-AC-6).

### Allowlist (`supplychain/policy/unowned-allowlist.yaml`)

```yaml
schema: 1
decompressed_aliases:
  - {suffix: ".bz2", under: ["usr/share/man", "usr/share/info"], reason: "extract-packages.sh runs bunzip2 on man pages"}
allowlist:
  - {path: "etc/passwd-", reason: "shadow-utils backup of /etc/passwd"}
  - {path: "usr/share/fonts/*/fonts.dir", reason: "generated by build-rootfs.sh mkfontscale; font ebuild postinst never runs on ROOT installs"}
  - {path: "var/db/pkg/**", reason: "Portage database itself", broad: true}
```

- Paths are relative to the sysroot, no leading `/`. A pattern starting with `/`, containing `..`, or empty is a schema error.
- `reason` is mandatory and non-empty. Duplicate `path` values are an error.
- `broad: true` is required on any pattern containing `**`, so reviewers see the wide ones. Unknown keys are rejected.
- Glob semantics, implemented by compiling to an anchored regex; `fnmatch` is not used:
  - `*` matches any run of characters except `/`;
  - `?` matches one character except `/`;
  - `**` matches any run including `/`;
  - a pattern matches the entry path exactly, not as a prefix.

  This is what the old file's comment already promised (`unowned-allowlist.yaml:7`). Rejected: keep `fnmatch` and fix the comment. The comment documents the intended behaviour, and the single-star patterns in the file are written as if segment-local.
- Migration check: the four old entries with a single-star or `?` wildcard (`unowned-allowlist.yaml:24, 109, 127, 161`) are all segment-local by inspection of the pattern text. Whether any rc1 file relied on the cross-slash behaviour is not known from the study and is checked by the first slow run (AC-10).
- `decompressed_aliases` replaces the unconditional `path + ".bz2"` owner alias (`check-unowned.py:259-263`). It applies only under the listed prefixes. This is S04-AC-6, which is *When:* after MS2: the first allowlist keeps the unconditional alias (a top-level `bz2_alias: true`, accepted by the schema until AC-6 removes it). The scoping is a tightening, not a fix for a verified bug.
- `fail`ing entries are not the only output: per-entry **match counts** and the list of **unused** entries are in the report.

### Evaluation order

For each walked entry `p` (sysroot-relative with leading `/`):
1. owned if `p` is in the owned set;
2. owned if `p + suffix` is in the owned set for a `decompressed_aliases` rule whose `under` prefix covers `p`;
3. allowlisted if an allowlist pattern matches `p` (first match wins; the count is attributed to that entry);
4. else unowned.

The report invariant `walked == owned + allowlisted + unowned` is asserted by the tool.

### Report (`unowned-report.json`)

Schema `unowned-report.schema.json`. Fields: `schema`, `gate: "unowned"`, `verdict` (`pass|fail`), `verdict_reasons[]`, `inputs{sysroot, allowlist_path, allowlist_sha256, contents_files, owned_paths, contents_sha256}`, `summary{walked, owned, allowlisted, unowned, owned_missing}`, `unowned_files[]` (sorted), `allowlist_usage[{path, matched}]`, `unused_allowlist[]`. `walked` replaces the old `total_files`.

The report records no SBOM hash because the gate no longer reads one. It records `inputs.contents_sha256` instead: sha256 over the sorted list of `(vdb path, sha256 of CONTENTS)` pairs. This identifies which package set was audited. Owned paths that are absent from the sysroot are normal, since rootfs cleanup (B04) may remove installed files. They are counted as `owned_missing` and are not an error.

### Allowlist migration

The 103 old entries become structured entries. Each section comment in the old file becomes the `reason` of the entries beneath it. Sections that are only a comment header (FHS directories, generated config) are expanded, with one reason per entry or per group sharing the same text. No entry is dropped in this node; shrinkage is R05's. The migration test requires every old pattern to appear in the new file verbatim, or in a top-level `dropped:` list with a reason.

## Traps and doctrines preserved

- **D-hand-authored-rootfs-files-owned.** If an unowned file can slip through, the doctrine is a wish. AC-2 (fail on an unowned file), AC-3 (glob semantics), AC-4 (every allowlist entry justified).
- **Principle 5, success is honest.** A gate that passes on nothing is not a gate. AC-1 closes the empty-input pass, the missing-input skip and the missing-allowlist warning.
- **T-syft-quirks.** Removed rather than worked around: no Syft dependency, no `files[]` schema variants (`installedFiles`, `Files`, `files`), no `SYFT_FILE_METADATA_SELECTION`.
- **T-schema-validation-hang.** The Syft setting that created 16,553 file components is gone (S01).
- **AGENTS.md rule (old repo, line 137).** "Hand-authored `$ROOTFS_DIR` files MUST be added to `unowned-allowlist.yaml` or Pillar 4 fails the build." Preserved; R05 is the node that makes this obsolete.

### Invariant and contradiction disposition (this node)

| Item | Disposition |
|---|---|
| INV-OWN-1 | AC-2, AC-6 |
| INV-OWN-2 (weak: empty `files[]` warns and passes) | **Replaced.** The gate walks the disk; empty is exit 2 (AC-1) |
| INV-OWN-3 (missing `sbom.syft.json` skips, counts as PASS) | **Replaced.** No Syft input; a missing report fails in S05 (AC-1; S05-AC-6) |
| Contradiction: `*` vs `**` | AC-3 |
| Weakness: missing allowlist is a warning | AC-1 |
| Weakness: CONTENTS `split()` | AC-5 |

## Gate

- **S04-AC-1** — Input errors are exit 2 and write no passing report: sysroot not a directory; no `var/db/pkg`; empty walk; zero owned paths; allowlist missing, unparseable, or schema-invalid. A sysroot with a vdb and zero files other than the vdb's own passes only if those entries are owned or allowlisted. *Verify:* `tests/fast/test_unowned_inputs.py`. *Tier:* fast.
- **S04-AC-2** — On a fake sysroot with a vdb, an entry present on disk but absent from every CONTENTS and not allowlisted is `unowned`, listed in `unowned_files`, and the exit is 1. Directories, symlinks and regular files owned via `dir`, `sym` and `obj` lines are each owned. *Verify:* `tests/fast/test_unowned_gate.py`. *Tier:* fast.
- **S04-AC-3** — Glob semantics: `*` does not match `/`; `**` does; `?` does not match `/`; matching is anchored; a pattern with a leading `/` or `..` or empty string is a schema error (exit 2). *Verify:* `tests/fast/test_unowned_glob.py` (table test). *Tier:* fast.
- **S04-AC-4** — Allowlist schema: every entry has a non-empty `reason`; `**` requires `broad: true`; duplicate paths and unknown keys are rejected. The shipped `unowned-allowlist.yaml` passes. *Verify:* `tests/fast/test_unowned_allowlist.py`. *Tier:* fast.
- **S04-AC-5** — CONTENTS parsing handles names with spaces in `obj`, `sym` and `dir` lines, ` -> ` in a symlink line, and rejects an unknown line type with exit 2. *Verify:* `tests/fast/test_unowned_contents.py`. *Tier:* fast.
- **S04-AC-6** — The decompressed-alias rule applies only under its `under` prefixes: `usr/share/man/man1/x.1` is owned via `x.1.bz2`; the same suffix situation under `usr/bin` is unowned. *Verify:* `tests/fast/test_unowned_gate.py::test_alias_scope`. *Tier:* fast. *When:* after MS2.
- **S04-AC-7** — Report invariants: `walked == owned + allowlisted + unowned`; `allowlist_usage` counts sum to `allowlisted`; entries that matched nothing are in `unused_allowlist`; `inputs.allowlist_sha256` equals the sha256 of the file; the report validates against its schema; `unowned_files` is sorted. *Verify:* `tests/fast/test_unowned_report.py`. *Tier:* fast.
- **S04-AC-8** — Migration: every pattern in `tests/fixtures/supplychain/unowned/allowlist-b9f533b.yaml` appears verbatim in the new allowlist or in its `dropped:` list with a reason; none of the four single-star or `?` patterns now matches across `/` on a probe path set built from the old comments. *Verify:* `tests/fast/test_unowned_migration.py`. *Tier:* fast.
- **S04-AC-9** — The gate has no Syft dependency: the module imports no JSON from a Syft file and does not mention `syft` or `files[]`. *Verify:* `tests/fast/test_unowned_gate.py::test_no_syft_input` (grep assertion). *Tier:* fast.
- **S04-AC-10** — On the sysroot of our first ISO, extracted from its squashfs, the gate exits 0; every allowlist entry's match count is shown in the log; any entry that matched a different file set than expected is reviewed in the PR (printed table). *Verify:* `build.yml` attest job step "Unowned gate"; report read by S05. *Tier:* slow.
- **S04-AC-11** — The rc1 lane: on rc1's extracted squashfs (O01 fixture, fetched by digest), the gate exits 0 with the allowlist converted from b9f533b's. Any file the walker finds that the old Syft-based gate did not report is added to the allowlist with a written reason, and the PR lists them. The report's `walked`, `owned`, `allowlisted` and `unowned` counts are recorded as evidence, and the sum invariant holds. The test fails, not skips, if the fixture is absent. *Verify:* `tests/slow/test_unowned_rc1.py`, run by the rc1-lane CI job; no build. *Tier:* slow.

## RED plan

- The port lands first (script and allowlist copied, run on the rc1 rootfs). The tester then writes `tests/fast/test_unowned_{inputs,gate,glob,allowlist,contents,report,migration}.py`. They fail against the port: it passes on an empty `files[]`, skips a missing allowlist, and lets `*` cross `/`.
- Fixture builder `tests/fixtures/supplychain/unowned/make_sysroot.py` creates fake sysroots in a temp directory from a table of `(path, kind, owner)`; no checked-in tree of files.
- `allowlist-b9f533b.yaml` is a verbatim copy of the old file, added in the RED commit so AC-8 compares against the real thing.

## Risks and open questions

- **Owned does not mean unmodified.** A file listed in CONTENTS but replaced or edited after install passes. Old gate had the same hole. Portage records an md5 for each `obj`; checking it would catch `build-rootfs.sh` edits to owned files, but some such edits are intentional and would need their own allowlist. No node in the graph owns this. Candidate for B04 (it already records the package for every file) or R05.
- **Wide globs hide files.** `var/db/pkg/**`, `var/cache/edb/**`, `var/lib/portage/**` allowlist whole trees (`unowned-allowlist.yaml:56-58`). The per-entry counts make this visible but do not limit it. R05 should decide whether these trees should be removed from the shipped rootfs instead.
- The allowlist lives in the protected `supplychain/policy/`, but R05's job is to shrink it and agents cannot edit protected paths. See Spec defects.
- The rc1 allowlist is the starting point and rc1 is the first test. If the walker reports files the Syft-based gate never saw, the allowlist grows in this node. R05 then has more to remove. That is the honest count.
- The sysroot extraction (`unsquashfs`) may need privileges or fail on device nodes; this belongs to B04/B06 and surfaces here as exit 2.
- Whether the walker sees the same entries Syft's file cataloger did (including directories) is unknown. The old allowlist contains directory names (`dev`, `proc`, `etc/network`), which suggests directories were reported; the rc1 run (AC-11) confirms, with no build needed.
- Time: walking a rootfs of tens of thousands of entries in Python is seconds. Not measured; AC-11 measures it.
- The rc1 squashfs must be extracted to a directory. `unsquashfs` as non-root may fail on device nodes; O01's fixture extraction owns the workaround and S04 reads the result.
- No SPEC OD applies.

## Cost

- Slices: 2.
  1. Port; then walker, CONTENTS parser, glob engine, inputs sanity (AC-1, 2, 3, 5; AC-6 after MS2).
  2. Allowlist schema, migration, report, the rc1 run, CI wiring (AC-4, 7, 8, 9, 11, 10).
- CI build cycles: 0 for the rc1 lane (AC-11). AC-10 rides the attest job of B06's first ISO (MS1), shared with S01 to S03.
- Money: none.

## Spec defects found

1. **Protected path blocks the node that shrinks the allowlist.** SPEC section 8 makes `supplychain/policy/` protected and says agents may not edit protected paths. Putting `unowned-allowlist.yaml` there is right for additions (growth loosens the gate) but R05, whose purpose is to remove entries, is agent-run and could not do its work. Resolution needed from the owner: either allow deletion-only edits to this file by agents (a rule F04 can check mechanically on the diff), or move the file out of `policy/` and gate additions another way. I put it in `policy/` pending the owner's call.
2. **Sequencing with R05 (v0.3 order).** R05 now depends on S04, not the reverse. S04's allowlist starts at its rc1 size and AC-10 passes with it. R05 shrinks the file afterwards. No change needed; noted so nobody waits for R05.
