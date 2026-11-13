#!/bin/sh
# M02 builder-rebuild: Dockerfile, Makefile build-image, .github/workflows/toolchain-bump.yml.
# Criteria: M02-AC-1 .. M02-AC-5. Offline; needs no rebuilt image, no rebuilt.txt and no git history
# (runs in commit-less copies: paths come from this file; the predecessor Dockerfile is a fixture).
#  - AC-1: diff of the comment-stripped predecessor Dockerfile (fixture, proved to be the b9f533b blob) and Dockerfile.
#  - AC-2: grep of Dockerfile and Makefile.
#  - AC-3, AC-5: parse toolchain-bump.yml (python3 + PyYAML, as pin-bump.test.sh).
#  - AC-4: runs `make build-image` in a copy of the repository, with fakes of docker, oras and toolbox/run.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
WF="$ROOT/.github/workflows/toolchain-bump.yml"
OLD="$ROOT/scripts/fixtures/M02/Dockerfile.b9f533b"
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/builder-rebuild.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
W="$tmp/M02"; mkdir -p "$W"

# ---------------------------------------------------------------- M02-AC-1
want=0fc5ab83b26909e4f8b88dcb8b252a436f9caaec
got=$(git hash-object "$OLD" 2>/dev/null || true)
if [ "$got" = "$want" ]; then pass "M02-AC-1 the fixture is the b9f533b Dockerfile blob ($want)"
else fail "M02-AC-1 the fixture is not the b9f533b Dockerfile blob (got '$got', want $want)"; fi
strip() { grep -v '^[[:space:]]*#' "$1"; }
strip "$OLD" > "$W/old.df"
strip "$ROOT/Dockerfile" > "$W/new.df" 2>/dev/null || : > "$W/new.df"
diff -U3 "$W/old.df" "$W/new.df" > "$W/df.diff" 2>&1
hunks=$(grep -c '^@@' "$W/df.diff")
if [ "$hunks" -eq 2 ]; then pass "M02-AC-1 comment-stripped diff against b9f533b has exactly two hunks"
else fail "M02-AC-1 comment-stripped diff against b9f533b has $hunks hunks, want exactly 2"; fi
# changed lines, without the ---/+++ headers
grep '^-[^-]\|^-$' "$W/df.diff" > "$W/removed" || : > "$W/removed"
grep '^+[^+]\|^+$' "$W/df.diff" > "$W/added" || : > "$W/added"
if [ "$(wc -l < "$W/removed")" -eq 2 ] && [ "$(wc -l < "$W/added")" -eq 2 ]; then
	pass "M02-AC-1 exactly two lines are replaced by two lines"
else fail "M02-AC-1 changed lines: $(wc -l < "$W/removed") removed, $(wc -l < "$W/added") added, want 2 and 2"; fi
if grep -qx -- '-FROM gentoo/stage3:amd64-openrc-${TOOLCHAIN_EPOCH} AS base-tools' "$W/removed" &&
	grep -qE -- '^\+FROM gentoo/stage3:amd64-openrc-\$\{TOOLCHAIN_EPOCH\}@sha256:[0-9a-f]{64} AS base-tools$' "$W/added"; then
	pass "M02-AC-1 the FROM line gains @sha256:<64 hex> and nothing else"
else fail "M02-AC-1 the FROM line does not gain exactly @sha256:<64 hex>"; fi
if grep -qx -- '-RUN emerge-webrsync --revert=${TOOLCHAIN_EPOCH}' "$W/removed" &&
	grep -qE -- '^\+COPY tree/ /var/db/repos/gentoo/$' "$W/added"; then
	pass "M02-AC-1 the emerge-webrsync RUN becomes COPY tree/ /var/db/repos/gentoo/"
else fail "M02-AC-1 the emerge-webrsync RUN does not become COPY tree/ /var/db/repos/gentoo/"; fi

# ---------------------------------------------------------------- M02-AC-2
if grep -n webrsync "$ROOT/Dockerfile" "$ROOT/Makefile" > "$W/webrsync.out" 2>&1; then
	fail "M02-AC-2 grep -n webrsync Dockerfile Makefile finds: $(head -n 3 "$W/webrsync.out" | tr '\n' ' ')"
else pass "M02-AC-2 grep -n webrsync Dockerfile Makefile finds nothing"; fi

