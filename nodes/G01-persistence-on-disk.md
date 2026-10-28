# G01 — persistence-on-disk

| Phase | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| G | O04 | X01 | — | M |

**Owns:** `oracle/modes/persist_init.py`, `oracle/modes/persist_uefi.py`, `oracle/lib/blank_disk.py`, `oracle/fixtures/argv/persist-init.txt`, `oracle/fixtures/argv/persist-uefi.txt`, `oracle/fixtures/serial/persist-init-*.txt`, entries `persist-init` and `persist-uefi` in `oracle/modes.yaml`, `tests/fast/test_persist_modes.py`, `tests/fast/persist-docs-claims.test.sh`. Changes to `monolith-persist`, `topics/persist.txt` and the init `persist` path are made in R01's tree (`recipes/overlay/app-misc/monolith-base/files/`, init under B03) by this node's PR, because the behaviour is G01's; ownership of those files stays with R01/R05/B03.
**Carries from linux-live-iso-factory@b9f533b:** `configs/overlay/app-misc/monolith-base/files/monolith-persist` (191 lines), `.../20-persist.sh`, `.../50-persist-history.bash`, `.../topics/persist.txt`, `scripts/tests/monolith-persist.test.sh` (stub-based, kept as the fast tier), `scripts/tests/monolith-persist-profile.test.sh`, `scripts/tests/monolith-persist-bashrc.test.sh`, `rootfs/init:446-526` (persist detection, loop of 8 tries, mount, tmpfs fallback), `scripts/build-iso.sh:252-258` (GRUB `(persistent)` entry), `scripts/boot-test.py:2185-2300` (O04 owns the history-persist mode).
**Study refs:** oracle.yaml gaps ("Real-disk persistence: persist mode uses a host-formatted virtio-blk file... nothing boots the guest and runs `monolith-persist init`", GRUB `persistent` entry, swapfile creation and `swapon`), `bootmode.persist`; doctrine.yaml T-persist-race, T-console-home, T-initrd-busybox-missing-applets, DEC-gui-doctrine (swap-on-persist for the 8 MB GUI), DEC-lean-boot-ux; `monolith-persist.test.sh` header ("stubs mkfs.ext4/mkswap/blkid/mount").

## Purpose
After this node the README's persistence story (format a labelled partition on the disc itself, boot with `persist`, keep your files, optionally add swap) is proved end to end in QEMU, from a blank disk, on BIOS via ISOLINUX and on UEFI via the GRUB `(persistent)` entry. The predecessor tested only that shell history survives on a disk the host had formatted; the tool users are told to run was only run against stubs.

## Scope
In:
- A BIOS mode that boots the ISO with a blank raw disk, runs the real `monolith-persist init` (with `--swap`) on it, reboots with `persist`, and checks files and swap across an unclean power-off.
- A UEFI mode that does the persist boot through the GRUB `(persistent)` entry on a disk formatted by the guest.
- Resolving the swap story: tested as documented (manual `swapon`), with the documentation made exact.
- A fast check that persistence claims in README/help topics match what the modes prove.
Out:
- The history-survives-power-off mode on a host-formatted disk: O04 (`persist`). This node does not touch it.
- Selecting the other GRUB entries and ISOLINUX labels: G02.
- The init script's general structure and device scan: B03; the persist block is covered here only by behaviour.
- Automatic boot-time swapon: not built (decision below).
- Encrypted persistence, multiple persist partitions, partitioning tools: not promised, not built.

## Design

### Behaviour claims under test
From the predecessor's text, restated as the testable contract:
1. `monolith-persist init <dev> [--swap N] [--yes]` creates ext4 labelled `MONOLITH_PERSIST` and, with `--swap N`, an N MB file `swapfile`, mode 0600, with a swap signature, at the filesystem root.
2. A boot with the `persist` kernel parameter finds that labelled device (within the 8 x 1 s poll), mounts it at `/overlay`, uses `/overlay/upper` and `/overlay/work` for the overlay, and every write under `/` then survives a reboot.
3. `swapon /overlay/swapfile` enables the swapfile (the topic says there is no boot-time swapon).
4. The GRUB `(persistent)` entry boots with `persist`.
5. With no labelled device, boot falls back to tmpfs and says so (`err "'persist' requested but no MONOLITH_PERSIST partition found"`).

