#!/bin/sh
# P07 prerelease-cve (criteria P07-AC-1 .. P07-AC-6; AC-7 is a recorded run after the merge).
#   P07-AC-1  scripts/release-kind.sh on the tag table; release-create.sh takes its flags from it (stub gh, no RELEASE_KIND,
#             from the checkout root and from another directory); make -n release-create names scripts/release-kind.sh
#   P07-AC-2  make -n test-gates under GITHUB_REF_TYPE/GITHUB_REF_NAME: pre-release tag, final tag, branch, unset
#             (branch and unset equal main's output, committed in scripts/fixtures/P07/make/)
#   P07-AC-3  gates-verdict.sh on fixture attestation directories; the workflow steps that stay blocking
#   P07-AC-4  release-notes.sh on fixture summaries; make -n release-notes
#   P07-AC-5  dashboard.py on a fixture pre-release (guard: P04's dashboard is unchanged)
#   P07-AC-6  docs/releasing.md states the rule
# A missing script is reported as FAIL lines, never a crash or a skip. Needs no git history.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES GH_REPO GH_TOKEN GITHUB_TOKEN GITHUB_REF_TYPE GITHUB_REF_NAME \
	GITHUB_STEP_SUMMARY CVE_REPORT_ONLY RELEASE_KIND RELEASE_DIR TAG PREV_TAG BUILD_VERSION ISO
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
FX=$ROOT/scripts/fixtures/P07
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
check() { # check <label> <command...>
	l=$1; shift
	if "$@" >/dev/null 2>&1; then ok "$l"; else fail "$l"; fi
}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/P07.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM
W=$TMP/P07
mkdir -p "$W/bin" "$W/cwd"
RK=$ROOT/scripts/release-kind.sh
RC=$ROOT/scripts/release-create.sh
RN=$ROOT/scripts/release-notes.sh

PRE_TAGS="v0.2.0-alpha1 v0.2.0-alpha2 v0.2.0-beta.2 v0.2.0-rc1 v1.0.0-rc.3"
FINAL_TAGS="v0.2.0 v1.0.0"

# ---------------------------------------------------------------- P07-AC-1
# kind <tag>: sets KOUT and KRC (127 when the script is absent)
kind() { KOUT=$(sh "$RK" "$1" 2>/dev/null); KRC=$?; }
for t in $PRE_TAGS; do
	kind "$t"
	[ -f "$RK" ] && [ $KRC -eq 0 ] && [ "$KOUT" = prerelease ] && ok "P07-AC-1 release-kind.sh $t prints prerelease" \
		|| fail "P07-AC-1 release-kind.sh $t prints prerelease (rc=$KRC out='$KOUT')"
done
for t in $FINAL_TAGS; do
	kind "$t"
	[ -f "$RK" ] && [ $KRC -eq 0 ] && [ "$KOUT" = final ] && ok "P07-AC-1 release-kind.sh $t prints final" \
		|| fail "P07-AC-1 release-kind.sh $t prints final (rc=$KRC out='$KOUT')"
done
for t in '' 0.2.0 main; do
	kind "$t"
	[ -f "$RK" ] && [ $KRC -ne 0 ] && [ $KRC -ne 127 ] && [ "$KOUT" != prerelease ] && [ "$KOUT" != final ] \
		&& ok "P07-AC-1 release-kind.sh '$t' exits non-zero" \
		|| fail "P07-AC-1 release-kind.sh '$t' exits non-zero (rc=$KRC out='$KOUT')"
done

