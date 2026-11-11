#!/usr/bin/env bash
#
# End-to-end smoke test for the Swift Raft server.
#
# Builds `.build/debug/RaftServer` with the pinned Swift toolchain, starts it on
# three free loopback ports (HTTP, socket.io, daemon/connect), and asserts the
# published behavior over real sockets:
#
#   * GET /livez                        -> 200
#   * GET /health (no DATABASE_URL)     -> 503 {"status":"error","detail":"database unreachable"}
#   * GET /api/version                  -> 200 ready identity, or 503 build_identity_unavailable
#   * register -> create server -> create channel -> external agent + credential ->
#     agent sends a message -> the human lists the channel and finds it back
#   * unverified-human POST /api/messages stays behind the upstream requireVerified gate
#   * verified-human roundtrip          -> register (SLOCK_E2E_AUTO_VERIFY_EMAIL=1 +
#     __e2eAutoVerify), join the server/channel, POST /api/messages -> 200, read it
#     back from GET /api/messages/channel/:id, and receive the live
#     `42["message:new", ...]` socket.io frame
#   * socket.io raw RFC6455 upgrade     -> 0{ open, 40{ connect, 42["rooms:joined"]
#   * /daemon/connect without a key     -> 401 (POST and the GET upgrade)
#   * POST /api/computer/attach         -> machine key
#   * /daemon/connect with that key     -> 101 + machine:context frame
#
# Every check prints exactly one `PASS ...` line. The last line is `smoke: PASS`.
# Any failure prints `FAIL ...`, the server log tail, and exits non-zero.
#
# Usage:  scripts/smoke-server.sh
# Env:    SWIFT=/path/to/swift   override the toolchain (defaults to the pinned 6.4.1)
#         SMOKE_KEEP=1           keep the temporary directory with the server log
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SWIFT_BIN="${SWIFT:-/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift}"
SERVER_BIN="$REPO_ROOT/.build/debug/RaftServer"

if [[ ! -x "$SWIFT_BIN" ]]; then
    echo "FAIL swift toolchain not executable: $SWIFT_BIN" >&2
    echo "smoke: FAIL" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/raft-smoke.XXXXXX")"
SERVER_LOG="$TMP_DIR/server.log"
CHECK_LOG="$TMP_DIR/check.log"
STATE_FILE="$TMP_DIR/state.json"
SERVER_PID=""
SERVER_PGID=""
CHECKS_PASSED=0

