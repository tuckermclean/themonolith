#!/bin/sh
# P03: the advisory feed monitor (scripts/nightly-cve-monitor.py).
# Covers P03-AC-1 (no flip-flop), P03-AC-2 (status file shape), P03-AC-3 (the CVE policy
# decides) and P03-AC-4 (unreachable is never clean).
#
# Monitor interface assumed (kept small, close to node spec P03 changes 1-5):
#   python3 -I scripts/nightly-cve-monitor.py --data-dir DIR [--policy FILE] [--base-url URL]
#   - DIR layout is the ported one: DIR/<tag>/bom.cdx.json per release; the status file for
#     a tag is DIR/status/<tag>.json (also the prior state: revoked / clearing).
#   - --policy defaults to configs/attestation/cve-policy.yaml; --base-url defaults to
#     https://monolith.technomantics.com ; details_url = <base-url>/<tag> on revoked files.
#   - the monitor finds scripts/check-cves.sh and scripts/run-cve-canary.sh next to itself, runs
#     `grype db update`, then the canary, then check-cves.sh per SBOM and reads its coverage report.
#   - exit 0 = every tag was scanned and written; 3 = grype db update failed (nothing scanned
#     or written); 4 = canary failed (nothing written); other non-zero = a per-tag scan error
#     (that tag's file is left unchanged, the other tags are still processed).
#   - status file keys: build_tag, status (clean|revoked), checked, policy_sha256,
#     grype_db_built, advisories (gating CVE ids), details_url (revoked), clearing (1 on the
#     first passing night of a revoked build).
# grype is a stub on PATH (as in check-cves-waivers.test.sh); check-cves.sh and
# run-cve-canary.sh are the real ones. The stub picks its matches by a marker-<tag> component
# name inside the SBOM. Each defect case is paired with a control so a missing script cannot
# pass just by exiting non-zero.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUBJ="$ROOT/scripts/nightly-cve-monitor.py"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; MATCH="$TMP/matches"; mkdir -p "$BIN" "$MATCH"
CALLS="$TMP/grype.calls"; : > "$CALLS"
SEEN="$TMP/statuses.seen"; : > "$SEEN"
BUILT="2026-11-01T06:17:24Z"
BASE="https://advisories.example.test/feed"
FAIL_DB=""; FAIL_CANARY=""

# ---- stub grype ----------------------------------------------------------------------
cat > "$BIN/grype" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_CALLS"
case "$1" in
db)
    if [ "${2:-}" = update ]; then
        [ -n "${STUB_DB_UPDATE_FAIL:-}" ] && { echo "db update: network unreachable" >&2; exit 1; }
        exit 0
    fi
    echo "Status:    valid"
    echo "Schema:    v6.0.2"
    echo "Built:     $STUB_DB_BUILT"
    echo "Checksum:  sha256:abc123"
    exit 0 ;;
version)
    echo '{"version": "0.117.0"}'; exit 0 ;;
esac
sbom=""; fmt=""; file=""
while [ $# -gt 0 ]; do
    case "$1" in
    sbom:*) sbom=${1#sbom:}; shift ;;
    -o) fmt=$2; shift 2 ;;
    --file) file=$2; shift 2 ;;
    *) shift ;;
    esac
done
if [ "$fmt" != json ]; then echo '{"bomFormat": "CycloneDX"}' > "$file"; exit 0; fi
if grep -q cve-gate-canary "$sbom"; then
    if [ -n "${STUB_CANARY_FAIL:-}" ]; then echo '{"matches": []}' > "$file"; exit 0; fi
    cat > "$file" <<'JSON'
{"matches": [{"vulnerability": {"id": "CVE-2014-0160", "severity": "High", "fix": {"state": "fixed", "versions": ["1.0.1g"]}},
  "artifact": {"name": "openssl", "version": "1.0.1", "cpes": ["cpe:2.3:a:openssl:openssl:1.0.1:*:*:*:*:*:*:*"]}}]}
