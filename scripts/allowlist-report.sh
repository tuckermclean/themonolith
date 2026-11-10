#!/bin/sh
# Prints the dynamic-binary allowlist as it is, then its entry count (the lines that are neither blank nor comments).
# Usage: allowlist-report.sh <dynamic-allowlist.txt>
set -u
[ $# -eq 1 ] || { echo "usage: $0 <dynamic-allowlist.txt>" >&2; exit 2; }
[ -r "$1" ] || { echo "allowlist-report: cannot read $1" >&2; exit 2; }
cat "$1" || exit 2
n=$(grep -v '^#' "$1" | grep -vc '^[[:space:]]*$')
echo "# entries: ${n:-0}"
