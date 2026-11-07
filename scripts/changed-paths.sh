#!/bin/sh
# Writes build=true|false to $GITHUB_OUTPUT: whether the run builds. The predecessor's gates, as one decision:
#   pull_request   only with the full-ci label (read from the event file)
#   a branch push  only when a path of the package build changed between BASE_SHA and HEAD_SHA; an unknown base
#                  (a first push, or one the clone does not hold) builds
#   anything else  (tag push, schedule, workflow_dispatch) builds
# Environment: EVENT_NAME, GITHUB_REF, GITHUB_EVENT_PATH, BASE_SHA, HEAD_SHA (default HEAD), GITHUB_OUTPUT.
set -eu

EVENT_NAME="${EVENT_NAME:-}"
GITHUB_REF="${GITHUB_REF:-}"
BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-HEAD}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"
PATHS="configs/portage/world configs/portage/versions.lock configs/overlay scripts rootfs"

build=true
case "$EVENT_NAME" in
    pull_request)
        : "${GITHUB_EVENT_PATH:?pull_request needs GITHUB_EVENT_PATH}"
        build=$(jq -r 'if ([.pull_request.labels[].name] | index("full-ci")) != null then "true" else "false" end' "$GITHUB_EVENT_PATH")
        ;;
    push)
        case "$GITHUB_REF" in
            refs/tags/*) ;;
            *)
                case "$BASE_SHA" in
                    ''|0000000000000000000000000000000000000000) ;;
                    *)
                        if git cat-file -e "${BASE_SHA}^{commit}" && git cat-file -e "${HEAD_SHA}^{commit}"; then
                            # shellcheck disable=SC2086 # PATHS is a list of words
                            if [ -n "$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" -- $PATHS)" ]; then build=true; else build=false; fi
                        fi
                        ;;
                esac
                ;;
        esac
        ;;
esac
echo "changed-paths: build=$build"
echo "build=$build" >> "$OUT"
