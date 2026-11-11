import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Phase 5.3 split: the former catch-all notifications slice now lives in four
/// route collections that mirror upstream `routes/*.ts`. Each collection must
/// own exactly its share of the 96 `method path` pairs the pre-split
/// `NotificationsFeature` registered, with no pair registered twice.
///
/// The tables are `[String]` inventories so the shared test target never depends
/// on tuple literals or RoutingKit path rendering.
@Test func notificationsFeatureRegistersEveryRemainingFamilyRoute() async throws {
    let services = FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {}
    )

    let agents = try await registeredRoutes(AgentsFeature(services: services))
    let computers = try await registeredRoutes(ComputersFeature(services: services))
    let reminders = try await registeredRoutes(RemindersFeature(services: services))
    let notifications = try await registeredRoutes(NotificationsFeature(services: services))

    // Every collection owns exactly its documented family size.
    #expect(agents.count == 53)
    #expect(computers.count == 3)
    #expect(reminders.count == 1)
    #expect(notifications.count == 44)
    #expect(agents == Set(expectedAgentsRoutes))
    #expect(computers == Set(expectedComputersRoutes))
    #expect(reminders == Set(expectedRemindersRoutes))
    #expect(notifications == Set(expectedNotificationsRoutes))

    // The four inventories are complete, duplicate-free and disjoint.
    let expectedAll =
        expectedAgentsRoutes
        + expectedComputersRoutes
        + expectedRemindersRoutes
        + expectedNotificationsRoutes
    #expect(expectedAgentsRoutes.count == 53)
    #expect(expectedComputersRoutes.count == 3)
    #expect(expectedRemindersRoutes.count == 1)
    #expect(expectedNotificationsRoutes.count == 44)
    #expect(expectedAll.count == 101)
    #expect(Set(expectedAll).count == 101)

    #expect(agents.isDisjoint(with: computers))
    #expect(agents.isDisjoint(with: reminders))
    #expect(agents.isDisjoint(with: notifications))
    #expect(computers.isDisjoint(with: reminders))
    #expect(computers.isDisjoint(with: notifications))
    #expect(reminders.isDisjoint(with: notifications))

    let union = agents.union(computers).union(reminders).union(notifications)
    #expect(union.count == 101)
    #expect(union == Set(expectedAll))

    // Mounted together on one router the four collections stay at 101 routes,
    // which is what `FallbackApplication.configure` composes.
    try await withApp { app in
        try await app.register(collection: AgentsFeature(services: services))
        try await app.register(collection: ComputersFeature(services: services))
        try await app.register(collection: RemindersFeature(services: services))
        try await app.register(collection: NotificationsFeature(services: services))

        #expect(app.routes.all.count == 101)
        #expect(registeredRouteKeys(app.routes.all) == union)
    }
}

/// Register one collection on a throwaway application and return its
/// `"METHOD path"` inventory.
private func registeredRoutes(_ feature: any RouteCollection) async throws -> Set<String> {
    try await withApp { app in
        try await app.register(collection: feature)
        return registeredRouteKeys(app.routes.all)
    }
}

private func registeredRouteKeys(_ routes: [Route]) -> Set<String> {
    Set(routes.map { route in
        "\(route.method.rawValue) " + route.path.map { "\($0)" }.joined(separator: "/")
    })
}

/// Every `api/agent*` pair `AgentsFeature` owns (upstream `routes/agents.ts`).
private let expectedAgentsRoutes: [String] = [
    "DELETE api/agents/:id",
    "DELETE api/agents/:id/assistant-owner",
    "DELETE api/agents/:id/connections/:provider",
    "DELETE api/agents/:id/connections/:provider/connectors/:connectorId",
    "DELETE api/agents/:id/credentials/:credentialId",
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
    "PUT api/agents/:id/assistant-owner",
    "PUT api/agents/:id/connections/:provider",
    "PUT api/agents/:id/hosted-runtime/model",
    "PUT api/agents/:id/scopes",
]

/// Every `api/computer*` pair `ComputersFeature` owns (upstream
/// `routes/computers.ts`).
private let expectedComputersRoutes: [String] = [
    "GET api/computer/legacy-machines",
    "POST api/computer/adopt-legacy",
    "POST api/computer/attach",
]

/// Every `api/reminders*` pair `RemindersFeature` owns (upstream
/// `routes/reminders.ts`).
private let expectedRemindersRoutes: [String] = [
    "GET api/reminders",
]

/// Every pair `NotificationsFeature` still owns after the split.
private let expectedNotificationsRoutes: [String] = [
    "DELETE api/notifications/credentials/current",
    "DELETE api/notifications/devices/:deviceId",
    "DELETE api/push/registrations/:installationId",
    "DELETE api/push/subscribe",
    "GET api/announcements/active",
    "GET api/announcements/images/:imageId",
    "GET api/avatars/:namespace/:filename",
    "GET api/avatars/pixel/:file",
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
    "GET api/push/vapid-key",
    "GET api/release-notes",
    "GET api/release-notes/:releaseId",
    "GET api/slack-bridge/oauth/callback",
    "GET api/slack-bridge/provisioning",
    "GET api/version",
    "GET share/:file",
    "POST api/announcements/:announcementId/dismiss",
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
    "POST api/push/prompt-events",
    "POST api/push/registrations",
    "POST api/push/subscribe",
    "POST api/push/test",
    "POST api/share-artifacts/message-selection",
    "POST api/slack-bridge/events",
    "POST api/slack-bridge/oauth/start",
    "POST api/v2/messages",
]
