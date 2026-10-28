# I04 — distfiles-mirror

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| I | I01, I03 | B01 | — (needed for MS2) | L |

**Owns:** `factory/bin/distfiles` (`plan`, `stage`, `record`, `report`, `vendor-crates`), `factory/bin/distfiles-fetch` (portage `FETCHCOMMAND` wrapper), `distfiles/exceptions.yaml`, `distfiles/stable-hosts.txt`, `tests/fast/distfiles-*.test.sh`, `tests/fast/fixtures/manifests/` (verbatim Manifests copied from the predecessor overlay and a gentoo-tree sample), CI job `distfiles-offline-subset`.
**Carries from linux-live-iso-factory@b9f533b:** nothing as code. The idea of a persistent distfiles volume (`Makefile:80,101`, volume `monolith-distfiles`, volume lost between CI runs) and the `rm -rf /var/cache/distfiles/*` after each emerge layer (every emerge `RUN` in the `Dockerfile`) are replaced.
**Study refs:** D-static-musl-cross-all-the-way ("every source Manifest-pinned (BLAKE2B+SHA512)"), D-supply-chain-honesty, D-tag-builds-from-source, T-glib-docutils-eigen-live, T-live-ebuild-and-host-keyword-skew, T-rust-i486-musl, Principle 2, OD-5, `ext.gentoo-distfiles`, `ext.kernel-org`, `ext.git-github`, build.yaml hazards ("Host build tools: frozen by snapshot only while upstream distfiles still exist"), build.yaml artifacts ("distfiles: docker volume only").

## Purpose
After this node every source file an emerge fetches is stored by content hash, builds look in the mirror before upstream and report every upstream fetch, and a mirrored tree rebuilds with the network off. The predecessor kept distfiles only in a throwaway Docker volume, so each build depended on every upstream host being alive and unchanged on that day. A frozen portage snapshot (I02) is worthless once its `SRC_URI` targets disappear.

## Scope
In:
- Build the fetch plan for a build (host and cross) from the actual emerge dependency closure.
- Stage mirrored files into `DISTDIR` before the build; record and upload anything fetched from upstream after it.
- A `FETCHCOMMAND` wrapper that logs every upstream fetch and refuses in offline mode.
- The report of upstream fetches and mirror volume, and the OD-5 scope switch.
- Deterministic vendoring of cargo crates for the two Rust packages.
- The offline-rebuild proof.

Out:
- Calling `distfiles stage`/`record` from the build workflow and choosing offline for tag builds: B01, B06 (this node provides `DISTFILES_ALLOW_UPSTREAM`).
- Editing ebuilds so rl144 and stele consume vendored crates and drop `RESTRICT=network-sandbox`: R01 (see Spec defects).
- Storage backends and the immutability contract: F06, I01. Retention: M03 (distfiles kept forever while referenced).
- Kernel tarball choice and rebuilds: B02.
- Fetches made inside the builder image build itself are covered by calling the same tool: this node's AC-14, wired through I03's Dockerfile `net-allowed` lines.
- The decision itself between "every distfile" and "only at-risk files": OD-5 (default: every distfile).

## Design
**Facts about the inputs.**
- Gentoo Manifests carry only `BLAKE2B` and `SHA512` plus size per `DIST` line (example `x11-base/monolith-xserver/Manifest:1`: size 788302). The store's distfile key is `sha256/<hex>` (SPEC §5). The two are joined by an index.
- Overlay `Manifest` files exist for 10 overlay directories; the overlay uses thin manifests (`configs/overlay/metadata/layout.conf`), so only `DIST` lines are present.
- Source URIs in the overlay: `cdn.kernel.org` (linux-6.12.80.tar.xz, 148,229,368 bytes per the kernel Manifest), `sqlite.org`, `dl.suckless.org` (dwm, st), `www.x.org` and `xorg.freedesktop.org` (libXfont, xcb-proto), perl's multi-line `SRC_URI` (`monolith-perl-5.42.0-r5.ebuild:52`), and three GitHub per-commit archives.
- **Correction to the brief:** rl144, stele and monolith-xserver are not git-fetched. They use `https://github.com/<owner>/<repo>/archive/<COMMIT>.tar.gz -> ${P}.tar.gz` (`rl144-0.1.0_p20260805.ebuild:15-16`, `stele-0.1.0_p20260821.ebuild:16-17`, `monolith-xserver-1.3_p20241113-r1.ebuild:20-21`), with the Manifest pinning the archive bytes. The ebuild comments warn that GitHub's archive gzip might change. The mirror therefore stores the exact bytes the Manifest accepted; no git snapshot is needed. Two of the three are first-party repositories (tuckermclean/rl144, tuckermclean/stele-browser); tinycorelinux/tinyx is third-party.
- rl144 and stele also run `cargo` with network access at build time (`RESTRICT="network-sandbox"`, `rl144 ebuild:28-31`, `stele ebuild:33-34`), and rustup downloads the nightly (I03). Crates are fetched from crates.io and are not covered by any Manifest.
- Distfiles volume: unknown. Known: kernel 148 MB. A full measurement is the first deliverable of `distfiles report`. A guess: several hundred files, low single-digit GB (not measured; flag as estimate).

