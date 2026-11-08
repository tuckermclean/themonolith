#!/bin/sh
# O03 uefi-flake: the failure evidence of boot-test.py (O03-AC-1), the runner CPU lines of
# `make test-boot` (O03-AC-2), the invariants that hide nothing (O03-AC-3) and the structure of
# .github/workflows/boot-test-repeat.yml (change 3, for O03-AC-5).
#
# pexpect-free: a fake child models the guest's tty (it runs each sent command and
# answers with the sentinel line capture_output waits for). BOOT_TEST_PY overrides the boot-test.py
# path (default: scripts/boot-test.py). Offline; never boots QEMU. Runs in commit-less copies: paths
# come from this file, `make -n` is given ISO= so no build is pulled in and no ISO is needed.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
BOOT_TEST="${BOOT_TEST_PY:-$HERE/../boot-test.py}"
WF="${REPEAT_WORKFLOW:-$ROOT/.github/workflows/boot-test-repeat.yml}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/boot-test-evidence.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# ---- O03-AC-2: `make -n test-boot` appends the host CPU's model name and flags lines ----
echo "== O03-AC-2: make -n test-boot MODE=uefi"
if ! (cd "$ROOT" && make -n test-boot MODE=uefi ISO=/nonexistent/boot-test.iso) >"$tmp/make.out" 2>"$tmp/make.err"; then
	fail "O03-AC-2 make -n test-boot MODE=uefi ISO=... succeeds: $(head -n 3 "$tmp/make.err")"
fi
python3 - "$tmp/make.out" <<'PY' || fails=$((fails + $?))
import re, sys
bad = 0
def ok(l): print("PASS: " + l)
def no(l):
    global bad
    print("FAIL: " + l); bad += 1
def chk(l, c): ok(l) if c else no(l)

lines = open(sys.argv[1]).read().splitlines()
qemu = [i for i, l in enumerate(lines) if "qemu-system-x86_64 --version" in l and "tool-versions.txt" in l]
chk("O03-AC-2 the recipe writes the QEMU and OVMF versions to output/tool-versions.txt", bool(qemu))
after = lines[qemu[0] + 1:] if qemu else []
# the CPU lines belong to the recipe before the boot itself starts
stop = next((i for i, l in enumerate(after) if "boot-test.py" in l), len(after))
after = after[:stop]
model = [l for l in after if "/proc/cpuinfo" in l and "model name" in l]
flags = [l for l in after if "/proc/cpuinfo" in l and re.search(r"\bflags\b", l)]
chk("O03-AC-2 a recipe line reads 'model name' from /proc/cpuinfo after the QEMU/OVMF line", bool(model))
chk("O03-AC-2 a recipe line reads 'flags' from /proc/cpuinfo after the QEMU/OVMF line", bool(flags))
chk("O03-AC-2 the model name line is appended (>>) to output/tool-versions.txt",
    any(">>" in l and "output/tool-versions.txt" in l for l in model))
chk("O03-AC-2 the flags line is appended (>>) to output/tool-versions.txt",
    any(">>" in l and "output/tool-versions.txt" in l for l in flags))
first = re.compile(r"-m ?1\b|head -n? ?1\b|\bexit\b|\bq\b|-m1\b|--max-count[= ]1\b")
chk("O03-AC-2 only the first CPU's model name line is taken", any(first.search(l) for l in model))
chk("O03-AC-2 only the first CPU's flags line is taken", any(first.search(l) for l in flags))
sys.exit(bad)
PY

# ---- O03-AC-1 / AC-3: boot-test.py through a fake child ----
echo "== O03-AC-1 / O03-AC-3: boot-test.py with a fake child"
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/qemu-system-x86_64"
chmod +x "$tmp/bin/qemu-system-x86_64"
python3 - "$BOOT_TEST" "$tmp" <<'PY' || fails=$((fails + $?))
import sys, os, re, time, types, hashlib, importlib.util

