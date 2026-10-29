# The myth of the Monolith

It is 1996. A ten-year-old sits at a 486, which probably runs Windows 95.

A time machine opens in the room, and the kid's grown-up self steps out of it, from 2026. The visitor
sets down a CD, a CD-ROM drive and probably a controller card to connect it, and says only: "Here you
go. Be good, kid." Then the visitor leaves and explains nothing.

The CD is a portal to the future. Like the monolith in *2001: A Space Odyssey*, it arrives without
explanation and changes what is possible for whoever finds it. On it is a complete, modern Linux
userland that boots on that 486, and on every PC after it, up to a current UEFI machine.

## What the artifact is

- **It runs on the kid's machine.** The aim is a 486 with 8 MB of RAM, booting from the CD.
  Everything is cross-compiled for i486 and statically linked against musl. It runs straight off the
  disc, with no dynamic loader and nothing to install. (The floor the tests check today is the
  predecessor's 64 MB, SPEC §1. 8 MB is the aim.)
- **It runs on everything after it.** The same disc boots by BIOS through ISOLINUX, and on a modern
  UEFI machine through GRUB.
- **It is a full system, not a toy.** It has a complete userland in text mode, or in X. The X stack is
  TinyX with the suckless tools, dwm and st, chosen because they run happily on a 486 with 8 MB. It also
  has networking, a router, persistence, a browser (Stele), a roguelike (rl144) and a help system that
  explains the machine to whoever finds it.
- **It is the best OS for a 486 in 2026.** That is the bar.

## Why it is built with this much care

It is a labour of love, and a great deal of work has already gone into it. The predecessor,
[linux-live-iso-factory](https://github.com/tuckermclean/linux-live-iso-factory), built, tested and
attested this product and shipped `v0.1.0-rc1`.

It is also meant to be understood completely:
- Every input is pinned, and every package is built from source in the release run.
- Everything that ends up on the disc is documented, and its licence is known.
- Every release has an SBOM, CVE checks and SLSA provenance, and is reproducible bit for bit.
- Every part is specified, so the whole system, from the tree commit to the attested ISO, fits in
  one head and can be explained end to end.

## What is happening now

The engine is being taken apart and put back together the right way. This repository ports the
predecessor onto standard Gentoo mechanisms and GitHub-native storage, and fixes what the study of the
predecessor found. `SPEC.md` is the authority. Its §0.1 lists the facts from this myth that the design
depends on.
