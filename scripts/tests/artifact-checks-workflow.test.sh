#!/bin/sh
# O02 artifact-checks, slice B: the test-artifact Make target, the two workflows, the rc1 expected
# findings and the empty allowlist. Criteria: O02-AC-7 (static half: the files), O02-AC-8.
# Offline; reads `make -n` output and greps files; never runs the audit or a nested toolbox/run.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
WFD="$ROOT/.github/workflows"
EXP="$ROOT/configs/attestation/rc1-static-audit.expected"
ALLOW="$ROOT/configs/attestation/dynamic-allowlist.txt"
RC1=a96006596b13cc09fa951f54aadc0b816765d783e5d0e40895d7d0945edeb27a
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
ck() { # ck <label> <command...>
	l=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$l"; else fail "$l"; fi
}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/artifact-checks-wf.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM

# ---- O02-AC-8: Make ----
(cd "$ROOT" && make -n test) >"$tmp/test.out" 2>&1
(cd "$ROOT" && make -n test-artifact) >"$tmp/def.out" 2>&1
(cd "$ROOT" && make -n test-artifact ISO=output/other.iso) >"$tmp/own.out" 2>&1
ck "O02-AC-8 make -n test includes the test-artifact recipe (static-audit.sh)" grep -q 'static-audit\.sh' "$tmp/test.out"
# review 1, ruling 11: exported ROOTFS_DIR/OUTPUT_DIR (the predecessor builder's) must not steer the recipe
(cd "$ROOT" && ROOTFS_DIR=/rootfs-build OUTPUT_DIR=/output make -n test-artifact) >"$tmp/env.out" 2>&1
ck "O02-AC-8 (review 1, ruling 11) exported ROOTFS_DIR=/rootfs-build and OUTPUT_DIR=/output do not reach the recipe" \
	sh -c 'grep -q "static-audit\\.sh" "$1" && ! grep -Eq "(^|[^A-Za-z0-9_.-])/(rootfs-build|output)([^A-Za-z0-9_-]|\$)" "$1"' _ "$tmp/env.out"
ck "O02-AC-8 test-artifact runs static-audit.sh through toolbox/run" grep -Eq 'toolbox/run.*static-audit\.sh' "$tmp/def.out"
ck "O02-AC-8 test-artifact extracts the squashfs of the ISO" grep -Eq 'rootfs\.squashfs|unsquashfs' "$tmp/def.out"
ck "O02-AC-8 test-artifact with the default ISO runs fetch-iso first (curl/sha256 recipe precedes the audit)" \
	sh -c 'awk "/curl -fsSL/ {c=NR} /static-audit\\.sh/ && !a {a=NR} END {exit !(c && a && c < a)}" "$1"' _ "$tmp/def.out"
ck "O02-AC-8 test-artifact with an explicit ISO does not fetch" sh -c '! grep -q "curl -fsSL" "$1" && grep -q "static-audit\\.sh" "$1"' _ "$tmp/own.out"
ck "O02-AC-8 recipe computes the ISO sha256 and compares it with RC1_SHA256 ($RC1)" \
	sh -c 'grep -q sha256sum "$1" && grep -q "$2" "$1"' _ "$tmp/def.out" "$RC1"
ck "O02-AC-8 recipe has the strict branch (--strict, with the allowlist)" \
	sh -c 'grep -q -- "--strict" "$1" && grep -q "dynamic-allowlist\\.txt" "$1"' _ "$tmp/def.out"
ck "O02-AC-8 recipe has the rc1 branch (--no-allowlist vs rc1-static-audit.expected)" \
	sh -c 'grep -q -- "--no-allowlist" "$1" && grep -q "rc1-static-audit\\.expected" "$1"' _ "$tmp/def.out"
ck "O02-AC-8 recipe sorts the findings and strips comments" sh -c 'grep -q "sort" "$1" && grep -Eq "grep -v|sed" "$1"' _ "$tmp/def.out"

# ---- O02-AC-8: workflows ----
for w in artifact-checks artifact-checks-rc1; do
	f="$WFD/$w.yml"
	if [ ! -f "$f" ]; then fail "O02-AC-8 $w.yml exists"; continue; fi
	pass "O02-AC-8 $w.yml exists"
	ck "O02-AC-8 $w.yml has no apt-get" sh -c '! grep -q "apt-get" "$1"' _ "$f"
	ck "O02-AC-8 $w.yml has no pip/pip3" sh -c '! grep -Eq "pip3? " "$1"' _ "$f"
	ck "O02-AC-8 $w.yml has no uses: .../setup-*" sh -c '! grep -Eq "uses:.*/setup-" "$1"' _ "$f"
	ck "O02-AC-8 $w.yml check step runs make test-artifact" grep -Eq '^[[:space:]]*run:[[:space:]]*make([[:space:]].*)?[[:space:]]test-artifact' "$f"
