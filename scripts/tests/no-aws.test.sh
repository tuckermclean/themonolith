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

pattern='(^|[^[:alnum:]_])aws |aws-actions|AWS_|amazonaws|s3://|S3_BUCKET|s3-gc'
self=scripts/tests/no-aws.test.sh
want_registry=ghcr.io/tuckermclean/themonolith

# ---- checks: each prints one line per violation and returns non-zero if any ----
check_ac1() { # check_ac1 <root>
	(
		cd "$1" || { echo "check_ac1: cannot cd to $1"; exit 1; }
		git -c core.quotePath=false ls-files >"$tmp/files.$$" || { echo "check_ac1: git ls-files failed"; exit 1; }
		[ -s "$tmp/files.$$" ] || { echo "check_ac1: empty file list"; exit 1; }
		while IFS= read -r f; do
			case $f in
			'"'*) echo "$f: quoted path in git ls-files output"; continue ;;
			SPEC.md | nodes/* | docs/study/* | docs/reviews/* | docs/graph.yaml | docs/capabilities.md | \
				docs/first-release.md | docs/migration.tsv | scripts/tests/make-test.test.sh | "$self") continue ;;
			esac
			[ -f "$f" ] || continue
			grep -InE -e "$pattern" -- "$f" | sed "s|^|$f:|"
		done <"$tmp/files.$$"
	) >"$tmp/out.$$"
	cat "$tmp/out.$$"
	[ ! -s "$tmp/out.$$" ]
}

reg_assign='^((override|export)[[:space:]]+)*REGISTRY[[:space:]]*(:::=|::=|:=|\?=|\+=|!=|=)'
check_ac2() { # check_ac2 <root>
	bad=0
	n=0
	if [ -f "$1/Makefile" ]; then
		n=$(grep -cE "$reg_assign" "$1/Makefile")
	fi
	if [ "$n" -ne 1 ]; then echo "Makefile: $n assignments of REGISTRY, want 1"; bad=1
	else
		v=$(grep -E "$reg_assign" "$1/Makefile" |
			sed -E 's/^((override|export)[[:space:]]+)*REGISTRY[[:space:]]*(:::=|::=|:=|\?=|\+=|!=|=)[[:space:]]*//; s/[[:space:]]+$//')
		[ "$v" = "$want_registry" ] || { echo "Makefile: REGISTRY is '$v', want $want_registry"; bad=1; }
	fi
	for w in "$1"/.github/workflows/*.yml "$1"/.github/workflows/*.yaml; do
		[ -f "$w" ] || continue
		grep -qE 'REGISTRY|ghcr\.io' "$w" || continue
		c=$(awk '
			/^[[:space:]]*REGISTRY:/ {
				v = $0; sub(/^[[:space:]]*REGISTRY:[[:space:]]*/, "", v)
				if (v ~ /^\$\{\{/) { line[NR] = $0; next }
				sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v)
				if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
				val = v
				match($0, /^[[:space:]]*/); ind = RLENGTH; cnt++
				ok = 0
				for (i = NR - 1; i >= 1; i--) {
					l = line[i]
					if (l ~ /^[[:space:]]*(#|$)/) continue
					match(l, /^[[:space:]]*/)
					if (RLENGTH < ind) { if (l ~ /^[[:space:]]*env:[[:space:]]*(#.*)?$/) ok = 1; break }
				}
				good += ok
			}
			{ line[NR] = $0 }
			END { print cnt + 0, good + 0, val }' "$w")
		if [ "$c" != "1 1 $want_registry" ]; then echo "${w#"$1"/}: want exactly one literal REGISTRY: $want_registry in an env: map (cnt good value: $c)"; bad=1; fi
	done
	(
		cd "$1" || { echo "check_ac2: cannot cd to $1"; exit 1; }
		git -c core.quotePath=false ls-files scripts >"$tmp/sfiles.$$" || { echo "check_ac2: git ls-files failed"; exit 1; }
		[ -s "$tmp/sfiles.$$" ] || { echo "check_ac2: empty scripts file list"; exit 1; }
		while IFS= read -r f; do
			case $f in
			'"'*) echo "$f: quoted path in git ls-files output"; continue ;;
			scripts/tests/*) continue ;;
			esac
			[ -f "$f" ] || continue
			grep -In 'ghcr\.io/' -- "$f" | sed "s|^|$f:|"
		done <"$tmp/sfiles.$$"
	) >"$tmp/ghcr.$$"
	if [ -s "$tmp/ghcr.$$" ]; then cat "$tmp/ghcr.$$"; bad=1; fi
	return $bad
}

check_ac3() { # check_ac3 <root>
	[ -d "$1/.github/workflows" ] || return 0
	cd "$1" || { echo "check_ac3: cannot cd to $1"; return 1; }
	grep -rnoE 'secrets\.[A-Za-z_0-9]*|secrets[[:space:]]*\[|toJSON\([[:space:]]*secrets' .github/workflows | grep -v 'secrets\.GITHUB_TOKEN$' >"$tmp/sec.$$"
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
r=$(mkrepo ac1-draws); echo 'X draws its box' >"$r/scripts/x.sh"; commit_all "$r"
expect "I01-AC-1 'aws ' inside 'draws ' is not a match" pass check_ac1 "$r"
r=$(mkrepo ac1-awsline); echo 'aws s3 cp a b' >"$r/scripts/x.sh"; commit_all "$r"
expect "I01-AC-1 line starting with 'aws s3 cp a b' fails" fail check_ac1 "$r"
r=$(mkrepo ac1-awsrun); printf '      run: aws s3 ls\n' >"$r/scripts/x.sh"; commit_all "$r"
expect "I01-AC-1 '      run: aws s3 ls' fails" fail check_ac1 "$r"
r=$(mkrepo ac1-excl); mkdir -p "$r/nodes" "$r/docs/study"; echo "s3://x" >"$r/nodes/n.md"; echo "AWS_X" >"$r/SPEC.md"
echo "s3-gc" >"$r/docs/migration.tsv"; echo "S3_BUCKET" >"$r/docs/study/a.md"; commit_all "$r"
expect "I01-AC-1 excluded spec paths are not reported" pass check_ac1 "$r"
echo "aws " >"$r/untracked-ok.txt"
expect "I01-AC-1 untracked files are not checked" pass check_ac1 "$r"
r=$(mkrepo ac1-utf8); printf 'AWS_X\n' >"$r/scripts/caf$(printf '\303\251').sh"; printf 'AWS_X\n' >"$r/scripts/a b.sh"; commit_all "$r"
expect "I01-AC-1 non-ASCII and spaced file names are still checked (fail)" fail check_ac1 "$r"
r=$(mkrepo ac1-utf8ok); echo ok >"$r/scripts/caf$(printf '\303\251').sh"; echo ok >"$r/scripts/a b.sh"; commit_all "$r"
expect "I01-AC-1 non-ASCII and spaced clean file names pass" pass check_ac1 "$r"
r=$(mkrepo ac1-nogit); echo 'AWS_X' >"$r/x.sh"; commit_all "$r"; mv "$r/.git" "$r/.gitx"
expect "I01-AC-1 failing git ls-files fails the check" fail check_ac1 "$r"
r=$(mkrepo ac1-empty)
expect "I01-AC-1 empty file list fails the check" fail check_ac1 "$r"
expect "I01-AC-1 failing cd fails the check" fail check_ac1 "$tmp/no-such-dir"
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
r=$(mkrepo ac2-recipe); printf 'REGISTRY ?= %s\npush:\n\tREGISTRY=$(REGISTRY) sh scripts/x.sh\n' "$want_registry" >"$r/Makefile"; echo hi >"$r/scripts/a.sh"; commit_all "$r"
expect "I01-AC-2 tab-led recipe 'REGISTRY=...' is not an assignment (pass)" pass check_ac2 "$r"
for op in 'override REGISTRY = ghcr.io/evil' 'export REGISTRY := ghcr.io/evil' 'override export REGISTRY ::= x' 'REGISTRY :::= x' 'REGISTRY += x' 'REGISTRY != echo x'; do
	r=$(mkrepo ac2-op); good_makefile "$r"; printf '%s\n' "$op" >>"$r/Makefile"; commit_all "$r"
	expect "I01-AC-2 second assignment '$op' fails" fail check_ac2 "$r"
	rm -rf "$r"
done
r=$(mkrepo ac2-wfval); good_makefile "$r"; printf 'env:\n  REGISTRY: ghcr.io/somewhere/else\n' >"$r/.github/workflows/a.yml"; echo hi >"$r/scripts/a.sh"; commit_all "$r"
expect "I01-AC-2 workflow REGISTRY with wrong value fails" fail check_ac2 "$r"
r=$(mkrepo ac2-yaml); good_makefile "$r"; printf 'env:\n  REGISTRY: x\n' >"$r/.github/workflows/b.yaml"; echo hi >"$r/scripts/a.sh"; commit_all "$r"
expect "I01-AC-2 .yaml workflow with wrong REGISTRY fails" fail check_ac2 "$r"
r=$(mkrepo ac2-yamlok); good_makefile "$r"; printf 'env:\n  REGISTRY: %s\n' "$want_registry" >"$r/.github/workflows/b.yaml"; echo hi >"$r/scripts/a.sh"; commit_all "$r"
expect "I01-AC-2 .yaml workflow with the right REGISTRY passes" pass check_ac2 "$r"
r=$(mkrepo ac2-cmt); good_makefile "$r"; printf 'env: # registry\n  REGISTRY: %s\n' "$want_registry" >"$r/.github/workflows/c.yml"; echo hi >"$r/scripts/a.sh"; commit_all "$r"
expect "I01-AC-2 'env:' with trailing comment is an env map (pass)" pass check_ac2 "$r"
r=$(mkrepo ac2-fwd); good_makefile "$r"; good_workflow "$r"
printf '  other:\n    runs-on: u\n    steps:\n      - uses: ./x\n        with:\n          REGISTRY: ${{ env.REGISTRY }}\n' >>"$r/.github/workflows/a.yml"; echo hi >"$r/scripts/a.sh"; commit_all "$r"
expect "I01-AC-2 forward 'REGISTRY: \${{ env.REGISTRY }}' is allowed and not counted" pass check_ac2 "$r"
r=$(mkrepo ac2-tests); good_makefile "$r"; mkdir -p "$r/scripts/tests"; echo 'stub ghcr.io/x/y' >"$r/scripts/tests/s.test.sh"; echo hi >"$r/scripts/a.sh"; commit_all "$r"
expect "I01-AC-2 ghcr.io/ under scripts/tests/ is allowed" pass check_ac2 "$r"
r=$(mkrepo ac2-nogit); good_makefile "$r"; echo hi >"$r/scripts/a.sh"; commit_all "$r"; mv "$r/.git" "$r/.gitx"
expect "I01-AC-2 failing git ls-files fails the check" fail check_ac2 "$r"
if out=$(check_ac2 "$root" 2>&1); then pass "I01-AC-2 REGISTRY assigned once in Makefile and workflow env, no ghcr.io/ in scripts"
else fail "I01-AC-2 registry location rules broken:"; printf '%s\n' "$out" | sed 's/^/  /'; fi

# ---- I01-AC-3 ----
r=$(mkrepo ac3-ok); good_workflow "$r"; commit_all "$r"
expect "I01-AC-3 fixture using only secrets.GITHUB_TOKEN passes" pass check_ac3 "$r"
r=$(mkrepo ac3-bad); good_workflow "$r"; echo '      - run: echo ${{ secrets.AWS_ACCESS_KEY_ID }}' >>"$r/.github/workflows/a.yml"; commit_all "$r"
expect "I01-AC-3 fixture workflow using another secret fails" fail check_ac3 "$r"
r=$(mkrepo ac3-br); printf 'jobs:\n  a:\n    steps:\n      - run: echo ${{ secrets["AWS_KEY"] }}\n' >"$r/.github/workflows/a.yml"; commit_all "$r"
expect "I01-AC-3 secrets[...] fails" fail check_ac3 "$r"
r=$(mkrepo ac3-json); printf 'jobs:\n  a:\n    steps:\n      - run: echo ${{ toJSON(secrets) }}\n' >"$r/.github/workflows/a.yml"; commit_all "$r"
expect "I01-AC-3 toJSON(secrets) fails" fail check_ac3 "$r"
r=$(mkrepo ac3-yaml); good_workflow "$r"; echo '      - run: echo ${{ secrets.OTHER }}' >>"$r/.github/workflows/a.yml"; mv "$r/.github/workflows/a.yml" "$r/.github/workflows/a.yaml"; commit_all "$r"
expect "I01-AC-3 .yaml workflow using another secret fails" fail check_ac3 "$r"
if out=$(check_ac3 "$root" 2>&1); then pass "I01-AC-3 no workflow requires a secret other than GITHUB_TOKEN"
else fail "I01-AC-3 workflows use other secrets:"; printf '%s\n' "$out" | sed 's/^/  /'; fi

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all no-aws checks"
