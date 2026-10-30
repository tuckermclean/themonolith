#!/bin/sh
# O01 boot-tests: the reusable workflow, the 486 oracle's invariants, and the Make targets.
# Criteria: O01-AC-2 (workflow), O01-AC-3 (486 pairs, RAM), O01-AC-6 (run-bios/run-uefi),
# O01-AC-7 (test-boot). Offline; never boots QEMU (make -n, and a stubbed toolbox/run).
# Runs inside the toolbox (PyYAML, make) and in commit-less copies: paths come from this file.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
WF="$ROOT/.github/workflows/boot-test.yml"
BT="$ROOT/scripts/boot-test.py"
MODES="bios uefi toram ahci nvme usb virtio nicless nic vga fbdev-modprobe nat gui stele-acid2 clock-epoch clock-1996 persist"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/boot-test-workflow.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# ---- O01-AC-2 / AC-3 (workflow part): structure of boot-test.yml ----
if [ ! -f "$WF" ]; then
	fail "O01-AC-2 .github/workflows/boot-test.yml exists"
else
	python3 - "$WF" "$MODES" <<'PY'
import sys, re, json
import yaml
path, modes = sys.argv[1], sys.argv[2].split()
text = open(path).read()
bad = 0
def ok(l): print("PASS: " + l)
def no(l):
    global bad
    print("FAIL: " + l); bad += 1
def chk(l, c): ok(l) if c else no(l)

try:
    doc = yaml.safe_load(text)
    on = doc.get(True, doc.get("on"))
    jobs = doc["jobs"]
except Exception as e:
    print(f"FAIL: O01-AC-2 boot-test.yml parses as a workflow: {e}")
    sys.exit(1)

wc = (on or {}).get("workflow_call") if isinstance(on, dict) else None
chk("O01-AC-2 trigger is workflow_call", wc is not None)
inputs = (wc or {}).get("inputs") or {}
for i in ("iso-artifact", "iso-url", "iso-sha256", "kernel-version", "modes"):
    chk(f"O01-AC-2 input {i}", i in inputs)
chk("O01-AC-2 no build-version input (cache-era interface gone)", "build-version" not in inputs)

low = text.lower()
chk("O01-AC-2 no actions/cache text", "actions/cache" not in low)
chk("O01-AC-2 no aws text", not re.search(r"\baws", low))
# word match: the legacy s3fb framebuffer module name is not S3 storage
chk("O01-AC-2 no s3 text", not re.search(r"\bs3\b", low))

chk("O01-AC-2 fetch-iso job exists", "fetch-iso" in jobs)

def steps(j): return (jobs.get(j) or {}).get("steps") or []
ce = json.dumps(jobs.get("clock-epoch"))
chk("O01-AC-2 clock-epoch job exists", "clock-epoch" in jobs)
chk("O01-AC-2 clock-epoch job has no http.server", "clock-epoch" in jobs and "http.server" not in ce)
chk("O01-AC-2 nat-router job keeps its http.server",
    "nat-router" in jobs and "http.server" in json.dumps(jobs["nat-router"]))

pin = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
uses = []
for n, j in jobs.items():
    if "uses" in j: uses.append((n, j["uses"]))
    for s in j.get("steps") or []:
        if "uses" in s: uses.append((n, s["uses"]))
unpinned = [u for _, u in uses if not (u.startswith("./") or pin.match(u))]
chk("O01-AC-2 every uses: is a full commit SHA or local", uses and not unpinned)
if unpinned: print("  unpinned: " + ", ".join(sorted(set(unpinned))))

banned = []
for n, j in jobs.items():
    for s in j.get("steps") or []:
        r = s.get("run", "") or ""
        u = s.get("uses", "") or ""
        if re.search(r"\bpip3?\b", r) or "apt-get" in r or re.search(r"(^|/)setup-", u):
            banned.append(n)
chk("O01-AC-2 no pip, apt-get or setup-* step", not banned)
if banned: print("  in jobs: " + ", ".join(sorted(set(banned))))

ek = steps("expected-kernel")
chk("O01-AC-2 expected-kernel has a test -n guard",
    "expected-kernel" in jobs and any("test -n" in (s.get("run") or "") for s in ek))

