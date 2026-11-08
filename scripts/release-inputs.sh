#!/bin/sh
# release-inputs.sh <out.json>: write release-inputs.json (SPEC §6) from the environment.
# Every input is required and non-empty; a missing or empty one fails the script and is named.
set -u

[ $# -eq 1 ] || { echo "usage: release-inputs.sh <out.json>" >&2; exit 2; }
out=$1

FIELDS="VERSION SOURCE_COMMIT TREE_COMMIT TREE_DIGEST BUILDER_DIGEST DISTFILES_DIGEST SOURCE_DATE_EPOCH XORRISO_VERSION SQUASHFS_TOOLS_VERSION GRUB_VERSION SYSLINUX_VERSION SYFT_VERSION GRYPE_VERSION QEMU_VERSION GRYPE_DB_BUILT"

bad=0
for f in $FIELDS; do
	v=$(printenv "$f") || v=
	case $v in
	*[![:space:]]*) ;;
	*) echo "release-inputs: $f is missing or empty" >&2; bad=1 ;;
	esac
done
[ $bad -eq 0 ] || exit 1

tmp=$(mktemp "$out.XXXXXX") || exit 1
keys=$(printf '%s\n' $FIELDS | jq -R . | jq -s .)
if jq -n --argjson keys "$keys" '$ENV | with_entries(select(.key | IN($keys[])))' >"$tmp"; then
	mv "$tmp" "$out"
else
	rm -f "$tmp"
	echo "release-inputs: jq failed" >&2
	exit 1
fi
