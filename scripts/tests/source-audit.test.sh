#!/bin/sh
# B01-AC-11 (changes 9, 10): scripts/source-audit.sh fails on a fixture sysroot in each of four cases and
# passes on a clean one:
#   a  a file owned by a cpv absent from the run's `>>> Emerging (` lines
#   b  a file owned by a cpv whose BUILD_TIME is before the run start (ruling 23 N2: the Emerging line IS
#      in the log, e.g. a failed re-merge of a preinstalled package)
#   c  an unowned file not in the exceptions list
#   d  a stale exception (matches no file)
# Interface under test (chosen for slice 3, simplest that fits the spec):
#   source-audit.sh --sysroot DIR --vdb DIR --log FILE --start EPOCH --exceptions FILE --output TSV
#     DIR   the exported sysroot (output/sysroot); every regular file and symlink in it is assigned an owner
#     VDB   target VDB: VDB/<cat>/<pf>/CONTENTS and VDB/<cat>/<pf>/BUILD_TIME (epoch seconds)
#     LOG   emerge log; a cpv is built from source iff a line `>>> Emerging (N of M) <cpv>[::repo] ...` names it
#           (`>>> Emerging binary (` lines do not count); its BUILD_TIME must be >= EPOCH
#     EXCEPTIONS  lines `<absolute path> <host cpv>`, `#` comments; the host owner of a file the target VDB
#           does not own. Every line must match a file in DIR.
#     TSV   report: header `path<TAB>owner<TAB>provenance`, then one row per file, path with leading `/`,
#           provenance `built-this-run` or `bootstrap`
#   exit 0 iff no failing case; each failure names its path or cpv on stdout/stderr.
# Also checks configs/attestation/bootstrap-exceptions.txt (change 10) against configs/portage/crossdev.lock.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUBJ="$ROOT/scripts/source-audit.sh"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

START=1000
# mk NAME [flags]: $TMP/NAME/{sysroot,vdb,emerge.log,exceptions.txt}
#   nolog      bar-2 has no Emerging line          binlog   bar-2 only in an `Emerging binary` line
#   oldbar     bar-2 BUILD_TIME before start       edgebar  bar-2 BUILD_TIME == start (passes)
#   wrongver   log names bar-1, VDB owner is bar-2
#   stray      unowned usr/bin/stray               stale    exception for a path not in the sysroot
mk() {
    n=$1; shift; d="$TMP/$n"; flags=" $* "
    S="$d/sysroot"; V="$d/vdb"
    mkdir -p "$S/usr/bin" "$S/lib" "$V/app-misc/foo-1" "$V/app-misc/bar-2"
    : > "$S/usr/bin/foo"; : > "$S/usr/bin/bar"; : > "$S/lib/ld-musl-i386.so.1"
    ln -s foo "$S/usr/bin/baz"
    case "$flags" in *" stray "*) : > "$S/usr/bin/stray" ;; esac
    printf 'dir /usr\ndir /usr/bin\nobj /usr/bin/foo d41d8cd98f00b204e9800998ecf8427e 1\nsym /usr/bin/baz -> foo 1\n' > "$V/app-misc/foo-1/CONTENTS"
    printf 'dir /usr\nobj /usr/bin/bar d41d8cd98f00b204e9800998ecf8427e 1\n' > "$V/app-misc/bar-2/CONTENTS"
    echo 1500 > "$V/app-misc/foo-1/BUILD_TIME"
    bt=1500
    case "$flags" in *" oldbar "*) bt=900 ;; *" edgebar "*) bt=$START ;; esac
    echo "$bt" > "$V/app-misc/bar-2/BUILD_TIME"
    {
        echo '>>> Emerging (1 of 2) app-misc/foo-1::gentoo to /usr/i486-linux-musl/'
        case "$flags" in
            *" nolog "*) : ;;
            *" binlog "*) echo '>>> Emerging binary (2 of 2) app-misc/bar-2::gentoo to /usr/i486-linux-musl/' ;;
            *" wrongver "*) echo '>>> Emerging (2 of 2) app-misc/bar-1::gentoo to /usr/i486-linux-musl/' ;;
            *) echo '>>> Emerging (2 of 2) app-misc/bar-2::gentoo to /usr/i486-linux-musl/' ;;
        esac
    } > "$d/emerge.log"
    { echo '# bootstrap exceptions'; echo '/lib/ld-musl-i386.so.1 cross-i486-linux-musl/musl-1.2.6'
      case "$flags" in *" stale "*) echo '/lib/gone.so cross-i486-linux-musl/musl-1.2.6' ;; esac
    } > "$d/exceptions.txt"
}
# go NAME: runs the subject, sets RC and $TMP/NAME/out.txt
go() {
    d="$TMP/$1"
    sh "$SUBJ" --sysroot "$d/sysroot" --vdb "$d/vdb" --log "$d/emerge.log" --start "$START" \
        --exceptions "$d/exceptions.txt" --output "$d/source-audit.tsv" > "$d/out.txt" 2>&1
    RC=$?
}
# neg LABEL DEFECT TOKEN: control must exit 0, the defect non-zero and name TOKEN
neg() {
    go clean; rc_ctl=$RC
    go "$2"
    if [ "$rc_ctl" -eq 0 ] && [ "$RC" -ne 0 ] && grep -q -- "$3" "$TMP/$2/out.txt"; then
        ok "B01-AC-11 $1: exits non-zero and names $3"
    else fail "B01-AC-11 $1: exits non-zero and names $3 (defect rc=$RC, control rc=$rc_ctl)"; fi
}

