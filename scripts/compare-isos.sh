#!/bin/sh
# compare-isos.sh <iso-a> <iso-b>: exit 0 only if both ISOs have the same sha256, 1 on a mismatch.
# diffoscope, if present, only prints a report after a mismatch; it decides nothing.
set -u

[ $# -eq 2 ] || { echo "usage: compare-isos.sh <iso-a> <iso-b>" >&2; exit 2; }
for f in "$1" "$2"; do
	[ -f "$f" ] && [ -r "$f" ] && [ -s "$f" ] || { echo "compare-isos: $f is missing, unreadable or empty" >&2; exit 2; }
done

da=$(sha256sum "$1") || { echo "compare-isos: sha256sum failed for $1" >&2; exit 2; }
db=$(sha256sum "$2") || { echo "compare-isos: sha256sum failed for $2" >&2; exit 2; }
da=${da%% *}
db=${db%% *}
echo "$da  $1"
echo "$db  $2"

if [ "$da" = "$db" ]; then
	echo "compare-isos: the ISOs are identical"
	exit 0
fi

echo "compare-isos: the ISOs differ" >&2
if command -v diffoscope >/dev/null 2>&1; then
	if [ -n "${DIFFOSCOPE_HTML:-}" ]; then
		diffoscope --text - --html "$DIFFOSCOPE_HTML" "$1" "$2" || true
	else
		diffoscope "$1" "$2" || true
	fi
fi
exit 1
