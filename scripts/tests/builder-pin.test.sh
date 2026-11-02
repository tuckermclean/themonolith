#!/bin/sh
# I03: the builder image is taken by digest, never built or pulled by tag in CI, and
# its contents are recorded.  Covers I03-AC-1, I03-AC-2, I03-AC-3 and the unit half
# of I03-AC-5 (the script, with a stub engine).  AC-4, AC-5 (real run) and AC-6 are
# recorded runs on the real image.  No git history, network or registry is used.
#
# CONTRACT (I03 ruling 1, 4):
#   Makefile: BUILDER_DIGEST := sha256:ab04...; DOCKER ?= docker;
#     pull-image    = $(DOCKER) pull $(REGISTRY)/builder@$(BUILDER_DIGEST), then
#                     $(DOCKER) tag <that reference> monolith-builder; no fallback build.
#     builder-manifest = sh scripts/builder-manifest.sh > output/builder-manifest.txt
#   scripts/builder-manifest.sh [IMAGE_REF]: engine from $DOCKER (default docker);
#     IMAGE_REF defaults to $REGISTRY/builder@$BUILDER_DIGEST (REGISTRY env, default
#     ghcr.io/tuckermclean/themonolith).  Runs qlist -Iv, i486-linux-musl-gcc --version,
#     syft --version, grype --version, rustup toolchain list via "$DOCKER run ... IMAGE_REF"
#     and "$DOCKER image inspect IMAGE_REF"; prints it all to stdout; exits non-zero if
#     the engine fails.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }

DIGEST=sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa
REF=ghcr.io/tuckermclean/themonolith/builder@$DIGEST

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
LOG="$TMP/docker.log"

# ---- I03-AC-1: the Dockerfile is the predecessor's, byte for byte -------------
DF="$ROOT/Dockerfile"
if [ -f "$DF" ]; then
    sum=$(sha256sum "$DF" | cut -d' ' -f1)
    [ "$sum" = 19a14861abd13739bf4c4380dea29fe3b028dc218181d43e01acb11a33f5f861 ] \
        && ok "I03-AC-1 Dockerfile sha256 is the b9f533b blob" \
        || fail "I03-AC-1 Dockerfile sha256 is $sum"
    pre=$(grep -v -e '^ARG BUILD_EPOCH=' -e '^ENV SOURCE_DATE_EPOCH=' "$DF" | sha256sum | cut -c1-12)
    [ "$pre" = d9d08d1c7422 ] \
        && ok "I03-AC-1 Dockerfile without the epoch lines hashes to d9d08d1c7422" \
        || fail "I03-AC-1 Dockerfile without the epoch lines hashes to $pre, want d9d08d1c7422"
else
    fail "I03-AC-1 Dockerfile sha256 is the b9f533b blob (Dockerfile missing)"
    fail "I03-AC-1 Dockerfile without the epoch lines hashes to d9d08d1c7422 (Dockerfile missing)"
fi

# ---- stub docker: DOCKER_MODE = ok | pullfail ---------------------------------
cat > "$BIN/docker" <<STUB
#!/bin/sh
echo "\$*" >> "$LOG"
case "\$1" in
    pull) [ "\${DOCKER_MODE:-ok}" = pullfail ] && { echo "stub: pull denied" >&2; exit 1; }; exit 0 ;;
    build|buildx) exit 0 ;;
    tag) exit 0 ;;
    image)
        [ "\${DOCKER_MODE:-ok}" = enginefail ] && exit 1
        echo '[{"RepoDigests":["$REF"]}]'; exit 0 ;;
    run)
        [ "\${DOCKER_MODE:-ok}" = enginefail ] && exit 1
        a="\$*"
        case "\$a" in *qlist*) cat "$TMP/qlist.out" ;; esac
        case "\$a" in *i486-linux-musl-gcc*) echo "i486-linux-musl-gcc (Gentoo STUB) STUBGCCVER" ;; esac
        case "\$a" in *syft*) echo "syft 1.51.0" ;; esac
        case "\$a" in *grype*) echo "grype 0.117.0" ;; esac
        case "\$a" in *rustup*) echo "stable-x86_64-unknown-linux-gnu (default)" ;; esac
        exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/docker"

