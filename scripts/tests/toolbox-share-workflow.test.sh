#!/bin/sh
# F02-AC-2 (pr-validate.yml part), F02-AC-3, F02-AC-4: the toolbox is built or pulled once per workflow run and shared.
# Reads .github/workflows/*.yml with PyYAML; needs no history of the checkout. Which jobs run toolbox/run is decided
# generically, so later workflows fall under it (F02 Risks): a `run:` containing `toolbox/run`, or a `make <targets...>` whose
# dry run (`make -n -B <targets> ISO=/x ISO_URL= GITHUB_OUTPUT=/dev/null <the step's VAR=val>`, the step/job/workflow env in the
# environment, variables and env values that hold a `${{ }}` expression left out, so Make's defaults apply) prints `toolbox/run`. Steps that only run make toolbox-save/-load/-check do not
# count as running the toolbox (so the toolbox job and the load step add nothing), and neither do their dry runs. A
# `uses: ./.github/workflows/x.yml` job is replaced by x.yml's jobs, whose caller is that job. Roots are the workflows with a trigger
# other than workflow_call. A root with toolbox-running jobs in more than one job (callee jobs counted) must have exactly one job
# running `make toolbox-save` followed by actions/upload-artifact (retention-days <= 7), and every other toolbox-running job must
# have that job in its needs (callee jobs: their calling job has it), a first run: step `make toolbox-load`, and an
# actions/download-artifact step of the same artifact name before it.
# AC-4's exemption: a job that also runs `make cache-push` holds packages: write for the binary package cache (build.yml `build`,
# before this node), so it may run toolbox-load; every other job running toolbox-save/-load/-check must not hold it.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES
out=$(python3 -I - "$ROOT" <<'PYEOF' 2>&1
import sys, os, re, shlex, subprocess, glob, traceback

root = sys.argv[1]
nfail = 0
def say(ok, msg):
    global nfail
    if not ok:
        nfail += 1
    print(("PASS: " if ok else "FAIL: ") + msg, flush=True)

try:
    import yaml
except Exception as e:
    say(False, "PyYAML is available (%s)" % e)
    sys.exit(0)

TOOLBOX_TARGETS = {"toolbox-save", "toolbox-load", "toolbox-check"}
EXPR = re.compile(r"\$\{\{.*?\}\}", re.S)
def resolve(s):
    return EXPR.sub("x", str(s))

def as_list(v):
    if v is None:
        return []
    return [v] if isinstance(v, str) else list(v)

def triggers(doc):
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {k: None for k in on}
    return dict(on or {})

wfdir = os.path.join(root, ".github", "workflows")
docs = {}
for path in sorted(glob.glob(os.path.join(wfdir, "*.yml"))):
    try:
        with open(path) as f:
            docs[os.path.basename(path)] = yaml.safe_load(f) or {}
    except Exception as e:
        say(False, "%s parses as YAML (%s)" % (os.path.basename(path), e))
say(bool(docs), "found %d workflows" % len(docs))

def makes(text):
    """[(targets, vars)] for each `make ...` command in a run: text."""
    found = []
    lines = []
    cur = ""
    for ln in text.splitlines():
        if ln.lstrip().startswith("#"):
            continue
        if ln.rstrip().endswith("\\"):
            cur += ln.rstrip()[:-1] + " "
            continue
        lines.append(cur + ln)
        cur = ""
    if cur:
        lines.append(cur)
    for ln in lines:
        try:
            lex = shlex.shlex(ln, posix=True, punctuation_chars=True)
            lex.whitespace_split = True
            toks = list(lex)
        except ValueError:
            continue
        seg = []
        segs = []
        for t in toks:
            if t and all(c in "();&|<>" for c in t):
                segs.append(seg); seg = []
            else:
                seg.append(t)
        segs.append(seg)
        for seg in segs:
            while seg and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[0]):
                seg = seg[1:]
            if seg and seg[0] == "make":
                targets = [t for t in seg[1:] if "=" not in t and not t.startswith("-")]
                vs = [t for t in seg[1:] if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t)]
                found.append((targets, vs))
    return found

