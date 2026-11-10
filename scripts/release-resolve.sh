#!/bin/sh
# Decides whether a finished Build run is a tag run to publish, and writes the release's names to $GITHUB_OUTPUT:
# publish, tag, build-version, prev-tag. Needs a checkout with its tags.
# Env: TAG (the Build run's head_branch), BUILT_SHA (its head_sha).
set -eu
out=${GITHUB_OUTPUT:-/dev/stdout}
case ${TAG:-} in
v*) ;;
*) echo "release-resolve: ${TAG:-(none)} is not a version tag; nothing to publish"; echo "publish=false" >> "$out"; exit 0 ;;
esac
[ -n "${BUILT_SHA:-}" ] || { echo "release-resolve: BUILT_SHA is unset" >&2; exit 1; }
if ! git rev-parse -q --verify "refs/tags/${TAG}" > /dev/null; then
	echo "::error::${TAG} is not a tag in this repository; refusing to publish."
	exit 1
fi
TAG_SHA=$(git rev-parse "refs/tags/${TAG}^{commit}")
if [ "$TAG_SHA" != "$BUILT_SHA" ]; then
	echo "::error::Tag ${TAG} points at ${TAG_SHA} but the Build ran on ${BUILT_SHA}; refusing to publish."
	exit 1
fi
PREV_TAG=$(git describe --tags --abbrev=0 "${TAG}^" 2> /dev/null || echo "")
{
	echo "publish=true"
	echo "tag=${TAG}"
	echo "build-version=${TAG#v}"
	echo "prev-tag=${PREV_TAG}"
} >> "$out"
if [ -n "$PREV_TAG" ]; then echo "==> Version ${TAG#v} (tag ${TAG}), previous tag: ${PREV_TAG}"
else echo "==> Version ${TAG#v} (tag ${TAG}), no previous tag found; full history"; fi