# release-create.sh against a stub gh, with no RELEASE_KIND
cat >"$W/bin/gh" <<'E'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done >>"$P07_GH_LOG"
E
chmod +x "$W/bin/gh"
mkdir -p "$W/other"
# rc_run <dir> <tag> [env...]: runs release-create.sh from <dir>; the gh arguments land in $W/gh.log
rc_run() {
	d=$1; t=$2; shift 2
	: >"$W/gh.log"
	(cd "$d" && env PATH="$W/bin:$PATH" P07_GH_LOG="$W/gh.log" TAG="$t" RELEASE_DIR="$W/rel" BUILD_VERSION=0.0.0 \
		GITHUB_REPOSITORY=acme/monolith-fixture GH_TOKEN=x "$@" sh "$RC") >"$W/rc.out" 2>&1
	RCRC=$?
}
for where in root other; do
	if [ $where = root ]; then dir=$ROOT; label="the checkout's root"; else dir=$W/other; label="another directory"; fi
	for t in $PRE_TAGS $FINAL_TAGS; do
		rc_run "$dir" "$t"
		case " $PRE_TAGS " in *" $t "*) want=pre ;; *) want=final ;; esac
		has_p=0; has_l=0
		grep -qxF -e '--prerelease' "$W/gh.log" && has_p=1
		grep -qxF -e '--latest=false' "$W/gh.log" && has_l=1
		if [ $RCRC -eq 0 ] && grep -qxF "$t" "$W/gh.log"; then
			if [ $want = pre ] && [ $has_p -eq 1 ] && [ $has_l -eq 1 ]; then
				ok "P07-AC-1 release-create.sh passes --prerelease --latest=false for $t (no RELEASE_KIND, from $label)"
			elif [ $want = final ] && [ $has_p -eq 0 ] && [ $has_l -eq 0 ]; then
				ok "P07-AC-1 release-create.sh passes neither flag for $t (no RELEASE_KIND, from $label)"
			else
				fail "P07-AC-1 release-create.sh flags for $t from $label (prerelease=$has_p latest=$has_l, want $want)"
			fi
		else
			fail "P07-AC-1 release-create.sh runs for $t from $label (rc=$RCRC)"
		fi
	done
done

# release-create.sh has no tag pattern of its own: it runs $RELEASE_KIND
cat >"$W/bin/kind-pre" <<'E'
#!/bin/sh
echo prerelease
E
cat >"$W/bin/kind-final" <<'E'
#!/bin/sh
echo final
E
chmod +x "$W/bin/kind-pre" "$W/bin/kind-final"
rc_run "$W/other" v0.2.0 RELEASE_KIND="$W/bin/kind-pre"
if [ $RCRC -eq 0 ] && grep -qxF -e '--prerelease' "$W/gh.log" && grep -qxF -e '--latest=false' "$W/gh.log"; then
	ok "P07-AC-1 release-create.sh takes the pre-release decision from RELEASE_KIND (a stub saying prerelease, tag v0.2.0)"
else
	fail "P07-AC-1 release-create.sh takes the pre-release decision from RELEASE_KIND (a stub saying prerelease, tag v0.2.0) (rc=$RCRC)"
fi
rc_run "$W/other" v0.2.0-alpha1 RELEASE_KIND="$W/bin/kind-final"
if [ $RCRC -eq 0 ] && ! grep -qxF -e '--prerelease' "$W/gh.log" && ! grep -qxF -e '--latest=false' "$W/gh.log" && grep -qxF v0.2.0-alpha1 "$W/gh.log"; then
	ok "P07-AC-1 release-create.sh takes the decision from RELEASE_KIND (a stub saying final, tag v0.2.0-alpha1)"
else
	fail "P07-AC-1 release-create.sh takes the decision from RELEASE_KIND (a stub saying final, tag v0.2.0-alpha1) (rc=$RCRC)"
fi
if ! grep -qE '\*-\*|case .*TAG' "$RC"; then
	ok "P07-AC-1 release-create.sh holds no tag pattern of its own (no *-* case)"
else
	fail "P07-AC-1 release-create.sh holds no tag pattern of its own (no *-* case)"
fi

mkn() { # mkn <outfile> <make args...>
	_o=$1; shift
	(cd "$ROOT" && make -n "$@") >"$_o" 2>&1
}
mkn "$W/mk.rc" release-create TAG=v0.2.0
grep -q 'scripts/release-kind\.sh' "$W/mk.rc" && ok "P07-AC-1 make -n release-create names scripts/release-kind.sh" \
	|| fail "P07-AC-1 make -n release-create names scripts/release-kind.sh"

# ---------------------------------------------------------------- P07-AC-2
DUMMY=output/p07-dummy.iso
# The Makefile's REGISTRY value, read from the Makefile (no literal registry name lives in a fixture)
REG=$(cd "$ROOT" && make -pn -f Makefile 2>/dev/null | sed -n 's/^REGISTRY = //p' | head -n 1)
REG_RE=$(printf '%s' "$REG" | sed 's/[][\.*^$|/]/\\&/g')
# tg <outfile> [VAR=value...]: make -n test-gates; the checkout's path becomes @ROOT@, the registry @REGISTRY@,
# every image digest sha256:@DIGEST@ (so the committed expected output holds no registry name and no digest)
tg() {
	_o=$1; shift
	(cd "$ROOT" && env "$@" make -n test-gates ISO="$DUMMY" 2>&1) | sed -e "s|$ROOT|@ROOT@|g" -e "s|$REG_RE|@REGISTRY@|g" \
		-e 's|sha256:[0-9a-f]\{64\}|sha256:@DIGEST@|g' >"$_o"
}
[ -n "$REG" ] || fail "P07-AC-2 the Makefile's REGISTRY value is readable"
tg "$W/tg.pre" GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v0.2.0-alpha2
tg "$W/tg.final" GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v0.2.0
if grep -q 'gates-verdict\.sh' "$W/tg.pre" && grep -q -e '--cve-report-only' "$W/tg.pre"; then
	ok "P07-AC-2 tag v0.2.0-alpha2: make -n test-gates passes --cve-report-only to gates-verdict.sh"
