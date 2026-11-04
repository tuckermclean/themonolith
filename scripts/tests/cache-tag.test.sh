#!/bin/sh
# B01 cache tag and cache-store policy, against binpkg-store.sh with a stub oras.
#   B01-AC-1   the cache tag changes with each input, not with an unrelated file
#   B01-AC-2   push only on main, pull on PRs, neither on tags (decided by the script from the CI env)
#   B01-AC-17  (reference half) the reference is ${REGISTRY}/binpkgs:<tag>; pull classifies 404 vs 401
#
# Interface under test (chosen for B01, all via environment, no positional args):
#   binpkg-store.sh tag    prints the tag: first 16 hex of sha256 over BUILDER_DIGEST, TREE_COMMIT and a
#                          hash of make.conf, bashrc, env/, package.env/, profile/ under PORTAGE_CONFIG_DIR
#   binpkg-store.sh push   REGISTRY, BINPKG_TARBALL (blob path), the tag as above
#   binpkg-store.sh pull   REGISTRY, PKGDIR, the tag as above
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../binpkg-store.sh"
fails=0

fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- stub oras: records its argv (one line per call) in $ORAS_LOG; `pull` fails with $ORAS_PULL_ERR ---
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/oras" <<'STUB'
#!/bin/sh
echo "$*" >> "$ORAS_LOG"
case "$1" in
    pull) if [ -n "${ORAS_PULL_ERR:-}" ]; then echo "$ORAS_PULL_ERR" >&2; exit 1; fi
          # success: write one layer (a zstd-compressed tar of an empty dir) into the -o directory
          shift; out=""
          while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
          if [ -n "$out" ]; then
              mkdir -p "$out" "$out.empty.$$"
              tar -C "$out.empty.$$" -cf - . | zstd -q -f -o "$out/binpkgs.tar.zst" -
              rmdir "$out.empty.$$"
          fi ;;
esac
exit 0
STUB
chmod +x "$STUBS/oras"
ORAS_LOG="$TMP/oras.log"

# --- fixture portage config tree ---
CFGDIR="$TMP/portage"
mkdir -p "$CFGDIR/env" "$CFGDIR/package.env" "$CFGDIR/profile" "$CFGDIR/package.mask"
echo 'CFLAGS="-Os"' > "$CFGDIR/make.conf"
echo 'export FOO=1' > "$CFGDIR/bashrc"
echo 'A=1' > "$CFGDIR/env/static.conf"
echo 'net-misc/x static.conf' > "$CFGDIR/package.env/x"
echo 'sys-devel/gcc' > "$CFGDIR/profile/package.mask"
echo 'app-misc/hello' > "$CFGDIR/world"
echo 'app-misc/hello:1.0:0' > "$CFGDIR/versions.lock"
echo 'app-misc/old' > "$CFGDIR/package.mask/old"

B_DIG="sha256:1111111111111111111111111111111111111111111111111111111111111111"
T_COM="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REG="registry.invalid/team/proj"

# bs ARGS... — run the script with a clean cache environment; stdout+stderr -> $OUT, status -> $RC.
bs() {
    # EXTRA_ENV holds NAME=value assignments separated by spaces; a value may itself contain spaces
    # (ORAS_PULL_ERR=manifest unknown), so split only where a space precedes NAME= and keep each
    # assignment one argument.
    _nl='
'
    _x="$(printf '%s' "${EXTRA_ENV:-}" | sed 's/ \([A-Za-z_][A-Za-z0-9_]*=\)/\
\1/g')"
    set -- bash "$SCRIPT" "$@"
    if [ -n "$_x" ]; then
        _old_ifs="$IFS"; IFS="$_nl"; set -f
        # shellcheck disable=SC2086
        set -- $_x "$@"
        set +f; IFS="$_old_ifs"
    fi
    OUT="$(env -u GITHUB_ACTIONS -u GITHUB_REF -u GHCR_OWNER -u GITHUB_REPOSITORY_OWNER -u BUILD_EPOCH \
        PATH="$STUBS:$PATH" ORAS_LOG="$ORAS_LOG" REGISTRY="${REGISTRY_V:-$REG}" \
        BUILDER_DIGEST="${BD:-$B_DIG}" TREE_COMMIT="${TC:-$T_COM}" PORTAGE_CONFIG_DIR="$CFGDIR" \
        PKGDIR="$TMP/pkgdir" BINPKG_TARBALL="$TMP/blob/binpkgs.tar.zst" \
        "$@" 2>&1)"
    RC=$?
}