### Swap decision
Tested as documented: manual `swapon /overlay/swapfile`. No automatic swapon is added. Reason: `topics/persist.txt:40-48` and `monolith-persist` state in three places that there is none and tell the user the one line to put in `/etc/profile.local`; adding behaviour changes the 486 RAM profile and the documented contract, which is an owner decision and not a gap-closing test. Rejected: an `S` init script that swaps on automatically; it is small but changes RAM use on every persist boot of an 8 MB machine and is not demanded by any README sentence. If the owner wants it, it is a new node with its own ACs. The mode's profile-local check (`echo 'swapon /overlay/swapfile' >> /etc/profile.local`, then reboot, then `/proc/swaps` lists it) proves the documented recipe works, not a new feature.

### `persist-init` mode (BIOS)
Registered as `persist-init` in `oracle/modes.yaml` with `node: G01`, `needs: [qmp-none]`, RAM 128 MB (as `persist`; the swapfile test at 64 MB is a second leg `persist-init-64`, see Risks). The mode runs three boots against one disk file created by `oracle/lib/blank_disk.py` (`truncate -s 128M`; no filesystem, no partition table). The host needs no `mkfs.ext4`.
- Argv: `qemu-system-i386 -cdrom ISO -drive id=pd,if=none,format=raw,file=DISK -device virtio-blk-pci,drive=pd -m 128 -cpu 486 -boot d -nographic -serial mon:stdio -no-reboot` (the `persist` argv of `boot-test.py:703-714` with a blank disk).
- Boot 1, label `serial` (no `persist`). Checks: `blkid /dev/vda` prints nothing (blank, exit 2), then `monolith-persist init /dev/vda --yes --swap 16` exits 0 and prints `is now MONOLITH_PERSIST (ext4)`; `blkid /dev/vda` shows `LABEL="MONOLITH_PERSIST"` and `TYPE="ext4"`; mount it at `/mnt`, `stat -c '%s %a' /mnt/swapfile` equals `16777216 600`; `umount /mnt`; `poweroff` and wait for EOF (clean).
- Boot 2, label `serial persist`. Checks: `/overlay` is mounted from `/dev/vda` with type ext4 (read `/proc/mounts`; no `awk` assumption beyond what the disc has); `/etc/profile.d/20-persist.sh` output `persist: mounted`; `swapon /overlay/swapfile` exits 0; `/proc/swaps` lists `/overlay/swapfile`; `swapoff` exits 0; write `/root/g01-marker-<hex>`, `/etc/g01-marker-<hex>` and a line to `/etc/profile.local`; `sync`; kill QEMU (unclean).
- Boot 3, label `serial persist`. Checks: both marker files exist with their content; `/proc/swaps` lists `/overlay/swapfile` (profile.local ran at login: the harness opens a login shell with `bash -l -c`); `e2fsck`-free check that the filesystem mounted without error (`dmesg | grep -c 'EXT4-fs error'` equals 0).
- A negative leg inside the same mode, boot 4: label `serial persist` with the disk detached (`-drive` omitted). Checks: output contains `no MONOLITH_PERSIST partition found`, `/overlay` is tmpfs, `persist: none` in the login status line. This proves the fallback message instead of leaving it undocumented (T-persist-race lives on the positive path).

### `persist-uefi` mode
OVMF + `-device virtio-blk-pci` with the same disk, formatted in-guest in boot 1 exactly as above but booted through GRUB. The GRUB `(persistent)` entry is the seventh entry (index 6) of `oracle/interfaces.yaml`; navigation uses G02's `select_grub_entry(index, title)` helper if G02 has landed, else the O01 pattern of counting Down presses with the index read from `interfaces.yaml`. The serial console is not present on the `(persistent)` entry (it carries only `persist`), so the mode waits for the shell on the always-spawned `ttyS0` getty (`inittab` line `s0`, see G02) and asserts `/proc/cmdline` ends with ` persist` and contains no `console=`; it does not wait for init milestones. Boot 2 of the mode is that GRUB boot; boot 1 formats via the `(serial)` entry. Checks mirror boot 2 and 3 above except the swap leg, which stays in the BIOS mode (one swap proof is enough). The hybrid-ISO UEFI boot from a USB-attached device is O02's `usb`.

### Documentation made exact
`topics/persist.txt`, README and `monolith-persist --help` are checked by `tests/fast/persist-docs-claims.test.sh`, which asserts: the help topic says there is no boot-time swapon; README states the `mkfs.ext4 -L MONOLITH_PERSIST` fallback and the `persist` label/entry names exactly as in `oracle/interfaces.yaml`; no file claims automatic swap. If a claim is changed later, the test and the modes change together.

