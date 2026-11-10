#!/bin/sh
# G01 README claims, second rule set (S4b, after the S4 review): M4, S3, H4, D1. These are regression
# guards: the rules are implemented HERE (readme-claims.test.sh is frozen and not touched), applied
# (a) to the real README and (b) to the fixtures in scripts/fixtures/G01/readme/ (placeholders
# @MODES@ @SLIPDEV@ @PPPDEV@ @HOSTKEY@ are filled from boot-test.py / build-rootfs.sh as there), which
# prove that each rule rejects its bad fixture and accepts good ones. Offline.
# Inputs (environment, defaults in brackets): README [README.md]  EVIDENCE_DIR [docs/evidence]
#   BOOT_TEST [scripts/boot-test.py]  BUILD_ROOTFS [scripts/build-rootfs.sh]  BUILD_ISO [scripts/build-iso.sh]
#
# RULES (fenced ``` blocks are excluded only where stated; "sentence" = text split after . ! ? + whitespace,
# at blank lines, and at the start of a list item, table row or heading):
#  M4 (G01-AC-7) Every inline code span the README uses as a boot-mode name ANYWHERE is a key of
#     MODE_RUNNERS in BOOT_TEST. A boot-mode name is: (1) a code span followed by optional whitespace and
#     (boot )?modes?\b ("the `nic` mode"); (2) each code span of a "`a`, `b` and `c` modes" list
#     (spans joined by commas / "and" / "or", then modes?); (3) every code span matching
#     [a-z][a-z0-9-]* in each non-fenced paragraph/list block of the "## Testing" section that contains the
#     word "modes", even on lines without the word "mode". Fenced blocks are excluded.
#  S3 (G01-AC-4) Any slattach invocation anywhere in a line (also in prose or inline code), found by
#     (^|[\s`$(])(busybox\s+)?slattach\s+- , must be exactly "busybox slattach -p slip <dev>" with <dev>
#     a device boot-test.py runs it on. Any (^|[\s`$(])pppd\s+/dev/ anywhere must be "pppd <dev> 115200 ..."
#     with <dev> a device boot-test.py runs pppd on, and carry connect "chat ..." on the same line.
#  H4 (G01-AC-3) Hyper-V is matched as hyper[-\s]?v, case-insensitively. Without a dated evidence file
#     (EVIDENCE_DIR/hyperv-YYYY-MM-DD.md, real calendar date, non-empty) every sentence mentioning it must,
#     after stripping markup and whitespace, match ^(the disc is )?not tested on hyper-v\.?$ (case-insens.).
#     With such a file any sentence is allowed.
#  D1 (G01-AC-7) If the README states the boot menu default ("default is `X`", or a `X` ... "the default"
#     table row), X equals the DEFAULT in BUILD_ISO's isolinux.cfg. No default claim passes.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
export README="${README:-$ROOT/README.md}"
export EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/docs/evidence}"
export BOOT_TEST="${BOOT_TEST:-$ROOT/scripts/boot-test.py}"
export BUILD_ROOTFS="${BUILD_ROOTFS:-$ROOT/scripts/build-rootfs.sh}"
export BUILD_ISO="${BUILD_ISO:-$ROOT/scripts/build-iso.sh}"

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

bt = rd(os.environ["BOOT_TEST"]) or ""
rf = rd(os.environ["BUILD_ROOTFS"]) or ""
bi = rd(os.environ["BUILD_ISO"]) or ""
m = re.search(r"^MODE_RUNNERS\s*=\s*\{(.*?)^\}", bt, re.S | re.M)
modes = re.findall(r'^\s*"([^"]+)"\s*:', m.group(1), re.M) if m else []
slip_devs = sorted(set(re.findall(r"busybox slattach -p slip (/dev/\w+)", bt)))
ppp_devs = sorted(set(re.findall(r"pppd (/dev/\w+) 115200", bt)))
key_types = sorted(set(re.findall(r"dropbearkey -t (\w+)", rf)))
mi = re.search(r"isolinux\.cfg\"\s*<<\s*'?EOF'?\n(.*?)^EOF$", bi, re.S | re.M)
dm = re.search(r"^DEFAULT\s+(\S+)", mi.group(1) if mi else "", re.M)
default = dm.group(1) if dm else None

