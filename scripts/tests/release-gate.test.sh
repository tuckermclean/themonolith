#!/bin/sh
# P02 release-gate: the reproducibility gate. Cases are grouped by slice; later slices add lines above the
# "slice cases end" marker, never below it, and never edit earlier lines.
#   P02-AC-2  compare exits 1 when the two ISO digests differ, 0 only when equal; nothing makes a mismatch pass;
#             no known-differences file exists
#
# Interface under test (chosen for P02 slice 1):
#   sh scripts/compare-isos.sh <iso-a> <iso-b>   sha256sum of both; prints both digests; exit 0 only if equal,
#                                                exit 1 on a mismatch (diffoscope may run after a mismatch to
#                                                print a report; it decides nothing); any other failure
#                                                (missing/unreadable/empty file, wrong arg count) is non-zero
#   make compare ISO_A=<iso-a> ISO_B=<iso-b>     the Make target the `compare` job calls; runs the script
#                                                (make reports a failed recipe as exit 2: asserted non-zero)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/scripts/compare-isos.sh"
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ================= slice 1: P02-AC-2 =================
# fixture ISOs: same content; one byte different; stub diffoscope that always succeeds
head -c 1048576 /dev/zero | tr '\0' 'M' >"$TMP/a.iso"
cp "$TMP/a.iso" "$TMP/same.iso"
cp "$TMP/a.iso" "$TMP/b.iso"
printf 'X' | dd of="$TMP/b.iso" bs=1 seek=524288 conv=notrunc 2>/dev/null
mkdir -p "$TMP/stubs"
printf '#!/bin/sh\necho stub diffoscope "$@"\nexit 0\n' >"$TMP/stubs/diffoscope"
chmod +x "$TMP/stubs/diffoscope"

run_cmp() { # run_cmp <a> <b> [env assignments...]; sets rc, out
	a=$1; b=$2; shift 2
	out=$(env "$@" sh "$SCRIPT" "$a" "$b" 2>&1)
	rc=$?
}

run_cmp "$TMP/a.iso" "$TMP/same.iso" X=1
if [ "$rc" -eq 0 ]; then pass "P02-AC-2 identical ISOs exit 0"; else fail "P02-AC-2 identical ISOs exit 0 (rc=$rc: $(echo "$out" | head -c 200))"; fi

run_cmp "$TMP/a.iso" "$TMP/b.iso" X=1
if [ "$rc" -eq 1 ]; then pass "P02-AC-2 ISOs differing by one byte exit exactly 1"; else fail "P02-AC-2 ISOs differing by one byte exit exactly 1 (rc=$rc)"; fi

run_cmp "$TMP/b.iso" "$TMP/a.iso" X=1
if [ "$rc" -eq 1 ]; then pass "P02-AC-2 mismatch exits 1 in either order"; else fail "P02-AC-2 mismatch exits 1 in either order (rc=$rc)"; fi

# the same file given twice is equal
run_cmp "$TMP/a.iso" "$TMP/a.iso" X=1
if [ "$rc" -eq 0 ]; then pass "P02-AC-2 a file against itself exits 0"; else fail "P02-AC-2 a file against itself exits 0 (rc=$rc)"; fi

# 0 only when equal: missing, empty and wrong-arity inputs never exit 0
: >"$TMP/empty1.iso"; : >"$TMP/empty2.iso"
rc=0; sh "$SCRIPT" "$TMP/a.iso" "$TMP/nonexistent.iso" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then pass "P02-AC-2 a missing ISO does not exit 0"; else fail "P02-AC-2 a missing ISO does not exit 0"; fi
rc=0; sh "$SCRIPT" "$TMP/nonexistent1.iso" "$TMP/nonexistent2.iso" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then pass "P02-AC-2 two missing ISOs (equal digests of nothing) do not exit 0"; else fail "P02-AC-2 two missing ISOs do not exit 0"; fi
rc=0; sh "$SCRIPT" "$TMP/empty1.iso" "$TMP/empty2.iso" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then pass "P02-AC-2 two empty files do not exit 0"; else fail "P02-AC-2 two empty files do not exit 0"; fi
rc=0; sh "$SCRIPT" "$TMP/a.iso" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then pass "P02-AC-2 one argument does not exit 0"; else fail "P02-AC-2 one argument does not exit 0"; fi

# no file, variable or input makes a mismatch pass
: >"$TMP/known-differences"
for f in known-differences known-differences.txt known_differences allowlist.txt allowed-differences ignore.txt; do
	: >"$TMP/$f"
done
printf '%s\n' "$(sha256sum "$TMP/b.iso" | cut -d' ' -f1)" "*" >"$TMP/known-differences.txt"
cp "$TMP/known-differences.txt" "$TMP/allowlist.txt"
bypass_envs="KNOWN_DIFFERENCES=$TMP/known-differences ALLOWLIST=$TMP/allowlist.txt ALLOW_MISMATCH=1 ALLOW_DIFFERENCES=1 IGNORE_DIFFERENCES=1 SKIP_COMPARE=1 COMPARE_SKIP=1 FORCE=1 CI=true DRY_RUN=1 ACCEPT=1 TOLERATE=1 REPRO_OVERRIDE=1 DIFFOSCOPE_EXIT=0 COMPARE_ALLOW=1"
# shellcheck disable=SC2086
for e in $bypass_envs; do
	run_cmp "$TMP/a.iso" "$TMP/b.iso" "$e" PATH="$TMP/stubs:$PATH"
	if [ "$rc" -eq 1 ]; then pass "P02-AC-2 mismatch still exits 1 with $e"; else fail "P02-AC-2 mismatch still exits 1 with $e (rc=$rc)"; fi
