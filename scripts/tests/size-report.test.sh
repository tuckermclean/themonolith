#!/bin/sh
# P01 slice 1: scripts/size-report.sh and the Makefile's ISO_BUDGET_BYTES (node spec change 8).
#   P01-AC-8  exits 1 for an ISO of 681,984,001 bytes and 0 for 681,984,000 with the default budget.
#
# Interface under test (the implementer writes the script and Make target from this header alone):
#   ISO_BUDGET_BYTES ?= 681984000                 Makefile variable (OD-10, the 74-minute CD-R)
#   make size-report ISO=<iso> [SQUASHFS=<f>] [KERNEL=<f>] [INITRD=<f>]
#                                                 Make target; its recipe passes $(ISO_BUDGET_BYTES) to the script
#                                                 (checked with `make -n`: the expanded default shows in the recipe)
#   ISO_BUDGET_BYTES=<n> sh scripts/size-report.sh <iso> [<squashfs> [<kernel> [<initrd>]]]
#     prints one line per file given ("-" or a missing optional argument skips it) with its size in bytes, and the
#     budget; the ISO line is compared with ISO_BUDGET_BYTES (read from the environment, set by make).
#     exit 0 when size(iso) <= budget, exit 1 when it is larger (the output says so), exit 2 on a usage error,
#     an unreadable ISO or ISO_BUDGET_BYTES unset/non-numeric.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
S="$ROOT/scripts/size-report.sh"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# the default budget is the Makefile's, not a value this test supplies
budget=$(make -s -p -n -f "$ROOT/Makefile" -C "$ROOT" size-report ISO=x 2>/dev/null | sed -n 's/^ISO_BUDGET_BYTES *[:?]*= *//p' | head -1)
if [ "$budget" = 681984000 ]; then ok "P01-AC-8: Makefile ISO_BUDGET_BYTES defaults to 681984000"
else fail "P01-AC-8: Makefile ISO_BUDGET_BYTES default is '$budget', want 681984000"; fi
mout=$(make -n -f "$ROOT/Makefile" -C "$ROOT" size-report ISO="$TMP/x.iso" 2>&1)
if echo "$mout" | grep -q 'size-report.sh' && echo "$mout" | grep -q 681984000; then
	ok "P01-AC-8: make size-report runs size-report.sh with the 681984000 default"
else fail "P01-AC-8: make -n size-report does not run size-report.sh with 681984000"; fi

truncate -s 681984001 "$TMP/over.iso"
truncate -s 681984000 "$TMP/exact.iso"
truncate -s 1000 "$TMP/sq"; truncate -s 2000 "$TMP/kern"; truncate -s 3000 "$TMP/rd"
b=${budget:-681984000}

out=$(ISO_BUDGET_BYTES=$b sh "$S" "$TMP/over.iso" "$TMP/sq" "$TMP/kern" "$TMP/rd" 2>&1); rc=$?
if [ "$rc" = 1 ]; then ok "P01-AC-8: ISO of 681,984,001 bytes exits 1"
else fail "P01-AC-8: 681,984,001-byte ISO must exit 1 (rc=$rc)"; fi
out=$(ISO_BUDGET_BYTES=$b sh "$S" "$TMP/exact.iso" "$TMP/sq" "$TMP/kern" "$TMP/rd" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "P01-AC-8: ISO of 681,984,000 bytes exits 0"
else fail "P01-AC-8: 681,984,000-byte ISO must exit 0 (rc=$rc)"; fi
for n in 681984000 1000 2000 3000; do
	echo "$out" | grep -q "$n" && ok "P01-AC-8: report prints $n" || fail "P01-AC-8: report must print the size $n"
done
out=$(ISO_BUDGET_BYTES=$b sh "$S" "$TMP/exact.iso" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "P01-AC-8: optional sizes may be omitted" || fail "P01-AC-8: ISO alone must work (rc=$rc)"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