else
	fail "P07-AC-2 tag v0.2.0-alpha2: make -n test-gates passes --cve-report-only to gates-verdict.sh"
fi
if grep -q 'gates-verdict\.sh' "$W/tg.pre" && ! grep -Eq 'arc -eq 0' "$W/tg.pre"; then
	ok "P07-AC-2 tag v0.2.0-alpha2: make -n test-gates drops the arc -eq 0 requirement"
else
	fail "P07-AC-2 tag v0.2.0-alpha2: make -n test-gates drops the arc -eq 0 requirement"
fi
if grep -q 'pre-release tag v0\.2\.0-alpha2' "$W/tg.pre"; then
	ok "P07-AC-2 tag v0.2.0-alpha2: the recipe prints the pre-release line naming the tag"
else
	fail "P07-AC-2 tag v0.2.0-alpha2: the recipe prints the pre-release line naming the tag"
fi
if grep -q 'gates-verdict\.sh' "$W/tg.final" && ! grep -q -e '--cve-report-only' "$W/tg.final"; then
	ok "P07-AC-2 tag v0.2.0: make -n test-gates passes no --cve-report-only"
else
	fail "P07-AC-2 tag v0.2.0: make -n test-gates passes no --cve-report-only"
fi
if grep -Eq 'arc -eq 0' "$W/tg.final"; then
	ok "P07-AC-2 tag v0.2.0: make -n test-gates keeps arc -eq 0"
else
	fail "P07-AC-2 tag v0.2.0: make -n test-gates keeps arc -eq 0"
fi
if grep -q 'gates-verdict\.sh' "$W/tg.final" && ! grep -q 'pre-release tag' "$W/tg.final"; then
	ok "P07-AC-2 tag v0.2.0: no pre-release line"
else
	fail "P07-AC-2 tag v0.2.0: no pre-release line"
fi
# branch or unset: the output equals main's, for CVE_REPORT_ONLY set to 1 and unset
for refs in "branch" "unset"; do
	for cro in 1 unset; do
		if [ "$refs" = branch ]; then set -- GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main; else set -- FOO_P07=1; fi
		if [ "$cro" = 1 ]; then set -- "$@" CVE_REPORT_ONLY=1; fi
		tg "$W/tg.cmp" "$@"
		if [ -s "$FX/make/test-gates.main.cve-$cro.txt" ] && cmp -s "$W/tg.cmp" "$FX/make/test-gates.main.cve-$cro.txt"; then
			ok "P07-AC-2 GITHUB_REF_TYPE $refs, CVE_REPORT_ONLY $cro: make -n test-gates output equals main's"
		else
			fail "P07-AC-2 GITHUB_REF_TYPE $refs, CVE_REPORT_ONLY $cro: make -n test-gates output equals main's"
		fi
	done
done

# ---------------------------------------------------------------- P07-AC-3
GV=$ROOT/scripts/gates-verdict.sh
# mkatt <name> <license> <cve> <unowned> <sbom> <dbbuilt|empty>: an attestation directory under $W/att
mkatt() {
	d="$W/att/$1"; mkdir -p "$d"
	python3 -I - "$d" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json, sys
d, lic, cve, un, sbom, built = sys.argv[1:7]
b = "" if built == "empty" else built
ov = "pass" if (lic, cve, un, sbom) == ("pass",) * 4 else "fail"
json.dump({"sbom_check": sbom, "license_check": lic, "cve_check": cve, "unowned_check": un, "overall": ov,
           "cve_failures": ["zlib-1.2.11: CVE-2099-1111"], "cve_db": {"built": b}}, open(d + "/attestation-summary.json", "w"))
json.dump({"db": {"built": b},
           "findings": [{"cve": "CVE-2099-1111", "severity": "High", "component": "zlib", "gating": True}]},
          open(d + "/cve-report-coverage.json", "w"))
PY
}
# gv <name> [flags]: sets GRC and GOUT
gv() { n=$1; shift; GOUT=$(sh "$GV" "$@" "$W/att/$n" 2>&1); GRC=$?; }
DB=2026-11-04T05:00:00Z
mkatt cvefail pass fail pass pass "$DB"
mkatt lic fail fail pass pass "$DB"
mkatt unowned pass fail fail pass "$DB"
mkatt sbom pass fail pass fail "$DB"
mkatt nodb pass fail pass pass empty
gv cvefail --cve-report-only
[ $GRC -eq 0 ] && ok "P07-AC-3 pre-release mode (--cve-report-only): cve_check fail with the other gates passing exits 0" \
	|| fail "P07-AC-3 pre-release mode (--cve-report-only): cve_check fail with the other gates passing exits 0 (rc=$GRC)"
