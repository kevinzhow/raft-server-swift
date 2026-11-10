#!/usr/bin/env bash
#
# Upgrade rehearsal for the connected first-server onboarding batch.
#
# Runs the OLD released RaftServer on a throwaway PostgreSQL 17 + Redis, writes
# an owner account/session/server through published HTTP, then starts the NEW
# build from this repository on the same database and verifies that the old
# state is restored and that new onboarding facts survive another restart.
#
# Every credential used here is generated at runtime. This script never reads
# a production secrets file, never targets the production containers and uses
# only loopback ports. The throwaway PostgreSQL/Redis containers are removed on
# exit; logs and the report are kept under $RAFT_UPGRADE_TMPDIR.
#
# Requirements: docker, curl, python3, a Swift 6.4.1 toolchain.
#
# Environment overrides:
#   SWIFT                              swift executable
#   RAFT_UPGRADE_OLD_SERVER_BIN        old release executable
#   RAFT_UPGRADE_OLD_SWIFT_RUNTIME     old release swift-runtime directory
#   RAFT_UPGRADE_NEW_SERVER_BIN        new executable (defaults to scratch build)
#   RAFT_UPGRADE_SCRATCH               SwiftPM scratch path
#   RAFT_UPGRADE_CACHE                 SwiftPM cache path
#   RAFT_UPGRADE_TMPDIR                artifact directory
#   RAFT_UPGRADE_PG_IMAGE              PostgreSQL image (must be 17)
#   RAFT_UPGRADE_REDIS_IMAGE           Redis image
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SWIFT_BIN="${SWIFT:-/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift}"
OLD_SERVER_BIN="${RAFT_UPGRADE_OLD_SERVER_BIN:-/mnt/data/services/raft-swift/releases/swift/1c40fe5b4b00f81b788f86222577dec2cd0700d5/RaftServer}"
OLD_SWIFT_RUNTIME="${RAFT_UPGRADE_OLD_SWIFT_RUNTIME:-/mnt/data/services/raft-swift/releases/swift/1c40fe5b4b00f81b788f86222577dec2cd0700d5/swift-runtime}"
SCRATCH_PATH="${RAFT_UPGRADE_SCRATCH:-/mnt/data/raft-swift-development/scratch/pg-acceptance}"
CACHE_PATH="${RAFT_UPGRADE_CACHE:-/mnt/data/raft-swift-development/cache/swiftpm}"
NEW_SERVER_BIN="${RAFT_UPGRADE_NEW_SERVER_BIN:-$SCRATCH_PATH/debug/RaftServer}"
PG_IMAGE="${RAFT_UPGRADE_PG_IMAGE:-postgres:17-alpine}"
REDIS_IMAGE="${RAFT_UPGRADE_REDIS_IMAGE:-redis:7-alpine}"
TMP_BASE="${RAFT_UPGRADE_TMPDIR:-/mnt/data/raft-swift-development/tmp/batch-pg-acceptance}"
STAMP="$(date +%Y%m%dT%H%M%S)-$(python3 -c 'import uuid;print(uuid.uuid4().hex[:6])')"
RUN_DIR="$TMP_BASE/upgrade-rehearsal-$STAMP"
REPORT="$RUN_DIR/report.log"
PG_NAME="raft-batch-upgrade-pg-$STAMP"
REDIS_NAME="raft-batch-upgrade-redis-$STAMP"
PG_PASSWORD="raftbatch$(python3 -c 'import uuid;print(uuid.uuid4().hex[:16])')"
OLD_PID=""
NEW_PID=""

mkdir -p "$RUN_DIR"
exec > >(tee -a "$REPORT") 2>&1

say() { printf '%s\n' "$*"; }
pass() { printf 'PASS %s\n' "$*"; }
fail() {
    printf 'FAIL %s\n' "$*" >&2
    printf 'upgrade-rehearsal: FAIL\n' >&2
    printf 'artifacts: %s\n' "$RUN_DIR" >&2
    exit 1
}

stop_pid() {
    local pid="$1"
    [[ -n "$pid" ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 100); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
    local status=$?
    trap - EXIT
    stop_pid "$NEW_PID"
    stop_pid "$OLD_PID"
    docker rm -f "$PG_NAME" "$REDIS_NAME" >/dev/null 2>&1 || true
    if [[ $status -ne 0 ]]; then
        printf 'upgrade-rehearsal: FAIL (status %s); artifacts: %s\n' "$status" "$RUN_DIR" >&2
    else
        printf 'upgrade-rehearsal: PASS; artifacts: %s\n' "$RUN_DIR"
    fi
    exit "$status"
}
trap cleanup EXIT

free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
}

