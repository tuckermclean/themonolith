#!/bin/sh
# R05-AC-2 (+ the build half of R05-AC-4): the static shape of the offline-build CI job. The evidence for the
# criteria themselves is a recorded run of .github/workflows/rust-offline.yml; this test pins what that job is:
#   - Make target test-rust-offline -> scripts/rust-offline-build.sh (logic in scripts/, not YAML)
#   - workflow rust-offline.yml: workflow_dispatch + pull_request, run steps only `make ...` / `toolbox/run -- ...`,
#     the job ending in `make test-rust-offline`
#   - the script, run here under a stub $DOCKER (records argv, fakes success or failure), with env DOCKER and
#     BUILDER_REF (also passed as $1), the builder image by digest:
#       (a) fetch: emerge --fetchonly of both -r1 atoms, with network, into a DISTDIR
#       (b) then a separate container with --network none, FETCHCOMMAND=/bin/false and RESUMECOMMAND=/bin/false
#           emerging both from that DISTDIR
#       (c) smoke runs: rl144 --version and stele --version|--help, a non-zero exit fails the script
#       (d) the image's library/Cargo.lock (read with `cat` or `docker cp`, or compared in the container with
#           cmp/diff) equals scripts/fixtures/R05/library-Cargo.lock; a difference fails
#       (e) any failing step makes the script exit non-zero
# Offline; runs in commit-less copies and in the toolbox. A missing script, target or workflow is a FAIL.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
SCRIPT="$ROOT/scripts/rust-offline-build.sh"
WF="$ROOT/.github/workflows/rust-offline.yml"
LOCK="$ROOT/scripts/fixtures/R05/library-Cargo.lock"
LIBLOCK=/opt/rustup/toolchains/nightly-2026-07-15-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library/Cargo.lock
REF=registry.test/builder@sha256:0000000000000000000000000000000000000000000000000000000000000aa1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rust-offline.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
# A failure case counts only when the script ran (it called $DOCKER) and the success run exited 0.
failed_ran() { [ "$(cat "$tmp/$1.rc")" != 0 ] && [ -s "$tmp/$1.log" ] && [ "$(cat "$tmp/ok.rc")" = 0 ]; }
ck() { # ck <label> <command...>
	_l=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$_l"; else fail "$_l"; fi
}

# ---- Make target ----
(cd "$ROOT" && make -n test-rust-offline) >"$tmp/make.out" 2>&1
ck "R05-AC-2 make -n test-rust-offline reaches scripts/rust-offline-build.sh" grep -q 'scripts/rust-offline-build\.sh' "$tmp/make.out"
ck "R05-AC-2 make -n test-rust-offline passes the DOCKER command and the builder image digest" \
	sh -c 'grep -q "DOCKER" "$1" && grep -q "builder@sha256:" "$1"' _ "$tmp/make.out"

# ---- Workflow ----
if [ ! -f "$WF" ]; then
	fail "R05-AC-2 .github/workflows/rust-offline.yml exists"
	for l in "triggers include workflow_dispatch" "triggers include pull_request" \
		"every run step is make <target> or toolbox/run -- ..." "the job ends in make test-rust-offline"; do
		fail "R05-AC-2 rust-offline.yml $l (file missing)"
	done
else
	python3 - "$WF" <<'PY'
import sys, yaml
bad = 0
def chk(l, c):
    global bad
    print(("PASS: " if c else "FAIL: ") + "R05-AC-2 rust-offline.yml " + l)
    if not c: bad += 1
try:
    doc = yaml.safe_load(open(sys.argv[1]))
    on = doc.get(True, doc.get("on"))
    jobs = doc["jobs"]
except Exception as e:
    print("FAIL: R05-AC-2 rust-offline.yml parses as a workflow: %s" % e); sys.exit(1)
keys = set(on) if isinstance(on, (dict, list)) else {on}
chk("triggers include workflow_dispatch", "workflow_dispatch" in keys)
chk("triggers include pull_request", "pull_request" in keys)
runs, last = [], None
for j in jobs.values():
    steps = j.get("steps") or []
    rs = [s["run"].strip() for s in steps if "run" in s]
    runs += rs
    if steps and "run" in steps[-1]: last = steps[-1]["run"].strip()
