import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

from evidence import Aliases, baseline_id, differences, digest, make_report
from transport import Client, Observation, PrivateEvidence


class AccountingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.baseline = {"upstream": {"sha": "reference"}, "swift": {"sha": "candidate"}}
        self.identity = baseline_id(self.baseline)
        artifact = self.root / "proof.json"
        artifact.write_text('{"status":200}')
        self.proof = {"path": artifact.name, "sha256": digest(artifact.read_bytes())}
        self.results = [{"target": target, "behavior_id": "download.bytes", "status": "PASS",
                         "baseline_id": self.identity, "evidence": [self.proof]}
                        for target in ("upstream", "swift")]
        self.comparisons = [{"behavior_id": "download.bytes", "status": "PASS", "baseline_id": self.identity}]

    def report(self, **overrides):
        values = {"baseline": self.baseline, "required": ["download.bytes"],
                  "results": self.results, "comparisons": self.comparisons,
                  "evidence_root": self.root,
                  "baseline_verified": {"upstream": True, "swift": True}}
        return make_report(**(values | overrides))

    def test_complete_evidence_still_requires_release_gates(self):
        self.assertTrue(self.report()["acceptance_complete"])
        self.assertFalse(self.report()["release_eligible"])
        self.assertTrue(self.report(gates_passed=True)["release_eligible"])

    def test_missing_required_run_cannot_become_a_zero_failure_pass(self):
        result = self.report(results=self.results[:1])
        self.assertTrue(result["execution_ok"])
        self.assertFalse(result["acceptance_complete"])
        self.assertEqual(result["counts"]["swift"]["NOT_RUN"], 1)

    def test_blocked_required_behavior_prevents_completion(self):
        self.results[1]["status"] = "BLOCKED"
        self.assertFalse(self.report()["acceptance_complete"])

    def test_current_results_do_not_accept_stale_or_changed_evidence(self):
        self.results[1]["baseline_id"] = "old-baseline"
        self.assertFalse(self.report()["acceptance_complete"])
        self.results[1]["baseline_id"] = self.identity
        (self.root / "proof.json").write_text('{"status":404}')
        self.assertFalse(self.report()["acceptance_complete"])

    def test_approved_deviation_does_not_credit_behavioral_pass(self):
        self.results[1]["disposition"] = "approved_deviation"
        self.assertFalse(self.report()["acceptance_complete"])

    def test_single_end_success_does_not_credit_pair(self):
        self.assertFalse(self.report(comparisons=[])["acceptance_complete"])
        self.comparisons[0]["status"] = "FAIL"
        self.assertFalse(self.report()["acceptance_complete"])
        self.assertFalse(self.report(baseline_verified={"swift": True})["acceptance_complete"])

    def test_duplicate_result_and_empty_denominator_are_errors(self):
        with self.assertRaises(ValueError):
            self.report(results=self.results + [self.results[0]])
        with self.assertRaises(ValueError):
            self.report(required=[])

    def test_evidence_cannot_escape_run_root(self):
        self.results[1]["evidence"] = [{"path": "../proof.json", "sha256": self.proof["sha256"]}]
        self.assertFalse(self.report()["acceptance_complete"])

    def test_critical_unresolved_defect_blocks_release(self):
        report = self.report(gates_passed=True, defects=[{"severity": "critical", "resolved": False}])
        self.assertTrue(report["acceptance_complete"])
        self.assertFalse(report["release_eligible"])