mode_jobs = {n: j for n, j in jobs.items() if n not in ("expected-kernel", "fetch-iso")}
chk("O01-AC-2 mode jobs exist", len(mode_jobs) > 0)
covered = set()
for n, j in mode_jobs.items():
    ss = j.get("steps") or []
    chk(f"O01-AC-2 job {n} downloads the ISO artifact",
        any(str(s.get("uses", "")).startswith("actions/download-artifact@") for s in ss))
    runs = [s.get("run") or "" for s in ss if "make test-boot" in (s.get("run") or "")]
    m = [re.search(r"\bMODE=([A-Za-z0-9_-]+)", r) for r in runs]
    m = [x.group(1) for x in m if x]
    chk(f"O01-AC-2 job {n} test step is make test-boot with MODE=<mode>", len(m) == 1 and m[0] in modes)
    covered.update(m)
chk("O01-AC-2 the jobs cover all 17 modes", set(modes) <= covered)
if set(modes) - covered: print("  missing: " + " ".join(sorted(set(modes) - covered)))

# O01-AC-3: bios keeps both RAM sizes
bios = jobs.get("bios") or {}
ram = (((bios.get("strategy") or {}).get("matrix") or {}).get("ram_mb"))
chk("O01-AC-3 bios job matrix ram_mb is [64, 256]", ram == [64, 256])
sys.exit(1 if bad else 0)
PY
	[ $? -eq 0 ] || fails=$((fails + 1))
fi

# ---- O01-AC-3: boot-test.py keeps the 486 pairs and the bios default RAM ----
if [ ! -f "$BT" ]; then
	fail "O01-AC-3 scripts/boot-test.py exists"
else
	n=$(grep -o '"-cpu", "486"' "$BT" | wc -l | tr -d ' ')
	if [ "$n" = 6 ]; then pass "O01-AC-3 six -cpu 486 argument pairs"; else fail "O01-AC-3 six -cpu 486 argument pairs (found $n)"; fi
	python3 - "$BT" <<'PY'
import sys, types, importlib.util
if "pexpect" not in sys.modules:
    stub = types.ModuleType("pexpect")
    stub.TIMEOUT = type("TIMEOUT", (Exception,), {})
    stub.EOF = type("EOF", (Exception,), {})
    stub.ExceptionPexpect = type("ExceptionPexpect", (Exception,), {})
    stub.spawn = lambda *a, **k: None
    sys.modules["pexpect"] = stub
try:
    spec = importlib.util.spec_from_file_location("boot_test_mod", sys.argv[1])
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    v = m.MODE_DEFAULT_RAM["bios"]
except Exception as e:
    print(f"FAIL: O01-AC-3 MODE_DEFAULT_RAM[\"bios\"] readable: {type(e).__name__}: {e}")
    sys.exit(1)
if v == 64: print('PASS: O01-AC-3 MODE_DEFAULT_RAM["bios"] == 64')
else:
    print(f'FAIL: O01-AC-3 MODE_DEFAULT_RAM["bios"] == 64 (got {v!r})'); sys.exit(1)
PY
	[ $? -eq 0 ] || fails=$((fails + 1))
fi

# ---- O01-AC-6: manual boots, make -n ----
: >"$tmp/fake.iso"
mk() { make -C "$ROOT" "$@" 2>&1; }
out=$(mk -n run-bios ISO="$tmp/fake.iso")
echo "$out" | grep 'qemu-system-i386' | grep -q -- '-cpu 486' && pass "O01-AC-6 make -n run-bios: qemu-system-i386 -cpu 486" || fail "O01-AC-6 make -n run-bios: qemu-system-i386 -cpu 486"
echo "$out" | grep -q -- '-m 64M' && pass "O01-AC-6 make -n run-bios: -m 64M" || fail "O01-AC-6 make -n run-bios: -m 64M"
echo "$out" | grep -q -- "$tmp/fake.iso" && pass "O01-AC-6 make -n run-bios: on the ISO" || fail "O01-AC-6 make -n run-bios: on the ISO"
out=$(mk -n run-uefi ISO="$tmp/fake.iso" OVMF_CODE="$tmp/OVMF_CODE.fd")
echo "$out" | grep -q 'qemu-system-x86_64' && pass "O01-AC-6 make -n run-uefi: qemu-system-x86_64" || fail "O01-AC-6 make -n run-uefi: qemu-system-x86_64"
echo "$out" | grep -q "pflash.*$tmp/OVMF_CODE.fd" && pass "O01-AC-6 make -n run-uefi: OVMF pflash" || fail "O01-AC-6 make -n run-uefi: OVMF pflash"

