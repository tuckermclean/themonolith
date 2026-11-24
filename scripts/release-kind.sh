#!/bin/sh
# Prints the release kind of a tag: "prerelease" for vX.Y.Z-<suffix> (any hyphen after the leading v), "final" for vX.Y.Z.
# Exits non-zero, naming the tag, for anything else. The one pre-release rule: release-create.sh and test-gates read it.
# Usage: release-kind.sh <tag>
set -eu
tag=${1-}
case "$tag" in
v?*) ;;
*)
	echo "release-kind: '${tag}' is not a v-prefixed release tag" >&2
	exit 1
	;;
esac
case "${tag#v}" in
*-*) echo prerelease ;;
*) echo final ;;
esac
