import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import route_inventory as ri


class NormalizePathTests(unittest.TestCase):
    def test_parameter_names_collapse(self):
        self.assertEqual(
            ri.normalize_path("/api/channels/:channelId/members/:memberId"),
            "/api/channels/:param/members/:param",
        )
        self.assertEqual(
            ri.normalize_path("/api/attachments/upload-sessions/{uploadId}/complete"),
            "/api/attachments/upload-sessions/:param/complete",
        )

    def test_extension_parameter_collapses_to_the_same_handler(self):
        self.assertEqual(ri.normalize_path("/share/:id.png"), "/share/:param")
        self.assertEqual(ri.normalize_path("/share/:id"), "/share/:param")

    def test_trailing_slash_is_ignored(self):
        self.assertEqual(ri.normalize_path("/api/channels/"), "/api/channels")
        self.assertEqual(ri.normalize_path("/"), "/")


class ParamAbsorbTests(unittest.TestCase):
    def test_literal_covers_parameter_slot(self):
        self.assertTrue(ri.param_absorb(
            "/api/channels/:param/members/:param/:param/role",
            "/api/channels/:param/members/user/:param/role",
        ))

    def test_different_segment_counts_do_not_match(self):
        self.assertFalse(ri.param_absorb("/api/channels/:param", "/api/channels/:param/members"))


class DiffTests(unittest.TestCase):
    def test_exact_match_and_missing(self):
        upstream = [
            ri.UpstreamRoute("GET", "/api/channels/joint-invites", "channels.ts"),
            ri.UpstreamRoute("DELETE", "/api/channels/saved/:messageId", "channels.ts"),
        ]
        swift = [
            ri.SwiftRoute("GET", "/api/channels/:channelId"),
            ri.SwiftRoute("DELETE", "/api/channels/saved/:messageId"),
        ]
        diff = ri.diff_routes(ri.Inventory(upstream, swift))
        self.assertEqual([route.path for route, _ in diff.matched], ["/api/channels/saved/:messageId"])
        self.assertEqual([route.path for route in diff.missing], ["/api/channels/joint-invites"])
        self.assertEqual([route.path for route in diff.extra], ["/api/channels/:channelId"])

    def test_generic_parameter_does_not_absorb_a_literal_endpoint(self):
        upstream = [
            ri.UpstreamRoute("GET", "/api/channels/:id", "channels.ts"),
            ri.UpstreamRoute("GET", "/api/channels/joint-invites", "channels.ts"),
        ]
        swift = [ri.SwiftRoute("GET", "/api/channels/:channelId")]
        diff = ri.diff_routes(ri.Inventory(upstream, swift))
        self.assertEqual(len(diff.matched), 1)
        self.assertEqual([route.path for route in diff.missing], ["/api/channels/joint-invites"])


class MachineInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.src = self.root / "packages/server/src"
        (self.src / "routes").mkdir(parents=True)

    def source(self, name, text):
        file = self.src / name
        file.write_text(text, encoding="utf-8")
        return file

    def inventory(self):
        parser = ri.UpstreamParser(self.root)
        routes = parser.parse_app()
        return ri.machine_inventory(parser, routes)

    def test_raw_constraints_survive_normalized_match(self):
        self.source("app.ts", 'app.get("/share/:id([0-9]+).png", handler);\n')
        parser = ri.UpstreamParser(self.root)
        routes = parser.parse_app()
        result = ri.machine_inventory(parser, routes, [ri.SwiftRoute("GET", "/share/:x")])
        operation = result["operations"][0]
        self.assertEqual(operation["operation_id"], "HTTP GET /share/:id([0-9]+).png")
        self.assertEqual(operation["path"], "/share/:id([0-9]+).png")
        self.assertEqual(operation["raw_path_expression"], '"/share/:id([0-9]+).png"')
        self.assertEqual(operation["constraints"]["parameters"], [{"name": "id", "raw_tail": "([0-9]+).png"}])
        self.assertEqual(operation["normalized_match"]["status"], "normalized_shape_match")
        self.assertFalse(operation["normalized_match"]["behavior_verified"])
        self.assertFalse(result["scope"]["complete"])
        self.assertEqual(operation["conditions"]["status"], "unknown")

    def test_head_and_options_are_kept(self):
        self.source("app.ts", 'app.head("/files/:id", head);\napp.options("/files/:id", cors);\n')
        result = self.inventory()
        self.assertEqual([item["method"] for item in result["operations"]], ["HEAD", "OPTIONS"])
        self.assertEqual([item["raw_method"] for item in result["registrations"]], ["head", "options"])

    def test_unknown_paths_computed_methods_and_chains_are_visible(self):
        self.source("app.ts", '''app.get(buildPath(config), handler);
app[method]("/computed", handler);
app.route("/chain").get(handler);
app.get(`/dynamic/${kind}`, handler);
app.get("/known", handler);
''')
        result = self.inventory()
        self.assertEqual([item["path"] for item in result["operations"]], ["/known"])
        unknown = result["unresolved_registrations"]
        self.assertEqual(len(unknown), 4)
        self.assertEqual({item["source"]["line"] for item in unknown}, {1, 2, 3, 4})
        self.assertTrue(all(item["reason"] for item in unknown))
        self.assertEqual(unknown[0]["raw_path_expression"], "buildPath(config)")

    def test_comments_do_not_shift_lines_or_create_registration_candidates(self):
        self.source("app.ts", '''/*\n app.get("/phantom", fake);\n*/
const example = 'app.get("/not-code", fake)';
// app.get("/also-phantom", fake);
app.get("/actual", handler);
''')
        result = self.inventory()
        self.assertEqual(len(result["registrations"]), 1)
        self.assertEqual([item["path"] for item in result["operations"]], ["/actual"])
        self.assertEqual(result["registrations"][0]["source"]["line"], 6)
        actual = next(item for item in result["operations"] if item["path"] == "/actual")
        self.assertEqual(actual["source"]["line"], 6)

    def test_quote_characters_inside_regex_do_not_hide_later_routes(self):
        self.source("app.ts", r'''const quotePattern = /["\\]/g;
// A quote-matching regex must not turn later code into a string.
app.get("/after-regex", handler);
''')
        result = self.inventory()
        self.assertEqual([item["path"] for item in result["operations"]], ["/after-regex"])
        self.assertEqual([item["registration_path"] for item in result["registrations"]], ["/after-regex"])
        self.assertEqual(result["operations"][0]["source"]["line"], 3)

    def test_mounts_keep_handler_location_and_mount_conditions_unknown(self):
        self.source("app.ts", '''import { files } from "./routes/files";
if (enabled) {
  app.use("/api/files", files);
}
''')
        self.source("routes/files.ts", '''export const files = Router();
/* route comment\n   continues */
files.get("/:id([a-f0-9]+).bin", handler);
''')
        result = self.inventory()
        operation = result["operations"][0]
        self.assertEqual(operation["path"], "/api/files/:id([a-f0-9]+).bin")
        self.assertEqual(operation["registration_path"], "/:id([a-f0-9]+).bin")
        self.assertEqual(operation["source"], {"file": "packages/server/src/routes/files.ts", "line": 4})
        self.assertEqual(operation["mounts"][0]["line"], 3)
        self.assertIn("unknown", operation["mounts"][0]["conditions"])
        self.assertEqual(len(result["unresolved_registrations"]), 1)  # mount remains reviewable

    def test_unmounted_router_and_middleware_are_not_omitted(self):
        self.source("app.ts", 'app.use(authentication);\napp.get("/ok", handler);\n')
        self.source("routes/not-mounted.ts", 'const detached = Router();\ndetached.get("/orphan", handler);\n')
        result = self.inventory()
        self.assertEqual(len(result["unresolved_registrations"]), 2)
        self.assertEqual({item["entry_kind"] for item in result["unresolved_registrations"]}, {"route", "mount_or_middleware"})
        self.assertEqual(len(result["baseline"]["source_files"]), 2)
        self.assertTrue(all(len(item["sha256"]) == 64 for item in result["baseline"]["source_files"]))

    def test_malformed_registration_retains_source_and_failure(self):
        self.source("app.ts", 'app.get("/ok", handler);\n')
        self.source("routes/broken.ts", 'const router = Router();\nrouter.get("/broken",\n')
        result = self.inventory()
        unknown = result["unresolved_registrations"][0]
        self.assertEqual(unknown["source"]["line"], 2)
        self.assertEqual(unknown["reason"], "unterminated call")

    def test_json_lists_independent_listener_and_middleware_unknowns(self):
        self.source("app.ts", 'app.get("/ok", handler);\n')
        result = self.inventory()
        self.assertEqual(result["swift_routes"], None)
        self.assertEqual(result["operations"][0]["normalized_match"]["status"], "NOT_RUN")
        self.assertEqual({item["listener"] for item in result["review_items"]}, {
            "upstream_express_app", "swift_vapor_middleware", "daemon_connect", "socket_io", "all_http_listeners"})
        self.assertTrue(all(item["status"] == "NOT_RUN" for item in result["review_items"]))

    def test_only_unknown_registrations_still_produce_json(self):
        self.source("app.ts", 'app.get(dynamicPath(), handler);\n')
        output = self.root / "unknown.json"
        self.assertEqual(ri.main(["--upstream-root", str(self.root), "--upstream-only", "--json-out", str(output)]), 0)
        result = json.loads(output.read_text())
        self.assertEqual(result["counts"]["static_operation_candidates"], 0)
        self.assertEqual(result["counts"]["unresolved_registrations"], 1)

    def test_failed_top_level_parse_is_explicit_in_json(self):
        self.source("app.ts", 'app.get("/broken",\n')
        output = self.root / "broken.json"
        self.assertEqual(ri.main(["--upstream-root", str(self.root), "--upstream-only", "--json-out", str(output)]), 0)
        result = json.loads(output.read_text())
        self.assertEqual(result["extraction_errors"], ["unterminated call"])
        unresolved = result["unresolved_registrations"][0]
        self.assertEqual(unresolved["registration_path"], "/broken")
        self.assertFalse(unresolved["raw_call_complete"])
        self.assertEqual(unresolved["source"]["line"], 1)

    def test_json_output_preserves_markdown_mode_without_build(self):
        self.source("app.ts", 'app.get("/ok", handler);\n')
        output, markdown, swift_dump = (self.root / name for name in ("entries.json", "routes.md", "swift.tsv"))
        swift_dump.write_text("GET\t/ok\n")
        args = ["--upstream-root", str(self.root), "--swift-dump", str(swift_dump),
                "--json-out", str(output), "--write", str(markdown), "--no-usage"]
        with patch.object(ri, "run_swift_dump", side_effect=AssertionError("must not build")):
            self.assertEqual(ri.main(args), 0)
            self.assertEqual(ri.main([*args, "--check"]), 0)
        self.assertIn("| Exact matches | 1 |", markdown.read_text())
        self.assertEqual(json.loads(output.read_text())["operations"][0]["normalized_match"]["status"], "normalized_shape_match")

    def test_upstream_only_cli_never_builds_swift(self):
        self.source("app.ts", 'app.get("/ok", handler);\n')
        output = self.root / "inventory.json"
        with patch.object(ri, "run_swift_dump", side_effect=AssertionError("must not build")):
            self.assertEqual(ri.main(["--upstream-root", str(self.root), "--upstream-only", "--json-out", str(output)]), 0)
        result = json.loads(output.read_text())
        self.assertEqual(result["schema_version"], 1)
        self.assertEqual(result["counts"]["static_operation_candidates"], 1)


if __name__ == "__main__":
    unittest.main()
