#!/bin/sh
# G01 change 4 (AC-1 support): the two persistence fixes, unit level.
#  (a) configs/portage/package.use/static: sys-fs/e2fsprogs enables `tools`
#      with `static` (no `-tools`), keeps `static-libs` and `-nls`.
#  (b) rootfs/init MONOLITH_PERSIST label scan: partitions before whole disks;
#      a whole disk that has partitions is skipped; an unpartitioned labelled
#      whole disk (O01 `persist` mode) is still found.
#
# CONTRACT the init must meet for (b) (the only shape this test needs):
#   * rootfs/init defines a shell function `persist_scan` (a line
#     `persist_scan() {` closed by a `}` at the same indentation) that prints
#     the selected device path on stdout, or nothing when none carries the label;
#   * it enumerates devices under "${DEV_ROOT:-/dev}" (vd* sd* nvme*n* mmcblk* hd*);
#   * it decides "is a block device" by calling a function `persist_is_blk DEV`
#     (the init defines it as `[ -b "$1" ]`; the test overrides it so plain files
#     can stand in for devices). The label test (cat | tr | grep) is unchanged;
#   * the function uses only variables it sets itself (the test evals just the
#     function bodies of persist_scan and persist_is_blk, not the whole init).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/../.."
INIT="$ROOT/rootfs/init"
USE="$ROOT/configs/portage/package.use/static"
fails=0
ok()   { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fails=$((fails+1)); }

# ---- (a) e2fsprogs flags (G01-AC-1) ----
line=$(grep -E '^[[:space:]]*sys-fs/e2fsprogs([[:space:]]|$)' "$USE" 2>/dev/null | head -n1)
flags=" $line "
chk() { # desc, present-flag
    case "$flags" in *" $2 "*) ok "G01-AC-1 e2fsprogs: $1";; *) bad "G01-AC-1 e2fsprogs: $1 (line: '$line')";; esac
}
chk "static"       static
chk "tools"        tools
chk "static-libs"  static-libs
chk "-nls"         -nls
case "$flags" in *" -tools "*) bad "G01-AC-1 e2fsprogs: no -tools";; *) ok "G01-AC-1 e2fsprogs: no -tools";; esac

# ---- (b) init scan ----
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
extract() { # function name -> its text from rootfs/init
    awk -v n="$1" '
        !f && $0 ~ "^[ \t]*" n "\\(\\)[ \t]*\\{" { match($0,/^[ \t]*/); ind=substr($0,1,RLENGTH); f=1 }
        f { print }
        f && $0 == ind "}" { exit }' "$INIT"
}
extract persist_scan > "$TMP/scan.sh"
if [ ! -s "$TMP/scan.sh" ]; then
    # report every case as FAIL (missing subject), no crash
    for c in "partitioned disk selects vda1" "unpartitioned disk found" "sd naming" "nvme naming" "mmcblk naming" "partition preferred over labelled whole disk" "no label -> empty"; do
        bad "G01-AC-1 init scan: $c (rootfs/init defines no persist_scan function)"
    done
    echo "$fails failure(s)"; exit 1
fi
extract persist_is_blk > "$TMP/blk.sh"

run_scan() { # devroot -> stdout of persist_scan, with plain files as devices
    (
        DEV_ROOT="$1"
        # shellcheck disable=SC1090
        . "$TMP/blk.sh" 2>/dev/null
        . "$TMP/scan.sh"
        persist_is_blk() { [ -f "$1" ]; }
        persist_scan 2>/dev/null
    )
}
mk() { # root, name, labelled(0/1)
    mkdir -p "$1"
    if [ "$3" = 1 ]; then printf 'xx\000\000MONOLITH_PERSIST\000yy' > "$1/$2"; else printf 'zz\000\000other\000' > "$1/$2"; fi
}
want() { # desc, root, expected
    got=$(run_scan "$2")
    if [ "$got" = "$3" ]; then ok "G01-AC-1 init scan: $1"; else bad "G01-AC-1 init scan: $1 (got '$got', want '$3')"; fi
}

# label in a partition; the whole disk's own image also contains the label bytes
r="$TMP/t1"; mk "$r" vda 1; mk "$r" vda1 1; mk "$r" vdb 0
want "partitioned disk selects vda1" "$r" "$r/vda1"
r="$TMP/t2"; mk "$r" vda 0; mk "$r" vda1 0; mk "$r" vdb 1
want "unpartitioned labelled disk found (vdb)" "$r" "$r/vdb"
r="$TMP/t3"; mk "$r" sda 1; mk "$r" sda2 1
want "sd naming selects sda2" "$r" "$r/sda2"
r="$TMP/t4"; mk "$r" nvme0n1 1; mk "$r" nvme0n1p1 1
want "nvme naming selects nvme0n1p1" "$r" "$r/nvme0n1p1"
r="$TMP/t5"; mk "$r" mmcblk0 1; mk "$r" mmcblk0p1 1
want "mmcblk naming selects mmcblk0p1" "$r" "$r/mmcblk0p1"
r="$TMP/t6"; mk "$r" vda 1; mk "$r" vda1 0; mk "$r" vdb 1
want "labelled whole disk with partitions skipped, unpartitioned vdb chosen" "$r" "$r/vdb"
r="$TMP/t7"; mk "$r" vda 0; mk "$r" vda1 0; mk "$r" nvme0n1 0; mk "$r" nvme0n1p1 0
want "no label -> empty" "$r" ""

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failure(s)"; exit 1