cleanup() {
    local status=$?
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        # Kill the whole process group when the server is its own group leader;
        # fall back to the single process + descendants otherwise.
        if [[ -n "$SERVER_PGID" && "$SERVER_PGID" == "$SERVER_PID" ]]; then
            kill -TERM -- "-$SERVER_PGID" 2>/dev/null || true
        else
            local child
            for child in $(pgrep -P "$SERVER_PID" 2>/dev/null || true); do
                kill -TERM "$child" 2>/dev/null || true
            done
            kill -TERM "$SERVER_PID" 2>/dev/null || true
        fi
        for _ in $(seq 1 40); do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            if [[ -n "$SERVER_PGID" && "$SERVER_PGID" == "$SERVER_PID" ]]; then
                kill -KILL -- "-$SERVER_PGID" 2>/dev/null || true
            fi
            kill -KILL "$SERVER_PID" 2>/dev/null || true
        fi
    fi
    if [[ $status -ne 0 && -f "$SERVER_LOG" ]]; then
        echo "--- server log (tail) ---" >&2
        tail -n 40 "$SERVER_LOG" >&2 || true
        echo "--- end server log ---" >&2
    fi
    if [[ "${SMOKE_KEEP:-0}" == "1" ]]; then
        echo "smoke artifacts kept in: $TMP_DIR" >&2
    else
        rm -rf "$TMP_DIR"
    fi
    exit "$status"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
pass() { printf 'PASS %s\n' "$*"; }
fail() {
    printf 'FAIL %s\n' "$*" >&2
    echo "smoke: FAIL" >&2
    exit 1
}

# --- check runner -----------------------------------------------------------
#
# run_check "<label>" <command...>
# Runs the command. Its stdout carries one `PASS` line per assertion; its stderr
# carries the failure diagnostic. A non-zero exit fails the whole smoke.
run_check() {
    local label="$1"
    shift
    local out_file="$TMP_DIR/check.out"
    local err_file="$TMP_DIR/check.err"
    : >"$out_file"
    : >"$err_file"
    local rc=0
    "$@" >"$out_file" 2>"$err_file" || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf 'FAIL %s\n' "$label" >&2
        if [[ -s "$out_file" ]]; then
            cat "$out_file" >&2
        fi
        if [[ -s "$err_file" ]]; then
            cat "$err_file" >&2
        fi
        echo "smoke: FAIL" >&2
        exit 1
    fi
    cat "$out_file"
    local passed
    passed="$(grep -c '^PASS ' "$out_file" || true)"
    CHECKS_PASSED=$((CHECKS_PASSED + passed))
}

# Wait for an HTTP endpoint to accept connections (the ready line is printed
# just before `app.start()` binds the listener).
wait_for_http() {
    local port="$1"
    local deadline=$((SECONDS + 15))
    while ((SECONDS < deadline)); do
        if python3 - "$port" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.5)
s.close()
PY
        then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

free_ports() {
    python3 - <<'PY'
import socket
sockets = []
ports = []
for _ in range(3):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    sockets.append(s)
    ports.append(s.getsockname()[1])
print(" ".join(str(p) for p in ports))
for s in sockets:
    s.close()
PY
}

start_server() {
    local ports
    ports="$(free_ports)"
    read -r HTTP_PORT SOCKET_PORT DAEMON_CONNECT_PORT <<<"$ports"
    if [[ -z "${HTTP_PORT:-}" || -z "${SOCKET_PORT:-}" || -z "${DAEMON_CONNECT_PORT:-}" ]]; then
        fail "could not allocate three free loopback ports"
    fi

    : >"$SERVER_LOG"
    # `setsid` puts the server in a fresh session so the EXIT trap can signal
    # the whole group. DATABASE_URL is explicitly removed: /health must stay at
    # 503 `database unreachable` for the in-memory store.
    env -u DATABASE_URL \
        PORT="$HTTP_PORT" \
        SOCKET_PORT="$SOCKET_PORT" \
        DAEMON_CONNECT_PORT="$DAEMON_CONNECT_PORT" \
        NODE_ENV=test \
        SLOCK_E2E_AUTO_VERIFY_EMAIL=1 \
        JWT_SECRET="smoke-jwt-secret" \
        SERVER_URL="http://127.0.0.1:$HTTP_PORT" \
        setsid "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    SERVER_PGID="$(ps -o pgid= -p "$SERVER_PID" 2>/dev/null | tr -d ' ' || true)"

    local ready_pattern='raft-server ready http=127\.0\.0\.1:[0-9]+ daemon-connect=127\.0\.0\.1:[0-9]+ realtime=127\.0\.0\.1:[0-9]+'
    local deadline=$((SECONDS + 20))
    while ((SECONDS < deadline)); do
        if grep -qE "$ready_pattern" "$SERVER_LOG" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            return 1
        fi
        sleep 0.1
    done
    return 1
}

# --- 1. build ---------------------------------------------------------------
say "smoke: building .build/debug/RaftServer with $("$SWIFT_BIN" --version 2>/dev/null | head -n1)"
if ! (cd "$REPO_ROOT" && "$SWIFT_BIN" build --product RaftServer) >"$TMP_DIR/build.log" 2>&1; then
    echo "FAIL swift build --product RaftServer" >&2
    tail -n 40 "$TMP_DIR/build.log" >&2 || true
    echo "smoke: FAIL" >&2
    exit 1
fi
[[ -x "$SERVER_BIN" ]] || fail "build succeeded but $SERVER_BIN is missing"
pass "build .build/debug/RaftServer"

# --- 2. start ---------------------------------------------------------------
started=0
for attempt in 1 2; do
    if start_server; then
        started=1
        break
    fi
    echo "server did not become ready on attempt $attempt; restarting with fresh ports" >&2
    if [[ -n "$SERVER_PID" ]]; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        sleep 0.2
        kill -KILL "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
        SERVER_PGID=""
    fi
done
if [[ $started -ne 1 ]]; then
    fail "server did not print a ready line within 20s"
fi
READY_LINE="$(grep -E 'raft-server ready' "$SERVER_LOG" | tail -n1)"
# Trust the line's port values: they are the bound ports.
HTTP_PORT="$(sed -E 's/.*http=127\.0\.0\.1:([0-9]+).*/\1/' <<<"$READY_LINE")"
DAEMON_PORT="$(sed -E 's/.*daemon-connect=127\.0\.0\.1:([0-9]+).*/\1/' <<<"$READY_LINE")"
REALTIME_PORT="$(sed -E 's/.*realtime=127\.0\.0\.1:([0-9]+).*/\1/' <<<"$READY_LINE")"
[[ -n "$HTTP_PORT" && -n "$DAEMON_PORT" && -n "$REALTIME_PORT" ]] || fail "could not parse ready line: $READY_LINE"

wait_for_http "$HTTP_PORT" || fail "HTTP listener on 127.0.0.1:$HTTP_PORT never accepted a connection"
pass "ready line: $READY_LINE"

# --- 3. helpers -------------------------------------------------------------
cat >"$TMP_DIR/smoke_checks.py" <<'PY'
"""Checks for scripts/smoke-server.sh. Python 3 stdlib only.

Each subcommand is one published contract. Success prints `PASS ...` on stdout
and exits 0; failure prints `FAIL ...` plus a diagnostic on stderr and exits 1.
Cross-check values (token, server id, channel id, ...) ride in $SMOKE_STATE.
"""

import json
import os
import socket
import struct
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime

HTTP_PORT = int(os.environ["SMOKE_HTTP_PORT"])
SOCKET_PORT = int(os.environ["SMOKE_SOCKET_PORT"])
DAEMON_PORT = int(os.environ["SMOKE_DAEMON_PORT"])
BASE = f"http://127.0.0.1:{HTTP_PORT}"
STATE_PATH = os.environ["SMOKE_STATE"]
WS_KEY = "dGhlIHNhbXBsZSBub25jZQ=="


def load_state():
    try:
        with open(STATE_PATH, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {}


def save_state(state):
    with open(STATE_PATH, "w", encoding="utf-8") as handle:
        json.dump(state, handle)


def ok(message):
    print(f"PASS {message}", flush=True)


def die(message):
    print(f"FAIL {message}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def http(method, path, token=None, server_id=None, body=None, timeout=15):
    headers = {}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if server_id:
        headers["X-Server-Id"] = server_id
    request = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def http_json(method, path, **kwargs):
    status, raw = http(method, path, **kwargs)
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        parsed = None
    return status, raw, parsed


def expect_json(status, raw, parsed, expected_status, label):
    if status != expected_status:
        die(f"{label}: expected HTTP {expected_status}, got {status}: {raw[:500]!r}")
    if not isinstance(parsed, dict):
        die(f"{label}: response is not a JSON object: {raw[:500]!r}")
    return parsed


# --- checks -----------------------------------------------------------------

def check_livez():
    deadline = time.time() + 10
    status = None
    raw = b""
    while time.time() < deadline:
        try:
            status, raw = http("GET", "/livez", timeout=2)
            break
        except (urllib.error.URLError, ConnectionError, OSError):
            time.sleep(0.1)
    if status is None:
        die("GET /livez: listener never answered")
    if status != 200:
        die(f"GET /livez: expected 200, got {status}: {raw[:300]!r}")
    payload = json.loads(raw)
    if payload.get("status") != "ok":
        die(f"GET /livez: expected status=ok, got {raw[:300]!r}")
    ok("GET /livez -> 200 status=ok")


def check_health():
    status, raw = http("GET", "/health")
    expected = b'{"status":"error","detail":"database unreachable"}'
    if status != 503:
        die(f"GET /health: expected 503, got {status}: {raw[:300]!r}")
    if raw != expected:
        die(f"GET /health: expected body {expected!r}, got {raw[:300]!r}")
    ok('GET /health -> 503 {"status":"error","detail":"database unreachable"}')


def check_version():
    status, raw, parsed = http_json("GET", "/api/version")
    if status == 200:
        parsed = expect_json(status, raw, parsed, 200, "GET /api/version")
        missing = [key for key in ("version", "sha", "builtAt", "branch") if not isinstance(parsed.get(key), str) or not parsed[key]]
        if missing:
            die(f"GET /api/version: 200 body missing ready keys {missing}: {raw[:400]!r}")
        ok("GET /api/version -> 200 ready identity " + json.dumps(parsed, sort_keys=True))
        return
    if status == 503:
        parsed = expect_json(status, raw, parsed, 503, "GET /api/version")
        if parsed.get("code") != "build_identity_unavailable":
            die(f"GET /api/version: 503 without build_identity_unavailable: {raw[:400]!r}")
        required = ("error", "code", "detail", "sha", "builtAt", "branch")
        missing = [key for key in required if key not in parsed]
        if missing:
            die(f"GET /api/version: 503 body missing documented keys {missing}: {raw[:400]!r}")
        ok("GET /api/version -> 503 build_identity_unavailable " + json.dumps(parsed, sort_keys=True))
        return
    die(f"GET /api/version: expected 200 or 503, got {status}: {raw[:400]!r}")


def complete_profile(token, registered_user, email, display_name, label):
    """Use the normal profile endpoint; registration's name is only a suggestion."""
    if not isinstance(registered_user, dict) or registered_user.get("emailVerified") is not True:
        die(f"{label}: registration did not publish verified user facts")
    user_id = registered_user.get("id")
    pending_name = registered_user.get("name")
    if not isinstance(user_id, str) or not user_id or registered_user.get("email") != email:
        die(f"{label}: registration user identity is missing or mismatched")
    if not isinstance(pending_name, str) or not pending_name.lower().startswith("pending_"):
        die(f"{label}: registration must retain a pending profile")
    if "profileSetupCompletedAt" not in registered_user or registered_user["profileSetupCompletedAt"] is not None:
        die(f"{label}: registration completion stamp must be explicit null")
    status, raw, parsed = http_json(
        "POST", "/api/servers", token=token,
        body={"name": "Admission Probe", "slug": "smoke-admission-probe"},
    )
    blocked = expect_json(status, raw, parsed, 403, label + " pending-profile business refusal")
    if blocked.get("code") != "PROFILE_SETUP_REQUIRED":
        die(f"{label}: verified pending profile was not refused by the profile gate")
    name = "smoke-profile-" + uuid.uuid4().hex[:12]
    status, raw, parsed = http_json(
        "POST", "/api/auth/me/complete-profile", token=token,
        body={"name": name, "displayName": display_name},
    )
    completed = expect_json(status, raw, parsed, 200, label + " complete-profile")
    stamp = completed.get("profileSetupCompletedAt")
    if completed.get("name") != name or completed.get("displayName") != display_name or not isinstance(stamp, str):
        die(f"{label}: complete-profile public fields do not match the request")
    try:
        if datetime.fromisoformat(stamp.replace("Z", "+00:00")).tzinfo is None:
            raise ValueError("missing timezone")
    except ValueError:
        die(f"{label}: completion timestamp is not a timezone-qualified ISO date")
    if "user" in completed:
        die(f"{label}: complete-profile must return the flat public user without a nested wrapper")
    user = completed
    expected = {"id": user_id, "email": email, "name": name, "displayName": display_name,
                "emailVerified": True, "profileSetupCompletedAt": stamp}
    if not isinstance(user, dict) or any(user.get(key) != value for key, value in expected.items()):
        die(f"{label}: complete-profile flat user does not match persisted admission facts")
    status, raw, parsed = http_json("GET", "/api/auth/me", token=token)
    persisted = expect_json(status, raw, parsed, 200, label + " completed GET /api/auth/me")
    if persisted != user:
        die(f"{label}: GET /api/auth/me differs from the completed public user")
    ok(label + " POST /api/auth/me/complete-profile -> 200 stored verified profile")


def check_register():
    state = load_state()
    email = f"smoke-{uuid.uuid4().hex[:12]}@slock.test"
    body = {
        "email": email,
        "password": "password123",
        "name": "smoke-owner",
        "acceptTerms": True,
        "termsVersion": "2026-05-12",
        "privacyVersion": "2026-05-12",
        "__e2eAutoVerify": True,
    }
    status, raw, parsed = http_json("POST", "/api/auth/register", body=body)
    parsed = expect_json(status, raw, parsed, 200, "POST /api/auth/register")
    token = parsed.get("accessToken")
    if not isinstance(token, str) or not token:
        die(f"POST /api/auth/register: no accessToken in {raw[:400]!r}")
    complete_profile(token, parsed.get("user"), email, "Smoke Owner", "smoke owner")
    state.update({"token": token, "email": email})
    save_state(state)
    ok("POST /api/auth/register -> 200 accessToken")


def check_create_server():
    state = load_state()
    token = state.get("token")
    if not token:
        die("POST /api/servers: no token in state; register check did not run")
    slug = f"smoke-{uuid.uuid4().hex[:8]}"
    status, raw, parsed = http_json(
        "POST", "/api/servers", token=token, body={"name": "Smoke Server", "slug": slug}
    )
    parsed = expect_json(status, raw, parsed, 200, "POST /api/servers")
    server_id = parsed.get("id")
    if not isinstance(server_id, str) or not server_id:
        die(f"POST /api/servers: no id in {raw[:400]!r}")
    if parsed.get("slug") not in (slug, None):
        die(f"POST /api/servers: unexpected slug {parsed.get('slug')!r}")
    state.update({"serverId": server_id, "slug": slug})
    save_state(state)
    ok("POST /api/servers -> 200 id " + server_id)


def check_create_channel():
    state = load_state()
    token, server_id = state.get("token"), state.get("serverId")
    if not token or not server_id:
        die("POST /api/channels: missing token or server id in state")
    status, raw, parsed = http_json(
        "POST",
        "/api/channels",
        token=token,
        server_id=server_id,
        body={"name": "smoke-room", "description": "created by scripts/smoke-server.sh"},
    )
    parsed = expect_json(status, raw, parsed, 200, "POST /api/channels")
    channel_id = parsed.get("id")
    if not isinstance(channel_id, str) or not channel_id:
        die(f"POST /api/channels: no id in {raw[:400]!r}")
    state["channelId"] = channel_id
    save_state(state)
    ok("POST /api/channels -> 200 id " + channel_id)


def check_create_agent():
    state = load_state()
    token, server_id = state.get("token"), state.get("serverId")
    if not token or not server_id:
        die("POST /api/agents: missing token or server id in state")
    status, raw, parsed = http_json(
        "POST",
        "/api/agents",
        token=token,
        server_id=server_id,
        body={"name": "smoke-agent", "external": True},
    )
    parsed = expect_json(status, raw, parsed, 200, "POST /api/agents")
    agent_id = parsed.get("id")
    if not isinstance(agent_id, str) or not agent_id:
        die(f"POST /api/agents: no id in {raw[:400]!r}")
    state.update({"agentId": agent_id, "agentName": "smoke-agent"})
    save_state(state)
    ok("POST /api/agents -> 200 external agent id " + agent_id)


def check_agent_credential():
    state = load_state()
    token, agent_id = state.get("token"), state.get("agentId")
    if not token or not agent_id:
        die("POST /api/agents/:id/credentials: missing token or agent id in state")
    status, raw, parsed = http_json(
        "POST",
        f"/api/agents/{agent_id}/credentials",
        token=token,
        body={"scopes": ["channels", "read", "send"]},
    )
    parsed = expect_json(status, raw, parsed, 201, "POST /api/agents/:id/credentials")
    api_key = parsed.get("apiKey")
    if not isinstance(api_key, str) or not api_key.startswith("sk_agent_"):
        die(f"POST /api/agents/:id/credentials: unexpected apiKey {api_key!r}")
    state["agentKey"] = api_key
    save_state(state)
    ok("POST /api/agents/:id/credentials -> 201 agent key")


def check_add_agent_member():
    state = load_state()
    token, server_id = state.get("token"), state.get("serverId")
    channel_id, agent_id = state.get("channelId"), state.get("agentId")
    if not token or not server_id or not channel_id or not agent_id:
        die("POST /api/channels/:id/members: incomplete state")
    status, raw, parsed = http_json(
        "POST",
        f"/api/channels/{channel_id}/members",
        token=token,
        server_id=server_id,
        body={"agentId": agent_id},
    )
    parsed = expect_json(status, raw, parsed, 200, "POST /api/channels/:id/members")
    ok("POST /api/channels/:id/members -> 200 agent joined")


def check_agent_send():
    state = load_state()
    api_key, channel_name = state.get("agentKey"), "smoke-room"
    if not api_key:
        die("POST /internal/agent-api/send: no agent key in state")
    content = f"smoke message {uuid.uuid4().hex[:12]}"
    status, raw, parsed = http_json(
        "POST",
        "/internal/agent-api/send",
        token=api_key,
        body={"target": f"#{channel_name}", "content": content},
    )
    parsed = expect_json(status, raw, parsed, 200, "POST /internal/agent-api/send")
    message_id = parsed.get("messageId") or parsed.get("id")
    if not isinstance(message_id, str) or not message_id:
        die(f"POST /internal/agent-api/send: no messageId in {raw[:400]!r}")
    state.update({"messageId": message_id, "messageContent": content})
    save_state(state)
    ok("POST /internal/agent-api/send (agent principal) -> 200 id " + message_id)


def check_human_send_gate():
    state = load_state()
    server_id, channel_id = state.get("serverId"), state.get("channelId")
    if not server_id or not channel_id:
        die("POST /api/messages: incomplete state")
    # The owner now completes admission. Keep this negative on a distinct real
    # registration with an explicit false request opt-in under the same test env.
    email = f"smoke-unverified-{uuid.uuid4().hex[:12]}@slock.test"
    status, raw, parsed = http_json("POST", "/api/auth/register", body={
        "email": email, "password": "password123", "name": "unverified-human",
        "acceptTerms": True, "termsVersion": "2026-05-12", "privacyVersion": "2026-05-12",
        "__e2eAutoVerify": False,
    })
    registered = expect_json(status, raw, parsed, 200, "unverified-human register")
    token = registered.get("accessToken")
    user = registered.get("user")
    if not isinstance(token, str) or not token or not isinstance(user, dict) or user.get("emailVerified") is not False:
        die("unverified-human register did not retain the explicit non-opt-in verification state")
    status, raw, parsed = http_json("GET", "/api/auth/me", token=token)
    persisted = expect_json(status, raw, parsed, 200, "unverified-human GET /api/auth/me")
    if persisted.get("emailVerified") is not False or persisted.get("id") != user.get("id"):
        die("unverified-human GET /api/auth/me did not retain the registered identity and false verification")
    status, raw, parsed = http_json(
        "POST",
        "/api/messages",
        token=token,
        server_id=server_id,
        body={"channelId": channel_id, "content": "unverified human post"},
    )
    if status != 403:
        die(f"POST /api/messages unverified human: expected the upstream requireVerified 403, got {status}: {raw[:400]!r}")
    error = (parsed or {}).get("error")
    if error != "Email verification required":
        die(f"POST /api/messages unverified human: unexpected 403 body {raw[:400]!r}")
    ok("POST /api/messages unverified human -> 403 Email verification required (upstream requireVerified gate)")


def check_verified_human_roundtrip():
    """A real human, auto-verified by the E2E double gate, sends a live message.

    Registration passes `__e2eAutoVerify: True` while the server runs with
    SLOCK_E2E_AUTO_VERIFY_EMAIL=1, so the account lands verified. The human then
    joins the owner's server through a join link, joins the channel, connects a
    socket.io client, posts, reads the message back over HTTP, and receives the
    live `42["message:new", ...]` frame.
    """
    state = load_state()
    owner_token = state.get("token")
    server_id, channel_id = state.get("serverId"), state.get("channelId")
    if not owner_token or not server_id or not channel_id:
        die("verified-human roundtrip: incomplete state")

    email = f"smoke-verified-{uuid.uuid4().hex[:12]}@slock.test"
    register_body = {
        "email": email,
        "password": "password123",
        "name": "verified-human",
        "acceptTerms": True,
        "termsVersion": "2026-05-12",
        "privacyVersion": "2026-05-12",
        "__e2eAutoVerify": True,
    }
    status, raw, parsed = http_json("POST", "/api/auth/register", body=register_body)
    parsed = expect_json(status, raw, parsed, 200, "verified-human register")
    token = parsed.get("accessToken")
    user = parsed.get("user") if isinstance(parsed.get("user"), dict) else {}
    user_id = user.get("id")
    if not isinstance(token, str) or not token:
        die(f"verified-human register: no accessToken in {raw[:400]!r}")
    if not isinstance(user_id, str) or not user_id:
        die(f"verified-human register: no user id in {raw[:400]!r}")
    if user.get("emailVerified") is not True:
        die(f"verified-human register: __e2eAutoVerify did not verify the user: {raw[:500]!r}")

    status, raw, parsed = http_json("GET", "/api/auth/me", token=token)
    parsed = expect_json(status, raw, parsed, 200, "verified-human GET /api/auth/me")
    if parsed.get("emailVerified") is not True:
        die(f"verified-human GET /api/auth/me: emailVerified is not true: {raw[:500]!r}")
    ok("POST /api/auth/register (SLOCK_E2E_AUTO_VERIFY_EMAIL=1 + __e2eAutoVerify) -> 200 verified human")
    complete_profile(token, user, email, "Verified Human", "verified human")

    # Join the owner's server with a real join link, then join the channel.
    status, raw, parsed = http_json(
        "POST", f"/api/servers/{server_id}/join-links", token=owner_token, server_id=server_id, body={}
    )
    parsed = expect_json(status, raw, parsed, 200, "verified-human POST /api/servers/:id/join-links")
    join_token = parsed.get("token")
    if not isinstance(join_token, str) or not join_token:
        die(f"verified-human join link: no token in {raw[:400]!r}")

    status, raw, parsed = http_json(
        "POST", "/api/auth/accept-invite", token=token, body={"token": join_token}
    )
    expect_json(status, raw, parsed, 200, "verified-human POST /api/auth/accept-invite")

    status, raw, parsed = http_json(
        "POST",
        f"/api/channels/{channel_id}/members",
        token=owner_token,
        server_id=server_id,
        body={"userId": user_id},
    )
    expect_json(status, raw, parsed, 200, "verified-human POST /api/channels/:id/members")
    ok("verified human joined the server and channel")

    sock, status_line, leftover = open_websocket(SOCKET_PORT, "/socket.io/?EIO=4&transport=websocket")
    try:
        if "101" not in status_line:
            die(f"verified-human socket.io: expected 101 upgrade, got {status_line!r}")
        ws = WebSocket(sock)
        ws.buffer = leftover

        def read_text(timeout_seconds=10.0):
            deadline = time.time() + timeout_seconds
            while time.time() < deadline:
                try:
                    opcode, payload = ws.read_frame()
                except socket.timeout:
                    continue
                if opcode == 0x1:
                    return payload.decode("utf-8", "replace")
                if opcode == 0x9:  # ping -> pong
                    ws.sock.sendall(bytes([0x8A, 0x80]) + b"\x00\x00\x00\x00")
            return None

        opened = read_text()
        if opened is None or not opened.startswith("0{"):
            die(f"verified-human socket.io: no Engine.IO open frame, got {opened!r}")
        ws.send_text("40" + json.dumps({"token": token, "serverId": server_id}, separators=(",", ":")))
        connected = read_text()
        if connected is None or not connected.startswith("40{"):
            die(f"verified-human socket.io: no connect frame, got {connected!r}")
        joined = read_text()
        if joined != '42["rooms:joined"]':
            die(f"verified-human socket.io: expected rooms:joined, got {joined!r}")

        content = f"smoke verified human message {uuid.uuid4().hex[:12]}"
        status, raw, parsed = http_json(
            "POST",
            "/api/messages",
            token=token,
            server_id=server_id,
            body={"channelId": channel_id, "content": content},
        )
        # Upstream `createHumanMessage` answers `res.json(...)`, i.e. 200.
        parsed = expect_json(status, raw, parsed, 200, "verified-human POST /api/messages")
        message_id = parsed.get("id")
        if not isinstance(message_id, str) or not message_id:
            die(f"verified-human POST /api/messages: no message id in {raw[:400]!r}")
        if parsed.get("content") != content:
            die(f"verified-human POST /api/messages: content mismatch {raw[:400]!r}")
        ok("POST /api/messages verified human -> 200 message id " + message_id)

        status, raw, parsed = http_json(
            "GET", f"/api/messages/channel/{channel_id}?limit=50", token=token, server_id=server_id
        )
        parsed = expect_json(status, raw, parsed, 200, "verified-human GET /api/messages/channel")
        messages = parsed.get("messages")
        if not isinstance(messages, list):
            die(f"verified-human GET /api/messages/channel: no messages array in {raw[:400]!r}")
        match = next(
            (row for row in messages if isinstance(row, dict) and row.get("id") == message_id),
            None,
        )
        if match is None:
            die(f"verified-human GET /api/messages/channel: sent message {message_id} not in {len(messages)} rows")
        if match.get("content") != content:
            die(f"verified-human GET /api/messages/channel: content mismatch {match.get('content')!r}")
        ok(f"GET /api/messages/channel/{{id}} -> 200 verified human message visible ({len(messages)} rows)")

        # The live frame must carry the same message id on `channel:<id>`.
        ws.sock.settimeout(0.5)
        live = None
        deadline = time.time() + 10
        while time.time() < deadline:
            frame = read_text(timeout_seconds=1.0)
            if frame is None:
                continue
            if frame.startswith('42["message:new"') and message_id in frame:
                live = frame
                break
        if live is None:
            die(f"verified-human socket.io: no live message:new frame for {message_id}")
        ok('socket.io 42["message:new", ...] -> live verified human message')
    finally:
        sock.close()


def check_list_messages():
    state = load_state()
    token, server_id = state.get("token"), state.get("serverId")
    channel_id, message_id = state.get("channelId"), state.get("messageId")
    content = state.get("messageContent")
    if not all((token, server_id, channel_id, message_id, content)):
        die("GET /api/messages/channel: incomplete state")
    status, raw, parsed = http_json(
        "GET",
        f"/api/messages/channel/{channel_id}?limit=50",
        token=token,
        server_id=server_id,
    )
    parsed = expect_json(status, raw, parsed, 200, "GET /api/messages/channel")
    messages = parsed.get("messages")
    if not isinstance(messages, list):
        die(f"GET /api/messages/channel: no messages array in {raw[:400]!r}")
    match = next(
        (row for row in messages if isinstance(row, dict) and row.get("id") == message_id),
        None,
    )
    if match is None:
        die(f"GET /api/messages/channel: sent message {message_id} not in {len(messages)} rows")
    if match.get("content") != content:
        die(f"GET /api/messages/channel: content mismatch: {match.get('content')!r} != {content!r}")
    ok(f"GET /api/messages/channel/{{id}} -> 200 sent message visible to the human ({len(messages)} rows)")


def check_attach_computer():
    state = load_state()
    token, server_id, slug = state.get("token"), state.get("serverId"), state.get("slug")
    if not token or not server_id or not slug:
        die("POST /api/computer/attach: missing token, server id or slug in state")
    status, raw, parsed = http_json(
        "POST",
        "/api/computer/attach",
        token=token,
        server_id=server_id,
        body={"serverSlug": slug, "name": "smoke-computer"},
    )
    parsed = expect_json(status, raw, parsed, 201, "POST /api/computer/attach")
    api_key = parsed.get("apiKey")
    machine_id = parsed.get("machineId")
    if not isinstance(api_key, str) or not api_key.startswith("sk_computer_"):
        die(f"POST /api/computer/attach: unexpected apiKey {api_key!r}")
    if not isinstance(machine_id, str) or not machine_id:
        die(f"POST /api/computer/attach: no machineId in {raw[:400]!r}")
    state.update({"apiKey": api_key, "machineId": machine_id})
    save_state(state)
    ok("POST /api/computer/attach -> 201 computer key " + machine_id)


# --- raw socket helpers -----------------------------------------------------

def read_until(sock, marker, deadline_seconds=8.0, max_bytes=1 << 20):
    buffer = b""
    sock.settimeout(0.5)
    deadline = time.time() + deadline_seconds
    while marker not in buffer and time.time() < deadline:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            break
        buffer += chunk
        if len(buffer) > max_bytes:
            break
    return buffer


def read_available(sock, seconds=5.0, stop_marker=None, max_bytes=1 << 20):
    buffer = b""
    sock.settimeout(0.25)
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            if buffer:
                # one quiet interval after the first byte is enough for the
                # daemon prelude + context frame, which arrive together
                break
            continue
        if not chunk:
            break
        buffer += chunk
        if stop_marker is not None and stop_marker in buffer:
            break
        if len(buffer) > max_bytes:
            break
    return buffer


class WebSocket:
    """Minimal RFC6455 client framing over an established socket."""

    def __init__(self, sock):
        self.sock = sock
        self.buffer = b""
        self.sock.settimeout(8.0)

    def _recv_exact(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise EOFError("socket closed while reading a frame")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def read_frame(self):
        first, second = self._recv_exact(2)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._recv_exact(8))[0]
        mask = self._recv_exact(4) if masked else None
        payload = self._recv_exact(length)
        if mask is not None:
            payload = bytes(payload[i] ^ mask[i % 4] for i in range(length))
        return opcode, payload

    def send_text(self, text):
        payload = text.encode("utf-8")
        mask = b"\x12\x34\x56\x78"
        header = bytes([0x81])
        size = len(payload)
        if size < 126:
            header += bytes([0x80 | size])
        elif size <= 0xFFFF:
            header += bytes([0x80 | 126]) + struct.pack(">H", size)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", size)
        self.sock.sendall(header + mask + bytes(payload[i] ^ mask[i % 4] for i in range(size)))


def open_websocket(port, path, headers=None):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    request = [
        f"GET {path} HTTP/1.1",
        f"Host: 127.0.0.1:{port}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Version: 13",
        f"Sec-WebSocket-Key: {WS_KEY}",
    ]
    for key, value in (headers or {}).items():
        request.append(f"{key}: {value}")
    sock.sendall(("\r\n".join(request) + "\r\n\r\n").encode("utf-8"))
    head = read_until(sock, b"\r\n\r\n")
    if b"\r\n\r\n" not in head:
        sock.close()
        raise RuntimeError(f"no HTTP upgrade response, got {head[:200]!r}")
    status_line = head.split(b"\r\n", 1)[0]
    leftover = head.split(b"\r\n\r\n", 1)[1]
    return sock, status_line.decode("latin-1"), leftover


def check_socketio():
    state = load_state()
    token, server_id = state.get("token"), state.get("serverId")
    if not token or not server_id:
        die("socket.io: missing token or server id in state")

    sock, status_line, leftover = open_websocket(SOCKET_PORT, "/socket.io/?EIO=4&transport=websocket")
    try:
        if "101" not in status_line:
            die(f"socket.io: expected 101 upgrade, got {status_line!r}")
        ws = WebSocket(sock)
        ws.buffer = leftover

        frames = []

        def collect(count, deadline_seconds=10.0):
            deadline = time.time() + deadline_seconds
            while len(frames) < count and time.time() < deadline:
                opcode, payload = ws.read_frame()
                if opcode == 0x1:
                    frames.append(payload.decode("utf-8", "replace"))
                elif opcode == 0x9:  # ping -> pong
                    ws.sock.sendall(bytes([0x8A, 0x80]) + b"\x00\x00\x00\x00")
            return len(frames) >= count

        if not collect(1):
            die("socket.io: no Engine.IO open frame within 10s")
        if not frames[0].startswith("0{"):
            die(f"socket.io: Engine.IO open frame does not start with '0{{': {frames[0][:200]!r}")
        ok("socket.io open frame starts with 0{")

        ws.send_text("40" + json.dumps({"token": token, "serverId": server_id}, separators=(",", ":")))
        if not collect(2):
            die("socket.io: no socket.io CONNECT frame within 10s")
        connect = next((frame for frame in frames[1:] if frame.startswith("40{")), None)
        if connect is None:
            die(f"socket.io: missing 40{{...}} connect frame; got {frames[1:]!r}")
        ok("socket.io 40 connect frame")

        if not collect(3):
            die(f"socket.io: no rooms:joined event within 10s; frames={frames!r}")
        joined = next((frame for frame in frames[1:] if frame == '42["rooms:joined"]'), None)
        if joined is None:
            die(f'socket.io: missing 42["rooms:joined"]; got {frames[1:]!r}')
        ok('socket.io 42["rooms:joined"]')
    finally:
        sock.close()


def _daemon_probe(method):
    sock = socket.create_connection(("127.0.0.1", DAEMON_PORT), timeout=5)
    request = (
        f"{method} /daemon/connect HTTP/1.1\r\n"
        "Host: 127.0.0.1\r\n"
        "Connection: Upgrade\r\n"
        "Upgrade: websocket\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Sec-WebSocket-Key: {WS_KEY}\r\n"
        "\r\n"
    )
    sock.sendall(request.encode("utf-8"))
    data = read_available(sock, seconds=5.0)
    sock.close()
    return data.decode("latin-1", "replace")


def check_daemon_missing_key():
    for method in ("POST", "GET"):
        data = _daemon_probe(method)
        if not data.startswith("HTTP/1.1 401 Unauthorized"):
            die(f"{method} /daemon/connect: expected 401, got {data[:300]!r}")
        if "Slock-Reason: missing_key" not in data:
            die(f"{method} /daemon/connect: expected Slock-Reason: missing_key, got {data[:300]!r}")
        ok(f"{method} /daemon/connect without key -> 401 missing_key")


def check_daemon_with_key():
    state = load_state()
    api_key, machine_id, server_id = state.get("apiKey"), state.get("machineId"), state.get("serverId")
    if not api_key or not machine_id or not server_id:
        die("/daemon/connect: missing machine credentials in state")
    sock = socket.create_connection(("127.0.0.1", DAEMON_PORT), timeout=5)
    try:
        request = (
            "GET /daemon/connect HTTP/1.1\r\n"
            "Host: 127.0.0.1\r\n"
            "Connection: Upgrade\r\n"
            "Upgrade: websocket\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Sec-WebSocket-Key: {WS_KEY}\r\n"
            f"Authorization: Bearer {api_key}\r\n"
            "\r\n"
        )
        sock.sendall(request.encode("utf-8"))
        data = read_until(sock, b"\r\n\r\n")
        text = data.decode("latin-1", "replace")
        if not text.startswith("HTTP/1.1 101 Switching Protocols"):
            die(f"/daemon/connect: expected 101, got {text[:300]!r}")
        if b"\r\n\r\n" not in data:
            die(f"/daemon/connect: incomplete HTTP upgrade prelude {text[:300]!r}")
        ws = WebSocket(sock)
        ws.buffer = data.split(b"\r\n\r\n", 1)[1]
        opcode, payload = ws.read_frame()
        if opcode != 0x1:
            die(f"/daemon/connect: expected a text context frame, got opcode {opcode}")
        text = payload.decode("utf-8")
        if '"type":"machine:context"' not in text:
            die(f'/daemon/connect: no machine:context frame; got {text[:500]!r}')
        if f'"machineId":"{machine_id}"' not in text:
            die(f"/daemon/connect: machine:context missing machineId {machine_id}: {text[:500]!r}")
        if f'"serverId":"{server_id}"' not in text:
            die(f"/daemon/connect: machine:context missing serverId {server_id}: {text[:500]!r}")
        context = json.loads(text)
        if not isinstance(context, dict) or context.get("type") != "machine:context" or context.get("machineId") != machine_id or context.get("serverId") != server_id:
            die(f"/daemon/connect: malformed or mismatched context object {text[:500]!r}")
    finally:
        sock.close()
    ok("/daemon/connect with machine key -> 101 + machine:context frame")


CHECKS = {
    "livez": check_livez,
    "health": check_health,
    "version": check_version,
    "register": check_register,
    "create-server": check_create_server,
    "create-channel": check_create_channel,
    "create-agent": check_create_agent,
    "agent-credential": check_agent_credential,
    "add-agent-member": check_add_agent_member,
    "agent-send": check_agent_send,
    "human-send-gate": check_human_send_gate,
    "verified-human-roundtrip": check_verified_human_roundtrip,
    "list-messages": check_list_messages,
    "socketio": check_socketio,
    "daemon-missing-key": check_daemon_missing_key,
    "attach-computer": check_attach_computer,
    "daemon-with-key": check_daemon_with_key,
}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in CHECKS:
        print("usage: smoke_checks.py <" + "|".join(CHECKS) + ">", file=sys.stderr)
        raise SystemExit(2)
    CHECKS[sys.argv[1]]()


if __name__ == "__main__":
    main()
PY

export SMOKE_HTTP_PORT="$HTTP_PORT"
export SMOKE_SOCKET_PORT="$REALTIME_PORT"
export SMOKE_DAEMON_PORT="$DAEMON_PORT"
export SMOKE_STATE="$STATE_FILE"
checks_py="$TMP_DIR/smoke_checks.py"

# --- 4. checks --------------------------------------------------------------
run_check "GET /livez -> 200"                 python3 "$checks_py" livez
run_check "GET /health -> 503"                python3 "$checks_py" health
run_check "GET /api/version -> published shape" python3 "$checks_py" version
run_check "POST /api/auth/register"           python3 "$checks_py" register
run_check "POST /api/servers"                 python3 "$checks_py" create-server
run_check "POST /api/channels"                python3 "$checks_py" create-channel
run_check "POST /api/agents"                  python3 "$checks_py" create-agent
run_check "POST /api/agents/:id/credentials"  python3 "$checks_py" agent-credential
run_check "POST /api/channels/:id/members"    python3 "$checks_py" add-agent-member
run_check "POST /internal/agent-api/send"     python3 "$checks_py" agent-send
run_check "GET /api/messages/channel/:id"     python3 "$checks_py" list-messages
run_check "POST /api/messages (unverified)"   python3 "$checks_py" human-send-gate
run_check "verified human message roundtrip"  python3 "$checks_py" verified-human-roundtrip
run_check "socket.io handshake + rooms:joined" python3 "$checks_py" socketio
run_check "daemon/connect without key"        python3 "$checks_py" daemon-missing-key
run_check "POST /api/computer/attach"         python3 "$checks_py" attach-computer
run_check "daemon/connect with machine key"   python3 "$checks_py" daemon-with-key

say ""
say "smoke: PASS (${CHECKS_PASSED} checks)"
