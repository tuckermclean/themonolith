#!/bin/sh
# P02 release-gate: the reproducibility gate. Cases are grouped by slice; later slices add lines above the
# "slice cases end" marker, never below it, and never edit earlier lines.
#   P02-AC-2  compare exits 1 when the two ISO digests differ, 0 only when equal; nothing makes a mismatch pass;
#             no known-differences file exists
#
# Interface under test (chosen for P02 slice 1):
#   sh scripts/compare-isos.sh <iso-a> <iso-b>   sha256sum of both; prints both digests; exit 0 only if equal,
#                                                exit 1 on a mismatch (diffoscope may run after a mismatch to
#                                                print a report; it decides nothing); any other failure
#                                                (missing/unreadable/empty file, wrong arg count) is non-zero
#   make compare ISO_A=<iso-a> ISO_B=<iso-b>     the Make target the `compare` job calls; runs the script
#                                                (make reports a failed recipe as exit 2: asserted non-zero)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/scripts/compare-isos.sh"
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ================= slice 1: P02-AC-2 =================
# fixture ISOs: same content; one byte different; stub diffoscope that always succeeds
head -c 1048576 /dev/zero | tr '\0' 'M' >"$TMP/a.iso"
cp "$TMP/a.iso" "$TMP/same.iso"
cp "$TMP/a.iso" "$TMP/b.iso"
printf 'X' | dd of="$TMP/b.iso" bs=1 seek=524288 conv=notrunc 2>/dev/null
mkdir -p "$TMP/stubs"
printf '#!/bin/sh\necho stub diffoscope "$@"\nexit 0\n' >"$TMP/stubs/diffoscope"
chmod +x "$TMP/stubs/diffoscope"

run_cmp() { # run_cmp <a> <b> [env assignments...]; sets rc, out
	a=$1; b=$2; shift 2
	out=$(env "$@" sh "$SCRIPT" "$a" "$b" 2>&1)
	rc=$?
}

run_cmp "$TMP/a.iso" "$TMP/same.iso" X=1
if [ "$rc" -eq 0 ]; then pass "P02-AC-2 identical ISOs exit 0"; else fail "P02-AC-2 identical ISOs exit 0 (rc=$rc: $(echo "$out" | head -c 200))"; fi

run_cmp "$TMP/a.iso" "$TMP/b.iso" X=1
if [ "$rc" -eq 1 ]; then pass "P02-AC-2 ISOs differing by one byte exit exactly 1"; else fail "P02-AC-2 ISOs differing by one byte exit exactly 1 (rc=$rc)"; fi

run_cmp "$TMP/b.iso" "$TMP/a.iso" X=1
if [ "$rc" -eq 1 ]; then pass "P02-AC-2 mismatch exits 1 in either order"; else fail "P02-AC-2 mismatch exits 1 in either order (rc=$rc)"; fi

# the same file given twice is equal
run_cmp "$TMP/a.iso" "$TMP/a.iso" X=1
if [ "$rc" -eq 0 ]; then pass "P02-AC-2 a file against itself exits 0"; else fail "P02-AC-2 a file against itself exits 0 (rc=$rc)"; fi

# 0 only when equal: missing, empty and wrong-arity inputs never exit 0
: >"$TMP/empty1.iso"; : >"$TMP/empty2.iso"
rc=0; sh "$SCRIPT" "$TMP/a.iso" "$TMP/nonexistent.iso" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then pass "P02-AC-2 a missing ISO does not exit 0"; else fail "P02-AC-2 a missing ISO does not exit 0"; fi
rc=0; sh "$SCRIPT" "$TMP/nonexistent1.iso" "$TMP/nonexistent2.iso" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then pass "P02-AC-2 two missing ISOs (equal digests of nothing) do not exit 0"; else fail "P02-AC-2 two missing ISOs do not exit 0"; fi
rc=0; sh "$SCRIPT" "$TMP/empty1.iso" "$TMP/empty2.iso" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then pass "P02-AC-2 two empty files do not exit 0"; else fail "P02-AC-2 two empty files do not exit 0"; fi
rc=0; sh "$SCRIPT" "$TMP/a.iso" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then pass "P02-AC-2 one argument does not exit 0"; else fail "P02-AC-2 one argument does not exit 0"; fi

# no file, variable or input makes a mismatch pass
: >"$TMP/known-differences"
for f in known-differences known-differences.txt known_differences allowlist.txt allowed-differences ignore.txt; do
	: >"$TMP/$f"
