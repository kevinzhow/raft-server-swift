import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func revokedGuestThreadDisappearsFromActivityAndUnread() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111706"
    let followerId = "11111111-1111-4111-8111-111111111707"
    let serverId = "33333333-3333-4333-8333-333333333710"
    accounts.addAccount(id: ownerId, email: "review-guest-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: followerId, email: "review-guest-follower@slock.test", password: "password123")
    accounts.markEmailVerified(userId: followerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "review-guest", name: "Review Guest", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: followerId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "review-guest-room", creatorUserId: ownerId)
    for id in [ownerId, followerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "review-guest-room")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    accounts.enableGuestRoleTransitions(serverId: serverId)

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
            func fields(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("review-guest-owner@slock.test")
            let followerToken = try await login("review-guest-follower@slock.test")

            let parent = try await client.send(.post, headers: fields(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"parent task\"}")
            }
            let parentId = (try JSONSerialization.jsonObject(with: Data((parent.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let threadResponse = try await client.send(.post, headers: fields(ownerToken), to: "/api/channels/\(channel)/threads") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(parentId)\"}")
            }
            let threadId = (try JSONSerialization.jsonObject(with: Data((threadResponse.body.string ?? "").utf8)) as? [String: Any])?["threadChannelId"] as? String ?? ""
            #expect(!threadId.isEmpty)
            let follow = try await client.send(.post, headers: fields(followerToken), to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(threadId)\"}")
            }
            #expect(follow.status == .ok)
            _ = accounts.oauth.createChannelMessage(channelId: threadId, content: "secret-review-thread-reply", senderId: ownerId)
            accounts.addInboxFactForTesting(receiverId: followerId, serverId: serverId, channelId: threadId, messageId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")

            func directRead() async throws -> ClientResponse {
                try await client.get(URI(string: "/api/messages/channel/\(threadId)"), headers: fields(followerToken))
            }
            func inbox(_ filter: String) async throws -> String {
                let response = try await client.get(URI(string: "/api/channels/inbox?filter=\(filter)"), headers: fields(followerToken))
                #expect(response.status == .ok)
                return response.body.string ?? ""
            }

            let directBefore = try await directRead()
            #expect(directBefore.status == .ok)
            let allBefore = try await inbox("all")
            #expect(allBefore.contains(threadId))
            let unreadBefore = try await inbox("unread")
            #expect(unreadBefore.contains(threadId))

            let demote = try await client.patch(URI(string: "/api/servers/\(serverId)/members/\(followerId)"), headers: fields(ownerToken)) { request in
                request.body = .init(string: "{\"role\":\"guest\"}")
            }
            #expect(demote.status == .ok)
            #expect(accounts.oauth.memberRole(serverId: serverId, userId: followerId) == "guest")

            let directAfter = try await directRead()
            #expect(directAfter.status == .forbidden)
            let afterReply = try await client.send(.post, headers: fields(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(threadId)\",\"content\":\"new-secret-after-guest-downgrade\"}")
            }
            #expect(afterReply.status == .ok)
            let afterReplyId = (try JSONSerialization.jsonObject(with: Data((afterReply.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            accounts.addInboxFactForTesting(receiverId: followerId, serverId: serverId, channelId: threadId, messageId: afterReplyId)
            let allAfter = try await inbox("all")
            #expect(!allAfter.contains(threadId))
            let unreadAfter = try await inbox("unread")
            #expect(!unreadAfter.contains(threadId))
        }
    }
}
