#!/bin/sh
# Prints what is in the builder image: its packages, compilers, scanners and Rust toolchain.
# Usage: builder-manifest.sh [IMAGE_REF]   (the engine is $DOCKER, default docker)
set -eu
mk=$(dirname "$0")/../Makefile
mkvar() { sed -n "s/^$1[ ]*[?:]*=[ ]*//p" "$mk"; }
REGISTRY=${REGISTRY:-$(mkvar REGISTRY)}
ref=${1:-$REGISTRY/builder@$(mkvar BUILDER_DIGEST)}
engine=${DOCKER:-docker}
echo "image: $ref"
$engine image inspect "$ref"
echo "== qlist -Iv"; $engine run --rm "$ref" qlist -Iv
echo "== i486-linux-musl-gcc"; $engine run --rm "$ref" i486-linux-musl-gcc --version
echo "== syft"; $engine run --rm "$ref" syft --version
echo "== grype"; $engine run --rm "$ref" grype --version
echo "== rustup"; $engine run --rm "$ref" rustup toolchain list
