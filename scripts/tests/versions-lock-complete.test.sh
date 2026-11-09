#!/bin/sh
# B01 version lock and removed-things policy, against configs/portage/ and the build scripts.
#   B01-AC-5   every world atom, normalised to category/package, has a versions.lock line;
#              build-packages.sh exits non-zero on a world atom without one
#   B01-AC-6   update-versions.sh update exits non-zero when an atom does not resolve (stub portageq)
#   B01-AC-8   every package of doctrine.yaml D-no-readding-removed-things is absent from world and masked
#              (sys-devel/gcc in profile/package.mask only: target root, never mirrored to the host)
#   B01-AC-13  world names no overlay ebuild with network-sandbox in RESTRICT, and has net-firewall/nftables
#   R05-AC-5   world has games-roguelike/rl144 and www-client/stele again (owner-approved change of the
#              B01-AC-13 loop, Q2); build.yml's boot-test call runs the stele-acid2 mode;
#              docs/rc1-diff-reasons.tsv no longer lists the two packages
#
# Uses the seams of build-packages-classify.test.sh (SYSROOT, HOST_ETC, CONFIGS_DIR, OUTPUT_DIR).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
BP="$ROOT/scripts/build-packages.sh"
UV="$ROOT/scripts/update-versions.sh"
PORTAGE="$ROOT/configs/portage"
WORLD="$PORTAGE/world"
LOCK="$PORTAGE/versions.lock"
fails=0

fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }
check() { d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# normalise: world atoms on stdin -> category/package (no operator, version, slot, ::repo, comments)
normalise() {
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' \
        -e 's/::.*$//' -e 's/:.*$//' \
        -e '/^[<>=~!]/{s/^[<>=~!]*//;s/-[0-9][^/]*$//;}' \
        -e 's/\*$//'
}
atoms_of() { [ -f "$1" ] && normalise < "$1"; }

# ===== B01-AC-5: lock complete =====
unlocked() {
    [ -f "$WORLD" ] && [ -f "$LOCK" ] || { echo "(world or versions.lock missing)"; return 0; }
    for a in $(normalise < "$WORLD"); do
        grep -q "^$a:" "$LOCK" || echo "$a"
    done
}
if [ -f "$WORLD" ] && [ -f "$LOCK" ]; then
    miss="$(unlocked)"
    if [ -z "$miss" ]; then pass "B01-AC-5: every world atom has a versions.lock line"
    else fail "B01-AC-5: world atoms without a versions.lock line: $(echo "$miss" | tr '\n' ' ')"; fi
    if [ -n "$(normalise < "$WORLD")" ]; then pass "B01-AC-5: world is not empty"; else fail "B01-AC-5: world is empty"; fi
else
    fail "B01-AC-5: configs/portage/world or versions.lock is missing"
fi

# --- build-packages.sh refuses a world atom with no lock line ---
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
for n in i486-linux-musl-emerge quickpkg emaint portageq i486-linux-musl-gcc rsync; do
    cat > "$STUBS/$n" <<'STUB'
#!/bin/sh
n="$(basename "$0")"
{ echo CALL; printf '%s\n' "$@"; } >> "$CALLS/$n.argv"
[ "$n" = portageq ] && [ "$1" = has_version ] && exit 0
[ "$n" = rsync ] && {
    src=""; dst=""
    for a in "$@"; do case "$a" in -*) ;; *) src="$dst"; dst="$a" ;; esac; done
    mkdir -p "$dst"; cp -a "$src." "$dst" 2>/dev/null
}
exit 0
STUB
    chmod +x "$STUBS/$n"
