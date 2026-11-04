#!/bin/sh
# R02 overlay-qa: scripts/overlay-qa.sh <tree> <overlay> <accepted>, `make test-overlay`, pr-validate.yml,
# docs/overlay-qa.md. Criterion: R02-AC-1 (unit half; the real pkgcheck run, the pr-validate job and the
# throwaway PR are recorded runs). pkgcheck is a stub on PATH. Needs no network, no git history.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES

here=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
script=$root/scripts/overlay-qa.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/overlay-qa.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

mkdir -p "$tmp/bin" "$tmp/tree/profiles/embedded" "$tmp/overlay" "$tmp/home"
cat >"$tmp/bin/pkgcheck" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_ARGV"
[ -f "$STUB_OUT" ] && cat "$STUB_OUT"
exit "${STUB_RC:-0}"
STUB
chmod +x "$tmp/bin/pkgcheck"
PATH=$tmp/bin:$PATH
HOME=$tmp/home
STUB_ARGV=$tmp/argv
STUB_OUT=$tmp/stub.out
export HOME STUB_ARGV STUB_OUT

acc() { # acc <lines...>: write the accepted-list doc in ruling 2's format
	{
		printf '# Overlay QA\n\nprose\n\n## Accepted warnings\n\n```\n'
		for l in "$@"; do printf '%s\n' "$l"; done
		printf '```\n\n## Other\n\n```\nnot/read Ignored  # no\n```\n'
	} >"$tmp/accepted.md"
}
res() { # res <lines...>: what the stub pkgcheck prints
	: >"$STUB_OUT"
	for l in "$@"; do printf '%s\n' "$l" >>"$STUB_OUT"; done
}
run() { # run: sets rc, out; argv log is fresh
	: >"$STUB_ARGV"
	out=$(sh "$script" "$tmp/tree" "$tmp/overlay" "$tmp/accepted.md" 2>&1); rc=$?
}
A='app-misc/monolith-base BadDescription'
R='app-misc/monolith-base MissingRemoteId'

# R02-AC-1: equal sets pass
acc "$A  # r1" "$R  # r2"; res "$A" "$R"; STUB_RC=0; export STUB_RC; run
if [ $rc -eq 0 ]; then pass "R02-AC-1 equal sets exit 0"; else fail "R02-AC-1 equal sets exit 0 (rc=$rc: $out)"; fi
if grep -q -e '--config no' "$STUB_ARGV" && grep -q -e '--cache no' "$STUB_ARGV" \
	&& grep -q "$tmp/overlay" "$STUB_ARGV"; then
	pass "R02-AC-1 pkgcheck runs with --config no, --cache no and the overlay path"
else fail "R02-AC-1 pkgcheck argv lacks --config no / --cache no / overlay path ($(cat "$STUB_ARGV"))"; fi

# R02-AC-1: order and the other doc blocks do not matter
acc "$R  # r2" "$A  # r1"; res "$A" "$R"; run
if [ $rc -eq 0 ]; then pass "R02-AC-1 order irrelevant, only the Accepted warnings block is read"
else fail "R02-AC-1 order irrelevant (rc=$rc: $out)"; fi

# R02-AC-1: a new warning fails and is named
acc "$A  # r1"; res "$A" "$R"; run
if [ $rc -ne 0 ] && [ -f "$script" ] && printf '%s' "$out" | grep -q 'MissingRemoteId'; then pass "R02-AC-1 new warning fails and is printed"
else fail "R02-AC-1 new warning fails and is printed (rc=$rc: $out)"; fi

# R02-AC-1: a stale accepted warning fails and is named
acc "$A  # r1" "$R  # r2"; res "$A"; run
if [ $rc -ne 0 ] && [ -f "$script" ] && printf '%s' "$out" | grep -q 'MissingRemoteId'; then pass "R02-AC-1 stale accepted warning fails and is printed"
else fail "R02-AC-1 stale accepted warning fails and is printed (rc=$rc: $out)"; fi

# R02-AC-1: no results, empty accepted list
acc; res; run
if [ $rc -eq 0 ]; then pass "R02-AC-1 no results and no accepted entries exit 0"; else fail "R02-AC-1 empty sets exit 0 (rc=$rc: $out)"; fi

# R02-AC-1: pkgcheck failing fails, with its output
acc "$A  # r1"; res "$A"; STUB_RC=3; export STUB_RC; run
if [ $rc -ne 0 ] && [ -f "$script" ]; then pass "R02-AC-1 pkgcheck exit non-zero fails"; else fail "R02-AC-1 pkgcheck exit non-zero fails (rc=0)"; fi
acc "$A  # r1"; res "$A" "pkgcore.errors: boom"; run
if [ $rc -ne 0 ] && [ -f "$script" ]; then pass "R02-AC-1 pkgcheck failing with error output fails"; else fail "R02-AC-1 pkgcheck error output fails (rc=0)"; fi
STUB_RC=0; export STUB_RC

