#!/bin/sh
# Report file sizes and compare the ISO with ISO_BUDGET_BYTES (from the environment).
# Usage: ISO_BUDGET_BYTES=<n> size-report.sh <iso> [<squashfs> [<kernel> [<initrd>]]]
set -u
[ $# -ge 1 ] && [ $# -le 4 ] || { echo "usage: ISO_BUDGET_BYTES=<n> $0 <iso> [<squashfs> [<kernel> [<initrd>]]]" >&2; exit 2; }
case ${ISO_BUDGET_BYTES:-} in ''|*[!0-9]*) echo "size-report: ISO_BUDGET_BYTES unset or not numeric" >&2; exit 2 ;; esac
iso=$1
[ -f "$iso" ] && [ -r "$iso" ] || { echo "size-report: cannot read $iso" >&2; exit 2; }
size() { wc -c < "$1" | tr -d ' '; }
isosize=$(size "$iso")
echo "iso: $isosize bytes ($iso)"
i=0
for f in "${2:--}" "${3:--}" "${4:--}"; do
	label=$(echo "squashfs kernel initrd" | cut -d' ' -f$((i+1))); i=$((i+1))
	[ "$f" = - ] && continue
	[ -r "$f" ] || { echo "size-report: cannot read $f" >&2; exit 2; }
	echo "$label: $(size "$f") bytes ($f)"
done
echo "budget: $ISO_BUDGET_BYTES bytes"
if [ "$isosize" -gt "$ISO_BUDGET_BYTES" ]; then
	echo "size-report: the ISO is $((isosize - ISO_BUDGET_BYTES)) bytes over the budget"
	exit 1
fi
echo "size-report: within budget ($((ISO_BUDGET_BYTES - isosize)) bytes spare)"