json_field() {
    # json_field <file> <dotted.path>
    python3 - "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding='utf-8'))
for part in sys.argv[2].split('.'):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value.get(part) if isinstance(value, dict) else None
    if value is None:
        break
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(',', ':')))
elif value is True:
    print('true')
elif value is False:
    print('false')
elif value is None:
    print('null')
else:
    print(value)
PY
}

require_value() {
    local value="$1" label="$2"
    [[ -n "$value" && "$value" != "null" ]] || fail "response omitted $label"
}

http() {
    # http <method> <path> [token] [serverId] [body-file]
    local method="$1" path="$2" token="${3:-}" server_id="${4:-}" body_file="${5:-}"
    local args=(-sS -o "$RUN_DIR/response.json" -w '%{http_code}' -X "$method" -H 'Content-Type: application/json')
    if [[ -n "$token" ]]; then args+=(-H "Authorization: Bearer $token"); fi
    if [[ -n "$server_id" ]]; then args+=(-H "X-Server-Id: $server_id"); fi
    if [[ -n "$body_file" ]]; then args+=(--data-binary "@$body_file"); fi
    HTTP_STATUS="$(curl "${args[@]}" "$BASE_URL$path" || true)"
    HTTP_BODY="$RUN_DIR/response.json"
}

BASE_URL=""
start_server() {
    # start_server <binary> <log> <http-port> <socket-port> <daemon-port> <mode old|new>
    local binary="$1" log="$2" http_port="$3" socket_port="$4" daemon_port="$5" mode="$6"
    local env_file="$RUN_DIR/$mode.env"
    cat >"$env_file" <<EOF
NODE_ENV=production
DATABASE_URL=$DATABASE_URL
REDIS_URL=$REDIS_URL
JWT_SECRET=$JWT_SECRET
CREDENTIAL_ENCRYPTION_KEY=$CREDENTIAL_ENCRYPTION_KEY
RAFT_EMAIL_PROVIDER=resend
FROM_EMAIL=raft@example.invalid
APP_URL=https://app.example.invalid
RESEND_API_KEY=$RESEND_API_KEY
ATTACHMENT_STORAGE_PROVIDER=s3
S3_BUCKET=raft-upgrade-attachments
S3_ACCESS_KEY_ID=raftupgradeaccept
S3_SECRET_ACCESS_KEY=raftupgradesecret
ATTACHMENT_ENCRYPTION_KEY=$CREDENTIAL_ENCRYPTION_KEY
S3_ENDPOINT=https://s3.example.invalid
SERVER_URL=https://server.example.invalid
HTTP_HOST=127.0.0.1
SOCKET_HOST=127.0.0.1
DAEMON_CONNECT_HOST=127.0.0.1
PORT=$http_port
SOCKET_PORT=$socket_port
DAEMON_CONNECT_PORT=$daemon_port
TRACE_UPLOAD_DISABLED=1
TMPDIR=$RUN_DIR/$mode-tmp
XDG_CACHE_HOME=$RUN_DIR/$mode-cache
EOF
    mkdir -p "$RUN_DIR/$mode-tmp" "$RUN_DIR/$mode-cache"
    local env_args=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && env_args+=("$line")
    done <"$env_file"
    if [[ "$mode" == "old" ]]; then
        env "${env_args[@]}" \
            LD_LIBRARY_PATH="$OLD_SWIFT_RUNTIME/lib/swift/linux:$OLD_SWIFT_RUNTIME/lib/native" \
            setsid "$binary" >>"$log" 2>&1 < /dev/null &
    else
        env "${env_args[@]}" setsid "$binary" >>"$log" 2>&1 < /dev/null &
    fi
    local pid=$!
    if [[ "$mode" == "old" ]]; then OLD_PID=$pid; else NEW_PID=$pid; fi
    BASE_URL="http://127.0.0.1:$http_port"
    local deadline=$((SECONDS + 30))
    while ((SECONDS < deadline)); do
        if grep -q 'raft-server ready' "$log" 2>/dev/null; then return 0; fi
        if ! kill -0 "$pid" 2>/dev/null; then
            tail -n 30 "$log" >&2 || true
            fail "$mode server exited before printing its ready line"
        fi
        sleep 0.1
    done
    tail -n 30 "$log" >&2 || true
    fail "$mode server did not print its ready line"
}

