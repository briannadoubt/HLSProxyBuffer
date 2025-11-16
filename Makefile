SWIFT_TEST = swift test
CI_SCRIPT = ./Scripts/run-ci.sh

.PHONY: test ci

test:
	$(SWIFT_TEST)

ci: test
	$(CI_SCRIPT)
