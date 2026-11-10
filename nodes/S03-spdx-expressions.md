# S03 — spdx-expressions

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | S02 | none | — | S |

**Owns:** the bare-group, SPDX `OR` and SPDX `WITH` handling of `parse_portage_expr` and `_parse_alternatives` in `scripts/check-licenses.py` (changes 1–3; S01 owns the rest of the file, S02 the `||` handling), `scripts/tests/check-licenses-spdx.test.sh`, `scripts/fixtures/S03/`.
**Ports from linux-live-iso-factory@b9f533b:** none. S01 ported `check-licenses.py` and S02 changed it; this node changes it again.
**Study refs:** R05's follow-up question of 2026-11-09 (Q1), PR #69, Build run 42721213707; S01 Risks (licence expressions); S02 Risks (`WITH`); D-supply-chain-honesty.

## Purpose
The licence gate reads the SBOM's expressions. These are the SPDX forms syft writes from the Portage VDB, not the ebuild's `LICENSE`. Two parts of that form are misread:
- **`WITH`.** The tokenizer splits on whitespace (`scripts/check-licenses.py:87`), so `Apache-2.0 WITH LLVM-exception` becomes three licences, `Apache-2.0`, `WITH` and `LLVM-exception`. An `allowed_spdx` entry `Apache-2.0 WITH LLVM-exception` can never match, and `WITH` is never allowed.
- **Bare groups.** `_parse_alternatives` flattens a bare parenthesised group into one conjunction (`:182-189`), so `MIT AND (A OR B)` needs MIT, A *and* B.

