#!/bin/sh
# P01 slice 2: the release workflows, static checks (node spec changes 1, 2, 4, 5, 7, 9, 10, 11).
#   P01-AC-1   release.yml has no AWS or S3 names and takes its files from the Build run's artifacts
#   P01-AC-2   build.yml uses actions/attest-build-provenance and actions/attest-sbom (SHA-pinned), neither
#              actions/attest@ nor generate-provenance.py; the release notes name --repo and --signer-workflow, never
#              --owner (the run halves (a) and (b) are recorded runs; (b) needs the job checked at the end)
#   P01-AC-4   `needs:` in build.yml; release.yml's workflow_run `conclusion == success`; the distfiles push before
#              `gh release create` (the throwaway -test tag is a recorded run)
#   P01-AC-9   permissions per change 10; a hyphenated tag is a prerelease and not Latest
#   P01-AC-10  (static half) the assets the publish step uploads, and that SHA256SUMS lists them
#   P01-AC-12  the boot-test modes, the attestation job's needs, and a `make test-overlay` job it needs
#
# Runs in the toolbox and in commit-less copies (no Git history, no network, no out/). YAML is parsed with PyYAML as
# boot-test-workflow.test.sh does. The tests read steps as TEXT: a step's text is its run:/with:/env: plus, for each
# `make <target>` in it, the `make -n <target>` expansion, plus the content of every scripts/<file> that text names.
# So a command may live in the workflow, a Make recipe or a script; the test does not care which.
#
# Interfaces chosen here (the implementer follows them):
#   build.yml, job `attestation` (steps in this order; "before" means an earlier step of this job):
#     - steps running `make test-artifact` and `make test-gates` (existing), `make release-package-set` (change 6),
#       `make check-cyclonedx` (change 11), `make size-report` (change 8, on EVERY build: no tag condition),
#       `make rc1-diff` (text names rc1-diff.md), `make allowlist-report` (text names dynamic-allowlist.txt), and a
#       step that writes SHA256SUMS (text has sha256sum and SHA256SUMS and names the ISO (.iso), bom.cdx.json,
#       release-inputs.json, source-audit.tsv, rootfs-provenance.tsv, rc1-diff.md, sizes.md, dynamic-allowlist.txt),
#       all before the first attest step. size-report's text names sizes.md.
#     - then actions/attest-build-provenance@<40-hex sha> and actions/attest-sbom@<40-hex sha>, both with
#       `if:` containing github.ref_type == 'tag'; the ISO is their only subject: with.subject-path is one path
#       ending .iso (no glob, no second line), and no subject-checksums; attest-sbom has with.sbom-path ending
#       bom.cdx.json.
#     - permissions: id-token write, attestations write, contents read, packages not write (packages: read may stay).
#     - `needs` (closure) include compare, boot-test and a job that runs `make test-overlay` with no tag exclusion
#       in its `if:`; the attestation `if:` requires that job's result == 'success' in every alternative.
#   build.yml, job `compare`: an upload-artifact step whose path ends compare.log and whose name contains
#       "compare"; `make -n compare` names that path (Make variable COMPARE_LOG, default output/compare.log).
#   build.yml, job `boot-test`: with.modes lists exactly the 20 modes of boot-test-workflow.test.sh (the 17 boot modes
#       plus persist-init, entry, smoke).
#   release.yml: on workflow_run [Build] completed; one job `publish` with `if:` containing
#       github.event.workflow_run.conclusion == 'success'; permissions workflow-level contents write + actions read,
#       and packages write on `publish`; download-artifact steps with run-id (github.event.workflow_run.id) and
#       github-token whose names (run id substituted) are names build.yml uploads; steps in this order:
#       downloads, `make release-digest-chain`, the distfiles push (text has `oras push`, distfiles, REGISTRY and
#       DISTFILES_DIGEST), `gh release create` (text has --prerelease, --latest=false and the hyphen test *-*, and
#       lists the 9 assets). Neither `oras push` nor `gh release create` is in any other job of either workflow.
#       The release notes name `--repo "$GITHUB_REPOSITORY"` (or the literal repository) and --signer-workflow
#       .../.github/workflows/build.yml, and never --owner.
#   A workflow that triggers on pull_request has a job whose step runs `make verify-rc1-attestation` (P01-AC-2(b)),
#   with GH_TOKEN or GITHUB_TOKEN in env and no label condition in its `if:`.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is not available in this harness"; exit 1; }

