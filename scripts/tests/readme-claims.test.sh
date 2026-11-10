#!/bin/sh
# G01-AC-3, G01-AC-7 and the text halves of G01-AC-4 / G01-AC-5: the README makes no claim the repo
# does not test. The checker lives in this file; it is proved on good/bad README fixtures in
# scripts/fixtures/G01/readme/ (placeholders @MODES@ @SLIPDEV@ @PPPDEV@ @HOSTKEY@ are filled from
# boot-test.py / build-rootfs.sh), then run on the real README.
# Inputs (environment, defaults in brackets):
#   README [README.md]  EVIDENCE_DIR [docs/evidence]  KCONFIG [configs/portage/savedconfig/sys-kernel/monolith-kernel]
#   BOOT_TEST [scripts/boot-test.py]  BUILD_ROOTFS [scripts/build-rootfs.sh]
# Offline; runs in the toolbox and in commit-less copies (paths come from this file).
#
# README RULES (the implementer follows these; "sentence" = text split at . ! ? + whitespace, blank
# lines, and at the start of a list item, table row or heading):
#  H1 (AC-3) A sentence naming Hyper-V (any case, "Hyper-V"/"HyperV") is allowed only if it is the
#     disclaimer: after deleting the words "not tested on Hyper-V" no Hyper-V remains. Any other
#     Hyper-V mention needs a dated file EVIDENCE_DIR/hyperv-<YYYY-MM-DD>.md (a real calendar date,
#     non-empty file); undated, badly named or empty files do not count.
#  H2 (AC-3) "Gen 1", "Gen1", "Generation 1" appears nowhere in the README, with or without evidence.
#  H3 (AC-3) KCONFIG has CONFIG_HYPERV, CONFIG_HYPERV_STORAGE, CONFIG_HYPERV_NET, CONFIG_HYPERV_KEYBOARD
#     and CONFIG_HYPERV_TIMER set to y or m (the symbols the predecessor's Hyper-V sentence implies:
#     paravirtual storage, network, input and the VMBus core). Independent of the README.
#  M1 (AC-7) Modes named in the README are: every MODE=<x> and every "--mode <x>" anywhere, plus every
#     inline code span matching [a-z][a-z0-9-]* on any line of the "## Testing" section that contains
#     the word "mode" (case-insensitive; fenced blocks excluded). Each must be a key of MODE_RUNNERS
#     in BOOT_TEST. (So write the mode list in one or more lines containing "mode", and no other
#     bare-word code span on such a line.)
#  M2 (AC-7 / change 1) Every key of MODE_RUNNERS appears as an inline code span in the "## Testing"
#     section (the README has such a section).
#  M3 (AC-7) The README does not contain "PPPoE" (any case).
#  S1 (AC-4) Every README line (any place) that runs slattach, i.e. matches (^|\s)(busybox\s+)?slattach\s+-,
#     must be exactly "busybox slattach -p slip <dev>" (optional trailing & ), with <dev> one of the
#     devices boot-test.py runs "busybox slattach -p slip <dev>" on (not the console ttyS0, no -l).
#     No such line is also fine (no SLIP claim).
#  S2 (AC-4) Every README line that starts a pppd command (^\s*(\$\s*)?pppd\s) must name a device that
#     boot-test.py runs "pppd <dev> 115200" on, and carry connect "chat ..." as the tested run does;
#     "pppd /dev/ttyS0 115200 noauth" is gone. No such line is fine.
#  K1 (AC-5) A sentence with "host key" names every key type S20keygen creates in BUILD_ROOTFS
#     (dropbearkey -t <type>) and no other type (rsa, dsa/dss, ed25519, ecdsa).
#  K2 (AC-5) If the README mentions dropbear, a sentence with "start" also has the inline code
#     span `dropbear` (started with `dropbear`, the form boot-test.py runs).
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
export README="${README:-$ROOT/README.md}"
export EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/docs/evidence}"
export KCONFIG="${KCONFIG:-$ROOT/configs/portage/savedconfig/sys-kernel/monolith-kernel}"
export BOOT_TEST="${BOOT_TEST:-$ROOT/scripts/boot-test.py}"
export BUILD_ROOTFS="${BUILD_ROOTFS:-$ROOT/scripts/build-rootfs.sh}"

python3 -I - "$ROOT" <<'PY'
import os, re, sys, datetime, tempfile

root = sys.argv[1]
bad = 0
def chk(label, cond, detail=""):
    global bad
    if cond: print("PASS: " + label)
    else: print("FAIL: " + label + (" -- " + detail if detail else "")); bad += 1

def rd(p):
    try: return open(p).read()
    except OSError: return None

bt_src = rd(os.environ["BOOT_TEST"]) or ""
rf_src = rd(os.environ["BUILD_ROOTFS"]) or ""
m = re.search(r"^MODE_RUNNERS\s*=\s*\{(.*?)^\}", bt_src, re.S | re.M)
modes = re.findall(r'^\s*"([^"]+)"\s*:', m.group(1), re.M) if m else []
slip_devs = sorted(set(re.findall(r"busybox slattach -p slip (/dev/\w+)", bt_src)))
ppp_devs = sorted(set(re.findall(r"pppd (/dev/\w+) 115200", bt_src)))
key_types = sorted(set(re.findall(r"dropbearkey -t (\w+)", rf_src)))
ALL_TYPES = ["rsa", "dsa", "dss", "ed25519", "ecdsa"]