TIMEOUT = type("TIMEOUT", (Exception,), {})
EOF_ = type("EOF", (Exception,), {})
if "pexpect" not in sys.modules:
    stub = types.ModuleType("pexpect")
    stub.TIMEOUT = TIMEOUT
    stub.EOF = EOF_
    stub.ExceptionPexpect = type("ExceptionPexpect", (Exception,), {})
    stub.spawn = lambda *a, **k: None
    sys.modules["pexpect"] = stub
import pexpect

bad = 0
def ok(l): print("PASS: " + l)
def no(l, extra=""):
    global bad
    print(f"FAIL: {l} {extra}".rstrip()); bad += 1
def chk(l, c, extra=""): ok(l) if c else no(l, extra)

BT, TMP = sys.argv[1], sys.argv[2]
try:
    spec = importlib.util.spec_from_file_location("boot_test_mod", BT)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
except Exception as e:
    no(f"O03-AC-1 cannot import {BT}: {type(e).__name__}: {e}")
    sys.exit(1)

FILES = [
    "/usr/bin/perl",
    "/usr/lib/cgi-bin/guestbook.cgi",
    "/usr/lib/perl5/5.42.0/CGI.pm",
    "/usr/lib/perl5/5.42.0/if.pm",
    "/usr/lib/perl5/5.42.0/deprecate.pm",
    "/usr/lib/perl5/5.42.0/i486-linux/Config.pm",
]
def digest(path):
    return hashlib.sha256(path.encode()).hexdigest()

# The commands of the two checks at the node base (O03-AC-3: unchanged).
PARAM_CMD = "perl -MCGI -e 'print CGI->new(q(x=42))->param(q(x));'"
GUESTBOOK_CMD = ("rm -f /tmp/guestbook.db; "
                 "REQUEST_METHOD=GET QUERY_STRING='name=Ada&message=Hello+from+1996' "
                 "perl /usr/lib/cgi-bin/guestbook.cgi")
SQLITE_MARK = "sqlite3 -list -separator '|' /tmp/guestbook.db"
ROW = "Ada|Hello from 1996"
CGI_ERR = "character \\x80; marked by <-- HERE after use  at /usr/lib/perl5/5.42.0/i486-linux/Config.pm line 1."

class FakeChild:
    """Runs every sent line (no tty echo), appends the sentinel line. `script` maps a command
    kind ('param', 'guestbook') to a list of (exit, output), one per run of that command."""
    def __init__(self, script):
        self.script = script
        self.runs = {}
        self.sent = []
        self.stream = ""
        self.pos = 0
        self.before = None
        self.match = None
        self.exitstatus = 0

    def _answer(self, cmd):
        kinds = []
        if cmd == PARAM_CMD:
            kinds.append("param")
        if cmd == GUESTBOOK_CMD:
            kinds.append("guestbook")
        for k in kinds:
            n = self.runs.get(k, 0)
            self.runs[k] = n + 1
            seq = self.script.get(k, [(0, "")])
            return seq[min(n, len(seq) - 1)]
        out = []
        if "sha256sum" in cmd:
            for f in FILES:
                if f in cmd:
                    out.append(f"{digest(f)}  {f}")
        if "dmesg" in cmd:
            lines = [f"DMESG_LINE_{i:03d}" for i in range(1, 61)]
            t = re.search(r"tail\s+(?:-n\s*|-)(\d+)", cmd)
            if t:
                lines = lines[-int(t.group(1)):]
            out.extend(lines)
        if SQLITE_MARK in cmd:
            out.append(ROW)
        return 0, "\r\n".join(out)

    def sendline(self, line=""):
        self.sent.append(line)  # the fake tty does not echo: an echoed command would satisfy `contains`
        mt = re.search(r"; echo (MONOLITH_CHECK_\w+):\$\?$", line)
        if not mt:
            return
        cmd = line[:mt.start()]
        code, out = self._answer(cmd)
        self.stream += (out + "\r\n" if out else "") + f"{mt.group(1)}:{code}\r\n"

    def expect(self, rx, timeout=None):
        mt = re.compile(rx).search(self.stream, self.pos) if isinstance(rx, str) else None
        if not mt:
            time.sleep(0.001)
            raise pexpect.TIMEOUT(f"no match for {rx!r}")
        self.before = self.stream[self.pos:mt.start()]
        self.pos = mt.end()
        self.match = mt
        return 0

    def expect_exact(self, s, timeout=None):
        return self.expect(re.escape(s), timeout)

    def close(self):
        pass