wait_health() {
    local deadline=$((SECONDS + 30))
    while ((SECONDS < deadline)); do
        local status
        status="$(curl -sS -o "$RUN_DIR/health.json" -w '%{http_code}' "$BASE_URL/health" || true)"
        if [[ "$status" == "200" ]]; then return 0; fi
        sleep 0.1
    done
    tail -n 30 "$RUN_DIR/new-1.log" >&2 || true
    fail "server never returned /health 200"
}

register_user() {
    # register_user <email> <name> <body-file>
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
body = {
    "email": sys.argv[1], "password": "upgrade-password-123456", "name": sys.argv[2],
    "acceptTerms": True, "termsVersion": "2026-05-12", "privacyVersion": "2026-05-12",
}
json.dump(body, open(sys.argv[3], 'w'))
PY
}

verify_from_outbox() {
    # verify_from_outbox <expected-email>
    local expected_email="$1" intent=""
    for _ in $(seq 1 60); do
        docker exec "$PG_NAME" psql -U raft -d raft -Atc \
            "select convert_from(payload,'UTF8') from raft_persistence.durable_outbox where kind='auth.verify-email.v1' order by sequence desc limit 1" \
            >"$RUN_DIR/verify-intent.json" 2>/dev/null || true
        if [[ -s "$RUN_DIR/verify-intent.json" ]] && \
           python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d["recipientEmail"].lower()==sys.argv[2].lower() else 1)' \
               "$RUN_DIR/verify-intent.json" "$expected_email" 2>/dev/null; then
            intent="$RUN_DIR/verify-intent.json"
            break
        fi
        sleep 0.1
    done
    [[ -n "$intent" ]] || fail "verification intent for $expected_email not found in throwaway outbox"
    TOKEN="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["rawToken"])' "$intent")"
    python3 - "$TOKEN" "$RUN_DIR/verify-body.json" <<'PY'
import json, sys
json.dump({"token": sys.argv[1]}, open(sys.argv[2], 'w'))
PY
    http POST /api/auth/verify-email "" "" "$RUN_DIR/verify-body.json"
    [[ "$HTTP_STATUS" == "200" ]] || fail "POST /api/auth/verify-email returned $HTTP_STATUS"
}

complete_profile() {
    # complete_profile <token> <name>
    python3 - "$2" "$RUN_DIR/profile-body.json" <<'PY'
import json, sys
json.dump({"name": sys.argv[1], "displayName": "Upgrade Owner"}, open(sys.argv[2], 'w'))
PY
    http POST /api/auth/me/complete-profile "$1" "" "$RUN_DIR/profile-body.json"
    [[ "$HTTP_STATUS" == "200" ]] || fail "complete-profile returned $HTTP_STATUS"
}

# --- 1. throwaway dependencies ---------------------------------------------
say "upgrade-rehearsal: artifacts under $RUN_DIR"
command -v docker >/dev/null || fail "docker is required"
command -v curl >/dev/null || fail "curl is required"
command -v python3 >/dev/null || fail "python3 is required"
[[ -x "$OLD_SERVER_BIN" ]] || fail "old release executable is missing: $OLD_SERVER_BIN"
[[ -x "$SWIFT_BIN" ]] || fail "swift toolchain is missing: $SWIFT_BIN"

PG_PORT="$(free_port)"
REDIS_PORT="$(free_port)"
DATABASE_URL="postgres://raft:$PG_PASSWORD@127.0.0.1:$PG_PORT/raft?sslmode=disable"
REDIS_URL="redis://127.0.0.1:$REDIS_PORT/0"
JWT_SECRET="upgrade-rehearsal-jwt-$(python3 -c 'import uuid;print(uuid.uuid4().hex)')"
CREDENTIAL_ENCRYPTION_KEY="$(python3 -c 'import base64;print(base64.b64encode(bytes([65])*32).decode())')"
RESEND_API_KEY="re_upgrade_rehearsal_$(python3 -c 'import uuid;print(uuid.uuid4().hex)')"

docker run -d --name "$PG_NAME" \
    -e POSTGRES_USER=raft -e POSTGRES_PASSWORD="$PG_PASSWORD" -e POSTGRES_DB=raft \
    -p "127.0.0.1:$PG_PORT:5432" "$PG_IMAGE" >/dev/null
