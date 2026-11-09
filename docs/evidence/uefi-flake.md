# uefi-flake: the diagnosis record of issue #46

Issue #46: in CI, the `uefi` boot of a `build.yml` ISO failed twice in seven boots. Both times
`perl /usr/lib/cgi-bin/guestbook.cgi` exited 255 while compiling
`/usr/lib/perl5/5.42.0/i486-linux/Config.pm` ("character \x80; marked by <-- HERE … line 1"). The
`CGI.pm param()` check just before it, which loads the same modules, passed. This file lists every CI
`uefi` boot of a built ISO from those seven to the end of O03-AC-5 and states the outcome (O03-AC-4).

## Outcome

**(b) Not reproduced.** Once change 1 was in place (a failing perl CGI check records the guest's
`sha256sum` of the six files it reads, the last 50 lines of `dmesg` and a second run of its
command), no CI `uefi` boot failed. That covers the 21 boots on the change-1 harness (rows 10–30) and
the one concurrent boot on another branch (row 31). Rows 11–30 are O03-AC-5's 20 consecutive passes. They
are on GitHub-hosted `ubuntu-24.04` runners, use two different `build.yml` ISOs (`5a39bd03…` from
main at 3bb3d80, `48b536a9…` from main at c003b14) and run through `boot-test-repeat.yml`. No failed
job was re-run. No cause was found, so no fix was made (change 4 does not apply), and #46 is closed as
not reproduced.

The 21 change-1 boots ran on five host CPU models: AMD EPYC 7763, AMD EPYC 9V74, AMD EPYC 9V45, Intel
Xeon Platinum 8370C and Intel Xeon Platinum 8573C. Before change 2 the host CPU was not recorded, so
the two failures (rows 2 and 4) cannot be tied to a CPU model. The spec's Risks apply: at the observed
rate (2 in 7) the chance of 20 passes in a row with the fault still present is about 0.1%, but at a
much lower true rate it is not. If a `uefi` boot fails again, its job log holds change 1's evidence
and its `tool-versions.txt` holds the CPU. Compare the hashes with `unsquashfs` of that run's
`squashfs-<run>` artifact, and #46 can be reopened from that record.

If such a failure comes, read the evidence this way. After a failing `guestbook.cgi` check, the second
run starts with `rm -f /tmp/guestbook.db` and inserts the row again, so the
`guestbook row independently verified via sqlite3 CLI` check that follows reflects the second run, not
the first.

## Boots

ISO sha256 values come from `sha256sum` of each run's `iso-<run>` artifact (`boot-test.iso`). Run
42428425660's ISO artifact is no longer listed, so its value is the `iso_sha256` of its
`attestation-<run>` artifact (`attestation-summary.json`). The runner CPU is the `model name` line of
the job's `tool-versions.txt` (change 2). For boots before change 2 it is "not recorded".

