#!/bin/sh
# O04 bios64-perl-flake (issue #115): a failing check shows the head of its output (O04-AC-1), the guest's
# /proc/meminfo before the sha256sum lines (O04-AC-2), PERL_CGI_FILES with nine files and the mode input of
# .github/workflows/boot-test-repeat.yml (O04-AC-3), and the invariants that hide nothing (O04-AC-4).
#
# pexpect-free: a fake child models the guest's tty (it runs each sent command and answers with the
# sentinel line capture_output waits for), as boot-test-evidence.test.sh does. BOOT_TEST_PY overrides the
# boot-test.py path, REPEAT_WORKFLOW and BOOT_WORKFLOW the workflow paths. Offline; never boots QEMU.
# Runs in commit-less copies: paths come from this file.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
BOOT_TEST="${BOOT_TEST_PY:-$HERE/../boot-test.py}"
WF="${REPEAT_WORKFLOW:-$ROOT/.github/workflows/boot-test-repeat.yml}"
BOOT_WF="${BOOT_WORKFLOW:-$ROOT/.github/workflows/boot-test.yml}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/O04-boot-test-bios64.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
fails=0

mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/qemu-system-i386"
chmod +x "$tmp/bin/qemu-system-i386"

# ---- AC-1, AC-2, AC-3 (tuple), AC-4: boot-test.py through a fake child ----
echo "== O04-AC-1..AC-4: boot-test.py with a fake child"
python3 - "$BOOT_TEST" "$tmp" <<'PY' || fails=$((fails + $?))
import sys, os, re, time, types, hashlib, random, importlib.util

try:
    sys.stdout.reconfigure(errors="backslashreplace")
except Exception:
    pass

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
    no(f"O04 cannot import {BT}: {type(e).__name__}: {e}")
    sys.exit(1)

def guard(label, fn):
    try:
        return fn()
    except Exception as e:
        no(f"{label}: raised {type(e).__name__}: {e}")
        return None

FILES = [
    "/usr/lib/cgi-bin/guestbook.cgi",
    "/usr/lib/perl5/5.42.0/CGI.pm",
    "/usr/lib/perl5/5.42.0/if.pm",
    "/usr/lib/perl5/5.42.0/deprecate.pm",
    "/usr/lib/perl5/5.42.0/i486-linux/Config.pm",
    "/usr/bin/perl",
    "/usr/lib/perl5/5.42.0/CGI/File/Temp.pm",
    "/usr/lib/perl5/5.42.0/parent.pm",
    "/usr/lib/perl5/5.42.0/File/Temp.pm",
]
def digest(path):
    return hashlib.sha256(path.encode()).hexdigest()
def shaline(f):
    return f"{digest(f)}  {f}"

PARAM_CMD = "perl -MCGI -e 'print CGI->new(q(x=42))->param(q(x));'"
GUESTBOOK_CMD = ("rm -f /tmp/guestbook.db; "
                 "REQUEST_METHOD=GET QUERY_STRING='name=Ada&message=Hello+from+1996' "
                 "perl /usr/lib/cgi-bin/guestbook.cgi")
SQLITE_MARK = "sqlite3 -list -separator '|' /tmp/guestbook.db"
ROW = "Ada|Hello from 1996"
MEMINFO = ["MemTotal:          61234 kB", "MemFree:            1234 kB", "MemAvailable:       5678 kB"]
CUT = "…"

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
        kind = "param" if cmd == PARAM_CMD else "guestbook" if cmd == GUESTBOOK_CMD else None
        if kind:
            n = self.runs.get(kind, 0)
            self.runs[kind] = n + 1
            seq = self.script.get(kind, [(0, "")])
            return seq[min(n, len(seq) - 1)]
        out = []
        if "/proc/meminfo" in cmd:
            out.extend(MEMINFO)
        if "sha256sum" in cmd:
            for f in FILES:
                if f in cmd:
                    out.append(shaline(f))
        if "dmesg" in cmd:
            out.extend(f"DMESG_LINE_{i:03d}" for i in range(1, 51))
        if SQLITE_MARK in cmd:
            out.append(ROW)
        return 0, "\r\n".join(out)

    def sendline(self, line=""):
        self.sent.append(line)
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

