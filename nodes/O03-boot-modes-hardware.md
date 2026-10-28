# O03 — boot-modes-hardware

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| O | O02, R04 | S05, P02 | MS3 | M |

**Owns:** `oracle/modes/{nic,vga,fbdev_modprobe}.py`, `oracle/fixtures/argv/{nic-*,vga-cirrus,fbdev-modprobe}.txt`, `oracle/policy/fbdev-modprobe-exclude.yaml`, matrix legs for these modes in `oracle/modes.yaml`.
**Carries from linux-live-iso-factory@b9f533b:** `scripts/boot-test.py` lines 419-460 (nic/vga argv), 1231-1319 (model tables and validators), 1895-2036 (runners), `.github/workflows/boot-test.yml` jobs `nic-models` (:538-600), `vga-models` (:602-664), `fbdev-modprobe` (:666-712).
**Study refs:** oracle.yaml `bootmode.nic|vga|fbdev-modprobe`, gaps (NIC drivers only `.ko`-checked, "rtl8139 regex satisfied by either driver"), contradictions (README `CONFIG_VORTEX`, build.yml comment "6 of 21", boot-test.py comment that e1000e is not carried); T-isa-ne-needs-irq, T-ddc-i2c-escalation, T-kernel-config-symbol-names, T-ahci-q35-nic, D-486-tier-regime, D-state-and-no-hidden-stderr.

## Purpose
After this node the ISO is shown to coldplug real emulated network and graphics hardware by modalias, to find an ISA NIC that has no modalias, and to survive hand-loading legacy fbdev drivers with no hardware present. These are the Tier 1/Tier 2 module claims that keep the bzImage small (D-486-tier-regime); a silent drop of a symbol by `olddefconfig` would otherwise ship an ISO that boots on QEMU defaults and fails on a real 3Com or Cirrus machine.

## Scope
In:
- `nic` with the five predecessor models (pcnet, rtl8139, tulip, ne2k_pci, ne2k_isa) as separate CI legs, plus four added models for drivers that were checked only by `.ko` presence.
- `vga` with `-vga cirrus`.
- `fbdev-modprobe` with a stronger module list and a stronger modprobe verdict.
Out:
- Harness, expect engine, shared smoke checks, `oracle.yml`: O01, O02.
- The kernel config and its fast checks (`verify-nic-zoo`, `verify-legacy-fbdev-config`, `verify-netfilter`): R04. The `.ko`-exists and `modinfo firmware` checks on built modules: O06.
- `monolith-net` itself and its unit tests: R05/R01 (the script is a recipe).
- NAT: O04. GUI on the framebuffer: O05. Hardware QEMU cannot emulate (3c509, wd, smc-ultra, lance, the rest of the 27 fbdev chips, Hyper-V): stays `.ko`-presence only (O06), Hyper-V is G03.

## Design

### Modes
All three boot BIOS/ISOLINUX with `qemu-system-i386 -cpu 486 -cdrom ISO -boot d -nographic -serial mon:stdio -no-reboot` (the `build_bios_cmd` base, `boot-test.py:191-212`), then add:

| Mode / leg | Added QEMU args | Label | RAM | Source |
|---|---|---|---|---|
| nic pcnet, rtl8139, tulip, ne2k_pci, ne2k_isa | `-net nic,model=<m> -net user` (legacy form replaces the default e1000, so exactly one card exists) | `serial` | 256 | `:419-428` |
| nic e1000e, virtio-net-pci, vmxnet3, i82559er (new) | same form | `serial` | 256 | new |
| vga cirrus | `-vga cirrus` | `serial vga=788` | 64 | `:430-445,1920` |
| fbdev-modprobe | none (default `-vga std`) | `serial` | 64 | `:1952` |

