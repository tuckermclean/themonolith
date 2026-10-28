# P04 — boot-demo

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| P | P03 | X01 | — (feeds MS5) | M |

**Owns:** `web/app/view-boot.js` (replaces P03's placeholder), `web/vendor/v86/{libv86.js,v86.wasm,seabios.bin,vgabios.bin,VENDOR.lock}`, `web/vendor/v86/LICENSES/`, `factory/bin/vendor-v86`, `oracle/demo/v86-headless.mjs`, `.github/workflows/demo-check.yml`, `tests/smoke/demo-range.sh`, `tests/fast/web/view-boot.test.mjs`, `tests/fast/vendor-v86.test.sh`, `docs/boot-demo.md`.
**Carries from linux-live-iso-factory@b9f533b:** `web/app/view-boot.js` (v86 options at `:90-102`, serial log, fullscreen, pointer lock), the layout idea of `boot.html` (not the file).
**Study refs:** supplychain `web_runtime_fetches` (`cdn_libs`: libv86.js and v86.wasm from `cdn.jsdelivr.net/npm/v86/build/` unversioned, BIOS from `cdn.jsdelivr.net/gh/copy/v86@master/bios/`; `cors_and_range_requirements`; `isos_for_boot`); supplychain `web.app/view-boot.js` notes (timer leak, "CORS error" for any failure, wasm/libv86 mismatch risk, "ISO ~135 MB" vs README "131 MB"); supplychain `web.boot.html` (duplicate copy, not deployed); supplychain `web.index.html` (v86 loaded on every page, no SRI/CSP); SPEC §6 (v86 is a pin); SPEC §2 principle 2.

## Purpose
After this node, the "try it in your browser" demo runs from files we hold: v86 and its BIOS images are committed with exact versions and sha256, served from our own origin, loaded only when someone opens the boot page, and tested. The old demo could break on any day jsDelivr's `latest` or the `master` branch of `copy/v86` changed, with no way to notice. It also streams the ISO by HTTP range from the public host.

## Scope
In:
- Vendoring and pinning v86, `v86.wasm`, SeaBIOS and VGABIOS, with a lock file and an offline verifier.
- The boot view: lazy loading, a clean mount/unmount lifecycle, honest error messages, ISO location from `latest-release.json`.
- A headless boot check of the vendored v86 against the built ISO, and a range probe against the public host.

Out:
- The SPA shell, router, CSP, `publish.yml`: P03. This node needs the CSP to allow `'wasm-unsafe-eval'` (checked here, set there).
- The public host, Range and CORS behaviour: P01. This node tests that the published ISO is range-readable.
- README wording and the demo URL: X01.
- Bumping v86 later: M04 (tool updates) uses `vendor-v86 --update`.
- A standalone `boot.html`: dropped. The SPA route `#/boot` is the only demo (one copy to maintain; the old copy was never deployed, supplychain `web.boot.html`).

## Design

### Vendored files and lock
```text
web/vendor/v86/
  libv86.js        from npm package v86@<exact>, build/libv86.js
  v86.wasm         from npm package v86@<exact>, build/v86.wasm
  seabios.bin      from git copy/v86 at commit <40 hex>, bios/seabios.bin
  vgabios.bin      from git copy/v86 at commit <40 hex>, bios/vgabios.bin
  VENDOR.lock
  LICENSES/        upstream licence text for v86, SeaBIOS, VGABIOS
```
Whether the npm package ships the BIOS images is not known from the study; the lock records the source of each file separately, so a git commit is used for the BIOS regardless. The old code mixed an unversioned npm `latest` with the `master` branch; there is no promise the two ever matched.

`VENDOR.lock` (YAML, written only by `vendor-v86`):
```yaml
schema: 1
v86:
  npm:  {package: v86, version: "<exact semver, no range>"}
  git:  {repo: "https://github.com/copy/v86", commit: "<40 hex>"}
files:
  libv86.js:   {sha256: "<64 hex>", bytes: 0, source: "npm v86@<version> build/libv86.js"}
  v86.wasm:    {sha256: "<64 hex>", bytes: 0, source: "npm v86@<version> build/v86.wasm"}
  seabios.bin: {sha256: "<64 hex>", bytes: 0, source: "git <commit> bios/seabios.bin"}
  vgabios.bin: {sha256: "<64 hex>", bytes: 0, source: "git <commit> bios/vgabios.bin"}
licenses:
  v86: "<SPDX id, verified against the upstream licence file>"
  seabios: "<SPDX id>"
  vgabios: "<SPDX id>"
```
The implementer fills the values by running `vendor-v86 --update` once with network (this spec cannot: no network, and the correct version is the newest one that boots the ISO, which is found by the headless check). Sizes are recorded in the lock; the study has no figure for them. Licences are expected to be BSD-2-Clause for v86 and LGPL for the BIOS images; the implementer verifies against the upstream files, not this sentence. The same npm version is the `v86` entry in `pins/pins.yaml` (SPEC §6); a test requires they are equal.

`factory/bin/vendor-v86`:
- `--verify` (offline, default in tests): recomputes every sha256 and byte count, checks `VENDOR.lock` completeness and the pins equality. Exit 0 or 1.
- `--update NPM_VERSION GIT_COMMIT` (network, run by a human or by M04): downloads the files, refuses non-exact versions (`latest`, `^1`, a branch name, a short hash), writes the files and the lock deterministically, and verifies the result. Rejected: git submodule or `npm install` in CI (a network fetch on every build, and `node_modules` is not auditable); committing without a lock (silent drift).

Files are committed to git as binary blobs. The wasm and BIOS files are small (low megabytes, size unrecorded, measure at first vendoring); no Git LFS. Rejected: fetching at publish time from jsDelivr with a hash check; it keeps the supply-chain dependency and breaks offline builds.

### The boot view (`web/app/view-boot.js`)
Lifecycle `mount(container, ctx)` / `unmount()` registered with P03's router:
- `mount`: loads `vendor/v86/libv86.js` once (a `<script>` element appended on first mount; later mounts reuse `window.V86`), reads `latest-release.json`, shows the version, the digest and the size from `iso.bytes`, and a Start button. No hard-coded megabyte figure anywhere in `web/`. (The old UI said 135 MB, the README 131 MB; the maintainer's current figure is about 212 MB.)
- Start creates the emulator with options unchanged from the old view unless noted:
  `wasm_path: "vendor/v86/v86.wasm"`, `bios: {url: "vendor/v86/seabios.bin"}`, `vga_bios: {url: "vendor/v86/vgabios.bin"}`, `cdrom: {url: <iso url>, async: true}`, `memory_size: 256 MiB`, `vga_memory_size: 8 MiB`, `boot_order: 0x132` (CD first), `autostart: true`. Memory stays at 256 MiB until measured otherwise; shrinking it toward the product's real floor is a later experiment, not a regression risk taken here. The `window.V86 || window.V86Starter` fallback goes: the pinned build defines one of them and the test names it.
- `unmount` (route change): `emulator.destroy()`, clear the serial `setInterval`, remove the `pointerlockchange` and `mozpointerlockchange` listeners, release the fullscreen state. The old view leaked a timer and re-added listeners on every visit (`view-boot.js:134-136`).
- Errors are classified before they are shown. On `download-error`, the view issues `HEAD` for the ISO URL and reports one of: network failure or blocked cross-origin request (the `fetch` rejects), `HTTP 404` (not published), server without byte ranges (no `Accept-Ranges: bytes`), other HTTP status. The CORS hint is shown only for the first. The old view said "CORS error" for every failure including 404.
- Serial log: keeps the last 4,000 characters, as before.

Same-origin by design (P01 H6): the ISO path is relative, so no CORS preflight happens for the demo. CORS support on the host still matters for people embedding the ISO elsewhere and for local development.

### Headless boot check (`oracle/demo/v86-headless.mjs`)
Runs the vendored `libv86.js` under Node (pinned in `pins/pins.yaml`, P03 defect 3), with the vendored wasm and BIOS, against a local ISO file. It types the ISOLINUX label `serial` after the boot prompt (SPEC §7: the `serial` label is an interface of the disc) and reads `serial0-output-byte` until the login marker used by the O01 harness appears or the timeout (default 20 minutes) expires. Exit 0 on marker, 1 on timeout, 2 on emulator error. This proves that the pinned v86 can boot this ISO, not that a browser tab can; browser behaviour is checked by hand (Risks). `demo-check.yml` runs it after a successful `Release` run and on dispatch. It does not gate publishing: the demo is not the product, and a red run is the signal. Rejected: gating releases on it (v86 speed in CI is unmeasured and would make releases flaky).

### Public range probe (`tests/smoke/demo-range.sh BASE_URL`)
For the path in `latest-release.json`: `HEAD` returns `Content-Length` equal to `iso.bytes` and `Accept-Ranges: bytes`; three ranges (`0-2047`, a middle range, the last 2,048 bytes) return `206` with the right `Content-Range`, and their bytes equal the same ranges of the ISO downloaded from the GitHub release. Needs only `curl`, `cmp`, `gh`.

## Traps and doctrines preserved
- **Unpinned CDN (`jsdelivr npm/v86` latest, `gh/copy/v86@master`), wasm/libv86 mismatch:** AC-1, AC-2, AC-3.
- **v86 loaded on every page load (`index.html:16`):** AC-4.
- **No SRI, no CSP:** same-origin vendoring plus P03's CSP; AC-9 checks the CSP allows what v86 needs and nothing external.
- **Interval and listener leak:** AC-5.
- **Blanket "CORS error":** AC-6.
- **Stale size claims (135 vs 131 vs about 212 MB):** AC-7.
- **Duplicate demo page (`boot.html`):** AC-12.
- **SPEC §2 principle 2** (every input pinned and mirrored under our control): the lock plus the committed files are the mirror; AC-1, AC-2, AC-10.
- **D-486-minimalism** concerns the target, not the browser; the demo may use 256 MiB until measured, and AC-8 pins the value so a change is deliberate.

## Gate
- **P04-AC-1** — Every file in `web/vendor/v86/` listed in `VENDOR.lock` exists, and its sha256 and byte count match the lock; no unlisted file other than `VENDOR.lock` and `LICENSES/*` is present. *Verify:* `factory/bin/vendor-v86 --verify`, run by `tests/fast/vendor-v86.test.sh`. *Tier:* fast.
- **P04-AC-2** — `VENDOR.lock` has `schema: 1`, an exact npm version matching `^[0-9]+\.[0-9]+\.[0-9]+$`, a 40-hex git commit, `sha256`/`bytes`/`source` for each of the four files, a non-empty licence id for each component, and the `v86` entry of `pins/pins.yaml` equals the lock's npm version. *Verify:* `tests/fast/vendor-v86.test.sh`. *Tier:* fast.
- **P04-AC-3** — Nothing under `web/` (except `web/vendor/v86/LICENSES/`), `docs/boot-demo.md` or `README.md` references `jsdelivr`, `unpkg`, `cdnjs`, `@master`, `/latest/`, or an `http(s)://` URL for v86 resources. *Verify:* `tests/fast/vendor-v86.test.sh` (grep with a RED fixture of the old `view-boot.js`). *Tier:* fast.
- **P04-AC-4** — `index.html` contains no v86 script tag; mounting the boot view twice inserts exactly one `libv86.js` script element and navigating to any other route inserts none. *Verify:* `tests/fast/web/view-boot.test.mjs` (DOM stub counts script insertions). *Tier:* fast.
- **P04-AC-5** — After three mount/unmount cycles, there is no live `setInterval`, no leftover `pointerlockchange`/`mozpointerlockchange` listener, and `destroy()` was called once per started emulator. *Verify:* `tests/fast/web/view-boot.test.mjs` (fake timers and listener registry). *Tier:* fast.
- **P04-AC-6** — The error classifier maps a rejected `fetch`, `404`, a `200` without `Accept-Ranges`, and a `500` to four different messages, and only the rejected-fetch case mentions CORS. *Verify:* `tests/fast/web/view-boot.test.mjs`. *Tier:* fast.
- **P04-AC-7** — The view takes the ISO URL, version, digest and size from `latest-release.json`; for a fixture with `iso.bytes = 222000000` it displays the size derived from that number; `web/` contains no literal `MB`/`MiB` ISO size. *Verify:* `tests/fast/web/view-boot.test.mjs` plus a grep in the same file's companion shell test. *Tier:* fast.
- **P04-AC-8** — The options passed to the `V86` constructor equal exactly: `wasm_path` and both BIOS paths under `vendor/v86/`, `cdrom.async: true`, `memory_size` 268435456, `vga_memory_size` 8388608, `boot_order` 0x132, `autostart: true`, and no other source URL. *Verify:* `tests/fast/web/view-boot.test.mjs` (stub constructor captures options). *Tier:* fast.
- **P04-AC-9** — The CSP in `web/index.html` contains `'wasm-unsafe-eval'` and `connect-src 'self'` and no external origin, and `worker-src`/`child-src` are not needed by the pinned v86 (the test loads `libv86.js` and fails on `new Worker`/`importScripts` of another origin). *Verify:* `tests/fast/web/view-boot-csp.test.sh`. *Tier:* fast.
- **P04-AC-10** — `vendor-v86 --update` refuses `latest`, `^1.2.3`, `1.x`, a branch name and a short commit hash with exit 2 and writes nothing; `--verify` fails when one byte of a vendored file changes. *Verify:* `tests/fast/vendor-v86.test.sh`. *Tier:* fast.
- **P04-AC-11** — The vendored v86 boots the release candidate ISO to the login marker in Node headless mode within the timeout. *Verify:* `demo-check.yml` run after the `v0.2.0-rc1` Release run (or dispatch with the ISO), `oracle/demo/v86-headless.mjs` exit 0 and the serial log attached. *Tier:* slow.
- **P04-AC-12** — `boot.html` does not exist in the repository, and `README.md` links the demo as `${PUBLIC_BASE_URL}/#/boot`. *Verify:* `tests/fast/web/no-standalone-boot.test.sh`. *Tier:* fast.
- **P04-AC-13** — On the live host, `tests/smoke/demo-range.sh` passes for the `v0.2.0-rc1` ISO: correct `Content-Length`, `Accept-Ranges`, three `206` ranges byte-equal to the release asset. *Verify:* `tests/smoke/demo-range.sh "$PUBLIC_BASE_URL"` in the P03-AC-17 follow-up run. *Tier:* slow.

## RED plan
Tester writes AC-1, 2, 3, 10 first as `tests/fast/vendor-v86.test.sh` against a fixture lock and fake vendor directory; they fail because `vendor-v86` and `web/vendor/v86/` do not exist, and the AC-3 grep is proven by a fixture copy of the old `view-boot.js` that must be rejected. AC-4 to AC-8 are `node --test` cases over a stub DOM and a stub `V86`; they fail because `view-boot.js` is P03's placeholder. AC-12 fails while `boot.html` exists in a fixture copy of the old tree. AC-11 and AC-13 have no RED.

## Risks and open questions
- **Does the default ISOLINUX/serial path work in v86?** The headless check types `serial` at the boot prompt. If the `serial` label does not print the O01 login marker under v86 timing, the check needs screen-text scraping instead. Unknown until tried.
- **v86 speed.** The old README claims 1–3 minutes to a login prompt (network-bound). In Node on a CI runner the figure is unmeasured; the 20-minute timeout is a guess.
- **Browser behaviour is not automated.** The fast tier uses a DOM stub. Before merge, a human opens `#/boot` on the live site in a real browser, starts the demo, reaches the prompt and navigates away and back, and records that in the PR. No AC can prove it.
- **Pointer lock, fullscreen and keyboard capture** (ported from the old view) have no test.
- **Licences of the BIOS images** need a human read of upstream files; the lock stores what the implementer verified.
- **Repo size.** Committing the wasm and BIOS adds their size to every clone; unknown figure. If it exceeds a few MB, revisit LFS, which would add a store-like dependency.
- OD-1 affects only AC-13.

## Cost
- Slices: 3 (vendoring and lock tooling; view with lifecycle and tests; headless check and range probe). 13 ACs.
- CI build cycles: 0 of its own; AC-11 and AC-13 reuse the `v0.2.0-rc1` artifacts. If v86 cannot boot the ISO at the first pinned version, a second `vendor-v86 --update` and a re-run of `demo-check.yml` (minutes, no rebuild).
- Money: none.

## Spec defects found
1. **P04 depends on P03 only, but its slow ACs need a published release (P02).** The edge is transitive (P03 depends on P02) and P04 is `deferred`, so `v0.2.0-rc1` exists when it starts (MS2). Nothing to fix.
2. **SPEC §6 lists v86 as a pin without saying what it pins.** This node defines it as the npm version in `VENDOR.lock`; I05's "unused pin" check must read `web/vendor/v86/VENDOR.lock` as the consumer of that pin.
