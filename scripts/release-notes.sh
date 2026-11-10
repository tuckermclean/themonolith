#!/bin/sh
# Writes release-notes.md for a tag.
# Env: TAG, BUILD_VERSION, PREV_TAG (may be empty), ISO (path of the release ISO), GITHUB_REPOSITORY.
# Reads configs/portage/versions.lock and the git log of the checkout.
set -eu
: "${TAG:?}" "${BUILD_VERSION:?}" "${ISO:?}" "${GITHUB_REPOSITORY:?}"
PREV_TAG=${PREV_TAG:-}
KERNEL=$(grep '^sys-kernel/monolith-kernel:' configs/portage/versions.lock | cut -d: -f2)
BUSYBOX=$(grep '^sys-apps/busybox:' configs/portage/versions.lock | cut -d: -f2)
SHA=$(sha256sum "$ISO" | cut -d' ' -f1)
{
	echo "## The Monolith ${TAG}"
	echo ""
	echo "Kernel \`${KERNEL}\` · BusyBox \`${BUSYBOX}\` · musl / Gentoo crossdev, i486 target"
	echo ""
	echo "### Verify"
	echo ""
	echo '```bash'
	echo "gh attestation verify themonolith-${BUILD_VERSION}.iso --repo \"${GITHUB_REPOSITORY}\" --signer-workflow ${GITHUB_REPOSITORY}/.github/workflows/build.yml"
	echo '```'
	echo ""
	echo "ISO SHA-256:"
	echo ""
	echo '```'
	echo "${SHA}"
	echo '```'
	echo ""
	echo "This is the digest of the build attestation's subject, of \`bom.cdx.json\`'s \`metadata.component.hashes[0]\`, of the \`SHA256SUMS\` entry and of both reproducibility builds' ISOs (see docs/releasing.md)."
	echo ""
	echo "### Changelog"
	if [ -n "$PREV_TAG" ]; then
		echo ""
		echo "Since \`${PREV_TAG}\`:"
	fi
	echo ""
	if [ -n "$PREV_TAG" ]; then
		git log --no-merges --pretty=format:'- %s (%h)' "${PREV_TAG}..${TAG}"
		echo ""
	else
		echo "- Initial release."
	fi
} > release-notes.md
cat release-notes.md