chk("has run steps", bool(runs))
chk("every run step is make <target> or toolbox/run -- ...",
    bool(runs) and all(r.startswith("make ") or r.startswith("toolbox/run -- ") for r in runs))
chk("the job ends in make test-rust-offline", last == "make test-rust-offline")
sys.exit(1 if bad else 0)
PY
	[ $? -eq 0 ] || fails=$((fails + 1))
fi

# ---- The script, under a stub $DOCKER ----
mkdir -p "$tmp/bin" "$tmp/cwd"
cat >"$tmp/bin/docker" <<'STUB'
#!/bin/sh
# Records one line per invocation (argv plus stdin); fails when FAIL_RE matches the line.
in=""; [ -t 0 ] || in=$(cat)
line=$(printf '%s %s' "$*" "$in" | tr '\n' ' ')
echo "$line" >>"$STUB_LOG"
case "$1" in create) echo stubcid; exit 0 ;; esac
if [ -n "${FAIL_RE:-}" ] && printf '%s\n' "$line" | grep -Eq -- "$FAIL_RE"; then exit 1; fi
case "$line" in *"$STUB_LIBLOCK"*)
	if [ "$1" = cp ]; then
		for a in "$@"; do dest=$a; done
		cp "$LOCK_SRC" "$dest" || exit 1
	elif printf '%s\n' "$line" | grep -Eq '(^| )(cmp|diff) '; then
		cmp -s "$LOCK_SRC" "$STUB_FIXTURE" || exit 1
	else
		cat "$LOCK_SRC"
	fi ;;
esac
exit 0
STUB
chmod +x "$tmp/bin/docker"
cp "$LOCK" "$tmp/lock.same" 2>/dev/null || : >"$tmp/lock.same"
{ cat "$tmp/lock.same"; echo '# drifted'; } >"$tmp/lock.diff"

run_case() { # run_case <name> <FAIL_RE> <LOCK_SRC>   -> $tmp/<name>.log, $tmp/<name>.rc
	( cd "$tmp/cwd" && env STUB_LOG="$tmp/$1.log" STUB_LIBLOCK="$LIBLOCK" STUB_FIXTURE="$LOCK" LOCK_SRC="$3" \
		FAIL_RE="$2" DOCKER="$tmp/bin/docker" BUILDER_REF="$REF" \
		sh "$SCRIPT" "$REF" </dev/null >"$tmp/$1.out" 2>&1 )
	echo $? >"$tmp/$1.rc"
	[ -f "$tmp/$1.log" ] || : >"$tmp/$1.log"
}
NET='--(network|net)[= ]none'
if [ ! -f "$SCRIPT" ]; then
	fail "R05-AC-2 scripts/rust-offline-build.sh exists"
fi
run_case ok '' "$tmp/lock.same"
run_case nofetch '--fetchonly' "$tmp/lock.same"
run_case nobuild "$NET" "$tmp/lock.same"
run_case norl '(^| |/)rl144 --version' "$tmp/lock.same"
run_case nostele '(^| |/)stele (--version|--help)' "$tmp/lock.same"
run_case drift '' "$tmp/lock.diff"
L=$tmp/ok.log
first() { grep -nE -e "$2" "$1" | head -n 1 | cut -d: -f1; }
ln_fetch=$(first "$L" -- '--fetchonly')
ln_net=$(first "$L" "$NET")
RL='games-roguelike/rl144'; ST='www-client/stele'

ck "R05-AC-2 script exits 0 when every stubbed step succeeds" test "$(cat "$tmp/ok.rc")" = 0
ck "R05-AC-2 every container runs the builder image by digest (\$BUILDER_REF)" \
	sh -c '[ -s "$1" ] && ! grep -E "(^| )run " "$1" | grep -qv -F -- "$2"' _ "$L" "$REF"
ck "R05-AC-2 (a) an emerge --fetchonly container runs, via \$DOCKER" test -n "$ln_fetch"
ck "R05-AC-2 (a) the fetch emerge names both rl144 and stele -r1" \
	sh -c 'l=$(grep -E -e "--fetchonly" "$1" | head -n 1); echo "$l" | grep -q -- "$2" && echo "$l" | grep -q -- "$3"' _ "$L" "$RL" "$ST"
