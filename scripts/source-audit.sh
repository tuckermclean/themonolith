#!/bin/sh
#
# source-audit.sh - prove that every file in the exported sysroot was built from source in this run.
#
# Usage: source-audit.sh --sysroot DIR --vdb DIR --log FILE --start EPOCH --exceptions FILE --output TSV
#   --sysroot     the exported sysroot (output/sysroot)
#   --vdb         the target VDB (VDB/<cat>/<pf>/CONTENTS and BUILD_TIME)
#   --log         this run's emerge log; a cpv is built from source iff a line
#                 '>>> Emerging (N of M) <cpv>[::repo] ...' names it ('Emerging binary' lines do not count)
#   --start       the run's start, epoch seconds; the owner's BUILD_TIME must be at or after it
#   --exceptions  configs/attestation/bootstrap-exceptions.txt: '<absolute path> <host cpv>', '#' comments;
#                 the path is everything before the last space
#   --output      report: header 'path<TAB>owner<TAB>provenance', one row per file,
#                 provenance 'built-this-run' or 'bootstrap'
#
# Fails (exit 1) when a file's owner was not merged from source in this run, when a file has no
# owner and is not a declared exception, or when an exception matches no file.
set -eu

SYSROOT=; VDB=; LOG=; START=; EXCEPTIONS=; OUTPUT=
while [ $# -gt 0 ]; do
    case "$1" in
        --sysroot)    SYSROOT=${2:?--sysroot needs a value}; shift 2 ;;
        --vdb)        VDB=${2:?--vdb needs a value}; shift 2 ;;
        --log)        LOG=${2:?--log needs a value}; shift 2 ;;
        --start)      START=${2:?--start needs a value}; shift 2 ;;
        --exceptions) EXCEPTIONS=${2:?--exceptions needs a value}; shift 2 ;;
        --output)     OUTPUT=${2:?--output needs a value}; shift 2 ;;
        *) echo "source-audit: unknown argument: $1" >&2; exit 2 ;;
    esac
done
for v in SYSROOT VDB LOG START EXCEPTIONS OUTPUT; do
    eval "[ -n \"\$$v\" ]" || { echo "source-audit: missing --$(echo "$v" | tr 'A-Z' 'a-z')" >&2; exit 2; }
done
case "$START" in *[!0-9]*) echo "source-audit: --start must be epoch seconds: $START" >&2; exit 2 ;; esac
[ -d "$SYSROOT" ] || { echo "source-audit: sysroot not found: $SYSROOT" >&2; exit 1; }
[ -d "$VDB" ]     || { echo "source-audit: VDB not found: $VDB" >&2; exit 1; }
[ -f "$LOG" ]     || { echo "source-audit: emerge log not found: $LOG" >&2; exit 1; }
[ -f "$EXCEPTIONS" ] || { echo "source-audit: exceptions file not found: $EXCEPTIONS" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# every regular file and symlink of the sysroot, as an absolute in-system path
( cd "$SYSROOT" && find . \( -type f -o -type l \) -print ) | sed 's|^\.||' | LC_ALL=C sort > "$WORK/files"
find "$VDB" -mindepth 3 -maxdepth 3 -name CONTENTS -print | LC_ALL=C sort > "$WORK/contents"

mkdir -p "$(dirname "$OUTPUT")"
awk -v vdb="$VDB" -v start="$START" -v logf="$LOG" -v exc="$EXCEPTIONS" -v out="$OUTPUT" '
function cpv_of(f,   c, n) {
    c = f; n = length(vdb) + 1
    if (substr(c, 1, n) == vdb "/") c = substr(c, n + 1)   # literal prefix, not a regex
    sub("/CONTENTS$", "", c); return c
}
BEGIN {
    # cpvs merged from source this run
    while ((getline l < logf) > 0) {
        if (l !~ /^>>> Emerging \([0-9]+ of [0-9]+\) /) continue
        sub(/^>>> Emerging \([0-9]+ of [0-9]+\) /, "", l)
        split(l, w, " "); c = w[1]; sub(/::.*/, "", c); built[c] = 1
    }
    close(logf)
    # declared bootstrap exceptions
    while ((getline l < exc) > 0) {
        sub(/#.*/, "", l); sub(/[ \t]+$/, "", l)
        if (l !~ /[^ \t]/) continue
        # the path is everything before the last space or tab
        if (l !~ /^\/.*[ \t][^ \t]+$/ || !match(l, /[ \t][^ \t]+$/)) { print "FAIL: bad exception line: " l; bad++; continue }
        host[substr(l, 1, RSTART - 1)] = substr(l, RSTART + 1)
    }
    close(exc)
    print "path\towner\tprovenance" > out
    mode = 0
}
FNR == 1 { mode++ }
FILENAME == ARGV[1] { # CONTENTS list
    f = $0; c = cpv_of(f)
    while ((getline line < f) > 0) {
        if (line ~ /^obj /) { p = line; sub(/^obj /, "", p); sub(/ [0-9a-f]+ [0-9]+$/, "", p) }
        else if (line ~ /^sym /) { p = line; sub(/^sym /, "", p); sub(/ -> .*/, "", p) }
        else continue
        owner[p] = c
    }
    close(f)
    next
}
{ # files of the sysroot
    p = $0; o = owner[p]
    if (o == "" && (p ".bz2") in owner) o = owner[p ".bz2"]   # decompressed man page
    if (o == "") {
        if (p in host) { used[p] = 1; print p "\t" host[p] "\tbootstrap" > out }
        else { print "FAIL: unowned file not in the bootstrap exceptions: " p; bad++ }
        next
    }
    if (p in host) { print "FAIL: " p " is a bootstrap exception but is owned by " o; bad++ }
    if (!(o in checked)) {
        checked[o] = 1; ok[o] = 1
        if (!(o in built)) {
            print "FAIL: " o " (owner of " p ") has no Emerging (N of M) line for it in " logf; bad++; ok[o] = 0
        } else {
            bt = ""; bf = vdb "/" o "/BUILD_TIME"
            if ((getline bt < bf) <= 0) { print "FAIL: " o " has no BUILD_TIME in " vdb; bad++; ok[o] = 0 }
            else if (bt + 0 < start + 0) { print "FAIL: " o " (owner of " p ") BUILD_TIME " bt " is before the run start " start " although the log names it"; bad++; ok[o] = 0 }
            close(bf)
        }
    }
    print p "\t" o "\t" (ok[o] ? "built-this-run" : "not-built-this-run") > out
}
END {
    for (p in host) if (!(p in used)) { print "FAIL: stale exception, no such file in the sysroot: " p; bad++ }
    exit(bad > 0)
}' "$WORK/contents" "$WORK/files"
