# O05 — boot-modes-gui

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| O | O02 | S05, P02 | MS3 | M |

**Owns:** `oracle/modes/{gui,stele_acid2}.py`, `oracle/lib/golden.py` (PNG codec, comparison, diff image), `oracle/bin/golden-record`, `oracle/golden/gui.png`, `oracle/golden/gui.yaml`, `oracle/golden/stele-acid2.png`, `oracle/golden/stele-acid2.yaml`, `oracle/fixtures/argv/{gui,stele-acid2}.txt`, matrix legs for these modes in `oracle/modes.yaml`.
**Carries from linux-live-iso-factory@b9f533b:** `scripts/boot-test.py` lines 372-417 (gui argv), 1444-1599 (QMP, PPM; moved to O01), 1742-1893 (runners), `.github/workflows/boot-test.yml` jobs `gui` (:424-479) and `stele-acid2` (:481-536).
**Study refs:** oracle.yaml `bootmode.gui|stele-acid2`, gaps ("Stele Acid2: gate is exit 0 + non-black", "GUI: dwm bar + terminal asserted only as >0.5% non-black"), contradictions (HMP vs QMP wording at boot-test.py:2401 and boot-test.yml:422); T-gui-boot-labels, T-startx-lean-fonts, T-terminus-xlfd, T-tinyx-xfbdev, D-bitmap-fonts-no-freetype, D-486-minimalism, D-state-and-no-hidden-stderr.

## Purpose
After this node a GUI regression that still paints some pixels fails the oracle. The predecessor's `gui` and `stele-acid2` modes passed whenever more than 0.5% of the screendump was non-black, so a wrong font, a broken window manager bar or a mis-laid-out Acid2 page passed. Each mode now compares the framebuffer to a reviewed golden image within a stated tolerance, keeps the liveness assertions, and proves the comparison can fail.

## Scope
In:
- `gui` and `stele-acid2` runners with all predecessor assertions.
- Golden screendump storage, comparison with tolerance and ignore regions, the record-and-review procedure, and diff output.
- Replacing fixed sleeps with polling.
Out:
- QMP client, PPM reader, harness core: O01. Workflow and legs plumbing: O02.
- `startx`, dwm, st, Xfbdev, Stele themselves and their fonts (R01/R05); the bitmap-font doctrine check on built files (O06).
- Comparing to the W3C Acid2 reference image: not attempted (see Design).
- A browser-visual demo (P04) and dashboard screenshots (P03).

## Design

### QEMU and boot
`qemu-system-i386 -cdrom ISO -m <ram> -cpu 486 -boot d -vga std -nographic -serial mon:stdio -qmp unix:<screendump>.qmp.sock,server,nowait -no-reboot` (`boot-test.py:404-415`); a stale socket is removed first (`:402-403`). BIOS only: the kernel has `FB_VESA`, not efifb. Label `serial vga=788` (800x600x16, vesafb; `vga=788` is `0x314`). The plain `serial` label gives text mode and Xfbdev dies "no screens found" (T-gui-boot-labels). RAM: `gui` 128 MB, `stele-acid2` 256 MB. QMP is used, not HMP, so the serial mux is not disturbed; the stale "HMP" wording in the predecessor's comments (`boot-test.py:2401`, `boot-test.yml:422`) is not carried.

### gui assertions
1. Boot to shell with warmup (O01 `boot_to_shell`).
2. Debug (non-gating): `/dev/fb0` present, `virtual_size`, `bits_per_pixel`.
3. `startx >/tmp/startx.log 2>&1 &`.
4. New: poll every 2 s for up to 60 s until `pgrep -x Xfbdev`, `pgrep -x dwm` and `pgrep -x st` all succeed; the predecessor used fixed `sleep 1` and `sleep 8` (`:1784-1790`), which is timing dependent on a TCG 486. After the processes are up, wait until two consecutive screendumps are stable (below).
5. Carried: all three processes alive and `grep -Eq 'Fatal|could not open default font|giving up' /tmp/Xfbdev.log` finds nothing (`:1796-1808`). T-startx-lean-fonts: this is what exposed a stale `startx` pointing at font files that do not exist on the disc.
6. Non-gating dump of `/tmp/Xfbdev.log` and `/tmp/startx.log` to the transcript.
7. Screendump (QMP, 25 s) and the carried non-black check (any channel > 16 on more than 0.5% of pixels). This is now a precondition, not the verdict.
8. New: golden comparison against `oracle/golden/gui.png`.

### stele-acid2 assertions
1. Boot as above, shell, warmup.
2. `stele --headless --render-fb /usr/share/stele/acid2.html; echo RENDER_RC=$?` within 180 s; output contains `RENDER_RC=0` (`:1871-1875`).
3. Screendump, non-black precondition, then golden comparison against `oracle/golden/stele-acid2.png`.
Decision: the golden is Stele's own reviewed render, not the W3C Acid2 reference. Stele paints with its own 8x8 bitmap font and its own layout; it cannot match the reference pixel for pixel, and a loose comparison to the reference would let wrong renders pass again. A reviewer compares the first golden to the reference by eye once; afterwards the golden is the regression oracle. Rejected: reference comparison (never matches), perceptual hash (no tolerance semantics a reviewer can read).

