#!/bin/sh
# Prints what is in the builder image: its packages, compilers, scanners and Rust toolchain.
# Usage: builder-manifest.sh [IMAGE_REF]   (the engine is $DOCKER, default docker)
set -eu
REGISTRY=${REGISTRY:-ghcr.io/tuckermclean/themonolith}
digest=$(sed -n 's/^BUILDER_DIGEST[ ]*:=[ ]*//p' "$(dirname "$0")/../Makefile")
ref=${1:-$REGISTRY/builder@$digest}
engine=${DOCKER:-docker}
echo "image: $ref"
$engine image inspect "$ref"
echo "== qlist -Iv"; $engine run --rm "$ref" qlist -Iv
echo "== i486-linux-musl-gcc"; $engine run --rm "$ref" i486-linux-musl-gcc --version
echo "== syft"; $engine run --rm "$ref" syft --version
echo "== grype"; $engine run --rm "$ref" grype --version
echo "== rustup"; $engine run --rm "$ref" rustup toolchain list