The `nic` mode requires `--nic-model`; `vga` requires `--vga-model`; a missing option exits 2 (`boot-test.py:423,440` raised `BootTestError`). The predecessor ran the five NIC models sequentially in one job and collected failures at the end (`boot-test.yml:563-583`); each model is now its own matrix leg so the failing model is visible in the job list and a hung model cannot starve the others. Rejected: one job with a shell loop (hides which model failed; one timeout for five boots).

### NIC assertions
Common to all legs: five milestones, shell, uname equals expected, overlay mounted.
- PCI models: `lsmod` matches the model's driver regex (`NIC_MODEL_MODULE`, `:1231-1236`): `^pcnet32\b`, `^tulip\b`, `^ne2k_pci\b`. New: rtl8139 asserts the one driver that binds and `/sys/class/net/eth0/device/driver` resolves to it (carried regex `^8139(too|cp)\b` is satisfied by either driver, oracle.yaml gap). The driver that binds is unknown until the first run; the implementer records it from the log and pins it. Added models: `e1000e` -> `^e1000e\b`, `virtio-net-pci` -> `^virtio_net\b`, `vmxnet3` -> `^vmxnet3\b`, `i82559er` -> `^e100\b`.
- New for every PCI model: `ip link show eth0` exists (the interface appears), not just the module. Rejected: module residency only (a driver that loads and fails probe passes).
- ne2k_isa has no modalias: `^ne\b` absent from `lsmod` after boot; `monolith-net probe` output contains `found` (60 s); `^ne\b` present afterwards (`:1321-1335`). T-isa-ne-needs-irq: QEMU's ISA NE2000 at io 0x300 needs an explicit irq, which `monolith-net` sweeps; if that sweep regresses this leg fails. New: after probe, `ip link show` lists a new non-`lo` interface.

The four added models widen the matrix to drivers the predecessor's `build.yml:322-354` only checked as files. `CONFIG_E1000E=m`, `VIRTIO_NET=m`, `VMXNET3=m`, `E100=m` are set (`configs/kernel.config:1547,1488,1729,1545`). Hardware QEMU does not emulate remains out (see Scope). `CONFIG_VORTEX=y` is built in, so no `.ko` exists and no leg can assert module residency; a test of 3Com is not possible in QEMU.

### vga assertions
`^cirrusfb\b` resident in `lsmod` (module residency, not ownership of `/dev/fb0`: with `vga=788` vesafb claims fb0 first and cirrusfb may lose the handover, `:1304-1319`), uname, overlay. Carried verbatim, including the explicit statement of why residency is the test.

### fbdev-modprobe assertions
Boot with the shared warmup (O01 applies it to every mode now). Then:
1. Record `dmesg | wc -l` as baseline.
2. For each module, `modprobe <m>`: verdict fails on `Oops|Kernel panic|BUG:` in output (`:1268-1284`). New: it also fails if the output contains `not found in directory`, `Module .* not found` or `could not insert` with an error other than "No such device"; the predecessor accepted any exit code, so a module missing from the image passed (`oracle.yaml`: "any exit code OK"). Accepted outcomes: exit 0, or exit non-zero with `No such device`.
3. `/proc/sys/kernel/tainted` equals `0` exactly (`exact_value`, `:1287-1301`, so "4096" does not pass).
4. New lines since baseline (`dmesg | tail -n +<baseline+1>` run in the guest, `:1998-2012`) contain no `Oops`, `BUG:` or `WARNING:`.
5. Print `dmesg | tail -100` to the transcript for diagnosis.

