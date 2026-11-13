#!/bin/bash
#
# update-build-pins.sh - propose a new Gentoo tree pin
#
# The tree pin is the four Makefile lines TREE_COMMIT, TREE_DIGEST, SOURCE_DATE_EPOCH and TREE_FILES
# (docs/tree-pin.md, docs/version-pinning.md). The stage3 and builder pins are not touched here.
#
# Runs on the host or in the toolbox (git, curl, oras, zstd, jq); it needs no Docker.
#
# Usage:
#   update-build-pins.sh check            # newest commit of gentoo-mirror/gentoo (or $TARGET_COMMIT)
#   update-build-pins.sh update <commit>  # write the four pin lines for an archived commit
#
# check prints NO-OP and exits 0 when the newest commit is TREE_COMMIT; otherwise it prints that commit.
# With $GITHUB_OUTPUT set it appends update_available=true|false, commit=<c40> and current=<TREE_COMMIT>;
# a NO-OP is also written to $GITHUB_STEP_SUMMARY.
# update reads the digest of $REGISTRY/gentoo-tree:<commit> and its committer time (the manifest's
# org.opencontainers.image.created, else the GitHub commits API), counts the files of the archive
# and rewrites the four lines. It never writes to the registry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKEFILE="${SCRIPT_DIR}/../Makefile"
TREE_SOURCE_URL="https://github.com/gentoo-mirror/gentoo.git"
COMMITS_API="https://api.github.com/repos/gentoo-mirror/gentoo/commits"
work=""

usage() {
    echo "Usage: $0 check | update <commit40>"
    echo ""
    echo "Commands:"
    echo "  check              Show the newest gentoo-mirror/gentoo commit (\$TARGET_COMMIT overrides it)"
    echo "                     against TREE_COMMIT; NO-OP when they are equal"
    echo "  update <commit40>  Write TREE_COMMIT, TREE_DIGEST, SOURCE_DATE_EPOCH and TREE_FILES"
    echo "                     for a commit already archived as gentoo-tree:<commit40>"
    exit 1
}

is_commit() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# Read the value of a NAME := value line of the Makefile
get_pin() {
    sed -n "s/^$1[[:space:]]*:=[[:space:]]*//p" "${MAKEFILE}" | head -n 1
}

# Read the REGISTRY default from the Makefile unless the environment sets it
get_registry() {
    if [[ -n "${REGISTRY:-}" ]]; then
        echo "${REGISTRY}"
    else
        sed -n 's/^REGISTRY[[:space:]]*?=[[:space:]]*//p' "${MAKEFILE}" | head -n 1
    fi
}

# Rewrite one NAME := value line and fail closed if it did not apply
set_pin() {
    local name="$1" value="$2" applied
    sed -i "s/^${name} := .*/${name} := ${value}/" "${MAKEFILE}"
    applied=$(get_pin "${name}")
    if [[ "${applied}" != "${value}" ]]; then
        echo "ERROR: ${name} sed did not apply — Makefile shows '${applied}', expected '${value}'" >&2
        exit 1
    fi
}

# The newest commit of the mirror's default branch
fetch_newest_commit() {
    git ls-remote "${TREE_SOURCE_URL}" HEAD | awk '$2 == "HEAD" { print $1; exit }'
}

# Command: check
cmd_check() {
    local current newest
    current=$(get_pin TREE_COMMIT)
    if [[ -n "${TARGET_COMMIT:-}" ]]; then
        if ! is_commit "${TARGET_COMMIT}"; then
            echo "ERROR: target_commit must be 40 hex digits, got: ${TARGET_COMMIT}" >&2
            exit 1
        fi
        newest="${TARGET_COMMIT}"
    else
        newest=$(fetch_newest_commit)
    fi
    if ! is_commit "${newest}"; then
        echo "ERROR: could not read the newest commit of gentoo-mirror/gentoo (got '${newest}')" >&2
        exit 1
    fi

    local available=true
    if [[ "${newest}" == "${current}" ]]; then
        available=false
        echo "NO-OP: the newest commit ${newest} is TREE_COMMIT"
        if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
            echo "NO-OP: the newest gentoo-mirror/gentoo commit ${newest} is TREE_COMMIT; no branch, label or PR." >> "${GITHUB_STEP_SUMMARY}"
        fi
    else
        echo "${newest}"
    fi
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "update_available=${available}"
            echo "commit=${newest}"
            echo "current=${current}"
        } >> "${GITHUB_OUTPUT}"
    fi
}

# The committer time of a commit, as an ISO 8601 string
commit_time() {
    local ref="$1" commit="$2" created=""
    created=$(oras manifest fetch "${ref}:${commit}" | jq -r '.annotations["org.opencontainers.image.created"] // empty') || created=""
    if [[ -z "${created}" ]]; then
        created=$(curl -fsSL "${COMMITS_API}/${commit}" | jq -r '.commit.committer.date // empty')
    fi
    echo "${created}"
}

# Command: update <commit40>
cmd_update() {
    local commit="${1:-}"
    if ! is_commit "${commit}"; then
        echo "ERROR: update needs a commit of 40 hex digits, got: '${commit}'" >&2
        usage
    fi
    local current
    current=$(get_pin TREE_COMMIT)
    if [[ "${commit}" == "${current}" ]]; then
        echo "NO-OP: ${commit} is already TREE_COMMIT"
        return 0
    fi

    local registry ref
    registry=$(get_registry)
    ref="${registry}/gentoo-tree"

    echo "==> Reading ${ref}:${commit}"
    local digest
    digest=$(oras manifest fetch --descriptor "${ref}:${commit}" | jq -r '.digest // empty')
    if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "ERROR: no digest for ${ref}:${commit} (got '${digest}') — is the tree archived?" >&2
        exit 1
    fi

    local created epoch
    created=$(commit_time "${ref}" "${commit}")
    if [[ -z "${created}" ]] || ! epoch=$(date -u -d "${created}" +%s); then
        echo "ERROR: could not read the committer time of ${commit}" >&2
        exit 1
    fi

    local files
    work=$(mktemp -d)
    trap 'rm -rf "${work}"' EXIT
    oras pull -o "${work}" "${ref}@${digest}" >&2
    files=$(zstd -dc "${work}/gentoo-tree-${commit}.tar.zst" | tar -tf - | grep -v '/$' | wc -l | tr -d ' ')
    if [[ "${files}" -le 0 ]]; then
        echo "ERROR: the archive of ${commit} lists no files" >&2
        exit 1
    fi

    echo "  TREE_COMMIT:       ${current} → ${commit}"
    echo "  TREE_DIGEST:       ${digest}"
    echo "  SOURCE_DATE_EPOCH: ${epoch} (${created})"
    echo "  TREE_FILES:        ${files}"
    set_pin TREE_COMMIT "${commit}"
    set_pin TREE_DIGEST "${digest}"
    set_pin SOURCE_DATE_EPOCH "${epoch}"
    set_pin TREE_FILES "${files}"

    echo ""
    echo "==> Done. Run 'make sync-portage update-versions' to regenerate versions.lock against the new tree."
}

# Main
case "${1:-}" in
    check)  cmd_check ;;
    update) cmd_update "${2:-}" ;;
    *)      usage ;;
esac
