#!/bin/sh
# G01-AC-6: scripts/smoke-checks.txt has one row per world atom, every exclusion is a valid
# `covered` or `untestable` row whose reference resolves, and the smoke runner reads the table.
# The checker lives in this file; it is proved on good/bad fixtures in scripts/fixtures/G01/, then
# run against the real table. The boot itself is `make test-boot MODE=smoke` (run, not encoded).
# Offline; runs in the toolbox and in commit-less copies (paths come from this file).
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)

python3 -I - "$ROOT" <<'PY'
import os, re, sys, importlib.util

root = sys.argv[1]
bad = 0
def chk(label, cond):
    global bad
    if cond: print("PASS: " + label)
    else: print("FAIL: " + label); bad += 1

def world_atoms(path):
    out = []
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out

def cat_pkg(atom):
    a = re.sub(r"^[<>=~!]+", "", atom)
    a = a.split(":")[0]
    return re.sub(r"-\d[\w.]*?(-r\d+)?$", "", a)

def mode_list(bt):
    src = open(bt).read()
    m = re.search(r"^MODE_RUNNERS\s*=\s*\{(.*?)^\}", src, re.S | re.M)
    return set(re.findall(r'^\s*"([^"]+)"\s*:', m.group(1), re.M)) if m else set()

def check(world, table_text, modes, root):
    """Return a list of (code, detail) problems; empty means the table is valid."""
    errs = []
    atoms = world_atoms(world)
    rows = {}
    parsed = []
    for n, raw in enumerate(table_text.splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        f = raw.split("\t")
        atom, kind = f[0], (f[1] if len(f) > 1 else "")
        parsed.append((n, atom, kind, f[2:]))
        rows.setdefault(atom, []).append(n)
    for a in atoms:
        if a not in rows: errs.append(("missing-row", a))
        elif len(rows[a]) > 1: errs.append(("duplicate-row", a))
    for a in rows:
        if a not in atoms: errs.append(("extra-row", a))
    runs = {cat_pkg(a) for (_, a, k, _) in parsed if k == "run" and a in atoms}
    for n, atom, kind, rest in parsed:
        if kind == "run":
            cmd = rest[0].strip() if rest else ""
            rx = rest[1] if len(rest) > 1 else ""
            if not cmd or not rx.strip(): errs.append(("bad-run", f"{atom}: needs a command and a regex"))
            try: re.compile(rx)
            except re.error: errs.append(("bad-regex", atom))
        elif kind == "covered":
            where = rest[0].strip() if rest else ""
            k, _, v = where.partition(":")
            if k == "mode":
                if v not in modes: errs.append(("bad-mode-ref", f"{atom}: {v}"))
            elif k == "test":
                if not (v.startswith("scripts/tests/") and os.path.isfile(os.path.join(root, v))):
                    errs.append(("bad-test-ref", f"{atom}: {v}"))
            elif k == "atom":
                if v not in runs: errs.append(("bad-atom-ref", f"{atom}: {v}"))
            else:
                errs.append(("bad-where", f"{atom}: {where!r}"))
        elif kind == "untestable":
            reason = rest[0].strip() if rest else ""
            if not reason: errs.append(("empty-reason", atom))
            elif re.fullmatch(r"n/?a\.?", reason, re.I): errs.append(("bare-na", atom))
        else:
            errs.append(("unknown-kind", f"{atom}: {kind!r}"))
    return errs

def codes(errs): return sorted({c for c, _ in errs})

bt = os.path.join(root, "scripts", "boot-test.py")
fx = os.path.join(root, "scripts", "fixtures", "G01")
modes = mode_list(bt)
chk("G01-AC-6 the mode list is read from boot-test.py MODE_RUNNERS", "bios" in modes and "persist" in modes)

# ---- the checker, proved on fixtures ----
fw = os.path.join(fx, "world.txt")
def fixture(name):
    p = os.path.join(fx, name)
    return open(p).read() if os.path.isfile(p) else None
good = fixture("good.tsv")
chk("G01-AC-6 fixture good.tsv is accepted", good is not None and check(fw, good, modes, root) == [])
for name, want in (
    ("bad-missing-atom.tsv", "missing-row"),
    ("bad-duplicate-row.tsv", "duplicate-row"),
    ("bad-extra-row.tsv", "extra-row"),
    ("bad-unknown-kind.tsv", "unknown-kind"),
    ("bad-bare-na.tsv", "bare-na"),
    ("bad-empty-reason.tsv", "empty-reason"),
    ("bad-mode-ref.tsv", "bad-mode-ref"),
    ("bad-test-ref.tsv", "bad-test-ref"),
    ("bad-atom-ref.tsv", "bad-atom-ref"),
    ("bad-run-command.tsv", "bad-run"),
    ("bad-run-regex.tsv", "bad-regex"),
):
    t = fixture(name)
    chk(f"G01-AC-6 fixture {name} is rejected as {want} only", t is not None and codes(check(fw, t, modes, root)) == [want])

# ---- the real table ----
table = os.path.join(root, "scripts", "smoke-checks.txt")
exists = os.path.isfile(table)
chk("G01-AC-6 scripts/smoke-checks.txt exists", exists)
real_world = os.path.join(root, "configs", "portage", "world")
text = open(table).read() if exists else ""
errs = check(real_world, text, modes, root) if exists else [("missing-row", "no table")]
def only(*cs): return exists and not [e for e in errs if e[0] in cs]
chk("G01-AC-6 every world atom has exactly one row, and no row names a non-atom", only("missing-row", "duplicate-row", "extra-row"))
chk("G01-AC-6 every row is run, covered or untestable", exists and only("unknown-kind"))
chk("G01-AC-6 every run row has a command and a regex that compiles", exists and only("bad-run", "bad-regex"))
chk("G01-AC-6 every covered row names a mode, an existing scripts/tests file, or an atom with a run row", exists and only("bad-mode-ref", "bad-test-ref", "bad-atom-ref", "bad-where"))
chk("G01-AC-6 every untestable row has a reason that is not a bare n/a", exists and only("empty-reason", "bare-na"))
for c, d in errs[:20]:
    if exists: print(f"  {c}: {d}")

# ---- the smoke runner reads the table (harness unit check) ----
mod = None
try:
    spec = importlib.util.spec_from_file_location("boot_test_mod_g01_smoke", bt)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
except BaseException as e:
    print(f"  cannot import boot-test.py: {type(e).__name__}: {e}")
fn = getattr(mod, "parse_smoke_table", None)
chk("G01-AC-6 boot-test.py defines parse_smoke_table(text)", callable(fn))
sample = fixture("smoke-checks-sample.tsv")
if callable(fn) and sample is not None:
    try: got = [tuple(r) for r in fn(sample)]
    except BaseException as e: got = None; print(f"  parse_smoke_table raised {type(e).__name__}: {e}")
    chk("G01-AC-6 parse_smoke_table returns only the run rows as (atom, command, regex)",
        got == [("sys-apps/busybox", "busybox --help", "BusyBox v"),
                ("=games-roguelike/nethack-3.6.7-r1", "ls /usr/games | head -1", "nethack")])
    if exists:
        try: n = len(fn(text))
        except BaseException: n = -1
        want = sum(1 for l in text.splitlines() if l.split("\t")[1:2] == ["run"])
        chk("G01-AC-6 parse_smoke_table returns one entry per run row of the real table", n == want and n > 0)
else:
    chk("G01-AC-6 parse_smoke_table returns only the run rows as (atom, command, regex)", False)
    chk("G01-AC-6 parse_smoke_table returns one entry per run row of the real table", False)
sys.exit(1 if bad else 0)
PY
rc=$?
echo
if [ "$rc" -ne 0 ]; then echo "FAILED"; exit 1; fi
echo "ALL PASS"
