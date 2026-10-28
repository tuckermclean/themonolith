# B05 — iso-assembly

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| B | B02, B03, B04, O01 | B06 | — (feeds MS1) | M |

**Owns:** `factory/bin/build-iso`, `factory/bin/check-iso`, `factory/lib/render_boot_cfg.py`,
`factory/lib/gpt_esp_patch.py`, `factory/data/boot/boot-contract.yaml`, `factory/data/boot/isolinux.cfg.in`,
`factory/data/boot/grub.cfg.in`, `factory/data/boot/f1.txt`, `factory/data/boot/bootbg.png`,
`factory/mk/iso-image.mk` (stage target `iso-image` only; the aggregate `make iso` is B06's), `tests/fast/boot-*.test.sh`,
`tests/fast/iso-*.test.sh`, `tests/fast/fixtures/boot/`
**Carries from linux-live-iso-factory@b9f533b:** `scripts/build-iso.sh` (ported; every label, entry and flag
carried, the changes are listed in "Port first" below), `configs/bootbg.png`, the inline GPT patch (`build-iso.sh:430-484`,
ported, extracted to a file).
**Study refs:** build.yaml `script.build-iso` notes (labels and GRUB entries, GPT patch, no date flags,
`log_error` before definition, stale hints, GRUB 2.12 pin claim); oracle.yaml harness (`select_isolinux_label`,
`select_grub_serial_entry`, `GRUB_SERIAL_ENTRY_DOWN_PRESSES=2`); T-grub-initrd-same-line, T-isolinux-timeout,
T-efi-esp-size, T-iso-readability, T-run-rerun-reuses-cache (input identity); SPEC §7 (serial label and GRUB
`(serial)` are interfaces), Principle 5.

## Purpose
After B05 one command turns kernel, initrd and squashfs into the hybrid BIOS and UEFI ISO, with the boot menus
generated from one machine-readable contract that the oracle reads, and with every timestamp and GUID derived from
`SOURCE_DATE_EPOCH`. The ISO's name, labels and entries are the interface the boot harness types against. B05 ports
`scripts/build-iso.sh` (Principle 11): the xorriso flags, GRUB module list, ESP sizing and GPT patch are carried, and
every change is a named criterion. O02 already boots rc1's ISO, so a mismatch between this ISO and rc1's boot behaviour
is a B05 defect, not an oracle question.

## Scope
In:
- `out/themonolith-<ver>.iso` with the layout below, built in the builder from file inputs, no mounts.
- `boot-contract.yaml` and the ISOLINUX and GRUB configs rendered from it.
- GRUB standalone EFI image, FAT16 ESP image, GPT ESP-type patch, explicit reproducibility flags.
- `check-iso`, a structural verification of the produced image.

Out:
- Booting the ISO and harness behaviour: O01-O05, G02 (every label tested), G03 (Hyper-V).
- Kernel, initrd, rootfs: B02-B04. Artifact handoff and `make iso`: B06. Comparing two ISOs: B07.
- 32-bit UEFI (`bootia32.efi`) is not built, as before; a new node would be needed.
- Pinning syslinux, grub, xorriso, mtools, dosfstools versions: I03 and I05 (see defects).

## Design

### Inputs and outputs
Inputs: `out/kernel/vmlinuz`, `out/themonolith-<ver>.initrd`, `out/themonolith-<ver>.squashfs` plus their stage
records `out/stage/{kernel,initrd,rootfs}.json`; syslinux files from the builder `/usr/share/syslinux`
(`isolinux.bin ldlinux.c32 libutil.c32 libcom32.c32 isohdpfx.bin`); `factory/data/boot/`.
Output: `out/themonolith-<ver>.iso` (mode 0644, host-owned), `out/stage/iso.json` (sha256 of the ISO and of every
intermediate: `BOOTX64.EFI`, `efi.img`, rendered `isolinux.cfg`, `grub.cfg`, tool versions).
Decisions: single kernel path `out/kernel/vmlinuz` (rejecting the versioned-name fallback at `build-iso.sh:22-30`,
a CI renaming hack); Gentoo syslinux layout only (rejecting the Debian branch at `:48-55`, which also called
`log_error` before it was defined); scratch under `/work`, not `/tmp`, same reason as `:392`.

### Port first (Principle 11)
`factory/bin/build-iso` is `scripts/build-iso.sh` with the changes below and no others. Carried unchanged: the xorriso
flag list (`:395-417`), the `grub-mkstandalone` module list (`:350-357`), the ESP size formula (`:365-367`), the
`mmd`/`mcopy` copies, the `TIMEOUT 300`, `DEFAULT fb800` and `PROMPT 1` lines, the `f1.txt` text (`:125-149`), the GPT
patch arithmetic (`:430-484`) and the log helpers.

| Predecessor step | Treatment | Forced by |
|---|---|---|
| configs written by heredocs (`:153-348`) | rendered from `boot-contract.yaml` | B05-AC-4 (a contract edit is rejected) and G02, which reads the contract; B05-AC-1 proves the output equals the heredocs |
| kernel path fallback (`:22-30`) | single path `out/kernel/vmlinuz` | B05-AC-8 (a missing input must exit 3, not fall back) |
| Debian syslinux branch (`:48-55`) | deleted; unreachable in the Gentoo builder and it calls `log_error` before its definition. No AC needs it, so this is a visible deletion | none (listed for visibility) |
| missing `bootbg.png`: warn (`:275`) | exit 3 | B05-AC-8 |
| no input identity check | stage-record sha256 compared | B05-AC-8 |
| `/tmp/iso`, `mktemp /tmp/...` (`:20`, `:392`) | `/work/iso`, `/work/iso.tmp` | B05-AC-7 |
| no date or GUID flags; plain `mkfs.vfat` (`:370`) | explicit date and GUID flags, `--invariant`, `touch -h` | B05-AC-7, AC-10 |
| GPT patch skips a missing signature with a message (`:452`) | exits non-zero; idempotent | B05-AC-6 |
| GRUB version only in comments (`:264-267`) | checked against the pin | B05-AC-11 |
| no structural check | `check-iso` | B05-AC-9 |
| inline Python for the GPT patch | `gpt_esp_patch.py` | extracted so B05-AC-6 can test it; logic unchanged |

The v0.2 design also rendered `f1.txt` from the label list. No criterion needs that (AC-1 checks that the text names
all nine labels), so `f1.txt` is the predecessor's text, unrendered.

### Boot contract
`factory/data/boot/boot-contract.yaml` is the single source; `render_boot_cfg.py` renders both configs from it with
`@BUILD_VERSION@` substituted. Hand-editing a generated config is impossible by construction. The templates
(`isolinux.cfg.in`, `grub.cfg.in`) hold the predecessor's comments, `SAY` block and GRUB preamble verbatim.
```yaml
isolinux: {default: fb800, timeout: 300, prompt: 1, f1: f1.txt, serial_directive: false}
labels:   # order matters; APPEND always starts with initrd=/boot/initrd.img
  - {name: linux,   append: ""}
  - {name: fb,      append: "quiet vga=791"}
  - {name: fb800,   append: "quiet vga=788"}
  - {name: fb640,   append: "quiet vga=785"}
  - {name: vga,     append: "vga=ask"}
  - {name: serial,  append: "console=ttyS0,115200n8"}
  - {name: debug,   append: "debug"}
  - {name: persist, append: "persist"}
  - {name: rescue,  append: "rescue"}
grub: {timeout: 5, default: 0, search_label: MONOLITH, serial: "--unit=0 --speed=115200 --word=8 --parity=no --stop=1"}
entries:  # index = position; title = "tHE m0n0LiTH @BUILD_VERSION@" + suffix
  - {index: 0, suffix: "",                  args: ""}
  - {index: 1, suffix: " (framebuffer)",    args: "video=efifb"}
  - {index: 2, suffix: " (serial)",         args: "console=ttyS0,115200n8"}
  - {index: 3, suffix: " (debug)",          args: "debug"}
  - {index: 4, suffix: " (rescue shell)",   args: "rescue"}
  - {index: 5, suffix: " (toram)",          args: "toram"}
  - {index: 6, suffix: " (persistent)",     args: "persist"}
```
Complete lists from `build-iso.sh:200-256,305-347`: nine ISOLINUX labels, seven GRUB entries. There is no ISOLINUX
`toram` label (the harness types `serial toram`, oracle.yaml) and no `SERIAL` directive (the harness uses
`-nographic -serial mon:stdio`, T-isolinux-timeout). `TIMEOUT 300` (30 s) stays. GRUB `kernel` and `initrd` are
always separate lines. The GRUB cfg keeps `search --no-floppy --set=root --label MONOLITH`, `insmod gfxterm png
serial`, `terminal_input console serial`, `terminal_output gfxterm serial`, `background_image
/boot/grub/bootbg.png`. `f1.txt` is the predecessor's help text, which lists every label with one line each plus the toram, root=, console=,
vga=ask note; B05-AC-1 fails if a label is added to the contract and not to `f1.txt`.
Changing any label name, entry index, `(serial)` suffix, default or the no-SERIAL rule is a breaking change to the
harness (SPEC §7).

### ISO layout (inner names are a contract)
`boot/vmlinuz`, `boot/initrd.img`, `rootfs.squashfs`, `boot/efi.img`, `boot/grub/bootbg.png`,
`isolinux/{isolinux.bin,ldlinux.c32,libutil.c32,libcom32.c32,isolinux.cfg,f1.txt,boot.cat}`,
`EFI/BOOT/BOOTX64.EFI`. Volume id `MONOLITH`. Missing `bootbg.png` is exit 3 (was a warning, `:275`).

### Steps (`factory/bin/build-iso`)
1. **verify inputs.** Each input exists and is non-empty (exit 3). Its sha256 must equal the `outputs` hash in the
   upstream stage record (exit 4 on mismatch), so a stale or mixed-run artifact cannot be assembled
   (T-run-rerun-reuses-cache: the consumer checks content, not a cache key).
2. **stage.** Copy inputs and syslinux files into `/work/iso`; render configs; `touch -h -d @$SOURCE_DATE_EPOCH` on
   every staged file and directory.
3. **GRUB.** `grub-mkstandalone --format=x86_64-efi` with the predecessor's module list
   (`part_gpt part_msdos fat iso9660 linux normal echo all_video test keystatus gfxmenu regexp probe efi_gop
   efi_uga search configfile gzio serial gfxterm png`) and `boot/grub/grub.cfg=<rendered>`, with
   `SOURCE_DATE_EPOCH` exported. Its version is read and recorded; it must equal the grub pin (the predecessor
   claimed 2.12 in comments, `:264-267`, but nothing pinned it).
4. **ESP.** Size in MiB = `max(8, ceil((len(BOOTX64.EFI) + 1 MiB) / 1 MiB))` (T-efi-esp-size, `:365-367`), zero
   file via `dd`, `mkfs.vfat -F 16 -s 1 -n EFIBOOT --invariant` (constant timestamps and volume id; requires
   dosfstools >= 4.2, version-gated), `mmd` and `mcopy` of the already clamped `BOOTX64.EFI`.
5. **xorriso.** `xorriso -as mkisofs` with the predecessor's flags: `-R -J -V MONOLITH -b isolinux/isolinux.bin
   -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -isohybrid-mbr isohdpfx.bin
   -iso_mbr_part_type 0x00 -eltorito-alt-boot -e boot/efi.img -no-emul-boot -isohybrid-gpt-basdat`, plus explicit
   reproducibility settings, not reliance on environment: all file dates set to `SOURCE_DATE_EPOCH`, volume
   creation/modification/effective dates set to the same instant, fixed volume UUID derived from it, and a fixed GPT
   disk GUID (`-boot_image any gpt_disk_guid=volume_date_uuid` or equivalent). The implementer confirms the flag
   spellings against the pinned xorriso and records them in the script; AC-10 tests the behaviour, not the spelling.
   Output goes to `/work/iso.tmp`.
6. **GPT patch.** `gpt_esp_patch.py <iso>` sets partition 2's type GUID to the ESP GUID
   `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` in primary (LBA 1/2) and backup (last sector, `total-33`) tables and
   recomputes both CRC32s. It refuses images without `EFI PART` and is idempotent. Decision: keep the patch and
   the xorriso layout, rejecting `-append_partition 2 <ESP-GUID>` because Hyper-V Gen1 compatibility was tuned on
   this exact layout (`:407,410`, G03 owns re-tuning).
7. **finish.** `mv` to `out/`, `chmod 0644`, chown to the host uid (T-iso-readability), write `out/stage/iso.json`.
8. **check-iso** (always at end of the stage): `xorriso -indev <iso> -report_el_torito plain -report_system_area
   plain -find` parsed to assert: two El Torito entries (BIOS `isolinux.bin`, EFI `boot/efi.img`), GPT partition 2
   type is the ESP GUID, volume id `MONOLITH`, and the file set equals the layout above exactly.

## Traps and doctrines preserved
- **T-grub-initrd-same-line:** `initrd` is its own line in every entry; default entry 0 is the plain one. AC-3.
- **T-isolinux-timeout:** `TIMEOUT >= 300`, `DEFAULT fb800`, no `SERIAL`, no `://` in any `APPEND` (it hangs
  ISOLINUX, commit b8d42c4 per doctrine.yaml T-isolinux-timeout). AC-2.
