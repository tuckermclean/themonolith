# AGENTS.md

Working notes for agents and contributors. `SPEC.md` is the authority on what is built; this file is
about how to work on it. The predecessor's guide follows this section: doctrines, traps, recipes and
credential handling.

## Where things are

- `SPEC.md`: product, constraints, the standard-mechanism table (§5), pins, oracle, release rules,
  open decisions (§10), conventions (§11).
- `docs/graph.yaml`: the 22 nodes, their dependencies and the three milestones.
- `nodes/<ID>-<name>.md`: one spec per node, in the SPEC §9 template.
- `docs/first-release.md`: the plan, owner actions and measured timings.
- The port source is `tuckermclean/linux-live-iso-factory` at `b9f533b`. Cite it as `path:line` at that
  commit. `docs/capabilities.md` says which node ports or builds each capability; `docs/migration.tsv`
  lists every predecessor file with its blob, node, disposition and destination
  (`scripts/check-migration.py` checks it).
- `toolbox/` is the test image, `toolbox/run` and the workflow runner `toolbox/ci`; `.claude/` holds the
  `/node` skill, the role agents and the guard hook.
- Nothing builds yet. `make test` runs every test; each node ports the code its tests need and adds
  its tests to it.

## Commands

- `toolbox/run -- <cmd>` runs a command in the test toolbox, with the checkout mounted at its own path.
  `toolbox/run` alone opens a shell; `--build` rebuilds the image; `--network none` cuts the network.
  The image rebuilds by itself when `toolbox/` changes.
  `-e NAME` forwards a variable; `CI`, `GITHUB_ACTIONS` and the `GITHUB_OUTPUT`-style files always pass.
- Read predecessor files with `git fetch --no-tags https://github.com/tuckermclean/linux-live-iso-factory
  b9f533b740b1db7bf5658d2805603d84e9b1f185`, then `git show b9f533b:<path>`. The fetch creates no branch
  or tag; never merge it.
- `toolbox/run -- toolbox-selfcheck` checks that every tool is present at its pinned version.
- Make is the build and test interface, run on the host; each target uses the toolbox or the builder
  image itself. `make test` runs every test (SPEC §7), building what it needs. `make test-lint test-unit` is the PR check without a build; run it before pushing.
  `toolbox/run -- sh scripts/tests/<name>.test.sh` runs one test file.
- `toolbox/ci lint` checks the workflow rules (SPEC §7). `toolbox/ci run <workflow> [<job>...]` runs a
  workflow's `run:` steps in this checkout as a convenience (`--event`, `--input k=v`, `--matrix k=v`).
  It does not model separate runners or artifact and cache transfers: jobs share one checkout here, so
  anything that moves files between jobs is verified in CI.
- Boot a mode: `toolbox/run -- python3 scripts/boot-test.py --iso <iso> --mode bios --kernel-version
  <version>`. Read the version from the ISO with `xorriso -osirrox on -indev <iso> -extract /boot/vmlinuz
  /tmp/vmlinuz` and `file /tmp/vmlinuz`.
- Package builds and the SBOM gates run in the builder image, with podman, pulled by digest.
- `python3 -I .claude/skills/node/check-spec.py` checks the graph against the node specs; `--write`
  regenerates the header rows.
- `sh .claude/hooks/guard.test.sh` tests the guard hook; `sh toolbox/ci.test.sh` tests `toolbox/ci`.

## Building a node

- Use `/node <ID>`. It writes a brief, has a fresh tester commit failing tests (RED), checks them, has a
  fresh implementer make them pass (GREEN), gets an independent review, runs the criteria that need a build, an ISO or CI, and opens
  a PR with the criterion → evidence table.
- `make test` runs every test; its `test-*` targets run parts of it (SPEC §7). Tests come first. A
  criterion verified by a build, a boot or a CI run is met only by a recorded run: a local log or a CI
  URL.
- Role agents may not edit the spec, `AGENTS.md`, `CLAUDE.md`, `.claude/` or `toolbox/`; the guard hook
  blocks it. Spec changes go to the owner.

## Traps

