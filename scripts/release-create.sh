#!/bin/sh
# Creates the GitHub Release for TAG from RELEASE_DIR and release-notes.md.
# A hyphenated tag (v0.2.0-rc1, -beta.2) is a prerelease and never Latest: the API refuses a prerelease as Latest.
# The kind comes from RELEASE_KIND (default: release-kind.sh next to this script).
# Env: TAG, RELEASE_DIR, BUILD_VERSION, GH_TOKEN, GITHUB_REPOSITORY (passed to gh as GH_REPO), RELEASE_KIND.
set -eu
: "${TAG:?}" "${RELEASE_DIR:?}" "${BUILD_VERSION:?}" "${GITHUB_REPOSITORY:?}"
GH_REPO=$GITHUB_REPOSITORY
export GH_REPO
RELEASE_KIND=${RELEASE_KIND:-$(dirname "$0")/release-kind.sh}
kind=$(sh "$RELEASE_KIND" "$TAG")
flags=
case "$kind" in
prerelease)
	flags="--prerelease --latest=false"
	echo "==> ${TAG}: pre-release; published as a prerelease, not Latest"
	;;
final) echo "==> ${TAG}: final release; published as Latest (gh default)" ;;
*)
	echo "release-create: ${RELEASE_KIND} printed '${kind}' for ${TAG}" >&2
	exit 1
	;;
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
	"$d/dynamic-allowlist.txt" \
	"$d/attestation-summary.json"
