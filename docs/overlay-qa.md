# Overlay QA

`make test-overlay` runs `pkgcheck scan` of `configs/overlay` in the toolbox, with the pinned Gentoo tree
(restored by `sync-portage`) as the `gentoo` master and its `profiles/embedded` as the profile.
`scripts/overlay-qa.sh` compares the reported `<category>/<package> <Keyword>` pairs with the list below. A
reported pair that is not listed fails, and so does a listed pair that is no longer reported.

## Accepted warnings

```
app-misc/monolith-base BadDescription  # R01's ported DESCRIPTION is over 80 characters; shortening it changes the ebuild and needs a revbump that rebuilds monolith-base, so it goes with the next functional revbump
```

## AC-2: `pkgcheck scan --commits` against R04's fixture cases

Verdict: `scripts/check-revbump.sh` stays. `pkgcheck scan --commits` fails none of the 18 cases that R04 fails;
R04 and `make test-revbump` remain the revbump gate.

Run (2026-11-03, pkgcheck 0.10.49 in the toolbox, pinned tree as `gentoo` master): a scratch copy of
`scripts/tests/check-revbump.test.sh`, cut before its R04-AC-4 (Make and workflow) section, with `script=` pointing
at a wrapper `<base> <head>`. The wrapper made each fixture overlay loadable (`profiles/repo_name`,
`metadata/layout.conf` with `masters = gentoo`; the wrapper only), ran `pkgcheck scan --config no --cache no
--commits <base>` in it, and failed on any result or on pkgcheck failing. The control run, with
`check-revbump.sh` as `script=`, passed every case. The log is `out/node/R02/ac2.log`. pkgcheck exited 0 and
printed no result for every case, including each ebuild, `files/`, `Manifest` and eclass edit without a
revision, so its git check does not look for a missing revision in this layout (the overlay is the
subdirectory `configs/overlay` of the repository).

R04's expect-fail cases (all missed by pkgcheck):

| R04 case | R04 | pkgcheck |
|---|---|---|
| edited ebuild, no new ebuild | fails | missed |
| comment-only ebuild edit | fails | missed |
| edited file under `files/` | fails | missed |
| added file under `files/` | fails | missed |
| removed patch under `files/` | fails | missed |
| `Manifest`-only change | fails | missed |
| two packages, one bumped | fails | missed |
| eclass change, no inheritor bumped | fails | missed |
| eclass change, one of two inheritors bumped | fails | missed |
| rename into another package | fails | missed |
| deleting only a patch, ebuilds remain | fails | missed |
| deleting an ebuild while editing a patch | fails | missed |
| multi-line `inherit` found | fails | missed |
| conditional `inherit` found | fails | missed |
| `inherit` after `;` found | fails | missed |
| `inherit` after `${PV#9}` found | fails | missed |
| an ebuild under `files/` is not a bump | fails | missed |
| non-ASCII file name under `files/` | fails | missed |

R04's expect-pass cases pass under pkgcheck trivially, since it reports nothing.