### Fast tier
The stub-based `monolith-persist.test.sh` is kept and ported unchanged (`tests/fast/monolith-persist.test.sh`), so the unit contract (prompt text, `--yes`, error exits, swap validation) stays; real mkfs/mkswap/mount behaviour is the slow modes' job. Mode logic (state machine, argv, expected strings) is fast-tested on recorded transcripts via O01's fake QEMU.

## Traps and doctrines preserved
- **T-persist-race:** the labelled disk probes about 0.2 s after the CD and the detection must poll. Prevented by G01-AC-3 and G01-AC-5 (boot 2 of both modes finds the disk with the label on a device the guest, not the host, formatted).
- **T-console-home:** history and `~` land in `/` if `HOME` is wrong. Prevented by G01-AC-3 (`/root/…` marker and `profile.local` land in the persisted tree).
- **T-initrd-busybox-missing-applets:** the init scan used applets missing in the initramfs. Prevented by G01-AC-3 (the scan must find a freshly in-guest-formatted device) and G01-AC-6 (negative leg shows the scan terminates).
- **D-state-and-no-hidden-stderr:** the predecessor's persist detection hid failures for six commits. Prevented by G01-AC-6, which requires the explicit failure message when no disk is present, and by O01's lint on `oracle/`.
- **DEC-gui-doctrine (swap-on-persist):** the 8 MB GUI relies on swap. Prevented by G01-AC-4 (a real swapfile from the real tool enables).
- **Promise-versus-test (SPEC §1):** every persistence sentence is either proved or removed. Prevented by G01-AC-8.

## Gate
- **G01-AC-1** — `persist-init` and `persist-uefi` are registered in `oracle/modes.yaml` with `node: G01`, RAM and `job_timeout_minutes`, and the generated argv equals the golden files (blank virtio-blk disk, no host `mkfs`, no `-snapshot`). *Verify:* `tests/fast/test_persist_modes.py::test_registry`, `::test_argv_golden`. *Tier:* fast.
- **G01-AC-2** — A blank 128 MB disk with no filesystem is created by the mode without host `mkfs.ext4`, and `blkid` in the guest finds nothing on it before `init`. *Verify:* `tests/fast/test_persist_modes.py::test_blank_disk` (file size, all-zero first MiB) and slow leg `oracle / boot (persist-init)` check `blkid` exit 2. *Tier:* fast + slow.
- **G01-AC-3** — In the guest, `monolith-persist init /dev/vda --yes --swap 16` exits 0, the device then reports `LABEL="MONOLITH_PERSIST"` and `TYPE="ext4"`, and the swapfile at the filesystem root is exactly 16777216 bytes, mode 600. *Verify:* CI leg `oracle / boot (persist-init)`, boot 1; transcript replay in `test_persist_modes.py::test_boot1_checks`. *Tier:* slow (+ fast replay).
- **G01-AC-4** — On boot with `persist`, `/overlay` is ext4 on the formatted device, `swapon /overlay/swapfile` exits 0 and `/proc/swaps` lists it, and the `profile.local` recipe from the help topic makes it appear again after the next boot. *Verify:* CI leg `oracle / boot (persist-init)`, boots 2 and 3. *Tier:* slow.
- **G01-AC-5** — Files written outside the home directory (`/root/…`, `/etc/…`) survive an unclean power-off (QEMU killed after `sync`) and are present with identical content on the next persist boot; the filesystem logs no `EXT4-fs error`. *Verify:* CI leg `oracle / boot (persist-init)`, boot 3; `persist-uefi` leg for the UEFI/GRUB path. *Tier:* slow.
- **G01-AC-6** — With `persist` requested and no labelled disk, the guest prints `no MONOLITH_PERSIST partition found`, `/overlay` is tmpfs, and the login status line reads `persist: none`. *Verify:* CI leg `oracle / boot (persist-init)`, boot 4. *Tier:* slow.
- **G01-AC-7** — The GRUB `(persistent)` entry boots (UEFI, OVMF) to a shell on `ttyS0`, its `/proc/cmdline` ends with `persist`, and `/overlay` is ext4 on the formatted device. *Verify:* CI leg `oracle / boot (persist-uefi)`. *Tier:* slow.
- **G01-AC-8** — README, `topics/persist.txt` and `monolith-persist --help` make no persistence claim the modes do not prove: no automatic swap, label and entry names equal `oracle/interfaces.yaml`, the fallback behaviour is stated. *Verify:* `tests/fast/persist-docs-claims.test.sh`. *Tier:* fast.
- **G01-AC-9** — The predecessor unit tests for `monolith-persist` (init prompt, `--yes`, bad `--swap`, missing `mkfs.ext4`, swapfile creation order) and the profile/bashrc hooks pass unchanged against the carried scripts. *Verify:* `tests/fast/monolith-persist.test.sh`, `monolith-persist-profile.test.sh`, `monolith-persist-bashrc.test.sh`. *Tier:* fast.
- **G01-AC-10** — Both modes complete within their `job_timeout_minutes` on the CI runner, with the three (four) boots recorded in the result JSON, and a boot that never reaches `/init` is retried only per O01's discriminator. *Verify:* result JSON from the CI legs; `tests/fast/test_oracle_retry.py` matrix includes `persist-init` boot 2 silent. *Tier:* slow + fast.

