SWIFT := /mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift
PYTHON ?= python3
SHARDS ?= 6

.PHONY: test check test-sharded test-pg test-e2e gate \
	pg-up pg-down pg-url parity parity-check architecture route-inventory deploy \
	verification-plan verification-preflight verification-selftest verification-handoff verification-release

# Artifacts stay outside Git. A business change requires these current inputs;
# a development plan never grants completion or release eligibility.
VERIFY_ENV = VERIFY_PLAN="$(VERIFY_PLAN)" VERIFY_BASELINE="$(VERIFY_BASELINE)" VERIFY_REPORT="$(VERIFY_REPORT)" VERIFY_EVIDENCE_ROOT="$(VERIFY_EVIDENCE_ROOT)" VERIFY_QUALIFICATION="$(VERIFY_QUALIFICATION)"

# Full suite, single serialized process. Kept for compatibility; prefer
# `make test-sharded` for the same coverage in minutes.
test:
	$(SWIFT) test --no-parallel

# Fast loop: incremental build + only the tests matching FILTER.
#   make check FILTER=OarListModelsTests
check: verification-preflight
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
	$(VERIFY_ENV) SHARDS=$(SHARDS) scripts/gate.sh

parity:
	$(PYTHON) scripts/parity.py

parity-check:
	$(PYTHON) scripts/parity.py --check

architecture:
	$(PYTHON) scripts/check_architecture.py

# Boot the FallbackApplication route table through the pinned toolchain and
# regenerate the committed upstream/Swift route diff.
route-inventory:
	$(PYTHON) scripts/route_inventory.py --swift $(SWIFT) --write docs/route-inventory.md

pg-up:
	docker compose -f docker-compose.pg.yml up -d --wait

pg-down:
	docker compose -f docker-compose.pg.yml down -v

pg-url:
	@echo postgres://raft:raft@127.0.0.1:54329/raft?sslmode=disable

# Build -> stage -> verify -> upgrade the production Main from COMMIT.
# Environment-specific paths come from deploy/swift-production/local.env
# (git-ignored; see local.env.example).
deploy: verification-release
	@test -n "$(COMMIT)" || { echo 'usage: make deploy COMMIT=<sha> VERIFY_QUALIFICATION=<integration-receipt>' >&2; exit 2; }
	deploy/swift-production/deploy.sh $(COMMIT)

# Generate a NOT_RUN plan from the protected deployment-trunk merge base.
verification-plan:
	$(VERIFY_ENV) $(PYTHON) scripts/verification/run_completion.py plan $(if $(VERIFY_PLAN),--out "$(VERIFY_PLAN)",)

verification-preflight:
	$(VERIFY_ENV) $(PYTHON) scripts/verification/run_completion.py preflight

verification-selftest:
	@mkdir -p "$(CURDIR)/.build/verification/tmp"
	TMPDIR="$(CURDIR)/.build/verification/tmp" $(PYTHON) -m unittest discover -s scripts/verification -p 'test_*.py'
	TMPDIR="$(CURDIR)/.build/verification/tmp" $(PYTHON) -m unittest discover -s scripts/acceptance -p 'test_*.py'
	TMPDIR="$(CURDIR)/.build/verification/tmp" $(PYTHON) -m unittest discover -s scripts -p test_route_inventory.py
	TMPDIR="$(CURDIR)/.build/verification/tmp" $(PYTHON) -m unittest discover -s scripts -p test_parity_ledger.py

# Handoff is scoped evidence validation, not the complete Swift integration gate.
verification-handoff: verification-preflight
	$(VERIFY_ENV) $(PYTHON) scripts/verification/run_completion.py handoff

verification-release:
	$(VERIFY_ENV) $(PYTHON) scripts/verification/run_completion.py release --commit "$(COMMIT)"
