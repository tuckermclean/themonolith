#!/bin/sh
#
# source-audit.sh - prove that every file in the exported sysroot was built from source in this run.
#
# Usage: source-audit.sh --sysroot DIR --vdb DIR --log FILE --start EPOCH --exceptions FILE [--allowlist FILE] --output TSV
#   --sysroot     the exported sysroot (output/sysroot)
#   --vdb         the target VDB (VDB/<cat>/<pf>/CONTENTS and BUILD_TIME)
#   --log         this run's emerge log; a cpv is built from source iff a line
#                 '>>> Emerging (N of M) <cpv>[::repo] ...' names it ('Emerging binary' lines do not count)
#   --start       the run's start, epoch seconds; the owner's BUILD_TIME must be at or after it
#   --exceptions  configs/attestation/bootstrap-exceptions.txt: '<absolute path> <host cpv>', '#' comments;
#                 the path is everything before the last space or tab
#   --allowlist   optional, configs/attestation/unowned-allowlist.yaml: an unowned file matching the first
#                 entry (fnmatch on the path with or without its leading /, * also matches /) passes when that
#                 entry's source is "portage" (report owner portage, provenance portage) or "postinst:<cat/pn>"
#                 with a cpv of that cat/pn named by an Emerging line (owner that cpv, provenance postinst).
#                 Other sources and the modified: section never cover a sysroot file; an entry matching no file
#                 is not a failure. The file must exist.
#   --output      report: header 'path<TAB>owner<TAB>provenance', one row per file,
#                 provenance 'built-this-run', 'bootstrap', 'portage' or 'postinst'
#
# Fails (exit 1) when a file's owner was not merged from source in this run, when an unowned file is not a declared exception or covered by the allowlist,
# or when an exception matches no file.
set -eu