- **T-efi-esp-size:** computed size with an 8 MiB floor, FAT16. AC-5.
- **T-iso-readability:** mode 0644, host-owned. AC-7.
- **T-run-rerun-reuses-cache (consumer side):** inputs verified by hash against the producing stage. AC-8.
- **SPEC §7 interface:** label `serial` and GRUB entry index 2 `(serial)` are pinned by a test the oracle can read
  (`boot-contract.yaml`). AC-1, AC-2, AC-3.
- **Principle 5:** missing background or input is a failure; the ISO is structurally checked after build. AC-8, AC-9.

## Gate
- **B05-AC-1** — The rendered `isolinux.cfg` and `grub.cfg` for `BUILD_VERSION=TESTVER` equal the golden files extracted from `build-iso.sh@b9f533b` (same labels, APPENDs, entry order and titles, ignoring comments and whitespace), and `f1.txt` names all nine labels. *Verify:* `tests/fast/boot-render.test.sh` against `tests/fast/fixtures/boot/*.golden`. *Tier:* fast.
- **B05-AC-2** — ISOLINUX invariants: label `serial` exists with `console=ttyS0,115200n8`; `DEFAULT fb800`; `TIMEOUT` >= 300; no `SERIAL` directive; no `://` in any `APPEND`; all nine labels present in order. *Verify:* `tests/fast/boot-contract.test.sh`. *Tier:* fast.
- **B05-AC-3** — GRUB invariants: exactly seven entries; entry 2's title ends with `(serial)`; `default=0`; every entry has `initrd /boot/initrd.img` on its own line and no `initrd` token on a `linux` line; `search --label MONOLITH` precedes the first `linux`. *Verify:* `tests/fast/boot-contract.test.sh`. *Tier:* fast.
- **B05-AC-4** — A change to `boot-contract.yaml` that renames `serial`, reorders GRUB entries so index 2 is not `(serial)`, or lowers `timeout` below 300 is rejected by the contract test with a message naming the harness interface. *Verify:* `tests/fast/boot-contract.test.sh` (mutated copies). *Tier:* fast.
- **B05-AC-5** — ESP size is `max(8, ceil((n + 1 MiB)/1 MiB))` MiB for n in {1 byte, 6.9 MiB, 7 MiB, 12.3 MiB}; `mkfs.vfat` is called with `-F 16 -n EFIBOOT --invariant`; dosfstools below 4.2 exits 2. *Verify:* `tests/fast/iso-esp.test.sh` (stubs). *Tier:* fast.
- **B05-AC-6** — `gpt_esp_patch.py` on a synthetic two-partition GPT image sets partition 2 to the ESP GUID in both tables, leaves partition 1 unchanged, produces valid header and array CRCs (recomputed independently), is idempotent, and exits non-zero without `EFI PART`. *Verify:* `tests/fast/iso-gpt.test.sh`. *Tier:* fast.
- **B05-AC-7** — The `xorriso` invocation carries every predecessor flag, explicit date and GUID settings, writes to `/work`, and the final file is mode 0644 owned by `HOST_UID`. *Verify:* `tests/fast/iso-xorriso.test.sh` (stub `xorriso` capturing argv). *Tier:* fast.
- **B05-AC-8** — A missing or empty kernel, initrd, squashfs or `bootbg.png` exits 3 naming the file; an input whose sha256 differs from its upstream stage record exits 4. *Verify:* `tests/fast/iso-inputs.test.sh`. *Tier:* fast.
- **B05-AC-9** — `check-iso` on the real ISO passes: two El Torito entries, GPT partition 2 type is the ESP GUID, volume id `MONOLITH`, file set equals the contract exactly, ISO size recorded. *Verify:* CI job `image`, step "check-iso". *Tier:* slow.
- **B05-AC-10** — Two `build-iso` runs at least two seconds apart on identical inputs produce the same ISO sha256, the same `efi.img` and `BOOTX64.EFI` sha256; any difference is reported by B07 and entered with a cause. *Verify:* CI job `image`, steps "iso twice" then `cmp`. *Tier:* slow.
- **B05-AC-11** — The grub version printed by `grub-mkstandalone --version` equals the pin and is stored in `iso.json.tools`; a mismatch exits 4. *Verify:* `tests/fast/iso-tools.test.sh` (stub); CI log. *Tier:* fast.
- **B05-AC-12** — The produced ISO boots through BIOS label `serial` and UEFI entry `(serial)` to the shell milestone. *Verify:* O02 modes `bios` and `uefi` in CI against this ISO. *Tier:* slow.

