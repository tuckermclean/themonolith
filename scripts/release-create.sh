#!/bin/sh
# Publishes the GitHub Release for TAG from RELEASE_DIR and release-notes.md.
# No release: creates it. A release without assets (a draft or published shell left by hand): uploads the files, then
# edits title, notes and flags and publishes it. A release with assets: refuses (scripts/release-existing.sh).
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
sh "$(dirname "$0")/release-existing.sh"
err=$(mktemp)
trap 'rm -f "$err"' EXIT INT TERM
if exists=$(gh release view "${TAG}" --json tagName --jq .tagName 2> "$err"); then
	:
else
	grep -q "release not found" "$err" || { cat "$err" >&2; exit 1; }
	exists=
fi
if [ -z "$exists" ]; then
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
	exit 0
fi
echo "==> ${TAG}: filling the existing release"
gh release upload "${TAG}" \
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
# shellcheck disable=SC2086
gh release edit "${TAG}" $flags \
	--title "The Monolith ${TAG}" \
	--notes-file release-notes.md \
	--draft=false
