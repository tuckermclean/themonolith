#!/bin/sh
# F01 make-test: `make test`, its fixtures, workflow pins, .gitignore and the AGENTS.md guide.
# Criteria: F01-AC-1 .. F01-AC-7. Needs no network. Runs inside the toolbox (TOOLBOX=1), so the
# nested `make` in a fixture tree runs commands directly.
# Recursion guard: fixture trees never contain this file, so `make test` there does not re-enter it.
# Listed extra paths: `make test SHELL_EXTRA=<path>...` adds paths to the bash -n and shellcheck lists.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES

here=$(cd "$(dirname "$0")" && pwd -P)
root=$(git -C "$here" rev-parse --show-toplevel) || { echo "FAIL: not in a git checkout"; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/make-test.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
check() { # check <label> <command...>
	l=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$l"; else fail "$l"; fi
}
runmake() { # runmake <dir> <log> <make args...>; sets rc
	d=$1; lg=$2; shift 2
	(cd "$d" && timeout 900 make "$@") >"$lg" 2>&1
	rc=$?
}

# ---- pristine fixture tree: a git repo with this checkout's files, minus this test ----
pristine=$tmp/pristine
mkdir -p "$pristine"
(
	cd "$root" || exit 1
	git ls-files -co --exclude-standard | while IFS= read -r f; do
		case $f in out/*|.claude/*|scripts/tests/make-test.test.sh) continue ;; esac
		[ -e "$f" ] && echo "$f"
	done >"$tmp/files"
	tar -cf - -T "$tmp/files" | tar -xf - -C "$pristine"
)
(cd "$pristine" && git init -q . && git add -A) >/dev/null 2>&1
fixture() { # fixture <name> -> prints the path of a fresh copy
	cp -a "$pristine" "$tmp/$1" && echo "$tmp/$1"
}

# ---- F01-AC-1: make test depends on test-lint and test-unit, names the eight checks, exits 0 ----
(cd "$pristine" && make -qp test 2>/dev/null) | grep -E '^test:' >"$tmp/deps"
if grep -q 'test-lint' "$tmp/deps" && grep -q 'test-unit' "$tmp/deps"; then
	pass "F01-AC-1 test depends on test-lint and test-unit"
else
	fail "F01-AC-1 test depends on test-lint and test-unit"
fi
(cd "$pristine" && make -n test-lint test-unit 2>/dev/null) | grep -q -e '--network none' \
	&& pass "F01-AC-1 test-lint and test-unit run with --network none" \
	|| fail "F01-AC-1 test-lint and test-unit run with --network none"
runmake "$pristine" "$tmp/ac1.log" test-lint test-unit
if [ "$rc" -eq 0 ]; then pass "F01-AC-1 make test-lint test-unit exits 0"; else fail "F01-AC-1 make test-lint test-unit exits 0 (rc=$rc)"; fi
for n in 'Shell script syntax (bash -n)' 'Python syntax (py_compile)' 'YAML well-formedness' \
	'Workflow lint (actionlint)' 'Shell lint (shellcheck, errors only)' \
	'Migration ledger (check-migration.py)' 'Workflow rules (toolbox/ci lint)' \
	'Shell unit tests (scripts/tests/*.sh)'; do
	if grep -qF "$n" "$tmp/ac1.log"; then pass "F01-AC-1 output names: $n"; else fail "F01-AC-1 output names: $n"; fi
done

# ---- F01-AC-2: one defect per fixture, make test exits non-zero ----
defect() { # defect <name> <marker> ; the fixture dir is $fx, the defect already applied by caller
	if [ -n "${3:-}" ]; then runmake "$fx" "$tmp/$1.log" test-lint test-unit "$3"; else runmake "$fx" "$tmp/$1.log" test-lint test-unit; fi
	if [ "$rc" -ne 0 ]; then pass "F01-AC-2 $1: make test-lint test-unit exits non-zero"; else fail "F01-AC-2 $1: make test-lint test-unit exits non-zero"; fi
	if grep -qF -- "$2" "$tmp/$1.log"; then pass "F01-AC-2 $1: output shows '$2'"; else fail "F01-AC-2 $1: output shows '$2'"; fi
}

fx=$(fixture sh-syntax)
mkdir -p "$fx/scripts"; printf '#!/bin/sh\nif then fi (\n' >"$fx/scripts/bad-syntax.sh"
defect sh-syntax bad-syntax.sh

fx=$(fixture py-syntax)
mkdir -p "$fx/scripts"; printf 'def (:\n' >"$fx/scripts/bad_syntax.py"
defect py-syntax bad_syntax.py

fx=$(fixture yaml)
mkdir -p "$fx/configs/x"; printf 'a: [1, 2\nb: {\n' >"$fx/configs/x/bad.yaml"
defect yaml bad.yaml

fx=$(fixture shellcheck)
mkdir -p "$fx/scripts"; printf '#!/bin/bash\nlocal x=1\n' >"$fx/scripts/sc-error.sh"
defect shellcheck sc-error.sh

fx=$(fixture failing-test)
mkdir -p "$fx/scripts/tests"; printf '#!/bin/sh\necho "FAIL: planted"\nexit 1\n' >"$fx/scripts/tests/planted-fail.test.sh"
defect failing-test planted-fail.test.sh

fx=$(fixture missing-path)
defect missing-path no/such/file SHELL_EXTRA=no/such/file

fx=$(fixture ledger-row)
grep -v '^LICENSE	' "$pristine/docs/migration.tsv" >"$fx/docs/migration.tsv"
defect ledger-row PROBLEM

fx=$(fixture ledger-mode)
chmod +x "$fx/LICENSE"; (cd "$fx" && git add -A) >/dev/null 2>&1
defect ledger-mode PROBLEM

fx=$(fixture ledger-blob)
echo "changed" >>"$fx/LICENSE"; (cd "$fx" && git add -A) >/dev/null 2>&1
defect ledger-blob PROBLEM

fx=$(fixture expr-in-run)
mkdir -p "$fx/.github/workflows"
cat >"$fx/.github/workflows/expr.yml" <<'YML'
name: expr
on: push
jobs:
  j:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
      - run: make test-lint ${{ github.sha }}
YML
(cd "$fx" && git add -A) >/dev/null 2>&1
defect expr-in-run 'expression inside run:'

# ---- F01-AC-3: pr-validate.yml's only run: step is `make test-lint test-unit` ----
wf=$root/.github/workflows/pr-validate.yml
if [ -f "$wf" ]; then
	python3 -I - "$wf" >"$tmp/steps" 2>&1 <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
runs = [s["run"].strip() for j in doc["jobs"].values() for s in j.get("steps", []) if "run" in s]
print("\n".join(runs))
PY
	case $(cat "$tmp/steps") in
	*"
"*)
		fail "F01-AC-3 pr-validate.yml's run: steps are a single line (ruling 4)" ;;
	"make test-lint test-unit" | "make test-lint test-unit "*)
		pass "F01-AC-3 pr-validate.yml's only run: step is 'make test-lint test-unit' (later targets allowed)" ;;
	*)
		fail "F01-AC-3 pr-validate.yml's only run: step is 'make test-lint test-unit' (later targets allowed)" ;;
	esac
else
	fail "F01-AC-3 .github/workflows/pr-validate.yml exists"
fi

# ---- F01-AC-4: toolbox/ci lint and check-migration.py exit 0 inside make test-lint ----
runmake "$pristine" "$tmp/ac4.log" test-lint
if [ "$rc" -eq 0 ]; then pass "F01-AC-4 make test-lint exits 0"; else fail "F01-AC-4 make test-lint exits 0 (rc=$rc)"; fi
grep -qE 'toolbox/ci lint: [0-9]+ workflow\(s\), 0 problem\(s\)' "$tmp/ac4.log" \
	&& pass "F01-AC-4 toolbox/ci lint ran and found 0 problems inside test-lint" \
	|| fail "F01-AC-4 toolbox/ci lint ran and found 0 problems inside test-lint"
grep -q 'PROBLEMS 0' "$tmp/ac4.log" \
	&& pass "F01-AC-4 check-migration.py ran and found 0 problems inside test-lint" \
	|| fail "F01-AC-4 check-migration.py ran and found 0 problems inside test-lint"
(cd "$root" && MONOLITH_WORKFLOWS="$root/.github/workflows" python3 -I toolbox/ci lint .github/workflows/pr-validate.yml) >"$tmp/cilint" 2>&1
if [ -f "$wf" ] && grep -q ' 0 problem' "$tmp/cilint"; then
	pass "F01-AC-4 toolbox/ci lint covers pr-validate.yml with 0 problems"
else
	fail "F01-AC-4 toolbox/ci lint covers pr-validate.yml with 0 problems"
fi

# ---- F01-AC-5: pinned actions, pinned raw URLs, dependabot and CODEOWNERS ----
hex40='[0-9a-f]{40}'
bad=0; n=0
for f in "$root"/.github/workflows/*.yml; do
	[ -f "$f" ] || continue
	n=$((n + 1))
	grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$f" | sed -E 's/^[^:]*uses:[[:space:]]*//; s/[[:space:]]*#.*$//; s/["'\'']//g' | while IFS= read -r u; do
		case $u in ./*) continue ;; esac
		printf '%s\n' "$u" | grep -Eq "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@ ]+)?@$hex40\$" || echo "$f: $u"
	done
done >"$tmp/unpinned"
[ "$n" -gt 0 ] && [ ! -s "$tmp/unpinned" ] \
	&& pass "F01-AC-5 every uses: is owner/repo@<40 hex> ($n workflow(s))" \
	|| fail "F01-AC-5 every uses: is owner/repo@<40 hex> ($n workflow(s)) $(cat "$tmp/unpinned" 2>/dev/null)"
for f in "$root"/.github/workflows/*.yml; do
	[ -f "$f" ] || continue
	grep -oE 'raw\.githubusercontent\.com/[^[:space:]"'\'')]*' "$f" | while IFS= read -r u; do
		ref=$(printf '%s' "$u" | cut -d/ -f4)
		printf '%s\n' "$ref" | grep -Eq "^$hex40\$" || echo "$f: $u"
	done
done >"$tmp/rawbad"
[ "$n" -gt 0 ] && [ ! -s "$tmp/rawbad" ] \
	&& pass "F01-AC-5 no raw.githubusercontent.com URL with a ref that is not 40 hex" \
	|| fail "F01-AC-5 no raw.githubusercontent.com URL with a ref that is not 40 hex $(cat "$tmp/rawbad" 2>/dev/null)"
db=$root/.github/dependabot.yml
if [ -f "$db" ] && grep -q 'github-actions' "$db" && grep -q 'weekly' "$db"; then
	pass "F01-AC-5 .github/dependabot.yml: github-actions, weekly"
else
	fail "F01-AC-5 .github/dependabot.yml: github-actions, weekly"
fi
co=$root/.github/CODEOWNERS
for p in '.github/**' 'SPEC.md' 'docs/graph.yaml' 'docs/migration.tsv' 'configs/attestation/' 'Dockerfile'; do
	if [ -f "$co" ] && grep -Eq "^/?$(printf '%s' "$p" | sed 's/[.*]/\\&/g')[[:space:]]+@" "$co"; then
		pass "F01-AC-5 CODEOWNERS routes $p"
	else
		fail "F01-AC-5 CODEOWNERS routes $p"
	fi
done

# ---- F01-AC-6: .gitignore ----
ig=$tmp/ignore
mkdir -p "$ig/out" "$ig/output" "$ig/.claude"
[ -f "$root/.gitignore" ] && cp "$root/.gitignore" "$ig/.gitignore"
touch "$ig/out/x" "$ig/output/x" "$ig/.claude/settings.json"
(cd "$ig" && git init -q .) >/dev/null 2>&1
check "F01-AC-6 out/x is ignored" git -C "$ig" check-ignore -q out/x
check "F01-AC-6 output/x is ignored" git -C "$ig" check-ignore -q output/x
if [ -f "$root/.gitignore" ] && ! git -C "$ig" check-ignore -q .claude/settings.json; then
	pass "F01-AC-6 .claude/settings.json is not ignored"
else
	fail "F01-AC-6 .claude/settings.json is not ignored"
fi

# ---- F01-AC-7: the predecessor's guide below this repository's section ----
# Recorded: sha256 of b9f533b:AGENTS.md with lines 76-91, 188-204 and 223-228 deleted and, on line 135,
# `stale S3 binpkg` replaced by `stale binpkg` (195 lines):
#   git show b9f533b:AGENTS.md | sed -e '76,91d;188,204d;223,228d' -e '135s/stale S3 binpkg/stale binpkg/'
want=88398146cb529adab9b2d22486c5a53c5d385f7444f455309dc3b8e9f1ea3bb0
sed -n '/^# The Monolith — Agent Working Guide$/,$p' "$root/AGENTS.md" >"$tmp/guide"
got=$(sha256sum <"$tmp/guide" | cut -d' ' -f1)
if [ -s "$tmp/guide" ] && [ "$got" = "$want" ]; then
	pass "F01-AC-7 AGENTS.md guide sha256 matches the recorded value"
else
	fail "F01-AC-7 AGENTS.md guide sha256 matches the recorded value (got $got)"
fi
if [ ! -s "$tmp/guide" ]; then
	fail "F01-AC-7 I01's pattern finds nothing in the guide (no guide section)"
elif grep -En 'aws |aws-actions|AWS_|amazonaws|s3://|S3_BUCKET|s3-gc' "$tmp/guide" >"$tmp/i01" 2>&1; then
	fail "F01-AC-7 I01's pattern finds nothing in AGENTS.md ($(head -n 1 "$tmp/i01"))"
else
	pass "F01-AC-7 I01's pattern finds nothing in AGENTS.md"
fi

echo
[ "$fails" -eq 0 ] && { echo "make-test: all passed"; exit 0; }
echo "make-test: $fails failed"
exit 1
