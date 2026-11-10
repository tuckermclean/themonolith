#!/bin/sh
# R05-Q3: the bundled crates' licences are in each ebuild's LICENSE, and S01's
# licence gate accepts it.
#   R05-Q3 (a)  every crate of the ebuild's CRATES has its licence covered by
#               LICENSE, in Gentoo names, a crate's choice of licence as an
#               || ( ... ) group (what pycargoebuild writes)
#   R05-Q3 (b)  scripts/check-licenses.py with configs/attestation/license-policy.yaml
#               accepts an SBOM component carrying the ebuild's full LICENSE
#               (control: the same LICENSE plus a non-free licence is rejected)
# scripts/fixtures/R05/crate-licenses.tsv: name, version, the crate's SPDX
# `license` field, one tab-separated line per crates.io package of the three
# R05 Cargo.lock fixtures.
cd "$(dirname "$0")/../.." || exit 2
ROOT=$(pwd)
FIX=$ROOT/scripts/fixtures/R05
OVERLAY=$ROOT/configs/overlay
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
fails=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
check() { if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi; }

join_ebuild() {
	awk '
	{ line = $0
	  if (!inq) sub(/^[ \t]*#.*/, "", line)
	  else sub(/(^|[ \t])#.*/, "", line)
	  if (cont != "") { line = cont " " line; cont = "" }
	  if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); cont = line; next }
	  if (inq) { buf = buf " " line; n = gsub(/"/, "\"", line); if (n % 2 == 1) { print buf; inq = 0 }; next }
	  n = gsub(/"/, "\"", line)
	  if (n % 2 == 1) { buf = line; inq = 1; next }
	  print line }
	END { if (inq) print buf; if (cont != "") print cont }' "$1"
}
ebuild_crates() { # name-version of each CRATES entry (name@version or name-version)
	join_ebuild "$1" | awk '
	/^[[:space:]]*CRATES\+?="/ { s = $0; sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s); print s }' |
		tr -s ' \t' '\n' | sed '/^$/d' | sed 's/@/-/' | sort -u
}
# ebuild_license EBUILD: LICENSE= followed by every LICENSE+= value, space-joined.
ebuild_license() {
	join_ebuild "$1" | awk '
	/^[[:space:]]*LICENSE=/ { s = $0; sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s); out = s; next }
	/^[[:space:]]*LICENSE\+=/ { s = $0; sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s); out = out " " s }
	END { print out }' | tr -s ' \t' ' ' | sed 's/^ //; s/ $//'
}

cat >"$TMP/cover.py" <<'PY'
import re, sys

# SPDX id -> Gentoo licence name (Gentoo's license-mapping.conf / pycargoebuild)
MAP = {
    "Apache-2.0": "Apache-2.0",
    "MIT": "MIT",
    "BSD-3-Clause": "BSD",
    "BSD-2-Clause": "BSD-2",
    "Zlib": "ZLIB",
    "MPL-2.0": "MPL-2.0",
    "Unlicense": "Unlicense",
    "Unicode-3.0": "Unicode-3.0",
    "0BSD": "0BSD",
    "ISC": "ISC",
    "LGPL-2.1-or-later": "LGPL-2.1+",
    "Apache-2.0 WITH LLVM-exception": "Apache-2.0-with-LLVM-exceptions",
}

def spdx_terms(expr):
    """SPDX expression -> list of AND-terms, each a list of OR-alternatives (Gentoo names)."""
    expr = expr.replace("/", " OR ")
    toks = re.findall(r"[()]|[^\s()]+", expr)
    pos = 0
    def atom():
        nonlocal pos
        t = toks[pos]
        if t == "(":
            pos += 1
            r = orexpr()
            assert toks[pos] == ")"
            pos += 1
            return r
        pos += 1
        if pos + 1 < len(toks) and toks[pos] == "WITH":
            t = t + " WITH " + toks[pos + 1]
            pos += 2
        return [[t]]            # AND of one OR of one
    # a node is a list of AND-terms, each a list of alternatives
    def andexpr():
        nonlocal pos
        terms = atom()
        while pos < len(toks) and toks[pos] == "AND":
            pos += 1
            terms = terms + atom()
        return terms
    def orexpr():
        nonlocal pos
        alts = andexpr()
        while pos < len(toks) and toks[pos] == "OR":
            pos += 1
            more = andexpr()
            if len(alts) != 1 or len(more) != 1:
                raise ValueError("OR of AND-terms: " + expr)
            alts = [alts[0] + more[0]]
        return alts
    r = orexpr()
    assert pos == len(toks), expr
    return [[MAP[a] for a in term] for term in r]

