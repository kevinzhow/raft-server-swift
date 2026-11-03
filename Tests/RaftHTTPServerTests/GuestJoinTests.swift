import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
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
