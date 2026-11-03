#!/bin/sh
# gates-verdict.sh [--rc1] <attestation-dir>
#
# Reads the attestation summary and the CVE coverage report that attestation.sh wrote and decides
# whether the gates passed.
#   without --rc1: exit 0 iff "overall" is "pass" (all three gates decide).
#   with --rc1:    exit 0 iff the licence and unowned gates passed and the coverage report records a
#                  non-empty db.built; the CVE gate's own verdict is reported, not gating (rc1's tree
#                  carries CVEs the owner waives after this run lists them).
# Both modes print the raw grype match count ("raw matches: N") and the CVE gating findings (CVE id, component, severity) and, when GITHUB_STEP_SUMMARY
# is set, append them to that file as a Markdown table.
# A missing or unparseable attestation-summary.json, or a missing cve-report-coverage.json, exits 1
# and names the file.
set -u

rc1=0
if [ "${1:-}" = "--rc1" ]; then rc1=1; shift; fi
if [ $# -ne 1 ]; then
    echo "usage: gates-verdict.sh [--rc1] <attestation-dir>" >&2
    exit 2
fi
dir=$1
sum="$dir/attestation-summary.json"
cov="$dir/cve-report-coverage.json"

[ -f "$sum" ] || { echo "gates-verdict: missing $sum" >&2; exit 1; }

python3 -I - "$sum" "$cov" "$rc1" "${GITHUB_STEP_SUMMARY:-}" <<'PY'
import json, sys

sum_path, cov_path, rc1, step = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]

def load(path):
    try:
        with open(path) as f:
            d = json.load(f)
    except FileNotFoundError:
        print("gates-verdict: missing %s" % path, file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError) as e:
        print("gates-verdict: cannot read %s: %s" % (path, e), file=sys.stderr)
        sys.exit(1)
    if not isinstance(d, dict):
        print("gates-verdict: %s is not a JSON object" % path, file=sys.stderr)
        sys.exit(1)
    return d

summary = load(sum_path)
cov = load(cov_path)

built = (cov.get("db") or {}).get("built")
gating = [f for f in (cov.get("findings") or []) if f.get("gating")]

print("gates-verdict: licence=%s cve=%s unowned=%s overall=%s db.built=%s"
      % (summary.get("license_check"), summary.get("cve_check"), summary.get("unowned_check"),
         summary.get("overall"), built))
raw = (cov.get("summary") or {}).get("total_findings")
if raw is None:
    raw = len(cov.get("findings") or [])
print("raw matches: %d" % raw)
print("gates-verdict: %d CVE gating finding(s)" % len(gating))
for f in gating:
    print("  %s  %s  %s" % (f.get("cve", "?"), f.get("component", "?"), f.get("severity", "?")))

if step:
    with open(step, "a") as out:
        out.write("\n### CVE gating findings (%d)\n\nraw matches: %d\n\n" % (len(gating), raw))
        out.write("| CVE | Component | Severity |\n| --- | --- | --- |\n")
        for f in gating:
            out.write("| %s | %s | %s |\n" % (f.get("cve", "?"), f.get("component", "?"), f.get("severity", "?")))

if rc1:
    bad = []
    if summary.get("license_check") != "pass":
        bad.append("licence gate: %s" % summary.get("license_check"))
    if summary.get("unowned_check") != "pass":
        bad.append("unowned gate: %s" % summary.get("unowned_check"))
    if not built:
        bad.append("%s has no db.built" % cov_path)
else:
    bad = [] if summary.get("overall") == "pass" else ["overall: %s" % summary.get("overall")]
for b in bad:
    print("gates-verdict: FAIL: " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