def gentoo(lic):
    """LICENSE string -> (plain top-level names, list of || groups' name sets)."""
    toks = re.findall(r"\|\||[()]|[^\s()]+", lic)
    plain, groups = set(), []
    stack = []   # entries: (is_or_group, names)
    i = 0
    while i < len(toks):
        t = toks[i]
        if t == "||":
            i += 2           # skip '('
            stack.append((True, set()))
        elif t == "(":
            stack.append((False, set()))
            i += 1
        elif t == ")":
            isor, names = stack.pop()
            if isor:
                groups.append(names)
            if stack:
                stack[-1][1].update(names)
            else:
                plain.update(names)
            i += 1
        else:
            if stack:
                stack[-1][1].add(t)
            else:
                plain.add(t)
            i += 1
    return plain, groups

fixture, crates, licfile = sys.argv[1:4]
if licfile == "--expected":
    # the LICENSE the fixture implies for these crates: every OR-choice a group
    fx = {}
    for line in open(fixture):
        n, v, l = line.rstrip("\n").split("\t")
        fx[n + "-" + v] = l
    parts = set()
    for line in open(crates):
        k = line.rstrip("\n")
        for term in spdx_terms(fx[k]):
            parts.add(term[0] if len(term) == 1 else "|| ( " + " ".join(sorted(term)) + " )")
    print(" ".join(sorted(parts)))
    sys.exit(0)
lic = open(licfile).read().strip()
plain, groups = gentoo(lic)
fx = {}
for line in open(fixture):
    n, v, l = line.rstrip("\n").split("\t")
    fx[n + "-" + v] = l
bad = []
for line in open(crates):
    k = line.rstrip("\n")
    if k not in fx:
        bad.append(f"{k}: no licence in fixture")
        continue
    for term in spdx_terms(fx[k]):
        if len(term) == 1:
            ok = term[0] in plain or any(term[0] in g for g in groups)
        else:
            ok = any(set(term) <= g for g in groups)
        if not ok:
            want = term[0] if len(term) == 1 else "|| ( " + " ".join(term) + " )"
            bad.append(f"{k} ({fx[k]}): LICENSE lacks {want}")
for b in sorted(set(bad)):
    print(b)
sys.exit(1 if bad else 0)
PY

covered() { # covered CRATES_FILE LICENSE_FILE -> prints uncovered crates, status 0 if none
	python3 -I "$TMP/cover.py" "$FIX/crate-licenses.tsv" "$1" "$2"
}

# ---- controls: the coverage check detects a gap and accepts a complete LICENSE ----
printf 'aaa-1.0.0\nbbb-2.0.0\nccc-0.3.0\nddd-1.1.1\n' >"$TMP/c.crates"
printf 'aaa\t1.0.0\tMIT OR Apache-2.0\nbbb\t2.0.0\tMIT AND Zlib\nccc\t0.3.0\tMIT/Apache-2.0\nddd\t1.1.1\t(MIT OR Apache-2.0) AND Unicode-3.0\n' >"$TMP/c.tsv"
cp "$FIX/crate-licenses.tsv" "$TMP/real.tsv"
FIXSAVE=$FIX
FIX=$TMP
cp "$TMP/c.tsv" "$TMP/crate-licenses.tsv"
echo "|| ( MIT Apache-2.0 ) ZLIB Unicode-3.0 MIT" >"$TMP/c.full"
echo "|| ( MIT Apache-2.0 ) ZLIB MIT" >"$TMP/c.nouni"
echo "MIT Apache-2.0 ZLIB Unicode-3.0" >"$TMP/c.flat"
covered "$TMP/c.crates" "$TMP/c.full" >/dev/null 2>&1
check "R05-Q3 control: a complete LICENSE is accepted" $?
out=$(covered "$TMP/c.crates" "$TMP/c.nouni" 2>&1)
[ $? -ne 0 ] && echo "$out" | grep -q 'ddd-1.1.1'
check "R05-Q3 control: a LICENSE missing a crate's licence is detected" $?
covered "$TMP/c.crates" "$TMP/c.flat" >/dev/null 2>&1
[ $? -ne 0 ]
check "R05-Q3 control: alternatives outside an || ( ) group are not a choice group" $?
FIX=$FIXSAVE

# ---- the two ebuilds (highest -rN, as no-network-ebuilds.test.sh finds it) ----
GATE_OK=0
python3 -I -c 'import yaml' >/dev/null 2>&1 && GATE_OK=1

