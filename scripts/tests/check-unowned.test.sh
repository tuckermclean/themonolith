#!/bin/sh
# S01-AC-1: scripts/check-unowned.py fails closed.
# Interface (the ported script's own): check-unowned.py --syft-json P --sysroot DIR --output P
#   --allowlist P; exit 0 only when every file in Syft's files[] is owned or allowlisted.
# Each defect is paired with a control (same fixture with the defect removed, must exit 0), so a
# missing script cannot pass by exiting non-zero.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUBJ="$ROOT/scripts/check-unowned.py"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# mk NAME [flags]: builds $TMP/NAME/{sysroot,syft.json,allowlist.yaml}
#   nofiles   files[] empty          nopkgdb   no sysroot/var/db/pkg
#   stray     one extra unowned file on disk
#   noowners  no portage artifacts and no CONTENTS (every file allowlisted)
mk() {
    n=$1; shift
    d="$TMP/$n"; mkdir -p "$d/sysroot/usr/bin" "$d/sysroot/etc"
    flags=" $* "
    S="$d/sysroot"
    : > "$S/usr/bin/foo"; : > "$S/etc/foo.conf"; : > "$S/etc/allowed"
    case "$flags" in *" stray "*) : > "$S/usr/bin/stray" ;; esac
    case "$flags" in *" nopkgdb "*|*" noowners "*) : ;; *)
        mkdir -p "$S/var/db/pkg/app-misc/foo-1"
        printf 'obj /usr/bin/foo d41d8cd98f00b204e9800998ecf8427e 1\nobj /etc/foo.conf d41d8cd98f00b204e9800998ecf8427e 1\n' \
            > "$S/var/db/pkg/app-misc/foo-1/CONTENTS" ;;
    esac
    python3 - "$d/syft.json" "$S" "$flags" <<'PY'
import json, sys
out, S, flags = sys.argv[1:4]
paths = ["/usr/bin/foo", "/etc/foo.conf", "/etc/allowed"]
if " stray " in flags: paths.append("/usr/bin/stray")
arts = []
if " noowners " not in flags:
    arts = [{"name": "foo", "type": "portage",
             "metadata": {"installedFiles": [{"path": "/usr/bin/foo"}, {"path": "/etc/foo.conf"}]}}]
files = [] if " nofiles " in flags else [{"location": {"path": S + p}} for p in paths]
json.dump({"schema": {"version": "16.0.0"}, "artifacts": arts, "files": files}, open(out, "w"))
PY
    printf 'allowlist:\n  - etc/allowed\n' > "$d/allowlist.yaml"
}
# go NAME [--syft P] [--allow P]: runs the subject, sets RC
go() {
    n=$1; shift; d="$TMP/$n"
    syft="$d/syft.json"; allow="$d/allowlist.yaml"
    while [ $# -gt 0 ]; do case "$1" in --syft) syft=$2; shift 2 ;; --allow) allow=$2; shift 2 ;; esac; done
    python3 "$SUBJ" --syft-json "$syft" --sysroot "$d/sysroot" --output "$d/report.json" \
        --allowlist "$allow" > "$d/out.txt" 2>&1
    RC=$?
}
# neg LABEL NAME-of-defect NAME-of-control [go args for defect]
neg() {
    label=$1; bad=$2; ctl=$3; shift 3
    go "$ctl"; rc_ctl=$RC
    go "$bad" "$@"
    if [ "$rc_ctl" -eq 0 ] && [ "$RC" -ne 0 ]; then ok "S01-AC-1 $label exits non-zero"
    else fail "S01-AC-1 $label exits non-zero (defect rc=$RC, control rc=$rc_ctl)"; fi
}

mk owned
go owned
[ "$RC" -eq 0 ] && ok "S01-AC-1 a fixture with all files owned (or allowlisted) exits 0" \
    || fail "S01-AC-1 a fixture with all files owned exits 0 (rc=$RC)"

mk stray stray
go stray
n=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["summary"]["unowned"])' "$TMP/stray/report.json" 2>/dev/null)
[ "$RC" -ne 0 ] && [ "$n" = 1 ] && ok "S01-AC-1 a fixture with one unowned file exits non-zero (report: 1 unowned)" \
    || fail "S01-AC-1 a fixture with one unowned file exits non-zero (rc=$RC unowned=$n)"

mk missjson
neg "a missing Syft JSON" missjson owned --syft "$TMP/missjson/nonexistent.json"

mk nofiles nofiles
neg "an empty files[]" nofiles owned

mk missallow
neg "a missing allowlist file" missallow owned --allow "$TMP/missallow/nonexistent.yaml"

mk nopkgdb nopkgdb
neg "a sysroot with no var/db/pkg (no owned paths read from the sysroot)" nopkgdb owned

mk noowners noowners
neg "a sysroot with no owned paths at all" noowners owned

echo
[ "$fails" -eq 0 ] && { echo "check-unowned: all passed"; exit 0; }
echo "check-unowned: $fails failed"; exit 1
