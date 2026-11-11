import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Complete `method path` table owned by `InternalAgentApiFeature`: the 90
/// static `app.<verb>("internal", "agent-api", ...)` registrations, including
/// the credential-surface upload-session, task history/unclaim, avatar and
/// integration-app management routes. The five-method
/// `app.on(method, "internal", "agent-api", "**")` policy catch-all is
/// intentionally absent: it is registered in a shared loop with the
/// `internal/agent/**` prefix and stays in `configure`.
private let expectedInternalAgentApiRoutes: [String] = [
    "GET /internal/agent-api",
    "POST /internal/agent-api/activity",
    "GET /internal/agent-api/apps/:appId/config",
    "PATCH /internal/agent-api/apps/:appId/config",
    "GET /internal/agent-api/assistant/owner-inbox",
    "GET /internal/agent-api/assistant/owner-messages",
    "GET /internal/agent-api/attachment-upload-capabilities",
    "POST /internal/agent-api/attachment-upload-sessions",
    "GET /internal/agent-api/attachment-upload-sessions/:uploadId",
    "DELETE /internal/agent-api/attachment-upload-sessions/:uploadId",
    "POST /internal/agent-api/attachment-upload-sessions/:uploadId/complete",
    "GET /internal/agent-api/attachments/:attachmentId",
    "GET /internal/agent-api/attachments/:attachmentId/comments",
    "POST /internal/agent-api/attachments/:attachmentId/comments",
    "GET /internal/agent-api/attachments/:attachmentId/url",
    "GET /internal/agent-api/channel-members",
    "POST /internal/agent-api/channels",
    "PATCH /internal/agent-api/channels/:channelId",
    "POST /internal/agent-api/channels/:channelId/join",
    "POST /internal/agent-api/channels/:channelId/leave",
    "DELETE /internal/agent-api/channels/:channelId/members",
    "POST /internal/agent-api/channels/:channelId/members",
    "POST /internal/agent-api/channels/:channelId/mute",
    "POST /internal/agent-api/channels/archive",
    "POST /internal/agent-api/channels/unarchive",
    "POST /internal/agent-api/channels/:channelId/unmute",
    "GET /internal/agent-api/context",
    "GET /internal/agent-api/events",
    "GET /internal/agent-api/feedback-locators",
    "POST /internal/agent-api/feedback-locators",
    "GET /internal/agent-api/history",
    "GET /internal/agent-api/inbox/conversations",
    "GET /internal/agent-api/integrations",
    "GET /internal/agent-api/integrations/app",
    "POST /internal/agent-api/integrations/app/logo",
    "POST /internal/agent-api/integrations/app/manage",
    "POST /internal/agent-api/integrations/app/prepare",
    "POST /internal/agent-api/integrations/app/rotate-secret",
    "POST /internal/agent-api/integrations/app/transfer-owner",
    "GET /internal/agent-api/integrations/app/status",
    "POST /internal/agent-api/integrations/app/update",
    "POST /internal/agent-api/integrations/login",
    "GET /internal/agent-api/integrations/marketplace",
    "POST /internal/agent-api/integrations/token",
    "POST /internal/agent-api/mcp/call",
    "GET /internal/agent-api/mcp/tools",
    "POST /internal/agent-api/mention-actions/execute",
    "GET /internal/agent-api/mention-actions/pending",
    "GET /internal/agent-api/mentions",
    "GET /internal/agent-api/messages/:messageId/mention-deliveries",
    "DELETE /internal/agent-api/messages/:messageId/reactions",
    "POST /internal/agent-api/messages/:messageId/reactions",
    "GET /internal/agent-api/messages/:messageId/resolve",
    "POST /internal/agent-api/prepare-action",
    "GET /internal/agent-api/profile",
    "POST /internal/agent-api/profile",
    "POST /internal/agent-api/profile/avatar",
    "PUT /internal/agent-api/push-webhook",
    "GET /internal/agent-api/reminders",
    "POST /internal/agent-api/reminders",
    "DELETE /internal/agent-api/reminders/:reminderId",
    "PATCH /internal/agent-api/reminders/:reminderId",
    "GET /internal/agent-api/reminders/:reminderId/log",
    "POST /internal/agent-api/reminders/:reminderId/snooze",
    "POST /internal/agent-api/resolve-channel",
    "GET /internal/agent-api/search",
    "POST /internal/agent-api/send",
    "GET /internal/agent-api/server",
    "PATCH /internal/agent-api/server",
    "POST /internal/agent-api/server/avatar",
    "GET /internal/agent-api/tasks",
    "POST /internal/agent-api/tasks",
    "POST /internal/agent-api/tasks/amend",
    "POST /internal/agent-api/tasks/assign",
    "POST /internal/agent-api/tasks/resource-receipt",
    "POST /internal/agent-api/tasks/claim",
    "POST /internal/agent-api/tasks/convert",
    "POST /internal/agent-api/tasks/delete",
    "POST /internal/agent-api/tasks/update-status",
    "GET /internal/agent-api/tasks/history",
    "POST /internal/agent-api/tasks/unclaim",
    "POST /internal/agent-api/third-party-events/delivered",
    "GET /internal/agent-api/threads",
    "POST /internal/agent-api/threads/unfollow",
    "POST /internal/agent-api/upload",
    "GET /internal/agent-api/users/:name/channels",
    "GET /internal/agent-api/users/info",
    "POST /internal/agent-api/v2/send",
    "GET /internal/agent-api/wake-hints",
    "GET /internal/agent-api/wake-hints/stream",
]

private func internalAgentApiRouteKey(_ route: Route) -> String {
    let path = route.path.map { "\($0)" }.joined(separator: "/")
    return "\(route.method.rawValue) /\(path)"
}

@Test func internalAgentApiFeatureRegistersEveryStaticRoute() async throws {
    let services = FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        emailAccounts: EmailLoginDirectory()
    )

    try await withApp { app in
        try await InternalAgentApiFeature(services: services).boot(routes: app)

        let routes = app.routes.all.map(internalAgentApiRouteKey).sorted()
        let expected = expectedInternalAgentApiRoutes.sorted()

        // The table is authoritative: reject an accidental duplicate or gap in
        // the table itself before comparing it to the router.
        #expect(expectedInternalAgentApiRoutes.count == 90)
        #expect(Set(expectedInternalAgentApiRoutes).count == 90)

        // One route per table entry, no route outside `/internal/agent-api`, and
        // no wildcard policy catch-all leaked into the collection.
        #expect(routes.count == expected.count)
        #expect(routes == expected)
        #expect(app.routes.all.allSatisfy { route in
            route.path.first?.description == "internal"
                && route.path.dropFirst().first?.description == "agent-api"
        })
        #expect(app.routes.all.allSatisfy { !$0.path.map { "\($0)" }.contains("**") })
    }
}