def cmd_of(sent):
    return sent.rsplit("; echo MONOLITH_CHECK", 1)[0]

# ---- O04-AC-1: the head of a failing check's output ----
print("  O04-AC-1: guestbook.cgi exits 255 with a 3000-character perl error")
FIRST = "O04_UNIQUE_FIRST_LINE: Can't locate Missing/Module.pm in @INC (you may need to install it)"
lines = [FIRST]
i = 0
while sum(len(l) + 2 for l in lines) < 3000:
    lines.append(f"Compilation failed in require at /usr/lib/perl5/5.42.0/mod{i}.pm line {i}.")
    i += 1
ERR = "\r\n".join(lines)[:3000]
c = FakeChild({"guestbook": [(255, ERR), (0, ROW)]})
results = []
guard("O04-AC-1 smoke_guestbook", lambda: m.smoke_guestbook(c, results))
gb = next(((o, d) for n, o, d in results if n.startswith("guestbook.cgi")), None)
if gb is None:
    no("O04-AC-1 smoke_guestbook reports the guestbook.cgi check")
else:
    chk("O04-AC-1 the guestbook.cgi check still fails", gb[0] is False)
    chk("O04-AC-1 the detail contains the unique first line of perl's error", FIRST in gb[1],
        f"(detail head={gb[1][:200]!r})")
    chk("O04-AC-1 the detail has a cut line for the 3000-character output",
        re.search(CUT + r"|\[.{1,3} \d+ characters cut .{1,3}\]", gb[1]) is not None and " characters cut " in gb[1])

print("  O04-AC-1: validators on 999, 1000 and 1001 characters")
rnd = random.Random(4)
def text(n):
    return "".join(rnd.choice("abcdefghijklmnopqrstuvwxyz") for _ in range(n))

def is_cut_line(detail, n):
    want = f"[{CUT} {n} characters cut {CUT}]"
    return any(l.strip() == want for l in detail.splitlines())

def clip_checks(label, run, n):
    """run(output) -> (ok, detail) for a failing case; output has no surrounding whitespace."""
    out = text(n)
    r = guard(f"O04-AC-1 {label} ({n})", lambda: run(out))
    if r is None:
        return
    okv, d = r
    chk(f"O04-AC-1 {label} ({n} chars) still fails", okv is False)
    if n <= 1000:
        chk(f"O04-AC-1 {label} ({n} chars) reports the output whole", out in d)
        chk(f"O04-AC-1 {label} ({n} chars) has no cut line", "characters cut" not in d)
    else:
        cut = n - 1000
        chk(f"O04-AC-1 {label} ({n} chars) reports the first 500 characters", out[:500] in d)
        chk(f"O04-AC-1 {label} ({n} chars) reports the last 500 characters", out[-500:] in d)
        chk(f"O04-AC-1 {label} ({n} chars) has a cut line with n={cut}", is_cut_line(d, cut),
            f"(detail has cut line: {'characters cut' in d})")
        chk(f"O04-AC-1 {label} ({n} chars) does not report the output whole", out not in d)
        if is_cut_line(d, cut) and out[:500] in d and out[-500:] in d:
            chk(f"O04-AC-1 {label} ({n} chars) orders head, cut line, tail",
                d.index(out[:500]) < d.index(f"[{CUT} {cut} characters cut {CUT}]") < d.rindex(out[-500:]))

