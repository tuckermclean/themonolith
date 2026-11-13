#!/bin/sh
# M01 tree-bump: .github/workflows/pin-bump.yml and scripts/update-build-pins.sh.
# Criteria: M01-AC-1 .. M01-AC-6 (M01-AC-7 is a recorded run after merge). Offline.
#  - AC-1: grep of .github/workflows/ for the forbidden strings; the same scan runs on planted violations
#    (built here from parts, never stored as files) and must report each one.
#  - AC-2, AC-3, AC-6 and the shape of changes 3, 4, 6, 8: parse pin-bump.yml (python3 + PyYAML, as tree-pin.test.sh).
#  - AC-4, AC-5: run scripts/update-build-pins.sh in a fixture repository with stubs of git ls-remote, curl, oras.
# Interface the stubs assume (spec change 4: where TREE_FILES and the committer time come from is the
# implementation's choice; the stubs serve every supported source with the same values):
#   update-build-pins.sh check          newest gentoo-mirror/gentoo commit via `git ls-remote`; equal to TREE_COMMIT
#                                       prints NO-OP, exits 0; otherwise prints the commit and exits 0
#   update-build-pins.sh update <c40>   digest from `oras manifest fetch` of gentoo-tree:<c40>; committer time from the
#                                       manifest's org.opencontainers.image.created or the GitHub commits API (curl);
#                                       file count from the archive `oras pull` returns (what tree-check counts)
# Runs in commit-less copies: paths come from this file; the fixture repository is created here.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
WFDIR="$ROOT/.github/workflows"
WF="$WFDIR/pin-bump.yml"
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
ck() { l=$1; shift; if "$@" >/dev/null 2>&1; then pass "$l"; else fail "$l"; fi; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pin-bump.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
REAL_GIT=$(command -v git)

# ---------------------------------------------------------------- M01-AC-1
# The forbidden strings are built from parts so that this file itself holds none of them.
G=g; H=h
P_MERGE="${G}${H} pr mer""ge"
P_ADMIN="--ad""min"
P_AUTO="--au""to"
P_ENABLE="enable""AutoMerge"
P_APPROVE="${G}${H} pr re""view --app""rove"
# scan <dir>: prints one line per violation and returns 1 if there is any
scan() {
	_bad=0
	for _p in "$P_MERGE" "$P_ADMIN" "$P_AUTO" "$P_ENABLE"; do
		if grep -rnF -e "$_p" "$1" 2>/dev/null; then _bad=1; fi
	done
	if grep -rnE "${G}${H} +pr +re""view.*--app""rove" "$1" 2>/dev/null; then _bad=1; fi
	return $_bad
}
ck "M01-AC-1 regen-pins.yml is gone" test ! -e "$WFDIR/regen-pins.yml"
if scan "$WFDIR" >"$tmp/scan.out" 2>&1; then
	pass "M01-AC-1 scan of .github/workflows/ finds none of the five forbidden merge/approve strings"
else
	fail "M01-AC-1 scan of .github/workflows/ finds a forbidden string: $(head -n 3 "$tmp/scan.out" | tr '\n' ' ')"
fi
PL="$tmp/planted"; mkdir -p "$PL/clean" "$PL/all"
printf 'name: ok\njobs:\n  a:\n    steps:\n      - run: make test\n' > "$PL/clean/ok.yml"
i=0
for p in "$P_MERGE --squash" "x edit 1 $P_AUTO" "x $P_ADMIN" "mutation { $P_ENABLE }" "$P_APPROVE 12"; do
	i=$((i + 1)); mkdir -p "$PL/$i"
	printf 'name: bad\njobs:\n  a:\n    steps:\n      - run: %s\n' "$p" > "$PL/$i/bad.yml"
	cp "$PL/$i/bad.yml" "$PL/all/bad$i.yml"
	if scan "$PL/$i" >/dev/null 2>&1; then fail "M01-AC-1 planted violation $i is not reported by the scan"
	else pass "M01-AC-1 planted violation $i is reported by the scan"; fi
done
if scan "$PL/all" >/dev/null 2>&1; then fail "M01-AC-1 planted directory with all five violations is not reported"
else pass "M01-AC-1 planted directory with all five violations is reported"; fi
if scan "$PL/clean" >/dev/null 2>&1; then pass "M01-AC-1 a clean fixture directory passes the scan"
else fail "M01-AC-1 a clean fixture directory is reported as a violation"; fi

# ------------------------------------------------- workflow shape (AC-2, AC-3, AC-6, changes 3, 4, 6, 8)
if [ ! -f "$WF" ]; then
	for c in \
		"M01 change 4 the workflow has an archive job and a bump job" \
		"M01-AC-2 the bump job mints a token with a SHA-pinned actions/create-github-app-token" \
		"M01-AC-2 every checkout of the bump job takes the App token" \
		"M01-AC-2 the bump job passes the App token to the step that opens the PR" \
		"M01-AC-2 GITHUB_TOKEN / github.token is not used in the bump job or the workflow env" \
		"M01-AC-3 the PR is created with the full-ci label" \
		"M01-AC-3 pin-bump.yml has no gh workflow run and no polling loop" \
		"M01 change 3 gh pr create opens the PR against main" \
		"M01-AC-6 workflow-level permissions are contents: read only" \
		"M01-AC-6 the bump job declares at most contents: write, pull-requests: write, packages: read" \
		"M01-AC-6 the archive job declares contents: read and packages: write only" \
		"M01-AC-6 the archive job has no App token" \
		"M01-AC-6 the archive job pushes through scripts/seed-tree.sh" \
		"M01 change 4 the bump job runs update-build-pins.sh update, make sync-portage, make update-versions" \
		"M01 change 6 NO-OP summary and a gh pr create that fails the job" \
		"M01 toolbox/ci lint passes"; do fail "$c (pin-bump.yml does not exist)"; done
else
	python3 - "$WF" "$ROOT" <<'PY'
import glob, os, re, shlex, subprocess, sys
import yaml
wf, root = sys.argv[1], sys.argv[2]
text = open(wf).read()
doc = yaml.safe_load(text)
bad = 0
def chk(l, c):
    global bad
    print(("PASS: " if c else "FAIL: ") + l)
    bad += (not c)
jobs = doc.get("jobs") or {}
archive = jobs.get("archive") or {}
bump = jobs.get("bump") or {}
chk("M01 change 4 the workflow has an `archive` job and a `bump` job", bool(archive) and bool(bump))
def steps(j): return [s for s in (j or {}).get("steps") or [] if isinstance(s, dict)]
def blob(x): return yaml.safe_dump(x)
def make_n(cmd, env=None):
    m = re.match(r"make\s+(.*)$", cmd.strip(), re.S)
    if not m: return ""
    try: words = shlex.split(m.group(1))
    except ValueError: return ""
    r = subprocess.run(["make", "-n"] + words, cwd=root, env=env, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""

# ---- AC-2
APP = re.compile(r"^actions/create-github-app-token@[0-9a-f]{40}(\s|$)")
app = [(i, s) for i, s in enumerate(steps(bump)) if APP.match(str(s.get("uses") or ""))]
chk("M01-AC-2 the bump job mints a token with a SHA-pinned actions/create-github-app-token", len(app) == 1)
appid = app[0][1].get("id") if app else None
tokref = re.compile(r"steps\.%s\.outputs\.token" % re.escape(appid)) if appid else None
cos = [(i, s) for i, s in enumerate(steps(bump)) if str(s.get("uses") or "").startswith("actions/checkout@")]
chk("M01-AC-2 every checkout of the bump job takes the App token, minted before it",
    bool(app) and bool(tokref) and bool(cos) and all(tokref.search(str((s.get("with") or {}).get("token") or "")) and i > app[0][0] for i, s in cos))
envs = [(s.get("env") or {}) for s in steps(bump)] + [bump.get("env") or {}]
chk("M01-AC-2 the bump job passes the App token as GH_TOKEN/GITHUB_TOKEN to the step that opens the PR",
    bool(tokref) and any(tokref.search(str(e.get(k) or "")) for e in envs for k in ("GH_TOKEN", "GITHUB_TOKEN")))
GT = re.compile(r"github\.token|secrets\.GITHUB_TOKEN", re.I)
chk("M01-AC-2 GITHUB_TOKEN / github.token is not used in the bump job or the workflow env",
    bool(bump) and not GT.search(blob(bump)) and not GT.search(blob(doc.get("env") or {})))

# ---- AC-3 and changes 3, 6: gh pr create wherever it lives (workflow, Makefile, scripts)
files = [wf, os.path.join(root, "Makefile")] + sorted(glob.glob(os.path.join(root, "scripts", "*.sh")))
corpus = {}
for f in files:
    try: corpus[f] = open(f).read()
    except OSError: pass
def logical(t): return re.sub(r"\\\n\s*", " ", t).splitlines()
creates = [(f, l) for f, t in corpus.items() for l in logical(t) if re.search(r"\bgh\s+pr\s+create\b", l)]
chk("M01-AC-3 the PR is created with the full-ci label (gh pr create --label full-ci)",
    bool(creates) and all("--label" in l and "full-ci" in corpus[f] for f, l in creates))
chk("M01 change 3 gh pr create opens the PR against main, not master",
    bool(creates) and all(re.search(r"--base[ =]main\b", l) and "master" not in l for f, l in creates))
chk("M01 change 6 a failed gh pr create fails the job (no || true after it)",
    bool(creates) and not any(re.search(r"\|\|\s*(true|:|exit 0)", l) for f, l in creates))
poll = re.compile(r"\bgh\s+workflow\s+run\b|\bgh\s+run\s+(watch|list|view)\b|\bsleep\b|\buntil\b|\bwhile\b")
chk("M01-AC-3 pin-bump.yml has no gh workflow run and no polling loop (gh run watch/list/view, sleep, until, while)",
    not poll.search(text))
chk("M01-AC-3 no script or Make target the workflow uses runs gh workflow run",
    not any(re.search(r"\bgh\s+workflow\s+run\b", t) for f, t in corpus.items() if not f.endswith("Makefile")))
alltext = "\n".join(corpus.values())
chk("M01 change 6 a no-PR run says NO-OP in the job summary (NO-OP and GITHUB_STEP_SUMMARY)",
    "NO-OP" in alltext and "GITHUB_STEP_SUMMARY" in alltext)

# ---- AC-6
chk("M01-AC-6 workflow-level permissions are contents: read only", doc.get("permissions") == {"contents": "read"})
ALLOW = {"contents": {"read", "write", "none"}, "pull-requests": {"read", "write", "none"}, "packages": {"read", "none"}}
bp = bump.get("permissions")
chk("M01-AC-6 the bump job declares at most contents: write, pull-requests: write, packages: read",
    isinstance(bp, dict) and bool(bp) and all(k in ALLOW and v in ALLOW[k] for k, v in bp.items()))
ap = archive.get("permissions")
chk("M01-AC-6 the archive job declares contents: read and packages: write, nothing else", ap == {"contents": "read", "packages": "write"})
chk("M01-AC-6 the archive job has no App token step and no App secret",
    bool(archive) and "create-github-app-token" not in blob(archive) and not re.search(r"PIN_BUMP|APP_PRIVATE|app-id", blob(archive), re.I))
needs = bump.get("needs")
chk("M01-AC-6 the bump job waits for the archive job (needs: archive)",
    "archive" in ([needs] if isinstance(needs, str) else (needs or [])))
# the archive job's push: only through seed-tree.sh, of the commit it resolved, to no other tag
COMMIT = "c" * 40
def subst(s): return re.sub(r"\$\{\{.*?\}\}", COMMIT, s)
PUSH = re.compile(r"\b(oras|docker|podman|skopeo|crane)\s+(push|copy|cp|tag)\b|\bgit\s+push\b")
seedok, other_push = False, False
for s in steps(archive):
    run = subst((s.get("run") or "").strip())
    env = dict(os.environ)
    for k, v in list((archive.get("env") or {}).items()) + list((s.get("env") or {}).items()):
        env[str(k)] = subst(str(v))
    if PUSH.search(run): other_push = True
    out = make_n(run, env)
    if PUSH.search(out): other_push = True
    if re.search(r"scripts/seed-tree\.sh\s+\S*" + COMMIT, out): seedok = True
chk("M01-AC-6 the archive job pushes gentoo-tree:<commit40> through scripts/seed-tree.sh (the commit it resolved, not the Makefile's TREE_COMMIT)", seedok)
chk("M01-AC-6 the archive job pushes nothing else (no oras push/copy/tag, docker push, git push)", bool(archive) and not other_push)

# ---- change 4: the jobs' steps
runs = [(s.get("run") or "").strip() for s in steps(bump)]
UPD = r"update-build-pins(\.sh)?\b.*\bupdate\b"
upd = [i for i, r in enumerate(runs) if re.search(UPD, r) or re.search(UPD, make_n(r))]
sp = [i for i, r in enumerate(runs) if re.match(r"make\s+sync-portage(\s|$)", r)]
uv = [i for i, r in enumerate(runs) if re.match(r"make\s+update-versions(\s|$)", r)]
chk("M01 change 4 the bump job runs update-build-pins.sh update, then make sync-portage, then make update-versions",
    bool(upd) and bool(sp) and bool(uv) and upd[0] < sp[0] < uv[0])
chk("M01 change 4 the archive job resolves the newest commit with update-build-pins.sh",
    any(re.search(r"update-build-pins\.sh", r) or re.search(r"update-build-pins\.sh", make_n(r))
        for r in [(s.get("run") or "").strip() for s in steps(archive)]))
chk("M01 change 4 the bump job runs only when the archive job found a newer commit (job-level if or needs.archive output)",
    bool(bump.get("if")) or "needs.archive" in blob(bump))
trig = doc.get(True) or doc.get("on") or {}
chk("M01 change 3 the workflow keeps its weekly cron and a workflow_dispatch trigger",
    isinstance(trig, dict) and "schedule" in trig and "workflow_dispatch" in trig)
chk("M01 change 4 the workflow keeps concurrency: pin-bump", "pin-bump" in str(doc.get("concurrency")))
sys.exit(1 if bad else 0)
PY
	[ $? -eq 0 ] || FAILS=$((FAILS + 1))
	ck "M01 toolbox/ci lint passes on pin-bump.yml" sh -c 'cd "$1" && python3 toolbox/ci lint pin-bump.yml' _ "$ROOT"
fi

# ------------------------------------------------------- AC-4, AC-5: update-build-pins.sh in a fixture repo
SRC=scripts/update-build-pins.sh
OLD=6e88ed01f3e97de8710efe1c333808dfbd05bf32
mkfix() { # mkfix <dir>: a repository with the files the script may read
	d=$1; mkdir -p "$d/scripts" "$d/configs/portage" "$d/docs"
	cp "$ROOT/Makefile" "$ROOT/Dockerfile" "$d/" 2>/dev/null
	cp "$ROOT"/configs/portage/*.lock "$d/configs/portage/" 2>/dev/null
	cp "$ROOT/docs/tree-pin.md" "$d/docs/" 2>/dev/null
	for f in "$ROOT"/scripts/*.sh; do cp -p "$f" "$d/scripts/"; done
	(cd "$d" && "$REAL_GIT" init -q . && "$REAL_GIT" add -A &&
		GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
		"$REAL_GIT" commit -q -m fixture) >/dev/null 2>&1
}
NEW=0123456789abcdef0123456789abcdef01234567
CREATED=2026-11-08T12:34:56Z
EPOCH=$(date -u -d "$CREATED" +%s 2>/dev/null || echo 0)
NFILES=7
mkstubs() { # mkstubs <dir> <ls-remote commit>
	b=$1; mkdir -p "$b/bin" "$b/log" "$b/arch"
	for i in 1 2 3 4 5 6 7; do echo "x$i" > "$b/arch/f$i"; done
	(cd "$b/arch" && tar -cf - f1 f2 f3 f4 f5 f6 f7 | zstd -q -f -o "$b/archive.tar.zst")
	cat > "$b/manifest.json" <<JSON
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","artifactType":"application/vnd.themonolith.gentoo-tree.v1","layers":[],"annotations":{"org.opencontainers.image.created":"$CREATED"}}
JSON
	MD=sha256:$(sha256sum "$b/manifest.json" | cut -d' ' -f1)
	cat > "$b/bin/git" <<STUB
#!/bin/sh
echo "git \$*" >> "$b/log/git.log"
case "\$1" in
ls-remote) printf '%s\tHEAD\n%s\trefs/heads/master\n' "$2" "$2"; exit 0;;
esac
exec "$REAL_GIT" "\$@"
STUB
	cat > "$b/bin/curl" <<STUB
#!/bin/sh
echo "curl \$*" >> "$b/log/curl.log"
case "\$*" in
*api.github.com/repos/gentoo-mirror/gentoo/*)
	printf '{"sha":"%s","commit":{"committer":{"date":"%s"},"author":{"date":"%s"}}}\n' "$NEW" "$CREATED" "$CREATED"; exit 0;;
esac
echo "curl: stub refuses \$*" >&2; exit 22
STUB
	cat > "$b/bin/oras" <<STUB
#!/bin/sh
echo "oras \$*" >> "$b/log/oras.log"
case "\$1 \$2" in
"manifest fetch")
	case "\$*" in
	*--descriptor*) printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":%s}\n' "$MD" "\$(wc -c < "$b/manifest.json")";;
	*) cat "$b/manifest.json";;
	esac; exit 0;;
esac
case "\$1" in
pull)
	out=.; while [ \$# -gt 0 ]; do case "\$1" in -o|--output) out=\$2;; esac; shift; done
	mkdir -p "\$out" && cp "$b/archive.tar.zst" "\$out/gentoo-tree-$NEW.tar.zst"
	echo "Pulled"; echo "Digest: $MD"; exit 0;;
esac
echo "oras: stub refuses \$*" >&2; exit 1
STUB
	for t in wget docker podman skopeo crane; do
		printf '#!/bin/sh\necho "%s $*" >> "%s/log/%s.log"\necho "%s: stub refuses" >&2; exit 1\n' "$t" "$b" "$t" "$t" > "$b/bin/$t"
	done
	chmod +x "$b/bin/"*
}
runpins() { # runpins <fixture> <stubs> <args...>
	f=$1; s=$2; shift 2
	(cd "$f" && HOME="$tmp/home" PATH="$s/bin:$PATH" "./$SRC" "$@") >"$s/out" 2>&1; echo $? > "$s/rc"
}
mkpin() { sed -n "s/^$2[[:space:]]*:=[[:space:]]*//p" "$1/Makefile" 2>/dev/null | head -n 1; }
mkdir -p "$tmp/home"

# ---- AC-5: the newest commit is TREE_COMMIT
F5="$tmp/fix5"; S5="$tmp/stub5"
mkfix "$F5"; CUR=$(mkpin "$F5" TREE_COMMIT); [ -n "$CUR" ] || CUR=$OLD
mkstubs "$S5" "$CUR"
before=$(cd "$F5" && "$REAL_GIT" branch --list 2>&1; "$REAL_GIT" status --porcelain 2>&1)
runpins "$F5" "$S5" check
after=$(cd "$F5" && "$REAL_GIT" branch --list 2>&1; "$REAL_GIT" status --porcelain 2>&1)
rc=$(cat "$S5/rc")
if [ "$rc" = 0 ]; then pass "M01-AC-5 check exits 0 when the newest commit equals TREE_COMMIT"
else fail "M01-AC-5 check exits 0 when the newest commit equals TREE_COMMIT (exit $rc: $(head -n 2 "$S5/out" | tr '\n' ' '))"; fi
ck "M01-AC-5 check prints NO-OP" grep -q 'NO-OP' "$S5/out"
ck "M01-AC-5 the stubbed git ls-remote was the source of the newest commit" grep -q '^git ls-remote' "$S5/log/git.log"
if [ "$before" = "$after" ]; then pass "M01-AC-5 no branch is created and no file changes"
else fail "M01-AC-5 no branch is created and no file changes"; fi
ck "M01-AC-5 no git branch, checkout, switch, commit or push was run" sh -c '! grep -E "^git (branch|checkout|switch|commit|push|worktree)" "$1" 2>/dev/null' _ "$S5/log/git.log"
ck "M01-AC-5 the NO-OP run pushes nothing (no oras push/copy/tag)" sh -c '! grep -E "^oras (push|copy|tag)" "$1" 2>/dev/null' _ "$S5/log/oras.log"

# ---- AC-4: a newer commit
F4="$tmp/fix4"; S4="$tmp/stub4"
mkfix "$F4"; mkstubs "$S4" "$NEW"
runpins "$F4" "$S4" check
rc=$(cat "$S4/rc")
if [ "$rc" = 0 ]; then pass "M01 change 4 check exits 0 when a newer commit exists"
else fail "M01 change 4 check exits 0 when a newer commit exists (exit $rc: $(head -n 2 "$S4/out" | tr '\n' ' '))"; fi
ck "M01 change 4 check prints the newest commit $NEW and not NO-OP" sh -c 'grep -q "$2" "$1" && ! grep -q "NO-OP" "$1"' _ "$S4/out" "$NEW"
ck "M01 change 4 check asks gentoo-mirror/gentoo through git ls-remote" sh -c 'grep "^git ls-remote" "$1" | grep -q "gentoo-mirror/gentoo"' _ "$S4/log/git.log"
runpins "$F4" "$S4" update "$NEW"
rc=$(cat "$S4/rc")
if [ "$rc" = 0 ]; then pass "M01-AC-4 update <commit> exits 0"
else fail "M01-AC-4 update <commit> exits 0 (exit $rc: $(head -n 3 "$S4/out" | tr '\n' ' '))"; fi
# the four tree pin lines, in I02's format
ck "M01-AC-4 Makefile: TREE_COMMIT := $NEW" test "$(mkpin "$F4" TREE_COMMIT)" = "$NEW"
ck "M01-AC-4 Makefile: TREE_DIGEST := the digest of the existing tag ($MD)" test "$(mkpin "$F4" TREE_DIGEST)" = "$MD"
ck "M01-AC-4 Makefile: SOURCE_DATE_EPOCH := the committer time ($EPOCH)" test "$(mkpin "$F4" SOURCE_DATE_EPOCH)" = "$EPOCH"
ck "M01-AC-4 Makefile: TREE_FILES := the file count of the archive ($NFILES)" test "$(mkpin "$F4" TREE_FILES)" = "$NFILES"
ck "M01-AC-4 the pin lines keep I02's format NAME := value" sh -c '
	for n in TREE_COMMIT TREE_DIGEST SOURCE_DATE_EPOCH TREE_FILES; do grep -Eq "^$n := [^ ]+\$" "$1/Makefile" || exit 1; done' _ "$F4"
# nothing else changes
changed=$(cd "$F4" && "$REAL_GIT" status --porcelain 2>&1 | sed 's/^...//' | sort | tr '\n' ' ')
case $changed in
"Makefile "|"Makefile configs/portage/versions.lock ")
	pass "M01-AC-4 the changed files are within the tree pin (Makefile) and versions.lock: $changed";;
*) fail "M01-AC-4 the changed files are within the tree pin (Makefile) and versions.lock (changed: $changed)";;
esac
ck "M01-AC-4 only the four tree pin lines (and comments) of the Makefile changed" sh -c '
	cd "$1" && git diff -U0 -- Makefile | grep -E "^[-+]" | grep -Ev "^(---|\+\+\+)" |
	grep -Ev "^[-+](TREE_COMMIT|TREE_DIGEST|SOURCE_DATE_EPOCH|TREE_FILES) :=|^[-+]#" | { ! grep -q .; }' _ "$F4"
ck "M01-AC-4 BUILD_EPOCH is untouched (Dockerfile and Makefile)" sh -c '
	[ "$(grep "^ARG BUILD_EPOCH=" "$1/Dockerfile")" = "$(grep "^ARG BUILD_EPOCH=" "$2/Dockerfile")" ] &&
	[ "$(grep "^BUILD_EPOCH" "$1/Makefile")" = "$(grep "^BUILD_EPOCH" "$2/Makefile")" ]' _ "$F4" "$ROOT"
ck "M01-AC-4 the Dockerfile (stage3 and builder pins) is untouched" cmp -s "$F4/Dockerfile" "$ROOT/Dockerfile"
ck "M01 change 4 docs/tree-pin.md stays rc1's record" cmp -s "$F4/docs/tree-pin.md" "$ROOT/docs/tree-pin.md"
ck "M01 change 4 update reads the tag's digest with a read-only oras manifest fetch" grep -q '^oras manifest fetch' "$S4/log/oras.log"
ck "M01 change 4 update does not write to the registry (no oras push/copy/tag/attach/delete)" sh -c '! grep -E "^oras (push|copy|tag|attach|delete)" "$1" 2>/dev/null' _ "$S4/log/oras.log"
cat "$S4"/log/*.log > "$S4/all.log" 2>/dev/null
ck "M01-AC-4 no request goes to distfiles.gentoo.org" sh -c '! grep -qi "distfiles\.gentoo\.org" "$1" 2>/dev/null' _ "$S4/all.log"
ck "M01-AC-4 no request goes to Docker Hub (hub.docker.com, registry-1.docker.io, docker.io)" sh -c '! grep -Eqi "hub\.docker\.com|docker\.io|^docker " "$1" 2>/dev/null' _ "$S4/all.log"
cat "$S5"/log/*.log > "$S5/all.log" 2>/dev/null
ck "M01-AC-4 the check run makes no request to distfiles.gentoo.org or Docker Hub either" sh -c '! grep -Eqi "distfiles\.gentoo\.org|hub\.docker\.com|docker\.io|^docker " "$1" 2>/dev/null' _ "$S5/all.log"

if [ "$FAILS" -eq 0 ]; then echo "pin-bump.test.sh: all passed"; exit 0; fi
echo "pin-bump.test.sh: $FAILS failed"; exit 1