def guard(label, fn):
    try:
        return fn()
    except Exception as e:
        no(f"{label}: raised {type(e).__name__}: {e}")
        return None

def sha_lines_ok(detail, label):
    for f in FILES:
        chk(f"{label}: detail has the sha256sum line for {f}", f"{digest(f)}  {f}" in detail)

def after_index(sent, needle, start=0):
    for i in range(start, len(sent)):
        if needle in sent[i]:
            return i
    return -1

# ---- AC-1: guestbook.cgi fails the first time, passes the second ----
print("  O03-AC-1: guestbook.cgi first run fails, second passes")
SECOND_OK = "SECOND_RUN_OUTPUT_MARK " + ROW
c = FakeChild({"guestbook": [(255, CGI_ERR), (0, SECOND_OK)]})
results = []
guard("O03-AC-1 smoke_guestbook", lambda: m.smoke_guestbook(c, results))
r = {n: (o, d) for n, o, d in results}
gb = r.get("guestbook.cgi inserts + reads back a row via sqlite3")
chk("O03-AC-1 smoke_guestbook reports the guestbook.cgi check", gb is not None, f"(results={[n for n, _, _ in results]})")
if gb is not None:
    ok_, detail = gb
    chk("O03-AC-1 the check's result is still FAIL when the second run passes", ok_ is False)
    sha_lines_ok(detail, "O03-AC-1 guestbook.cgi")
    chk("O03-AC-1 detail has the dmesg tail: its last 50 lines, no earlier one",
        "DMESG_LINE_060" in detail and "DMESG_LINE_011" in detail and "DMESG_LINE_010" not in detail)
    chk("O03-AC-1 detail has the second run's output", "SECOND_RUN_OUTPUT_MARK" in detail)
    chk("O03-AC-1 detail has the second run's exit code 0",
        re.search(r"exit[^0-9\n]{0,20}\b0\b", detail, re.I) is not None, f"(detail={detail[-300:]!r})")
    chk("O03-AC-1 detail keeps the first run's failure", "255" in detail)
chk("O03-AC-1 the guestbook command ran twice (the second run is evidence)",
    sum(1 for s in c.sent if "perl /usr/lib/cgi-bin/guestbook.cgi" in s) == 2,
    f"(runs={sum(1 for s in c.sent if 'perl /usr/lib/cgi-bin/guestbook.cgi' in s)})")
i2 = [i for i, s in enumerate(c.sent) if "perl /usr/lib/cgi-bin/guestbook.cgi" in s]
inext = after_index(c.sent, SQLITE_MARK)
chk("O03-AC-1 the evidence runs in the same boot, before the next check",
    len(i2) == 2 and inext > i2[-1], f"(second run at {i2}, next check at {inext})")
sec = r.get("guestbook row independently verified via sqlite3 CLI")
chk("O03-AC-1 the next check is unaffected", sec is not None and sec[0] is True)

print("  O03-AC-1: the second run fails too, with another exit code")
c = FakeChild({"guestbook": [(255, CGI_ERR), (7, "SECOND_FAIL_MARK")]})
results = []
guard("O03-AC-1 smoke_guestbook (second fails)", lambda: m.smoke_guestbook(c, results))
gb = next(((o, d) for n, o, d in results if n.startswith("guestbook.cgi")), None)
if gb is None:
    no("O03-AC-1 smoke_guestbook reports the guestbook.cgi check (second run fails)")
else:
    chk("O03-AC-1 FAIL when both runs fail", gb[0] is False)
    chk("O03-AC-1 detail has the second run's output (second run fails)", "SECOND_FAIL_MARK" in gb[1])
    chk("O03-AC-1 detail has the second run's exit code 7",
        re.search(r"exit[^0-9\n]{0,20}\b7\b", gb[1], re.I) is not None, f"(detail={gb[1][-300:]!r})")

