import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Complete `method path` table owned by `InternalAdminFeature`: the 48 static
/// `app.<verb>("internal", "agent" | "computer" | "machine", ...)` registrations
/// that used to be inline in `FallbackApplication.configure` (28 agent, 19
/// computer, 1 machine). The two five-method policy catch-alls
/// (`app.on(method, "internal", "computer", "**")` and the
/// `internal/agent/**` line of the shared loop with `internal/agent-api/**`)
/// intentionally stay in `configure` and are therefore absent here.
private let expectedInternalAdminRoutes: [String] = [
    "GET /internal/agent/:agentId/reminders",
    "POST /internal/agent/:agentId/reminders",
    "DELETE /internal/agent/:agentId/reminders/:reminderId",
    "POST /internal/agent/:agentId/reminders/:reminderId/snooze",
    "PATCH /internal/agent/:agentId/reminders/:reminderId",
    "GET /internal/agent/:agentId/reminders/:reminderId/log",
    "POST /internal/agent/:agentId/send",
    "POST /internal/agent/:agentId/runtime-profile/migration-done",
    "GET /internal/agent/:agentId/server",
    "PATCH /internal/agent/:agentId/server",
    "POST /internal/agent/:agentId/channels",
    "PATCH /internal/agent/:agentId/channels/:channelId",
    "POST /internal/agent/:agentId/channels/:channelId/members",
    "DELETE /internal/agent/:agentId/channels/:channelId/members",
    "POST /internal/agent/:agentId/channels/:channelId/join",
    "POST /internal/agent/:agentId/channels/:channelId/leave",
    "GET /internal/agent/:agentId/channel-members",
    "GET /internal/agent/:agentId/history",
    "POST /internal/agent/:agentId/tasks",
    "POST /internal/agent/:agentId/tasks/claim",
    "POST /internal/agent/:agentId/tasks/update-status",
    "POST /internal/agent/:agentId/tasks/delete",
    "POST /internal/agent/:agentId/tasks/convert",
    "POST /internal/agent/:agentId/messages/:messageId/reactions",
    "DELETE /internal/agent/:agentId/messages/:messageId/reactions",
    "POST /internal/agent/:agentId/threads/unfollow",
    "GET /internal/agent/:agentId/search",
    "POST /internal/agent/:agentId/upload",
    "POST /internal/computer/preflight",
    "POST /internal/computer/attachment/revoke",
    "POST /internal/computer/runners/:agentId/credentials",
    "DELETE /internal/computer/runners/:agentId/credentials/:credentialId",
    "POST /internal/computer/runners/:agentId/stop",
    "GET /internal/computer/runners",
    "POST /internal/computer/agent-migrations/by-id/:migrationId/resumable/control",
    "GET /internal/computer/agent-migrations/by-id/:migrationId/resumable/control",
    "POST /internal/computer/agent-migrations/by-id/:migrationId/resumable/chunks/:chunkIndex/receipt",
    "GET /internal/computer/agent-migrations/by-id/:migrationId/resumable/chunks",
    "POST /internal/computer/agent-migrations/by-id/:migrationId/resumable/upload-complete",
    "GET /internal/computer/agent-migrations/by-id/:migrationId",
    "POST /internal/computer/agent-migrations/by-id/:migrationId/start-transfer",
    "POST /internal/computer/agent-migrations/by-id/:migrationId/flip-machine",
    "POST /internal/computer/agent-migrations/by-id/:migrationId/arrived",
    "POST /internal/computer/agent-migrations/by-id/:migrationId/transport-lost",
    "POST /internal/computer/agent-migrations/by-id/:migrationId/cancel-ack",
    "POST /internal/computer/agent-migrations/by-id/:migrationId/resumable/source-quiesced",
    "POST /internal/computer/agent-migrations/by-id/:migrationId/resumable/source-progress",
    "POST /internal/machine/scope-attestation",
]

private func internalAdminRouteKey(_ route: Route) -> String {
    let path = route.path.map { "\($0)" }.joined(separator: "/")
    return "\(route.method.rawValue) /\(path)"
}

@Test func internalAdminFeatureRegistersEveryStaticRoute() async throws {
    let services = FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        emailAccounts: EmailLoginDirectory()
    )

    try await withApp { app in
        try await InternalAdminFeature(services: services).boot(routes: app)

        let routes = app.routes.all.map(internalAdminRouteKey).sorted()
        let expected = expectedInternalAdminRoutes.sorted()

        // The table is authoritative: reject an accidental duplicate or gap in
        // the table itself before comparing it to the router.
        #expect(expectedInternalAdminRoutes.count == 48)
        #expect(expectedInternalAdminRoutes.filter { $0.hasSuffix("/internal/agent") || $0.contains(" /internal/agent/") }.count == 28)
        #expect(expectedInternalAdminRoutes.filter { $0.contains(" /internal/computer/") }.count == 19)
        #expect(expectedInternalAdminRoutes.filter { $0.contains(" /internal/machine/") }.count == 1)
        #expect(Set(expectedInternalAdminRoutes).count == 48)

        // One route per table entry, no route outside the three prefixes, and
        // no wildcard policy catch-all leaked into the collection.
        #expect(routes.count == expected.count)
        #expect(routes == expected)
        #expect(app.routes.all.allSatisfy { route in
            route.path.first?.description == "internal"
                && ["agent", "computer", "machine"].contains(route.path.dropFirst().first?.description ?? "")
        })
        #expect(app.routes.all.allSatisfy { !$0.path.map { "\($0)" }.contains("**") })
    }
}
