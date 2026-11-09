#!/bin/sh
# repro-inputs.sh <out.json> <distfiles.tar> <builder-versions.env>: complete the environment of release-inputs.sh
# (VERSION, SOURCE_COMMIT, TREE_COMMIT, TREE_DIGEST, BUILDER_DIGEST, SOURCE_DATE_EPOCH come from the caller) with
# the distfiles archive's digest, the builder's tool versions and the toolbox's QEMU version, then write the file.
set -eu

[ $# -eq 3 ] || { echo "usage: repro-inputs.sh <out.json> <distfiles.tar> <builder-versions.env>" >&2; exit 2; }
out=$1
archive=$2
versions=$3
here=$(cd "$(dirname "$0")" && pwd)

[ -f "$archive" ] || { echo "repro-inputs: $archive is missing" >&2; exit 1; }
[ -f "$versions" ] || { echo "repro-inputs: $versions is missing" >&2; exit 1; }

set -a
. "$versions"
set +a
d=$(sha256sum "$archive")
DISTFILES_DIGEST=sha256:${d%% *}
QEMU_VERSION=$(qemu-system-i386 --version | sed -n '1s/^QEMU emulator version \([^ ]*\).*/\1/p')
export DISTFILES_DIGEST QEMU_VERSION
exec sh "$here/release-inputs.sh" "$out"
