#!/bin/sh
# S01: CVE waiver expiry is enforced and the grype DB build time is required.
# Covers S01-AC-3 and S01-AC-4 (drives scripts/check-cves.sh with a stub grype on PATH).
#
# Interface used (the ported script's own): check-cves.sh --sbom P --output P --policy P
#   --coverage-output P; grype is called as `grype db status`, `grype version ...`,
#   `grype sbom:SBOM -o json --file F` and `grype sbom:SBOM -o cyclonedx-json --file F`.
#   Waivers are policy `allowlist` entries {cve, component, justification, approved_by, expires}.
#   The coverage report has findings[].{cve,gating,waived}, db.built, verdict; S01 adds
#   `expired_waivers` (a list naming each waiver that did not waive; searched at the top
#   level, then under summary or policy).
# Each case pairs the defect with a control so a missing script cannot pass by exiting non-zero.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUBJ="$ROOT/scripts/check-cves.sh"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
CALLS="$TMP/grype.calls"

# Stub grype.  STUB_DB_BUILT empty -> `db status` prints no Built: line.
cat > "$BIN/grype" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_CALLS"
case "$1" in
db)
    echo "Status:    valid"
    echo "Schema:    v6.0.2"
    [ -n "${STUB_DB_BUILT:-}" ] && echo "Built:     $STUB_DB_BUILT"
    echo "Checksum:  sha256:abc123"
    exit 0 ;;
version)
    echo '{"version": "0.117.0"}'; exit 0 ;;
esac
fmt=""; file=""
while [ $# -gt 0 ]; do
    case "$1" in -o) fmt=$2; shift 2 ;; --file) file=$2; shift 2 ;; *) shift ;; esac
done
if [ "$fmt" = json ]; then
    cat > "$file" <<JSON
{"matches": [
 {"vulnerability": {"id": "CVE-2099-0001", "severity": "Critical", "fix": {"state": "fixed", "versions": ["2"]}},
  "artifact": {"name": "pkga", "version": "1", "cpes": ["cpe:2.3:a:x:pkga:1:*:*:*:*:*:*:*"]}},
 {"vulnerability": {"id": "CVE-2099-0002", "severity": "Critical", "fix": {"state": "not-fixed"}},
  "artifact": {"name": "pkgb", "version": "1", "cpes": ["cpe:2.3:a:x:pkgb:1:*:*:*:*:*:*:*"]}}
]}
JSON
else
    echo '{"bomFormat": "CycloneDX"}' > "$file"
fi
exit 0
STUB
chmod +x "$BIN/grype"

SBOM="$TMP/bom.cdx.json"
cat > "$SBOM" <<'JSON'
{"bomFormat": "CycloneDX", "specVersion": "1.6", "components": [
 {"type": "library", "name": "pkga", "version": "1", "cpe": "cpe:2.3:a:x:pkga:1:*:*:*:*:*:*:*"},
 {"type": "library", "name": "pkgb", "version": "1", "cpe": "cpe:2.3:a:x:pkgb:1:*:*:*:*:*:*:*"}]}
JSON

BUILT="2026-11-01T06:17:24Z"
FUTURE=$(date -u -d '+30 days' +%F)
PAST=$(date -u -d '-30 days' +%F)
TODAY=$(date -u +%F)

# run NAME POLICY_BODY [BUILT]  -> RC_<n>, report $TMP/NAME/cov.json
run() {
    d="$TMP/$1"; mkdir -p "$d"
    printf '%s\n' "gating_severities: [Critical, High, Unknown]" "$2" > "$d/policy.yaml"
    : > "$CALLS"
    ( PATH="$BIN:$PATH" STUB_CALLS="$CALLS" STUB_DB_BUILT="${3-$BUILT}" \
      bash "$SUBJ" --sbom "$SBOM" --output "$d/cve.cdx.json" --policy "$d/policy.yaml" \
          --coverage-output "$d/cov.json" > "$d/out.txt" 2>&1 )
    RC=$?
}
# jget NAME PY-EXPR-on-r   (prints "" when report is absent/unparseable)
jget() {
    python3 - "$TMP/$1/cov.json" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print(eval(sys.argv[2]))
PY
}
waiver() { # CVE COMPONENT EXPIRES-LINE
    printf 'allowlist:\n  - cve: %s\n    component: %s\n    justification: test\n    approved_by: "T <t@example.org>"\n%s\n' "$1" "$2" "$3"
}
FIND='dict(sorted({f["cve"]: (f["gating"], f["waived"]) for f in r["findings"]}.items()))'
EXPIRED='[str(w) for w in (r.get("expired_waivers") or (r.get("summary") or {}).get("expired_waivers") or (r.get("policy") or {}).get("expired_waivers") or [])]'

