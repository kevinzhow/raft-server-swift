#!/usr/bin/env python3
"""Focused, network-free tests for the scripted acceptance runner.

Run with ``python3 -m unittest discover -s scripts/acceptance -p 'test_*.py'``.
These tests do not start a server and do not call the deployment.
"""

from __future__ import annotations

import unittest
from types import SimpleNamespace
from unittest import mock

from acceptance import (
    Acceptance,
    Failure,
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


if __name__ == "__main__":
    unittest.main()