JSON
    exit 0
fi
marker=$(grep -o 'marker-[A-Za-z0-9]*' "$sbom" | head -1)
[ -n "$marker" ] && [ -f "$STUB_MATCHES/${marker#marker-}.json" ] || { echo "grype: cannot read SBOM $sbom" >&2; exit 1; }
cp "$STUB_MATCHES/${marker#marker-}.json" "$file"
exit 0
STUB
chmod +x "$BIN/grype"

# ---- helpers ---------------------------------------------------------------------------
mk_sbom() { # DATADIR TAG
    mkdir -p "$1/$2"
    cat > "$1/$2/bom.cdx.json" <<JSON
{"bomFormat": "CycloneDX", "specVersion": "1.6",
 "metadata": {"component": {"type": "operating-system", "name": "marker-$2", "version": "1"}},
 "components": [
  {"type": "library", "name": "pkga", "version": "1", "cpe": "cpe:2.3:a:x:pkga:1:*:*:*:*:*:*:*"},
  {"type": "library", "name": "pkgb", "version": "1", "cpe": "cpe:2.3:a:x:pkgb:1:*:*:*:*:*:*:*"}]}
JSON
}
mk_corrupt() { mkdir -p "$1/$2"; printf '{"bomFormat": "CycloneDX", "components": [ {"type": "libr' > "$1/$2/bom.cdx.json"; }
vuln() { # CVE SEVERITY COMPONENT
    printf '{"vulnerability": {"id": "%s", "severity": "%s", "fix": {"state": "fixed", "versions": ["2"]}}, "artifact": {"name": "%s", "version": "1", "cpes": ["cpe:2.3:a:x:%s:1:*:*:*:*:*:*:*"]}}' "$1" "$2" "$3" "$3"
}
night() { # TAG F|E|ML  -> what the stub grype matches for TAG tonight
    case "$2" in
    F)  printf '{"matches": [%s]}\n' "$(vuln CVE-2099-1000 High pkga)" > "$MATCH/$1.json" ;;
    ML) printf '{"matches": [%s, %s]}\n' "$(vuln CVE-2099-2000 Medium pkgb)" "$(vuln CVE-2099-2001 Low pkga)" > "$MATCH/$1.json" ;;
    *)  echo '{"matches": []}' > "$MATCH/$1.json" ;;
    esac
}
runmon() { # DATADIR [monitor args]  -> RC, output in DATADIR.out
    d=$1; shift
    : > "$CALLS"
    ( cd "$ROOT" && PATH="$BIN:$PATH" STUB_CALLS="$CALLS" STUB_MATCHES="$MATCH" STUB_DB_BUILT="$BUILT" \
      STUB_DB_UPDATE_FAIL="$FAIL_DB" STUB_CANARY_FAIL="$FAIL_CANARY" \
      python3 -I "$SUBJ" --data-dir "$d" "$@" > "$d.out" 2>&1 )
    RC=$?
}
jget() { # FILE PY-EXPR-on-d  (prints "" when absent/unparseable)
    python3 -I - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print(eval(sys.argv[2]))
PY
}
sfile() { echo "$1/status/$2.json"; }
snap() { ( cd "$1" && find . -type f -exec cksum {} + | sort ); }
policy() { # FILE [ALLOWLIST-BODY]
    printf 'gating_severities: [Critical, High, Unknown]\n%s\n' "${2:-}" > "$1"
}
POL="$TMP/policy.yaml"; policy "$POL"
FUTURE=$(date -u -d '+30 days' +%F)
PAST=$(date -u -d '-30 days' +%F)

# observe DATADIR TAG -> prints status[+clearing]; records the status seen
observe() {
    s=$(jget "$(sfile "$1" "$2")" 'd.get("status")')
    c=$(jget "$(sfile "$1" "$2")" 'd.get("clearing")')
    echo "$s" >> "$SEEN"
    if [ "$c" = 1 ]; then echo "$s+clearing"; else echo "$s"; fi
}

