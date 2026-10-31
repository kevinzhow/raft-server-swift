import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func markUnreadPersistsWhenTheLatestMessageIsSelfAuthored() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111439"
    let peerId = "11111111-1111-4111-8111-111111111440"
    let serverId = "33333333-3333-4333-8333-333333333558"
    accounts.addAccount(id: ownerId, email: "mark-unread-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "mark-unread-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "mark-unread", name: "Mark Unread", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "mark-unread-channel", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channel, userId: peerId)
    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: peerId)
    _ = accounts.oauth.createMessageRecord(channelId: channel, content: "message to revisit", senderId: peerId)
    let ownChannel = accounts.oauth.createMessageRecord(channelId: channel, content: "own latest channel message", senderId: ownerId)
    _ = accounts.oauth.createMessageRecord(channelId: dm, content: "dm message to revisit", senderId: peerId)
    let ownDm = accounts.oauth.createMessageRecord(channelId: dm, content: "own latest dm message", senderId: ownerId)
    accounts.oauth.setChannelReadCursor(channelId: channel, userId: ownerId, seq: ownChannel.seq)
    accounts.oauth.setChannelReadCursor(channelId: dm, userId: ownerId, seq: ownDm.seq)

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
                request.body = .init(string: "{\"email\":\"mark-unread-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            for target in [channel, dm] {
                let response = try await client.send(.post, headers: headers, to: "/api/channels/\(target)/unread")
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                #expect(body?["unreadCount"] as? Int == 1)
            }
            let unread = try await client.send(.get, headers: headers, to: "/api/channels/unread")
            let map = try JSONSerialization.jsonObject(with: Data((unread.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(map[channel] as? Int == 1)
            #expect(map[dm] as? Int == 1)
        }
    }
}