# ---- S01-AC-3 --------------------------------------------------------------------
# Control: both Critical matches waived with future expiry -> both waived, exit 0.
P="allowlist:
  - {cve: CVE-2099-0001, component: pkga, justification: t, approved_by: 'T <t@x>', expires: '$FUTURE'}
  - {cve: CVE-2099-0002, component: pkgb, justification: t, approved_by: 'T <t@x>', expires: '$FUTURE'}"
run future-both "$P"
v=$(jget future-both "$FIND")
if [ "$RC" -eq 0 ] && [ "$v" = "{'CVE-2099-0001': (False, True), 'CVE-2099-0002': (False, True)}" ]; then
    ok "S01-AC-3 waivers dated in the future are waived (exit 0, both findings waived, not gating)"
else fail "S01-AC-3 waivers dated in the future are waived (rc=$RC findings=$v)"; fi

# Future waived, past not waived and listed in expired_waivers.
P="allowlist:
  - {cve: CVE-2099-0001, component: pkga, justification: t, approved_by: 'T <t@x>', expires: '$FUTURE'}
  - {cve: CVE-2099-0002, component: pkgb, justification: t, approved_by: 'T <t@x>', expires: '$PAST'}"
run past "$P"
v=$(jget past "$FIND"); e=$(jget past "$EXPIRED")
if [ "$RC" -ne 0 ] && [ "$v" = "{'CVE-2099-0001': (False, True), 'CVE-2099-0002': (True, False)}" ]; then
    ok "S01-AC-3 a waiver dated in the past does not waive: the finding gates, the future one still waives"
else fail "S01-AC-3 a waiver dated in the past does not waive (rc=$RC findings=$v)"; fi
case "$e" in *CVE-2099-0002*) ok "S01-AC-3 the past-dated waiver is listed in expired_waivers" ;;
    *) fail "S01-AC-3 the past-dated waiver is listed in expired_waivers (got: $e)" ;; esac
case "$e" in *CVE-2099-0001*) fail "S01-AC-3 the future waiver is not listed in expired_waivers (got: $e)" ;;
    *) [ -n "$e" ] && ok "S01-AC-3 the future waiver is not listed in expired_waivers" \
        || fail "S01-AC-3 the future waiver is not listed in expired_waivers (no expired_waivers in report)" ;; esac

# Waiver with no expires: not waived.
P=$(waiver CVE-2099-0001 pkga "")
run noexp "$P
  - {cve: CVE-2099-0002, component: pkgb, justification: t, approved_by: 'T <t@x>', expires: '$FUTURE'}"
v=$(jget noexp "$FIND"); e=$(jget noexp "$EXPIRED")
if [ "$RC" -ne 0 ] && [ "$v" = "{'CVE-2099-0001': (True, False), 'CVE-2099-0002': (False, True)}" ]; then
    ok "S01-AC-3 a waiver with no expires does not waive: the finding gates"
else fail "S01-AC-3 a waiver with no expires does not waive (rc=$RC findings=$v)"; fi
case "$e" in *CVE-2099-0001*) ok "S01-AC-3 the waiver with no expires is listed in expired_waivers" ;;
    *) fail "S01-AC-3 the waiver with no expires is listed in expired_waivers (got: $e)" ;; esac

# Expiry today (UTC) does not waive (node spec change 4: on or before today).
P="allowlist:
  - {cve: CVE-2099-0001, component: pkga, justification: t, approved_by: 'T <t@x>', expires: '$TODAY'}
  - {cve: CVE-2099-0002, component: pkgb, justification: t, approved_by: 'T <t@x>', expires: '$FUTURE'}"