# ---- P03-AC-1 ------------------------------------------------------------------------------
seq_case() { # NAME "F F E E" "expected statuses"
    name=$1; results=$2; want=$3
    dd="$TMP/$name"; mk_sbom "$dd" tagA
    printf '{"cve_check": "pass", "note": "attested, never rewritten"}\n' > "$dd/tagA/attestation-summary.json"
    cp "$dd/tagA/attestation-summary.json" "$TMP/$name.summary.orig"
    got=""
    for r in $results; do
        night tagA "$r"
        runmon "$dd" --policy "$POL" --base-url "$BASE"
        got="$got $(observe "$dd" tagA)"
    done
    got=${got# }
    if [ "$got" = "$want" ]; then ok "P03-AC-1 nights $results give: $want"
    else fail "P03-AC-1 nights $results give: $want (got: ${got:-nothing})"; fi
    if [ -f "$(sfile "$dd" tagA)" ] && cmp -s "$dd/tagA/attestation-summary.json" "$TMP/$name.summary.orig"; then
        ok "P03-AC-1 nights $results leave attestation-summary.json byte-identical"
    else fail "P03-AC-1 nights $results leave attestation-summary.json byte-identical"; fi
    extra=$(find "$dd" -name 'attestation-summary.json' | wc -l)
    [ "$extra" -eq 1 ] && [ -f "$(sfile "$dd" tagA)" ] && ok "P03-AC-1 nights $results create no other attestation-summary.json" \
        || fail "P03-AC-1 nights $results create no other attestation-summary.json (found $extra)"
}
seq_case ac1-ffee "F F E E" "revoked revoked revoked+clearing clean"
seq_case ac1-ef   "E F"     "clean revoked"
seq_case ac1-fef  "F E F"   "revoked revoked+clearing revoked"
# a tag without an attestation summary never gets one
dd="$TMP/ac1-nosummary"; mk_sbom "$dd" tagA; night tagA F; runmon "$dd" --policy "$POL" --base-url "$BASE"
[ -f "$(sfile "$dd" tagA)" ] && [ -z "$(find "$dd" -name 'attestation-summary.json')" ] \
    && ok "P03-AC-1 a tag with no attestation-summary.json does not get one" \
    || fail "P03-AC-1 a tag with no attestation-summary.json does not get one"

# ---- P03-AC-2 ------------------------------------------------------------------------------
dd="$TMP/ac2"; mk_sbom "$dd" tagR; mk_sbom "$dd" tagC; mk_sbom "$dd" tagL
night tagR F; night tagC E; night tagL F
runmon "$dd" --policy "$POL" --base-url "$BASE"
night tagL E
runmon "$dd" --policy "$POL" --base-url "$BASE"      # tagL: revoked then a passing night = clearing file
R=$(sfile "$dd" tagR); C=$(sfile "$dd" tagC); L=$(sfile "$dd" tagL)
for f in "$R" "$C" "$L"; do
    s=$(jget "$f" 'd.get("status")'); echo "$s" >> "$SEEN"
done
G='"status"[^"]*"revoked"'
[ -f "$R" ] && grep -q "$G" "$R" && ok "P03-AC-2 a revoked file matches the disc grep" \
    || fail "P03-AC-2 a revoked file matches the disc grep"
[ -f "$L" ] && [ "$(jget "$L" 'd.get("clearing")')" = 1 ] && grep -q "$G" "$L" \
    && ok "P03-AC-2 a clearing file (still revoked) matches the disc grep" \
    || fail "P03-AC-2 a clearing file (still revoked) matches the disc grep"
[ -f "$C" ] && ! grep -q "$G" "$C" && [ "$(jget "$C" 'd.get("status")')" = clean ] \
    && ok "P03-AC-2 a clean file does not match the disc grep" \
    || fail "P03-AC-2 a clean file does not match the disc grep"
for pair in "R:$R" "L:$L" "C:$C"; do
    k=${pair%%:*}; f=${pair#*:}
    n1=$(grep -o '"status"' "$f" 2>/dev/null | wc -l); n2=$(grep -o '"revoked"' "$f" 2>/dev/null | wc -l)
    want2=1; [ "$k" = C ] && want2=0
    if [ -f "$f" ] && [ "$n1" -eq 1 ] && [ "$n2" -eq "$want2" ]; then
        ok "P03-AC-2 file $k holds the token \"status\" once and \"revoked\" $want2 time(s): no other key carries them"
    else fail "P03-AC-2 file $k holds the token \"status\" once and \"revoked\" $want2 time(s) (got $n1 and $n2)"; fi
done
v=$(jget "$R" 'd["details_url"].startswith("'"$BASE"'") and d["details_url"].endswith("tagR")')
[ "$v" = True ] && ok "P03-AC-2 details_url starts with the configured base URL and names the tag" \
    || fail "P03-AC-2 details_url starts with the configured base URL and names the tag"
if [ -f "$R" ] && [ -f "$C" ] && [ -f "$L" ] && ! grep -qi 'themonolith\.org' "$R" "$C" "$L"; then
    ok "P03-AC-2 no status file contains themonolith.org"
else fail "P03-AC-2 no status file contains themonolith.org"; fi
dd="$TMP/ac2-default"; mk_sbom "$dd" tagR; night tagR F
runmon "$dd" --policy "$POL"
v=$(jget "$(sfile "$dd" tagR)" 'd["details_url"].startswith("https://monolith.technomantics.com")')
[ "$v" = True ] && ok "P03-AC-2 without --base-url details_url starts with https://monolith.technomantics.com" \
    || fail "P03-AC-2 without --base-url details_url starts with https://monolith.technomantics.com"
# change 5 keys
SHA=$(sha256sum "$POL" | cut -d' ' -f1)
v=$(jget "$R" '[d.get("build_tag"), d.get("policy_sha256"), d.get("grype_db_built"), d.get("advisories")]')
[ "$v" = "['tagR', '$SHA', '$BUILT', ['CVE-2099-1000']]" ] \
    && ok "P03-AC-2 file carries build_tag, policy_sha256, grype_db_built and advisories" \
    || fail "P03-AC-2 file carries build_tag, policy_sha256, grype_db_built and advisories (got $v)"
v=$(jget "$C" '[bool(__import__("re").fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", str(d.get("checked")))), d.get("policy_sha256"), d.get("grype_db_built")]')
[ "$v" = "[True, '$SHA', '$BUILT']" ] \
    && ok "P03-AC-2 a clean file carries checked (UTC time), policy_sha256 and grype_db_built" \
    || fail "P03-AC-2 a clean file carries checked (UTC time), policy_sha256 and grype_db_built (got $v)"

# ---- P03-AC-3 ------------------------------------------------------------------------------
dd="$TMP/ac3-a"; mk_sbom "$dd" tagM; mk_sbom "$dd" tagH
night tagM ML; night tagH F
runmon "$dd" --policy "$POL" --base-url "$BASE"
sm=$(jget "$(sfile "$dd" tagM)" 'd.get("status")'); sh_=$(jget "$(sfile "$dd" tagH)" 'd.get("status")')
adv=$(jget "$(sfile "$dd" tagH)" 'd.get("advisories")')
echo "$sm" >> "$SEEN"; echo "$sh_" >> "$SEEN"
[ "$sm" = clean ] && ok "P03-AC-3 an SBOM whose only matches are Medium or Low is clean" \
    || fail "P03-AC-3 an SBOM whose only matches are Medium or Low is clean (got '$sm')"
if [ "$sh_" = revoked ] && [ "$adv" = "['CVE-2099-1000']" ]; then ok "P03-AC-3 one High is revoked and lists its CVE id"
else fail "P03-AC-3 one High is revoked and lists its CVE id (status '$sh_', advisories $adv)"; fi
case "$(cat "$(sfile "$dd" tagM)" 2>/dev/null)" in *CVE-2099-2000*|*CVE-2099-2001*)
    fail "P03-AC-3 Medium and Low CVE ids are not listed as advisories" ;;
    *) [ -f "$(sfile "$dd" tagM)" ] && ok "P03-AC-3 Medium and Low CVE ids are not listed as advisories" \
        || fail "P03-AC-3 Medium and Low CVE ids are not listed as advisories (no file)" ;; esac