### Golden comparison
`oracle/golden/<mode>.yaml`:
```yaml
version: 1
width: 800
height: 600
source: {iso_version: "...", stele_version: "...", recorded: "2026-..-..", reviewed_by: "..."}
tolerance:
  channel_delta: 24          # per-channel absolute difference that counts as a changed pixel
  max_diff_fraction: 0.005   # fraction of unmasked pixels allowed to differ
ignore:                       # rectangles excluded from both numerator and denominator
  - {x: 0, y: 0, w: 800, h: 16, reason: "dwm status text"}
stability: {frames: 2, interval_s: 3, max_tries: 5, max_diff_fraction: 0.0005}
```
Defaults for `gui` are `channel_delta: 24`, `max_diff_fraction: 0.005`; for `stele-acid2`, `0.002`. The numbers are starting points chosen against 16-bit colour quantization (a 565 pixel round-trips within 8 per channel) and must be confirmed against the first recorded runs; changing a tolerance is a golden change and gets a reviewer. `golden.py` reads PNG (zlib plus filter types 0-4) and writes PNG with the standard library only. The PNG golden is a few KB; rejected: committing 1.4 MB PPMs.

Comparison: dimensions must equal exactly; a pixel counts as different when the maximum absolute channel difference exceeds `channel_delta`; masked pixels are ignored; the check passes when the different fraction is at most `max_diff_fraction`. Stability: the screendump is taken until two consecutive frames differ by at most `stability.max_diff_fraction`; if none are stable within `max_tries`, the check fails with both frames saved. This replaces the idea of retrying until a frame matches, which would mask flake. On failure the harness writes `<screendump>.diff.png` (differing pixels red over the dimmed golden) and the actual frame as PNG; CI uploads both.

### Record and review (bootstrap)
A missing golden is a failure (SPEC principle 5), never an auto-accept. Procedure: run the leg with `--golden-record`, which saves the stable frame and exits 1 with "no golden". A human downloads the artifact, looks at it (gui: dwm bar, one st terminal with prompt in Terminus; acid2: the smiley layout), runs `oracle/bin/golden-record <frame.png> --mode gui --reviewed-by "<name>"` which writes the PNG and a YAML skeleton, fills `ignore` regions with reasons, and commits. Every later golden change is a PR with before/after images attached. The first goldens cannot be written before a first successful ISO exists; the rc1 PPM artifacts expired with the 14-day retention.

### Self-test
`golden.py` ships with synthetic cases so the comparison's ability to fail is proven in the fast tier: identical image passes; every pixel off by 8 in one channel passes; a 40x40 block of the terminal area shifted by 10 px fails; uniform mid-gray fails; a one-pixel size mismatch fails; an ignored region's changes do not count.

## Traps and doctrines preserved
- **T-gui-boot-labels:** plain `serial` gives text mode. Prevented by O05-AC-1 (golden argv and the label in the transcript test) and by the golden's 800x600 dimension.
- **T-startx-lean-fonts:** stale `startx` pointed at font files not on the disc. Prevented by O05-AC-2 (log scan) and O05-AC-3 (a wrong font changes the terminal text pixels).
- **T-terminus-xlfd / D-bitmap-fonts-no-freetype:** dwm and st name the full Terminus XLFD; a broken index makes them exit. Prevented by O05-AC-2 (processes alive). The on-disc absence of freetype/Xft files is O06's.
- **T-tinyx-xfbdev:** TinyX Xfbdev static, kdrive built-in drivers only; its liveness is O05-AC-2.
- **D-486-minimalism:** the gui mode holds a 128 MB RAM floor for X + dwm + st. Prevented from silently rising by the RAM value in `modes.yaml` and the golden argv test.
- **D-state-and-no-hidden-stderr:** `startx >/tmp/startx.log 2>&1` is deliberate and its log is dumped on failure; no failure may be swallowed. Prevented by O05-AC-5 (diff image and both logs uploaded on failure).

