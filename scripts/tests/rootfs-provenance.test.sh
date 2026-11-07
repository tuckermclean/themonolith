#!/bin/sh
# B01-AC-14 (change 12): check-unowned.py --provenance on a fixture rootfs with a VDB, output/sysroot, an
# allowlist and a source-audit.tsv fails in each listed case and passes on a clean one; without --provenance
# the same fixtures give the ported results.
# Interface under test (chosen for slice 3, simplest that fits the spec). Ported flags unchanged
# (--syft-json --sysroot[=the rootfs] --output --allowlist), plus:
#   --provenance                       enable the checks
#   --package-tree DIR                 output/sysroot
#   --source-audit TSV                 release mode; TSV is source-audit.sh's report (header, then
#                                      path<TAB>owner<TAB>built-this-run|bootstrap); an owning cpv is
#                                      built-this-run iff some row names it with that value
#   --bootstrap-exceptions FILE        lines `<absolute path> <host cpv>`; those files are class bootstrap
#   --provenance-report TSV            rootfs-provenance.tsv: path (leading /), class, owner-or-source,
#                                      and built-this-run with --source-audit
# Allowlist (provenance form): entries are mappings `- path: <glob>` + `source: build-rootfs.sh|
# postinst:<cat/pn>|portage`; a top-level `modified:` list has the same entry form. Plain string entries
# stay valid without --provenance (S01's file today) and fail with it (no source).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUBJ="$ROOT/scripts/check-unowned.py"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# mk NAME [flags] -> $TMP/NAME/{rootfs,pkgtree,syft.json,allowlist.yaml,exceptions.txt,audit.tsv}
#  md5diff     /etc/foo.conf differs from CONTENTS and is not under modified:
#  symdiff     /usr/bin/foolink points elsewhere
#  nosource    the /etc/motd allowlist entry has no source
#  dupgen      /etc/motd (a build-rootfs.sh entry) also exists in pkgtree
#  nopostinst  postinst package sys-libs/musl not in the rootfs VDB
#  nohook      /etc/ld.so.cache (postinst) is absent from pkgtree
#  notbuilt    audit.tsv has no built-this-run row for app-misc/foo-1 (owner of on-disk files)
#  hooknotbuilt audit.tsv has no built-this-run row for sys-libs/musl (postinst package; owns nothing on disk)
#  stale       allowlist entry matching nothing   stalemod  modified: entry matching nothing
#  stray       an unowned, unlisted file          noboot    (go flag) omit --bootstrap-exceptions
mk() {
    n=$1; shift; d="$TMP/$n"; mkdir -p "$d"
    python3 - "$d" " $* " <<'PY'
import hashlib, json, os, sys
d, flags = sys.argv[1], sys.argv[2]
R, P = d + "/rootfs", d + "/pkgtree"
def w(base, rel, data=b""):
    p = os.path.join(base, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "wb").write(data); return p
md5 = lambda b: hashlib.md5(b).hexdigest()
foo, conf_pkg = b"foo-bytes\n", b"conf-from-package\n"
w(R, "usr/bin/foo", foo)
os.symlink("other" if " symdiff " in flags else "foo", R + "/usr/bin/foolink")
w(R, "etc/foo.conf", b"conf-rewritten-by-build-rootfs\n" if " md5diff " not in flags else b"conf-edited\n")
if " md5diff " in flags: conf_rewritten = None
w(R, "etc/motd", b"motd\n"); os.makedirs(R + "/home", exist_ok=True)
w(R, "etc/ld.so.cache", b"cache\n"); w(R, "lib/ld-musl-i386.so.1", b"libc\n")
if " stray " in flags: w(R, "usr/bin/stray", b"x")
vdb = R + "/var/db/pkg"
w(vdb, "app-misc/foo-1/CONTENTS",
  ("dir /usr\ndir /usr/bin\nobj /usr/bin/foo %s 1\nsym /usr/bin/foolink -> foo 1\nobj /etc/foo.conf %s 1\n"
   % (md5(foo), md5(conf_pkg))).encode())
if " nopostinst " not in flags:
    # owns a file that the assembly removed, so no on-disk file ties it to audit.tsv
    w(vdb, "sys-libs/musl-1.2.6/CONTENTS", ("obj /usr/lib/libc.a %s 1\n" % md5(b"a")).encode())
w(P, "usr/bin/foo", foo)
if " nohook " not in flags: w(P, "etc/ld.so.cache", b"cache\n")
if " dupgen " in flags: w(P, "etc/motd", b"package motd\n")
os.makedirs(P + "/home", exist_ok=True)
# audit.tsv
rows = []
if " notbuilt " not in flags:
    rows += [("/usr/bin/foo", "app-misc/foo-1", "built-this-run"), ("/usr/bin/foolink", "app-misc/foo-1", "built-this-run"),
             ("/etc/foo.conf", "app-misc/foo-1", "built-this-run")]
if " hooknotbuilt " not in flags: rows.append(("/usr/lib/libc.a", "sys-libs/musl-1.2.6", "built-this-run"))
rows.append(("/lib/ld-musl-i386.so.1", "cross-i486-linux-musl/musl-1.2.6", "bootstrap"))
open(d + "/audit.tsv", "w").write("path\towner\tprovenance\n" + "".join("\t".join(r) + "\n" for r in rows))
open(d + "/exceptions.txt", "w").write("# bootstrap\n/lib/ld-musl-i386.so.1 cross-i486-linux-musl/musl-1.2.6\n")
# allowlist
ent = lambda p, s: "  - path: %s\n%s" % (p, "" if s is None else "    source: \"%s\"\n" % s)
al = "allowlist:\n"
al += ent("etc/motd", None if " nosource " in flags else "build-rootfs.sh")
al += ent("home", "build-rootfs.sh") + ent("etc/ld.so.cache", "postinst:sys-libs/musl")
al += ent("var/db/pkg/**", "portage")
if " stale " in flags: al += ent("etc/nothere", "build-rootfs.sh")
al += "modified:\n"
if " md5diff " not in flags: al += ent("etc/foo.conf", "build-rootfs.sh")
else: al += "  []\n" if False else ""
if " stalemod " in flags: al += ent("usr/bin/ghost", "build-rootfs.sh")
if al.endswith("modified:\n"): al += "  []\n"
open(d + "/allowlist.yaml", "w").write(al)
# syft files[] = everything on disk in the rootfs
files = []
for dp, dn, fn in os.walk(R):
    for x in fn + [x for x in dn if os.path.islink(os.path.join(dp, x)) or os.path.join(dp, x) == R + "/home"]:
        files.append({"location": {"path": os.path.join(dp, x)}})
json.dump({"schema": {"version": "16.0.0"}, "artifacts": [], "files": files}, open(d + "/syft.json", "w"))
PY
}
# go NAME [extra args]: runs the subject; RC, $TMP/NAME/out.txt, report $TMP/NAME/prov.tsv
go() {
    n=$1; shift; d="$TMP/$n"
    python3 "$SUBJ" --syft-json "$d/syft.json" --sysroot "$d/rootfs" --output "$d/report.json" \
        --allowlist "$d/allowlist.yaml" "$@" > "$d/out.txt" 2>&1
    RC=$?
}
prov() { # NAME [release|noboot]
    n=$1; extra=""
    case "${2:-}" in release) extra="--source-audit $TMP/$n/audit.tsv" ;; esac
    if [ "${2:-}" = noboot ]; then bx=""; else bx="--bootstrap-exceptions $TMP/$n/exceptions.txt"; fi
    go "$n" --provenance --package-tree "$TMP/$n/pkgtree" $bx --provenance-report "$TMP/$n/prov.tsv" $extra
}
# neg LABEL DEFECT MODE TOKEN: the clean fixture (same mode) exits 0; the defect exits non-zero and names TOKEN
neg() {
    prov clean "$3"; rc_ctl=$RC
    prov "$2" "$3"
    if [ "$rc_ctl" -eq 0 ] && [ "$RC" -ne 0 ] && grep -q -- "$4" "$TMP/$2/out.txt"; then
        ok "B01-AC-14 $1: exits non-zero and names $4"
    else fail "B01-AC-14 $1: exits non-zero and names $4 (defect rc=$RC, control rc=$rc_ctl)"; fi
}

