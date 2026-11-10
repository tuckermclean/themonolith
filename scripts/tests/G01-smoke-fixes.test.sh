#!/bin/sh
# G01 slice S2b: the two product bugs `smoke` finds (node spec change 4, G01-AC-6).
#   G01-AC-6 (a)  build-packages.sh's sysroot export keeps usr/i486-linux-musl/binutils-bin/<ver>/<tool> and the
#                 binutils tools' usr/bin/i486-linux-musl-<tool> links, plus usr/bin/<tool>; it still drops the rest of
#                 usr/i486-linux-musl/ (nested crossdev sysroot) and every other usr/bin/i486-linux-musl-* entry.
#   G01-AC-6 (b)  build-rootfs.sh writes an /etc/group with `users:x:100:` (shadow's useradd default group),
#                 next to the existing groups.
# (a) runs the whole script through its SYSROOT seam (stub emerge/portageq/..., as build-packages-classify.test.sh).
# The toolbox has no rsync, so the rsync stub applies the script's --include/--exclude rules itself
# (first match wins, anchored patterns, trailing / = directories only, an excluded directory is not entered).
# (b) build-rootfs.sh has no root seam (ROOTFS_DIR is fixed): the /etc/group heredoc is extracted and run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/.."
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }
check() { d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ===== (a) sysroot export =====
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
for n in i486-linux-musl-emerge quickpkg emaint portageq i486-linux-musl-gcc; do
    printf '#!/bin/sh\n[ "$(basename "$0")" = portageq ] && [ "$1" = has_version ] && exit 0\nexit 0\n' > "$STUBS/$n"
    chmod +x "$STUBS/$n"
done
cat > "$STUBS/rsync" <<'STUB'
#!/bin/sh
# rsync -a with ordered --include/--exclude filters: rsync src/ dst/
rules=""; src=""; dst=""
for a in "$@"; do
    case "$a" in
        --exclude=*) rules="$rules
x ${a#--exclude=}" ;;
        --include=*) rules="$rules
i ${a#--include=}" ;;
        -*) ;;
        *) src="$dst"; dst="$a" ;;
    esac
done
src="${src%/}"; dst="${dst%/}"
mkdir -p "$dst"
matches() { # $1 pattern, $2 path (/rel), $3 d|f
    p="$1"; path="$2"
    case "$p" in */) [ "$3" = d ] || return 1; p="${p%/}" ;; esac
    case "$p" in
        */'***') b="${p%/???}"; [ "$path" = "$b" ] && return 0; p="$b/*" ;;
    esac
    case "$p" in /*) ;; *) case "$p" in */*) p="/$p" ;; *) p="/*/$p"; case "$path" in "/$1") return 0 ;; esac ;; esac ;; esac
    case "$path" in $p) return 0 ;; esac
    return 1
}
skipped=""
( cd "$src" && find . -mindepth 1 | sort ) | while IFS= read -r rel; do
    path="${rel#.}"
    for s in $skipped; do :; done
    parent="$(dirname "$path")"
    [ -e "$dst/.skip$(printf '%s' "$path" | tr / _)" ] && continue
    # skip when an ancestor was excluded or is not present in the destination
    [ "$parent" != / ] && [ ! -d "$dst$parent" ] && continue
    if [ -d "$src$path" ] && [ ! -L "$src$path" ]; then t=d; else t=f; fi
    verdict=i
    old_ifs="$IFS"; IFS='
'
    for r in $rules; do
        [ -n "$r" ] || continue
        kind="${r%% *}"; pat="${r#* }"
        if matches "$pat" "$path" "$t"; then verdict="$kind"; break; fi
    done
    IFS="$old_ifs"
    [ "$verdict" = x ] && continue
    if [ "$t" = d ]; then mkdir -p "$dst$path"; else cp -a "$src$path" "$dst$path"; fi
done
exit 0
STUB
chmod +x "$STUBS/rsync"

W="$TMP/a"; CFG="$W/configs"; OUT="$W/output"; SYS="$W/sysroot"; HETC="$W/hostetc"
mkdir -p "$CFG/portage" "$OUT" "$SYS/etc/portage" "$HETC" "$SYS/usr/share/monolith-kernel"
: > "$HETC/group"
printf 'app-misc/hello\n' > "$CFG/portage/world"
printf 'app-misc/hello:1.0:0\n' > "$CFG/portage/versions.lock"
echo 'CONFIG_I2C=n' | gzip -c > "$SYS/usr/share/monolith-kernel/resolved-kernel.config.gz"

