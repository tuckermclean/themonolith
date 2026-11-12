#!/bin/sh
# P03 advisory-feed workflow checks (P03-AC-5, P03-AC-6). POSIX sh; no network, no Git history.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

MON="$ROOT/scripts/nightly-cve-monitor.py"
WF="$ROOT/.github/workflows/advisory-feed.yml"

# --- P03-AC-5: none of the four substrings (case-insensitive) in either file.
# Needles are built from pieces so this file's own text is not the point of the check.
_t=the; _m=monolith; _a=a
for f in "$MON" "$WF"; do
	rel=${f#"$ROOT"/}
	if [ ! -f "$f" ]; then
		for n in "${_a}ws" s3 "${_t}${_m}.org" generate-dashboard; do
			fail "P03-AC-5 $rel has no '$n' (file missing)"
		done
		continue
	fi
	for n in "${_a}ws" s3 "${_t}${_m}.org" generate-dashboard; do
		if grep -qiF -e "$n" "$f"; then
			fail "P03-AC-5 $rel has no '$n'"
		else
			pass "P03-AC-5 $rel has no '$n'"
		fi
	done
done

# --- P03-AC-6: workflow shape
if [ ! -f "$WF" ]; then
	for l in "parses as a workflow" "cron schedule 0 4 * * *" "workflow_dispatch trigger" \
		"workflow permissions: contents read" "permissions are contents read plus pages/id-token write only" \
		"pages: write and id-token: write granted" "every uses: is pinned to a 40-hex SHA" \
		"a concurrency group" "grype pinned by version" "grype pinned by a sha256" \
		"grype sha256 is verified" "no install.sh"; do
		fail "P03-AC-6 $l (advisory-feed.yml missing)"
	done
else
	python3 -I - "$WF" "$ROOT" <<'PY'
import sys, re, os
bad = 0
def chk(l, c):
    global bad
    print(("PASS: " if c else "FAIL: ") + "P03-AC-6 " + l)
    if not c: bad += 1
wf, root = sys.argv[1], sys.argv[2]
text = open(wf).read()
try:
    import yaml
    doc = yaml.safe_load(text)
    on = doc.get(True, doc.get("on"))
    jobs = doc["jobs"]
    assert isinstance(jobs, dict) and jobs
except Exception as e:
    print("FAIL: P03-AC-6 advisory-feed.yml parses as a workflow: %s" % e)
    sys.exit(1)
chk("parses as a workflow", True)

crons = [s.get("cron") for s in ((on or {}).get("schedule") or [])] if isinstance(on, dict) else []
chk("cron schedule 0 4 * * * (got %r)" % crons, "0 4 * * *" in crons)
chk("workflow_dispatch trigger", isinstance(on, dict) and "workflow_dispatch" in on)

top = doc.get("permissions")
chk("workflow permissions: contents read", isinstance(top, dict) and top.get("contents") == "read")
allp = [("workflow", top)] + [("job " + j, (jd or {}).get("permissions")) for j, jd in jobs.items()]
allowed = {"contents": {"read"}, "pages": {"write"}, "id-token": {"write"}}
ok = True
for name, p in allp:
    if p is None: continue
    if not isinstance(p, dict): ok = False; continue
    for k, v in p.items():
        if k not in allowed or v not in allowed[k]: ok = False
chk("permissions are contents read plus pages/id-token write only", ok)
granted = set()
for _, p in allp:
    if isinstance(p, dict):
        granted |= {k for k, v in p.items() if v == "write"}
chk("pages: write and id-token: write granted", {"pages", "id-token"} <= granted)

uses = []
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "uses" and isinstance(v, str): uses.append(v)
            else: walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(jobs)
bad_uses = [u for u in uses if not u.startswith("./") and not re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", u)]
chk("every uses: is pinned to a 40-hex SHA (%d uses, unpinned %r)" % (len(uses), bad_uses), bool(uses) and not bad_uses)

def has_group(c):
    return (isinstance(c, str) and c.strip() != "") or (isinstance(c, dict) and bool(c.get("group")))
chk("a concurrency group", has_group(doc.get("concurrency")) or any(has_group((jd or {}).get("concurrency")) for jd in jobs.values()))

# Corpus where the grype fetch may live: the workflow, the scripts it names, and the Makefile
# recipes of the make targets it runs.
corpus = text
for m in set(re.findall(r"scripts/[A-Za-z0-9_./-]+", text)):
    p = os.path.join(root, m)
    if os.path.isfile(p): corpus += "\n" + open(p, errors="replace").read()
try: mk = open(os.path.join(root, "Makefile")).read()
except OSError: mk = ""
for t in set(re.findall(r"\bmake\s+(?:-\S+\s+)*([A-Za-z0-9_.-]+)", text)):
    m = re.search(r"^%s:.*\n((?:\t.*\n?|\n)*)" % re.escape(t), mk, re.M)
    if m:
        corpus += "\n" + m.group(1)
        for s in set(re.findall(r"scripts/[A-Za-z0-9_./-]+", m.group(1))):
            p = os.path.join(root, s)
            if os.path.isfile(p): corpus += "\n" + open(p, errors="replace").read()

chk("grype pinned by version", bool(re.search(r"(?i)grype[^\n]*\b\d+\.\d+\.\d+\b|\b\d+\.\d+\.\d+\b[^\n]*grype", corpus)))
chk("grype pinned by a sha256", bool(re.search(r"\b[0-9a-f]{64}\b", corpus)))
chk("grype sha256 is verified", bool(re.search(r"sha256sum\b[^\n]*(-c|--check)|shasum\s+-a\s+256|sha256sum\b", corpus)) and "grype" in corpus.lower())
chk("no install.sh", "install.sh" not in corpus)
sys.exit(1 if bad else 0)
PY
	[ $? -eq 0 ] && : || fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then echo "advisory-feed-workflow: all checks passed"; else echo "advisory-feed-workflow: $fails failure group(s)"; exit 1; fi
