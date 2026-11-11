"""Recovery scenarios for scripted acceptance.

The runner (``acceptance.Acceptance``) supplies the API operations; this module
owns the destructive unit lifecycle and the correlation/evidence rules. The
unit controller is injected so the network-free harness tests can prove the
stop -> send -> start ordering and the always-restart cleanup without touching
a real deployment.

Two scenarios:

  * Computer restart: stop the official Computer unit, send a DM while it is
    offline (queued delivery), start the unit again, require a correlated reply
    from the new instance, then send a second DM and require a newer correlated
    reply from the resident process. Main is never restarted and the agent
    session is never reset.
  * Agent keep-session restart: ``POST /api/agents/:id/reset`` with
    ``{"mode":"restart"}`` (HTTP 202), then the same two correlated DM replies.
    The reset mode is always ``restart``; ``session`` and ``full`` are never
    used.
"""

from __future__ import annotations

import secrets
import subprocess
import time

UNIT_PROPERTIES = ("MainPID", "InvocationID", "ActiveState", "SubState")
DEFAULT_UNIT_TIMEOUT = 90.0


class RecoveryError(Exception):
    """A recovery scenario failed without implying a Main outage."""


class RecoveryBlocked(RecoveryError):
    """A dependency is unavailable; record SKIP and continue the run."""


class UnitControlError(RecoveryError):
    """The systemd unit command failed or timed out."""


def new_marker(scenario: str) -> str:
    """A fresh random marker, independent for every recovery message."""
    return f"acceptance-{scenario}-{secrets.token_hex(8)}"


def reply_exact_request(marker: str, purpose: str) -> str:
    """The prompt asks for the exact marker, and the wait checks for it."""
    return f"{marker} {purpose}. Reply with exactly {marker} and nothing else."


def _short(value, limit: int = 240) -> str:
    return value[:limit] if isinstance(value, str) else ""


class UnitControl:
    """A thin ``systemctl --user`` wrapper for one unit.

    ``command_runner`` defaults to ``subprocess.run`` and is injectable for the
    network-free tests. Every command failure becomes ``UnitControlError`` so
    the acceptance runner records a ``Failure`` instead of treating it as a
    Main outage.
    """

    def __init__(self, command_runner=None, timeout: float = DEFAULT_UNIT_TIMEOUT):
        self._command_runner = command_runner or subprocess.run
        self.timeout = timeout

    def _systemctl(self, arguments: list[str]) -> str:
        command = ["systemctl", "--user", *arguments]
        try:
            result = self._command_runner(command, capture_output=True, text=True, timeout=self.timeout)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise UnitControlError(f"{' '.join(command)}: {error}") from None
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "").strip().splitlines()
            reason = detail[-1] if detail else "no output"
            raise UnitControlError(f"{' '.join(command)} -> {result.returncode}: {reason[:300]}")
        return result.stdout

    def show(self, unit: str) -> dict:
        """Current identity/state: MainPID, InvocationID, ActiveState, SubState."""
        properties = [f"--property={name}" for name in UNIT_PROPERTIES]
        output = self._systemctl(["show", unit, *properties])
        values: dict[str, str] = {}
        for line in output.splitlines():
            key, separator, value = line.partition("=")
            if separator:
                values[key.strip()] = value.strip()
        try:
            main_pid = int(values.get("MainPID") or 0)
        except ValueError:
            main_pid = 0
        return {
            "unit": unit,
            "mainPid": main_pid,
            "invocationId": values.get("InvocationID") or "",
            "activeState": values.get("ActiveState") or "",
            "subState": values.get("SubState") or "",
        }

    def stop(self, unit: str) -> None:
        self._systemctl(["stop", unit])

    def start(self, unit: str) -> None:
        self._systemctl(["start", unit])

    def restart(self, unit: str) -> None:
        self._systemctl(["restart", unit])

    def wait_state(self, unit: str, states: tuple[str, ...], timeout: float) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            state = self.show(unit)
            if state["activeState"] in states:
                return state
            if time.monotonic() >= deadline:
                raise UnitControlError(
                    f"{unit} did not reach {'/'.join(states)} within {timeout:.0f}s "
                    f"(state {state['activeState']}/{state['subState']})"
                )
            time.sleep(0.5)

    def wait_active(self, unit: str, timeout: float) -> dict:
        return self.wait_state(unit, ("active",), timeout)

    def wait_inactive(self, unit: str, timeout: float) -> dict:
        return self.wait_state(unit, ("inactive", "failed"), timeout)