# ---------------------------------------------------------------- M02-AC-4
# A copy of the repository whose toolbox/run, docker and oras are fakes that only log.
R="$W/repo"; mkdir -p "$R/toolbox" "$R/scripts" "$R/configs/portage" "$W/bin" "$W/log"
cp "$ROOT/Makefile" "$ROOT/Dockerfile" "$R/" 2>/dev/null
cp "$ROOT"/scripts/*.sh "$R/scripts/" 2>/dev/null
cp "$ROOT"/configs/portage/*.lock "$R/configs/portage/" 2>/dev/null
cat > "$R/toolbox/run" <<STUB
#!/bin/sh
echo "toolbox/run \$*" >> "$W/log/calls"
exit 0
STUB
for c in docker oras podman; do
	cat > "$W/bin/$c" <<STUB
#!/bin/sh
echo "$c \$*" >> "$W/log/calls"
exit 0
STUB
done
chmod +x "$R/toolbox/run" "$W/bin/docker" "$W/bin/oras" "$W/bin/podman"
D64=sha256:0000000000000000000000000000000000000000000000000000000000000000
C40=0123456789abcdef0123456789abcdef01234567
try() { # try <empty pin> <commit value> <digest value>
	: > "$W/log/calls"
	(cd "$R" && PATH="$W/bin:$PATH" make build-image TREE_COMMIT_TOOLCHAIN="$2" TREE_DIGEST_TOOLCHAIN="$3" >"$W/$1.out" 2>&1)
	rc=$?
	[ $rc -ne 0 ] && pass "M02-AC-4 make build-image with $1 empty exits non-zero" ||
		fail "M02-AC-4 make build-image with $1 empty exits $rc, want non-zero"
	# a make "No rule" error names no pin; the message must name the empty one
	if ! grep -q 'No rule to make target' "$W/$1.out" && grep -q "$1" "$W/$1.out"; then
		pass "M02-AC-4 the message names the empty pin $1"
	else fail "M02-AC-4 the message does not name the empty pin $1: $(head -n 2 "$W/$1.out" | tr '\n' ' ')"; fi
	if ! grep -q '^docker\|^podman' "$W/log/calls"; then pass "M02-AC-4 with $1 empty docker is not run"
	else fail "M02-AC-4 with $1 empty docker ran: $(grep '^docker\|^podman' "$W/log/calls" | head -n 1)"; fi
	if ! grep -qi 'oras\|tree\|sync-portage' "$W/log/calls" && [ ! -e "$R/tree" ]; then
		pass "M02-AC-4 with $1 empty no tree is restored"
	else fail "M02-AC-4 with $1 empty a tree restore ran: $(grep -i 'oras\|tree\|sync-portage' "$W/log/calls" | head -n 1)"; fi
}
try TREE_COMMIT_TOOLCHAIN "" "$D64"
try TREE_DIGEST_TOOLCHAIN "$C40" ""

# ------------------------------------------------- toolchain-bump.yml (AC-3, AC-5)
G=g; H=h
P_MERGE="${G}${H} pr mer""ge"
P_ADMIN="--ad""min"
if [ ! -f "$WF" ]; then
	for c in \
		"M02-AC-3 toolchain-bump.yml has no merge command" \
		"M02-AC-3 toolchain-bump.yml has no admin flag" \
		"M02-AC-3 toolchain-bump.yml has no schedule: trigger" \
		"M02-AC-3 the only trigger of toolchain-bump.yml is workflow_dispatch" \
		"M02-AC-5 on.workflow_dispatch.inputs has tree_commit" \
		"M02-AC-5 a first-rebuild mode input exists" \
		"M02-AC-5 an archive job has permissions.packages: write" \
		"M02-AC-5 the archive job runs scripts/seed-tree.sh" \
		"M02-AC-5 the archive job seeds only when gentoo-tree:<commit40> is absent" \
		"M02-AC-5 the job that runs update-build-pins.sh update-toolchain needs archive"; do
		fail "$c (toolchain-bump.yml does not exist)"
	done
else
	P_MERGE="$P_MERGE" P_ADMIN="$P_ADMIN" python3 - "$WF" "$ROOT" <<'PY'
import os, re, shlex, subprocess, sys
import yaml
wf, root = sys.argv[1], sys.argv[2]
text = open(wf).read()
doc = yaml.safe_load(text)
bad = 0
def chk(l, c):
    global bad
    print(("PASS: " if c else "FAIL: ") + l)
    bad += (not c)
chk("M02-AC-3 toolchain-bump.yml has no merge command", os.environ["P_MERGE"] not in text)
chk("M02-AC-3 toolchain-bump.yml has no admin flag", os.environ["P_ADMIN"] not in text)
chk("M02-AC-3 toolchain-bump.yml has no schedule: trigger", "schedule:" not in text)
trig = doc.get(True) if True in doc else doc.get("on")
if isinstance(trig, str): trig = {trig: None}
if isinstance(trig, list): trig = {k: None for k in trig}
chk("M02-AC-3 the only trigger of toolchain-bump.yml is workflow_dispatch",
    isinstance(trig, dict) and set(trig) == {"workflow_dispatch"})
inputs = ((trig or {}).get("workflow_dispatch") or {}).get("inputs") or {}
chk("M02-AC-5 on.workflow_dispatch.inputs has tree_commit", "tree_commit" in inputs)
chk("M02-AC-5 a first-rebuild mode input exists (an input named for the first rebuild, or a mode choice naming it)",
    any(re.search(r"first|rebuild", k, re.I) or re.search(r"first", yaml.safe_dump(v), re.I) for k, v in inputs.items()
        if k != "tree_commit"))

jobs = doc.get("jobs") or {}
archive = jobs.get("archive") or {}
def steps(j): return [s for s in (j or {}).get("steps") or [] if isinstance(s, dict)]
def make_n(cmd, env=None):
    m = re.match(r"make\s+(.*)$", cmd.strip(), re.S)
    if not m: return ""
    try: words = shlex.split(m.group(1))
    except ValueError: return ""
    r = subprocess.run(["make", "-n"] + words, cwd=root, env=env, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""
COMMIT = "c" * 40
def subst(s): return re.sub(r"\$\{\{.*?\}\}", COMMIT, s)
def expand(s):
    env = dict(os.environ)
    for k, v in list((archive.get("env") or {}).items()) + list((s.get("env") or {}).items()):
        env[str(k)] = subst(str(v))
    run = subst((s.get("run") or "").strip())
    return run + "\n" + make_n(run, env)
perm = archive.get("permissions")
chk("M02-AC-5 an archive job has permissions.packages: write", isinstance(perm, dict) and perm.get("packages") == "write")
seed = [s for s in steps(archive) if "seed-tree.sh" in expand(s)]
chk("M02-AC-5 the archive job runs scripts/seed-tree.sh", bool(seed))
# gated: the seeding step has an `if` on a registry probe, or the same script checks for the tag first
probe = [s for s in steps(archive) if s not in seed and re.search(r"tree-exists|manifest fetch|gentoo-tree", expand(s))]
gated = False
for s in seed:
    cond = str(s.get("if") or "")
    ex = expand(s)
    if probe and re.search(r"steps\.\w+\.outputs", cond) and re.search(r"false|!|absent|missing", cond):
        gated = True
    if re.search(r"manifest fetch", ex) and re.search(r"\bif\b|\|\||&&|case", ex):
        gated = True
    if "gentoo-tree" in cond or re.search(r"\bsteps\.\w+\.outputs", cond) and not probe and re.search(r"false|!", cond):
        gated = True
chk("M02-AC-5 the archive job seeds only when gentoo-tree:<commit40> is absent (a probe of the registry and a condition on it)", gated)
upd = [n for n, j in jobs.items()
       if any(re.search(r"update-build-pins(\.sh)?\b.*\bupdate-toolchain\b", (s.get("run") or "") + "\n" + make_n((s.get("run") or "").strip()))
              for s in steps(j))]
def needs(j):
    n = (j or {}).get("needs")
    return [n] if isinstance(n, str) else list(n or [])
chk("M02-AC-5 the job that runs update-build-pins.sh update-toolchain needs archive",
    bool(upd) and "archive" not in upd and all("archive" in needs(jobs[n]) for n in upd))
sys.exit(1 if bad else 0)
PY
	[ $? -eq 0 ] || FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -ne 0 ]; then echo "builder-rebuild: $FAILS check group(s) failed"; exit 1; fi
echo "builder-rebuild: all checks passed"