def expand(t):
    return (t.replace("@MODES@", ", ".join("`%s`" % x for x in modes)).replace("@SLIPDEV@", slip_devs[0] if slip_devs else "")
             .replace("@PPPDEV@", ppp_devs[0] if ppp_devs else "").replace("@HOSTKEY@", " and ".join(k.upper() for k in key_types)))

def strip_fences(t): return re.sub(r"^```.*?^```", "", t, flags=re.S | re.M)
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

SPAN = r"`([^`\n]+)`"
def mode_names(text):
    prose = strip_fences(text)
    out = set(re.findall(SPAN + r"\s*(?:boot\s+)?modes?\b", prose))
    for lm in re.finditer(r"((?:`[^`\n]+`\s*(?:,\s*(?:(?:and|or)\s+)?|\s+(?:and|or)\s+))*`[^`\n]+`)\s*(?:boot\s+)?modes?\b", prose):
        out |= set(re.findall(SPAN, lm.group(1)))
    sec = testing_section(text)
    if sec:
        for block in re.split(r"\n\s*\n", strip_fences(sec)):
            if re.search(r"\bmodes\b", block, re.I):
                out |= {s for s in re.findall(SPAN, block) if re.fullmatch(r"[a-z][a-z0-9-]*", s)}
    return out

def rules(text, evid):
    r = {k: [] for k in ("M4", "S3", "H4", "D1")}
    for x in sorted(mode_names(text)):
        if x not in modes: r["M4"].append(x)
    for line in text.splitlines():
        for mm in re.finditer(r"(?:^|[\s`$(])((?:busybox\s+)?slattach\s+-.*)", line):
            ok = re.match(r"busybox slattach -p slip (/dev/\w+)(?![\w/])", mm.group(1))
            if not ok or ok.group(1) not in slip_devs: r["S3"].append(line.strip()[:90])
        for mm in re.finditer(r"(?:^|[\s`$(])(pppd\s+/dev/.*)", line):
            ok = re.match(r"pppd (/dev/\w+) 115200\b", mm.group(1))
            if not ok or ok.group(1) not in ppp_devs or not re.search(r"connect\s+[\"']chat\s", line): r["S3"].append(line.strip()[:90])
    if not valid_evidence(evid):
        for s in sentences(text):
            if re.search(r"hyper[-\s]?v", s, re.I):
                t = re.sub(r"[`*_\[\]|>#]|^\s*(?:[-+]|\d+\.)\s+", "", s)
                t = re.sub(r"\s+", " ", t).strip()
                if not re.fullmatch(r"(the disc is )?not tested on hyper-v\.?", t, re.I): r["H4"].append(s.strip()[:80])
    claims = set(re.findall(r"\bdefault\s+is\s+`([^`\n]+)`", text, re.I))
    for line in text.splitlines():
        lm = re.search(r"`([A-Za-z0-9_-]+)`[^\n]*,\s*the\s+default\b", line, re.I)
        if lm: claims.add(lm.group(1))
    for c in sorted(claims):
        if c != default: r["D1"].append(c)
    return r
def fired(text, evid): return {k for k, v in rules(text, evid).items() if v}

chk("G01-AC-7 the mode list is read from boot-test.py MODE_RUNNERS", "bios" in modes and "serial-net" in modes)
chk("G01-AC-4 the tested SLIP and pppd devices are read from boot-test.py", bool(slip_devs) and bool(ppp_devs), f"slip={slip_devs} ppp={ppp_devs}")
chk("G01-AC-7 D1 the isolinux.cfg DEFAULT is read from build-iso.sh", default is not None)

# ---- the rules proved on fixtures ----
fx = os.path.join(root, "scripts", "fixtures", "G01", "readme")
tmp = tempfile.mkdtemp()
empty = os.path.join(tmp, "none"); os.mkdir(empty)
def fixture(name):
    t = rd(os.path.join(fx, name))
    return None if t is None else expand(t)
def evid(name="hyperv-2026-11-09.md", content="Tested on a Hyper-V host.\n"):
    d = tempfile.mkdtemp(dir=tmp)
    if name:
        with open(os.path.join(d, name), "w") as f: f.write(content)
    return d

for name in ("good.md", "good-default.md"):
    t = fixture(name)
    got = fired(t, empty) if t else None
    chk(f"G01 fixture {name} is accepted by M4 S3 H4 D1", got == set(), f"got {got}")