done
# all of them together, from a directory holding allowlist-named files, with a succeeding diffoscope
# shellcheck disable=SC2086
(cd "$TMP" && env $bypass_envs PATH="$TMP/stubs:$PATH" sh "$SCRIPT" a.iso b.iso >/dev/null 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "P02-AC-2 mismatch exits 1 with every bypass variable, allowlist files and a succeeding diffoscope"; else fail "P02-AC-2 mismatch exits 1 with every bypass variable, allowlist files and a succeeding diffoscope (rc=$rc)"; fi
# a failing diffoscope does not turn an equal pair into a failure, nor a mismatch into a pass
printf '#!/bin/sh\nexit 3\n' >"$TMP/stubs/diffoscope"
run_cmp "$TMP/a.iso" "$TMP/b.iso" PATH="$TMP/stubs:$PATH"
if [ "$rc" -eq 1 ]; then pass "P02-AC-2 mismatch exits 1 when diffoscope itself fails"; else fail "P02-AC-2 mismatch exits 1 when diffoscope itself fails (rc=$rc)"; fi
run_cmp "$TMP/a.iso" "$TMP/same.iso" PATH="$TMP/stubs:$PATH"
if [ "$rc" -eq 0 ]; then pass "P02-AC-2 equal ISOs exit 0 and never need diffoscope"; else fail "P02-AC-2 equal ISOs exit 0 and never need diffoscope (rc=$rc)"; fi

# the script prints both digests (the compare log is the AC-6/AC-7 evidence)
run_cmp "$TMP/a.iso" "$TMP/b.iso" X=1
da=$(sha256sum "$TMP/a.iso" | cut -d' ' -f1); db=$(sha256sum "$TMP/b.iso" | cut -d' ' -f1)
if echo "$out" | grep -q "$da" && echo "$out" | grep -q "$db"; then pass "P02-AC-2 both digests are printed"; else fail "P02-AC-2 both digests are printed"; fi

# the Make target backs the script
if grep -qE '^compare:' "$ROOT/Makefile" 2>/dev/null; then pass "P02-AC-2 Makefile has a compare target"; else fail "P02-AC-2 Makefile has a compare target"; fi
rc=0; (cd "$ROOT" && make compare ISO_A="$TMP/a.iso" ISO_B="$TMP/same.iso") >"$TMP/mk0.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then pass "P02-AC-2 make compare exits 0 on identical ISOs"; else fail "P02-AC-2 make compare exits 0 on identical ISOs (rc=$rc)"; fi
rc=0; (cd "$ROOT" && make compare ISO_A="$TMP/a.iso" ISO_B="$TMP/b.iso" KNOWN_DIFFERENCES="$TMP/known-differences" ALLOW_MISMATCH=1) >"$TMP/mk1.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && grep -q "$db" "$TMP/mk1.log"; then pass "P02-AC-2 make compare fails on a mismatch, bypass variables included"; else fail "P02-AC-2 make compare fails on a mismatch, bypass variables included (rc=$rc)"; fi

# no known-differences file anywhere in the tree, and no bypass in the script or its Make target
found=$(cd "$ROOT" && find . -path ./.git -prune -o -path ./out -prune -o \( -iname '*known-differences*' -o -iname '*known_differences*' -o -iname '*accepted-differences*' -o -iname '*allowed-differences*' \) -print 2>/dev/null)
if [ -z "$found" ]; then pass "P02-AC-2 no known-differences file exists"; else fail "P02-AC-2 no known-differences file exists ($found)"; fi
if [ -f "$SCRIPT" ] && ! grep -qiE 'known.differences|allowlist|allow.list|allow_mismatch|ignore|skip|tolerat|exception' "$SCRIPT"; then
	pass "P02-AC-2 compare script has no allowlist, ignore or skip path"
else
	fail "P02-AC-2 compare script has no allowlist, ignore or skip path (script missing or has one)"
fi
# ================= slice 2: P02-AC-1, P02-AC-3, P02-AC-4 (static), P02-AC-5 (second sentence), P02-AC-8 =================
# Interfaces chosen for slice 2 (an implementer follows these):
#   Jobs of .github/workflows/build.yml on the tag path: fetch, build-a, build-b, compare (names fixed by the ACs).
#     build-a and build-b: `needs: fetch` (directly or through a closure) and never each other; steps are checkout,
#     the download of the distfiles / release-inputs artifacts (artifact names contain "distfiles" or "release-inputs"),
#     `make repro-build-a` / `make repro-build-b`, uploads. No actions/cache, no `make cache-pull`/`cache-push`.
#     compare: needs build-a and build-b, runs `make compare` with ISO_A/ISO_B.
#     Each of the four jobs runs exactly one Make target: repro-fetch, repro-build-a, repro-build-b, compare. Other
#     steps: actions/checkout, upload-artifact, download-artifact, `make build-version`, or a `toolbox/run -- <cmd>`
#     that is not a test.
#   Make targets: test-repro (prerequisite of test) = repro-fetch repro-build-a repro-build-b compare, in this order.
#     `make repro-build-a|repro-build-b RELEASE_INPUTS=<path>` (default output/release-inputs.json) read BUILDER_DIGEST,
#     TREE_DIGEST, TREE_COMMIT and SOURCE_DATE_EPOCH from that file (e.g. $(shell jq -r .BUILDER_DIGEST ...)), so that
#     `make -n` shows the file's values and not the Makefile's pins or the environment's.
#     Each build's container runs of build-packages.sh, build-rootfs.sh, build-initrd.sh and build-iso.sh have
#     `--network none`, `--hostname <name>` (build B's differs from A's), `-e JOBS=<n>` on the build-packages line
#     (build B's differs from A's), and on the build-packages line `-e FETCHCOMMAND=/bin/false -e RESUMECOMMAND=/bin/false`
#     and `MONOLITH_USEPKG=n`. Both targets run `sh scripts/check-distfiles.sh <DISTFILES_DIR>`.
#   sh scripts/check-distfiles.sh <distdir>: <distdir>/distfiles.list (written by scripts/fetch-distfiles.sh, one
#     file name per line) lists every distfile; exit 0 only if all are present; otherwise exit 1 naming each missing
#     file, and never touch the network (no curl, wget, emerge, oras, git, docker call).
#   Tag path = a job whose `if:` does not exclude tags (no `ref_type != 'tag'`). A job that calls a reusable workflow
#     (`uses: ./.github/workflows/x.yml`) counts the steps of that workflow as its own.
#   A write (oras push/cp, docker push, gh release, actions/attest*, deploy-pages, binpkg-store.sh push, make
#     cache-push/registry-copy/toolbox-publish/seed-tree, or any make target whose `make -n` shows one) on the tag
#     path needs compare, a boot-test job, a `make test-artifact` job and a `make test-gates` job in its needs
#     closure (or, for the last two, an earlier step of the same job); a write step is never `if: always()` or
#     `failure()`, and a write job whose `if:` uses always() must also require `needs.compare.result == 'success'`.
cat >"$TMP/cd-fixture.sh" <<'FIXEOF'
set -u
d=$1
mkdir -p "$d/with" "$d/without"
printf 'a-1.tar.gz\nb-2.tar.xz\nc-3.zip\n' >"$d/with/distfiles.list"
: >"$d/with/a-1.tar.gz"; : >"$d/with/b-2.tar.xz"; : >"$d/with/c-3.zip"
cp "$d/with/distfiles.list" "$d/without/distfiles.list"
: >"$d/without/a-1.tar.gz"; : >"$d/without/c-3.zip"
FIXEOF
sh "$TMP/cd-fixture.sh" "$TMP/cd"
mkdir -p "$TMP/netstubs"
for c in curl wget emerge oras git docker podman rsync ssh; do
	printf '#!/bin/sh\necho "%s $*" >>"%s/netcalls"\nexit 1\n' "$c" "$TMP" >"$TMP/netstubs/$c"
	chmod +x "$TMP/netstubs/$c"
done
CD="$ROOT/scripts/check-distfiles.sh"
rc=0; out=$(PATH="$TMP/netstubs:$PATH" sh "$CD" "$TMP/cd/with" 2>&1) || rc=$?
if [ -f "$CD" ] && [ "$rc" -eq 0 ]; then pass "P02-AC-4 check-distfiles passes when every listed distfile is present"; else fail "P02-AC-4 check-distfiles passes when every listed distfile is present (rc=$rc: $(echo "$out" | head -c 160))"; fi
rc=0; out=$(PATH="$TMP/netstubs:$PATH" sh "$CD" "$TMP/cd/without" 2>&1) || rc=$?
if [ -f "$CD" ] && [ "$rc" -ne 0 ] && echo "$out" | grep -q 'b-2.tar.xz' && ! echo "$out" | grep -q 'a-1.tar.gz'; then pass "P02-AC-4 a missing distfile fails the check and the output names exactly that file"; else fail "P02-AC-4 a missing distfile fails the check and the output names exactly that file (rc=$rc: $(echo "$out" | head -c 160))"; fi
if [ -f "$CD" ] && [ ! -e "$TMP/netcalls" ]; then pass "P02-AC-4 check-distfiles makes no network or fetch attempt"; else fail "P02-AC-4 check-distfiles makes no network or fetch attempt"; fi
rc=0; PATH="$TMP/netstubs:$PATH" sh "$CD" "$TMP/cd/nonexistent" >/dev/null 2>&1 || rc=$?
if [ -f "$CD" ] && [ "$rc" -ne 0 ]; then pass "P02-AC-4 check-distfiles on a missing directory does not exit 0"; else fail "P02-AC-4 check-distfiles on a missing directory does not exit 0"; fi

cat >"$TMP/ri-fixture.json" <<'RIEOF'
{"VERSION":"0.2.0-rc9","SOURCE_COMMIT":"1111111111111111111111111111111111111111","TREE_COMMIT":"2222222222222222222222222222222222222222","TREE_DIGEST":"sha256:3333333333333333333333333333333333333333333333333333333333333333","BUILDER_DIGEST":"sha256:4444444444444444444444444444444444444444444444444444444444444444","DISTFILES_DIGEST":"sha256:5555555555555555555555555555555555555555555555555555555555555555","SOURCE_DATE_EPOCH":"1234567890","XORRISO_VERSION":"x","SQUASHFS_TOOLS_VERSION":"x","GRUB_VERSION":"x","SYSLINUX_VERSION":"x","SYFT_VERSION":"x","GRYPE_VERSION":"x","QEMU_VERSION":"x","GRYPE_DB_BUILT":"x"}
RIEOF
RI_ENV_SENT="sha256:9999999999999999999999999999999999999999999999999999999999999999"

cat >"$TMP/slice2.py" <<'PYEOF'
import os, re, subprocess, sys, tempfile

ROOT, TMP = sys.argv[1], sys.argv[2]
WFD = os.path.join(ROOT, ".github", "workflows")
BW = os.path.join(WFD, "build.yml")
nfail = 0


def out(ok, label, detail=""):
    global nfail
    if ok:
        print("PASS: " + label)
    else:
        nfail += 1
        print("FAIL: " + label + ((" (" + detail[:300] + ")") if detail else ""))


def case(label, fn):
    try:
        r = fn()
    except Exception as e:
        out(False, label, "%s: %s" % (type(e).__name__, e))
        return
    if isinstance(r, tuple):
        out(r[0], label, r[1])
    else:
        out(bool(r), label)


try:
    import yaml
except Exception as e:
    yaml = None
    yerr = str(e)


def load(p):
    if yaml is None:
        raise RuntimeError("PyYAML unavailable: " + yerr)
    with open(p) as f:
        return yaml.safe_load(f) or {}


def mk(args, env_extra=None):
    env = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MAKELEVEL", "MFLAGS", "MAKEOVERRIDES")}
    if env_extra:
        env.update(env_extra)
    p = subprocess.run(["make", "-n"] + args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout + p.stderr


_mkcache = {}


def mk_target(t):
    if t not in _mkcache:
        try:
            _mkcache[t] = mk([t])[1]
        except Exception as e:
            _mkcache[t] = ""
    return _mkcache[t]


def as_list(v):
    if v is None:
        return []
    return [v] if isinstance(v, str) else list(v)


def closure(jobs, name):
    seen, todo = set(), list(as_list((jobs.get(name) or {}).get("needs")))
    while todo:
        n = todo.pop()
        if n in seen:
            continue
        seen.add(n)
        todo += as_list((jobs.get(n) or {}).get("needs"))
    return seen


def job_steps(job):
    """The job's steps; a job that calls a reusable workflow counts that workflow's steps."""
    u = job.get("uses")
    if u and u.startswith("./"):
        p = os.path.join(ROOT, u[2:])
        res = []
        if os.path.exists(p):
            for j in (load(p).get("jobs") or {}).values():
                res += j.get("steps") or []
        return res
    return job.get("steps") or []


def off_tag(job):
    return "ref_type != 'tag'" in str(job.get("if", "")) or "!startsWith(github.ref, 'refs/tags" in str(job.get("if", ""))


WRITE_RE = re.compile(
    r"\boras\s+(push|cp|copy|attach|tag)\b|\bdocker\s+(push|manifest\s+push)\b|\bgh\s+release\b|\bskopeo\s+copy\b"
    r"|\bcrane\s+(push|copy)\b|binpkg-store\.sh\s+push\b|\bgh\s+attestation\b")
WRITE_USES_RE = re.compile(r"actions/attest|actions/deploy-pages|actions/upload-pages-artifact|softprops/action-gh-release|gh-release")
WRITE_TARGETS = ("cache-push", "registry-copy", "toolbox-publish", "seed-tree")


def make_targets(run):
    res = []
    for ln in str(run).split("\n"):
        m = re.match(r"\s*make\s+(.*)", ln)
        if m:
            res += [w for w in m.group(1).split() if re.match(r"^[a-z][a-z0-9_.-]*$", w) and "=" not in w]
    return res


def step_is_write(s):
    run = str(s.get("run", ""))
    uses = str(s.get("uses", ""))
    if WRITE_USES_RE.search(uses) or WRITE_RE.search(run):
        return True
    for t in make_targets(run):
        if t in WRITE_TARGETS:
            return True
        if WRITE_RE.search(mk_target(t)):
            return True
    return False


def is_kind(s, kind):
    run = str(s.get("run", ""))
    uses = str(s.get("uses", ""))
    pats = {"artifact": (r"\bmake\s+test-artifact\b", r"artifact-checks"), "gates": (r"\bmake\s+test-gates\b", r"sbom-gates")}[kind]
    return bool(re.search(pats[0], run) or re.search(pats[1], uses))


def check_writes(wf, expand=True):
    """Return a list of violations of P02-AC-3 in the parsed workflow wf."""
    jobs = wf.get("jobs") or {}
    bad = []
    if "compare" not in jobs:
        bad.append("no compare job")
    nwrites = 0
    for jn, j in jobs.items():
        if off_tag(j):
            continue
        steps = job_steps(j)
        cl = closure(jobs, jn)

        def has(kind, upto):
            for c in cl:
                if c == jn or off_tag(jobs.get(c) or {}):
                    continue
                if any(is_kind(s, kind) for s in job_steps(jobs[c])):
                    return True
            return any(is_kind(s, kind) for s in steps[:upto])

        for i, s in enumerate(steps):
            if not step_is_write(s):
                continue
            nwrites += 1
            why = []
            if "compare" not in cl:
                why.append("compare not in needs closure")
            if not any("uses" in (jobs.get(c) or {}) and "boot-test" in str((jobs.get(c) or {}).get("uses")) and not off_tag(jobs[c]) for c in cl):
                why.append("boot-test not in needs closure")
            if not has("artifact", i):
                why.append("no test-artifact before it")
            if not has("gates", i):
                why.append("no test-gates before it")
            cond = str(s.get("if", ""))
            if re.search(r"\b(always|failure|cancelled)\(\)", cond) and "success()" not in cond:
                why.append("write step runs on failure/always")
            jc = str(j.get("if", ""))
            if "always()" in jc and "needs.compare.result == 'success'" not in jc:
                why.append("job if: always() without needs.compare.result == 'success'")
            if why:
                bad.append("%s step %d (%s): %s" % (jn, i, s.get("name", s.get("uses", s.get("run", "")))[:40], "; ".join(why)))
    return bad


# ---- AC-3 detector self-check on synthetic workflows ----
def self_check():
    run = lambda r: {"run": r}
    good = {"jobs": {
        "compare": {"needs": ["build-a", "build-b"], "steps": [run("make compare")]},
        "build-a": {"steps": [run("make repro-build-a")]}, "build-b": {"steps": [run("make repro-build-b")]},
        "boot-test": {"needs": "build-a", "uses": "./.github/workflows/boot-test.yml"},
        "art": {"needs": "build-a", "steps": [run("make test-artifact")]},
        "gates": {"needs": "build-a", "steps": [run("make test-gates")]},
        "pub": {"needs": ["compare", "boot-test", "art", "gates"], "steps": [run("oras push x"), {"uses": "actions/attest@abc"}]},
    }}
    bad = {"jobs": dict(good["jobs"])}
    bad["jobs"]["pub"] = {"needs": ["boot-test", "art", "gates"], "steps": [run("oras push x")]}
    bad2 = {"jobs": dict(good["jobs"])}
    bad2["jobs"]["pub"] = {"needs": ["compare", "boot-test", "art"], "steps": [{"uses": "actions/attest@abc"}]}
    g = check_writes(good)
    b = check_writes(bad)
    b2 = check_writes(bad2)
    return (not g and b and b2), "good=%s bad=%s bad2=%s" % (g, b, b2)


case("P02-AC-3 detector self-check: a writer needing compare, boot-test, artifact checks and gates passes; one missing compare or the gates is flagged", self_check)

# ---- AC-1 ----
wf = None
try:
    wf = load(BW)
except Exception as e:
    wferr = str(e)
jobs = (wf or {}).get("jobs") or {}


def need_wf():
    if wf is None:
        raise RuntimeError("cannot parse build.yml: " + wferr)


def ac1_jobs():
    need_wf()
    miss = [n for n in ("fetch", "build-a", "build-b", "compare") if n not in jobs]
    return (not miss, "missing jobs: %s" % miss)


case("P02-AC-1 build.yml has the separate jobs fetch, build-a, build-b and compare", ac1_jobs)


def ac1_tag():
    need_wf()
    bad = [n for n in ("fetch", "build-a", "build-b", "compare") if n not in jobs or off_tag(jobs[n])]
    ev = (wf.get(True) or wf.get("on") or {})
    tags = bool((ev.get("push") or {}).get("tags"))
    return (not bad and tags, "excluded from the tag path or missing: %s; push tags=%s" % (bad, tags))


case("P02-AC-1 the four gate jobs run on the tag path (not excluded by their if:)", ac1_tag)


def ac1_noneeds():
    need_wf()
    a, b = "build-a", "build-b"
    if a not in jobs or b not in jobs:
        return False, "build-a or build-b missing"
    ok = b not in closure(jobs, a) and a not in closure(jobs, b)
    return ok, "needs closure: a=%s b=%s" % (closure(jobs, a), closure(jobs, b))


case("P02-AC-1 neither build-a nor build-b has a needs: on the other (closure included)", ac1_noneeds)


def ac1_fetch():
    need_wf()
    bad = []
    for n in ("build-a", "build-b"):
        if "fetch" not in closure(jobs, n):
            bad.append(n + " does not need fetch")
    if "compare" in jobs:
        cl = closure(jobs, "compare")
        for n in ("build-a", "build-b"):
            if n not in cl:
                bad.append("compare does not need " + n)
    else:
        bad.append("no compare job")
    return (not bad, "; ".join(bad))


case("P02-AC-1 build-a and build-b need fetch, compare needs both builds", ac1_fetch)


def ac1_inputs():
    need_wf()
    bad = []
    for n in ("build-a", "build-b"):
        j = jobs.get(n)
        if j is None:
            bad.append(n + " missing")
            continue
        if "uses" in j and not str(j["uses"]).startswith("./"):
            bad.append(n + " calls an outside workflow")
        steps = job_steps(j)
        if not steps:
            bad.append(n + " has no steps")
        got_dl = False
        for s in steps:
            u, run = str(s.get("uses", "")), str(s.get("run", ""))
            if "actions/cache" in u:
                bad.append(n + " uses actions/cache")
            if re.search(r"\bcache-(pull|push)\b|binpkg-store\.sh", run) or any(t in ("cache-pull", "cache-push", "take-packages") for t in make_targets(run)):
                bad.append(n + " pulls or pushes binpkgs")
            if re.search(r"docker\s+volume|--volumes-from|\bscp\b|\brsync\b", run):
                bad.append(n + " shares a volume")
            if "download-artifact" in u:
                got_dl = True
                nm = str((s.get("with") or {}).get("name", ""))
                if not re.search(r"distfiles|release-inputs", nm):
                    bad.append("%s downloads artifact %r (only distfiles and release-inputs allowed)" % (n, nm))
            if "upload-artifact" in u or "download-artifact" in u or "checkout" in u or run:
                pass
            if u and not re.search(r"actions/(checkout|upload-artifact|download-artifact)@", u):
                bad.append("%s uses %s" % (n, u[:40]))
        if not got_dl:
            bad.append(n + " does not download the distfiles artifact")
        # no outputs or artifacts of the sibling build
        other = "build-b" if n == "build-a" else "build-a"
        if re.search(r"needs\.%s\b" % re.escape(other), str(j)):
            bad.append(n + " reads the outputs of " + other)
    return (not bad, "; ".join(bad))


case("P02-AC-1 build-a and build-b take only the checkout, release-inputs.json and the distfiles artifact (no actions/cache, binpkg pull, shared volume or artifact between them)", ac1_inputs)

# ---- AC-3 ----
def ac3():
    need_wf()
    bad = check_writes(wf)
    return (not bad, "; ".join(bad))


case("P02-AC-3 on the tag path every write (oras push, docker push, gh release, attest, Pages, registry-writing make target) has compare, boot-test, test-artifact and test-gates before it", ac3)


def ac3_cache():
    need_wf()
    bad = []
    for n, j in jobs.items():
        if off_tag(j):
            continue
        for s in job_steps(j):
            if any(t in ("cache-push",) for t in make_targets(str(s.get("run", "")))):
                if "compare" not in closure(jobs, n):
                    bad.append(n)
    return (not bad, "cache-push on the tag path without compare in needs: %s" % bad)


case("P02-AC-3 make cache-push (a registry write) is not reachable on the tag path before compare", ac3_cache)


def ac3_gate_jobs():
    need_wf()
    # boot modes, artifact checks and gates run on a tag, and publication (P01) can need them
    kinds = {"boot": False, "artifact": False, "gates": False}
    for n, j in jobs.items():
        if off_tag(j):
            continue
        if "boot-test" in str(j.get("uses", "")):
            kinds["boot"] = True
        for s in job_steps(j):
            for k in ("artifact", "gates"):
                if is_kind(s, k):
                    kinds[k] = True
    return (all(kinds.values()), "tag-path coverage %s" % kinds)


case("P02-AC-3 the boot modes, the artifact checks and the gates are all part of the tag path", ac3_gate_jobs)

# ---- AC-4 / AC-5 second sentence: make -n of the two offline builds ----
FX = os.path.join(TMP, "ri-fixture.json")
S = {"BUILDER_DIGEST": "4" * 64, "TREE_DIGEST": "3" * 64, "TREE_COMMIT": "2" * 40, "SOURCE_DATE_EPOCH": "1234567890"}
ENVSENT = {"BUILDER_DIGEST": "sha256:" + "9" * 64, "TREE_DIGEST": "sha256:" + "9" * 64, "TREE_COMMIT": "8" * 40, "SOURCE_DATE_EPOCH": "987654321"}
mkout = {}
for t in ("a", "b"):
    try:
        rc, o = mk(["repro-build-" + t, "RELEASE_INPUTS=" + FX])
    except Exception as e:
        rc, o = 1, str(e)
    mkout[t] = (rc, o)
    try:
        rc2, o2 = mk(["repro-build-" + t, "RELEASE_INPUTS=" + FX], ENVSENT)
    except Exception as e:
        rc2, o2 = 1, str(e)
    mkout[t + "-env"] = (rc2, o2)


def run_lines(o, scripts=r"build-(packages|rootfs|initrd|iso)\.sh"):
    return [ln for ln in o.split("\n") if re.search(r"\brun\b", ln) and re.search(scripts, ln)]


def ac4_net(t):
    def f():
        rc, o = mkout[t]
        if rc != 0:
            return False, "make -n repro-build-%s rc=%d: %s" % (t, rc, o.strip().split("\n")[-1])
        lines = run_lines(o)
        got = {re.search(r"build-(packages|rootfs|initrd|iso)\.sh", ln).group(1) for ln in lines}
        miss = {"packages", "rootfs", "initrd", "iso"} - got
        bad = [ln[:80] for ln in lines if not re.search(r"--network[= ]none\b", ln)]
        return (not miss and not bad, "no container run for %s; runs without --network none: %s" % (sorted(miss), bad))
    return f


for t in ("a", "b"):
    case("P02-AC-4 every ISO-producing container run of build %s (packages, rootfs, initrd, iso) has --network none" % t.upper(), ac4_net(t))


def ac4_fetch(t):
    def f():
        rc, o = mkout[t]
        if rc != 0:
            return False, "make -n failed"
        pk = [ln for ln in run_lines(o, r"build-packages\.sh")]
        ok = bool(pk) and all(re.search(r"FETCHCOMMAND=/bin/false\b", ln) and re.search(r"RESUMECOMMAND=/bin/false\b", ln) and re.search(r"MONOLITH_USEPKG=n\b", ln) for ln in pk)
        return ok, "build-packages run lacks FETCHCOMMAND/RESUMECOMMAND=/bin/false or MONOLITH_USEPKG=n: %s" % [ln[:120] for ln in pk]
    return f


for t in ("a", "b"):
    case("P02-AC-4 build %s disables Portage fetching (FETCHCOMMAND and RESUMECOMMAND set to /bin/false, release mode)" % t.upper(), ac4_fetch(t))


def ac4_check(t):
    def f():
        rc, o = mkout[t]
        return rc == 0 and "check-distfiles.sh" in o, "make -n repro-build-%s does not run scripts/check-distfiles.sh" % t
    return f


for t in ("a", "b"):
    case("P02-AC-4 build %s runs the distfiles check (a missing distfile fails and names the file) before the build" % t.upper(), ac4_check(t))


def ac4_order(t):
    def f():
        rc, o = mkout[t]
        i, j = o.find("check-distfiles.sh"), o.find("build-packages.sh")
        return rc == 0 and 0 <= i < j, "distfiles check at %d, package build at %d" % (i, j)
    return f


for t in ("a", "b"):
    case("P02-AC-4 build %s checks the distfiles before it builds packages" % t.upper(), ac4_order(t))


def hostjobs():
    ra, oa = mkout["a"]
    rb, ob = mkout["b"]
    if ra or rb:
        return False, "make -n of a build failed"

    def hosts(o):
        return set(re.findall(r"(?:--hostname[= ]|\s-h\s)(\S+)", "\n".join(run_lines(o))))

    def jobsv(o):
        return set(re.findall(r"(?:-e JOBS=|--jobs[= ])(\S+)", "\n".join(run_lines(o, r"build-packages\.sh"))))
    ha, hb, ja, jb = hosts(oa), hosts(ob), jobsv(oa), jobsv(ob)
    return (bool(ha) and bool(hb) and ha != hb and not (ha & hb), "hostnames a=%s b=%s" % (ha, hb)), (bool(ja) and bool(jb) and ja != jb, "jobs a=%s b=%s" % (ja, jb))


def host_case():
    r = hostjobs()
    return r[0] if isinstance(r[0], tuple) else r


def jobs_case():
    r = hostjobs()
    return r[1] if isinstance(r[0], tuple) else r


case("P02-AC-4 build B runs its containers with a different --hostname from build A (and each sets one)", host_case)
case("P02-AC-4 build B builds packages with a different --jobs value (JOBS) from build A", jobs_case)


def ac5_pins(t):
    def f():
        rc, o = mkout[t]
        if rc:
            return False, "make -n failed"
        miss = [k for k in ("BUILDER_DIGEST", "TREE_DIGEST", "TREE_COMMIT", "SOURCE_DATE_EPOCH") if S[k] not in o]
        return not miss, "values from release-inputs.json absent from make -n: %s" % miss
    return f


def ac5_env(t):
    def f():
        rc, o = mkout[t + "-env"]
        if rc:
            return False, "make -n failed"
        leak = [k for k in ENVSENT if ENVSENT[k].split(":")[-1] in o]
        return not leak, "runner environment values used: %s" % leak
    return f


def ac5_mk(t):
    def f():
        rc, o = mkout[t]
        return rc == 0 and not re.search(r"6e88ed01f3e97de8710efe1c333808dfbd05bf32|ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa|b01bbe7a886fa869a4018a5f711e11fae8fb783b30878216b0f8f408ad2a70bd", o), "the Makefile's own pins appear in make -n repro-build-%s (build reads pins from release-inputs.json)" % t
    return f


case("P02-AC-5 build B takes BUILDER_DIGEST, TREE_DIGEST, TREE_COMMIT and SOURCE_DATE_EPOCH from release-inputs.json", ac5_pins("b"))
case("P02-AC-5 build B ignores BUILDER_DIGEST, TREE_DIGEST, TREE_COMMIT and SOURCE_DATE_EPOCH set in the runner environment", ac5_env("b"))
case("P02-AC-5 build B's pins are not the Makefile's own (nothing comes from the checkout's pin lines, a runner, volume or cache)", ac5_mk("b"))


def ac5_job():
    need_wf()
    j = jobs.get("build-b")
    if j is None:
        return False, "no build-b job"
    pins = ("BUILDER_DIGEST", "TREE_DIGEST", "TREE_COMMIT", "SOURCE_DATE_EPOCH", "BUILDER_REF", "TREE_REF")
    bad = []
    top = wf.get("env") or {}
    for k in pins:
        if k in top or k in (j.get("env") or {}):
            bad.append("env " + k)
    for s in job_steps(j):
        for k in pins:
            if k in (s.get("env") or {}) or re.search(r"\b%s=" % k, str(s.get("run", ""))):
                bad.append("step sets " + k)
        for k, v in list((s.get("env") or {}).items()) + list((s.get("with") or {}).items()):
            if re.search(r"\b(vars|runner|secrets)\.|actions/cache|\bcache\b", str(v)) and "GITHUB_TOKEN" not in str(k):
                bad.append("%s reads %s" % (k, str(v)[:40]))
    dl = [str((s.get("with") or {}).get("name", "")) for s in job_steps(j) if "download-artifact" in str(s.get("uses", ""))]
    if not any("release-inputs" in n for n in dl):
        bad.append("does not download release-inputs.json")
    return (not bad, "; ".join(bad))


case("P02-AC-5 build-b's job sets none of the pins itself, reads no var/runner/cache value, and downloads release-inputs.json", ac5_job)

# ---- AC-8 ----
def mkdb():
    env = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MAKELEVEL", "MFLAGS", "MAKEOVERRIDES")}
    p = subprocess.run(["make", "-pn", "test-repro"], cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
    return p.stdout


def prereqs(db, t):
    m = re.search(r"^%s:(?!=)\s*([^\n#]*)" % re.escape(t), db, re.M)
    return m.group(1).split() if m else None


def ac8_test():
    db = mkdb()
    p = prereqs(db, "test")
    return (p is not None and "test-repro" in p, "prerequisites of test: %s" % p)


def ac8_parts():
    db = mkdb()
    p = prereqs(db, "test-repro")
    want = ["repro-fetch", "repro-build-a", "repro-build-b", "compare"]
    if p is None:
        return False, "no test-repro target"
    pos = [p.index(w) if w in p else -1 for w in want]
    return (all(x >= 0 for x in pos) and pos == sorted(pos), "prerequisites of test-repro: %s" % p)


def ac8_n():
    rc, o = mk(["test-repro"])
    iso = [ln for ln in o.split("\n") if re.search(r"\brun\b", ln) and "build-iso.sh" in ln]
    return (rc == 0 and len(iso) >= 2 and "compare-isos.sh" in o and "fetch-distfiles.sh" in o, "rc=%d; ISO runs=%d; compare-isos=%s; fetch-distfiles=%s" % (rc, len(iso), "compare-isos.sh" in o, "fetch-distfiles.sh" in o))


case("P02-AC-8 make test depends on test-repro", ac8_test)
case("P02-AC-8 test-repro runs repro-fetch, repro-build-a, repro-build-b and compare as Make targets, in that order", ac8_parts)
case("P02-AC-8 make -n test-repro fetches distfiles, runs two offline ISO builds and compares them", ac8_n)

JOBTARGET = {"fetch": "repro-fetch", "build-a": "repro-build-a", "build-b": "repro-build-b", "compare": "compare"}


def ac8_job(n):
    def f():
        need_wf()
        j = jobs.get(n)
        if j is None:
            return False, "no %s job" % n
        if "uses" in j:
            return False, "job calls a workflow, not a Make target"
        steps = j.get("steps") or []
        targets, bad = [], []
        for s in steps:
            u, run = str(s.get("uses", "")), str(s.get("run", ""))
            if u:
                if not re.match(r"actions/(checkout|upload-artifact|download-artifact)@", u):
                    bad.append("uses " + u[:40])
                continue
            if re.match(r"\s*make\s", run):
                ts = make_targets(run)
                if ts == ["build-version"]:
                    continue
                targets += ts
            elif re.match(r"\s*toolbox/run\b", run):
                if re.search(r"\btests?\b|test-|\.test\.sh|\bmake\b", run):
                    bad.append("test logic in " + run[:50])
            else:
                bad.append("other step: " + run[:50])
        ok = targets == [JOBTARGET[n]] and not bad
        return ok, "make targets=%s (want [%s]); %s" % (targets, JOBTARGET[n], "; ".join(bad))
    return f


for n in ("fetch", "build-a", "build-b", "compare"):
    case("P02-AC-8 the %s job runs exactly the Make target %s and no other test logic" % (n, JOBTARGET[n]), ac8_job(n))

sys.exit(0)
PYEOF
py_out=$(python3 -I "$TMP/slice2.py" "$ROOT" "$TMP" 2>&1); py_rc=$?
echo "$py_out"
n_py_fail=$(echo "$py_out" | grep -c '^FAIL' || true)
fails=$((fails + n_py_fail))
if [ "$py_rc" -ne 0 ]; then fail "P02 slice 2 python harness exited $py_rc"; fi
# ================= slice 3: P02-AC-6 static support (changes 3-6) =================
# These cases support P02-AC-6 (whose verdict is the dispatch run's compare log); each names the change.
# Interfaces chosen for slice 3:
#   Change 3  configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-6.12.80-r10.ebuild exports
#             KBUILD_BUILD_TIMESTAMP=@${SOURCE_DATE_EPOCH}, KBUILD_BUILD_USER=monolith, KBUILD_BUILD_HOST=monolith,
#             KBUILD_BUILD_VERSION=1; configs/portage/versions.lock pins sys-kernel/monolith-kernel:6.12.80-r10:0.
#             The r9 ebuild stays: frozen kernel-ebuild.test.sh (B02-AC-1) reads the r9 path.
#   Change 4  scripts/build-initrd.sh: the archive step is the lines that begin with `find . ` (clamp, then
#             sort | cpio | gzip), run with the working directory = INITRD_DIR and INITRD_IMAGE, SOURCE_DATE_EPOCH
#             in the environment; `touch -h -d @${SOURCE_DATE_EPOCH}` on every entry, `cpio --reproducible`.
#   Change 5  static greps of scripts/build-iso.sh and scripts/build-rootfs.sh (non-comment lines only).
#   Change 6  sh scripts/normalize-vdb.sh <vdb-dir>   (POSIX sh; SOURCE_DATE_EPOCH from the environment, an error
#             naming SOURCE_DATE_EPOCH when unset; rewrites only the given directory, a rootfs copy of
#             var/db/pkg, in place) called by scripts/build-rootfs.sh after the VDB is copied in and before the
#             mtime clamp and mksquashfs. It uses bzip2 -9 (the toolbox has no bzip2: this test puts a python
#             bz2-backed bzip2/bzcat/bunzip2 on PATH; libbz2 level 9 is the same output as bzip2 -9).
#             Per package dir <cat>/<pn-pv>/: BUILD_TIME := SOURCE_DATE_EPOCH; COUNTER := 1..N in sorted
#             cpv order (LC_ALL=C sort of category/pn-pv); environment.bz2 loses `declare ... NAME=` lines for
#             the volatile variables EPOCHREALTIME EPOCHSECONDS SRANDOM RANDOM BASHPID and is recompressed with
#             bzip2 -9; in CONTENTS the trailing mtime of every `obj` and `sym` line := SOURCE_DATE_EPOCH.
#             All other files and lines are untouched.
#   Every build script of changes 4-6 exits non-zero naming SOURCE_DATE_EPOCH when it is unset, before any
#   other work, and has no ${SOURCE_DATE_EPOCH:-...} fallback.
SDE=1786489256
nc() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null; }
fline() { nc_n=$(grep -n -E -e "$2" "$1" 2>/dev/null | grep -v -E '^[0-9]+:[[:space:]]*#' | head -n 1 | cut -d: -f1); echo "${nc_n:-}"; }
lline() { grep -n -E -e "$2" "$1" 2>/dev/null | grep -v -E '^[0-9]+:[[:space:]]*#' | tail -n 1 | cut -d: -f1; }
s3check() { d=$1; shift; if "$@" 2>/dev/null; then pass "$d"; else fail "$d"; fi; }

# ---- change 3: kernel r10 ----
K10="$ROOT/configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-6.12.80-r10.ebuild"
if [ -f "$K10" ]; then pass "P02-AC-6 change 3: monolith-kernel-6.12.80-r10.ebuild exists"; else fail "P02-AC-6 change 3: monolith-kernel-6.12.80-r10.ebuild exists"; fi
s3check "P02-AC-6 change 3: r10 exports KBUILD_BUILD_TIMESTAMP=@\${SOURCE_DATE_EPOCH}" \
	grep -Eq 'KBUILD_BUILD_TIMESTAMP="?@\$\{SOURCE_DATE_EPOCH\}"?' "$K10"
s3check "P02-AC-6 change 3: r10 exports KBUILD_BUILD_USER=monolith" grep -Eq '^[[:space:]]*export[[:space:]]+KBUILD_BUILD_USER="?monolith"?([[:space:]]|$)' "$K10"
s3check "P02-AC-6 change 3: r10 exports KBUILD_BUILD_HOST=monolith" grep -Eq '^[[:space:]]*export[[:space:]]+KBUILD_BUILD_HOST="?monolith"?([[:space:]]|$)' "$K10"
s3check "P02-AC-6 change 3: r10 exports KBUILD_BUILD_VERSION=1" grep -Eq '^[[:space:]]*export[[:space:]]+KBUILD_BUILD_VERSION="?1"?([[:space:]]|$)' "$K10"
s3check "P02-AC-6 change 3: r10 timestamp is an export" grep -Eq '^[[:space:]]*export[[:space:]]+KBUILD_BUILD_TIMESTAMP=' "$K10"
if [ -f "$K10" ] && ! grep -Eq 'SOURCE_DATE_EPOCH:[-=]' "$K10"; then pass "P02-AC-6 change 3: r10 has no SOURCE_DATE_EPOCH fallback"; else fail "P02-AC-6 change 3: r10 has no SOURCE_DATE_EPOCH fallback (or no r10)"; fi
s3check "P02-AC-6 change 3: r10 still inherits savedconfig" grep -Eq '^[[:space:]]*inherit[[:space:]].*\bsavedconfig\b' "$K10"
s3check "P02-AC-6 change 3: versions.lock pins sys-kernel/monolith-kernel:6.12.80-r10:0" \
	grep -Fxq 'sys-kernel/monolith-kernel:6.12.80-r10:0' "$ROOT/configs/portage/versions.lock"
n=$(grep -c '^sys-kernel/monolith-kernel:' "$ROOT/configs/portage/versions.lock")
if [ "$n" -eq 1 ]; then pass "P02-AC-6 change 3: versions.lock has exactly one kernel line"; else fail "P02-AC-6 change 3: versions.lock has exactly one kernel line (got $n)"; fi

# ---- change 4: initrd ----
BI="$ROOT/scripts/build-initrd.sh"
s3check "P02-AC-6 change 4: initrd clamp is touch -h -d @\${SOURCE_DATE_EPOCH} on every entry" \
	sh -c "grep -v '^[[:space:]]*#' '$BI' | grep -Eq 'touch -h -d \"?@\\\$\\{SOURCE_DATE_EPOCH\\}\"?'"
if nc "$BI" | grep -E '^find \. ' | grep -q -e '-not -type l'; then fail "P02-AC-6 change 4: initrd clamp no longer skips symlinks"; else pass "P02-AC-6 change 4: initrd clamp no longer skips symlinks"; fi
s3check "P02-AC-6 change 4: initrd cpio uses --reproducible" sh -c "grep -v '^[[:space:]]*#' '$BI' | grep -Eq 'cpio .*--reproducible'"

# behavioural: run the script's own `find . ` lines on a fixture tree holding a symlink
mkfix() { # mkfix <dir> <extra-pre-files>
	mkdir -p "$1/bin" "$1/etc" "$1/dev"
	echo busy >"$1/bin/busybox"; ln -s busybox "$1/bin/sh"; ln -s /nonexistent "$1/etc/dangling"
	echo x >"$1/etc/passwd"
	touch -h -d @1700000000 "$1/bin/busybox" "$1/bin/sh" "$1/etc/dangling" "$1/etc/passwd" "$1/bin" "$1/etc" "$1/dev" "$1"
}
run_archive() { # run_archive <treedir> <out.gz>
	nc "$BI" | grep -E '^find \. ' >"$TMP/archive-lines.sh"
	if [ ! -s "$TMP/archive-lines.sh" ]; then return 1; fi
	(cd "$1" && env SOURCE_DATE_EPOCH="$SDE" INITRD_IMAGE="$2" sh "$TMP/archive-lines.sh") >"$TMP/archive.log" 2>&1
}
mkfix "$TMP/ird1"
mkdir -p "$TMP/ird2-pre"; echo pad >"$TMP/ird2-pre/pad"; echo pad2 >"$TMP/ird2-pre/pad2"
mkfix "$TMP/ird2"
if run_archive "$TMP/ird1" "$TMP/ird1.gz"; then
	odd=$(cd "$TMP/ird1" && find . -printf '%Ts\n' | sort -u | tr '\n' ' ')
	if [ "$odd" = "$SDE " ]; then pass "P02-AC-6 change 4: every initrd entry incl. symlinks has mtime SOURCE_DATE_EPOCH"; else fail "P02-AC-6 change 4: every initrd entry incl. symlinks has mtime SOURCE_DATE_EPOCH (mtimes: $odd)"; fi
else
	fail "P02-AC-6 change 4: the initrd archive step runs on a fixture tree ($(head -c 200 "$TMP/archive.log" 2>/dev/null))"
	fail "P02-AC-6 change 4: every initrd entry incl. symlinks has mtime SOURCE_DATE_EPOCH (archive step did not run)"
fi
if run_archive "$TMP/ird2" "$TMP/ird2.gz" && cmp -s "$TMP/ird1.gz" "$TMP/ird2.gz"; then
	pass "P02-AC-6 change 4: the archive is byte-identical for trees that differ only in inode numbers"
else
	fail "P02-AC-6 change 4: the archive is byte-identical for trees that differ only in inode numbers"
fi

# ---- change 5: ISO, ESP, grub memdisk, squashfs ----
BIS="$ROOT/scripts/build-iso.sh"
s3check "P02-AC-6 change 5: xorriso -volume_date all_file_dates =\${SOURCE_DATE_EPOCH}" \
	sh -c "grep -v '^[[:space:]]*#' '$BIS' | grep -Eq -e '-volume_date[[:space:]]+all_file_dates[[:space:]]+\"?=\\\$\\{SOURCE_DATE_EPOCH\\}\"?'"
s3check "P02-AC-6 change 5: xorriso -volume_date uuid is derived (a \$ expression), not a literal" \
	sh -c "grep -v '^[[:space:]]*#' '$BIS' | grep -Eq -e '-volume_date[[:space:]]+uuid[[:space:]]+\"?\\\$'"
s3check "P02-AC-6 change 5: the uuid is derived from SOURCE_DATE_EPOCH in xorriso's 16-digit form" \
	sh -c "grep -v '^[[:space:]]*#' '$BIS' | grep -E 'date ' | grep 'SOURCE_DATE_EPOCH' | grep -Eq '%Y%m%d%H%M%S'"
s3check "P02-AC-6 change 5: the volume id is fixed (no variable)" \
	sh -c "grep -v '^[[:space:]]*#' '$BIS' | grep -Eq -e '(^|[[:space:]])(-V|-volid)[[:space:]]+\"[A-Z0-9_]+\"'"
s3check "P02-AC-6 change 5: the ESP is made with mkfs.vfat --invariant" \
	sh -c "grep -v '^[[:space:]]*#' '$BIS' | grep -E 'mkfs.vfat' | grep -Eq -e '--invariant'"
s3check "P02-AC-6 change 5: mkfs.vfat has a fixed volume id (-i <8 hex digits>)" \
	sh -c "grep -v '^[[:space:]]*#' '$BIS' | grep -E 'mkfs.vfat' | grep -Eq -e '-i[[:space:]]+\"?[0-9A-Fa-f]{8}\"?([[:space:]]|\$)'"
gm=$(fline "$BIS" 'grub-mkstandalone'); mc=$(fline "$BIS" '^[[:space:]]*mcopy ')
tg=$(fline "$BIS" 'touch .*SOURCE_DATE_EPOCH.*GRUB_CFG')
if [ -n "$gm" ] && [ -n "$tg" ] && [ "$tg" -lt "$gm" ]; then pass "P02-AC-6 change 5: the grub memdisk input is clamped to SOURCE_DATE_EPOCH before grub-mkstandalone"; else fail "P02-AC-6 change 5: the grub memdisk input is clamped to SOURCE_DATE_EPOCH before grub-mkstandalone (touch line '${tg:-none}', grub-mkstandalone line '${gm:-none}')"; fi
te=$(fline "$BIS" 'touch .*SOURCE_DATE_EPOCH.*(BOOTX64|ISO_DIR)')
if [ -n "$mc" ] && [ -n "$te" ] && [ "$te" -lt "$mc" ]; then pass "P02-AC-6 change 5: the EFI binary mtime is clamped before mcopy"; else fail "P02-AC-6 change 5: the EFI binary mtime is clamped before mcopy (touch line '${te:-none}', mcopy line '${mc:-none}')"; fi
s3check "P02-AC-6 change 5: mcopy preserves the (clamped) mtime with -m" \
	sh -c "grep -v '^[[:space:]]*#' '$BIS' | grep -E '^[[:space:]]*mcopy ' | grep -Eq -e 'mcopy( -[a-zA-Z]+)* -[a-zA-Z]*m'"

BR="$ROOT/scripts/build-rootfs.sh"
ms=$(fline "$BR" '^[[:space:]]*mksquashfs ')
nv=$(lline "$BR" 'normalize-vdb\.sh')
cl=$(lline "$BR" 'touch -h .*SOURCE_DATE_EPOCH')
if [ -n "$ms" ] && [ -n "$cl" ] && [ "$cl" -lt "$ms" ]; then pass "P02-AC-6 change 5: build-rootfs.sh clamps rootfs mtimes (touch -h ... SOURCE_DATE_EPOCH) before mksquashfs"; else fail "P02-AC-6 change 5: build-rootfs.sh clamps rootfs mtimes (touch -h ... SOURCE_DATE_EPOCH) before mksquashfs (clamp '${cl:-none}', mksquashfs '${ms:-none}')"; fi
if [ -n "$cl" ] && nc "$BR" | grep -E 'touch -h .*SOURCE_DATE_EPOCH' | grep -q 'ROOTFS_DIR'; then pass "P02-AC-6 change 5: the clamp covers \$ROOTFS_DIR"; else fail "P02-AC-6 change 5: the clamp covers \$ROOTFS_DIR"; fi
msl=$(awk '/^[[:space:]]*mksquashfs /{f=1} f{print} f&&!/\\$/{exit}' "$BR")
if [ -n "$msl" ] && ! echo "$msl" | grep -q -e '-all-time'; then pass "P02-AC-6 change 5: mksquashfs keeps its own SOURCE_DATE_EPOCH handling (no -all-time)"; else fail "P02-AC-6 change 5: mksquashfs keeps its own SOURCE_DATE_EPOCH handling (no -all-time)"; fi

# ---- change 6: shipped VDB normalisation ----
NV="$ROOT/scripts/normalize-vdb.sh"
if [ -n "$nv" ] && [ -n "$ms" ] && [ "$nv" -lt "$ms" ]; then pass "P02-AC-6 change 6: build-rootfs.sh calls normalize-vdb.sh before mksquashfs"; else fail "P02-AC-6 change 6: build-rootfs.sh calls normalize-vdb.sh before mksquashfs (call '${nv:-none}', mksquashfs '${ms:-none}')"; fi
if [ -n "$nv" ] && [ -n "$cl" ] && [ "$nv" -lt "$cl" ]; then pass "P02-AC-6 change 6: the VDB is normalised before the mtime clamp"; else fail "P02-AC-6 change 6: the VDB is normalised before the mtime clamp (call '${nv:-none}', clamp '${cl:-none}')"; fi
s3check "P02-AC-6 change 6: normalize-vdb.sh uses bzip2 -9" sh -c "grep -v '^[[:space:]]*#' '$NV' | grep -Eq 'bzip2 .*-9|bzip2 -9'"

mkdir -p "$TMP/s3stubs"
cat >"$TMP/s3stubs/bzpy.py" <<'PYEOF'
import sys, bz2, os
prog = os.path.basename(sys.argv[0])
dec = prog in ("bzcat", "bunzip2")
cout = prog == "bzcat"
files = []
keep = False
for a in sys.argv[1:]:
    if a.startswith("-") and len(a) > 1 and not a.startswith("--"):
        for c in a[1:]:
            if c == "d": dec = True
            elif c == "c": cout = True
            elif c == "k": keep = True
    elif a == "--decompress": dec = True
    elif a == "--stdout": cout = True
    elif not a.startswith("--"):
        files.append(a)
def conv(b):
    return bz2.decompress(b) if dec else bz2.compress(b, 9)
if not files:
    sys.stdout.buffer.write(conv(sys.stdin.buffer.read())); sys.exit(0)
for f in files:
    data = conv(open(f, "rb").read())
    if cout:
        sys.stdout.buffer.write(data)
    else:
        o = f[:-4] if dec and f.endswith(".bz2") else (f if dec else f + ".bz2")
        open(o, "wb").write(data)
        if not keep and o != f: os.unlink(f)
PYEOF
# one python file per tool name so argv[0]'s basename selects the mode
for t in bzip2 bzcat bunzip2; do cp "$TMP/s3stubs/bzpy.py" "$TMP/s3stubs/$t.py"; printf '#!/bin/sh\nexec python3 -I "%s/%s.py" "$@"\n' "$TMP/s3stubs" "$t" >"$TMP/s3stubs/$t"; chmod +x "$TMP/s3stubs/$t"; done
sed -i 's/^prog = .*/prog = os.path.basename(sys.argv[0])[:-3]/' "$TMP/s3stubs/bzip2.py" "$TMP/s3stubs/bzcat.py" "$TMP/s3stubs/bunzip2.py"

# fixture VDB: variant 1 and 2 differ in BUILD_TIME, COUNTER, volatile env lines, CONTENTS mtimes, bz2 level, creation order
bzc() { python3 -I -c 'import sys,bz2;sys.stdout.buffer.write(bz2.compress(sys.stdin.buffer.read(),int(sys.argv[1])))' "$1"; }
mkvdb() { # mkvdb <dir> <variant 1|2>
	d=$1; v=$2
	if [ "$v" = 1 ]; then pk="app-misc/foo-1.0 dev-libs/baz-3 sys-apps/bar-2.1-r1"; lvl=9; else pk="sys-apps/bar-2.1-r1 dev-libs/baz-3 app-misc/foo-1.0"; lvl=1; fi
	i=0
	for p in $pk; do
		i=$((i + 1)); mkdir -p "$d/$p"
		case $p in app-misc/foo-1.0) c1=5; c2=31 ;; dev-libs/baz-3) c1=9; c2=7 ;; sys-apps/bar-2.1-r1) c1=2; c2=19 ;; esac
		if [ "$v" = 1 ]; then cnt=$c1; bt=170000000$i; mt=170100000$i; else cnt=$c2; bt=171000000$i; mt=172200000$i; fi
		echo "$bt" >"$d/$p/BUILD_TIME"; echo "$cnt" >"$d/$p/COUNTER"
		echo "i486-linux-musl" >"$d/$p/CHOST"; echo "ssl ipv6" >"$d/$p/USE"; printf '8\n' >"$d/$p/EAPI"
		{
			echo "dir /usr"; echo "dir /usr/bin"
			echo "obj /usr/bin/${p##*/} d41d8cd98f00b204e9800998ecf8427e $mt"
			echo "sym /usr/bin/${p##*/}-link -> ${p##*/} $mt"
		} >"$d/$p/CONTENTS"
		{
			echo 'declare -x CHOST="i486-linux-musl"'
			echo "declare -- EPOCHREALTIME=\"$bt.$i\""
			echo 'declare -x PN="'"${p##*/}"'"'
			echo "declare -r EPOCHSECONDS=\"$bt\""
			echo "declare -i BASHPID=\"$((cnt * 1000 + i))\""
			echo "declare -- SRANDOM=\"$((cnt * 77777))\""
			echo "declare -i RANDOM=\"$((cnt * 311))\""
			echo 'src_install ()'; echo '{'; echo '    emake DESTDIR="${D}" install'; echo '}'
			echo 'declare -x ARCH="x86"'
		} | bzc "$lvl" >"$d/$p/environment.bz2"
	done
}
expect_env() { # expect_env <pn> : the non-volatile lines in original order
	echo 'declare -x CHOST="i486-linux-musl"'; echo 'declare -x PN="'"$1"'"'
	echo 'src_install ()'; echo '{'; echo '    emake DESTDIR="${D}" install'; echo '}'; echo 'declare -x ARCH="x86"'
}
treesum() { (cd "$1" && { find . | LC_ALL=C sort; find . -type f | LC_ALL=C sort | xargs sha256sum; } | sha256sum | cut -d' ' -f1); }

