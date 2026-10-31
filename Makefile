SWIFT := /mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift
PYTHON ?= python3

.PHONY: test test-e2e parity parity-check
test:
	$(SWIFT) test

test-e2e:
	$(SWIFT) build
	RAFT_E2E=1 RAFT_SERVER_BIN=$(CURDIR)/.build/debug/RaftServer RAFT_DAEMON_BIN=$(CURDIR)/.build/debug/RaftDaemon $(SWIFT) test --filter RaftServerStartupTests

parity:
	$(PYTHON) scripts/parity.py

parity-check:
	$(PYTHON) scripts/parity.py --check
