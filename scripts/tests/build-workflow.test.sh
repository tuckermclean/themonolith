#!/bin/sh
# B03 build-workflow checks. Works in a commit-less copy (no git history).
# Later cases are appended above the final summary.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
check() { # check <label> <command...>
  _l=$1; shift
  if "$@"; then pass "$_l"; else fail "$_l"; fi
}

# --- B03-AC-8: build-rootfs.sh has no vendor-host string; HOME_URL matches advisory default
RFS="$ROOT/scripts/build-rootfs.sh"
ADV="$ROOT/configs/overlay/app-misc/monolith-base/files/monolith-advisory-check"

# Needle built from pieces so this file never contains the whole string.
_a=amazon
needle="${_a}aws"

check "B03-AC-8: scripts/build-rootfs.sh exists" test -f "$RFS"

if [ -f "$RFS" ]; then
  if grep -q "$needle" "$RFS"; then
    fail "B03-AC-8: build-rootfs.sh contains no vendor-host string"
  else
    pass "B03-AC-8: build-rootfs.sh contains no vendor-host string"
  fi
else
  fail "B03-AC-8: build-rootfs.sh contains no vendor-host string (file missing)"
fi

adv_default=
if [ -f "$ADV" ]; then
  adv_default=$(sed -n 's/^ADVISORY_BASE_URL="\${ADVISORY_BASE_URL:-\([^}]*\)}".*/\1/p' "$ADV" | head -n 1)
fi
if [ -n "$adv_default" ]; then
  pass "B03-AC-8: advisory-check default base URL found ($adv_default)"
else
  fail "B03-AC-8: advisory-check default base URL found"
fi

home_url=
if [ -f "$RFS" ]; then
  home_url=$(grep 'HOME_URL=' "$RFS" | head -n 1 | sed 's/.*HOME_URL=//; s/^["'"'"']//; s/["'"'"'].*$//')
fi
if [ -n "$home_url" ] && [ -n "$adv_default" ] && [ "$home_url" = "$adv_default" ]; then
  pass "B03-AC-8: os-release HOME_URL equals advisory default base URL"
else
  fail "B03-AC-8: os-release HOME_URL ('$home_url') equals advisory default base URL ('$adv_default')"
fi

# --- Slice 2 cases (B03-AC-1, -3, -4, -5, -6, -9, change 10) ---
WFD="$ROOT/.github/workflows"
BW="$WFD/build.yml"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/build-workflow.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES

check "B03-AC-1 B03-AC-3 B03-AC-4 B03-AC-5 B03-AC-6 B03-AC-9: .github/workflows/build.yml exists" test -f "$BW"

# B03-AC-3: no vendor-cloud reference in build.yml. Terms are built from pieces so that this file never holds
# a forbidden string (I01).
_a=a; _w=w; _s=s
for term in "${_a}${_w}${_s}" "${_s}3" "${_s}3_BUCKET" "${_a}${_w}${_s}_" "${_a}${_w}${_s}-actions"; do
  if [ ! -f "$BW" ]; then
    fail "B03-AC-3: build.yml has no '$term' (file missing)"
  elif grep -iq -e "$term" "$BW"; then
    fail "B03-AC-3: build.yml has no '$term' reference"
  else
    pass "B03-AC-3: build.yml has no '$term' reference"
  fi
done

# make -n captures for AC-6 and change 10 (a missing target leaves the pattern unmatched, so the case FAILs).
mkn() { # mkn <outfile> <make args...>
  _o=$1; shift
  (cd "$ROOT" && make -n "$@") >"$_o" 2>&1
}
firstline() { grep -nE -e "$2" "$1" | head -n 1 | cut -d: -f1; } # firstline <file> <regex>
before() { # before <label> <file> <regex-first> <regex-second>
  _l=$1; _f=$2
  _x=$(firstline "$_f" "$3"); _y=$(firstline "$_f" "$4")
  if [ -n "$_x" ] && [ -n "$_y" ] && [ "$_x" -lt "$_y" ]; then pass "$_l"; else fail "$_l (lines: first=${_x:-none} second=${_y:-none})"; fi
}
SH_PKG='scripts/build-packages\.sh'
SH_RFS='scripts/build-rootfs\.sh'
SH_ISO='scripts/build-iso\.sh'
mkn "$tmp/all.out" all
before "B03-AC-6: make -n all lists build-packages before build-rootfs" "$tmp/all.out" "$SH_PKG" "$SH_RFS"
before "B03-AC-6: make -n all lists build-rootfs before iso" "$tmp/all.out" "$SH_RFS" "$SH_ISO"

mkn "$tmp/test.out" test
before "B03-AC-6: make -n test builds the ISO before test-boot (boot-test.py)" "$tmp/test.out" "$SH_ISO" 'boot-test\.py'
before "B03-AC-6: make -n test builds the ISO before test-artifact (static-audit.sh)" "$tmp/test.out" "$SH_ISO" 'static-audit\.sh'
before "B03-AC-6: make -n test builds the ISO before test-gates (attestation.sh)" "$tmp/test.out" "$SH_ISO" 'attestation\.sh'

