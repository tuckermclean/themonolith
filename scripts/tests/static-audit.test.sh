#!/bin/sh
# static-audit.test.sh - O02 acceptance tests for scripts/static-audit.sh (AC-1..AC-6).
#
# CONTRACT the implementation must follow (grounded in real pax-utils 1.3.8 output):
#   Command line:  static-audit.sh [--strict] [--allowlist FILE | --no-allowlist]
#                                  [--require-empty-allowlist] TARGET_DIR
#     (default allowlist: configs/attestation/dynamic-allowlist.txt relative to the repo)
#   ELF scan: ONE call per run, `scanelf -RBF '%a|%i|%t|%F' TARGET_DIR`, the tool found
#     on PATH. Real output, one line per ELF file (non-ELF files print nothing; an
#     unreadable/missing target prints nothing and exits 1):
#         EM_386||   -   |TARGET_DIR/bin/busybox          static: %i empty, %t "   -   "
#         EM_X86_64|/lib64/ld-linux-x86-64.so.2|   -   |TARGET_DIR/bin/ls
#     %t is "TEXTREL" for a file with text relocations. %F is TARGET_DIR-prefixed;
#     the script strips the prefix: findings use rootfs-relative paths.
#     The stub below keys its answer on each file's first line, "ELFSTUB <a>|<i>|<t>",
#     and prints nothing for files without it.
#   Report: $OUTPUT_DIR/reports/static-audit.txt, with lines exactly
#         FINDING <check> <relpath>     (interp machine loader python font plugin)
#         INFO textrel <relpath>        (never fails)
#     Stale or malformed allowlist entries also fail (exit non-zero).
#   Exit: 0 only for a clean audit, which prints the line "static-audit: PASS" on stdout
#     (never printed on any failing exit). Without --strict, findings do not change the
#     exit status; missing target, missing scanelf and zero ELF files are always exit 1.
#   Allowlist line: "<rootfs-relative path> # <issue> <reason>". The musl loader is
#     lib/ld-musl-i386.so.1: present iff the allowlist has an entry (else FINDING loader).
#   --no-allowlist: ignore any allowlist; every PT_INTERP file is FINDING interp.

SUBJECT=scripts/static-audit.sh
BUILD_ROOTFS=scripts/build-rootfs.sh
BASH_BIN=$(command -v bash || echo /bin/bash)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }

# --- stubs ---------------------------------------------------------------------
STUB="$T/stubbin"; mkdir -p "$STUB"
cat > "$STUB/scanelf" <<'STUBEOF'
#!/bin/sh
# last argument is the directory; print "<a>|<i>|<t>|<path>" for files marked ELFSTUB
for last; do :; done
[ -d "$last" ] || exit 1
find "$last" -type f | while IFS= read -r f; do
    l=$(head -n 1 "$f")
    case "$l" in
        "ELFSTUB "*) printf '%s|%s\n' "${l#ELFSTUB }" "$f" ;;
    esac
