#!/bin/bash
#
# update-build-pins.sh - propose a new Gentoo tree pin, or a new builder toolchain
#
# The tree pin is the four Makefile lines TREE_COMMIT, TREE_DIGEST, SOURCE_DATE_EPOCH and TREE_FILES
# (docs/tree-pin.md, docs/version-pinning.md). The toolchain pins are ARG TOOLCHAIN_EPOCH (Dockerfile), the Makefile's
# TREE_COMMIT_TOOLCHAIN and TREE_DIGEST_TOOLCHAIN, BUILDER_DIGEST and configs/portage/crossdev.lock
# (.github/workflows/toolchain-bump.yml).
#
# Runs on the host or in the toolbox (git, curl, oras, zstd, jq, python3); only crossdev-lock needs Docker.
#
# Usage:
#   update-build-pins.sh check            # newest commit of gentoo-mirror/gentoo (or $TARGET_COMMIT)
#   update-build-pins.sh update <commit>  # write the four pin lines for an archived commit
#   update-build-pins.sh update-toolchain <commit> [YYYYMMDD]
#                                         # write the two toolchain tree pins for an archived commit; a changed
#                                         # TOOLCHAIN_EPOCH (latest stage3 tag, or the given date) is refused until
#                                         # the Dockerfile's stage3 digest is updated
#   update-build-pins.sh crossdev-lock    # regenerate crossdev.lock from the monolith-builder image
#   update-build-pins.sh set-builder <sha256:digest>   # write BUILDER_DIGEST
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
DOCKERFILE="${SCRIPT_DIR}/../Dockerfile"
CROSSDEV_LOCK="${SCRIPT_DIR}/../configs/portage/crossdev.lock"
CONFIGS_DIR="$(cd "${SCRIPT_DIR}/../configs" && pwd)"
BUILDER_IMAGE="monolith-builder"
DOCKERHUB_TAGS_URL="https://hub.docker.com/v2/repositories/gentoo/stage3/tags?page_size=100&ordering=last_updated&name=amd64-openrc-"
TREE_SOURCE_URL="https://github.com/gentoo-mirror/gentoo.git"
COMMITS_API="https://api.github.com/repos/gentoo-mirror/gentoo/commits"
work=""

