#!/bin/sh
# R01 slice B: the advisory check fails closed, is sanitised, ships as r7, and
# its sibling scripts are linted.  Covers R01-AC-1 .. R01-AC-6.
#
# TEST SEAM (R01 ruling 3).  files/monolith-advisory-check and
# files/40-advisory.sh must honour these environment overrides, each
# defaulting to the installed path:
#   MONOLITH_RELEASE_FILE    default /etc/monolith-release           (both scripts)
#   MONOLITH_ADVISORY_STATE  default /run/monolith-advisory-state    (checker writes)
#   MONOLITH_ADVISORY_FILE   default /run/monolith-advisory          (checker writes
#                            for revoked only; 40-advisory.sh reads: the banner)
# ADVISORY_BASE_URL keeps its meaning; unset, it defaults to
# https://monolith.technomantics.com (OD-1).  curl/wget are stubs on PATH, so
# no network is used; nothing reads host /etc or /run.  No git needed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PKG="$ROOT/configs/overlay/app-misc/monolith-base"
CHECK="$PKG/files/monolith-advisory-check"
BANNER="$PKG/files/40-advisory.sh"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
CURL_LOG="$TMP/curl.log"
# stub curl: CURL_MODE = ok (copy $CURL_BODY to -o file) | 404 | fail
cat > "$BIN/curl" <<STUB
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do
    case "\$1" in -o) out="\$2"; shift ;; -*) ;; *) url="\$1" ;; esac
    shift
done
echo "\$url" >> "$CURL_LOG"
case "\${CURL_MODE:-ok}" in
    404)  exit 22 ;;
    fail) exit 7 ;;
    *)    cat "\$CURL_BODY" > "\$out"; exit 0 ;;
esac
STUB
chmod +x "$BIN/curl"
PATH="$BIN:$PATH"; export PATH

ESC=$(printf '\033')
printf '%s' 'v1.2.3' > "$TMP/release"
printf '{"status": "clean", "advisories": []}\n' > "$TMP/clean.json"
printf '{"status": "revoked", "advisories": ["CVE-2026-12345"], "details_url": "https://example.org/x"}\n' > "$TMP/revoked.json"
: > "$TMP/empty.json"
printf '<!DOCTYPE html><html><body><h1>Not Found</h1></body></html>\n' > "$TMP/html.json"

