import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// The servers slice must expose every `api/servers...` pair that used to be
/// registered inline by `configure(_:services:)`, without the full mount. This
/// locks the collection's own registration contract; behavioral coverage stays
/// with the existing per-route server tests once the Lead mounts it.
@Suite
struct FeatureServersRoutesTests {
    @Test func serversFeatureRegistersEveryServerRouteOnABareApplication() async throws {
        let services = FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}
        )

        try await withApp { app in
            try await app.register(collection: ServersFeature(services: services))

            // Multiset of registered method/path pairs: two `DELETE
            // .../:machineId` registrations exist upstream and both must be
            // reproduced.
            var registered: [String: Int] = [:]
            for route in app.routes.all {
                registered["\(route.method.rawValue) \(route.path.string)", default: 0] += 1
            }
            var expected: [String: Int] = [:]
            let expectedPairs: [(HTTPRequest.Method, String)] = [
                (.post, "api/servers/join-community"),
                (.get, "api/servers/unread-summary"),
                (.post, "api/servers"),
                (.get, "api/servers"),
                (.get, "api/servers/order"),
                (.patch, "api/servers/order"),
                (.post, "api/servers/:id/machines/:machineId/agents/:agentId/feedback/:reportId/transcript"),
                (.post, "api/servers/:id/machines/:machineId/computer-lifecycle-operations"),
                (.get, "api/servers/:id/machines/:machineId/agents/:agentId/diagnostic/mention-delivery/:messageId"),
                (.get, "api/servers/:id/machines/:machineId/agents/:agentId/diagnostic/session-transcript"),
                (.post, "api/servers/:id/machines/:machineId/agents/:agentId/diagnostic/mention-delivery/:messageId/redrive"),
                (.post, "api/servers/:id/scope-attestation"),
                (.get, "api/servers/:id/translation-settings"),
                (.patch, "api/servers/:id/translation-settings"),
                (.get, "api/servers/:id/labs"),
                (.patch, "api/servers/:id/labs/access"),
                (.put, "api/servers/:id/labs/:labKey"),
                (.get, "api/servers/:id/agreement"),
                (.put, "api/servers/:id/agreement"),
                (.post, "api/servers/:id/avatar"),
                (.post, "api/servers/:id/join-links"),
                (.get, "api/servers/:id/join-links"),
                (.delete, "api/servers/:id/join-links/:linkId"),
                (.get, "api/servers/:id/invites"),
                (.post, "api/servers/:id/invites"),
                (.post, "api/servers/:id/setup-reset"),
                (.post, "api/servers/:id/setup-handoff"),
                (.delete, "api/servers/:id/invites/:inviteId"),
                (.post, "api/servers/:id/leave"),
                (.get, "api/servers/:id/setup-projection"),
                (.post, "api/servers/:id/setup-transition"),
                (.patch, "api/servers/:id/members/:memberId"),
                (.delete, "api/servers/:id/members/:memberId"),
                (.delete, "api/servers/:id"),
                (.patch, "api/servers/:id/sidebar-order"),
                (.get, "api/servers/:id/sidebar-order"),
                (.get, "api/servers/:id/model-label-catalog"),
                (.get, "api/servers/:id/product-analytics-settings"),
                (.patch, "api/servers/:id/product-analytics-settings"),
                (.get, "api/servers/:id/settings"),
                (.get, "api/servers/:id/notification-settings"),
                (.patch, "api/servers/:id/notification-settings"),
                (.get, "api/servers/:id/onboarding-settings"),
                (.patch, "api/servers/:id/onboarding-settings"),
                (.post, "api/servers/:id/machines/:machineId/computer/:action"),
                (.delete, "api/servers/:id/machines/:machineId"),
                (.get, "api/servers/:id/usage"),
                (.get, "api/servers/:id/machines/:machineId/workspaces"),
                (.post, "api/servers/:id/machines/:machineId/runtimes/rescan"),
                (.get, "api/servers/:id/machines/:machineId/runtime-options"),
                (.get, "api/servers/:id/machines/:machineId/runtime-models/:runtime"),
                (.get, "api/servers/:id/machines/:machineId/runtime-form-definitions/:runtimeId"),
                (.get, "api/servers/:id/machines/:machineId/runtime-forms/v2/:runtimeId"),
                (.get, "api/servers/:id/machines/:machineId/runtime-form-definitions/:runtimeId/option-sources/:sourceId"),
                (.get, "api/servers/:id/machines/:machineId/runtime-forms/v2/:runtimeId/option-sources/:sourceId"),
                (.get, "api/servers/:id/machines/:machineId/runtime-account-usage/:provider"),
                (.post, "api/servers/:id/machines/:machineId/runtime-account-usage/:provider/refresh"),
                (.delete, "api/servers/:id/machines/:machineId/workspaces/:directoryName"),
                (.get, "api/servers/:id/system-notifications"),
                (.get, "api/servers/:id/system-notifications-v2"),
                (.post, "api/servers/:id/system-notifications-v2/:incidentId/seen"),
                (.post, "api/servers/:id/system-notifications-v2/:incidentId/dismiss"),
                (.post, "api/servers/:id/machines"),
                (.get, "api/servers/:id/machines"),
                (.post, "api/servers/:id/machines/:machineId/rotate-key"),
                (.delete, "api/servers/:id/machines/:machineId"),
                (.patch, "api/servers/:id/machines/:machineId"),
                (.patch, "api/servers/:id"),
                (.get, "api/servers/:id"),
                (.get, "api/servers/:id/members/:memberId/profile"),
                (.get, "api/servers/:id/apps"),
                (.get, "api/servers/:id/member-graph"),
                (.get, "api/servers/:id/members"),
                (.get, "api/servers/:id/public-visibility"),
                (.patch, "api/servers/:id/public-guest-join"),
                (.patch, "api/servers/:id/public-visibility"),
                (.patch, "api/servers/:id/public-search"),
            ]
            for (method, path) in expectedPairs {
                expected["\(method.rawValue) \(path)", default: 0] += 1
            }

            #expect(expectedPairs.count == 77)
            #expect(app.routes.all.count == expectedPairs.count)
            #expect(registered == expected)
        }
    }
}