**Keys (class `distfile`).**
- `sha256/<hex>` — the file body (SPEC §5).
- `index/sha512/<128 hex>` — JSON `{"file":…, "sha256":…, "size":…, "blake2b":…, "uris":[…], "first_seen":"<BUILD_EPOCH>"}`; the lookup path, since Manifests give sha512. `first_seen` is the epoch, never a wall-clock time (determinism).
The SPEC's "(+ name index)" is interpreted as this hash index. Rejected: a name index (`name/<FILE>`); names are not unique over time (GitHub re-rolls, `-> ${P}.tar.gz` renames).

**Plan.** `distfiles plan --root <root> [--cross]` runs inside the builder with the runtime tree synced: `emerge --pretend --emptytree --with-bdeps=y --quiet <world>` for the host closure and for the cross closure (`i486-linux-musl-emerge`), extracts `cat/pkg-ver`, fails (exit 1) if any ends in `-9999` (live ebuilds mean no Manifest, T-glib-docutils-eigen-live, T-live-ebuild-and-host-keyword-skew), then for each cpv intersects the `DIST` lines of that package's Manifest with the file names in `portageq metadata / ebuild <cpv> SRC_URI` (USE applied). Output: `build/distfiles-plan.json` (cpv, file, size, blake2b, sha512).
Rejected: staging every `DIST` line of every Manifest (the gentoo tree has gigabytes of irrelevant versions).

**Stage.** `distfiles stage <plan>` (runner side, store credentials) looks up `index/sha512/…`, `store get distfile sha256/…`, and writes the file into the `DISTDIR` bind mount. Portage re-verifies every file against the Manifest itself. Files not in the index are written to `build/distfiles-missing.json`. Credentials never enter the container.

**Fetch wrapper.** `make.conf` in the builder sets `FETCHCOMMAND` and `RESUMECOMMAND` to `factory/bin/distfiles-fetch "${DISTDIR}" "${FILE}" "${URI}"`. Behaviour by `DISTFILES_ALLOW_UPSTREAM`:
- `0` (offline): exit 1 immediately with "OFFLINE: <FILE> not in DISTDIR; would fetch <URI>"; never calls `wget`.
- `1`: run `wget` (the upstream default flags), append one JSON line `{file, uri, rc, epoch}` to `build/upstream-fetches.jsonl`.
Because portage only calls the wrapper for files absent from or invalid in `DISTDIR`, "mirror first" is achieved by staging, and the log is exactly the set of upstream fetches.

**Record.** After a successful online build, `distfiles record <DISTDIR>` verifies each file against its Manifest `SHA512` and `BLAKE2B` again, then `store put distfile sha256/<hex>` and `store put distfile index/sha512/<hex>`. A put conflict (exit 4) cannot occur for `sha256/` keys; for an index key it means the same sha512 maps to a different sha256, which is a hard failure. Fork PRs without write credentials skip `record` and say so in the summary.

**Report.** `distfiles report` writes `build/upstream-fetches.json` (always present: `[]` when empty, so absence is distinguishable from emptiness) and prints file count and total bytes of the mirrored set and of this build's staged and fetched sets to the job summary.

**Scope switch (OD-5).** `DISTFILES_SCOPE=all` (default) records everything. `DISTFILES_SCOPE=at-risk` records only files whose URI host is not in `distfiles/stable-hosts.txt` (initially `cdn.kernel.org`, `distfiles.gentoo.org`), or whose URI is a `github.com/*/archive/*` URL, or whose name was renamed with `->`. Same code path, one filter.

**Cargo crates.** `distfiles vendor-crates <cpv>` runs, inside the builder with network, `cargo +<nightly> vendor --locked` against the package's `Cargo.lock` (taken from the archive after unpack), then writes a deterministic tarball (sorted names, owner 0, mtime clamped to the epoch, `xz -T1`) and puts it as `sha256/<hex>` with an index entry keyed by the sha512 of the tarball. Wiring the ebuilds to unpack it (and removing `RESTRICT=network-sandbox`) is an R01 task. Until then `distfiles/exceptions.yaml` lists rl144 and stele with owner, reason and removal condition, and the offline proof excludes them. An exceptions entry that names a package not in the plan fails the check.

