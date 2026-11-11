#!/usr/bin/env bash
#
# Real-PostgreSQL acceptance gate.
#
# Starts ONE throwaway PostgreSQL 17 + Redis container pair on free loopback
# ports, creates one database per gated suite, runs every env-gated real-PG
# acceptance test with the right environment, the DatabaseHealth test and the
# infrastructure check executable, then removes the containers.
#
# Each gated test runs in its own process: the shared transaction domain
# forbids allocating new stores after production policy is enabled, so two
# gated acceptance tests in one process would abort. Running the already-linked
# test runner directly also avoids SwiftPM's .build lock and per-test relaunch
# overhead.
#
#   make test-pg            (or scripts/test-pg.sh)
#
# Nothing here touches the production database or the production Redis.
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    printf 'usage: %s\n\n' "$(basename "$0")"
    printf 'Starts one throwaway PostgreSQL 17 + Redis pair on free loopback ports,\n'
    printf 'runs every gated real-PG acceptance suite, then removes the containers.\n'
    printf 'Logs: .build/test-pg/<UTC stamp>/ (override with RAFT_TEST_PG_LOG_DIR).\n'
    printf 'RAFT_TEST_PG_ONLY=<extended regex> runs only matching gated tests (debug).\n'
    exit 0
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SWIFT_BIN="${SWIFT:-/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift}"
PG_IMAGE="${RAFT_TEST_PG_IMAGE:-postgres:17-alpine}"
REDIS_IMAGE="${RAFT_TEST_REDIS_IMAGE:-redis:7-alpine}"
LOG_DIR="${RAFT_TEST_PG_LOG_DIR:-$REPO_ROOT/.build/test-pg/$(date -u +%Y%m%dT%H%M%SZ)}"
STAMP="$(date +%Y%m%dT%H%M%S)-$$"
PG_NAME="raft-test-pg-$STAMP"
REDIS_NAME="raft-test-redis-$STAMP"
PG_PASSWORD="rafttest$(python3 -c 'import uuid;print(uuid.uuid4().hex)')"
REDIS_PASSWORD="raftredis$(python3 -c 'import uuid;print(uuid.uuid4().hex)')"
PG_PORT=""
REDIS_PORT=""
FAILURES=0
STEP=""

mkdir -p "$LOG_DIR" "$LOG_DIR/gated"

free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