mk clean
prov clean
[ "$RC" -eq 0 ] && ok "B01-AC-14 clean fixture passes (--provenance)" || fail "B01-AC-14 clean fixture passes (--provenance) (rc=$RC)"
prov clean release
[ "$RC" -eq 0 ] && ok "B01-AC-14 clean fixture passes (--provenance --source-audit)" \
    || fail "B01-AC-14 clean fixture passes (--provenance --source-audit) (rc=$RC)"
T="$TMP/clean/prov.tsv"
row() { awk -F'\t' -v p="$1" -v c="$2" -v o="$3" -v b="$4" '$1==p && $2==c && $3==o && (b=="" || $4==b) {f=1} END{exit !f}' "$T" 2>/dev/null; }
row /usr/bin/foo package app-misc/foo-1 built-this-run && row /etc/motd generated build-rootfs.sh built-this-run \
    && row /etc/foo.conf modified build-rootfs.sh "" && row /lib/ld-musl-i386.so.1 bootstrap cross-i486-linux-musl/musl-1.2.6 "" \
    && ok "B01-AC-14 rootfs-provenance.tsv rows: path, class (package|generated|modified|bootstrap), owner or source" \
    || fail "B01-AC-14 rootfs-provenance.tsv rows: path, class (package|generated|modified|bootstrap), owner or source"

