#!/usr/bin/env bash
#
# Trunk / pre-merge gate: the full tiered gate, fail-fast, logs to a directory.
#
#   scripts/gate.sh [--shards N] [--log-dir DIR]
#
# Steps, in order:
#   1. scripts/test-sharded.py   full suite in parallel test-runner shards
#   2. make test-e2e             real RaftServer/RaftDaemon processes
#   3. scripts/smoke-server.sh   real-process smoke on loopback ports
#   4. make architecture         layering/file-size/test-seam guardrails
#   5. make parity-check         upstream ledger validation
#
# A failing step stops the gate. Every step writes its own log file under the
# log directory (default .build/gate-logs/<UTC stamp>); nothing is piped
# through tee.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SHARDS="${SHARDS:-6}"
LOG_ROOT=""
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

usage() {
    printf 'usage: %s [--shards N] [--log-dir DIR]\n' "$(basename "$0")" >&2
    exit 2
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --shards) SHARDS="${2:?--shards needs a value}"; shift 2 ;;
        --log-dir) LOG_ROOT="${2:?--log-dir needs a value}"; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done
LOG_DIR="${LOG_ROOT:-$REPO_ROOT/.build/gate-logs}/${STAMP}"
mkdir -p "$LOG_DIR"

STEP=""
STEP_STARTED=0
STEP_TIMES=()

cleanup() {
    local status=$?
    if [[ $status -ne 0 && -n "$STEP" ]]; then
        printf '\nGATE FAILED at step: %s\n' "$STEP" >&2
        printf 'log: %s\n' "$LOG_DIR" >&2
        tail -n 40 "$LOG_DIR/${STEP}.log" >&2 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT

run_step() {
    local name="$1"
    shift
    STEP="$name"
    STEP_STARTED=$(date +%s)
    printf '==> %s\n' "$name"
    local log="$LOG_DIR/${name}.log"
    if "$@" >"$log" 2>&1; then
        local elapsed=$(( $(date +%s) - STEP_STARTED ))
        STEP_TIMES+=("$(printf '%-16s PASS %4ss  %s' "$name" "$elapsed" "$log")")
        printf '    PASS %ss\n' "$elapsed"
    else
        local elapsed=$(( $(date +%s) - STEP_STARTED ))
        STEP_TIMES+=("$(printf '%-16s FAIL %4ss  %s' "$name" "$elapsed" "$log")")
        printf '    FAIL %ss\n' "$elapsed"
        exit 1
    fi
    STEP=""
}

run_step test-sharded "$SCRIPT_DIR/test-sharded.py" --shards "$SHARDS" --logs "$LOG_DIR/sharded"
run_step test-e2e make -C "$REPO_ROOT" test-e2e
run_step smoke "$SCRIPT_DIR/smoke-server.sh"
run_step architecture make -C "$REPO_ROOT" architecture
run_step parity-check make -C "$REPO_ROOT" parity-check

printf '\nGATE PASS %s\n' "$LOG_DIR/summary.txt"
printf '%-16s %-5s %s\n' STEP RESULT LOG
for line in "${STEP_TIMES[@]}"; do printf '%s\n' "$line"; done
{
    printf 'gate %s\n' "$STAMP"
    for line in "${STEP_TIMES[@]}"; do printf '%s\n' "$line"; done
} >"$LOG_DIR/summary.txt"
