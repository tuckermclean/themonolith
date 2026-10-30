"""Check docs/graph.yaml against the node specs and SPEC.md.

    python3 -I .claude/skills/node/check-spec.py [--write]

Checks: deps and decisions resolve, no cycles, `track: critical` is exactly P01 and its ancestors,
every node has a spec with the SPEC §9 headings, numbered criteria each with *Verify* and *Tier*,
known doctrine/trap ids and OD ids, and docs/migration.tsv (scripts/check-migration.py). --write regenerates each spec's header row from the graph.
"""
import os
import re
import subprocess
import sys

import yaml

ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                      check=True, cwd=os.path.dirname(os.path.abspath(__file__))).stdout.strip()
WRITE = "--write" in sys.argv
g = yaml.safe_load(open(f"{ROOT}/docs/graph.yaml"))
N = {n["id"]: n for n in g["nodes"]}
doc = yaml.safe_load(open(f"{ROOT}/docs/study/doctrine.yaml"))
known = {t["id"] for t in doc["traps"]} | {d["id"] for d in doc["doctrines"]} | {d["id"] for d in doc["decisions"]}
spec = open(f"{ROOT}/SPEC.md").read()
ods = set(re.findall(r"^\| (OD-\d+) \|", spec, re.M))
WANT = ["Purpose", "Standard mechanism", "Tests", "Changes from the port", "Gate", "Risks"]
problems = 0


def anc(i):
    s, st = set(), [i]
    while st:
        for d in N[st.pop()]["deps"]:
            if d not in s:
                s.add(d)
                st.append(d)
    return s


for n in g["nodes"]:
    for d in n["deps"]:
        if d not in N:
            print(n["id"], "unknown dep", d)
            problems += 1
    for o in n.get("decisions", []):
        if o not in ods:
            print(n["id"], "unknown decision", o)
            problems += 1
    if n["id"] in anc(n["id"]):
        print(n["id"], "CYCLE")
        problems += 1
crit = anc("P01") | {"P01"}
for n in g["nodes"]:
    if (n["track"] == "critical") != (n["id"] in crit):
        print(n["id"], "track mismatch")
        problems += 1
ms_of = {}
for m in g["milestones"]:
    for a in m["after"]:
        ms_of.setdefault(a, m["id"])

total = 0
for nid, n in N.items():
    f = f"{ROOT}/nodes/{nid}-{n['name']}.md"
    if not os.path.exists(f):
        print(nid, "MISSING", f)
        problems += 1
        continue
    s = open(f).read()
    lines = s.split("\n")
    unl = sorted(m["id"] for m in g["nodes"] if nid in m["deps"])
    new = f"| {n['track']} | {', '.join(n['deps']) or 'none'} | {', '.join(unl) or 'none'} | {ms_of.get(nid, '—')} | "
    for k, line in enumerate(lines[:8]):
        if line.startswith("| ") and not line.startswith("| Track") and not line.startswith("|---"):
            size = line.strip("|").split("|")[-1].strip()
            if size not in ("S", "M", "L"):
                print(nid, "bad size", size)
                problems += 1
            row = new + size + " |"
            if line != row:
                if WRITE:
                    lines[k] = row
                else:
                    print(nid, "header differs:\n  ", line, "\n  ", row)
                    problems += 1
            break
    else:
        print(nid, "no header row")
        problems += 1
    if WRITE:
        s = "\n".join(lines)
        open(f, "w").write(s)
    inf, hs = False, []
    for line in lines:
        if line.startswith("```"):
            inf = not inf
        if not inf and re.match(r"#{1,2} ", line):
            hs.append(line)
    if hs != [f"# {nid} — {n['name']}"] + ["## " + w for w in WANT]:
        print(nid, "HEADINGS", hs)
        problems += 1
    acs = re.findall(r"^- \*\*(" + nid + r")-AC-(\d+)\*\* — (.+)$", s, re.M)
    nums = [int(a[1]) for a in acs]
    if not nums or nums != list(range(1, len(nums) + 1)):
        print(nid, "AC numbering", nums)
        problems += 1
    bad = [a[1] for a in acs if "*Verify:*" not in a[2] or not re.search(r"\*Tier:\* (fast|slow)", a[2])]
    if bad:
        print(nid, "AC without Verify or Tier", bad)
        problems += 1
    unk = sorted(r for r in set(re.findall(r"\b[TD]-[a-z0-9][a-z0-9-]*[a-z0-9]\b", s)) if r not in known)
    badn = sorted(r for r in set(re.findall(r"\b[FIRBOSPMGX]0[0-9]\b", s)) if r not in N)
    odr = sorted(o for o in set(re.findall(r"\bOD-\d+\b", s)) if o not in ods)
    if unk or badn or odr:
        print(nid, "unknown refs:", unk, badn, odr)
        problems += 1
    total += len(acs)
print(f"{len(N)} nodes, {len(crit)} critical, {total} acceptance criteria")
mig = subprocess.run([sys.executable, "-I", f"{ROOT}/scripts/check-migration.py"], capture_output=True, text=True)
for line in mig.stdout.splitlines():
    if not line.startswith("PROBLEMS"):
        print(line)
if mig.returncode:
    problems += 1
print("PROBLEMS", problems)
sys.exit(1 if problems else 0)