done
ck "O02-AC-8 artifact-checks.yml is reusable (workflow_call)" sh -c 'grep -q "workflow_call" "$1"' _ "$WFD/artifact-checks.yml"
f="$WFD/artifact-checks-rc1.yml"
ck "O02-AC-8 rc1 workflow triggers on workflow_dispatch" grep -q 'workflow_dispatch' "$f"
ck "O02-AC-8 rc1 workflow triggers on pull_request" grep -q 'pull_request' "$f"
for p in scripts/static-audit.sh configs/attestation/dynamic-allowlist.txt configs/attestation/rc1-static-audit.expected \
	Makefile 'toolbox/\*\*' .github/workflows/artifact-checks.yml .github/workflows/artifact-checks-rc1.yml; do
	ck "O02-AC-8 rc1 workflow paths: $p" grep -Eq -- "^[[:space:]]*-[[:space:]]*${p}[[:space:]]*\$" "$f"
done
ck "O02-AC-8 rc1 workflow passes rc1's sha256" grep -q "$RC1" "$f"
ck "O02-AC-8 rc1 workflow passes rc1's URL" grep -q 'v0\.1\.0-rc1/themonolith-0\.1\.0-rc1\.iso' "$f"
ck "O02-AC-8 toolbox/ci lint passes both workflows" sh -c 'cd "$1" && python3 toolbox/ci lint artifact-checks.yml artifact-checks-rc1.yml' _ "$ROOT"

# ---- O02-AC-7 (static half): expected findings and the empty allowlist ----
PY='usr/bin/event_rpcgen.py
usr/lib/xcb-proto/xcbgen/__init__.py
usr/lib/xcb-proto/xcbgen/align.py
usr/lib/xcb-proto/xcbgen/error.py
usr/lib/xcb-proto/xcbgen/expr.py
usr/lib/xcb-proto/xcbgen/matcher.py
usr/lib/xcb-proto/xcbgen/state.py
usr/lib/xcb-proto/xcbgen/xtypes.py
usr/share/glib-2.0/gdb/glib_gdb.py
usr/share/glib-2.0/gdb/gobject_gdb.py
usr/share/gdb/auto-load/usr/lib/libglib-2.0.so.0.8800.3-gdb.py
usr/share/gdb/auto-load/usr/lib/libgobject-2.0.so.0.8800.3-gdb.py
usr/share/gdb/system-gdbinit/elinos.py
usr/share/gdb/system-gdbinit/wrs-linux.py'
if [ -f "$EXP" ]; then
	pass "O02-AC-7 rc1-static-audit.expected exists"
	grep -v '^[[:space:]]*#' "$EXP" | grep -v '^[[:space:]]*$' >"$tmp/lines"
	printf '%s\n' "$PY" | sed 's/^/FINDING python /' | sort >"$tmp/want"
	sed 's/[[:space:]]*#.*//' "$tmp/lines" | sort >"$tmp/got"
	ck "O02-AC-7 expected holds exactly the 14 rc1 python findings" cmp -s "$tmp/got" "$tmp/want"
	ck "O02-AC-7 expected has 14 finding lines" sh -c '[ "$(wc -l < "$1")" -eq 14 ]' _ "$tmp/lines"
	ck "O02-AC-7 every finding line is FINDING python <path> # D-no-python-on-target" \
		sh -c '! grep -Ev "^FINDING python [^ ]+[[:space:]]+# D-no-python-on-target[[:space:]]*\$" "$1" | grep -q .' _ "$tmp/lines"
else
	fail "O02-AC-7 rc1-static-audit.expected exists"
fi
if [ -f "$ALLOW" ]; then
	pass "O02-AC-7 dynamic-allowlist.txt exists"
	ck "O02-AC-7 allowlist has no entries (comments and blank lines only)" \
		sh -c '! grep -Ev "^[[:space:]]*(#.*)?\$" "$1" | grep -q .' _ "$ALLOW"
else
	fail "O02-AC-7 dynamic-allowlist.txt exists"
fi

echo "failures: $FAILS"
[ "$FAILS" -eq 0 ]