W="allowlist:
  - {cve: CVE-2099-1000, component: pkga, justification: t, approved_by: 'T <t@x>', expires: '$FUTURE'}"
policy "$TMP/pol-valid.yaml" "$W"
dd="$TMP/ac3-b"; mk_sbom "$dd" tagH; night tagH F
runmon "$dd" --policy "$TMP/pol-valid.yaml" --base-url "$BASE"
s=$(jget "$(sfile "$dd" tagH)" 'd.get("status")'); echo "$s" >> "$SEEN"
[ "$s" = clean ] && ok "P03-AC-3 a High under a valid waiver is clean" \
    || fail "P03-AC-3 a High under a valid waiver is clean (got '$s')"
W="allowlist:
  - {cve: CVE-2099-1000, component: pkga, justification: t, approved_by: 'T <t@x>', expires: '$PAST'}"
policy "$TMP/pol-expired.yaml" "$W"
dd="$TMP/ac3-c"; mk_sbom "$dd" tagH; night tagH F
runmon "$dd" --policy "$TMP/pol-expired.yaml" --base-url "$BASE"
s=$(jget "$(sfile "$dd" tagH)" 'd.get("status")'); adv=$(jget "$(sfile "$dd" tagH)" 'd.get("advisories")'); echo "$s" >> "$SEEN"
[ "$s" = revoked ] && [ "$adv" = "['CVE-2099-1000']" ] && ok "P03-AC-3 the same waiver past expires is revoked" \
    || fail "P03-AC-3 the same waiver past expires is revoked (got '$s' $adv)"