# run_check <name> <mode> <bodyfile> [releasefile]: sets RC, OUTF, STATE, BANN
run_check() {
    rm -f "$TMP/state" "$TMP/banner"
    rf="${4:-$TMP/release}"
    CURL_MODE="$2" CURL_BODY="$3" MONOLITH_RELEASE_FILE="$rf" \
    MONOLITH_ADVISORY_STATE="$TMP/state" MONOLITH_ADVISORY_FILE="$TMP/banner" \
    ADVISORY_BASE_URL="http://stub.invalid" \
        sh "$CHECK" > "$TMP/out" 2>&1
    RC=$?
}
state_is() { # name, expected
    got=$(cat "$TMP/state" 2>/dev/null; echo x); got=${got%x}
    if [ "$got" = "$2
" ] || [ "$got" = "$2" ]; then ok "AC-2 $1 writes '$2'"; else fail "AC-2 $1 writes '$2' (state: '$got')"; fi
}
silent() { # name
    if [ "$RC" = 0 ] && [ ! -s "$TMP/out" ] && [ -s "$TMP/state" ]; then ok "AC-3 $1: state written, no output, exit 0"
    else fail "AC-3 $1: state written, no output, exit 0 (rc=$RC, output: $(cat "$TMP/out"))"; fi
}

# ---- AC-1
if [ -f "$CHECK" ] && ! grep -q amazonaws "$CHECK"; then ok "AC-1 no amazonaws in the script"
else fail "AC-1 no amazonaws in the script"; fi
if [ -f "$CHECK" ] && grep -q 'https://monolith\.technomantics\.com' "$CHECK"; then ok "AC-1 default base URL in source"
else fail "AC-1 default base URL in source"; fi
: > "$CURL_LOG"
CURL_MODE=ok CURL_BODY="$TMP/clean.json" MONOLITH_RELEASE_FILE="$TMP/release" \
MONOLITH_ADVISORY_STATE="$TMP/state" MONOLITH_ADVISORY_FILE="$TMP/banner" \
    env -u ADVISORY_BASE_URL sh "$CHECK" >/dev/null 2>&1
if [ "$(tail -n1 "$CURL_LOG" 2>/dev/null)" = "https://monolith.technomantics.com/status/v1.2.3.json" ]; then
    ok "AC-1 unset ADVISORY_BASE_URL fetches https://monolith.technomantics.com/status/<tag>.json"
else fail "AC-1 unset ADVISORY_BASE_URL fetches https://monolith.technomantics.com/status/<tag>.json (asked: '$(cat "$CURL_LOG" 2>/dev/null)')"; fi

# ---- AC-2 / AC-3
run_check 404 404 "$TMP/clean.json";      state_is "HTTP 404" unknown;     silent "HTTP 404"
run_check empty ok "$TMP/empty.json";     state_is "empty body" unknown;   silent "empty body"
run_check html ok "$TMP/html.json";       state_is "HTML page" unknown;    silent "HTML page"
run_check failed fail "$TMP/clean.json";  state_is "failed fetch" unknown; silent "failed fetch"
: > "$TMP/emptytag"
run_check notag ok "$TMP/clean.json" "$TMP/nonexistent"
state_is "missing release file" unknown; silent "missing release file"
run_check emptytag ok "$TMP/clean.json" "$TMP/emptytag"
state_is "empty release tag" unknown; silent "empty release tag"
run_check clean ok "$TMP/clean.json";     state_is "clean status" clean;   silent "clean status"
if [ ! -e "$TMP/banner" ]; then ok "AC-2 clean writes no banner file"; else fail "AC-2 clean writes no banner file"; fi
run_check revoked ok "$TMP/revoked.json"; state_is "revoked status" revoked; silent "revoked status"
if [ -f "$TMP/banner" ] && grep -q '"revoked"' "$TMP/banner"; then ok "AC-2 revoked writes the banner file"
else fail "AC-2 revoked writes the banner file"; fi
run_check 404b 404 "$TMP/clean.json"
if [ ! -e "$TMP/banner" ]; then ok "AC-2 404 writes no banner file"; else fail "AC-2 404 writes no banner file"; fi

# ---- AC-4: control bytes in details_url never reach the terminal
printf '{"status": "revoked", "advisories": ["CVE-2026-1"], "details_url": "https://e.org/a%s[31mRED%s]0;pwn%c%cz%c"}\n' \
    "$ESC" "$ESC" 7 13 127 > "$TMP/evil.json"
printf '{"status": "revoked", "advisories": ["CVE-2026-1"], "details_url": "https://e.org/a"}\n' > "$TMP/benign.json"
banner() { # bannerfile -> $TMP/bout
    MONOLITH_RELEASE_FILE="$TMP/release" MONOLITH_ADVISORY_FILE="$1" \
        sh -c '. "$1"' sh "$BANNER" > "$TMP/bout" 2>&1
}
banner "$TMP/benign.json"; base_esc=$(tr -cd '\033' < "$TMP/bout" | wc -c)
banner "$TMP/evil.json"
evil_esc=$(tr -cd '\033' < "$TMP/bout" | wc -c)
other=$(tr -d '\n\033' < "$TMP/bout" | tr -cd '\001-\037\177' | wc -c)
if [ "$base_esc" -gt 0 ] && [ "$evil_esc" = "$base_esc" ]; then ok "AC-4 no injected ESC byte in banner output"
else fail "AC-4 no injected ESC byte in banner output (benign $base_esc, evil $evil_esc)"; fi
if [ "$base_esc" -gt 0 ] && [ "$other" = 0 ]; then ok "AC-4 no other control byte in banner output"
else fail "AC-4 no other control byte in banner output ($other found)"; fi
if ! grep -aq "^Details: " "$TMP/bout" || grep -a "^Details: " "$TMP/bout" | tr -d "\n" | tr -cd "\001-\037\177" | grep -q .; then
    fail "AC-4 Details line is free of control bytes"
else ok "AC-4 Details line is free of control bytes"; fi

# ---- AC-5
n=$(ls "$PKG"/*.ebuild 2>/dev/null | wc -l)
if [ "$n" = 1 ] && [ -f "$PKG/monolith-base-0.1.0-r7.ebuild" ]; then ok "AC-5 exactly one ebuild, monolith-base-0.1.0-r7.ebuild"
else fail "AC-5 exactly one ebuild, monolith-base-0.1.0-r7.ebuild (found: $(ls "$PKG" 2>/dev/null | grep ebuild | tr '\n' ' '))"; fi

# ---- AC-6: dry run of `make test` (never run it: it would recurse into this test)
lint_args() { make -n -C "$ROOT" test "$@" 2>&1 | grep 'test-lint\.sh' | head -n1; }
for variant in "" "SHELL_EXTRA=some/other/path"; do
    line=$(lint_args $variant)
    for s in monolith-net monolith-router monolith monolith-time monolith-time-check monolith-persist; do
        found=0
        for w in $line; do
            case "$w" in
                */files/"$s"|files/"$s") found=1 ;;
            esac
        done
        if [ "$found" = 1 ]; then ok "AC-6 make test lints files/$s${variant:+ ($variant)}"
        else fail "AC-6 make test lints files/$s${variant:+ ($variant)}"; fi
    done
done

if [ "$fails" -gt 0 ]; then echo "$fails FAILED"; exit 1; fi
echo "all passed"