| # | Job | Workflow, ISO source | ISO sha256 | Runner CPU | Result | Note |
|---|---|---|---|---|---|---|
| 1 | [42416838904 a1](https://github.com/tuckermclean/themonolith/actions/runs/42416838904/job/128551472056) | `build.yml` (B03 PR), its own ISO | `0f7be3fcaeabf4a04fe7eb5dc375376967c543e33b2dabfd88f3dad1d814351c` | not recorded | pass | #46's seven |
| 2 | [42428425660 a1](https://github.com/tuckermclean/themonolith/actions/runs/42428425660/job/128588754286) | `build.yml` (B03 PR), its own ISO | `0e8e4573f3dafe86f1eac6a83ae7dc1f59020a4dcd929268deb8596d83beee16` | not recorded | **fail** (guestbook.cgi, Config.pm \x80) | #46's seven |
| 3 | [42428425660 a2](https://github.com/tuckermclean/themonolith/actions/runs/42428425660/job/128589657566) | `build.yml` re-run of failed jobs, same ISO | `0e8e4573f3dafe86f1eac6a83ae7dc1f59020a4dcd929268deb8596d83beee16` | not recorded | pass | #46's seven |
| 4 | [42428425660 a5](https://github.com/tuckermclean/themonolith/actions/runs/42428425660/job/128604973309) | `build.yml` re-run of failed jobs, same ISO | `0e8e4573f3dafe86f1eac6a83ae7dc1f59020a4dcd929268deb8596d83beee16` | not recorded | **fail** (guestbook.cgi, Config.pm \x80) | #46's seven |
| 5 | [42428425660 a6](https://github.com/tuckermclean/themonolith/actions/runs/42428425660/job/128608615664) | `build.yml` re-run of failed jobs, same ISO | `0e8e4573f3dafe86f1eac6a83ae7dc1f59020a4dcd929268deb8596d83beee16` | not recorded | pass | #46's seven |
| 6 | [42448686665 a1](https://github.com/tuckermclean/themonolith/actions/runs/42448686665/job/128648054946) | `build.yml` (B03 PR), its own ISO | `42bdde56874558c89013aa8fef229a1001c2005b11fc0075b16853cbc3e5709a` | not recorded | pass | #46's seven |
| 7 | [42502182433 a1](https://github.com/tuckermclean/themonolith/actions/runs/42502182433/job/128820298634) | `build.yml` (B03 PR), its own ISO | `c85e7efe861be8cb42a51f608d27c014c64e9d0721fb75ef440db463fde8dabf` | not recorded | pass | #46's seven |
| 8 | [42515033164 a1](https://github.com/tuckermclean/themonolith/actions/runs/42515033164/job/128854444749) | `build.yml` (main, 3bb3d80), its own ISO | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | not recorded | pass | before change 1 |
| 9 | [42524921857 a1](https://github.com/tuckermclean/themonolith/actions/runs/42524921857/job/128869790129) | `build.yml` (main, c003b14), its own ISO | `48b536a9cadbb4c8520149776342d5ef09bfd6c38672549a97154dee0fa4e46f` | not recorded | pass | before change 1 |
| 10 | [42526071144 boot 1](https://github.com/tuckermclean/themonolith/actions/runs/42526071144/job/128869949471) | `boot-test-repeat.yml` at 3b639b2, [build 42515033164](https://github.com/tuckermclean/themonolith/actions/runs/42515033164) | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | AMD EPYC 9V74 80-Core Processor | pass | changes 1, 2 (trial dispatch; not counted) |
| 11 | [42515033164 boot 1](https://github.com/tuckermclean/themonolith/actions/runs/42527963769/job/128875780894) | `boot-test-repeat.yml` at a6facdc, [build 42515033164](https://github.com/tuckermclean/themonolith/actions/runs/42515033164) | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | AMD EPYC 7763 64-Core Processor | pass | AC-5 #1 |
| 12 | [42515033164 boot 2](https://github.com/tuckermclean/themonolith/actions/runs/42527963769/job/128875780836) | `boot-test-repeat.yml` at a6facdc, [build 42515033164](https://github.com/tuckermclean/themonolith/actions/runs/42515033164) | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | INTEL(R) XEON(R) PLATINUM 8573C | pass | AC-5 #2 |
| 13 | [42515033164 boot 3](https://github.com/tuckermclean/themonolith/actions/runs/42527963769/job/128875780843) | `boot-test-repeat.yml` at a6facdc, [build 42515033164](https://github.com/tuckermclean/themonolith/actions/runs/42515033164) | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | AMD EPYC 9V45 96-Core Processor | pass | AC-5 #3 |
| 14 | [42515033164 boot 4](https://github.com/tuckermclean/themonolith/actions/runs/42527963769/job/128875780826) | `boot-test-repeat.yml` at a6facdc, [build 42515033164](https://github.com/tuckermclean/themonolith/actions/runs/42515033164) | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | AMD EPYC 7763 64-Core Processor | pass | AC-5 #4 |
| 15 | [42515033164 boot 5](https://github.com/tuckermclean/themonolith/actions/runs/42527963769/job/128875780822) | `boot-test-repeat.yml` at a6facdc, [build 42515033164](https://github.com/tuckermclean/themonolith/actions/runs/42515033164) | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | AMD EPYC 9V45 96-Core Processor | pass | AC-5 #5 |
| 16 | [42515033164 boot 6](https://github.com/tuckermclean/themonolith/actions/runs/42527963769/job/128875780847) | `boot-test-repeat.yml` at a6facdc, [build 42515033164](https://github.com/tuckermclean/themonolith/actions/runs/42515033164) | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz | pass | AC-5 #6 |
| 17 | [42515033164 boot 7](https://github.com/tuckermclean/themonolith/actions/runs/42527963769/job/128875780817) | `boot-test-repeat.yml` at a6facdc, [build 42515033164](https://github.com/tuckermclean/themonolith/actions/runs/42515033164) | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | AMD EPYC 9V74 80-Core Processor | pass | AC-5 #7 |
| 18 | [42515033164 boot 8](https://github.com/tuckermclean/themonolith/actions/runs/42527963769/job/128875780886) | `boot-test-repeat.yml` at a6facdc, [build 42515033164](https://github.com/tuckermclean/themonolith/actions/runs/42515033164) | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | AMD EPYC 9V74 80-Core Processor | pass | AC-5 #8 |
| 19 | [42515033164 boot 9](https://github.com/tuckermclean/themonolith/actions/runs/42527963769/job/128875780906) | `boot-test-repeat.yml` at a6facdc, [build 42515033164](https://github.com/tuckermclean/themonolith/actions/runs/42515033164) | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | INTEL(R) XEON(R) PLATINUM 8573C | pass | AC-5 #9 |
| 20 | [42515033164 boot 10](https://github.com/tuckermclean/themonolith/actions/runs/42527963769/job/128875780902) | `boot-test-repeat.yml` at a6facdc, [build 42515033164](https://github.com/tuckermclean/themonolith/actions/runs/42515033164) | `5a39bd03edb6b0d2ba0844d8e0b3c690f28cdb16c9d4f4fd76b70ddf246acdb0` | Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz | pass | AC-5 #10 |
| 21 | [42524921857 boot 1](https://github.com/tuckermclean/themonolith/actions/runs/42527967932/job/128875808789) | `boot-test-repeat.yml` at a6facdc, [build 42524921857](https://github.com/tuckermclean/themonolith/actions/runs/42524921857) | `48b536a9cadbb4c8520149776342d5ef09bfd6c38672549a97154dee0fa4e46f` | AMD EPYC 9V45 96-Core Processor | pass | AC-5 #11 |
| 22 | [42524921857 boot 2](https://github.com/tuckermclean/themonolith/actions/runs/42527967932/job/128875808873) | `boot-test-repeat.yml` at a6facdc, [build 42524921857](https://github.com/tuckermclean/themonolith/actions/runs/42524921857) | `48b536a9cadbb4c8520149776342d5ef09bfd6c38672549a97154dee0fa4e46f` | AMD EPYC 7763 64-Core Processor | pass | AC-5 #12 |
| 23 | [42524921857 boot 3](https://github.com/tuckermclean/themonolith/actions/runs/42527967932/job/128875808842) | `boot-test-repeat.yml` at a6facdc, [build 42524921857](https://github.com/tuckermclean/themonolith/actions/runs/42524921857) | `48b536a9cadbb4c8520149776342d5ef09bfd6c38672549a97154dee0fa4e46f` | AMD EPYC 7763 64-Core Processor | pass | AC-5 #13 |
| 24 | [42524921857 boot 4](https://github.com/tuckermclean/themonolith/actions/runs/42527967932/job/128875808697) | `boot-test-repeat.yml` at a6facdc, [build 42524921857](https://github.com/tuckermclean/themonolith/actions/runs/42524921857) | `48b536a9cadbb4c8520149776342d5ef09bfd6c38672549a97154dee0fa4e46f` | AMD EPYC 9V74 80-Core Processor | pass | AC-5 #14 |
| 25 | [42524921857 boot 5](https://github.com/tuckermclean/themonolith/actions/runs/42527967932/job/128875808928) | `boot-test-repeat.yml` at a6facdc, [build 42524921857](https://github.com/tuckermclean/themonolith/actions/runs/42524921857) | `48b536a9cadbb4c8520149776342d5ef09bfd6c38672549a97154dee0fa4e46f` | Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz | pass | AC-5 #15 |
| 26 | [42524921857 boot 6](https://github.com/tuckermclean/themonolith/actions/runs/42527967932/job/128875808779) | `boot-test-repeat.yml` at a6facdc, [build 42524921857](https://github.com/tuckermclean/themonolith/actions/runs/42524921857) | `48b536a9cadbb4c8520149776342d5ef09bfd6c38672549a97154dee0fa4e46f` | INTEL(R) XEON(R) PLATINUM 8573C | pass | AC-5 #16 |
| 27 | [42524921857 boot 7](https://github.com/tuckermclean/themonolith/actions/runs/42527967932/job/128875808831) | `boot-test-repeat.yml` at a6facdc, [build 42524921857](https://github.com/tuckermclean/themonolith/actions/runs/42524921857) | `48b536a9cadbb4c8520149776342d5ef09bfd6c38672549a97154dee0fa4e46f` | AMD EPYC 9V74 80-Core Processor | pass | AC-5 #17 |
| 28 | [42524921857 boot 8](https://github.com/tuckermclean/themonolith/actions/runs/42527967932/job/128875808866) | `boot-test-repeat.yml` at a6facdc, [build 42524921857](https://github.com/tuckermclean/themonolith/actions/runs/42524921857) | `48b536a9cadbb4c8520149776342d5ef09bfd6c38672549a97154dee0fa4e46f` | AMD EPYC 7763 64-Core Processor | pass | AC-5 #18 |
| 29 | [42524921857 boot 9](https://github.com/tuckermclean/themonolith/actions/runs/42527967932/job/128875808879) | `boot-test-repeat.yml` at a6facdc, [build 42524921857](https://github.com/tuckermclean/themonolith/actions/runs/42524921857) | `48b536a9cadbb4c8520149776342d5ef09bfd6c38672549a97154dee0fa4e46f` | AMD EPYC 7763 64-Core Processor | pass | AC-5 #19 |
| 30 | [42524921857 boot 10](https://github.com/tuckermclean/themonolith/actions/runs/42527967932/job/128875808769) | `boot-test-repeat.yml` at a6facdc, [build 42524921857](https://github.com/tuckermclean/themonolith/actions/runs/42524921857) | `48b536a9cadbb4c8520149776342d5ef09bfd6c38672549a97154dee0fa4e46f` | AMD EPYC 9V74 80-Core Processor | pass | AC-5 #20 |
| 31 | [42526785812 a1](https://github.com/tuckermclean/themonolith/actions/runs/42526785812/job/128876126991) | `build.yml` (R03 PR), its own ISO | `85c56ccf39e98a0830881acc6e6113999e4b345b2c33e6d3d8de01d7895d20c1` | not recorded | pass | another branch, before change 1; started 22:01:43Z, before AC-5's last boot ended (22:02:02Z) |

These are not boots and are left out of the table. Attempts 3 and 4 of run 42428425660 failed at
`download-artifact` before booting. Attempts 7 and 8 of that run, and attempt 2 of run 42502182433, list
the `uefi` job carried over unchanged from an earlier attempt: same steps, same start time, not run
again. The `boot-test-rc1.yml` runs boot rc1's published ISO, not a `build.yml` ISO.

## Runs

- AC-5: [42527963769](https://github.com/tuckermclean/themonolith/actions/runs/42527963769) (10 boots of build 42515033164's ISO) and
  [42527967932](https://github.com/tuckermclean/themonolith/actions/runs/42527967932) (10 boots of build 42524921857's ISO). Both were dispatched at a6facdc
  on `node/O03-uefi-flake`. Each run has one attempt, and every job's artifact
  `boot-test-uefi-<build>-<index>` holds its serial log and a `tool-versions.txt` with one
  `model name` line.
- Trial: [42526071144](https://github.com/tuckermclean/themonolith/actions/runs/42526071144) (1 boot, at 3b639b2).