dry_cache = {}
def dry_toolbox(targets, vs, env):
    key = (tuple(targets), tuple(vs), tuple(sorted(env.items())))
    if key in dry_cache:
        return dry_cache[key]
    e = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MAKELEVEL", "MFLAGS", "MAKEOVERRIDES")}
    e.update(env)
    cmd = ["make", "-n", "-B"] + targets + ["ISO=/x", "ISO_URL=", "GITHUB_OUTPUT=/dev/null"] + [v for v in vs if "${{" not in v]
    try:
        p = subprocess.run(cmd, cwd=root, env=e, capture_output=True, text=True, timeout=90)
        res = (p.returncode, "toolbox/run" in p.stdout, p.stderr.strip()[-200:])
    except Exception as ex:
        res = (99, False, str(ex))
    dry_cache[key] = res
    return res

class Entry:
    pass

def step_env(doc, job, step):
    env = {}
    for d in (doc.get("env"), job.get("env"), step.get("env")):
        if isinstance(d, dict):
            for k, v in d.items():
                if "${{" not in str(v):
                    env[str(k)] = str(v)
    return env

dry_errors = []
def analyse(doc, wf, jid, job, caller, caller_doc, caller_job):
    e = Entry()
    e.wf, e.jid, e.job, e.caller, e.doc = wf, jid, job, caller, doc
    e.caller_job, e.caller_doc = caller_job, caller_doc
    e.real = False
    e.save_idx = None
    e.targets = set()
    e.push = False
    steps = job.get("steps") or []
    for i, st in enumerate(steps):
        text = st.get("run")
        if not isinstance(text, str):
            continue
        for ln in text.splitlines():
            if not ln.lstrip().startswith("#") and re.search(r"toolbox/run\b[^\n]*--push", ln):
                e.push = True
        ms = makes(text)
        for targets, vs in ms:
            e.targets.update(targets)
            if "toolbox-save" in targets and e.save_idx is None:
                e.save_idx = i
            if "toolbox-publish" in targets:
                e.push = True
        # a run: that is not just toolbox-save/-load/-check
        direct = "toolbox/run" in "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
        if direct:
            e.real = True
        for targets, vs in ms:
            rest = [t for t in targets if t not in TOOLBOX_TARGETS]
            if not rest:
                continue
            rc, hit, err = dry_toolbox(rest, vs, step_env(doc, job, st))
            if rc != 0:
                dry_errors.append("%s %s: make -n %s failed: %s" % (wf, jid, " ".join(rest), err))
            if hit:
                e.real = True
    return e

def expand(wf, doc):
    ents = []
    for jid, job in (doc.get("jobs") or {}).items():
        uses = job.get("uses")
        if isinstance(uses, str) and uses.startswith("./.github/workflows/"):
            callee = os.path.basename(uses)
            cdoc = docs.get(callee)
            if cdoc is None:
                say(False, "%s: job %s calls %s, which exists" % (wf, jid, uses))
                continue
            for cjid, cjob in (cdoc.get("jobs") or {}).items():
                ents.append(analyse(cdoc, callee, cjid, cjob, jid, doc, job))
        else:
            ents.append(analyse(doc, wf, jid, job, None, None, None))
    return ents

roots = {wf: d for wf, d in docs.items() if set(triggers(d)) - {"workflow_call"}}
entries = {wf: expand(wf, d) for wf, d in roots.items()}
callers = {wf: d for wf, d in docs.items()}

def label(e):
    return e.jid if e.caller is None else "%s/%s" % (e.caller, e.jid)

for wf in sorted(entries):
    real = [label(e) for e in entries[wf] if e.real]
    print("INFO: %s: toolbox-running jobs: %s" % (wf, ", ".join(real) if real else "(none)"))
for msg in sorted(set(dry_errors)):
    print("INFO: dry run problem: " + msg)