def _ensure_active(control, unit: str, timeout: float) -> dict:
    """Start the unit only if it is not active, then require active/running."""
    state = control.show(unit)
    if state["activeState"] == "active":
        return state
    control.start(unit)
    return control.wait_active(unit, timeout)


def _require_new_instance(original: dict, restarted: dict) -> None:
    if restarted["activeState"] != "active":
        raise RecoveryError(
            f"{restarted['unit']} is not active after restart "
            f"({restarted['activeState']}/{restarted['subState']})"
        )
    new_invocation = bool(restarted["invocationId"]) and (
        restarted["invocationId"] != original["invocationId"]
    )
    new_pid = bool(restarted["mainPid"]) and restarted["mainPid"] != original["mainPid"]
    if not new_invocation and not new_pid:
        raise RecoveryError(
            f"{restarted['unit']} reports active but kept invocation "
            f"{restarted['invocationId']!r} and PID {restarted['mainPid']}; "
            "the stop/start did not produce a new instance"
        )


def _sent_seq(runner, channel_id: str, sent: dict) -> int:
    seq = sent.get("seq") if isinstance(sent, dict) else None
    if isinstance(seq, int):
        return seq
    rows = runner.messages(channel_id)
    return max([row.get("seq", 0) for row in rows if isinstance(row.get("seq"), int)] or [0])


def _reply_evidence(marker: str, sent_seq: int, reply: dict, agent_id: str) -> dict:
    seq = reply.get("seq") if isinstance(reply, dict) else None
    sender = reply.get("senderId") if isinstance(reply, dict) else None
    content = reply.get("content") if isinstance(reply, dict) else None
    if not isinstance(seq, int) or seq <= sent_seq:
        raise RecoveryError(f"reply seq {seq!r} is not after the sent seq {sent_seq}")
    if sender != agent_id:
        raise RecoveryError(f"reply came from {sender!r}, not the DM agent {agent_id!r}")
    if not isinstance(content, str) or marker not in content:
        raise RecoveryError(f"reply at seq {seq} does not carry the marker {marker}")
    return {
        "marker": marker,
        "sentSeq": sent_seq,
        "replySeq": seq,
        "replyId": reply.get("id"),
        "senderId": sender,
        "content": _short(content),
    }


def _require_second_after_first(first: dict, second: dict) -> None:
    if second["replySeq"] <= first["replySeq"]:
        raise RecoveryError(
            f"second reply seq {second['replySeq']} is not newer than the first reply seq "
            f"{first['replySeq']}"
        )


def run_computer_restart(
    runner,
    unit: str,
    control,
    channel_id: str,
    agent_id: str,
    *,
    unit_timeout: float = DEFAULT_UNIT_TIMEOUT,
) -> dict:
    """Stop Computer -> offline DM -> start -> two correlated resident replies.

    The unit is started in ``finally`` even when the offline send, the start
    verification or either wait fails, so this scenario never intentionally
    leaves the Computer stopped. Main is neither restarted nor reset here.
    """
    original = control.show(unit)
    if original["activeState"] != "active":
        raise RecoveryError(
            f"{unit} is not active before the Computer restart proof "
            f"({original['activeState']}/{original['subState']})"
        )

    first: dict | None = None
    second: dict | None = None
    stopped: dict | None = None
    restarted: dict | None = None
    failure: BaseException | None = None
    cleanup_error: BaseException | None = None

    try:
        control.stop(unit)
        stopped = control.wait_inactive(unit, unit_timeout)
        first_marker = new_marker("computer-offline")
        second_marker = new_marker("computer-resident")
        if first_marker == second_marker:
            raise RecoveryError("the Computer restart markers are not distinct")

        sent_first = runner.send_message(
            channel_id,
            reply_exact_request(
                first_marker,
                "The official Computer is stopped, so this DM is queued for it",
            ),
        )
        first_sent_seq = _sent_seq(runner, channel_id, sent_first)
        restarted = _ensure_active(control, unit, unit_timeout)
        _require_new_instance(original, restarted)
        reply_first = runner.wait_for_agent_reply(
            channel_id,
            agent_id,
            first_sent_seq,
            "Computer offline queued DM reply",
            expect_text=first_marker,
        )
        first = _reply_evidence(first_marker, first_sent_seq, reply_first, agent_id)

        sent_second = runner.send_message(
            channel_id,
            reply_exact_request(
                second_marker,
                "The official Computer is running again, so reply from the resident process",
            ),
        )
        second_sent_seq = _sent_seq(runner, channel_id, sent_second)
        reply_second = runner.wait_for_agent_reply(
            channel_id,
            agent_id,
            second_sent_seq,
            "Computer resident DM reply",
            expect_text=second_marker,
        )
        second = _reply_evidence(second_marker, second_sent_seq, reply_second, agent_id)
        _require_second_after_first(first, second)
    except BaseException as error:  # noqa: BLE001 - the unit is restarted below
        failure = error
    finally:
        try:
            restarted = _ensure_active(control, unit, unit_timeout)
        except BaseException as error:  # noqa: BLE001 - report the cleanup failure
            cleanup_error = error

    if cleanup_error is not None:
        suffix = f"; scenario error: {failure}" if failure is not None else ""
        raise RecoveryError(
            f"{unit} could not be verified running after the restart proof: {cleanup_error}{suffix}"
        )
    if failure is not None:
        raise failure

    if first is None or second is None or stopped is None or restarted is None:
        raise RecoveryError(f"{unit} restart proof finished without complete evidence")
    return {
        "detail": (
            f"{unit} stopped and restarted with a new instance; queued reply seq "
            f"{first['replySeq']} and resident reply seq {second['replySeq']}"
        ),
        "computer_restart_unit": {
            "unit": unit,
            "original": original,
            "stopped": stopped,
            "restarted": restarted,
            "newInstance": True,
        },
        "computer_restart_first_reply": first,
        "computer_restart_second_reply": second,
    }