docker run -d --name "$REDIS_NAME" -p "127.0.0.1:$REDIS_PORT:6379" "$REDIS_IMAGE" >/dev/null
for _ in $(seq 1 480); do
    if docker exec "$PG_NAME" pg_isready -U raft -d raft >/dev/null 2>&1; then break; fi
    sleep 0.25
done
for _ in $(seq 1 240); do
    if docker exec "$REDIS_NAME" redis-cli ping 2>/dev/null | grep -q PONG; then break; fi
    sleep 0.25
done
# The image entrypoint runs a temporary init server and then restarts
# PostgreSQL. One successful pg_isready can hit that temporary server and the
# next connection then fails while the final server starts, so require a stable
# window before the rehearsal uses the container.
PG_READY_CHECKS=0
for _ in $(seq 1 80); do
    if docker exec "$PG_NAME" pg_isready -U raft -d raft >/dev/null 2>&1; then
        PG_READY_CHECKS=$((PG_READY_CHECKS + 1))
        [[ "$PG_READY_CHECKS" -ge 8 ]] && break
    else
        PG_READY_CHECKS=0
    fi
    sleep 0.25
done
[[ "$PG_READY_CHECKS" -ge 8 ]] || {
    docker logs "$PG_NAME" 2>&1 | tail -n 30 >&2 || true
    fail "throwaway PostgreSQL did not become ready"
}
docker exec "$REDIS_NAME" redis-cli ping 2>/dev/null | grep -q PONG || {
    docker logs "$REDIS_NAME" 2>&1 | tail -n 20 >&2 || true
    fail "throwaway Redis did not become ready"
}
pass "throwaway PostgreSQL 17 and Redis started ($PG_NAME, $REDIS_NAME)"

# --- 2. old binary: real account, session and server ------------------------
OLD_HTTP="$(free_port)"; OLD_SOCKET="$(free_port)"; OLD_DAEMON="$(free_port)"
: >"$RUN_DIR/old.log"
start_server "$OLD_SERVER_BIN" "$RUN_DIR/old.log" "$OLD_HTTP" "$OLD_SOCKET" "$OLD_DAEMON" old
wait_health
pass "old release binary started on throwaway PostgreSQL"

OWNER_EMAIL="upgrade-owner-$STAMP@example.invalid"
OWNER_NAME="upgrade-owner-$STAMP"
register_user "$OWNER_EMAIL" "Upgrade Owner" "$RUN_DIR/register-owner.json"
http POST /api/auth/register "" "" "$RUN_DIR/register-owner.json"
[[ "$HTTP_STATUS" == "200" ]] || fail "old-binary register returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/owner-register-response.json"
OWNER_ACCESS="$(json_field "$RUN_DIR/owner-register-response.json" accessToken)"
OWNER_REFRESH="$(json_field "$RUN_DIR/owner-register-response.json" refreshToken)"
OWNER_ID="$(json_field "$RUN_DIR/owner-register-response.json" user.id)"
require_value "$OWNER_ACCESS" "accessToken"
require_value "$OWNER_REFRESH" "refreshToken"
require_value "$OWNER_ID" "user.id"
verify_from_outbox "$OWNER_EMAIL"
complete_profile "$OWNER_ACCESS" "$OWNER_NAME"
SERVER_SLUG="upgrade-server-$STAMP"
python3 - "$SERVER_SLUG" "$RUN_DIR/create-server.json" <<'PY'
import json, sys
json.dump({"name": "Upgrade Server", "slug": sys.argv[1]}, open(sys.argv[2], 'w'))
PY
http POST /api/servers "$OWNER_ACCESS" "" "$RUN_DIR/create-server.json"
[[ "$HTTP_STATUS" == "200" ]] || fail "old-binary create server returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/owner-server-response.json"
SERVER_ID="$(json_field "$RUN_DIR/owner-server-response.json" id)"
require_value "$SERVER_ID" "id"
http GET /api/servers "$OWNER_ACCESS"
[[ "$HTTP_STATUS" == "200" ]] || fail "old-binary server list returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/old-server-list.json"
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if any(s.get("id")==sys.argv[2] for s in d) else 1)' \
    "$RUN_DIR/old-server-list.json" "$SERVER_ID" || fail "old-binary list did not contain the created server"
pass "old binary registered/verified an owner, completed profile, created server $SERVER_ID"