print("  O03-AC-1: CGI.pm param() fails the first time, passes the second")
c = FakeChild({"param": [(1, "boom"), (0, "SECOND_RUN_OUTPUT_MARK 42")]})
res = guard("O03-AC-1 smoke_perl_cgi", lambda: m.smoke_perl_cgi(c))
if res is None:
    no("O03-AC-1 smoke_perl_cgi returns (ok, detail)")
else:
    ok_, detail = res
    chk("O03-AC-1 CGI.pm param(): FAIL when the second run passes", ok_ is False)
    sha_lines_ok(detail, "O03-AC-1 CGI.pm param()")
    chk("O03-AC-1 CGI.pm param(): detail has the dmesg tail", "DMESG_LINE_060" in detail and "DMESG_LINE_011" in detail and "DMESG_LINE_010" not in detail)
    chk("O03-AC-1 CGI.pm param(): detail has the second run's output", "SECOND_RUN_OUTPUT_MARK" in detail)
    chk("O03-AC-1 CGI.pm param(): detail has the second run's exit code 0",
        re.search(r"exit[^0-9\n]{0,20}\b0\b", detail, re.I) is not None, f"(detail={detail[-300:]!r})")
    chk("O03-AC-1 CGI.pm param(): the command ran twice", sum(1 for s in c.sent if "CGI->new" in s) == 2)

print("  O03-AC-1: through the uefi suite (run_full_smoke_suite)")
c = FakeChild({"guestbook": [(255, CGI_ERR), (0, SECOND_OK)]})
res = guard("O03-AC-1 run_full_smoke_suite", lambda: m.run_full_smoke_suite(c, "6.12.80-i486-monolith"))
if res is not None:
    gb = next(((o, d) for n, o, d in res if n.startswith("guestbook.cgi")), None)
    chk("O03-AC-1 the suite's guestbook.cgi result is FAIL with the six hashes",
        gb is not None and gb[0] is False and all(f"{digest(f)}  {f}" in gb[1] for f in FILES))

print("  O03-AC-1: passing checks run nothing extra")
c = FakeChild({"guestbook": [(0, ROW)], "param": [(0, "42")]})
results = []
guard("O03-AC-1 smoke_guestbook (pass)", lambda: m.smoke_guestbook(c, results))
chk("O03-AC-1 a passing guestbook check sends only the two checks' commands", len(c.sent) == 2, f"(sent={len(c.sent)}: {c.sent!r})")
chk("O03-AC-1 a passing guestbook check sends no sha256sum or dmesg",
    not any("sha256sum" in s or "dmesg" in s for s in c.sent))
chk("O03-AC-1 a passing guestbook check passes", all(o for _, o, _ in results) and len(results) == 2)
c = FakeChild({"param": [(0, "42")]})
res = guard("O03-AC-1 smoke_perl_cgi (pass)", lambda: m.smoke_perl_cgi(c))
chk("O03-AC-1 a passing CGI.pm param() sends exactly one command", len(c.sent) == 1, f"(sent={c.sent!r})")
chk("O03-AC-1 a passing CGI.pm param() passes", res is not None and res[0] is True)

# ---- AC-3: the uefi mode keeps its checks, validators and commands; the launch rule stays ----
print("  O03-AC-3: uefi mode checks, commands and validators")
def run_uefi_with(script):
    c = FakeChild(script)
    captured = []
    saved = {k: getattr(m, k) for k in ("select_grub_serial_entry", "expect_milestone", "wait_for_shell",
                                        "poweroff_and_wait", "report_results")}
    m.select_grub_serial_entry = lambda ch: None
    m.expect_milestone = lambda *a, **k: None
    m.wait_for_shell = lambda *a, **k: None
    m.poweroff_and_wait = lambda *a, **k: None
    m.report_results = lambda results: captured.extend(results) or True
    try:
        m.run_uefi(c, types.SimpleNamespace(boot_timeout=5, kernel_version="6.12.80-i486-monolith"))
    finally:
        for k, v in saved.items():
            setattr(m, k, v)
    return c, {n: (o, d) for n, o, d in captured}

def uefi_case(label, script):
    got = guard(f"O03-AC-3 run_uefi ({label})", lambda: run_uefi_with(script))
    return got if got is not None else (FakeChild({}), {})