for g in "lic:licence" "unowned:unowned" "sbom:sbom" "nodb:db.built"; do
	n=${g%%:*}; w=${g#*:}
	gv "$n" --cve-report-only
	if [ -f "$GV" ] && [ $GRC -ne 0 ] && [ $GRC -ne 127 ] && echo "$GOUT" | grep -i "FAIL" | grep -qi "$w"; then
		ok "P07-AC-3 pre-release mode: a failing $w gate exits non-zero, naming it"
	else
		fail "P07-AC-3 pre-release mode: a failing $w gate exits non-zero, naming it (rc=$GRC)"
	fi
done
gv cvefail
if [ -f "$GV" ] && [ $GRC -ne 0 ] && [ $GRC -ne 127 ]; then
	ok "P07-AC-3 final-tag mode (no flag): cve_check fail exits non-zero"
else
	fail "P07-AC-3 final-tag mode (no flag): cve_check fail exits non-zero (rc=$GRC)"
fi

# the blocking steps of build.yml and release.yml keep their if: conditions and have no continue-on-error
python3 -I - "$ROOT/.github/workflows/build.yml" "$ROOT/.github/workflows/release.yml" <<'PY'
import sys
try:
    import yaml
except Exception as e:
    print("FAIL: P07-AC-3 PyYAML is not available: %s" % e); sys.exit(1)
GATE = "needs.changes.outputs.gate == 'true'"
want = [
    (sys.argv[1], "Check the package set", GATE),
    (sys.argv[1], "Check that the rootfs provenance holds in release mode", GATE),
    (sys.argv[1], "Validate the SBOM against the CycloneDX schema", None),
    (sys.argv[1], "Report the sizes (sizes.md) against the budget", None),
    (sys.argv[2], "Check every file against SHA256SUMS", None),
    (sys.argv[2], "Check the digest chain", None),
]
bad = 0
docs = {}
for path, name, cond in want:
    try:
        if path not in docs:
            docs[path] = yaml.safe_load(open(path).read())
        steps = [s for j in docs[path]["jobs"].values() for s in (j.get("steps") or []) if s.get("name") == name]
    except Exception as e:
        print("FAIL: P07-AC-3 %s parses: %s" % (path.rsplit("/", 1)[-1], e)); bad += 1; continue
    wf = path.rsplit("/", 1)[-1]
    if len(steps) != 1:
        print("FAIL: P07-AC-3 %s has the step '%s' once (%d)" % (wf, name, len(steps))); bad += 1; continue
    s = steps[0]
    if s.get("if") == cond:
        print("PASS: P07-AC-3 %s step '%s' keeps its if: %s" % (wf, name, cond))
    else:
        print("FAIL: P07-AC-3 %s step '%s' keeps its if: %s (now %r)" % (wf, name, cond, s.get("if"))); bad += 1
    if "continue-on-error" not in s:
        print("PASS: P07-AC-3 %s step '%s' has no continue-on-error" % (wf, name))
    else:
        print("FAIL: P07-AC-3 %s step '%s' has no continue-on-error" % (wf, name)); bad += 1
sys.exit(1 if bad else 0)
PY
wrc=$?
# the python summary lines are counted by exit status (any FAIL line makes it non-zero)
[ $wrc -eq 0 ] || fails=$((fails+1))

# ---------------------------------------------------------------- P07-AC-4
mkdir -p "$W/notes/configs/portage"
cp "$FX/notes/versions.lock" "$W/notes/configs/portage/versions.lock"
echo iso >"$W/notes/test.iso"
# notes <summary-dir> <tag> [VAR=value...] : runs release-notes.sh in $W/notes; sets NRC, NOUT; the notes are in $W/notes/release-notes.md
notes() {
	sd=$1; t=$2; shift 2
	rm -f "$W/notes/release-notes.md"
	NOUT=$(cd "$W/notes" && env TAG="$t" BUILD_VERSION=0.2.0 PREV_TAG= ISO="$W/notes/test.iso" GITHUB_REPOSITORY=acme/monolith-fixture \
		"$@" RELEASE_DIR="$sd" sh "$RN" 2>&1)
	NRC=$?
}
# section <file>: the Supply-chain gates section of the notes
section() { awk '/^### Supply-chain gates/{f=1;next} /^#/{f=0} f' "$1" 2>/dev/null; }
notes "$FX/notes/pre" v0.2.0-alpha2
section "$W/notes/release-notes.md" >"$W/sec.pre"
if [ $NRC -eq 0 ] && [ -s "$W/sec.pre" ]; then ok "P07-AC-4 release-notes.sh on the pre-release summary writes a Supply-chain gates section"
else fail "P07-AC-4 release-notes.sh on the pre-release summary writes a Supply-chain gates section (rc=$NRC)"; fi
grep -qw 'fail' "$W/sec.pre" && ok "P07-AC-4 pre-release notes: the CVE verdict fail" || fail "P07-AC-4 pre-release notes: the CVE verdict fail"
for n in 3 2 40; do
	grep -qw "$n" "$W/sec.pre" && ok "P07-AC-4 pre-release notes: the count $n" || fail "P07-AC-4 pre-release notes: the count $n"
done
grep -q '2026-11-04' "$W/sec.pre" && ok "P07-AC-4 pre-release notes: the grype DB build time" || fail "P07-AC-4 pre-release notes: the grype DB build time"
grep -i 'known CVE' "$W/sec.pre" >"$W/sent.pre"
if [ -s "$W/sent.pre" ] && grep -q 'attestation-summary\.json' "$W/sent.pre" && grep -qi 'final release' "$W/sent.pre" && grep -qi 'clear' "$W/sent.pre"; then
	ok "P07-AC-4 pre-release notes: the known-CVE sentence (known CVE findings, attestation-summary.json, a final release must clear them)"
else
	fail "P07-AC-4 pre-release notes: the known-CVE sentence (known CVE findings, attestation-summary.json, a final release must clear them)"
fi
# the gating count is cve_coverage.gating_findings (9), not the CVEs listed in cve_failures (2 entries listing 3 CVEs); 5 waived; 41 total
notes "$FX/notes/multi" v0.2.0-alpha2
section "$W/notes/release-notes.md" >"$W/sec.multi"
if [ $NRC -eq 0 ] && grep -qw 9 "$W/sec.multi" && grep -qw 5 "$W/sec.multi" && grep -qw 41 "$W/sec.multi" \
	&& ! grep -qw 3 "$W/sec.multi" && ! grep -qw 2 "$W/sec.multi"; then
	ok "P07-AC-4 pre-release notes: gating findings are cve_coverage.gating_findings (9, not the 3 CVEs in cve_failures), with 5 waived and 41 total"
else
	fail "P07-AC-4 pre-release notes: gating findings are cve_coverage.gating_findings (9, not the 3 CVEs in cve_failures), with 5 waived and 41 total (rc=$NRC)"
fi
notes "$FX/notes/final" v0.2.0
section "$W/notes/release-notes.md" >"$W/sec.final"
if [ $NRC -eq 0 ] && [ -s "$W/sec.final" ]; then ok "P07-AC-4 release-notes.sh on the final summary writes a Supply-chain gates section"
else fail "P07-AC-4 release-notes.sh on the final summary writes a Supply-chain gates section (rc=$NRC)"; fi
grep -qw 'pass' "$W/sec.final" && ok "P07-AC-4 final notes: the CVE verdict pass" || fail "P07-AC-4 final notes: the CVE verdict pass"
grep -qw 'fail' "$W/sec.final" && fail "P07-AC-4 final notes: no fail verdict" || { [ -s "$W/sec.final" ] && ok "P07-AC-4 final notes: no fail verdict" || fail "P07-AC-4 final notes: no fail verdict (no section)"; }
for n in 0 2; do
	grep -qw "$n" "$W/sec.final" && ok "P07-AC-4 final notes: the count $n" || fail "P07-AC-4 final notes: the count $n"
done
if [ -s "$W/sec.final" ] && ! grep -qi 'known CVE' "$W/notes/release-notes.md"; then
	ok "P07-AC-4 final notes: no known-CVE sentence"
else
	fail "P07-AC-4 final notes: no known-CVE sentence"
fi
mkdir -p "$W/emptyrel"
notes "$W/emptyrel" v0.2.0-alpha2
if [ -f "$RN" ] && [ $NRC -ne 0 ] && echo "$NOUT" | grep -q 'attestation-summary\.json'; then
	ok "P07-AC-4 release-notes.sh with no summary exits non-zero, naming attestation-summary.json"
else
	fail "P07-AC-4 release-notes.sh with no summary exits non-zero, naming attestation-summary.json (rc=$NRC)"
fi
NOUT=$(cd "$W/notes" && env -u RELEASE_DIR TAG=v0.2.0-alpha2 BUILD_VERSION=0.2.0 PREV_TAG= ISO="$W/notes/test.iso" \
	GITHUB_REPOSITORY=acme/monolith-fixture sh "$RN" 2>&1)
NRC=$?
if [ -f "$RN" ] && [ $NRC -ne 0 ] && echo "$NOUT" | grep -q 'RELEASE_DIR'; then
	ok "P07-AC-4 release-notes.sh with RELEASE_DIR unset exits non-zero, naming RELEASE_DIR"
else
	fail "P07-AC-4 release-notes.sh with RELEASE_DIR unset exits non-zero, naming RELEASE_DIR (rc=$NRC)"
fi
mkn "$W/mk.rn" release-notes
grep -qF "RELEASE_DIR='output/release'" "$W/mk.rn" && ok "P07-AC-4 make -n release-notes passes RELEASE_DIR='output/release' by default" \
	|| fail "P07-AC-4 make -n release-notes passes RELEASE_DIR='output/release' by default"
mkn "$W/mk.rn2" release-notes RELEASE_DIR=p07/given
grep -qF "RELEASE_DIR='p07/given'" "$W/mk.rn2" && ! grep -qF "RELEASE_DIR='output/release'" "$W/mk.rn2" \
	&& ok "P07-AC-4 make -n release-notes passes the RELEASE_DIR given on the command line" \
	|| fail "P07-AC-4 make -n release-notes passes the RELEASE_DIR given on the command line"
# a summary that parses but lacks a field the notes need fails the same way: non-zero, naming the file, not silently
for v in nounowned:unowned_check emptycve:cve_check; do
	notes "$FX/notes/${v%%:*}" v0.2.0-alpha2
	if [ -f "$RN" ] && [ $NRC -ne 0 ] && echo "$NOUT" | grep -q 'attestation-summary\.json'; then
		ok "P07-AC-4 release-notes.sh on a summary lacking ${v##*:} exits non-zero, naming attestation-summary.json"
	else
		fail "P07-AC-4 release-notes.sh on a summary lacking ${v##*:} exits non-zero, naming attestation-summary.json (rc=$NRC)"
	fi
done

# a summary lacking cve_coverage.gating_findings (cve_failures still lists 3 CVEs) fails the same way, not by counting cve_failures
notes "$FX/notes/nogating" v0.2.0-alpha2
if [ -f "$RN" ] && [ $NRC -ne 0 ] && echo "$NOUT" | grep -q 'attestation-summary\.json'; then
	ok "P07-AC-4 release-notes.sh on a summary lacking cve_coverage.gating_findings exits non-zero, naming attestation-summary.json"
else
	fail "P07-AC-4 release-notes.sh on a summary lacking cve_coverage.gating_findings exits non-zero, naming attestation-summary.json (rc=$NRC)"
fi

# attestation.sh writes cve_coverage.gating_findings into the summary, copied from cve-report-coverage.json's summary.gating_findings.
# Run offline in a scratch copy of scripts/ whose sibling pillar scripts are stubs (check-cves.sh writes the fixture coverage file),
# with stub syft and grype on PATH.
AT=$W/att
rm -rf "${AT:?}"; mkdir -p "$AT/scripts" "$AT/bin" "$AT/sysroot" "$AT/out"
if [ -f "$ROOT/scripts/attestation.sh" ]; then cp "$ROOT/scripts/attestation.sh" "$AT/scripts/attestation.sh"; fi
cat >"$AT/scripts/check-cves.sh" <<'STUB'
#!/bin/bash
# stub: writes the fixture coverage file beside --output, as the real check-cves.sh does
while [ $# -gt 0 ]; do case $1 in --output) out=$2; shift 2 ;; *) shift ;; esac; done
cp "$P07_COVERAGE" "$(dirname "$out")/cve-report-coverage.json"
echo '{"vulnerabilities": []}' >"$out"
STUB
for f in enrich-sbom.py check-licenses.py check-unowned.py; do printf 'import sys\n' >"$AT/scripts/$f"; done
cat >"$AT/bin/syft" <<'STUB'
#!/bin/sh
for a in "$@"; do case $a in
	cyclonedx-json=*) echo '{"components": []}' >"${a#*=}" ;;
	json=*) echo '{"artifacts": [], "files": []}' >"${a#*=}" ;;