def sentences(text):
    return [s for s in re.split(r"(?<=[.!?])\s+|\n\s*\n|\n(?=\s*(?:[-*|#]|\d+\.)\s?)", text) if s.strip()]

def valid_evidence(d):
    try: names = os.listdir(d)
    except OSError: return False
    for n in names:
        mm = re.fullmatch(r"hyperv-(\d{4}-\d{2}-\d{2})\.md", n)
        if not mm: continue
        try: datetime.date.fromisoformat(mm.group(1))
        except ValueError: continue
        p = os.path.join(d, n)
        if os.path.isfile(p) and os.path.getsize(p) > 0: return True
    return False

def testing_section(text):
    mm = re.search(r"^##\s+Testing\b.*?$(.*?)(?=^##\s|\Z)", text, re.S | re.M)
    return None if not mm else mm.group(1)

def strip_fences(t): return re.sub(r"^```.*?^```", "", t, flags=re.S | re.M)

def named_modes(text):
    out = set(re.findall(r"\bMODE=([A-Za-z0-9_-]+)", text)) | set(re.findall(r"--mode[ =]([A-Za-z0-9_-]+)", text))
    sec = testing_section(text)
    if sec:
        for line in strip_fences(sec).splitlines():
            if re.search(r"mode", line, re.I):
                out |= {s for s in re.findall(r"`([^`\n]+)`", line) if re.fullmatch(r"[a-z][a-z0-9-]*", s)}
    return out

def rules(text, evid):
    """Return {rule: [problem, ...]} for a README text."""
    r = {k: [] for k in ("H1", "H2", "M1", "M2", "M3", "S1", "S2", "K1", "K2")}
    ev = valid_evidence(evid)
    for s in sentences(text):
        if re.search(r"hyper-?v", re.sub(r"not\s+tested\s+on\s+hyper-?v", "", s, flags=re.I), re.I) and not ev:
            r["H1"].append(s.strip()[:80])
    for mm in re.finditer(r"\bgen(?:eration)?\.?\s*1\b", text, re.I): r["H2"].append(mm.group(0))
    for x in sorted(named_modes(text)):
        if x not in modes: r["M1"].append(x)
    sec = testing_section(text)
    if sec is None: r["M2"].append("no ## Testing section")
    else:
        spans = set(re.findall(r"`([^`\n]+)`", strip_fences(sec)))
        for x in modes:
            if x not in spans: r["M2"].append(x)
    if re.search(r"pppoe", text, re.I): r["M3"].append("PPPoE")
    for line in text.splitlines():
        if re.search(r"(^|\s)(busybox\s+)?slattach\s+-", line):
            mm = re.fullmatch(r"\s*(?:\$\s*)?busybox slattach -p slip (/dev/\w+)\s*&?\s*", line)
            if not mm or mm.group(1) not in slip_devs: r["S1"].append(line.strip())
        if re.match(r"\s*(\$\s*)?pppd\s", line):
            mm = re.match(r"\s*(?:\$\s*)?pppd\s+(/dev/\w+)\s+115200\b", line)
            if not mm or mm.group(1) not in ppp_devs or not re.search(r"connect\s+.*chat\b", line): r["S2"].append(line.strip())
    ss = sentences(text)
    for s in ss:
        if re.search(r"host\s+keys?", s, re.I):
            have = {t for t in ALL_TYPES if re.search(r"\b" + t + r"\b", s, re.I)}
            if have != set(key_types): r["K1"].append(s.strip()[:80] + f" [names {sorted(have)}, guest has {key_types}]")
    if re.search(r"dropbear", text, re.I) and not any(re.search(r"\bstart", s, re.I) and "`dropbear`" in s for s in ss):
        r["K2"].append("no sentence says to start it with `dropbear`")
    return r

def expand(t):
    return (t.replace("@MODES@", ", ".join("`%s`" % x for x in modes)).replace("@SLIPDEV@", slip_devs[0] if slip_devs else "")
             .replace("@PPPDEV@", ppp_devs[0] if ppp_devs else "").replace("@HOSTKEY@", " and ".join(k.upper() for k in key_types)))

chk("G01-AC-7 the mode list is read from boot-test.py MODE_RUNNERS", "bios" in modes and "serial-net" in modes)
chk("G01-AC-4 boot-test.py's tested SLIP and pppd devices are read", bool(slip_devs) and bool(ppp_devs), f"slip={slip_devs} ppp={ppp_devs}")
chk("G01-AC-5 the dropbear host key type is read from S20keygen in build-rootfs.sh", bool(key_types), f"types={key_types}")

# ---- the checker proved on fixtures ----
fx = os.path.join(root, "scripts", "fixtures", "G01", "readme")
tmp = tempfile.mkdtemp()
empty = os.path.join(tmp, "none"); os.mkdir(empty)
def fixture(name):
    t = rd(os.path.join(fx, name))
    return None if t is None else expand(t)
