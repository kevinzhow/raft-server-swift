import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest

import upgrade_delta as tool


A = "packages/server/src/routes/files.ts"
H = "packages/shared/src/auth.ts"


def fixture():
    entry = {"operation_id": "HTTP GET /files/:id", "method": "GET", "path": "/files/:id",
             "raw_path_expression": '"/files/:id"', "constraints": {"raw_path": "/files/:id"},
             "source": {"file": A, "line": 10}, "mounts": [], "conditions": {"status": "unknown"},
             "entry_kind": "route", "transport": "HTTP", "listener": "express"}
    inventory = {"schema_version": 1, "scope": {"complete": True}, "baseline": {"source_files": [{"file": A, "sha256": "a" * 64}]},
                 "operations": [entry], "registrations": [], "unresolved_registrations": [], "extraction_errors": [], "review_items": []}
    rule = {"behavior_id": "download.bytes", "operation_ids": [entry["operation_id"]], "source_refs": [A + ":10-20", H + ":4"],
            "profile": "stream", "preconditions": ["member"], "expected": {"status": 200, "required_fields": ["id"]}, "dependencies": []}
    contract = {"schema_version": 1, "reference": {"sha": "old"}, "profiles": {"stream": {"storage": "local"}},
                "required_rules": [rule], "additional_required_rules": []}
    manifest = {"schema_version": 1, "kind": "source_manifest", "scope": {"includes": ["."], "exclusions": [],
                "coverage_complete": True, "coverage_statement": "Fixture contains the entire reviewed relevant source universe"},
                "coverage_issues": [], "files": [{"file": A, "sha256": "a" * 64}, {"file": H, "sha256": "b" * 64}]}
    return inventory, contract, manifest


