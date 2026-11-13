# Builder rebuild: rc1 against the rebuilt image

Two manifests of the builder image, one for rc1's image and one for the image rebuilt by `toolchain-bump.yml` from a
pinned stage3 and an archived Gentoo tree. This page explains every line in which they differ.

## The manifests

Both are the output of `make builder-manifest` (the `builder-manifest` artifact of a `build.yml` run), taken on an image
pulled by digest: `docker image inspect` of the image, the `qlist -Iv` package list, the cross gcc version, rustup's
active toolchain and the `syft`/`grype` versions.

| File | Run | Image |
| --- | --- | --- |
| `docs/builder-manifests/rc1.txt` | `build.yml` run 43351407499 on `main`, artifact `builder-manifest-43351407499` | rc1's image, `ghcr.io/tuckermclean/themonolith/builder@sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa` |
| `docs/builder-manifests/rebuilt.txt` | `build.yml` run 43460710322, artifact `builder-manifest-43460710322`, dispatched by `toolchain-bump.yml` run 43449403944 on its bump branch `toolchain/bump-20260810-20260810-d4d0b0c78bd9-43449403944-1` | the rebuilt image, `ghcr.io/tuckermclean/themonolith/builder@sha256:3f825cc695668cd70096b3fc14b5abfdf4d4888c299f313be71a8652fb0c3d13` |

The manifest of the `toolchain-bump.yml` run itself (`builder-manifest-43449403944`) is not used: it inspects the local
`monolith-builder` right after `docker commit`, whose `docker image inspect` has a different layout (`Descriptor`, no
`GraphDriver`), so it would mostly show the engine's inspect layout, not the image.

## The tree

rc1's builder bakes a Gentoo snapshot (`emerge-webrsync --revert=20260810`). Its `metadata/timestamp.commit` is
gentoo.git `3702b1b3eff1f563892525b8e3cad7670659b1a0` (2026-08-10T22:15:16Z, "dev-libs/expat: 2.8.3"); its
`timestamp.chk` is Tue, 11 Aug 2026 00:45:01 +0000.

The gentoo-mirror commit `d4d0b0c78bd9a3b0b81434268dd96e6f97b294cb` (2026-08-10T22:30:54Z) is the newest mirror commit
at or before that cut. It follows the mirror merge `3987ac2e` (22:30:47Z), whose second parent is `3702b1b3`. The next
mirror commit, `271d0fc4`, is at 01:15:49Z, after the cut.

Cross-check: 33060 of 33060 `*.ebuild`/`*.eclass` blobs of rc1's snapshot equal those of `d4d0b0c7`. The neighbours
differ: `8c116ba1` (before) lacks 1 file (`dev-libs/expat/expat-2.8.3.ebuild`), `d447f389` (after) adds `app-antivirus/clamav/clamav-0.103.12-r6.ebuild`, has `dev-python/pyqt6/pyqt6-6.11.0-r1.ebuild` in place of `pyqt6-6.11.0.ebuild`, and has a different blob for `games-emulation/pcsx2/pcsx2-2.6.3-r2.ebuild`. All 358 `qlist -Iv` entries of `rc1.txt`
have their ebuild at `d4d0b0c7`.

