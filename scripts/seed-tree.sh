#!/bin/sh
# One-time seed of the pinned Gentoo tree: seed-tree.sh [--oci-layout DIR] <commit40>
# Fetches only that commit from $TREE_SOURCE, archives it (git archive | zstd) and pushes it as
# $REGISTRY/gentoo-tree:<commit40> (or into an OCI layout DIR). Refuses an existing tag.
# Prints `signature: good|bad|unsigned|key-missing` (only bad fails) and the manifest digest.
set -eu

layout=
if [ "${1:-}" = "--oci-layout" ]; then
    layout=${2:?seed-tree: --oci-layout needs a directory}; shift 2
    layout=$(mkdir -p "$layout" && cd "$layout" && pwd)
fi
commit=${1:-}
case $commit in
    *[!0-9a-f]*|"") echo "seed-tree: '$commit' is not 40 hex digits" >&2; exit 2;;
esac
[ ${#commit} -eq 40 ] || { echo "seed-tree: '$commit' is not 40 hex digits" >&2; exit 2; }
if [ -n "$layout" ]; then
    ref="$layout:$commit"; set -- --oci-layout
else
    : "${REGISTRY:?seed-tree: REGISTRY must be set}"
    ref="$REGISTRY/gentoo-tree:$commit"; set --
fi

if oras manifest fetch "$@" "$ref" >/dev/null 2>&1; then
    echo "seed-tree: $ref already exists; refusing to overwrite it" >&2; exit 1
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT INT TERM
cd "$work"
git init -q tree && cd tree
git fetch -q --depth 1 "${TREE_SOURCE:-https://github.com/gentoo-mirror/gentoo.git}" "$commit"

key=/usr/share/openpgp-keys/gentoo-release.asc
if ! git cat-file commit "$commit" | grep -q '^gpgsig'; then sig=unsigned
elif ! command -v gpg >/dev/null 2>&1 || [ ! -f "$key" ]; then sig=key-missing
else
    GNUPGHOME=$work/gnupg; export GNUPGHOME; mkdir -m 700 "$GNUPGHOME"
    gpg --batch -q --import "$key"
    if git verify-commit "$commit" >/dev/null 2>&1; then sig=good; else sig=bad; fi
fi
echo "signature: $sig"
[ "$sig" != bad ] || { echo "seed-tree: bad signature on $commit" >&2; exit 1; }

file=gentoo-tree-$commit.tar.zst
created=$(TZ=UTC0 git log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ "$commit")
git archive --format=tar "$commit" | zstd -q -19 -T1 > "$work/$file"
cd "$work"
oras push "$@" "$ref" --artifact-type application/vnd.themonolith.gentoo-tree.v1 \
    --annotation "org.opencontainers.image.created=$created" \
    "$file:application/vnd.themonolith.gentoo-tree.layer.v1.tar+zstd" > push.out
digest=$(grep -Eo 'sha256:[0-9a-f]{64}' push.out | tail -n 1)
echo "digest: $digest"
