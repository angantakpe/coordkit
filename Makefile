.PHONY: help claude codex test test-fast test-all

.DEFAULT_GOAL := help

help:
	@printf '%s\n' 'make test TESTS="tests/plugin-package.sh tests/validate-package.sh"' '  Run explicit focused test files.' 'python3 scripts/select-tests.py --base origin/main' '  Print affected tests for tracked changes.' 'make test-all' '  Run every test only when a full run is explicitly wanted.'

claude:
	claude

codex:
	codex

test:
	@test -n "$(TESTS)" || { printf '%s\n' 'Choose focused tests: make test TESTS="tests/plugin-package.sh" (or explicitly use make test-all).' >&2; exit 2; }
	@set -eu; for test in $(TESTS); do \
	  case "$$test" in tests/*.sh|tests/*.py) test -f "$$test" || { echo "Missing test: $$test" >&2; exit 2; } ;; *) echo "Unsupported test: $$test" >&2; exit 2 ;; esac; \
	done; \
	for test in $(TESTS); do \
	  echo "Running $$test"; \
	  case "$$test" in *.sh) bash -n "$$test"; bash "$$test" ;; *.py) python3 "$$test" ;; esac; \
	done

test-fast: test

test-all:
	@$(MAKE) test TESTS="$(wildcard tests/*.sh tests/test_*.py)"
