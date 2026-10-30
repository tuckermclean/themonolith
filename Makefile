# SPEC section 7: CI calls these targets; a test is always a Make target.
SHELL_EXTRA ?=

.PHONY: test test-lint test-unit test-revbump

test: test-lint test-unit test-revbump

test-lint:
	toolbox/run --network none -- sh scripts/test-lint.sh $(SHELL_EXTRA)

test-unit:
	toolbox/run --network none -- sh -c 'echo "==> Shell unit tests (scripts/tests/*.sh)"; rc=0; for t in scripts/tests/*.sh; do [ -e "$$t" ] || continue; echo "==> Running $$t"; sh "$$t" || { echo "::error file=$$t::test suite failed"; rc=1; }; done; exit $$rc'

# BASE: the merge base of HEAD with origin/main if that ref exists, else with main.
BASE ?= $(shell git merge-base HEAD $$(git rev-parse --verify -q origin/main >/dev/null && echo origin/main || echo main))

# Judged by BASE's copy of the script, so a PR cannot weaken the check it is judged by.
# Only when BASE lacks the script (the PR that introduces it) the working-tree copy is used.
test-revbump:
	toolbox/run --network none -- sh -c 'echo "==> Revision bump check ($(BASE)..HEAD)"; git rev-parse --verify -q "$(BASE)^{commit}" >/dev/null || { echo "test-revbump: BASE \"$(BASE)\" is not a commit"; exit 1; }; s=$$(mktemp); if [ -n "$$(git ls-tree "$(BASE)" -- scripts/check-revbump.sh)" ]; then git show "$(BASE):scripts/check-revbump.sh" >"$$s" || { rm -f "$$s"; exit 1; }; else echo "note: $(BASE) has no scripts/check-revbump.sh; using the working-tree copy"; cp scripts/check-revbump.sh "$$s" || { rm -f "$$s"; exit 1; }; fi; sh "$$s" "$(BASE)" HEAD; rc=$$?; rm -f "$$s"; exit $$rc'
