#!/bin/bash
#
# static-audit.sh - Check the built rootfs against the all-static doctrines
#
# The Monolith ships a fully static userland (configs/portage/env/static.conf
# + package.use/static force USE=static and -static LDFLAGS across the world
# file). This script verifies it on the built (or extracted) rootfs. One
# scanelf call reads PT_INTERP, e_machine and text relocations from every ELF
# file's headers; plain find covers the file-name rules.
#
# Each problem is a line in the report:
#   FINDING <check> <rootfs-relative path>
#     interp   PT_INTERP, and the file is not in the allowlist
#     machine  an ELF file that is not EM_386
#     loader   lib/ld-musl-i386.so.1 present iff the allowlist has an entry
#     plugin   an ELF file named *.so or *.so.* outside lib/modules/
#     python   a *.py or *.pyc file, or a python / python[0-9]* file or
#              directory under bin, sbin, lib, usr/bin, usr/sbin, usr/lib
#     font     freetype, fontconfig or libXft (library, config or VDB entry)
#   INFO textrel <path>    text relocations; never a failure
#
# Without --strict the report is written and the exit status stays 0, so the
# call in build-rootfs.sh cannot fail the build or perturb the SquashFS bytes.
# With --strict any finding is exit 1. A missing target, a missing scanelf,
# an unreadable tree, zero ELF files scanned, and a stale or malformed
# allowlist entry are always exit 1. "static-audit: PASS" is printed only on
# a clean pass.
#
# Allowlist (configs/attestation/dynamic-allowlist.txt by default): one
# rootfs-relative path per line followed by "# <issue> <reason>". An entry
# that matches no dynamic ELF file is stale and fails.
#
# Usage:
#   static-audit.sh [--strict] [--allowlist FILE | --no-allowlist]
#                   [--require-empty-allowlist] [TARGET_DIR]
#
#   TARGET_DIR defaults to ${ROOTFS_DIR:-/rootfs-build}, falling back to
#   ${OUTPUT_DIR:-/output}/sysroot if that doesn't exist. The report goes to
#   ${OUTPUT_DIR:-/output}/reports/static-audit.txt.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
STRICT=0
TARGET_DIR=""
ALLOWLIST="${SCRIPT_DIR}/../configs/attestation/dynamic-allowlist.txt"
USE_ALLOWLIST=1
REQUIRE_EMPTY=0
LOADER="lib/ld-musl-i386.so.1"

while [ $# -gt 0 ]; do
    case "$1" in
        --strict) STRICT=1 ;;
        --no-allowlist) USE_ALLOWLIST=0 ;;
        --require-empty-allowlist) REQUIRE_EMPTY=1 ;;
        --allowlist)
            if [ $# -lt 2 ]; then
                echo "ERROR: --allowlist needs a file" >&2
                exit 1
            fi
            ALLOWLIST="$2"
            USE_ALLOWLIST=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--strict] [--allowlist FILE | --no-allowlist] [--require-empty-allowlist] [TARGET_DIR]"
            exit 0
            ;;
        *) TARGET_DIR="$1" ;;
    esac
    shift
done

if [ -z "$TARGET_DIR" ]; then
    if [ -d "${ROOTFS_DIR:-/rootfs-build}" ]; then
        TARGET_DIR="${ROOTFS_DIR:-/rootfs-build}"
    else
        TARGET_DIR="${OUTPUT_DIR:-/output}/sysroot"
    fi
fi
TARGET_DIR="${TARGET_DIR%/}"

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
REPORT_DIR="${OUTPUT_DIR}/reports"
REPORT_FILE="${REPORT_DIR}/static-audit.txt"

if [ ! -d "$TARGET_DIR" ]; then
    echo "ERROR: target directory not found: $TARGET_DIR" >&2
    echo "  Run build-rootfs.sh (or extract-packages.sh) first, or pass an" >&2
    echo "  explicit path to an extracted rootfs/sysroot." >&2
    exit 1
fi

command -v scanelf >/dev/null || {
    echo "ERROR: 'scanelf' not found on PATH (pax-utils; needed to read ELF headers)" >&2
    exit 1
}

if [ "$USE_ALLOWLIST" -eq 1 ] && [ ! -f "$ALLOWLIST" ]; then
    echo "ERROR: allowlist not found: $ALLOWLIST" >&2
    exit 1
fi

mkdir -p "$REPORT_DIR" || exit 1
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

SCAN="$WORK/scan"
ENTRIES="$WORK/entries"     # allowlisted paths
DYNAMIC="$WORK/dynamic"     # every PT_INTERP path found
: > "$ENTRIES"
: > "$DYNAMIC"

echo "==> Static-link audit of ${TARGET_DIR}"

{
    echo "# Static-link audit"
    echo "# Target: ${TARGET_DIR}"
    echo "# Date:   $(date -Iseconds || date)"
    echo "#"
    echo "# The userland is all static (configs/portage/env/static.conf and"
    echo "# configs/portage/package.use/static): no dynamic binary, no loader, no"
    echo "# plugin or dlopen'd .so, no Python, no freetype chain. FINDING lines"
    echo "# break those doctrines; --strict makes them fail. INFO lines do not."
    echo
} > "$REPORT_FILE" || exit 1

FINDINGS=0
ERRORS=0
finding() { # <check> <relpath>
    FINDINGS=$((FINDINGS + 1))
    printf 'FINDING %s %s\n' "$1" "$2" >> "$REPORT_FILE"
}
problem() { # <message>
    ERRORS=$((ERRORS + 1))
    printf 'ERROR %s\n' "$1" >> "$REPORT_FILE"
    echo "ERROR: $1" >&2
}