run today "$P"
v=$(jget today "$FIND")
[ "$RC" -ne 0 ] && [ "$v" = "{'CVE-2099-0001': (True, False), 'CVE-2099-0002': (False, True)}" ] \
    && ok "S01-AC-3 a waiver expiring today (UTC) does not waive" \
    || fail "S01-AC-3 a waiver expiring today (UTC) does not waive (rc=$RC findings=$v)"

# Unparseable expires does not waive.
P="allowlist:
  - {cve: CVE-2099-0001, component: pkga, justification: t, approved_by: 'T <t@x>', expires: 'next tuesday'}
  - {cve: CVE-2099-0002, component: pkgb, justification: t, approved_by: 'T <t@x>', expires: '$FUTURE'}"
run garbage "$P"
v=$(jget garbage "$FIND")
[ "$RC" -ne 0 ] && [ "$v" = "{'CVE-2099-0001': (True, False), 'CVE-2099-0002': (False, True)}" ] \
    && ok "S01-AC-3 a waiver with an unparseable expires does not waive" \
    || fail "S01-AC-3 a waiver with an unparseable expires does not waive (rc=$RC findings=$v)"

# ---- S01-AC-4 ----
PFUT="allowlist:
  - {cve: CVE-2099-0001, component: pkga, justification: t, approved_by: 'T <t@x>', expires: '$FUTURE'}
  - {cve: CVE-2099-0002, component: pkgb, justification: t, approved_by: 'T <t@x>', expires: '$FUTURE'}"
run built "$PFUT"
b=$(jget built 'r["db"]["built"]')
[ "$b" = "$BUILT" ] && ok "S01-AC-4 db.built equals the Built: line of grype db status" \
    || fail "S01-AC-4 db.built equals the Built: line of grype db status (got '$b')"

# No Built: line: non-zero, paired with the control above (exit of the same inputs with a Built: line).
run nobuilt "$PFUT" ""
rc_nobuilt=$RC
run builtctl "$PFUT"
if [ -f "$SUBJ" ] && [ "$RC" -eq 0 ] && grep -q '^db status' "$CALLS" && [ "$rc_nobuilt" -ne 0 ]; then
    ok "S01-AC-4 with no Built: line the script exits non-zero (and exits 0 with one)"
else fail "S01-AC-4 with no Built: line the script exits non-zero (no-Built rc=$rc_nobuilt, control rc=$RC)"; fi

# ---- Ruling 15 / slice 1 review note 1: an unparseable Built value exits non-zero ----
# Control: the same inputs with a valid Built exit 0.
run badbuilt "$PFUT" "not a date"
rc_bad=$RC
run badbuiltctl "$PFUT"
if [ -f "$SUBJ" ] && [ "$RC" -eq 0 ] && [ "$rc_bad" -ne 0 ] && [ "$rc_bad" -ne 127 ]; then
    ok "S01-AC-4 (ruling 15) Built: not a date exits non-zero (and a valid Built exits 0)"
else fail "S01-AC-4 (ruling 15) Built: not a date exits non-zero (bad rc=$rc_bad, control rc=$RC)"; fi

# ---- S01-AC-9: grype is handed an SBOM without syft:package:type, otherwise unchanged ----
# Second stub (the one above is frozen): keeps a copy of the sbom:<path> it is given.
BIN9="$TMP/bin9"; KEEP9="$TMP/keep9"; mkdir -p "$BIN9" "$KEEP9"
cat > "$BIN9/grype" <<'STUB'
#!/bin/sh
case "$1" in
db) echo "Status:    valid"; echo "Built:     $STUB_DB_BUILT"; echo "Checksum:  sha256:abc123"; exit 0 ;;
version) echo '{"version": "0.117.0"}'; exit 0 ;;
esac
case "$1" in sbom:*) n=$(ls "$KEEP9" | wc -l); cp "${1#sbom:}" "$KEEP9/sbom.$n.json" ;; esac
fmt=""; file=""
while [ $# -gt 0 ]; do
    case "$1" in -o) fmt=$2; shift 2 ;; --file) file=$2; shift 2 ;; *) shift ;; esac