python3 -I - "$ROOT" <<'PY'
import fnmatch
import os
import re
import subprocess
import sys

import yaml

ROOT = sys.argv[1]
WF = os.path.join(ROOT, ".github", "workflows")
bad = 0


def case(label, fn):
    global bad
    try:
        ok, why = fn()
    except Exception as e:  # a missing subject is a FAIL, never a crash
        ok, why = False, "%s: %s" % (type(e).__name__, e)
    if ok:
        print("PASS: " + label)
    else:
        print("FAIL: %s (%s)" % (label, why))
        bad += 1


def load(name):
    p = os.path.join(WF, name)
    if not os.path.isfile(p):
        raise FileNotFoundError(".github/workflows/" + name + " does not exist")
    text = open(p).read()
    doc = yaml.safe_load(text)
    if True in doc:
        doc["on"] = doc.pop(True)
    return doc, text


def jobs_of(doc):
    return doc.get("jobs") or {}


def steps_of(job):
    return job.get("steps") or []


def as_list(x):
    if x is None:
        return []
    return list(x) if isinstance(x, list) else [x]


def closure(jobs, name):
    seen, todo = set(), as_list((jobs.get(name) or {}).get("needs"))
    while todo:
        n = todo.pop()
        if n not in seen:
            seen.add(n)
            todo += as_list((jobs.get(n) or {}).get("needs"))
    return seen


_make_cache = {}


