#!/bin/sh
# Builds the advisory feed tree: installs the pinned grype, gathers each release's SBOM and its
# existing status file, runs the monitor, and leaves the whole site in $FEED_DIR/site.
# Env: GRYPE_VERSION, GRYPE_SHA256 (the linux_amd64 tarball), GH_TOKEN, GITHUB_REPOSITORY,
#      RC1_TAG, RC1_SBOM_URL, RC1_SBOM_SHA256, BASE_URL, FEED_DIR (default output/advisory-feed).
# The site carries status/index.txt (every tag with a status file). The prior index and the prior status files
# of the releases, rc1 and every indexed tag are fetched; a tag whose release is gone is carried forward unscanned.
# An index or status file that cannot be fetched (anything but HTTP 404) fails the run: unreachable is never clean.
# A release whose SBOM cannot be fetched or verified, or that the monitor cannot scan, is a per-build error:
# its status file stays as it was, the other builds still update, and $FEED_DIR/result says "partial" (else "ok")
# so the workflow can end red after it has published. Any other monitor failure builds nothing and fails.
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
bin=$(cd "$bin" && pwd)
partial=

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
	if ! gh release download "$t" --pattern bom.cdx.json --dir "$data/$t"; then
		echo "advisory-feed: no SBOM for $t; its status file stays as it was" >&2
		rm -rf "${data:?}/$t"
		partial=1
	fi
done
mkdir -p "$data/$RC1_TAG"
if ! curl -fsSL --retry 3 -o "$data/$RC1_TAG/bom.cdx.json" "$RC1_SBOM_URL" ||
	! echo "$RC1_SBOM_SHA256  $data/$RC1_TAG/bom.cdx.json" | sha256sum -c -; then
	echo "advisory-feed: no verified SBOM for $RC1_TAG; its status file stays as it was" >&2
	rm -rf "${data:?}/$RC1_TAG"
	partial=1
fi

echo "==> tag index from $BASE_URL"
code=$(curl -sS --retry 3 -o "$FEED_DIR/index.in" -w '%{http_code}' "$BASE_URL/status/index.txt") ||
	{ echo "advisory-feed: $BASE_URL/status/index.txt unreachable" >&2; exit 1; }
case $code in
200) ;;
404) : >"$FEED_DIR/index.in" ;;
*) echo "advisory-feed: $BASE_URL/status/index.txt answered HTTP $code" >&2; exit 1 ;;
esac
# A tag is used in a URL and a path: keep only plain names.
indexed=
while IFS= read -r t || [ -n "$t" ]; do
	case $t in
	'' | .* | *[!A-Za-z0-9._+-]*) [ -z "$t" ] || echo "advisory-feed: ignoring bad index line" >&2 ;;
	*) indexed="$indexed $t" ;;
	esac
done <"$FEED_DIR/index.in"

echo "==> prior status files from $BASE_URL"
# Releases that were deleted keep their status file: it is carried forward unscanned.
for t in $(printf '%s\n' "$tags" "$RC1_TAG" "$indexed" | tr ' ' '\n' | sort -u); do
	code=$(curl -sS --retry 3 -o "$data/status/$t.json" -w '%{http_code}' "$BASE_URL/status/$t.json") ||
		{ echo "advisory-feed: $BASE_URL/status/$t.json unreachable" >&2; exit 1; }
	case $code in
	200) ;;
	404) rm -f "$data/status/$t.json" ;;
	*) echo "advisory-feed: $BASE_URL/status/$t.json answered HTTP $code" >&2; exit 1 ;;
	esac
done

echo "==> monitor"
rc=0
GRYPE_DB_CACHE_DIR=$FEED_DIR/grype-db PATH=$bin:$PATH \
	python3 "$HERE/nightly-cve-monitor.py" --data-dir "$data" --base-url "$BASE_URL" || rc=$?
case $rc in
0) ;;
1) partial=1 ;;
*) echo "advisory-feed: monitor failed (exit $rc); nothing built" >&2; exit "$rc" ;;
esac

cp "$data"/status/*.json "$site/status/"
set -- "$site"/status/*.json
for f; do basename "$f" .json; done | sort >"$site/status/index.txt"
echo "==> site: $# status file(s)"
if [ -n "$partial" ]; then
	echo partial >"$FEED_DIR/result"
	echo "advisory-feed: some builds were not refreshed (see above); the rest are published" >&2
else
	echo ok >"$FEED_DIR/result"
fi
