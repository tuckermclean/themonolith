# SPEC section 7: CI calls these targets; a test is always a Make target.
SHELL_EXTRA ?=

.PHONY: test test-lint test-unit

test: test-lint test-unit

test-lint:
	toolbox/run --network none -- sh scripts/test-lint.sh $(SHELL_EXTRA) $(addprefix configs/overlay/app-misc/monolith-base/files/,monolith-net monolith-router monolith monolith-time monolith-time-check monolith-persist)

test-unit:
	toolbox/run --network none -- sh -c 'echo "==> Shell unit tests (scripts/tests/*.sh)"; rc=0; for t in scripts/tests/*.sh; do [ -e "$$t" ] || continue; echo "==> Running $$t"; sh "$$t" || { echo "::error file=$$t::test suite failed"; rc=1; }; done; exit $$rc'