# --- allowlist ---------------------------------------------------------------
ENTRY_COUNT=0
if [ "$USE_ALLOWLIST" -eq 1 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [ -z "$trimmed" ] && continue
        case "$trimmed" in '#'*) continue ;; esac
        ENTRY_COUNT=$((ENTRY_COUNT + 1))
        path="${trimmed%%#*}"
        path="${path%"${path##*[![:space:]]}"}"
        case "$trimmed" in
            *'#'*) comment="${trimmed#*#}" ;;
            *) comment="" ;;
        esac
        if [ -z "$path" ] || [ -z "${comment//[[:space:]]/}" ]; then
            problem "allowlist entry has no '# <issue> <reason>': ${trimmed}"
            continue
        fi
        printf '%s\n' "${path#/}" >> "$ENTRIES"
    done < "$ALLOWLIST"
fi

if [ "$REQUIRE_EMPTY" -eq 1 ] && [ "$ENTRY_COUNT" -gt 0 ]; then
    problem "--require-empty-allowlist: allowlist has ${ENTRY_COUNT} entries"
fi

# --- ELF scan ----------------------------------------------------------------
if ! scanelf -RBF '%a|%i|%t|%F' "$TARGET_DIR" > "$SCAN"; then
    problem "scanelf failed on ${TARGET_DIR}"
fi

ELF_COUNT=0
while IFS='|' read -r mach interp textrel file; do
    [ -z "$file" ] && continue
    ELF_COUNT=$((ELF_COUNT + 1))
    rel="${file#"${TARGET_DIR}"/}"
    mach="${mach//[[:space:]]/}"
    interp="${interp//[[:space:]]/}"
    allowed=0
    grep -Fxq -- "$rel" "$ENTRIES" && allowed=1

    if [ -n "$interp" ] && [ "$interp" != "-" ]; then
        printf '%s\n' "$rel" >> "$DYNAMIC"
        [ "$allowed" -eq 0 ] && finding interp "$rel"
    fi
    [ "$mach" != "EM_386" ] && finding machine "$rel"
    case "$textrel" in *TEXTREL*) printf 'INFO textrel %s\n' "$rel" >> "$REPORT_FILE" ;; esac
    case "$rel" in
        lib/modules/*|"$LOADER") : ;;
        *.so|*.so.*) [ "$allowed" -eq 0 ] && finding plugin "$rel" ;;
    esac
done < "$SCAN"

if [ "$ELF_COUNT" -eq 0 ]; then
    problem "no ELF file found under ${TARGET_DIR}"
fi

# stale allowlist entries: must name a dynamic ELF file
while IFS= read -r entry; do
    grep -Fxq -- "$entry" "$DYNAMIC" || problem "stale allowlist entry (not a dynamic file): ${entry}"
done < "$ENTRIES"

# musl loader: present iff the allowlist has an entry
if [ -e "${TARGET_DIR}/${LOADER}" ] || [ -L "${TARGET_DIR}/${LOADER}" ]; then
    [ "$ENTRY_COUNT" -eq 0 ] && finding loader "$LOADER"
else
    [ "$ENTRY_COUNT" -gt 0 ] && finding loader "$LOADER"
fi

# --- path-based doctrines ----------------------------------------------------
# run_find <args...>: print the rootfs-relative matches, one per line
run_find() {
    local out="$WORK/find.out"
    if ! (cd "$TARGET_DIR" && find . \( "$@" \) -print > "$out"); then
        problem "find failed under ${TARGET_DIR}"
        return
    fi
    sed 's|^\./||' "$out"
}

while IFS= read -r p; do
    [ -n "$p" ] && finding python "$p"
done < <(run_find \( -name '*.py' -o -name '*.pyc' \) -o \
    \( \( -path './bin/*' -o -path './sbin/*' -o -path './lib/*' -o -path './usr/bin/*' \
          -o -path './usr/sbin/*' -o -path './usr/lib/*' \) \
       \( -name python -o -name 'python[0-9]*' \) \))

while IFS= read -r p; do
    [ -n "$p" ] && finding font "$p"
done < <(run_find \( -name '*libfreetype*' -o -name '*libfontconfig*' -o -name '*libXft*' \) -o \
    \( -path './etc/fonts' -o -path './usr/share/fontconfig' \) -o \
    \( -path './var/db/pkg/*/freetype-*' -o -path './var/db/pkg/*/fontconfig-*' \
       -o -path './var/db/pkg/*/libXft-*' \))

# --- report ------------------------------------------------------------------
{
    echo
    echo "Scanned:               ${ELF_COUNT} ELF files"
    echo "Dynamically linked:    $(wc -l < "$DYNAMIC")"
    echo "Findings:              ${FINDINGS}"
} >> "$REPORT_FILE"

echo "==> Scanned ${ELF_COUNT} ELF files, ${FINDINGS} findings"
echo "==> Report: ${REPORT_FILE}"

if [ "$ERRORS" -gt 0 ]; then
    echo "==> failing: ${ERRORS} errors" >&2
    exit 1
fi
if [ "$FINDINGS" -gt 0 ] && [ "$STRICT" -eq 1 ]; then
    echo "==> --strict: failing due to ${FINDINGS} findings" >&2
    exit 1
fi
if [ "$FINDINGS" -eq 0 ] && [ "$ERRORS" -eq 0 ]; then
    echo "static-audit: PASS"
fi
exit 0