# ---- O01-AC-7: test-boot, make -n ----
mk -pq test 2>/dev/null | grep '^test:' | grep -qw 'test-boot' && pass "O01-AC-7 make test depends on test-boot" || fail "O01-AC-7 make test depends on test-boot"
out=$(mk -nB test-boot)
echo "$out" | grep -q 'toolbox/run' && echo "$out" | grep -q 'boot-test\.py' && pass "O01-AC-7 make -n test-boot runs boot-test.py through toolbox/run" || fail "O01-AC-7 make -n test-boot runs boot-test.py through toolbox/run"
missing=""
for m in $MODES; do echo "$out" | grep -qw -- "$m" || missing="$missing $m"; done
[ -z "$missing" ] && pass "O01-AC-7 make -n test-boot names all 17 modes" || fail "O01-AC-7 make -n test-boot names all 17 modes (missing:$missing)"
sha_line=$(echo "$out" | grep -n 'sha256' | head -1 | cut -d: -f1)
boot_line=$(echo "$out" | grep -n 'boot-test\.py' | head -1 | cut -d: -f1)
if [ -n "$sha_line" ] && [ -n "$boot_line" ] && [ "$sha_line" -lt "$boot_line" ]; then pass "O01-AC-7 default ISO is sha256-checked before the first boot"; else fail "O01-AC-7 default ISO is sha256-checked before the first boot"; fi
echo "$out" | grep -q 'a96006596b13cc09fa951f54aadc0b816765d783e5d0e40895d7d0945edeb27a' && pass "O01-AC-7 default sha256 is rc1's" || fail "O01-AC-7 default sha256 is rc1's"
out=$(mk -nB test-boot MODE=bios)
others=""
for m in uefi toram ahci nvme virtio nicless stele-acid2 fbdev-modprobe clock-epoch clock-1996 persist; do echo "$out" | grep -qw -- "$m" && others="$others $m"; done
if echo "$out" | grep -q 'boot-test\.py' && echo "$out" | grep -qw bios && [ -z "$others" ]; then pass "O01-AC-7 make -n test-boot MODE=bios runs only bios"; else fail "O01-AC-7 make -n test-boot MODE=bios runs only bios (others:$others)"; fi

# ---- O01-AC-7: a wrong sha256 fails before any boot (real run, stubbed toolbox/run, file:// ISO) ----
t="$tmp/tree"
mkdir -p "$t/toolbox" "$t/scripts"
cp "$ROOT/Makefile" "$t/" 2>/dev/null
[ -f "$ROOT/scripts/boot-test.py" ] && cp "$ROOT/scripts/boot-test.py" "$t/scripts/"
cat >"$t/toolbox/run" <<'STUB'
#!/bin/sh
# stub: log every call; swallow boots and tool-version queries; run anything else directly
echo "$*" >>"$CALLS"
case "$*" in *boot-test.py*|*--version*|*dpkg-query*) exit 0 ;; esac
while [ $# -gt 0 ]; do case $1 in --) shift; break ;; --network|-e) shift 2 ;; --build) shift ;; *) break ;; esac; done
exec "$@"
STUB
chmod +x "$t/toolbox/run"
printf 'fixture iso\n' >"$tmp/src.iso"
good=$(sha256sum "$tmp/src.iso" | cut -d' ' -f1)
wrong=0000000000000000000000000000000000000000000000000000000000000000
CALLS="$tmp/calls.good"; export CALLS; : >"$CALLS"
(cd "$t" && make test-boot MODE=bios ISO_URL="file://$tmp/src.iso" ISO_SHA256="$good") >"$tmp/good.log" 2>&1
rc_good=$?
if [ $rc_good -eq 0 ] && grep -q 'boot-test\.py' "$CALLS" && grep -q 'bios' "$CALLS"; then pass "O01-AC-7 right sha256, MODE=bios: boots bios"; else fail "O01-AC-7 right sha256, MODE=bios: boots bios (rc=$rc_good)"; fi
rm -rf "$t/output"
CALLS="$tmp/calls.bad"; export CALLS; : >"$CALLS"
(cd "$t" && make test-boot ISO_URL="file://$tmp/src.iso" ISO_SHA256="$wrong") >"$tmp/bad.log" 2>&1
rc=$?
# Only meaningful once the right digest works: otherwise the target is simply missing.
if [ $rc_good -eq 0 ] && [ $rc -ne 0 ] && ! grep -q 'boot-test\.py' "$CALLS"; then pass "O01-AC-7 wrong sha256 fails before any boot"; else fail "O01-AC-7 wrong sha256 fails before any boot (rc=$rc, good rc=$rc_good, boots: $(grep -c 'boot-test\.py' "$CALLS"))"; fi

echo
if [ "$fails" -ne 0 ]; then echo "$fails FAILED"; exit 1; fi
echo "ALL PASS"