# ---- AC-2: pr-validate.yml runs make toolbox-check with BASE
try:
    pv = docs.get("pr-validate.yml") or {}
    steps = ((pv.get("jobs") or {}).get("validate") or {}).get("steps") or []
    ci = [i for i, s in enumerate(steps) if "toolbox-check" in str(s.get("name", ""))]
    say(bool(ci), "F02-AC-2: pr-validate.yml validate has a step named toolbox-check")
    if ci:
        st = steps[ci[0]]
        runs = [t for t, _ in makes(st.get("run", "")) if "toolbox-check" in t]
        say(bool(runs), "F02-AC-2: that step runs make toolbox-check")
        base = str((st.get("env") or {}).get("BASE", "")).replace(" ", "")
        say(base == "${{github.event.pull_request.base.sha}}", "F02-AC-2: that step's env BASE is the pull request's base sha (got %r)" % base)
        later = [i for i, s in enumerate(steps) if i > ci[0] and re.search(r"test-lint|test-unit", str(s.get("run", "")))]
        say(bool(later), "F02-AC-2: the toolbox-check step comes before the test-lint/test-unit step")
    else:
        for m in ("that step runs make toolbox-check", "that step's env BASE is the pull request's base sha", "the toolbox-check step comes before the test-lint/test-unit step"):
            say(False, "F02-AC-2: " + m + " (no such step)")
except Exception:
    say(False, "F02-AC-2: pr-validate.yml checks crashed: " + traceback.format_exc().splitlines()[-1])

# ---- AC-3
def needs_of(j):
    return as_list(j.get("needs"))

multi = []
try:
    for wf in sorted(entries):
        ents = entries[wf]
        real = [e for e in ents if e.real]
        if len(real) < 2:
            continue
        multi.append(wf)
        saves = [e for e in ents if e.save_idx is not None]
        say(len(saves) == 1, "F02-AC-3: %s: exactly one job runs make toolbox-save (found %s)" % (wf, [label(e) for e in saves] or "none"))
        upname = None
        if len(saves) == 1:
            s = saves[0]
            steps = s.job.get("steps") or []
            ups = [st for st in steps[s.save_idx + 1:] if str(st.get("uses", "")).startswith("actions/upload-artifact@")]
            say(bool(ups), "F02-AC-3: %s: %s uploads an artifact after make toolbox-save" % (wf, label(s)))
            if ups:
                w = ups[0].get("with") or {}
                upname = str(w.get("name", "")).strip()
                ret = w.get("retention-days")
                try:
                    okret = ret is not None and 1 <= int(ret) <= 7
                except (TypeError, ValueError):
                    okret = False
                say(okret, "F02-AC-3: %s: the toolbox artifact has retention-days <= 7 (got %r)" % (wf, ret))
                say(bool(upname), "F02-AC-3: %s: the toolbox artifact has a name (%r)" % (wf, upname))
        bad_needs, bad_first, bad_dl, bad_name = [], [], [], []
        for e in real:
            if len(saves) == 1 and e is saves[0]:
                continue
            if len(saves) == 1:
                s = saves[0]
                if e.caller is None:
                    ok = s.caller is None and s.jid in needs_of(e.job)
                else:
                    ok = s.caller is None and s.jid in needs_of(e.caller_job)
            else:
                ok = False
            if not ok:
                bad_needs.append(label(e))
            steps = e.job.get("steps") or []
            first = next((i for i, st in enumerate(steps) if "run" in st), None)
            okfirst = False
            if first is not None:
                ms = makes(steps[first]["run"])
                okfirst = len(ms) == 1 and ms[0][0] == ["toolbox-load"] and len(steps[first]["run"].strip().splitlines()) == 1
            if not okfirst:
                bad_first.append(label(e))
            dls = [i for i, st in enumerate(steps) if str(st.get("uses", "")).startswith("actions/download-artifact@") and (first is None or i < first)]
            if not dls or first is None:
                bad_dl.append(label(e))
            elif upname is not None and not any(str((steps[i].get("with") or {}).get("name", "")).strip() == upname for i in dls):
                bad_name.append(label(e))
        say(not bad_needs, "F02-AC-3: %s: every other toolbox-running job needs the toolbox job (lacking: %s)" % (wf, ", ".join(bad_needs) or "none"))
        say(not bad_first, "F02-AC-3: %s: every other toolbox-running job's first run: step is make toolbox-load (lacking: %s)" % (wf, ", ".join(bad_first) or "none"))
        say(not bad_dl, "F02-AC-3: %s: ... preceded by an actions/download-artifact step (lacking: %s)" % (wf, ", ".join(bad_dl) or "none"))
        say(not bad_name and len(saves) == 1, "F02-AC-3: %s: ... of the artifact that was uploaded (name mismatch: %s)" % (wf, ", ".join(bad_name) or "none"))
    for wf in ("build.yml", "boot-test-rc1.yml", "artifact-checks-rc1.yml", "sbom-gates-rc1.yml", "boot-test-repeat.yml"):
        say(wf in multi, "F02-AC-3: %s is among the workflows that run the toolbox in more than one job" % wf)
    for e in [e for es in entries.values() for e in es if e.real is False and e.save_idx is None]:
        pass
