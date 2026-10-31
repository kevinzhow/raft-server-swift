import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func followAndUnfollowThreadMutation() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111524"
    let memberId = "11111111-1111-4111-8111-111111111525"
    let serverId = "33333333-3333-4333-8333-333333333607"
    accounts.addAccount(id: ownerId, email: "follow-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "follow-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "follow", name: "Follow", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let parent = accounts.oauth.createChannel(serverId: serverId, name: "follow-parent", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: memberId, name: "follow-parent")
    accounts.oauth.addChannelHuman(channelId: parent, userId: memberId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: UUID().uuidString.lowercased())
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: memberId, kind: "thread", parentChannelId: parent, name: "thread")
    accounts.oauth.addChannelHuman(channelId: thread, userId: memberId)

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
                request.body = .init(string: "{\"email\":\"follow-member@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let follow = try await client.send(.post, headers: headers, to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}")
            }
            #expect(follow.status == .ok)
            let followed = try await client.send(.get, headers: headers, to: "/api/channels/threads/followed")
            let followedBody = try JSONSerialization.jsonObject(with: Data((followed.body.string ?? "").utf8)) as? [String: Any]
            #expect((followedBody?["threads"] as? [[String: Any]] ?? []).contains { $0["threadChannelId"] as? String == thread })

            let unfollow = try await client.send(.post, headers: headers, to: "/api/channels/threads/unfollow") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}")
            }
            #expect(unfollow.status == .ok)
            let empty = try await client.send(.get, headers: headers, to: "/api/channels/threads/followed")
            #expect(empty.status == .ok)
            #expect(((try JSONSerialization.jsonObject(with: Data((empty.body.string ?? "").utf8)) as? [String: Any])?["threads"] as? [[String: Any]] ?? []).isEmpty)
        }
    }
}
