# G02 — boot-entry-coverage

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| G | O02 | X01 | — | L |

**Owns:** `oracle/boot-entries.yaml` (expectations only; the entries themselves are B05's `factory/data/boot/boot-contract.yaml`), `oracle/modes/entries_isolinux.py`, `oracle/modes/entries_grub.py`, `oracle/lib/entries.py` (select, verify, per-entry checks), `oracle/lib/grubcfg.py` (extract and parse `grub.cfg` from `BOOTX64.EFI`), `oracle/lib/isocfg.py` (read `isolinux.cfg`, `f1.txt` from the ISO), `oracle/lib/rootdisk.py` (build the `root=` disk), `oracle/fixtures/argv/entries-*.txt`, `oracle/fixtures/serial/entries-*.txt`, `oracle/fixtures/grub/` (synthetic EFI with embedded tar), entries `entries-isolinux`, `entries-grub` in `oracle/modes.yaml`, `tests/fast/test_boot_entries.py`, `tests/fast/test_grubcfg.py`, `tests/fast/boot-claims.test.sh`.
**Carries from linux-live-iso-factory@b9f533b:** the entry definitions at `scripts/build-iso.sh:120-250` (f1.txt, `isolinux.cfg`) and `:260-344` (GRUB menu), `rootfs/init:174-200` (rescue shell), `:245-292` (cmdline parsing, `root=` branch); `README.md:119-165` (boot matrix, label table, `root=` examples); `scripts/boot-test.py:732-782` (label and GRUB navigation; O01 owns the port).
**Study refs:** oracle.yaml gaps (ISOLINUX labels `linux fb fb800 fb640 vga debug persist rescue` never selected; GRUB entries plain, framebuffer, debug, rescue, toram, persistent never selected; GRUB toram untested; rescue untested; `root=` untested; UEFI 32-bit documented not built; BIOS-from-hybrid-disk never booted); doctrine.yaml T-isolinux-timeout, T-grub-initrd-same-line (proposed fast check), T-gui-boot-labels, T-toram-ram, T-hyperv-old-grub, T-pivot-root-overlay, D-state-and-no-hidden-stderr; contradictions in README (`/dev/hda1`).

## Purpose
After this node every boot choice a user can make from the ISOLINUX prompt or the GRUB menu is selected by a test, boots to a shell, and shows the parameters and hardware state that choice promises. The predecessor tested exactly four selections (`serial`, `serial toram`, `serial vga=788`, `serial persist`) and the GRUB `(serial)` entry; the default that real users get (`fb800`, no keypress) and six of seven GRUB entries had never booted, and one of them (GRUB initrd on the `linux` line) was broken for weeks.

## Scope
In:
- An expectations file keyed by B05's boot contract, and a check that the shipped configs equal the contract's render.
- Boot tests for each label and entry, including the default path with no keypress, toram through ISOLINUX and GRUB, rescue, `root=`, and BIOS boot of the ISO as a hybrid disk.
- README and F1-help claim checks, including removal of claims that cannot be true.
Out:
- The contract, the renderer and the ISO build: B05 (its fast tests cover the render; this node covers the shipped bytes and the behaviour).
- The harness primitives and the five-milestone boot sequence: O01. Core modes (bios, uefi, toram, storage variants): O02.
- Hyper-V: G03 (which reuses the GRUB helpers). Persistence behaviour: G01.
- Video-mode correctness beyond the framebuffer size and driver: O03/O05.

## Design

### Source of truth: B05's boot contract, plus an expectations file
B05 owns `factory/data/boot/boot-contract.yaml` (nine ISOLINUX labels, seven GRUB entries, default, timeout, parameters) and renders both configs from it. This node does not restate the parameters. `oracle/boot-entries.yaml` holds only what a test expects *per contract id* (checks to run, observation mode) and the test variants that are not contract entries. Rejected: a second authored table of labels and parameters, which would drift from the contract B05 enforces.

```yaml
# keys of `entries` are contract ids: label names, and grub-<index>
entries:
  linux:    {observe: shell, checks: [cmdline, overlay]}
  fb:       {observe: shell, checks: [cmdline, overlay, fb: {size: "1024,768", bpp: 16}]}
  fb800:    {observe: shell, checks: [cmdline, overlay, fb: {size: "800,600", bpp: 16}]}
  fb640:    {observe: shell, checks: [cmdline, overlay, fb: {size: "640,480", bpp: 16}]}
  vga:      {observe: shell, send_at_prompt: " ", checks: [cmdline, overlay]}
  serial:   {observe: milestones, checks: [cmdline, overlay, no_debug_lines]}
  debug:    {observe: shell, append: "console=ttyS0,115200n8", checks: [cmdline_plus_append, debug_lines]}
  persist:  {observe: shell, checks: [cmdline, tmpfs_fallback_message]}
  rescue:   {observe: console, append: "console=ttyS0,115200n8", checks: [cmdline_plus_append, rescue_pid1]}
  grub-0:   {observe: shell, checks: [cmdline, overlay, fb_name_recorded]}
  grub-1:   {observe: shell, checks: [cmdline, overlay, fb_name: "EFI VGA"]}
  grub-2:   {observe: milestones, checks: [cmdline, overlay]}      # O02 `uefi` also covers it
  grub-3:   {observe: shell, edit_append: "console=ttyS0,115200n8", checks: [cmdline_plus_append, debug_lines]}
  grub-4:   {observe: console, edit_append: "console=ttyS0,115200n8", checks: [cmdline_plus_append, rescue_pid1]}
  grub-5:   {observe: shell, ram_mb: 512, checks: [cmdline, toram_state, eject]}
  grub-6:   {observe: shell, checks: [cmdline, tmpfs_fallback_message]}
variants:                       # not contract entries; each names the label text typed at `boot:`
  default:      {loader: isolinux, input: none, expect_id: fb800, note: "no keypress, 30 s timeout"}
  grub-default: {loader: grub, input: none, expect_id: grub-0, note: "5 s timeout"}
  toram:        {loader: isolinux, input: "linux toram", ram_mb: 512, checks: [cmdline, toram_state, eject]}
  root:         {loader: isolinux, input: "serial root=/dev/sda1 rootflags=rw", disk: root.img, checks: [real_root]}
  root-readme:  {loader: isolinux, input: "serial root=/dev/sda1", disk: root.img, checks: [real_root]}
  hybrid-usb:   {loader: isolinux, input: "serial", media: usb-disk, checks: [storage_smoke]}
  hybrid-ide:   {loader: isolinux, input: "serial", media: ide-disk, checks: [storage_smoke]}
```
`test_boot_entries.py::test_covers_contract` fails when a contract label or entry has no row (new label added, no test) or a row has no contract id. `oracle/interfaces.yaml` (O01) carries the GRUB order; `::test_interfaces_agree` fails if it differs from the contract's.

### Observing a guest without `console=ttyS0`
Only `serial` and the `(serial)` entry send the kernel console to `ttyS0`; init milestones therefore appear on serial for no other entry. `inittab` always runs `agetty ... ttyS0` (`scripts/build-rootfs.sh:359-360`, "Serial console - bypass login"), so once the system is up every entry gives a shell on the QEMU serial line. These modes therefore do not wait for milestones: they `wait_for_shell` (O01) on serial, then verify the entry from the inside:
- `/proc/cmdline` ends with the entry's `cmdline` (anchored regex; `BOOT_IMAGE=/boot/vmlinuz` precedes it).
- The entry-specific `expect` checks below.
Entries where the thing under test is the boot path before `/sbin/init` (rescue, `debug`'s init output) get `console=ttyS0,115200n8` appended: ISOLINUX takes extra text after the label (the documented mechanism, `f1.txt` "Advanced"), GRUB uses `e`, End (Ctrl-E), the text, Ctrl-X. The appended text is logged and recorded in the result JSON, and the cmdline check allows exactly that suffix. Rejected: appending `console=ttyS0` everywhere, which would test a different cmdline from what users run.

### Selecting
- ISOLINUX: `select_isolinux_label` (O01) types the label text at `boot:`. The default path sends nothing and the mode records the time from prompt to first shell. ISOLINUX has `TIMEOUT 300` (30 s, T-isolinux-timeout); the mode's boot budget is `prompt 90 s + 30 s + boot timeout`.
- GRUB: `select_grub_entry(index, title)` (this node, `oracle/lib/entries.py`) waits for the serial-mirrored menu, sends `index` Down presses, and checks the matching title (from the parsed `grub.cfg`) was printed on the menu before pressing Enter. It supersedes `select_grub_serial_entry` for new callers and O01's helper delegates to it with `index=2`. The default (`grub-plain`) sends nothing and waits out `timeout=5`.
- `vga` waits for the kernel's mode prompt on serial (SeaBIOS's serial console mirrors BIOS text; O01 notes the same dependency for the `boot:` prompt). If the prompt text is not seen within 20 s the mode sends SPACE blindly and logs the warning, as the predecessor did for `boot:`.

### Per-entry checks (`expect`)
- Every entry: shell reached; `uname -r` equals the expected kernel; `/proc/cmdline` as above; overlay root mounted (`mount | grep ' / ' | grep overlay`) unless `root=`.
- `fb`, `fb800`, `fb640`: `/sys/class/graphics/fb0/virtual_size` equals `1024,768`, `800,600`, `640,480` and `bits_per_pixel` is `16`. A framebuffer that exists at the wrong size fails.
- `vga`: after SPACE the system boots to a shell; cmdline contains `vga=ask`.
- `debug` (both loaders): with the console appended, serial shows `[init] DEBUG:` lines before the shell (`rootfs/init:41-43`); without `debug` no such lines appear in the `isolinux-serial` run (negative control).
- `rescue` (both): serial shows the banner `tHE m0n0LiTH ... - rescue shell`; `echo $$` prints `1`; no overlay is mounted (`grep -c overlay /proc/mounts` is `0`); `cat /proc/cmdline` contains `rescue`. The mode then ends with `poweroff -f` (busybox). The shell is `exec /bin/sh` as PID 1, so `exit` panics the kernel; the banner currently says "Type 'exit' to continue booting". That text is false and is changed to name `poweroff -f` and `reboot -f` (G02-AC-8).
- `toram` (both loaders): 512 MB RAM (T-toram-ram); serial shell; `/ram/rootfs.squashfs` exists; `/media` is not a mountpoint; ejecting the CD through the QEMU monitor (O02's `eject` helper) leaves `uname -r` working.
- `grub-framebuffer`: `/sys/class/graphics/fb0/name` is `EFI VGA` (the `video=efifb` driver).
- `grub-plain`: boots with no parameters; records `fb0/name` in the result JSON; asserts it is not `EFI VGA` once the first real run has fixed the expected value (see Risks).
- `isolinux-persist`, `grub-persistent`: cmdline check and shell only; with no disk attached the guest falls back to tmpfs and says so. Persistence behaviour is G01.

### `root=`
`rootdisk.py` builds `root.img` on the host from the ISO's `rootfs.squashfs`: `unsquashfs` into a directory and `mke2fs -t ext4 -d` with `-E offset=1048576` into a sparse image, inside one `fakeroot` session (ownership and device nodes preserved), with a one-partition MBR written by `sfdisk` first. Attached as AHCI (`-device ahci -device ide-hd`), it appears as `/dev/sda`, partition `/dev/sda1`, matching the README example. The label is `serial root=/dev/sda1 rootflags=rw`. Checks: shell; `/proc/cmdline` ends with the typed text; `findmnt`-free check that `/` is `/dev/sda1` of type ext4 and not overlay; `/etc/monolith-release` equals the ISO's version; `mount | grep -c ' /overlay '` is `0` (the live overlay path is skipped). A second leg boots the same disk with the README's exact line `root=/dev/sda1` (default `ro`); if the system cannot boot read-only the README line is wrong and is changed to include `rootflags=rw`. Rejected: building the disk in the guest (a 300+ MB copy under TCG, minutes of emulated I/O) and `sudo mount` on the runner.

### BIOS boot of the ISO as a disk
Leg `hybrid-disk` of `entries-isolinux` attaches the ISO file as a USB mass-storage disk (`-drive if=none,format=raw,file=ISO,readonly=on -device usb-storage`) with no CD-ROM, boots SeaBIOS from it via the isohybrid MBR, selects `serial` at `boot:`, and runs the storage smoke checks (`uname -r`, overlay mounted). This is the README "Hybrid USB/CD" row, never booted as a disk before. A second variant attaches it as an IDE disk (`-drive if=ide,format=raw`) to cover the MBR type used by G03. UEFI-from-USB stays O02's `usb`.

### Checks on the built artifact
B05's tests validate the contract and the *rendered* configs (B05-AC-1 to AC-4). Nothing in B05 checks the config that actually shipped inside `BOOTX64.EFI`. This node does, in CI, against the built ISO:
- `oracle/lib/isocfg.py` reads `isolinux/isolinux.cfg` and `isolinux/f1.txt` from the ISO (xorriso `-osirrox`, or a pure-Python ISO9660 reader) and compares them with the render of the contract for the same `BUILD_VERSION`.
- `oracle/lib/grubcfg.py` finds the standalone `grub.cfg` in `BOOTX64.EFI`: `grub-mkstandalone` embeds a tar containing `boot/grub/grub.cfg` (B05 step 3); the extractor scans for a tar header whose name is `boot/grub/grub.cfg` and whose magic at offset 257 is `ustar`, and reads the member. If the image is compressed or no header is found it exits non-zero with the file size and a hex dump of the first 512 bytes. It also reads the GRUB version string from the image for the result JSON. Rejected: asking B05 for a second copy of `grub.cfg` in the ISO tree (GRUB's prefix is the memdisk, so a loose file would be a decoy).
- `oracle/bin/check-entries ISO` runs both comparisons plus: no `BOOTIA32.EFI` in the ISO and the README saying 32-bit UEFI is not built (a negative claim made testable); when a later node adds it, the check and README change together.
The T-grub-initrd-same-line and ISOLINUX invariants (`TIMEOUT 300`, `DEFAULT fb800`, no `://`) are asserted on the render by B05; here they are asserted on the shipped bytes by the equality check, so a build that bypasses the renderer fails.

## Traps and doctrines preserved
- **T-grub-initrd-same-line:** an `initrd` on the `linux` line froze every entry but `(serial)`. Prevented by B05-AC-3 (render), G02-AC-1 (shipped bytes) and G02-AC-5..7 (each entry booted).
- **T-isolinux-timeout:** a 5 s window raced a pexpect keystroke. Prevented by B05-AC-2 and G02-AC-1 (`TIMEOUT 300` on shipped bytes) and G02-AC-3 (default path waits it out).
- **b8d42c4 (`://` in APPEND hangs ISOLINUX):** Prevented by B05-AC-2 and G02-AC-1.
- **T-gui-boot-labels:** plain `serial` has no `vga=`, so no graphical framebuffer; the framebuffer labels are the ones with `vga=`. Prevented by G02-AC-4 (size and bpp assertions per label).
- **T-toram-ram:** toram needs more RAM than the base boot. Prevented by G02-AC-9 (512 MB, both loaders).
- **T-pivot-root-overlay:** `root=` and overlay take different pivot paths. Prevented by G02-AC-10.
- **T-hyperv-old-grub:** GRUB behaviour is version-sensitive. G02 records the GRUB version string from the EFI image into the result JSON for G03.
- **D-state-and-no-hidden-stderr:** a README that promises `/dev/hda1` and a rescue banner that promises `exit` are statements nobody tested. Prevented by G02-AC-8 and G02-AC-11.
- **SPEC §7 interface rule:** label names, GRUB order and index 2 are harness interfaces. Prevented by G02-AC-2 (expectations versus contract versus `interfaces.yaml`) and G02-AC-1 (built ISO).

## Gate
- **G02-AC-1** — The ISOLINUX and GRUB configs extracted from the built ISO equal the render of B05's boot contract for the same version (so one separate `initrd` line per GRUB entry, `default=0`, `timeout=5`, `DEFAULT fb800`, `TIMEOUT 300`, no `://` in APPEND all hold on the shipped bytes). *Verify:* `tests/fast/test_boot_entries.py::test_shipped_equals_render` on fixture ISO parts, including the predecessor's broken `linux ... initrd` one-line form as a must-fail fixture; `oracle/bin/check-entries ISO` in CI. *Tier:* fast + slow.
- **G02-AC-2** — `oracle/boot-entries.yaml` validates, has a row for each of the nine contract labels and seven GRUB entries and no extra ids, and the contract's GRUB order and serial index equal `oracle/interfaces.yaml`. *Verify:* `tests/fast/test_boot_entries.py::test_table_schema`, `::test_covers_contract`, `::test_interfaces_agree`. *Tier:* fast.
- **G02-AC-3** — With no keypress the ISO boots the `fb800` default after the 30 s timeout to a shell on serial, with cmdline ending `quiet vga=788` and `fb0` at `800,600`, 16 bpp; and the same for GRUB `grub-plain` with an empty parameter list. *Verify:* CI legs `oracle / boot (entries-isolinux:default)` and `(entries-grub:default)`. *Tier:* slow.
- **G02-AC-4** — Labels `fb`, `fb640`, `linux` and `vga` each boot to a shell and meet their `expect`: `fb` 1024x768, `fb640` 640x480, both 16 bpp, `linux` with the exact cmdline, `vga` after the mode prompt is answered. *Verify:* CI legs `entries-isolinux:{linux,fb,fb640,vga}`. *Tier:* slow.
- **G02-AC-5** — `debug` boots under both loaders and prints `[init] DEBUG:` lines on serial (console appended), while the `serial` label run prints none. *Verify:* legs `entries-isolinux:{debug,serial}`, `entries-grub:debug`; transcript replay in `test_boot_entries.py::test_debug_lines`. *Tier:* slow + fast.
- **G02-AC-6** — GRUB entries `framebuffer` and `persistent` each boot to a shell with the table's cmdline; `framebuffer` reports `fb0/name` `EFI VGA`; `persistent` with no disk reports the tmpfs fallback message. *Verify:* legs `entries-grub:{framebuffer,persistent}`. *Tier:* slow.
- **G02-AC-7** — `rescue` boots under both loaders (console appended), shows the rescue banner, runs as PID 1 with no overlay mounted, and `poweroff -f` ends QEMU. *Verify:* legs `entries-isolinux:rescue`, `entries-grub:rescue`. *Tier:* slow.
- **G02-AC-8** — The rescue banner no longer promises that `exit` continues booting, README and `f1.txt` describe rescue accurately, and the README no longer lists `root=/dev/hda1` (no legacy IDE driver is configured; `/dev/sdX` is the only disk name for ATA). *Verify:* `tests/fast/boot-claims.test.sh` (greps init banner, README, `f1.txt`; checks `CONFIG_IDE` absent in the resolved kernel config artifact). *Tier:* fast.
- **G02-AC-9** — `toram` boots under ISOLINUX (`linux toram`) and GRUB (toram entry) at 512 MB, `/ram/rootfs.squashfs` exists, `/media` is not mounted, and ejecting the CD leaves the system running. *Verify:* legs `entries-isolinux:toram`, `entries-grub:toram`. *Tier:* slow.
- **G02-AC-10** — `serial root=/dev/sda1 rootflags=rw` boots from an AHCI ext4 disk built from the ISO's rootfs: `/` is `/dev/sda1` ext4, no overlay, release string equal to the ISO's; and the README's exact `root=/dev/sda1` line is either proven to boot or corrected to carry `rootflags=rw`. *Verify:* legs `entries-isolinux:root`, `entries-isolinux:root-readme`; `test_boot_entries.py::test_rootdisk_build` (fixture squashfs, `fakeroot` skipped with a loud notice if absent in the fast tier). *Tier:* slow + fast.
- **G02-AC-11** — README, `f1.txt` and the contract agree on the label set and their parameters, the README's GRUB paragraph lists the seven entries, and the 32-bit-UEFI "not built" statement is true (no `BOOTIA32.EFI` in the ISO). *Verify:* `tests/fast/boot-claims.test.sh` on the repo; `oracle/bin/check-entries ISO` for the EFI file in CI. *Tier:* fast + slow.
- **G02-AC-12** — The ISO boots as a BIOS hybrid disk: as USB mass storage and as an IDE disk with no CD-ROM, label `serial`, storage smoke checks pass. *Verify:* legs `entries-isolinux:hybrid-usb`, `entries-isolinux:hybrid-ide`. *Tier:* slow.
- **G02-AC-13** — `entries-isolinux` and `entries-grub` are registered in `oracle/modes.yaml` as sharded legs (≤ 6 boots per job), each with `job_timeout_minutes`, and every row of `boot-entries.yaml` is run by exactly one leg (a fast test fails if one is orphaned or duplicated). *Verify:* `tests/fast/test_boot_entries.py::test_leg_coverage`. *Tier:* fast.
- **G02-AC-14** — `grubcfg.extract` returns the `grub.cfg` text from a synthetic EFI containing a tar member, and fails loudly (non-zero, size and hex dump) on an image without the member and on a compressed memdisk. *Verify:* `tests/fast/test_grubcfg.py`. *Tier:* fast.

## RED plan
First `test_boot_entries.py::test_shipped_equals_render` with the predecessor's broken GRUB snippet (`linux /boot/vmlinuz initrd /boot/initrd.img` on one line) as a fixture that must be rejected, plus the table tests (fail: files absent). Then `test_grubcfg.py` (extractor absent), `boot-claims.test.sh` (README still lists `/dev/hda1`, banner still says `exit`: red on the present text), then the leg-coverage test. Slow legs are written last, red until a real ISO is available.

## Risks and open questions
- Hardest: roughly twenty boots under TCG. At 2-4 minutes each the full set is over an hour; the legs shard across jobs, and the per-job budget is set after the first run. Cost is the dominant factor for this node.
- Serial reachability without `console=` rests on the `ttyS0` getty (`inittab` line `s0`). If R05/B04 ever drop it, ten modes fail together. `oracle/interfaces.yaml` should name it (see defects).
- SeaBIOS serial-console mirroring is assumed to carry the `vga=ask` prompt. If it does not, the blind SPACE fallback applies and the AC reduces to "boots to a shell after SPACE".
- Which framebuffer driver the plain GRUB entry uses (`simple` via `SYSFB_SIMPLEFB`, or `EFI VGA`) is not known from the repo; `CONFIG_FB_SIMPLE=y` and `CONFIG_SYSFB_SIMPLEFB=y` are set (`kernel.config:1133,2180`), `FB_EFI` is not examined. The assertion on `grub-plain` is recorded first, enforced after one real run.
- `fakeroot` plus `mke2fs -d` for the `root=` disk is the standard approach but is untested with this squashfs (device nodes, xattrs). Fallback: `sudo` is available on GitHub-hosted runners. Floating apt packages (`fakeroot`) must be declared in I05's `floating.apt`.
- A read-only `root=` boot may fail in `rcS` for reasons unrelated to the claim (writes to `/run`, `/var`). The AC then forces a README correction rather than an init change.
- The `rescue` banner fix touches `rootfs/init` (B03). The change is one string; B03 owns the file and this PR carries the edit with B03's review.

## Cost
Five agent slices: (1) expectations file, `grubcfg`, `isocfg`, `check-entries` and fast tests; (2) `select_grub_entry`, ISOLINUX and GRUB mode runners with fixtures; (3) per-entry expectations and sharding in `modes.yaml`; (4) `rootdisk` and the `root=` legs; (5) hybrid-disk legs and first-run calibration. CI: the first real run is expected to find defects (init, README); plan on 3-4 oracle cycles, each over an hour of runner time because of the boot count. No money beyond runner minutes.

## Spec defects found
- O01-AC-13 lists "exactly the 17" modes in `oracle/modes.yaml`; this node adds `entries-isolinux` and `entries-grub` (and the other G nodes add more). Amend to allow `node: G0x` modes.
- graph.yaml: G02 is listed as unlocking nothing, but G01 and G03 reuse `select_grub_entry`. Either add G02 as a dependency of those or move the helper into O01.
- SPEC §7 and `oracle/interfaces.yaml` (O01) name milestones and GRUB order as the harness interface but not the `ttyS0` getty that G01, G02 and G03 depend on to reach a shell on entries without `console=`. Add it to the interface list; R05/B04 must keep the `inittab` line.
- README claims `root=/dev/hda1` for IDE disks; the kernel has no legacy IDE driver (`CONFIG_IDE` absent), so the claim cannot hold for 6.12. Not a SPEC defect; recorded because it is a promise the gate removes.
- graph.yaml: B05 reaches the kernel only through B03; G02 inherits the same transitive reach. Not a G02 problem; noted in B05.
- `build-iso.sh:264-267` claims "We pin to GRUB 2.12" while the Dockerfile has no such pin (commit e8ad618 reverted it); I05's `asserted.grub` check is the planned fix, G03 depends on it.
- X01 (graph.yaml) does not depend on G01-G05; see G01.
