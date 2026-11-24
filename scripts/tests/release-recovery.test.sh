#!/bin/sh
# P06 release-recovery: re-run attempts publish, an existing release is handled, a tag that did not publish is reported,
# the release is never made by hand (P06-AC-1 .. P06-AC-5; issue #115).
#
# Runs in the toolbox and in commit-less copies (no Git history, no network, no out/). Every missing subject (script,
# Make target, step, job, doc text) is its own FAIL line; the harness always runs to its end.
#
# Interfaces chosen here (the implementer follows them):
#
#  gh stub (a POSIX sh script on PATH; it logs one `CALL <args>` line per call and answers):
#    gh release view <tag> [--json F] [--jq E]   exit 1 + "release not found" on stderr when the case has no release;
#        else prints the JSON {"tagName":..,"isDraft":bool,"assets":[{"name":..},..]} (--json field list is ignored;
#        --jq E is applied with jq -r). So the scripts read only tagName, isDraft and assets.
#    gh issue list [... --jq E]                  prints the JSON [{"number":N,"title":"..."},..] of the open issues
#        (--search/--state are ignored, so the script must match the title EXACTLY: a decoy with another title is listed).
#    gh run view <id> [--attempt N] --json jobs [--jq E]
#                                                prints {"jobs":[{"name":..,"conclusion":"failure|cancelled|success|skipped"}]}
#    gh issue create / gh issue comment          succeed; their arguments and any --body-file/-F content (a file, or stdin
#        for `-`) go to a separate issue log, which the body checks read.
#    gh release create / upload / edit           succeed.
#  git stub: only `git rev-parse`; a `refs/tags/<name>` argument (with or without a ^{commit} suffix) prints the sha the
#    case gives that tag and exits 0, an unknown tag or any other argument exits 1.
#
#  scripts/release-existing.sh   env TAG, GITHUB_REPOSITORY (passed to gh as GH_REPO). Calls only `gh release view`.
#      exit 0: no release, or a release with no assets (draft or published). exit 1: one or more assets; the output
#      (stdout and stderr) holds the tag, the asset count and `gh release delete <tag> --yes`.
#  make release-existing         runs that script (the test reads `make -n release-existing`).
#  scripts/release-create.sh     env as today: TAG, RELEASE_DIR, BUILD_VERSION, GITHUB_REPOSITORY; run in a directory
#      holding release-notes.md. No release: `gh release create <tag> [--prerelease --latest=false] --title "The Monolith
#      <tag>" --notes-file release-notes.md <10 files>` as today. A release with no assets: no `release create`, `gh release
#      upload <tag> <the same 10 files>`, then after the last upload `gh release edit <tag> [--prerelease --latest=false]
#      --title "The Monolith <tag>" --notes-file release-notes.md --draft=false`. With assets: exit 1, none of
#      create/upload/edit, the same message as release-existing.sh. A `gh release view` that exits 0 with no output (P04's
#      stub) uploads every asset (by create or by upload).
#  scripts/release-report.sh     env (from the Build run's workflow_run payload and the Release run's needs):
#      HEAD_BRANCH, HEAD_SHA, BUILD_RUN_ID, BUILD_RUN_ATTEMPT, BUILD_CONCLUSION, BUILD_RUN_URL (html_url),
#      RELEASE_RUN_URL (this Release run), RESOLVE_RESULT, PUBLISH_RESULT (needs.resolve.result, needs.publish.result),
#      GITHUB_REPOSITORY. It reports only when HEAD_BRANCH is a tag at HEAD_SHA (git rev-parse) and the Build conclusion
#      is not success, or RESOLVE_RESULT or PUBLISH_RESULT is failure. It lists `gh issue list`, then `gh issue create
#      --title "Release <tag> did not publish"` or `gh issue comment <number>` on the open issue with that exact title.
#      The body holds the Build run URL, its attempt and conclusion, each job of `gh run view $BUILD_RUN_ID --attempt N
#      --json jobs` that failed or was cancelled, the Release run URL when the failure is the Release run's own, and a
#      link to docs/releasing.md. Exit 0 in every case.
#  make release-report           runs that script. release.yml's `report` job: needs [resolve, publish], `if:` has
#      always() and the push event, permissions issues write + actions read, steps: an optional checkout and one step
#      that runs `make release-report`.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is not available in this harness"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is not available in this harness"; exit 1; }
fails=0

