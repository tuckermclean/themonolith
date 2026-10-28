# G03 — hyperv

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| G | O02 | X01 | — | M |

**Owns:** `oracle/modes/hyperv_proxy.py` (mode `hyperv-gen2-like`), `oracle/fixtures/argv/hyperv-gen2-like.txt`, `oracle/fixtures/serial/hyperv-*.txt`, entry `hyperv-gen2-like` in `oracle/modes.yaml`, the `hyperv` group in `recipes/kernel/invariants.yaml` and the hyperv rows of `oracle/policy/required-modules.yaml` (files owned by R04 and O06; this node edits only those groups), `oracle/bin/check-hybrid-layout`, `docs/evidence/hyperv/` (README, `TEMPLATE.md`, evidence files), `factory/bin/check-evidence`, `tests/fast/test_hyperv_proxy.py`, `tests/fast/hyperv-claims.test.sh`, `tests/fast/test_hybrid_layout.py`, `tests/fast/test_evidence.py`.
**Carries from linux-live-iso-factory@b9f533b:** the Hyper-V facts only: `README.md:167` (claims), `scripts/build-iso.sh:260-266` (GRUB 2.12 comment), `:300-308` (default entry reasoning), `:400-420` (xorriso hybrid flags), `:424-484` (GPT ESP GUID patch), `configs/kernel.config` symbols `HYPERV`, `HYPERV_TIMER`, `HYPERV_STORAGE`, `HYPERV_KEYBOARD`, `HYPERV_NET`, `FB_HYPERV`, `HID_HYPERV_MOUSE`, `HYPERV_BALLOON`, `HYPERV_IOMMU`, `HYPERVISOR_GUEST` (lines 272, 1324, 1731, 1822, 2179, 2308, 2518-2520, 2592). No test code exists to carry.
**Study refs:** oracle.yaml gaps ("Hyper-V Gen 1 / Gen 2 boot: README.md:167 claims ... no QEMU test can emulate Hyper-V; no test of the hybrid MBR type or hv_netvsc/hv_storvsc"); doctrine.yaml T-hyperv-old-grub (and its open question "where is the constraint encoded"), T-grub-initrd-same-line (frozen Gen2 entries), T-efi-esp-size, T-iso-readability, D-state-and-no-hidden-stderr; git evidence: commit 329f9ea (pinned GRUB 2.12 for Hyper-V), e8ad618 (reverted that pin the same day, reason unrecorded), 259a6af (#11) and ab8705c (#10) (Gen2 fixes; message says "the actual Gen2 fix needs real-hardware validation"); remote branch `origin/feat/hyperv-gen2` (one commit ahead, kernel drivers, already merged as #10).

## Purpose
After this node the README says only what the project can show about Hyper-V. Everything that can be proved without a Hyper-V host is proved in CI: the paravirtual drivers are configured and shipped, their modules load without symbol errors, the ISO has the layout that was tuned for Hyper-V, and the machine shape Hyper-V Generation 2 presents (UEFI, SCSI media, no legacy devices) boots the default GRUB entry. What QEMU cannot show is stated as a manual-evidence requirement with a template and a checker, and the README's strongest wording is tied to that evidence.

## Scope
In:
- Fast and artifact checks for the Hyper-V kernel symbols, modules and module aliases.
- A QEMU mode shaped like a Generation 2 VM (UEFI, SCSI CD, virtio network, no IDE) booting the default GRUB entry.
- Module-load checks in a normal QEMU guest (the loadability half of "hv_netvsc works").
- Checks on the hybrid ISO layout (MBR and GPT bytes) as built.
- The GRUB version constraint and where it is recorded.
- The manual evidence format, its checker, and the README claim rules.
Out:
- Running Hyper-V in CI. Not possible on GitHub-hosted runners; see Risks for the Azure option.
- The ISO build and the layout itself: B05 (preserves it; this node tests it).
- The default-entry boot on UEFI in general and the GRUB entry set: O02, G02. This node adds only the Gen2-shaped machine.
- Kernel config fragments and tiers: R04. Module-shipped checks: O06. This node adds rows to their lists.
- Pinning GRUB: I03/I05 (`asserted.grub`); this node consumes the pin.
- Secure Boot signing of the EFI image: not built, no node owns it. The README states the consequence.

## Design

### Claim inventory and disposition
Every Hyper-V sentence in the predecessor's README, split into testable parts:

| Claim (source) | Disposition |
|---|---|
| "ships ... Hyper-V paravirtual devices" (README:167) | Made true and tested: G03-AC-1, AC-2, AC-3. |
| "Hybrid layout with `-iso_mbr_part_type 0x00` targets Hyper-V Gen 1 BIOS boot specifically" (README:167) | Layout is asserted as built (AC-4). The causal sentence ("targets Gen 1") is reworded to "layout retained from a Hyper-V Gen 1 compatibility fix, not re-verified" until evidence exists. |
| "boots on Hyper-V" (SPEC §1, implicit) | Proxy tests in CI (AC-5, AC-6); README wording tied to manual evidence (AC-7, AC-8). |
| GRUB must be older than the version that fails on Hyper-V (`build-iso.sh:260-266`) | Recorded and checked (AC-9). |
| Gen 2 default entry is plain, not efifb (`build-iso.sh:300-308`) | Covered by G02 (default entry) and AC-5 here. |
| Secure Boot (not mentioned) | Added to README: the EFI image is unsigned, so Gen 2 needs Secure Boot off or the Microsoft UEFI CA template (AC-8). Stated as "expected", flagged for evidence. |

### Kernel and module checks (fast and artifact tier)
- `recipes/kernel/invariants.yaml` gets a `hyperv` group (R04's `require:` form): `HYPERVISOR_GUEST=y`, `HYPERV=y` (the VMBus core is built in), `HYPERV_TIMER=y`, `HYPERV_STORAGE=y` (the Gen 2 boot disk is a storvsc SCSI disk, needed before any module can load), `HYPERV_KEYBOARD=y`, `HYPERV_NET=m`, `FB_HYPERV=m`, `HID_HYPERV_MOUSE=m`, `HYPERV_BALLOON=m`. These are the symbols present at b9f533b. The group is checked against the authored fragments and the resolved config artifact by R04's `kconfig-check`.
- `oracle/policy/required-modules.yaml` (O06) gets `hv_netvsc`, `hyperv_fb`, `hid-hyperv`, `hv_balloon` as required shipped modules, so a missing `.ko` fails O06's `modules-shipped` check.
- New artifact check in this node, `hyperv-aliases`: for each of those four modules, `modules.alias` in the built tree contains at least one `vmbus:` alias mapping to it. Reason: the boot-time coldplug (`rcS`) loads modules by `modalias` found under `/sys`, and VMBus devices appear there as `vmbus:<class-guid>`. Without the alias the module exists but is never loaded. The hex values are read from the file, not hard-coded here.
- Known absence recorded, not fixed: `CONFIG_HYPERV_UTILS` (shutdown, heartbeat, time sync, KVP integration services) does not appear in `kernel.config` at all (its dependency `CONNECTOR` is off). Hyper-V's "Shut down" action therefore will not reach the guest. `docs/evidence/hyperv/README.md` lists "host-initiated shutdown" as an expected-to-fail item; adding the symbols is a kernel decision for the owner (486-minimalism, Tier 2 cost), see Risks.

### Module loadability in QEMU (`hyperv-gen2-like` mode, boot A)
In any guest the four modules are present, but no VMBus exists. Loading them must not fail for a *wrong* reason. The mode runs, for each module, `modprobe -v <m>` and records exit status and stderr. Accepted outcomes: exit 0, or failure with `No such device` (the VMBus driver registration returns ENODEV when not running on Hyper-V; expected, to be confirmed by the first real run). Rejected outcomes, each a test failure: `Unknown symbol`, `Exec format error`, `Invalid module format`, `Key was rejected`, `Required key not available`, `not found`. This proves the modules match the running kernel and resolve against `hv_vmbus` without needing a hypervisor. It does not prove they work; the README does not claim it.

### The Gen 2 shaped machine (`hyperv-gen2-like` mode, boot B)
Hyper-V Generation 2 presents UEFI firmware with no IDE controller, no floppy, no legacy BIOS, boot media on a SCSI controller, a synthetic NIC, and a GOP framebuffer until `hyperv_fb` takes over. The closest QEMU shape: `qemu-system-x86_64 -machine q35 -cpu qemu64 -m 512` (OVMF is 64-bit firmware and needs a CPU with long mode, so `-cpu 486` cannot be used; the predecessor's UEFI mode likewise runs `qemu-system-x86_64` with OVMF, and the i386 kernel runs on it through the EFI handover protocol, `build-iso.sh:260-262`), `-drive if=pflash,...OVMF_CODE...`, `-nodefaults`, `-device virtio-scsi-pci,id=s0`, `-drive id=cd,if=none,format=raw,media=cdrom,file=ISO,readonly=on`, `-device scsi-cd,drive=cd,bus=s0.0`, `-netdev user,id=n0 -device virtio-net-pci,netdev=n0`, `-vga std` (GOP only), `-serial mon:stdio -nographic`. No IDE, no AHCI CD, no PS/2 mouse beyond what q35 hardwires.
- GRUB: no keypress, default entry 0 (plain, no parameters), so the test exercises the entry Hyper-V Gen 2 users get (T-grub-initrd-same-line: initrd on its own line; `set default=0`).
- Observation: shell on the `ttyS0` getty (as G02); `/proc/cmdline` has no `console=` and no `video=efifb`; `uname -r` equals the expected kernel; the boot media was found on SCSI (`/proc/mounts` shows the media under `/media` or `/ram`; `ls /sys/class/scsi_host` non-empty); `dmesg | grep -c 'hv_'` is recorded.
- Console: the plain entry must not select `efifb` (it freezes on Gen 2). The mode records `/sys/class/graphics/fb0/name` and fails if it is `EFI VGA`. This ties to G02's `grub-0` row.
- RAM 512 MB (UEFI path; T-toram-ram applies only to toram).
Rejected: emulating Hyper-V with `-cpu host,hv-*` enlightenments. They need KVM (not available on hosted runners, O02 notes TCG only), advertise Hyper-V CPUID without providing VMBus devices, and would make the guest hang waiting for a hypervisor that is not there. Also rejected: custom QEMU patches providing VMBus (none upstream).

### Hybrid layout checks (`oracle/bin/check-hybrid-layout`)
Reads the built ISO's first 34 sectors: MBR partition table entries (type bytes, start, size, boot flag), the protective/hybrid structure, GPT header signature and both CRC32s, partition 2's type GUID equals the ESP GUID `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` (B05 sets it, B05-AC-6/AC-9 check it on a synthetic image and by `xorriso` report; this check reads the shipped bytes directly), and El Torito has the BIOS (`isolinux.bin`) and EFI (`boot/efi.img`) entries. It prints the bytes it found. The MBR partition type byte is compared with the value documented in `docs/evidence/hyperv/README.md` (`0x00`, from `-iso_mbr_part_type 0x00`), so a xorriso upgrade that changes it fails here. Stdlib `struct` only.

### GRUB version constraint
The predecessor's commit 329f9ea pinned GRUB 2.12 because 2.14 "introduced a regression in kern/efi/mm.c: add_memory_regions() calls grub_fatal() when EFI AllocatePages fails at a fixed address ... Hyper-V reports those pages as EfiConventionalMemory but refuses to allocate them". That text is the only evidence; nothing in the repository reproduces it. The same day (e8ad618) the pin was reverted and the Dockerfile has floated ever since, while `build-iso.sh:264-267` still says the pin exists. The rebuild records the truth: I05's `asserted.grub` holds the version the builder resolves, B05 records `grub-mkstandalone --version` in `iso.json.tools`, and this node's rule is: if `asserted.grub` is 2.14 or newer, a Gen 2 evidence file for that exact GRUB version must exist (AC-9). Rejected: pinning GRUB < 2.14 now. The reason for the revert is unknown, a pin may break the toolchain tree build, and pinning an old GRUB has its own cost; the rule makes the risk visible without guessing.

### Manual evidence
`docs/evidence/hyperv/TEMPLATE.md` defines the fields; one file per generation per release: `docs/evidence/hyperv/<vX.Y.Z[-rcN]>-gen1.md` and `-gen2.md`.
- Header (machine-read): `iso_version`, `iso_sha256` (must equal the ISO's digest in that release's `attestation-summary`), `generation` (1|2), `host_os` and build, `date_utc`, `secure_boot` (`off` | `microsoft-uefi-ca` | `microsoft-windows` for Gen 2), `memory_mb`, `grub_version` (from `iso.json.tools`), `tester`.
- Checklist, each `PASS` | `FAIL` | `N/A` with a one-line note: boots default entry to a usable shell on the VM console; keyboard; mouse (Gen 2 synthetic); framebuffer after hyperv_fb loads (`lsmod` shows `hyperv_fb`); NIC gets a DHCP lease through `hv_netvsc` (`ip -4 addr`); `dmesg | grep -i hv_` excerpt; host-initiated shutdown (expected `FAIL` until `HYPERV_UTILS`); ISOLINUX label `serial` on Gen 1.
- Attachments by reference: console screenshot filenames with sha256 (stored beside the file, small PNGs).
`factory/bin/check-evidence` (stdlib + PyYAML front-matter) validates structure, enum values, the digest format, the filename/version agreement, and that `generation` matches the filename.

README states, from a small set of sentences keyed to the evidence directory (AC-8):
- `Hyper-V: expected to work (Gen 1 BIOS, Gen 2 UEFI with Secure Boot off); not verified.` when no evidence file exists;
- `Hyper-V Gen N: verified on vX.Y.Z (<date>)` per evidence file whose checklist has no `FAIL` outside the listed expected-to-fail items;
- and, when `asserted.grub` differs from the evidence's `grub_version`, the verified sentence is replaced by `... verified with GRUB <v>; current build uses GRUB <w>, re-verification pending`.
Rejected: a CI badge or boolean file; the evidence is a human act and must carry who, when, what.

## Traps and doctrines preserved
- **T-hyperv-old-grub:** the GRUB constraint existed only in a commit message and a stale comment. Prevented by G03-AC-9 (version recorded; 2.14+ needs matching evidence) and G03-AC-8 (README cannot say "verified" on a GRUB the evidence did not cover).
- **T-grub-initrd-same-line:** CI exercised only `(serial)` while Gen 2 users got entry 0. Prevented by G03-AC-5 (Gen 2-shaped boot of entry 0) together with G02-AC-1/AC-3.
- **Frozen console from efifb on Gen 2:** Prevented by G03-AC-5 (`fb0/name` is not `EFI VGA` on the default entry).
- **Module shipped but never loaded:** Tier 2 modules load only by modalias. Prevented by G03-AC-2 (`vmbus:` aliases exist).
- **T-efi-esp-size / ESP type GUID:** UEFI firmware recognises the ESP by type GUID. Prevented by G03-AC-4 (shipped bytes).
- **D-state-and-no-hidden-stderr:** the predecessor's Hyper-V "support" was a commit message that said "needs real-hardware validation" and never got any. Prevented by G03-AC-7 and AC-8 (claims follow evidence; absence of evidence changes the wording, not the test).
- **Promise-versus-test (SPEC §1):** a README promise with no test is a gap. Prevented by AC-8.

## Gate
- **G03-AC-1** — The `hyperv` invariant group (`HYPERVISOR_GUEST=y`, `HYPERV=y`, `HYPERV_TIMER=y`, `HYPERV_STORAGE=y`, `HYPERV_KEYBOARD=y`, `HYPERV_NET=m`, `FB_HYPERV=m`, `HID_HYPERV_MOUSE=m`, `HYPERV_BALLOON=m`) holds in both the authored fragments and the resolved config artifact, and removing any of them from a fragment fails the check. *Verify:* `tests/fast/kconfig-features.test.sh` (R04's runner, hyperv group) with a mutated-fragment case; B02 runs `kconfig-check resolved` on the artifact. *Tier:* fast + slow.
- **G03-AC-2** — The built module tree contains `hv_netvsc`, `hyperv_fb`, `hid-hyperv` and `hv_balloon`, each with at least one `vmbus:` alias in `modules.alias` that maps to it, and no `firmware=` modinfo entry. *Verify:* O06 `modules-shipped` with the hyperv rows, plus `oracle/artifacts/checks/hyperv_aliases.py` run by `oracle/artifacts/check.py`; `tests/fast/test_hyperv_proxy.py::test_alias_check` on a fixture `modules.alias`. *Tier:* fast + slow.
- **G03-AC-3** — In a booted guest each of the four modules either loads or fails only with `No such device`; any `Unknown symbol`, `Exec format error`, `Invalid module format`, key-rejection or `not found` message fails the mode. *Verify:* CI leg `oracle / boot (hyperv-gen2-like)` boot A; classification function unit-tested in `test_hyperv_proxy.py::test_modprobe_classifier` with one transcript per accepted and rejected outcome. *Tier:* slow + fast.
- **G03-AC-4** — `check-hybrid-layout` on the built ISO reports: El Torito BIOS and EFI entries present; GPT header valid with both CRC32s correct; partition 2 type GUID equals the ESP GUID; MBR partition type byte equals the documented value (`0x00`); and it fails on each of those four conditions in a mutated image. *Verify:* `tests/fast/test_hybrid_layout.py` (synthetic images, one mutation per condition) and CI step on the real ISO. *Tier:* fast + slow.
- **G03-AC-5** — The Gen 2-shaped QEMU machine (q35, OVMF, `virtio-scsi` CD, no IDE or AHCI, virtio-net, std VGA) boots GRUB entry 0 with no keypress to a shell on serial, with `/proc/cmdline` free of `console=` and `video=efifb`, `uname -r` as expected, boot media found on SCSI, and `fb0/name` not `EFI VGA`. *Verify:* CI leg `oracle / boot (hyperv-gen2-like)` boot B; argv golden `oracle/fixtures/argv/hyperv-gen2-like.txt` tested in `test_hyperv_proxy.py::test_argv_golden` (asserts no `ide`/`ahci`/`-cdrom`). *Tier:* slow + fast.
- **G03-AC-6** — The mode is registered in `oracle/modes.yaml` with `node: G03`, a `job_timeout_minutes`, `needs: [ovmf]`, and its result JSON records the GRUB version string read from the EFI image and the `fb0/name` value. *Verify:* `tests/fast/test_hyperv_proxy.py::test_registry`; result JSON schema check from O01. *Tier:* fast.
- **G03-AC-7** — `docs/evidence/hyperv/` contains `README.md` and `TEMPLATE.md`; `check-evidence` accepts a complete fixture, and rejects missing fields, a non-64-hex digest, a version/filename mismatch, `generation` not matching the filename, and a checklist value outside `PASS|FAIL|N/A`. *Verify:* `tests/fast/test_evidence.py` with one fixture per rule. *Tier:* fast.
- **G03-AC-8** — README Hyper-V sentences equal exactly one of the allowed forms for the current state of `docs/evidence/hyperv/`: the "expected to work, not verified" form when no valid evidence exists; a "verified on vX (date)" form per valid evidence file; the GRUB-mismatch form when `asserted.grub` differs from the evidence's `grub_version`. README also names the Secure Boot requirement for Gen 2 and does not say the hybrid layout "targets" Gen 1 as fact. *Verify:* `tests/fast/hyperv-claims.test.sh` (fixture repo states: none, valid, valid-but-stale-grub, invalid evidence). *Tier:* fast.
- **G03-AC-9** — The GRUB version used by the builder is recorded (`pins.asserted.grub` and `iso.json.tools.grub`), and if it is 2.14 or newer, a valid Gen 2 evidence file with that `grub_version` and no failing boot item must exist or the check fails. *Verify:* `tests/fast/hyperv-claims.test.sh` (`grub-gate` cases: 2.12 no evidence = pass, 2.14 no evidence = fail, 2.14 with matching evidence = pass). *Tier:* fast.
- **G03-AC-10** — `build-iso.sh`-style comments claiming a GRUB pin that does not exist are gone: no file in the repo says "pin(ned) to GRUB 2.12" unless `asserted.grub` equals it. *Verify:* `tests/fast/hyperv-claims.test.sh` (grep `GRUB 2\.12` against the ledger value). *Tier:* fast.
- **G03-AC-11** — Manual evidence for the first release from this repository exists, one file per generation, validated by `check-evidence`, or the README carries the "not verified" form and the release notes (P02) include the line. *Verify:* `check-evidence` in the release checklist (X01); recorded in the X01 PR table. *Tier:* slow (manual).

## RED plan
First `hyperv-claims.test.sh` (red against a checkout whose README still says the layout "targets Hyper-V Gen 1" and that has no evidence directory), then `test_evidence.py` and `test_hybrid_layout.py` (tools absent), then `test_hyperv_proxy.py` (mode, classifier, argv golden absent). Kernel invariants test is red until the `hyperv` group exists in R04's file. Slow legs follow once the ISO exists.

## Risks and open questions
- Hardest: nothing in CI exercises VMBus. Every green check here is a proxy, and the node's honest output is a README that says "not verified" until a human supplies evidence. A reader who wants Hyper-V guaranteed gets a procedure, not a pass.
- Whether GRUB 2.14 truly fails on Hyper-V is unverified; only the predecessor's commit message says so. Whether the revert e8ad618 was deliberate is unknown (the commit message says only "Revert to Dockerfile from 61b40a0c…"). Owner question: does the owner know if a current GRUB boots on Gen 2?
- `modprobe` returning `No such device` rather than 0 for `hv_*` without VMBus is expected, not confirmed. The classifier accepts both; if the first run shows another benign error text it is added with a transcript fixture.
- `HYPERV_UTILS` is absent, so host shutdown, heartbeat and time sync do not work. Adding it (and `CONNECTOR`) is a Tier 2 module and a small size cost; the owner decides (D-486-minimalism). The node documents the gap and does not change the kernel.
- Automating real Hyper-V evidence is possible through Azure (convert the ISO to a fixed VHD, create a Gen 1 and a Gen 2 VM from the custom image, read the serial console through boot diagnostics). It needs an owner Azure subscription and credentials as repository secrets, costs cents per run, and adds a third-party service dependency. Not designed here; proposed as a new OD if wanted. Rejected for this node: it presumes spend and a secret the owner has not offered.
- Secure Boot: the GRUB standalone image is unsigned. Whether Hyper-V Gen 2's default "Microsoft Windows" template refuses it is expected (unsigned third-party EFI) but unverified; that is why README names the templates to use.
- The `hyperv_fb` driver is deprecated upstream in favour of `hyperv_drm` in newer kernels; at 6.12.80 `FB_HYPERV` exists. A kernel bump (B02) may need `DRM_HYPERV`; recorded here so the next invariant review looks.
- Modules are Tier 2 on the squashfs, so a Gen 2 console may stay on the EFI GOP framebuffer until the coldplug loads `hyperv_fb`; the first seconds of boot are on a framebuffer the host may not refresh. Only real hardware shows whether that is the "frozen console".

## Cost
Three agent slices: (1) kernel invariant group, required-modules rows, alias check, layout checker with fast tests; (2) `hyperv-gen2-like` mode with classifier and goldens; (3) evidence tooling, README claim rules and the claims test. CI: two or three oracle cycles; the mode is two short boots (about 10 minutes of TCG). Manual: one Gen 1 and one Gen 2 test session by the owner per release for the "verified" wording; if skipped, the README says so. Money: none unless the owner approves the Azure option.

## Spec defects found
- O01-AC-13 requires exactly 17 modes; this node adds `hyperv-gen2-like` (see G01).
- SPEC §1 lists Hyper-V as a target "per G03" with no definition of what makes a target supported. This node defines: CI proxies plus dated manual evidence, with README wording tied to the evidence.
- SPEC §6 does not list GRUB (or syslinux, xorriso) among pinned items although a known Hyper-V regression depends on the GRUB version; I05's `asserted.grub` and B05's `iso.json.tools` are the planned fix. B05 already notes it; X01 should check G03-AC-9 holds before release.
- `build-iso.sh:264-267` and `:503` still claim a GRUB 2.12 pin that commit e8ad618 removed. The rebuild's B05 must not carry the comment; G03-AC-10 guards it.
- X01 (graph.yaml) does not depend on G03, so the first release can ship with README Hyper-V text unreviewed. Add G03 (or G01-G05) to X01.