run_nv() { # run_nv <dir> ; rc/out
	out=$(env PATH="$TMP/s3stubs:$PATH" SOURCE_DATE_EPOCH="$SDE" sh "$NV" "$1" 2>&1); rc=$?
}
mkvdb "$TMP/vdb1" 1; mkvdb "$TMP/vdb2" 2
mkvdb "$TMP/builder-vdb" 1; builder_before=$(treesum "$TMP/builder-vdb")
cp -a "$TMP/vdb1" "$TMP/rootfs-copy1"; cp -a "$TMP/vdb2" "$TMP/rootfs-copy2"; cp -a "$TMP/builder-vdb" "$TMP/rootfs-copy3"
if [ -f "$NV" ]; then
	run_nv "$TMP/rootfs-copy1"; rc1=$rc
	run_nv "$TMP/rootfs-copy2"; rc2=$rc
	run_nv "$TMP/rootfs-copy3"
else
	rc1=127; rc2=127; echo "no $NV" >"$TMP/nv.err"
fi
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; then pass "P02-AC-6 change 6: normalize-vdb.sh <vdb-dir> exits 0 on the fixture VDBs"; else fail "P02-AC-6 change 6: normalize-vdb.sh <vdb-dir> exits 0 on the fixture VDBs (rc=$rc1/$rc2)"; fi
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$(treesum "$TMP/rootfs-copy1")" = "$(treesum "$TMP/rootfs-copy2")" ]; then pass "P02-AC-6 change 6: two VDBs differing in BUILD_TIME, COUNTER, order, volatile env lines and CONTENTS mtimes normalise to identical trees"; else fail "P02-AC-6 change 6: two VDBs differing in BUILD_TIME, COUNTER, order, volatile env lines and CONTENTS mtimes normalise to identical trees"; fi
bad=""
for p in app-misc/foo-1.0 dev-libs/baz-3 sys-apps/bar-2.1-r1; do
	[ "$(cat "$TMP/rootfs-copy1/$p/BUILD_TIME" 2>/dev/null)" = "$SDE" ] || bad="$bad $p"
