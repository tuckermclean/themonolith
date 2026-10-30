#!/bin/sh
# Unit test for boot-test.py's wait_for_shell (O01-AC-8).
#
# The serial tty echoes every typed line at once, before any shell reads it.
# So a probe whose expected output equals its typed text "passes" on the echo
# while the console stub is still waiting for Enter. O01-AC-8: wait_for_shell
# returns only once the guest shell has EXECUTED its probe, and the next
# command's output is not mixed with what came before.
#
# pexpect-free: a fake child models the tty. Every sent line is echoed into the
# output stream at once; the "shell" is woken by the first empty line and runs
# the queued lines only after DELAY further sends, then appends each command's
# real output (echo X_$((6*7)) -> X_42, $? -> 0). BOOT_TEST_PY overrides the
# boot-test.py path (default: scripts/boot-test.py).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BOOT_TEST="${BOOT_TEST_PY:-$HERE/../boot-test.py}"

python3 - "$BOOT_TEST" <<'PY'
import sys, re, time, types, importlib.util

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

fails = 0
def check(label, cond, extra=""):
    global fails
    if cond:
        print(f"  ok: {label}")
    else:
        print(f"  FAIL: {label} {extra}")
        fails += 1

try:
    spec = importlib.util.spec_from_file_location("boot_test_mod", sys.argv[1])
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    wait_for_shell = m.wait_for_shell
    capture_output = m.capture_output
except Exception as e:
    print(f"  FAIL: O01-AC-8 cannot import wait_for_shell from {sys.argv[1]}: {type(e).__name__}: {e}")
    print()
    print("1 FAILED")
    sys.exit(1)

class FakeTTY:
    def __init__(self, delay):
        self.delay = delay
        self.stream = ""
        self.pos = 0
        self.sends = 0
        self.woken_at = None
        self.queue = []
        self.shell_up = False
        self.before = None
        self.match = None

    def _run(self, line):
        out = []
        for part in line.split(";"):
            part = part.strip()
            if part.startswith("echo "):
                t = part[5:].replace("$((6*7))", "42").replace("$?", "0")
                out.append(t + "\r\n")
        self.stream += "".join(out)

    def sendline(self, line=""):
        self.sends += 1
        self.stream += line + "\r\n"          # tty echo, immediately
        if self.woken_at is None:
            if line == "":
                self.woken_at = self.sends    # the stub's `read` is satisfied
            return                            # (lines before it are not run)
        if line:
            self.queue.append(line)
        if self.sends - self.woken_at >= self.delay:
            self.shell_up = True
        if self.shell_up:
            while self.queue:
                self._run(self.queue.pop(0))

    def _find(self, rx, timeout):
        mt = re.compile(rx).search(self.stream, self.pos)
        if not mt:
            time.sleep(0.005)
            raise pexpect.TIMEOUT(f"no match for {rx!r}")
        self.before = self.stream[self.pos:mt.start()]
        self.pos = mt.end()
        self.match = mt
        return 0

    def expect_exact(self, s, timeout=None):
        return self._find(re.escape(s), timeout)

    def expect(self, rx, timeout=None):
        return self._find(rx, timeout)

DELAY = 4
c = FakeTTY(DELAY)
returned_up = None
try:
    wait_for_shell(c, timeout=5)
    returned_up = c.shell_up
    err = ""
except Exception as e:
    err = f"{type(e).__name__}: {e}"
print("  O01-AC-8: wait_for_shell against a console that echoes at once, runs after a delay")
check("O01-AC-8 wait_for_shell returns once the shell is up",
      returned_up is not None, err)
check("O01-AC-8 wait_for_shell does not return on the tty echo (shell had executed the probe)",
      returned_up is True, f"(returned with shell_up={returned_up}, sends={c.sends})")

if returned_up is not None:
    try:
        code, out = capture_output(c, "echo hello", timeout=5)
    except Exception as e:
        check("O01-AC-8 next command completes", False, f"({type(e).__name__}: {e})")
    else:
        lines = [l.strip() for l in out.replace("\r", "").split("\n") if l.strip()]
        check("O01-AC-8 next command exits 0", code == 0, f"(code={code})")
        check("O01-AC-8 next command's own output is the last output, not mixed with earlier text",
              lines[-1:] == ["hello"] and "hello" in lines, f"(lines={lines!r})")

print()
if fails:
    print(f"{fails} FAILED")
    sys.exit(1)
print("ALL PASS")
PY
