import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func privateConversionPrunesThreadFollowsOutsideTheSnapshot() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111543"
    let followerId = "11111111-1111-4111-8111-111111111544"
    let serverId = "33333333-3333-4333-8333-333333333619"
    accounts.addAccount(id: ownerId, email: "prune-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: followerId, email: "prune-follower@slock.test", password: "password123")
    accounts.markEmailVerified(userId: followerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "prune", name: "Prune", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: followerId, role: "member")
    let parent = accounts.oauth.createChannel(serverId: serverId, name: "prune-parent", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: ownerId, name: "prune-parent")
    let agentFollowerId = accounts.oauth.createAgent(serverId: serverId, name: "prune-agent", runtime: "codex")
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: UUID().uuidString.lowercased())
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: parent, name: "thread")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("prune-owner@slock.test")
            let followerToken = try await login("prune-follower@slock.test")
            for token in [ownerToken, followerToken] {
                #expect(try await client.send(.post, headers: headers(token), to: "/api/channels/threads/follow") { request in
                    request.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}")
                }.status == .ok)
            }
            accounts.followThreadForTesting(
                serverId: serverId,
                userId: agentFollowerId,
                threadChannelId: thread,
                parentMessageId: "parent"
            )
            #expect(try await client.send(.patch, headers: headers(ownerToken), to: "/api/channels/\(parent)") { request in
                request.body = .init(string: "{\"visibility\":\"private\"}")
            }.status == .ok)
            let followerFollowed = try await client.send(.get, headers: headers(followerToken), to: "/api/channels/threads/followed")
            #expect(((try JSONSerialization.jsonObject(with: Data((followerFollowed.body.string ?? "").utf8)) as? [String: Any])?["threads"] as? [[String: Any]] ?? []).isEmpty)
            let ownerFollowed = try await client.send(.get, headers: headers(ownerToken), to: "/api/channels/threads/followed")
            #expect(((try JSONSerialization.jsonObject(with: Data((ownerFollowed.body.string ?? "").utf8)) as? [String: Any])?["threads"] as? [[String: Any]] ?? []).contains { $0["threadChannelId"] as? String == thread })
            #expect(accounts.threadFollowerIdsForTesting(threadChannelId: thread) == [ownerId])

            let reply = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(thread)\",\"content\":\"private reply\"}")
            }
            #expect(reply.status == .ok)
            let replyId = try #require((try JSONSerialization.jsonObject(with: Data((reply.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String)

            let hidden = try await client.send(.get, headers: headers(followerToken), to: "/api/messages/channel/\(thread)")
            #expect(hidden.status == .notFound)

            let inbox = try await client.send(.get, headers: headers(followerToken), to: "/api/channels/inbox")
            #expect(inbox.status == .ok)
            let inboxItems = (try JSONSerialization.jsonObject(with: Data((inbox.body.string ?? "").utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            #expect(!inboxItems.contains { item in
                item["threadChannelId"] as? String == thread || item["parentChannelId"] as? String == parent
            })

            let unread = try await client.send(.get, headers: headers(followerToken), to: "/api/channels/unread")
            #expect(unread.status == .ok)
            let unreadBody = try JSONSerialization.jsonObject(with: Data((unread.body.string ?? "").utf8)) as? [String: Any]
            #expect(unreadBody?[thread] == nil)

            let sync = try await client.send(.get, headers: headers(followerToken), to: "/api/messages/sync?since_seq=0")
            #expect(sync.status == .ok)
            let syncRows = try JSONSerialization.jsonObject(with: Data((sync.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(!syncRows.contains { $0["id"] as? String == replyId })
        }
    }
}