cases = [
    ("contains (nonzero exit)", lambda o: m.contains("ZZZ")(1, o)),
    ("contains (needle missing)", lambda o: m.contains("ZZZ")(0, o)),
    ("regex_matches (nonzero exit)", lambda o: m.regex_matches("ZZZ")(1, o)),
    ("regex_matches (no match)", lambda o: m.regex_matches("ZZZ")(0, o)),
    ("regex_absent (nonzero exit)", lambda o: m.regex_absent("ZZZ")(1, o)),
    ("exit_code_only (nonzero exit)", lambda o: m.exit_code_only()(1, o)),
    ("contains_with_exit (wrong exit)", lambda o: m.contains_with_exit("ZZZ", 0)(1, o)),
    ("contains_with_exit (needle missing)", lambda o: m.contains_with_exit("ZZZ", 0)(0, o)),
    ("epoch_close_to (nonzero exit)", lambda o: m.epoch_close_to(1000000000, 10)(1, o)),
    ("epoch_close_to (no epoch integer)", lambda o: m.epoch_close_to(1000000000, 10)(0, o)),
]
for label, run in cases:
    for n in (999, 1000, 1001):
        clip_checks(label, run, n)
    clip_checks(label, run, 3000)

print("  O04-AC-1: pass and fail results are unchanged")
o = text(1001)
passing = [
    ("contains", m.contains("abc")(0, o + " abc")),
    ("regex_matches", m.regex_matches("abc")(0, o + " abc")),
    ("regex_absent", m.regex_absent("ZZZ")(0, o)),
    ("exit_code_only", m.exit_code_only()(0, o)),
    ("contains_with_exit", m.contains_with_exit("abc", 3)(3, o + " abc")),
    ("epoch_close_to", m.epoch_close_to(1000000000, 10)(0, "1000000005")),
]
for label, r in passing:
    chk(f"O04-AC-1 {label} still passes on good output", r[0] is True)
chk("O04-AC-1 regex_absent still fails when the pattern is present", m.regex_absent("abc")(0, "xx abc xx")[0] is False)
chk("O04-AC-1 epoch_close_to still fails outside the tolerance", m.epoch_close_to(1000000000, 10)(0, "1000000500")[0] is False)

# ---- O04-AC-2: /proc/meminfo before the sha256sum lines ----
print("  O04-AC-2: a failing check records the guest's /proc/meminfo before the hashes")
def mem_checks(label, detail, sent):
    chk(f"O04-AC-2 {label}: detail has a MemTotal: line", "MemTotal:" in detail)
    chk(f"O04-AC-2 {label}: detail has a MemAvailable: or MemFree: line", "MemAvailable:" in detail or "MemFree:" in detail)
    mi = detail.find("MemTotal:")
    sha = min([detail.find(shaline(f)) for f in FILES if shaline(f) in detail] or [-1])
    chk(f"O04-AC-2 {label}: /proc/meminfo comes before the sha256sum lines", 0 <= mi < sha, f"(meminfo at {mi}, sha256 at {sha})")
    label_lines = [l for l in detail.splitlines() if l.startswith("---") and "meminfo" in l]
    chk(f"O04-AC-2 {label}: the meminfo output has its own label", bool(label_lines))
    if label_lines and mi >= 0:
        chk(f"O04-AC-2 {label}: the label precedes the meminfo output", detail.index(label_lines[0]) < mi)
    im = next((k for k, s in enumerate(sent) if "/proc/meminfo" in s), -1)
    isha = next((k for k, s in enumerate(sent) if "sha256sum" in s), -1)
    chk(f"O04-AC-2 {label}: the meminfo command is sent before sha256sum", 0 <= im < isha, f"(meminfo at {im}, sha256sum at {isha})")

c = FakeChild({"guestbook": [(255, "boom"), (0, ROW)]})
results = []
guard("O04-AC-2 smoke_guestbook", lambda: m.smoke_guestbook(c, results))
gb = next(((o, d) for n, o, d in results if n.startswith("guestbook.cgi")), None)
if gb is None:
    no("O04-AC-2 smoke_guestbook reports the guestbook.cgi check")
else:
    mem_checks("guestbook.cgi", gb[1], c.sent)
c = FakeChild({"param": [(1, "boom"), (0, "42")]})
res = guard("O04-AC-2 smoke_perl_cgi", lambda: m.smoke_perl_cgi(c))
if res is None:
    no("O04-AC-2 smoke_perl_cgi returns (ok, detail)")
