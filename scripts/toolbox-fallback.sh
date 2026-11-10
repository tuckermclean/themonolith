#!/bin/sh
# Called by toolbox/run in Actions when no toolbox image could be pulled and it is about to build one.
# Says, as a ::warning:: line on stderr and a line in $GITHUB_STEP_SUMMARY, whether that build is
# expected: it is when toolbox/Containerfile or toolbox/selfcheck differ from the base commit.
# Usage: toolbox-fallback.sh <tag>; the base is $BASE, else origin/$GITHUB_BASE_REF, else origin/main.
set -u
tag=${1:-the toolbox image}
files="toolbox/Containerfile toolbox/selfcheck"

if [ -n "${BASE:-}" ]; then
	base=$BASE
elif [ -n "${GITHUB_BASE_REF:-}" ]; then
	base=origin/$GITHUB_BASE_REF
	if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
		git fetch --no-tags --depth=1 origin "$GITHUB_BASE_REF" || true
		# Without a tracking refspec the fetch only sets FETCH_HEAD.
		git rev-parse --verify --quiet "$base^{commit}" >/dev/null || base=FETCH_HEAD
	fi
else
	base=origin/main
fi

pre="toolbox/run: no $tag to pull; building it"
if reason=$(git rev-parse --verify "$base^{commit}" 2>&1 >/dev/null); then
	same=1
	for f in $files; do
		if ! git cat-file -e "$base:$f" 2>/dev/null || ! git show "$base:$f" | cmp -s - "$f"; then
			same=0
		fi
	done
	if [ $same = 0 ]; then
		msg="$pre, as expected: this branch changes toolbox/Containerfile or toolbox/selfcheck against $base"
	else
		msg="$pre, but main's image is missing: the toolbox inputs equal those of $base, so the Toolbox Image workflow (toolbox-image.yml) has not published it"
	fi
else
	reason=$(printf '%s' "$reason" | tr '\n' ' ')
	msg="$pre; the base could not be read ($base: $reason), so whether this build is expected is unknown"
fi

echo "::warning::$msg" >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	echo "$msg" >>"$GITHUB_STEP_SUMMARY"
fi
exit 0