# ---- P03-AC-4 ------------------------------------------------------------------------------
# Control for the defect cases: the same data dir with a healthy grype exits 0 and writes files.
mk3() { # DATADIR : three tags, tagB's SBOM corrupt if $2 is corrupt
    mk_sbom "$1" tagA; mk_sbom "$1" tagC
    if [ "${2:-}" = corrupt ]; then mk_corrupt "$1" tagB; else mk_sbom "$1" tagB; fi
    night tagA F; night tagB F; night tagC E
}
dd="$TMP/ac4-ctl"; mk3 "$dd"
runmon "$dd" --policy "$POL" --base-url "$BASE"
rc_ctl=$RC; nctl=$(find "$dd/status" -type f 2>/dev/null | wc -l)
if [ "$rc_ctl" -eq 0 ] && [ "$nctl" -eq 3 ]; then ok "P03-AC-4 control: healthy db, canary and SBOMs exit 0 and write three files"
else fail "P03-AC-4 control: healthy db, canary and SBOMs exit 0 and write three files (rc=$rc_ctl files=$nctl)"; fi
if grep -q 'CVE-2014-0160' "$dd.out"; then ok "P03-AC-4 control: the canary line (CVE-2014-0160) is in the run log"
else fail "P03-AC-4 control: the canary line (CVE-2014-0160) is in the run log"; fi

dd="$TMP/ac4-db"; mk3 "$dd"; before=$(snap "$dd")
FAIL_DB=1; runmon "$dd" --policy "$POL" --base-url "$BASE"; FAIL_DB=""
after=$(snap "$dd")
if [ "$rc_ctl" -eq 0 ] && [ "$RC" -ne 0 ] && [ "$before" = "$after" ] && [ ! -e "$dd/status" ]; then
    ok "P03-AC-4 a failing grype db update exits non-zero and writes no file"