cleanup() {
    local status=$?
    STEP=""
    docker rm -f "$PG_NAME" "$REDIS_NAME" >/dev/null 2>&1 || true
    if [[ $status -ne 0 ]]; then
        printf 'test-pg: FAIL (logs: %s)\n' "$LOG_DIR" >&2
    else
        printf 'test-pg: PASS (logs: %s)\n' "$LOG_DIR"
    fi
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
fail() {
    printf 'test-pg: FAIL: %s\n' "$*" >&2
    exit 1
}

run_suite() {
    local name="$1"
    shift
    local log="$LOG_DIR/$name.log"
    STEP="$name"
    local started
    started=$(date +%s)
    say "==> $name"
    if "$@" >"$log" 2>&1; then
        say "    PASS $(( $(date +%s) - started ))s  $log"
    else
        FAILURES=$((FAILURES + 1))
        say "    FAIL $(( $(date +%s) - started ))s  $log"
        tail -n 30 "$log" >&2 || true
    fi
    STEP=""
}

command -v docker >/dev/null || fail "docker is required"
[[ -x "$SWIFT_BIN" ]] || fail "swift toolchain is not executable: $SWIFT_BIN"

say "test-pg: logs under $LOG_DIR"
"$SWIFT_BIN" build >"$LOG_DIR/build.log" 2>&1 || fail "swift build failed (see $LOG_DIR/build.log)"
"$SWIFT_BIN" build --build-tests >>"$LOG_DIR/build.log" 2>&1 \
    || fail "swift build --build-tests failed (see $LOG_DIR/build.log)"
SERVER_BIN="$REPO_ROOT/.build/debug/RaftServer"
DAEMON_BIN="$REPO_ROOT/.build/debug/RaftDaemon"
INFRA_BIN="$REPO_ROOT/.build/debug/RaftInfrastructureCheck"
RUNNER_DIR="$("$SWIFT_BIN" build --show-bin-path 2>/dev/null)"
[[ -x "$SERVER_BIN" ]] || fail "missing executable: $SERVER_BIN"
[[ -x "$INFRA_BIN" ]] || fail "missing executable: $INFRA_BIN"
[[ -x "$RUNNER_DIR/RaftServerStartupTests-test-runner" ]] || fail "missing startup test runner in $RUNNER_DIR"
[[ -x "$RUNNER_DIR/RaftHTTPTests-test-runner" ]] || fail "missing HTTP test runner in $RUNNER_DIR"

"$SWIFT_BIN" test list --skip-build >"$LOG_DIR/test-list.txt" 2>&1 \
    || fail "swift test list failed (see $LOG_DIR/test-list.txt)"
grep -E '^RaftServerStartupTests\.' "$LOG_DIR/test-list.txt" >"$LOG_DIR/gated-tests.txt" || true
if [[ -n "${RAFT_TEST_PG_ONLY:-}" ]]; then
    # Debug knob: run only gated tests whose id matches this extended regex.
    grep -E "${RAFT_TEST_PG_ONLY}" "$LOG_DIR/gated-tests.txt" >"$LOG_DIR/gated-tests.filtered" || true
    mv "$LOG_DIR/gated-tests.filtered" "$LOG_DIR/gated-tests.txt"
fi
[[ -s "$LOG_DIR/gated-tests.txt" ]] || fail "no RaftServerStartupTests entries in $LOG_DIR/test-list.txt"

PG_PORT="$(free_port)"
REDIS_PORT="$(free_port)"
DATABASE_ROOT="postgres://raft:$PG_PASSWORD@127.0.0.1:$PG_PORT"
REDIS_ROOT="redis://:$REDIS_PASSWORD@127.0.0.1:$REDIS_PORT"
DATABASE_URL="$DATABASE_ROOT/raft_health?sslmode=disable"
REDIS_URL="$REDIS_ROOT/0"

say "==> throwaway PostgreSQL 17 and Redis on loopback ports $PG_PORT/$REDIS_PORT"
docker run -d --name "$PG_NAME" \
    -e POSTGRES_USER=raft -e POSTGRES_PASSWORD="$PG_PASSWORD" -e POSTGRES_DB=raft \
    -p "127.0.0.1:$PG_PORT:5432" "$PG_IMAGE" >/dev/null
docker run -d --name "$REDIS_NAME" -p "127.0.0.1:$REDIS_PORT:6379" "$REDIS_IMAGE" \
    redis-server --requirepass "$REDIS_PASSWORD" >/dev/null

ready=0
for _ in $(seq 1 480); do
    if docker exec "$PG_NAME" pg_isready -U raft -d raft >/dev/null 2>&1; then
        ready=$((ready + 1))
        [[ "$ready" -ge 8 ]] && break
    else
        ready=0
    fi
    sleep 0.25
done
if [[ "$ready" -lt 8 ]]; then
    docker logs "$PG_NAME" >&2 2>&1 | tail -n 30 || true
    fail "throwaway PostgreSQL did not become ready"
fi
for _ in $(seq 1 240); do
    if docker exec "$REDIS_NAME" redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then break; fi
    sleep 0.25
done
docker exec "$REDIS_NAME" redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG \
    || fail "throwaway Redis did not become ready"

# Every gated test gets a fresh database: several fixtures require an empty
# database, and the shared transaction domain already forces a fresh process.
DATABASES=(
    raft_health
    raft_infrastructure
)
for database in "${DATABASES[@]}"; do
    docker exec "$PG_NAME" createdb -U raft "$database"
done
say "    ready: PostgreSQL 17 (one fresh database per test) and Redis"

database_url() {
    printf '%s/%s?sslmode=disable' "$DATABASE_ROOT" "$1"
}

BASE_ENV=(
    "PATH=$PATH"
    "RAFT_SERVER_BIN=$SERVER_BIN"
    "RAFT_DAEMON_BIN=$DAEMON_BIN"
    "RAFT_PG_INTEGRATION=1"
    "TMPDIR=$LOG_DIR/tmp"
    "RAFT_AGENT_EXECUTION_PG_ACCEPTANCE=1"
    "RAFT_HUMAN_MESSAGE_EXECUTION_PG_ACCEPTANCE=1"
    "RAFT_REALTIME_ACTIVE_AUTH_PG_ACCEPTANCE=1"
    "RAFT_RESIDENT_DELIVERY_PG_ACCEPTANCE=1"
    "RAFT_RESTART_RECOVERY_PG_ACCEPTANCE=1"
    "RAFT_MENTION_DELIVERY_PG_ACCEPTANCE=1"
    "RAFT_OPENER_NOTICE_PG_ACCEPTANCE=1"
    "RAFT_AGENT_OFFLINE_QUEUE_PG_ACCEPTANCE=1"
    "RAFT_MACHINE_QUERY_PG_ACCEPTANCE=1"
    "RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE=1"
    "RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_REDIS_URL=$REDIS_ROOT/1"
    "RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_SERVER_BIN=$SERVER_BIN"
    "RAFT_EMAIL_SHUTDOWN_PG_ACCEPTANCE=1"
    "RAFT_EMAIL_SHUTDOWN_PG_ACCEPTANCE_REDIS_URL=$REDIS_ROOT/2"
    "RAFT_EMAIL_SHUTDOWN_PG_ACCEPTANCE_SERVER_BIN=$SERVER_BIN"
    "RAFT_ONBOARDING_PG_ACCEPTANCE=1"
    "RAFT_ONBOARDING_PG_ACCEPTANCE_REDIS_URL=$REDIS_ROOT/3"
    "RAFT_ONBOARDING_PG_ACCEPTANCE_SERVER_BIN=$SERVER_BIN"
)

case_env() {
    local url
    url="$(database_url "$1")"
    CASE_ENV=(
        "${BASE_ENV[@]}"
        "DATABASE_URL=$url"
        "RAFT_AGENT_EXECUTION_TEST_DATABASE_URL=$url"
        "RAFT_HUMAN_MESSAGE_EXECUTION_TEST_DATABASE_URL=$url"
        "RAFT_REALTIME_ACTIVE_AUTH_TEST_DATABASE_URL=$url"
        "RAFT_RESIDENT_DELIVERY_TEST_DATABASE_URL=$url"
        "RAFT_RESTART_RECOVERY_TEST_DATABASE_URL=$url"
        "RAFT_MENTION_DELIVERY_TEST_DATABASE_URL=$url"
        "RAFT_OPENER_NOTICE_TEST_DATABASE_URL=$url"
        "RAFT_AGENT_OFFLINE_QUEUE_TEST_DATABASE_URL=$url"
        "RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_DATABASE_URL=$url"
        "RAFT_EMAIL_SHUTDOWN_PG_ACCEPTANCE_DATABASE_URL=$url"
        "RAFT_ONBOARDING_PG_ACCEPTANCE_DATABASE_URL=$url"
    )
}

mkdir -p "$LOG_DIR/tmp"

# Run every listed startup test in its own runner process, oldest first. A
# failing test is recorded and the run continues.
run_gated_startup_tests() {
    local test_id escaped safe log case_db failed=0 count=0
    while IFS= read -r test_id; do
        [[ -n "$test_id" ]] || continue
        count=$((count + 1))
        safe="$(printf '%s' "$test_id" | tr -c 'A-Za-z0-9._-' '_')"
        escaped="$(python3 -c 'import re,sys;print(re.escape(sys.argv[1]))' "$test_id")"
        log="$LOG_DIR/gated/$safe.log"
        case_db="raft_case_$count"
        docker exec "$PG_NAME" createdb -U raft "$case_db" \
            || { failed=$((failed + 1)); printf 'FAIL %s (createdb %s)\n' "$test_id" "$case_db"; continue; }
        case_env "$case_db"
        if env "${CASE_ENV[@]}" \
            "$RUNNER_DIR/RaftServerStartupTests-test-runner" \
            --testing-library swift-testing --no-parallel \
            --filter "^${escaped}(/|$)" >"$log" 2>&1; then
            # A gated acceptance test must actually run: enabled(if:) skipping
            # because an environment variable is missing is a gate failure.
            if [[ "$test_id" =~ (Postgres|Onboarding|EmailShutdown|BusinessPersistence|ProductionMachine|Mention|OpenerLedger) ]] \
                && ! grep -qE 'Test run with [1-9]' "$log"; then
                failed=$((failed + 1))
                printf 'FAIL %s (gated test did not run; log %s)\n' "$test_id" "$log"
                tail -n 8 "$log" | sed 's/^/    /'
            else
                printf 'PASS %s\n' "$test_id"
            fi
        else
            failed=$((failed + 1))
            printf 'FAIL %s (log %s)\n' "$test_id" "$log"
            tail -n 8 "$log" | sed 's/^/    /'
        fi
        docker exec "$PG_NAME" dropdb -U raft --force "$case_db" >/dev/null 2>&1 || true
    done <"$LOG_DIR/gated-tests.txt"
    printf '%d gated startup tests, %d failed\n' "$count" "$failed"
    [[ "$failed" -eq 0 ]]
}

run_suite gated-startup-tests run_gated_startup_tests

run_suite database-health \
    env "${BASE_ENV[@]}" "DATABASE_URL=$DATABASE_URL" \
    "$RUNNER_DIR/RaftHTTPTests-test-runner" \
    --testing-library swift-testing --no-parallel --filter 'DatabaseHealthTests'

run_suite infrastructure-check \
    env "DATABASE_URL=$(database_url raft_infrastructure)" "REDIS_URL=$REDIS_URL" \
    "$INFRA_BIN" --check

if [[ $FAILURES -ne 0 ]]; then
    printf 'test-pg: %d suite(s) failed\n' "$FAILURES" >&2
    exit 1
fi