# ============================================================ static checks (greps and YAML)
python3 -I - "$ROOT" <<'PY'
import os
import re
import subprocess
import sys

import yaml

ROOT = sys.argv[1]
bad = 0


def case(label, fn):
    global bad
    try:
        ok, why = fn()
    except Exception as e:  # a missing subject is a FAIL, never a crash
        ok, why = False, "%s: %s" % (type(e).__name__, e)
    if ok:
        print("PASS: " + label)
    else:
        print("FAIL: %s (%s)" % (label, why))
        bad += 1


def read(rel):
    with open(os.path.join(ROOT, rel), errors="replace") as f:
        return f.read()


def load(rel):
    text = read(rel)
    doc = yaml.safe_load(text)
    if True in doc:
        doc["on"] = doc.pop(True)
    return doc, text


def make_n(target):
    env = {k: v for k, v in os.environ.items() if not k.startswith("MAKE")}
    env.setdefault("GITHUB_REPOSITORY", "tuckermclean/themonolith")
    r = subprocess.run(["make", "-n", target], cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError("make -n %s fails (no such target?)" % target)
    return r.stdout


def steps(job):
    return (job or {}).get("steps") or []


def runs_make(s, target):
    return re.search(r"\bmake\b[^\n]*\b" + re.escape(target) + r"\b", str(s.get("run", ""))) is not None


def first(job, pred):
    for i, s in enumerate(steps(job)):
        if pred(s):
            return i
    return -1


def norm(t):
    return re.sub(r"\s+", " ", t)


RID = "${{ github.event.workflow_run.id }}"

# ---------------------------------------------------------------- P06-AC-1
def ac1_release():
    doc, text = load(".github/workflows/release.yml")
    dl = [s for j in doc["jobs"].values() for s in steps(j) if str(s.get("uses", "")).startswith("actions/download-artifact@")]
    if not dl:
        return False, "no download-artifact step"
    for s in dl:
        w = s.get("with") or {}
        if w.get("run-id") != RID:
            return False, "run-id of %r is %r" % (s.get("name"), w.get("run-id"))
        if RID not in str(w.get("name", "")):
            return False, "artifact name of %r does not carry the run id" % s.get("name")
    return True, ""


case("P06-AC-1 release.yml reads every artifact with run-id workflow_run.id and a name that carries that id", ac1_release)
case("P06-AC-1 release.yml contains no run_attempt", lambda: ("run_attempt" not in read(".github/workflows/release.yml"), "run_attempt is present"))


def ac1_overwrite():
    doc, _ = load(".github/workflows/build.yml")
    ups = [s for s in steps(doc["jobs"]["attestation"]) if str(s.get("uses", "")).startswith("actions/upload-artifact@")]
    if not ups:
        return False, "the attestation job has no upload-artifact step"
    for s in ups:
        if (s.get("with") or {}).get("overwrite") not in (True, "true"):
            return False, "step %r has no overwrite: true" % s.get("name")
    return True, ""


case("P06-AC-1 every upload-artifact step of build.yml's attestation job sets overwrite: true", ac1_overwrite)


def retry_text():
    sec = read("docs/releasing.md").split("## Operator steps to cut a release", 1)
    if len(sec) < 2:
        raise RuntimeError("docs/releasing.md has no 'Operator steps to cut a release' section")
    m = re.search(r"^6\.", sec[1], re.M)
    if not m:
        raise RuntimeError("the operator steps have no step 6")
    return norm(sec[1][m.start():])


def ac1_doc_first():
    t = retry_text()
    i = t.find("Re-run failed jobs")
    m = re.search(r"re-tag|delete[^.]{0,60}tag", t)
    if i < 0:
        return False, "step 6 does not name Re-run failed jobs"
    if m is None or i > m.start():
        return False, "Re-run failed jobs does not come before the delete-and-re-tag path"
    return True, ""


case("P06-AC-1 docs/releasing.md step 6 names Re-run failed jobs before the delete-and-re-tag path", ac1_doc_first)


def ac1_doc_when():
    t = retry_text().lower()
    if "flake" not in t:
        return False, "no statement of when re-run applies (a flake)"
    if "fix" not in t:
        return False, "no statement of when fix-forward and re-tag applies"
    return True, ""


case("P06-AC-1 docs/releasing.md step 6 says when each retry applies", ac1_doc_when)
case("P06-AC-1 docs/releasing.md step 6 says a failed Release run is re-run",
     lambda: (re.search(r"release run[^.]{0,80}re-?run|re-?run[^.]{0,80}release run", retry_text(), re.I) is not None, "no such statement"))

# ---------------------------------------------------------------- P06-AC-2 / AC-5: release.yml publish
def publish():
    doc, _ = load(".github/workflows/release.yml")
    return doc["jobs"]["publish"]


def ac2_order():
    p = publish()
    a = first(p, lambda s: runs_make(s, "release-digest-chain"))
    b = first(p, lambda s: runs_make(s, "release-existing"))
    c = first(p, lambda s: s.get("name") == "Push the distfiles archive")
    if b < 0:
        return False, "no publish step runs make release-existing"
    if a < 0 or c < 0:
        return False, "digest chain or distfiles push step is missing"
    return (a < b < c), "order is digest-chain %d, release-existing %d, distfiles push %d" % (a, b, c)


case("P06-AC-2 publish runs make release-existing after make release-digest-chain and before Push the distfiles archive", ac2_order)
case("P06-AC-2 scripts/release-existing.sh does not contain 'gh release create'",
     lambda: ("gh release create" not in read("scripts/release-existing.sh"), "it does"))


def ac2_make():
    out = make_n("release-existing")
    if "release-existing.sh" not in out:
        return False, "make -n release-existing does not run scripts/release-existing.sh"
    return "gh release create" not in out, "make -n release-existing contains gh release create"


case("P06-AC-2 make -n release-existing runs release-existing.sh and does not contain 'gh release create'", ac2_make)


def ac2_only_view():
    # the message may name `gh release delete`; only lines that are not echo/printf/comments can run a command
    t = "\n".join(l for l in read("scripts/release-existing.sh").splitlines()
                  if not re.match(r"\s*(#|echo\b|printf\b)", l))
    others = [m for m in re.findall(r"\bgh\s+([a-z-]+)(?:\s+([a-z-]+))?", t) if (m[0], m[1]) != ("release", "view")]
    return not others, "other gh commands: %r" % others


case("P06-AC-2 scripts/release-existing.sh names no gh command other than gh release view", ac2_only_view)

# ---------------------------------------------------------------- P06-AC-5
def ac5_cond():
    p = publish()
    cond = str(p.get("if", ""))
    return ("github.event.workflow_run.conclusion == 'success'" in cond), "if: %r" % cond


case("P06-AC-5 publish still runs only for conclusion == 'success'", ac5_cond)


def ac5_chain():
    p = publish()
    a = first(p, lambda s: runs_make(s, "release-digest-chain"))
    b = first(p, lambda s: runs_make(s, "push-distfiles"))
    c = first(p, lambda s: runs_make(s, "release-create"))
    return (0 <= a < b < c), "digest chain %d, distfiles push %d, release step %d" % (a, b, c)


case("P06-AC-5 the digest chain still runs before the distfiles push and the release step", ac5_chain)

# ---------------------------------------------------------------- P06-AC-3: the report job
def report_job():
    doc, _ = load(".github/workflows/release.yml")
    return doc["jobs"]["report"]


def ac3_needs():
    n = report_job().get("needs")
    n = [n] if isinstance(n, str) else list(n or [])
    return sorted(n) == ["publish", "resolve"], "needs: %r" % n


case("P06-AC-3 the report job needs [resolve, publish]", ac3_needs)


def ac3_if():
    c = str(report_job().get("if", ""))
    ok = "always()" in c and re.search(r"workflow_run\.event\s*==\s*'push'", c) is not None
    return ok, "if: %r" % c


case("P06-AC-3 the report job has if: always() limited to push Build runs", ac3_if)


def ac3_perm():
    p = report_job().get("permissions")
    ok = isinstance(p, dict) and p.get("issues") == "write" and p.get("actions") == "read"
    return ok, "permissions: %r" % p


case("P06-AC-3 the report job holds issues: write and actions: read", ac3_perm)


def ac3_steps():
    ss = steps(report_job())
    runs = [s for s in ss if "run" in s]
    others = [s for s in ss if "run" not in s and not str(s.get("uses", "")).startswith("actions/checkout@")]
    if len(runs) != 1 or str(runs[0]["run"]).strip() != "make release-report":
        return False, "the job has no single step that runs exactly `make release-report`"
    return not others, "extra steps: %r" % [s.get("uses") for s in others]


case("P06-AC-3 the report job runs make release-report only", ac3_steps)


def ac3_top():
    doc, _ = load(".github/workflows/release.yml")
    return doc.get("permissions") == {"contents": "write", "actions": "read"}, "top-level permissions: %r" % doc.get("permissions")


case("P06-AC-3 release.yml's top-level permissions are unchanged", ac3_top)


def ac3_make():
    out = make_n("release-report")
    if "release-report.sh" not in out:
        return False, "make -n release-report does not run scripts/release-report.sh"
    return "gh release create" not in out and "gh release create" not in read("scripts/release-report.sh"), "gh release create appears"


case("P06-AC-3 make -n release-report runs release-report.sh; neither contains 'gh release create'", ac3_make)

# ---------------------------------------------------------------- P06-AC-4
def operator():
    sec = read("docs/releasing.md").split("## Operator steps to cut a release", 1)
    if len(sec) < 2:
        raise RuntimeError("no operator steps section")
    return norm(sec[1])


def has(pat):
    t = operator()
    return re.search(pat, t, re.I) is not None, "no match for /%s/ in the operator steps" % pat


case("P06-AC-4 the operator steps say pushing the tag is the only step", lambda: has(r"only (operator )?(step|action)"))
case("P06-AC-4 the operator steps say the release is never created, drafted or published by hand",
     lambda: has(r"(never|not|n't)[^.]*gh release create|gh release create[^.]*(never|not|n't)"))
case("P06-AC-4 the operator steps name the UI and gh release create as the by-hand ways",
     lambda: has(r"\bUI\b") if re.search(r"gh release create", operator()) else (False, "gh release create is not named"))
case("P06-AC-4 the operator steps say why: publishing creates the tag and starts the Build",
     lambda: has(r"creates the tag[^.]{0,40}starts the Build|starts the Build[^.]{0,40}creates the tag"))
case("P06-AC-4 the operator steps say what publish does with a release that already exists",
     lambda: has(r"already exist[^.]*\.[^.]*|already exist") if re.search(r"gh release delete", operator()) and re.search(r"assets", operator()) else (False, "no mention of assets and gh release delete"))

sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# ============================================================ dynamic checks (stubs)
W=$(mktemp -d "${TMPDIR:-/tmp}/P06.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT INT TERM
ok() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
t() { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi; }

mkdir -p "$W/bin" "$W/allzero"
cat >"$W/bin/gh" <<'E'
#!/bin/sh
printf 'CALL' >>"$GH_LOG"
for a in "$@"; do printf ' %s' "$a" >>"$GH_LOG"; done
echo >>"$GH_LOG"
expr=
prev=
for a in "$@"; do
	[ "$prev" = --jq ] && expr=$a
	prev=$a
done
emit() { if [ -n "$expr" ]; then jq -r "$expr" "$1"; else cat "$1"; fi; }
case "$1 $2" in
"release view")
	if [ -f "${GH_RELEASE_JSON:-/nonexistent}" ]; then emit "$GH_RELEASE_JSON"; exit 0; fi
	echo "release not found" >&2
	exit 1
	;;
"issue list")
	[ -f "${GH_ISSUES_JSON:-/nonexistent}" ] || { echo '[]' >"${GH_ISSUES_JSON:=$GH_LOG.issues}"; }
	emit "$GH_ISSUES_JSON"
	;;
