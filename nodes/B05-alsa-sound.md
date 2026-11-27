# B05 — alsa-sound

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | B01, B04, O01, R01 | B06 | — | M |

**Owns:** the sound symbols of change 1 in `configs/portage/savedconfig/sys-kernel/monolith-kernel` (B02 owns the file), the `media-libs/alsa-lib` and `media-sound/alsa-utils` lines of `configs/portage/world` and `configs/portage/versions.lock` (B01 owns the files) and the static-build settings they need under `configs/portage/package.use/`, `package.env/` and `env/` (R03 owns the static hooks), `/etc/asound.conf` and the mixer step at boot in `configs/overlay/app-misc/monolith-base/` (change 3; R01 owns the package, revbumped), the two rows of `scripts/smoke-checks.txt` (G01 owns the file), the `sound` mode of `scripts/boot-test.py` (O01 owns the rest of the file), `sound` in the `Makefile`'s `BOOT_MODES` and in the `boot-test` job's `modes:` list of `.github/workflows/build.yml`, the sound section of `docs/kernel-tiers.md`, the B05 row of `docs/capabilities.md`, `scripts/tests/sound.test.sh`, `scripts/fixtures/B05/`.
**Resolves:** #130
**Ports from linux-live-iso-factory@b9f533b:** none. The predecessor had no sound.
**Study refs:** D-486-minimalism, D-all-static, D-no-dynamic-loading-no-dlopen, D-486-tier-regime, D-hand-authored-rootfs-files-owned, D-revbump-on-overlay-change, T-ddc-i2c-escalation; issue #130 section 3, measured on 86Box with a Sound Blaster 16 (0x220, IRQ 5, DMA 1/5) and a recorded, tone-checked output.

## Purpose
The disc has no sound. After this node the kernel has ALSA, with the sound drivers of 486-era ISA cards, PCI cards and modern machines as modules, so coldplug loads only what a machine has. Static `alsa-lib` and `alsa-utils` are in `world`, and `/etc/asound.conf` makes dmix the default device at 44.1 kHz, so every client shares the card at the rate old cards top out at. Mixers come up audible. A `sound` boot mode proves that QEMU's SB16 is found and that two clients play at once, both heard in the recording, and the 16 MB `lowmem` mode still passes.

## Standard mechanism
- **Kernel:** ALSA in kbuild, on B04's savedconfig; drivers as modules, loaded by the ported coldplug for PnP and PCI cards. A jumpered (non-PnP) ISA card takes module options (`options snd-sb16 isapnp=0 port=0x220 irq=5 dma8=1 dma16=5`), the standard `modprobe.d` mechanism.
- **Userland:** Gentoo's `media-libs/alsa-lib` (its built-in PCM plugins, dmix and plug) and `media-sound/alsa-utils` (`aplay`, `amixer`, `alsactl`, `speaker-test`), built static by the R03 means. The default device is ALSA's own configuration file, `/etc/asound.conf`. dmix uses SysV IPC (`CONFIG_SYSVIPC=y` is set).
- **Mixers:** `alsactl` (`restore`, which initialises a card that has no saved state).
- Custom code: none new. One mode in `boot-test.py` and a tone check on the recorded wav (host-side Python), one test, `scripts/tests/sound.test.sh`.

## Tests
- **Ported first:** none.
- **Kept unchanged:** B02's tier tests and `verify-resolved-i2c-off.test.sh`, B04's `scripts/tests/lowmem.test.sh`, G01's `scripts/tests/smoke-coverage.test.sh`, R01's monolith-base tests, O02's static audit.
- **Added:** `scripts/tests/sound.test.sh`, offline in the toolbox, with fixtures in `scripts/fixtures/B05/`: the kernel symbols of AC-1 (a fixture with a driver `=y` or `SND` unset fails), the `asound.conf` of AC-3 (a fixture with another rate or slave fails), the `world` and `versions.lock` lines, and the tone check of AC-5 on planted wav files (two tones found; one tone missing, silence, or the tones one after the other and never together, each fail).
- **Baseline:** on `main` `SOUND` is not set, no ALSA package is in `world` and there is no `asound.conf`, so AC-1 to AC-5 fail; rc1's ISO has no sound and fails the `sound` mode, which rc1's lane does not run.

