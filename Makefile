SWIFT := /mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift
PYTHON ?= python3
SHARDS ?= 6

.PHONY: test check test-sharded test-pg test-e2e gate \
	pg-up pg-down pg-url parity parity-check architecture deploy

# Full suite, single serialized process. Kept for compatibility; prefer
# `make test-sharded` for the same coverage in minutes.
test:
	$(SWIFT) test --no-parallel

# Fast loop: incremental build + only the tests matching FILTER.
#   make check FILTER=OarListModelsTests
check:
	@test -n "$(FILTER)" || { echo 'usage: make check FILTER=<regex>' >&2; exit 2; }
	$(SWIFT) build --build-tests
	$(SWIFT) test --skip-build --no-parallel --filter '$(FILTER)'

# Full suite as parallel test-runner shards, with one isolated retry per
# failing test and a machine-readable summary.
test-sharded:
	$(PYTHON) scripts/test-sharded.py --shards $(SHARDS)

# Real PostgreSQL 17 + Redis acceptance: one throwaway container pair on free
# loopback ports, every gated real-PG suite, then the containers are removed.
test-pg:
	scripts/test-pg.sh

test-e2e:
	$(SWIFT) build
	RAFT_E2E=1 RAFT_SERVER_BIN=$(CURDIR)/.build/debug/RaftServer RAFT_DAEMON_BIN=$(CURDIR)/.build/debug/RaftDaemon $(SWIFT) test --no-parallel --filter RaftServerStartupTests

# Trunk / pre-merge gate: test-sharded, test-e2e, smoke, architecture,
# parity-check, fail-fast, one log directory.
gate:
	SHARDS=$(SHARDS) scripts/gate.sh

parity:
	$(PYTHON) scripts/parity.py

parity-check:
	$(PYTHON) scripts/parity.py --check

architecture:
	$(PYTHON) scripts/check_architecture.py

pg-up:
	docker compose -f docker-compose.pg.yml up -d --wait

pg-down:
	docker compose -f docker-compose.pg.yml down -v

pg-url:
	@echo postgres://raft:raft@127.0.0.1:54329/raft?sslmode=disable

# Build -> stage -> verify -> upgrade the production Main from COMMIT.
# Environment-specific paths come from deploy/swift-production/local.env
# (git-ignored; see local.env.example).
deploy:
	@test -n "$(COMMIT)" || { echo 'usage: make deploy COMMIT=<sha>' >&2; exit 2; }
	deploy/swift-production/deploy.sh $(COMMIT)
