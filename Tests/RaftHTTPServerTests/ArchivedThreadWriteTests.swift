import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadRepliesAreFrozenWhileTheParentChannelIsArchived() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111405"
    let serverId = "33333333-3333-4333-8333-333333333537"
    accounts.addAccount(id: ownerId, email: "archived-thread@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "archived-thread", name: "Archived Thread", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"archived-thread@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let parent = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"archived-thread-parent\"}")
            }
            let parentId = (try JSONSerialization.jsonObject(with: Data((parent.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let threadId = UUID().uuidString.lowercased()
            accounts.addPostableChannel(
                serverId: serverId,
                channelId: threadId,
                memberId: ownerId,
                kind: "thread",
                parentChannelId: parentId,
                name: "archived-thread-child"
            )

            func reply() async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(threadId)\",\"content\":\"thread reply\"}")
                }
            }
            let firstReply = try await reply()
            #expect(firstReply.status == .ok)

            #expect(try await client.send(.post, headers: headers, to: "/api/channels/\(parentId)/archive").status == .ok)
            let frozen = try await reply()
            #expect(frozen.status == .conflict)
            #expect((try JSONSerialization.jsonObject(with: Data((frozen.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "channel_archived")

            #expect(try await client.send(.post, headers: headers, to: "/api/channels/\(parentId)/unarchive").status == .ok)
            #expect(try await reply().status == .ok)
        }
    }
}