except Exception:
    say(False, "F02-AC-3: checks crashed: " + traceback.format_exc().splitlines()[-1])

# ---- AC-4
try:
    pushers = []
    for wf, d in docs.items():
        if wf == "toolbox-image.yml":
            continue
        for jid, job in (d.get("jobs") or {}).items():
            e = analyse(d, wf, jid, job, None, None, None) if job.get("steps") else None
            if e is not None and e.push:
                pushers.append("%s:%s" % (wf, jid))
    say(not pushers, "F02-AC-4: no workflow but toolbox-image.yml runs make toolbox-publish or toolbox/run --push (found: %s)" % (", ".join(pushers) or "none"))
    ti = docs.get("toolbox-image.yml")
    say(ti is not None, "F02-AC-4: toolbox-image.yml exists")
    if ti is not None:
        tr = triggers(ti)
        say(set(tr) == {"push", "workflow_dispatch"}, "F02-AC-4: toolbox-image.yml triggers are exactly push and workflow_dispatch (got %s)" % sorted(map(str, tr)))
        push = tr.get("push") or {}
        say(as_list(push.get("branches")) == ["main"] and set(push) <= {"branches", "paths"}, "F02-AC-4: toolbox-image.yml's push trigger is branches [main] only (got %s)" % push)
    def perm(p):
        if p is None:
            return None
        if isinstance(p, str):
            return p == "write-all"
        return p.get("packages") == "write"
    wrote = []
    for wf, d in docs.items():
        if not ({"pull_request", "pull_request_target"} & set(triggers(d))):
            continue
        if wf not in entries:
            continue
        for e in entries[wf]:
            if not (e.targets & TOOLBOX_TARGETS):
                continue
            own = perm(e.job.get("permissions"))
            if own is None:
                own = perm(e.doc.get("permissions"))
            if e.caller is not None:
                up = perm(e.caller_job.get("permissions"))
                if up is None:
                    up = perm(e.caller_doc.get("permissions"))
                own = up if own is None else (own and bool(up))
            if own:
                if "cache-push" in e.targets:
                    print("INFO: %s %s holds packages: write for make cache-push (exempt)" % (wf, label(e)))
                else:
                    wrote.append("%s:%s" % (wf, label(e)))
    say(not wrote, "F02-AC-4: no pull_request workflow grants packages: write to a job running toolbox-save/-load/-check (found: %s)" % (", ".join(wrote) or "none"))
    wrote2 = []
    for wf, d in docs.items():
        if not ({"pull_request", "pull_request_target"} & set(triggers(d))):
            continue
        if wf not in entries:
            continue
        for e in entries[wf]:
            if not (e.targets & {"toolbox-save", "toolbox-check"}):
                continue
            own = perm(e.job.get("permissions"))
            if own is None:
                own = perm(e.doc.get("permissions"))
            if e.caller is not None:
                up = perm(e.caller_job.get("permissions"))
                if up is None:
                    up = perm(e.caller_doc.get("permissions"))
                own = up if own is None else (own and bool(up))
            if own:
                wrote2.append("%s:%s" % (wf, label(e)))
    say(not wrote2, "F02-AC-4: no pull_request workflow grants packages: write to a job running toolbox-save/-check, even with make cache-push (found: %s)" % (", ".join(wrote2) or "none"))
except Exception:
    say(False, "F02-AC-4: checks crashed: " + traceback.format_exc().splitlines()[-1])

print("RESULT: %d failure(s)" % nfail)
PYEOF
)
printf '%s\n' "$out" | grep -v '^RESULT:'
if printf '%s\n' "$out" | grep -q '^FAIL:'; then
	exit 1
fi
if ! printf '%s\n' "$out" | grep -q '^RESULT: 0 failure'; then
	echo "FAIL: the workflow checks did not run to their end"
	exit 1
fi
exit 0