done
bpcase() { # $1 name; world on stdin-ish via $2, lock via $3
    W="$TMP/bp-$1"; CFG="$W/configs"; OUT="$W/output"; SYS="$W/sysroot"; HETC="$W/hostetc"; CALLS="$W/calls"
    mkdir -p "$CFG/portage" "$OUT" "$SYS/etc/portage" "$HETC" "$CALLS" "$SYS/usr/share/monolith-kernel"
    : > "$HETC/group"
    printf '%s\n' "$2" > "$CFG/portage/world"
    printf '%s\n' "$3" > "$CFG/portage/versions.lock"
    echo 'CONFIG_I2C=n' | gzip -c > "$SYS/usr/share/monolith-kernel/resolved-kernel.config.gz"
}
run_bp() {
    env -u MONOLITH_USEPKG CONFIGS_DIR="$CFG" OUTPUT_DIR="$OUT" SYSROOT="$SYS" HOST_ETC="$HETC" CALLS="$CALLS" \
        JOBS=2 LOAD_AVG=2 PATH="$STUBS:$PATH" bash "$BP" > "$W/out.txt" 2>&1
    RC=$?
}
exists() { [ -f "$BP" ]; }
ok_rc() { exists && [ "$RC" -eq 0 ]; }
bad_rc() { exists && [ "$RC" -ne 0 ] && [ "$RC" -ne 127 ]; }
no_emerge() { exists && [ ! -e "$CALLS/i486-linux-musl-emerge.argv" ]; }
ran_emerge() { [ -f "$CALLS/i486-linux-musl-emerge.argv" ]; }

OPS_WORLD='app-misc/hello
<sys-fs/ncdu-2
net-misc/iperf:3
=games-roguelike/nethack-3.6.7-r1'
OPS_LOCK='app-misc/hello:1.0:0
sys-fs/ncdu:1.22:0
net-misc/iperf:3.17:3
games-roguelike/nethack:3.6.7-r1:0'
bpcase full "$OPS_WORLD" "$OPS_LOCK"
run_bp
check "B01-AC-5: all atoms locked (operators, slot) => build-packages.sh exits 0" ok_rc
check "B01-AC-5: all atoms locked => emerge runs" ran_emerge
bpcase missing "$OPS_WORLD" "$(printf '%s\n' "$OPS_LOCK" | grep -v '^sys-fs/ncdu:')"
run_bp
check "B01-AC-5: an operator atom (<sys-fs/ncdu-2) without a lock line => non-zero" bad_rc
check "B01-AC-5: ... before any emerge" no_emerge
check "B01-AC-5: ... naming the atom" sh -c 'grep -q "sys-fs/ncdu" "$1"' _ "$W/out.txt"
bpcase missing2 "$OPS_WORLD" "$(printf '%s\n' "$OPS_LOCK" | grep -v '^app-misc/hello:')"
run_bp
check "B01-AC-5: a plain atom without a lock line => non-zero" bad_rc
check "B01-AC-5: ... before any emerge" no_emerge

# ===== B01-AC-6: update-versions.sh update fails on an unresolvable atom =====
PQ="$TMP/pqstubs"
mkdir -p "$PQ"
cat > "$PQ/portageq" <<'STUB'
#!/bin/sh
# best_visible <root> <atom>; metadata <root> ebuild <cpv> SLOT. app-misc/ghost never resolves.
case "$1" in
    best_visible) case "$3" in app-misc/ghost*) exit 1 ;; *) echo "$3-1.0" ;; esac ;;
    metadata) echo 0 ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$PQ/portageq"
uvcase() {
    W="$TMP/uv-$1"; mkdir -p "$W/portage"
    printf '%s\n' "$2" > "$W/portage/world"
    : > "$W/portage/versions.lock"
}
run_uv() {
    CONFIGS_DIR="$W" PATH="$PQ:$PATH" bash "$UV" update > "$W/out.txt" 2>&1
    RC=$?
}
uvcase ok 'app-misc/hello
app-misc/other'
run_uv
ok_rc_uv() { [ -f "$UV" ] && [ "$RC" -eq 0 ]; }
check "B01-AC-6: update with every atom resolvable exits 0" ok_rc_uv
check "B01-AC-6: ... and writes the lock lines" sh -c 'grep -qx "app-misc/hello:1.0:0" "$1" && grep -qx "app-misc/other:1.0:0" "$1"' _ "$W/portage/versions.lock"
uvcase ghost 'app-misc/hello
app-misc/ghost
app-misc/other'
run_uv
check "B01-AC-6: update with an unresolvable atom exits non-zero" sh -c '[ -f "$1" ] && [ "$2" -ne 0 ] && [ "$2" -ne 127 ]' _ "$UV" "$RC"
check "B01-AC-6: ... naming the atom" sh -c 'grep -q "app-misc/ghost" "$1"' _ "$W/out.txt"

