import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func unreadCountsExcludeOwnMessagesAndCarryReadState() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111284"
    let peerId = "11111111-1111-4111-8111-111111111285"
    let serverId = "33333333-3333-4333-8333-333333333470"
    accounts.addAccount(id: ownerId, email: "unread-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "unread-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "unread-trace", name: "Unread Trace Server", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "unread-channel", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: peerId)
    accounts.oauth.createChannelMessage(channelId: channelId, content: "already read", senderId: ownerId)
    accounts.oauth.createChannelMessage(channelId: channelId, content: "unread channel message", senderId: peerId)
    accounts.oauth.setChannelReadCursor(channelId: channelId, userId: ownerId, seq: 1)
    let dmId = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: peerId)
    accounts.oauth.createChannelMessage(channelId: dmId, content: "unread dm message", senderId: peerId)

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
                request.body = .init(string: "{\"email\":\"unread-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let response = try await client.send(.get, headers: headers, to: "/api/channels/unread")
            #expect(response.status == .ok)
            #expect(response.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            let counts = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Int]
            #expect(counts?[channelId] == 1)
            #expect(counts?[dmId] == 1)

            let summaryResponse = try await client.send(.get, headers: headers, to: "/api/channels/unread?summary=1")
            #expect(summaryResponse.status == .ok)
            let summary = try JSONSerialization.jsonObject(with: Data((summaryResponse.body.string ?? "").utf8)) as? [String: Any]
            let channels = summary?["channels"] as? [String: Any]
            let channel = channels?[channelId] as? [String: Any]
            #expect(channel?["unreadCount"] as? Int == 1)
            #expect(channel?["hasMention"] as? Bool == false)
            let readState = channel?["readState"] as? [String: Any]
            #expect(readState?["kind"] as? String == "present")
            #expect(readState?["maxReadSeq"] as? String == "1")
            let latest = readState?["latestActivity"] as? [String: Any]
            #expect(latest?["seq"] as? String == "2")
            #expect((latest?["messageId"] as? String)?.isEmpty == false)
        }
    }
}
