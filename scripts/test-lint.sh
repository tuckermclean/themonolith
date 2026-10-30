#!/bin/sh
# The lint checks behind `make test-lint`. Arguments: extra shell paths, each must exist.
# Empty globs are not errors; a listed path that does not exist is.
set -u
rc=0

shells=
for f in scripts/*.sh scripts/tests/*.sh; do
	[ -e "$f" ] && shells="$shells $f"
done
for f in "$@"; do
	if [ -e "$f" ]; then
		shells="$shells $f"
	else
		echo "::error file=$f::no such file"
		rc=1
	fi
done

echo "==> Shell script syntax (bash -n)"
for f in $shells; do
	[ -e "$f" ] || continue
	bash -n "$f" || { echo "::error file=$f::bash -n failed"; rc=1; }
done

echo "==> Python syntax (py_compile)"
for f in scripts/*.py; do
	[ -e "$f" ] || continue
	python3 -I -m py_compile "$f" || { echo "::error file=$f::py_compile failed"; rc=1; }
done

echo "==> YAML well-formedness"
python3 -I - <<'PY' || rc=1
import glob, sys, yaml
rc = 0
for f in sorted(glob.glob('configs/**/*.yaml', recursive=True)
                + glob.glob('.github/workflows/*.yml')):
    try:
        yaml.safe_load(open(f))
    except yaml.YAMLError as e:
        print(f'::error file={f}::{e}')
        rc = 1
sys.exit(rc)
PY

echo "==> Workflow lint (actionlint)"
# -shellcheck= disables actionlint's bundled shellcheck on run: blocks (scripts/ are linted
# separately below); actionlint's own checks stay on.
if [ -d .github/workflows ]; then
	actionlint -color -shellcheck= || rc=1
fi

echo "==> Shell lint (shellcheck, errors only)"
if [ -n "$shells" ]; then
	# shellcheck disable=SC2086
	shellcheck --severity=error $shells || rc=1
fi

echo "==> Migration ledger (check-migration.py)"
python3 -I scripts/check-migration.py || rc=1

echo "==> Workflow rules (toolbox/ci lint)"
toolbox/ci lint || rc=1

exit $rc
