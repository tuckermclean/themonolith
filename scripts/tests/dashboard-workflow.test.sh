#!/bin/sh
# P04 slice 2: the workflow, the release asset list and the ledger (node spec changes 1, 4, 5; P04-AC-6, P04-AC-7).
#   P04-AC-6  advisory-feed.yml: cron, workflow_dispatch and a workflow_run trigger on Release completion; the scan job
#             does not run for a Release run that did not succeed; `make dashboard` after `make advisory-feed` and before
#             the Pages upload without stopping it; `make dashboard-check` the scan job's last step; no new action and
#             no new permission; P03's workflow test still passes.
#             `toolbox/ci lint` needs the Git checkout and the toolbox itself, so it is not run from here.
#   P04-AC-7  `make release-assets`, release-sums.sh, build.yml's reports upload and release-create.sh carry
#             attestation-summary.json; docs/capabilities.md lists the dashboard (P04, build) and the boot demo as dropped.
# POSIX sh; no network, no Git history. Scratch lives under a folder named P04.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fails=0
ok() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
check() { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi; }

W=$(mktemp -d)/P04
mkdir -p "$W"
trap 'rm -rf "$(dirname "$W")"' EXIT INT TERM

WF=$ROOT/.github/workflows/advisory-feed.yml
BUILD=$ROOT/.github/workflows/build.yml

# ======================================================================= P04-AC-6
if [ ! -f "$WF" ]; then
	fail "P04-AC-6 advisory-feed.yml is missing"
else
	python3 -I - "$WF" <<'PY'
import sys
bad = 0
def chk(l, c):
    global bad
    print(("PASS: " if c else "FAIL: ") + "P04-AC-6 " + l)
    if not c: bad += 1
try:
    import yaml
    doc = yaml.safe_load(open(sys.argv[1]).read())
    on = doc.get(True, doc.get("on"))
    jobs = doc["jobs"]
    scan = jobs["scan"]
    steps = scan["steps"]
except Exception as e:
    print("FAIL: P04-AC-6 advisory-feed.yml parses with a scan job: %s" % e)
    sys.exit(1)
on = on if isinstance(on, dict) else {}
chk("cron 0 4 * * * is kept", "0 4 * * *" in [s.get("cron") for s in (on.get("schedule") or [])])
chk("workflow_dispatch is kept", "workflow_dispatch" in on)
wr = on.get("workflow_run")
wr = wr if isinstance(wr, dict) else {}
chk("workflow_run triggers on the Release workflow (workflows: [Release])", wr.get("workflows") == ["Release"])
chk("workflow_run triggers on completion (types: [completed])", wr.get("types") == ["completed"])

cond = str(scan.get("if", ""))
chk("the scan job has an if:", bool(cond.strip()))
chk("the scan job's if: requires github.event.workflow_run.conclusion == 'success'",
    "github.event.workflow_run.conclusion == 'success'" in cond)
chk("the scan job's if: lets schedule and workflow_dispatch through",
    "github.event_name != 'workflow_run'" in cond or ("== 'schedule'" in cond and "== 'workflow_dispatch'" in cond))

def run_of(s): return str(s.get("run", "")).strip()
def idx(pred):
    for i, s in enumerate(steps):
        if pred(s): return i
    return -1
i_feed = idx(lambda s: run_of(s) == "make advisory-feed")
i_dash = idx(lambda s: run_of(s) == "make dashboard")
i_pages = idx(lambda s: str(s.get("uses", "")).startswith("actions/upload-pages-artifact"))
i_check = idx(lambda s: run_of(s) == "make dashboard-check")
chk("a step runs `make dashboard`", i_dash >= 0)
chk("`make dashboard` runs after `make advisory-feed`", i_feed >= 0 and i_dash > i_feed)
chk("`make dashboard` runs before the Pages upload", i_pages >= 0 and 0 <= i_dash < i_pages)
chk("the `make dashboard` step does not stop the Pages upload (continue-on-error: true)",
    i_dash >= 0 and steps[i_dash].get("continue-on-error") in (True, "true"))
chk("`make dashboard-check` is a step of the scan job", i_check >= 0)
chk("`make dashboard-check` is the scan job's last step", i_check >= 0 and i_check == len(steps) - 1)

# no new action, no new permission (the set P03 has)
want = {
    "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
    "actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9",
    "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9",
    "actions/deploy-pages@368f82528645a54fb793d4d04e342629a3f51346",
}
got = {s["uses"] for j in jobs.values() for s in (j.get("steps") or []) if "uses" in s}
chk("the set of actions is P03's (got %r)" % sorted(got ^ want), got == want)
chk("workflow permissions are contents: read only", doc.get("permissions") == {"contents": "read"})
chk("the scan job has no permissions block of its own", "permissions" not in scan)
chk("only the deploy job has a permissions block: pages write, id-token write",
    {k: v.get("permissions") for k, v in jobs.items() if "permissions" in v} == {"deploy": {"pages": "write", "id-token": "write"}})
sys.exit(1 if bad else 0)
PY
	[ $? -eq 0 ] || fails=$((fails + 1))
fi
check "P04-AC-6 P03's advisory-feed-workflow.test.sh passes" sh "$HERE/advisory-feed-workflow.test.sh"

# ======================================================================= P04-AC-7
mkn() { (cd "$ROOT" && make -n "$@" 2>&1); }
out=$(mkn release-assets ATTEST_OUT=P04/att RELEASE_DIR=P04/rel)
echo "$out" | grep -E "^cp .*P04/att/attestation-summary\.json.* .*P04/rel/attestation-summary\.json" >/dev/null \
	&& ok "P04-AC-7 make release-assets copies attestation-summary.json from ATTEST_OUT into the release directory" \
	|| fail "P04-AC-7 make release-assets copies attestation-summary.json from ATTEST_OUT into the release directory"

