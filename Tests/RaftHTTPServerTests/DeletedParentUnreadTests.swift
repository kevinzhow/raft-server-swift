import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func unreadOmitsAThreadWhoseParentChannelWasDeleted() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111460"
    let peerId = "11111111-1111-4111-8111-111111111461"
    let serverId = "33333333-3333-4333-8333-333333333571"
    accounts.addAccount(id: ownerId, email: "deleted-parent-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "deleted-parent-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "deleted-parent", name: "Deleted Parent", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let parent = accounts.oauth.createChannel(serverId: serverId, name: "deleted-parent-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: ownerId, name: "deleted-parent-room")
    accounts.oauth.addChannelHuman(channelId: parent, userId: peerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: "abcdef1234567890")
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: parent, parentMessageId: "abcdef1234567890", name: "thread")
    accounts.oauth.addChannelHuman(channelId: thread, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: thread, userId: peerId)
    _ = accounts.oauth.createMessageRecord(channelId: thread, content: "reply after parent delete", senderId: peerId)
    accounts.oauth.setChannelReadCursor(channelId: thread, userId: ownerId, seq: 0)
    accounts.followThreadForTesting(serverId: serverId, userId: ownerId, threadChannelId: thread, parentMessageId: "abcdef1234567890")

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
                request.body = .init(string: "{\"email\":\"deleted-parent-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let before = try await client.send(.get, headers: headers, to: "/api/channels/unread")
            #expect((try JSONSerialization.jsonObject(with: Data((before.body.string ?? "").utf8)) as? [String: Any])?[thread] as? Int == 1)

            let followedBefore = try await client.send(.get, headers: headers, to: "/api/channels/threads/followed")
            #expect(((try JSONSerialization.jsonObject(with: Data((followedBefore.body.string ?? "").utf8)) as? [String: Any])?["threads"] as? [[String: Any]] ?? []).count == 1)

            accounts.softDeletePostableChannelForTesting(channelId: parent)
            let after = try await client.send(.get, headers: headers, to: "/api/channels/unread")
            #expect((try JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8)) as? [String: Any])?[thread] == nil)
            let followedAfter = try await client.send(.get, headers: headers, to: "/api/channels/threads/followed")
            #expect(((try JSONSerialization.jsonObject(with: Data((followedAfter.body.string ?? "").utf8)) as? [String: Any])?["threads"] as? [[String: Any]] ?? []).isEmpty)
        }
    }
}