- **Rootless podman without a systemd user session** fails with "Interactive authentication required".
  `toolbox/run` passes `--cgroup-manager=cgroupfs` in that case; do the same for direct podman calls.
  With cgroupfs, podman also leaves an empty `oom` file in the directory it starts from; `toolbox/run`
  starts it from a state directory. Never commit an `oom` file.
- **QEMU runs in software, here and in CI.** `boot-test.py` uses `-cpu 486`, which means something only
  under emulation (and even then is not a full post-486 instruction check), so `toolbox/run` passes no
  `/dev/kvm`. Boots take about a minute and the first in-guest check
  can hit its 30 s timeout. Re-run before suspecting the disc.
- **A step timeout must stop the container.** `toolbox/run` starts containers with `--init`, so SIGTERM
  reaches the command; without it a timed-out step leaves its container running.
- **Workflow files need the `workflow` scope to push.** The default `gh` token lacks it, so a branch that
  changes `.github/workflows/*` is rejected. Use a token the owner provides, transiently, or ask the owner
  to push.

## Constraints on every change

- i486, statically linked against musl, cross-compiled with crossdev. No Python and no freetype on the
  disc (SPEC §1, §3).
- The tested RAM floor is 64 MB. 8 MB is the aim; do not describe it as tested.
- Preserve proven code and its tests; test first, then port, and don't redesign. A node ports the
  predecessor's tests first (harness and path adjustments only), adds tests for uncovered criteria,
  establishes RED, then ports only the code those tests need (SPEC §2.2). Predecessor recipes,
  scripts and tests carry over unchanged unless a node spec lists the change.
- Use Portage and standard tools. Custom code only where SPEC §5 names a gap.
- Make is the interface (SPEC §7): operations are Make targets backed by `scripts/`, and workflows only
  call them. A workflow that can trigger passes `toolbox/ci lint`: each `run:` command is
  `make <target>`, or `toolbox/run -- <cmd>` for a step that is not a test, values reach `run:` through `env:`, and tools come
  from the toolbox, never `apt-get` or `setup-*`. Put logic in `scripts/`, not YAML.
- Provenance lives in `docs/migration.tsv` and Git history, not in source files: no "ported from"
  comments. A porting commit names the predecessor paths it lands; `scripts/check-migration.py` checks
  the ledger.
- MS1, a working ISO for iteration, comes first. Do not add work to its path; SPEC §10 lists the concerns
  tracked outside it.

## Editing the spec

- Change `docs/graph.yaml` first. A node's header row (track, deps, unlocks) must match it.
- Acceptance criteria are `<ID>-AC-<n>`, each with *Verify*. Open decisions are `OD-<n>`,
  numbered without gaps.