esac; done
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' >"$AT/bin/grype"
chmod +x "$AT/bin/syft" "$AT/bin/grype" "$AT/scripts/check-cves.sh"
ATOUT=$(cd "$AT" && env -u GITHUB_REF PATH="$AT/bin:$PATH" P07_COVERAGE="$FX/attestation/cve-report-coverage.json" \
	bash "$AT/scripts/attestation.sh" --sysroot "$AT/sysroot" --build-tag v0.2.0-alpha2 --output-dir "$AT/out" 2>&1)
ATRC=$?
ATL="P07-AC-4 attestation.sh summary cve_coverage copies summary.gating_findings, total_findings and waived_findings from cve-report-coverage.json"
if [ -f "$AT/out/attestation-summary.json" ]; then
	python3 -I - "$AT/out/attestation-summary.json" "$ATL" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])).get("cve_coverage", {})
bad = []
for k, want in (("gating_findings", 7), ("total_findings", 53), ("waived_findings", 4)):
    if c.get(k) != want:
        bad.append("%s=%r (want %r)" % (k, c.get(k), want))
if bad:
    print("FAIL: %s (%s)" % (sys.argv[2], "; ".join(bad)))
    sys.exit(1)
print("PASS: " + sys.argv[2])
PY
	[ $? -eq 0 ] || fails=$((fails+1))
