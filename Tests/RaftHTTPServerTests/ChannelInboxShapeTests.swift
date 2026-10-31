import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelInboxItemsCarryTheirScopeKind() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111458"
    let serverId = "33333333-3333-4333-8333-333333333569"
    accounts.addAccount(id: ownerId, email: "inbox-shape@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "inbox-shape", name: "Inbox Shape", ownerId: ownerId)
    let parent = UUID().uuidString.lowercased()
    let thread = UUID().uuidString.lowercased()
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: ownerId, name: "inbox-parent")
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: parent, parentMessageId: UUID().uuidString.lowercased(), name: "thread")
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: parent, messageId: UUID().uuidString.lowercased())
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: thread, messageId: UUID().uuidString.lowercased())

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"inbox-shape@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.get, headers: headers, to: "/api/channels/inbox")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let items = body?["items"] as? [[String: Any]] ?? []
            #expect(items.count == 2)
            #expect(items.contains { $0["kind"] as? String == "channel" && $0["channelId"] as? String == parent })
            #expect(items.contains { $0["kind"] as? String == "thread" && $0["threadChannelId"] as? String == thread })
        }
    }
}