class UpgradeDeltaTests(unittest.TestCase):
    def plan(self, change=None, manifests=True):
        old, contract, source = fixture()
        new, new_contract, new_source = copy.deepcopy((old, contract, source))
        if change:
            change(new, new_contract, new_source)
        return tool.compare(old, new, contract, new_contract, source if manifests else None, new_source if manifests else None)

    def test_same_routes_shared_auth_change_queues_every_rule_without_false_green(self):
        result = self.plan(lambda inv, con, src: src["files"][1].update(sha256="c" * 64))
        self.assertTrue(result["global_review_required"])
        self.assertEqual(result["source_changes"][0]["behavior_ids"], ["download.bytes"])
        self.assertEqual(result["entry_changes"], [])
        self.assertTrue(any(row.get("behavior_id") == "download.bytes" for row in result["reverification_queue"]))
        self.assertFalse(result["acceptance_complete"])
        self.assertFalse(result["release_eligible"])
        self.assertFalse(result["prior_passes_inherited"])
        self.assertTrue(all(row["status"] == "NOT_RUN" for row in result["reverification_queue"]))

    def test_required_field_profile_precondition_dependency_and_source_ref_changes(self):
        def change(inv, con, src):
            rule = con["required_rules"][0]
            rule["expected"]["required_fields"].append("mimeType")
            rule["preconditions"].append("live grant")
            rule["dependencies"] = ["missing.prerequisite"]
            rule["source_refs"].append("packages/server/src/services/storage.ts:9")
            con["profiles"]["stream"]["storage"] = "different capability"
        result = self.plan(change)
        fields = result["rule_changes"][0]["changed_fields"]
        self.assertTrue({"expected", "preconditions", "dependencies", "source_refs"}.issubset(fields))
        self.assertTrue(result["profiles_changed"])
        self.assertTrue(result["global_review_required"])
        self.assertIn("missing.prerequisite", result["coverage"]["unresolved_dependency_ids"])

    def test_raw_regex_mount_and_conditions_changes_are_not_normalized_away(self):
        def change(inv, con, src):
            entry = inv["operations"][0]
            entry["raw_path_expression"] = '"/files/:id([0-9]+).png"'
            entry["constraints"]["raw_path"] = "/files/:id([0-9]+).png"
            entry["mounts"] = [{"file": A, "line": 3, "resolved_prefix": "/private"}]
            entry["conditions"] = {"feature": "enabled"}
        row = self.plan(change)["entry_changes"][0]
        self.assertEqual(row["operation_id"], "HTTP GET /files/:id")
        self.assertTrue({"raw_path_expression", "constraints", "mounts", "conditions"}.issubset(row["changed_fields"]))

    def test_source_line_and_registration_id_drift_only_is_location_metadata(self):
        def change(inv, con, src):
            inv["operations"][0]["source"]["line"] = 110
            con["required_rules"][0]["source_refs"] = [A + ":110-120", H + ":104"]
        result = self.plan(change)
        self.assertEqual(result["entry_changes"][0]["change"], "source_location")
        self.assertEqual(result["rule_changes"][0]["change"], "source_location")
        self.assertEqual(result["rule_changes"][0]["changed_fields"], [])
        self.assertFalse(result["global_review_required"])
        self.assertFalse(result["acceptance_complete"])
        old, contract, sources = fixture()
        registration = {"registration_id": "f:1:10", "source": {"file": A, "line": 1}, "raw_call": 'router.use(auth)', "entry_kind": "middleware"}
        old["registrations"] = [registration]
        new = copy.deepcopy(old)
        new["registrations"][0].update(registration_id="f:101:1000", source={"file": A, "line": 101})
        result = tool.compare(old, new, contract, contract, sources, sources)
        self.assertEqual(result["registration_changes"]["added_candidates"], [])
        self.assertEqual(result["registration_changes"]["removed_candidates"], [])
        self.assertTrue(result["registration_changes"]["source_location_changed"])

    def test_route_source_hash_change_requires_review_not_asserted_behavior_change(self):
        def change(inv, con, src):
            inv["baseline"]["source_files"][0]["sha256"] = "c" * 64
            src["files"][0]["sha256"] = "c" * 64
        row = self.plan(change)["entry_changes"][0]
        self.assertEqual(row["change"], "review_required")
        self.assertEqual(row["changed_source_files"], [A])
        self.assertEqual(row["changed_fields"], [])

    def test_added_removed_entries_and_new_unknown_preserve_review_obligations(self):
        def change(inv, con, src):
            inv["operations"] = [{"operation_id": "HTTP POST /new", "method": "POST", "path": "/new"}]
            inv["unresolved_registrations"] = [{"registration_id": "f:10:20", "source": {"file": A, "line": 10}, "raw_call": "router[method](path, handler)"}]
            inv["extraction_errors"] = ["unresolved mount"]
            inv["registrations"] = [{"entry_kind": "middleware", "raw_call": "router.use(newAuth)"}]
        result = self.plan(change)
        self.assertEqual({row["change"] for row in result["entry_changes"]}, {"added", "removed"})
        self.assertEqual(len(result["pending_inputs"]["new"]["unresolved_registrations"]), 1)
        self.assertEqual(result["pending_inputs"]["new"]["extraction_errors"], ["unresolved mount"])
        queue = result["reverification_queue"]
        self.assertTrue(any(row.get("disposition") == "UNSPECIFIED" and row.get("operation_id") == "HTTP POST /new" for row in queue))
        self.assertTrue(any(row["kind"] == "consumer_compatibility_adjudication" for row in queue))
        self.assertTrue(result["global_review_required"])

    def test_missing_manifest_or_unmapped_source_does_not_narrow_impact(self):
        self.assertTrue(self.plan(manifests=False)["global_review_required"])
        result = self.plan(lambda inv, con, src: src["files"].append({"file": "package-lock.json", "sha256": "d" * 64}))
        self.assertTrue(result["global_review_required"])
        self.assertIn("changed_source_without_rule_mapping", result["global_review_reasons"])

    def test_strict_json_expected_numeric_types(self):
        for before, after in ((True, 1), (1, 1.0)):
            with self.subTest(before=repr(before), after=repr(after)):
                inventory, contract, sources = fixture()
                contract["required_rules"][0]["expected"] = {"nested": [{"flag": before}]}
                changed = copy.deepcopy(contract)
                changed["required_rules"][0]["expected"]["nested"][0]["flag"] = after
                result = tool.compare(inventory, inventory, contract, changed, sources, sources)
                self.assertIn("expected", result["rule_changes"][0]["changed_fields"])
                self.assertEqual(result["rule_changes"][0]["change"], "review_required")
                self.assertTrue(any(row.get("behavior_id") == "download.bytes" for row in result["reverification_queue"]))

    def test_strict_json_profiles_numeric_types(self):
        for before, after in ((True, 1), (1, 1.0)):
            with self.subTest(before=repr(before), after=repr(after)):
                inventory, contract, sources = fixture()
                second = copy.deepcopy(contract["required_rules"][0])
                second["behavior_id"] = "independent.rule"
                contract["required_rules"].append(second)
                contract["profiles"]["stream"]["live_grant"] = before
                changed = copy.deepcopy(contract)
                changed["profiles"]["stream"]["live_grant"] = after
                result = tool.compare(inventory, inventory, contract, changed, sources, sources)
                self.assertTrue(result["profiles_changed"])
                self.assertTrue(result["global_review_required"])
                self.assertIn("profile_definitions_changed", result["global_review_reasons"])
                queued = {row.get("behavior_id") for row in result["reverification_queue"] if row["kind"] == "rule_reverification"}
                self.assertEqual(queued, {"download.bytes", "independent.rule"})
                self.assertTrue(all(row["status"] == "NOT_RUN" for row in result["reverification_queue"]))

    def test_strict_json_metadata_numeric_types(self):
        for before, after in ((True, 1), (1, 1.0)):
            with self.subTest(before=repr(before), after=repr(after)):
                inventory, contract, sources = fixture()
                contract["cases"] = {"body": {"offset": before}}
                changed = copy.deepcopy(contract)
                changed["cases"]["body"]["offset"] = after
                result = tool.compare(inventory, inventory, contract, changed, sources, sources)
                self.assertTrue(result["global_review_required"])
                self.assertIn("contract_cases_or_metadata_changed", result["global_review_reasons"])
                self.assertTrue(any(row.get("behavior_id") == "download.bytes" for row in result["reverification_queue"]))

    def test_strict_json_identity_numeric_types(self):
        for identity_scope in ("inventory", "reference", "manifest"):
            for before, after in ((True, 1), (1, 1.0)):
                with self.subTest(scope=identity_scope, before=repr(before), after=repr(after)):
                    inventory, contract, sources = fixture()
                    if identity_scope == "inventory":
                        inventory["baseline"]["runtime"] = {"generation": before}
                    elif identity_scope == "reference":
                        contract["reference"]["generation"] = before
                    else:
                        sources["identity"] = {"generation": before}
                    new_inventory, new_contract, new_sources = copy.deepcopy((inventory, contract, sources))
                    if identity_scope == "inventory":
                        new_inventory["baseline"]["runtime"]["generation"] = after
                    elif identity_scope == "reference":
                        new_contract["reference"]["generation"] = after
                    else:
                        new_sources["identity"]["generation"] = after
                    result = tool.compare(inventory, new_inventory, contract, new_contract, sources, new_sources)
                    self.assertTrue(result["baseline_changed"])
                    candidate = next(row for row in result["reverification_queue"] if row.get("behavior_id") == "download.bytes")
                    self.assertIn("new_baseline_requires_fresh_evidence", candidate["reasons"])
                    self.assertFalse(result["prior_passes_inherited"])

    def test_strict_json_missing_vs_null(self):
        inventory, contract, sources = fixture()
        changed = copy.deepcopy(contract)
        changed["required_rules"][0]["expected"]["optional"] = None
        result = tool.compare(inventory, inventory, contract, changed, sources, sources)
        self.assertIn("expected", result["rule_changes"][0]["changed_fields"])
        del contract["reference"]
        changed = copy.deepcopy(contract)
        changed["reference"] = None
        self.assertTrue(tool.compare(inventory, inventory, contract, changed, sources, sources)["baseline_changed"])
        changed_source = copy.deepcopy(sources)
        changed_source["identity"] = None
        self.assertTrue(tool.compare(inventory, inventory, contract, contract, sources, changed_source)["baseline_changed"])

    def test_strict_json_entry_conditions_numeric_types(self):
        inventory, contract, sources = fixture()
        inventory["operations"][0]["conditions"] = {"live": True}
        changed = copy.deepcopy(inventory)
        changed["operations"][0]["conditions"]["live"] = 1
        result = tool.compare(inventory, changed, contract, contract, sources, sources)
        self.assertIn("conditions", result["entry_changes"][0]["changed_fields"])
        self.assertTrue(any(row.get("behavior_id") == "download.bytes" for row in result["reverification_queue"]))

    def test_condition_status_and_expected_http_status_are_not_ignored_as_results(self):
        def change(inv, con, src):
            inv["operations"][0]["conditions"]["status"] = "disabled"
            con["required_rules"][0]["expected"]["status"] = 403
        result = self.plan(change)
        self.assertIn("conditions", result["entry_changes"][0]["changed_fields"])
        self.assertIn("expected", result["rule_changes"][0]["changed_fields"])

    def test_payload_coordinate_named_fields_remain_semantic_inputs(self):
        for key in ("line", "column", "offset", "registration_id"):
            with self.subTest(key=key):
                inventory, contract, source = fixture()
                contract["required_rules"][0]["expected"] = {key: 0}
                changed = copy.deepcopy(contract)
                changed["required_rules"][0]["expected"][key] = 1
                result = tool.compare(inventory, inventory, contract, changed, source, source)
                self.assertEqual(result["rule_changes"][0]["change"], "review_required")
                self.assertIn("expected", result["rule_changes"][0]["changed_fields"])
                self.assertFalse(result["rule_changes"][0]["source_location_changed"])
                contract["required_rules"][0]["expected"] = {"source": {key: 0}}
                changed = copy.deepcopy(contract)
                changed["required_rules"][0]["expected"]["source"][key] = 1
                nested = tool.compare(inventory, inventory, contract, changed, source, source)
                self.assertIn("expected", nested["rule_changes"][0]["changed_fields"])
        def add_line(inv, con, src):
            con["required_rules"][0]["expected"]["line"] = "required response field"
        self.assertIn("expected", self.plan(add_line)["rule_changes"][0]["changed_fields"])

    def test_removed_rules_do_not_specify_current_entries(self):
        result = self.plan(lambda inv, con, src: con.update(required_rules=[]))
        self.assertTrue(any(row.get("disposition") == "UNSPECIFIED" for row in result["reverification_queue"]))
        self.assertTrue(any(row.get("disposition") == "removal_adjudication" for row in result["reverification_queue"]))

    def test_partial_manifests_do_not_hide_inventory_handler_hash_delta(self):
        inventory, contract, old_sources = fixture()
        new = copy.deepcopy(inventory)
        new["baseline"]["source_files"][0]["sha256"] = "c" * 64
        old_sources["files"] = old_sources["files"][1:]
        result = tool.compare(inventory, new, contract, contract, old_sources, old_sources)
        self.assertTrue(result["global_review_required"])
        self.assertEqual(result["entry_changes"][0]["changed_source_files"], [A])
        self.assertIn(A, result["coverage"]["missing_source_files"]["new"])

    def test_declared_dependency_is_queued_when_its_rule_changes(self):
        inventory, contract, sources = fixture()
        dependent = copy.deepcopy(contract["required_rules"][0])
        dependent.update(behavior_id="dependent", dependencies=["download.bytes"])
        contract["required_rules"].append(dependent)
        changed = copy.deepcopy(contract)
        changed["required_rules"][0]["expected"]["status"] = 201
        result = tool.compare(inventory, inventory, contract, changed, sources, sources)
        identities = {row.get("behavior_id") for row in result["reverification_queue"]}
        self.assertTrue({"download.bytes", "dependent"}.issubset(identities))

    def test_excluded_source_scope_cannot_claim_sufficient_coverage(self):
        old, contract, source = fixture()
        source["scope"]["exclusions"] = ["services/"]
        result = tool.compare(old, old, contract, contract, source, source)
        self.assertTrue(result["global_review_required"])

    def test_duplicate_and_malformed_inputs_fail_closed(self):
        inventory, contract, source = fixture()
        duplicate = copy.deepcopy(inventory)
        duplicate["operations"].append(duplicate["operations"][0])
        with self.assertRaises(tool.InputError):
            tool.compare(duplicate, inventory, contract, contract)
        duplicate = copy.deepcopy(contract)
        duplicate["required_rules"].append(duplicate["required_rules"][0])
        with self.assertRaises(tool.InputError):
            tool.compare(inventory, inventory, contract, duplicate)
        broken = copy.deepcopy(inventory)
        del broken["operations"][0]["operation_id"]
        with self.assertRaises(tool.InputError):
            tool.compare(inventory, broken, contract, contract)
        source["files"][0]["file"] = "../escape"
        with self.assertRaises(tool.InputError):
            tool.compare(inventory, inventory, contract, contract, source, source)

    def test_manifest_cannot_write_source_tree_and_exposes_symlink_omissions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"
            root.mkdir()
            (root / "auth.ts").write_text("authorization")
            outside = Path(directory) / "outside.ts"
            outside.write_text("outside")
            (root / "escape.ts").symlink_to(outside)
            (root / "node_modules").mkdir()
            (root / "node_modules" / "generated.js").write_text("generated")
            output = root / "auth.ts"
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(tool.main(["manifest", "--source-root", str(root), "--include", ".", "--out", str(output)]), 2)
            self.assertEqual(output.read_text(), "authorization")
            result = tool.manifest(root, ["."])
            self.assertFalse(result["scope"]["coverage_complete"])
            self.assertEqual([row["file"] for row in result["files"]], ["auth.ts"])
            self.assertEqual({row["file"] for row in result["coverage_issues"]}, {"escape.ts", "node_modules"})

    def test_cli_does_not_overwrite_inputs_or_accept_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inventory, contract, _ = fixture()
            inv, con = root / "inventory.json", root / "contract.json"
            inv.write_text(json.dumps(inventory))
            con.write_text(json.dumps(contract))
            args = ["compare", "--old-inventory", str(inv), "--new-inventory", str(inv), "--old-contract", str(con), "--new-contract", str(con)]
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(tool.main(args + ["--out", str(inv)]), 2)
            inv.write_text('{"schema_version":1,"schema_version":1}')
            with self.assertRaises(tool.InputError):
                tool.load(inv)


if __name__ == "__main__":
    unittest.main()
