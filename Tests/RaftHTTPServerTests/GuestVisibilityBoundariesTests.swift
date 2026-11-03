import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct GuestBoundaryFixture {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let guestId: String
    let serverId: String
    let channelId: String
    let messageId: String
    let guestHeaders: HTTPFields
}

private func makeGuestBoundaryFixture() -> GuestBoundaryFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111659"
    let guestId = "11111111-1111-4111-8111-111111111660"
    let serverId = "33333333-3333-4333-8333-333333333692"
    for (id, email) in [(ownerId, "boundary-owner@slock.test"), (guestId, "boundary-guest@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "boundaries", name: "Boundaries", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "boundary-hidden", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "boundary-hidden")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let messageId = accounts.addChannelMessageForTesting(channelId: channelId, content: "hidden-boundary-content", senderId: ownerId)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: guestId))"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return GuestBoundaryFixture(
        accounts: accounts, ownerId: ownerId, guestId: guestId, serverId: serverId,
        channelId: channelId, messageId: messageId, guestHeaders: headers
    )
}

@Test func guestCannotReadMetadataOrMembersForAHiddenChannel() async throws {
    let f = makeGuestBoundaryFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for suffix in ["", "/members", "/agents"] {
                let response = try await client.get(URI(string: "/api/channels/\(f.channelId)\(suffix)"), headers: f.guestHeaders)
                #expect(response.status == .notFound, "\(suffix.isEmpty ? "details" : suffix) must cloak the hidden channel")
            }
        }
    }
}

@Test func guestBroadSyncOmitsHiddenChannelContent() async throws {
    let f = makeGuestBoundaryFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.get(URI(string: "/api/messages/sync?since_seq=0"), headers: f.guestHeaders)
            #expect(response.status == .ok)
            #expect(!(response.body.string ?? "").contains(f.messageId))
        }
    }
}

@Test func guestCannotMutateReadStateOnAHiddenChannel() async throws {
    let f = makeGuestBoundaryFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            var statuses: [HTTPResponse.Status] = []
            for (suffix, body) in [("read", #"{"seq":1}"#), ("read-all", "{}"), ("unread", "{}")] {
                let response = try await client.send(.post, headers: f.guestHeaders, to: URI(string: "/api/channels/\(f.channelId)/\(suffix)")) { request in
                    request.body = .init(string: body)
                }
                statuses.append(response.status)
            }
            #expect(statuses == [.notFound, .notFound, .notFound], "\(statuses.map(\.code))")
        }
    }
}