else:
    chk("O04-AC-2 CGI.pm param(): the check still fails", res[0] is False)
    mem_checks("CGI.pm param()", res[1], c.sent)

print("  O04-AC-2: passing checks run nothing extra")
c = FakeChild({"guestbook": [(0, ROW)], "param": [(0, "42")]})
results = []
guard("O04-AC-2 smoke_guestbook (pass)", lambda: m.smoke_guestbook(c, results))
chk("O04-AC-2 a passing guestbook check sends only the two checks' commands", len(c.sent) == 2, f"(sent={c.sent!r})")
chk("O04-AC-2 a passing guestbook check sends no meminfo", not any("/proc/meminfo" in s for s in c.sent))
c = FakeChild({"param": [(0, "42")]})
res = guard("O04-AC-2 smoke_perl_cgi (pass)", lambda: m.smoke_perl_cgi(c))
chk("O04-AC-2 a passing CGI.pm param() sends exactly one command", len(c.sent) == 1, f"(sent={c.sent!r})")
chk("O04-AC-2 a passing CGI.pm param() passes", res is not None and res[0] is True)

# ---- O04-AC-3: the nine files ----
print("  O04-AC-3: PERL_CGI_FILES and the checks' files")
files = list(getattr(m, "PERL_CGI_FILES", ()))
for f in FILES:
    chk(f"O04-AC-3 PERL_CGI_FILES names {f}", f in files)
c = FakeChild({"param": [(1, "boom"), (0, "42")]})
res = guard("O04-AC-3 smoke_perl_cgi", lambda: m.smoke_perl_cgi(c))
if res is not None:
    chk("O04-AC-3 CGI.pm param(): the detail has the sha256sum line of all nine files", all(shaline(f) in res[1] for f in FILES))
    shacmd = next((cmd_of(s) for s in c.sent if "sha256sum" in s), "")
    chk("O04-AC-3 CGI.pm param(): sha256sum is given all nine files", all(f in shacmd for f in FILES))
c = FakeChild({"guestbook": [(255, "boom"), (0, ROW)]})
results = []
guard("O04-AC-3 smoke_guestbook", lambda: m.smoke_guestbook(c, results))
gb = next(((o, d) for n, o, d in results if n.startswith("guestbook.cgi")), None)
chk("O04-AC-3 guestbook.cgi: the detail has the sha256sum line of all nine files",
    gb is not None and all(shaline(f) in gb[1] for f in FILES))

# ---- O04-AC-4: the bios mode keeps its checks, commands, validators and launch rule ----
print("  O04-AC-4: bios mode checks, commands and validators")
def run_bios_with(script):
    c = FakeChild(script)
    captured = []
    saved = {k: getattr(m, k) for k in ("select_isolinux_label", "expect_milestone", "wait_for_shell",
                                        "poweroff_and_wait", "report_results")}
    m.select_isolinux_label = lambda *a, **k: None
    m.expect_milestone = lambda *a, **k: None
    m.wait_for_shell = lambda *a, **k: None
    m.poweroff_and_wait = lambda *a, **k: None
    m.report_results = lambda results: captured.extend(results) or True
    try:
        m.run_bios(c, types.SimpleNamespace(boot_timeout=5, kernel_version="6.12.80-i486-monolith"))
    finally:
        for k, v in saved.items():
            setattr(m, k, v)
    return c, {n: (o, d) for n, o, d in captured}

def bios_case(label, script):
    got = guard(f"O04-AC-4 run_bios ({label})", lambda: run_bios_with(script))
    return got if got is not None else (FakeChild({}), {})