# A second old-binary user with no server is the canonical empty-collection case.
NOSERVER_EMAIL="upgrade-noserver-$STAMP@example.invalid"
register_user "$NOSERVER_EMAIL" "Upgrade No Server" "$RUN_DIR/register-noserver.json"
http POST /api/auth/register "" "" "$RUN_DIR/register-noserver.json"
[[ "$HTTP_STATUS" == "200" ]] || fail "old-binary second register returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/noserver-register-response.json"
NOSERVER_ACCESS="$(json_field "$RUN_DIR/noserver-register-response.json" accessToken)"
require_value "$NOSERVER_ACCESS" "accessToken"
verify_from_outbox "$NOSERVER_EMAIL"
complete_profile "$NOSERVER_ACCESS" "upgrade-noserver-$STAMP"
pass "old binary created a verified, profile-complete user without a server"

stop_pid "$OLD_PID"; OLD_PID=""
pass "old release binary stopped"

# --- 3. new binary on the same database ------------------------------------
say "upgrade-rehearsal: building new RaftServer"
mkdir -p "$(dirname "$NEW_SERVER_BIN")" "$(dirname "$CACHE_PATH")"
(
    export TMPDIR="$TMP_BASE"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/mnt/data/raft-swift-development/cache}"
    cd "$REPO_ROOT"
    "$SWIFT_BIN" build --scratch-path "$SCRATCH_PATH" --cache-path "$CACHE_PATH" \
        -j 4 --force-resolved-versions --product RaftServer
) >"$RUN_DIR/build-new.log" 2>&1 \
    || { tail -n 60 "$RUN_DIR/build-new.log"; fail "new RaftServer build failed"; }
[[ -x "$NEW_SERVER_BIN" ]] || fail "new RaftServer binary is missing after build"
pass "new RaftServer built"

NEW_HTTP="$(free_port)"; NEW_SOCKET="$(free_port)"; NEW_DAEMON="$(free_port)"
: >"$RUN_DIR/new-1.log"
start_server "$NEW_SERVER_BIN" "$RUN_DIR/new-1.log" "$NEW_HTTP" "$NEW_SOCKET" "$NEW_DAEMON" new
wait_health
pass "new binary started on the old database"

python3 - "$OWNER_EMAIL" "$RUN_DIR/login-owner.json" <<'PY'
import json, sys
json.dump({"email": sys.argv[1], "password": "upgrade-password-123456"}, open(sys.argv[2], 'w'))
PY
http POST /api/auth/login "" "" "$RUN_DIR/login-owner.json"
[[ "$HTTP_STATUS" == "200" ]] || fail "new-binary login with old password returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/new-owner-login.json"
NEW_ACCESS="$(json_field "$RUN_DIR/new-owner-login.json" accessToken)"
require_value "$NEW_ACCESS" "accessToken"
pass "old password still logs in on the new binary"

python3 - "$OWNER_REFRESH" "$RUN_DIR/refresh-owner.json" <<'PY'
import json, sys
json.dump({"refreshToken": sys.argv[1]}, open(sys.argv[2], 'w'))
PY
http POST /api/auth/refresh "" "" "$RUN_DIR/refresh-owner.json"
[[ "$HTTP_STATUS" == "200" ]] || fail "old refresh token returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/new-refresh.json"
REFRESHED_ACCESS="$(json_field "$RUN_DIR/new-refresh.json" accessToken)"
require_value "$REFRESHED_ACCESS" "accessToken"
pass "old refresh token still rotates on the new binary"

http GET /api/auth/me "$REFRESHED_ACCESS"
[[ "$HTTP_STATUS" == "200" ]] || fail "new-binary me returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/new-me-before-survey.json"
ROLE_BEFORE="$(json_field "$RUN_DIR/new-me-before-survey.json" signupRole)"
SURVEY_BEFORE="$(json_field "$RUN_DIR/new-me-before-survey.json" signupSurveyCompletedAt)"
[[ "$ROLE_BEFORE" == "null" ]] || fail "old account unexpectedly had signupRole=$ROLE_BEFORE"
[[ "$SURVEY_BEFORE" == "null" ]] || fail "old account unexpectedly had signupSurveyCompletedAt=$SURVEY_BEFORE"
pass "old account me reports signupRole null and signupSurveyCompletedAt null"

http GET /api/servers "$NEW_ACCESS"
[[ "$HTTP_STATUS" == "200" ]] || fail "new-binary server list returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/new-server-list.json"
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if any(s.get("id")==sys.argv[2] and s.get("slug")==sys.argv[3] for s in d) else 1)' \
    "$RUN_DIR/new-server-list.json" "$SERVER_ID" "$SERVER_SLUG" || fail "new-binary list did not retain the old server"