## RED plan
Tester writes first, all failing for lack of the scripts and contract: `boot-render` (golden files produced by
extracting the heredocs from `build-iso.sh@b9f533b` with `BUILD_VERSION=TESTVER`), `boot-contract` (including
mutated-contract cases), `iso-gpt` (synthetic GPT built in the test, no xorriso), `iso-esp`, `iso-xorriso`
(stub captures argv; asserts date flags present, which the predecessor lacked), `iso-inputs`.

## Risks and open questions
- Reproducibility of `grub-mkstandalone`, `mcopy`/`mmd` directory times and xorriso's GPT GUIDs is from tool
  documentation, not tested here. B07 is the arbiter; fallbacks are a pinned `libfaketime` in the builder (I03) or
  writing the FAT image with a small Python writer.
- `mkfs.vfat --invariant` needs dosfstools 4.2 or newer; unknown whether the builder's stage3 has it.
- The grub pin matters: 2.14 has a Hyper-V regression (`build-iso.sh:264-266`). SPEC §6 now pins the boot-media
  tools; B05-AC-11 checks the version actually used.
- Whether Hyper-V needs the current layout is G03's question; B05 preserves it.
- 32-bit UEFI machines (ia32 firmware) still cannot boot; out of scope.
- Golden-file fixtures contain the predecessor's wording; a deliberate change updates the golden in the same PR
  with the reason.

## Cost
Slices: (1) contract, renderer, goldens; (2) GPT patch, ESP, xorriso invocation with stubs; (3) `check-iso`,
inputs verification, determinism. About 3 slices. CI cycles: 3 (first real ISO, determinism repair, UEFI repair);
each iteration is minutes because the ISO job reuses earlier artifacts. No money.
