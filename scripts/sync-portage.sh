#!/bin/sh
# Restore the pinned Gentoo tree from the registry, by digest. The tree is the archive that
# scripts/seed-tree.sh pushed once for TREE_COMMIT: $TREE_REF@$TREE_DIGEST holds one file,
# gentoo-tree-$TREE_COMMIT.tar.zst. A missing artifact, a digest that is not the pin, or an
# unreadable archive fails LOUD, so every build sees exactly the same tree.
#   env: REGISTRY, TREE_COMMIT, TREE_DIGEST (required); TREE_REF (default $REGISTRY/gentoo-tree);
#        TREE_DIR (target, default /var/db/repos/gentoo; replaced, not merged;
#        empty or / is refused)
set -u

restore_tree() {
    for _v in TREE_COMMIT TREE_DIGEST REGISTRY; do
        eval "_val=\${$_v:-}"
        if [ -z "$_val" ]; then
            echo "sync-portage: $_v must be set" >&2
            return 1
        fi
    done
    _ref="${TREE_REF:-$REGISTRY/gentoo-tree}@$TREE_DIGEST"
    _file="gentoo-tree-$TREE_COMMIT.tar.zst"
    _dir="${TREE_DIR-/var/db/repos/gentoo}"
    while [ "${_dir%/}" != "$_dir" ]; do _dir="${_dir%/}"; done
    if [ -z "$_dir" ]; then
        echo "sync-portage: FATAL - TREE_DIR is empty or /; refusing to replace it" >&2
        return 1
    fi
    _tmp=$(mktemp -d) || return 1
    if ! oras pull -o "$_tmp" "$_ref" >"$_tmp.log" 2>&1; then
        echo "sync-portage: FATAL - cannot pull $_ref" >&2
        cat "$_tmp.log" >&2
        rm -rf "$_tmp" "$_tmp.log"
        return 1
    fi
    rm -f "$_tmp.log"
    if [ "$(find "$_tmp" -type f | wc -l)" -ne 1 ] || [ ! -f "$_tmp/$_file" ]; then
        echo "sync-portage: FATAL - $_ref does not hold exactly $_file (digest or commit mismatch)" >&2
        rm -rf "$_tmp"
        return 1
    fi
    if ! zstd -t -q "$_tmp/$_file" || [ -z "$(zstd -dc "$_tmp/$_file" | tar -tf - | head -n 1)" ]; then
        echo "sync-portage: FATAL - $_file from $_ref is empty or unreadable" >&2
        rm -rf "$_tmp"
        return 1
    fi
    _new="$_dir.new.$$"
    rm -rf "$_new"
    mkdir -p "$_new" || { rm -rf "$_tmp"; return 1; }
    if ! zstd -dc "$_tmp/$_file" | tar -xf - -C "$_new"; then
        echo "sync-portage: FATAL - extracting $_file from $_ref into $_new failed" >&2
        rm -rf "$_tmp" "$_new"
        return 1
    fi
    if ! rm -rf "$_dir" || ! mv "$_new" "$_dir"; then
        echo "sync-portage: FATAL - replacing TREE_DIR $_dir failed" >&2
        rm -rf "$_tmp" "$_new"
        return 1
    fi
    rm -rf "$_tmp"
    echo "sync-portage: restored $_ref into $_dir"
}

# --source-only detection: `sh`/dash's `.` (unlike bash) does not propagate
# arguments into the sourced file, so "${1:-}" alone is unreliable for detecting
# `. sync-portage.sh --source-only` under dash. $0 stays as the sourcing script's
# own path under both shells when sourced, so fall back to a basename check: if
# we're not being run as ourselves, treat it as sourced.
case "${0##*/}" in
    sync-portage.sh) sourced=0 ;;
    *) sourced=1 ;;
esac
if [ "${1:-}" = "--source-only" ] || [ "$sourced" -eq 1 ]; then
    return 0
fi

restore_tree
exit $?
