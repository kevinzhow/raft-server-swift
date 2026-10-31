import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func unreadMapOmitsChannelsWithOnlyOwnOrReadMessages() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111437"
    let peerId = "11111111-1111-4111-8111-111111111438"
    let serverId = "33333333-3333-4333-8333-333333333557"
    accounts.addAccount(id: ownerId, email: "self-unread-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "self-unread-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "self-unread", name: "Self Unread", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "self-unread-channel", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channel, userId: peerId)
    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: peerId)
    let baseline = accounts.oauth.createMessageRecord(channelId: channel, content: "read baseline", senderId: peerId).id
    _ = accounts.oauth.createMessageRecord(channelId: channel, content: "own channel message", senderId: ownerId).id
    _ = accounts.oauth.createMessageRecord(channelId: dm, content: "own dm message", senderId: ownerId).id
    let baselineSeq = accounts.oauth.channelUnreadInfo(channelId: channel, userId: ownerId).latestSeq ?? 1
    accounts.oauth.setChannelReadCursor(channelId: channel, userId: ownerId, seq: baselineSeq - 1)
    accounts.oauth.setChannelReadCursor(channelId: dm, userId: ownerId, seq: 0)
    _ = baseline

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
                request.body = .init(string: "{\"email\":\"self-unread-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.get, headers: headers, to: "/api/channels/unread")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(body[channel] == nil)
            #expect(body[dm] == nil)
        }
    }
}
