import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func replyingToAThreadFollowsIt() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111467"
    let serverId = "33333333-3333-4333-8333-333333333576"
    accounts.addAccount(id: ownerId, email: "thread-follow@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-follow", name: "Thread Follow", ownerId: ownerId)
    let parent = UUID().uuidString.lowercased()
    let thread = UUID().uuidString.lowercased()
    let parentMessageId = UUID().uuidString.lowercased()
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: ownerId, name: "thread-follow-parent")
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: parent, parentMessageId: parentMessageId, name: "thread")

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
                request.body = .init(string: "{\"email\":\"thread-follow@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let reply = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(thread)\",\"content\":\"thread reply\"}")
            }
            #expect(reply.status == .ok)

            let followed = try await client.send(.get, headers: headers, to: "/api/channels/threads/followed")
            #expect(followed.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((followed.body.string ?? "").utf8)) as? [String: Any]
            let threads = body?["threads"] as? [[String: Any]] ?? []
            #expect(threads.contains { $0["threadChannelId"] as? String == thread })
        }
    }
}