PN, GN = "CGI.pm param() works", "guestbook.cgi inserts + reads back a row via sqlite3"
c, r = bios_case("all pass", {"param": [(0, "42")], "guestbook": [(0, ROW)]})
chk("O04-AC-4 bios runs the CGI.pm param() check", PN in r, f"(checks={sorted(r)})")
chk("O04-AC-4 bios runs the guestbook.cgi check", GN in r)
chk("O04-AC-4 bios sends the CGI.pm param() command unchanged", PARAM_CMD in [cmd_of(s) for s in c.sent])
chk("O04-AC-4 bios sends the guestbook.cgi command unchanged", GUESTBOOK_CMD in [cmd_of(s) for s in c.sent])
chk("O04-AC-4 both checks pass on good output", r.get(PN, (False,))[0] is True and r.get(GN, (False,))[0] is True)
c, r = bios_case("param output without 42", {"param": [(0, "nothing")], "guestbook": [(0, ROW)]})
chk("O04-AC-4 CGI.pm param() fails when '42' is missing (contains)", r.get(PN, (True,))[0] is False)
c, r = bios_case("param exit nonzero", {"param": [(3, "42")], "guestbook": [(0, ROW)]})
chk("O04-AC-4 CGI.pm param() fails on a nonzero exit even with '42' (contains)", r.get(PN, (True,))[0] is False)
c, r = bios_case("guestbook without row", {"param": [(0, "42")], "guestbook": [(0, "Ada")]})
chk("O04-AC-4 guestbook.cgi fails when the row is missing (contains)", r.get(GN, (True,))[0] is False)
c, r = bios_case("guestbook exit nonzero", {"param": [(0, "42")], "guestbook": [(1, ROW)]})
chk("O04-AC-4 guestbook.cgi fails on a nonzero exit even with the row (contains)", r.get(GN, (True,))[0] is False)

print("  O04-AC-4: build_bios_cmd and should_retry_launch")
os.environ["PATH"] = os.path.join(TMP, "bin") + os.pathsep + os.environ.get("PATH", "")
for ram in (64, 256):
    cmd = guard(f"O04-AC-4 build_bios_cmd ({ram})", lambda: m.build_bios_cmd(types.SimpleNamespace(
        qemu_i386="qemu-system-i386", iso="boot-test.iso", ram_mb=ram, rtc_date=None)))
    if cmd is not None:
        chk(f"O04-AC-4 build_bios_cmd runs -cpu 486 (ram {ram})", "-cpu" in cmd and cmd[cmd.index("-cpu") + 1] == "486")
        chk(f"O04-AC-4 build_bios_cmd passes -m {ram}", "-m" in cmd and cmd[cmd.index("-m") + 1] == str(ram))
srl = m.should_retry_launch
chk("O04-AC-4 no relaunch after a failure once /init was reached",
    guard("O04-AC-4 should_retry_launch", lambda: srl(ok=False, reached_init=True, attempt=1, max_attempts=3)) is False)

sys.exit(bad)
PY

# ---- O04-AC-3 / AC-4: the workflows ----
echo "== O04-AC-3: boot-test-repeat.yml"
if [ ! -f "$WF" ]; then
	fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
	fail "O04-AC-3: .github/workflows/boot-test-repeat.yml exists"
else
	python3 - "$WF" <<'PY' || fails=$((fails + $?))
import re, sys
bad = 0
def ok(l): print("PASS: " + l)
def no(l):
    global bad
    print("FAIL: " + l); bad += 1
def chk(l, c): ok(l) if c else no(l)

text = open(sys.argv[1]).read()
try:
    import yaml
    doc = yaml.safe_load(text)
    on = doc.get(True, doc.get("on"))
    jobs = doc["jobs"]
    assert isinstance(jobs, dict) and jobs
except Exception as e:
    no(f"O04-AC-3: boot-test-repeat.yml parses as a workflow: {type(e).__name__}: {e}")
    sys.exit(1)

inputs = ((on if isinstance(on, dict) else {}).get("workflow_dispatch") or {}).get("inputs") or {}
mode = inputs.get("mode") or {}
chk("O04-AC-3: a workflow_dispatch input mode", "mode" in inputs)
chk("O04-AC-3: input mode is of type choice", mode.get("type") == "choice")
chk("O04-AC-3: input mode has exactly the options uefi and bios-64", sorted(mode.get("options") or []) == ["bios-64", "uefi"])
chk("O04-AC-3: input mode defaults to uefi", mode.get("default") == "uefi")

