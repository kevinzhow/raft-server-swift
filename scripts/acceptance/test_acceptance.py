#!/usr/bin/env python3
"""Focused, network-free tests for the scripted acceptance runner.

Run with ``python3 -m unittest discover -s scripts/acceptance -p 'test_*.py'``.
These tests do not start a server and do not call the deployment.
"""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

from acceptance import (
    Acceptance,
    Corruption,
    Failure,
    Outage,
    Skip,
    main,
    find_correlated_reply,
    make_attachment_read_case,
)


class AttachmentReadCaseTests(unittest.TestCase):
    def test_hidden_nonce_is_absent_from_prompt_and_filename(self) -> None:
        for index in range(1, 101):
            case = make_attachment_read_case(index)
            prompt = case["instruction"].format(
                attachment_id="00000000-0000-4000-8000-000000000000",
                filename=case["filename"],
            )
            self.assertNotIn(case["nonce"], prompt)
            self.assertNotIn(case["nonce"], case["filename"])
            self.assertEqual(case["content"], case["nonce"] + "\n")
            self.assertTrue(case["filename"].endswith(".txt"))

    def test_rounds_have_distinct_nonces_and_filenames(self) -> None:
        first = make_attachment_read_case(1)
        second = make_attachment_read_case(2)
        self.assertNotEqual(first["nonce"], second["nonce"])
        self.assertNotEqual(first["filename"], second["filename"])
        self.assertEqual(first["instruction"], second["instruction"])

    def test_instruction_requires_reading_the_attachment(self) -> None:
        case = make_attachment_read_case(1)
        prompt = case["instruction"].format(
            attachment_id="00000000-0000-4000-8000-000000000000",
            filename=case["filename"],
        )
        self.assertIn("attached text file", prompt)
        self.assertIn("exact token", prompt)
        self.assertIn("attachment view", prompt)
        self.assertIn("00000000-0000-4000-8000-000000000000", prompt)
        self.assertIn(f"--output ./{case['filename']}", prompt)
        self.assertIn("current workspace", prompt)
        self.assertNotIn("/tmp/", prompt)
        self.assertNotIn("--output /", prompt)


class CorrelatedReplyTests(unittest.TestCase):
    def test_accepts_only_a_newer_reply_from_the_agent_carrying_the_token(self) -> None:
        rows = [
            {"seq": 4, "senderId": "agent-1", "content": "old token"},
            {"seq": 5, "senderId": "agent-2", "content": "new token"},
            {"seq": 6, "senderId": "agent-1", "content": "working on it"},
            {"seq": 7, "senderId": "agent-1", "content": "the token is new-token"},
        ]
        match = find_correlated_reply(rows, "agent-1", 5, "new-token")
        self.assertIsNotNone(match)
        self.assertEqual(match["seq"], 7)

    def test_rejects_a_reply_at_or_before_the_cursor(self) -> None:
        rows = [{"seq": 5, "senderId": "agent-1", "content": "new-token"}]
        self.assertIsNone(find_correlated_reply(rows, "agent-1", 5, "new-token"))
        self.assertIsNone(find_correlated_reply(rows, "agent-1", 6, "new-token"))

    def test_rejects_unrelated_agent_messages(self) -> None:
        rows = [
            {"seq": 6, "senderId": "agent-1", "content": "working on it"},
            {"seq": 7, "senderId": "agent-1", "content": "done"},
        ]
        self.assertIsNone(find_correlated_reply(rows, "agent-1", 5, "hidden-token"))

    def test_previous_round_token_cannot_satisfy_the_next_round(self) -> None:
        rows = [
            {"seq": 6, "senderId": "agent-1", "content": "the previous token was token-round-1"},
            {"seq": 7, "senderId": "agent-1", "content": "the token is token-round-2"},
        ]
        match = find_correlated_reply(rows, "agent-1", 5, "token-round-2")
        self.assertEqual(match["seq"], 7)
        self.assertNotIn("token-round-1", match["content"])

    def test_rejects_a_reply_from_another_sender(self) -> None:
        rows = [{"seq": 6, "senderId": "human-1", "content": "hidden-token"}]
        self.assertIsNone(find_correlated_reply(rows, "agent-1", 5, "hidden-token"))

    def test_rejects_malformed_rows(self) -> None:
        rows = [
            {"seq": "6", "senderId": "agent-1", "content": "hidden-token"},
            {"seq": 7, "senderId": "agent-1", "content": None},
            {"seq": 8, "senderId": "agent-1", "content": "hidden-token"},
        ]
        match = find_correlated_reply(rows, "agent-1", 5, "hidden-token")
        self.assertEqual(match["seq"], 8)


