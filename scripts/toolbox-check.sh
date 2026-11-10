#!/bin/sh
# Fails a pull request when its toolbox image would be built for nothing: when the toolbox inputs at HEAD equal
# those at $BASE, main has published (toolbox-image.yml) ${REGISTRY}/toolbox:<inputs>, and the registry must have it.
# When the inputs differ, the build is expected and the registry is not asked.
# Env: BASE (a commit, required), REGISTRY (<host>/<owner>/<repo>, else the Makefile's), TOOLBOX_REGISTRY_SCHEME (https).
# Sends no credential: curl -q reads no .curlrc, nothing passes --netrc or -u, and the only Authorization header is
# the bearer token the registry's own anonymous token endpoint issues.
set -u

die() { echo "toolbox-check: $*" >&2; exit 1; }

[ -n "${BASE:-}" ] || die "BASE is not set; it names the commit to compare the toolbox inputs with"
if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
	# A shallow checkout (fetch-depth 1) does not have the pull request's base commit.
	echo "toolbox-check: BASE $BASE is not a local commit; fetching it" >&2
	git fetch --no-tags --depth=1 origin "$BASE" || echo "toolbox-check: git fetch origin $BASE failed" >&2
	git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || die "BASE $BASE is not a commit, locally or on origin"
fi

# The inputs, as toolbox/run hashes them (cat Containerfile selfcheck | sha256sum | cut -c1-12), read at a commit.
inputs_at() {
	{ git show "$1:toolbox/Containerfile" && git show "$1:toolbox/selfcheck"; } | sha256sum | cut -c1-12
}
head_inputs=$(inputs_at HEAD) || die "cannot read toolbox/Containerfile and toolbox/selfcheck at HEAD"
if base_inputs=$(inputs_at "$BASE" 2>/dev/null) && [ "$base_inputs" = "$head_inputs" ]; then
	same=1
else
	same=0
fi

registry=${REGISTRY:-$(sed -n 's/^REGISTRY[[:space:]]*?=[[:space:]]*//p' Makefile 2>/dev/null | head -n 1)}
[ -n "$registry" ] || die "REGISTRY is not set and the Makefile has none"
tag=$registry/toolbox:$head_inputs

if [ $same = 0 ]; then
	echo "toolbox-check: toolbox/Containerfile or toolbox/selfcheck differ from $BASE; building $tag is as expected, so it is not looked up"
	exit 0
fi

host=${registry%%/*}
path=${registry#*/}
case $registry in */*) ;; *) die "REGISTRY $registry has no <host>/<path>" ;; esac
base_url=${TOOLBOX_REGISTRY_SCHEME:-https}://$host

tmp=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT INT TERM

# fetch <url> [curl args...]: prints the HTTP status; the body goes to $tmp/body. A curl failure is fatal and named.
fetch() {
	url=$1
	shift
	code=$(curl -q -sS --max-time 30 -o "$tmp/body" -w '%{http_code}' "$@" "$url") || {
		rc=$?
		die "curl failed (exit $rc) asking $url for $tag"
	}
	printf '%s' "$code"
}

code=$(fetch "$base_url/token?scope=repository:$path/toolbox:pull") || exit 1
[ "$code" = 200 ] || die "the token endpoint $base_url/token answered HTTP $code (not 200) for $tag: $(head -c 300 "$tmp/body")"
token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp/body" | head -n 1)
[ -n "$token" ] || die "the token endpoint $base_url/token returned no token for $tag: $(head -c 300 "$tmp/body")"

accept='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
code=$(fetch "$base_url/v2/$path/toolbox/manifests/$head_inputs" -H "Authorization: Bearer $token" -H "Accept: $accept") || exit 1
case $code in
200)
	echo "toolbox-check: $tag exists"
	;;
404)
	die "$tag does not exist: the toolbox inputs equal those of $BASE, so the Toolbox Image workflow (toolbox-image.yml) has not published it"
	;;
*)
	die "the registry answered HTTP $code (neither 200 nor 404) for $tag: $(head -c 300 "$tmp/body")"
	;;
esac
