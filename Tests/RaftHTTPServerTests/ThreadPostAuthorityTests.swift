import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadPostAuthorityComesFromTheParentChannel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111552"
    let memberId = "11111111-1111-4111-8111-111111111553"
    let followerId = "11111111-1111-4111-8111-111111111554"
    let outsiderId = "11111111-1111-4111-8111-111111111555"
    let serverId = "33333333-3333-4333-8333-333333333623"
    for (id, email) in [
        (ownerId, "post-auth-owner@slock.test"),
        (memberId, "post-auth-member@slock.test"),
        (followerId, "post-auth-follower@slock.test"),
        (outsiderId, "post-auth-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "post-auth", name: "Post Auth", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: followerId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let parent = accounts.oauth.createChannel(serverId: serverId, name: "post-auth-parent", creatorUserId: ownerId)
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: id, name: "post-auth-parent")
        accounts.oauth.addChannelHuman(channelId: parent, userId: id)
    }
    let parentMessageId = UUID().uuidString.lowercased()
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: parentMessageId)
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: parent, parentMessageId: parentMessageId, name: "thread")
    accounts.oauth.addChannelHuman(channelId: thread, userId: ownerId)
    accounts.followThreadForTesting(serverId: serverId, userId: followerId, threadChannelId: thread, parentMessageId: parentMessageId)

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
            func send(_ token: String, _ channel: String) async throws -> Int {
                let response = try await client.send(.post, headers: headers(token), to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"hello\"}")
                }
                return response.status.code
            }
            let ownerToken = try await login("post-auth-owner@slock.test")
            let memberToken = try await login("post-auth-member@slock.test")
            let followerToken = try await login("post-auth-follower@slock.test")
            let outsiderToken = try await login("post-auth-outsider@slock.test")

            #expect(try await send(followerToken, thread) == 403)
            #expect(try await send(followerToken, parent) == 403)
            #expect(try await send(outsiderToken, thread) == 403)
            #expect(try await send(ownerToken, thread) == 200)
            #expect(try await send(memberToken, thread) == 200)
        }
    }
}
