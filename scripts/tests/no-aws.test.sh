#!/bin/sh
# I01 off-s3: no AWS/S3 names in tracked files, one REGISTRY assignment, no secret but GITHUB_TOKEN.
# Criteria: I01-AC-1, I01-AC-2, I01-AC-3. Needs no network. Each check takes a root directory so the
# fixture cases run the same code as the real check. This file holds the pattern, so it is excluded.
set -u

here=$(cd "$(dirname "$0")" && pwd -P)
root=$(git -C "$here" rev-parse --show-toplevel) || { echo "FAIL: not in a git checkout"; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/no-aws.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

pattern='aws |aws-actions|AWS_|amazonaws|s3://|S3_BUCKET|s3-gc'
self=scripts/tests/no-aws.test.sh
want_registry=ghcr.io/tuckermclean/themonolith

# ---- checks: each prints one line per violation and returns non-zero if any ----
check_ac1() { # check_ac1 <root>
	(
		cd "$1" || exit 1
		git ls-files | while IFS= read -r f; do
			case $f in
			SPEC.md | nodes/* | docs/study/* | docs/reviews/* | docs/graph.yaml | docs/capabilities.md | \
				docs/first-release.md | docs/migration.tsv | scripts/tests/make-test.test.sh | "$self") continue ;;
			esac
			[ -f "$f" ] || continue
			grep -InE -e "$pattern" -- "$f" | sed "s|^|$f:|"
		done
	) >"$tmp/out.$$"
	cat "$tmp/out.$$"
	[ ! -s "$tmp/out.$$" ]
}

check_ac2() { # check_ac2 <root>
	bad=0
	n=0
	if [ -f "$1/Makefile" ]; then
		n=$(grep -cE '^[[:space:]]*REGISTRY[[:space:]]*(:=|\?=|=)' "$1/Makefile")
	fi
	if [ "$n" -ne 1 ]; then echo "Makefile: $n assignments of REGISTRY, want 1"; bad=1
	else
		v=$(grep -E '^[[:space:]]*REGISTRY[[:space:]]*(:=|\?=|=)' "$1/Makefile" |
			sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$//')
		[ "$v" = "$want_registry" ] || { echo "Makefile: REGISTRY is '$v', want $want_registry"; bad=1; }
	fi
	for w in "$1"/.github/workflows/*.yml; do
		[ -f "$w" ] || continue
		grep -qE 'REGISTRY|ghcr\.io' "$w" || continue
		c=$(awk '
			/^[[:space:]]*REGISTRY:/ {
				match($0, /^[[:space:]]*/); ind = RLENGTH; cnt++
				ok = 0
				for (i = NR - 1; i >= 1; i--) {
					l = line[i]
					if (l ~ /^[[:space:]]*(#|$)/) continue
					match(l, /^[[:space:]]*/)
					if (RLENGTH < ind) { if (l ~ /^[[:space:]]*env:[[:space:]]*$/) ok = 1; break }
				}
				good += ok
			}
			{ line[NR] = $0 }
			END { print cnt + 0, good + 0 }' "$w")
		if [ "$c" != "1 1" ]; then echo "${w#"$1"/}: want exactly one REGISTRY: key in an env: map (cnt good: $c)"; bad=1; fi
	done
	(cd "$1" && git ls-files scripts 2>/dev/null) | while IFS= read -r f; do
		[ "$f" = "$self" ] && continue
		[ -f "$1/$f" ] || continue
		grep -In 'ghcr\.io/' "$1/$f" | sed "s|^|$f:|"
	done >"$tmp/ghcr.$$"
	if [ -s "$tmp/ghcr.$$" ]; then cat "$tmp/ghcr.$$"; bad=1; fi
	return $bad
}

check_ac3() { # check_ac3 <root>
	[ -d "$1/.github/workflows" ] || return 0
	(cd "$1" && grep -rnoE 'secrets\.[A-Za-z_0-9]*' .github/workflows) | grep -v 'secrets\.GITHUB_TOKEN$' >"$tmp/sec.$$"
	cat "$tmp/sec.$$"
	[ ! -s "$tmp/sec.$$" ]
}

mkrepo() { # mkrepo <name> -> empty git repo path
	d=$tmp/$1
	mkdir -p "$d/scripts" "$d/.github/workflows"
	git init -q "$d"
	echo "$d"
}
commit_all() { git -C "$1" add -A; }
good_makefile() { printf 'REGISTRY ?= %s\n\nall:\n\t@true\n' "$want_registry" >"$1/Makefile"; }
good_workflow() { printf 'name: x\non: push\nenv:\n  REGISTRY: %s\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ${{ secrets.GITHUB_TOKEN }}\n' "$want_registry" >"$1/.github/workflows/a.yml"; }

# expect <label> <pass|fail> <function> <root>
expect() {
	label=$1; want=$2; fn=$3; r=$4
	out=$($fn "$r" 2>&1); rc=$?
	if [ "$want" = pass ]; then
		if [ $rc -eq 0 ]; then pass "$label"; else fail "$label"; printf '%s\n' "$out" | sed 's/^/  /'; fi
	else
		if [ $rc -ne 0 ]; then pass "$label"; else fail "$label (check accepted a bad fixture)"; fi
	fi
}

# ---- I01-AC-1 ----
r=$(mkrepo ac1-clean); good_makefile "$r"; echo "plain text" >"$r/README.md"; commit_all "$r"
expect "I01-AC-1 fixture without a match passes" pass check_ac1 "$r"
for s in 'uses: aws-actions/configure@v1' 'aws s3 cp x s3://bucket/y' 'export AWS_REGION=x' 'https://a.amazonaws.com/' 'S3_BUCKET=b' 'run s3-gc now'; do
	r=$(mkrepo ac1-bad); echo "$s" >"$r/scripts/x.sh"; commit_all "$r"
	expect "I01-AC-1 fixture file containing '$s' fails" fail check_ac1 "$r"
	rm -rf "$r"
done
r=$(mkrepo ac1-excl); mkdir -p "$r/nodes" "$r/docs/study"; echo "s3://x" >"$r/nodes/n.md"; echo "AWS_X" >"$r/SPEC.md"
echo "s3-gc" >"$r/docs/migration.tsv"; echo "S3_BUCKET" >"$r/docs/study/a.md"; commit_all "$r"
expect "I01-AC-1 excluded spec paths are not reported" pass check_ac1 "$r"
echo "aws " >"$r/untracked-ok.txt"
expect "I01-AC-1 untracked files are not checked" pass check_ac1 "$r"
if out=$(check_ac1 "$root" 2>&1); then pass "I01-AC-1 no tracked file outside the spec paths matches"
else fail "I01-AC-1 tracked files match the AWS/S3 pattern:"; printf '%s\n' "$out" | sed 's/^/  /'; fi

# ---- I01-AC-2 ----
r=$(mkrepo ac2-ok); good_makefile "$r"; good_workflow "$r"; echo "echo hi" >"$r/scripts/a.sh"; commit_all "$r"
expect "I01-AC-2 fixture with one assignment, env key and no script URL passes" pass check_ac2 "$r"
r=$(mkrepo ac2-two); good_makefile "$r"; echo 'REGISTRY := ghcr.io/tuckermclean/themonolith' >>"$r/Makefile"; commit_all "$r"
expect "I01-AC-2 two Makefile assignments fail" fail check_ac2 "$r"
r=$(mkrepo ac2-none); printf 'all:\n\t@true\n' >"$r/Makefile"; commit_all "$r"
expect "I01-AC-2 no Makefile assignment fails" fail check_ac2 "$r"
r=$(mkrepo ac2-val); printf 'REGISTRY = ghcr.io/other/thing\n' >"$r/Makefile"; commit_all "$r"
expect "I01-AC-2 wrong default value fails" fail check_ac2 "$r"
r=$(mkrepo ac2-script); good_makefile "$r"; echo 'oras pull ghcr.io/x/y' >"$r/scripts/b.sh"; commit_all "$r"
expect "I01-AC-2 script containing ghcr.io/ fails" fail check_ac2 "$r"
r=$(mkrepo ac2-wf); good_makefile "$r"
printf 'name: x\non: push\njobs:\n  a:\n    runs-on: u\n    steps:\n      - run: oras pull ghcr.io/x/y\n' >"$r/.github/workflows/a.yml"; commit_all "$r"
expect "I01-AC-2 workflow naming the registry without REGISTRY env fails" fail check_ac2 "$r"
r=$(mkrepo ac2-wf2); good_makefile "$r"; good_workflow "$r"
printf '  other:\n    runs-on: u\n    env:\n      REGISTRY: %s\n' "$want_registry" >>"$r/.github/workflows/a.yml"; commit_all "$r"
expect "I01-AC-2 workflow with two REGISTRY keys fails" fail check_ac2 "$r"
if out=$(check_ac2 "$root" 2>&1); then pass "I01-AC-2 REGISTRY assigned once in Makefile and workflow env, no ghcr.io/ in scripts"
else fail "I01-AC-2 registry location rules broken:"; printf '%s\n' "$out" | sed 's/^/  /'; fi

# ---- I01-AC-3 ----
r=$(mkrepo ac3-ok); good_workflow "$r"; commit_all "$r"
expect "I01-AC-3 fixture using only secrets.GITHUB_TOKEN passes" pass check_ac3 "$r"
r=$(mkrepo ac3-bad); good_workflow "$r"; echo '      - run: echo ${{ secrets.AWS_ACCESS_KEY_ID }}' >>"$r/.github/workflows/a.yml"; commit_all "$r"
expect "I01-AC-3 fixture workflow using another secret fails" fail check_ac3 "$r"
if out=$(check_ac3 "$root" 2>&1); then pass "I01-AC-3 no workflow requires a secret other than GITHUB_TOKEN"
else fail "I01-AC-3 workflows use other secrets:"; printf '%s\n' "$out" | sed 's/^/  /'; fi

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all no-aws checks"
