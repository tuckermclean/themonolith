#!/bin/sh
# Reports a tag that did not publish: opens the issue "Release <tag> did not publish", or comments on the open one.
# Reports only when HEAD_BRANCH is a tag at HEAD_SHA and the Build run did not succeed, or resolve or publish failed.
# Always exits 0: a report must never turn a red Build run into a second failure.
# Env: HEAD_BRANCH, HEAD_SHA, BUILD_RUN_ID, BUILD_CONCLUSION, BUILD_RUN_URL, RELEASE_RUN_URL, RESOLVE_RESULT,
# PUBLISH_RESULT, GH_TOKEN, GITHUB_REPOSITORY (passed to gh as GH_REPO); BUILD_RUN_ATTEMPT (else asked from gh).
set -u
: "${HEAD_BRANCH:?}" "${HEAD_SHA:?}" "${BUILD_RUN_ID:?}" "${GITHUB_REPOSITORY:?}"
GH_REPO=$GITHUB_REPOSITORY
export GH_REPO
tag=$HEAD_BRANCH
conclusion=${BUILD_CONCLUSION:-}
resolve=${RESOLVE_RESULT:-}
publish=${PUBLISH_RESULT:-}
case $tag in
v[0-9]*) ;;
*) echo "release-report: ${tag} is not a version tag; nothing to report"; exit 0 ;;
esac
tag_sha=$(git rev-parse "refs/tags/${tag}^{commit}") || { echo "release-report: ${tag} is not a tag here; nothing to report"; exit 0; }
[ "$tag_sha" = "$HEAD_SHA" ] || { echo "release-report: ${tag} does not point at ${HEAD_SHA}; nothing to report"; exit 0; }
own=0
if [ "$resolve" = failure ] || [ "$publish" = failure ]; then own=1; fi
if [ "$conclusion" = success ] && [ "$own" = 0 ]; then
	echo "release-report: ${tag} published or is publishing; nothing to report"
	exit 0
fi
attempt=${BUILD_RUN_ATTEMPT:-}
[ -n "$attempt" ] || attempt=$(gh run view "$BUILD_RUN_ID" --json attempt --jq .attempt) || attempt=
attempt=${attempt:-1}
body=$(mktemp)
trap 'rm -f "$body"' EXIT INT TERM
{
	echo "The tag ${tag} (${HEAD_SHA}) did not publish a release."
	echo
	echo "- Build run: ${BUILD_RUN_URL:-run ${BUILD_RUN_ID}}"
	echo "- Attempt: ${attempt}"
	echo "- Build conclusion: ${conclusion}"
	if [ "$own" = 1 ]; then
		echo "- Release run: ${RELEASE_RUN_URL:-} (resolve: ${resolve}, publish: ${publish})"
	fi
	echo
	echo "Jobs of that Build attempt that failed or were cancelled:"
	echo
	jobs=$(gh run view "$BUILD_RUN_ID" --attempt "$attempt" --json jobs \
		--jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled") | "- " + .name + ": " + .conclusion') || jobs=
	if [ -n "$jobs" ]; then echo "$jobs"; else echo "- (none listed)"; fi
	echo
	echo "What to do: see the operator steps in ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/blob/main/docs/releasing.md#operator-steps-to-cut-a-release (re-run failed jobs for a flake; fix forward and re-tag otherwise)."
} > "$body"
title="Release ${tag} did not publish"
number=
list=$(gh issue list --state open --limit 200 --json number,title \
	--jq '.[] | "\(.number)\t\(.title)"') || list=
tab=$(printf '\t')
while IFS=$tab read -r num t; do
	if [ "$t" = "$title" ]; then number=$num; break; fi
done <<EOF
$list
EOF
if [ -n "$number" ]; then
	gh issue comment "$number" --body-file "$body" || echo "release-report: could not comment on issue ${number}" >&2
else
	gh issue create --title "$title" --body-file "$body" || echo "release-report: could not create the issue" >&2
fi
exit 0
