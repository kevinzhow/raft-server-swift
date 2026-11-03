import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func deletedChannelDeepLinksAndThreadsAreCloaked() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111661"
    let serverId = "33333333-3333-4333-8333-333333333693"
    accounts.addAccount(id: ownerId, email: "deleted-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "deleted", name: "Deleted", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "deleted-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "deleted-room")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let message = accounts.addChannelMessageForTesting(channelId: channelId, content: "deleted-content", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: message)
    accounts.addPostableChannel(
        serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread",
        parentChannelId: channelId, parentMessageId: message, name: "thread"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let deleted = try await client.delete(URI(string: "/api/channels/\(channelId)"), headers: headers)
            #expect(deleted.status == .ok)
            let channelRead = try await client.get(URI(string: "/api/messages/channel/\(channelId)"), headers: headers)
            #expect(channelRead.status == .notFound, "deleted channel deep-links are cloaked")
            let threadRead = try await client.get(URI(string: "/api/messages/channel/\(thread)"), headers: headers)
            #expect(threadRead.status == .notFound, "thread deep-links are cloaked after parent deletion")
        }
    }
}