ck "R05-AC-2 (a) the fetch container is not run with --network none" \
	sh -c 'grep -E -e "--fetchonly" "$1" | grep -Evq -e "$2"' _ "$L" "$NET"
ck "R05-AC-2 (a) the fetch does not set FETCHCOMMAND=/bin/false" \
	sh -c '[ -n "$2" ] && ! grep -E -e "--fetchonly" "$1" | grep -q "FETCHCOMMAND=/bin/false"' _ "$L" "$ln_fetch"
ck "R05-AC-2 (b) a --network none container runs" test -n "$ln_net"
ck "R05-AC-2 (b) the fetch comes before the --network none build" \
	sh -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$ln_fetch" "$ln_net"
ck "R05-AC-2 (b) the --network none container has FETCHCOMMAND=/bin/false and RESUMECOMMAND=/bin/false" \
	sh -c 'l=$(grep -E -e "$2" "$1" | head -n 1); echo "$l" | grep -q "FETCHCOMMAND=/bin/false" && echo "$l" | grep -q "RESUMECOMMAND=/bin/false"' _ "$L" "$NET"
ck "R05-AC-2 (b) the --network none container emerges both rl144 and stele -r1" \
	sh -c 'l=$(grep -E -e "$2" "$1" | head -n 1); echo "$l" | grep -q "emerge" && echo "$l" | grep -q -- "$3" && echo "$l" | grep -q -- "$4"' _ "$L" "$NET" "$RL" "$ST"
ck "R05-AC-2 (b) the offline emerge does not fetch (no --fetchonly)" \
	sh -c '[ -n "$3" ] && ! grep -E -e "$2" "$1" | grep -q -e "--fetchonly"' _ "$L" "$NET" "$ln_net"
ck "R05-AC-2 (b) both containers use the same DISTDIR (distfiles mount or DISTDIR)" \
	sh -c 'f=$(grep -E -e "--fetchonly" "$1" | head -n 1); n=$(grep -E -e "$2" "$1" | head -n 1); for x in "$f" "$n"; do echo "$x" | grep -Eq "DISTDIR|distfiles" || exit 1; done' _ "$L" "$NET"
ck "R05-AC-2 (c) rl144 --version is run" grep -Eq '(^| |/)rl144 --version' "$L"
ck "R05-AC-2 (c) stele is smoke-run (--version or --help)" grep -Eq '(^| |/)stele (--version|--help)' "$L"
ck "R05-AC-2 (c) the smoke runs come after the fetch" \
	sh -c 'n=$(grep -nE -e "(^| |/)rl144 --version" "$1" | head -n 1 | cut -d: -f1); [ -n "$n" ] && [ -n "$2" ] && [ "$n" -ge "$2" ]' _ "$L" "$ln_fetch"
ck "R05-AC-4 (d) the builder's library/Cargo.lock is read from the image" grep -q -F -- "$LIBLOCK" "$L"
ck "R05-AC-2 (e) a failing fetch makes the script exit non-zero" failed_ran nofetch
ck "R05-AC-2 (e) a failing fetch stops before any --network none container" \
	sh -c '[ -s "$1" ] && ! grep -Eq -e "$2" "$1"' _ "$tmp/nofetch.log" "$NET"
ck "R05-AC-2 (e) a failing offline build makes the script exit non-zero" failed_ran nobuild
ck "R05-AC-2 (e) a failing rl144 --version makes the script exit non-zero" failed_ran norl
ck "R05-AC-2 (e) a failing stele smoke run makes the script exit non-zero" failed_ran nostele
ck "R05-AC-4 (d) an image library/Cargo.lock that differs from the fixture fails the script" \
	sh -c '[ "$(cat "$1")" != 0 ] && grep -q -F -- "$2" "$3" && [ "$(cat "$4")" = 0 ]' _ "$tmp/drift.rc" "$LIBLOCK" "$tmp/drift.log" "$tmp/ok.rc"
ck "R05-AC-4 (d) the fixture scripts/fixtures/R05/library-Cargo.lock exists" test -s "$LOCK"

if [ "$fails" -gt 0 ]; then
	echo "rust-offline: $fails check(s) FAILED"
	exit 1
fi
echo "rust-offline: all checks passed"
