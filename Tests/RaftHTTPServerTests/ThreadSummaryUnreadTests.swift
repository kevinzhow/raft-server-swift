import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadSummariesCarryViewerUnreadReplyState() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111556"
    let replierId = "11111111-1111-4111-8111-111111111557"
    let serverId = "33333333-3333-4333-8333-333333333624"
    accounts.addAccount(id: ownerId, email: "summary-unread-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: replierId, email: "summary-unread-replier@slock.test", password: "password123")
    accounts.markEmailVerified(userId: replierId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "summary-unread", name: "Summary Unread", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: replierId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "summary-unread-channel", creatorUserId: ownerId)
    for id in [ownerId, replierId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "summary-unread-channel")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
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
            let ownerToken = try await login("summary-unread-owner@slock.test")
            let replierToken = try await login("summary-unread-replier@slock.test")
            func send(_ token: String, _ channelId: String, _ content: String) async throws -> String {
                let response = try await client.send(.post, headers: headers(token), to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
                }
                #expect(response.status == .ok)
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            }
            let followedParent = try await send(ownerToken, channel, "followed parent")
            let followedThread = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/\(channel)/threads") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(followedParent)\"}")
            }
            let followedThreadId = (try JSONSerialization.jsonObject(with: Data((followedThread.body.string ?? "").utf8)) as? [String: Any])?["threadChannelId"] as? String ?? ""
            let alreadyReadReply = try await send(replierToken, followedThreadId, "already read reply")
            let unreadReply = try await send(replierToken, followedThreadId, "unread reply")
            #expect(try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(followedThreadId)\"}")
            }.status == .ok)
            #expect(try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/\(followedThreadId)/read") { request in
                request.body = .init(string: "{\"seq\":\(accounts.humanMessageSequence(id: alreadyReadReply) ?? 1)}")
            }.status == .ok)

            let unfollowedParent = try await send(ownerToken, channel, "unfollowed parent")
            let unfollowedThread = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/\(channel)/threads") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(unfollowedParent)\"}")
            }
            let unfollowedThreadId = (try JSONSerialization.jsonObject(with: Data((unfollowedThread.body.string ?? "").utf8)) as? [String: Any])?["threadChannelId"] as? String ?? ""
            #expect(try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/threads/unfollow") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(unfollowedThreadId)\"}")
            }.status == .ok)
            _ = try await send(replierToken, unfollowedThreadId, "not followed unread")

            let response = try await client.send(.get, headers: headers(ownerToken), to: "/api/channels/\(channel)/threads")
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let followed = body[followedParent] as? [String: Any]
            #expect(followed?["replyCount"] as? Int == 2)
            #expect(followed?["unreadCount"] as? Int == 1)
            #expect(followed?["firstUnreadMessageId"] as? String == unreadReply)
            let unfollowed = body[unfollowedParent] as? [String: Any]
            #expect(unfollowed?["replyCount"] as? Int == 1)
            #expect(unfollowed?["unreadCount"] as? Int == 0)
            #expect(unfollowed?["firstUnreadMessageId"] == nil || unfollowed?["firstUnreadMessageId"] is NSNull)
        }
    }
}
