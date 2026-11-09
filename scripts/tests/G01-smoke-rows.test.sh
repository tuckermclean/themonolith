#!/bin/sh
# G01 slice S2d: review fixes on the smoke rows and the unowned allowlist (G01-AC-6, smoke rows).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/../.."
ROWS="$REPO/scripts/smoke-checks.txt"
AL="$REPO/configs/attestation/unowned-allowlist.yaml"

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }
check() { d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

# field N (1-based, tab separated) of the row whose atom is $1
field() { awk -F'\t' -v a="$1" -v n="$2" '$1 == a && $2 == "run" { print $n; exit }' "$ROWS"; }

SHCMD="$(field sys-apps/shadow 3)"
SHRE="$(field sys-apps/shadow 4)"
MDRE="$(field app-text/mandoc 4)"

has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
eq() { [ "$1" = "$2" ]; }
anchored() { case "$1" in '^'*'$') return 0 ;; esac; return 1; }

check "G01-AC-6: shadow row runs useradd with -N (no per-user group under USERGROUPS_ENAB yes)" \
    sh -c 'case "$1" in *useradd*" -N"*) exit 0;; esac; exit 1' _ "$SHCMD"
check "G01-AC-6: shadow row checks id -gn" has "$SHCMD" "id -gn"
check "G01-AC-6: shadow row regex is exactly ^users\$" eq "$SHRE" '^users$'
check "G01-AC-6: mandoc row regex is anchored at both ends" anchored "$MDRE"

# unowned allowlist: the exported usr/i486-linux-musl/bin directory itself
ok() { python3 -I - "$AL" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
def walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values(): yield from walk(v)
    elif isinstance(o, list):
        for v in o: yield from walk(v)
sys.exit(0 if any(e.get("path") == "usr/i486-linux-musl/bin" and e.get("source") == "postinst:sys-devel/binutils" for e in walk(d)) else 1)
PY
}
check "G01-AC-6: allowlist has directory usr/i486-linux-musl/bin (postinst:sys-devel/binutils)" ok

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAIL"
[ "$fails" -eq 0 ]
