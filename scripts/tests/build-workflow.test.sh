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
  if [ -n "$(firstline "$tmp/$tgt.def" "$tool")" ] && [ -z "$(firstline "$tmp/$tgt.def" 'curl -fsSL')" ]; then
    pass "B03-AC-6: make -n $tgt with the default ISO does not fetch (no curl)"
  else
    fail "B03-AC-6: make -n $tgt with the default ISO does not fetch (no curl)"
  fi
  mkn "$tmp/$tgt.lane" "$tgt" ISO_URL=https://example.invalid/lane.iso \
    ISO_SHA256=0000000000000000000000000000000000000000000000000000000000000001
  before "B03-AC-6: make -n $tgt with ISO_URL and ISO_SHA256 set fetches (curl) before $toolname" "$tmp/$tgt.lane" 'curl -fsSL' "$tool"
done

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

# --- end of cases ---
echo
if [ "$fails" -ne 0 ]; then
  echo "$fails FAILED"
  exit 1
fi
echo "ALL PASS"