SYSROOT=; VDB=; LOG=; START=; EXCEPTIONS=; OUTPUT=; ALLOWLIST=
while [ $# -gt 0 ]; do
    case "$1" in
        --sysroot)    SYSROOT=${2:?--sysroot needs a value}; shift 2 ;;
        --vdb)        VDB=${2:?--vdb needs a value}; shift 2 ;;
        --log)        LOG=${2:?--log needs a value}; shift 2 ;;
        --start)      START=${2:?--start needs a value}; shift 2 ;;
        --exceptions) EXCEPTIONS=${2:?--exceptions needs a value}; shift 2 ;;
        --output)     OUTPUT=${2:?--output needs a value}; shift 2 ;;
        --allowlist)  ALLOWLIST=${2:?--allowlist needs a value}; shift 2 ;;
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
[ -z "$ALLOWLIST" ] || [ -f "$ALLOWLIST" ] || { echo "source-audit: allowlist not found: $ALLOWLIST" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# every regular file and symlink of the sysroot, as an absolute in-system path
( cd "$SYSROOT" && find . \( -type f -o -type l \) -print ) | sed 's|^\.||' | LC_ALL=C sort > "$WORK/files"
find "$VDB" -mindepth 3 -maxdepth 3 -name CONTENTS -print | LC_ALL=C sort > "$WORK/contents"

mkdir -p "$(dirname "$OUTPUT")"
awk -v vdb="$VDB" -v start="$START" -v logf="$LOG" -v exc="$EXCEPTIONS" -v out="$OUTPUT" -v allow="$ALLOWLIST" '
# class body as fnmatch reads it: a reversed range matches nothing, [ is a literal
function fnclass(cls,   o, p, n, c, x, y) {
    if (!ordok) { for (x = 1; x < 256; x++) ord[sprintf("%c", x)] = x; ordok = 1 }
    n = length(cls); o = ""
    for (p = 1; p <= n; p++) {
        c = substr(cls, p, 1)
        if (substr(cls, p + 1, 1) == "-" && p + 2 <= n) {
            y = substr(cls, p + 2, 1)
            if (ord[c] > ord[y]) { p += 2; continue }
            o = o c "-" y; p += 2; continue
        }
        o = o c
    }
    gsub(/\\/, "\\\\", o)
    gsub(/\[/, "\\[", o)
    return o
}
# fnmatch pattern -> anchored extended regex: * any run (including /), ? one character,
# [..] / [!..] classes, everything else literal
function fn2re(pat,   i, n, ch, re, j, cls, k) {
    n = length(pat); re = "^"
    for (i = 1; i <= n; i++) {
        ch = substr(pat, i, 1)
        if (ch == "*") re = re ".*"
        else if (ch == "?") re = re "."
        else if (ch == "[") {
            j = i + 1
            if (substr(pat, j, 1) == "!") j++
            if (substr(pat, j, 1) == "]") j++
            while (j <= n && substr(pat, j, 1) != "]") j++
            if (j > n) { re = re "\\["; continue }
            cls = substr(pat, i + 1, j - i - 1); k = ""
            if (substr(cls, 1, 1) == "!") { k = "^"; cls = substr(cls, 2) }
            cls = fnclass(cls)
            if (cls == "") re = re (k == "" ? "x^" : ".")
            else re = re "[" (k == "" && substr(cls, 1, 1) == "^" ? "\\" : "") k cls "]"
            i = j
        }
        else if (ch ~ /[.^$()|+{}\\]/) re = re "\\" ch
        else re = re ch
    }
    return re "$"
}
# first allowlist entry matching path p (with or without its leading /); 0 if none
function allow_idx(p,   rel, i) {
    rel = p; sub(/^\/+/, "", rel)
    for (i = 1; i <= nal; i++) if (rel ~ alre[i] || p ~ alre[i]) return i
    return 0
}
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
    # cat/pn -> a cpv of it merged from source this run
    for (c in built) { pn = c; sub(/-[0-9][^-]*(-r[0-9]+)?$/, "", pn); if (!(pn in builtpn)) builtpn[pn] = c }
    # unowned-file allowlist: entries before the modified: section, in file order
    if (allow != "") {
        inmod = 0; cur = 0
        while ((getline l < allow) > 0) {
            if (l ~ /^modified:/) inmod = 1
            if (inmod) continue
            if (l ~ /^[ \t]*-[ \t]+path:/) {
                sub(/^[ \t]*-[ \t]+path:[ \t]*/, "", l); sub(/[ \t]+#.*$/, "", l); sub(/[ \t]+$/, "", l)
                if (l ~ /^".*"$/ || l ~ /^\x27.*\x27$/) l = substr(l, 2, length(l) - 2)
                nal++; alre[nal] = fn2re(l); alsrc[nal] = ""; cur = nal
            } else if (cur && l ~ /^[ \t]+source:/) {
                sub(/^[ \t]+source:[ \t]*/, "", l); sub(/[ \t]*(#.*)?$/, "", l)
                gsub(/^["\x27]|["\x27]$/, "", l); alsrc[cur] = l; cur = 0
            }
        }
        close(allow)
    }
    # declared bootstrap exceptions
    while ((getline l < exc) > 0) {
        sub(/#.*/, "", l); sub(/[ \t]+$/, "", l)
        if (l !~ /[^ \t]/) continue
        # the path is everything before the last space or tab
        if (l !~ /^\/.*[ \t][^ \t]+$/ || !match(l, /[ \t][^ \t]+$/)) { print "FAIL: bad exception line: " l; bad++; continue }
        p = substr(l, 1, RSTART - 1); sub(/[ \t]+$/, "", p)
        host[p] = substr(l, RSTART + 1)
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
        i = 0
        if (p in host) { used[p] = 1; print p "\t" host[p] "\tbootstrap" > out }
        else if ((i = allow_idx(p)) > 0 && alsrc[i] == "portage") print p "\tportage\tportage" > out
        else if (i > 0 && alsrc[i] ~ /^postinst:/ && ((pn = substr(alsrc[i], 10)) in builtpn)) print p "\t" builtpn[pn] "\tpostinst" > out
        else { print "FAIL: unowned file not in the bootstrap exceptions" (allow != "" ? " or covered by the allowlist" : "") ": " p (i > 0 && alsrc[i] ~ /^postinst:/ ? " (" substr(alsrc[i], 10) " has no Emerging (N of M) line in " logf ")" : ""); bad++ }
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
