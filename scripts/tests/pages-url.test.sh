#!/bin/sh
# P05 pages-url: the OD-1 URL is one value everywhere it is set, and the old host is gone from
# the tree.  Covers P05-AC-3 and P05-AC-4.  Offline; works in a commit-less git copy (git ls-files
# of a `git init` + `git add -A` tree), never walks out/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }

WANT="https://tuckermclean.github.io/themonolith"
# The old host word, built from parts so this file never contains it.
old=techno; old=${old}mantics

TMP=$(mktemp -d "${TMPDIR:-/tmp}/P05.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---- P05-AC-3: every place the URL is set equals the advisory check's default
ADV="$ROOT/configs/overlay/app-misc/monolith-base/files/monolith-advisory-check"
RFS="$ROOT/scripts/build-rootfs.sh"
MK="$ROOT/Makefile"
MON="$ROOT/scripts/nightly-cve-monitor.py"
adv=; home=; mk=; mon=
[ -f "$ADV" ] && adv=$(sed -n 's/^ADVISORY_BASE_URL="\${ADVISORY_BASE_URL:-\([^}]*\)}".*/\1/p' "$ADV" | head -n 1)
[ -f "$RFS" ] && home=$(sed -n 's/^HOME_URL=["'"'"']\{0,1\}\([^"'"'"']*\).*/\1/p' "$RFS" | head -n 1)
[ -f "$MK" ]  && mk=$(sed -n 's/^ADVISORY_BASE_URL[ ]*?=[ ]*//p' "$MK" | head -n 1 | sed 's/[ 	]*$//')
[ -f "$MON" ] && mon=$(sed -n 's/^DEFAULT_BASE_URL = "\([^"]*\)".*/\1/p' "$MON" | head -n 1)

if [ "$adv" = "$WANT" ]; then ok "P05-AC-3 monolith-advisory-check default base URL is $WANT"
else fail "P05-AC-3 monolith-advisory-check default base URL is $WANT (got '$adv')"; fi
if [ "$adv" = "$WANT" ] && [ "$home" = "$adv" ]; then ok "P05-AC-3 build-rootfs.sh HOME_URL equals the advisory check's default"
else fail "P05-AC-3 build-rootfs.sh HOME_URL ('$home') equals the advisory check's default ('$adv')"; fi
if [ "$adv" = "$WANT" ] && [ "$mk" = "$adv" ]; then ok "P05-AC-3 Makefile ADVISORY_BASE_URL equals the advisory check's default"
else fail "P05-AC-3 Makefile ADVISORY_BASE_URL ('$mk') equals the advisory check's default ('$adv')"; fi
if [ "$adv" = "$WANT" ] && [ "$mon" = "$adv" ]; then ok "P05-AC-3 nightly-cve-monitor.py DEFAULT_BASE_URL equals the advisory check's default"
else fail "P05-AC-3 nightly-cve-monitor.py DEFAULT_BASE_URL ('$mon') equals the advisory check's default ('$adv')"; fi

# ---- P05-AC-4: no tracked file outside the history directories names the old host
# scan <root>: print each tracked file (outside the excluded dirs) that contains the old host word
scan() {
    git -C "$1" ls-files | grep -Ev '^(nodes|docs/study|docs/reviews|docs/evidence)/' | while IFS= read -r f; do
        [ -f "$1/$f" ] && grep -qI -- "$old" "$1/$f" && echo "$f"
    done
    return 0
}
hits=$(scan "$ROOT")
if [ -z "$hits" ]; then ok "P05-AC-4 no tracked file outside nodes/, docs/study/, docs/reviews/, docs/evidence/ names the old host"
else fail "P05-AC-4 tracked files outside nodes/, docs/study/, docs/reviews/, docs/evidence/ still name the old host: $(echo "$hits" | tr '\n' ' ')"; fi

# the check must catch a planted file, and must skip the history directories
SC="$TMP/scratch"
mkdir -p "$SC/docs/study" "$SC/scripts" "$SC/nodes"
echo "history: https://x.${old}.com" > "$SC/docs/study/a.md"
echo "history: https://x.${old}.com" > "$SC/nodes/N.md"
echo "clean" > "$SC/scripts/ok.sh"
(cd "$SC" && git init -q . && git add -A) >/dev/null 2>&1
if [ -z "$(scan "$SC")" ]; then ok "P05-AC-4 scan ignores the old host inside nodes/ and docs/study/"
else fail "P05-AC-4 scan ignores the old host inside nodes/ and docs/study/"; fi
echo "HOME_URL=https://x.${old}.com" > "$SC/scripts/planted.sh"
(cd "$SC" && git add -A) >/dev/null 2>&1
if [ "$(scan "$SC")" = "scripts/planted.sh" ]; then ok "P05-AC-4 a planted file outside the history directories fails the scan"
else fail "P05-AC-4 a planted file outside the history directories fails the scan (scan said: '$(scan "$SC")')"; fi

# check-migration, both modes
for mode in "--node P05" "--all"; do
    # shellcheck disable=SC2086
    out=$(cd "$ROOT" && python3 -I scripts/check-migration.py $mode 2>&1); rc=$?
    if [ $rc = 0 ]; then ok "P05-AC-4 check-migration.py $mode passes"
    else fail "P05-AC-4 check-migration.py $mode passes (rc=$rc: $(echo "$out" | head -n 3 | tr '\n' ' '))"; fi
done

echo
if [ "$fails" -eq 0 ]; then echo "pages-url: all passed"; else echo "pages-url: $fails FAILED"; exit 1; fi
