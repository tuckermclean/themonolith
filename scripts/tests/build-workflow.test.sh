#!/bin/sh
# B03 build-workflow checks. Works in a commit-less copy (no git history).
# Later cases are appended above the final summary.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
check() { # check <label> <command...>
  _l=$1; shift
  if "$@"; then pass "$_l"; else fail "$_l"; fi
}

# --- B03-AC-8: build-rootfs.sh has no vendor-host string; HOME_URL matches advisory default
RFS="$ROOT/scripts/build-rootfs.sh"
ADV="$ROOT/configs/overlay/app-misc/monolith-base/files/monolith-advisory-check"

# Needle built from pieces so this file never contains the whole string.
_a=amazon
needle="${_a}aws"

check "B03-AC-8: scripts/build-rootfs.sh exists" test -f "$RFS"

if [ -f "$RFS" ]; then
  if grep -q "$needle" "$RFS"; then
    fail "B03-AC-8: build-rootfs.sh contains no vendor-host string"
  else
    pass "B03-AC-8: build-rootfs.sh contains no vendor-host string"
  fi
else
  fail "B03-AC-8: build-rootfs.sh contains no vendor-host string (file missing)"
fi

adv_default=
if [ -f "$ADV" ]; then
  adv_default=$(sed -n 's/^ADVISORY_BASE_URL="\${ADVISORY_BASE_URL:-\([^}]*\)}".*/\1/p' "$ADV" | head -n 1)
fi
if [ -n "$adv_default" ]; then
  pass "B03-AC-8: advisory-check default base URL found ($adv_default)"
else
  fail "B03-AC-8: advisory-check default base URL found"
fi

home_url=
if [ -f "$RFS" ]; then
  home_url=$(grep 'HOME_URL=' "$RFS" | head -n 1 | sed 's/.*HOME_URL=//; s/^["'"'"']//; s/["'"'"'].*$//')
fi
if [ -n "$home_url" ] && [ -n "$adv_default" ] && [ "$home_url" = "$adv_default" ]; then
  pass "B03-AC-8: os-release HOME_URL equals advisory default base URL"
else
  fail "B03-AC-8: os-release HOME_URL ('$home_url') equals advisory default base URL ('$adv_default')"
fi

# --- end of cases ---
echo
if [ "$fails" -ne 0 ]; then
  echo "$fails FAILED"
  exit 1
fi
echo "ALL PASS"