done
if [ -z "$bad" ] && [ "$rc1" -eq 0 ]; then pass "P02-AC-6 change 6: BUILD_TIME is SOURCE_DATE_EPOCH in every package"; else fail "P02-AC-6 change 6: BUILD_TIME is SOURCE_DATE_EPOCH in every package (wrong:${bad:- all})"; fi
cs=$(for p in app-misc/foo-1.0 dev-libs/baz-3 sys-apps/bar-2.1-r1; do cat "$TMP/rootfs-copy1/$p/COUNTER" 2>/dev/null; done | tr '\n' ' ')
if [ "$rc1" -eq 0 ] && [ "$cs" = "1 2 3 " ]; then pass "P02-AC-6 change 6: COUNTER is renumbered 1..N in sorted cpv order"; else fail "P02-AC-6 change 6: COUNTER is renumbered 1..N in sorted cpv order (got: $cs)"; fi
envok=1
for p in app-misc/foo-1.0 dev-libs/baz-3 sys-apps/bar-2.1-r1; do
	expect_env "${p##*/}" >"$TMP/envwant"
	PATH="$TMP/s3stubs:$PATH" bzcat "$TMP/rootfs-copy1/$p/environment.bz2" >"$TMP/envgot" 2>/dev/null
	cmp -s "$TMP/envwant" "$TMP/envgot" || envok=0
