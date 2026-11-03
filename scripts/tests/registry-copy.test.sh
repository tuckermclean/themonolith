#!/bin/sh
# registry-copy: copies an image or artifact into $REGISTRY by digest, with a stub oras.
# No network or registry is used.
#
# CONTRACT:
#   scripts/registry-copy.sh <source>@sha256:<64 hex> <name>:<tag>, REGISTRY from the environment.
#   Refuses a source not pinned by digest and a destination not <name>:<tag>, before calling oras.
#   With GITHUB_TOKEN set, logs in to REGISTRY's host with --password-stdin (the token never in argv).
#   Runs oras cp <source> $REGISTRY/<name>:<tag>, then fails unless that tag's manifest digest
#   equals the source digest.
#   Makefile: registry-copy runs the script in the toolbox with SRC, DST and REGISTRY.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SCRIPT="$ROOT/scripts/registry-copy.sh"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }

D=sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa
OTHER=sha256:0000000000000000000000000000000000000000000000000000000000000000
SRC=src.example/owner/old-builder@$D
REG=registry.example/owner/repo

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
LOG="$TMP/oras.log"

# Stub oras: ORAS_DIGEST is what manifest fetch reports; ORAS_CP=fail makes cp fail.
cat > "$BIN/oras" <<STUB
#!/bin/sh
echo "\$*" >> "$LOG"
case "\$1" in
    login) cat > "$TMP/stdin"; exit 0 ;;
    cp) [ "\${ORAS_CP:-ok}" = fail ] && { echo "stub: cp denied" >&2; exit 1; }; exit 0 ;;
    manifest) printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":1}\n' "\${ORAS_DIGEST:-$D}"; exit 0 ;;
esac
exit 3
STUB
chmod +x "$BIN/oras"

run() { # run <args...>: runs the script with the stub, output in $TMP/out, exit code in $rc
    : > "$LOG"
    env PATH="$BIN:$PATH" REGISTRY="$REG" sh "$SCRIPT" "$@" > "$TMP/out" 2>&1; rc=$?
}

if [ ! -f "$SCRIPT" ]; then
    fail "scripts/registry-copy.sh exists"
else
    for bad in "src.example/owner/old-builder:latest" "src.example/owner/old-builder@sha256:abc" "src.example/owner/old-builder@md5:$D"; do
        run "$bad" builder:rc1
        [ "$rc" -ne 0 ] && [ ! -s "$LOG" ] && ok "source '$bad' refused before oras runs" \
            || fail "source '$bad' refused before oras runs (rc=$rc, oras: $(cat "$LOG"))"
    done
    for bad in builder "builder:" ":rc1" "Builder:rc1" "builder:rc1 x"; do
        run "$SRC" "$bad"
        [ "$rc" -ne 0 ] && [ ! -s "$LOG" ] && ok "destination '$bad' refused before oras runs" \
            || fail "destination '$bad' refused before oras runs (rc=$rc, oras: $(cat "$LOG"))"
    done
    run "$SRC"
    [ "$rc" -ne 0 ] && [ ! -s "$LOG" ] && ok "one argument refused" || fail "one argument refused (rc=$rc)"

    run "$SRC" builder:rc1
    [ "$rc" -eq 0 ] && ok "copy with a matching digest exits 0" || fail "copy with a matching digest exits 0 (rc=$rc: $(cat "$TMP/out"))"
    grep -qx "cp $SRC $REG/builder:rc1" "$LOG" && ok "oras cp <source> \$REGISTRY/<name:tag>" \
        || fail "oras cp <source> \$REGISTRY/<name:tag> (oras: $(cat "$LOG"))"
    grep -q "^manifest fetch --descriptor $REG/builder:rc1\$" "$LOG" && ok "the destination's digest is read back" \
        || fail "the destination's digest is read back (oras: $(cat "$LOG"))"
    grep -q "$D" "$TMP/out" && ok "the copied digest is printed" || fail "the copied digest is printed"
    grep -q '^login' "$LOG" && fail "no login without GITHUB_TOKEN" || ok "no login without GITHUB_TOKEN"

    run "$SRC" themonolith-x/rc1-binpkgs:20260811
    grep -qx "cp $SRC $REG/themonolith-x/rc1-binpkgs:20260811" "$LOG" && ok "a nested name is allowed" \
        || fail "a nested name is allowed (rc=$rc, oras: $(cat "$LOG"))"

    ORAS_DIGEST=$OTHER run "$SRC" builder:rc1
    [ "$rc" -ne 0 ] && grep -q "$OTHER" "$TMP/out" && grep -q "$D" "$TMP/out" \
        && ok "another digest at the destination -> non-zero, both digests named" \
        || fail "another digest at the destination -> non-zero, both digests named (rc=$rc: $(cat "$TMP/out"))"

    ORAS_CP=fail run "$SRC" builder:rc1
    [ "$rc" -ne 0 ] && ok "a failed cp -> non-zero" || fail "a failed cp -> non-zero"

    : > "$LOG"
    env PATH="$BIN:$PATH" REGISTRY="$REG" GITHUB_TOKEN=s3cr3t GITHUB_ACTOR=someone sh "$SCRIPT" "$SRC" builder:rc1 > "$TMP/out" 2>&1; rc=$?
    grep -qx "login registry.example -u someone --password-stdin" "$LOG" && [ "$(cat "$TMP/stdin")" = s3cr3t ] \
        && ok "GITHUB_TOKEN -> login to REGISTRY's host, token on stdin" \
        || fail "GITHUB_TOKEN -> login to REGISTRY's host, token on stdin (oras: $(cat "$LOG"))"
    grep -q s3cr3t "$LOG" "$TMP/out" && fail "the token is not in argv or output" || ok "the token is not in argv or output"

    mkdir -p "$TMP/empty"; : > "$LOG"
    env PATH="$TMP/empty:/usr/bin:/bin" REGISTRY="$REG" sh "$SCRIPT" "$SRC" builder:rc1 > "$TMP/out" 2>&1; rc=$?
    if [ -x /usr/bin/oras ] || [ -x /bin/oras ]; then
        ok "missing oras (skipped: oras is installed in /usr/bin or /bin)"
    else
        [ "$rc" -ne 0 ] && grep -q oras "$TMP/out" && ok "missing oras -> non-zero, says so" \
            || fail "missing oras -> non-zero, says so (rc=$rc: $(cat "$TMP/out"))"
    fi
fi

exp=$(cd "$ROOT" && make -n registry-copy SRC="$SRC" DST=builder:rc1 2>&1)
printf '%s\n' "$exp" | grep -q 'scripts/registry-copy.sh' && printf '%s\n' "$exp" | grep -qF "$SRC" \
    && printf '%s\n' "$exp" | grep -q 'builder:rc1' && printf '%s\n' "$exp" | grep -q 'REGISTRY=' \
    && ok "make registry-copy runs the script with SRC, DST and REGISTRY" \
    || fail "make registry-copy runs the script with SRC, DST and REGISTRY ($exp)"

echo
[ "$fails" -eq 0 ] && { echo "All registry-copy tests passed."; exit 0; }
echo "$fails registry-copy test(s) FAILED."; exit 1