mk clean
go clean
[ "$RC" -eq 0 ] && ok "B01-AC-11 clean fixture sysroot passes" || fail "B01-AC-11 clean fixture sysroot passes (rc=$RC)"
T="$TMP/clean/source-audit.tsv"
row() { awk -F'\t' -v p="$1" -v o="$2" -v c="$3" '$1==p && $2==o && $3==c {f=1} END{exit !f}' "$T" 2>/dev/null; }
row /usr/bin/foo app-misc/foo-1 built-this-run && row /usr/bin/bar app-misc/bar-2 built-this-run \
    && row /usr/bin/baz app-misc/foo-1 built-this-run \
    && ok "B01-AC-11 report rows (path, owner, built-this-run) for files and symlinks" \
    || fail "B01-AC-11 report rows (path, owner, built-this-run) for files and symlinks"
row /lib/ld-musl-i386.so.1 cross-i486-linux-musl/musl-1.2.6 bootstrap \
    && ok "B01-AC-11 report row for the declared exception is 'bootstrap' with its host owner" \
    || fail "B01-AC-11 report row for the declared exception is 'bootstrap' with its host owner"

mk nolog nolog;     neg "(a) file owned by a cpv absent from the Emerging lines" nolog app-misc/bar-2
mk binlog binlog;   neg "(a) cpv only in an 'Emerging binary' line is not source-built" binlog app-misc/bar-2
mk wrongver wrongver; neg "(a) log names another version of the package" wrongver app-misc/bar-2
mk oldbar oldbar;   neg "(b, ruling 23 N2) Emerging line present but BUILD_TIME before run start" oldbar app-misc/bar-2
mk stray stray;     neg "(c) unowned file not in the exceptions list" stray /usr/bin/stray
mk stale stale;     neg "(d) stale exception" stale /lib/gone.so

mk edgebar edgebar; go edgebar
[ "$RC" -eq 0 ] && ok "B01-AC-11 BUILD_TIME equal to the run start passes ('at or after')" \
    || fail "B01-AC-11 BUILD_TIME equal to the run start passes (rc=$RC)"

