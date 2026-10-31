import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func inboxFiltersByMentionAndUnread() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111465"
    let peerId = "11111111-1111-4111-8111-111111111466"
    let serverId = "33333333-3333-4333-8333-333333333575"
    accounts.addAccount(id: ownerId, email: "inbox-filter@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "inbox-filter-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "inbox-filter", name: "Inbox Filter", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let mentionScope = UUID().uuidString.lowercased()
    let unreadScope = UUID().uuidString.lowercased()
    for scope in [mentionScope, unreadScope] {
        accounts.addPostableChannel(serverId: serverId, channelId: scope, memberId: ownerId, name: "inbox-filter-room")
        accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: scope, messageId: UUID().uuidString.lowercased())
    }
    accounts.addStoredMentionForTesting(channelId: mentionScope, messageId: UUID().uuidString.lowercased(), targetId: ownerId)
    _ = accounts.oauth.createMessageRecord(channelId: unreadScope, content: "unread filter", senderId: peerId)
    accounts.oauth.setChannelReadCursor(channelId: unreadScope, userId: ownerId, seq: 0)

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
                request.body = .init(string: "{\"email\":\"inbox-filter@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func ids(_ filter: String) async throws -> [String] {
                let response = try await client.send(.get, headers: headers, to: URI(string: "/api/channels/inbox?filter=\(filter)"))
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return (body?["items"] as? [[String: Any]] ?? []).compactMap { $0["channelId"] as? String }
            }

            #expect(Set(try await ids("all")) == [mentionScope, unreadScope])
            #expect(try await ids("mentions") == [mentionScope])
            #expect(try await ids("unread") == [unreadScope])
        }
    }
}
