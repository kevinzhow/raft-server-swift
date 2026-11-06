import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func unfollowKeepsThreadActivityAllButSuppressesMentionsOutsideTheParent() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001001001"
    let ownerId = "11111111-1111-4111-8111-000001001001"
    let memberId = "11111111-1111-4111-8111-000001001002"
    let followerId = "11111111-1111-4111-8111-000001001003"
    let ownerEmail = "unfollow-delivery-owner@slock.test"
    let memberEmail = "unfollow-delivery-member@slock.test"
    let followerEmail = "unfollow-delivery-follower@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail), (followerId, followerEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "unfollow-delivery", name: "Unfollow Delivery", ownerId: ownerId)
    for id in [memberId, followerId] {
        accounts.oauth.addMember(serverId: serverId, userId: id, role: "member")
    }
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "unfollow-delivery", creatorUserId: ownerId)
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "unfollow-delivery")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let parent = accounts.addChannelMessageForTesting(channelId: channel, content: "thread parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parent)
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: id, kind: "thread", parentChannelId: channel, parentMessageId: parent, name: "thread")
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
            let member = try await login(memberEmail)
            let follower = try await login(followerEmail)

            for path in ["follow", "unfollow"] {
                let response = try await client.send(.post, headers: headers(follower), to: URI(string: "/api/channels/threads/\(path)")) { request in
                    request.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}")
                }
                #expect(response.status == .ok)
            }

            let reply = try await client.send(.post, headers: headers(member), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(thread)\",\"content\":\"ordinary reply after non-author unfollow\"}")
            }
            #expect(reply.status == .ok)

            let all = try await client.get(URI(string: "/api/channels/inbox?filter=all"), headers: headers(follower))
            let allItems = (try JSONSerialization.jsonObject(with: Data((all.body.string ?? "").utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let threadRow = try #require(allItems.first { $0["kind"] as? String == "thread" && $0["threadChannelId"] as? String == thread })
            #expect(threadRow["isFollowing"] as? Bool == false)
            #expect(threadRow["unreadCount"] as? Int == 0)
            #expect(threadRow["hasMention"] as? Bool == false)
            #expect(threadRow["firstUnreadMessageId"] is NSNull)

            let mention = try await client.send(.post, headers: headers(member), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(thread)\",\"content\":\"ping @unfollow-delivery-follower after unfollow\"}")
            }
            #expect(mention.status == .ok)

            let mentions = try await client.get(URI(string: "/api/channels/inbox?filter=mentions"), headers: headers(follower))
            let mentionItems = (try JSONSerialization.jsonObject(with: Data((mentions.body.string ?? "").utf8)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
            #expect(!mentionItems.contains { $0["kind"] as? String == "thread" && $0["threadChannelId"] as? String == thread })
        }
    }
}
