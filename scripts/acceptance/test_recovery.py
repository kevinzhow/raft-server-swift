#!/usr/bin/env python3
"""Focused, network-free tests for the recovery scenarios.

Run with ``python3 -m unittest discover -s scripts/acceptance -p 'test_*.py'``.
No real unit is started or stopped and no HTTP request leaves the process: the
unit controller, the runner and the HTTP client are fakes.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import acceptance
import recovery
from client import HTTPResult


class FakeUnitControl:
    """Records every lifecycle call and models a systemd unit instance."""

    def __init__(
        self,
        events: list[str],
        *,
        active: bool = True,
        fail_start: bool = False,
        reuse_identity: bool = False,
    ) -> None:
        self.events = events
        self.active = active
        self.fail_start = fail_start
        self.reuse_identity = reuse_identity
        self.invocation = "invocation-1"
        self.pid = 100
        self.starts = 0

    def show(self, unit: str) -> dict:
        self.events.append("show")
        return {
            "unit": unit,
            "mainPid": self.pid if self.active else 0,
            "invocationId": self.invocation,
            "activeState": "active" if self.active else "inactive",
            "subState": "running" if self.active else "dead",
        }

    def stop(self, unit: str) -> None:
        self.events.append("stop")
        self.active = False

    def start(self, unit: str) -> None:
        self.events.append("start")
        if self.fail_start:
            raise recovery.UnitControlError(f"{unit}: start failed")
        self.active = True
        self.starts += 1
        if not self.reuse_identity:
            self.invocation = f"invocation-{self.starts + 1}"
            self.pid = 100 + self.starts

    def wait_inactive(self, unit: str, timeout: float) -> dict:
        self.events.append("wait-inactive")
        if self.active:
            raise recovery.UnitControlError(f"{unit} is still active")
        return self.show(unit)

    def wait_active(self, unit: str, timeout: float) -> dict:
        self.events.append("wait-active")
        if not self.active:
            raise recovery.UnitControlError(f"{unit} is still inactive")
        return self.show(unit)


class FakeHTTP:
    def __init__(self, events: list[str], status: int = 202, body: bytes = b'{"ok":true,"status":"accepted"}'):
        self.events = events
        self.status = status
        self.body = body
        self.calls: list[dict] = []

    def request(self, method, path, body=None, headers=None, **kwargs):  # noqa: ANN001
        self.events.append("reset")
        self.calls.append({"method": method, "path": path, "body": body, "headers": headers})
        return HTTPResult(self.status, {}, self.body)


class FakeRunner:
    """A correlated two-reply agent with an offline window for the first send."""

    def __init__(self, events: list[str], control: FakeUnitControl | None = None) -> None:
        self.events = events
        self.control = control
        self.rows: list[dict] = []
        self.sequence = 0
        self.sent_while_active: list[bool] = []
        self.options = SimpleNamespace(reply_timeout=1.0)
        self.context = {"server_id": "server-1"}
        self.http = FakeHTTP(events)
        self.send_error: BaseException | None = None
        self.wait_error: BaseException | None = None

    def auth_headers(self, server_id: str | None = None) -> dict[str, str]:
        return {"Authorization": "Bearer test", "X-Server-Id": server_id or "server-1"}

    def send_message(self, channel_id: str, content: str, **extra) -> dict:
        self.events.append("send")
        self.sent_while_active.append(bool(self.control and self.control.active))
        if self.send_error is not None:
            raise self.send_error
        self.sequence += 1
        row = {
            "id": f"row-{self.sequence}",
            "seq": self.sequence,
            "senderId": "human-1",
            "content": content,
        }
        self.rows.append(row)
        return row

    def wait_for_agent_reply(
        self,
        channel_id: str,
        agent_id: str,
        after_seq: int,
        label: str,
        *,
        expect_text: str | None = None,
    ) -> dict | None:
        self.events.append("wait")
        if self.wait_error is not None:
            raise self.wait_error
        if self.control is not None and not self.control.active:
            raise acceptance.Failure(f"{label}: the agent is offline")
        self.sequence += 1
        row = {
            "id": f"row-{self.sequence}",
            "seq": self.sequence,
            "senderId": agent_id,
            "content": f"the token is {expect_text}",
        }
        self.rows.append(row)
        return acceptance.find_correlated_reply(self.rows, agent_id, after_seq, expect_text)

    def messages(self, channel_id: str, after: int | None = None) -> list[dict]:
        return [row for row in self.rows if after is None or row["seq"] > after]


class ComputerRestartScenarioTests(unittest.TestCase):
    def make(self, **control_options) -> tuple[list[str], FakeUnitControl, FakeRunner]:
        events: list[str] = []
        control = FakeUnitControl(events, **control_options)
        runner = FakeRunner(events, control)
        return events, control, runner

    def test_stop_then_offline_send_then_start_then_two_correlated_replies(self) -> None:
        events, control, runner = self.make()
        data = recovery.run_computer_restart(
            runner, "computer.service", control, "dm-1", "agent-1"
        )

        self.assertLess(events.index("stop"), events.index("send"))
        sends = [index for index, event in enumerate(events) if event == "send"]
        starts = [index for index, event in enumerate(events) if event == "start"]
        waits = [index for index, event in enumerate(events) if event == "wait"]
        self.assertEqual(len(sends), 2)
        self.assertEqual(len(starts), 1)
        self.assertEqual(len(waits), 2)
        self.assertLess(sends[0], starts[0])
        self.assertLess(starts[0], waits[0])
        self.assertLess(waits[0], sends[1])
        self.assertLess(sends[1], waits[1])
        self.assertEqual(runner.sent_while_active, [False, True])
        self.assertTrue(control.active)

        first = data["computer_restart_first_reply"]
        second = data["computer_restart_second_reply"]
        self.assertNotEqual(first["marker"], second["marker"])
        self.assertLess(first["replySeq"], second["replySeq"])
        self.assertEqual(first["senderId"], "agent-1")
        self.assertEqual(second["senderId"], "agent-1")
        self.assertTrue(data["computer_restart_unit"]["newInstance"])
        self.assertNotEqual(
            data["computer_restart_unit"]["original"]["invocationId"],
            data["computer_restart_unit"]["restarted"]["invocationId"],
        )

    def test_start_runs_in_finally_when_the_offline_send_fails(self) -> None:
        events, control, runner = self.make()
        runner.send_error = acceptance.Failure("offline send failed")
        with self.assertRaises(acceptance.Failure):
            recovery.run_computer_restart(runner, "computer.service", control, "dm-1", "agent-1")
        self.assertIn("start", events)
        self.assertLess(events.index("stop"), events.index("start"))
        self.assertNotIn("wait", events)
        self.assertTrue(control.active)

    def test_start_runs_in_finally_when_the_reply_wait_fails(self) -> None:
        events, control, runner = self.make()
        runner.wait_error = acceptance.Failure("no correlated reply")
        with self.assertRaises(acceptance.Failure):
            recovery.run_computer_restart(runner, "computer.service", control, "dm-1", "agent-1")
        self.assertEqual(events.count("start"), 1)
        self.assertTrue(control.active)

    def test_a_start_failure_is_recorded_after_a_start_attempt(self) -> None:
        events, control, runner = self.make(fail_start=True)
        with self.assertRaises(recovery.RecoveryError) as raised:
            recovery.run_computer_restart(runner, "computer.service", control, "dm-1", "agent-1")
        self.assertIn("could not be verified running", str(raised.exception))
        self.assertGreaterEqual(events.count("start"), 1)
        self.assertFalse(control.active)

    def test_the_restarted_unit_must_be_a_new_instance(self) -> None:
        events, control, runner = self.make(reuse_identity=True)
        with self.assertRaises(recovery.RecoveryError) as raised:
            recovery.run_computer_restart(runner, "computer.service", control, "dm-1", "agent-1")
        self.assertIn("new instance", str(raised.exception))
        self.assertTrue(control.active)

    def test_an_inactive_unit_is_not_stopped_or_messaged(self) -> None:
        events, control, runner = self.make(active=False)
        with self.assertRaises(recovery.RecoveryError):
            recovery.run_computer_restart(runner, "computer.service", control, "dm-1", "agent-1")
        self.assertEqual(events, ["show"])
        self.assertEqual(runner.sent_while_active, [])


class AgentRestartScenarioTests(unittest.TestCase):
    def test_reset_uses_mode_restart_and_sends_before_the_first_wait(self) -> None:
        events: list[str] = []
        runner = FakeRunner(events)
        data = recovery.run_agent_keep_session_restart(runner, "dm-1", "agent-1")

        self.assertEqual(events, ["reset", "send", "wait", "send", "wait"])
        call = runner.http.calls[0]
        self.assertEqual(call["method"], "POST")
        self.assertEqual(call["path"], "/api/agents/agent-1/reset")
        self.assertEqual(call["body"], {"mode": "restart"})
        self.assertEqual(data["agent_restart_reset"]["mode"], "restart")
        first = data["agent_restart_first_reply"]
        second = data["agent_restart_second_reply"]
        self.assertNotEqual(first["marker"], second["marker"])
        self.assertLess(first["replySeq"], second["replySeq"])

    def test_external_agent_is_a_recorded_blocked_dependency(self) -> None:
        events: list[str] = []
        runner = FakeRunner(events)
        runner.http.status = 400
        runner.http.body = b'{"error":"External agents do not use Raft-managed runtime lifecycle"}'
        with self.assertRaises(recovery.RecoveryBlocked):
            recovery.run_agent_keep_session_restart(runner, "dm-1", "agent-1")
        self.assertEqual(events, ["reset"])

    def test_reset_in_progress_is_a_recorded_blocked_dependency(self) -> None:
        events: list[str] = []
        runner = FakeRunner(events)
        runner.http.status = 409
        runner.http.body = b'{"code":"agent_reset_in_progress"}'
        with self.assertRaises(recovery.RecoveryBlocked):
            recovery.run_agent_keep_session_restart(runner, "dm-1", "agent-1")
        self.assertEqual(events, ["reset"])

    def test_rejected_reset_is_a_failure_before_any_message(self) -> None:
        events: list[str] = []
        runner = FakeRunner(events)
        runner.http.status = 403
        runner.http.body = b'{"error":"forbidden"}'
        with self.assertRaises(recovery.RecoveryError):
            recovery.run_agent_keep_session_restart(runner, "dm-1", "agent-1")
        self.assertEqual(events, ["reset"])

    def test_second_reply_must_be_newer_than_the_first(self) -> None:
        first = {"replySeq": 7, "marker": "first"}
        with self.assertRaises(recovery.RecoveryError):
            recovery._require_second_after_first(first, {"replySeq": 7})
        with self.assertRaises(recovery.RecoveryError):
            recovery._require_second_after_first(first, {"replySeq": 6})
        recovery._require_second_after_first(first, {"replySeq": 8})

    def test_evidence_rejects_a_stale_seq_a_wrong_sender_or_a_lost_marker(self) -> None:
        with self.assertRaises(recovery.RecoveryError):
            recovery._reply_evidence("token", 5, {"seq": 5, "senderId": "agent-1", "content": "token"}, "agent-1")
        with self.assertRaises(recovery.RecoveryError):
            recovery._reply_evidence("token", 5, {"seq": 6, "senderId": "other", "content": "token"}, "agent-1")
        with self.assertRaises(recovery.RecoveryError):
            recovery._reply_evidence("token", 5, {"seq": 6, "senderId": "agent-1", "content": "nope"}, "agent-1")
        evidence = recovery._reply_evidence(
            "token", 5, {"seq": 6, "senderId": "agent-1", "content": "the token is token"}, "agent-1"
        )
        self.assertEqual(evidence["replySeq"], 6)


class MarkerTests(unittest.TestCase):
    def test_markers_are_random_distinct_and_ask_for_the_exact_reply(self) -> None:
        first = recovery.new_marker("computer-offline")
        second = recovery.new_marker("computer-offline")
        self.assertNotEqual(first, second)
        self.assertTrue(first.startswith("acceptance-computer-offline-"))
        prompt = recovery.reply_exact_request(first, "queued")
        self.assertIn(first, prompt)
        self.assertIn("Reply with exactly", prompt)


class CliAndNonMutationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env_file = self.root / "empty.env"
        self.env_file.write_text("", encoding="utf-8")
        self.out = self.root / "report.json"

    def base_args(self) -> list[str]:
        return [
            "--env-file",
            str(self.env_file),
            "--base-url",
            "http://127.0.0.1:1",
            "--out",
            str(self.out),
        ]

    def test_dry_run_plans_all_restarts_without_starting_a_unit_or_sending(self) -> None:
        with mock.patch("acceptance.UnitControl") as unit_control, mock.patch(
            "acceptance.subprocess.run"
        ) as subprocess_run, mock.patch.object(acceptance.Acceptance, "send_message") as send:
            code = acceptance.main(
                self.base_args()
                + [
                    "--dry-run",
                    "--full",
                    "--restart-main",
                    "--restart-computer",
                    "--restart-agent",
                    "--computer-service-unit",
                    "computer.service",
                ]
            )
        self.assertEqual(code, 0)
        unit_control.assert_not_called()
        subprocess_run.assert_not_called()
        send.assert_not_called()
        report = json.loads(self.out.read_text(encoding="utf-8"))
        names = [entry["check"] for entry in report["results"]]
        for name in ("restart-main", "restart-computer", "restart-agent"):
            self.assertIn(name, names)

    def test_read_only_never_calls_a_unit_command_or_sends_a_message(self) -> None:
        def fake_health(self) -> dict:
            return {"detail": "ok", "health": {}, "version": {"sha": "test"}}

        def fake_login(self) -> dict:
            return {
                "detail": "login",
                "access_token": "token",
                "refresh_token": "refresh",
                "user_id": "user-1",
            }

        def fake_refresh(self) -> dict:
            return {"detail": "refresh", "access_token": "token", "refresh_token": "refresh"}

        def fake_servers(self) -> dict:
            return {"detail": "servers", "server_id": "server-1"}

        def fake_sweep(self) -> dict:
            return {"detail": "sweep", "revision_rows": 0}

        with mock.patch.multiple(
            acceptance.Acceptance,
            check_health=fake_health,
            check_login=fake_login,
            check_refresh=fake_refresh,
            check_servers=fake_servers,
            check_readonly_sweep=fake_sweep,
        ), mock.patch("acceptance.UnitControl") as unit_control, mock.patch(
            "acceptance.subprocess.run"
        ) as subprocess_run, mock.patch.object(acceptance.Acceptance, "send_message") as send:
            code = acceptance.main(self.base_args() + ["--read-only"])
        self.assertEqual(code, 0)
        unit_control.assert_not_called()
        subprocess_run.assert_not_called()
        send.assert_not_called()
        report = json.loads(self.out.read_text(encoding="utf-8"))
        self.assertEqual(report["mode"], "read-only")
        by_name = {entry["check"]: entry for entry in report["results"]}
        for name in ("restart-main", "restart-computer", "restart-agent"):
            self.assertEqual(by_name[name]["status"], "SKIP")

    def test_restart_flags_require_full_and_agent_accepts_only_keep_session(self) -> None:
        for extra in (
            ["--restart-computer"],
            ["--restart-agent"],
            ["--restart-agent", "keep-session"],
            ["--restart-agent", "session"],
            ["--restart-agent", "full"],
        ):
            with self.subTest(extra=extra):
                with self.assertRaises(SystemExit):
                    acceptance.main(self.base_args() + extra)


if __name__ == "__main__":
    unittest.main()
