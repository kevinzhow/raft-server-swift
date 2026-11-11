import unittest

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


if __name__ == "__main__":
    unittest.main()
