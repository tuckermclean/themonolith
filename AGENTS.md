# The Monolith — agent guide

Read this first if you are an AI agent or a new contributor. `SPEC.md` is the authority on what is
built; this file is about how to work on it. The predecessor's guide (design doctrines, credential
handling, debugging discipline, traps and recipes) follows this section once F01 imports it (F01
change 6).

The owner is Tucker McLean (me@tuckermclean.com), the sole developer.

## What the project is

- Read [`MYTH.md`](MYTH.md) first. The Monolith is an artifact from the future: one CD with a complete,
  modern Linux userland, handed to a ten-year-old at a 486 in 1996, that boots on that machine and on
  every PC after it. Calling it "a small Gentoo derivative" or a toy misses the point.
- When you describe the project (README, PR text, specs), lead with that framing, then give the
  technical category.
- 8 MB of RAM is the aim. The floor the tests check is 64 MB (SPEC §1). Do not write that 8 MB is
  tested.
- The practical end is a fully attested, fully documented stack (licences, SBOM, CVE checks, SLSA
  provenance, every part specified) that fits in one head and can be explained end to end.

## Writing specs and docs

- Write `SPEC.md`, the node specs, the README, the plan and PR descriptions as the definitive product.
  Leave out the spec's own revision history: no "v0.3 had…", "corrective pass", "withdrawn", "earlier
  draft", and no gaps in id numbering kept for old references. In the owner's words: "I'm trying to read
  The Hobbit and The Silmarillion is trying to steal the limelight."
- Change history goes in commit messages and `docs/reviews/`. Reader-facing docs do not link to
  `docs/reviews/`.
- Facts about the predecessor that the port needs are fine: `file:line` citations at `b9f533b`, the rc1
  assets.
- After a spec change, describe the result, not the change.

## Commits

- The owner authors every commit for work the owner directed and accepted.
- Record AI assistance in an `Assisted-by:` trailer naming the tool and model, for example
  `Assisted-by: Claude Code (claude-opus-5-5)`. Do not add AI tools as `Co-Authored-By:`.
- Do not rewrite historical commits to change their authors. That includes the predecessor's
  inconsistent agent identities.
- SPEC §11 is the rule; this is the reminder.