# tag_of — prints the tag the script computes (empty if it does not print a clean 16-hex tag).
tag_of() {
    OUT="$(env -u GITHUB_ACTIONS -u GITHUB_REF \
        PATH="$STUBS:$PATH" REGISTRY="$REG" \
        BUILDER_DIGEST="${BD:-$B_DIG}" TREE_COMMIT="${TC:-$T_COM}" PORTAGE_CONFIG_DIR="$CFGDIR" \
        bash "$SCRIPT" tag 2>/dev/null)"
    case "$OUT" in
        *[!0-9a-f]*|"") echo ""; return ;;
    esac
    [ "${#OUT}" -eq 16 ] && echo "$OUT" || echo ""
}

# --- B01-AC-1: the tag ---
T0="$(tag_of)"
if [ -n "$T0" ]; then pass "B01-AC-1 tag is 16 hex ($T0)"; else fail "B01-AC-1 'binpkg-store.sh tag' did not print a 16-hex tag (script missing or no tag subcommand)"; fi
T0b="$(tag_of)"
if [ -n "$T0" ] && [ "$T0" = "$T0b" ]; then pass "B01-AC-1 tag is deterministic"; else fail "B01-AC-1 tag is not deterministic / empty"; fi

# changed NAME TAG — TAG must be a valid tag that differs from T0.
changed() {
    if [ -n "$2" ] && [ -n "$T0" ] && [ "$2" != "$T0" ]; then pass "B01-AC-1 tag changes with $1"; else fail "B01-AC-1 tag does not change with $1"; fi
}

cp "$CFGDIR/bashrc" "$TMP/bashrc.orig"
echo 'export FOO=2' > "$CFGDIR/bashrc";                      changed "bashrc" "$(tag_of)"
cp "$TMP/bashrc.orig" "$CFGDIR/bashrc"

cp "$CFGDIR/make.conf" "$TMP/make.conf.orig"
echo 'CFLAGS="-O2"' > "$CFGDIR/make.conf";                   changed "make.conf" "$(tag_of)"
cp "$TMP/make.conf.orig" "$CFGDIR/make.conf"

echo 'A=2' > "$CFGDIR/env/static.conf";                      changed "a file in env/" "$(tag_of)"
echo 'A=1' > "$CFGDIR/env/static.conf"
echo 'B=1' > "$CFGDIR/env/new.conf";                         changed "a new file in env/" "$(tag_of)"
rm -f "$CFGDIR/env/new.conf"

echo 'net-misc/x other.conf' > "$CFGDIR/package.env/x";      changed "a file in package.env/" "$(tag_of)"
echo 'net-misc/x static.conf' > "$CFGDIR/package.env/x"

echo 'sys-devel/gcc sys-devel/binutils' > "$CFGDIR/profile/package.mask"; changed "a file in profile/" "$(tag_of)"
echo 'sys-devel/gcc' > "$CFGDIR/profile/package.mask"

TC=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;                 changed "TREE_COMMIT" "$(tag_of)"; unset TC
BD=sha256:2222222222222222222222222222222222222222222222222222222222222222; changed "BUILDER_DIGEST" "$(tag_of)"; unset BD

# unrelated files: same tag
echo 'app-misc/hello app-misc/world' > "$CFGDIR/world"
echo 'app-misc/hello:2.0:0' > "$CFGDIR/versions.lock"
echo 'app-misc/other' > "$CFGDIR/package.mask/other"
echo 'unrelated' > "$CFGDIR/README"
T1="$(tag_of)"
if [ -n "$T1" ] && [ "$T1" = "$T0" ]; then pass "B01-AC-1 tag unchanged for unrelated files (world, versions.lock, package.mask/, README)"; else fail "B01-AC-1 tag changed (or was empty) for unrelated files"; fi

# --- B01-AC-2: ref conditions, decided by the script ---
CI="GITHUB_ACTIONS=true"
mkdir -p "$TMP/blob"; echo blob > "$TMP/blob/binpkgs.tar.zst"