else fail "P03-AC-4 a failing grype db update exits non-zero and writes no file (rc=$RC, control rc=$rc_ctl)"; fi
[ "$RC" -eq 3 ] && ok "P03-AC-4 a failing grype db update exits 3 (change 4)" \
    || fail "P03-AC-4 a failing grype db update exits 3 (change 4) (rc=$RC)"
grep -q '^db update' "$CALLS" && ! grep -q 'sbom:' "$CALLS" \
    && ok "P03-AC-4 a failing grype db update stops before any scan" \
    || fail "P03-AC-4 a failing grype db update stops before any scan"

dd="$TMP/ac4-can"; mk3 "$dd"; before=$(snap "$dd")
FAIL_CANARY=1; runmon "$dd" --policy "$POL" --base-url "$BASE"; FAIL_CANARY=""
after=$(snap "$dd")
if [ "$rc_ctl" -eq 0 ] && [ "$RC" -ne 0 ] && [ "$before" = "$after" ] && [ ! -e "$dd/status" ]; then
    ok "P03-AC-4 a failing canary exits non-zero and writes no file"
else fail "P03-AC-4 a failing canary exits non-zero and writes no file (rc=$RC, control rc=$rc_ctl)"; fi
[ "$RC" -eq 4 ] && ok "P03-AC-4 a failing canary exits 4 (change 4)" \
    || fail "P03-AC-4 a failing canary exits 4 (change 4) (rc=$RC)"

# one corrupt SBOM among three: its pre-existing file unchanged, the other two updated, non-zero
dd="$TMP/ac4-bad"; mk3 "$dd" corrupt; mkdir -p "$dd/status"
OLD="2000-01-01T00:00:00Z"
for t in tagA tagC; do
    printf '{"build_tag": "%s", "status": "clean", "checked": "%s"}\n' "$t" "$OLD" > "$dd/status/$t.json"
done
printf '{"build_tag": "tagB", "status": "revoked", "checked": "%s", "advisories": ["CVE-2000-0001"]}\n' "$OLD" > "$dd/status/tagB.json"
cp "$dd/status/tagB.json" "$TMP/tagB.orig"
runmon "$dd" --policy "$POL" --base-url "$BASE"
a=$(jget "$(sfile "$dd" tagA)" 'd.get("checked") != "'"$OLD"'" and d.get("status")')
c=$(jget "$(sfile "$dd" tagC)" 'd.get("checked") != "'"$OLD"'" and d.get("status")')
if [ "$rc_ctl" -eq 0 ] && [ "$RC" -ne 0 ]; then ok "P03-AC-4 one corrupt SBOM among three exits non-zero (a clean run exits 0)"
else fail "P03-AC-4 one corrupt SBOM among three exits non-zero (rc=$RC, control rc=$rc_ctl)"; fi
if [ "$a" = revoked ] && cmp -s "$dd/status/tagB.json" "$TMP/tagB.orig"; then
    ok "P03-AC-4 the corrupt SBOM's pre-existing file is unchanged (while tagA was rewritten)"
else fail "P03-AC-4 the corrupt SBOM's pre-existing file is unchanged"; fi
if [ "$a" = revoked ] && [ "$c" = clean ]; then ok "P03-AC-4 the other two files are updated (tagA revoked, tagC clean, new checked time)"
else fail "P03-AC-4 the other two files are updated (tagA '$a', tagC '$c')"; fi