else
	fail "$ATL (no attestation-summary.json written, rc=$ATRC)"
fi

# ---------------------------------------------------------------- P07-AC-5 (guard)
REPO=acme/monolith-fixture
cat >"$W/bin/gh" <<'E'
#!/bin/sh
# gh stub: serves $P07_GH_FIXTURES/gh/<owner>__<repo>/{list.json,<tag>/view.json,<tag>/<asset>}
fx=${P07_GH_FIXTURES:?}
[ "${1:-}" = release ] || { echo "gh stub: unsupported: $*" >&2; exit 2; }
sub=${2:-}; shift 2
repo=${GH_REPO:-${GITHUB_REPOSITORY:-}}
tag=; pat=; dir=.
while [ $# -gt 0 ]; do
	case $1 in
	--repo|-R) repo=$2; shift 2 ;;
	--pattern|-p) pat=$2; shift 2 ;;
	--dir|-D) dir=$2; shift 2 ;;
	--json|--limit|-L) shift 2 ;;
	-*) shift ;;
	*) tag=$1; shift ;;
	esac
done
rd=$fx/gh/$(printf '%s' "$repo" | sed 's|/|__|')
[ -d "$rd" ] || { echo "gh stub: no repository '$repo'" >&2; exit 1; }
case $sub in
list) cat "$rd/list.json" ;;
view) [ -f "$rd/$tag/view.json" ] || exit 1; cat "$rd/$tag/view.json" ;;
download)
	[ -d "$rd/$tag" ] || exit 1
	n=0
	for f in "$rd/$tag"/*; do
		b=$(basename "$f")
		[ "$b" = view.json ] && continue
		# shellcheck disable=SC2254
		case $b in $pat) mkdir -p "$dir"; cp "$f" "$dir/$b"; n=$((n+1)) ;; esac
	done
	[ $n -gt 0 ] || exit 1 ;;
*) exit 2 ;;
esac
E
chmod +x "$W/bin/gh"
D=$W/dash
rm -rf "${D:?}"; mkdir -p "$D"
cp -R "$FX/dashboard/gh" "$D/gh"; cp -R "$FX/dashboard/feed/site" "$D/site"; cp -R "$FX/dashboard/feed/data" "$D/data"
cp -R "$ROOT/scripts/fixtures/P04/gh/tuckermclean__linux-live-iso-factory" "$D/gh/tuckermclean__linux-live-iso-factory"
(cd "$W/cwd" && env PATH="$W/bin:$PATH" P07_GH_FIXTURES="$D" GITHUB_REPOSITORY=$REPO RC1_TAG=v0.1.0-rc1 \
	python3 -I "$ROOT/scripts/dashboard.py" --site "$D/site" --data "$D/data" --result "$D/result") >"$D/out.log" 2>&1
DRC=$?
P=$D/site/v0.2.0-alpha2/index.html
if [ $DRC -eq 0 ] && [ -s "$P" ]; then ok "P07-AC-5 dashboard.py writes the page of the fixture pre-release"
else fail "P07-AC-5 dashboard.py writes the page of the fixture pre-release (rc=$DRC)"; fi
flat() { [ -f "$1" ] && tr '\n' ' ' <"$1"; }
flat "$P" | sed 's#</tr>#\n#g' >"$D/rows"
grep -F '>CVEs<' "$D/rows" | grep -qF '>fail<' && ok "P07-AC-5 the page shows the CVE gate as fail" || fail "P07-AC-5 the page shows the CVE gate as fail"
grep -F 'total findings' "$D/rows" | grep -qF '>40<' && ok "P07-AC-5 the page shows 40 total findings" || fail "P07-AC-5 the page shows 40 total findings"
grep -F 'waived findings' "$D/rows" | grep -qF '>2<' && ok "P07-AC-5 the page shows 2 waived findings" || fail "P07-AC-5 the page shows 2 waived findings"
n=0; for c in CVE-2026-9001 CVE-2026-9002 CVE-2026-9003; do flat "$P" | grep -qF "$c" && n=$((n+1)); done
[ $n -eq 3 ] && ok "P07-AC-5 the page lists the 3 gating findings" || fail "P07-AC-5 the page lists the 3 gating findings ($n)"
grep -F 'Kind' "$D/rows" | grep -qF '>prerelease<' && ok "P07-AC-5 the page marks the release a prerelease" || fail "P07-AC-5 the page marks the release a prerelease"
flat "$D/site/index.html" | sed 's#</tr>#\n#g' | grep -F 'href="v0.2.0-alpha2/' | grep -qF '>prerelease<' \
	&& ok "P07-AC-5 the index row marks the release a prerelease" || fail "P07-AC-5 the index row marks the release a prerelease"

# ---------------------------------------------------------------- P07-AC-6
DOC=$ROOT/docs/releasing.md
awk '/^### Pre-?release/{f=1;print;next} /^##/{f=0} f' "$DOC" 2>/dev/null | tr '\n' ' ' | sed 's/\. /.\n/g' >"$W/sec.doc"
[ -s "$W/sec.doc" ] || fail "P07-AC-6 docs/releasing.md has a Prerelease section"
sent() { # sent <regex>...: a sentence of the section matching every regex
	cp "$W/sec.doc" "$W/s.0"; i=0
	for re in "$@"; do grep -iE -- "$re" "$W/s.$i" >"$W/s.$((i+1))"; i=$((i+1)); done
	[ -s "$W/s.$i" ]
}
if sent 'CVE' 'report' '(not|never|n.t) (block|gat|fail)|non-?blocking|not gating'; then
	ok "P07-AC-6 releasing.md: on a pre-release tag the CVE gate reports and does not block"
else
	fail "P07-AC-6 releasing.md: on a pre-release tag the CVE gate reports and does not block"
fi
if grep -qiE 'still block' "$W/sec.doc" && grep -qiE 'licen[cs]e' "$W/sec.doc" && grep -qi 'unowned' "$W/sec.doc" && grep -qi 'SBOM' "$W/sec.doc"; then
	ok "P07-AC-6 releasing.md: lists the gates that still block (licence, unowned, SBOM)"
else
	fail "P07-AC-6 releasing.md: lists the gates that still block (licence, unowned, SBOM)"
fi
if sent 'final' 'CVE' 'must|fail|block|pass|clear'; then
	ok "P07-AC-6 releasing.md: a final tag must pass the CVE gate"
else
	fail "P07-AC-6 releasing.md: a final tag must pass the CVE gate"
fi
grep -qiE '(^|[^[:alnum:]])-?alpha' "$W/sec.doc" && ok "P07-AC-6 releasing.md: covers -alpha tags" || fail "P07-AC-6 releasing.md: covers -alpha tags"

echo
if [ "$fails" -eq 0 ]; then echo "prerelease-cve: all checks passed"; else echo "prerelease-cve: $fails check(s) failed"; fi
[ "$fails" -eq 0 ]