The tree is archived as `gentoo-tree:d4d0b0c7...`, digest
`sha256:05e24a4b8d0d2d2f15552ffb26b82db5c3cee5ccf25a86a2e60205c747022ad8` (the bump commit's `TREE_DIGEST_TOOLCHAIN`).

## The differences

`diff rc1.txt rebuilt.txt` is 78 lines. Each differing line, with its cause:

| Differing line | Cause |
| --- | --- |
| `"AttachStderr": false,` | rc1's image config records this field; the rebuilt image's config omits it, so `docker image inspect` shows the zero value (observed; mechanism unproven, see below) |
| `"AttachStderr": true,` | rc1's image config records this field; the rebuilt image's config omits it, so `docker image inspect` shows the zero value (observed; mechanism unproven, see below) |
| `"AttachStdout": false,` | rc1's image config records this field; the rebuilt image's config omits it, so `docker image inspect` shows the zero value (observed; mechanism unproven, see below) |
| `"AttachStdout": true,` | rc1's image config records this field; the rebuilt image's config omits it, so `docker image inspect` shows the zero value (observed; mechanism unproven, see below) |
| `"Created": "2026-08-15T00:25:50.854152837Z",` | time of the final `docker commit` of the crossdev container |
| `"Created": "2026-11-13T16:14:02.525845635Z",` | time of the final `docker commit` of the crossdev container |
| `"DockerVersion": "",` | rc1's image config records this field; the rebuilt image's config omits it, so `docker image inspect` shows the zero value (observed; mechanism unproven, see below) |
| `"DockerVersion": "28.0.4",` | rc1's image config records this field; the rebuilt image's config omits it, so `docker image inspect` shows the zero value (observed; mechanism unproven, see below) |
| `"Hostname": "",` | rc1's image config records this field; the rebuilt image's config omits it, so `docker image inspect` shows the zero value (observed; mechanism unproven, see below) |
| `"Hostname": "d9db719e260d",` | rc1's image config records this field; the rebuilt image's config omits it, so `docker image inspect` shows the zero value (observed; mechanism unproven, see below) |
| `"Id": "sha256:0ebb5f6f88c941f12c04aba5ec4a5a4164dd0ac65b854b9c9c396db91ab60089",` | image config digest; the config differs (creation time, history, layer diff_ids) |
| `"Id": "sha256:4aff9132817585bd5abb0a0f9c60c65f60c33f0432d3260b28385d2730f17668",` | image config digest; the config differs (creation time, history, layer diff_ids) |
| `"Image": "",` | rc1's image config records this field; the rebuilt image's config omits it, so `docker image inspect` shows the zero value (observed; mechanism unproven, see below) |
| `"Image": "monolith-builder-base-tools",` | rc1's image config records this field; the rebuilt image's config omits it, so `docker image inspect` shows the zero value (observed; mechanism unproven, see below) |
| `"LastTagTime": "2026-11-13T02:22:27.825887293Z"` | when the CI run tagged the pulled image `monolith-builder`; a property of the run |
| `"LastTagTime": "2026-11-13T16:16:58.301750565Z"` | when the CI run tagged the pulled image `monolith-builder`; a property of the run |
| `"LowerDir": "/var/lib/docker/overlay2/18396f4de8b3bbe5a131723e080cd8311c6c5db44747e79c86c27efc7dc20484/diff:/var/lib/docker/overlay2/a427473974ea3d4284b65ee1421d8c52ec0ed0576d8943e08f25fe28289d5c8f/diff:/var/lib/docker/overlay2/71f9c7942ce18f3a4b7e730aed4f2d2757ac3c1b9721bea5f4436330f081be0a/diff:/var/lib/docker/overlay2/f9a15e39145f65f8ca09088f933fb3336e70e143fbf20fc4c86c150d92aceae9/diff:/var/lib/docker/overlay2/70934c1aa6873827738a5139b475a96987300d9c634b9d6cef07e56da8781de9/diff:/var/lib/docker/overlay2/77e82a55ece3d4a5c52e20e71b9fb43f0e517ab0e76f95d9d94d16a7fa67da65/diff:/var/lib/docker/overlay2/829a74f62336bcd514b3eb91bfe6b143884525c2d72d5961e41e80fa620cc39f/diff:/var/lib/docker/overlay2/61fea92ecf98cea362c935d4a8153f82c9c06be3b61d5ae81e0f66ea54772c38/diff",` | overlay2 path on the runner that pulled the image; random per pull, not part of the image |
| `"LowerDir": "/var/lib/docker/overlay2/79c4f60e93830b180fbd9ddeb20ee58ad84e22716afc049f20fd18833f1fa176/diff:/var/lib/docker/overlay2/a52bce34bc0bdc17e192643fdfd350712f9f04779a0b2d00e6d076aca787cedd/diff:/var/lib/docker/overlay2/b2d21723777c1cfac4cff878956d11086fdd28d93ea85533dee74a90dc4032b6/diff:/var/lib/docker/overlay2/2db46d77a6761293b652ee8084792533eeb414ee015d837f21d2d9f4942760ce/diff:/var/lib/docker/overlay2/4acd11e4b967900b5c45aa479e41ddddfdb9471db57c60a5ba9e605ebfd0f0e4/diff:/var/lib/docker/overlay2/eb2511bc4a69a603ca65100bd5eb8fadfebc48302bb43e2226e266fb6216d3ee/diff:/var/lib/docker/overlay2/40bec3f21c3e79b4afaab06f5c8b66eb93a23cd7a7fbe685fbd017cd1c15bdfc/diff:/var/lib/docker/overlay2/32701c4501d2a375ed5f4a8c6632b9a44ff7dc2aa758e604435e167eb65a7208/diff",` | overlay2 path on the runner that pulled the image; random per pull, not part of the image |
| `"MergedDir": "/var/lib/docker/overlay2/0b0d027842425663e0ae6a7c4826e381a454aa371dc320be3a5661540b7e3c6e/merged",` | overlay2 path on the runner that pulled the image; random per pull, not part of the image |
| `"MergedDir": "/var/lib/docker/overlay2/f6ee59b34b50df82247ecbe6201c9ffab2c4034ddd18b46ed3c07be18ba17994/merged",` | overlay2 path on the runner that pulled the image; random per pull, not part of the image |
| `"Size": 4327867737,` | layer contents differ; rebuilt is 17.7 MB smaller uncompressed. Attributing this mostly to the tree layer is inferred from compressed GHCR layer sizes (layer 3 21.4 MB smaller, layer 5 5.4 MB larger, layer 9 3.0 MB larger); the per-layer uncompressed split is unverified |
| `"Size": 4345610411,` | layer contents differ; rebuilt is 17.7 MB smaller uncompressed. Attributing this mostly to the tree layer is inferred from compressed GHCR layer sizes (layer 3 21.4 MB smaller, layer 5 5.4 MB larger, layer 9 3.0 MB larger); the per-layer uncompressed split is unverified |
| `"UpperDir": "/var/lib/docker/overlay2/0b0d027842425663e0ae6a7c4826e381a454aa371dc320be3a5661540b7e3c6e/diff",` | overlay2 path on the runner that pulled the image; random per pull, not part of the image |
| `"UpperDir": "/var/lib/docker/overlay2/f6ee59b34b50df82247ecbe6201c9ffab2c4034ddd18b46ed3c07be18ba17994/diff",` | overlay2 path on the runner that pulled the image; random per pull, not part of the image |
| `"WorkDir": "/var/lib/docker/overlay2/0b0d027842425663e0ae6a7c4826e381a454aa371dc320be3a5661540b7e3c6e/work"` | overlay2 path on the runner that pulled the image; random per pull, not part of the image |
| `"WorkDir": "/var/lib/docker/overlay2/f6ee59b34b50df82247ecbe6201c9ffab2c4034ddd18b46ed3c07be18ba17994/work"` | overlay2 path on the runner that pulled the image; random per pull, not part of the image |
| `"base-tools-hash": "5f4649d82fa92e9051fb157294a430d48ac75d96c7a483957b8a777118263b63",` | `COMBINED_HASH` over the base-tools layer list and the crossdev pins; the crossdev versions are identical, but whether rc1's build hashed the same pin string is unverified; the base-tools layers (3-8) differ, which alone changes the hash |
| `"base-tools-hash": "966c33b3a8e50d64fffe3ed7a078099e116d085afe128762ea0489be457924aa",` | `COMBINED_HASH` over the base-tools layer list and the crossdev pins; the crossdev versions are identical, but whether rc1's build hashed the same pin string is unverified; the base-tools layers (3-8) differ, which alone changes the hash |
| `"ghcr.io/tuckermclean/themonolith/builder@sha256:3f825cc695668cd70096b3fc14b5abfdf4d4888c299f313be71a8652fb0c3d13"` | RepoDigests entry: the same registry digest as the `image:` line |
| `"ghcr.io/tuckermclean/themonolith/builder@sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa"` | RepoDigests entry: the same registry digest as the `image:` line |
| `"sha256:085bdd307f4222d9f3423e1214d6c0bc54d4c06bb6e3edb574ea3b15832c032f"` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `"sha256:16d24e879b4ab47f5e886c6c782ed9d07eb3f7577d42a8dd683edb432a70ce6d",` | layer 3, rc1: `RUN emerge-webrsync --revert=20260810` (rsync snapshot of the tree) |
| `"sha256:2334cbc321bfb3f8537a039b4ddd10905209253a420361ee02393a3c22dbe6fb",` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `"sha256:2bc502cb140c9c61e70b38faadeed84e12c39f4066d4945886adc193d8a705df",` | layer 3, rebuilt: `COPY tree/ /var/db/repos/gentoo/` (git archive of gentoo-mirror `d4d0b0c7`) |
| `"sha256:407a8191f8da1c12dfb0b82324be1dd3f20a2dde9f9e7fdead2e7c0e3770e9ca",` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `"sha256:7086448501a7ea867b7f4be4a9dbd15bf5c87a53073248cc88885b465399cea2",` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `"sha256:78ba831b275f39f1e4924cc65330f31e5fab936bfbf1162f4e8f57dfb7e18883",` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `"sha256:80e779842e23145546ed2fe554b63d27be705e6d87ca0b28f466bc1ac81e280d",` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `"sha256:8b343697971f690e15f0761178381d1fd249525f572fdfcdf5c4933d795fd853",` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `"sha256:8c805c7f7582a196dd79e0970c7b06153e3c70100de4309b24ed5e83f84ac521",` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `"sha256:a543c186b03b551ed05770fbf3303b64998d0a1d25140cf5a3f10594b2d24384",` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `"sha256:f3435f87ef68e3ccc8edfc1470af930202c5a2b611b31666bf81ffbbd26cf23f",` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `"sha256:fb3a123ae17a81d667b24804d2312804526343125e83827736e62d73a6b5e978",` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `"sha256:ff24187f15f3b315548a68d73e16d3ec2fc88e9db980b54355d31fd65edb6ea7"` | one of layers 4-9 (host-tools emerge, pyyaml and syft/grype, xcb-proto, rustup, crossdev repo setup, crossdev `docker commit`); the layer differs, which cause moves which layer is unverified (possible causes below), except syft/grype, observed in layer 5 |
| `grype 0.117.0` | installed by anchore install script from `main` without a version pin (`Dockerfile:128-142`); each build gets the latest release |
| `grype 0.121.3` | installed by anchore install script from `main` without a version pin (`Dockerfile:128-142`); each build gets the latest release |
| `image: ghcr.io/tuckermclean/themonolith/builder@sha256:3f825cc695668cd70096b3fc14b5abfdf4d4888c299f313be71a8652fb0c3d13` | registry digest of the image; a new image has a new manifest digest |
| `image: ghcr.io/tuckermclean/themonolith/builder@sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa` | registry digest of the image; a new image has a new manifest digest |
| `syft 1.51.0` | installed by anchore install script from `main` without a version pin (`Dockerfile:128-142`); each build gets the latest release |
| `syft 1.57.1` | installed by anchore install script from `main` without a version pin (`Dockerfile:128-142`); each build gets the latest release |

Notes on the causes.

- Digests: GHCR tags `rc1` point at `ab04002a...`; `20260810-245c88d08440-d4d0b0c78bd9`, `20260810` and `latest` point at
  `3f825cc6...`.
- Fields of the image config (`DockerVersion`, `Hostname`, `AttachStdout`, `AttachStderr`, `Image`): rc1's image
  config records `docker_version` `28.0.4` at its top level, and `Hostname` `d9db719e260d`, `AttachStdout` and
  `AttachStderr` `true` and `Image` `monolith-builder-base-tools` in `config` (and again in `container_config`). The
  rebuilt image's config has no `docker_version` and no `container_config`, and its `config` has none of the other four,
  so `docker image inspect` prints the zero value (`""` or `false`). The rebuild's runner engine stored images in
  Docker's containerd image store (its own inspect of the committed image shows `Descriptor` and no `GraphDriver`).
  That this store's commit omits these fields is observed, not a proven mechanism.
- `base-tools-hash`: the crossdev versions are identical (the `cross-i486-linux-musl/*` entries of `qlist -Iv` are the
  same in both manifests: binutils 2.46.1, gcc 15.3.1_p20260717, linux-headers 6.12, musl 1.2.6-r2), and the bump
  branch left `configs/portage/crossdev.lock` unchanged. Whether rc1's build, made with the predecessor's Makefile,
  hashed the same pin string is unverified. The base-tools layers (3-8) differ, which alone changes the hash.
- Layers: 9 layers each; layers 1 and 2 are identical (`a67c7be5...`, the stage3, and `5f70bf18...`, the empty
  `gcc -m32` check layer). Layer 3 holds the same ebuilds in both images (all 33060 blob ids equal) in different
  packaging, an rsync snapshot against a git archive of the mirror commit; which files account for the 47.5 MB against
  68.9 MB compressed is unverified. Layers 4-9 all differ. Possible causes, with which one moves which layer unverified: file mtimes and build timestamps, `syft` and
  `grype` installed from `main` (`Dockerfile:128-142`), rustup's install script (`Dockerfile:167-170`), distfiles
  fetched live, and `docker commit`. The one observed cause is the `syft`/`grype` version change (manifest lines), which
  lives in layer 5, the `emerge dev-python/pyyaml && … syft grype` RUN. The `qlist -Iv` packages are identical (below);
  `syft` and `grype`, which are not Portage packages, differ.

## What is the same

- `== qlist -Iv`: all 358 installed packages, versions included.
- `i486-linux-musl-gcc (Gentoo 15.3.1_p20260717 p8) 15.3.1 20260717`.
- rustup: `nightly-2026-07-15-x86_64-unknown-linux-gnu (active, default)`.
- The stage3 base layer `a67c7be5...`, pinned by digest.

Whether to merge the bump PR is the owner's call.
