import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Every `method path` pair the channels slice owns. This is the complete list
/// of `app.get/post/patch/delete("api", "channels", ...)` registrations in
/// `FallbackApplication.configure` at extraction time (54 routes).
private let expectedChannelsRoutes: [(HTTPRequest.Method, String)] = [
    (.post, "POST /api/channels/:channelId/archive"),
    (.post, "POST /api/channels/:channelId/unarchive"),
    (.post, "POST /api/channels/:channelId/join"),
    (.post, "POST /api/channels/inbox/done"),
    (.post, "POST /api/channels/inbox/read-all"),
    (.get, "GET /api/channels/inbox/done"),
    (.post, "POST /api/channels/inbox/undone"),
    (.post, "POST /api/channels/threads/undone"),
    (.post, "POST /api/channels/threads/done"),
    (.get, "GET /api/channels/inbox/unfollowed"),
    (.get, "GET /api/channels/inbox"),
    (.delete, "DELETE /api/channels/:channelId"),
    (.delete, "DELETE /api/channels/threads/:threadId/followers/agents/:agentId"),
    (.post, "POST /api/channels/threads/:threadId/followers/agents/:agentId/restore"),
    (.get, "GET /api/channels/threads/followers"),
    (.post, "POST /api/channels/threads/follow"),
    (.post, "POST /api/channels/threads/unfollow"),
    (.get, "GET /api/channels/threads/followed"),
    (.get, "GET /api/channels/:channelId/threads/:messageId"),
    (.get, "GET /api/channels/:channelId/threads"),
    (.get, "GET /api/channels/activity/snapshot"),
    (.get, "GET /api/channels/activity/difference"),
    (.post, "POST /api/channels/saved/check"),
    (.post, "POST /api/channels/saved"),
    (.get, "GET /api/channels/saved"),
    (.post, "POST /api/channels/system/all/hide"),
    (.post, "POST /api/channels/system/all/restore"),
    (.post, "POST /api/channels/dm"),
    (.get, "GET /api/channels/dm"),
    (.get, "GET /api/channels/:channelId"),
    (.post, "POST /api/channels/:channelId/resume-all-agents"),
    (.post, "POST /api/channels/:channelId/read"),
    (.post, "POST /api/channels/:channelId/read-all"),
    (.post, "POST /api/channels/:channelId/unread"),
    (.get, "GET /api/channels/unread"),
    (.get, "GET /api/channels/:channelId/message-display-settings"),
    (.post, "POST /api/channels/:channelId/conversation-read-all"),
    (.patch, "PATCH /api/channels/:channelId/message-display-settings"),
    (.post, "POST /api/channels/:channelId/leave"),
    (.post, "POST /api/channels/:channelId/members/batch"),
    (.post, "POST /api/channels/joint-invites/:inviteId/accept"),
    (.post, "POST /api/channels/:channelId/threads"),
    (.post, "POST /api/channels/:channelId/members"),
    (.patch, "PATCH /api/channels/:channelId/members/user/:memberId/role"),
    (.delete, "DELETE /api/channels/:channelId/members/user/:memberId"),
    (.delete, "DELETE /api/channels/:channelId/members/agent/:agentId"),
    (.get, "GET /api/channels/:channelId/files"),
    (.get, "GET /api/channels/:channelId/agents"),
    (.get, "GET /api/channels/:channelId/members"),
    (.get, "GET /api/channels/:channelId/notification-settings"),
    (.patch, "PATCH /api/channels/:channelId/notification-settings"),
    (.patch, "PATCH /api/channels/:channelId"),
    (.post, "POST /api/channels"),
    (.get, "GET /api/channels"),
]

@Test func channelsFeatureRegistersEveryChannelsRoute() async throws {
    let services = FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        emailAccounts: EmailLoginDirectory()
    )
    try await withApp { app in
        try await app.register(collection: ChannelsFeature(services: services))

        let registered = Set(app.routes.all.map { route in
            "\(route.method.rawValue) /" + route.path.map { "\($0)" }.joined(separator: "/")
        })
        let expected = Set(expectedChannelsRoutes.map { $0.1 })

        // The table is authoritative: reject an accidental duplicate or gap in
        // the table itself before comparing it to the router.
        #expect(expectedChannelsRoutes.count == 54)
        #expect(expected.count == 54)

        // One route per table entry, and no route outside `/api/channels...`.
        #expect(app.routes.all.count == expected.count)
        #expect(registered == expected)
        #expect(app.routes.all.allSatisfy { route in
            route.path.first?.description == "api" && route.path.dropFirst().first?.description == "channels"
        })
    }
}