mk md5diff md5diff;    neg "owned file with another MD5, not under modified:" md5diff "" /etc/foo.conf
mk symdiff symdiff;    neg "owned symlink with another target" symdiff "" /usr/bin/foolink
mk nosource nosource;  neg "allowlist entry without source" nosource "" etc/motd
mk dupgen dupgen;      neg "build-rootfs.sh entry whose file also exists in output/sysroot" dupgen "" etc/motd
mk nopostinst nopostinst; neg "postinst: entry whose package is not installed" nopostinst "" sys-libs/musl
mk nohook nohook;      neg "postinst: entry whose path is missing from output/sysroot" nohook "" etc/ld.so.cache
mk notbuilt notbuilt;  neg "(--source-audit) owned file whose cpv is not built-this-run" notbuilt release app-misc/foo-1
mk hooknotbuilt hooknotbuilt; neg "(--source-audit) postinst: entry whose package is not built-this-run" hooknotbuilt release sys-libs/musl
mk stale stale;        neg "stale allowlist entry" stale "" etc/nothere
mk stalemod stalemod;  neg "stale modified: entry" stalemod "" usr/bin/ghost
mk stray stray;        neg "an unowned, unlisted file still fails (ported gate)" stray "" /usr/bin/stray
mk noboot; prov clean ""; rc_ctl=$RC; prov noboot noboot  # control keeps the bootstrap exceptions, the defect drops them
if [ "$rc_ctl" -eq 0 ] && [ "$RC" -ne 0 ] && grep -q -- /lib/ld-musl-i386.so.1 "$TMP/noboot/out.txt"; then
    ok "B01-AC-14 a toolchain file missing from the bootstrap exceptions is unowned: exits non-zero and names /lib/ld-musl-i386.so.1"
else fail "B01-AC-14 a toolchain file missing from the bootstrap exceptions is unowned: exits non-zero and names /lib/ld-musl-i386.so.1 (defect rc=$RC, control rc=$rc_ctl)"; fi

# Not under --source-audit, an unbuilt cpv is not checked (MS1 builds run without it)
prov notbuilt
[ "$RC" -eq 0 ] && ok "B01-AC-14 without --source-audit the built-this-run check is off" \
    || fail "B01-AC-14 without --source-audit the built-this-run check is off (rc=$RC)"

# Without --provenance: the ported results on the same fixtures. Ported mode knows no bootstrap exceptions,
# so the toolchain file is its one unowned file; provenance-only defects change nothing, and the mapping-form
# allowlist entries are read as patterns. The result is judged from the report's unowned list, so a crash
# (no report) cannot pass.
unowned() { python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["unowned_files"]))' "$TMP/$1/report.json" 2>/dev/null; }
for n in clean md5diff symdiff nosource dupgen nopostinst nohook notbuilt hooknotbuilt stale stalemod; do
    rm -f "$TMP/$n/report.json"; go "$n"; u=$(unowned "$n")
    [ "$RC" -eq 1 ] && [ "$u" = "/lib/ld-musl-i386.so.1" ] \
        && ok "B01-AC-14 without --provenance, fixture '$n' gives the ported result (only the toolchain file unowned)" \
        || fail "B01-AC-14 without --provenance, fixture '$n' gives the ported result (rc=$RC unowned='$u')"
done
rm -f "$TMP/stray/report.json"; go stray; u=$(unowned stray)
[ "$RC" -eq 1 ] && [ "$u" = "/lib/ld-musl-i386.so.1 /usr/bin/stray" ] \
    && ok "B01-AC-14 without --provenance, an unowned file is reported as ported" \
    || fail "B01-AC-14 without --provenance, an unowned file is reported as ported (rc=$RC unowned='$u')"

# The shipped allowlist: every entry has a source (change 12)
python3 - "$ROOT/configs/attestation/unowned-allowlist.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
bad = [e for e in d.get("allowlist", []) + d.get("modified", [])
       if not (isinstance(e, dict) and e.get("path") and
               (e.get("source") in ("build-rootfs.sh", "portage") or str(e.get("source", "")).startswith("postinst:")))]
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] && ok "B01-AC-14 every entry of configs/attestation/unowned-allowlist.yaml has a valid source" \
    || fail "B01-AC-14 every entry of configs/attestation/unowned-allowlist.yaml has a valid source"

echo
[ "$fails" -eq 0 ] && { echo "rootfs-provenance: all passed"; exit 0; }
echo "rootfs-provenance: $fails failed"; exit 1