# release-sums.sh over a release directory
mk_rel() { rm -rf "$1"; mkdir -p "$1"; for f in themonolith-0.2.0.iso bom.cdx.json release-inputs.json source-audit.tsv \
	rootfs-provenance.tsv rc1-diff.md sizes.md dynamic-allowlist.txt attestation-summary.json; do echo "content of $f" >"$1/$f"; done; }
mk_rel "$W/rel"
sh "$ROOT/scripts/release-sums.sh" "$W/rel" >"$W/sums.out" 2>&1
check "P04-AC-7 release-sums.sh succeeds over a release directory holding attestation-summary.json" test $? -eq 0
grep -qE '[0-9a-f]{64}  attestation-summary\.json$' "$W/rel/SHA256SUMS" 2>/dev/null \
	&& ok "P04-AC-7 SHA256SUMS lists attestation-summary.json" || fail "P04-AC-7 SHA256SUMS lists attestation-summary.json"
check "P04-AC-7 SHA256SUMS verifies against the release directory" sh -c 'cd "$1" && sha256sum -c SHA256SUMS' _ "$W/rel"
mk_rel "$W/rel2"; rm -f "$W/rel2/attestation-summary.json"
sh "$ROOT/scripts/release-sums.sh" "$W/rel2" >"$W/sums2.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] && grep -q 'attestation-summary.json' "$W/sums2.out" \
	&& ok "P04-AC-7 release-sums.sh fails, naming attestation-summary.json, when it is missing" \
	|| fail "P04-AC-7 release-sums.sh fails, naming attestation-summary.json, when it is missing (rc=$rc)"

# build.yml: the reports upload step
python3 -I - "$BUILD" <<'PY'
import sys
step = "Upload the SBOM, SHA256SUMS and the reports"
try:
    import yaml
    doc = yaml.safe_load(open(sys.argv[1]).read())
    found = [s for j in doc["jobs"].values() for s in (j.get("steps") or []) if s.get("name") == step]
except Exception as e:
    print("FAIL: P04-AC-7 build.yml parses: %s" % e); sys.exit(1)
paths = [l.strip() for l in str(((found[0].get("with") or {}).get("path")) if found else "").splitlines()]
print(("PASS: " if found else "FAIL: ") + "P04-AC-7 build.yml has the step '%s'" % step)
c = "output/release/attestation-summary.json" in paths
print(("PASS: " if c else "FAIL: ") + "P04-AC-7 that step uploads output/release/attestation-summary.json")
sys.exit(0 if found and c else 1)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# release-create.sh with a stub gh
mkdir -p "$W/bin" "$W/cwd"
cat >"$W/bin/gh" <<'E'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done >>"$P04_GH_LOG"
E
chmod +x "$W/bin/gh"
: >"$W/gh.log"
echo notes >"$W/cwd/release-notes.md"
(cd "$W/cwd" && env PATH="$W/bin:$PATH" P04_GH_LOG="$W/gh.log" TAG=v0.2.0 RELEASE_DIR="$W/rel" BUILD_VERSION=0.2.0 \
	GITHUB_REPOSITORY=acme/monolith-fixture GH_TOKEN=x sh "$ROOT/scripts/release-create.sh") >"$W/create.out" 2>&1
check "P04-AC-7 release-create.sh runs against a stub gh" test $? -eq 0
grep -qxF "$W/rel/attestation-summary.json" "$W/gh.log" \
	&& ok "P04-AC-7 release-create.sh uploads attestation-summary.json from RELEASE_DIR" \
	|| fail "P04-AC-7 release-create.sh uploads attestation-summary.json from RELEASE_DIR"
grep -qxF "$W/rel/SHA256SUMS" "$W/gh.log" && ok "P04-AC-7 release-create.sh still uploads SHA256SUMS" \
	|| fail "P04-AC-7 release-create.sh still uploads SHA256SUMS"

# P01's release tests
for t in "$HERE"/release-*.test.sh; do
	check "P04-AC-7 P01's $(basename "$t") passes" sh "$t"
done

# the ledger
python3 -I - "$ROOT/docs/capabilities.md" <<'PY'
import sys
bad = 0
def chk(l, c):
    global bad
    print(("PASS: " if c else "FAIL: ") + "P04-AC-7 " + l)
    if not c: bad += 1
sec, name = {}, None
for l in open(sys.argv[1]).read().splitlines():
    if l.startswith("## "): name = l[3:].strip(); sec[name] = []
    elif name: sec[name].append(l)
rows = lambda n: [[c.strip() for c in l.strip().strip("|").split("|")] for l in sec.get(n, []) if l.startswith("|")]
rel = [r for r in rows("Release and after") if "dashboard" in r[0].lower()]
chk("capabilities.md lists the release dashboard under 'Release and after'", bool(rel))
chk("the dashboard row names node P04", any(len(r) > 2 and r[2] == "P04" for r in rel))
chk("the dashboard row has mode build", any(len(r) > 3 and r[3] == "build" for r in rel))
dr = rows("Dropped")
chk("'Dropped' keeps the in-browser boot demo", any("boot demo" in r[0].lower() for r in dr))
chk("'Dropped' no longer lists `make dashboard`", not any("make dashboard" in " ".join(r) for r in dr))
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

[ "$fails" -eq 0 ] && { echo "PASS: all dashboard workflow checks"; exit 0; }
echo "FAIL: $fails dashboard workflow check group(s) failed"
exit 1