**Image build use.** I03's Dockerfile permits network only on lines marked `# net-allowed: distfiles (I04)`; this node's AC-14 makes the builder image rebuild work with those steps served from the mirror. Details of the mount are in I03 (`DISTDIR` bind mount at build).

## Traps and doctrines preserved
- **T-glib-docutils-eigen-live / T-live-ebuild-and-host-keyword-skew** (a live 9999 ebuild drifting a build): `plan` refuses any `-9999` cpv: AC-1.
- **D-supply-chain-honesty / Principle 5** (fallbacks loud, missing inputs fail): upstream fetches are recorded and offline mode fails closed: AC-4, AC-5, AC-6.
- **Principle 2** (every input mirrored): AC-3, AC-7, AC-8, AC-9.
- **D-tag-builds-from-source**: a tag build compiles every package and, with `DISTFILES_ALLOW_UPSTREAM=0`, uses only mirrored sources: AC-7 (the env contract); B06 wires it.
- **D-static-musl-cross-all-the-way** (every source Manifest-pinned): `record` and `stage` both re-verify against the Manifest: AC-2, AC-3.
- **Hidden fetches** outside Manifests (cargo crates, rustup): AC-10, AC-11 and the exceptions file.
- **M02 / rebuildable builder** (image cannot be rebuilt once upstream distfiles vanish): AC-14.
- **D-state-and-no-hidden-stderr**: AC-12.

## Gate
- **I04-AC-1** — `plan` lists the cpv closure from recorded `emerge --pretend` fixtures and exits 1 naming any cpv ending in `-9999`. *Verify:* `tests/fast/distfiles-plan.test.sh` (fixtures include an `eigen-9999` line). *Tier:* fast.
- **I04-AC-2** — The Manifest parser returns file, size, BLAKE2B and SHA512 for all fixture Manifests (kernel, monolith-xserver, rl144, stele, a multi-DIST gentoo-tree Manifest) and ignores non-`DIST` lines; a line with a missing hash is an error. *Verify:* `tests/fast/distfiles-manifest.test.sh`. *Tier:* fast.
- **I04-AC-3** — For the three GitHub-archive packages, `stage` restores the exact bytes from a fake store (sha512 equal to the Manifest) and `record` refuses a file whose sha512 or blake2b differs from the Manifest. *Verify:* `tests/fast/distfiles-stage-record.test.sh`. *Tier:* fast.
- **I04-AC-4** — With `DISTFILES_ALLOW_UPSTREAM=0` the wrapper exits 1 without invoking `wget` (stub `wget` fails the test if called) and names the file and URI. *Verify:* `tests/fast/distfiles-fetch-wrapper.test.sh` case `offline`. *Tier:* fast.
- **I04-AC-5** — With `=1` the wrapper runs `wget` and appends exactly one well-formed JSON line per fetch to `build/upstream-fetches.jsonl`, including failed fetches with `rc != 0`. *Verify:* `tests/fast/distfiles-fetch-wrapper.test.sh` case `online`. *Tier:* fast.
- **I04-AC-6** — `report` always writes `build/upstream-fetches.json` (`[]` when nothing was fetched) and the report step exits non-zero when the file cannot be produced; a missing file is not treated as "no fetches". *Verify:* `tests/fast/distfiles-report.test.sh`. *Tier:* fast.
- **I04-AC-7** — `stage` in offline mode with any plan entry absent from the mirror exits 3, writes `build/distfiles-missing.json` listing every missing file, and stages nothing partially claimed as complete. *Verify:* `tests/fast/distfiles-stage-record.test.sh` case `offline-miss`. *Tier:* fast.
- **I04-AC-8** — Index and key behaviour: `record` is idempotent, writes `sha256/<hex>` and `index/sha512/<hex>` for each file, and exits non-zero if an index key already maps to a different sha256. *Verify:* `tests/fast/distfiles-stage-record.test.sh` cases `idempotent`, `index-conflict`. *Tier:* fast.
- **I04-AC-9** — Offline rebuild: after one online run primed the mirror, a build of the subset {monolith-kernel, busybox, monolith-xserver, monolith-perl} in the I03 image with `docker run --network none`, `DISTFILES_ALLOW_UPSTREAM=0` and `distfiles stage` succeeds, and `build/upstream-fetches.json` is `[]`. *Verify:* CI job `distfiles-offline-subset`. *Tier:* slow.
- **I04-AC-10** — The same offline proof extends to the whole plan once the exceptions are retired; until then `distfiles/exceptions.yaml` entries (rl144, stele: cargo network fetch) each carry `owner`, `reason`, `removal` and name a package present in the plan. *Verify:* `tests/fast/distfiles-exceptions.test.sh`. *Tier:* fast.
- **I04-AC-11** — `vendor-crates` produces a byte-identical tarball on two runs over the same vendor directory (sorted entries, uid/gid 0, clamped mtimes). *Verify:* `tests/fast/distfiles-vendor.test.sh` with a stub `cargo vendor`. *Tier:* fast.
- **I04-AC-12** — `DISTFILES_SCOPE=at-risk` records GitHub archives and renamed files but not a `cdn.kernel.org` file; `all` records both; no `2>/dev/null` or `|| true` on deciding commands in `factory/bin/distfiles*`. *Verify:* `tests/fast/distfiles-stage-record.test.sh` case `scope`; F01 lint. *Tier:* fast.
- **I04-AC-13** — The report states the real mirrored volume (count and bytes) for the first full prime, recorded in the PR and used to answer OD-5. *Verify:* CI job `distfiles-prime` summary (dispatch). *Tier:* slow.
- **I04-AC-14** — The builder image rebuilds with the host-tool and crossdev distfiles served only from the mirror: the `net-allowed` Dockerfile steps run with `DISTFILES_ALLOW_UPSTREAM=0` and the build log shows no upstream fetch. *Verify:* CI job `builder-image-offline` (reuses I03 `builder-image build` with the mirror staged). *Tier:* slow.