## RED plan
First `test_persist_modes.py` (imports `oracle.modes.persist_init`, absent; includes the transcript-replay of the four boots using synthetic fixtures that show the expected strings), then `persist-docs-claims.test.sh` (fails if README or the topic still implies otherwise; the topic already says "no boot-time swap" so the failing part is README's missing fallback sentence and the interfaces cross-check). The slow legs are red until the mode exists; the first CI run against the real ISO is expected to expose real defects (see Risks).

## Risks and open questions
- Hardest: this mode has never run, so it may find real bugs: `mkfs.ext4`, `mkswap` or `swapon` may be missing or dynamic on the rootfs (`sys-fs/e2fsprogs` and `util-linux` are in the world, but D-all-static is untrue and OD-2 may change what ships), `fallocate` may be absent so the `dd` fallback runs slowly under TCG for 16 MB, or the `persist` scan may fail when the label lives on a disk not scanned by the `/dev/vd*` loop. A defect means a fix inside this PR (`monolith-persist`, init) or a README claim removed, never a weakened assertion.
- The init scan reads each block device through `cat | tr | grep -q MONOLITH_PERSIST`, so any device whose raw bytes contain that string matches (the init code's own comment at `rootfs/init:470-476` excludes loop and sr for that reason). A disk that merely contains the ISO would match; tests do not cover it and the risk is accepted.
- Swap on a file on ext4 under an overlay may fail (`swapon: ... Invalid argument`) if the file has holes; `fallocate` preallocates, the `dd` fallback writes zeros. The mode asserts success, so a failure is reported, not skipped.
- The 64 MB leg (swap on a small-RAM machine, where it matters) is deferred until the first run shows the 128 MB timing; if cheap, add it as `persist-init-64` without changing ACs.
- `persist-uefi` on a GRUB entry that has no `console=` relies on the `ttyS0` getty: this is G02's central assumption, shared here.
- Unknown: how long `mkfs.ext4` of 128 MB takes under TCG i486 emulation (predecessor never ran it in the guest). Budget: allow 120 s for the `init` step.

## Cost
Three agent slices: (1) `blank_disk`, `persist_init` mode, fast tests and fixtures; (2) `persist_uefi`, docs-claims test, doc edits; (3) fixing whatever the first real runs find. CI: about three build-plus-boot cycles expected (first run exposes defects; each fix is a cycle); each persist leg is 10-20 minutes of TCG time. No money beyond runner minutes.

## Spec defects found
- O01-AC-13 requires `oracle/modes.yaml` to list exactly the 17 SPEC §7 modes. Every G node adds modes (`persist-init`, `persist-uefi`, and those of G02-G05). Amend O01-AC-13 to "the 17 inherited modes plus any mode with a `node:` of G01-G05".
- SPEC §7 says the slow tier has "the 17 boot modes inherited"; G nodes make it more. State that phase G modes are additive and part of the oracle for X01.
- graph.yaml: X01 does not depend on any G node, so cutover can happen with promises (SPEC §1: "a behaviour the README promises and no test proves is a gap") still untested. Add G01-G05 to X01's deps, or record an explicit owner waiver per G node.
- The `GRUB (persistent)` entry cannot be observed through init milestones (no `console=ttyS0`). G01 and G02 both rely on the `inittab` serial getty (`s0:2345:respawn:… ttyS0 115200 vt100`, `scripts/build-rootfs.sh:359-360`) to reach a shell. R05/B04 must keep that line, and `oracle/interfaces.yaml` should name it as part of the harness interface.