# ---- review follow-up: unreadable prior state and a policy that did not load -------------------------
# An unreadable prior file must never read as "no prior state" (which would write clean).
prior_case() { # NAME ID PRIOR-FILE-CONTENT DESCRIPTION
    dd="$TMP/$1"; mk_sbom "$dd" tagA; mk_sbom "$dd" tagB; mk_sbom "$dd" tagC
    night tagA E; night tagB E; night tagC E
    mkdir -p "$dd/status"
    for t in tagA tagC; do
        printf '{"build_tag": "%s", "status": "clean", "checked": "%s"}\n' "$t" "$OLD" > "$dd/status/$t.json"
    done
    printf '%s' "$3" > "$dd/status/tagB.json"; cp "$dd/status/tagB.json" "$TMP/$1.orig"
    runmon "$dd" --policy "$POL" --base-url "$BASE"
    a=$(jget "$(sfile "$dd" tagA)" 'd.get("checked") != "'"$OLD"'" and d.get("status")')
    c=$(jget "$(sfile "$dd" tagC)" 'd.get("checked") != "'"$OLD"'" and d.get("status")')
    if [ "$rc_ctl" -eq 0 ] && [ "$RC" -ne 0 ]; then ok "P03-AC-4 $4 exits non-zero (a clean run exits 0)"
    else fail "P03-AC-4 $4 exits non-zero (rc=$RC, control rc=$rc_ctl)"; fi
    if cmp -s "$dd/status/tagB.json" "$TMP/$1.orig" && ! grep -q '"clean"' "$dd/status/tagB.json"; then
        ok "P03-AC-1 $4: the tag's file is left unchanged, no clean written"
    else fail "P03-AC-1 $4: the tag's file is left unchanged, no clean written"; fi
    if [ "$a" = clean ] && [ "$c" = clean ]; then ok "P03-AC-4 $4: the other tags are still processed"
    else fail "P03-AC-4 $4: the other tags are still processed (tagA '$a', tagC '$c')"; fi
    if ! grep -q 'Traceback' "$dd.out"; then ok "P03-AC-4 $4: no traceback"
    else fail "P03-AC-4 $4: no traceback"; fi
}
prior_case ac1-trunc ac1 '{"build_tag": "tagB", "status": "revok' "a truncated prior file"
prior_case ac1-array ac1 '["revoked"]' "a prior file that is JSON but not an object"

# A policy that did not load must not produce clean files (check-cves.sh falls back to a default).
policy_case() { # NAME POLICY-FILE DESCRIPTION
    dd="$TMP/$1"; mk_sbom "$dd" tagA; mk_sbom "$dd" tagB; night tagA E; night tagB E
    runmon "$dd" --policy "$2" --base-url "$BASE"
    n=$(grep -l '"clean"' "$dd"/status/*.json 2>/dev/null | wc -l)
    if [ "$rc_ctl" -eq 0 ] && [ "$RC" -ne 0 ]; then ok "P03-AC-3 $3 exits non-zero"
    else fail "P03-AC-3 $3 exits non-zero (rc=$RC, control rc=$rc_ctl)"; fi
    if [ "$n" -eq 0 ]; then ok "P03-AC-3 $3 writes no clean file"
    else fail "P03-AC-3 $3 writes no clean file ($n written)"; fi
}
printf 'gating_severities: [Critical\n  allowlist: : {{\n' > "$TMP/pol-broken.yaml"
policy_case ac3-broken "$TMP/pol-broken.yaml" "a --policy file that does not parse as YAML"
policy_case ac3-missing "$TMP/no-such-policy.yaml" "a --policy file that does not exist"

# ---- no other status value ever appeared ------------------------------------------------------
nseen=$(wc -l < "$SEEN")
bad=$(grep -v -x -e clean -e revoked "$SEEN" | sort -u | tr '\n' ' ')
if [ "$nseen" -gt 0 ] && [ -z "$bad" ]; then ok "P03-AC-1 only 'clean' and 'revoked' appear as a status in $nseen observations"
else fail "P03-AC-1 only 'clean' and 'revoked' appear as a status (observations $nseen, others: ${bad:-none})"; fi

echo
if [ "$fails" -eq 0 ]; then echo "advisory-feed: all passed"; exit 0; fi
echo "advisory-feed: $fails failed"; exit 1
