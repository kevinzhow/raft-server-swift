#!/usr/bin/env python3
"""Paired attachment pilot against two private, isolated product runtimes.

Usage: python3 scripts/verification/attachment_pilot.py --config PRIVATE.json
       --out RUN_DIRECTORY --phase initial|after-restart

The initial phase creates disposable channels and external Agents through normal
HTTP, uploads actual multipart bodies, checks history/downloads and invokes the
fixed real CLI. Restart only the two owned servers outside this runner, retaining
data; then use after-restart with the same config and run directory. Missing
phases remain NOT_RUN. Shared reports never contain credentials or signed URLs.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import struct
import subprocess
import uuid
from urllib.parse import quote
import zlib

from evidence import Aliases, baseline_id, differences, digest, evidence_valid, make_report
from transport import Client, Observation, PrivateEvidence

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
FILES = {
    "png": ("pilot.png", "image/png", PNG),
    "all_bytes": ("pilot.bin", "application/octet-stream", bytes(range(256))),
    "text": ("pilot.txt", "text/plain", "paired attachment: 文件字节\n".encode()),
}
UNAVAILABLE_ACTION = ('If this value came from a feedback report, do not use its artifactId here. '
                      'Use the reportId with the Raft Feedback Admin integration instead: run '
                      '`raft integration invoke --service "Raft Feedback Admin" --action download_feedback_transcript '
                      '--param id=REPORT_ID --output PATH`.')
UNAVAILABLE = {"error": "Attachment is unavailable. " + UNAVAILABLE_ACTION,
               "code": "ATTACHMENT_UNAVAILABLE", "suggestedNextAction": UNAVAILABLE_ACTION}
URL_UNAVAILABLE = {"error": "This Server's file storage cannot mint download URLs.",
                   "code": "download_url_unavailable",
                   "suggestedNextAction": "Download the attachment bytes instead: GET /internal/agent-api/attachments/:attachmentId (`raft attachment view --id <attachmentId> --output <path>`)."}
CASE_RULES = ("upload.metadata", "history.association", "human.bytes", "agent.bytes", "agent.protocol")
REQUIRED = [f"attachment.{rule}.{case}" for case in FILES for rule in CASE_RULES] + [
    "attachment.channel.private_established",
    "attachment.upload.empty_rejected", "attachment.cli.bytes",
    "attachment.agent.url_unavailable", "attachment.agent.missing_cloaked",
    "attachment.agent.unauthenticated", "attachment.human.unauthenticated",
    "attachment.agent.revoked", "attachment.owner.revocation_witness",
    "attachment.agent.revoked_after_restart", "attachment.owner.revocation_witness_after_restart",
] + [f"attachment.restart.{surface}.{case}" for case in FILES for surface in ("human", "agent", "history")]

SOURCES = {
    "private_channel": "packages/server/src/routes/channels.ts:935-1033",
    "upload": "packages/server/src/routes/attachments.ts:886-978,656-676",
    "history": "packages/server/src/routes/internalAgentApi.ts:2773; toAgentApiMessageEnvelope",
    "agent": "packages/server/src/routes/internalAgentApi.ts:4800-4963",
    "human": "packages/server/src/routes/attachments.ts:1509-1600",
    "cli": "packages/cli/src/commands/attachment/view.ts:62-91; packages/cli/src/client.ts:457-538",
    "revocation": "packages/server/src/routes/channels.ts:4085; internalAgentApi.ts:4816-4845",
}


def private_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")


def multipart(channel: str, filename: str, mime: str, data: bytes) -> tuple[bytes, str]:
    boundary = "raft-pilot-" + uuid.uuid4().hex
    prefix = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n{channel}\r\n"
              f"--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"{filename}\"\r\n"
              f"Content-Type: {mime}\r\n\r\n").encode()
    return prefix + data + f"\r\n--{boundary}--\r\n".encode(), f"multipart/form-data; boundary={boundary}"


def png_decodes(data: bytes) -> bool:
    """Decode the known 1x1 pilot PNG, validating chunks, CRC and deflate data."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return False
    position, compressed, image = 8, bytearray(), None
    try:
        while position < len(data):
            length = struct.unpack(">I", data[position:position + 4])[0]
            kind = data[position + 4:position + 8]
            payload = data[position + 8:position + 8 + length]
            crc = struct.unpack(">I", data[position + 8 + length:position + 12 + length])[0]
            if zlib.crc32(kind + payload) & 0xffffffff != crc:
                return False
            if kind == b"IHDR":
                image = struct.unpack(">IIBBBBB", payload)
            if kind == b"IDAT":
                compressed.extend(payload)
            position += 12 + length
            if kind == b"IEND":
                return image == (1, 1, 8, 4, 0, 0, 0) and len(zlib.decompress(compressed)) == 3 and position == len(data)
    except (struct.error, zlib.error):
        return False
    return False


