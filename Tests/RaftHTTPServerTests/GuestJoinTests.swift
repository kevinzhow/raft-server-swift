import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func guestJoinsRequireTheChannelFlagAndStayUnlimited() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111663"
    let serverId = "33333333-3333-4333-8333-333333333695"
    let guests = ["11111111-1111-4111-8111-111111111664", "11111111-1111-4111-8111-111111111665", "11111111-1111-4111-8111-111111111666"]
    accounts.addAccount(id: ownerId, email: "guestjoin-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "guestjoin", name: "Guest Join", ownerId: ownerId)
    for (index, guestId) in guests.enumerated() {
        accounts.addAccount(id: guestId, email: "guestjoin-\(index)@slock.test", password: "password123")
        accounts.markEmailVerified(userId: guestId)
        accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    }
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "guestjoin-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "guestjoin-room")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func join(_ guestId: String) async throws -> HTTPResponse.Status {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: guestId))"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/channels/\(channelId)/join"))
                return response.status
            }
            let initial = try await join(guests[0])
            #expect(initial == .forbidden, "a guest cannot join without the channel flag")
            accounts.setChannelGuestJoinableForTesting(channelId: channelId, joinable: true)
            for guestId in guests {
                let joined = try await join(guestId)
                #expect(joined == .ok, "guest joins have no per-server cap")
            }
            accounts.oauth.setChannelArchived(id: channelId, archivedAt: Date())
            let archived = try await join(guests[0])
            #expect(archived == .conflict, "archived channels refuse joins")
        }
    }
}


@Test func adminsCanEnableGuestJoinThroughTheChannelApi() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111667"
    let memberId = "11111111-1111-4111-8111-111111111668"
    let guestId = "11111111-1111-4111-8111-111111111669"
    let serverId = "33333333-3333-4333-8333-333333333696"
    for (id, email) in [(ownerId, "joinapi-owner@slock.test"), (memberId, "joinapi-member@slock.test"), (guestId, "joinapi-guest@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "joinapi", name: "Join API", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "joinapi-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "joinapi-room")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func patch(_ userId: String, _ body: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: userId))"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.patch, headers: headers, to: URI(string: "/api/channels/\(channelId)")) { request in
                    request.body = .init(string: body)
                }
            }
            let denied = try await patch(memberId, #"{"guestJoinable":true}"#)
            #expect(denied.status == .forbidden, "only owners/admins may change guest settings")
            let enabled = try await patch(ownerId, #"{"guestJoinable":true,"guestVisible":true}"#)
            #expect(enabled.status == .ok)
            let body = (try? JSONSerialization.jsonObject(with: Data((enabled.body.string ?? "").utf8))) as? [String: Any]
            #expect(body?["guestJoinable"] as? Bool == true)
            #expect(body?["guestVisible"] as? Bool == true)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: guestId))"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let joined = try await client.send(.post, headers: headers, to: URI(string: "/api/channels/\(channelId)/join"))
            #expect(joined.status == .ok)
        }
    }
}


@Test func guestChannelListHonorsTheGuestVisibleFlag() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111670"
    let guestId = "11111111-1111-4111-8111-111111111671"
    let serverId = "33333333-3333-4333-8333-333333333697"
    accounts.addAccount(id: ownerId, email: "guestlist-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: guestId, email: "guestlist-guest@slock.test", password: "password123")
    accounts.markEmailVerified(userId: guestId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "guestlist", name: "Guest List", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let visible = accounts.oauth.createChannel(serverId: serverId, name: "guestlist-visible", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: visible, memberId: ownerId, name: "guestlist-visible")
    let hidden = accounts.oauth.createChannel(serverId: serverId, name: "guestlist-hidden", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: hidden, memberId: ownerId, name: "guestlist-hidden")
    accounts.setChannelGuestVisibleForTesting(channelId: visible, visible: true)
    accounts.setChannelGuestVisibleForTesting(channelId: hidden, visible: false)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: guestId))"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.get(URI(string: "/api/channels"), headers: headers)
            #expect(response.status == .ok)
            let ids = Set(((try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            #expect(ids.contains(visible))
            #expect(!ids.contains(hidden), "guestVisible=false channels stay out of a guest's list")
        }
    }
}