Module list. The predecessor loaded five of 27 (`tdfxfb sm712fb matroxfb_base s3fb lxfb`, `:1265`) and excluded `vga16fb` because it coldplugs unconditionally on `-vga std` (`:1256-1264`). New: the list is the 27 `FB_*` modules of `verify-legacy-fbdev-config` (R04's list is the source of truth, read from `recipes/kernel/`) minus `oracle/policy/fbdev-modprobe-exclude.yaml`, whose entries each have `module`, `reason`, `issue`. Initial exclusion: `vga16fb` (already resident; reason as above). Rejected: hand-kept subset (DCX-48 chose five as representative, but a driver that oopses on an unplugged load is exactly what this mode exists to find, and each `modprobe` costs seconds). Wall time on TCG is unmeasured; if all 26 exceed the leg budget, the implementer splits by chip family into two legs rather than shrinking the list.

## Traps and doctrines preserved
- **T-isa-ne-needs-irq:** ISA NE2000 found at the right io but no interface because irq autodetect fails. Prevented by O03-AC-3 (interface must exist after probe).
- **T-ddc-i2c-escalation:** enabling fbdev drivers can silently escalate `CONFIG_I2C=y` into bzImage via FB_DDC; the other half of that check is R04's and O06's. This node's part: hand-loading drivers must not taint or warn. Prevented by O03-AC-7.
- **T-kernel-config-symbol-names:** symbols dropped by `olddefconfig` yield a missing module; the module-present check is O06's, and here a missing module now fails the modprobe verdict (O03-AC-6) rather than passing as "any exit code".
- **T-ahci-q35-nic:** q35 default NIC. The predecessor believed `e1000e` was not carried (`boot-test.py:1368-1371`), but `CONFIG_E1000E=m` is set (`configs/kernel.config:1547`). The e1000e leg (O03-AC-2) tests the real state. The O02 storage suite stays network-free.
- **D-486-tier-regime:** Tier 1/2 `=m` drivers load only for present hardware. Prevented by the positive coldplug legs here plus O02's nicless negative control.
- **D-state-and-no-hidden-stderr:** each assertion must mean something. Prevented by O03-AC-5 (interface exists), O03-AC-6 (no vacuous modprobe verdict), O03-AC-8 (one leg per model).

## Gate
- **O03-AC-1** — `nic` boots with `-net nic,model=<m> -net user` for pcnet, rtl8139, tulip and ne2k_pci, reaches a shell, and `lsmod` shows the model's driver (`pcnet32`, the single bound rtl8139 driver recorded from the first run, `tulip`, `ne2k_pci`). *Verify:* CI legs `oracle / boot (nic-pcnet|nic-rtl8139|nic-tulip|nic-ne2k_pci)`. *Tier:* slow.
- **O03-AC-2** — `nic` legs for `e1000e`, `virtio-net-pci`, `vmxnet3` and `i82559er` pass with `lsmod` showing `e1000e`, `virtio_net`, `vmxnet3`, `e100` respectively. A leg that exposes a product defect is not skipped: the defect is filed, the leg stays red, and the node does not pass until the defect is fixed or the model is removed from the matrix in the same PR with a recorded reason. *Verify:* CI legs `oracle / boot (nic-e1000e|nic-virtio-net-pci|nic-vmxnet3|nic-i82559er)`. *Tier:* slow.
- **O03-AC-3** — `nic ne2k_isa` asserts `ne` absent after boot, `monolith-net probe` prints `found` within 60 s, `ne` resident afterwards, and a new non-loopback interface exists in `ip link show`. *Verify:* CI leg `oracle / boot (nic-ne2k_isa)`. *Tier:* slow.
- **O03-AC-4** — `vga` boots with `serial vga=788 -vga cirrus` at 64 MB, and `^cirrusfb\b` is resident. *Verify:* CI leg `oracle / boot (vga-cirrus)`. *Tier:* slow.
- **O03-AC-5** — Every PCI NIC leg also asserts that `ip link show eth0` succeeds after boot. *Verify:* `tests/fast/test_oracle_nic.py::test_pci_model_requires_eth0` (replay transcript where the module is in `lsmod` but `eth0` is absent must fail); then CI legs. *Tier:* fast (logic), slow (legs).
- **O03-AC-6** — The fbdev modprobe verdict fails on a crash signature and on a "module not found" outcome, and accepts exit 0 or "No such device". *Verify:* `tests/fast/test_oracle_fbdev.py` with four captured outputs (clean, No such device, Oops, `modprobe: FATAL: Module tdfxfb not found in directory`). *Tier:* fast.
- **O03-AC-7** — `fbdev-modprobe` loads every module in the R04 fbdev list minus the exclusion file, then asserts tainted is exactly `0`, and the guest-side dmesg slice since baseline has no `Oops`, `BUG:` or `WARNING:`. *Verify:* CI leg `oracle / boot (fbdev-modprobe)`; `tests/fast/test_oracle_fbdev.py::test_module_list_is_list_minus_exclusions` and `::test_tainted_4096_fails`. *Tier:* slow (leg), fast (logic).
- **O03-AC-8** — Each NIC model and the VGA model is its own matrix leg in `oracle/modes.yaml` with its own `job_timeout_minutes`; no job runs a shell loop over models. *Verify:* `tests/fast/test_oracle_modes.py::test_nic_legs_are_individual` (nine NIC legs, one VGA leg) and the O02 workflow test that no step contains `for m in`. *Tier:* fast.
- **O03-AC-9** — `fbdev-modprobe-exclude.yaml` entries each carry `module`, `reason`, `issue`; an entry for a module not in the fbdev list, or a duplicate, fails. *Verify:* `tests/fast/test_oracle_fbdev.py::test_exclusion_file_schema`. *Tier:* fast.
- **O03-AC-10** — Golden argv files exist for each leg (`nic-<model>`, `vga-cirrus`, `fbdev-modprobe`) and match the builders, including that NICs use the legacy `-net nic,model=<m> -net user` form. *Verify:* `tests/fast/test_oracle_argv.py`. *Tier:* fast.

## RED plan
Tester commits: `test_oracle_fbdev.py` (verdict function, list-minus-exclusions, tainted `4096`, exclusion schema; modules absent), `test_oracle_nic.py` (replay transcripts under `oracle/fixtures/serial/` for module-present-eth0-absent and for ISA probe with no new interface), the golden argv files, and the `test_oracle_modes.py` leg assertions. They fail because the mode modules, the exclusion file and the legs do not exist.

## Risks and open questions
- Hardest: the four added NIC models and the 26-module fbdev list may surface genuine product bugs on first run (a driver oopsing with no hardware, `i82559er` not binding). That is the point, but it makes MS3 depend on fixes outside the oracle. If any leg needs a recipe change, that fix belongs to R04 or R01 and blocks this node.
- Which of `8139too` / `8139cp` binds QEMU's rtl8139 is unknown; measure on the first run.
- `monolith-net probe` timing under TCG: the 60 s budget was set for the predecessor and may be tight with a long irq sweep.
- Whether QEMU's `-net nic,model=` legacy form stays supported across runner QEMU versions (the oracle setup records the version, O02).
- 26 sequential `modprobe` runs on a 64 MB 486 TCG guest may exceed 30 s per check; the check timeout for `modprobe` should be 60 s and is part of the first-run calibration.
- `rtl8139`, `tulip`, `ne2k_pci` and `pcnet` all also exist as `.ko`-presence checks in O06; keep the two lists generated from one source (R04's module lists).

## Cost
Two to three agent slices: (1) fast tests, mode modules, golden argv; (2) matrix legs, exclusion file; (3) first-run calibration. One to three CI cycles with the O02 `oracle.yml` plus an ISO. Added NIC legs add roughly four more 256 MB TCG boots per run (unmeasured). No paid services.

## Spec defects found
- graph.yaml says O03 is "nic (model matrix), vga, fbdev-modprobe modes" and gives the milestone as MS3, but the modes depend on R04's module lists (the 27 fbdev symbols, NIC symbols), and R04 is not a dependency. Add R04 as a dependency of O03, or have O03 keep its own list (rejected here: duplication).
