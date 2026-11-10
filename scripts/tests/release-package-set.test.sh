#!/bin/sh
# P01 slice 1: scripts/release-package-set.sh, the release's whole-package-set check (node spec change 6).
#   P01-AC-11  fails when one of the 99 b9f533b world atoms is missing from `world`, from the rootfs VDB or from the
#              `built-this-run` rows of source-audit.tsv; passes with all 99, rl144 and stele among them.
#              (The v0.2.0-rc1 run-log half is run, not encoded.)
#
# Interface under test (the implementer writes the script from this header alone):
#   sh scripts/release-package-set.sh --world <world> --rootfs <dir> --audit <source-audit.tsv> [--atoms <list>]
#     --world   a Portage world file (comments with #, blank lines, atoms that may carry an operator, a version or a
#               slot: "<sys-fs/ncdu-2", "=games-roguelike/nethack-3.6.7-r1", "net-misc/iperf:3"); every line is
#               normalised to category/package (operators, version, slot stripped) before comparing
#     --rootfs  the extracted ISO rootfs; installed packages are the directories <dir>/var/db/pkg/<cat>/<pf>/ where
#               <pf> is <package>-<version>[-rN] (an atom is installed when some <pf> is "<package>-<digit>...")
#     --audit   source-audit.tsv: header "path<TAB>owner<TAB>provenance"; owner is a cpv such as
#               sys-apps/busybox-1.36.1-r3; an atom counts only through rows whose provenance is built-this-run
#     --atoms   the list compared against: one normalised category/package per line. Default (and the one the
#               release uses): configs/release/world-b9f533b.txt in the repository, the 99 atoms of b9f533b's
#               configs/portage/world normalised; a removal from it needs a SPEC change.
#   exit 0 when all three hold for every atom; exit 1 otherwise, printing one line per failure that contains the
#   atom and which source lacks it ("world", "vdb" or "audit"); exit 2 on a usage error or an unreadable input.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
S="$ROOT/scripts/release-package-set.sh"
FX="$HERE/fixtures/P01"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# --- fixture world: the b9f533b world verbatim (with its operators, version and slot), a VDB, an audit ---
mk_world() { { echo "# fixture world"; echo; cat "$FX/world-b9f533b.raw"; } > "$TMP/world"; }
mk_vdb() {
	rm -rf "$TMP/rootfs"; mkdir -p "$TMP/rootfs/var/db/pkg"
	while IFS= read -r a; do
		[ -n "$a" ] || continue
		v=1.0; [ "$a" = games-roguelike/nethack ] && v=3.6.7-r1
		mkdir -p "$TMP/rootfs/var/db/pkg/${a%/*}/${a#*/}-$v"
	done < "$FX/world-b9f533b.norm"
}
mk_audit() {
	{ printf 'path\towner\tprovenance\n'
	  while IFS= read -r a; do
		[ -n "$a" ] || continue
		v=1.0; [ "$a" = games-roguelike/nethack ] && v=3.6.7-r1
		printf '/usr/bin/%s\t%s-%s\tbuilt-this-run\n' "${a#*/}" "$a" "$v"
	  done < "$FX/world-b9f533b.norm"
	  printf '/etc/motd\tapp-misc/monolith-base-1.0\tbuilt-this-run\n'
	} > "$TMP/audit.tsv"
}
run() { out=$(sh "$S" --world "$TMP/world" --rootfs "$TMP/rootfs" --audit "$TMP/audit.tsv" 2>&1); rc=$?; }

# P01-AC-11: the list the check compares against is the 99 normalised atoms, in the repository
if [ -f "$ROOT/configs/release/world-b9f533b.txt" ] && cmp -s "$ROOT/configs/release/world-b9f533b.txt" "$FX/world-b9f533b.norm"; then
	ok "P01-AC-11: configs/release/world-b9f533b.txt is the 99 normalised b9f533b atoms"
else
	fail "P01-AC-11: configs/release/world-b9f533b.txt is missing or is not the 99 normalised b9f533b atoms"
fi
[ "$(wc -l < "$FX/world-b9f533b.norm" | tr -d ' ')" = 99 ] && grep -qx games-roguelike/rl144 "$FX/world-b9f533b.norm" \
	&& grep -qx www-client/stele "$FX/world-b9f533b.norm" || fail "P01-AC-11: fixture list is not the 99 with rl144 and stele"

mk_world; mk_vdb; mk_audit
run
if [ "$rc" = 0 ]; then ok "P01-AC-11: all 99 atoms in world, VDB and built-this-run audit rows exits 0"
else fail "P01-AC-11: full set must exit 0 (rc=$rc): $(echo "$out" | head -3)"; fi

# one atom removed from each source in turn (including the two newest, and the three oddly written atoms)
for atom in games-roguelike/rl144 www-client/stele sys-fs/ncdu net-misc/iperf games-roguelike/nethack sys-apps/busybox; do
	pkg=${atom#*/}
	# world
	mk_world; mk_vdb; mk_audit
	grep -v "$atom\|$pkg" "$FX/world-b9f533b.raw" > "$TMP/w2"; { echo "# c"; cat "$TMP/w2"; } > "$TMP/world"
	run
	if [ "$rc" = 1 ] && echo "$out" | grep -q "$atom"; then ok "P01-AC-11: $atom missing from world exits 1 and is named"
	else fail "P01-AC-11: $atom missing from world must exit 1 naming it (rc=$rc)"; fi
	# vdb
	mk_world; mk_vdb; mk_audit
	rm -rf "$TMP/rootfs/var/db/pkg/${atom%/*}/$pkg"-[0-9]*
	run
	if [ "$rc" = 1 ] && echo "$out" | grep -q "$atom"; then ok "P01-AC-11: $atom missing from the VDB exits 1 and is named"
	else fail "P01-AC-11: $atom missing from the VDB must exit 1 naming it (rc=$rc)"; fi
	# audit
	mk_world; mk_vdb; mk_audit
	awk -F'\t' -v p="/$pkg-" 'index($2, p) == 0' "$TMP/audit.tsv" > "$TMP/a2"; mv "$TMP/a2" "$TMP/audit.tsv"
	run
	if [ "$rc" = 1 ] && echo "$out" | grep -q "$atom"; then ok "P01-AC-11: $atom missing from source-audit.tsv exits 1 and is named"
	else fail "P01-AC-11: $atom missing from source-audit.tsv must exit 1 naming it (rc=$rc)"; fi
done

# an atom present in the audit only as bootstrap/portage does not count as built-this-run
mk_world; mk_vdb; mk_audit
sed 's|^\(/usr/bin/stele\t.*\)built-this-run$|\1bootstrap|' "$TMP/audit.tsv" > "$TMP/a2"; mv "$TMP/a2" "$TMP/audit.tsv"
grep -q 'bootstrap' "$TMP/audit.tsv" || fail "P01-AC-11: harness: stele row not rewritten"
run
if [ "$rc" = 1 ] && echo "$out" | grep -q 'www-client/stele'; then ok "P01-AC-11: an atom only bootstrap in the audit exits 1"
else fail "P01-AC-11: an atom only bootstrap in the audit must exit 1 (rc=$rc)"; fi

# extra packages beyond the 99 are fine
mk_world; mk_vdb; mk_audit; echo "app-misc/extra" >> "$TMP/world"; mkdir -p "$TMP/rootfs/var/db/pkg/app-misc/extra-2"
run
[ "$rc" = 0 ] && ok "P01-AC-11: packages beyond the 99 do not fail" || fail "P01-AC-11: extra package must not fail (rc=$rc)"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
