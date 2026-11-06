import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func unreadSummaryCarriesMentionFlagsPerChannel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111442"
    let peerId = "11111111-1111-4111-8111-111111111443"
    let serverId = "33333333-3333-4333-8333-333333333560"
    accounts.addAccount(id: ownerId, email: "summary-mention@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "summary-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "summary-mention", name: "Summary Mention", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "summary-channel", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channel, userId: peerId)
    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: peerId)
    let read = accounts.oauth.createMessageRecord(channelId: channel, content: "already read", senderId: ownerId)
    let unread = accounts.oauth.createMessageRecord(channelId: channel, content: "unread channel message", senderId: peerId)
    _ = accounts.oauth.createMessageRecord(channelId: dm, content: "unread dm message", senderId: peerId)
    accounts.oauth.setChannelReadCursor(channelId: channel, userId: ownerId, seq: read.seq)
    accounts.addStoredMentionForTesting(channelId: channel, messageId: unread.id, targetId: ownerId)

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
                request.body = .init(string: "{\"email\":\"summary-mention@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.get, headers: headers, to: "/api/channels/unread?summary=1")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let channels = body?["channels"] as? [String: Any]
            let channelEntry = channels?[channel] as? [String: Any]
            #expect(channelEntry?["unreadCount"] as? Int == 1)
            #expect(channelEntry?["hasMention"] as? Bool == true)
            #expect(channelEntry?["hasAnyMention"] as? Bool == true)
            #expect((channelEntry?["readState"] as? [String: Any])?["latestActivity"] != nil)
            let dmEntry = channels?[dm] as? [String: Any]
            #expect(dmEntry?["unreadCount"] as? Int == 1)
            #expect(dmEntry?["hasMention"] as? Bool == false)
            #expect(dmEntry?["hasAnyMention"] as? Bool == false)
        }
    }
}
