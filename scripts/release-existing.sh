#!/bin/sh
# Stops the publish job before anything is pushed when the release for TAG already holds assets.
# No release, or a release (draft or published) without assets: exit 0; release-create.sh fills it.
# Assets present: exit 1 with the recovery step; a half-published release is deleted by hand, keeping the tag.
# Env: TAG, GH_TOKEN, GITHUB_REPOSITORY (passed to gh as GH_REPO).
set -eu
: "${TAG:?}" "${GITHUB_REPOSITORY:?}"
GH_REPO=$GITHUB_REPOSITORY
export GH_REPO
err=$(mktemp)
trap 'rm -f "$err"' EXIT INT TERM
if ! count=$(gh release view "$TAG" --json tagName,isDraft,assets --jq '.assets | length' 2> "$err"); then
	if grep -q "release not found" "$err"; then
		echo "==> ${TAG}: no release yet; the release step creates it"
		exit 0
	fi
	cat "$err" >&2
	echo "release-existing: could not look up the release for ${TAG}" >&2
	exit 1
fi
count=${count:-0}
if [ "$count" -eq 0 ]; then
	echo "==> ${TAG}: a release exists without assets; the release step fills it"
	exit 0
fi
echo "::error::The release for ${TAG} already holds ${count} asset(s); refusing to publish over it."
echo "Delete the release and keep the tag, then re-run the Release run:"
echo "  gh release delete ${TAG} --yes"
exit 1