good = fixture("good.md")
rg = rules(good, empty) if good else None
chk("G01-AC-3 fixture good.md is accepted (no rule fires)", rg is not None and not any(rg.values()), str(rg))
cases = [
    ("bad-hyperv-claim.md", {"H1"}, "G01-AC-3"), ("bad-gen1.md", {"H1", "H2"}, "G01-AC-3"),
    ("bad-unknown-mode.md", {"M1"}, "G01-AC-7"), ("bad-pppoe.md", {"M3"}, "G01-AC-7"),
    ("bad-slattach.md", {"S1"}, "G01-AC-4"), ("bad-pppd.md", {"S2"}, "G01-AC-4"),
    ("bad-rsa-hostkey.md", {"K1"}, "G01-AC-5"), ("bad-dropbear-start.md", {"K2"}, "G01-AC-5"),
]
for name, want, ac in cases:
    t = fixture(name)
    got = {k for k, v in rules(t, empty).items() if v} if t else None
    chk(f"{ac} fixture {name} is rejected as {sorted(want)} only", got == want, f"got {got}")
# the README with its Testing section removed fails M2
if good:
    nosec = re.sub(r"^## Testing.*?(?=^## |\Z)", "", good, flags=re.S | re.M)
    chk("G01-AC-7 a README without a Testing section fails M2", bool(rules(nosec, empty)["M2"]))
    part = good.replace("`" + modes[0] + "`", "", 1) if modes else good
    chk("G01-AC-7 a Testing section missing one mode fails M2", bool(rules(part, empty)["M2"]))
# evidence branch, both ways (G01-AC-3)
claim = fixture("bad-hyperv-claim.md")
def with_evidence(name, content="Tested on a Hyper-V host.\n"):
    d = tempfile.mkdtemp(dir=tmp)
    if name:
        with open(os.path.join(d, name), "w") as f: f.write(content)
    return d
chk("G01-AC-3 a Hyper-V claim passes with a dated evidence file", claim and not rules(claim, with_evidence("hyperv-2026-11-09.md"))["H1"])
for nm in ("hyperv-today.md", "hyperv-2026-11-9.md", "hyperv-2026-13-45.md", "hyperv-20261109.md", "hyperv-2026-11-09.txt", "evidence-2026-11-09.md"):
    chk(f"G01-AC-3 evidence file {nm} does not count", claim and bool(rules(claim, with_evidence(nm))["H1"]))
chk("G01-AC-3 an empty dated evidence file does not count", claim and bool(rules(claim, with_evidence("hyperv-2026-11-09.md", ""))["H1"]))
chk("G01-AC-3 the Gen 1 rule holds even with evidence", bool(rules(fixture("bad-gen1.md"), with_evidence("hyperv-2026-11-09.md"))["H2"]))
chk("G01-AC-3 the disclaimer alone needs no evidence", good and not rules(good, empty)["H1"])

# ---- the real README ----
text = rd(os.environ["README"])
chk("G01-AC-3 the README exists", text is not None, os.environ["README"])
text = text or ""
r = rules(text, os.environ["EVIDENCE_DIR"])
def rep(label, rule, extra=None):
    chk(label, not r[rule], "; ".join(r[rule]))
rep("G01-AC-3 H1 every README Hyper-V sentence is the disclaimer or has a dated docs/evidence/hyperv-<date>.md", "H1")
rep("G01-AC-3 H2 no sentence claims Hyper-V Gen 1 targeting", "H2")
kc = rd(os.environ["KCONFIG"]) or ""
for sym in ("HYPERV", "HYPERV_STORAGE", "HYPERV_NET", "HYPERV_KEYBOARD", "HYPERV_TIMER"):
    chk(f"G01-AC-3 H3 CONFIG_{sym} is y or m in the savedconfig", re.search(rf"^CONFIG_{sym}=[ym]\s*$", kc, re.M) is not None)
rep("G01-AC-7 M1 every mode the README names is in boot-test.py's mode list", "M1")
chk("G01-AC-7 M2 the README has a Testing section", testing_section(text) is not None)
for x in modes:
    chk(f"G01-AC-7 M2 the README's Testing section lists mode {x}", x not in r["M2"] and testing_section(text) is not None)
rep("G01-AC-7 M3 the README does not mention PPPoE", "M3")
rep("G01-AC-4 S1 the README's SLIP command is the tested busybox slattach -p slip on a tested port", "S1")
rep("G01-AC-4 S2 the README's pppd command is the tested one (device, connect chat)", "S2")
chk("G01-AC-4 the untested predecessor line 'pppd /dev/ttyS0 115200 noauth' is gone", "pppd /dev/ttyS0 115200 noauth" not in text)
rep("G01-AC-5 K1 the README names the host key type S20keygen creates, and no other", "K1")
rep("G01-AC-5 K2 the README starts dropbear with `dropbear`", "K2")
sys.exit(1 if bad else 0)
PY
rc=$?
echo
if [ "$rc" -ne 0 ]; then echo "FAILED"; exit 1; fi
echo "ALL PASS"