pass "new binary lists the old server $SERVER_ID"

python3 - "$RUN_DIR/survey-body.json" <<'PY'
import json, sys
json.dump({"signupRole": "founder"}, open(sys.argv[1], 'w'))
PY
http PATCH /api/auth/me "$NEW_ACCESS" "" "$RUN_DIR/survey-body.json"
[[ "$HTTP_STATUS" == "200" ]] || fail "PATCH signupRole returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/new-survey-response.json"
SURVEY_AT="$(json_field "$RUN_DIR/new-survey-response.json" signupSurveyCompletedAt)"
ROLE_AT="$(json_field "$RUN_DIR/new-survey-response.json" signupRole)"
[[ "$ROLE_AT" == "founder" && "$SURVEY_AT" != "null" ]] || fail "PATCH signupRole did not publish retained values"
pass "PATCH /api/auth/me signupRole wrote founder and $SURVEY_AT"

stop_pid "$NEW_PID"; NEW_PID=""
NEW_HTTP="$(free_port)"; NEW_SOCKET="$(free_port)"; NEW_DAEMON="$(free_port)"
: >"$RUN_DIR/new-2.log"
start_server "$NEW_SERVER_BIN" "$RUN_DIR/new-2.log" "$NEW_HTTP" "$NEW_SOCKET" "$NEW_DAEMON" new
wait_health
http POST /api/auth/login "" "" "$RUN_DIR/login-owner.json"
[[ "$HTTP_STATUS" == "200" ]] || fail "post-restart login returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/new-owner-login-2.json"
NEW_ACCESS_2="$(json_field "$RUN_DIR/new-owner-login-2.json" accessToken)"
require_value "$NEW_ACCESS_2" "accessToken"
http GET /api/auth/me "$NEW_ACCESS_2"
[[ "$HTTP_STATUS" == "200" ]] || fail "post-restart me returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/new-me-after-restart.json"
ROLE_AFTER="$(json_field "$RUN_DIR/new-me-after-restart.json" signupRole)"
SURVEY_AFTER="$(json_field "$RUN_DIR/new-me-after-restart.json" signupSurveyCompletedAt)"
[[ "$ROLE_AFTER" == "founder" ]] || fail "signupRole not retained across restart ($ROLE_AFTER)"
[[ "$SURVEY_AFTER" == "$SURVEY_AT" ]] || fail "signupSurveyCompletedAt changed across restart ($SURVEY_AT -> $SURVEY_AFTER)"
pass "signupRole and signupSurveyCompletedAt retained across new-binary restart"

http GET /api/servers "$NEW_ACCESS_2"
[[ "$HTTP_STATUS" == "200" ]] || fail "post-restart server list returned $HTTP_STATUS"
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if any(s.get("id")==sys.argv[2] for s in d) else 1)' \
    "$RUN_DIR/response.json" "$SERVER_ID" || fail "post-restart list did not retain the server"
pass "old server still listed after new-binary restart"

# The old-binary user with no membership must receive a bare 200 [].
python3 - "$NOSERVER_EMAIL" "$RUN_DIR/login-noserver.json" <<'PY'
import json, sys
json.dump({"email": sys.argv[1], "password": "upgrade-password-123456"}, open(sys.argv[2], 'w'))
PY
http POST /api/auth/login "" "" "$RUN_DIR/login-noserver.json"
[[ "$HTTP_STATUS" == "200" ]] || fail "no-server user login returned $HTTP_STATUS"
cp "$HTTP_BODY" "$RUN_DIR/noserver-login-new.json"
NOSERVER_ACCESS_NEW="$(json_field "$RUN_DIR/noserver-login-new.json" accessToken)"
require_value "$NOSERVER_ACCESS_NEW" "accessToken"
http GET /api/servers "$NOSERVER_ACCESS_NEW"
[[ "$HTTP_STATUS" == "200" ]] || fail "no-server GET /api/servers returned $HTTP_STATUS"
cmp -s "$HTTP_BODY" <(printf '[]') || fail "no-server GET /api/servers body was not bare []"
pass "old-binary user without a server gets 200 [] from the new binary"

stop_pid "$NEW_PID"; NEW_PID=""
pass "upgrade rehearsal completed"
say "upgrade-rehearsal: PASS"
say "artifacts: $RUN_DIR"