cases = [
    ("bad-mode-prose.md", "M4", "G01-AC-7"), ("bad-mode-listline.md", "M4", "G01-AC-7"),
    ("bad-slattach-prose.md", "S3", "G01-AC-4"), ("bad-pppd-prose.md", "S3", "G01-AC-4"),
    ("bad-hyperv-but.md", "H4", "G01-AC-3"), ("bad-hyperv-space.md", "H4", "G01-AC-3"),
    ("bad-default.md", "D1", "G01-AC-7"),
]
for name, rule, ac in cases:
    t = fixture(name)
    got = fired(t, empty) if t else None
    chk(f"{ac} fixture {name} is rejected by {rule} only", got == {rule}, f"got {got}")
for name in ("bad-hyperv-but.md", "bad-hyperv-space.md"):
    t = fixture(name)
    chk(f"G01-AC-3 H4 {name} is accepted with a dated evidence file", t is not None and "H4" not in fired(t, evid()))
    chk(f"G01-AC-3 H4 {name} is still rejected with an undated evidence file", t is not None and "H4" in fired(t, evid("hyperv-today.md")))
    chk(f"G01-AC-3 H4 {name} is still rejected with an empty dated evidence file", t is not None and "H4" in fired(t, evid(content="")))
# inline positives and negatives
pre = "# T\n\n## Testing\n\nThe boot modes are @MODES@.\n\n"
def inline(s): return fired(expand(pre) + s + "\n", empty)
chk("G01-AC-4 S3 inline `busybox slattach -p slip <tested dev>` is accepted", inline("Run `busybox slattach -p slip %s` there." % slip_devs[0]) == set())
chk("G01-AC-4 S3 inline `busybox slattach -p slip /dev/ttyS0` (console) is rejected", inline("Run `busybox slattach -p slip /dev/ttyS0` there.") == {"S3"})
chk("G01-AC-4 S3 bare slattach -p slip without busybox is rejected", inline("Run slattach -p slip %s there." % slip_devs[0]) == {"S3"})
chk("G01-AC-4 S3 `pppd <tested dev> 115200 ... connect \"chat ...\"` is accepted",
    inline("Run `pppd %s 115200 noauth connect \"chat -t 60 '' AT OK\"` there." % ppp_devs[0]) == set())
chk("G01-AC-4 S3 pppd without connect chat is rejected", inline("Run `pppd %s 115200 noauth` there." % ppp_devs[0]) == {"S3"})
chk("G01-AC-7 M4 `nic` mode named in prose is accepted", inline("The `nic` mode boots it.") == set())
chk("G01-AC-7 M4 `bogus` boot mode named in prose is rejected", inline("The `bogus` boot mode boots it.") == {"M4"})
chk("G01-AC-7 M4 a list '`bios`, `bogus` and `uefi` modes' is rejected", inline("The `bios`, `bogus` and `uefi` modes work.") == {"M4"})
chk("G01-AC-7 M4 a bogus span inside a fenced block is not a mode claim", inline("```\n`bogus` mode\n```") == set())
chk("G01-AC-3 H4 'The disc is not tested on Hyper-V.' is accepted", inline("The disc is not tested on Hyper-V.") == set())
chk("G01-AC-3 H4 'Hyperv works.' is rejected", inline("Hyperv works.") == {"H4"})
chk("G01-AC-7 D1 'The default is `bogus`.' is rejected", inline("The default is `bogus`.") == {"D1"})

# ---- the real README ----
text = rd(os.environ["README"])
chk("G01 the README exists", text is not None, os.environ["README"])
r = rules(text or "", os.environ["EVIDENCE_DIR"])
chk("G01-AC-7 M4 every boot-mode name the README uses is a MODE_RUNNERS key", not r["M4"], "; ".join(r["M4"]))
chk("G01-AC-4 S3 every slattach/pppd invocation in the README is the tested one", not r["S3"], "; ".join(r["S3"]))
chk("G01-AC-3 H4 every README Hyper-V sentence is exactly the disclaimer (or a dated evidence file exists)", not r["H4"], "; ".join(r["H4"]))
chk("G01-AC-7 D1 the README's boot menu default claim (if any) is the isolinux.cfg DEFAULT", not r["D1"], "; ".join(r["D1"]) + " vs " + str(default))
sys.exit(1 if bad else 0)
PY
rc=$?
echo
if [ "$rc" -ne 0 ]; then echo "FAILED"; exit 1; fi
echo "ALL PASS"
