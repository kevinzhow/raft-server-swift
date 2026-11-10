import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func archivedGuestChannelStaysReadableButReadOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111674"
    let guestId = "11111111-1111-4111-8111-111111111675"
    let serverId = "33333333-3333-4333-8333-333333333699"
    accounts.addAccount(id: ownerId, email: "archive-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: guestId, email: "archive-guest@slock.test", password: "password123")
    accounts.markEmailVerified(userId: guestId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "guest-archive", name: "Guest Archive", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    accounts.enableGuestRoleTransitions(serverId: serverId)
    accounts.createFeatureFlagForTesting(key: "server_guest_v0")
    accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "server", decision: "allow", values: [serverId])
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "guest-archive-room", creatorUserId: ownerId)
    for member in [ownerId, guestId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: member, name: "guest-archive-room")
    }
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: guestId)
    accounts.setChannelGuestVisibleForTesting(channelId: channelId, visible: true)
    let marker = "guest-archive-marker-\(UUID().uuidString.prefix(8))"
    _ = accounts.addChannelMessageForTesting(channelId: channelId, content: marker, senderId: ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: guestId))"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let initial = try await client.get(URI(string: "/api/channels"), headers: headers)
            #expect((initial.body.string ?? "").contains(channelId), "a joined guest sees the channel before archiving")

            var ownerHeaders = HTTPFields()
            ownerHeaders[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
            ownerHeaders[.contentType] = "application/json"
            ownerHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let archived = try await client.send(.post, headers: ownerHeaders, to: URI(string: "/api/channels/\(channelId)/archive"))
            #expect(archived.status == .ok)
            let after = try await client.get(URI(string: "/api/channels"), headers: headers)
            #expect(!(after.body.string ?? "").contains(channelId), "archived channels leave the active list")
            let history = try await client.get(URI(string: "/api/messages/channel/\(channelId)"), headers: headers)
            #expect(history.status == .ok, "archived guest history remains readable")
            let search = try await client.get(URI(string: "/api/messages/search?q=guest-archive-marker"), headers: headers)
            #expect(search.status == .ok)
            let results = ((try? JSONSerialization.jsonObject(with: Data((search.body.string ?? "").utf8))) as? [String: Any])?["results"] as? [[String: Any]] ?? []
            let hit = results.first { ($0["channelId"] as? String) == channelId }
            #expect((hit?["channelArchivedAt"] as? String)?.isEmpty == false, "archived search hits retain their read-only marker")
            let join = try await client.send(.post, headers: headers, to: URI(string: "/api/channels/\(channelId)/join"))
            #expect(join.status == .conflict)
            let post = try await client.send(.post, headers: headers, to: URI(string: "/api/messages")) { request in
                request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"must stay read-only\"}")
            }
            #expect(post.status == .forbidden, "\(post.status) \((post.body.string ?? "").prefix(120))")
        }
    }
}
