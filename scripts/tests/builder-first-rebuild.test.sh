#!/bin/sh
# M03 builder-first-rebuild: docs/builder-manifests/{rc1,rebuilt}.txt and docs/builder-rebuild.md.
# Criterion: M03-AC-3 (M03-AC-1, -2, -4 are recorded workflow runs). Offline; no git history, no out/.
#
# Format the check enforces on docs/builder-rebuild.md (M03-AC-3):
#  - Differing lines: `diff rc1.txt rebuilt.txt` gives the differing lines (the `<` and `>` lines, with the
#    marker and leading/trailing whitespace removed; blank ones ignored). Each such text must appear, as a
#    fixed string (grep -F), in a line of the doc that also carries a cause. Use a table row:
#        | `<differing line, trimmed>` | <cause> |
#    i.e. after the text comes a `|` and then a non-empty cell. A text found only on lines with no cause fails.
#  - Empty diff: the doc states it with the sentence
#        The diff between rc1.txt and rebuilt.txt is empty.
#    (that exact sentence, on one line). With a non-empty diff the sentence is not needed.
# The main checks run on the real files; the scratch cases (under a folder named M03) test both branches.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
MAN="$ROOT/docs/builder-manifests"
DOC="$ROOT/docs/builder-rebuild.md"
EMPTY='The diff between rc1.txt and rebuilt.txt is empty.'
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/builder-first-rebuild.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
W="$tmp/M03"; mkdir -p "$W"

# verify <rc1> <rebuilt> <doc>: returns 0 when every differing line is explained; reasons go to $W/reason.
verify() {
	: > "$W/reason"
	diff "$1" "$2" > "$W/diff.out" 2>/dev/null; rc=$?
	if [ "$rc" -gt 1 ]; then echo "diff failed" >> "$W/reason"; return 1; fi
	grep '^[<>]' "$W/diff.out" | sed 's/^[<>][[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u > "$W/lines" || : > "$W/lines"
	if [ ! -s "$W/lines" ]; then
		if grep -qF -- "$EMPTY" "$3"; then return 0; fi
		echo "empty diff is not stated ('$EMPTY')" >> "$W/reason"; return 1
	fi
	bad=0
	while IFS= read -r l; do
		if ! grep -qF -- "$l" "$3"; then echo "not in the doc: $l" >> "$W/reason"; bad=1; continue; fi
		# some doc line holds the text followed by '|' and a non-empty cell (the cause)
		if ! awk -v t="$l" '{ i = index($0, t); if (i) { r = substr($0, i + length(t));
			if (r ~ /^[^|]*\|[[:space:]]*[^|[:space:]]/) ok = 1 } } END { exit !ok }' "$3"; then
			echo "no cause for: $l" >> "$W/reason"; bad=1
		fi
	done < "$W/lines"
	return $bad
}

# ---------------------------------------------------------------- M03-AC-3 real files
have=1
for f in "$MAN/rc1.txt" "$MAN/rebuilt.txt" "$DOC"; do
	if [ -f "$f" ]; then pass "M03-AC-3 ${f#"$ROOT"/} exists"
	else fail "M03-AC-3 ${f#"$ROOT"/} is missing"; have=0; fi
done
if [ "$have" -eq 1 ]; then
	if verify "$MAN/rc1.txt" "$MAN/rebuilt.txt" "$DOC"; then
		pass "M03-AC-3 every differing line of rc1.txt/rebuilt.txt is in builder-rebuild.md with a cause (or the empty diff is stated)"
	else
		fail "M03-AC-3 builder-rebuild.md does not explain the diff: $(head -n 5 "$W/reason" | tr '\n' ';')"
	fi
else
	fail "M03-AC-3 diff not checked: a manifest or builder-rebuild.md is missing"
fi

# ---------------------------------------------------------------- scratch cases (both branches)
S="$W/s"; mkdir -p "$S"
printf '%s\n' 'sys-devel/gcc-15.3.1' '  "Created": "A"' 'x' > "$S/a.txt"
printf '%s\n' 'sys-devel/gcc-15.3.2' '  "Created": "B"' 'x' > "$S/b.txt"
{ echo '| `sys-devel/gcc-15.3.1` | removed |'; echo '| `sys-devel/gcc-15.3.2` | rebuilt from the same tree |'
  echo '| `"Created": "A"` | docker commit time |'; echo '| `"Created": "B"` | docker commit time |'; } > "$S/good.md"
if verify "$S/a.txt" "$S/b.txt" "$S/good.md"; then pass "M03-AC-3 scratch: differing lines with causes accepted"
else fail "M03-AC-3 scratch: differing lines with causes rejected: $(cat "$W/reason")"; fi
grep -v 'gcc-15.3.2' "$S/good.md" > "$S/missing.md"
if verify "$S/a.txt" "$S/b.txt" "$S/missing.md"; then fail "M03-AC-3 scratch: a differing line absent from the doc accepted"
else pass "M03-AC-3 scratch: a differing line absent from the doc rejected"; fi
sed 's/| rebuilt from the same tree |/|  |/' "$S/good.md" > "$S/nocause.md"
if verify "$S/a.txt" "$S/b.txt" "$S/nocause.md"; then fail "M03-AC-3 scratch: a differing line without a cause accepted"
else pass "M03-AC-3 scratch: a differing line without a cause rejected"; fi
cp "$S/a.txt" "$S/same.txt"
printf 'Intro.\n%s\n' "$EMPTY" > "$S/empty.md"
if verify "$S/a.txt" "$S/same.txt" "$S/empty.md"; then pass "M03-AC-3 scratch: empty diff stated is accepted"
else fail "M03-AC-3 scratch: empty diff stated rejected: $(cat "$W/reason")"; fi
printf 'Intro.\n' > "$S/silent.md"
if verify "$S/a.txt" "$S/same.txt" "$S/silent.md"; then fail "M03-AC-3 scratch: empty diff not stated accepted"
else pass "M03-AC-3 scratch: empty diff not stated rejected"; fi

if [ "$FAILS" -ne 0 ]; then echo "FAIL: $FAILS check(s) failed"; exit 1; fi
echo "PASS: all builder-first-rebuild checks"
