#!/bin/sh
# Writes SHA256SUMS in a release directory over the ISO and every other asset; fails if one is missing.
# Usage: release-sums.sh <dir>
set -eu
[ $# -eq 1 ] && [ -d "$1" ] || { echo "usage: $0 <release-dir>" >&2; exit 2; }
cd "$1"
set -- themonolith-*.iso bom.cdx.json release-inputs.json source-audit.tsv rootfs-provenance.tsv rc1-diff.md sizes.md dynamic-allowlist.txt
[ $# -eq 8 ] || { echo "release-sums: want exactly one themonolith-*.iso in $(pwd)" >&2; exit 1; }
for f; do [ -f "$f" ] || { echo "release-sums: $f is missing from $(pwd)" >&2; exit 1; }; done
sha256sum "$@" > SHA256SUMS
cat SHA256SUMS