def make_n(target):
    if target not in _make_cache:
        env = {k: v for k, v in os.environ.items() if not k.startswith("MAKE")}
        env.setdefault("GITHUB_REPOSITORY", "tuckermclean/themonolith")
        try:
            r = subprocess.run(["make", "-n", target], cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
            _make_cache[target] = r.stdout if r.returncode == 0 else ""
        except Exception:
            _make_cache[target] = ""
    return _make_cache[target]


def scripts_text(text):
    out = []
    for m in sorted(set(re.findall(r"scripts/[A-Za-z0-9_.-]+\.(?:sh|py)", text))):
        p = os.path.join(ROOT, m)
        if os.path.isfile(p):
            out.append(open(p, errors="replace").read())
    return "\n".join(out)


def step_text(step):
    parts = [str(step.get("run", "")), str(step.get("uses", "")), repr(step.get("with") or {}), repr(step.get("env") or {})]
    run = str(step.get("run", ""))
    for line in re.sub(r"\\\n", " ", run).splitlines():
        m = re.search(r"\bmake\s+(.*)", line)
        if m:
            for tok in m.group(1).split():
                if re.fullmatch(r"[A-Za-z0-9_.-]+", tok) and not tok.startswith("-"):
                    parts.append(make_n(tok))
    t = "\n".join(parts)
    return t + "\n" + scripts_text(t)


def runs_make(step, target):
    return re.search(r"\bmake\b[^\n]*\b" + re.escape(target) + r"\b", str(step.get("run", ""))) is not None


def find_step(job, pred, start=0):
    for i, s in enumerate(steps_of(job)):
        if i >= start and pred(s):
            return i
    return -1


def last_step(job, pred):
    r = -1
    for i, s in enumerate(steps_of(job)):
        if pred(s):
            r = i
    return r


def is_attest(s):
    return str(s.get("uses", "")).startswith(("actions/attest-build-provenance@", "actions/attest-sbom@"))


def perm(p, k):
    if p == "write-all":
        return "write"
    return (p or {}).get(k) if isinstance(p, dict) else None


PIN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")

try:
    B, BTEXT = load("build.yml")
except Exception as e:
    B, BTEXT = None, ""
    print("FAIL: build.yml loads (%s)" % e)
    bad += 1
try:
    R, RTEXT = load("release.yml")
except Exception as e:
    R, RTEXT = None, ""


def need(doc, name):
    if doc is None:
        raise FileNotFoundError(name + " is missing")
    return doc


def bjobs():
    return jobs_of(need(B, "build.yml"))


def rjobs():
    return jobs_of(need(R, "release.yml"))


def att():
    j = bjobs().get("attestation")
    if j is None:
        raise KeyError("build.yml has no attestation job")
    return j


def pub():
    j = rjobs().get("publish")
    if j is None:
        raise KeyError("release.yml has no publish job")
    return j


# ---------------------------------------------------------------- P01-AC-1
def r_exists():
    need(R, "release.yml")
    return True, ""


def r_noaws():
    t = need(R, "release.yml") and RTEXT.lower()
    hits = [w for w in ("aws", "s3", "s3_bucket") if w in t]
    return (not hits), "release.yml contains: " + ", ".join(hits)


def r_trigger():
    on = need(R, "release.yml").get("on") or {}
    wr = on.get("workflow_run") if isinstance(on, dict) else None
    ok = bool(wr) and as_list(wr.get("workflows")) == ["Build"] and as_list(wr.get("types")) == ["completed"]
    return ok, "on: workflow_run workflows [Build] types [completed] expected, got %r" % (wr,)


def dl_steps():
    return [s for s in steps_of(pub()) if str(s.get("uses", "")).startswith("actions/download-artifact@")]


def r_downloads():
    ds = dl_steps()
    if not ds:
        return False, "the publish job has no download-artifact step"
    bad_ = []
    for s in ds:
        w = s.get("with") or {}
        if "github.event.workflow_run.id" not in str(w.get("run-id", "")):
            bad_.append("run-id of %r" % (w.get("name") or w.get("pattern")))
        if not w.get("github-token"):
            bad_.append("github-token of %r" % (w.get("name") or w.get("pattern")))
    return (not bad_), "; ".join(bad_)


def norm(n):
    return re.sub(r"\$\{\{\s*(github\.run_id|github\.event\.workflow_run\.id)\s*\}\}", "<RUN>", str(n))


def uploaded_names():
    names = []
    for j in bjobs().values():
        for s in steps_of(j):
            if str(s.get("uses", "")).startswith("actions/upload-artifact@"):
                names.append(norm((s.get("with") or {}).get("name", "")))
    return names


def dl_names():
    return [norm((s.get("with") or {}).get("name") or (s.get("with") or {}).get("pattern") or "") for s in dl_steps()]


def r_names_exist():
    up, miss = uploaded_names(), []
    for n in dl_names():
        if not n or not any(fnmatch.fnmatch(u, n) or u == n for u in up):
            miss.append(n or "(no name)")
    return (not miss and bool(dl_names())), "downloaded but not uploaded by build.yml: %s" % miss


def r_names_cover():
    ns = dl_names()
    want = {"the ISO": r"\biso\b", "release-inputs.json": r"release-inputs", "the distfiles archive": r"distfiles",
            "source-audit.tsv": r"source-audit", "the compare log": r"compare",
            "the SBOM and reports": r"attestation|release-assets|sbom"}
    miss = [k for k, rx in want.items() if not any(re.search(rx, n) for n in ns)]
    return (not miss), "no download for: " + ", ".join(miss)


case("P01-AC-1 .github/workflows/release.yml exists", r_exists)
case("P01-AC-1 release.yml has no AWS or S3 names", r_noaws)
case("P01-AC-1 release.yml triggers on workflow_run of Build, completed (carried)", r_trigger)
case("P01-AC-1 release.yml downloads with run-id of the Build run and a github-token", r_downloads)
case("P01-AC-1 every artifact release.yml downloads is one build.yml uploads", r_names_exist)
case("P01-AC-1 the downloads cover ISO, release-inputs, distfiles, source-audit, compare log, SBOM and reports", r_names_cover)


def r_pinned():
    uses = [s["uses"] for j in rjobs().values() for s in steps_of(j) if "uses" in s]
    un = [u for u in uses if not (u.startswith("./") or PIN.match(u))]
    return (bool(uses) and not un), "unpinned or no uses: %s" % un


case("P01-AC-1 every uses: in release.yml is a full commit SHA", r_pinned)


def r_carried():
    ok = ("refs/tags/" in RTEXT and "head_sha" in RTEXT and re.search(r"git describe --tags --abbrev=0", RTEXT))
    return bool(ok), "the tag-to-commit check (refs/tags, workflow_run.head_sha) and the previous-tag changelog are not carried"


case("P01-AC-1 the tag-to-commit check and previous-tag changelog are carried", r_carried)


# ---------------------------------------------------------------- P01-AC-4 (release.yml) / AC-12 (release.yml)
def r_if():
    j = pub()
    c = str(j.get("if", ""))
    ok = "github.event.workflow_run.conclusion == 'success'" in c and not re.search(r"always\(\)|failure\(\)|cancelled\(\)", c)
    ss = [s for s in steps_of(j) if re.search(r"always\(\)|failure\(\)", str(s.get("if", "")))]
    return (ok and not ss), "publish if: %r; steps with always()/failure(): %d" % (c, len(ss))


case("P01-AC-4 P01-AC-12 publish runs only for a Build run whose conclusion is success (no always/failure)", r_if)


def idx_chain():
    ss = steps_of(pub())
    last_dl = last_step(pub(), lambda s: str(s.get("uses", "")).startswith("actions/download-artifact@"))
    dc = find_step(pub(), lambda s: runs_make(s, "release-digest-chain"))
    push = find_step(pub(), lambda s: "oras push" in step_text(s))
    rel = find_step(pub(), lambda s: "gh release create" in step_text(s))
    return ss, last_dl, dc, push, rel


def r_order():
    ss, last_dl, dc, push, rel = idx_chain()
    miss = [n for n, i in (("download-artifact", last_dl), ("make release-digest-chain", dc), ("oras push", push), ("gh release create", rel)) if i < 0]
    if miss:
        return False, "publish has no step for: " + ", ".join(miss)
    return (last_dl < dc < push < rel), "step indices: downloads %d, digest chain %d, oras push %d, gh release create %d" % (last_dl, dc, push, rel)


case("P01-AC-4 publish order: downloads, digest chain (make release-digest-chain), oras push, gh release create", r_order)


def r_push():
    _, _, _, push, _ = idx_chain()
    if push < 0:
        return False, "no oras push step in publish"
    t = step_text(steps_of(pub())[push])
    miss = [k for k in ("distfiles", "REGISTRY", "DISTFILES_DIGEST") if k not in t]
    return (not miss), "the push step's text lacks: " + ", ".join(miss)


case("P01-AC-4 the distfiles push targets ${REGISTRY}/distfiles and checks DISTFILES_DIGEST", r_push)


def r_only_publish():
    offenders = []
    for nm, doc in (("release.yml", R), ("build.yml", B)):
        for jn, j in jobs_of(need(doc, nm)).items():
            if nm == "release.yml" and jn == "publish":
                continue
            for s in steps_of(j):
                t = step_text(s)
                if re.search(r"\bgh release create\b", t):
                    offenders.append("%s:%s" % (nm, jn))
                elif re.search(r"\boras push\b", t):
                    # exemption: the B01 binary package cache (scripts/binpkg-store.sh, not distfiles)
                    if "scripts/binpkg-store.sh" in t and "distfiles" not in t:
                        continue
                    offenders.append("%s:%s" % (nm, jn))
    return (not offenders), "oras push or gh release create outside publish (binary package cache steps exempt): %s" % sorted(set(offenders))


case("P01-AC-4 oras push and gh release create appear only in release.yml's publish job (binary package cache steps exempt)", r_only_publish)


# ---------------------------------------------------------------- P01-AC-9
def r_perm_release():
    d = need(R, "release.yml")
    wp = d.get("permissions")
    jp = pub().get("permissions")
    eff = jp if jp is not None else wp
    wf_ok = isinstance(wp, dict) and wp.get("contents") == "write" and wp.get("actions") == "read" \
        and perm(wp, "packages") != "write" and not perm(wp, "id-token") and not perm(wp, "attestations")
    pj_ok = isinstance(jp, dict) and jp.get("packages") == "write" and jp.get("contents") == "write" and jp.get("actions") == "read"
    others = [k for k in (eff or {}) if k not in ("contents", "actions", "packages")]
    return (wf_ok and pj_ok and not others), "workflow permissions %r, publish permissions %r" % (wp, jp)


def r_perm_other_jobs():
    bad_ = [n for n, j in rjobs().items() if n != "publish" and (perm(j.get("permissions"), "packages") == "write")]
    return (not bad_), "jobs other than publish with packages: write: %s" % bad_


def r_perm_att():
    p = att().get("permissions")
    ok = isinstance(p, dict) and p.get("id-token") == "write" and p.get("attestations") == "write" and p.get("contents") == "read" \
        and p.get("packages") != "write"
    return ok, "attestation permissions %r" % (p,)


case("P01-AC-9 release.yml permissions: contents write, actions read; packages write on publish only (change 10)", r_perm_release)
case("P01-AC-9 no release.yml job other than publish has packages: write", r_perm_other_jobs)
case("P01-AC-9 build.yml attestation permissions: id-token write, attestations write, contents read, no packages write", r_perm_att)


def r_prerelease():
    _, _, _, _, rel = idx_chain()
    if rel < 0:
        return False, "no gh release create step in publish"
    t = step_text(steps_of(pub())[rel])
    miss = [k for k, rx in (("--prerelease", r"--prerelease"), ("--latest=false", r"--latest=false"), ("the hyphen test *-*", r"\*-\*")) if not re.search(rx, t)]
    return (not miss), "the release step's text lacks: " + ", ".join(miss)


case("P01-AC-9 a hyphenated tag is created with --prerelease --latest=false (carried rule)", r_prerelease)


# ---------------------------------------------------------------- P01-AC-10 (static)
ASSETS = ["bom.cdx.json", "SHA256SUMS", "release-inputs.json", "source-audit.tsv", "rootfs-provenance.tsv",
          "rc1-diff.md", "sizes.md", "dynamic-allowlist.txt"]
SUMMED = ASSETS[:1] + ASSETS[2:]


def r_assets():
    _, _, _, _, rel = idx_chain()
    if rel < 0:
        return False, "no gh release create step in publish"
    t = step_text(steps_of(pub())[rel])
    miss = [a for a in ASSETS if a not in t]
    if not re.search(r"\.iso\b", t):
        miss.append("the ISO (*.iso)")
    return (not miss), "the release step does not upload: " + ", ".join(miss)


def r_sums():
    a = att()
    first = find_step(a, is_attest)
    i = find_step(a, lambda s: "SHA256SUMS" in step_text(s) and "sha256sum" in step_text(s))
    if i < 0:
        return False, "no attestation step writes SHA256SUMS"
    if first >= 0 and i > first:
        return False, "SHA256SUMS is written after signing (step %d, first attest step %d)" % (i, first)
    t = step_text(steps_of(a)[i])
    miss = [x for x in SUMMED if x not in t]
    if not re.search(r"\.iso\b", t):
        miss.append("the ISO (*.iso)")
    return (not miss), "the SHA256SUMS step does not name: " + ", ".join(miss)


case("P01-AC-10 the release step uploads the ISO, SBOM, SHA256SUMS, release-inputs.json, source-audit.tsv, rootfs-provenance.tsv and the three reports", r_assets)
case("P01-AC-10 SHA256SUMS is written once in the attestation job, before signing, over all assets but itself", r_sums)


# ---------------------------------------------------------------- P01-AC-2 (static)
def b_attest_uses():
    a = att()
    us = [s.get("uses", "") for s in steps_of(a)]
    miss = [p for p in ("actions/attest-build-provenance@", "actions/attest-sbom@") if not any(u.startswith(p) and PIN.match(u.split()[0]) for u in us)]
    return (not miss), "attestation job lacks SHA-pinned: " + ", ".join(miss)


def b_no_old():
    t = need(B, "build.yml") and BTEXT
    hits = [x for x in ("actions/attest@", "generate-provenance.py") if x in t]
    return (not hits), "build.yml contains: " + ", ".join(hits)


def _subject_ok(w):
    sp = str(w.get("subject-path", "")).strip()
    lines = [x.strip() for x in sp.splitlines() if x.strip()]
    return (len(lines) == 1 and lines[0].endswith(".iso") and "*" not in lines[0] and not w.get("subject-checksums")
            and not w.get("subject-digest")), repr(sp)


def b_subject_prov():
    a = att()
    i = find_step(a, lambda s: str(s.get("uses", "")).startswith("actions/attest-build-provenance@"))
    if i < 0:
        return False, "no actions/attest-build-provenance step"
    ok, sp = _subject_ok(steps_of(a)[i].get("with") or {})
    return ok, "subject-path must be the ISO alone, got " + sp


def b_subject_sbom():
    a = att()
    i = find_step(a, lambda s: str(s.get("uses", "")).startswith("actions/attest-sbom@"))
    if i < 0:
        return False, "no actions/attest-sbom step"
    w = steps_of(a)[i].get("with") or {}
    ok, sp = _subject_ok(w)
    sb = str(w.get("sbom-path", "")).strip()
    return (ok and sb.endswith("bom.cdx.json")), "subject-path %s, sbom-path %r" % (sp, sb)


def b_same_iso():
    a = att()
    paths = [str((s.get("with") or {}).get("subject-path", "")).strip() for s in steps_of(a) if is_attest(s)]
    return (len(paths) == 2 and paths[0] == paths[1]), "subject-path of the two steps: %r" % paths


def b_tag_guard():
    a = att()
    ss = [s for s in steps_of(a) if is_attest(s)]
    bad_ = [s.get("uses") for s in ss if not re.search(r"github\.ref_type\s*==\s*'tag'", str(s.get("if", "")))]
    return (len(ss) == 2 and not bad_), "attest steps without a tag condition: %s (found %d steps)" % (bad_, len(ss))


case("P01-AC-2 build.yml's attestation job uses SHA-pinned actions/attest-build-provenance and actions/attest-sbom", b_attest_uses)
case("P01-AC-2 build.yml has neither actions/attest@ nor generate-provenance.py", b_no_old)
case("P01-AC-2 attest-build-provenance has the ISO as its only subject", b_subject_prov)
case("P01-AC-2 attest-sbom has the ISO as its only subject and bom.cdx.json as its sbom-path", b_subject_sbom)
case("P01-AC-2 both attest steps sign the same ISO path", b_same_iso)
case("P01-AC-2 both attest steps run on a tag only (if: github.ref_type == 'tag')", b_tag_guard)


def r_notes():
    t = RTEXT + "\n" + "\n".join(step_text(s) for s in steps_of(pub()))
    t += "\n" + scripts_text(t)
    miss = []
    if not re.search(r"gh attestation verify", t):
        miss.append("gh attestation verify")
    if not re.search(r"--repo[ =]\\*\"?(\$\{?GITHUB_REPOSITORY\}?|tuckermclean/themonolith)", t):
        miss.append('--repo "$GITHUB_REPOSITORY"')
    if not re.search(r"--signer-workflow[ =]\\*\"?[^\s\"]*/\.github/workflows/build\.yml", t):
        miss.append("--signer-workflow .../.github/workflows/build.yml")
    bad_ = []
    if "--owner" in t:
        bad_.append("--owner")
    if "linux-live-iso-factory" in t:
        bad_.append("the predecessor repository")
    return (not miss and not bad_), "missing: %s; present but forbidden: %s" % (miss, bad_)


case("P01-AC-2 the release notes print gh attestation verify with --repo and --signer-workflow, never --owner", r_notes)


def pr_job():
    for fn in sorted(os.listdir(WF)):
        if not fn.endswith(".yml"):
            continue
        d, _ = load(fn)
        on = d.get("on") or {}
        if not (isinstance(on, dict) and "pull_request" in on) and on != "pull_request" and not (isinstance(on, list) and "pull_request" in on):
            continue
        for jn, j in jobs_of(d).items():
            if "uses" in j:
                continue
            for s in steps_of(j):
                if runs_make(s, "verify-rc1-attestation"):
                    env = {}
                    env.update(d.get("env") or {})
                    env.update(j.get("env") or {})
                    env.update(s.get("env") or {})
                    tok = any(k in env for k in ("GH_TOKEN", "GITHUB_TOKEN"))
                    lbl = re.search(r"labels|full-ci", str(j.get("if", "")))
                    return (tok and not lbl), "%s:%s token in env: %s, label condition: %s" % (fn, jn, tok, bool(lbl))
    return False, "no workflow triggered by pull_request has a step running make verify-rc1-attestation"


case("P01-AC-2 (b) a pull_request workflow runs make verify-rc1-attestation with a token and no label gate", pr_job)

# ---------------------------------------------------------------- P01-AC-4 / AC-12 (build.yml)
EXPECT_MODES = "bios uefi toram ahci nvme usb virtio nicless nic vga fbdev-modprobe nat gui stele-acid2 clock-epoch clock-1996 persist persist-init entry serial-net smoke".split()


def b_modes():
    j = bjobs().get("boot-test")
    if j is None:
        return False, "no boot-test job"
    modes = str((j.get("with") or {}).get("modes", "")).split()
    miss = sorted(set(EXPECT_MODES) - set(modes))
    return (not miss), "boot-test modes lack: " + ", ".join(miss)


def b_entry_legs():
    try:
        d, _ = load("boot-test.yml")
    except Exception as e:
        return False, str(e)
    e = jobs_of(d).get("entry") or {}
    m = ((e.get("strategy") or {}).get("matrix")) or {}
    ok = bool(m) and any(runs_make(s, "test-boot") and "MODE=entry" in str(s.get("run", "")) for s in steps_of(e))
    return ok, "boot-test.yml's entry job needs a matrix of legs and `make test-boot MODE=entry`"


def overlay_job():
    for n, j in bjobs().items():
        if any(runs_make(s, "test-overlay") for s in steps_of(j)):
            return n, j
    return None, None


def b_overlay():
    n, j = overlay_job()
    if n is None:
        return False, "no build.yml job runs make test-overlay"
    cl = closure(bjobs(), "attestation")
    probs = []
    if n not in cl:
        probs.append("%s is not in the attestation job's needs closure" % n)
    c = str(j.get("if", ""))
    if re.search(r"ref_type\s*!=\s*'tag'", c) or re.search(r"ref_type\s*==\s*'(?!tag')", c):
        probs.append("%s excludes tags" % n)
    if any(s.get("with", {}).get("ref") for s in steps_of(j) if str(s.get("uses", "")).startswith("actions/checkout@")):
        probs.append("%s checks out another ref than the tagged commit" % n)
    ifc = str(att().get("if", ""))
    alts = [x for x in ifc.split("||") if x.strip()]
    if not alts or any("needs.%s.result == 'success'" % n not in x for x in alts):
        probs.append("the attestation if: does not require needs.%s.result == 'success' in every alternative" % n)
    return (not probs), "; ".join(probs)


def b_needs():
    cl = closure(bjobs(), "attestation")
    miss = [n for n in ("compare", "boot-test") if n not in cl]
    ok_if = "needs.compare.result == 'success'" in str(att().get("if", "")) and "needs.boot-test.result == 'success'" in str(att().get("if", ""))
    return (not miss and ok_if), "attestation needs closure lacks %s; if: requires compare and boot-test success: %s" % (miss, ok_if)


def b_before():
    a = att()
    first = find_step(a, is_attest)
    if first < 0:
        return False, "no attest step"
    want = [("make test-artifact", lambda s: runs_make(s, "test-artifact")),
            ("make test-gates", lambda s: runs_make(s, "test-gates")),
            ("make release-package-set", lambda s: runs_make(s, "release-package-set")),
            ("make check-cyclonedx", lambda s: runs_make(s, "check-cyclonedx")),
            ("make size-report", lambda s: runs_make(s, "size-report")),
            ("make rc1-diff", lambda s: runs_make(s, "rc1-diff")),
            ("make allowlist-report", lambda s: runs_make(s, "allowlist-report"))]
    probs = []
    for label, p in want:
        i = last_step(a, p)
        if i < 0:
            probs.append(label + " is not a step of the attestation job")
        elif i > first:
            probs.append(label + " runs after signing")
    return (not probs), "; ".join(probs)


def b_sizes_every_build():
    a = att()
    ss = [s for s in steps_of(a) if runs_make(s, "size-report")]
    if not ss:
        return False, "no make size-report step in the attestation job"
    tagonly = [s for s in ss if "tag" in str(s.get("if", "")) or "always()" in str(s.get("if", ""))]
    named = any("sizes.md" in step_text(s) for s in ss)
    return (not tagonly and named), "size-report steps with a tag condition: %d; text names sizes.md: %s" % (len(tagonly), named)


def b_reports_named():
    a = att()
    probs = []
    for tgt, name in (("rc1-diff", "rc1-diff.md"), ("allowlist-report", "dynamic-allowlist.txt")):
        ss = [s for s in steps_of(a) if runs_make(s, tgt)]
        if not ss or not any(name in step_text(s) for s in ss):
            probs.append("make %s does not write %s" % (tgt, name))
    return (not probs), "; ".join(probs)


def b_cdx_before_sbom():
    a = att()
    i = last_step(a, lambda s: runs_make(s, "check-cyclonedx"))
    j = find_step(a, lambda s: str(s.get("uses", "")).startswith("actions/attest-sbom@"))
    return (0 <= i < j), "check-cyclonedx step %d, attest-sbom step %d" % (i, j)


def b_compare_log():
    j = bjobs().get("compare")
    if j is None:
        return False, "no compare job"
    ups = [s for s in steps_of(j) if str(s.get("uses", "")).startswith("actions/upload-artifact@")
           and str((s.get("with") or {}).get("path", "")).strip().endswith("compare.log")]
    if not ups:
        return False, "the compare job uploads no compare.log"
    w = ups[0].get("with") or {}
    path = str(w.get("path")).strip()
    probs = []
    if "compare" not in str(w.get("name", "")):
        probs.append("artifact name lacks 'compare'")
    if w.get("if-no-files-found") != "error":
        probs.append("if-no-files-found is not error")
    if path not in make_n("compare"):
        probs.append("make -n compare does not name %s" % path)
    return (not probs), "; ".join(probs)


def b_no_publish_in_build():
    return r_only_publish()


case("P01-AC-12 build.yml's boot-test job runs the 17 boot modes plus persist-init, entry and smoke", b_modes)
case("P01-AC-12 boot-test.yml's entry job has a leg matrix and runs make test-boot MODE=entry", b_entry_legs)
case("P01-AC-12 a job running make test-overlay is in the attestation job's needs, on the tag path, and its success is required", b_overlay)
case("P01-AC-4 the attestation job needs compare and boot-test and its if: requires their success", b_needs)
case("P01-AC-4 artifact checks, gates, package set, schema check, size, rc1-diff and allowlist report run before signing", b_before)
case("P01-AC-8 make size-report runs on every build (no tag condition) and writes sizes.md", b_sizes_every_build)
case("P01-AC-7 make rc1-diff writes rc1-diff.md and make allowlist-report writes dynamic-allowlist.txt", b_reports_named)
case("P01-AC-2 the CycloneDX schema check runs before attest-sbom (change 11)", b_cdx_before_sbom)
case("P01-AC-6 the compare job uploads the compare log that make compare writes", b_compare_log)


def lint():
    r = subprocess.run(["python3", "-I", os.path.join(ROOT, "toolbox", "ci"), "lint", "release.yml", "build.yml"], cwd=ROOT,
                       capture_output=True, text=True, timeout=120)
    return (r.returncode == 0), "toolbox/ci lint: " + (r.stdout + r.stderr).strip().replace("\n", " | ")[:300]


case("P01-AC-1 toolbox/ci lint passes release.yml and build.yml (workflows call only make or toolbox/run)", lint)

print("release-workflow: %d failure(s)" % bad)
sys.exit(1 if bad else 0)
PY
