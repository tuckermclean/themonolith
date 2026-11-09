#!/bin/sh
# G01 slice S2c: binutils is only dangling links (node spec change 4, G01-AC-6).
# The disc's link chain is /usr/bin/<tool> -> i486-linux-musl-<tool> -> /usr/i486-linux-musl/bin/<tool>
#   -> /usr/i486-linux-musl/binutils-bin/<ver>/<tool>. The last two hops' first link is made by binutils-config
#   (not in CONTENTS), so the exports must keep usr/i486-linux-musl/bin/<tool> for the 16 tools and nothing else of it.
#   G01-AC-6 (c)  build-packages.sh's sysroot export keeps the chain, drops the rest.
#   G01-AC-6 (d)  scripts/extract-packages.sh's export applies the same rules.
#   G01-AC-6 (e)  configs/attestation/unowned-allowlist.yaml lists usr/bin/i486-linux-musl-<tool> and
#                 usr/i486-linux-musl/bin/<tool> (source postinst:sys-devel/binutils) for the 16 tools.
# Neither the toolbox nor the host has rsync, so each script's own --include/--exclude arguments are extracted from
# its text and replayed by a perl implementation of rsync's filter semantics (first match wins, anchored with a
# leading /, trailing / = directories only, * does not cross /, *** = dir and everything below, an excluded
# directory is not entered).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="${G01_SCRIPTS_DIR:-$HERE/..}"   # override only to sanity-check the test against scratch scripts
REPO="$HERE/../.."

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }
check() { d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VER=2.46.1
TOOLS="addr2line ar as c++filt elfedit gprof ld ld.bfd nm objcopy objdump ranlib readelf size strings strip"

# perl replay: replay.pl <rules-file> <src> <dst>   (rules: "i pat" / "x pat" per line)
cat > "$TMP/replay.pl" <<'PL'
use strict; use warnings; use File::Path qw(make_path); use File::Copy ();
my ($rf, $src, $dst) = @ARGV;
open(my $fh, '<', $rf) or die; my @rules;
while (<$fh>) { chomp; next unless /^([ix]) (.*)$/; my ($k, $p) = ($1, $2);
  my $dironly = ($p =~ s{/$}{}) ? 1 : 0;
  my $anch = ($p =~ m{^/}) ? 1 : 0; $p =~ s{^/}{};
  my $all = ($p =~ s{/\*\*\*$}{}) ? 1 : 0;
  my $re = ''; my $i = 0;
  while ($i < length $p) { my $c = substr($p, $i, 1);
    if (substr($p, $i, 2) eq '**') { $re .= '.*'; $i += 2; next }
    if ($c eq '*') { $re .= '[^/]*' } elsif ($c eq '?') { $re .= '[^/]' } else { $re .= quotemeta($c) }
    $i++ }
  $anch = 1 if $p =~ m{/};
  my $full = $anch ? "^$re" : "(?:^|/)$re";
  push @rules, { k => $k, dironly => $dironly, re => qr{$full\z}, sub => qr{$full/.*\z}, all => $all };
}
sub verdict { my ($path, $isdir) = @_;
  for my $r (@rules) {
    if ($r->{all} && $path =~ $r->{sub}) { return $r->{k} }
    next if $r->{dironly} && !$isdir;
    return $r->{k} if $path =~ $r->{re};
  } 'i' }
sub walk { my ($rel) = @_;
  my $d = length $rel ? "$src/$rel" : $src;
  opendir(my $dh, $d) or return;
  for my $e (sort grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
    my $p = length $rel ? "$rel/$e" : $e; my $f = "$src/$p";
    my $isdir = (-d $f && !-l $f) ? 1 : 0;
    next if verdict($p, $isdir) eq 'x';
    if ($isdir) { make_path("$dst/$p"); walk($p) }
    elsif (-l $f) { make_path("$dst/" . ($rel // '')); symlink(readlink($f), "$dst/$p") or die }
    else { make_path("$dst/" . ($rel // '')); File::Copy::copy($f, "$dst/$p") }
  } closedir $dh }
make_path($dst); walk('');
PL

# fake sysroot with the full chain
SYS="$TMP/sys"
mkdir -p "$SYS/usr/bin" "$SYS/usr/i486-linux-musl/bin" "$SYS/usr/i486-linux-musl/binutils-bin/$VER" \
    "$SYS/usr/i486-linux-musl/usr/lib" "$SYS/usr/i486-linux-musl/include" "$SYS/usr/i486-linux-musl/lib" "$SYS/usr/include"
for t in $TOOLS; do
    echo "tool $t" > "$SYS/usr/i486-linux-musl/binutils-bin/$VER/$t"
    chmod +x "$SYS/usr/i486-linux-musl/binutils-bin/$VER/$t"
    # exact targets as on the CI ISO: binutils-config makes the first two with absolute targets
    ln -s "/usr/i486-linux-musl/binutils-bin/$VER/$t" "$SYS/usr/i486-linux-musl/bin/$t"
    ln -s "/usr/i486-linux-musl/bin/$t" "$SYS/usr/bin/i486-linux-musl-$t"
    ln -s "i486-linux-musl-$t" "$SYS/usr/bin/$t"
done
: > "$SYS/usr/i486-linux-musl/bin/gcc"
: > "$SYS/usr/i486-linux-musl/bin/pkg-config"
: > "$SYS/usr/i486-linux-musl/usr/lib/libc.a"
: > "$SYS/usr/i486-linux-musl/include/x.h"
: > "$SYS/usr/i486-linux-musl/lib/ld-musl-i386.so.1"
for n in curl-config gcc pkg-config; do : > "$SYS/usr/bin/i486-linux-musl-$n"; done
: > "$SYS/usr/bin/hello"
: > "$SYS/usr/include/stray.h"

# rules <script> -> file: the --include/--exclude arguments of the script's `rsync -a` that exports the sysroot
rules_of() {
    awk '/^rsync -a/ { on = 1; next } on && /--(include|exclude)=/ { print; next } on { exit }' "$1" |
        sed -n "s/^ *--\\(include\\|exclude\\)='\\(.*\\)' *\\\\\$/\\1 \\2/p" |
        sed 's/^include /i /; s/^exclude /x /'
}

run_case() { # $1 label, $2 script
    lbl="$1"; s="$2"; R="$TMP/$lbl.rules"; D="$TMP/$lbl.dest"
    rules_of "$s" > "$R"
    if [ -s "$R" ]; then perl "$TMP/replay.pl" "$R" "$SYS" "$D" 2> "$TMP/$lbl.err"; else mkdir -p "$D"; fi
    check "G01-AC-6: $lbl: the rsync filter arguments were found and replayed (usr/bin/hello exported)" test -e "$D/usr/bin/hello"
    gone() { [ -e "$D/usr/bin/hello" ] && [ ! -e "$1" ] && [ ! -L "$1" ]; }
    for t in $TOOLS; do
        check "G01-AC-6: $lbl: keeps the link usr/i486-linux-musl/bin/$t" test -L "$D/usr/i486-linux-musl/bin/$t"
        check "G01-AC-6: $lbl: keeps the link usr/bin/i486-linux-musl-$t" test -L "$D/usr/bin/i486-linux-musl-$t"
        check "G01-AC-6: $lbl: keeps the link usr/bin/$t" test -L "$D/usr/bin/$t"
        check "G01-AC-6: $lbl: keeps usr/i486-linux-musl/binutils-bin/$VER/$t" test -f "$D/usr/i486-linux-musl/binutils-bin/$VER/$t"
        resolves() { # walk the links inside the dest root
            cur="$D/usr/bin/$t"; n=0   # an absolute target is taken relative to the export root $D, never the host /
            while [ -L "$cur" ] && [ "$n" -lt 10 ]; do
                l="$(readlink "$cur")"
                case "$l" in /*) cur="$D$l" ;; *) cur="$(dirname "$cur")/$l" ;; esac
                n=$((n + 1))
            done
            [ ! -L "$cur" ] && [ -f "$cur" ] && [ "$(cat "$cur")" = "tool $t" ]
        }
        check "G01-AC-6: $lbl: usr/bin/$t resolves inside the export to the binutils-bin binary" resolves
    done
    for n in gcc pkg-config; do
        check "G01-AC-6: $lbl: drops usr/i486-linux-musl/bin/$n (not a binutils tool)" gone "$D/usr/i486-linux-musl/bin/$n"
    done
    check "G01-AC-6: $lbl: drops usr/i486-linux-musl/usr/lib/libc.a" gone "$D/usr/i486-linux-musl/usr/lib/libc.a"
    check "G01-AC-6: $lbl: drops usr/i486-linux-musl/include/x.h" gone "$D/usr/i486-linux-musl/include/x.h"
    check "G01-AC-6: $lbl: drops usr/i486-linux-musl/lib/ld-musl-i386.so.1" gone "$D/usr/i486-linux-musl/lib/ld-musl-i386.so.1"
    for n in curl-config gcc pkg-config; do
        check "G01-AC-6: $lbl: drops usr/bin/i486-linux-musl-$n" gone "$D/usr/bin/i486-linux-musl-$n"
    done
    check "G01-AC-6: $lbl: still drops usr/include/" gone "$D/usr/include/stray.h"
}

run_case build-packages.sh "$SCRIPTS/build-packages.sh"
run_case extract-packages.sh "$SCRIPTS/extract-packages.sh"

# ===== (e) unowned allowlist =====
AL="$REPO/configs/attestation/unowned-allowlist.yaml"
for t in $TOOLS; do
    for p in "usr/bin/i486-linux-musl-$t" "usr/i486-linux-musl/bin/$t"; do
        ok() { python3 -I - "$AL" "$p" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
def walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values(): yield from walk(v)
    elif isinstance(o, list):
        for v in o: yield from walk(v)
sys.exit(0 if any(e.get("path") == sys.argv[2] and e.get("source") == "postinst:sys-devel/binutils" for e in walk(d)) else 1)
PY
        }
        check "G01-AC-6: allowlist has $p (postinst:sys-devel/binutils)" ok
    done
done

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAIL"
[ "$fails" -eq 0 ]