steps = []
for jn, j in jobs.items():
    for s in j.get("steps") or []:
        cond = str(j.get("if", "")) + " " + str(s.get("if", ""))
        steps.append((jn, s, cond))

def flat(s):
    return str(s.get("run", "")) + " " + str(s.get("env", ""))
def mk(var, val):
    return re.compile(r"\b" + var + r"(=|': '|: )'?" + val + r"(?![\w-])")

bios = [(jn, s, c) for jn, s, c in steps if s.get("run") and "make test-boot" in flat(s)
        and mk("MODE", "bios").search(flat(s)) and mk("RAM_MB", "64").search(flat(s))]
chk("O04-AC-3: a run step runs make test-boot with MODE=bios and RAM_MB=64", bool(bios))
chk("O04-AC-3: the bios-64 run step passes the downloaded ISO", any("ISO" in flat(s) for _, s, _ in bios))
chk("O04-AC-3: the bios-64 run step is conditioned on mode == bios-64",
    bool(bios) and all(re.search(r"mode\s*==\s*['\"]bios-64['\"]", c) for _, _, c in bios))
uefi = [(jn, s, c) for jn, s, c in steps if s.get("run") and "make test-boot" in flat(s) and mk("MODE", "uefi").search(flat(s))]
chk("O04-AC-3: a run step still runs make test-boot with MODE=uefi", bool(uefi))
chk("O04-AC-3: the uefi run step is conditioned on mode == uefi (the default runs uefi only)",
    bool(uefi) and all(re.search(r"mode\s*==\s*['\"]uefi['\"]", c) for _, _, c in uefi))

up = [(jn, s, c) for jn, s, c in steps if str(s.get("uses", "")).startswith("actions/upload-artifact@")]
bup = [(jn, s, c) for jn, s, c in up if "output/boot-test-bios-64m.log" in str((s.get("with") or {}).get("path", ""))]
chk("O04-AC-3: an upload has output/boot-test-bios-64m.log", bool(bup))
chk("O04-AC-3: the bios-64 upload has output/tool-versions.txt",
    any("output/tool-versions.txt" in str((s.get("with") or {}).get("path", "")) for _, s, _ in bup))
chk("O04-AC-3: the bios-64 upload name carries the mode and matrix.index",
    any(("bios-64" in str((s.get("with") or {}).get("name", "")) or "inputs.mode" in str((s.get("with") or {}).get("name", "")))
        and "matrix.index" in str((s.get("with") or {}).get("name", "")) for _, s, _ in bup))
chk("O04-AC-3: every action is pinned by SHA",
    all(re.search(r"@[0-9a-f]{40}\b", str(s["uses"])) for _, s, _ in steps if "uses" in s))
sys.exit(bad)
PY
fi

echo "== O04-AC-4: boot-test.yml bios matrix"
python3 - "$BOOT_WF" <<'PY' || fails=$((fails + $?))
import sys
bad = 0
try:
    import yaml
    doc = yaml.safe_load(open(sys.argv[1]).read())
    ram = doc["jobs"]["bios"]["strategy"]["matrix"]["ram_mb"]
except Exception as e:
    print(f"FAIL: O04-AC-4 boot-test.yml bios job matrix ram_mb is readable: {type(e).__name__}: {e}")
    sys.exit(1)
if ram == [64, 256]:
    print("PASS: O04-AC-4 boot-test.yml bios job matrix ram_mb is [64, 256]")
else:
    print(f"FAIL: O04-AC-4 boot-test.yml bios job matrix ram_mb is [64, 256] (got {ram!r})")
    sys.exit(1)
PY

echo
if [ "$fails" -ne 0 ]; then
	echo "$fails FAILED"
	exit 1
fi
echo "ALL PASS"