done
exit 0
STUBEOF
chmod +x "$STUB/scanelf"
# PATH without scanelf: symlink the tools a script may need.
NOSCAN="$T/noscan"; mkdir -p "$NOSCAN"
for tool in sh bash find grep sed awk sort cat mkdir date env dirname basename tr cut head tail wc rm printf test '[' ls uname comm cmp mktemp uniq xargs cp mv readlink tee sleep id; do
    p=$(command -v "$tool" 2>/dev/null) && case "$p" in /*) ln -sf "$p" "$NOSCAN/$tool" ;; esac
done

# --- helpers -------------------------------------------------------------------
N=0
newtree() { N=$((N + 1)); TREE="$T/t$N"; OD="$T/o$N"; mkdir -p "$TREE" "$OD"; }
# elf <rel> [machine] [interp] [textrel] [mode]
elf() {
    mkdir -p "$TREE/$(dirname "$1")"
    printf 'ELFSTUB %s|%s|%s\n' "${2:-EM_386}" "${3:-}" "${4:-   -   }" > "$TREE/$1"
    chmod "${5:-755}" "$TREE/$1"
}
plain() { mkdir -p "$TREE/$(dirname "$1")"; echo "data" > "$TREE/$1"; }
cleantree() { newtree; elf usr/bin/true; elf bin/busybox; }
EMPTY="$T/empty.txt"; : > "$EMPTY"
LOADER=lib/ld-musl-i386.so.1
# run <args...>: sets RC, OUT; script absent -> RC=99 (every assertion then fails)
run() {
    if [ ! -f "$SUBJECT" ]; then OUT="$SUBJECT: not found"; RC=99; return; fi
    OUT=$(PATH="$STUB:$PATH" OUTPUT_DIR="$OD" "$BASH_BIN" "$SUBJECT" "$@" 2>&1); RC=$?
}
failing() { [ "$RC" -ne 0 ] && [ "$RC" -ne 99 ]; }
notclean() { case "$OUT" in *"static-audit: PASS"*) return 1 ;; esac; return 0; }
report() { cat "$OD/reports/static-audit.txt" 2>/dev/null; }
has() { report | grep -Fqx "$1"; }
# expect_fail <name> <finding line or ''> (after run)
expect_fail() {
    if failing && notclean && { [ -z "$2" ] || has "$2"; }; then pass "$1"; else fail "$1 (rc=$RC want '$2')"; fi
}
expect_clean() {
    if [ "$RC" -eq 0 ] && case "$OUT" in *"static-audit: PASS"*) true ;; *) false ;; esac && ! report | grep -q '^FINDING'; then
        pass "$1"; else fail "$1 (rc=$RC)"; fi
}

# --- AC-1: no hidden failures --------------------------------------------------
newtree; run --strict --allowlist "$EMPTY" "$T/does-not-exist"
expect_fail "O02-AC-1 missing target dir exits non-zero, not clean" ""
cleantree
OUT=$(PATH="$NOSCAN" OUTPUT_DIR="$OD" "$BASH_BIN" "$SUBJECT" --strict --allowlist "$EMPTY" "$TREE" 2>&1); RC=$?
[ -f "$SUBJECT" ] || RC=99
expect_fail "O02-AC-1 scanelf not on PATH exits non-zero, not clean" ""
newtree; plain etc/motd; plain usr/share/doc/readme; run --strict --allowlist "$EMPTY" "$TREE"
expect_fail "O02-AC-1 tree with no ELF file exits non-zero, not clean" ""

# --- AC-2: scanelf findings ----------------------------------------------------
cleantree; run --strict --allowlist "$EMPTY" "$TREE"
expect_clean "O02-AC-2 clean EM_386 static tree passes --strict"
cleantree; elf usr/bin/hidden EM_386 /lib/ld-musl-i386.so.1 '   -   ' 644
run --strict --allowlist "$EMPTY" "$TREE"
expect_fail "O02-AC-2 non-executable (0644) file with PT_INTERP: FINDING interp" "FINDING interp usr/bin/hidden"
cleantree; elf usr/bin/wide EM_X86_64
run --strict --allowlist "$EMPTY" "$TREE"
expect_fail "O02-AC-2 EM_X86_64 file: FINDING machine" "FINDING machine usr/bin/wide"
cleantree; elf usr/bin/reloc EM_386 '' TEXTREL
run --strict --allowlist "$EMPTY" "$TREE"
if [ "$RC" -eq 0 ] && has "INFO textrel usr/bin/reloc" && ! has "FINDING textrel usr/bin/reloc"; then
    pass "O02-AC-2 textrel is INFO and does not fail"; else fail "O02-AC-2 textrel is INFO and does not fail (rc=$RC)"; fi
cleantree; elf usr/bin/wide EM_X86_64
run --allowlist "$EMPTY" "$TREE"
if [ "$RC" -eq 0 ] && has "FINDING machine usr/bin/wide"; then
    pass "O02-AC-2 without --strict a finding is reported but exit is 0"; else fail "O02-AC-2 without --strict a finding is reported but exit is 0 (rc=$RC)"; fi

# --- AC-3: allowlist -----------------------------------------------------------
AL="$T/al.txt"
dyntree() { cleantree; elf "$LOADER"; elf usr/bin/dyn EM_386 "/$LOADER"; }
dyntree; echo 'usr/bin/dyn # O02-9 upstream has no static flag' > "$AL"
run --strict --allowlist "$AL" "$TREE"
expect_clean "O02-AC-3 allowlisted dynamic file (loader present) passes"
dyntree; echo 'usr/bin/dyn # O02-9 upstream has no static flag' > "$AL"
run --strict --no-allowlist "$TREE"
expect_fail "O02-AC-3 --no-allowlist: allowlisted dynamic file is FINDING interp" "FINDING interp usr/bin/dyn"
dyntree; echo 'usr/bin/gone # O02-9 removed' > "$AL"
run --strict --allowlist "$AL" "$TREE"
expect_fail "O02-AC-3 stale entry (no such file) fails" ""
dyntree; echo 'usr/bin/true # O02-9 not dynamic any more' > "$AL"
run --strict --allowlist "$AL" "$TREE"
expect_fail "O02-AC-3 stale entry (file no longer dynamic) fails" ""
dyntree; echo 'usr/bin/dyn' > "$AL"
run --strict --allowlist "$AL" "$TREE"
expect_fail "O02-AC-3 entry without '# <issue> <reason>' fails" ""
cleantree; elf "$LOADER"
run --strict --allowlist "$EMPTY" "$TREE"
expect_fail "O02-AC-3 loader present with empty allowlist: FINDING loader" "FINDING loader $LOADER"
cleantree; elf usr/bin/dyn EM_386 "/$LOADER"; echo 'usr/bin/dyn # O02-9 reason' > "$AL"
run --strict --allowlist "$AL" "$TREE"
expect_fail "O02-AC-3 loader absent with non-empty allowlist: FINDING loader" "FINDING loader $LOADER"

# --- AC-4: --require-empty-allowlist -------------------------------------------
dyntree; echo 'usr/bin/dyn # O02-9 reason' > "$AL"
run --strict --require-empty-allowlist --allowlist "$AL" "$TREE"
expect_fail "O02-AC-4 --require-empty-allowlist fails on a one-entry file" ""
cleantree; run --strict --require-empty-allowlist --allowlist "$EMPTY" "$TREE"
expect_clean "O02-AC-4 --require-empty-allowlist passes on an empty file"

# --- AC-5: other doctrines -----------------------------------------------------
# plugin_case <name> <setup-cmd> <finding>
c5() { cleantree; eval "$2"; run --strict --allowlist "$EMPTY" "$TREE"; expect_fail "$1" "$3"; }
c5 "O02-AC-5 ELF .so outside lib/modules: FINDING plugin" "elf usr/lib/foo.so EM_386 '' '   -   ' 644" "FINDING plugin usr/lib/foo.so"
c5 "O02-AC-5 usr/bin/python3: FINDING python" "plain usr/bin/python3" "FINDING python usr/bin/python3"
c5 "O02-AC-5 a .py file: FINDING python" "plain usr/share/gdb/x_gdb.py" "FINDING python usr/share/gdb/x_gdb.py"
c5 "O02-AC-5 a .pyc file: FINDING python" "plain usr/lib/mod.pyc" "FINDING python usr/lib/mod.pyc"
c5 "O02-AC-5 usr/lib/libfreetype.so.6: FINDING font" "plain usr/lib/libfreetype.so.6" "FINDING font usr/lib/libfreetype.so.6"
c5 "O02-AC-5 var/db/pkg/media-libs/freetype-2.13 dir: FINDING font" "mkdir -p \$TREE/var/db/pkg/media-libs/freetype-2.13" "FINDING font var/db/pkg/media-libs/freetype-2.13"
cleantree; plain usr/share/man/man8/ld.so.8; plain usr/share/bash-completion/completions/python3.bash
elf lib/modules/6.12/kernel/net/x.ko EM_386 '' '   -   ' 644; elf lib/modules/6.12/kernel/y.so EM_386 '' '   -   ' 644
run --strict --allowlist "$EMPTY" "$TREE"
expect_clean "O02-AC-5 non-ELF ld.so.8, python3.bash and ELF .ko/.so under lib/modules are not findings"

# --- review 1, ruling 10: a failing find is an error, not a clean pass ----------
# PATH without find (stub scanelf kept, running with the full PATH); python findings would exist.
NOFIND="$T/nofind"; mkdir -p "$NOFIND"
for tool in sh bash grep sed awk sort cat mkdir date env dirname basename tr cut head tail wc rm printf test '[' ls uname comm cmp mktemp uniq xargs cp mv readlink tee sleep id; do
    p=$(command -v "$tool" 2>/dev/null) && case "$p" in /*) ln -sf "$p" "$NOFIND/$tool" ;; esac
done
printf '#!/bin/sh\nPATH=%s exec %s/scanelf "$@"\n' "$PATH" "$STUB" > "$NOFIND/scanelf"; chmod +x "$NOFIND/scanelf"
cleantree; plain usr/share/x/a.py; plain usr/bin/python3
OUT=$(PATH="$NOFIND" OUTPUT_DIR="$OD" "$BASH_BIN" "$SUBJECT" --strict --allowlist "$EMPTY" "$TREE" 2>&1); RC=$?
[ -f "$SUBJECT" ] || RC=99
expect_fail "O02-AC-6 (review 1, ruling 10) find not on PATH exits non-zero, not clean" ""

# --- review 1, ruling 9: allowlisted libraries are live entries -----------------
dyntree; elf usr/lib/libfoo.so.1 EM_386 '' '   -   ' 644
printf 'usr/bin/dyn # 1 reason\nusr/lib/libfoo.so.1 # 2 its library\n' > "$AL"
run --strict --allowlist "$AL" "$TREE"
expect_clean "O02-AC-3 (review 1, ruling 9) allowlisted dynamic binary plus its allowlisted .so passes --strict"
dyntree; elf usr/bin/static2 EM_386
printf 'usr/bin/dyn # 1 reason\nusr/bin/static2 # 2 not dynamic, not a .so\n' > "$AL"
run --strict --allowlist "$AL" "$TREE"
expect_fail "O02-AC-3 (review 1, ruling 9) allowlist entry naming a static non-.so ELF is stale" ""

# --- review 2, ruling 12: unreadable files are errors ---------------------------
# Real scanelf -R skips a file it cannot open, prints nothing, exits 0; the stub does the same
# (head fails on it, the file prints nothing). Running as root would read every file, so that is a FAIL.
if [ "$(id -u)" -eq 0 ]; then
    fail "O02-AC-6 (review 2, ruling 12) tests must run as non-root: unreadable files are readable to root"
else
    cleantree; elf usr/bin/a; elf usr/bin/b; elf usr/lib/c
    elf usr/bin/dyn EM_X86_64 "/$LOADER" '   -   ' 111
    run --strict --allowlist "$EMPTY" "$TREE"
    expect_fail "O02-AC-6 (review 2, ruling 12) unreadable (0111) ELF with PT_INTERP is an error, not a clean pass" ""
    cleantree; elf usr/lib/sub/x EM_386 '' '   -   ' 000; elf usr/lib/zzz
    run --strict --allowlist "$EMPTY" "$TREE"
    expect_fail "O02-AC-6 (review 2, ruling 12) unreadable file in a subdirectory with a readable file after it is an error" ""
    dyntree; echo 'usr/bin/dyn # O02-9 reason' > "$AL"; chmod 000 "$AL"
    run --strict --allowlist "$AL" "$TREE"
    chmod 644 "$AL"
    expect_fail "O02-AC-6 (review 2, ruling 12) unreadable allowlist file is an error, not a clean pass" ""
    # review 3: the case above fails anyway on dyntree (no allowlist -> FINDING interp/loader); these cannot.
    cleantree; echo 'usr/bin/true # 1 x' > "$AL"; chmod 000 "$AL"
    run --strict --allowlist "$AL" "$TREE"
    chmod 644 "$AL"
    expect_fail "O02-AC-6 (review 3) unreadable allowlist on a clean tree with --strict is an error" ""
    case "$OUT" in *"static-audit: PASS"*) fail "O02-AC-6 (review 3) unreadable allowlist (--strict, clean tree) did not print PASS" ;; *) pass "O02-AC-6 (review 3) unreadable allowlist (--strict, clean tree) did not print PASS" ;; esac
    cleantree; echo 'usr/bin/true # 1 x' > "$AL"; chmod 000 "$AL"
    run --allowlist "$AL" "$TREE"
    chmod 644 "$AL"
    expect_fail "O02-AC-6 (review 3) unreadable allowlist on a clean tree without --strict is an error" ""
fi

# --- AC-6: no hidden failures in source ----------------------------------------
if [ -f "$SUBJECT" ] && ! grep -q '2>/dev/null' "$SUBJECT"; then
    pass "O02-AC-6 static-audit.sh contains no 2>/dev/null"; else fail "O02-AC-6 static-audit.sh contains no 2>/dev/null (or script missing)"; fi
if [ -f "$BUILD_ROOTFS" ]; then
    if grep -q 'static-audit\.sh' "$BUILD_ROOTFS" && ! grep 'static-audit\.sh' "$BUILD_ROOTFS" | grep -q -- '--strict'; then
        pass "O02-AC-6 build-rootfs.sh calls static-audit.sh without --strict"; else fail "O02-AC-6 build-rootfs.sh calls static-audit.sh without --strict"; fi
else
    echo "NOTE O02-AC-6 $BUILD_ROOTFS is B03's and not yet ported; its calls are checked once it exists"
fi

echo "failures: $FAILS"
[ "$FAILS" -eq 0 ]
