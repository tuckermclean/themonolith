# S02 — licence-alternatives

| Track | Deps | Unlocks | Milestone | Size |
|---|---|---|---|---|
| later | S01 | S03 | — | S |

**Owns:** the `||` handling of `_parse_alternatives` in `scripts/check-licenses.py` (change 1; S01 owns the rest of the file), `scripts/tests/check-licenses.test.sh`, `scripts/fixtures/S02/`.
**Resolves:** #61
**Ports from linux-live-iso-factory@b9f533b:** none. The predecessor has no test of `check-licenses.py`; S01 ported the script unchanged, and this node changes that port.
**Study refs:** issue #61; S01 Risks (licence expressions); D-supply-chain-honesty.

## Purpose
`check-licenses.py` evaluates a Gentoo any-of group `|| ( A B )` as A AND B: inside the group, `_parse_alternatives` (`scripts/check-licenses.py:118-168`) appends each plain identifier to one running conjunction, so `|| ( MIT GPL-2+ )` parses to `[["MIT", "GPL-2+"]]`, although the docstrings (`:11`, `:78`, `:109-111`) promise `[["MIT"], ["GPL-2+"]]`. The gate fails closed, so nothing non-free passes, but a package whose `LICENSE` offers a choice needs every alternative in `allowed_spdx`. After this node each item of a `||` group is its own alternative, a package passes when one alternative is fully allowed and fails when none is, and a unit test in `make test-unit` holds both.

## Standard mechanism
The grammar is Portage's: in a `LICENSE` string, `|| ( ... )` is an any-of group whose items are alternatives (PMS, dependency specification). Portage's own parser (`portage.dep.use_reduce`) reads it, but the gate also runs its tests in the toolbox, which has no Portage, and S01 keeps the ported checker in the release path (SPEC §5). The custom code is the existing recursive-descent parser; the fix is a few lines in its `||` branch.

## Tests
- **Ported first:** none (see Ports from).
- **Added:** `scripts/tests/check-licenses.test.sh` (AC-1, AC-2), offline in the toolbox. It imports `check-licenses.py` for `parse_portage_expr` (AC-1), and runs the script on small CycloneDX SBOMs and a small policy under `scripts/fixtures/S02/` (AC-2).
- **Baseline:** against `main`'s `check-licenses.py` (the `b9f533b` blob), the `||` cases of AC-1 fail (each group comes back as one conjunction) and its other cases pass; in AC-2, `|| ( MIT NOT-ALLOWED )` fails and `|| ( NOT-A NOT-B )` fails as it should.

## Changes from the port
`check-licenses.py` stays as S01 ported it except for this change.

1. **Each item of a `||` group is its own alternative.** Inside `|| ( ... )`, a plain identifier is one alternative; a nested conjunctive group `( A B )` is one alternative holding all its licences; a nested `|| ( ... )` adds each of its alternatives. The group's alternatives are then crossed with the conjunction before it, as today (`MIT || ( ISC BSD )` is `[["MIT", "ISC"], ["MIT", "BSD"]]`). Outside a `||` group nothing changes: identifiers conjoin, a bare group conjoins, and SPDX `AND` and `OR` keep their meaning. The docstrings at `:11`, `:78` and `:109-111` then describe the code and are not edited. *AC-1, AC-2.*

## Gate
- **S02-AC-1** — `parse_portage_expr` returns `[["MIT"], ["GPL-2+"]]` for `|| ( MIT GPL-2+ )`, `[["MIT", "ISC"], ["MIT", "BSD"]]` for `MIT || ( ISC BSD )`, `[["A", "B"], ["C"]]` for `|| ( ( A B ) C )` and `[["A"], ["B"], ["C"]]` for `|| ( A || ( B C ) )`; and, as before, `[["MIT"]]` for `MIT`, `[["MIT", "BSD-2-Clause"]]` for `MIT BSD-2-Clause` and `[["MIT"], ["Apache-2.0"]]` for `MIT OR Apache-2.0`. *Verify:* `toolbox/run -- sh scripts/tests/check-licenses.test.sh`, run by `make test-unit`.
- **S02-AC-2** — With a policy whose `allowed_spdx` is `MIT` and `Apache-2.0` (so `Apache-2.0-with-LLVM-exceptions`, `NOT-ALLOWED`, `NOT-A` and `NOT-B` are not allowed), `check-licenses.py` reports a component with `LICENSE` `|| ( MIT NOT-ALLOWED )` as `pass`, `|| ( MIT Apache-2.0-with-LLVM-exceptions )` as `pass` and `|| ( ( MIT NOT-ALLOWED ) Apache-2.0 )` as `pass`, and exits 0 on an SBOM of those three; it reports `|| ( NOT-A NOT-B )` and `|| ( ( MIT NOT-ALLOWED ) NOT-B )` as `fail` and exits 1 on an SBOM holding either. *Verify:* `toolbox/run -- sh scripts/tests/check-licenses.test.sh`, run by `make test-unit`.

## Risks
- `enrich-sbom.py:190` says syft turns Portage's `|| ( A B )` into `A OR B` for packages in the target's VDB (unverified here). If so, the Gentoo form reaches the gate only for components whose `LICENSE` is read raw, such as the builder components `enrich-sbom.py` propagates (`:798-813`), and wherever syft keeps it. The tests do not depend on which; issue #61 records that R05's crate `LICENSE` lines reach the gate in this form.
- The gate only grows more permissive where a `LICENSE` offers a choice: every alternative of the old reading contains an alternative of the new one, so a component that passed still passes and S01-AC-6 (the licence gate on rc1) cannot turn red.
- The crate licences R05 adds to `license-policy.yaml` (`Unlicense`, `Apache-2.0 WITH LLVM-exception`) are R05's entries; whether they stay once this node lands is R05's and the owner's call, not this node's.
- Unchanged here: SPDX `WITH` expressions split into three tokens, USE-conditional groups (`flag? ( ... )`) read as an identifier and a bare group, and a multi-entry `licenses[]` joined as AND (S01 Risks).