done
printf '%s\n' "$(sha256sum "$TMP/b.iso" | cut -d' ' -f1)" "*" >"$TMP/known-differences.txt"
cp "$TMP/known-differences.txt" "$TMP/allowlist.txt"
bypass_envs="KNOWN_DIFFERENCES=$TMP/known-differences ALLOWLIST=$TMP/allowlist.txt ALLOW_MISMATCH=1 ALLOW_DIFFERENCES=1 IGNORE_DIFFERENCES=1 SKIP_COMPARE=1 COMPARE_SKIP=1 FORCE=1 CI=true DRY_RUN=1 ACCEPT=1 TOLERATE=1 REPRO_OVERRIDE=1 DIFFOSCOPE_EXIT=0 COMPARE_ALLOW=1"
# shellcheck disable=SC2086
for e in $bypass_envs; do
	run_cmp "$TMP/a.iso" "$TMP/b.iso" "$e" PATH="$TMP/stubs:$PATH"
	if [ "$rc" -eq 1 ]; then pass "P02-AC-2 mismatch still exits 1 with $e"; else fail "P02-AC-2 mismatch still exits 1 with $e (rc=$rc)"; fi
done
# all of them together, from a directory holding allowlist-named files, with a succeeding diffoscope
# shellcheck disable=SC2086
(cd "$TMP" && env $bypass_envs PATH="$TMP/stubs:$PATH" sh "$SCRIPT" a.iso b.iso >/dev/null 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "P02-AC-2 mismatch exits 1 with every bypass variable, allowlist files and a succeeding diffoscope"; else fail "P02-AC-2 mismatch exits 1 with every bypass variable, allowlist files and a succeeding diffoscope (rc=$rc)"; fi
# a failing diffoscope does not turn an equal pair into a failure, nor a mismatch into a pass
printf '#!/bin/sh\nexit 3\n' >"$TMP/stubs/diffoscope"
run_cmp "$TMP/a.iso" "$TMP/b.iso" PATH="$TMP/stubs:$PATH"
if [ "$rc" -eq 1 ]; then pass "P02-AC-2 mismatch exits 1 when diffoscope itself fails"; else fail "P02-AC-2 mismatch exits 1 when diffoscope itself fails (rc=$rc)"; fi
run_cmp "$TMP/a.iso" "$TMP/same.iso" PATH="$TMP/stubs:$PATH"
if [ "$rc" -eq 0 ]; then pass "P02-AC-2 equal ISOs exit 0 and never need diffoscope"; else fail "P02-AC-2 equal ISOs exit 0 and never need diffoscope (rc=$rc)"; fi

# the script prints both digests (the compare log is the AC-6/AC-7 evidence)
run_cmp "$TMP/a.iso" "$TMP/b.iso" X=1
da=$(sha256sum "$TMP/a.iso" | cut -d' ' -f1); db=$(sha256sum "$TMP/b.iso" | cut -d' ' -f1)
if echo "$out" | grep -q "$da" && echo "$out" | grep -q "$db"; then pass "P02-AC-2 both digests are printed"; else fail "P02-AC-2 both digests are printed"; fi

# the Make target backs the script
if grep -qE '^compare:' "$ROOT/Makefile" 2>/dev/null; then pass "P02-AC-2 Makefile has a compare target"; else fail "P02-AC-2 Makefile has a compare target"; fi
rc=0; (cd "$ROOT" && make compare ISO_A="$TMP/a.iso" ISO_B="$TMP/same.iso") >"$TMP/mk0.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then pass "P02-AC-2 make compare exits 0 on identical ISOs"; else fail "P02-AC-2 make compare exits 0 on identical ISOs (rc=$rc)"; fi
rc=0; (cd "$ROOT" && make compare ISO_A="$TMP/a.iso" ISO_B="$TMP/b.iso" KNOWN_DIFFERENCES="$TMP/known-differences" ALLOW_MISMATCH=1) >"$TMP/mk1.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && grep -q "$db" "$TMP/mk1.log"; then pass "P02-AC-2 make compare fails on a mismatch, bypass variables included"; else fail "P02-AC-2 make compare fails on a mismatch, bypass variables included (rc=$rc)"; fi

# no known-differences file anywhere in the tree, and no bypass in the script or its Make target
found=$(cd "$ROOT" && find . -path ./.git -prune -o -path ./out -prune -o \( -iname '*known-differences*' -o -iname '*known_differences*' -o -iname '*accepted-differences*' -o -iname '*allowed-differences*' \) -print 2>/dev/null)
if [ -z "$found" ]; then pass "P02-AC-2 no known-differences file exists"; else fail "P02-AC-2 no known-differences file exists ($found)"; fi
if [ -f "$SCRIPT" ] && ! grep -qiE 'known.differences|allowlist|allow.list|allow_mismatch|ignore|skip|tolerat|exception' "$SCRIPT"; then
	pass "P02-AC-2 compare script has no allowlist, ignore or skip path"
else
	fail "P02-AC-2 compare script has no allowlist, ignore or skip path (script missing or has one)"
fi
# ================= slice cases end: add later slices' cases above this line =================

[ "$fails" -eq 0 ]