## Gate
- **O05-AC-1** — `gui` boots with `serial vga=788`, `-vga std` and a QMP socket at 128 MB; `stele-acid2` at 256 MB; both golden argv files match the builders. *Verify:* `tests/fast/test_oracle_argv.py::test_gui`, `::test_stele_acid2`. *Tier:* fast.
- **O05-AC-2** — `gui`: after `startx`, `Xfbdev`, `dwm` and `st` are all alive (polled up to 60 s, no fixed sleep) and `/tmp/Xfbdev.log` contains none of `Fatal`, `could not open default font`, `giving up`. *Verify:* CI leg `oracle / boot (gui)`; `tests/fast/test_oracle_gui.py` replay transcripts: st absent, Fatal in log, and a slow start (processes appear after 40 s) which must pass. *Tier:* slow and fast.
- **O05-AC-3** — `gui` compares the stable framebuffer to `oracle/golden/gui.png` within the tolerance in `gui.yaml` and passes only on a match. *Verify:* CI leg `oracle / boot (gui)`. *Tier:* slow.
- **O05-AC-4** — `stele-acid2` prints `RENDER_RC=0` from `stele --headless --render-fb /usr/share/stele/acid2.html` within 180 s and the stable framebuffer matches `oracle/golden/stele-acid2.png` within `stele-acid2.yaml`. *Verify:* CI leg `oracle / boot (stele-acid2)`. *Tier:* slow.
- **O05-AC-5** — On any golden failure the harness writes the actual frame and a diff PNG next to the screendump and CI uploads PPM, PNG, diff, serial log and result JSON with `if: always()`. *Verify:* `tests/fast/test_oracle_golden.py::test_failure_writes_diff`; workflow lint `tests/fast/test_oracle_workflow.py::test_gui_artifacts`. *Tier:* fast.
- **O05-AC-6** — The comparison can fail: identical passes; all pixels +8 in one channel pass; a shifted 40x40 block fails; a uniform gray frame fails; a size mismatch fails; ignore regions are excluded from numerator and denominator. *Verify:* `tests/fast/test_oracle_golden.py`. *Tier:* fast.
- **O05-AC-7** — Golden files are well-formed and meaningful: each `<mode>.yaml` validates against `oracle/schemas/golden.schema.json`, its PNG has the stated size, contains at least 8 distinct colors (gui) / 4 (acid2), exceeds the 0.5% non-black precondition, and every `ignore` rectangle has a non-empty `reason`. *Verify:* `tests/fast/test_oracle_golden.py::test_committed_goldens`. *Tier:* fast.
- **O05-AC-8** — A missing golden or YAML fails the mode (exit 1, message names the file and the record procedure) and `--golden-record` never passes a run; `oracle/bin/golden-record` writes a PNG and YAML skeleton and refuses to overwrite without `--force`. *Verify:* `tests/fast/test_oracle_golden.py::test_missing_golden_fails`, `::test_record_cli`. *Tier:* fast.
- **O05-AC-9** — Frame stability is required before comparison: two consecutive dumps within `stability.max_diff_fraction`; if none stabilize in `max_tries`, the mode fails and saves both frames. *Verify:* `tests/fast/test_oracle_golden.py::test_stability_loop` with a fake QMP that returns a changing frame. *Tier:* fast.
- **O05-AC-10** — The PNG codec reads and writes using only the standard library (`zlib`, `struct`) and round-trips all five PNG filter types. *Verify:* `tests/fast/test_oracle_golden.py::test_png_roundtrip` and the stdlib-only lint (O01-AC-14). *Tier:* fast.

## RED plan
Tester commits: `test_oracle_golden.py` (all cases in AC-5..10 with synthetic frames; module absent), `test_oracle_gui.py` (replay of three transcripts), golden argv files. No real golden exists at RED time, so AC-7 is written to read `oracle/golden/` and fails because the directory is empty; AC-3/AC-4 have only slow GREEN.

## Risks and open questions
- Hardest: dwm and st content that varies between runs (dwm status text, st cursor, prompt contents). The `ignore` list is determined on the first recorded frames; if the status bar shows a clock the ignore region has to cover it. Unknown until the first run.
- Tolerance numbers are placeholders from reasoning, not measurements.
- The Acid2 golden freezes Stele's current behaviour, including its bugs. A reviewer must compare it once to the reference by eye and record the verdict in `source.reviewed_by`.
- Golden churn: every dwm, st, Stele, font or kernel-console change that touches pixels needs a golden PR. Acceptable and intended, but it adds friction to M01 pin bumps (a BUILD_EPOCH bump that changes st or Xfbdev could break the leg and need a human golden update). If it recurs, split `ignore` regions or widen the tolerance with a reviewed reason rather than skipping the check.
- QMP `screendump` format (PPM P6) and its colour conversion from 16 bpp may differ across QEMU versions; the runner's QEMU version is in the result JSON (O02), and a version change that shifts colors shows up as a golden failure.
- `vga=788` under `-vga std` is BIOS-only; UEFI GUI is not covered (kernel has no efifb), by design.

## Cost
Three agent slices: (1) golden library, PNG codec, self-tests; (2) runners, polling, argv; (3) record procedure, first-run goldens. Two to three CI cycles: the first records frames (fails by design), the second runs with committed goldens. No paid services.

## Spec defects found
- graph.yaml lists no dependency from O05 to anything that produces the Terminus/dwm/st configuration it asserts; the golden depends on R01's recipes being stable at record time. No change required, but a recipe change that moves pixels invalidates the golden (noted in Risks).
- SPEC §7 describes the slow tier as "the 17 boot modes inherited from the predecessor" with no place for stored binary reference data; `oracle/golden/*.png` is new repository content (about 10-30 KB each) and should be mentioned in SPEC §4.2.
