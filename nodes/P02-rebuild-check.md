# P02 — rebuild-check

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| critical | P01 | M01, X01 | MS2 | M |

**Owns:** `.github/workflows/rebuild-check.yml`, `docs/known-differences.md`, `scripts/tests/rebuild-check.test.sh`.
**Ports from linux-live-iso-factory@b9f533b:** nothing. The predecessor had no rebuild check. Its partial measures are reused as they are: `SOURCE_DATE_EPOCH` for the initrd (`build-initrd.sh:343-353`), mksquashfs (`build-rootfs.sh:721`) and the binpkg pack (`binpkg-store.sh:391`).
**Study refs:** build.yaml hazards `nondeterminism` (initrd cpio, symlink mtimes, ISO date flags, parallel emerge, docker commit); T-mksquashfs-sde; D-supply-chain-honesty; SPEC §1 "Reproducibility", §7.

## Purpose
After this node, anyone can rebuild a published release from `release-inputs.json` and the release's archived inputs alone, and compare the result with the published ISO. Every difference is written down with a cause. This closes MS2.

## Standard mechanism
`diffoscope` compares the two ISOs, recursing into the squashfs, initrd and kernel. Its exit code and `--text` output are the whole comparison. Custom code: none. v0.3's comparison schema, ratchet tool and expiry rules are dropped. The "list only shrinks" rule is a review rule on `docs/known-differences.md` (the owner reviews it), not a program or an acceptance criterion. Considered and not adopted: a hand-written layer-hash comparer. diffoscope already shows what differs, and a comparer would be code to maintain.

## Changes from the port
There is no ported code. The new workflow does the following, and nothing else.

1. **Inputs come only from the release.** `workflow_dispatch` takes a tag. The job downloads `release-inputs.json` and the ISO from that release. It checks out `source_commit` from the file. It pulls the builder by `BUILDER_DIGEST`, the tree by `TREE_DIGEST` (I02's restore) and the distfiles artifact by its recorded digest. It sets `SOURCE_DATE_EPOCH` from the file. It builds with `MONOLITH_USEPKG=n` and no binpkg pull. *AC-1.*
2. **No upstream fetches by Portage.** `DISTDIR` is filled from the distfiles artifact and `FETCHCOMMAND` and `RESUMECOMMAND` are set to `/bin/false` in the rebuild's `make.conf`. A missing distfile fails the build and names the file. *AC-2.*
3. **Comparison.** `diffoscope --html-dir` and `--text` of the rebuilt ISO against the published one, uploaded as artifacts. The step records the exit code and does not fail on a difference. It fails if the rebuild itself fails. *AC-3.*
4. **Known differences.** `docs/known-differences.md` lists each difference class with a cause and a pointer to an issue, or says "identical". MS2 needs this list to be complete, not empty. A workflow step fails if diffoscope reports a file path the document does not mention. *AC-4.*

## Gate
- **P02-AC-1** — `rebuild-check.yml` reads the builder digest, tree digest, distfiles digest, source commit and `SOURCE_DATE_EPOCH` from `release-inputs.json` and from no other file in the working tree. *Verify:* `scripts/tests/rebuild-check.test.sh` (greps the workflow for the field names and for any `Dockerfile` or `Makefile` pin read). *Tier:* fast.
- **P02-AC-2** — A rebuild with one distfile removed from the archive fails naming that file, and does not fetch it. *Verify:* CI run on a copy of the `v0.2.0-rc1` distfiles artifact with one file deleted; the log shows the `FETCHCOMMAND` failure. *Tier:* slow.
- **P02-AC-3** — The workflow ran for `v0.2.0-rc1`, built every package from source, and uploaded the diffoscope report. *Verify:* run URL in the PR table; the artifact exists. *Tier:* slow.
- **P02-AC-4** — Every path in the diffoscope text report for `v0.2.0-rc1` appears in `docs/known-differences.md` with a cause, and the workflow fails otherwise. *Verify:* `scripts/tests/rebuild-check.test.sh` (fixture report with a listed and an unlisted path); the rc1 run. *Tier:* fast + slow.

## Risks
- Known sources of difference from the study, not yet observed: initrd cpio without `--reproducible` and symlink mtimes not clamped (`build-initrd.sh:352-353`); ISO built without explicit date flags (`build-iso.sh`); `grub-mkstandalone`, `mkfs.vfat` and `mcopy` timestamps; mksquashfs needs 4.5+ to honour `SOURCE_DATE_EPOCH`; the `acct-user/dnsmasq` UID race that once dropped dnsmasq (`extract-packages.sh:91-107`); parallel emerge changes build ids. I did not re-check these in the code. The first run decides which are real.
- Offline is not complete: `rl144` and `stele` run `cargo` with network (`RESTRICT=network-sandbox`, `rl144-0.1.0_p20260805.ebuild:31`, `stele-0.1.0_p20260821.ebuild:34`) and the builder carries a rustup toolchain. Crates are in no archive. P02 allows network for those two, logs what they fetch, and lists crates as a known input gap. Vendoring is a later change.
- The builder runs syft and grype, installed from `main` of anchore's install script (`Dockerfile:129-131`), so their versions are only recorded, not pinned. Not an ISO input, but it can change the SBOM.
- diffoscope on a 200 MiB ISO may need more memory than a hosted runner has (unverified). A fallback is `cmp` plus diffoscope on the squashfs alone.
- If the ISO comes out identical, MS2 still needs the list to say so.
