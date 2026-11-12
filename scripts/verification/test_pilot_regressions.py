"""Regression cases for the attachment pilot; never contact product runtimes.

Run with TMPDIR on the data disk. HTTP observations and process outputs below
are controlled witnesses; Pilot bookkeeping, assertions and reports stay real.
"""
import base64
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import attachment_pilot as pilot_module
from evidence import digest, evidence_valid
from transport import Observation


class ProductBoundary:
    """Small HTTP fixture with independent response faults and retained data."""

    def __init__(self, pilot, target="swift", upload_faults=None):
        self.pilot, self.target = pilot, target
        self.upload_faults = upload_faults or {}
        self.calls, self.files, self.messages = [], {}, []
        self.linked_attachments = set()
        self.channels = {}
        self.channel_create_types = {}
        self.channel_read_types = {}
        self.revoked = False
        self.lost_revoked_object = False
        self.corrupt_download = False

    def observe(self, status, value, headers=None):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        proof = self.pilot.store.save({"kind": "test-http-response", "status": status,
                                       "response_headers": headers or [],
                                       "response_body_base64": base64.b64encode(body).decode(),
                                       "response_body_sha256": digest(body)})
        return Observation(status, headers or [], body, proof)

    def request(self, method, path, *, body=None, headers=None):
        self.calls.append((method, path))
        if path == "/health":
            return self.observe(200, {"status": "ok"})
        if path == "/api/version":
            return self.observe(200, {"sha": self.pilot.config["targets"][self.target]["sourceSHA"]})
        if path == "/api/auth/login":
            return self.observe(200, {"accessToken": "test-owner-token"})
        if path == "/api/agents":
            return self.observe(200, {"id": "test-agent"})
        if path.endswith("/credentials"):
            return self.observe(201, {"apiKey": "test-agent-token"})
        if method == "POST" and path == "/api/channels":
            channel_id = "revoke-channel" if "revoke" in body["name"] else "file-channel"
            # Fixture behavior is independent of the visibility requested by Pilot.
            row = {"id": channel_id, "name": "files", "type": self.channel_create_types.get(channel_id, "private")}
            self.channels[channel_id] = row
            return self.observe(200, row)
        if method == "GET" and path.startswith("/api/channels/"):
            channel_id = path.rsplit("/", 1)[-1]
            row = dict(self.channels[channel_id])
            row["type"] = self.channel_read_types.get(channel_id, row["type"])
            return self.observe(200, row)
        if path == "/api/attachments/upload":
            if b'filename="empty.txt"' in body:
                return self.observe(400, {"error": "Empty files are not allowed"})
            if b'filename="revoke.bin"' in body:
                row = {"id": "revoke-attachment", "filename": "revoke.bin", "mimeType": "application/octet-stream", "sizeBytes": 256}
                self.files[row["id"]] = (row, bytes(range(256)))
                return self.observe(200, {"attachments": [row]})
            for case, (filename, mime, data) in pilot_module.FILES.items():
                if ('filename="' + filename + '"').encode() in body:
                    if case in self.upload_faults:
                        return self.observe(200, self.upload_faults[case])
                    row = {"id": "attachment-" + case, "filename": filename, "mimeType": mime,
                           "sizeBytes": len(data), "width": None, "height": None,
                           "thumbnailUrl": None, "rasterPreviewUrl": None}
                    self.files[row["id"]] = (row, data)
                    return self.observe(200, {"attachments": [row]})
            raise AssertionError("unexpected upload fixture")
        if path == "/api/messages":
            attachment = self.files[body["attachmentIds"][0]][0]
            row = {"id": "message-" + attachment["id"], "channelId": body["channelId"], "attachments": [attachment]}
            self.messages.append(row)
            self.linked_attachments.add(attachment["id"])
            return self.observe(200, {"id": row["id"]})
        if path.startswith("/internal/agent-api/history?"):
            return self.observe(200, {"messages": self.messages})
        if method == "DELETE":
            self.revoked = True
            return self.observe(200, {"ok": True})
        if path.endswith("/url"):
            return self.observe(409, pilot_module.URL_UNAVAILABLE)
        is_agent = path.startswith("/internal/agent-api/")
        if not headers:
            return self.observe(401, {"error": "Missing agent credential" if is_agent else "Authentication required"})
        attachment_id = path.rsplit("/", 1)[-1]
        if is_agent and attachment_id not in self.linked_attachments:
            return self.observe(404, pilot_module.UNAVAILABLE)
        if attachment_id == "revoke-attachment":
            if self.lost_revoked_object or (is_agent and self.revoked):
                return self.observe(404, pilot_module.UNAVAILABLE)
            return self.observe(200, bytes(range(256)))
        if attachment_id not in self.files:
            return self.observe(404, pilot_module.UNAVAILABLE)
        row, data = self.files[attachment_id]
        mime = row["mimeType"]
        disposition = "inline" if mime == "image/png" else "attachment"
        response_headers = [("Content-Length", str(len(data))),
                            ("Content-Type", mime + "; charset=utf-8" if mime.startswith("text/") else mime),
                            ("Content-Disposition", f'{disposition}; filename="{row["filename"]}"; filename*=UTF-8\'\'{row["filename"]}'),
                            ("Cache-Control", "private, immutable, max-age=31536000"),
                            ("X-Content-Type-Options", "nosniff")]
        return self.observe(200, b"damaged" if self.corrupt_download else data, response_headers)

    def binary(self, path, *, headers=None):
        response = self.request("GET", path, headers=headers)
        return response, response


