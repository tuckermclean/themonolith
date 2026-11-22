#!/bin/sh
# Writes release-notes.md for a tag.
# Env: TAG, BUILD_VERSION, PREV_TAG (may be empty), ISO (path of the release ISO), GITHUB_REPOSITORY, RELEASE_DIR.
# Reads configs/portage/versions.lock, $RELEASE_DIR/attestation-summary.json and the git log of the checkout.
set -eu
: "${TAG:?}" "${BUILD_VERSION:?}" "${ISO:?}" "${GITHUB_REPOSITORY:?}" "${RELEASE_DIR:?}"
PREV_TAG=${PREV_TAG:-}
KERNEL=$(grep '^sys-kernel/monolith-kernel:' configs/portage/versions.lock | cut -d: -f2)
BUSYBOX=$(grep '^sys-apps/busybox:' configs/portage/versions.lock | cut -d: -f2)
SHA=$(sha256sum "$ISO" | cut -d' ' -f1)
SUMMARY=$RELEASE_DIR/attestation-summary.json
[ -f "$SUMMARY" ] || { echo "release-notes: no $SUMMARY" >&2; exit 1; }
# cve_check, gating findings (the CVEs listed in cve_failures), waived, total, grype DB build time, licence, unowned
GATES=$(python3 -I -c '
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    cov = s.get("cve_coverage") or {}
    gating = sum(len([c for c in e.split(": ", 1)[-1].split(",") if c.strip()]) for e in s.get("cve_failures") or [])
    for v in (s.get("cve_check"), gating, cov.get("waived_findings"), cov.get("total_findings"),
              (s.get("cve_db") or {}).get("built"), s.get("license_check"), s.get("unowned_check")):
        print("" if v is None else v)
except Exception as e:
    sys.exit("release-notes: cannot read %s: %s" % (sys.argv[1], e))
' "$SUMMARY") || exit 1
{
	read -r CVE_CHECK
	read -r CVE_GATING
	read -r CVE_WAIVED
	read -r CVE_TOTAL
	read -r DB_BUILT
	read -r LIC_CHECK
	read -r UNOWNED_CHECK
} <<NOTES_GATES
$GATES
NOTES_GATES
KIND=$(sh "$(dirname "$0")/release-kind.sh" "$TAG")
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
	echo "### Supply-chain gates"
	echo ""
	echo "- CVE gate: \`${CVE_CHECK}\` (${CVE_GATING} gating findings, ${CVE_WAIVED} waived, ${CVE_TOTAL} total)"
	echo "- Grype database built: \`${DB_BUILT}\`"
	echo "- Licence gate: \`${LIC_CHECK}\`"
	echo "- Unowned-files gate: \`${UNOWNED_CHECK}\`"
	if [ "$KIND" = prerelease ] && [ "$CVE_CHECK" = fail ]; then
		echo ""
		echo "This pre-release ships with known CVE findings, listed in \`attestation-summary.json\`, and a final release must clear them."
	fi
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
