# G01 — claims-coverage

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | O01, B03 | X01 | — | L |

**Owns:** four new modes in `scripts/boot-test.py` (`persist-init`, `entry`, `serial-net`, `smoke`) and their jobs in `.github/workflows/boot-test.yml`, `scripts/smoke-checks.txt`, `docs/evidence/hyperv-<date>.md` (if OD-7 says evidence), README edits, `scripts/tests/readme-claims.test.sh`, `scripts/tests/smoke-coverage.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** the predecessor `README.md`'s promises, each with the test that proves it; a promise with no test is not ported. It extends `scripts/boot-test.py` using the ported `run_check`, `wait_for_shell`, `select_isolinux_label` and GRUB navigation (`:732-782`), and the ported `build_persist_cmd` for the disk handling.
**Study refs:** oracle.yaml gaps (ISOLINUX labels and GRUB entries never selected; Hyper-V; SLIP/PPP/dropbear; persistence only on a host-formatted disk); doctrine T-hyperv-old-grub, T-isolinux-timeout, T-grub-initrd-same-line; SPEC §1 (a README promise that no test proves is a gap); OD-7.

## Purpose
After this node every promise the README makes is either tested in a boot mode or removed from the README. The predecessor tested four label choices, the GRUB `(serial)` entry, history survival on a host-formatted disk, and nothing about Hyper-V, SLIP, PPP, dropbear or most packages.

## Standard mechanism
Existing QEMU options (`-drive`, `-serial`, `-chardev`) and the ported harness; no new framework. `sfdisk` on the runner makes the test disk's partition table. In the guest, the tools the README names are used as written. Custom code: only mode functions in `boot-test.py` and one text table, `smoke-checks.txt`. Gap: no tool tests a live ISO against its README. No manifest schema, evaluator or lint library: a plain table read by one shell loop in the guest is enough.

## Tests
- **Ported first:** none of its own. The boot modes O01 ported already prove some README promises, and they stay as they are.
- **Added:** `scripts/tests/readme-claims.test.sh`, `scripts/tests/smoke-coverage.test.sh` and the four new modes.
- **Baseline:** `b9f533b`'s README fails `readme-claims.test.sh` on its untested promises, as expected.

## Changes from the port
Claims, with README line numbers at b9f533b, and what happens to each.

| Claim | README | Disposition |
|---|---|---|
| `persist` label; `MONOLITH_PERSIST` partition; `monolith-persist init /dev/sdXN [--swap N]`; fallback to tmpfs when absent (`topics/persist.txt`) | 151 | Mode `persist-init`: blank virtio disk with one partition made by `sfdisk` on the host; boot 1 runs `monolith-persist init --yes /dev/vda1 --swap 16`; boot 2 (`serial persist`) sees `/overlay` ext4, a marker file, `swapon /overlay/swapfile` works; boot 3 without the disk prints the fallback warning. Proved by AC-1. |
| Every ISOLINUX label `linux fb fb800 fb640 vga serial debug persist rescue` | 142-152 | Mode `entry --loader isolinux --label L`, one matrix leg per label: boots to a shell (extra `console=ttyS0,115200n8` typed after the label where the label has none) and `/proc/cmdline` has the label's parameters. Proved by AC-2. |
| GRUB entries normal, framebuffer, serial, debug, rescue, toram, persistent | 154 | Mode `entry --loader grub --index N` (UEFI, OVMF): same checks; `(toram)` also ejects the media. Proved by AC-2. |
| Hyper-V paravirtual drivers; hybrid layout "targets Hyper-V Gen 1" | 167 | OD-7. Default: a dated manual evidence file (hypervisor version, generation, serial or screenshot of a shell). A fast test fails if the README mentions Hyper-V and no evidence file is dated. Without evidence the sentence is reworded to "not tested on Hyper-V" and the layout claim is dropped. A second fast grep checks the `CONFIG_HYPERV*` symbols the sentence implies are `=y` or `=m` in the savedconfig. Proved by AC-3. |
| SLIP via `slattach -l -p slip /dev/ttyS0` | 291-292 | Mode `serial-net` links a pseudo-terminal pair made with `socat` in one guest and brings up SLIP across it; if the pair cannot carry SLIP, two guests joined by a `-chardev socket` serial link are used. The README example is corrected to the tested command (it names the console port). Proved by AC-4. |
| `pppd` and `chat`; "PPPoE" | 93, 294-295 | PPP is brought up over the same link with `pppd` and `chat` against a fake modem. PPPoE is removed from the README: pppd is built `--disable-plugins` (`ppp-no-plugins.conf`) and PPPoE needs a plugin. The example `pppd /dev/ttyS0 115200 noauth` sets no addresses; the corrected line is the tested one. Proved by AC-4. |
| Dropbear "start it with `dropbear`"; S20keygen "RSA and ECDSA" | 94, 298 | `serial-net` mode also runs `dropbear`, connects with a host `ssh` over a forwarded port using a key, and checks the host key. `S20keygen` writes only an ECDSA key (`build-rootfs.sh:598-603`), so the README says ECDSA. Proved by AC-5. |
| The package set (99 atoms) | 69-111 | Mode `smoke` runs `scripts/smoke-checks.txt` in the guest, one row per world atom: `atom<TAB>command<TAB>regex`. Libraries and metapackages get `n/a <reason>` rows. Proved by AC-6. |

Other changes:
1. The README "Testing" section (`README.md:327-345`) lists the modes that exist, after this node. Proved by AC-7.
2. New modes run first on the rc1 ISO. A failure is a product bug (fix in a recipe with a revbump, R02) or a wrong claim (remove it); each failing row is recorded with the decision.

## Gate
- **G01-AC-1** — `persist-init` passes: init on a blank partition, `/overlay` is ext4 on `/dev/vda1`, a marker written in boot 2 is present after an unclean kill and a third boot, `swapon /overlay/swapfile` succeeds, and boot 3 without the disk shows the fallback warning. *Verify:* CI leg `persist-init`. *Tier:* slow.
- **G01-AC-2** — Each ISOLINUX label and each GRUB entry has a green `entry` leg that boots to a shell with the expected `/proc/cmdline`. *Verify:* CI matrix `entry`. *Tier:* slow.
- **G01-AC-3** — The README contains no Hyper-V sentence without a dated file under `docs/evidence/`, and no sentence claiming Hyper-V Gen 1 targeting; the `HYPERV` symbols are present in the savedconfig. *Verify:* `bash scripts/tests/readme-claims.test.sh`. *Tier:* fast.
- **G01-AC-4** — `serial-net` brings up SLIP and PPP (through `chat`) and passes a `ping` over each; a `chat` expecting a string that never arrives fails. *Verify:* CI leg `serial-net`. *Tier:* slow.
- **G01-AC-5** — Dropbear starts on request, a host `ssh -i` login runs `id`, and the README names the host key type the guest actually has. *Verify:* CI leg `serial-net`; `readme-claims.test.sh` for the text. *Tier:* slow.
- **G01-AC-6** — Every world atom has a row in `smoke-checks.txt`, and the `smoke` mode passes with every non-`n/a` row matching. *Verify:* `bash scripts/tests/smoke-coverage.test.sh` (atoms versus rows), CI leg `smoke`. *Tier:* fast and slow.
- **G01-AC-7** — Every mode named in the README exists in `boot-test.py`'s mode list, and the README does not mention PPPoE. *Verify:* `bash scripts/tests/readme-claims.test.sh`. *Tier:* fast.

## Risks
- Whether a pty pair carries SLIP (line discipline on a pty) is unverified; the two-guest fallback costs a second QEMU and a harness rule on serial starvation (T-nat-router-serial-starvation).
- GRUB entries other than `(serial)` have no serial console. Reaching a shell needs `console=ttyS0` added through the GRUB editor (`e`); whether the harness can drive that reliably is unverified. The `inittab` ttyS0 getty (`build-rootfs.sh:359-360`) is relied on.
- `sfdisk`, `mkfs.ext4`, `mkswap` and `swapon` must exist on the disc and run; D-all-static is untrue in rc1, so a dynamic binary may matter (O02, R03).
- OD-7: real Hyper-V evidence is a human task outside CI. If the owner has no host, the claim is dropped.
- About 99 smoke rows is the largest piece; rows are one line each. Mark rows for GUI-only or interactive packages `n/a covered by gui mode`, not by a new fixture.
- New modes add CI minutes; they run in parallel with the existing 17.
