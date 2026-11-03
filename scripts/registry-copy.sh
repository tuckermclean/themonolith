#!/bin/sh
# Copies an image or artifact into $REGISTRY by digest; a copy keeps the digest.
# Usage: registry-copy.sh <source>@sha256:<64 hex> <name>:<tag>
# The copy lands at $REGISTRY/<name>:<tag>, and the script fails unless that tag then has the source digest.
# With GITHUB_TOKEN set (CI), it logs in to REGISTRY's host first; the login ends with the container.
set -eu

[ $# -eq 2 ] || { echo "usage: registry-copy.sh <source>@sha256:<64 hex> <name>:<tag>" >&2; exit 2; }
src=$1
dst=$2
: "${REGISTRY:?registry-copy: REGISTRY is not set}"

case $src in
*@*) digest=${src##*@} ;;
*) echo "registry-copy: source '$src' is not pinned by digest" >&2; exit 2 ;;
esac
printf '%s\n' "$digest" | grep -qxE 'sha256:[0-9a-f]{64}' ||
	{ echo "registry-copy: source '$src' is not pinned by a sha256 digest" >&2; exit 2; }
printf '%s\n' "$dst" | grep -qxE '[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}' ||
	{ echo "registry-copy: destination '$dst' is not <name>:<tag>" >&2; exit 2; }

command -v oras >/dev/null || { echo "registry-copy: oras is not installed" >&2; exit 1; }

if [ -n "${GITHUB_TOKEN:-}" ]; then
	printf '%s' "$GITHUB_TOKEN" | oras login "${REGISTRY%%/*}" -u "${GITHUB_ACTOR:-token}" --password-stdin
fi

oras cp "$src" "$REGISTRY/$dst"
got=$(oras manifest fetch --descriptor "$REGISTRY/$dst" | sed -n 's/.*"digest": *"\([^"]*\)".*/\1/p')
[ "$got" = "$digest" ] || { echo "registry-copy: $REGISTRY/$dst is ${got:-unknown}, want $digest" >&2; exit 1; }
echo "registry-copy: $REGISTRY/$dst is $digest"