class ComparisonTests(unittest.TestCase):
    def test_aliases_preserve_references_and_reject_identity_collapse(self):
        a, b = Aliases(), Aliases()
        a.bind("attachment", "id-a")
        b.bind("attachment", "id-b")
        self.assertEqual(a.normalize({"id": "id-a", "ref": "id-a"}),
                         b.normalize({"id": "id-b", "ref": "id-b"}))
        with self.assertRaises(ValueError):
            a.bind("different-attachment", "id-a")
        with self.assertRaises(ValueError):
            a.bind("attachment", "new-id")

    def test_missing_null_types_array_order_and_unknown_fields_are_observable(self):
        for a, b in [({}, {"value": None}), ({"n": 1}, {"n": True}),
                     ({"n": 1}, {"n": "1"}), (["a", "b"], ["b", "a"]),
                     ({"id": "x"}, {"id": "x", "unknown": 2})]:
            with self.subTest(a=a, b=b):
                self.assertTrue(differences(a, b))
        self.assertEqual(differences({"a": 1, "b": None}, {"b": None, "a": 1}), [])


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.evidence = PrivateEvidence(self.root)
        self.hits = []
        hits = self.hits

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append((self.path, self.headers.get("Authorization")))
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/object")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                else:
                    body = bytes(range(256))
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Content-Type", "application/octet-stream")
                    self.end_headers()
                    self.wfile.write(body)

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)
        self.client = Client(f"http://127.0.0.1:{self.server.server_port}", self.evidence)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def test_http_preserves_arbitrary_bytes_and_does_not_follow_redirects(self):
        result = self.client.request("GET", "/object")
        self.assertEqual(result.body, bytes(range(256)))
        self.assertEqual(result.header("Content-Length"), "256")
        first = self.client.request("GET", "/redirect", headers={"Authorization": "Bearer test"})
        self.assertEqual(first.status, 302)
        self.assertEqual(first.header("Location"), "/object")
        self.assertEqual([path for path, _ in self.hits], ["/object", "/redirect"])
        private_file = self.root / first.evidence["path"]
        captured = json.loads(private_file.read_text())
        self.assertEqual(captured["request_headers"]["Authorization"], "<redacted>")
        self.assertEqual(private_file.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / "private").stat().st_mode & 0o777, 0o700)

    def test_binary_rejects_same_origin_or_non_https_redirect(self):
        with self.assertRaisesRegex(ValueError, "redirect"):
            self.client.binary("/redirect", headers={"Authorization": "Bearer test"})
        self.assertEqual([path for path, _ in self.hits], ["/redirect"])

    def test_object_request_carries_no_api_credentials(self):
        calls = []
        def fake_request(client, method, path, *, body=None, headers=None):
            calls.append((client.base_url, method, path, headers))
            if len(calls) == 1:
                return Observation(302, [("Location", "https://object.invalid/file?signature=private")], b"", {})
            return Observation(200, [], b"bytes", {})
        with patch.object(Client, "request", fake_request):
            first, final = self.client.binary("/download", headers={"Authorization": "Bearer test", "X-Server-Id": "id"})
        self.assertEqual(first.status, 302)
        self.assertEqual(final.body, b"bytes")
        self.assertIsNone(calls[1][3])

    def test_api_client_rejects_absolute_and_network_path_targets(self):
        for path in ("https://other.invalid/file", "//other.invalid/file"):
            with self.assertRaises(ValueError):
                self.client.request("GET", path, headers={"Authorization": "Bearer test"})

    def test_binary_does_not_follow_a_second_object_redirect(self):
        def fake_request(client, method, path, **kwargs):
            return Observation(302, [("Location", "https://object.invalid/file")], b"", {})
        with patch.object(Client, "request", fake_request):
            with self.assertRaisesRegex(ValueError, "second redirect"):
                self.client.binary("/download")


class ContractTraceabilityTests(unittest.TestCase):
    def test_required_rules_have_unique_source_traceability_and_match_executor(self):
        from attachment_pilot import REQUIRED
        contract = json.loads((Path(__file__).parent / "attachment_contract.json").read_text())
        rules = contract["required_rules"]
        identities = [row["behavior_id"] for row in rules]
        self.assertEqual(len(identities), len(set(identities)))
        self.assertEqual(set(identities), set(REQUIRED))
        self.assertEqual(contract["reference"]["source_tag"], "v1.21.23-source.1")
        for row in rules:
            self.assertTrue(row["operation_ids"], row["behavior_id"])
            self.assertTrue(row["source_refs"], row["behavior_id"])
            self.assertIn(row["profile"], contract["profiles"])
            self.assertTrue(row["preconditions"])
            self.assertTrue(row["expected"])
            self.assertTrue(row["test_or_scenario_id"])
            for reference in row["source_refs"]:
                source, lines = reference.rsplit(":", 1)
                self.assertFalse(Path(source).is_absolute())
                self.assertNotIn("..", Path(source).parts)
                self.assertRegex(lines, r"^[1-9][0-9]*(?:-[1-9][0-9]*)?$")
        self.assertTrue(contract["additional_required_rules"])
        self.assertTrue(all(row["status"] == "NOT_RUN" for row in contract["additional_required_rules"]))


if __name__ == "__main__":
    unittest.main()
