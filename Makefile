SWIFT := /mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift
PYTHON ?= python3

.PHONY: test test-e2e test-pg pg-up pg-down pg-url parity parity-check
test:
	$(SWIFT) test

test-e2e:
	$(SWIFT) build
	RAFT_E2E=1 RAFT_SERVER_BIN=$(CURDIR)/.build/debug/RaftServer RAFT_DAEMON_BIN=$(CURDIR)/.build/debug/RaftDaemon $(SWIFT) test --filter RaftServerStartupTests

parity:
	$(PYTHON) scripts/parity.py

parity-check:
	$(PYTHON) scripts/parity.py --check

pg-up:
	docker compose -f docker-compose.pg.yml up -d --wait

pg-down:
	docker compose -f docker-compose.pg.yml down -v

pg-url:
	@echo postgres://raft:raft@127.0.0.1:54329/raft?sslmode=disable

test-pg: pg-up
	DATABASE_URL=$$($(MAKE) -s pg-url) RAFT_PG_INTEGRATION=1 $(SWIFT) test --filter DatabaseHealthTests
