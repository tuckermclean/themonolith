#!/bin/sh
# I02 tree-pin, slice B: the pin document (I02-AC-1), the Makefile pins and targets, and the
# tree-accept workflow wiring (plumbing for I02-AC-3 and I02-AC-5, which are recorded runs).
# Offline: greps files, reads `make -n` output, parses the workflow; never runs oras or a container.
# Runs in commit-less copies: paths come from this file.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
DOC="$ROOT/docs/tree-pin.md"
MK="$ROOT/Makefile"
WF="$ROOT/.github/workflows/tree-accept.yml"
COMMIT=6e88ed01f3e97de8710efe1c333808dfbd05bf32
DIGEST=sha256:b01bbe7a886fa869a4018a5f711e11fae8fb783b30878216b0f8f408ad2a70bd
REV=6622796b6162d6f41b6556041027f19e7964028e
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
ck() { l=$1; shift; if "$@" >/dev/null 2>&1; then pass "$l"; else fail "$l"; fi; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tree-pin.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM

# ---- I02-AC-1: docs/tree-pin.md ----
if [ -f "$DOC" ]; then
	pass "I02-AC-1 docs/tree-pin.md exists"
	ck "I02-AC-1 exactly one line is a bare 40-hex commit" sh -c '[ "$(grep -cE "^[0-9a-f]{40}\$" "$1")" -eq 1 ]' _ "$DOC"
	ck "I02-AC-1 that line equals TREE_COMMIT in the Makefile" sh -c '
		l=$(grep -E "^[0-9a-f]{40}\$" "$1"); m=$(sed -n "s/^TREE_COMMIT[[:space:]]*:\{0,1\}=[[:space:]]*//p" "$2" | tr -d " \t")
		[ -n "$l" ] && [ "$l" = "$m" ]' _ "$DOC" "$MK"
	ck "I02-AC-1 names the REPO_REVISIONS value $REV" grep -q "$REV" "$DOC"
	ck "I02-AC-1 names REPO_REVISIONS" grep -q 'REPO_REVISIONS' "$DOC"
	ck "I02-AC-1 names the matched count (152 of 152)" grep -Eq '152 of 152' "$DOC"
	ck "I02-AC-1 gives the signature result" grep -Eiq 'signature.*(good|key-missing|unsigned|bad)' "$DOC"
	ck "I02-AC-1 names TREE_DIGEST and its value" sh -c 'grep -q TREE_DIGEST "$1" && grep -q "$2" "$1"' _ "$DOC" "$DIGEST"
else
	for c in "exists" "exactly one line is a bare 40-hex commit" "that line equals TREE_COMMIT in the Makefile" \
		"names the REPO_REVISIONS value $REV" "names the matched count (152 of 152)" "gives the signature result" \
		"names TREE_DIGEST and its value"; do fail "I02-AC-1 docs/tree-pin.md: $c"; done
fi

# ---- ruling 1: the pins in the Makefile ----
ck "I02 Makefile: TREE_COMMIT := $COMMIT" grep -Eq "^TREE_COMMIT[[:space:]]*:=[[:space:]]*$COMMIT[[:space:]]*\$" "$MK"
ck "I02 Makefile: TREE_DIGEST := $DIGEST" grep -Eq "^TREE_DIGEST[[:space:]]*:=[[:space:]]*$DIGEST[[:space:]]*\$" "$MK"
ck "I02 Makefile: TREE_REF built from \$(REGISTRY)" grep -Eq '^TREE_REF[[:space:]]*:=[[:space:]]*\$\(REGISTRY\)/gentoo-tree[[:space:]]*$' "$MK"

# ---- ruling 5: Make targets (make -n) ----
(cd "$ROOT" && make -n sync-portage) >"$tmp/sync.out" 2>&1
(cd "$ROOT" && make -n sync-portage TREE_DIR=/tmp/other-tree) >"$tmp/sync2.out" 2>&1
(cd "$ROOT" && make -n seed-tree) >"$tmp/seed.out" 2>&1
(cd "$ROOT" && make -n tree-check) >"$tmp/check.out" 2>&1
(cd "$ROOT" && make -n tree-restore-offline) >"$tmp/off.out" 2>&1
ck "I02-AC-5 make sync-portage runs scripts/sync-portage.sh through toolbox/run" grep -Eq 'toolbox/run.*scripts/sync-portage\.sh' "$tmp/sync.out"
ck "I02-AC-5 sync-portage passes TREE_COMMIT, TREE_DIGEST and the ref" \
	sh -c 'grep -q "$2" "$1" && grep -q "$3" "$1" && grep -q "ghcr.io/tuckermclean/themonolith" "$1"' _ "$tmp/sync.out" "$COMMIT" "$DIGEST"
ck "I02-AC-5 sync-portage restores into output/repos/gentoo by default" grep -q 'output/repos/gentoo' "$tmp/sync.out"
ck "I02-AC-5 TREE_DIR overrides the target directory" sh -c 'grep -q /tmp/other-tree "$1" && ! grep -q output/repos/gentoo "$1"' _ "$tmp/sync2.out"
ck "I02-AC-3 make seed-tree runs scripts/seed-tree.sh with TREE_COMMIT through toolbox/run" \
	grep -Eq "toolbox/run.*scripts/seed-tree\.sh.*$COMMIT|toolbox/run.*scripts/seed-tree\.sh" "$tmp/seed.out"
ck "I02-AC-3 seed-tree passes the commit and REGISTRY" sh -c 'grep -q "$2" "$1" && grep -q "ghcr.io/tuckermclean/themonolith" "$1"' _ "$tmp/seed.out" "$COMMIT"
ck "I02-AC-3 make tree-check fetches the manifest of TREE_REF:TREE_COMMIT" \
	sh -c 'grep -q "manifest fetch" "$1" && grep -q "gentoo-tree:$2" "$1"' _ "$tmp/check.out" "$COMMIT"
ck "I02-AC-3 tree-check compares with TREE_DIGEST" grep -q "$DIGEST" "$tmp/check.out"
ck "I02-AC-3 tree-check compares file counts (wc -l)" grep -q 'wc -l' "$tmp/check.out"
ck "I02-AC-5 make tree-restore-offline extracts in a --network none run" grep -Eq 'toolbox/run.*--network none' "$tmp/off.out"
ck "I02-AC-5 tree-restore-offline compares with the archive (wc -l or cmp or diff)" grep -Eq 'wc -l|cmp |diff ' "$tmp/off.out"

# ---- ruling 6: .github/workflows/tree-accept.yml ----
if [ ! -f "$WF" ]; then
	fail "I02 tree-accept.yml exists"
	for c in "workflow_dispatch only" "permissions packages: write, contents: read" "no secret but GITHUB_TOKEN" \
		"seed step runs make seed-tree under an if" "steps call make tree-check then make tree-restore-offline" \
		"toolbox/ci lint passes"; do fail "I02-AC-5 tree-accept.yml: $c"; done
else
	pass "I02 tree-accept.yml exists"
	python3 - "$WF" <<'PY'
import sys
import yaml
doc = yaml.safe_load(open(sys.argv[1]))
bad = 0
def chk(l, c):
    global bad
    print(("PASS: " if c else "FAIL: ") + "I02-AC-5 tree-accept.yml: " + l)
    bad += (not c)
on = doc.get(True, doc.get("on"))
chk("workflow_dispatch only", (on == "workflow_dispatch") or (isinstance(on, list) and on == ["workflow_dispatch"])
    or (isinstance(on, dict) and list(on) == ["workflow_dispatch"]))
perm = doc.get("permissions") or {}
jobs = doc.get("jobs") or {}
perms = [perm] + [(j or {}).get("permissions") or {} for j in jobs.values()]
chk("permissions packages: write and contents: read",
    any(p.get("packages") == "write" and p.get("contents") == "read" for p in perms if isinstance(p, dict)))
steps = [s for j in jobs.values() for s in (j or {}).get("steps") or []]
runs = [(s.get("run") or "").strip() for s in steps]
text = open(sys.argv[1]).read()
import re
secrets = set(re.findall(r"secrets\.([A-Za-z0-9_]+)", text))
chk("no secret but GITHUB_TOKEN", secrets <= {"GITHUB_TOKEN"})
seed = [s for s in steps if (s.get("run") or "").strip().startswith("make seed-tree")]
chk("seed step runs make seed-tree under an if (only when the tag is absent)", len(seed) == 1 and bool(seed[0].get("if")))
def idx(t):
    for i, r in enumerate(runs):
        if re.match(r"make\s+" + t + r"(\s|$)", r): return i
    return -1
a, b = idx("tree-check"), idx("tree-restore-offline")
chk("a step runs make tree-check", a >= 0)
chk("a step runs make tree-restore-offline after it", b > a >= 0)
sys.exit(1 if bad else 0)
PY
	[ $? -eq 0 ] || FAILS=$((FAILS + 1))
	ck "I02-AC-5 tree-accept.yml toolbox/ci lint passes" sh -c 'cd "$1" && python3 toolbox/ci lint tree-accept.yml' _ "$ROOT"
fi

echo "failures: $FAILS"
[ "$FAILS" -eq 0 ]
