#!/bin/sh
# G01-AC-4 / G01-AC-5: harness checks for mode `serial-net` in scripts/boot-test.py, without booting QEMU.
# Specified: the mode exists (runner, builder, RAM default, --mode choice); its QEMU command line(s) give the
# guest a NIC with a host port forward to guest port 22 (for the host `ssh -i` login); the mode's code covers
# SLIP ping, PPP ping through chat, the negative chat case, the dropbear `ssh -i ... id` login and an ECDSA
# host key. Left open: one guest with a pty pair versus two guests over a serial link.
# Left to the boot run (`make test-boot MODE=serial-net`, run, not encoded): that the pings and the login
# really work and that packets cross the link. Offline; runs in the toolbox and in commit-less copies.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/g01-serial-net.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
printf '#!/bin/sh\nexit 0\n' > "$tmp/qemu-system-i386"; chmod +x "$tmp/qemu-system-i386"
: > "$tmp/x.iso"

python3 -I - "$ROOT" "$tmp" <<'PY'
import sys, os, re, inspect, importlib.util
root, tmp = sys.argv[1], sys.argv[2]
bad = 0
def chk(label, cond, detail=""):
    global bad
    if cond: print("PASS: " + label)
    else:
        print("FAIL: " + label + (f" ({detail})" if detail else "")); bad += 1

m = None
try:
    spec = importlib.util.spec_from_file_location("boot_test_mod_g01_serial_net", os.path.join(root, "scripts/boot-test.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
except BaseException as e:
    print(f"  cannot import boot-test.py: {type(e).__name__}: {e}")
have = m is not None and "serial-net" in getattr(m, "MODE_RUNNERS", {}) and "serial-net" in getattr(m, "MODE_BUILDERS", {})
chk("G01-AC-4 mode serial-net has a runner and a builder", have)

# --mode accepts serial-net
ok = False
if m is not None:
    old = sys.argv
    sys.argv = ["boot-test.py", "--iso", os.path.join(tmp, "x.iso"), "--mode", "serial-net",
                "--kernel-version", "k", "--qemu-i386", os.path.join(tmp, "qemu-system-i386")]
    try:
        import contextlib, io
        with contextlib.redirect_stderr(io.StringIO()):
            a = m.parse_args()
        ok = a.mode == "serial-net"
    except BaseException:
        a = None
    sys.argv = old
chk("G01-AC-4 boot-test.py --mode accepts serial-net", ok)

# QEMU command line(s): collect what the builder (and any serial-net builder helpers) return
cmds = []
if have and ok:
    a.ram_mb = m.MODE_DEFAULT_RAM.get("serial-net", 64) if hasattr(m, "MODE_DEFAULT_RAM") else 64
    os.environ["PATH"] = tmp + os.pathsep + os.environ.get("PATH", "")
    fns = [m.MODE_BUILDERS["serial-net"]] + [f for n, f in vars(m).items()
           if re.match(r"build_serial_?net", n) and callable(f) and f is not m.MODE_BUILDERS["serial-net"]]
    for f in fns:
        try:
            r = f(a)
        except BaseException as e:
            print(f"  builder {getattr(f, '__name__', f)}: {type(e).__name__}: {e}")
            continue
        if r and isinstance(r[0], (list, tuple)): cmds += [list(c) for c in r]
        elif r: cmds.append(list(r))
chk("G01-AC-4 serial-net builder returns a QEMU command line", bool(cmds) and all(c and "qemu" in os.path.basename(str(c[0])) for c in cmds))
flat = " ".join(str(x) for c in cmds for x in c)
chk("G01-AC-5 a serial-net QEMU command line forwards a host port to guest port 22 (hostfwd)",
    re.search(r"hostfwd=[^, ]*:[0-9]*-[^, ]*:22(,|\s|$)", flat) is not None)
chk("G01-AC-5 a serial-net QEMU command line gives the guest a NIC", bool(cmds) and
    re.search(r"(-nic\s+(?!none)|-device\s+\S*(e1000|rtl8139|ne2k|pcnet|virtio-net)\S*)", flat) is not None)

# the mode's checks: source of the runner and any serial-net helpers
src = ""
if have:
    fs = [m.MODE_RUNNERS["serial-net"]] + [f for n, f in vars(m).items()
          if re.search(r"serial_?net", n) and inspect.isfunction(f)]
    seen = set()
    for f in fs:
        if f in seen: continue
        seen.add(f)
        try: src += inspect.getsource(f) + "\n"
        except (OSError, TypeError): pass
def has(rx): return re.search(rx, src, re.I) is not None
chk("G01-AC-4 serial-net checks SLIP (slattach) and a ping over it", has(r"slattach") and has(r"ping"))
chk("G01-AC-4 serial-net checks PPP through chat (pppd ... chat) and a ping over it", has(r"pppd") and has(r"\bchat\b"))
chk("G01-AC-4 serial-net checks a chat expecting a string that never arrives fails (non-zero exit accepted as the pass)",
    has(r"\bchat\b") and (has(r"contains_with_exit|expected_exit|nonzero|non-zero|never") ))
chk("G01-AC-5 serial-net starts dropbear and logs in with a host `ssh -i ... id`", has(r"dropbear") and has(r"\bssh\b") and has(r"-i\b") and has(r"\bid\b"))
chk("G01-AC-5 serial-net checks the guest host key type is ECDSA", has(r"ecdsa"))
sys.exit(1 if bad else 0)
PY
r=$?
echo
if [ "$r" -ne 0 ]; then echo "FAILED"; exit 1; fi
echo "ALL PASS"
