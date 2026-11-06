#!/usr/bin/env python3
"""Regression tests for architecture scan scopes and baseline updates."""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("check_architecture.py")
SPEC = importlib.util.spec_from_file_location("check_architecture", SCRIPT)
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)
METRICS = {metric["id"]: metric for metric in guard.RATCHET_METRICS}


class ArchitectureFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def put(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        return target

    def baseline(self, metric_id, counts):
        return self.put(METRICS[metric_id]["baseline"], guard.render_baseline_tsv(counts))

    def cli(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = guard.main(["--root", str(self.root), *args])
        return code, stdout.getvalue(), stderr.getvalue()


class ArchitectureGuardTests(ArchitectureFixture):
    def test_complete_server_dependency_closure_excludes_daemon_only_targets(self):
        server = {"RaftHTTP", "RaftHTTPServer", "RaftRealtime", "RaftServer",
                  "RaftMachineSocket", "RaftConnectAuth", "RaftShared"}
        for target in server | {"RaftDaemon", "RaftDaemonClient"}:
            self.put(f"Sources/{target}/Example.swift",
                     "HTTPReply JSONSerialization [String: Any] EmailLoginDirectory @unchecked Sendable\n")
        for metric_id, count in [("httpreply_sources", 1), ("json_any_sources", 2),
                                 ("unchecked_sendable_server", 1)]:
            with self.subTest(metric=metric_id):
                counts = guard.scan_ratchet_metric(self.root, METRICS[metric_id])
                self.assertEqual({Path(path).parts[1] for path in counts}, server)
                self.assertEqual(sum(counts.values()), count * len(server))
        for metric_id in ("directory_references", "unchecked_sendable"):
            self.assertEqual(sum(guard.scan_ratchet_metric(self.root, METRICS[metric_id]).values()), 9)

    def test_overlapping_roots_count_each_file_once(self):
        self.put("Sources/RaftHTTP/Services/Example.swift", "HTTPReply HTTPReply\n")
        metric = dict(METRICS["httpreply_sources"], roots=(Path("Sources"),
                      Path("Sources/RaftHTTP"), Path("Sources/RaftHTTP/Services")))
        self.assertEqual(guard.scan_ratchet_metric(self.root, metric),
                         {"Sources/RaftHTTP/Services/Example.swift": 2})

    def test_generated_exclusion_is_exact_and_shared_by_all_match_metrics(self):
        text = "HTTPReply JSONSerialization EmailLoginDirectory @unchecked Sendable\n"
        self.put("Sources/RaftHTTPServer/Generated/Nested/Corpus.swift", text * 3)
        handwritten = "Sources/RaftHTTPServer/GeneratedHelpers/Example.swift"
        self.put(handwritten, text)
        for metric_id in ("httpreply_sources", "json_any_sources", "directory_references",
                          "unchecked_sendable", "unchecked_sendable_server"):
            with self.subTest(metric=metric_id):
                self.assertEqual(guard.scan_ratchet_metric(self.root, METRICS[metric_id]),
                                 {handwritten: 1})

    def test_json_any_metric_does_not_claim_string_json_coverage(self):
        typed = "Sources/RaftHTTP/Typed.swift"
        self.put(typed, "JSONSerialization [String: Any] [String:Any]\n")
        self.put("Sources/RaftHTTP/Strings.swift",
                 r'let body = "{\"id\":\"" + id + "\"}"' + "\n")
        self.assertEqual(guard.scan_ratchet_metric(self.root, METRICS["json_any_sources"]),
                         {typed: 3})

    def test_directory_identifier_boundaries_and_multiple_occurrences(self):
        path = "Sources/RaftHTTP/Example.swift"
        self.put(path, "extension EmailLoginDirectory { EmailLoginDirectory() }\n"
                       "NotEmailLoginDirectory EmailLoginDirectorySuffix\n")
        self.assertEqual(guard.scan_ratchet_metric(self.root, METRICS["directory_references"]),
                         {path: 2})

    def test_raw_counts_include_comments(self):
        path = "Sources/RaftShared/Example.swift"
        self.put(path, "// HTTPReply is a compatibility bridge\n")
        self.assertEqual(guard.scan_ratchet_metric(self.root, METRICS["httpreply_sources"]),
                         {path: 1})

    def test_growth_is_rejected_before_any_baseline_is_written(self):
        early = "Sources/RaftHTTP/Early.swift"
        late = "Sources/RaftHTTP/Late.swift"
        first = self.baseline("extension_directory", {early: 2})
        last = self.baseline("unchecked_sendable_server", {})
        self.put(early, "extension EmailLoginDirectory {}\n")
        self.put(late, "@unchecked Sendable\n")
        before = {path: path.read_bytes() for path in (first, last)}
        with self.assertRaisesRegex(guard.GuardrailError, "refusing to raise"):
            guard.update_ratchet_baselines(self.root)
        self.assertEqual({path: path.read_bytes() for path in before}, before)
        self.assertEqual(set((self.root / "scripts").glob("*.tsv")), set(before))

    def test_existing_path_growth_is_rejected(self):
        path = "Sources/RaftHTTP/Example.swift"
        self.put(path, "HTTPReply HTTPReply\n")
        baseline = self.baseline("httpreply_sources", {path: 1})
        with self.assertRaisesRegex(guard.GuardrailError, "exceeds baseline 1"):
            guard.update_ratchet_baselines(self.root)
        self.assertEqual(baseline.read_text(), f"{path}\t1\n")

    def test_lowering_and_deleted_files_update_and_then_pass(self):
        path = "Sources/RaftHTTP/Example.swift"
        self.put(path, "HTTPReply\n")
        self.baseline("httpreply_sources", {path: 2, "Sources/RaftHTTP/Deleted.swift": 1})
        before = guard.check_ratchet_metric(self.root, METRICS["httpreply_sources"])
        self.assertEqual(before["status"], "fail")
        self.assertEqual(len(before["under"]), 2)
        guard.update_ratchet_baselines(self.root)
        self.assertEqual(guard.read_ratchet_baseline(self.root, METRICS["httpreply_sources"]), {path: 1})
        self.assertEqual(guard.check_ratchet_metric(self.root, METRICS["httpreply_sources"])["status"], "pass")

    def test_missing_baseline_is_zero_and_export_is_read_only(self):
        path = "Sources/RaftShared/New.swift"
        self.put(path, "HTTPReply\n")
        code, output, errors = self.cli("--print-ratchet-baseline", "httpreply_sources")
        self.assertEqual((code, output, errors), (0, f"{path}\t1\n", ""))
        self.assertFalse((self.root / "scripts").exists())
        code, output, errors = self.cli("--update-baselines", "--json")
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(output)["exit_code"], 2)
        self.assertIn("no baselines written", errors)
        self.assertFalse((self.root / "scripts").exists())
        # A reviewer explicitly adopts the exported migration, then ordinary updates work.
        self.baseline("httpreply_sources", {path: 1})
        self.assertEqual(self.cli("--update-baselines")[0], 0)

    def test_malformed_late_baseline_cannot_partially_lower_earlier_metric(self):
        path = "Sources/RaftHTTP/Old.swift"
        early = self.baseline("extension_directory", {path: 1})
        self.put(METRICS["unchecked_sendable_server"]["baseline"], "invalid\n")
        with self.assertRaisesRegex(guard.GuardrailError, "expected 'path<TAB>count'"):
            guard.update_ratchet_baselines(self.root)
        self.assertEqual(early.read_text(), f"{path}\t1\n")

    def test_duplicate_baseline_rows_are_rejected(self):
        self.put(METRICS["httpreply_sources"]["baseline"], "Sources/A.swift\t1\nSources/A.swift\t1\n")
        with self.assertRaisesRegex(guard.GuardrailError, "duplicate entry"):
            guard.read_ratchet_baseline(self.root, METRICS["httpreply_sources"])

    def test_store_ceiling_includes_nested_files_and_unterminated_last_line(self):
        self.put("Sources/RaftHTTP/Stores/AtLimit.swift", "// line\n" * 1000)
        self.put("Sources/RaftHTTP/Stores/Nested/OverLimit.swift", "// line\n" * 1000 + "// last")
        result = guard.check_store_file_ceilings(self.root)
        self.assertEqual(result["status"], "fail")
        self.assertEqual(len(result["files"]), 2)
        self.assertEqual([(entry["lines"], entry["limit"]) for entry in result["violations"]], [(1001, 1000)])
        (self.root / "Sources/RaftHTTP/Stores/Nested/OverLimit.swift").write_text("// line\n" * 1000)
        self.assertEqual(guard.check_store_file_ceilings(self.root)["status"], "pass")

    def test_missing_store_directory_reports_zero(self):
        result = guard.check_store_file_ceilings(self.root)
        self.assertEqual((result["status"], result["directory_present"], result["files"]),
                         ("pass", False, []))

    def test_evaluate_wires_store_ceiling_and_reports_its_limit(self):
        self.put("Sources/RaftHTTP/EmailLogin.swift", "")
        self.put("scripts/for_testing_baseline.tsv", "")
        self.put("Sources/RaftHTTP/Stores/Over.swift", "// line\n" * 1001)
        report = guard.evaluate(self.root)
        self.assertEqual(report["baselines"]["store_file_line_limit"], 1000)
        self.assertEqual(report["exit_code"], 1)
        self.assertEqual([check["id"] for check in report["checks"] if check["status"] == "fail"],
                         ["store-file-ceiling"])


class JSONStringPayloadTests(ArchitectureFixture):
    def test_actual_body_literals_interpolation_and_concatenation(self):
        source = r'''
        body: "{\"error\":\"Attachment \(id) is not available for this sender.\",\"code\":\"attachment_not_found\"}",
        let empty = AgentSurfaceBodyResponse(body: "{\"summaries\":[],\"next\":null}")
        let list = "[" + rows.joined(separator: ",") + "]"
        let object = "{\"id\":\"" + id + "\"}"
        let fields = OrderedJSON.object([("error", .string(reason)), ("code", .string(code))])
        '''
        self.assertEqual(guard.count_json_string_payloads(source), 4)
        self.assertEqual(guard.count_json_string_payloads('let body = "[]"'), 1)

    def test_comments_are_skipped_but_comment_markers_in_strings_are_data(self):
        source = r'''
        // body: "{\"hidden\":true}"
        /* outer "[]" /* nested #"{"hidden":true}"# */ "{}" */
        let body = "{\"url\":\"https://host/path/*data*/\"}"
        let raw = #"{"text":"// stays in payload"}"#
        '''
        self.assertEqual(guard.count_json_string_payloads(source), 2)

    def test_raw_strings_with_one_or_multiple_hashes(self):
        source = r'''
        let first = #"{"id":"\#(id)"}"#
        let second = ##"["text", {"id":"\##(id)"}]"##
        let inactiveEscape = #"{"path":"\(ordinary raw data)"}"#
        '''
        self.assertEqual(guard.count_json_string_payloads(source), 3)

    def test_multiline_and_raw_multiline_literals(self):
        source = r'''
        let object = """
          {"id":"\(id)","quote":"\""}
          """
        let array = ##"""
          [{"id":"\##(id)"}]
          """##
        let label = """
          [INFO] this is a log label
          """
        '''
        self.assertEqual(guard.count_json_string_payloads(source), 2)

    def test_nested_string_literals_in_interpolation_are_scanned_once(self):
        source = r'''
        let body = "{\"result\":\(lookup("{\"id\":1}", (1 + 2)))}"
        let raw = #"{"result":\#(lookup(#"[true]"#, (3 + 4)))}"#
        '''
        self.assertEqual(guard.count_json_string_payloads(source), 4)

    def test_interpolation_skips_comments_and_balances_parentheses(self):
        source = r'''
        let body = "{\"result\":\(lookup(
          /* ) "[]" /* nested */ */ value, // ) "{}"
          (1 + 2)))}"
        let after = "[null]"
        '''
        self.assertEqual(guard.count_json_string_payloads(source), 2)

    def test_escaped_backslash_does_not_open_interpolation(self):
        source = r'''
        let body = "{\"text\":\"\\(notInterpolation)\"}"
        let after = "{}"
        '''
        self.assertEqual(guard.count_json_string_payloads(source), 2)

    def test_plain_labels_field_names_and_scalar_strings_do_not_count(self):
        source = r'''
        let labels = ["[", "{", "[INFO]", "[error]", "[1tag]", "[truthy]", "[falsehood]", "{name}"]
        let fields = OrderedJSON.object([("field", .string("plain value")), ("count", .integer(1))])
        let scalar = "true"
        '''
        self.assertEqual(guard.count_json_string_payloads(source), 0)
        # JSON-shaped labels remain candidates: the scanner cannot infer intent.
        self.assertEqual(guard.count_json_string_payloads('let label = "[1]"'), 1)

    def test_array_value_starts_whitespace_and_bare_concat_fragments(self):
        source = r'''
        let values = ["[]", "[  ]", "[true]", "[false]", "[null]", "[-1.2]", "[0]", "[[1]]", "[{}]"]
        let interpolated = "[\(elements)]"
        let whitespace = "\n\t{\"id\":1}"
        let arrayPrefix = "[ " /* ignored */ + elements + "]"
        let objectPrefix = "{" // ignored
          + fields + "}"
        '''
        self.assertEqual(guard.count_json_string_payloads(source), 13)

    def test_documented_unicode_and_variable_assembly_gaps(self):
        source = r'''
        let unicodeDelimiter = "\u{7b}\"key\":1}"
        let assembled = openingVariable + fields + closingVariable
        let appendDelimiter = "["
        '''
        self.assertEqual(guard.count_json_string_payloads(source), 0)

    def test_json_string_metric_scope_generated_exclusion_and_deduplication(self):
        metric = METRICS["json_string_payloads"]
        self.assertEqual(metric["roots"], guard.SERVER_SURFACE_RELATIVE)
        for target in guard.SERVER_SURFACE_RELATIVE:
            self.put(target / "Payload.swift", 'let body = "[]"\n')
        self.put("Sources/RaftDaemonClient/Payload.swift", 'let body = "[]"\n')
        self.put("Sources/RaftHTTPServer/Generated/Corpus.swift", 'let body = "[]"\n')
        counts = guard.scan_ratchet_metric(self.root, metric)
        self.assertEqual((len(counts), sum(counts.values())), (7, 7))
        overlap = dict(metric, roots=(*metric["roots"], Path("Sources/RaftHTTP")))
        self.assertEqual(guard.scan_ratchet_metric(self.root, overlap), counts)

    def test_nonzero_initial_baseline_export_and_only_decreasing_updates(self):
        path = "Sources/RaftHTTP/Services/Payload.swift"
        self.put(path, 'let body = "[]"\n')
        metric = METRICS["json_string_payloads"]
        self.assertEqual(guard.check_ratchet_metric(self.root, metric)["status"], "fail")
        code, output, errors = self.cli("--print-ratchet-baseline", "json_string_payloads")
        self.assertEqual((code, output, errors), (0, f"{path}\t1\n", ""))
        with self.assertRaises(guard.GuardrailError):
            guard.update_ratchet_baselines(self.root)
        self.baseline("json_string_payloads", {path: 1})
        self.assertEqual(guard.check_ratchet_metric(self.root, metric)["status"], "pass")
        self.put(path, '// removed body: "[]"\n')
        self.assertEqual(guard.check_ratchet_metric(self.root, metric)["status"], "fail")
        guard.update_ratchet_baselines(self.root)
        self.assertEqual(guard.read_ratchet_baseline(self.root, metric), {})
        self.assertEqual(guard.check_ratchet_metric(self.root, metric)["status"], "pass")


if __name__ == "__main__":
    unittest.main()