run_case() { # run_case DESC "ENV" CMD
    rm -f "$ORAS_LOG"; rm -rf "$TMP/pkgdir"
    EXTRA_ENV="$2" bs "$3"
}
pushed()  { [ -f "$ORAS_LOG" ] && grep -q '^push ' "$ORAS_LOG"; }
pulled()  { [ -f "$ORAS_LOG" ] && grep -q '^pull ' "$ORAS_LOG"; }
pkg_empty() { [ -d "$TMP/pkgdir" ] && [ -z "$(ls -A "$TMP/pkgdir")" ]; }

run_case x "$CI GITHUB_REF=refs/heads/main" push
if [ "$RC" -eq 0 ] && pushed; then pass "B01-AC-2 CI main: push calls oras push"; else fail "B01-AC-2 CI main: push should call oras push, rc=$RC"; fi

run_case x "$CI GITHUB_REF=refs/pull/1/merge" push
if [ "$RC" -eq 0 ] && ! pushed && [ -n "$OUT" ]; then pass "B01-AC-2 CI PR: push prints why, no oras push, exit 0"; else fail "B01-AC-2 CI PR: push must not call oras, exit 0 and say why (rc=$RC)"; fi

run_case x "$CI GITHUB_REF=refs/tags/v1" push
if [ "$RC" -eq 0 ] && ! pushed && [ -n "$OUT" ]; then pass "B01-AC-2 CI tag: push does nothing, exit 0"; else fail "B01-AC-2 CI tag: push must not call oras, exit 0 (rc=$RC)"; fi

run_case x "$CI GITHUB_REF=refs/pull/1/merge" pull
if [ "$RC" -eq 0 ] && pulled; then pass "B01-AC-2 CI PR: pull calls oras pull"; else fail "B01-AC-2 CI PR: pull should call oras pull, rc=$RC"; fi

run_case x "$CI GITHUB_REF=refs/heads/main" pull
if [ "$RC" -eq 0 ] && pulled; then pass "B01-AC-2 CI main: pull calls oras pull"; else fail "B01-AC-2 CI main: pull should call oras pull, rc=$RC"; fi

run_case x "$CI GITHUB_REF=refs/tags/v1" pull
if [ "$RC" -eq 0 ] && ! pulled && pkg_empty && [ -n "$OUT" ]; then pass "B01-AC-2 CI tag: pull prints why, no oras pull, PKGDIR empty, exit 0"; else fail "B01-AC-2 CI tag: pull must not call oras, leave PKGDIR empty, exit 0 (rc=$RC)"; fi

run_case x "GITHUB_REF=refs/pull/1/merge" push
if [ "$RC" -eq 0 ] && pushed; then pass "B01-AC-2 outside CI: push runs as asked"; else fail "B01-AC-2 outside CI: push should run, rc=$RC"; fi

run_case x "GITHUB_REF=refs/tags/v1" pull
if [ "$RC" -eq 0 ] && pulled; then pass "B01-AC-2 outside CI: pull runs as asked"; else fail "B01-AC-2 outside CI: pull should run, rc=$RC"; fi

# --- B01-AC-17 (reference half): ${REGISTRY}/binpkgs:<tag>, not ghcr.io/<owner>/monolith-binpkgs:<epoch> ---
TAG="$(tag_of)"
WANT_REF="$REG/binpkgs:$TAG"
run_case x "ORAS_PULL_ERR=404" pull
if [ -n "$TAG" ] && grep -q "^pull $WANT_REF\( \|\$\)" "$ORAS_LOG" 2>/dev/null; then pass "B01-AC-17 pull reference is \${REGISTRY}/binpkgs:<tag>"; else fail "B01-AC-17 pull reference is not $WANT_REF (calls: $(cat "$ORAS_LOG" 2>/dev/null))"; fi

run_case x "GHCR_OWNER=someone GITHUB_REPOSITORY_OWNER=someone BUILD_EPOCH=20260101" pull
if [ -f "$ORAS_LOG" ] && ! grep -q 'monolith-binpkgs\|someone\|20260101' "$ORAS_LOG"; then pass "B01-AC-17 GHCR_OWNER/BUILD_EPOCH no longer shape the reference"; else fail "B01-AC-17 reference still uses GHCR_OWNER/monolith-binpkgs/BUILD_EPOCH"; fi

