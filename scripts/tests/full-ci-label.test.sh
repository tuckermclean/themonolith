#!/bin/sh
# B03 Standard mechanism: scripts/full-ci-label.sh is the only custom gate of build.yml, run by `make changes`.
# pull_request builds only with the full-ci label; push to a branch, push of a tag, schedule and workflow_dispatch
# build. The branch-push path filter is the workflow's on.push.paths, not this script. It runs without git.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
S="$ROOT/scripts/full-ci-label.sh"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES

# A PATH with the usual tools and no git.
BIN="$TMP/bin"; mkdir -p "$BIN"
for t in sh jq sed grep cat printf echo tr cut head tail awk dirname basename env test expr tee mktemp rm; do
  p=$(command -v "$t" 2>/dev/null) || continue
  case "$p" in /*) ln -s "$p" "$BIN/$t" ;; esac
done
[ -e "$BIN/git" ] && { echo "FAIL: test PATH holds git"; exit 1; }

# run <label> <want> VAR=value...
run() {
  _l=$1; _w=$2; shift 2
  : > "$TMP/out"
  env -i PATH="$BIN" GITHUB_OUTPUT="$TMP/out" "$@" sh "$S" >/dev/null 2>&1
  _got=$(sed -n 's/^build=//p' "$TMP/out" | tail -n 1)
  if [ "$_got" = "$_w" ]; then ok "$_l"; else fail "$_l (build='$_got', want '$_w')"; fi
}

printf '{"pull_request":{"labels":[{"name":"bug"},{"name":"full-ci"}]}}' > "$TMP/labeled.json"
printf '{"pull_request":{"labels":[{"name":"bug"}]}}' > "$TMP/plain.json"
printf '{"pull_request":{"labels":[]}}' > "$TMP/none.json"
printf '{"pull_request":{"labels":[{"name":"full-ci-later"}]}}' > "$TMP/near.json"

check_script() { [ -f "$S" ]; }
if check_script; then ok "scripts/full-ci-label.sh exists"; else fail "scripts/full-ci-label.sh exists"; fi

run "pull_request with the full-ci label builds" true EVENT_NAME=pull_request GITHUB_EVENT_PATH="$TMP/labeled.json"
run "pull_request without the label does not build" false EVENT_NAME=pull_request GITHUB_EVENT_PATH="$TMP/plain.json"
run "pull_request with no labels does not build" false EVENT_NAME=pull_request GITHUB_EVENT_PATH="$TMP/none.json"
run "pull_request with a label that only starts with full-ci does not build" false EVENT_NAME=pull_request GITHUB_EVENT_PATH="$TMP/near.json"
run "push to a branch builds" true EVENT_NAME=push GITHUB_REF=refs/heads/main
run "push to a branch with a base sha builds (the paths filter is on.push.paths)" true EVENT_NAME=push GITHUB_REF=refs/heads/main BASE_SHA=1111111111111111111111111111111111111111
run "push of a tag builds" true EVENT_NAME=push GITHUB_REF=refs/tags/v1.0.0
run "schedule builds" true EVENT_NAME=schedule
run "workflow_dispatch builds" true EVENT_NAME=workflow_dispatch

# make -n changes runs the script and nothing else of the old gate.
(cd "$ROOT" && env -u MAKEFLAGS make -n changes) > "$TMP/mk.out" 2>&1
if grep -q 'scripts/full-ci-label\.sh' "$TMP/mk.out"; then ok "make -n changes runs scripts/full-ci-label.sh"; else fail "make -n changes runs scripts/full-ci-label.sh"; fi
if grep -q 'changed-paths' "$TMP/mk.out"; then fail "make -n changes no longer runs changed-paths.sh"; else ok "make -n changes no longer runs changed-paths.sh"; fi
if [ -e "$ROOT/scripts/changed-paths.sh" ]; then fail "scripts/changed-paths.sh is gone (replaced by on.push.paths and full-ci-label.sh)"; else ok "scripts/changed-paths.sh is gone (replaced by on.push.paths and full-ci-label.sh)"; fi

[ "$fails" -eq 0 ] || { echo "$fails FAILED"; exit 1; }
echo "ALL PASS"
