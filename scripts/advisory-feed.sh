#!/bin/sh
# Builds the advisory feed tree: installs the pinned grype, gathers each release's SBOM and its
# existing status file, runs the monitor, and leaves the whole site in $FEED_DIR/site.
# Env: GRYPE_VERSION, GRYPE_SHA256 (the linux_amd64 tarball), GH_TOKEN, GITHUB_REPOSITORY,
#      RC1_TAG, RC1_SBOM_URL, RC1_SBOM_SHA256, BASE_URL, FEED_DIR (default output/advisory-feed).
# A status file that cannot be fetched (anything but HTTP 404) fails the run: unreachable is never clean.
set -eu
: "${GRYPE_VERSION:?}" "${GRYPE_SHA256:?}" "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}"
: "${RC1_TAG:?}" "${RC1_SBOM_URL:?}" "${RC1_SBOM_SHA256:?}" "${BASE_URL:?}"
FEED_DIR=${FEED_DIR:-output/advisory-feed}
HERE=$(cd "$(dirname "$0")" && pwd)
GH_REPO=$GITHUB_REPOSITORY
export GH_REPO

rm -rf "$FEED_DIR"
bin=$FEED_DIR/bin
data=$FEED_DIR/data
site=$FEED_DIR/site
mkdir -p "$bin" "$data/status" "$site/status"

echo "==> grype $GRYPE_VERSION"
tgz=$FEED_DIR/grype_${GRYPE_VERSION}_linux_amd64.tar.gz
curl -fsSL --retry 3 -o "$tgz" \
	"https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_linux_amd64.tar.gz"
echo "$GRYPE_SHA256  $tgz" | sha256sum -c -
tar -xzf "$tgz" -C "$bin" grype
rm -f "$tgz"

echo "==> SBOMs"
tags=$(gh release list --limit 1000 --json tagName --jq '.[].tagName')
for t in $tags; do
	mkdir -p "$data/$t"
	gh release download "$t" --pattern bom.cdx.json --dir "$data/$t"
done
mkdir -p "$data/$RC1_TAG"
curl -fsSL --retry 3 -o "$data/$RC1_TAG/bom.cdx.json" "$RC1_SBOM_URL"
echo "$RC1_SBOM_SHA256  $data/$RC1_TAG/bom.cdx.json" | sha256sum -c -

echo "==> prior status files from $BASE_URL"
for t in $tags $RC1_TAG; do
	code=$(curl -sS --retry 3 -o "$data/status/$t.json" -w '%{http_code}' "$BASE_URL/status/$t.json") ||
		{ echo "advisory-feed: $BASE_URL/status/$t.json unreachable" >&2; exit 1; }
	case $code in
	200) ;;
	404) rm -f "$data/status/$t.json" ;;
	*) echo "advisory-feed: $BASE_URL/status/$t.json answered HTTP $code" >&2; exit 1 ;;
	esac
done

echo "==> monitor"
GRYPE_DB_CACHE_DIR=$FEED_DIR/grype-db PATH=$PWD/$bin:$PATH \
	python3 "$HERE/nightly-cve-monitor.py" --data-dir "$data" --base-url "$BASE_URL"

cp "$data"/status/*.json "$site/status/"
echo "==> site: $(ls "$site/status" | wc -l) status file(s)"