class CheckFailed(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailed(message)


class Pilot:
    def __init__(self, config: dict, root: Path):
        self.config, self.root = config, root
        root.mkdir(parents=True, exist_ok=True)
        self.store = PrivateEvidence(root)
        self.baseline = config["baseline"]
        self.baseline_key = baseline_id(self.baseline)
        self.state_path = root / "private" / "state.json"
        if self.state_path.exists():
            self.state = json.loads(self.state_path.read_text())
            require(self.state["baseline_id"] == self.baseline_key, "saved scenario baseline changed")
        else:
            names = ("attachment_pilot.py", "evidence.py", "transport.py", "attachment_contract.json")
            snapshot = self.store.save({"kind": "verification-tooling-snapshot", "files": {
                name: {"sha256": digest((Path(__file__).parent / name).read_bytes()),
                       "content_base64": base64.b64encode((Path(__file__).parent / name).read_bytes()).decode()}
                for name in names
            }})
            self.state = {"baseline_id": self.baseline_key, "targets": {}, "results": [], "observed": {},
                          "tooling_snapshot": snapshot}
        self.results = {(row["target"], row["behavior_id"]): row for row in self.state["results"]}

    def preflight(self, target, phase):
        client, config = self.client(target), self.config["targets"][target]
        health = client.request("GET", "/health")
        require(health.status == 200, "target health is unavailable")
        version = client.request("GET", "/api/version")
        require(version.status == 200 and version.json().get("sha") == config["sourceSHA"],
                "running source identity does not match the declared baseline")
        actual_tooling = {name: digest((Path(__file__).parent / name).read_bytes())
                          for name in ("attachment_pilot.py", "evidence.py", "transport.py", "attachment_contract.json")}
        require(self.baseline.get("tooling") == actual_tooling, "verification tooling changed since the declared baseline")
        cli = self.config.get("cli")
        if cli:
            require(digest(Path(cli["artifact"]["path"]).read_bytes()) == cli["artifact"]["sha256"],
                    "fixed CLI artifact changed")
        self.state.setdefault("preflight", {}).setdefault(phase, {})[target] = {
            "status": "PASS", "evidence": [health.evidence, version.evidence],
            "sourceSHA": config["sourceSHA"],
        }
        if phase == "initial":
            self.state.setdefault("runtime_before", {})[target] = config["runtimeIdentity"]
        self.checkpoint()

    def verify_restart(self, target, receipts):
        require(receipts is not None and receipts.get("baseline_id") == self.baseline_key,
                "retained-data restart requires current-baseline operator evidence")
        receipt = receipts.get("targets", {}).get(target, {})
        require(bool(receipt.get("before")) and receipt["before"] == self.state.get("runtime_before", {}).get(target),
                "restart witness must identify the process observed before the scenario")
        require(bool(receipt.get("after")) and receipt["after"] != receipt["before"],
                "restart witness must identify a different process incarnation")
        require(receipt.get("sourceSHA") == self.config["targets"][target]["sourceSHA"],
                "restart witness must preserve the source identity")
        proof = receipt.get("evidence", [])
        require(bool(proof) and all(evidence_valid(item, self.root) for item in proof),
                "restart witness evidence is missing or changed")
        self.state.setdefault("restart_evidence", {})[target] = proof
        self.checkpoint()

    def checkpoint(self):
        self.state["results"] = list(self.results.values())
        private_json(self.state_path, self.state)

    def record(self, target, identity, function):
        proof, observation = [], None
        before = self.store.index
        try:
            observation, proof = function()
            status, detail = "PASS", "assertions passed"
        except CheckFailed as error:
            status, detail = "FAIL", str(error)
            proof = getattr(error, "evidence", [])
            observation = getattr(error, "observation", None)
        except (KeyError, TypeError, ValueError, AttributeError) as error:
            status, detail = "FAIL", f"response/schema contract: {type(error).__name__}"
        except (OSError, TimeoutError) as error:
            status, detail = "BLOCKED", f"transport prerequisite: {type(error).__name__}"
        if not proof:
            # A failure can happen after a request but before JSON/schema parsing.
            # Retain every observation made by this check; a caller may have
            # captured its response immediately before entering record().
            indices = range(before + 1, self.store.index + 1) if self.store.index > before else [before]
            for index in indices:
                path = self.store.directory / f"http-{index:05d}.json"
                if path.is_file():
                    proof.append({"path": str(path.relative_to(self.root)), "sha256": digest(path.read_bytes())})
        if observation is None and proof:
            for item in reversed(proof):
                try:
                    captured = json.loads((self.root / item["path"]).read_text())
                    if "response_body_base64" in captured:
                        observation = Observation(captured["status"], captured["response_headers"],
                                                  base64.b64decode(captured["response_body_base64"]), item).safe_summary()
                        break
                except (OSError, ValueError, KeyError, TypeError):
                    continue
        if ".restart." in identity or identity.endswith("_after_restart"):
            proof.extend(self.state.get("restart_evidence", {}).get(target, []))
        row = {"target": target, "behavior_id": identity, "status": status,
               "baseline_id": self.baseline_key, "evidence": proof, "detail": detail}
        self.results[(target, identity)] = row
        if observation is not None:
            self.state["observed"].setdefault(target, {})[identity] = observation
        else:
            self.state["observed"].setdefault(target, {}).pop(identity, None)
        self.checkpoint()
        print(f"{target} {identity} {status}", flush=True)
        return status

    def checked(self, response, condition, message, observation=None):
        value = observation if observation is not None else response.safe_summary()
        if not condition:
            error = CheckFailed(message)
            error.evidence, error.observation = [response.evidence], value
            raise error
        return value, [response.evidence]

    def json_check(self, response, expected_status, expected_body, message):
        if response.status != expected_status:
            return self.checked(response, False, message)
        body = response.json()
        return self.checked(response, body == expected_body, message, {"status": response.status, "body": body})

    def client(self, target):
        config = self.config["targets"][target]
        return Client(config["baseUrl"], self.store, ca_file=config.get("caFile"))

    def setup(self, target):
        config, client = self.config["targets"][target], self.client(target)
        login = client.request("POST", "/api/auth/login", body=config["owner"])
        require(login.status == 200, "owner login must succeed")
        token = login.json()["accessToken"]
        headers = {"Authorization": f"Bearer {token}", "X-Server-Id": config["serverId"]}
        suffix = uuid.uuid4().hex[:10]
        agent = client.request("POST", "/api/agents", body={"name": "parity-reader-" + suffix, "external": True}, headers=headers)
        require(agent.status == 200, "external Agent creation must succeed")
        agent_id = agent.json()["id"]
        credential = client.request("POST", f"/api/agents/{agent_id}/credentials", body={}, headers={"Authorization": f"Bearer {token}"})
        require(credential.status == 201, "external Agent credential mint must succeed")
        context = {"ownerToken": token, "agentId": agent_id, "agentKey": credential.json()["apiKey"], "files": {}}

        def establish_private_channels():
            observations, proof = {}, []
            for role, prefix, key in (("files", "parity-files-", "channelId"),
                                      ("revocation", "parity-revoke-", "revokedChannelId")):
                created = client.request("POST", "/api/channels", body={
                    "name": prefix + suffix, "visibility": "private", "agentIds": [agent_id],
                }, headers=headers)
                proof.append(created.evidence)
                value = created.json() if created.status == 200 else {}
                channel_id = value.get("id") if isinstance(value, dict) else None
                facts = {"create": {"status": created.status, "type": value.get("type") if isinstance(value, dict) else None},
                         "readback": {"status": "NOT_RUN", "type": None}}
                observations[role] = facts
                readback = None
                if isinstance(channel_id, str) and channel_id:
                    # Read back even a public create response, preserving both
                    # observations without another write or a corrective PATCH.
                    readback = client.request("GET", "/api/channels/" + quote(channel_id, safe=""), headers=headers)
                    proof.append(readback.evidence)
                    persisted = readback.json() if readback.status == 200 else {}
                    facts["readback"] = {"status": readback.status,
                                         "type": persisted.get("type") if isinstance(persisted, dict) else None}
                valid = (created.status == 200 and isinstance(channel_id, str) and bool(channel_id)
                         and facts["create"]["type"] == "private"
                         and readback is not None and readback.status == 200
                         and facts["readback"]["type"] == "private")
                if not valid:
                    error = CheckFailed("both channel create and readback must establish type=private; dependent writes stopped")
                    error.evidence, error.observation = proof, observations
                    raise error
                context[key] = channel_id
                if role == "files":
                    context["channelName"] = value["name"]
            return observations, proof

        if self.record(target, "attachment.channel.private_established", establish_private_channels) != "PASS":
            # No target context is published after this prerequisite fails. The
            # remaining declared behaviors stay NOT_RUN; nothing repairs or uses
            # the incorrectly created channel.
            return None
        self.state["targets"][target] = context
        self.checkpoint()
        return context

    def blocked(self, target, identity, dependency):
        prerequisite = self.results.get((target, dependency), {})
        self.results[(target, identity)] = {
            "target": target, "behavior_id": identity, "status": "BLOCKED",
            "baseline_id": self.baseline_key, "evidence": list(prerequisite.get("evidence", [])),
            "blocked_by": dependency, "detail": "required prerequisite did not produce a usable attachment",
        }
        self.state["observed"].setdefault(target, {}).pop(identity, None)
        self.checkpoint()
        print(f"{target} {identity} BLOCKED", flush=True)

    def credentials(self, target, context):
        return ({"Authorization": f"Bearer {context['ownerToken']}", "X-Server-Id": self.config["targets"][target]["serverId"]},
                {"Authorization": f"Bearer {context['agentKey']}"})

    def initial(self, target):
        require(target not in self.state["targets"], "initial phase already prepared this target; use a fresh run directory")
        context = self.setup(target)
        if context is None:
            return
        client = self.client(target)
        human, agent = self.credentials(target, context)
        aliases = Aliases()
        for case, (filename, mime, data) in FILES.items():
            def upload(case=case, filename=filename, mime=mime, data=data):
                body, content_type = multipart(context["channelId"], filename, mime, data)
                response = client.request("POST", "/api/attachments/upload", body=body,
                                          headers=human | {"Content-Type": content_type})
                if response.status != 200:
                    return self.checked(response, False, "multipart upload must succeed")
                rows = response.json().get("attachments", [])
                require(isinstance(rows, list) and len(rows) == 1 and isinstance(rows[0], dict)
                        and isinstance(rows[0].get("id"), str) and bool(rows[0]["id"]),
                        "upload must return exactly one concrete attachment ID")
                row = rows[0]
                aliases.bind(case, row["id"])
                context["files"][case] = {"attachmentId": row["id"], "upload": row}
                return self.checked(response, row.get("filename") == filename and row.get("mimeType") == mime
                                    and type(row.get("sizeBytes")) is int and row["sizeBytes"] == len(data),
                                    "upload filename/MIME/size differs from original input", aliases.normalize(row))
            self.record(target, f"attachment.upload.metadata.{case}", upload)
            if case not in context["files"]:
                dependency = f"attachment.upload.metadata.{case}"
                for rule in CASE_RULES[1:]:
                    self.blocked(target, f"attachment.{rule}.{case}", dependency)
                continue
            file = context["files"][case]
            sent = client.request("POST", "/api/messages", body={"channelId": context["channelId"],
                                  "content": "paired file " + case, "attachmentIds": [file["attachmentId"]]}, headers=human)
            file["messageSetupEvidence"] = sent.evidence
            try:
                value = sent.json()
                if sent.status == 200 and isinstance(value, dict) and isinstance(value.get("id"), str) and value["id"]:
                    file["messageId"] = value["id"]
                else:
                    file["messageSetupFailed"] = sent.status
            except (ValueError, TypeError):
                file["messageSetupFailed"] = sent.status
            self.checkpoint()
        for case in context["files"]:
            self.read_case(target, case, restarted=False)
        body, content_type = multipart(context["channelId"], "empty.txt", "text/plain", b"")
        empty = client.request("POST", "/api/attachments/upload", body=body, headers=human | {"Content-Type": content_type})
        self.record(target, "attachment.upload.empty_rejected", lambda: self.json_check(empty, 400, {"error": "Empty files are not allowed"}, "empty HTTP upload must return the official 400 error"))
        if "png" in context["files"]:
            attachment = context["files"]["png"]["attachmentId"]
            url = client.request("GET", f"/internal/agent-api/attachments/{attachment}/url", headers=agent)
            self.record(target, "attachment.agent.url_unavailable", lambda: self.json_check(url, 409, URL_UNAVAILABLE, "streaming URL refusal must equal the pinned contract"))
            for identity, path in [("attachment.agent.unauthenticated", f"/internal/agent-api/attachments/{attachment}"), ("attachment.human.unauthenticated", f"/api/attachments/{attachment}")]:
                response = client.request("GET", path)
                expected = {"error": "Missing agent credential" if ".agent." in identity else "Authentication required"}
                self.record(target, identity, lambda r=response, expected=expected: self.json_check(r, 401, expected, "unauthenticated error must equal the pinned middleware response"))
            self.run_cli(target, attachment)
        else:
            for identity in ("attachment.cli.bytes", "attachment.agent.url_unavailable",
                             "attachment.agent.unauthenticated", "attachment.human.unauthenticated"):
                self.blocked(target, identity, "attachment.upload.metadata.png")
        missing = client.request("GET", "/internal/agent-api/attachments/" + str(uuid.uuid4()), headers=agent)
        self.record(target, "attachment.agent.missing_cloaked", lambda: self.json_check(missing, 404, UNAVAILABLE, "unknown attachment must return the pinned cloaking response"))
        self.revoke(target)

    def history(self, target, case, *, restarted):
        context = self.state["targets"][target]
        _, agent = self.credentials(target, context)
        file = context["files"][case]
        if not isinstance(file.get("messageId"), str) or not file["messageId"]:
            error = CheckFailed("message association setup did not return a concrete message ID")
            error.evidence = [file["messageSetupEvidence"]] if file.get("messageSetupEvidence") else []
            raise error
        response = self.client(target).request("GET", "/internal/agent-api/history?channel=" + quote("#" + context["channelName"], safe="") + "&limit=100&consume=false", headers=agent)
        if response.status != 200:
            return self.checked(response, False, "history read must succeed")
        rows = response.json()["messages"]
        require(isinstance(rows, list), "history messages must be an array")
        row = next((item for item in rows if isinstance(item, dict) and item.get("id") == file["messageId"]), None)
        require(row is not None, "associated message must be present in Agent history")
        attachments = row.get("attachments", [])
        attachment = next((item for item in attachments if item.get("id") == file["attachmentId"]), None)
        filename, mime, data = FILES[case]
        condition = (len(attachments) == 1 and attachment is not None and attachment.get("filename") == filename
                     and attachment.get("mimeType") == mime and type(attachment.get("sizeBytes")) is int
                     and attachment["sizeBytes"] == len(data))
        aliases = Aliases()
        aliases.bind(case, file["attachmentId"])
        return self.checked(response, condition, "history must preserve the associated attachment metadata", aliases.normalize(attachments))

    def read_case(self, target, case, *, restarted):
        context, client = self.state["targets"][target], self.client(target)
        human, agent = self.credentials(target, context)
        attachment = context["files"][case]["attachmentId"]
        data = FILES[case][2]
        for surface, headers, path in [("human", human, f"/api/attachments/{attachment}"), ("agent", agent, f"/internal/agent-api/attachments/{attachment}")]:
            identity = f"attachment.restart.{surface}.{case}" if restarted else f"attachment.{surface}.bytes.{case}"
            def check(headers=headers, path=path):
                first, final = client.binary(path, headers=headers)
                value = {"status": final.status, "bytes": len(final.body), "sha256": digest(final.body)}
                proof = list({item["path"]: item for item in [first.evidence, final.evidence]}.values())
                valid = final.status == 200 and final.body == data and (case != "png" or png_decodes(final.body))
                if not valid:
                    error = CheckFailed("download must equal every uploaded byte and the PNG must decode")
                    error.evidence, error.observation = proof, value
                    raise error
                return value, proof
            self.record(target, identity, check)
        if not restarted:
            response = client.request("GET", f"/internal/agent-api/attachments/{attachment}", headers=agent)
            filename, mime, _ = FILES[case]
            expected_type = mime + "; charset=utf-8" if mime.startswith("text/") else mime
            disposition = "inline" if mime == "image/png" else "attachment"
            expected_disposition = f'{disposition}; filename="{filename}"; filename*=UTF-8\'\'{filename}'
            self.record(target, f"attachment.agent.protocol.{case}", lambda: self.checked(response,
                        response.status == 200 and response.header("Content-Length") == str(len(data))
                        and response.header("Content-Type") == expected_type
                        and response.header("Content-Disposition") == expected_disposition
                        and response.header("Cache-Control") == "private, immutable, max-age=31536000"
                        and response.header("X-Content-Type-Options") == "nosniff",
                        "Agent streaming status/length/MIME/disposition/cache/nosniff contract differs", response.safe_summary()))
        identity = f"attachment.restart.history.{case}" if restarted else f"attachment.history.association.{case}"
        self.record(target, identity, lambda: self.history(target, case, restarted=restarted))

    def run_cli(self, target, attachment):
        config, context = self.config.get("cli"), self.state["targets"][target]
        def check():
            require(config is not None, "fixed real CLI is not configured")
            directory = self.root / "private" / ("cli-" + target)
            directory.mkdir(mode=0o700, exist_ok=True)
            environment = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL") if key in os.environ}
            allowed = {"NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "TMPDIR", "XDG_CACHE_HOME"}
            environment.update({key: value for key, value in config.get("env", {}).items() if key in allowed})
            ca = self.config["targets"][target].get("caFile")
            if ca:
                environment["NODE_EXTRA_CA_CERTS"] = ca
            environment.update({"RAFT_HOME": str(directory), "RAFT_PROFILE_DIR": str(directory / "profile")})
            command = config["command"]
            login = subprocess.run(command + ["agent", "login", "--server", self.config["targets"][target]["baseUrl"], "--agent", context["agentId"], "--profile-slug", "paired"], input=(context["agentKey"] + "\n").encode(), capture_output=True, env=environment, cwd=config["cwd"], timeout=60)
            login_proof = self.store.save({"kind": "real-cli-login", "target": target, "exit_code": login.returncode, "stdout_base64": base64.b64encode(login.stdout).decode(), "stderr_base64": base64.b64encode(login.stderr).decode()})
            if login.returncode != 0:
                error = CheckFailed("real CLI login must succeed")
                error.evidence, error.observation = [login_proof], {"stage": "login", "exit_code": login.returncode}
                raise error
            output = directory / "download.png"
            result = subprocess.run(command + ["attachment", "view", attachment, "--output", str(output)], capture_output=True, env=environment | {"RAFT_PROFILE": "paired"}, cwd=config["cwd"], timeout=60)
            proof = self.store.save({"kind": "real-cli-download", "target": target, "exit_code": result.returncode, "stdout_base64": base64.b64encode(result.stdout).decode(), "stderr_base64": base64.b64encode(result.stderr).decode()})
            data = output.read_bytes() if output.is_file() else None
            evidence = [login_proof, proof]
            if data is not None:
                evidence.append({"path": str(output.relative_to(self.root)), "sha256": digest(data)})
            summary = {"stage": "download", "exit_code": result.returncode, "output_exists": data is not None,
                       "bytes": len(data) if data is not None else None,
                       "sha256": digest(data) if data is not None else None,
                       "png_decodes": png_decodes(data) if data is not None else False}
            if result.returncode != 0 or data != PNG or not summary["png_decodes"]:
                error = CheckFailed("real CLI must save the exact original, decodable PNG")
                error.evidence, error.observation = evidence, summary
                raise error
            return {key: summary[key] for key in ("exit_code", "bytes", "sha256", "png_decodes")}, evidence
        self.record(target, "attachment.cli.bytes", check)

    def revoke(self, target):
        context, client = self.state["targets"][target], self.client(target)
        human, agent = self.credentials(target, context)
        body, content_type = multipart(context["revokedChannelId"], "revoke.bin", "application/octet-stream", bytes(range(256)))
        uploaded = client.request("POST", "/api/attachments/upload", body=body, headers=human | {"Content-Type": content_type})
        require(uploaded.status == 200, "revocation witness upload must succeed")
        attachment = uploaded.json()["attachments"][0]["id"]
        context["revokedAttachmentId"] = attachment
        associated = client.request("POST", "/api/messages", body={
            "channelId": context["revokedChannelId"], "content": "paired revocation witness",
            "attachmentIds": [attachment],
        }, headers=human)
        require(associated.status == 200 and isinstance(associated.json().get("id"), str),
                "revocation witness must be associated with a readable message before Agent access")
        context["revokedMessageId"] = associated.json()["id"]
        self.checkpoint()
        before = client.request("GET", f"/internal/agent-api/attachments/{attachment}", headers=agent)
        require(before.status == 200 and before.body == bytes(range(256)), "Agent must have access before membership removal")
        removed = client.request("DELETE", f"/api/channels/{context['revokedChannelId']}/members/agent/{context['agentId']}", headers=human)
        require(removed.status == 200, "Agent membership removal must succeed")
        self.checkpoint()
        denied = client.request("GET", f"/internal/agent-api/attachments/{attachment}", headers=agent)
        self.record(target, "attachment.agent.revoked", lambda: self.json_check(denied, 404, UNAVAILABLE, "revoked download must return the pinned cloaking response"))
        witness = client.request("GET", f"/api/attachments/{attachment}", headers=human)
        self.record(target, "attachment.owner.revocation_witness", lambda: self.checked(witness, witness.status == 200 and witness.body == bytes(range(256)), "owner must still read the same revoked attachment", {"status": witness.status, "sha256": digest(witness.body)}))

    def after_restart(self, target):
        context = self.state["targets"][target]
        for case in FILES:
            if case in context["files"]:
                self.read_case(target, case, restarted=True)
            else:
                for surface in ("human", "agent", "history"):
                    self.blocked(target, f"attachment.restart.{surface}.{case}", f"attachment.upload.metadata.{case}")
        _, agent = self.credentials(target, context)
        attachment = context["revokedAttachmentId"]
        denied = self.client(target).request("GET", f"/internal/agent-api/attachments/{attachment}", headers=agent)
        self.record(target, "attachment.agent.revoked_after_restart", lambda: self.json_check(denied, 404, UNAVAILABLE, "revoked download must retain the pinned refusal after restart"))
        human, _ = self.credentials(target, context)
        witness = self.client(target).request("GET", f"/api/attachments/{attachment}", headers=human)
        self.record(target, "attachment.owner.revocation_witness_after_restart", lambda: self.checked(
            witness, witness.status == 200 and witness.body == bytes(range(256)),
            "the same revoked object must still exist and remain readable to its owner after restart",
            {"status": witness.status, "sha256": digest(witness.body)}))

    def report(self):
        comparisons = []
        for identity in REQUIRED:
            rows = [self.results.get((target, identity)) for target in ("upstream", "swift")]
            observed = [self.state["observed"].get(target, {}).get(identity) for target in ("upstream", "swift")]
            changes = differences(observed[0], observed[1]) if all(item is not None for item in observed) else []
            if any(row and row["status"] == "FAIL" for row in rows):
                status = "FAIL"
            elif all(row and row["status"] == "PASS" for row in rows):
                status = ("FAIL" if changes else "PASS") if all(item is not None for item in observed) else "BLOCKED"
            elif any(row and row["status"] == "BLOCKED" for row in rows):
                status = "BLOCKED"
            else:
                status = "NOT_RUN"
            comparisons.append({"behavior_id": identity, "baseline_id": self.baseline_key,
                                "status": status, "differences": changes})
        report = make_report(baseline=self.baseline, required=REQUIRED, results=list(self.results.values()), comparisons=comparisons,
                             evidence_root=self.root, baseline_verified=self.config.get("baselineVerified", {}),
                             gates_passed=False, execution_errors=list(self.state.get("execution_errors_by_phase", {}).values()))
        report.update({"scope": "streaming-profile attachment pilot; required retained-data restart phase is separate",
                       "source_refs": SOURCES, "normalizations": ["one-to-one attachment ID aliases only; JSON key order is irrelevant"],
                       "additional_profiles": {"presign": "NOT_RUN", "enabled_upload_sessions": "NOT_RUN"},
                       "limits": ["History contract checks the associated attachment envelope, not the entire message schema.",
                                  "External Agent credential plus real CLI is not a managed Agent/Computer execution campaign.",
                                  "Server restarts are performed by the owning environment operator; this runner never resets data."]})
        (self.root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--phase", choices=("initial", "after-restart"), required=True)
    parser.add_argument("--restart-evidence", type=Path, help="operator restart receipt bound to this run and process identities")
    args = parser.parse_args()
    if args.config.stat().st_mode & 0o077:
        parser.error("config contains private identity material; require mode 0600")
    if args.phase == "after-restart" and args.restart_evidence is None:
        parser.error("after-restart requires --restart-evidence; readback alone is not a restart test")
    config = json.loads(args.config.read_text())
    receipts = json.loads(args.restart_evidence.read_text()) if args.restart_evidence else None
    pilot = Pilot(config, args.out.resolve())
    for target in ("upstream", "swift"):
        key = f"{target}/{args.phase}"
        errors = pilot.state.setdefault("execution_errors_by_phase", {})
        errors.pop(key, None)
        try:
            pilot.preflight(target, args.phase)
            if args.phase == "after-restart":
                pilot.verify_restart(target, receipts)
            getattr(pilot, args.phase.replace("-", "_"))(target)
            pilot.state.setdefault("attempt_history", []).append({"phase": args.phase, "target": target, "execution": "OK"})
        except Exception as error:
            # Exception strings and responses can contain secrets. Raw HTTP evidence
            # is already private; the public report only exposes exception classes.
            errors[key] = f"{key}: {type(error).__name__}"
            pilot.state.setdefault("attempt_history", []).append({"phase": args.phase, "target": target, "execution": "ERROR", "class": type(error).__name__})
            print(f"{key} execution stopped: {type(error).__name__}", flush=True)
        pilot.checkpoint()
    report = pilot.report()
    print(json.dumps({key: report[key] for key in ("counts", "execution_ok", "acceptance_complete", "release_eligible")}), flush=True)
    return 0 if report["acceptance_complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