VER=2.43.1
TOOLS="ld as ar nm objdump readelf strip objcopy ranlib size strings addr2line c++filt elfedit gprof ld.bfd"
mkdir -p "$SYS/usr/bin" "$SYS/usr/i486-linux-musl/binutils-bin/$VER" \
    "$SYS/usr/i486-linux-musl/usr/lib" "$SYS/usr/i486-linux-musl/include" "$SYS/usr/i486-linux-musl/lib"
for t in $TOOLS; do
    echo "tool $t" > "$SYS/usr/i486-linux-musl/binutils-bin/$VER/$t"
    chmod +x "$SYS/usr/i486-linux-musl/binutils-bin/$VER/$t"
    ln -s "../i486-linux-musl/binutils-bin/$VER/$t" "$SYS/usr/bin/i486-linux-musl-$t"
    ln -s "i486-linux-musl-$t" "$SYS/usr/bin/$t"
done
: > "$SYS/usr/i486-linux-musl/usr/lib/libc.a"
: > "$SYS/usr/i486-linux-musl/include/x.h"
: > "$SYS/usr/i486-linux-musl/lib/ld-musl-i386.so.1"
for n in curl-config gcc pkg-config; do : > "$SYS/usr/bin/i486-linux-musl-$n"; done
: > "$SYS/usr/bin/hello"
mkdir -p "$SYS/usr/include"; : > "$SYS/usr/include/stray.h"

env -u MONOLITH_USEPKG CONFIGS_DIR="$CFG" OUTPUT_DIR="$OUT" SYSROOT="$SYS" HOST_ETC="$HETC" \
    JOBS=2 LOAD_AVG=2 PATH="$STUBS:$PATH" bash "$SCRIPTS/build-packages.sh" > "$W/out.txt" 2>&1
echo "build-packages.sh exit $?"
EXP="$OUT/sysroot"

check "G01-AC-6: the export ran (usr/bin/hello is exported)" test -e "$EXP/usr/bin/hello"
for t in $TOOLS; do
    check "G01-AC-6: export keeps usr/i486-linux-musl/binutils-bin/$VER/$t" test -f "$EXP/usr/i486-linux-musl/binutils-bin/$VER/$t"
    check "G01-AC-6: export keeps the link usr/bin/i486-linux-musl-$t" test -L "$EXP/usr/bin/i486-linux-musl-$t"
    check "G01-AC-6: export keeps the link usr/bin/$t" test -L "$EXP/usr/bin/$t"
done
check "G01-AC-6: the kept i486-linux-musl-ld link resolves to a file" test -f "$EXP/usr/bin/i486-linux-musl-ld"
gone() { [ -f "$EXP/usr/bin/hello" ] && [ ! -e "$1" ] && [ ! -L "$1" ]; }
check "G01-AC-6: export drops usr/i486-linux-musl/usr/lib/libc.a (nested crossdev sysroot)" gone "$EXP/usr/i486-linux-musl/usr/lib/libc.a"
check "G01-AC-6: export drops usr/i486-linux-musl/include/x.h" gone "$EXP/usr/i486-linux-musl/include/x.h"
check "G01-AC-6: export drops usr/i486-linux-musl/lib/ld-musl-i386.so.1" gone "$EXP/usr/i486-linux-musl/lib/ld-musl-i386.so.1"
for n in curl-config gcc pkg-config; do
    check "G01-AC-6: export drops usr/bin/i486-linux-musl-$n" gone "$EXP/usr/bin/i486-linux-musl-$n"
done
check "G01-AC-6: export still drops usr/include/" gone "$EXP/usr/include/stray.h"

# ===== (b) /etc/group of the rootfs =====
RFS="$SCRIPTS/build-rootfs.sh"
mkdir -p "$TMP/b/etc"
awk '/cat > "\$ROOTFS_DIR\/etc\/group" << .EOF./ { on = 1; next } on && /^EOF$/ { exit } on { print }' "$RFS" > "$TMP/b/etc/group"
check "G01-AC-6: build-rootfs.sh writes an /etc/group" test -s "$TMP/b/etc/group"
check "G01-AC-6: /etc/group has users:x:100:" grep -qx 'users:x:100:' "$TMP/b/etc/group"
for g in root:x:0: wheel:x:10:root nobody:x:65534:; do
    check "G01-AC-6: /etc/group keeps $g" grep -qx "$g" "$TMP/b/etc/group"
done

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAIL"
[ "$fails" -eq 0 ]
