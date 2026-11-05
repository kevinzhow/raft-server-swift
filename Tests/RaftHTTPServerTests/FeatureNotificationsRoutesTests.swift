import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// The notifications/leftover slice must expose every non-internal `api/*`
/// pair (plus `share/:file`) that was still registered inline by
/// `configure(_:services:)` after the earlier feature collections moved out.
/// This locks the collection's own registration contract; behavioral coverage
/// stays with the existing per-family tests once the Lead mounts it.
///
/// The table is a `[String]` inventory so the shared test target never depends
/// on tuple literals or RoutingKit path rendering.
@Test func notificationsFeatureRegistersEveryRemainingFamilyRoute() async throws {
    let services = FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {}
    )
    try await withApp { app in
        try await app.register(collection: NotificationsFeature(services: services))

        let actual = Set(app.routes.all.map { route in
            "\(route.method.rawValue) \(route.path.map { "\($0)" }.joined(separator: "/"))"
        })
        let expected = Set(expectedNotificationsRoutes)

        // The inventory itself must stay complete and duplicate-free.
        #expect(expectedNotificationsRoutes.count == 96)
        #expect(expected.count == 96)
        // One registration for every pair, and nothing outside the slice.
        #expect(app.routes.all.count == 96)
        #expect(actual == expected)
    }
}

/// Every `method path` pair this slice owns, derived from the `configure()`
/// registrations removed by this extraction.
private let expectedNotificationsRoutes: [String] = [
    "DELETE api/agents/:id",
    "DELETE api/agents/:id/assistant-owner",
    "DELETE api/agents/:id/connections/:provider",
    "DELETE api/agents/:id/connections/:provider/connectors/:connectorId",
    "DELETE api/agents/:id/credentials/:credentialId",
    "DELETE api/notifications/credentials/current",
    "DELETE api/notifications/devices/:deviceId",
    "DELETE api/push/registrations/:installationId",
    "GET api/agents",
    "GET api/agents/:id",
    "GET api/agents/:id/activity",
    "GET api/agents/:id/activity-log",
    "GET api/agents/:id/activity-summaries",
    "GET api/agents/:id/agent-dms",
    "GET api/agents/:id/archive",
    "GET api/agents/:id/channels",
    "GET api/agents/:id/connections/:provider",
    "GET api/agents/:id/credentials",
    "GET api/agents/:id/external-diagnostics",
    "GET api/agents/:id/external-status",
    "GET api/agents/:id/hosted-runtime",
    "GET api/agents/:id/hosted-runtime/model",
    "GET api/agents/:id/hosted-runtime/usage",
    "GET api/agents/:id/migration",
    "GET api/agents/:id/onboarding-identity-adoption",
    "GET api/agents/:id/runtime-form",
    "GET api/agents/:id/runtime-options",
    "GET api/agents/:id/scopes",
    "GET api/agents/:id/skills",
    "GET api/agents/:id/workspace-files",
    "GET api/agents/:id/workspace-files/read",
    "GET api/agents/archived",
    "GET api/agents/manageable",
    "GET api/announcements/active",
    "GET api/announcements/images/:imageId",
    "GET api/avatars/pixel/:file",
    "GET api/computer/legacy-machines",
    "GET api/desktop-download",
    "GET api/desktop-download/platforms",
    "GET api/email/mobile-app/unsubscribe",
    "GET api/external-avatars/:file",
    "GET api/mobile-download",
    "GET api/notifications/devices",
    "GET api/notifications/stream",
    "GET api/product-events/config",
    "GET api/public/feature-flags",
    "GET api/push/delivery-status",
    "GET api/release-notes",
    "GET api/release-notes/:releaseId",
    "GET api/reminders",
    "GET api/slack-bridge/oauth/callback",
    "GET api/slack-bridge/provisioning",
    "GET api/version",
    "GET share/:file",
    "PATCH api/agents/:id",
    "PATCH api/agents/:id/creator",
    "POST api/agent/login",
    "POST api/agents",
    "POST api/agents/:id/archive/workspace",
    "POST api/agents/:id/assign-machine",
    "POST api/agents/:id/avatar",
    "POST api/agents/:id/bootstrap-tokens",
    "POST api/agents/:id/connections/:provider",
    "POST api/agents/:id/connections/:provider/confirm",
    "POST api/agents/:id/credentials",
    "POST api/agents/:id/hosted-runtime/retry",
    "POST api/agents/:id/migrate",
    "POST api/agents/:id/migration/cancel",
    "POST api/agents/:id/migration/confirm-hosted",
    "POST api/agents/:id/onboarding-identity-adoption",
    "POST api/agents/:id/reset",
    "POST api/agents/:id/start",
    "POST api/agents/:id/stop",
    "POST api/announcements/:announcementId/dismiss",
    "POST api/computer/adopt-legacy",
    "POST api/computer/attach",
    "POST api/email/mobile-app/unsubscribe",
    "POST api/feature-flags/evaluate",
    "POST api/notifications/credentials/rotate",
    "POST api/notifications/enrollment-exchanges",
    "POST api/notifications/enrollment-grants",
    "POST api/product-events/batch",
    "POST api/product-events/onboarding-wizard",
    "POST api/public-visits/:slug",
    "POST api/public/servers/:slug/join-as-guest",
    "POST api/push/family-revoke",
    "POST api/push/registrations",
    "POST api/push/subscribe",
    "POST api/share-artifacts/message-selection",
    "POST api/slack-bridge/events",
    "POST api/slack-bridge/oauth/start",
    "POST api/v2/messages",
    "PUT api/agents/:id/assistant-owner",
    "PUT api/agents/:id/connections/:provider",
    "PUT api/agents/:id/hosted-runtime/model",
    "PUT api/agents/:id/scopes",
]
