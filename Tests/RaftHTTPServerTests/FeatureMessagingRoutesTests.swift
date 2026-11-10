import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Complete `method path` table owned by `MessagingFeature`: the 15
/// `/api/messages/*`, 15 `/api/attachments/*`, 12 `/api/tasks/*`,
/// 3 `/api/actions/*` and 2 `/api/read-mutations*` registrations (47 pairs).
/// This includes the batch URL and both HTML preview leaves. `/api/v2/messages`
/// is intentionally absent: it is not one of the extracted prefixes.
private let expectedMessagingRoutes: [String] = [
    "POST /api/actions/:messageId/execute",
    "POST /api/actions/:messageId/mark-executed",
    "POST /api/actions/migration-export",
    "GET /api/attachments/:id",
    "GET /api/attachments/:id/comments",
    "POST /api/attachments/:id/comments",
    "GET /api/attachments/:id/html-preview",
    "GET /api/attachments/:id/html-preview-url",
    "GET /api/attachments/:id/url",
    "GET /api/attachments/comments/counts",
    "POST /api/attachments/upload",
    "GET /api/attachments/upload-capabilities",
    "POST /api/attachments/upload-sessions",
    "DELETE /api/attachments/upload-sessions/:uploadId",
    "GET /api/attachments/upload-sessions/:uploadId",
    "GET /api/attachments/upload-sessions/:uploadId/active",
    "POST /api/attachments/upload-sessions/:uploadId/complete",
    "POST /api/attachments/urls",
    "POST /api/messages",
    "GET /api/messages/:messageId/mention-deliveries",
    "DELETE /api/messages/:messageId/reactions",
    "POST /api/messages/:messageId/reactions",
    "GET /api/messages/:messageId/reactions/actors",
    "GET /api/messages/:messageId/reactions/viewer",
    "GET /api/messages/attachment-preview/enabled",
    "GET /api/messages/channel/:channelId",
    "GET /api/messages/context/:messageId",
    "POST /api/messages/forward",
    "GET /api/messages/forward/enabled",
    "GET /api/messages/forward/targets/search",
    "POST /api/messages/mention-actions/execute",
    "GET /api/messages/search",
    "GET /api/messages/sync",
    "POST /api/read-mutations",
    "GET /api/read-mutations/frontier",
    "DELETE /api/tasks/:taskId",
    "PATCH /api/tasks/:taskId/assignee",
    "PATCH /api/tasks/:taskId/claim",
    "PATCH /api/tasks/:taskId/status",
    "PATCH /api/tasks/:taskId/unclaim",
    "GET /api/tasks/channel/:channelId",
    "POST /api/tasks/channel/:channelId",
    "GET /api/tasks/channel/:channelId/number/:taskNumber",
    "POST /api/tasks/convert-message",
    "GET /api/tasks/server",
    "GET /api/tasks/server/period-metrics",
    "GET /api/tasks/server/snapshot-metrics",
]

private func messagingRouteKey(_ route: Route) -> String {
    let path = route.path.map { "\($0)" }.joined(separator: "/")
    return "\(route.method.rawValue) /\(path)"
}

@Test func messagingFeatureRegistersEveryMessagingRoute() async throws {
    let services = FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {}
    )

    try await withApp { app in
        try await MessagingFeature(services: services).boot(routes: app)

        let routes = app.routes.all.map(messagingRouteKey).sorted()
        let expected = expectedMessagingRoutes.sorted()

        // The table is authoritative: reject an accidental duplicate or gap in
        // the table itself before comparing it to the router.
        #expect(expectedMessagingRoutes.count == 47)
        #expect(Set(expectedMessagingRoutes).count == 47)

        // One route per table entry, and no route outside the five families.
        #expect(routes.count == expected.count)
        #expect(routes == expected)
        let families = Set(app.routes.all.compactMap { route in
            route.path.dropFirst().first.map { "\($0)" }
        })
        #expect(families == ["messages", "attachments", "tasks", "actions", "read-mutations"])
        #expect(app.routes.all.allSatisfy { $0.path.first?.description == "api" })
    }
}