"run view") [ -f "${GH_JOBS_JSON:-/nonexistent}" ] && emit "$GH_JOBS_JSON" ;;
"issue create" | "issue comment")
	{
		echo "ISSUE-CALL $*"
		prev=
		for a in "$@"; do
			case $prev in
			--body-file | -F) if [ "$a" = - ]; then cat; else cat "$a"; fi ;;
			esac
			prev=$a
		done
	} >>"$GH_ISSUE_LOG"
	;;
esac
exit 0
E
cat >"$W/bin/git" <<'E'
#!/bin/sh
[ "$1" = rev-parse ] || exit 1
for a in "$@"; do
	case $a in
	refs/tags/*)
		n=${a#refs/tags/}
		n=${n%^\{commit\}}
		sha=$(awk -v n="$n" '$1 == n { print $2 }' "$GIT_TAGS")
		[ -n "$sha" ] || exit 1
		echo "$sha"
		exit 0
		;;
	esac
done
exit 1
E
chmod +x "$W/bin/gh" "$W/bin/git"
printf '#!/bin/sh\nexit 0\n' >"$W/allzero/gh"
chmod +x "$W/allzero/gh"

FILES="themonolith-VER.iso SHA256SUMS bom.cdx.json release-inputs.json source-audit.tsv rootfs-provenance.tsv rc1-diff.md sizes.md dynamic-allowlist.txt attestation-summary.json"

# newcase <name>: a fresh directory with a log and the notes file; sets C, GH_LOG
newcase() {
	C=$W/$1
	mkdir -p "$C/cwd"
	: >"$C/gh.log"
	: >"$C/issue.log"
	echo notes >"$C/cwd/release-notes.md"
}
# release JSON <file> <draft:true|false> <asset count>
mkrelease() {
	jq -n --arg tag "$TAG" --argjson d "$2" --argjson n "$3" \
		'{tagName: $tag, isDraft: $d, assets: [range(0; $n) | {name: ("asset-" + tostring)}]}' >"$1"
}
# runit <script> [env...]: runs it in $C/cwd with the stub gh/git; output in $C/out, status in $C/rc
runit() {
	s=$1
	shift
	(cd "$C/cwd" && env PATH="$W/bin:$PATH" GH_LOG="$C/gh.log" GH_ISSUE_LOG="$C/issue.log" GIT_TAGS="$C/tags" \
		TAG="$TAG" RELEASE_DIR="$W/rel" BUILD_VERSION="${TAG#v}" GITHUB_REPOSITORY=acme/monolith-fixture GH_TOKEN=x \
		"$@" sh "$ROOT/scripts/$s") >"$C/out" 2>&1
	echo $? >"$C/rc"
}
ncalls() { grep -c "^CALL $1" "$C/gh.log"; }
rc_is() { [ "$(cat "$C/rc")" = "$1" ]; }
msg_ok() { # the tag, the count and the delete-keeping-the-tag step
	grep -qF "$TAG" "$C/out" && grep -qw "$1" "$C/out" && grep -qF "gh release delete $TAG --yes" "$C/out"
}
files_in() { # <call prefix>: every release file is on one of those calls
	for f in $FILES; do
		f=$(echo "$f" | sed "s/VER/${TAG#v}/")
		grep "^CALL $1" "$C/gh.log" | grep -qF "$W/rel/$f" || return 1
	done
}

for TAG in v0.2.0-rc1 v0.2.0; do
	case $TAG in *-*) pre=1 ;; *) pre=0 ;; esac
	kind=$([ "$pre" = 1 ] && echo "prerelease $TAG" || echo "final $TAG")

	# ---- release-existing.sh (P06-AC-2)
	newcase "ex-none-$TAG"
	runit release-existing.sh
	rc_is 0 && ok "P06-AC-2 release-existing.sh exits 0 with no release ($kind)" || fail "P06-AC-2 release-existing.sh exits 0 with no release ($kind)"
	for st in true false; do
		newcase "ex-empty-$st-$TAG"
		mkrelease "$C/rel.json" "$st" 0
		runit release-existing.sh GH_RELEASE_JSON="$C/rel.json"
		rc_is 0 && ok "P06-AC-2 release-existing.sh exits 0 with a release without assets, draft=$st ($kind)" \
			|| fail "P06-AC-2 release-existing.sh exits 0 with a release without assets, draft=$st ($kind)"
		[ -s "$C/gh.log" ] && [ "$(grep -vc '^CALL release view' "$C/gh.log")" = 0 ] \
			&& ok "P06-AC-2 release-existing.sh calls only gh release view, draft=$st ($kind)" \
			|| fail "P06-AC-2 release-existing.sh calls only gh release view, draft=$st ($kind)"
		newcase "ex-assets-$st-$TAG"
		mkrelease "$C/rel.json" "$st" 7
		runit release-existing.sh GH_RELEASE_JSON="$C/rel.json"
		rc_is 1 && msg_ok 7 && ok "P06-AC-2 release-existing.sh exits 1 and prints tag, count and the delete step with 7 assets, draft=$st ($kind)" \
			|| fail "P06-AC-2 release-existing.sh exits 1 and prints tag, count and the delete step with 7 assets, draft=$st ($kind)"
		[ -s "$C/gh.log" ] && [ "$(grep -vc '^CALL release view' "$C/gh.log")" = 0 ] \
			&& ok "P06-AC-2 release-existing.sh with assets calls only gh release view, draft=$st ($kind)" \
			|| fail "P06-AC-2 release-existing.sh with assets calls only gh release view, draft=$st ($kind)"
	done

	# ---- release-create.sh (P06-AC-2)
	newcase "cr-none-$TAG"
	runit release-create.sh
	if rc_is 0 && [ "$(ncalls 'release create')" = 1 ] && files_in 'release create' \
		&& grep '^CALL release create' "$C/gh.log" | grep -qF -- "--title The Monolith $TAG" \
		&& grep '^CALL release create' "$C/gh.log" | grep -qF -- "--notes-file release-notes.md" \
		&& grep '^CALL release create' "$C/gh.log" | grep -qF "release create $TAG"; then
		fl=$(grep '^CALL release create' "$C/gh.log")
		if [ "$pre" = 1 ]; then
			case $fl in *"--prerelease"*"--latest=false"* | *"--latest=false"*"--prerelease"*) ok "P06-AC-2 release-create.sh with no release calls gh release create with today's files and flags ($kind)" ;; *) fail "P06-AC-2 release-create.sh with no release calls gh release create with today's files and flags ($kind)" ;; esac
		else
			case $fl in *--prerelease* | *--latest=false*) fail "P06-AC-2 release-create.sh with no release calls gh release create with today's files and flags ($kind)" ;; *) ok "P06-AC-2 release-create.sh with no release calls gh release create with today's files and flags ($kind)" ;; esac
		fi
	else
		fail "P06-AC-2 release-create.sh with no release calls gh release create with today's files and flags ($kind)"
	fi

	for st in true false; do
		newcase "cr-empty-$st-$TAG"
		mkrelease "$C/rel.json" "$st" 0
		runit release-create.sh GH_RELEASE_JSON="$C/rel.json"
		lbl="a release without assets, draft=$st ($kind)"
		rc_is 0 && [ "$(ncalls 'release create')" = 0 ] && ok "P06-AC-2 release-create.sh never calls gh release create with $lbl" \
			|| fail "P06-AC-2 release-create.sh never calls gh release create with $lbl"
		files_in 'release upload' && grep '^CALL release upload' "$C/gh.log" | grep -qF "$TAG" \
			&& ok "P06-AC-2 release-create.sh uploads the same files with gh release upload for $lbl" \
			|| fail "P06-AC-2 release-create.sh uploads the same files with gh release upload for $lbl"
		ed=$(grep '^CALL release edit' "$C/gh.log" || true)
		eok=0
		if [ -n "$ed" ] && [ "$(ncalls 'release edit')" = 1 ] && printf '%s\n' "$ed" | grep -qF "release edit $TAG" \
			&& printf '%s\n' "$ed" | grep -qF "The Monolith $TAG" && printf '%s\n' "$ed" | grep -qF "release-notes.md" \
			&& printf '%s\n' "$ed" | grep -qF -- "--draft=false"; then
			if [ "$pre" = 1 ]; then
				case $ed in *--prerelease*) case $ed in *--latest=false*) eok=1 ;; esac ;; esac
			else
				case $ed in *--prerelease* | *--latest=false*) ;; *) eok=1 ;; esac
			fi
		fi
		[ "$eok" = 1 ] && ok "P06-AC-2 release-create.sh calls gh release edit with title, notes file, --draft=false and the $kind flags for $lbl" \
			|| fail "P06-AC-2 release-create.sh calls gh release edit with title, notes file, --draft=false and the $kind flags for $lbl"
		lu=$(grep -n '^CALL release upload' "$C/gh.log" | tail -1 | cut -d: -f1)
		le=$(grep -n '^CALL release edit' "$C/gh.log" | tail -1 | cut -d: -f1)
		[ -n "$lu" ] && [ -n "$le" ] && [ "$lu" -lt "$le" ] && ok "P06-AC-2 release-create.sh edits after the last upload for $lbl" \
			|| fail "P06-AC-2 release-create.sh edits after the last upload for $lbl"

		newcase "cr-assets-$st-$TAG"
		mkrelease "$C/rel.json" "$st" 7
		runit release-create.sh GH_RELEASE_JSON="$C/rel.json"
		lbl="a release with 7 assets, draft=$st ($kind)"
		rc_is 1 && ok "P06-AC-2 release-create.sh exits 1 with $lbl" || fail "P06-AC-2 release-create.sh exits 1 with $lbl"
		{ [ -s "$C/gh.log" ] && [ "$(ncalls 'release create')$(ncalls 'release upload')$(ncalls 'release edit')" = 000 ]; } \
			&& ok "P06-AC-2 release-create.sh calls neither create, upload nor edit with $lbl" \
			|| fail "P06-AC-2 release-create.sh calls neither create, upload nor edit with $lbl"
		msg_ok 7 && ok "P06-AC-2 release-create.sh prints the tag, the count and the delete step with $lbl" \
			|| fail "P06-AC-2 release-create.sh prints the tag, the count and the delete step with $lbl"
	done

	# ---- P06-AC-5: P04's stub answers every call with exit 0 and no output
	newcase "cr-allzero-$TAG"
	mkdir -p "$C/zbin"
	cp "$W/allzero/gh" "$C/zbin/gh"
	(cd "$C/cwd" && env PATH="$C/zbin:$PATH" TAG="$TAG" RELEASE_DIR="$W/rel" BUILD_VERSION="${TAG#v}" \
		GITHUB_REPOSITORY=acme/monolith-fixture GH_TOKEN=x sh "$ROOT/scripts/release-create.sh") >"$C/out" 2>&1
	echo $? >"$C/rc"
	rc_is 0 && ok "P06-AC-5 release-create.sh runs to the end against a gh that answers exit 0 with no output ($kind)" \
		|| fail "P06-AC-5 release-create.sh runs to the end against a gh that answers exit 0 with no output ($kind)"
	# that stub logs nothing; use the logging stub with a view that exits 0 and prints nothing
	newcase "cr-empty-out-$TAG"
	: >"$C/rel.json"
	runit release-create.sh GH_RELEASE_JSON="$C/rel.json"
	{ rc_is 0 && { files_in 'release create' || files_in 'release upload'; }; } \
		&& ok "P06-AC-5 release-create.sh uploads every asset when gh release view exits 0 with no output ($kind)" \
		|| fail "P06-AC-5 release-create.sh uploads every asset when gh release view exits 0 with no output ($kind)"
done

# ============================================================ release-report.sh (P06-AC-3)
SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
BURL=https://github.com/acme/monolith-fixture/actions/runs/900100
RURL=https://github.com/acme/monolith-fixture/actions/runs/900200

# report <name> <tag> <head_branch> <build conclusion> <resolve> <publish> <issues json> -> runs it
report() {
	TAG=$2
	newcase "rp-$1"
	printf 'v0.2.0-rc1 %s\nv0.2.0 %s\nv0.3.0 %s\n' "$SHA" "$SHA" "$OTHER" >"$C/tags"
	cat >"$C/jobs.json" <<'E'
{"jobs":[{"name":"build-z","conclusion":"success"},{"name":"boot-test-qemu","conclusion":"failure"},{"name":"compare-gate","conclusion":"cancelled"},{"name":"toolbox-ok","conclusion":"skipped"}]}
E
	printf '%s\n' "$7" >"$C/issues.json"
	runit release-report.sh HEAD_BRANCH="$3" HEAD_SHA="$SHA" BUILD_RUN_ID=900100 BUILD_RUN_ATTEMPT=4 BUILD_CONCLUSION="$4" \
		BUILD_RUN_URL="$BURL" RELEASE_RUN_URL="$RURL" RESOLVE_RESULT="$5" PUBLISH_RESULT="$6" \
		GH_JOBS_JSON="$C/jobs.json" GH_ISSUES_JSON="$C/issues.json"
}
issue_has() { grep -qF -- "$1" "$C/issue.log"; }
decoy='[{"number":5,"title":"Release v0.9.9 did not publish"},{"number":6,"title":"Something else"}]'

for pair in "v0.2.0-rc1 failure" "v0.2.0 cancelled"; do
	set -- $pair
	tg=$1
	cc=$2
	title="Release $tg did not publish"
	report "a-$tg" "$tg" "$tg" "$cc" skipped skipped "$decoy"
	lbl="a $cc Build run of $tg with no open issue"
	{ [ "$(ncalls 'issue create')" = 1 ] && [ "$(ncalls 'issue comment')" = 0 ] && grep '^CALL issue create' "$C/gh.log" | grep -qF "$title"; } \
		&& ok "P06-AC-3(a) release-report.sh calls gh issue create once with the title for $lbl" \
		|| fail "P06-AC-3(a) release-report.sh calls gh issue create once with the title for $lbl"
	bodyok=1
	for s in "$BURL" "$cc" "boot-test-qemu" "compare-gate" "docs/releasing.md"; do issue_has "$s" || bodyok=0; done
	issue_has " 4" || issue_has "4" || bodyok=0
	[ "$bodyok" = 1 ] && ok "P06-AC-3(a) the issue body holds the Build run URL, attempt 4, $cc, each failed or cancelled job and the docs link ($tg)" \
		|| fail "P06-AC-3(a) the issue body holds the Build run URL, attempt 4, $cc, each failed or cancelled job and the docs link ($tg)"
	rc_is 0 && ok "P06-AC-3(a) release-report.sh exits 0 ($tg)" || fail "P06-AC-3(a) release-report.sh exits 0 ($tg)"

	report "b-$tg" "$tg" "$tg" "$cc" skipped skipped '[{"number":5,"title":"Release v0.9.9 did not publish"},{"number":12,"title":"'"$title"'"}]'
	{ [ "$(ncalls 'issue comment')" = 1 ] && [ "$(ncalls 'issue create')" = 0 ] && grep '^CALL issue comment' "$C/gh.log" | grep -qE "issue comment 12( |$)"; } \
		&& ok "P06-AC-3(b) release-report.sh comments once on the open issue 12 and never creates one ($tg)" \
		|| fail "P06-AC-3(b) release-report.sh comments once on the open issue 12 and never creates one ($tg)"
	issue_has "$BURL" && issue_has "boot-test-qemu" && ok "P06-AC-3(b) the comment holds the Build run URL and the failed job ($tg)" \
		|| fail "P06-AC-3(b) the comment holds the Build run URL and the failed job ($tg)"

	for res in "failure success" "success failure"; do
		set -- $res
		report "c-$tg-$1-$2" "$tg" "$tg" success "$1" "$2" "$decoy"
		{ [ "$(ncalls 'issue create')" = 1 ] && issue_has "$RURL" && grep '^CALL issue create' "$C/gh.log" | grep -qF "$title"; } \
			&& ok "P06-AC-3(c) release-report.sh reports with the Release run URL for a green Build run, resolve=$1 publish=$2 ($tg)" \
			|| fail "P06-AC-3(c) release-report.sh reports with the Release run URL for a green Build run, resolve=$1 publish=$2 ($tg)"
	done

	report "ok-$tg" "$tg" "$tg" success success success "$decoy"
	{ rc_is 0 && ! grep -q '^CALL issue' "$C/gh.log"; } && ok "P06-AC-3 release-report.sh reports nothing for a published tag ($tg)" \
		|| fail "P06-AC-3 release-report.sh reports nothing for a published tag ($tg)"
done

report d-branch v0.2.0 main failure skipped skipped "$decoy"
{ rc_is 0 && ! grep -q '^CALL issue' "$C/gh.log"; } && ok "P06-AC-3(d) a branch push calls no gh issue command" \
	|| fail "P06-AC-3(d) a branch push calls no gh issue command"
report d-wrongsha v0.3.0 v0.3.0 failure skipped skipped "$decoy"
{ rc_is 0 && ! grep -q '^CALL issue' "$C/gh.log"; } && ok "P06-AC-3(d) a tag that does not point at head_sha calls no gh issue command" \
	|| fail "P06-AC-3(d) a tag that does not point at head_sha calls no gh issue command"
report d-notag v9.9.9 v9.9.9 cancelled skipped skipped "$decoy"
{ rc_is 0 && ! grep -q '^CALL issue' "$C/gh.log"; } && ok "P06-AC-3(d) a head_branch that is not a tag calls no gh issue command" \
	|| fail "P06-AC-3(d) a head_branch that is not a tag calls no gh issue command"

if [ "$fails" -ne 0 ]; then
	echo "release-recovery.test.sh: $fails group(s) or case(s) failed"
	exit 1
fi
echo "release-recovery.test.sh: all passed"