# Change 10: test-boot, test-artifact and test-gates default to the built ISO; no fetch in the default lane.
for t in "test-boot:boot-test\\.py" "test-artifact:static-audit\\.sh" "test-gates:attestation\\.sh"; do
  tgt=${t%%:*}; tool=${t#*:}; toolname=$(printf %s "$tool" | tr -d '\\')
  mkn "$tmp/$tgt.def" "$tgt"
  before "B03-AC-6: make -n $tgt with the default ISO runs build-iso.sh before $toolname" "$tmp/$tgt.def" "$SH_ISO" "$tool"
  if [ -n "$(firstline "$tmp/$tgt.def" "$tool")" ] && [ -z "$(firstline "$tmp/$tgt.def" 'curl -fsSL.*\.iso')" ]; then
    pass "B03-AC-6: make -n $tgt with the default ISO does not fetch the ISO (no curl of ISO_URL)"
  else
    fail "B03-AC-6: make -n $tgt with the default ISO does not fetch the ISO (no curl of ISO_URL)"
  fi
  mkn "$tmp/$tgt.lane" "$tgt" ISO_URL=https://example.invalid/lane.iso \
    ISO_SHA256=0000000000000000000000000000000000000000000000000000000000000001
  before "B03-AC-6: make -n $tgt with ISO_URL and ISO_SHA256 set fetches (curl) before $toolname" "$tmp/$tgt.lane" 'curl -fsSL' "$tool"
done

# B03-AC-6 / change 10 (2b): on a clean checkout (no output/) make -n test runs the package build, the rootfs build
# and the ISO build, in that order, before the boot tests: the built ISO is a file target reached through the all
# chain. Run in a temporary copy of the Makefile so that an existing output/ cannot hide a step.
mkdir -p "$tmp/clean"
cp "$ROOT/Makefile" "$tmp/clean/Makefile" 2>/dev/null
(cd "$tmp/clean" && make -n test) >"$tmp/clean.out" 2>&1
before "B03-AC-6: clean checkout, make -n test builds packages before the rootfs (build-packages.sh, build-rootfs.sh)" "$tmp/clean.out" "$SH_PKG" "$SH_RFS"
before "B03-AC-6: clean checkout, make -n test builds the rootfs before the ISO (build-rootfs.sh, build-iso.sh)" "$tmp/clean.out" "$SH_RFS" "$SH_ISO"
before "B03-AC-6: clean checkout, make -n test builds the ISO before the first boot test (build-iso.sh, boot-test.py)" "$tmp/clean.out" "$SH_ISO" 'boot-test\.py'

# Change 10: the rc1 workflows pass the rc1 inputs explicitly (ISO_URL and ISO_SHA256, or ISO=) to the test step.
# AC-1, -4, -5, -6 (build.yml parts) and AC-9 are parsed by one Python block; each case prints its own line.
python3 -I - "$ROOT" >"$tmp/py.out" 2>"$tmp/py.err" <<'PY'
import os, re, shlex, subprocess, sys

root = sys.argv[1]
wfd = root + "/.github/workflows"
bpath = wfd + "/build.yml"
done = []


def out(ok, label, why=""):
    print(("PASS: " if ok else "FAIL: ") + label + ("" if ok or not why else " (" + why + ")"))


def case(label, fn):
    try:
        r = fn()
    except Exception as e:  # a missing file or key is a FAIL of this case, never a crash
        out(False, label, "%s: %s" % (type(e).__name__, e))
        return
    if isinstance(r, tuple):
        out(r[0], label, r[1])
    else:
        out(bool(r), label)


try:
    import yaml
except Exception as e:  # no PyYAML: every parsed case FAILs, the harness goes on
    yaml = None
    yerr = str(e)


def load(p):
    if yaml is None:
        raise RuntimeError("PyYAML unavailable: " + yerr)
    with open(p) as f:
        return yaml.safe_load(f) or {}


def text(p):
    with open(p) as f:
        lines = f.read().split("\n")
    kept = []
    for ln in lines:
        ln = re.sub(r"(^|\s)#.*$", "", ln)
        kept.append(ln)
    return "\n".join(kept)


def joined_lines(s):
    return re.sub(r"\\\n", " ", s).split("\n")


def jobs_of(wf):
    return wf.get("jobs") or {}


def steps_of(job):
    return job.get("steps") or []


def run_text(job):
    return "\n".join(str(s.get("run", "")) for s in steps_of(job) if "run" in s)


def needs_of(job):
    n = job.get("needs") or []
    return [n] if isinstance(n, str) else list(n)


def need_build():
    if not os.path.isfile(bpath):
        raise RuntimeError(".github/workflows/build.yml is missing")
    return load(bpath)


def called_files(wf, seen=None):
    seen = set() if seen is None else seen
    for j in jobs_of(wf).values():
        u = str(j.get("uses", ""))
        m = re.match(r"\./\.github/workflows/([A-Za-z0-9_.-]+)$", u)
        if m and m.group(1) not in seen and os.path.isfile(wfd + "/" + m.group(1)):
            seen.add(m.group(1))
            called_files(load(wfd + "/" + m.group(1)), seen)
    return sorted(seen)


# ---------------- B03-AC-1 ----------------
def ac1_no_cache():
    b = need_build()
    bad = []
    for fn in ["build.yml"] + called_files(b):
        wf = load(wfd + "/" + fn)
        for jn, j in jobs_of(wf).items():
            for s in steps_of(j):
                if str(s.get("uses", "")).startswith("actions/cache"):
                    bad.append("%s:%s" % (fn, jn))
    return (not bad, "actions/cache steps in " + ", ".join(bad))


def ac1_no_key():
    b = need_build()
    bad = [fn for fn in ["build.yml"] + called_files(b) if "ci-artifacts-" in text(wfd + "/" + fn)]
    return (not bad, "ci-artifacts- key in " + ", ".join(bad))


def ac1_upload():
    b = need_build()
    paths = []
    for j in jobs_of(b).values():
        for s in steps_of(j):
            if str(s.get("uses", "")).startswith("actions/upload-artifact"):
                paths.append(str((s.get("with") or {}).get("path", "")))
    allp = "\n".join(paths)
    return ("squashfs" in allp and ".iso" in allp, "upload-artifact paths: %r" % allp)


def ac1_download():
    b = need_build()
    a = jobs_of(b)["attestation"]
    ok = any(str(s.get("uses", "")).startswith("actions/download-artifact") for s in steps_of(a))
    return (ok, "no download-artifact step in the attestation job")


def ac1_boot_call():
    b = need_build()
    j = jobs_of(b)["boot-test"]
    ok = str(j.get("uses", "")).endswith("/boot-test.yml") and bool((j.get("with") or {}).get("iso-artifact"))
    return (ok, "boot-test job must call boot-test.yml with an iso-artifact input")


case("B03-AC-1: build.yml and the workflows it calls have no actions/cache step", ac1_no_cache)
case("B03-AC-1: build.yml and the workflows it calls have no ci-artifacts- key", ac1_no_key)
case("B03-AC-1: build.yml uploads the ISO and the squashfs with upload-artifact", ac1_upload)
case("B03-AC-1: the attestation job restores them with download-artifact", ac1_download)
case("B03-AC-1: the boot-test job calls boot-test.yml with the ISO artifact (iso-artifact)", ac1_boot_call)

# ---------------- B03-AC-4 ----------------
def make_pull_dry(args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("MAKE")}
    r = subprocess.run(["make", "-n", "pull-image"] + args, cwd=root, env=env,
                       capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def ac4_pulls():
    need_build()
    lines = joined_lines(text(bpath))
    n = 0
    bad = []
    for ln in lines:
        if re.search(r"\bdocker\s+pull\b", ln):
            n += 1
            if "@sha256:" not in ln or ":latest" in ln:
                bad.append(ln.strip())
        m = re.search(r"\bmake\b(.*\bpull-image\b.*)$", ln)
        if m:
            n += 1
            toks = [t for t in shlex.split(re.split(r"[;&|]", m.group(1))[0].replace("${{", "").replace("}}", "")) if t]
            args = [t for t in toks if "=" in t and "$" not in t and not t.startswith("-")]
            rc, o = make_pull_dry(args)
            if rc != 0 or "@sha256:" not in o or ":latest" in o:
                bad.append(ln.strip() + " -> make -n pull-image rc=%d" % rc)
    if n == 0:
        return (False, "build.yml pulls the builder nowhere")
    return (not bad, "; ".join(bad))


def ac4_latest():
    need_build()
    bad = [ln.strip() for ln in text(bpath).split("\n") if ":latest" in ln]
    return (not bad, "; ".join(bad))


case("B03-AC-4: every docker pull and make pull-image in build.yml resolves the builder by @sha256: digest", ac4_pulls)
case("B03-AC-4: build.yml uses no :latest", ac4_latest)

# ---------------- B03-AC-5 ----------------
SIGN_USES = re.compile(r"^(actions/attest|sigstore/|softprops/action-gh-release|actions/create-release)")
SIGN_RUN = re.compile(r"\bcosign\b|\bgh\s+release\b|\bslsa\b")


def is_sign(step):
    return bool(SIGN_USES.match(str(step.get("uses", ""))) or SIGN_RUN.search(str(step.get("run", ""))))


def has_art(job):
    return str(job.get("uses", "")).endswith("artifact-checks.yml") or bool(
        re.search(r"\bmake\b[^\n]*\btest-artifact\b", run_text(job)))


def has_gates(job):
    return bool(re.search(r"\bmake\b[^\n]*\btest-gates\b", run_text(job))) or bool(
        re.search(r"gates", str(job.get("uses", ""))))


def check_idx(job, pred):
    for i, s in enumerate(steps_of(job)):
        if re.search(r"\bmake\b[^\n]*\b%s\b" % pred, str(s.get("run", ""))):
            return i, s
    return None, None


def ac5_boot():
    b = need_build()
    js = jobs_of(b)
    if "boot-test" not in js or not str(js["boot-test"].get("uses", "")).endswith("boot-test.yml"):
        return (False, "no boot-test job calling boot-test.yml")
    return ("boot-test" in needs_of(js["attestation"]), "attestation does not need boot-test")


def required_providers(js, kind):
    a = js["attestation"]
    pred = has_art if kind == "art" else has_gates
    ps = [n for n in needs_of(a) if n in js and pred(js[n])]
    own = pred(a)
    return ps, own


def ac5_provider(kind, label):
    def f():
        b = need_build()
        js = jobs_of(b)
        ps, own = required_providers(js, kind)
        return (bool(ps) or own, "no job in the attestation job's needs, and no step in it, runs the %s" % label)
    return f


def ac5_steps_blocking():
    b = need_build()
    js = jobs_of(b)
    a = js["attestation"]
    bad = []
    for kind, pred in (("art", "test-artifact"), ("gates", "test-gates")):
        ps, own = required_providers(js, kind)
        if own:
            i, s = check_idx(a, pred)
            if s is not None:
                if s.get("continue-on-error") in (True, "true"):
                    bad.append(pred + " step has continue-on-error")
                if re.search(r"\|\|\s*(true|:)", str(s.get("run", ""))):
                    bad.append(pred + " step ends in || true")
                for k, st in enumerate(steps_of(a)):
                    if is_sign(st) and k < i:
                        bad.append(pred + " step comes after a signing step")
    return (not bad, "; ".join(bad))


def ac5_if():
    b = need_build()
    js = jobs_of(b)
    a = js["attestation"]
    cond = str(a.get("if", ""))
    required = ["boot-test"]
    for kind in ("art", "gates"):
        ps, own = required_providers(js, kind)
        required += ps
    if "compare" in js and "compare" in needs_of(a):
        required.append("compare")
    if re.search(r"always\(\)|failure\(\)|cancelled\(\)", cond):
        miss = [r for r in required if not re.search(r"needs\.%s\.result\s*==\s*'success'" % re.escape(r), cond)]
        return (not miss, "if: lets the job run without success of " + ", ".join(miss))
    return (True, "")


def ac5_later_jobs():
    b = need_build()
    js = jobs_of(b)

    def closure(n, acc):
        for m in needs_of(js[n]):
            if m in js and m not in acc:
                acc.add(m)
                closure(m, acc)
        return acc

    bad = []
    for n, j in js.items():
        if n == "attestation":
            continue
        if any(is_sign(s) for s in steps_of(j)) and "attestation" not in closure(n, set()):
            bad.append(n)
    return (not bad, "signing or publishing jobs that do not need attestation: " + ", ".join(bad))


case("B03-AC-5: build.yml has a boot-test job (boot-test.yml) and the attestation job needs it", ac5_boot)
case("B03-AC-5: the artifact check runs in the attestation job or a job it needs", ac5_provider("art", "artifact check (make test-artifact)"))
case("B03-AC-5: the gates run in the attestation job or a job it needs", ac5_provider("gates", "gates (make test-gates)"))
case("B03-AC-5: check steps inside the attestation job precede signing and cannot be bypassed", ac5_steps_blocking)
case("B03-AC-5: the attestation job's if: cannot run it after a failed or skipped required need", ac5_if)
case("B03-AC-5: any other signing or publishing job needs the attestation job", ac5_later_jobs)

# ---------------- B03-AC-6 ----------------
def make_targets():
    env = {k: v for k, v in os.environ.items() if not k.startswith("MAKE")}
    r = subprocess.run(["make", "-pq", "-f", "Makefile"], cwd=root, env=env, capture_output=True, text=True)
    prev = ""
    names = set()
    for ln in r.stdout.split("\n"):
        m = re.match(r"^([A-Za-z0-9_][^:\s=]*)\s*:(?!=)", ln)
        if m and not prev.startswith("# Not a target"):
            names.add(m.group(1))
        prev = ln
    return names


def make_calls(run):
    tg = []
    for ln in joined_lines(run):
        for m in re.finditer(r"(?:^|[;&|(]\s*|\s)make\s+([^;&|)]*)", ln):
            try:
                toks = shlex.split(m.group(1))
            except ValueError:
                toks = m.group(1).split()
            for t in toks:
                if t.startswith("-") or "=" in t or "$" in t or "`" in t:
                    continue
                tg.append(t)
    return tg


def ac6_targets():
    b = need_build()
    tg = make_calls(run_text(jobs_of(b)["build"]))
    if not tg:
        return (False, "the build job runs no make target")
    have = make_targets()
    miss = sorted(set(t for t in tg if t not in have))
    return (not miss, "targets missing from the Makefile: " + ", ".join(miss))


def ac6_test_steps():
    b = need_build()
    tools = re.compile(r"boot-test\.py|static-audit\.sh|attestation\.sh|scripts/tests/|\bpytest\b|gates-verdict")
    bad = []
    for jn, j in jobs_of(b).items():
        for s in steps_of(j):
            r = str(s.get("run", ""))
            name = str(s.get("name", ""))
            if "run" not in s:
                continue
            if re.search(r"\btests?\b", name, re.I) or tools.search(r):
                if not re.search(r"\bmake\b[^\n]*\btest-[a-z]", r) or tools.search(r):
                    bad.append("%s: %s" % (jn, name or r.strip().split("\n")[0]))
    return (not bad, "test steps that are not a make test-* target: " + "; ".join(bad))


case("B03-AC-6: every make target the build job runs exists in the Makefile", ac6_targets)
case("B03-AC-6: every test step of build.yml is a make test-* target", ac6_test_steps)

# ---------------- B03-AC-9 ----------------
def ac9_runs():
    b = need_build()
    rt = run_text(jobs_of(b)["build"])
    if "verify-kernel-modules.sh" in rt:
        return True
    env = {k: v for k, v in os.environ.items() if not k.startswith("MAKE")}
    for t in make_calls(rt):
        r = subprocess.run(["make", "-n", t], cwd=root, env=env, capture_output=True, text=True)
        if "verify-kernel-modules.sh" in r.stdout:
            return True
    return (False, "the build job does not run scripts/verify-kernel-modules.sh")


def ac9_no_inline():
    b = need_build()
    bad = []
    for jn, j in jobs_of(b).items():
        for s in steps_of(j):
            if "lib/modules" in str(s.get("run", "")):
                bad.append("%s: %s" % (jn, s.get("name", "")))
    return (not bad, "run: steps naming lib/modules: " + "; ".join(bad))


case("B03-AC-9: the build job runs scripts/verify-kernel-modules.sh", ac9_runs)
case("B03-AC-9: no run: step in build.yml names lib/modules", ac9_no_inline)

# ---------------- change 10: rc1 workflows pass the rc1 inputs explicitly ----------------
def rc1_inputs(fn):
    def f():
        wf = load(wfd + "/" + fn)
        top_env = wf.get("env") or {}
        n = 0
        bad = []
        for jn, j in jobs_of(wf).items():
            jenv = j.get("env") or {}
            for s in steps_of(j):
                r = str(s.get("run", ""))
                if re.search(r"\bmake\b[^\n]*\b(test-artifact|test-gates)\b", r):
                    n += 1
                    env = {}
                    env.update(top_env)
                    env.update(jenv)
                    env.update(s.get("env") or {})
                    ok = bool(re.search(r"\bISO=", r)) or (
                        ("ISO_URL" in env or re.search(r"\bISO_URL=", r))
                        and ("ISO_SHA256" in env or re.search(r"\bISO_SHA256=", r)))
                    if not ok:
                        bad.append("%s: %s" % (jn, s.get("name", r.strip())))
        if n == 0:
            return (False, "no make test-artifact or test-gates step")
        return (not bad, "steps without explicit rc1 inputs: " + "; ".join(bad))
    return f


case("B03-AC-6 (change 10): artifact-checks-rc1.yml passes the rc1 ISO inputs to test-artifact", rc1_inputs("artifact-checks-rc1.yml"))
case("B03-AC-6 (change 10): sbom-gates-rc1.yml passes the rc1 ISO inputs to test-gates", rc1_inputs("sbom-gates-rc1.yml"))
# ---------------- slice 2b ----------------
def ac1_download_name():
    b = need_build()
    js = jobs_of(b)
    ups = [str((s.get("with") or {}).get("name", "")) for s in steps_of(js["build"])
           if str(s.get("uses", "")).startswith("actions/upload-artifact")
           and ".iso" in str((s.get("with") or {}).get("path", ""))]
    downs = [str((s.get("with") or {}).get("name", "")) for s in steps_of(js["attestation"])
             if str(s.get("uses", "")).startswith("actions/download-artifact")]
    if not ups:
        return (False, "the build job uploads no ISO")
    return (any(d and d in ups for d in downs), "ISO upload names %r, attestation download names %r" % (ups, downs))


case("B03-AC-1: the attestation job downloads the artifact by the name the build job's ISO upload uses", ac1_download_name)


def on_of(wf):
    return wf.get("on", wf.get(True)) or {}


def mech_paths():
    push = (on_of(need_build()).get("push") or {})
    want = ["configs/portage/world", "configs/portage/versions.lock", "configs/overlay/**", "scripts/**",
            "rootfs/**", "Dockerfile", "Makefile"]
    got = push.get("paths")
    return (isinstance(got, list) and sorted(got) == sorted(want) and len(got) == len(want),
            "on.push.paths is %r" % (got,))


def mech_changes_job():
    j = jobs_of(need_build()).get("changes") or {}
    rt = run_text(j)
    return (bool(re.search(r"(^|\s)make\s+changes\b", rt)), "the changes job runs: %r" % rt)


def mech_no_filter_action():
    need_build()
    t = text(bpath)
    return ("dorny/paths-filter" not in t, "build.yml names dorny/paths-filter")


def mech_no_contains():
    need_build()
    t = text(bpath)
    return ("contains(" not in t, "build.yml uses contains(")


case("Standard mechanism: build.yml on.push.paths lists exactly the seven build inputs", mech_paths)
case("Standard mechanism: the changes job runs make changes", mech_changes_job)
case("Standard mechanism: build.yml does not use dorny/paths-filter", mech_no_filter_action)
case("Standard mechanism: build.yml has no contains( expression", mech_no_contains)


def pkg_write(perms):
    return isinstance(perms, dict) and str(perms.get("packages", "")) == "write"


def lp_workflow_level():
    b = need_build()
    p = b.get("permissions")
    return (not pkg_write(p) and p != "write-all", "workflow-level permissions grant packages: write: %r" % (p,))


def lp_only_build():
    b = need_build()
    js = jobs_of(b)
    bad = [n for n, j in js.items() if n != "build" and (pkg_write(j.get("permissions")) or j.get("permissions") == "write-all")]
    return (not bad, "jobs other than build granted packages: write: " + ", ".join(bad))


def lp_build_has():
    b = need_build()
    return (pkg_write(jobs_of(b)["build"].get("permissions")), "the build job has no permissions: packages: write")


case("B03 least privilege (change 6): no packages: write at workflow level", lp_workflow_level)
case("B03 least privilege (change 6): no job other than build is granted packages: write", lp_only_build)
case("B03 least privilege (change 6): the build job has packages: write (it pushes the package cache)", lp_build_has)

# ---------------- slice 2c ----------------
def iso_of_steps(job, tgt):
    res = []
    top = (need_build().get("env") or {})
    for s in steps_of(job):
        r = str(s.get("run", ""))
        if re.search(r"\bmake\b[^\n]*\b" + tgt + r"\b", r):
            env = {}
            env.update(top)
            env.update(job.get("env") or {})
            env.update(s.get("env") or {})
            m = re.search(r"\bISO=(\S+)", r)
            res.append(m.group(1) if m else env.get("ISO"))
    return res


def make_n(args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("MAKE")}
    return subprocess.run(["make", "-n"] + args, cwd=root, env=env, capture_output=True, text=True).stdout


def handed(tgt, args):
    o = make_n([tgt] + args)
    if tgt == "test-gates":
        m = re.search(r"--iso /output/(\S+)", o)
        return ("output/" + m.group(1)) if m else None
    m = re.search(r'-indev "([^"]+)"', o)
    return m.group(1) if m else None


def same_iso(tgt):
    def f():
        j = jobs_of(need_build())["attestation"]
        isos = iso_of_steps(j, tgt)
        if not isos:
            return (False, "the attestation job has no make %s step" % tgt)
        bad = []
        for iso in isos:
            if not iso:
                bad.append("step passes no ISO")
                continue
            h = handed(tgt, ["ISO=" + iso])
            if h is None or os.path.normpath(h) != os.path.normpath(iso):
                bad.append("passed %s, recipe hands %s" % (iso, h))
        return (not bad, "; ".join(bad))
    return f


def same_default(tgt):
    def f():
        h = handed(tgt, [])
        o = make_n(["test-artifact"])
        m = re.search(r'-indev "([^"]+)"', o)
        return (h is not None and m is not None and os.path.normpath(h) == os.path.normpath(m.group(1)),
                "recipe hands %s, the built ISO is %s" % (h, m.group(1) if m else None))
    return f


case("B03-AC-5: the attestation job's make test-gates step hands the gates the ISO it passes (same file)", same_iso("test-gates"))
case("B03-AC-5: the attestation job's make test-artifact step hands the artifact checks the ISO it passes (same file)", same_iso("test-artifact"))
case("B03-AC-5: make test-gates in the default lane hands the gates the built ISO (same file as test-artifact)", same_default("test-gates"))


def sr_read():
    p = jobs_of(need_build())["static-rebuild"].get("permissions")
    return (isinstance(p, dict) and str(p.get("packages", "")) == "read",
            "static-rebuild permissions are %r (it logs in to ghcr.io with GITHUB_TOKEN)" % (p,))


case("B03 least privilege (change 6/7): the static-rebuild job, which logs in to ghcr.io, has packages: read", sr_read)

print("PYDONE")
PY
cat "$tmp/py.out"
if ! grep -q '^PYDONE$' "$tmp/py.out"; then
  fail "slice 2 parsing block did not run to its end: $(head -n 3 "$tmp/py.err" | tr '\n' ' ')"
fi
fails=$((fails + $(grep -c '^FAIL: ' "$tmp/py.out")))

# B03-AC-1: actionlint on build.yml (make test-lint runs it over the tree; here only when it is on PATH).
if command -v actionlint >/dev/null 2>&1; then
  if [ ! -f "$BW" ]; then
    fail "B03-AC-1: actionlint passes on build.yml (file missing)"
  elif (cd "$ROOT" && actionlint .github/workflows/build.yml) >"$tmp/al.out" 2>&1; then
    pass "B03-AC-1: actionlint passes on build.yml"
  else
    fail "B03-AC-1: actionlint passes on build.yml: $(head -n 3 "$tmp/al.out" | tr '\n' ' ')"
  fi
fi

# --- slice 2c: change 10 (owner Q2) the default lane runs no fetch-iso recipe; AC-9 verify-kernel-modules in the chain ---
# fetch-iso's recipe is the only one with f="<...>.iso" (ISO_OUT); the rc1 SBOM fetch in test-gates uses another f.
FETCH_MARK='f="[^"]*\.iso"; mkdir'
for tgt in test-boot test-artifact test-gates; do
  mkn "$tmp/nf.$tgt" "$tgt"
  if [ -s "$tmp/nf.$tgt" ] && [ -z "$(firstline "$tmp/nf.$tgt" "$FETCH_MARK")" ]; then
    pass "B03-AC-6 (change 10): make -n $tgt in the default lane prints no line of fetch-iso's recipe"
  else
    fail "B03-AC-6 (change 10): make -n $tgt in the default lane prints no line of fetch-iso's recipe"
  fi
done
mkn "$tmp/nf.lane" test-boot ISO_URL=https://example.invalid/lane.iso \
  ISO_SHA256=0000000000000000000000000000000000000000000000000000000000000001
if [ -n "$(firstline "$tmp/nf.lane" "$FETCH_MARK")" ]; then
  pass "B03-AC-6 (change 10): the fetch-iso marker is found in make -n test-boot with ISO_URL set (the no-fetch case is not vacuous)"
else
  fail "B03-AC-6 (change 10): the fetch-iso marker is found in make -n test-boot with ISO_URL set (the no-fetch case is not vacuous)"
fi

SH_VKM='scripts/verify-kernel-modules\.sh'
before "B03-AC-9: make -n all runs verify-kernel-modules after build-packages" "$tmp/all.out" "$SH_PKG" "$SH_VKM"
before "B03-AC-9: make -n all runs verify-kernel-modules before build-iso" "$tmp/all.out" "$SH_VKM" "$SH_ISO"
before "B03-AC-9: clean checkout, make -n test runs verify-kernel-modules after build-packages" "$tmp/clean.out" "$SH_PKG" "$SH_VKM"
before "B03-AC-9: clean checkout, make -n test runs verify-kernel-modules before build-iso" "$tmp/clean.out" "$SH_VKM" "$SH_ISO"

# --- slice 3: change 12 (INSTALL_MASK), change 13 (CVE gate report-only off tags), .DEFAULT_GOAL, run-* hint ---
MC="$ROOT/configs/portage/make.conf"
EXPF="$ROOT/configs/attestation/rc1-static-audit.expected"
mask_lines=$(grep -c '^[[:space:]]*INSTALL_MASK=' "$MC" 2>/dev/null || true)
if [ "${mask_lines:-0}" -eq 1 ]; then
  pass "B03-AC-7 (change 12): make.conf has exactly one INSTALL_MASK= assignment"
else
  fail "B03-AC-7 (change 12): make.conf has exactly one INSTALL_MASK= assignment (found ${mask_lines:-0})"
fi
mask=$(grep '^[[:space:]]*INSTALL_MASK=' "$MC" 2>/dev/null | head -n 1 | sed 's/^[^=]*=//; s/^["'"'"']//; s/["'"'"'][[:space:]]*\(#.*\)*$//')
want_mask="/usr/bin/event_rpcgen.py /usr/lib/xcb-proto /usr/share/gdb/auto-load /usr/share/gdb/system-gdbinit /usr/share/glib-2.0/gdb"
if [ "$(printf '%s\n' $mask | sort)" = "$(printf '%s\n' $want_mask | sort)" ] && [ -n "$mask" ]; then
  pass "B03-AC-7 (change 12): INSTALL_MASK is exactly the spec's five-entry list (no glob, no *.py)"
else
  fail "B03-AC-7 (change 12): INSTALL_MASK is exactly the spec's five-entry list (no glob, no *.py) (got '$mask')"
fi
cov_bad=
npy=0
if [ -n "$mask" ] && [ -f "$EXPF" ]; then
  for p in $(sed -n 's/^FINDING python \([^ ]*\).*/\1/p' "$EXPF"); do
    npy=$((npy + 1))
    c=0
    for e in $mask; do
      case "/$p" in "$e"|"$e"/*) c=1 ;; esac
    done
    [ $c -eq 1 ] || cov_bad="$cov_bad $p"
  done
fi
if [ -n "$mask" ] && [ "$npy" -eq 14 ] && [ -z "$cov_bad" ]; then
  pass "B03-AC-7 (change 12): every one of the 14 'FINDING python' paths of rc1-static-audit.expected is covered by an INSTALL_MASK entry"
else
  fail "B03-AC-7 (change 12): every one of the 14 'FINDING python' paths of rc1-static-audit.expected is covered by an INSTALL_MASK entry (python paths=$npy, uncovered:${cov_bad:- none; or no mask})"
fi

# Change 13, Makefile: CVE_REPORT_ONLY=1 passes --cve-report-only to gates-verdict.sh and drops the arc -eq 0 requirement.
: > "$tmp/dummy.iso"
mkn "$tmp/tg.off" test-gates ISO="$tmp/dummy.iso"
mkn "$tmp/tg.on" test-gates ISO="$tmp/dummy.iso" CVE_REPORT_ONLY=1
if grep -q 'gates-verdict\.sh' "$tmp/tg.on" && grep -q -e '--cve-report-only' "$tmp/tg.on"; then
  pass "B03-AC-7 (change 13): make -n test-gates CVE_REPORT_ONLY=1 passes --cve-report-only to gates-verdict.sh"
else
  fail "B03-AC-7 (change 13): make -n test-gates CVE_REPORT_ONLY=1 passes --cve-report-only to gates-verdict.sh"
fi
if grep -q 'gates-verdict\.sh' "$tmp/tg.off" && ! grep -q -e '--cve-report-only' "$tmp/tg.off"; then
  pass "B03-AC-7 (change 13): make -n test-gates without CVE_REPORT_ONLY passes no --cve-report-only"
else
  fail "B03-AC-7 (change 13): make -n test-gates without CVE_REPORT_ONLY passes no --cve-report-only"
fi
if grep -q -e '-eq 0' "$tmp/tg.off" && grep -Eq 'arc -eq 0' "$tmp/tg.off"; then
  pass "B03-AC-7 (change 13): without CVE_REPORT_ONLY the non-rc1 branch still requires attestation.sh's exit 0 (arc -eq 0)"
else
  fail "B03-AC-7 (change 13): without CVE_REPORT_ONLY the non-rc1 branch still requires attestation.sh's exit 0 (arc -eq 0)"
fi
if grep -q 'gates-verdict\.sh' "$tmp/tg.on" && grep -q -e '--cve-report-only' "$tmp/tg.on" && ! grep -Eq 'arc -eq 0' "$tmp/tg.on"; then
  pass "B03-AC-7 (change 13): with CVE_REPORT_ONLY=1 the non-rc1 branch no longer requires arc -eq 0"
else
  fail "B03-AC-7 (change 13): with CVE_REPORT_ONLY=1 the non-rc1 branch no longer requires arc -eq 0"
fi
if grep -q -e '--rc1' "$tmp/tg.on" && grep -q -e '--rc1' "$tmp/tg.off" && grep -q 'sbom' "$tmp/tg.on" && grep -q 'sbom' "$tmp/tg.off"; then
  pass "B03-AC-7 (change 13): the rc1 branch (--rc1, SBOM comparison) is present with and without the switch"
else
  fail "B03-AC-7 (change 13): the rc1 branch (--rc1, SBOM comparison) is present with and without the switch"
fi

# Change 13 / slice 3b: only the value 1 turns the switch on; 0 and empty behave as unset.
mkn "$tmp/tg.zero" test-gates ISO="$tmp/dummy.iso" CVE_REPORT_ONLY=0
mkn "$tmp/tg.empty" test-gates ISO="$tmp/dummy.iso" CVE_REPORT_ONLY=
for v in zero empty; do
  if grep -q 'gates-verdict\.sh' "$tmp/tg.$v" && ! grep -q -e '--cve-report-only' "$tmp/tg.$v"; then
    pass "B03-AC-7 (change 13): make -n test-gates CVE_REPORT_ONLY=$([ $v = zero ] && echo 0 || echo '<empty>') passes no --cve-report-only"
  else
    fail "B03-AC-7 (change 13): make -n test-gates CVE_REPORT_ONLY=$([ $v = zero ] && echo 0 || echo '<empty>') passes no --cve-report-only"
  fi
  if grep -Eq 'arc -eq 0' "$tmp/tg.$v"; then
    pass "B03-AC-7 (change 13): CVE_REPORT_ONLY=$([ $v = zero ] && echo 0 || echo '<empty>') keeps the arc -eq 0 requirement"
  else
    fail "B03-AC-7 (change 13): CVE_REPORT_ONLY=$([ $v = zero ] && echo 0 || echo '<empty>') keeps the arc -eq 0 requirement"
  fi
done

# Change 13, build.yml: make test-gates steps set CVE_REPORT_ONLY=1 iff they run off tag pushes; one step per ref type.
python3 -I - "$ROOT" >"$tmp/py3.out" 2>"$tmp/py3.err" <<'PY'
import re, sys

root = sys.argv[1]
bpath = root + "/.github/workflows/build.yml"


def out(ok, label, why=""):
    print(("PASS: " if ok else "FAIL: ") + label + ("" if ok or not why else " (" + why + ")"))


def case(label, fn):
    try:
        r = fn()
    except Exception as e:
        out(False, label, "%s: %s" % (type(e).__name__, e))
        return
    out(r[0], label, r[1])


def gates_steps():
    import yaml
    with open(bpath) as f:
        wf = yaml.safe_load(f) or {}
    res = []
    top = wf.get("env") or {}
    for jn, j in (wf.get("jobs") or {}).items():
        for s in j.get("steps") or []:
            r = str(s.get("run", ""))
            if re.search(r"\bmake\b[^\n]*\btest-gates\b", r):
                env = {}
                env.update(top)
                env.update(j.get("env") or {})
                env.update(s.get("env") or {})
                flag = str(env.get("CVE_REPORT_ONLY", "")) == "1" or bool(re.search(r"\bCVE_REPORT_ONLY=1\b", r))
                cond = str(s.get("if", ""))
                if re.search(r"github\.ref_type\s*!=\s*'tag'", cond):
                    kind = "off"
                elif re.search(r"github\.ref_type\s*==\s*'tag'", cond):
                    kind = "tag"
                else:
                    kind = "ungated"
                res.append((jn, s.get("name", r), kind, flag))
    return res


def per_step():
    st = gates_steps()
    if not st:
        return (False, "no make test-gates step in build.yml")
    bad = []
    for jn, nm, kind, flag in st:
        if kind == "ungated":
            bad.append("%s/%s has no ref_type if:" % (jn, nm))
        elif (kind == "off") != flag:
            bad.append("%s/%s: if: kind=%s, CVE_REPORT_ONLY set=%s" % (jn, nm, kind, flag))
    return (not bad, "; ".join(bad))


def both():
    kinds = [k for _, _, k, _ in gates_steps()]
    return ("off" in kinds and "tag" in kinds, "make test-gates steps by ref type: %r" % kinds)


case("B03-AC-7 (change 13): every make test-gates step of build.yml sets CVE_REPORT_ONLY=1 iff its if: restricts it to non-tag events", per_step)
case("B03-AC-7 (change 13): build.yml has a make test-gates step for non-tag events and one for tag pushes", both)
print("PYDONE")
PY
cat "$tmp/py3.out"
if ! grep -q '^PYDONE$' "$tmp/py3.out"; then
  fail "slice 3 parsing block did not run to its end: $(head -n 3 "$tmp/py3.err" | tr '\n' ' ')"
fi
fails=$((fails + $(grep -c '^FAIL: ' "$tmp/py3.out")))

# B03-AC-6: make with no target runs the test chain (.DEFAULT_GOAL := test).
mkn "$tmp/default.out"
if grep -q 'boot-test\.py' "$tmp/default.out" && grep -q 'scripts/tests/\*\.sh' "$tmp/default.out"; then
  pass "B03-AC-6: make -n with no target runs the test chain (test-unit and test-boot recipes are listed)"
else
  fail "B03-AC-6: make -n with no target runs the test chain (test-unit and test-boot recipes are listed)"
fi
# B03-AC-6: the run-bios/run-uefi hint says make iso, not make fetch-iso.
mkn "$tmp/hint.out" run-bios ISO="$tmp/nonexistent.iso"
mkn "$tmp/hint2.out" run-uefi ISO="$tmp/nonexistent.iso"
for h in "$tmp/hint.out" "$tmp/hint2.out"; do
  if grep -q "Run 'make iso'" "$h" && ! grep -q "make fetch-iso" "$h"; then
    pass "B03-AC-6: the $(basename "$h" .out) not-found hint says make iso, not make fetch-iso"
  else
    fail "B03-AC-6: the $(basename "$h" .out) not-found hint says make iso, not make fetch-iso"
  fi
done

# --- end of cases ---
echo
if [ "$fails" -ne 0 ]; then
  echo "$fails FAILED"
  exit 1
fi
echo "ALL PASS"
