#!/bin/sh
# P02 release-inputs: scripts/release-inputs.sh writes release-inputs.json (SPEC §6).
#   P02-AC-5  every SPEC §6 field is present and non-empty; a missing or empty input fails the script and names it
#
# Interface under test (chosen for P02, all inputs via environment, one positional argument):
#   sh scripts/release-inputs.sh <out.json>
#   Inputs (environment variables, all required, none may be empty); each becomes the JSON key of the same name:
#     VERSION  SOURCE_COMMIT  TREE_COMMIT  TREE_DIGEST  BUILDER_DIGEST  DISTFILES_DIGEST  SOURCE_DATE_EPOCH
#     XORRISO_VERSION  SQUASHFS_TOOLS_VERSION  GRUB_VERSION  SYSLINUX_VERSION  SYFT_VERSION  GRYPE_VERSION
#     QEMU_VERSION  GRYPE_DB_BUILT
#   On success: exit 0, <out.json> is a JSON object (written with jq) holding exactly those keys as strings.
#   On a missing or empty input: exit non-zero, stderr names the input, and no <out.json> is left behind.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../release-inputs.sh"
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIELDS="VERSION SOURCE_COMMIT TREE_COMMIT TREE_DIGEST BUILDER_DIGEST DISTFILES_DIGEST SOURCE_DATE_EPOCH XORRISO_VERSION SQUASHFS_TOOLS_VERSION GRUB_VERSION SYSLINUX_VERSION SYFT_VERSION GRYPE_VERSION QEMU_VERSION GRYPE_DB_BUILT"

value_of() {
	case $1 in
	VERSION) echo v0.2.0-rc1 ;;
	SOURCE_COMMIT) echo 0123456789abcdef0123456789abcdef01234567 ;;
	TREE_COMMIT) echo 89abcdef0123456789abcdef0123456789abcdef ;;
	TREE_DIGEST) echo sha256:1111111111111111111111111111111111111111111111111111111111111111 ;;
	BUILDER_DIGEST) echo sha256:2222222222222222222222222222222222222222222222222222222222222222 ;;
	DISTFILES_DIGEST) echo sha256:3333333333333333333333333333333333333333333333333333333333333333 ;;
	SOURCE_DATE_EPOCH) echo 1786489256 ;;
	XORRISO_VERSION) echo 1.5.8.pl02 ;;
	SQUASHFS_TOOLS_VERSION) echo 4.7.5 ;;
	GRUB_VERSION) echo 2.12 ;;
	SYSLINUX_VERSION) echo 6.04_pre1 ;;
	SYFT_VERSION) echo 1.20.0 ;;
	GRYPE_VERSION) echo 0.90.0 ;;
	QEMU_VERSION) echo 10.0.0 ;;
	GRYPE_DB_BUILT) echo 2026-08-11T05:00:00Z ;;
	esac
}

# run_script <out> <field-to-omit|""> <field-to-empty|""> ; sets rc, errfile
run_script() {
	out=$1; omit=$2; empty=$3
	errfile="$TMP/err"
	(
		for f in $FIELDS; do unset "$f"; done
		for f in $FIELDS; do
			[ "$f" = "$omit" ] && continue
			if [ "$f" = "$empty" ]; then export "$f="; else export "$f=$(value_of "$f")"; fi
		done
		sh "$SCRIPT" "$out"
	) >"$TMP/outlog" 2>"$errfile"
	rc=$?
}

# ---- full input: every field present and non-empty ----
rm -f "$TMP/ok.json"
run_script "$TMP/ok.json" "" ""
if [ "$rc" -eq 0 ] && [ -s "$TMP/ok.json" ]; then
	pass "P02-AC-5 full input exits 0 and writes the file"
else
	fail "P02-AC-5 full input exits 0 and writes the file (rc=$rc, $(head -c 200 "$errfile" 2>/dev/null))"
fi

if jq -e 'type == "object"' "$TMP/ok.json" >/dev/null 2>&1; then
	pass "P02-AC-5 output is a JSON object"
else
	fail "P02-AC-5 output is a JSON object"
fi

for f in $FIELDS; do
	want=$(value_of "$f")
	got=$(jq -r --arg k "$f" '.[$k] // empty' "$TMP/ok.json" 2>/dev/null)
	if [ -n "$got" ] && [ "$got" = "$want" ]; then
		pass "P02-AC-5 field $f present, non-empty, carries the input"
	else
		fail "P02-AC-5 field $f present, non-empty, carries the input (got '$got')"
	fi
done

n=$(jq 'length' "$TMP/ok.json" 2>/dev/null || echo 0)
nf=$(echo $FIELDS | wc -w)
if [ "$n" = "$nf" ]; then
	pass "P02-AC-5 exactly the $nf SPEC §6 fields, nothing volatile added"
else
	fail "P02-AC-5 exactly the $nf SPEC §6 fields, nothing volatile added (has $n)"
fi

# ---- each missing and each empty input fails the script and names it ----
for f in $FIELDS; do
	for mode in missing empty; do
		out="$TMP/bad-$f-$mode.json"
		rm -f "$out"
		if [ $mode = missing ]; then run_script "$out" "$f" ""; else run_script "$out" "" "$f"; fi
		if [ "$rc" -ne 0 ] && grep -q "$f" "$errfile" && [ ! -e "$out" ]; then
			pass "P02-AC-5 $mode $f fails, names it, writes no file"
		else
			fail "P02-AC-5 $mode $f fails, names it, writes no file (rc=$rc, file=$([ -e "$out" ] && echo yes || echo no))"
		fi
	done
done

# ---- a whitespace-only input counts as empty ----
rm -f "$TMP/ws.json"
(
	for f in $FIELDS; do export "$f=$(value_of "$f")"; done
	export SYFT_VERSION="  "
	sh "$SCRIPT" "$TMP/ws.json"
) >/dev/null 2>"$TMP/err"
rc=$?
if [ "$rc" -ne 0 ] && grep -q SYFT_VERSION "$TMP/err"; then
	pass "P02-AC-5 whitespace-only SYFT_VERSION fails and names it"
else
	fail "P02-AC-5 whitespace-only SYFT_VERSION fails and names it (rc=$rc)"
fi

[ "$fails" -eq 0 ]