usage() {
    echo "Usage: $0 check | update <commit40> | update-toolchain <commit40> [YYYYMMDD] | crossdev-lock | set-builder <digest>"
    echo ""
    echo "Commands:"
    echo "  check              Show the newest gentoo-mirror/gentoo commit (\$TARGET_COMMIT overrides it)"
    echo "                     against TREE_COMMIT; NO-OP when they are equal"
    echo "  update <commit40>  Write TREE_COMMIT, TREE_DIGEST, SOURCE_DATE_EPOCH and TREE_FILES"
    echo "                     for a commit already archived as gentoo-tree:<commit40>"
    echo "  update-toolchain <commit40> [YYYYMMDD]"
    echo "                     Write TREE_COMMIT_TOOLCHAIN and TREE_DIGEST_TOOLCHAIN for a commit already archived as"
    echo "                     gentoo-tree:<commit40>; a changed TOOLCHAIN_EPOCH (the latest stage3 tag, or the given"
    echo "                     date) is refused until the Dockerfile's stage3 digest is updated"
    echo "  crossdev-lock      Regenerate crossdev.lock from the monolith-builder image (needs Docker)"
    echo "  set-builder <sha256:digest>  Write BUILDER_DIGEST"
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
    sed -i "s/^${name} :=.*/${name} := ${value}/" "${MAKEFILE}"
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

# Read the current value of an ARG pin (TOOLCHAIN_EPOCH) from the Dockerfile
get_current_pin() {
    local name="$1"
    grep "^ARG ${name}=" "${DOCKERFILE}" | cut -d= -f2
}

# Fetch the latest amd64-openrc stage3 date tag from Docker Hub
fetch_latest_stage3_date() {
    local url="${DOCKERHUB_TAGS_URL}"
    local latest_date=""

    while [[ -n "${url}" ]]; do
        local response
        response=$(curl -fsSL "${url}") || {
            echo "ERROR: Failed to fetch Docker Hub tags" >&2
            return 1
        }

        local page_latest
        page_latest=$(python3 -c "
import json, sys, re
data = json.load(sys.stdin)
pattern = re.compile(r'^amd64-openrc-(\d{8})$')
dates = []
for tag in data.get('results', []):
    m = pattern.match(tag['name'])
    if m:
        dates.append(m.group(1))
dates.sort(reverse=True)
print(dates[0] if dates else '')
" <<< "${response}")

        if [[ -n "${page_latest}" ]]; then
            if [[ -z "${latest_date}" ]] || [[ "${page_latest}" > "${latest_date}" ]]; then
                latest_date="${page_latest}"
            fi
            break
        fi

        url=$(python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('next') or '')
" <<< "${response}")
    done

    echo "${latest_date}"
}

# Query the best available (visible) version of a package from the builder image's
# portage tree. Works whether or not the package is installed on the builder system.
query_portage_version() {
    local atom="$1"
    local strip_prefix="$2"
    if ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
        return 0
    fi
    # Two things this docker run must get right:
    #  1. Mount /configs — the builder image's repos.conf points the 'monolith'
    #     overlay at /configs/overlay, so without it portageq aborts with
    #     "nonexistent directory: '/configs/overlay'" (empty output, non-zero).
    #  2. Constrain keywords to '*/* ~*' — the builder image ships '*/* **',
    #     which accepts LIVE 9999 ebuilds, so an unconstrained best_visible pins
    #     e.g. sys-devel/gcc-15.3.9999 (a non-reproducible live ebuild). '~*'
    #     keeps testing across arches but drops live ebuilds (they need '**').
    #     Mirrors update-versions.sh's setup_keywords().
    # Trailing '|| true' keeps a transient/partial query failure from aborting
    # the whole bump under 'set -euo pipefail' — update_crossdev_lock() falls
    # back to the current pins when this returns empty (see its empty guard).
    docker run --rm -v "${CONFIGS_DIR}:/configs" "${BUILDER_IMAGE}" sh -euc '
        kw=/etc/portage/package.accept_keywords/crossdev-all
        if [ -f "$kw" ] && grep -qF "**" "$kw"; then echo "*/* ~*" > "$kw"; fi
        portageq best_visible / "$1"
    ' _ "${atom}" 2>/dev/null | sed "s|${strip_prefix}||" || true
}

# Update crossdev.lock with best versions from the current builder image.
# NOTE: the builder's portage tree reflects the previous BUILD_EPOCH (one epoch behind
# the newly-set one). Versions advance on the next update-build-pins cycle.
update_crossdev_lock() {
    if ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
        echo "  WARNING: ${BUILDER_IMAGE} image not found — skipping crossdev.lock update"
        return 0
    fi

    echo "  Querying builder image for crossdev package versions..."

    local musl_ver gcc_ver
    musl_ver=$(query_portage_version "sys-libs/musl" "sys-libs/musl-")
    local gcc_major
    gcc_major=$(grep '^sys-devel/gcc:' "${CROSSDEV_LOCK}" 2>/dev/null | cut -d: -f3 || echo "15")
    gcc_ver=$(query_portage_version "=sys-devel/gcc-${gcc_major}*" "sys-devel/gcc-")

    if [[ -z "${musl_ver}" && -z "${gcc_ver}" ]]; then
        echo "  WARNING: Could not query portage versions — crossdev.lock unchanged"
        return 0
    fi

    local current_musl current_gcc
    current_musl=$(grep '^sys-libs/musl:' "${CROSSDEV_LOCK}" | cut -d: -f2 || true)
    current_gcc=$(grep '^sys-devel/gcc:' "${CROSSDEV_LOCK}" | cut -d: -f2 || true)

    local changed=0
    [[ -n "${musl_ver}" && "${musl_ver}" != "${current_musl}" ]] && changed=1
    [[ -n "${gcc_ver}"  && "${gcc_ver}"  != "${current_gcc}"  ]] && changed=1

    if [[ "${changed}" -eq 0 ]]; then
        echo "  crossdev.lock already up to date"
        return 0
    fi

    musl_ver="${musl_ver:-${current_musl}}"
    gcc_ver="${gcc_ver:-${current_gcc}}"
    local gcc_slot="${gcc_ver%%.*}"

    cat > "${CROSSDEV_LOCK}" << EOF
# crossdev.lock — Cross-toolchain version pins
#
# Updated by: make update-build-pins
# Applied by: make build-image (passed to crossdev --libc / --gcc)
#
# linux-headers derived from kernel pin in versions.lock (major.minor).
# binutils read from versions.lock (world package, kept in sync automatically).
#
# Format: category/package:version:slot  (same as versions.lock)

sys-libs/musl:${musl_ver}:0
sys-devel/gcc:${gcc_ver}:${gcc_slot}
EOF

    [[ -n "${musl_ver}" && "${musl_ver}" != "${current_musl}" ]] && \
        echo "  sys-libs/musl: ${current_musl} → ${musl_ver}"
    [[ -n "${gcc_ver}"  && "${gcc_ver}"  != "${current_gcc}"  ]] && \
        echo "  sys-devel/gcc: ${current_gcc} → ${gcc_ver}"
}

# Command: update-toolchain <commit40> [YYYYMMDD]
# Writes the tree the image bakes in: TREE_COMMIT_TOOLCHAIN and TREE_DIGEST_TOOLCHAIN, for a commit already archived as
# gentoo-tree:<commit>. A changed TOOLCHAIN_EPOCH (the builder image's stage3 pin) is refused until the Dockerfile's
# stage3 digest is updated.
# The image must then be rebuilt (make build-image). This does not touch SOURCE_DATE_EPOCH or the runtime tree pin.
cmd_update_toolchain() {
    echo "==> Updating the toolchain pins (TOOLCHAIN_EPOCH, TREE_COMMIT_TOOLCHAIN, TREE_DIGEST_TOOLCHAIN)"

    local commit="${1:-}" forced_date="${2:-}"
    if ! is_commit "${commit}"; then
        echo "ERROR: update-toolchain needs a commit of 40 hex digits, got: '${commit}'" >&2
        usage
    fi
    local current_epoch latest_date
    current_epoch=$(get_current_pin TOOLCHAIN_EPOCH)

    if [[ -n "${forced_date}" ]]; then
        if ! [[ "${forced_date}" =~ ^[0-9]{8}$ ]]; then
            echo "ERROR: forced target epoch must be YYYYMMDD, got: ${forced_date}" >&2
            exit 1
        fi
        echo "  Using forced target epoch: ${forced_date}"
        latest_date="${forced_date}"
    else
        echo "  Fetching latest stage3 amd64-openrc tag from Docker Hub..."
        latest_date=$(fetch_latest_stage3_date)

        if [[ -z "${latest_date}" ]]; then
            echo "ERROR: Could not fetch latest stage3 date — network issue?" >&2
            exit 1
        fi
    fi

    # A new epoch needs a new stage3 digest in the Dockerfile FROM and a mirror first: the FROM resolves by digest, so
    # changing only the ARG would build the old stage3 under the new epoch's name.
    if [[ "${current_epoch}" != "${latest_date}" ]]; then
        echo "ERROR: TOOLCHAIN_EPOCH ${current_epoch} -> ${latest_date}: a new epoch needs a new stage3 digest in the Dockerfile FROM and a mirror first (docs/version-pinning.md, 'The toolchain bump'). Dispatch with first_rebuild." >&2
        exit 1
    fi

    # Fail closed: the tree must be archived. An empty answer or an error from the registry is a failure.
    local ref digest
    ref="$(get_registry)/gentoo-tree"
    echo "  Verifying ${ref}:${commit} exists..."
    digest=$(oras manifest fetch --descriptor "${ref}:${commit}" | jq -r '.digest // empty')
    if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "ERROR: no digest for ${ref}:${commit} (got '${digest}') — is the tree archived?" >&2
        exit 1
    fi

    set_pin TREE_COMMIT_TOOLCHAIN "${commit}"
    set_pin TREE_DIGEST_TOOLCHAIN "${digest}"
    echo "  TREE_COMMIT_TOOLCHAIN: ${commit}"
    echo "  TREE_DIGEST_TOOLCHAIN: ${digest}"

    if [[ "${current_epoch}" == "${latest_date}" ]]; then
        echo "  TOOLCHAIN_EPOCH already up to date: ${current_epoch}"
    else
        # Unreachable while the guard above stands; it stays for when the stage3 digest moves with the epoch.
        echo "  Updating TOOLCHAIN_EPOCH: ${current_epoch} → ${latest_date}"
        sed -i "s/^ARG TOOLCHAIN_EPOCH=.*/ARG TOOLCHAIN_EPOCH=${latest_date}/" "${DOCKERFILE}"
        # Fail closed: assert the sed actually applied before continuing.
        local applied_epoch
        applied_epoch=$(get_current_pin TOOLCHAIN_EPOCH)
        if [[ "${applied_epoch}" != "${latest_date}" ]]; then
            echo "ERROR: TOOLCHAIN_EPOCH sed did not apply — Dockerfile shows '${applied_epoch}', expected '${latest_date}'" >&2
            exit 1
        fi
    fi

    echo ""
    echo "==> Done. Run 'make build-image' to rebuild the toolchain image with the new base and tree."
}

# Command: set-builder <digest>
cmd_set_builder() {
    local digest="${1:-}"
    if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "ERROR: set-builder needs sha256:<64 hex>, got: '${digest}'" >&2
        exit 1
    fi
    set_pin BUILDER_DIGEST "${digest}"
}

# Main
case "${1:-}" in
    check)  cmd_check ;;
    update) cmd_update "${2:-}" ;;
    update-toolchain) cmd_update_toolchain "${2:-}" "${3:-}" ;;
    crossdev-lock) update_crossdev_lock ;;
    set-builder) cmd_set_builder "${2:-}" ;;
    *)      usage ;;
esac