## Changes from the port
1. **The kernel.** Built in: `SOUND`, `SND`, `SND_PCM`, `SND_TIMER`, `SND_PROC_FS`. Modules (`=m`): ISA `SND_SB16`, `SND_SBAWE`, `SND_SB8`, `SND_ES18XX`, `SND_CS4231`, `SND_CS4236`, `SND_AD1816A`, `SND_GUSCLASSIC`, `SND_GUSMAX`, `SND_OPL3SA2`; PCI `SND_ENS1370`, `SND_ENS1371`, `SND_CMIPCI`, `SND_VIA82XX`, `SND_INTEL8X0`, `SND_HDA_INTEL`; USB `SND_USB_AUDIO`. Through `scripts/config` and `olddefconfig`, as B04. B02's checks pass; a sound option that selects `I2C` built in is forced off (T-ddc-i2c-escalation). `docs/kernel-tiers.md` lists the drivers as Tier 2 and gives the jumpered SB16's options line. *AC-1.*
2. **The packages.** `media-libs/alsa-lib` and `media-sound/alsa-utils` join `world` and `versions.lock` at the pinned tree's versions, built static (no `.so`, no plugin directory). Each gets a `run` row in `smoke-checks.txt` (`aplay --version`, `amixer --version`). The licence, unowned and artifact checks pass. *AC-2.*
3. **The default device and the mixers.** `monolith-base` installs `/etc/asound.conf`, issue #130's text: `pcm.!default` a `plug` over `pcm.mixed`, a `dmix` with `ipc_key 1024`, `ipc_perm 0666` and a slave of `hw:0,0` at `rate 44100`, `channels 2`, `format S16_LE`, `period_size 1024`, `buffer_size 4096`; `ctl.!default` the `hw` of card 0. Its boot path runs `alsactl restore` once the cards are up, so a card comes up unmuted at the driver's or the saved levels. The package is revbumped. *AC-3.*
4. **The `sound` mode.** `boot-test.py --mode sound` boots the `bios` machine at 64 MB with `-audiodev wav,id=snd,path=<out>.wav -device sb16,audiodev=snd`. In the guest it loads `snd-sb16` with QEMU's jumpered settings (`isapnp=0 port=0x220 irq=5 dma8=1 dma16=5`; QEMU's SB16 is not PnP), requires the card in `/proc/asound/cards`, and starts two clients at once on the default device, a sine at 440 Hz and one at 660 Hz (`speaker-test -t sine`), each for at least 2 s; both must exit 0. After poweroff the host finds both tones in the wav, sounding together for at least 1 s. `sound` joins `BOOT_MODES` and the `boot-test` job's `modes:` list. *AC-4, AC-5.*

## Gate
- **B05-AC-1** — The savedconfig has `SOUND`, `SND`, `SND_PCM`, `SND_TIMER` and `SND_PROC_FS` built in and every driver of change 1 `=m`; B02's tier tests pass and `verify-resolved-i2c-off.sh` passes on the node PR's resolved config. `docs/kernel-tiers.md` lists the sound drivers as Tier 2 with the jumpered SB16's options line. *Verify:* `scripts/tests/sound.test.sh` with `scripts/fixtures/B05/`; the `verify-*-config.sh` tests via `make test`; the node PR's Build run.
- **B05-AC-2** — `world` and `versions.lock` have `media-libs/alsa-lib` and `media-sound/alsa-utils`. On the node PR's ISO, `aplay`, `amixer`, `alsactl` and `speaker-test` are static `EM_386` binaries, no ALSA `.so` file or plugin directory ships, and the licence, unowned and artifact checks pass. `smoke-checks.txt` has a row for each atom, and the `smoke` mode passes. *Verify:* `scripts/tests/sound.test.sh`; `scripts/tests/smoke-coverage.test.sh`; the node PR's Build run (`test-artifact`, `test-gates`, `smoke`).
- **B05-AC-3** — The rootfs's `/etc/asound.conf` is owned by `monolith-base` and has the text of change 3; `monolith-base` has a new revision. *Verify:* `scripts/tests/sound.test.sh` (the file's text; a fixture with `rate 48000` fails); `make test-revbump`; the node PR's Build run (unowned gate).
- **B05-AC-4** — In the `sound` mode on the node PR's ISO, `/proc/asound/cards` lists the SB16, `amixer` shows its Master and PCM controls unmuted after boot, and both clients exit 0 while they play at once. *Verify:* the node PR's Build run (`sound` leg), its log lines in the node PR.
- **B05-AC-5** — The wav recorded in that run holds a 440 Hz and a 660 Hz tone sounding together for at least 1 s. The tone check passes on a planted two-tone wav and fails on a wav with one tone, on silence and on two tones that never overlap. *Verify:* `scripts/tests/sound.test.sh` (planted wavs); the node PR's Build run (`sound` leg).
- **B05-AC-6** — Every other boot mode passes on the node PR's ISO, `lowmem` at 16 MB included. *Verify:* the node PR's Build run with `full-ci`.

## Risks
- **Memory at 16 MB.** ALSA core built in adds to the kernel's resident size; AC-6 keeps the `lowmem` mode green. If it no longer fits, the node stops and asks the owner (ALSA core as modules instead is the candidate).
- **Static alsa-lib.** Whether Gentoo's `alsa-lib` builds static for i486 musl with its PCM plugins built in and no `dlopen` of external plugins is unverified; the issue's prototype built 1.2.16.1 static. Each static binary carries all of alsa-lib (about 630 KB each).
- **QEMU's wav audiodev** under TCG may drop or stretch samples on a slow runner; the tone check looks for overlap in time, not for exact timing. The issue's CPU figures came from 86Box at real speed and are not criteria.
- **OSS emulation** (`/dev/dsp`) opens the card directly and gets `EBUSY` while dmix holds it. Clients use ALSA; this node adds no OSS.
- **A frozen test that lists the boot modes** (O01's or G01's) may need the new mode. If one does, the node stops and asks the owner before changing it, naming the lines.