# ---- I03-AC-2: pull failure is fatal, names the reference, never builds -------
: > "$LOG"
out=$(cd "$ROOT" && PATH="$BIN:$PATH" DOCKER_MODE=pullfail make pull-image 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "I03-AC-2 make pull-image exits non-zero when the pull fails" \
                || fail "I03-AC-2 make pull-image exits non-zero when the pull fails (rc=$rc)"
printf '%s\n' "$out" | grep -qF "$REF" \
    && ok "I03-AC-2 the failure output prints the digest reference" \
    || fail "I03-AC-2 the failure output prints $REF"
grep -qF "pull $REF" "$LOG" \
    && ok "I03-AC-2 docker was asked to pull the digest reference" \
    || fail "I03-AC-2 docker was asked to pull $REF (log: $(tr '\n' '|' < "$LOG"))"
if grep -Eq '^(build|buildx)( |$)' "$LOG" || ! grep -q '^pull ' "$LOG"; then
    fail "I03-AC-2 no docker build/buildx after a failed pull (and the pull was attempted)"
else ok "I03-AC-2 no docker build/buildx after a failed pull (and the pull was attempted)"; fi

# success path: pull by digest, tag monolith-builder (change 1); REGISTRY override
: > "$LOG"
(cd "$ROOT" && PATH="$BIN:$PATH" make pull-image >/dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qF "pull $REF" "$LOG" && grep -Eq "^tag $REF monolith-builder\$" "$LOG" \
    && ok "I03-AC-2 make pull-image pulls the digest reference and tags it monolith-builder" \
    || fail "I03-AC-2 make pull-image pulls the digest reference and tags it monolith-builder (rc=$rc)"
: > "$LOG"
(cd "$ROOT" && PATH="$BIN:$PATH" make pull-image REGISTRY=example.test/ns >/dev/null 2>&1)
grep -qF "pull example.test/ns/builder@$DIGEST" "$LOG" \
    && ok "I03-AC-2 the reference follows REGISTRY" \
    || fail "I03-AC-2 the reference follows REGISTRY"

# ---- I03-AC-3: no builder tag, no buildx build, one builder reference ---------
grep -qE "^BUILDER_DIGEST[ ]*:?=[ ]*${DIGEST}[ ]*\$" "$ROOT/Makefile" \
    && ok "I03-AC-3 Makefile defines BUILDER_DIGEST as rc1's digest" \
    || fail "I03-AC-3 Makefile defines BUILDER_DIGEST := $DIGEST"

# builder reference: /builder ending a path component, or monolith-builder with : or @
# (not file paths such as scripts/builder-manifest.sh, output/builder-manifest.txt)
BREF='/builder([:@"'"'"'[:space:]]|$)|monolith-builder[:@]'
bn=$(printf '%s\n' 'sh scripts/builder-manifest.sh > output/builder-manifest.txt' | grep -cE "$BREF")
bt=$(printf '%s\n' 'docker pull ghcr.io/x/builder:latest' 'docker pull ghcr.io/x/builder' | grep -cE "$BREF")
[ "$bn" -eq 0 ] && [ "$bt" -eq 2 ] \
    && ok "I03-AC-3 builder-reference pattern skips manifest paths, matches builder:tag and bare builder" \
    || fail "I03-AC-3 builder-reference pattern (paths matched=$bn, refs matched=$bt of 2)"

WF=$(ls "$ROOT"/.github/workflows/* 2>/dev/null)
bad=0
for f in $WF; do
    if grep -nE ':latest|REGISTRY_TAG|buildx build|STAGE3_DIGEST' "$f" >/dev/null; then
        fail "I03-AC-3 $(basename "$f") names a builder tag, buildx build or STAGE3_DIGEST"; bad=1
    fi
    if grep -E "$BREF" "$f" | grep -vq 'BUILDER_DIGEST'; then
        fail "I03-AC-3 $(basename "$f") names a builder other than by BUILDER_DIGEST"; bad=1
    fi
done
[ "$bad" -eq 0 ] && ok "I03-AC-3 no workflow names a builder tag, buildx build or STAGE3_DIGEST"

# CI-called targets: every target a workflow run: line passes to make, plus pull-image
# and builder-manifest (B03 calls them), expanded with make -n (prerequisites included).
targets=$(grep -hE '^[[:space:]]*(- )?run:[[:space:]]*make ' $WF 2>/dev/null \
    | sed -e 's/^[^:]*run:[[:space:]]*make //' | tr ' ' '\n' \
    | grep -E '^[a-z][a-z0-9_-]*$' | sort -u)
targets="$targets pull-image builder-manifest"
bad=0
for t in $(printf '%s\n' $targets | sort -u); do
    exp=$(cd "$ROOT" && make -n "$t" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "I03-AC-3 make -n $t expands (rc=$rc)"; bad=1; continue
    fi
    if printf '%s\n' "$exp" | grep -qE ':latest|REGISTRY_TAG|buildx build|STAGE3_DIGEST|docker build'; then
        fail "I03-AC-3 target $t references a builder tag or builds an image"; bad=1
    fi
    if printf '%s\n' "$exp" | grep -E "$BREF" | grep -vq "@$DIGEST"; then
        fail "I03-AC-3 target $t names a builder not by BUILDER_DIGEST"; bad=1
    fi
done
[ "$bad" -eq 0 ] && ok "I03-AC-3 CI-called targets name the builder only by digest and build nothing"

ATT="$ROOT/scripts/attestation.sh"
if [ -f "$ATT" ]; then
    grep -q 'STAGE3_DIGEST' "$ATT" && fail "I03-AC-3 attestation.sh reads STAGE3_DIGEST" \
        || ok "I03-AC-3 attestation.sh reads no STAGE3_DIGEST"
else
    echo "NOTE: I03-AC-3 scripts/attestation.sh is not yet ported (S01); STAGE3_DIGEST check waits for it"
fi

# ---- I03-AC-5 (unit half): scripts/builder-manifest.sh with a stub engine -----
LOCK="$ROOT/configs/portage/crossdev.lock"
gccver=$(grep '^sys-devel/gcc:' "$LOCK" 2>/dev/null | cut -d: -f2)
muslver=$(grep '^sys-libs/musl:' "$LOCK" 2>/dev/null | cut -d: -f2)
[ -n "$gccver" ] && [ -n "$muslver" ] \
    && ok "I03-AC-5 configs/portage/crossdev.lock pins gcc $gccver and musl $muslver" \
    || fail "I03-AC-5 configs/portage/crossdev.lock pins gcc and musl"
cat > "$TMP/qlist.out" <<Q
cross-i486-linux-musl/gcc-${gccver:-UNSET}
cross-i486-linux-musl/musl-${muslver:-UNSET}
sys-boot/grub-2.12
sys-boot/syslinux-6.04_pre1
dev-libs/libisoburn-1.5.6
sys-fs/squashfs-tools-4.6.1
Q
MAN="$ROOT/scripts/builder-manifest.sh"
: > "$LOG"
if [ -f "$MAN" ]; then
    m=$(cd "$ROOT" && PATH="$BIN:$PATH" DOCKER=docker sh "$MAN" 2>"$TMP/man.err"); rc=$?
else
    m=""; rc=127
fi
[ "$rc" -eq 0 ] && ok "I03-AC-5 builder-manifest.sh exits 0 with a working engine" \
                || fail "I03-AC-5 builder-manifest.sh exits 0 with a working engine (rc=$rc)"
for p in cross-i486-linux-musl/gcc-"${gccver:-UNSET}" cross-i486-linux-musl/musl-"${muslver:-UNSET}" \
         sys-boot/grub sys-boot/syslinux dev-libs/libisoburn sys-fs/squashfs-tools; do
    printf '%s\n' "$m" | grep -qF "$p" && ok "I03-AC-5 manifest lists $p" \
                                       || fail "I03-AC-5 manifest lists $p"
done
for t in STUBGCCVER "syft 1.51.0" "grype 0.117.0" "stable-x86_64-unknown-linux-gnu"; do
    printf '%s\n' "$m" | grep -qF "$t" && ok "I03-AC-5 manifest records '$t'" \
                                       || fail "I03-AC-5 manifest records '$t'"
done
printf '%s\n' "$m" | grep -qF "$DIGEST" && ok "I03-AC-5 manifest records the image inspect output (digest)" \
                                        || fail "I03-AC-5 manifest records the image inspect output (digest)"
grep -qF "$REF" "$LOG" && ok "I03-AC-5 default image is the BUILDER_DIGEST reference" \
                       || fail "I03-AC-5 default image is $REF"
: > "$LOG"
[ -f "$MAN" ] && (cd "$ROOT" && PATH="$BIN:$PATH" sh "$MAN" example.test/x@sha256:0 >/dev/null 2>&1)
grep -qF "example.test/x@sha256:0" "$LOG" && ok "I03-AC-5 an argument names the image" \
                                          || fail "I03-AC-5 an argument names the image"
if [ -f "$MAN" ]; then
    (cd "$ROOT" && PATH="$BIN:$PATH" DOCKER_MODE=enginefail sh "$MAN" >/dev/null 2>&1); rc=$?
else rc=127; fi
[ "$rc" -ne 0 ] && [ "$rc" -ne 127 ] && ok "I03-AC-5 builder-manifest.sh exits non-zero when the engine fails" \
                 || fail "I03-AC-5 builder-manifest.sh exits non-zero when the engine fails (rc=$rc)"
exp=$(cd "$ROOT" && make -n builder-manifest 2>&1)
printf '%s\n' "$exp" | grep -q 'builder-manifest\.sh' && printf '%s\n' "$exp" | grep -q 'output/builder-manifest\.txt' \
    && ok "I03-AC-5 make builder-manifest writes output/builder-manifest.txt from the script" \
    || fail "I03-AC-5 make builder-manifest writes output/builder-manifest.txt from the script"

echo
[ "$fails" -eq 0 ] && { echo "All builder-pin tests passed."; exit 0; }
echo "$fails builder-pin test(s) FAILED."; exit 1