- Write specs, README, plan and PR descriptions as the current state, with no revision history ("v0.3
  had…", "withdrawn"). Change notes go in commit messages and `docs/reviews/`.
- Describe the project by what it is (`MYTH.md`), not as "a small Gentoo derivative".
- Branches and PRs: SPEC §11.

## Don't touch

- `docs/study/`: the frozen study of the predecessor.
- `docs/reviews/`: dated history. Append; don't edit old entries or link to them from reader-facing docs.
- The predecessor repository: never rename it (rc1's attestation names it) and don't push to it. X01
  archives it.
- The rc1 builder image and binary packages on GHCR: copy by digest, never retag or delete.

## Git conventions

Preserve existing history and attribution. Don't rewrite historical commits for cosmetic reasons. Use
the configured Git identity for new commits. AI assistance may be noted in commit messages or PR
descriptions, but doesn't require special attribution machinery.

---

# The Monolith — Agent Working Guide

**Read this first if you are an AI agent (or new contributor) picking up work on this repo.**

`README.md` and `docs/` document *what the system is and how it's built* — read those for
architecture (build pipeline, boot matrix, attestation, package set). **This file captures the
tacit knowledge that you cannot grep for**: the design doctrines, how the maintainer wants work
done, and the hard-won traps and recipes discovered while building this. Keep it updated — it is
the durable handoff record.

The project owner is **Tucker McLean** (me@tuckermclean.com), the sole developer. He is
technically deep (Gentoo internals, CI/CD, SLSA/attestation, low-level boot), cost-conscious
about AWS/CI spend, and terse. He values getting to the point over exhaustive option surveys.

---

## Design doctrines — hard rules

Violating these wastes his time. When in doubt, ask "would this run on a 486?"

- **486-target minimalism.** Everything must run on an i486 with a few MB of RAM. Do not pull in
  heavy dependencies. The reflex challenge to any addition is *"we're trying to run this on a 486,
  remember?"*
- **rootfs is all-static.** Dynamic binaries fail at boot. The "musl libc not found" warning means
  static-only, not benign.
- **Python stays out** of the target rootfs. See the tmpfiles→systemd-utils→python trap below.
- **Bitmap-only fonts. NO freetype / fontconfig / Xft.** The disc ships bitmap fonts (Terminus is
  the default X font). Any package that drags in freetype — commonly via `font.eclass` →
  `x11-apps/mkfontscale` → `media-libs/freetype` — is rejected. Break the chain with
  `package.provided`, do not accept the dep.
- **Don't add back things we deliberately removed.** He will notice and be annoyed.
- **The clock-epoch origin sentinel is `1970-01-01` (the Unix epoch) — NOT Y2K.** We fought for
  1970 and 1970 won: `CLOCK_EPOCH_RTC = "1970-01-01T00:00:00"` in `boot-test.py`, "the truest image
  of a machine whose clock never started." A commit once moved it to 2000-01-01, but that was a
  **misdiagnosis** (the `clock-epoch` test was hanging on a long `monolith_time_url=…` ISOLINUX boot
  label, not the RTC) and was reverted — *"Y2K is too late; it occurs AFTER the origin myth in the
  story."* Separately, the runtime `monolith-time-check` recognizes 1970 / 1980 / 2000 as dead-clock
  "ignorance" sentinels (`SENTINELS="0 315532800 946684800"`) because real hardware resets to any of
  them — that's detection breadth, not the origin.

He built an honest, elaborate supply-chain pipeline (SLSA provenance, a digest-chain invariant,
a CVE gate). Releases should come *through* that pipeline and be verifiable. He dislikes UI cruft
(e.g. he had the `g` / `/` keyboard shortcuts ripped out of the dashboard).

---

## How to work with him

- Treat `.github/workflows/*` and the release / signing path as **high-stakes** — surface and
  explain such changes clearly rather than making them quietly. How and when work gets integrated
  is Tucker's call, established per task; don't assume it.
- **Pushing workflow files needs a `workflow`-scoped PAT.** The default `gh` token has only
  `gist, read:org, repo`, which GitHub rejects for `.github/workflows/*` pushes. Use a PAT
  **transiently** (inline `git -c credential.helper=…` or an env-scoped `GH_TOKEN`), never written
  to `.git/config` or `gh auth`. **⚠️ A PAT used in the prior chat is exposed in that history and
  MUST be rotated — never carry it forward. Obtain a fresh one or have Tucker push workflow files
  himself.** Never commit a token to the repo.
- **Debugging discipline** (this repo rewards it):
  - **Capture stderr before theorizing.** A `2>/dev/null` once masked a `dd: not found` and sent a
    debugging session chasing the wrong cause. Never hide stderr while debugging.
  - **Instrument both sides of a boundary early** when a multi-component flow misbehaves.
  - **Tests aren't free.** Every boot test must mean something; de-flake rather than pile on
    retries.
- **Recovery instinct he appreciates:** if a build is green but only a downstream publish/wrapper
  step failed, recover from the already-verified artifact rather than triggering a wasteful full
  rebuild (a from-source Monolith build is ~30–60 min).

---

## Build / CI / release essentials

Architecture is in the repo — start with `README.md` (Build instructions), then:
`docs/releasing.md`, `docs/version-pinning.md`, `docs/cve-gate.md`, `docs/kernel-tiers.md`,
and `docs/superpowers/specs/` for design specs.


---

## Traps & hard-won recipes (knowledge base)

Symptom → cause → fix. These cost real debugging time; don't rediscover them.

**Agent workspace / git traps**
- **"detected dubious ownership" → the checkout is fine, your git env is not.** `/workspace` is
  owned by `root` while agent runs execute as uid 1000, so git refuses the repo unless
  `safe.directory` is set. The workspace *does* export `GIT_CONFIG_KEY_0=safe.directory` /
  `GIT_CONFIG_VALUE_0=*`, but it exports **`GIT_CONFIG_COUNT` empty** — and git only reads
  `GIT_CONFIG_KEY_n`/`VALUE_n` for `n < GIT_CONFIG_COUNT`, so every pair is silently ignored.
  Every git command then dies, and the error's own suggested remedy
  (`git config --global --add safe.directory`) *also* fails, because `GIT_CONFIG_GLOBAL` and
  `GIT_CONFIG_SYSTEM` are both pinned to `/dev/null`. Fix, first thing in any run that touches git:
  `. scripts/agent-git-env.sh` (or, inline, `export GIT_CONFIG_COUNT=2`). Verify with `git status`
  printing a branch name. **Do not conclude "there is no checkout here" and redo work from
  scratch** — that misdiagnosis burned six consecutive implementation passes on DCX-99.
- **"fatal: empty ident name (for <>) not allowed" when committing.** The workspace exports
  `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_*` as *empty strings*, and an empty env
  identity outranks even `git -c user.name=... commit`. Unset the empty ones first — that is what
  `agent_git_clear_empty_identity` in `scripts/agent-git-env.sh` is for.
- **The workspace is a fresh shallow single-branch clone every run.** `.git/shallow` is present and
  only `master` is fetched, so branches and commits you created in a previous run are *gone* — the
  shared workspace shares files, not git history. Deepen with
  `git fetch --unshallow origin` (or `git fetch origin <branch>`) when you need history, and see
  the handoff rule below before ending a run.
- **Hand off code as a patch, not as a local branch.** Agents other than the Release Engineer have
  no push path (the managed credential broker reports `broker_transport_unavailable`, so even the
  `git` shim falls back to unmanaged credentials). Since local branches do not survive the run,
  a branch alone is not a handoff. Before you end a run, attach the work to the issue:
  `git format-patch origin/master --stdout > /tmp/dcx-NN.patch` and upload it as an issue
  attachment. The next agent replays it with `git am`.

**Packaging / dependency traps**
- **freetype trap:** `font.eclass` RDEPENDs `mkfontscale` which RDEPENDs `freetype`. Adding any
  bitmap-font package can silently pull freetype in. Fix: `package.provided` the
  `freetype`/`mkfontscale`/`encodings` chain (see `configs/portage/profile/package.provided`).
- **tmpfiles → systemd-utils → python trap:** any `inherit tmpfiles` package (ppp, mutt via
  cyrus-sasl, …) pulls `virtual/tmpfiles` → `systemd-utils[tmpfiles]`, which `REQUIRED_USE`-needs
  Python → emerge fails at dep resolution. Fix options: `package.provided` / an overlay virtual.
- **Overlay-ebuild revbump busts binpkg cache:** editing an overlay ebuild *in place* after its
  first green build silently reuses the stale binpkg under `emerge --usepkg`. Always revbump
  (`-rN`) and bump `versions.lock` to force a rebuild.
- **rootfs files unowned by attestation:** hand-authored `$ROOTFS_DIR` files (init scripts, `/etc`,
  monolith-net) MUST be added to `unowned-allowlist.yaml` or attestation Pillar 4 fails the build.
  Every new one needs an entry. (Longer-term plan: a `monolith-base` ebuild to own them.)
- **cross-toolchain missing `libatomic.a`** — FIXED (PR #32): `EXTRA_ECONF='--disable-shared
  --enable-static'` on `cross-*/gcc` in the Dockerfile (the `static-libs` USE was a no-op).
- **acct-user/dnsmasq collision** (nondeterministic): `acct-user/dnsmasq` can fail pre-merge →
  `--keep-going` drops `net-dns/dnsmasq` → dnsmasq missing from rootfs → nat-router boot test fails.
  A rebuild usually clears it.

**Static cross-build recipes (i486-musl)**
- **Rust:** rustup nightly + `build-std` + 6 link fixes → static i486-musl. First used for `rl144`;
  also how `www-client/stele` builds.
- **perl-cross static musl (`-Uusedl` perl 5.42):** the full gauntlet — `_GNU_SOURCE`,
  `--allow-multiple-definition`, `-DNO_LOCALE`, and the big one: force per-module `pm_to_blib` or
  ship NO static-ext `.pm`.
- **DBD driver can't `static_ext` into `-Uusedl` perl:** `DBD::SQLite`'s `Makefile.PL` needs an
  importable `DBI` at configure time but miniperl can't load DBI's XS. Workaround: the guestbook
  uses the `sqlite3` CLI instead.
- **TinyX Xfbdev static build:** 5 vendored server header shims, no client libs, `Xpoll` from
  xorg-proto, a GCC-14 `-Wno-error` quartet. Lesson: enumerate the whole header gap *before*
  spending another build cycle.
- **X client libs (libX11/libxcb/libXext) cross+static:** dodge the modern-X Python tar-pit with a
  data-only overlay `xcb-proto` (host-python codegen; no target python/libxml2/zstd).
- **X Terminus default font:** bitmap-only, no freetype. `pcf-fontname.py` reads a PCF's `FONT`
  property to generate `fonts.dir`; XLFDs are CamelCase (`-xos4-Terminus-Medium-R-Normal--…`);
  `fonts.alias` maps `fixed`/`variable`/bold/heading.

**Boot / runtime**
- **initramfs busybox lacks `dd` and `findfs`** (stale binpkg): read block-device labels with
  `cat | tr | grep`, not `dd`/`findfs`.
- **nat-router link-local flake:** `monolith-router` skipped assigning the LAN gateway CIDR when
  `eth1` held a failed-DHCP `169.254` link-local. (Instrument both sides of a boundary early.)
- **kernel module tiers:** three-tier (Tier 0/1/2) driver split balancing the 486 vs modern UEFI
  boxes — full writeup in `docs/kernel-tiers.md`.
- **DDC sub-option → `CONFIG_I2C=y` trap:** `FB_DDC` is a `tristate`, but `select` raises its target
  to *at least* the selecting symbol's value — so a `bool` sub-option at its Kconfig default `y`
  (`FB_RADEON_I2C`, `FB_3DFX_I2C`, `FB_CYBER2000_DDC`) forces `FB_DDC=y`, which `select`s
  `CONFIG_I2C=y`: a whole subsystem built into `bzImage` from one unexamined driver sub-option, with
  no error or warning. Caught while enabling the legacy fbdev Tier-2 set (24 `=m` framebuffer
  drivers) — see `docs/superpowers/specs/2026-09-17-legacy-fbdev-design.md` §Sub-options. Fix: force
  the `default y` DDC bools off explicitly rather than trusting `olddefconfig`'s default, and assert
  `CONFIG_I2C != y` in a config test so a future kernel bump that flips a default can't reopen it
  silently.

**CI / release**
- **`actions/attest` can't persist from a reusable workflow:** GitHub binds the Sigstore cert SAN
  to the *entry* workflow. Calling `build.yml` via `workflow_call` from `release.yml` failed with
  `values do not match: build.yml != release.yml`. Fix: build.yml owns the tag trigger; release.yml
  publishes via `workflow_run`. (PR #55.)
- **A prerelease can never be GitHub "Latest"** — `HTTP 422: Latest release cannot be draft or
  prerelease`. Publish prereleases `--prerelease --latest=false`. (PR #56.)

---

## Roadmap (deferred, owner-aware)

- **Networking-box arc (SP1–SP5):** netboot is deferred behind a persistence → initrd-mod UI.
- **Stele browser** (`www-client/stele`): Rust i486 browser, currently direct-framebuffer; an X11
  wire backend is on the roadmap. REPIN it each build.

---

## Current status (2026-08-21, at harness handoff)

*Verify against `git log` and `gh` before trusting — this is a point-in-time snapshot.*

- **`master` = `e20a252`.** The release pipeline is complete and correct end-to-end. The relevant
  changes landed as **#54** (from-source tag builds + dashboard timestamp sort), **#55** (decouple
  attest/publish via `workflow_run`), **#56** (prereleases never "Latest").

---

*Note for maintainers: the outgoing agent kept per-fact notes in a Claude Code memory directory that
does not travel between harnesses. This file supersedes those notes as the in-repo durable record —
add to it here rather than relying on any external memory.*