# --- change 10: configs/attestation/bootstrap-exceptions.txt ---
EX="$ROOT/configs/attestation/bootstrap-exceptions.txt"
LOCK="$ROOT/configs/portage/crossdev.lock"
if [ -f "$EX" ] && grep -q '^/usr/bin/ldd[[:space:]]' "$EX"; then
    ok "B01-AC-11 bootstrap-exceptions.txt lists /usr/bin/ldd"
else fail "B01-AC-11 bootstrap-exceptions.txt lists /usr/bin/ldd"; fi
bad=$(grep -v '^[[:space:]]*\(#\|$\)' "$EX" 2>/dev/null | awk -v lock="$LOCK" '
    BEGIN { while ((getline l < lock) > 0) { if (l ~ /^#/ || l == "") continue; split(l, a, ":"); n = a[1]; sub(/.*\//, "", n); ver[n] = a[2] } }
    { cpv = $2; if (cpv !~ /^cross-i486-linux-musl\//) { print "not a cross package: " $0; next }
      pf = cpv; sub(/^[^\/]*\//, "", pf)
      found = 0
      for (n in ver) if (index(pf, n "-") == 1 && substr(pf, length(n) + 2) ~ ("^" ver[n] "(-r[0-9]+)?$")) found = 1
      if (!found) print "version differs from crossdev.lock: " $0 }')
if [ -f "$EX" ] && [ -z "$bad" ]; then ok "B01-AC-11 every bootstrap exception is a cross-i486-linux-musl cpv at the crossdev.lock version"
else fail "B01-AC-11 every bootstrap exception is a cross cpv at the crossdev.lock version ($bad)"; fi


# --- B01-AC-11 / B01-AC-12 (change 9 as amended by spec #55): allowlist mode (lines added by P02) ---
# Added interface: the optional argument  --allowlist FILE  (configs/attestation/unowned-allowlist.yaml form:
#   `  - path: <fnmatch pattern>   # comment` then `    source: "<value>"`; patterns follow check-unowned.py:
#   fnmatch on the path without its leading `/`, `*` also matches `/`).
#   Only `source: portage` and `source: "postinst:<cat/pn>"` entries cover an unowned sysroot file; `build-rootfs.sh`
#   entries never do; an entry matching no sysroot file is not a failure. The `postinst:<cat/pn>` entry covers a file
#   only when some cpv of that cat/pn has a `>>> Emerging (N of M)` line in the log. Without --allowlist behaviour
#   is unchanged. Report provenance: `portage` (owner column `portage`) or `postinst` (owner column the built cpv).
goa() {
    d="$TMP/$1"
    sh "$SUBJ" --sysroot "$d/sysroot" --vdb "$d/vdb" --log "$d/emerge.log" --start "$START" \
        --exceptions "$d/exceptions.txt" --allowlist "$2" --output "$d/source-audit.tsv" > "$d/out.txt" 2>&1
    RC=$?
}
# unown NAME PATH...: add unowned files to the fixture sysroot
unown() { n=$1; shift; for f in "$@"; do mkdir -p "$TMP/$n/sysroot/$(dirname "$f")"; : > "$TMP/$n/sysroot/$f"; done; }
AL="$TMP/allowlist.yaml"
cat > "$AL" <<'YAML'
allowlist:
  - path: etc/profile.env   # env-update output
    source: "portage"
  - path: var/db/pkg/**
    source: portage
  - path: etc/env.d/05bar
    source: "postinst:app-misc/bar"
  - path: etc/env.d/05qux
    source: "postinst:app-misc/qux"
  - path: opt/rootfs/*
    source: "build-rootfs.sh"
  - path: lib/ld-musl-i386.so.1
    source: "portage"
  - path: never/there
    source: "portage"
modified:
  - path: usr/bin/stray
    source: "portage"
YAML
rowr() { awk -F'\t' -v p="$2" -v o="$3" -v c="$4" '$1==p && $2==o && $3==c {f=1} END{exit !f}' "$1" 2>/dev/null; }

mk alp; unown alp etc/profile.env var/db/pkg/cat/pkg-1/CONTENTS var/db/pkg/a/b/c/deep
goa alp "$AL"
[ "$RC" -eq 0 ] && ok "B01-AC-11 unowned files covered by portage allowlist entries pass" \
    || fail "B01-AC-11 unowned files covered by portage allowlist entries pass (rc=$RC)"
rowr "$TMP/alp/source-audit.tsv" /etc/profile.env portage portage \
    && rowr "$TMP/alp/source-audit.tsv" /var/db/pkg/cat/pkg-1/CONTENTS portage portage \
    && ok "B01-AC-12 portage-covered file: report row has owner and provenance 'portage'" \
    || fail "B01-AC-12 portage-covered file: report row has owner and provenance 'portage'"
rowr "$TMP/alp/source-audit.tsv" /var/db/pkg/a/b/c/deep portage portage \
    && ok "B01-AC-11 pattern 'var/db/pkg/**' follows fnmatch: matches across directories" \
    || fail "B01-AC-11 pattern 'var/db/pkg/**' follows fnmatch: matches across directories"
rowr "$TMP/alp/source-audit.tsv" /usr/bin/foo app-misc/foo-1 built-this-run \
    && ok "B01-AC-12 owned files keep their built-this-run rows with an allowlist" \
    || fail "B01-AC-12 owned files keep their built-this-run rows with an allowlist"

mk alpi; unown alpi etc/env.d/05bar
goa alpi "$AL"
[ "$RC" -eq 0 ] && ok "B01-AC-11 unowned file covered by postinst:app-misc/bar (bar-2 built this run) passes" \
    || fail "B01-AC-11 unowned file covered by postinst:app-misc/bar (bar-2 built this run) passes (rc=$RC)"
rowr "$TMP/alpi/source-audit.tsv" /etc/env.d/05bar app-misc/bar-2 postinst \
    && ok "B01-AC-12 postinst row names the built cpv app-misc/bar-2 as owner" \
    || fail "B01-AC-12 postinst row names the built cpv app-misc/bar-2 as owner"

mk alpn; unown alpn etc/env.d/05qux
goa alpn "$AL"
if [ "$RC" -ne 0 ] && grep -q -e /etc/env.d/05qux -e app-misc/qux "$TMP/alpn/out.txt"; then
    ok "B01-AC-11 postinst:app-misc/qux entry, package not built this run: fails and names it"
else fail "B01-AC-11 postinst:app-misc/qux entry, package not built this run: fails and names it (rc=$RC)"; fi

mk alpb; unown alpb etc/env.d/05qux
echo '>>> Emerging binary (3 of 3) app-misc/qux-1::gentoo to /usr/i486-linux-musl/' >> "$TMP/alpb/emerge.log"
goa alpb "$AL"
if [ "$RC" -ne 0 ] && grep -q -e /etc/env.d/05qux -e app-misc/qux "$TMP/alpb/out.txt"; then
    ok "B01-AC-11 postinst entry whose package only has an 'Emerging binary' line: fails and names it"
else fail "B01-AC-11 postinst entry whose package only has an 'Emerging binary' line: fails and names it (rc=$RC)"; fi

mk alps; unown alps etc/env.d/05qux
echo '>>> Emerging (3 of 3) app-misc/qux-1::gentoo to /usr/i486-linux-musl/' >> "$TMP/alps/emerge.log"
goa alps "$AL"
if [ "$RC" -eq 0 ] && rowr "$TMP/alps/source-audit.tsv" /etc/env.d/05qux app-misc/qux-1 postinst; then
    ok "B01-AC-11 postinst entry passes once the package has an Emerging line (row owner app-misc/qux-1)"
else fail "B01-AC-11 postinst entry passes once the package has an Emerging line (rc=$RC)"; fi

mk alpr; unown alpr opt/rootfs/file
goa alpr "$AL"
if [ "$RC" -ne 0 ] && grep -q /opt/rootfs/file "$TMP/alpr/out.txt"; then
    ok "B01-AC-11 build-rootfs.sh allowlist entry does not cover a sysroot file: fails and names it"
else fail "B01-AC-11 build-rootfs.sh allowlist entry does not cover a sysroot file (rc=$RC)"; fi

mk alpx; unown alpx etc/other opt/rootfs/file
goa alpx "$AL"
if [ "$RC" -ne 0 ] && grep -q /etc/other "$TMP/alpx/out.txt"; then
    ok "B01-AC-11 unowned file matching no allowlist entry still fails with an allowlist given"
else fail "B01-AC-11 unowned file matching no allowlist entry still fails with an allowlist given (rc=$RC)"; fi

mk alpm; unown alpm usr/bin/stray
goa alpm "$AL"
if [ "$RC" -ne 0 ] && grep -q /usr/bin/stray "$TMP/alpm/out.txt"; then
    ok "B01-AC-11 the modified: section is not an allowlist"
else fail "B01-AC-11 the modified: section is not an allowlist (rc=$RC)"; fi

# the exception list and the allowlist coexist; unmatched allowlist entries (never/there) are not stale
mk alpc; goa alpc "$AL"
[ "$RC" -eq 0 ] && ok "B01-AC-11 clean fixture passes with an allowlist (unmatched entries are not failures)" \
    || fail "B01-AC-11 clean fixture passes with an allowlist (rc=$RC)"

# frozen calls without --allowlist keep their results: unowned file covered only by the allowlist fails
mk alpq; unown alpq etc/profile.env; go alpq
if [ "$RC" -ne 0 ] && grep -q /etc/profile.env "$TMP/alpq/out.txt"; then
    ok "B01-AC-11 without --allowlist an unowned file still fails"
else fail "B01-AC-11 without --allowlist an unowned file still fails (rc=$RC)"; fi

# the real allowlist covers paths from a real release-mode run (literals from run 42538229470)
REAL="$ROOT/configs/attestation/unowned-allowlist.yaml"
mk alpreal
unown alpreal bin/sh etc/profile.env etc/csh.env etc/passwd- etc/env.d/05binutils etc/env.d/binutils/config-i486-linux-musl \
    usr/bin/ld usr/bin/objdump var/db/pkg/sys-libs/musl-1.2.6/CONTENTS
for pn in sys-devel/binutils sys-apps/shadow; do
    echo ">>> Emerging (3 of 3) ${pn}-1::gentoo to /usr/i486-linux-musl/" >> "$TMP/alpreal/emerge.log"
done
goa alpreal "$REAL"
if [ "$RC" -eq 0 ] && rowr "$TMP/alpreal/source-audit.tsv" /etc/profile.env portage portage \
    && rowr "$TMP/alpreal/source-audit.tsv" /usr/bin/ld sys-devel/binutils-1 postinst; then
    ok "B01-AC-12 real unowned-allowlist.yaml covers paths of a real run (portage and postinst rows)"
else fail "B01-AC-12 real unowned-allowlist.yaml covers paths of a real run (rc=$RC): $(head -5 "$TMP/alpreal/out.txt" | tr '\n' ' ')"; fi

# build-packages.sh's release call passes the allowlist to source-audit.sh
if awk '/source-audit\.sh/ {on=1} on {print} on && /output/ {exit}' "$ROOT/scripts/build-packages.sh" \
    | grep -q -e '--allowlist.*unowned-allowlist\.yaml'; then
    ok "B01-AC-12 build-packages.sh release call passes --allowlist unowned-allowlist.yaml"
else fail "B01-AC-12 build-packages.sh release call passes --allowlist unowned-allowlist.yaml"; fi
echo
[ "$fails" -eq 0 ] && { echo "source-audit: all passed"; exit 0; }
echo "source-audit: $fails failed"; exit 1
