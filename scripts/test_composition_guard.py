#!/usr/bin/env python3
"""Composition architecture checks through the guard's public JSON CLI.

The accepted declarations are written independently of guard constants. The
negative cases model architecture escapes, rather than reproducing its parser.
"""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("architecture", Path(__file__).with_name("check_architecture.py"))
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)

CONTAINER = """public struct ServiceContainer: Sendable {
    public let identity: IdentityServices
    public let messaging: MessagingServices
    public let channels: ChannelServices
    public let agents: AgentServices
    public let machines: MachineServices
    public let tasks: TaskServices
    public let integrations: IntegrationServices
    public let notifications: NotificationServices
    public let feedback: FeedbackServices
}

extension ServiceContainer {
    public init() {
        self = composeServices()
    }
}
"""
# Each domain has a concrete published value. Field placement is a review
# decision; this guard checks declaration shape and approved concrete types.
GROUPS = """public struct IdentityServices: Sendable { public let core: AuthCoreService; public let issuerMetadata: OAuthIssuerMetadataService; public let authorization: OAuthAuthorizationService; public let principal: OAuthPrincipalService }
public struct MessagingServices: Sendable { public let realtime: RealtimeRelayService }
public struct ChannelServices: Sendable { public let threads: ThreadsService }
public struct AgentServices: Sendable { public let history: AgentHistoryService }
public struct MachineServices: Sendable { public let fleet: ComputersFleetService }
public struct TaskServices: Sendable { public let catalog: TaskCatalogService }
public struct IntegrationServices: Sendable { public let apps: IntegrationsAndAppAccessService }
public struct NotificationServices: Sendable { public let email: MobileAppEmailUnsubscribe }
public struct FeedbackServices: Sendable { public let tickets: FeedbackMultiAppService }
"""
COMPOSITION = "Sources/RaftHTTP/Composition/"


class CompositionGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.put("Sources/RaftHTTP/EmailLogin.swift", "")
        self.put("scripts/for_testing_baseline.tsv", "")
        self.put(COMPOSITION + "ServiceContainer.swift", CONTAINER)
        self.put(COMPOSITION + "ServiceGroups.swift", GROUPS)
        self.put(COMPOSITION + "ComposeServices.swift", "func composeServices() -> ServiceContainer { fatalError() }\n")

    def put(self, path, text):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        return p

    def remove(self, path):
        target = (self.root / path).resolve()
        self.assertTrue(target.is_relative_to(self.root.resolve()))
        target.unlink()

    def cli(self):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = guard.main(["--root", str(self.root), "--json"])
        self.assertEqual(err.getvalue(), "")
        report = json.loads(out.getvalue())
        self.assertEqual(code, report["exit_code"])
        return code, report

    def fails(self, check):
        code, report = self.cli()
        self.assertEqual(code, 1)
        self.assertEqual(next(c for c in report["checks"] if c["id"] == check)["status"], "fail")
        self.assertTrue(report["violations"])

    def test_published_shape_with_checked_conformance_and_memberwise_safe_init(self):
        code, report = self.cli()
        self.assertEqual(code, 0, report["violations"])
        self.assertEqual(report["baselines"]["composition_file_line_limit"], 1000)
        self.assertEqual(report["baselines"]["container_line_limit"], 28)
        self.assertEqual(report["baselines"]["email_login_lines"], 28)

    def test_comments_and_multiline_fields_do_not_look_like_business(self):
        self.put(COMPOSITION + "ServiceContainer.swift", "/* outer /* var owner: OAuthLedger */ nested */\n" + CONTAINER.replace("identity: IdentityServices", "identity:\n        IdentityServices"))
        self.put(COMPOSITION + "ServiceGroups.swift", "// let bag: Any; extension ServiceContainer {}\n" + GROUPS)
        self.assertEqual(self.cli()[0], 0)

    def test_nested_file_gets_same_ceiling_and_no_line_budget(self):
        self.put(COMPOSITION + "Nested/Helper.swift", "// comment\n" * 1001)
        self.fails("composition-file-ceiling")

    def test_1000_lines_is_allowed_but_container_has_its_own_limit(self):
        self.put(COMPOSITION + "Helper.swift", "// comment\n" * 1000)
        self.assertEqual(self.cli()[0], 0)
        self.put(COMPOSITION + "ServiceContainer.swift", CONTAINER + "\n" * 12)
        self.fails("composition-declarations")

    def test_composition_transport_or_untyped_json_is_hard_zero(self):
        for bad in ("@preconcurrency import Vapor", "import struct Vapor.Response", "HTTPReply()", "Foundation.JSONSerialization.self", "let x: [String : Any]", "let x: Dictionary<String, Any>", "let x: AnyObject"):
            with self.subTest(bad=bad):
                self.put(COMPOSITION + "Nested/Bad.swift", bad + "\n")
                self.fails("composition-boundaries")

    def test_root_cannot_be_mutable_computed_or_hold_owner_or_function(self):
        for bad in (CONTAINER.replace("public let identity", "public var identity"), CONTAINER.replace("IdentityServices\n", "AuthProfileStore\n", 1), CONTAINER.replace("}\n\nextension", "    public let owner: OAuthLedger\n}\n\nextension", 1), CONTAINER.replace("}\n\nextension", "    public var raw: IdentityServices { identity }\n}\n\nextension", 1), CONTAINER.replace("IdentityServices\n", "() -> IdentityServices\n", 1), CONTAINER.replace(": Sendable", ": @unchecked Sendable", 1)):
            with self.subTest(source=bad):
                self.put(COMPOSITION + "ServiceContainer.swift", bad)
                self.fails("composition-declarations")

    def test_root_all_nine_roles_and_unique_declarations_are_required(self):
        for bad in (CONTAINER.replace("    public let tasks: TaskServices\n", ""), CONTAINER.replace("public let tasks: TaskServices", "public let identity: IdentityServices"), CONTAINER.replace("public let tasks: TaskServices", "public let taskAlias: TaskServices")):
            with self.subTest(source=bad):
                self.put(COMPOSITION + "ServiceContainer.swift", bad)
                self.fails("composition-declarations")

    def test_constructor_in_struct_or_hidden_extension_logic_is_rejected(self):
        for bad in (CONTAINER.replace("}\n\nextension", "    public init() { self = composeServices() }\n}\n\nextension", 1), CONTAINER.replace("self = composeServices()", "self = composeServices()\n        notify()"), CONTAINER + "extension ServiceContainer { func lookup() {} }\n", CONTAINER + "typealias OldRoot = ServiceContainer\n"):
            with self.subTest(source=bad):
                self.put(COMPOSITION + "ServiceContainer.swift", bad)
                self.fails("composition-declarations")

    def test_group_store_alias_existential_callback_and_getter_are_rejected(self):
        for bad in ("AuthProfileStore", "OAuthLedger", "EmailLoginDirectory", "ServiceContainer", "Any", "any Sendable", "() -> AuthCoreService", "[AuthCoreService]", "AuthCoreService?", "UnreviewedService"):
            with self.subTest(type=bad):
                self.put(COMPOSITION + "ServiceGroups.swift", GROUPS.replace("public let core: AuthCoreService", f"public let core: {bad}"))
                self.fails("composition-declarations")
        for extra in ("public var core: AuthCoreService", "public let core: AuthCoreService { fatalError() }", "typealias Core = AuthCoreService", "public init() {}"):
            with self.subTest(member=extra):
                self.put(COMPOSITION + "ServiceGroups.swift", GROUPS.replace("public let core: AuthCoreService", extra))
                self.fails("composition-declarations")

    def test_cross_file_extensions_cannot_add_a_locator_to_root_or_groups(self):
        for target in (COMPOSITION + "More.swift", "Sources/RaftHTTP/Services/Hidden.swift", "Sources/RaftHTTPServer/Generated/Hidden.swift"):
            for name in ("ServiceContainer", "IdentityServices"):
                with self.subTest(target=target, name=name):
                    self.put(target, f"extension /* split */ {name} {{ func locate() {{}} }}\n")
                    self.fails("composition-declarations")
                    self.put(target, "")

    def test_data_literals_and_nested_comments_cannot_invent_extensions(self):
        self.put(COMPOSITION + "Text.swift", 'let doc = ##"extension ServiceContainer { var owner: OAuthLedger }"##\n/* a /* nested */ extension IdentityServices {} */\n')
        self.assertEqual(self.cli()[0], 0)

    def test_missing_canonical_group_file_is_a_failure(self):
        self.remove(COMPOSITION + "ServiceGroups.swift")
        self.fails("composition-declarations")

    def test_selective_client_import_does_not_redeclare_the_container(self):
        self.put("Sources/RaftHTTPServer/Import.swift", "import struct RaftHTTP.ServiceContainer\nimport struct RaftHTTP.IdentityServices\n")
        self.assertEqual(self.cli()[0], 0)

    def test_qualified_aliases_or_extensions_cannot_hide_in_another_target(self):
        for source in ("extension RaftHTTP.ServiceContainer { func locate() {} }", "typealias Local = RaftHTTP.IdentityServices"):
            with self.subTest(source=source):
                self.put("Sources/RaftHTTPServer/Hidden.swift", source)
                self.fails("composition-declarations")

    def test_moving_all_composition_sources_does_not_disable_root_check(self):
        for name in ("ServiceContainer.swift", "ServiceGroups.swift", "ComposeServices.swift"):
            self.remove(COMPOSITION + name)
        self.put("Sources/RaftHTTP/Elsewhere.swift", CONTAINER)
        self.fails("composition-declarations")

    def test_untyped_operations_inside_interpolation_remain_code(self):
        self.put(COMPOSITION + "Text.swift", 'let text = "\\(Foundation.JSONSerialization.data())"\n')
        self.fails("composition-boundaries")

    def test_missing_directory_and_private_test_scene_are_supported(self):
        for name in ("ServiceContainer.swift", "ServiceGroups.swift", "ComposeServices.swift"):
            self.remove(COMPOSITION + name)
        self.put("Tests/Scene.swift", "struct ServiceContainer {}")
        self.assertEqual(self.cli()[0], 0)

    def test_escaped_protected_names_cannot_hide_extensions_or_alias_targets(self):
        for name in ("ServiceContainer", "IdentityServices"):
            for reference in (f"`{name}`", f"RaftHTTP.`{name}`", f"`RaftHTTP`.`{name}`"):
                for source in (f"extension {reference} {{ var extra: Int {{ 0 }} }}", f"typealias Local = {reference}"):
                    with self.subTest(source=source):
                        self.put("Sources/RaftHTTPServer/Hidden.swift", source)
                        self.fails("composition-declarations")
        self.put("Sources/RaftHTTPServer/Hidden.swift", "import struct RaftHTTP.`ServiceContainer`\n")
        self.assertEqual(self.cli()[0], 0)

    def test_whole_directory_cannot_be_replaced_by_a_protected_alias_name(self):
        for name in ("ServiceContainer.swift", "ServiceGroups.swift", "ComposeServices.swift"):
            self.remove(COMPOSITION + name)
        for name in ("ServiceContainer", "`ServiceContainer`", "IdentityServices", "`IdentityServices`"):
            with self.subTest(alias=name):
                self.put("Sources/RaftHTTP/Elsewhere.swift", f"public struct ReplacementRoot: Sendable {{}}\npublic typealias {name} = ReplacementRoot\n")
                self.fails("composition-declarations")

    def test_existing_services_scan_and_ratchets_remain_independent(self):
        self.put("Sources/RaftHTTP/Services/Bad.swift", "import Vapor\nHTTPReply()\n")
        code, report = self.cli()
        self.assertEqual(code, 1)
        failed = {c["id"] for c in report["checks"] if c["status"] == "fail"}
        self.assertIn("services-vapor-free", failed)
        self.assertIn("ratchet-service_httpreply", failed)
        self.assertNotIn("composition-boundaries", failed)
        self.assertEqual(report["baselines"]["email_login_lines"], 28)
        self.assertFalse(list((self.root / "scripts").glob("ratchet_*.tsv")))


if __name__ == "__main__":
    unittest.main()