Build run 42721213707 (R05's crate licences, PR #69) failed both packages' licence gate on `not in allowlist: WITH, LLVM-exception`. Its SBOM gives rl144 `MIT AND … AND Zlib AND (0BSD OR Apache-2.0 OR MIT OR … OR Apache-2.0 WITH LLVM-exception OR … OR Unlicense)`.

After this node:
- `A WITH B` is one licence, matched as a whole against `allowed_spdx`;
- a bare group's `OR` keeps its meaning, so that group passes on MIT;
- an `OR` with nothing on one side adds no empty alternative that would pass by itself.

## Standard mechanism
The grammar is SPDX's license expression syntax (SPDX specification, Annex D): `WITH` binds a licence to an exception and binds tighter than `AND`, which binds tighter than `OR`, and parentheses group. The gate runs in the toolbox and in the release path, where S01 keeps the ported checker (SPEC §5). The custom code is the existing recursive-descent parser. The fix is a token-joining pass and a few lines in its bare-group and `OR` branches.

## Tests
- **Ported first:** none (see Ports from).
- **Kept:** `scripts/tests/check-licenses.test.sh` (S02) passes unchanged.
- **Added:** `scripts/tests/check-licenses-spdx.test.sh` (AC-1 to AC-3), offline in the toolbox. It imports `check-licenses.py` for `parse_portage_expr` (AC-1), and runs the script on small CycloneDX SBOMs and policies under `scripts/fixtures/S03/` (AC-2, AC-3). One of those SBOMs holds rl144's expression from Build run 42721213707, copied verbatim.
- **Baseline:** against `main`'s `check-licenses.py` (S02's):
  - the `WITH`, bare-group `OR` and dangling-`OR` cases of AC-1 fail, except `MIT AND (NOT-A OR)`, which main's flattening of bare groups already reads as `[["MIT", "NOT-A"]]` (the case guards change 2 against bringing change 3's defect into groups); its "as before" cases pass;
  - in AC-2, every pass case fails, and every fail case fails except `NOT-A OR`, which passes through its empty alternative (change 3's defect);
  - in AC-3, the expression fails with both policies.

## Changes from the port
`check-licenses.py` stays as S01 ported it and S02 changed it, except for these changes.

1. **`A WITH B` is one licence.** After tokenizing, `parse_portage_expr` joins an identifier, a following `WITH` and the identifier after it into one token `A WITH B`, with single spaces. An identifier here is any token that is not `(`, `)`, `||`, `AND`, `OR` or `WITH`. The joined token is normalised through `gentoo_to_spdx` and checked against `allowed_spdx` and `denied_spdx` as a whole, like any licence. A `WITH` that does not stand between two identifiers stays its own token, and the gate fails it, because no policy allows `WITH`. *AC-1, AC-2.*
2. **A bare group is its alternatives.** Outside a `||` group, `_parse_alternatives` crosses a bare `( ... )` group's inner alternatives with the running conjunctions, as it does for a `||` group, instead of flattening them into one conjunction. So `MIT AND (A OR B)` is `[["MIT", "A"], ["MIT", "B"]]`. A group with no `OR` and no `||` inside (Gentoo's `( A B )`, a USE-conditional's group) has one alternative, so its reading is unchanged. The same rule makes Gentoo's `( A || ( B C ) )` `[["A", "B"], ["A", "C"]]`. Inside a `||` group nothing changes (S02). *AC-1, AC-2, AC-3.*
3. **An `OR` with nothing on one side adds no alternative.** At the top level and inside a bare group, an `OR` that has no licence before it or after it adds no empty alternative. Today `NOT-A OR` parses to `[["NOT-A"], []]`, and the empty alternative passes the gate whatever `NOT-A` is. Change 2 would carry this into groups, as `MIT AND (NOT-A OR)`. After this change both read as if the dangling `OR` were absent. If nothing is left, the expression falls back to one literal licence, as malformed input does today (`:94`). *AC-1, AC-2.*

## Gate
- **S03-AC-1** — `parse_portage_expr` returns `[["Apache-2.0 WITH LLVM-exception"]]` for `Apache-2.0 WITH LLVM-exception`, `[["MIT"], ["Apache-2.0 WITH LLVM-exception"]]` for `MIT OR Apache-2.0 WITH LLVM-exception`, `[["MIT", "A"], ["MIT", "B"]]` for `MIT AND (A OR B)`, `[["MIT", "A"], ["MIT", "B WITH C"]]` for `MIT AND (A OR B WITH C)`, `[["A", "C"], ["A", "D"], ["B", "C"], ["B", "D"]]` for `(A OR B) AND (C OR D)`, `[["A", "B"], ["A", "C"]]` for `( A || ( B C ) )`, `[["NOT-A"]]` for `NOT-A OR`, `[["MIT", "NOT-A"]]` for `MIT AND (NOT-A OR)` and `[["OR"]]` for `OR`; and, as before, `[["MIT", "BSD"]]` for `( MIT BSD )`, `[["A", "B"], ["C"]]` for `(A AND B) OR C` and `[["MIT", "WITH"]]` for `MIT WITH`. *Verify:* `toolbox/run -- sh scripts/tests/check-licenses-spdx.test.sh`, run by `make test-unit`; `scripts/tests/check-licenses.test.sh` still passes.
- **S03-AC-2** — With a policy whose `allowed_spdx` is `MIT`, `Apache-2.0` and `Apache-2.0 WITH LLVM-exception`, `check-licenses.py` reports components with the expressions `Apache-2.0 WITH LLVM-exception`, `NOT-A OR Apache-2.0 WITH LLVM-exception`, `MIT AND (NOT-A OR Apache-2.0)` and `MIT AND (NOT-A OR Apache-2.0 WITH LLVM-exception)` as `pass`, and exits 0 on an SBOM of those four; it reports `MIT WITH LLVM-exception`, `Apache-2.0 WITH NOT-AN-EXCEPTION`, `MIT AND (NOT-A OR NOT-B)`, `NOT-A AND (MIT OR Apache-2.0)`, `NOT-A OR` and `MIT AND (NOT-A OR)` as `fail`, and exits 1 on an SBOM holding any one of them. *Verify:* `toolbox/run -- sh scripts/tests/check-licenses-spdx.test.sh`, run by `make test-unit`.
- **S03-AC-3** — The licence expression of `games-roguelike/rl144` in the `bom.cdx.json` of Build run 42721213707 (a fixture, copied verbatim) passes with a policy whose `allowed_spdx` is exactly `MIT`, `BSD-3-Clause`, `MPL-2.0`, `Unicode-3.0` and `Zlib`. It fails when `Unicode-3.0` is removed from that policy. *Verify:* `toolbox/run -- sh scripts/tests/check-licenses-spdx.test.sh`, run by `make test-unit`.

## Risks
- **The gate only grows more permissive where an expression offers a choice or names an exception.** Every alternative of the old reading contains an alternative of the new one. The only exceptions are the joined `A WITH B` tokens, which replace `A`, `WITH` and `B`, and no policy allows `WITH`. So a component that passed still passes, and S01-AC-6 (the licence gate on rc1) cannot turn red. Change 3 is the exception: it is stricter. On rc1, an expression with a dangling `OR` that passed only through its empty alternative would now fail. syft does not emit that form, so none is expected, and the rc1 lane shows it if one exists.
- **The flattened SBOM group.** syft flattens a package's Gentoo `||` groups into one SPDX `OR` group (the R05 question of 2026-11-09, Q2; the owner asked for an issue on S01's `enrich-sbom.py`). With change 2, rl144's crate group passes when any one crate alternative is allowed, not when each crate's choice is. Today every alternative in that group is a free licence, so nothing non-free passes. Checking per crate needs the SBOM to keep the groups apart. That fix belongs to the issue, not this node.
- **R05's policy entries.** R05's entries in `license-policy.yaml` (`Unlicense`, `Apache-2.0 WITH LLVM-exception`) may stop being needed for rl144 and stele once this node lands. Whether they stay is R05's and the owner's call. The entry `GPL-2.0-only WITH Font-exception-2.0` already in the policy starts to match an SBOM's `WITH` expression only after change 1.
- **Unchanged here:**
  - lowercase `with`, `and` and `or` (SPDX operators are matched in upper case here, as `AND` and `OR` are today);
  - a parenthesised group inside a `||` group, which is still flattened (S02);
  - USE-conditional groups (`flag? ( ... )`), still read as an identifier and a bare group;
  - a multi-entry `licenses[]`, still joined as AND (S01 Risks).
  - an expression that is only an empty group `( )`, still read as one empty alternative (syft does not emit it).
