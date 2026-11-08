#!/bin/sh
# Writes build=true|false to $GITHUB_OUTPUT: whether the run builds. A pull_request builds only with a label
# named exactly full-ci (read from the event file); every other event builds. The branch-push path filter is
# the workflow's on.push.paths, not this script.
# Environment: EVENT_NAME, GITHUB_EVENT_PATH, GITHUB_OUTPUT.
set -eu

EVENT_NAME="${EVENT_NAME:-}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

build=true
if [ "$EVENT_NAME" = pull_request ]; then
    : "${GITHUB_EVENT_PATH:?pull_request needs GITHUB_EVENT_PATH}"
    build=$(jq -r 'if ([.pull_request.labels[].name] | index("full-ci")) != null then "true" else "false" end' "$GITHUB_EVENT_PATH")
fi
echo "full-ci-label: build=$build"
echo "build=$build" >> "$OUT"