done
if [ "$fmt" = json ]; then echo '{"matches": []}' > "$file"; else echo '{"bomFormat": "CycloneDX"}' > "$file"; fi
exit 0
STUB
chmod +x "$BIN9/grype"
SBOM9="$TMP/bom9.cdx.json"
cat > "$SBOM9" <<'JSON'
{"bomFormat": "CycloneDX", "specVersion": "1.6",
 "metadata": {"properties": [{"name": "syft:package:type", "value": "portage"}, {"name": "keep:me", "value": "1"}]},
 "components": [
 {"bom-ref": "ref-a", "type": "library", "name": "pkga", "version": "1",
  "cpe": "cpe:2.3:a:x:pkga:1:*:*:*:*:*:*:*", "purl": "pkg:ebuild/cat/pkga@1",
  "properties": [{"name": "syft:package:type", "value": "portage"}, {"name": "syft:package:foundBy", "value": "portage-cataloger"}]},
 {"bom-ref": "ref-b", "type": "library", "name": "pkgb", "version": "2",
  "cpe": "cpe:2.3:a:x:pkgb:2:*:*:*:*:*:*:*", "purl": "pkg:ebuild/cat/pkgb@2",
  "properties": [{"name": "syft:package:type", "value": "portage"}, {"name": "syft:metadata:size", "value": "42"}]}]}
JSON
cp "$SBOM9" "$TMP/bom9.orig"
mkdir -p "$TMP/ac9"; printf 'gating_severities: [Critical, High, Unknown]\n' > "$TMP/ac9/policy.yaml"
( PATH="$BIN9:$PATH" KEEP9="$KEEP9" STUB_DB_BUILT="$BUILT" \
  bash "$SUBJ" --sbom "$SBOM9" --output "$TMP/ac9/cve.cdx.json" --policy "$TMP/ac9/policy.yaml" \
      --coverage-output "$TMP/ac9/cov.json" > "$TMP/ac9/out.txt" 2>&1 )
rc9=$?
nkept=$(ls "$KEEP9" | wc -l)
if [ "$nkept" -ge 1 ]; then ok "S01-AC-9 control: the stub grype received an SBOM ($nkept)"
else fail "S01-AC-9 control: the stub grype received an SBOM (none; script rc=$rc9)"; fi
chk9() { # prints OK or a reason, for each SBOM grype received
python3 -I - "$KEEP9" "$TMP/bom9.orig" <<'PY'
import glob, json, sys
files = sorted(glob.glob(sys.argv[1] + "/*.json"))
if not files:
    print("no SBOM kept"); sys.exit(0)
orig = json.load(open(sys.argv[2]))
def key(c): return (c.get("bom-ref"), c.get("name"), c.get("version"), c.get("cpe"), c.get("purl"))
for f in files:
    got = json.load(open(f))
    if "syft:package:type" in json.dumps(got):
        print("syft:package:type present in " + f); sys.exit(0)
    if sorted(map(key, got.get("components", []))) != sorted(map(key, orig["components"])):
        print("components/cpe/purl differ in " + f); sys.exit(0)
print("OK")
PY
}
r=$(chk9)
[ "$r" = OK ] && ok "S01-AC-9 the SBOM grype receives has no syft:package:type and the same components, cpe and purl" \
    || fail "S01-AC-9 the SBOM grype receives has no syft:package:type and the same components, cpe and purl ($r)"
# other syft properties survive
if [ "$nkept" -ge 1 ] && grep -q 'syft:package:foundBy' "$KEEP9"/sbom.0.json && grep -q 'syft:metadata:size' "$KEEP9"/sbom.0.json; then
    ok "S01-AC-9 other syft properties are kept in the SBOM grype receives"
else fail "S01-AC-9 other syft properties are kept in the SBOM grype receives"; fi
if cmp -s "$SBOM9" "$TMP/bom9.orig"; then ok "S01-AC-9 the input SBOM file is unchanged"
else fail "S01-AC-9 the input SBOM file is unchanged"; fi

echo
[ "$fails" -eq 0 ] && { echo "check-cves-waivers: all passed"; exit 0; }
echo "check-cves-waivers: $fails failed"; exit 1