class FakeAcceptance(Acceptance):
    """A two-round agent that acknowledges, replays the old token, then answers."""

    def __init__(self) -> None:
        self.options = SimpleNamespace(reply_timeout=2.0)
        self.context = {"dm_channel_id": "dm-1", "dm_agent_id": "agent-1"}
        self.rows: list[dict] = []
        self.uploads: dict[str, tuple[bytes, str]] = {}
        self.sequence = 0
        self.previous_nonce: str | None = None

    def _append(self, sender_id: str, content: str) -> dict:
        self.sequence += 1
        row = {
            "id": f"row-{self.sequence}",
            "seq": self.sequence,
            "senderId": sender_id,
            "content": content,
        }
        self.rows.append(row)
        return row

    def upload_attachment(self, channel_id: str, content: bytes, filename: str) -> dict:
        attachment_id = f"attachment-{len(self.uploads) + 1}"
        self.uploads[attachment_id] = (content, filename)
        return {"id": attachment_id, "filename": filename}

    def send_message(self, channel_id: str, content: str, **extra) -> dict:
        human = self._append("human-1", content)
        body, _ = self.uploads[extra["attachmentIds"][0]]
        nonce = body.decode("utf-8").strip()
        self._append("agent-1", "I am working on it.")
        if self.previous_nonce is not None:
            self._append("agent-1", f"The previous token was {self.previous_nonce}.")
        self._append("agent-1", f"The token is {nonce}.")
        self.previous_nonce = nonce
        return human

    def messages(self, channel_id: str, after: int | None = None) -> list[dict]:
        return [row for row in self.rows if after is None or row["seq"] > after]


class AttachmentReadRunnerTests(unittest.TestCase):
    def test_two_rounds_accept_only_each_rounds_hidden_nonce(self) -> None:
        fake = FakeAcceptance()
        result = fake.check_attachment_read()
        rounds = result["attachment_read_rounds"]
        self.assertEqual(len(fake.uploads), 2)
        self.assertEqual(len(rounds), 2)
        self.assertNotEqual(rounds[0]["nonce"], rounds[1]["nonce"])
        self.assertGreater(rounds[1]["reply_seq"], rounds[0]["reply_seq"])
        for entry in rounds:
            self.assertNotIn(entry["nonce"], entry["filename"])
            reply = next(row for row in fake.rows if row["seq"] == entry["reply_seq"])
            self.assertIn(entry["nonce"], reply["content"])
        stale = [row for row in fake.rows if row["content"].startswith("The previous token was")]
        self.assertEqual(len(stale), 1)
        self.assertIn(rounds[0]["nonce"], stale[0]["content"])
        self.assertNotEqual(stale[0]["seq"], rounds[1]["reply_seq"])

    def test_missing_correlation_raises_a_recorded_failure(self) -> None:
        fake = FakeAcceptance()
        fake.options.reply_timeout = 0.01

        def no_answer(channel_id: str, content: str, **extra) -> dict:
            return fake._append("human-1", content)

        fake.send_message = no_answer
        with mock.patch("acceptance.time.sleep", return_value=None):
            with self.assertRaises(Failure):
                fake.check_attachment_read()


class AcceptanceCompletionTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.out = Path(temporary.name) / "report.json"
        self.print_patch = mock.patch("builtins.print")
        self.print_patch.start()
        self.addCleanup(self.print_patch.stop)

    def runner(self, **changes) -> Acceptance:
        options = dict(
            base_url="http://acceptance.invalid", socket_url=None, http_timeout=1,
            full=False, dry_run=False, restart_main=False,
            restart_computer=False, restart_agent=None, pg_container=None,
            database=None, out=str(self.out),
        )
        options.update(changes)
        return Acceptance(SimpleNamespace(**options))

    def passing_scope(self, runner: Acceptance) -> None:
        for name, _ in runner.plan():
            runner.record(name, "PASS", "offline control")

    def test_readonly_scope_completes_with_nine_excluded_skips(self) -> None:
        runner = self.runner()
        self.passing_scope(runner)
        for name in ("dm-reply", "mention-reply", "task", "attachment", "attachment-read",
                     "thread", "restart-main", "restart-computer", "restart-agent"):
            runner.record(name, "SKIP", "outside read-only scope")
        report = runner.write_report()
        self.assertEqual(len(report["required_checks"]), 5)
        self.assertEqual(report["counts"], {"PASS": 5, "SKIP": 9})
        self.assertTrue(report["execution_ok"])
        self.assertTrue(report["acceptance_complete"])
        self.assertTrue(report["passed"])
        self.assertEqual(report["completion_issues"], [])

    def test_required_nonpass_is_incomplete_even_with_no_failures(self) -> None:
        for status in ("SKIP", "BLOCKED", "DRY-RUN", "UNKNOWN"):
            with self.subTest(status=status):
                runner = self.runner()
                self.passing_scope(runner)
                runner.results[-1]["status"] = status
                report = runner.write_report()
                self.assertTrue(report["execution_ok"])
                self.assertFalse(report["acceptance_complete"])
                self.assertFalse(report["passed"])
                self.assertEqual(report["counts"].get("FAIL", 0), 0)
                self.assertTrue(report["completion_issues"])

    def test_missing_required_result_does_not_complete(self) -> None:
        runner = self.runner()
        self.passing_scope(runner)
        runner.results.pop()
        report = runner.write_report()
        self.assertFalse(report["acceptance_complete"])
        self.assertFalse(report["passed"])
        self.assertIn("read-only-sweep", str(report["completion_issues"]))

    def test_duplicate_required_pass_does_not_complete(self) -> None:
        runner = self.runner()
        self.passing_scope(runner)
        runner.record("read-only-sweep", "PASS", "duplicate control")
        report = runner.write_report()
        self.assertFalse(report["acceptance_complete"])
        self.assertFalse(report["passed"])
        self.assertIn("duplicate", str(report["completion_issues"]).lower())

    def test_full_scope_and_requested_restarts_are_required(self) -> None:
        runner = self.runner(full=True, restart_main=True, restart_computer=True,
                             restart_agent="keep-session")
        self.passing_scope(runner)
        report = runner.write_report()
        self.assertEqual(len(report["required_checks"]), 14)
        self.assertTrue(report["acceptance_complete"])
        runner.results[-1]["status"] = "SKIP"
        self.assertFalse(runner.write_report()["acceptance_complete"])

    def test_empty_results_cannot_complete(self) -> None:
        report = self.runner().write_report()
        self.assertFalse(report["acceptance_complete"])
        self.assertFalse(report["passed"])

    def test_dryrun_cannot_qualify_even_if_rows_claim_pass(self) -> None:
        runner = self.runner(dry_run=True)
        self.passing_scope(runner)
        report = runner.write_report()
        self.assertTrue(report["execution_ok"])
        self.assertFalse(report["acceptance_complete"])
        self.assertFalse(report["passed"])

    def test_behavior_failure_continues_but_outage_and_corruption_stop(self) -> None:
        runner = self.runner()
        runner.run("defect", mock.Mock(side_effect=Failure("contract mismatch")))
        follow = mock.Mock(return_value={"detail": "continued"})
        runner.run("independent", follow)
        follow.assert_called_once()
        self.assertIsNone(runner.stopped)
        self.assertTrue(runner.write_report()["execution_ok"])
        self.assertFalse(runner.write_report()["passed"])
        for error in (Outage("health unavailable"), Corruption("revision moved")):
            with self.subTest(error=type(error).__name__):
                stopped = self.runner()
                stopped.run("stop", mock.Mock(side_effect=error))
                blocked = mock.Mock()
                stopped.run("later", blocked)
                blocked.assert_not_called()
                self.assertEqual(stopped.results[-1]["status"], "BLOCKED")
                report = stopped.write_report()
                self.assertFalse(report["execution_ok"])
                self.assertFalse(report["passed"])

    def test_missing_pg_is_skip_without_claiming_zero_unchanged(self) -> None:
        runner = self.runner()
        runner.context = {"access_token": "offline-token", "server_id": "server"}
        runner.http = mock.Mock()
        runner.http.request.return_value.status = 200
        runner.run("read-only-sweep", runner.check_readonly_sweep)
        result = runner.results[-1]
        self.assertEqual(result["status"], "SKIP")
        self.assertNotIn("unchanged", result["detail"])
        self.assertNotIn("revision_rows", result.get("data", {}))
        runner.http.request.assert_not_called()
        self.assertFalse(runner.write_report()["acceptance_complete"])

    def test_missing_after_snapshot_is_skip_not_zero_row_pass(self) -> None:
        for missing in (None, Skip("snapshot unavailable")):
            with self.subTest(missing=missing):
                runner = self.runner()
                runner.context = {"access_token": "offline-token", "server_id": "server"}
                runner.http = mock.Mock()
                runner.http.request.return_value.status = 200
                runner.db_snapshot = mock.Mock(side_effect=[["messages|root|1"], missing])
                runner.run("read-only-sweep", runner.check_readonly_sweep)
                self.assertEqual(runner.results[-1]["status"], "SKIP")
                self.assertNotIn("revision_rows", runner.results[-1].get("data", {}))

    def test_snapshot_revision_change_is_still_corruption(self) -> None:
        runner = self.runner()
        runner.context = {"access_token": "offline-token", "server_id": "server"}
        runner.http = mock.Mock()
        runner.http.request.return_value.status = 200
        runner.db_snapshot = mock.Mock(side_effect=[["messages|root|1"], ["messages|root|2"]])
        runner.run("read-only-sweep", runner.check_readonly_sweep)
        self.assertEqual(runner.results[-1]["status"], "FAIL")
        self.assertIn("corruption", runner.stopped)

    def test_readonly_http_refusal_is_not_functional_success(self) -> None:
        for status in (401, 403, 404):
            with self.subTest(status=status):
                runner = self.runner()
                runner.context = {"access_token": "offline-token", "server_id": "server"}
                runner.http = mock.Mock()
                runner.http.request.return_value.status = status
                runner.db_snapshot = mock.Mock(return_value=["messages|root|1"])
                runner.run("read-only-sweep", runner.check_readonly_sweep)
                self.assertEqual(runner.results[-1]["status"], "FAIL")
                self.assertIn(str(status), runner.results[-1]["detail"])
                self.assertIsNone(runner.stopped)

    def test_scope_status_checks_do_not_hide_corruption_or_treat_api_500_as_outage(self) -> None:
        for status, changed in ((500, False), (401, True)):
            with self.subTest(status=status, changed=changed):
                runner = self.runner()
                runner.context = {"access_token": "offline-token", "server_id": "server"}
                runner.http = mock.Mock()
                runner.http.request.side_effect = lambda method, path, **kw: SimpleNamespace(
                    status=status if path == "/api/channels" else 200)
                before = ["messages|root|1"]
                after = ["messages|root|2"] if changed else before
                runner.db_snapshot = mock.Mock(side_effect=[before, after])
                runner.run("read-only-sweep", runner.check_readonly_sweep)
                self.assertEqual(runner.results[-1]["status"], "FAIL")
                if changed:
                    self.assertIn("corruption", runner.stopped)
                else:
                    self.assertIsNone(runner.stopped)
                    independent = mock.Mock(return_value={})
                    runner.run("independent", independent)
                    independent.assert_called_once()

    def test_sweep_health_503_still_stops_as_outage(self) -> None:
        runner = self.runner()
        runner.context = {"access_token": "offline-token", "server_id": "server"}
        runner.http = mock.Mock()
        runner.http.request.return_value.status = 503
        runner.db_snapshot = mock.Mock(return_value=["messages|root|1"])
        runner.run("read-only-sweep", runner.check_readonly_sweep)
        self.assertEqual(runner.results[-1]["status"], "FAIL")
        self.assertIn("outage", runner.stopped)

    def test_unchanged_snapshot_is_real_pass(self) -> None:
        runner = self.runner()
        runner.context = {"access_token": "offline-token", "server_id": "server"}
        runner.http = mock.Mock()
        runner.http.request.return_value.status = 200
        runner.db_snapshot = mock.Mock(return_value=["messages|root|1"])
        runner.run("read-only-sweep", runner.check_readonly_sweep)
        result = runner.results[-1]
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["data"]["revision_rows"], 1)
        self.assertEqual(len(result["data"]["read_only_statuses"]), 7)

    def main_args(self) -> list[str]:
        return ["--env-file", str(self.out.parent / "absent.env"), "--base-url",
                "http://acceptance.invalid", "--out", str(self.out)]

    def test_dryrun_cli_exits_zero_without_network_or_product_pass(self) -> None:
        with mock.patch.dict("os.environ", {}, clear=True), \
             mock.patch("acceptance.HTTPClient.request", side_effect=AssertionError("network")):
            self.assertEqual(main(self.main_args() + ["--dry-run"]), 0)
        report = json.loads(self.out.read_text())
        self.assertFalse(report["passed"])
        self.assertFalse(report["acceptance_complete"])
        self.assertEqual(report["counts"], {"DRY-RUN": 5})

    def test_cli_required_skip_returns_nonzero(self) -> None:
        with mock.patch.dict("os.environ", {}, clear=True), \
             mock.patch.object(Acceptance, "check_health", return_value={}), \
             mock.patch.object(Acceptance, "check_login", side_effect=Skip("no credentials")), \
             mock.patch("acceptance.HTTPClient.request", side_effect=AssertionError("network")):
            self.assertEqual(main(self.main_args()), 1)
        report = json.loads(self.out.read_text())
        self.assertFalse(report["passed"])
        self.assertFalse(report["acceptance_complete"])
        self.assertEqual(report["counts"].get("FAIL", 0), 0)


if __name__ == "__main__":
    unittest.main()