check_pkg() { # check_pkg category/name
	cp=$1
	cat=${cp%/*} pn=${cp#*/}
	dir=$OVERLAY/$cat/$pn
	best=$(find "$dir" -maxdepth 1 -name "$pn-*.ebuild" 2>/dev/null | sed "s|.*/$pn-||; s|\.ebuild\$||" | sort -V | tail -1)
	if [ -z "$best" ]; then
		fail "R05-Q3 $cp: no ebuild under configs/overlay/$cp"
		return
	fi
	eb=$dir/$pn-$best.ebuild
	ebuild_crates "$eb" >"$TMP/$pn.crates"
	ebuild_license "$eb" >"$TMP/$pn.license"
	[ -s "$TMP/$pn.crates" ] && [ -s "$TMP/$pn.license" ]
	check "R05-Q3 $cp: $pn-$best has CRATES ($(wc -l <"$TMP/$pn.crates" | tr -d ' ')) and a LICENSE" $?
	echo "  LICENSE=\"$(cat "$TMP/$pn.license")\""

	# (a) LICENSE covers every crate's licence
	m=$(covered "$TMP/$pn.crates" "$TMP/$pn.license" 2>&1)
	rc=$?
	[ "$rc" -eq 0 ]
	check "R05-Q3 $cp: LICENSE covers every CRATES crate's licence ${m:+(first gaps: $(echo "$m" | head -4 | tr '\n' ';'))}" $?

	# (b) the licence gate accepts the LICENSE; it only means something when the
	# LICENSE carries the crates' licences, so (a) must hold for it
	lic=$(cat "$TMP/$pn.license")
	GATE_MSG="LICENSE does not cover the crates"
	[ "$rc" -eq 0 ] && gate "$pn" "$lic" "$TMP/$pn.real"
	check "R05-Q3 $cp: licence gate accepts the LICENSE, which covers the crates' licences ($GATE_MSG)" $?
	# the gate with the policy must accept the LICENSE the fixture implies
	python3 -I "$TMP/cover.py" "$FIX/crate-licenses.tsv" "$TMP/$pn.crates" --expected >"$TMP/$pn.expected"
	[ -s "$TMP/$pn.expected" ]
	check "R05-Q3 $cp: fixture has a licence for every CRATES crate" $?
	gate "$pn" "$(cat "$TMP/$pn.expected")" "$TMP/$pn.exp"
	check "R05-Q3 $cp: licence gate accepts the full LICENSE the crate licences imply ($GATE_MSG)" $?
	gate "$pn" "$lic Proprietary-Nonfree-EULA" "$TMP/$pn.bad"
	[ $? -ne 0 ]
	check "R05-Q3 $cp control: the gate rejects that LICENSE plus a non-free licence" $?
}

# gate NAME LICENSE PREFIX: runs the licence gate on a one-component SBOM; sets GATE_MSG.
gate() {
	[ "$GATE_OK" -eq 1 ] || { GATE_MSG="pyyaml missing"; return 1; }
	python3 -I -c '
import json, sys
n, l, o = sys.argv[1:4]
json.dump({"bomFormat": "CycloneDX", "specVersion": "1.5",
           "metadata": {"component": {"type": "operating-system", "name": "the-monolith", "version": "test"}},
           "components": [{"type": "library", "name": n, "version": "0", "licenses": [{"expression": l}]}]}, open(o, "w"))' "$1" "$2" "$3.cdx.json"
	python3 -I scripts/check-licenses.py --sbom "$3.cdx.json" \
		--policy configs/attestation/license-policy.yaml --output "$3.report.json" >"$3.out" 2>&1
	g=$?
	GATE_MSG="exit $g: $(grep 'FAIL  ' "$3.out" | head -1 | cut -c1-200)"
	return "$g"
}

check_pkg games-roguelike/rl144
check_pkg www-client/stele

# ---- slice 2 (R05-Q3 parity): the gate case in syft's SPDX form ----
# scripts/fixtures/R05/sbom-licences.json: the licence expressions of rl144 and
# stele as syft wrote them into bom.cdx.json of Build run 42721213707 (artifact
# attestation, bom.cdx.json sha256
# 06d2a2e67c7ff632c551d999fb34c1ee22ef254326a6ce551190699c629456d2), verbatim.
# CI reads that form, not the ebuild's Gentoo LICENSE.
sbom_expr() { # sbom_expr NAME -> the fixture's expression for NAME
	python3 -I -c '
import json, sys
for c in json.load(open(sys.argv[1])):
    if c["name"] == sys.argv[2]:
        print(c["licenses"][0]["expression"], end="")' "$FIX/sbom-licences.json" "$1"
}
check_syft_pkg() { # check_syft_pkg category/name
	cp=$1
	pn=${cp#*/}
	expr=$(sbom_expr "$cp")
	[ -n "$expr" ]
	check "R05-Q3 $cp: fixture has syft's licence expression" $?
	gate "$pn-syft" "$expr" "$TMP/$pn.syft"
	check "R05-Q3 $cp: licence gate accepts syft's SPDX expression verbatim ($GATE_MSG)" $?
	gate "$pn-syft" "$expr AND Proprietary-Nonfree-EULA" "$TMP/$pn.syftbad"
	[ $? -ne 0 ]
	check "R05-Q3 $cp control: the gate rejects syft's expression plus a non-free licence" $?
}
check_syft_pkg games-roguelike/rl144
check_syft_pkg www-client/stele

if [ "$fails" -gt 0 ]; then
	echo "crate-licences: $fails check(s) FAILED"
	exit 1
fi
echo "crate-licences: all checks passed"
