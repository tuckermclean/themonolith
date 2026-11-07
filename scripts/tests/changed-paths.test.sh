#!/bin/sh
# scripts/changed-paths.sh: the full-ci label gate and the events that always build. The branch-push path filter
# needs git, which the unit-test toolbox lacks; it is covered by the build workflow run.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
S="$ROOT/scripts/changed-paths.sh"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# run <label> <want> VAR=value...
run() {
    _l=$1; _w=$2; shift 2
    : > "$TMP/out"
    env -i PATH="$PATH" GITHUB_OUTPUT="$TMP/out" "$@" sh "$S" >/dev/null 2>&1
    _got=$(sed -n 's/^build=//p' "$TMP/out")
    if [ "$_got" = "$_w" ]; then ok "$_l"; else fail "$_l (build='$_got', want '$_w')"; fi
}

printf '{"pull_request":{"labels":[{"name":"bug"},{"name":"full-ci"}]}}' > "$TMP/labeled.json"
printf '{"pull_request":{"labels":[{"name":"bug"}]}}' > "$TMP/plain.json"
printf '{"pull_request":{"labels":[]}}' > "$TMP/none.json"

run "pull_request with the full-ci label builds" true EVENT_NAME=pull_request GITHUB_EVENT_PATH="$TMP/labeled.json"
run "pull_request without it does not build" false EVENT_NAME=pull_request GITHUB_EVENT_PATH="$TMP/plain.json"
run "pull_request with no labels does not build" false EVENT_NAME=pull_request GITHUB_EVENT_PATH="$TMP/none.json"
run "a tag push builds" true EVENT_NAME=push GITHUB_REF=refs/tags/v1.0.0 BASE_SHA=1111111111111111111111111111111111111111
run "a push with no known base builds" true EVENT_NAME=push GITHUB_REF=refs/heads/main
run "a push with an all-zero base builds" true EVENT_NAME=push GITHUB_REF=refs/heads/main BASE_SHA=0000000000000000000000000000000000000000
run "schedule builds" true EVENT_NAME=schedule
run "workflow_dispatch builds" true EVENT_NAME=workflow_dispatch

[ "$fails" -eq 0 ] || { echo "$fails FAILED"; exit 1; }
echo "ALL PASS"