def _reset_agent_keep_session(runner, agent_id: str) -> dict:
    result = runner.http.request(
        "POST",
        f"/api/agents/{agent_id}/reset",
        {"mode": "restart"},
        headers=runner.auth_headers(runner.context["server_id"]),
    )
    detail = _short(result.text.strip(), 300)
    if result.status == 202:
        try:
            body = result.json()
        except ValueError:
            body = None
        return {"status": 202, "mode": "restart", "body": body}
    if result.status == 400 and "external" in detail.lower():
        raise RecoveryBlocked(
            f"agent {agent_id} is external and has no Raft-managed lifecycle: {detail}"
        )
    if result.status == 409:
        raise RecoveryBlocked(f"another agent reset is in progress: {detail}")
    raise RecoveryError(
        f"POST /api/agents/{agent_id}/reset {{mode:restart}} -> HTTP {result.status}: {detail}"
    )


def run_agent_keep_session_restart(runner, channel_id: str, agent_id: str) -> dict:
    """Reset the DM agent with ``mode=restart`` and require two fresh replies.

    The session is not cleared: the only reset mode sent is ``restart``. The
    first DM is sent immediately after the accepted reset; the second DM then
    proves the restarted resident process still answers.
    """
    reset = _reset_agent_keep_session(runner, agent_id)
    first_marker = new_marker("agent-restart-first")
    second_marker = new_marker("agent-restart-second")
    if first_marker == second_marker:
        raise RecoveryError("the agent restart markers are not distinct")

    sent_first = runner.send_message(
        channel_id,
        reply_exact_request(
            first_marker,
            "The agent was restarted with its session kept, so reply from the restarted process",
        ),
    )
    first_sent_seq = _sent_seq(runner, channel_id, sent_first)
    reply_first = runner.wait_for_agent_reply(
        channel_id,
        agent_id,
        first_sent_seq,
        "agent keep-session restart reply",
        expect_text=first_marker,
    )
    first = _reply_evidence(first_marker, first_sent_seq, reply_first, agent_id)

    sent_second = runner.send_message(
        channel_id,
        reply_exact_request(
            second_marker,
            "Reply again after the keep-session restart",
        ),
    )
    second_sent_seq = _sent_seq(runner, channel_id, sent_second)
    reply_second = runner.wait_for_agent_reply(
        channel_id,
        agent_id,
        second_sent_seq,
        "agent post-restart second reply",
        expect_text=second_marker,
    )
    second = _reply_evidence(second_marker, second_sent_seq, reply_second, agent_id)
    _require_second_after_first(first, second)
    return {
        "detail": (
            f"agent reset with mode=restart (HTTP 202); replies at seq "
            f"{first['replySeq']} and {second['replySeq']}"
        ),
        "agent_restart_reset": reset,
        "agent_restart_first_reply": first,
        "agent_restart_second_reply": second,
    }
