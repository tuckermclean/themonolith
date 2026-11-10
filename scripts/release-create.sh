#!/bin/sh
# Creates the GitHub Release for TAG from RELEASE_DIR and release-notes.md.
# A hyphenated tag (v0.2.0-rc1, -beta.2) is a prerelease and never Latest: the API refuses a prerelease as Latest.
# Env: TAG, RELEASE_DIR, BUILD_VERSION, GH_TOKEN, GITHUB_REPOSITORY (passed to gh as GH_REPO).
set -eu
: "${TAG:?}" "${RELEASE_DIR:?}" "${BUILD_VERSION:?}" "${GITHUB_REPOSITORY:?}"
GH_REPO=$GITHUB_REPOSITORY
export GH_REPO
flags=
case "${TAG#v}" in
*-*)
	flags="--prerelease --latest=false"
	echo "==> ${TAG}: pre-release; published as a prerelease, not Latest"
	;;
*) echo "==> ${TAG}: final release; published as Latest (gh default)" ;;
esac
d=$RELEASE_DIR
# shellcheck disable=SC2086
gh release create "${TAG}" $flags \
	--title "The Monolith ${TAG}" \
	--notes-file release-notes.md \
	"$d/themonolith-${BUILD_VERSION}.iso" \
	"$d/SHA256SUMS" \
	"$d/bom.cdx.json" \
	"$d/release-inputs.json" \
	"$d/source-audit.tsv" \
	"$d/rootfs-provenance.tsv" \
	"$d/rc1-diff.md" \
	"$d/sizes.md" \
	"$d/dynamic-allowlist.txt"
