#!/usr/bin/env python3
"""Scripted acceptance against a running Raft deployment.

Replaces slow browser-only acceptance for the API surface. The browser stays
for visual confirmation only.

Checks, in order:

  1. health and build identity             GET /health, GET /api/version
  2. owner login                           POST /api/auth/login
  3. owner token refresh                   POST /api/auth/refresh
  4. server collection                     GET /api/servers
  5. read-only sweep                       GET-only requests; the durable DB
                                           revision rows must not change
  6. DM reply                              POST /api/channels/dm, message, wait
  7. channel @mention reply                message with a mention, wait
  8. task create (asTask), board, history  message asTask, board, task history
  9. attachment upload/download/preview     multipart upload, bytes, preview URL
 10. attachment read by the real agent     upload a nonce text file, send it to
                                           the DM agent, require the exact nonce
                                           in two consecutive replies
 11. thread reply + thread:updated         Socket.IO frame assertion
 12. optional --restart-main               unit restart, reconnect, delivery

Failure policy (replaces "stop at first defect"): stop only for an outage
(/health unavailable or 503), a possible data corruption (read-only sweep moved
persisted revisions) or a security signal. Every other failure is recorded and
the run continues; checks that depend on a failed step are reported BLOCKED.

Configuration comes from the local deployment env file (git-ignored):

  ACCEPTANCE_BASE_URL
  ACCEPTANCE_SOCKET_URL
  ACCEPTANCE_OWNER_CREDENTIAL_FILE
  ACCEPTANCE_PG_CONTAINER        optional, for the revision sweep
  ACCEPTANCE_DATABASE            optional, for the revision sweep
  ACCEPTANCE_SERVICE_UNIT        optional, for --restart-main

Run ``--dry-run`` to print every check without touching the network. The
default mode is read-only: message-sending checks require ``--full``.

Exit status is non-zero when any check FAILS or the run aborts.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from client import HTTPClient, HTTPResult, WebSocketClient, multipart  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ENV_FILE = REPO_ROOT / "deploy" / "swift-production" / "local.env"
DEFAULT_REPLY_TIMEOUT = 120.0


class Failure(Exception):
    """A recorded defect. The run continues."""


class Skip(Exception):
    """The check cannot run here; it is not a failure."""


class Outage(Exception):
    """Stop the run: the service is unavailable."""


class Corruption(Exception):
    """Stop the run: persisted state changed during a read-only sweep."""


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


ATTACHMENT_READ_INSTRUCTION = (
    "Read the attached text file and reply with the exact token it contains. "
    "The token is the file's only content; do not guess or invent one. "
    "The attachment id is {attachment_id}. Download it with "
    "`raft attachment view --id {attachment_id} --output ./{filename}` "
    "(or your attachment viewer), then read that file. "
    "Write the output inside your current workspace using that relative path; "
    "do not write it to /tmp or anywhere outside the workspace."
)


def new_nonce() -> str:
    """A random marker the agent can only learn by reading the attachment.

    The marker is independent of the filename and the instruction, so neither
    the human prompt nor the filename can leak it.
    """
    return "acceptance-read-" + secrets.token_hex(8)


def make_attachment_read_case(index: int) -> dict[str, str]:
    """One round of the agent attachment-read proof.

    ``instruction`` is a template; the caller fills in the attachment id after
    the upload. The random nonce is never part of it.
    """
    nonce = new_nonce()
    filename = f"acceptance-read-{int(time.time())}-{index}-{secrets.token_hex(3)}.txt"
    instruction = ATTACHMENT_READ_INSTRUCTION
    content = nonce + "\n"
    if nonce in instruction or nonce in filename or nonce not in content:
        raise RuntimeError("attachment-read case leaked or lost its hidden nonce")
    return {
        "nonce": nonce,
        "filename": filename,
        "content": content,
        "instruction": instruction,
    }


def find_correlated_reply(
    rows: list[dict],
    agent_id: str,
    after_seq: int,
    expect_text: str | None = None,
) -> dict | None:
    """Return the first agent reply newer than ``after_seq``.

    ``expect_text`` turns the reply into a correlation check: an unrelated
    agent message, a reply to an earlier prompt, or a replay of the previous
    round's token cannot satisfy the wait.
    """
    for row in rows:
        if not isinstance(row, dict):
            continue
        seq = row.get("seq")
        if not isinstance(seq, int) or seq <= after_seq:
            continue
        if row.get("senderId") != agent_id:
            continue
        content = row.get("content")
        if not isinstance(content, str):
            continue
        if expect_text is not None and expect_text not in content:
            continue
        return row
    return None


SECRET_KEYS = ("token", "password", "secret", "authorization", "apikey", "api_key", "credential")


def redact(value):
    """Never write tokens or passwords into the acceptance report."""
    if isinstance(value, dict):
        return {
            key: ("<redacted>" if any(marker in key.lower() for marker in SECRET_KEYS) else redact(item))
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :]
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key.strip()] = value
    return values


def expect_json(result: HTTPResult, path: str) -> dict | list:
    if not (200 <= result.status < 300):
        raise Failure(f"{path} -> HTTP {result.status}: {result.text[:400]}")
    try:
        return result.json()
    except json.JSONDecodeError:
        raise Failure(f"{path} -> non-JSON body: {result.text[:200]!r}") from None


class Acceptance:
    def __init__(self, options: argparse.Namespace):
        self.options = options
        self.base_url = options.base_url.rstrip("/")
        socket_url = options.socket_url or self.base_url
        if socket_url.startswith("http"):
            parsed = urllib.parse.urlparse(socket_url)
            socket_url = f"ws://{parsed.netloc}/socket.io/?EIO=4&transport=websocket"
        self.socket_url = socket_url
        self.http = HTTPClient(self.base_url, timeout=options.http_timeout)
        self.context: dict = {}
        self.results: list[dict] = []
        self.stopped: str | None = None
        self.started_at = utc_now()
        self.started_clock = time.monotonic()
        self.socket: WebSocketClient | None = None

    # -- recording -------------------------------------------------------
    def record(self, check: str, status: str, detail: str, data: dict | None = None) -> None:
        entry = {"check": check, "status": status, "detail": detail, "at": utc_now()}
        if data:
            entry["data"] = redact(data)
        self.results.append(entry)
        print(f"{status:<8} {check:<22} {detail}", flush=True)

    def run(self, name: str, function, *, needs: tuple[str, ...] = ()) -> None:
        if self.stopped:
            self.record(name, "BLOCKED", f"run stopped: {self.stopped}")
            return
        missing = [key for key in needs if not self.context.get(key)]
        if missing:
            self.record(name, "BLOCKED", "missing prerequisite: " + ", ".join(missing))
            return
        try:
            data = function()
        except Skip as error:
            self.record(name, "SKIP", str(error))
        except Failure as error:
            self.record(name, "FAIL", str(error))
        except Outage as error:
            self.stopped = f"outage: {error}"
            self.record(name, "FAIL", f"OUTAGE: {error}")
        except Corruption as error:
            self.stopped = f"possible corruption: {error}"
            self.record(name, "FAIL", f"CORRUPTION: {error}")
        except (ConnectionError, TimeoutError, PermissionError, OSError) as error:
            self.stopped = f"outage: {error}"
            self.record(name, "FAIL", f"OUTAGE: {error}")
        else:
            self.record(name, "PASS", data.pop("detail", "ok"), data or None)
            self.context.update(data)

    # -- individual checks ----------------------------------------------
    def check_health(self) -> dict:
        health = self.http.request("GET", "/health")
        if health.status == 503:
            raise Outage(f"/health 503 {health.text[:200]}")
        if health.status != 200:
            raise Failure(f"/health -> {health.status} {health.text[:200]}")
        body = expect_json(health, "/health")
        version = self.http.request("GET", "/api/version")
        parsed = expect_json(version, "/api/version")
        if not parsed.get("sha"):
            raise Failure(f"/api/version has no sha: {version.text[:200]}")
        expected = self.options.expect_sha
        if expected and not str(parsed.get("sha", "")).startswith(expected):
            raise Failure(f"/api/version sha {parsed.get('sha')!r} does not match expected {expected!r}")
        return {
            "detail": f"health ok; version {parsed.get('version')} sha {str(parsed.get('sha'))[:8]}",
            "health": body,
            "version": parsed,
        }

    def check_login(self) -> dict:
        path = self.options.owner_credentials
        if not path:
            raise Skip("no owner credential file configured")
        credential_path = Path(path)
        if not credential_path.is_file():
            raise Skip(f"owner credential file not found: {credential_path}")
        credentials = json.loads(credential_path.read_text(encoding="utf-8"))
        if credentials.get("accessToken") and not credentials.get("password"):
            return {
                "detail": "using the owner session token from the credential file",
                "access_token": credentials["accessToken"],
                "refresh_token": credentials.get("refreshToken"),
                "user_id": credentials.get("userId"),
            }
        email = credentials.get("email")
        password = credentials.get("password")
        if not email or not password:
            raise Skip("owner credential file has neither accessToken nor email/password")
        result = self.http.request("POST", "/api/auth/login", {"email": email, "password": password})
        if result.status in (401, 403):
            raise Failure(f"POST /api/auth/login rejected the owner credential ({result.status})")
        body = expect_json(result, "POST /api/auth/login")
        if not body.get("accessToken"):
            raise Failure(f"login response has no accessToken: {result.text[:300]}")
        user = body.get("user") or {}
        return {
            "detail": f"owner login ok (user {str(user.get('id'))[:8]})",
            "access_token": body["accessToken"],
            "refresh_token": body.get("refreshToken"),
            "user_id": user.get("id"),
        }

    def check_refresh(self) -> dict:
        if not self.context.get("refresh_token"):
            raise Skip("login did not return a refresh token")
        result = self.http.request("POST", "/api/auth/refresh", {"refreshToken": self.context["refresh_token"]})
        if result.status in (401, 403):
            raise Failure(f"POST /api/auth/refresh rejected the owner refresh token ({result.status})")
        body = expect_json(result, "POST /api/auth/refresh")
        if not body.get("accessToken"):
            raise Failure(f"refresh response has no accessToken: {result.text[:300]}")
        return {
            "detail": "owner token refresh ok",
            "access_token": body["accessToken"],
            "refresh_token": body.get("refreshToken", self.context.get("refresh_token")),
        }

    def auth_headers(self, server_id: str | None = None) -> dict[str, str]:
        headers = {"Authorization": f"Bearer {self.context['access_token']}"}
        if server_id:
            headers["X-Server-Id"] = server_id
        return headers

    def check_servers(self) -> dict:
        result = self.http.request("GET", "/api/servers", headers=self.auth_headers())
        body = expect_json(result, "GET /api/servers")
        servers = body if isinstance(body, list) else body.get("servers", [])
        if not isinstance(servers, list):
            raise Failure(f"GET /api/servers unexpected shape: {result.text[:200]}")
        owned = [row for row in servers if row.get("role") == "owner"]
        if not servers:
            raise Failure("owner has no servers (GET /api/servers returned [])")
        if not owned:
            raise Failure("owner is not the owner of any server")
        server = owned[0]
        if not server.get("id"):
            raise Failure(f"server row has no id: {server}")
        return {
            "detail": f"{len(servers)} servers; using {server.get('slug') or server.get('name')}",
            "server_id": server["id"],
            "server_name": server.get("name"),
            "server_slug": server.get("slug"),
        }

    def db_snapshot(self) -> list[str] | None:
        if not self.options.pg_container or not self.options.database:
            return None
        if re.fullmatch(r"[A-Za-z0-9_]+", self.options.database) is None:
            raise Failure("ACCEPTANCE_DATABASE is not a plain identifier")
        sql = (
            "select domain || '|' || aggregate_key || '|' || revision "
            "from raft_persistence.durable_domain_rows order by 1"
        )
        command = [
            "docker",
            "exec",
            self.options.pg_container,
            "sh",
            "-c",
            f'psql -U "$POSTGRES_USER" -d {self.options.database} -Atc "{sql}"',
        ]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise Skip(f"database revision snapshot unavailable: {error}")
        if result.returncode != 0:
            raise Skip(f"database revision snapshot unavailable: {result.stderr.strip()[:200]}")
        return [line for line in result.stdout.splitlines() if line.strip()]

    def check_readonly_sweep(self) -> dict:
        before = self.db_snapshot()
        requests = ["/health", "/api/version", "/api/servers", "/api/channels", "/api/channels/dm", "/api/agents", "/api/auth/me"]
        statuses: dict[str, int] = {}
        for path in requests:
            result = self.http.request("GET", path, headers=self.auth_headers(self.context.get("server_id")))
            statuses[path] = result.status
            if result.status >= 500:
                raise Outage(f"read-only GET {path} -> {result.status}")
        after = self.db_snapshot()
        if before is not None and after is not None and before != after:
            changed = sorted(set(after) - set(before))
            raise Corruption(f"read-only sweep changed {len(changed)} durable revision rows")
        detail = "read-only sweep ok"
        if before is None:
            detail += " (database revision check skipped: no PG container configured)"
        else:
            detail += f"; {len(before)} durable rows unchanged"
        return {"detail": detail, "read_only_statuses": statuses, "revision_rows": len(before or [])}

    def server_agents(self) -> list[dict]:
        result = self.http.request("GET", "/api/agents", headers=self.auth_headers(self.context["server_id"]))
        body = expect_json(result, "GET /api/agents")
        agents = body.get("agents", []) if isinstance(body, dict) else body
        return [agent for agent in agents if isinstance(agent, dict) and agent.get("id")]

    def onboarding_agent(self) -> dict:
        settings = self.http.request(
            "GET",
            f"/api/servers/{self.context['server_id']}/onboarding-settings",
            headers=self.auth_headers(self.context["server_id"]),
        )
        agent_id = None
        if settings.status == 200:
            try:
                agent_id = settings.json().get("onboardingAgentId")
            except json.JSONDecodeError:
                agent_id = None
        agents = self.server_agents()
        if agent_id:
            for agent in agents:
                if agent["id"] == agent_id:
                    return agent
        if not agents:
            raise Failure("server has no agents")
        for agent in agents:
            if not agent.get("external"):
                return agent
        return agents[0]

    def messages(self, channel_id: str, after: int | None = None) -> list[dict]:
        path = f"/api/messages/channel/{channel_id}?limit=50"
        if after is not None:
            path += f"&after={after}"
        result = self.http.request("GET", path, headers=self.auth_headers(self.context["server_id"]))
        body = expect_json(result, path)
        rows = body.get("messages", []) if isinstance(body, dict) else body
        return rows if isinstance(rows, list) else []

    def wait_for_agent_reply(
        self,
        channel_id: str,
        agent_id: str,
        after_seq: int,
        label: str,
        *,
        expect_text: str | None = None,
    ) -> dict:
        deadline = time.monotonic() + self.options.reply_timeout
        last_error = None
        while time.monotonic() < deadline:
            try:
                rows = self.messages(channel_id, after=after_seq)
            except Failure as error:
                last_error = error
                time.sleep(2)
                continue
            match = find_correlated_reply(rows, agent_id, after_seq, expect_text)
            if match is not None:
                return match
            time.sleep(3)
        suffix = f" (last error: {last_error})" if last_error else ""
        correlation = f" carrying {expect_text!r}" if expect_text is not None else ""
        raise Failure(
            f"{label}: no agent reply{correlation} within {self.options.reply_timeout:.0f}s{suffix}"
        )

    def send_message(self, channel_id: str, content: str, **extra) -> dict:
        body = {"channelId": channel_id, "content": content}
        body.update(extra)
        result = self.http.request("POST", "/api/messages", body, headers=self.auth_headers(self.context["server_id"]))
        return expect_json(result, "POST /api/messages")

    def check_dm(self) -> dict:
        agent = self.onboarding_agent()
        dm = self.http.request(
            "POST",
            "/api/channels/dm",
            {"agentId": agent["id"]},
            headers=self.auth_headers(self.context["server_id"]),
        )
        channel = expect_json(dm, "POST /api/channels/dm")
        channel_id = channel.get("id")
        if not channel_id:
            raise Failure(f"DM response has no id: {dm.text[:300]}")
        marker = f"acceptance-dm-{int(time.time())}"
        sent = self.send_message(channel_id, f"{marker} scripted acceptance DM")
        seq = sent.get("seq") if isinstance(sent.get("seq"), int) else 0
        reply = self.wait_for_agent_reply(channel_id, agent["id"], seq, "DM reply")
        return {
            "detail": f"DM {channel_id[:8]} answered by {agent.get('name')} at seq {reply.get('seq')}",
            "dm_channel_id": channel_id,
            "dm_agent_id": agent["id"],
        }

    def check_mention(self) -> dict:
        agent = self.onboarding_agent()
        channels_result = self.http.request("GET", "/api/channels", headers=self.auth_headers(self.context["server_id"]))
        body = expect_json(channels_result, "GET /api/channels")
        channels = body if isinstance(body, list) else body.get("channels", [])
        regular = [
            row
            for row in channels
            if row.get("type") not in ("dm", "thread") and row.get("name") and row.get("id")
        ]
        if not regular:
            raise Failure("server has no regular channel for the mention check")
        chosen = next((row for row in regular if row.get("name") == "all"), regular[0])
        channel_id = chosen["id"]
        before = self.messages(channel_id)
        last_seq = max([row.get("seq", 0) for row in before if isinstance(row.get("seq"), int)] or [0])
        name = agent.get("name") or agent.get("displayName")
        content = f"@{name} acceptance mention-{int(time.time())}"
        self.send_message(
            channel_id,
            content,
            mentions=[{"type": "agent", "id": agent["id"], "name": name}],
        )
        reply = self.wait_for_agent_reply(channel_id, agent["id"], last_seq, "channel mention reply")
        return {
            "detail": f"@mention in #{chosen.get('name')} answered at seq {reply.get('seq')}",
            "mention_channel_id": channel_id,
        }

    def check_task(self) -> dict:
        channel_id = self.context.get("mention_channel_id") or self.context.get("dm_channel_id")
        if not channel_id:
            raise Failure("no channel available for the task check")
        marker = f"acceptance-task-{int(time.time())}"
        sent = self.send_message(channel_id, f"{marker} scripted acceptance task", asTask=True)
        board_result = self.http.request(
            "GET",
            f"/api/tasks/channel/{channel_id}?detail=full",
            headers=self.auth_headers(self.context["server_id"]),
        )
        board = expect_json(board_result, "GET /api/tasks/channel")
        tasks = board.get("tasks", []) if isinstance(board, dict) else board
        task = None
        for row in tasks:
            if not isinstance(row, dict):
                continue
            title = row.get("title") or row.get("content") or ""
            if marker in title or row.get("messageId") == sent.get("id"):
                task = row
                break
        if task is None and isinstance(sent.get("taskNumber"), int):
            task = next((row for row in tasks if row.get("taskNumber") == sent.get("taskNumber")), None)
        if task is None or not task.get("id"):
            raise Failure(f"asTask message {sent.get('id')} is not on the channel board")
        history_result = self.http.request(
            "GET",
            f"/api/tasks/{task['id']}/history",
            headers=self.auth_headers(self.context["server_id"]),
        )
        history = expect_json(history_result, "GET /api/tasks/:id/history")
        events = history.get("events") or history.get("history") or []
        if not events:
            raise Failure(f"task {task['id']} history is empty")
        server_board = self.http.request(
            "GET",
            "/api/tasks/server",
            headers=self.auth_headers(self.context["server_id"]),
        )
        expect_json(server_board, "GET /api/tasks/server")
        return {
            "detail": f"task {task['id'][:8]} on board; {len(events)} history events",
            "task_id": task["id"],
            "task_channel_id": channel_id,
        }

    def upload_attachment(self, channel_id: str, content: bytes, filename: str) -> dict:
        body, content_type = multipart(
            [
                ("channelId", channel_id.encode(), None),
                ("files", content, filename),
            ]
        )
        uploaded = self.http.request(
            "POST",
            "/api/attachments/upload",
            body,
            headers=self.auth_headers(self.context["server_id"]),
            content_type=content_type,
        )
        parsed = expect_json(uploaded, "POST /api/attachments/upload")
        rows = parsed.get("attachments", []) if isinstance(parsed, dict) else []
        if not rows or not isinstance(rows[0], dict) or not rows[0].get("id"):
            raise Failure(f"upload response has no attachment id: {uploaded.text[:300]}")
        return rows[0]

    def check_attachment(self) -> dict:
        channel_id = self.context.get("task_channel_id") or self.context.get("mention_channel_id")
        if not channel_id:
            raise Failure("no channel available for the attachment check")
        html = b"<!doctype html><html><body><h1>acceptance</h1></body></html>"
        attachment = self.upload_attachment(channel_id, html, "acceptance.html")
        attachment_id = attachment["id"]
        download = self.http.request(
            "GET",
            f"/api/attachments/{attachment_id}",
            headers=self.auth_headers(self.context["server_id"]),
        )
        if download.status != 200:
            raise Failure(f"attachment download -> {download.status}")
        if download.body != html:
            raise Failure("attachment download bytes differ from the uploaded bytes")
        preview = self.http.request(
            "GET",
            f"/api/attachments/{attachment_id}/html-preview-url",
            headers=self.auth_headers(self.context["server_id"]),
        )
        preview_body = expect_json(preview, "GET /api/attachments/:id/html-preview-url")
        url = preview_body.get("url") if isinstance(preview_body, dict) else None
        if not url:
            raise Failure(f"preview URL response has no url: {preview.text[:300]}")
        preview_page = self.http.request("GET", url)
        if preview_page.status != 200 or b"<h1>acceptance</h1>" not in preview_page.body:
            raise Failure(f"preview page -> {preview_page.status} without the uploaded HTML")
        return {
            "detail": f"attachment {attachment_id[:8]} download and HTML preview ok",
            "attachment_id": attachment_id,
        }

    def check_attachment_read(self) -> dict:
        """Prove the real resident agent reads an attachment, twice in a row.

        The token lives only in the uploaded bytes: it is absent from the
        human prompt and from the filename. Each round waits for a reply that
        both comes from the DM agent and contains that round's token, so an
        unrelated message or the previous round's reply cannot satisfy it.
        The second message is sent on the same DM without a reset after the
        first reply.
        """
        channel_id = self.context.get("dm_channel_id")
        agent_id = self.context.get("dm_agent_id")
        if not channel_id or not agent_id:
            raise Failure("attachment read needs the DM check to pass first")
        rounds: list[dict] = []
        for index in (1, 2):
            case = make_attachment_read_case(index)
            attachment = self.upload_attachment(
                channel_id, case["content"].encode("utf-8"), case["filename"]
            )
            instruction = case["instruction"].format(
                attachment_id=attachment["id"], filename=case["filename"]
            )
            if case["nonce"] in instruction:
                raise Failure(f"attachment read round {index}: prompt leaked the hidden token")
            sent = self.send_message(
                channel_id,
                instruction,
                attachmentIds=[attachment["id"]],
            )
            sent_seq = sent.get("seq")
            if not isinstance(sent_seq, int):
                rows = self.messages(channel_id)
                sent_seq = max(
                    [row.get("seq", 0) for row in rows if isinstance(row.get("seq"), int)] or [0]
                )
            reply = self.wait_for_agent_reply(
                channel_id,
                agent_id,
                sent_seq,
                f"attachment read round {index}",
                expect_text=case["nonce"],
            )
            reply_seq = reply.get("seq")
            reply_content = reply.get("content") if isinstance(reply.get("content"), str) else ""
            if not isinstance(reply_seq, int) or reply_seq <= sent_seq:
                raise Failure(f"attachment read round {index}: reply seq {reply_seq!r} is not after {sent_seq}")
            if case["nonce"] not in reply_content:
                raise Failure(f"attachment read round {index}: reply does not contain the hidden token")
            rounds.append(
                {
                    "round": index,
                    "nonce": case["nonce"],
                    "filename": case["filename"],
                    "attachment_id": attachment["id"],
                    "sent_seq": sent_seq,
                    "reply_seq": reply_seq,
                }
            )
        if rounds[1]["reply_seq"] <= rounds[0]["reply_seq"]:
            raise Failure("attachment read replies are not consecutive")
        return {
            "detail": (
                "agent read the attachment and echoed hidden tokens in two "
                f"consecutive replies (seq {rounds[0]['reply_seq']}, {rounds[1]['reply_seq']})"
            ),
            "attachment_read_rounds": rounds,
        }

    def check_thread(self) -> dict:
        channel_id = self.context.get("task_channel_id") or self.context.get("mention_channel_id")
        if not channel_id:
            raise Failure("no channel available for the thread check")
        socket_client = None
        try:
            socket_client = self.open_socket()
            parent = self.send_message(channel_id, f"acceptance-thread-parent-{int(time.time())}")
            if not parent.get("id"):
                raise Failure(f"parent message has no id: {parent}")
            result = self.http.request(
                "POST",
                f"/api/channels/{channel_id}/threads",
                {"parentMessageId": parent["id"], "content": "acceptance thread reply"},
                headers=self.auth_headers(self.context["server_id"]),
            )
            thread = expect_json(result, "POST /api/channels/:id/threads")
            thread_id = thread.get("threadChannelId")
            if not thread_id:
                raise Failure(f"thread response has no threadChannelId: {result.text[:300]}")
            frame = socket_client.wait_event(
                "thread:updated",
                timeout=self.options.socket_timeout,
                predicate=lambda data: not data.get("threadChannelId") or data.get("threadChannelId") == thread_id,
            )
            summary = self.http.request(
                "GET",
                f"/api/channels/{channel_id}/threads/{parent['id']}",
                headers=self.auth_headers(self.context["server_id"]),
            )
            expect_json(summary, "GET thread summary")
            return {
                "detail": f"thread {thread_id[:8]} replied; thread:updated received",
                "thread_channel_id": thread_id,
                "thread_frame": frame,
            }
        finally:
            if socket_client is not None:
                socket_client.close()

    def open_socket(self) -> WebSocketClient:
        if not self.context.get("access_token") or not self.context.get("server_id"):
            raise Skip("socket check needs an owner token and a server id")
        client = WebSocketClient(self.socket_url, timeout=self.options.socket_timeout)
        client.connect_socketio(self.context["access_token"], self.context["server_id"])
        return client

    def check_restart(self) -> dict:
        if not self.options.restart_main:
            raise Skip("--restart-main not requested")
        unit = self.options.service_unit
        if not unit:
            raise Skip("no ACCEPTANCE_SERVICE_UNIT configured")
        channel_id = self.context.get("dm_channel_id") or self.context.get("mention_channel_id")
        agent_id = self.context.get("dm_agent_id")
        if not channel_id or not agent_id:
            raise Failure("restart delivery needs the DM check to pass first")
        old_socket = self.open_socket()
        subprocess.run(["systemctl", "--user", "restart", unit], check=True, timeout=120)
        closed = False
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                if old_socket.recv_text(timeout=2) is None:
                    closed = True
                    break
            except (TimeoutError, ConnectionError, OSError):
                closed = True
                break
        old_socket.close()
        if not closed:
            raise Failure("socket did not observe the Main restart")
        last_status = None
        while time.monotonic() < deadline:
            try:
                last_status = self.http.request("GET", "/health").status
            except ConnectionError:
                last_status = None
            if last_status == 200:
                break
            time.sleep(2)
        if last_status != 200:
            raise Outage(f"/health did not return to 200 after restart (last {last_status})")
        fresh_socket = self.open_socket()
        try:
            seq = 0
            try:
                rows = self.messages(channel_id)
                seq = max([row.get("seq", 0) for row in rows if isinstance(row.get("seq"), int)] or [0])
            except Failure:
                pass
            self.send_message(channel_id, f"acceptance-restart-{int(time.time())} after restart")
            reply = self.wait_for_agent_reply(channel_id, agent_id, seq, "post-restart DM reply")
        finally:
            fresh_socket.close()
        return {
            "detail": f"unit restarted, socket reconnected, reply at seq {reply.get('seq')}",
            "restart_reply_seq": reply.get("seq"),
        }

    def plan(self) -> list[tuple[str, str]]:
        checks = [
            ("health-version", "GET /health, GET /api/version"),
            ("owner-login", "POST /api/auth/login using the owner credential file"),
            ("owner-refresh", "POST /api/auth/refresh"),
            ("servers", "GET /api/servers and pick the owned server"),
            ("read-only-sweep", "GET-only requests with a before/after durable revision snapshot"),
        ]
        if self.options.full:
            checks += [
                ("dm-reply", "POST /api/channels/dm, POST /api/messages, poll the reply"),
                ("mention-reply", "POST /api/messages with an agent mention, poll the reply"),
                ("task", "POST /api/messages asTask, GET board, GET task history"),
                ("attachment", "POST /api/attachments/upload, download bytes, HTML preview"),
                (
                    "attachment-read",
                    "upload a hidden-nonce text file, send it to the DM agent, require the "
                    "exact nonce in two consecutive replies",
                ),
                ("thread", "POST /api/channels/:id/threads and wait for thread:updated"),
            ]
            if self.options.restart_main:
                checks.append(("restart-main", "systemctl --user restart, reconnect, deliver"))
        return checks

    def write_report(self) -> dict:
        counts: dict[str, int] = {}
        for entry in self.results:
            counts[entry["status"]] = counts.get(entry["status"], 0) + 1
        report = {
            "schemaVersion": 1,
            "startedAt": self.started_at,
            "finishedAt": utc_now(),
            "durationSeconds": round(time.monotonic() - self.started_clock, 1),
            "mode": "full" if self.options.full else "read-only",
            "dryRun": self.options.dry_run,
            "baseUrl": self.base_url,
            "socketUrl": self.socket_url,
            "stopped": self.stopped,
            "counts": counts,
            "passed": not self.stopped and counts.get("FAIL", 0) == 0,
            "results": self.results,
        }
        path = Path(self.options.out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        return report


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", default=str(DEFAULT_ENV_FILE), help="local env file (git-ignored)")
    parser.add_argument("--base-url", help="override ACCEPTANCE_BASE_URL")
    parser.add_argument("--socket-url", help="override ACCEPTANCE_SOCKET_URL")
    parser.add_argument("--owner-credentials", help="override ACCEPTANCE_OWNER_CREDENTIAL_FILE")
    parser.add_argument("--pg-container", help="override ACCEPTANCE_PG_CONTAINER")
    parser.add_argument("--database", help="override ACCEPTANCE_DATABASE")
    parser.add_argument("--service-unit", help="override ACCEPTANCE_SERVICE_UNIT")
    parser.add_argument(
        "--full",
        action="store_true",
        help="enable message-sending checks (DM, mention, task, attachment read, thread)",
    )
    parser.add_argument("--read-only", action="store_true", help="GET/login/refresh checks only (default)")
    parser.add_argument("--dry-run", action="store_true", help="print the plan without touching the network")
    parser.add_argument("--restart-main", action="store_true", help="include the unit restart scenario")
    parser.add_argument("--expect-sha", help="require /api/version sha to start with this value")
    parser.add_argument("--reply-timeout", type=float, default=DEFAULT_REPLY_TIMEOUT)
    parser.add_argument("--socket-timeout", type=float, default=45.0)
    parser.add_argument("--http-timeout", type=float, default=30.0)
    parser.add_argument("--out", default=f"acceptance-{time.strftime('%Y%m%dT%H%M%S')}.json")
    options = parser.parse_args(argv)

    if options.full and options.read_only:
        parser.error("--full and --read-only are mutually exclusive")
    if not options.full:
        options.read_only = True

    env = read_env_file(Path(options.env_file))
    options.base_url = options.base_url or os.environ.get("ACCEPTANCE_BASE_URL") or env.get("ACCEPTANCE_BASE_URL")
    options.socket_url = options.socket_url or os.environ.get("ACCEPTANCE_SOCKET_URL") or env.get("ACCEPTANCE_SOCKET_URL")
    options.owner_credentials = (
        options.owner_credentials
        or os.environ.get("ACCEPTANCE_OWNER_CREDENTIAL_FILE")
        or env.get("ACCEPTANCE_OWNER_CREDENTIAL_FILE")
    )
    options.pg_container = (
        options.pg_container or os.environ.get("ACCEPTANCE_PG_CONTAINER") or env.get("ACCEPTANCE_PG_CONTAINER")
    )
    options.database = options.database or os.environ.get("ACCEPTANCE_DATABASE") or env.get("ACCEPTANCE_DATABASE")
    options.service_unit = (
        options.service_unit or os.environ.get("ACCEPTANCE_SERVICE_UNIT") or env.get("ACCEPTANCE_SERVICE_UNIT")
    )
    options.reply_timeout = float(env.get("ACCEPTANCE_REPLY_TIMEOUT", options.reply_timeout))
    if not options.base_url:
        parser.error(f"no base URL: set ACCEPTANCE_BASE_URL in {options.env_file} or pass --base-url")
    if options.restart_main and not options.full:
        parser.error("--restart-main requires --full")

    acceptance = Acceptance(options)
    if options.dry_run:
        for name, description in acceptance.plan():
            acceptance.record(name, "DRY-RUN", description)
        report = acceptance.write_report()
        print(f"\nacceptance dry-run: {len(acceptance.results)} checks planned; report {options.out}")
        return 0

    acceptance.run("health-version", acceptance.check_health)
    acceptance.run("owner-login", acceptance.check_login)
    acceptance.run("owner-refresh", acceptance.check_refresh, needs=("access_token",))
    acceptance.run("servers", acceptance.check_servers, needs=("access_token",))
    acceptance.run("read-only-sweep", acceptance.check_readonly_sweep, needs=("access_token",))
    if options.full:
        acceptance.run("dm-reply", acceptance.check_dm, needs=("server_id",))
        acceptance.run("mention-reply", acceptance.check_mention, needs=("server_id",))
        acceptance.run("task", acceptance.check_task, needs=("server_id",))
        acceptance.run("attachment", acceptance.check_attachment, needs=("server_id",))
        acceptance.run(
            "attachment-read",
            acceptance.check_attachment_read,
            needs=("server_id", "dm_channel_id", "dm_agent_id"),
        )
        acceptance.run("thread", acceptance.check_thread, needs=("server_id",))
        if options.restart_main:
            acceptance.run("restart-main", acceptance.check_restart, needs=("server_id",))
    else:
        for name in ("dm-reply", "mention-reply", "task", "attachment", "attachment-read", "thread"):
            acceptance.record(name, "SKIP", "read-only mode (pass --full)")
        if options.restart_main:
            acceptance.record("restart-main", "SKIP", "read-only mode (pass --full)")

    report = acceptance.write_report()
    counts = report["counts"]
    print()
    print(
        "acceptance summary: "
        + ", ".join(f"{status}={counts.get(status, 0)}" for status in ("PASS", "FAIL", "BLOCKED", "SKIP"))
        + f" in {report['durationSeconds']}s"
    )
    if report["stopped"]:
        print(f"stopped early: {report['stopped']}")
    print(f"report: {options.out}")
    print("acceptance: " + ("PASS" if report["passed"] else "FAIL"))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