# R02-AC-1: accepted line without a reason is an error
acc "$A"; res "$A"; run
if [ $rc -ne 0 ] && [ -f "$script" ]; then pass "R02-AC-1 accepted line without '# reason' fails"; else fail "R02-AC-1 accepted line without reason fails (rc=0)"; fi
acc "$A  #"; res "$A"; run
if [ $rc -ne 0 ] && [ -f "$script" ]; then pass "R02-AC-1 accepted line with an empty reason fails"; else fail "R02-AC-1 empty reason fails (rc=0)"; fi

# R02-AC-1: versions are not part of the key (same pair for two versions collapses)
acc "$A  # r1"; res "$A" "$A"; run
if [ $rc -eq 0 ]; then pass "R02-AC-1 the same pair reported twice matches one entry"
else fail "R02-AC-1 duplicate pair matches one entry (rc=$rc: $out)"; fi
acc "$A  # r1"; res "app-misc/monolith-base-0.1.0-r7 BadDescription"; run
if [ $rc -ne 0 ] && [ -f "$script" ]; then pass "R02-AC-1 key is <category>/<package> <Keyword> (a versioned name is not the key)"
else fail "R02-AC-1 key is versionless (rc=0)"; fi

# R02-AC-1: repos.conf and make.profile
acc "$A  # r1"; res "$A"; run
rcf=$HOME/portage/repos.conf
if [ -f "$rcf" ] && grep -q 'main-repo *= *gentoo' "$rcf" \
	&& awk -v t="$tmp/tree" '/^\[gentoo\]/{s=1;next} /^\[/{s=0} s&&$1=="location"&&$3==t{f=1} END{exit !f}' "$rcf" \
	&& awk -v o="$tmp/overlay" '/^\[monolith\]/{s=1;next} /^\[/{s=0} s&&$1=="location"&&$3==o{f=1} END{exit !f}' "$rcf"; then
	pass "R02-AC-1 repos.conf: main-repo gentoo at the tree, monolith at the overlay"
else fail "R02-AC-1 repos.conf wrong or missing ($(cat "$rcf" 2>&1))"; fi
mp=$HOME/portage/make.profile
if [ -e "$mp" ] && [ "$(cd "$mp" 2>/dev/null && pwd -P)" = "$(cd "$tmp/tree/profiles/embedded" && pwd -P)" ]; then
	pass "R02-AC-1 make.profile resolves to <tree>/profiles/embedded"
else fail "R02-AC-1 make.profile does not resolve to <tree>/profiles/embedded"; fi

# R02-AC-1: Make wiring
if make -C "$root" -pn test 2>/dev/null | grep '^test:' | grep -qw 'test-overlay'; then
	pass "R02-AC-1 make test lists test-overlay"
else fail "R02-AC-1 make test lists test-overlay"; fi
if make -C "$root" -n test-overlay 2>&1 | grep -q 'overlay-qa\.sh'; then
	pass "R02-AC-1 make test-overlay runs overlay-qa.sh"
else fail "R02-AC-1 make test-overlay runs overlay-qa.sh"; fi
wf=$root/.github/workflows/pr-validate.yml
if python3 - "$wf" <<'PY' 2>/dev/null
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for j in d["jobs"].values() for s in j["steps"]]
def mk(s):
    w = str(s.get("run", "")).split()
    return len(w) > 1 and w[0] == "make" and "test-overlay" in w[1:]
sys.exit(0 if any(mk(s) for s in steps) else 1)
PY
then pass "R02-AC-1 pr-validate.yml runs make … test-overlay"
else fail "R02-AC-1 pr-validate.yml runs make … test-overlay"; fi

# R02-AC-1 (ruling 4): docs/overlay-qa.md accepted block
doc=$root/docs/overlay-qa.md
blk=$(awk '/^## /{s=($0=="## Accepted warnings");f=0;next} s&&/^```/{if(f){exit}f=1;next} s&&f' "$doc" 2>/dev/null)
if [ -n "$blk" ] && ! printf '%s\n' "$blk" | grep -v '^[[:space:]]*$' | grep -qv '#[[:space:]]*[^[:space:]]'; then
	pass "R02-AC-1 docs/overlay-qa.md: every accepted line carries a reason"
else fail "R02-AC-1 docs/overlay-qa.md lacks an '## Accepted warnings' block with reasons"; fi
if printf '%s\n' "$blk" | grep -q '^app-misc/monolith-base BadDescription'; then
	pass "R02-AC-1 docs/overlay-qa.md accepts app-misc/monolith-base BadDescription"
else fail "R02-AC-1 docs/overlay-qa.md accepts app-misc/monolith-base BadDescription"; fi

if [ $fails -eq 0 ]; then echo "overlay-qa: all passed"; else echo "overlay-qa: $fails failed"; exit 1; fi