class PilotRegressions(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        tooling_root = Path(pilot_module.__file__).parent
        cli = self.root / "fixed-cli-artifact"
        cli.write_bytes(b"test fixed CLI artifact")
        self.config = {
            "baseline": {"tooling": {name: digest((tooling_root / name).read_bytes())
                                      for name in ("attachment_pilot.py", "evidence.py", "transport.py", "attachment_contract.json")}},
            "targets": {target: {"sourceSHA": "source-" + target, "runtimeIdentity": "before-" + target,
                                    "baseUrl": "https://unused.invalid", "serverId": "test-server",
                                    "owner": {"email": "fixture", "password": "fixture"}}
                        for target in ("upstream", "swift")},
            "baselineVerified": {"upstream": True, "swift": True},
            "cli": {"artifact": {"path": str(cli), "sha256": digest(cli.read_bytes())}},
        }
        self.pilot = pilot_module.Pilot(self.config, self.root / "run")
        self.boundaries = {target: ProductBoundary(self.pilot, target) for target in ("upstream", "swift")}
        self.client_patch = patch.object(self.pilot, "client", side_effect=lambda target: self.boundaries[target])
        self.client_patch.start()
        self.addCleanup(self.client_patch.stop)
        self.console = contextlib.redirect_stdout(io.StringIO())
        self.console.__enter__()
        self.addCleanup(self.console.__exit__, None, None, None)

    def context(self, target="swift"):
        context = {"ownerToken": "test-owner", "agentKey": "test-key", "agentId": "test-agent",
                   "channelId": "file-channel", "channelName": "files", "revokedChannelId": "revoke-channel",
                   "revokedAttachmentId": "revoke-attachment", "files": {}}
        self.pilot.state["targets"][target] = context
        return context

    def row(self, identity, target="swift"):
        return self.pilot.results[(target, identity)]

    def receipt(self):
        proof = self.pilot.store.save({"kind": "operator-process-witness", "before": "old", "after": "new"})
        self.pilot.state["runtime_before"] = {target: "before-" + target for target in ("upstream", "swift")}
        return {"baseline_id": self.pilot.baseline_key, "targets": {
            target: {"before": "before-" + target, "after": "after-" + target,
                     "sourceSHA": "source-" + target, "evidence": [proof]}
            for target in ("upstream", "swift")}}

    def cli_arguments(self, phase="after-restart", receipt=None):
        config_path = self.root / "config.json"
        pilot_module.private_json(config_path, self.config)
        args = ["attachment_pilot.py", "--config", str(config_path), "--out", str(self.pilot.root), "--phase", phase]
        if receipt is not None:
            receipt_path = self.root / "restart-receipt.json"
            pilot_module.private_json(receipt_path, receipt)
            args += ["--restart-evidence", str(receipt_path)]
        return args

    def test_both_created_channels_must_be_private_in_create_and_readback(self):
        with patch.object(self.pilot, "run_cli"):
            self.pilot.initial("swift")
        identity = "attachment.channel.private_established"
        row = self.row(identity)
        self.assertEqual(row["status"], "PASS")
        self.assertEqual(len(row["evidence"]), 4)
        self.assertTrue(all(evidence_valid(item, self.pilot.root) for item in row["evidence"]))
        observed = self.pilot.state["observed"]["swift"][identity]
        self.assertEqual(set(observed), {"files", "revocation"})
        for channel in observed.values():
            self.assertEqual(channel["create"], {"status": 200, "type": "private"})
            self.assertEqual(channel["readback"], {"status": 200, "type": "private"})
        calls = self.boundaries["swift"].calls
        self.assertLess(calls.index(("GET", "/api/channels/file-channel")), calls.index(("POST", "/api/attachments/upload")))
        self.assertLess(calls.index(("GET", "/api/channels/revoke-channel")), calls.index(("POST", "/api/attachments/upload")))
        self.assertEqual(len(pilot_module.REQUIRED), 35)

    def test_public_downgrade_in_either_create_or_readback_stops_dependent_writes(self):
        for channel_id in ("file-channel", "revoke-channel"):
            for faulty_surface in ("create", "readback"):
                with self.subTest(channel=channel_id, surface=faulty_surface):
                    root = self.root / (channel_id + "-" + faulty_surface)
                    pilot = pilot_module.Pilot(self.config, root)
                    boundary = ProductBoundary(pilot)
                    if faulty_surface == "create":
                        boundary.channel_create_types[channel_id] = "public"
                        boundary.channel_read_types[channel_id] = "private"
                    else:
                        boundary.channel_read_types[channel_id] = "public"
                    with patch.object(pilot, "client", return_value=boundary), patch.object(pilot, "run_cli") as cli:
                        pilot.initial("swift")
                    identity = "attachment.channel.private_established"
                    result = pilot.results[("swift", identity)]
                    self.assertEqual(result["status"], "FAIL")
                    expected_proofs = 2 if channel_id == "file-channel" else 4
                    self.assertEqual(len(result["evidence"]), expected_proofs)
                    self.assertTrue(all(evidence_valid(item, root) for item in result["evidence"]))
                    self.assertIn(("GET", "/api/channels/" + channel_id), boundary.calls)
                    self.assertFalse(any(path in ("/api/attachments/upload", "/api/messages") for _, path in boundary.calls))
                    self.assertFalse(any(method in ("DELETE", "PATCH") for method, _ in boundary.calls))
                    self.assertEqual(sum(path == "/api/channels" for _, path in boundary.calls), expected_proofs // 2)
                    cli.assert_not_called()
                    report = pilot.report()
                    self.assertEqual(report["denominator_per_target"], 35)
                    self.assertEqual(report["counts"]["swift"]["FAIL"], 1)
                    self.assertEqual(report["counts"]["swift"]["NOT_RUN"], 34)
                    self.assertFalse(report["acceptance_complete"])

    def test_missing_message_id_cannot_match_an_idless_history_row(self):
        context = self.context()
        proof = self.boundaries["swift"].observe(200, {"sent": True}).evidence
        context["files"]["png"] = {"attachmentId": "attachment-png", "messageSetupFailed": 200,
                                      "messageSetupEvidence": proof}
        self.boundaries["swift"].messages = [{"attachments": [{"id": "attachment-png", "filename": "pilot.png",
                                                               "mimeType": "image/png", "sizeBytes": len(pilot_module.PNG)}]}]
        identity = "attachment.history.association.png"
        self.pilot.record("swift", identity, lambda: self.pilot.history("swift", "png", restarted=False))
        self.assertEqual(self.row(identity)["status"], "FAIL")
        self.assertEqual(self.row(identity)["evidence"], [proof])
        self.assertFalse(any("/history?" in path for _, path in self.boundaries["swift"].calls))

    def test_html_500_is_a_product_failure_with_observation_and_evidence(self):
        response = self.boundaries["swift"].observe(500, b"<h1>broken product</h1>")
        identity = "attachment.upload.empty_rejected"
        self.pilot.record("swift", identity, lambda: self.pilot.json_check(response, 400, {"error": "Empty files are not allowed"}, "wrong empty-upload response"))
        self.assertEqual(self.row(identity)["status"], "FAIL")
        self.assertEqual(self.pilot.state["observed"]["swift"][identity]["status"], 500)
        self.assertTrue(all(evidence_valid(item, self.pilot.root) for item in self.row(identity)["evidence"]))

    def test_invalid_json_at_expected_status_is_fail_not_blocked(self):
        response = self.boundaries["swift"].observe(400, b"not JSON")
        identity = "attachment.upload.empty_rejected"
        self.pilot.record("swift", identity, lambda: self.pilot.json_check(response, 400, {}, "expected JSON error"))
        self.assertEqual(self.row(identity)["status"], "FAIL")
        self.assertEqual(self.row(identity)["evidence"], [response.evidence])
        observed = self.pilot.state["observed"].get("swift", {}).get(identity)
        self.assertIsNotNone(observed, "a malformed JSON response must retain its HTTP summary")
        self.assertEqual(observed["status"], 400)
        self.assertEqual(observed["sha256"], digest(b"not JSON"))

    def test_failed_target_makes_pair_fail_even_with_missing_peer(self):
        response = self.boundaries["swift"].observe(500, {"error": "bad"})
        identity = "attachment.agent.bytes.png"
        self.pilot.record("swift", identity, lambda: self.pilot.checked(response, False, "bad download"))
        report = self.pilot.report()
        pair = next(item for item in report["comparisons"] if item["behavior_id"] == identity)
        self.assertEqual(pair["status"], "FAIL")
        self.assertFalse(report["acceptance_complete"])

    def test_upload_200_missing_id_does_not_stop_other_files_or_checks(self):
        self.boundaries["swift"].upload_faults["png"] = {"attachments": [{"filename": "pilot.png"}]}
        with patch.object(self.pilot, "run_cli"):
            self.pilot.initial("swift")
        self.assertEqual(self.row("attachment.upload.metadata.png")["status"], "FAIL")
        self.assertIn("attachment.upload.metadata.png", self.pilot.state["observed"]["swift"],
                      "a 200 response with missing attachment ID must retain its HTTP summary")
        for case in ("all_bytes", "text"):
            self.assertEqual(self.row("attachment.upload.metadata." + case)["status"], "PASS")
            self.assertEqual(self.row("attachment.history.association." + case)["status"], "PASS")
        self.assertEqual(self.row("attachment.upload.empty_rejected")["status"], "PASS")
        self.assertEqual(self.row("attachment.agent.revoked")["status"], "PASS")
        dependency = "attachment.upload.metadata.png"
        dependents = ["attachment.history.association.png", "attachment.human.bytes.png",
                      "attachment.agent.bytes.png", "attachment.agent.protocol.png",
                      "attachment.cli.bytes", "attachment.agent.url_unavailable",
                      "attachment.agent.unauthenticated", "attachment.human.unauthenticated"]
        for identity in dependents:
            with self.subTest(dependent=identity):
                result = self.row(identity)
                self.assertEqual(result["status"], "BLOCKED")
                self.assertEqual(result["blocked_by"], dependency)
                self.assertEqual(result["evidence"], self.row(dependency)["evidence"])
                self.assertTrue(all(evidence_valid(item, self.pilot.root) for item in result["evidence"]))
                self.assertNotIn(identity, self.pilot.state["observed"]["swift"])
        pairs = {row["behavior_id"]: row for row in self.pilot.report()["comparisons"]}
        self.assertTrue(all(pairs[identity]["status"] == "BLOCKED" for identity in dependents))

    def test_upload_wrong_top_level_json_does_not_abort_other_cases(self):
        self.boundaries["swift"].upload_faults["png"] = []
        with patch.object(self.pilot, "run_cli"):
            self.pilot.initial("swift")
        self.assertEqual(self.row("attachment.upload.metadata.png")["status"], "FAIL")
        self.assertEqual(self.row("attachment.upload.metadata.all_bytes")["status"], "PASS")
        self.assertEqual(self.row("attachment.upload.empty_rejected")["status"], "PASS")

    def test_failed_upload_blocks_restart_reads_with_original_failure_proof(self):
        self.boundaries["swift"].upload_faults["png"] = {"attachments": []}
        with patch.object(self.pilot, "run_cli"):
            self.pilot.initial("swift")
        dependency = "attachment.upload.metadata.png"
        self.pilot.verify_restart("swift", self.receipt())
        self.pilot.after_restart("swift")
        for surface in ("human", "agent", "history"):
            identity = "attachment.restart." + surface + ".png"
            result = self.row(identity)
            self.assertEqual(result["status"], "BLOCKED")
            self.assertEqual(result["blocked_by"], dependency)
            self.assertEqual(result["evidence"], self.row(dependency)["evidence"])
            for case in ("all_bytes", "text"):
                self.assertEqual(self.row("attachment.restart." + surface + "." + case)["status"], "PASS")
        self.assertEqual(self.row("attachment.owner.revocation_witness_after_restart")["status"], "PASS")
        report = self.pilot.report()
        self.assertEqual(report["counts"]["swift"]["NOT_RUN"], 0)
        self.assertEqual(report["counts"]["swift"]["BLOCKED"], 11)
        self.assertEqual(report["counts"]["swift"]["FAIL"], 1)
        self.assertFalse(report["acceptance_complete"])

    def test_cli_failures_keep_safe_summary_and_private_process_evidence(self):
        secret = b"private credential sk_agent_fixture and signed URL https://object.invalid/?signature=private"
        for fault in ("login_exit", "download_exit", "missing_file", "bad_bytes"):
            with self.subTest(fault=fault):
                config = copy.deepcopy(self.config)
                config["cli"].update({"command": ["fixture-cli"], "cwd": str(self.root)})
                pilot = pilot_module.Pilot(config, self.root / fault)
                pilot.state["targets"]["swift"] = self.context().copy()
                def process(arguments, **kwargs):
                    login = arguments[1:3] == ["agent", "login"]
                    if not login and fault == "bad_bytes":
                        Path(arguments[-1]).write_bytes(b"damaged PNG bytes")
                    code = 7 if login and fault == "login_exit" else (9 if not login and fault == "download_exit" else 0)
                    return subprocess.CompletedProcess(arguments, code, secret, secret)
                with patch.object(pilot_module.subprocess, "run", side_effect=process) as mocked:
                    pilot.run_cli("swift", "attachment-png")
                identity = "attachment.cli.bytes"
                row = pilot.results[("swift", identity)]
                self.assertEqual(row["status"], "FAIL")
                observed = pilot.state["observed"]["swift"][identity]
                self.assertEqual(observed["stage"], "login" if fault == "login_exit" else "download")
                self.assertEqual(observed["exit_code"], 7 if fault == "login_exit" else (9 if fault == "download_exit" else 0))
                if fault != "login_exit":
                    self.assertEqual(observed["output_exists"], fault == "bad_bytes")
                    self.assertEqual(observed["bytes"], len(b"damaged PNG bytes") if fault == "bad_bytes" else None)
                    self.assertEqual(observed["sha256"], digest(b"damaged PNG bytes") if fault == "bad_bytes" else None)
                    self.assertFalse(observed["png_decodes"])
                self.assertEqual(mocked.call_count, 1 if fault == "login_exit" else 2)
                self.assertEqual(len(row["evidence"]), 1 if fault == "login_exit" else (3 if fault == "bad_bytes" else 2))
                self.assertTrue(all(evidence_valid(item, pilot.root) for item in row["evidence"]))
                process_records = [json.loads((pilot.root / item["path"]).read_text())
                                   for item in row["evidence"] if item["path"].endswith(".json")]
                self.assertTrue(all(base64.b64decode(item["stdout_base64"]) == secret for item in process_records))
                self.assertTrue(all(base64.b64decode(item["stderr_base64"]) == secret for item in process_records))
                report_text = json.dumps(pilot.report())
                self.assertNotIn("sk_agent_fixture", report_text)
                self.assertNotIn("signature=private", report_text)
                self.assertNotIn("stdout_base64", report_text)
                for call in mocked.call_args_list:
                    self.assertNotIn("test-key", " ".join(call.args[0]))

    def test_new_run_snapshot_restores_all_four_files_byte_for_byte(self):
        reference = self.pilot.state["tooling_snapshot"]
        self.assertTrue(evidence_valid(reference, self.pilot.root))
        path = self.pilot.root / reference["path"]
        snapshot = json.loads(path.read_text())
        self.assertEqual(snapshot["kind"], "verification-tooling-snapshot")
        self.assertEqual(set(snapshot["files"]), {"attachment_pilot.py", "evidence.py", "transport.py", "attachment_contract.json"})
        restored = self.root / "restored-tooling"
        restored.mkdir()
        for name, entry in snapshot["files"].items():
            content = base64.b64decode(entry["content_base64"], validate=True)
            self.assertEqual(digest(content), entry["sha256"])
            self.assertEqual(entry["sha256"], self.config["baseline"]["tooling"][name])
            recovered = restored / name
            recovered.write_bytes(content)
            self.assertEqual(recovered.read_bytes(), (Path(pilot_module.__file__).parent / name).read_bytes())
            if name.endswith(".py"):
                compile(content, str(recovered), "exec")
            else:
                self.assertEqual(json.loads(content)["schema_version"], 1)
        self.assertEqual(path.stat().st_mode & 0o077, 0)

    def test_existing_snapshot_is_not_replaced_when_current_tool_location_changes(self):
        reference = copy.deepcopy(self.pilot.state["tooling_snapshot"])
        path = self.pilot.root / reference["path"]
        original = path.read_bytes()
        self.pilot.checkpoint()
        index = self.pilot.store.index
        with patch.object(pilot_module, "__file__", str(self.root / "unavailable-new-code" / "attachment_pilot.py")), \
                patch.object(pilot_module.PrivateEvidence, "save", side_effect=AssertionError("existing run must not snapshot replacement code")):
            reopened = pilot_module.Pilot(self.config, self.pilot.root)
        self.assertEqual(reopened.state["tooling_snapshot"], reference)
        self.assertEqual(reopened.store.index, index)
        self.assertEqual(path.read_bytes(), original)
        self.assertTrue(evidence_valid(reference, reopened.root))

    def test_legacy_run_without_snapshot_is_not_retroactively_given_current_code(self):
        root = self.root / "legacy-run"
        state_path = root / "private" / "state.json"
        legacy = {"baseline_id": self.pilot.baseline_key, "targets": {}, "results": [], "observed": {}}
        pilot_module.private_json(state_path, legacy)
        original = state_path.read_bytes()
        with patch.object(pilot_module, "__file__", str(self.root / "unavailable-new-code" / "attachment_pilot.py")), \
                patch.object(pilot_module.PrivateEvidence, "save", side_effect=AssertionError("legacy run must not gain a new-code snapshot")):
            reopened = pilot_module.Pilot(self.config, root)
        self.assertNotIn("tooling_snapshot", reopened.state)
        self.assertEqual(state_path.read_bytes(), original)
        self.assertEqual(list((root / "private").glob("http-*.json")), [])

    def test_byte_failure_keeps_observed_summary_as_well_as_private_proof(self):
        with patch.object(self.pilot, "run_cli"):
            self.pilot.initial("swift")
        self.boundaries["swift"].corrupt_download = True
        self.pilot.read_case("swift", "png", restarted=False)
        identity = "attachment.agent.bytes.png"
        self.assertEqual(self.row(identity)["status"], "FAIL")
        self.assertTrue(self.row(identity)["evidence"])
        observed = self.pilot.state["observed"].get("swift", {}).get(identity)
        self.assertIsNotNone(observed, "a failed byte comparison must retain its response summary")
        self.assertEqual(observed["sha256"], digest(b"damaged"))

    def test_after_restart_command_rejects_missing_receipt_before_any_reads(self):
        with patch.object(sys, "argv", self.cli_arguments()), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                pilot_module.main()
        self.assertEqual(error.exception.code, 2)
        self.assertEqual(self.boundaries["swift"].calls, [])
        self.assertFalse(any("restart" in identity for _, identity in self.pilot.results))

    def test_restart_receipt_rejects_missing_stale_same_process_and_changed_proof(self):
        valid = self.receipt()
        cases = [None]
        for field, value in (("before", "unrelated-process"), ("after", "before-swift"),
                             ("sourceSHA", "different-source"), ("evidence", [])):
            changed = copy.deepcopy(valid)
            changed["targets"]["swift"][field] = value
            cases.append(changed)
        changed = copy.deepcopy(valid)
        changed["baseline_id"] = "stale"
        cases.append(changed)
        changed = copy.deepcopy(valid)
        changed["targets"]["swift"]["evidence"][0]["sha256"] = "changed"
        cases.append(changed)
        for receipt in cases:
            with self.subTest(receipt=receipt):
                with self.assertRaises(pilot_module.CheckFailed):
                    self.pilot.verify_restart("swift", receipt)
                self.assertNotIn("swift", self.pilot.state.get("restart_evidence", {}))

    def test_revocation_associates_the_object_before_positive_access_and_removal(self):
        context = self.context()
        boundary = self.boundaries["swift"]
        self.assertNotIn("revoke-attachment", boundary.linked_attachments)
        self.pilot.revoke("swift")
        self.assertEqual(boundary.calls, [
            ("POST", "/api/attachments/upload"),
            ("POST", "/api/messages"),
            ("GET", "/internal/agent-api/attachments/revoke-attachment"),
            ("DELETE", "/api/channels/revoke-channel/members/agent/test-agent"),
            ("GET", "/internal/agent-api/attachments/revoke-attachment"),
            ("GET", "/api/attachments/revoke-attachment"),
        ])
        associated = next(row for row in boundary.messages if row["id"] == context["revokedMessageId"])
        self.assertEqual(associated["channelId"], context["revokedChannelId"])
        self.assertEqual([item["id"] for item in associated["attachments"]], [context["revokedAttachmentId"]])
        self.assertEqual(self.row("attachment.agent.revoked")["status"], "PASS")
        self.assertEqual(self.row("attachment.owner.revocation_witness")["status"], "PASS")
        saved = json.loads(self.pilot.state_path.read_text())
        self.assertEqual(saved["targets"]["swift"]["revokedMessageId"], associated["id"])

    def test_valid_restart_receipt_is_saved_and_attached_to_durable_read(self):
        context = self.context()
        self.boundaries["swift"].revoked = True
        receipt = self.receipt()
        self.pilot.verify_restart("swift", receipt)
        self.pilot.after_restart("swift")
        row = self.row("attachment.agent.revoked_after_restart")
        self.assertEqual(row["status"], "PASS")
        self.assertIn(receipt["targets"]["swift"]["evidence"][0], row["evidence"])
        reloaded = pilot_module.Pilot(self.config, self.pilot.root)
        self.assertEqual(reloaded.state["restart_evidence"]["swift"], receipt["targets"]["swift"]["evidence"])

    def test_restart_revocation_requires_owner_witness_for_same_existing_object(self):
        self.context()
        self.boundaries["swift"].revoked = True
        self.boundaries["swift"].lost_revoked_object = True
        self.pilot.verify_restart("swift", self.receipt())
        self.pilot.after_restart("swift")
        denied = self.row("attachment.agent.revoked_after_restart")
        witness = self.row("attachment.owner.revocation_witness_after_restart")
        self.assertEqual(denied["status"], "PASS")
        self.assertEqual(witness["status"], "FAIL")
        self.assertIn("attachment.owner.revocation_witness_after_restart", pilot_module.REQUIRED)
        self.assertFalse(self.pilot.report()["acceptance_complete"])
        self.assertIn(("GET", "/api/attachments/revoke-attachment"), self.boundaries["swift"].calls)

    def test_successful_phase_retry_clears_current_error_but_keeps_attempt_history(self):
        receipt = self.receipt()
        arguments = self.cli_arguments(receipt=receipt)
        with patch.object(sys, "argv", arguments), patch.object(pilot_module, "Pilot", return_value=self.pilot), \
                patch.object(self.pilot, "after_restart", side_effect=[OSError("temporary test fault"), None, None, None]):
            self.assertEqual(pilot_module.main(), 1)  # required behaviors have not been run
            self.assertFalse(self.pilot.report()["execution_ok"])
            self.assertEqual(pilot_module.main(), 1)
        report = self.pilot.report()
        self.assertTrue(report["execution_ok"])
        self.assertEqual(report["execution_errors"], [])
        attempts = self.pilot.state["attempt_history"]
        self.assertEqual([item["execution"] for item in attempts], ["ERROR", "OK", "OK", "OK"])
        self.assertEqual(len(self.pilot.state["preflight"]["after-restart"]), 2)

    def test_preflight_rejects_wrong_runtime_sha_changed_tooling_and_changed_cli(self):
        boundary = self.boundaries["swift"]
        original_request = boundary.request
        def wrong_version(method, path, **kwargs):
            return boundary.observe(200, {"sha": "wrong"}) if path == "/api/version" else original_request(method, path, **kwargs)
        with patch.object(boundary, "request", side_effect=wrong_version):
            with self.assertRaises(pilot_module.CheckFailed):
                self.pilot.preflight("swift", "initial")
        self.assertNotIn("initial", self.pilot.state.get("preflight", {}))
        original_tooling = self.pilot.baseline["tooling"]
        self.pilot.baseline["tooling"] = {}
        with self.assertRaises(pilot_module.CheckFailed):
            self.pilot.preflight("swift", "initial")
        self.pilot.baseline["tooling"] = original_tooling
        Path(self.config["cli"]["artifact"]["path"]).write_bytes(b"changed artifact")
        with self.assertRaises(pilot_module.CheckFailed):
            self.pilot.preflight("swift", "initial")
        self.assertNotIn("initial", self.pilot.state.get("preflight", {}))


if __name__ == "__main__":
    unittest.main()
