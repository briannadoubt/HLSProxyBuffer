SWIFT_TEST = swift test
CI_SCRIPT = ./Scripts/run-ci.sh

.PHONY: test ci benchmark

test:
	$(SWIFT_TEST)

ci: test
	$(CI_SCRIPT)

benchmark:
	swift run -c release HLSProxyBenchmarks