c, r = uefi_case("all pass", {"param": [(0, "42")], "guestbook": [(0, ROW)]})
chk("O03-AC-3 uefi runs the CGI.pm param() check", "CGI.pm param() works" in r, f"(checks={sorted(r)})")
chk("O03-AC-3 uefi runs the guestbook.cgi check", "guestbook.cgi inserts + reads back a row via sqlite3" in r)
chk("O03-AC-3 uefi sends the CGI.pm param() command unchanged", PARAM_CMD in [s.rsplit("; echo MONOLITH_CHECK", 1)[0] for s in c.sent])
chk("O03-AC-3 uefi sends the guestbook.cgi command unchanged", GUESTBOOK_CMD in [s.rsplit("; echo MONOLITH_CHECK", 1)[0] for s in c.sent])
chk("O03-AC-3 both checks pass on good output", r.get("CGI.pm param() works", (False,))[0] is True
    and r.get("guestbook.cgi inserts + reads back a row via sqlite3", (False,))[0] is True)

c, r = uefi_case("param output without 42", {"param": [(0, "nothing")], "guestbook": [(0, ROW)]})
chk("O03-AC-3 CGI.pm param() fails when '42' is missing (contains)", r.get("CGI.pm param() works", (True,))[0] is False)
c, r = uefi_case("param exit nonzero", {"param": [(3, "42")], "guestbook": [(0, ROW)]})
chk("O03-AC-3 CGI.pm param() fails on a nonzero exit even with '42' (contains)", r.get("CGI.pm param() works", (True,))[0] is False)
c, r = uefi_case("guestbook without row", {"param": [(0, "42")], "guestbook": [(0, "Ada")]})
chk("O03-AC-3 guestbook.cgi fails when the row is missing (contains)",
    r.get("guestbook.cgi inserts + reads back a row via sqlite3", (True,))[0] is False)
c, r = uefi_case("guestbook exit nonzero", {"param": [(0, "42")], "guestbook": [(1, ROW)]})
chk("O03-AC-3 guestbook.cgi fails on a nonzero exit even with the row (contains)",
    r.get("guestbook.cgi inserts + reads back a row via sqlite3", (True,))[0] is False)

print("  O03-AC-3: build_uefi_cmd and should_retry_launch")
os.environ["PATH"] = os.path.join(TMP, "bin") + os.pathsep + os.environ.get("PATH", "")
ovmf = os.path.join(TMP, "OVMF_CODE.fd")
open(ovmf, "w").close()
ram = getattr(m, "MODE_DEFAULT_RAM", {}).get("uefi")
chk("O03-AC-3 the uefi mode's default RAM is 512 MB", ram == 512, f"(MODE_DEFAULT_RAM['uefi']={ram!r})")
cmd = guard("O03-AC-3 build_uefi_cmd", lambda: m.build_uefi_cmd(types.SimpleNamespace(
    qemu_x86_64="qemu-system-x86_64", ovmf_code=ovmf, iso="boot-test.iso", ram_mb=ram)))
if cmd is not None:
    chk("O03-AC-3 build_uefi_cmd runs qemu-system-x86_64", os.path.basename(cmd[0]) == "qemu-system-x86_64", f"({cmd[0]})")
    chk("O03-AC-3 build_uefi_cmd has no -cpu argument", "-cpu" not in cmd)
    chk("O03-AC-3 build_uefi_cmd passes -m 512 by default",
        "-m" in cmd and cmd[cmd.index("-m") + 1] == "512")
srl = m.should_retry_launch
chk("O03-AC-3 no relaunch after a failure once /init was reached", srl(ok=False, reached_init=True, attempt=1, max_attempts=3) is False)
chk("O03-AC-3 a silent guest with attempts left is still relaunched", srl(ok=False, reached_init=False, attempt=1, max_attempts=3) is True)

sys.exit(bad)
PY

# ---- change 3 (O03-AC-5): .github/workflows/boot-test-repeat.yml ----
echo "== change 3: boot-test-repeat.yml"
if [ ! -f "$WF" ]; then
	fail "O03 change 3: .github/workflows/boot-test-repeat.yml exists"
