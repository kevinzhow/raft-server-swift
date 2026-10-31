import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func unfollowedInboxFreezesAtTheUnfollowBoundary() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111527"
    let followerId = "11111111-1111-4111-8111-111111111528"
    let serverId = "33333333-3333-4333-8333-333333333609"
    accounts.addAccount(id: ownerId, email: "unfollow-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: followerId, email: "unfollow-follower@slock.test", password: "password123")
    accounts.markEmailVerified(userId: followerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "unfollow", name: "Unfollow", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: followerId, role: "member")
    let parent = accounts.oauth.createChannel(serverId: serverId, name: "unfollow-parent", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: ownerId, name: "unfollow-parent")
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: followerId, name: "unfollow-parent")
    let parentMessageId = UUID().uuidString.lowercased()
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: parentMessageId)
    for id in [ownerId, followerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: id, kind: "thread", parentChannelId: parent, parentMessageId: parentMessageId, name: "thread")
        accounts.oauth.addChannelHuman(channelId: thread, userId: id)
    }

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
            func send(_ token: String, _ content: String) async throws -> String {
                let response = try await client.send(.post, headers: headers(token), to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(thread)\",\"content\":\"\(content)\"}")
                }
                #expect(response.status == .ok)
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            }
            func follow(_ token: String) async throws {
                #expect(try await client.send(.post, headers: headers(token), to: "/api/channels/threads/follow") { request in
                    request.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}")
                }.status == .ok)
            }
            func unfollow(_ token: String) async throws {
                #expect(try await client.send(.post, headers: headers(token), to: "/api/channels/threads/unfollow") { request in
                    request.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}")
                }.status == .ok)
            }
            let ownerToken = try await login("unfollow-owner@slock.test")
            let followerToken = try await login("unfollow-follower@slock.test")
            try await follow(ownerToken)
            let before = try await send(ownerToken, "unfollow before boundary")
            try await unfollow(ownerToken)
            _ = try await send(ownerToken, "unfollow after boundary")

            try await follow(followerToken)
            try await unfollow(followerToken)

            var ownerHeaders = HTTPFields()
            ownerHeaders[.authorization] = "Bearer \(ownerToken)"
            ownerHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let history = try await client.send(.get, headers: ownerHeaders, to: URI(string: "/api/channels/inbox/unfollowed?limit=10"))
            #expect(history.status == .ok)
            #expect(history.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            let historyBody = try JSONSerialization.jsonObject(with: Data((history.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let items = historyBody["items"] as? [[String: Any]] ?? []
            let retained = items.first { $0["threadChannelId"] as? String == thread }
            #expect(retained?["kind"] as? String == "thread")
            #expect(retained?["latestActivityMessageId"] as? String == before)
            #expect(retained?["replyCount"] as? Int == 1)
            #expect(retained?["unreadCount"] as? Int == 0)
            #expect(retained?["isFollowing"] as? Bool == false)
            #expect(historyBody["totalCount"] == nil || historyBody["totalCount"] is NSNull)
            #expect(historyBody["hasMore"] as? Bool == false)

            let beforeSearch = try await client.send(.get, headers: ownerHeaders, to: URI(string: "/api/channels/inbox/unfollowed?limit=10&q=before%20boundary"))
            let beforeBody = try JSONSerialization.jsonObject(with: Data((beforeSearch.body.string ?? "").utf8)) as? [String: Any]
            #expect((beforeBody?["items"] as? [[String: Any]] ?? []).contains { $0["threadChannelId"] as? String == thread })
            let afterSearch = try await client.send(.get, headers: ownerHeaders, to: URI(string: "/api/channels/inbox/unfollowed?limit=10&q=after%20boundary"))
            let afterBody = try JSONSerialization.jsonObject(with: Data((afterSearch.body.string ?? "").utf8)) as? [String: Any]
            #expect(!(afterBody?["items"] as? [[String: Any]] ?? []).contains { $0["threadChannelId"] as? String == thread })

            var followerHeaders = ownerHeaders
            followerHeaders[.authorization] = "Bearer \(followerToken)"
            let zero = try await client.send(.get, headers: followerHeaders, to: URI(string: "/api/channels/inbox/unfollowed?limit=10"))
            let zeroBody = try JSONSerialization.jsonObject(with: Data((zero.body.string ?? "").utf8)) as? [String: Any]
            let zeroItem = (zeroBody?["items"] as? [[String: Any]] ?? []).first { $0["threadChannelId"] as? String == thread }
            #expect(zeroItem?["replyCount"] as? Int == 0)
            #expect(zeroItem?["latestActivityMessageId"] as? String == parentMessageId)

            #expect(try await client.send(.post, headers: ownerHeaders, to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(parentMessageId)\"}")
            }.status == .ok)
            let afterRefollow = try await client.send(.get, headers: ownerHeaders, to: URI(string: "/api/channels/inbox/unfollowed?limit=10"))
            let afterRefollowBody = try JSONSerialization.jsonObject(with: Data((afterRefollow.body.string ?? "").utf8)) as? [String: Any]
            #expect(!(afterRefollowBody?["items"] as? [[String: Any]] ?? []).contains { $0["threadChannelId"] as? String == thread })
        }
    }
}