rm -f "$ORAS_LOG"; REGISTRY_V=other.invalid/ns/p; EXTRA_ENV="" bs pull; unset REGISTRY_V
if [ -n "$TAG" ] && grep -q "^pull other.invalid/ns/p/binpkgs:$TAG" "$ORAS_LOG" 2>/dev/null; then pass "B01-AC-17 reference follows REGISTRY"; else fail "B01-AC-17 reference does not follow REGISTRY"; fi

run_case x "" push
if [ -n "$TAG" ] && grep -q "^push $WANT_REF " "$ORAS_LOG" 2>/dev/null; then pass "B01-AC-17 push reference is \${REGISTRY}/binpkgs:<tag>"; else fail "B01-AC-17 push reference is not $WANT_REF (calls: $(cat "$ORAS_LOG" 2>/dev/null))"; fi

# pull through the stub: misses are benign (0, PKGDIR empty), auth errors fatal
for e in 'manifest unknown' 'not found' 'name unknown' '404'; do
    run_case x "ORAS_PULL_ERR=$e" pull
    if [ "$RC" -eq 0 ] && pulled && pkg_empty; then pass "B01-AC-17 pull returns 0 with empty PKGDIR for '$e'"; else fail "B01-AC-17 pull should return 0 with empty PKGDIR for '$e' (rc=$RC)"; fi
done
for e in 'unauthorized' 'denied' '401'; do
    run_case x "ORAS_PULL_ERR=$e" pull
    if [ "$RC" -ne 0 ] && pulled; then pass "B01-AC-17 pull returns non-zero for '$e'"; else fail "B01-AC-17 pull should return non-zero for '$e' (rc=$RC)"; fi
done


# --- slice 1 review follow-up (ruling 16) ---

# B1 (B01-AC-17): a 401 whose text names a hex tag containing "404" is an auth error, not a benign miss.
run_case x "ORAS_PULL_ERR=Error: GET \"https://registry.invalid/v2/team/proj/binpkgs/manifests/9e6404b25dc8c1e9\": response status code 401: Unauthorized" pull
if [ "$RC" -ne 0 ] && pulled; then pass "B01-AC-17 pull is fatal for a 401 naming a tag containing 404"; else fail "B01-AC-17 pull must be fatal for a 401 naming tag 9e6404b25dc8c1e9 (rc=$RC)"; fi

# B2 (B01-AC-2, ruling 1): when .github/workflows/build.yml exists, its cache steps call the make
# targets and carry no `if:` ref condition of their own (the script decides). This passes trivially
# while build.yml is absent (it arrives with B03).
BUILD_YML="$HERE/../../.github/workflows/build.yml"
if [ ! -f "$BUILD_YML" ]; then
    pass "B01-AC-2 build.yml absent (until B03): no cache steps to check"
else
    # a cache step is a step whose name or run line mentions cache-pull/cache-push; look at the lines
    # of each such step (from its '- ' marker to the next one) for an `if:` containing github.ref.
    bad="$(awk '
        function flush() { if (blk ~ /cache-(pull|push)/ && blk ~ /(^|\n)[ \t-]*if:[^\n]*(github\.ref|GITHUB_REF)/) n++ ; blk="" }
        /^[ \t]*- / { flush() }
        { blk = blk "\n" $0 }
        END { flush(); print n+0 }' "$BUILD_YML")"
    if [ "$bad" -eq 0 ]; then pass "B01-AC-2 build.yml cache steps carry no ref condition"; else fail "B01-AC-2 build.yml has $bad cache step(s) with an if: ref condition contradicting the script"; fi
    if grep -q 'make[^#]*cache-pull' "$BUILD_YML" && grep -q 'make[^#]*cache-push' "$BUILD_YML"; then pass "B01-AC-2 build.yml calls make cache-pull and make cache-push"; else fail "B01-AC-2 build.yml must call make cache-pull and make cache-push"; fi
fi

# B3 (B01-AC-9): prune-predicate warns on stderr about a malformed path.
PP_ERR="$(printf 'net-dns/dnsmasq/not-a-gpkg\n' | bash "$SCRIPT" prune-predicate 2>&1 >/dev/null)"
if [ -n "$PP_ERR" ]; then pass "B01-AC-9 prune-predicate warns on stderr for a malformed path"; else fail "B01-AC-9 prune-predicate printed no stderr warning for a malformed path"; fi

[ "$fails" -eq 0 ] && echo ALL PASS || { echo "$fails FAILED"; exit 1; }