# ===== B01-AC-8: removed things stay removed =====
DOCTRINE="$ROOT/docs/study/doctrine.yaml"
# doctrine name -> category/package (gcc: on target)
MAP='w3m www-client/w3m
nmap net-analyzer/nmap
man-db sys-apps/man-db
gcc sys-devel/gcc
usbutils sys-apps/usbutils
fortune-mod games-misc/fortune-mod
thttpd www-servers/thttpd'
# a mask line is the bare category/package (every version)
masked_in() { # atom file...
    a="$1"; shift
    for f in "$@"; do [ -f "$f" ] && sed -e 's/#.*//' -e 's/[[:space:]]//g' "$f" | grep -qxF "$a" && return 0; done
    return 1
}
hostmasks() { ls "$PORTAGE"/package.mask/* 2>/dev/null; }
profmask="$PORTAGE/profile/package.mask"
printf '%s\n' "$MAP" | while read -r name atom; do
    grep -A2 'id: D-no-readding-removed-things' "$DOCTRINE" | grep -q "$name" || echo "$name"
done > "$TMP/doctrine-missing"
check "B01-AC-8: doctrine.yaml still names all seven packages (map is current)" test ! -s "$TMP/doctrine-missing"
printf '%s\n' "$MAP" | while read -r name atom; do
    if [ ! -f "$WORLD" ]; then fail "B01-AC-8: $atom: world is missing"; continue; fi
    if atoms_of "$WORLD" | grep -qxF "$atom"; then fail "B01-AC-8: $atom is in world"
    else pass "B01-AC-8: $atom is not in world"; fi
    # shellcheck disable=SC2046
    if [ "$atom" = sys-devel/gcc ]; then
        if masked_in "$atom" "$profmask"; then pass "B01-AC-8: $atom masked in profile/package.mask (target only)"
        else fail "B01-AC-8: $atom is not masked in configs/portage/profile/package.mask"; fi
    else
        # shellcheck disable=SC2046
        if masked_in "$atom" $(hostmasks) "$profmask"; then pass "B01-AC-8: $atom is masked"
        else fail "B01-AC-8: $atom is not masked"; fi
    fi
done > "$TMP/ac8.out"
cat "$TMP/ac8.out"
fails=$((fails + $(grep -c '^FAIL' "$TMP/ac8.out")))
# gcc must not be in the host-mirrored dir
if [ -d "$PORTAGE/package.mask" ]; then
    # shellcheck disable=SC2046
    if masked_in sys-devel/gcc $(hostmasks); then fail "B01-AC-8: sys-devel/gcc is in package.mask/ (mirrored to the host)"
    else pass "B01-AC-8: sys-devel/gcc is not in the host-mirrored package.mask/"; fi
else
    fail "B01-AC-8: configs/portage/package.mask/ is missing"
fi
# the script mirrors package.mask to the host and profile/ only to the sysroot
bpcase mask 'app-misc/hello' 'app-misc/hello:1.0:0'
if [ -d "$PORTAGE/package.mask" ] && [ -f "$profmask" ]; then
    mkdir -p "$CFG/portage/package.mask" "$CFG/portage/profile"
    cp "$PORTAGE"/package.mask/* "$CFG/portage/package.mask/"
    cp "$profmask" "$CFG/portage/profile/package.mask"
    run_bp
    check "B01-AC-8: the build copies profile/package.mask (gcc) to the sysroot" \
        sh -c '[ -f "$1" ] && grep -qxF sys-devel/gcc "$1"' _ "$SYS/etc/portage/profile/package.mask"
    check "B01-AC-8: the build does not put sys-devel/gcc into the host /etc/portage" \
        sh -c '[ -d "$1/portage/package.mask" ] && ! grep -rqxF sys-devel/gcc "$1/portage"' _ "$HETC"
else
    fail "B01-AC-8: package.mask/ or profile/package.mask is missing; sysroot/host mask placement cannot be checked"
fi

# ===== B01-AC-13: world contents =====
if [ -f "$WORLD" ]; then
    for a in games-roguelike/rl144 www-client/stele; do
        if atoms_of "$WORLD" | grep -qxF "$a"; then pass "R05-AC-5: $a is in world"
        else fail "R05-AC-5: $a is not in world"; fi
    done
    if atoms_of "$WORLD" | grep -qxF net-firewall/nftables; then pass "B01-AC-13: world has net-firewall/nftables"
    else fail "B01-AC-13: world lacks net-firewall/nftables"; fi
else
    fail "B01-AC-13: configs/portage/world is missing"
fi
# overlay ebuilds with network-sandbox in RESTRICT: category/package list
sandboxed() { # overlay dir -> atoms
    for e in "$1"/*/*/*.ebuild; do
        [ -f "$e" ] || continue
        if awk '/^[ \t]*RESTRICT=/{r=1; buf=""} r{buf=buf $0 "\n"; n=gsub(/"/,"\"",buf); if(n>=2){if(buf~/network-sandbox/)f=1; r=0}} END{exit !f}' "$e"; then
            d="$(dirname "$e")"; echo "$(basename "$(dirname "$d")")/$(basename "$d")"
        fi
    done | sort -u
}
named_sandboxed() { # world overlay -> atoms of sandboxed overlay packages named in world
    atoms_of "$1" | sort -u | comm -12 - "$TMP/sb.list"
}
# control: the scan finds a network-sandbox ebuild in a fixture overlay (so the real scan is not vacuous)
mkdir -p "$TMP/ov/x-misc/needsnet" "$TMP/ov/x-misc/plain"
printf 'EAPI=8\nRESTRICT="mirror network-sandbox"\n' > "$TMP/ov/x-misc/needsnet/needsnet-1.ebuild"
printf 'EAPI=8\nRESTRICT="\n\tmirror\n\tnetwork-sandbox\n"\n' > "$TMP/ov/x-misc/needsnet/needsnet-2.ebuild"
printf 'EAPI=8\nRESTRICT="mirror"\n' > "$TMP/ov/x-misc/plain/plain-1.ebuild"
sandboxed "$TMP/ov" > "$TMP/sb.list"
check "B01-AC-13: (scan control) finds RESTRICT with network-sandbox, one-line and multi-line" \
    sh -c 'grep -qxF x-misc/needsnet "$1" && ! grep -qxF x-misc/plain "$1"' _ "$TMP/sb.list"
if [ -f "$WORLD" ]; then
    sandboxed "$ROOT/configs/overlay" > "$TMP/sb.list"
    named="$(named_sandboxed "$WORLD")"
    if [ -z "$named" ]; then pass "B01-AC-13: no network-sandbox overlay ebuild is named in world"
    else fail "B01-AC-13: world names overlay packages with network-sandbox in RESTRICT: $named"; fi
else
    fail "B01-AC-13: world is missing, so the overlay check cannot run"
fi

# ===== R05-AC-5: stele-acid2 in build.yml's boot-test modes; rc1-diff-reasons rows removed =====
# (each world atom having a versions.lock line is the generic B01-AC-5 check above)
BUILDYML="$ROOT/.github/workflows/build.yml"
if [ -f "$BUILDYML" ]; then
    modes="$(python3 -I - "$BUILDYML" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d["jobs"]["boot-test"]
if j.get("uses") != "./.github/workflows/boot-test.yml":
    sys.exit(1)
print(j["with"]["modes"])
PY
)"
    case " $modes " in
        *" stele-acid2 "*) pass "R05-AC-5: build.yml's boot-test call includes the stele-acid2 mode" ;;
        *) fail "R05-AC-5: build.yml's boot-test call lacks stele-acid2 (modes: ${modes:-unreadable})" ;;
    esac
else
    fail "R05-AC-5: .github/workflows/build.yml is missing"
fi
TSV="$ROOT/docs/rc1-diff-reasons.tsv"
if [ -f "$TSV" ]; then
    for a in games-roguelike/rl144 www-client/stele; do
        if awk -F'\t' -v a="$a" '$1==a{f=1} END{exit !f}' "$TSV"; then
            fail "R05-AC-5: docs/rc1-diff-reasons.tsv still lists $a"
        else pass "R05-AC-5: docs/rc1-diff-reasons.tsv does not list $a"; fi
    done
else
    fail "R05-AC-5: docs/rc1-diff-reasons.tsv is missing"
fi

if [ "$fails" -gt 0 ]; then
    echo "$fails check(s) FAILED"
    exit 1
fi
echo "ALL PASS"
