#!/bin/sh
# R03 all-static, static half of R03-AC-2: neither builder script installs the musl loader.
# Offline; plain grep over files; no git, no out/ (runs in commit-less copies).
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

for s in build-packages.sh extract-packages.sh; do
	f="$ROOT/scripts/$s"
	if [ ! -f "$f" ]; then
		fail "R03-AC-2 scripts/$s exists"
		fail "R03-AC-2 scripts/$s does not name ld-musl-i386"
		fail "R03-AC-2 scripts/$s does not copy the crossdev libc.so as a loader"
		fail "R03-AC-2 scripts/$s has no 'Dynamically-linked binaries will fail' warning"
		continue
	fi
	pass "R03-AC-2 scripts/$s exists"
	if grep -q 'ld-musl-i386' "$f"; then
		fail "R03-AC-2 scripts/$s does not name ld-musl-i386"
	else
		pass "R03-AC-2 scripts/$s does not name ld-musl-i386"
	fi
	if grep -Eq 'cp[[:space:]].*(MUSL_LIBC|usr/lib/libc\.so)' "$f" || grep -q 'MUSL_LIBC=' "$f"; then
		fail "R03-AC-2 scripts/$s does not copy the crossdev libc.so as a loader"
	else
		pass "R03-AC-2 scripts/$s does not copy the crossdev libc.so as a loader"
	fi
	if grep -q 'Dynamically-linked binaries will fail' "$f"; then
		fail "R03-AC-2 scripts/$s has no 'Dynamically-linked binaries will fail' warning"
	else
		pass "R03-AC-2 scripts/$s has no 'Dynamically-linked binaries will fail' warning"
	fi
done

# grep -r 'ld-musl-i386' scripts/ : nothing outside scripts/tests/ and scripts/static-audit.sh
hits=$(grep -rl 'ld-musl-i386' "$ROOT/scripts" 2>/dev/null \
	| grep -v "^$ROOT/scripts/tests/" | grep -v "^$ROOT/scripts/static-audit\.sh$")
if [ -z "$hits" ]; then
	pass "R03-AC-2 no ld-musl-i386 under scripts/ outside scripts/tests/ and static-audit.sh"
else
	for h in $hits; do fail "R03-AC-2 ld-musl-i386 named in ${h#"$ROOT"/}"; done
fi

echo "all-static: $FAILS failure(s)"
[ "$FAILS" -eq 0 ]