## RED plan
Tester writes first: `distfiles-plan`, `-manifest`, `-stage-record`, `-fetch-wrapper`, `-report`, `-exceptions`, `-vendor` tests, with real Manifests copied from the predecessor overlay as fixtures (e.g. `x11-base/monolith-xserver/Manifest`, `games-roguelike/rl144/Manifest`, `sys-kernel/monolith-kernel/Manifest`) and recorded `emerge -pq` output containing a `-9999` line. They fail because `factory/bin/distfiles` and the wrapper do not exist. The slow subset job is GREEN evidence.

## Risks and open questions
- Hardest: **the closure for the plan**. `emerge --pretend --emptytree --with-bdeps=y` for host and cross, with USE-conditional `SRC_URI`, must equal what a real build fetches. The first online prime is the proof: AC-9 fails if anything was missed. Packages pulled in only by fix-up steps (acct-user races, T-acct-user-dnsmasq-race) could be missed.
- Cargo crates and the rustup nightly are unmirrored fetches; the cargo path is an explicit exception (rl144, stele) until R01 wires vendored crates. Unknown whether `static.rust-lang.org` keeps old nightlies (see I03).
- Volume is unmeasured. At the default scope ("every distfile", OD-5) distfiles are kept forever while referenced, so the class only grows; GHCR billing for private packages is unverified. OD-5 should be answered after AC-13.
- Redistribution of third-party source in a public store: the GPL source-offer duty makes mirrors desirable, but some distfiles may be `RESTRICT=mirror`/fetch-restricted. Unknown which, if any, are in the world.
- Portage verifies the Manifest, not the sha256 key; both are checked at `record` (AC-3), so a corrupted staged file is caught by whichever runs first.
- If GitHub's archive bytes change for the same commit (the ebuilds warn about it), upstream becomes unverifiable against the Manifest, and the mirrored copy is the only copy that still builds.

## Cost
Four to five slices: (1) Manifest parser, plan, -9999 refusal (AC-1, AC-2); (2) stage, record, index, scope (AC-3, AC-7, AC-8, AC-12); (3) wrapper and report (AC-4 to AC-6); (4) vendoring, exceptions, offline subset and prime jobs (AC-9, AC-10, AC-11, AC-13, AC-14). CI build cycles: one prime run (a cold full fetch, 15 to 30 minutes of mostly download; no compile needed for `--fetchonly`) two to three offline-subset cycles (30 to 60 minutes each, since they compile) and one builder-image offline rebuild (60 to 100 minutes). Money: store storage for the distfiles volume (unmeasured; guess low single-digit GB) and egress during priming.

## Spec defects found
- No node owns turning `rl144` and `stele` into offline-buildable packages (vendored crates, dropping `RESTRICT=network-sandbox`). R01 depends only on F01 and cannot depend on I04, yet it carries the ebuilds. Needs a named owner (suggest B01 or a new R-node after I04).
- SPEC §5 says distfiles are keyed `sha256/<hex>` "(+ name index)", but Gentoo Manifests contain no sha256, so lookup needs a sha512 index. This node defines `index/sha512/<hex>`; SPEC §5 should say so.
- graph.yaml has I03 before I04, so I03's gate cannot claim the image is rebuildable offline; that claim is only provable here (I04-AC-14). I03 states this limit in its Scope.