done
if [ "$rc1" -eq 0 ] && [ "$envok" -eq 1 ]; then pass "P02-AC-6 change 6: environment.bz2 loses exactly the volatile declare lines (EPOCHREALTIME EPOCHSECONDS SRANDOM RANDOM BASHPID)"; else fail "P02-AC-6 change 6: environment.bz2 loses exactly the volatile declare lines (EPOCHREALTIME EPOCHSECONDS SRANDOM RANDOM BASHPID)"; fi
expect_env foo-1.0 | bzc 9 >"$TMP/envwant.bz2"
if [ "$rc1" -eq 0 ] && cmp -s "$TMP/envwant.bz2" "$TMP/rootfs-copy1/app-misc/foo-1.0/environment.bz2"; then pass "P02-AC-6 change 6: environment.bz2 is recompressed with bzip2 -9 (byte-exact)"; else fail "P02-AC-6 change 6: environment.bz2 is recompressed with bzip2 -9 (byte-exact)"; fi
printf 'dir /usr\ndir /usr/bin\nobj /usr/bin/foo-1.0 d41d8cd98f00b204e9800998ecf8427e %s\nsym /usr/bin/foo-1.0-link -> foo-1.0 %s\n' "$SDE" "$SDE" >"$TMP/contwant"
if [ "$rc1" -eq 0 ] && cmp -s "$TMP/contwant" "$TMP/rootfs-copy1/app-misc/foo-1.0/CONTENTS"; then pass "P02-AC-6 change 6: CONTENTS obj/sym mtimes are SOURCE_DATE_EPOCH, dir lines and the rest untouched"; else fail "P02-AC-6 change 6: CONTENTS obj/sym mtimes are SOURCE_DATE_EPOCH, dir lines and the rest untouched"; fi
if [ "$rc1" -eq 0 ] && [ "$(cat "$TMP/rootfs-copy1/dev-libs/baz-3/USE")" = "ssl ipv6" ] && [ "$(cat "$TMP/rootfs-copy1/dev-libs/baz-3/CHOST")" = "i486-linux-musl" ]; then pass "P02-AC-6 change 6: other VDB files are untouched"; else fail "P02-AC-6 change 6: other VDB files are untouched"; fi
t1=$(treesum "$TMP/rootfs-copy1")
run_nv "$TMP/rootfs-copy1"
if [ "$rc" -eq 0 ] && [ "$(treesum "$TMP/rootfs-copy1")" = "$t1" ]; then pass "P02-AC-6 change 6: normalising again is byte-stable"; else fail "P02-AC-6 change 6: normalising again is byte-stable"; fi
if [ "$(treesum "$TMP/builder-vdb")" = "$builder_before" ] && [ "$rc1" -eq 0 ]; then pass "P02-AC-6 change 6: the builder's own VDB is not touched (only the given copy)"; else fail "P02-AC-6 change 6: the builder's own VDB is not touched (only the given copy)"; fi
out=$(env -u SOURCE_DATE_EPOCH PATH="$TMP/s3stubs:$PATH" sh "$NV" "$TMP/rootfs-copy3" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q SOURCE_DATE_EPOCH; then pass "P02-AC-6 change 6: normalize-vdb.sh fails naming SOURCE_DATE_EPOCH when it is unset"; else fail "P02-AC-6 change 6: normalize-vdb.sh fails naming SOURCE_DATE_EPOCH when it is unset (rc=$rc)"; fi
out=$(env PATH="$TMP/s3stubs:$PATH" SOURCE_DATE_EPOCH="$SDE" sh "$NV" "$TMP/no-such-vdb" 2>&1); rc=$?
if [ -f "$NV" ] && [ "$rc" -ne 0 ]; then pass "P02-AC-6 change 6: a missing VDB directory is an error"; else fail "P02-AC-6 change 6: a missing VDB directory is an error"; fi

# ---- changes 4-6: no build script falls back when SOURCE_DATE_EPOCH is unset ----
# build-initrd.sh is run (INITRD_DIR/OUTPUT_DIR are overridable). build-iso.sh and build-rootfs.sh hard-code
# /tmp/iso and /rootfs-build and rm -rf them, so they are checked statically: a check of SOURCE_DATE_EPOCH
# (`:?`, or `[ -z "${SOURCE_DATE_EPOCH...` / `-n`) that comes before the first top-level command that does work.
for s in build-initrd.sh build-iso.sh build-rootfs.sh normalize-vdb.sh; do
	f="$ROOT/scripts/$s"
	if [ -f "$f" ] && ! nc "$f" | grep -Eq 'SOURCE_DATE_EPOCH:[-=]'; then pass "P02-AC-6 $s has no \${SOURCE_DATE_EPOCH:-...} fallback"; else fail "P02-AC-6 $s has no \${SOURCE_DATE_EPOCH:-...} fallback (or does not exist)"; fi
done
mkdir -p "$TMP/unset-out" "$TMP/unset-initrd"
if [ -f "$BI" ]; then
	out=$(cd "$TMP" && env -u SOURCE_DATE_EPOCH BUILD_VERSION=t OUTPUT_DIR="$TMP/unset-out" INITRD_DIR="$TMP/unset-initrd" bash "$BI" 2>&1 </dev/null); rc=$?
	if [ "$rc" -ne 0 ] && echo "$out" | grep -q SOURCE_DATE_EPOCH; then pass "P02-AC-6 build-initrd.sh fails naming SOURCE_DATE_EPOCH when it is unset"; else fail "P02-AC-6 build-initrd.sh fails naming SOURCE_DATE_EPOCH when it is unset (rc=$rc: $(echo "$out" | head -c 100))"; fi
fi
for s in build-iso.sh build-rootfs.sh; do
	f="$ROOT/scripts/$s"
	ck=$(fline "$f" 'SOURCE_DATE_EPOCH:\?|-z[[:space:]]+"?\$\{SOURCE_DATE_EPOCH|-n[[:space:]]+"?\$\{SOURCE_DATE_EPOCH')
	first=$(fline "$f" '^(rm|mkdir|mktemp|dd|cd|cp|rsync|xorriso|grub-mkstandalone|mksquashfs|python3|log_info|create_[a-z_]+|install_[a-z_]+|main)([[:space:]]|$)')
	if [ -n "$ck" ] && [ -n "$first" ] && [ "$ck" -lt "$first" ]; then pass "P02-AC-6 $s checks SOURCE_DATE_EPOCH before any work"; else fail "P02-AC-6 $s checks SOURCE_DATE_EPOCH before any work (check line '${ck:-none}', first work line '${first:-none}')"; fi
done
# ================= slice 4: change 7, live ebuilds out of the release graph (P02-AC-4, P02-AC-5, P02-AC-6 support) =================
# Interface: sh scripts/check-no-live.sh <file>   <file> holds `emerge --pretend` output; every [ebuild ...] line
# whose package version contains 9999 (host side "[ebuild  N    *] x11-base/xorg-proto-9999::gentoo  USE=..." and
# target side "... to /usr/i486-linux-musl/ ...") is a live package: names each (category/package-version) on
# stdout/stderr and exits non-zero; exit 0 when none. A missing/unreadable file is non-zero.
NL="$ROOT/scripts/check-no-live.sh"
FX="$HERE/fixtures"
for fx in emerge-pretend-live.txt emerge-pretend-live-target.txt; do
	out=$(sh "$NL" "$FX/$fx" 2>&1); rc=$?
	if [ -f "$NL" ] && [ "$rc" -ne 0 ] && echo "$out" | grep -q 'dev-cpp/eigen-3.4.9999\|x11-base/xorg-proto-9999'; then pass "P02-AC-5 change 7: check-no-live.sh fails on $fx and names a live package"; else fail "P02-AC-5 change 7: check-no-live.sh fails on $fx and names a live package (rc=$rc)"; fi
done
out=$(sh "$NL" "$FX/emerge-pretend-live.txt" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'x11-base/xorg-proto-9999' && echo "$out" | grep -q 'dev-cpp/eigen-3.4.9999'; then pass "P02-AC-5 change 7: check-no-live.sh names every live package (both)"; else fail "P02-AC-5 change 7: check-no-live.sh names every live package (both) (rc=$rc)"; fi
if [ -f "$NL" ] && ! echo "$out" | grep -q 'jansson\|libffi\|pygments'; then pass "P02-AC-5 change 7: check-no-live.sh does not name released packages"; else fail "P02-AC-5 change 7: check-no-live.sh does not name released packages"; fi
out=$(sh "$NL" "$FX/emerge-pretend-released.txt" 2>&1); rc=$?
if [ -f "$NL" ] && [ "$rc" -eq 0 ]; then pass "P02-AC-5 change 7: check-no-live.sh exits 0 when the graph holds no live package"; else fail "P02-AC-5 change 7: check-no-live.sh exits 0 when the graph holds no live package (rc=$rc)"; fi
out=$(sh "$NL" "$TMP/no-such-pretend" 2>&1); rc=$?
if [ -f "$NL" ] && [ "$rc" -ne 0 ]; then pass "P02-AC-5 change 7: check-no-live.sh fails on a missing file"; else fail "P02-AC-5 change 7: check-no-live.sh fails on a missing file"; fi
# the fetch path runs it before the fetch/archive: in build-packages.sh before the --fetchonly emerge, or in the
# repro-fetch recipe before fetch-distfiles.sh
BPK="$ROOT/scripts/build-packages.sh"
ck=$(fline "$BPK" 'check-no-live\.sh'); fo=$(fline "$BPK" 'exec .*--fetchonly')
rf=$(awk '/^repro-fetch:/{on=1;next} on&&/^[^\t]/{on=0} on' "$ROOT/Makefile")
mk_ck=$(printf '%s\n' "$rf" | grep -n 'check-no-live\.sh' | head -n 1 | cut -d: -f1)
mk_fd=$(printf '%s\n' "$rf" | grep -n 'fetch-distfiles\.sh' | head -n 1 | cut -d: -f1)
if { [ -n "$ck" ] && [ -n "$fo" ] && [ "$ck" -lt "$fo" ]; } || { [ -n "$mk_ck" ] && [ -n "$mk_fd" ] && [ "$mk_ck" -lt "$mk_fd" ]; }; then pass "P02-AC-5 change 7: the fetch path runs check-no-live.sh before fetching/archiving"; else fail "P02-AC-5 change 7: the fetch path runs check-no-live.sh before fetching/archiving (build-packages '${ck:-none}' vs '${fo:-none}'; Makefile '${mk_ck:-none}' vs '${mk_fd:-none}')"; fi
# Portage config: build-packages.sh copies configs/portage/package.mask/* onto the sysroot AND the build host's
# /etc/portage (host BDEPEND resolution), so the repo files under configs/portage/package.mask are the source.
# Existing ">=dev-cpp/eigen-9999" does not match 3.4.9999; the live versions seen must be masked exactly.
PM=$(cat "$ROOT"/configs/portage/package.mask/* 2>/dev/null | grep -v '^[[:space:]]*#')
for pat in '^=x11-base/xorg-proto-9999([[:space:]]|$)' '^=dev-cpp/eigen-3\.4\.9999([[:space:]]|$)'; do
	if echo "$PM" | grep -Eq "$pat"; then pass "P02-AC-6 change 7: package.mask has a live-version mask matching $pat"; else fail "P02-AC-6 change 7: package.mask has a live-version mask matching $pat"; fi
done
# ================= slice cases end: add later slices' cases above this line =================

[ "$fails" -eq 0 ]