else
	python3 - "$WF" <<'PY' || fails=$((fails + $?))
import re, sys
bad = 0
def ok(l): print("PASS: " + l)
def no(l):
    global bad
    print("FAIL: " + l); bad += 1
def chk(l, c): ok(l) if c else no(l)

path = sys.argv[1]
text = open(path).read()
try:
    import yaml
    doc = yaml.safe_load(text)
    on = doc.get(True, doc.get("on"))
    jobs = doc["jobs"]
    assert isinstance(jobs, dict) and jobs
except Exception as e:
    no(f"O03 change 3: boot-test-repeat.yml parses as a workflow: {type(e).__name__}: {e}")
    sys.exit(1)

on = on if isinstance(on, dict) else {}
wd = on.get("workflow_dispatch")
inputs = (wd or {}).get("inputs") or {}
chk("O03 change 3: triggered by workflow_dispatch", "workflow_dispatch" in on)
chk("O03 change 3: input build-run-id", "build-run-id" in inputs)
chk("O03 change 3: input count", "count" in inputs)

steps = []
matrix_jobs = []
for name, j in jobs.items():
    if "matrix" in (j.get("strategy") or {}):
        matrix_jobs.append((name, j))
    for s in j.get("steps") or []:
        steps.append((name, s))
chk("O03 change 3: a job runs a matrix", bool(matrix_jobs))
mtext = " ".join(str(j.get("strategy")) + " " + str(j.get("needs", "")) for _, j in matrix_jobs)
alltext = text
chk("O03 change 3: the matrix is sized by the count input",
    "inputs.count" in alltext and (("fromJSON" in alltext) or ("fromJson" in alltext) or "count" in mtext))

dl = [s for _, s in steps if str(s.get("uses", "")).startswith("actions/download-artifact@")]
chk("O03 change 3: uses actions/download-artifact", bool(dl))
w = (dl[0].get("with") or {}) if dl else {}
chk("O03 change 3: download-artifact has run-id from build-run-id", "build-run-id" in str(w.get("run-id", "")))
chk("O03 change 3: download-artifact has github-token", bool(w.get("github-token")))
chk("O03 change 3: download-artifact fetches the ISO artifact iso-<build-run-id>",
    "iso-" in str(w.get("name", "")) and "build-run-id" in str(w.get("name", "")))
chk("O03 change 3: the download is pinned by SHA",
    bool(dl) and re.search(r"@[0-9a-f]{40}\b", dl[0]["uses"]) is not None)
chk("O03 change 3: the ISO file is boot-test.iso", "boot-test.iso" in text)
chk("O03 change 3: actions: read permission for the cross-run download", re.search(r"actions:\s*read", text) is not None)

runs = [str(s.get("run", "")) + " " + str(s.get("env", "")) for _, s in steps if s.get("run")]
chk("O03 change 3: a step runs make test-boot MODE=uefi",
    any("make test-boot" in r and re.search(r"MODE(=|': '|: )'?uefi", r) for r in runs))
chk("O03 change 3: the step passes the downloaded ISO", any("make test-boot" in r and "ISO" in r for r in runs))

up = [s for _, s in steps if str(s.get("uses", "")).startswith("actions/upload-artifact@")]
chk("O03 change 3: uploads an artifact", bool(up))
named = [s for s in up if "matrix." in str((s.get("with") or {}).get("name", ""))]
chk("O03 change 3: the upload name carries the matrix index", bool(named))
paths = " ".join(str((s.get("with") or {}).get("path", "")) for s in up)
chk("O03 change 3: the upload has the serial log (output/boot-test-uefi.log)", "output/boot-test-uefi.log" in paths)
chk("O03 change 3: the upload has output/tool-versions.txt", "output/tool-versions.txt" in paths)
chk("O03 change 3: every action is pinned by SHA",
    all(re.search(r"@[0-9a-f]{40}\b", str(s["uses"])) for _, s in steps if "uses" in s))
sys.exit(bad)
PY
fi

echo
if [ "$fails" -ne 0 ]; then
	echo "$fails FAILED"
	exit 1
fi
echo "ALL PASS"
