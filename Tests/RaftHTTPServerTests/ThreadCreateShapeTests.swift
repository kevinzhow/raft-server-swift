import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadCreationIsIdempotentAndShapesTheSummary() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111537"
    let replierId = "11111111-1111-4111-8111-111111111538"
    let serverId = "33333333-3333-4333-8333-333333333615"
    accounts.addAccount(id: ownerId, email: "thread-shape-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: replierId, email: "thread-shape-replier@slock.test", password: "password123")
    accounts.markEmailVerified(userId: replierId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-shape", name: "Thread Shape", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: replierId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "shape-parent", creatorUserId: ownerId)
    for id in [ownerId, replierId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "shape-parent")
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
            let ownerToken = try await login("thread-shape-owner@slock.test")
            let replierToken = try await login("thread-shape-replier@slock.test")
            let parent = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"thread parent\"}")
            }
            let parentId = (try JSONSerialization.jsonObject(with: Data((parent.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""

            let create = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/\(channel)/threads") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(parentId)\"}")
            }
            #expect(create.status == .ok)
            let created = try JSONSerialization.jsonObject(with: Data((create.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let threadId = created["threadChannelId"] as? String ?? ""
            #expect(!threadId.isEmpty)
            #expect(created["replyCount"] as? Int == 0)
            #expect(created["lastReplyAt"] == nil || created["lastReplyAt"] is NSNull)
            #expect((created["participantIds"] as? [String] ?? []).isEmpty)

            let repeatCreate = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/\(channel)/threads") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(parentId)\"}")
            }
            let repeated = try JSONSerialization.jsonObject(with: Data((repeatCreate.body.string ?? "").utf8)) as? [String: Any]
            #expect(repeated?["threadChannelId"] as? String == threadId)

            accounts.addPostableChannel(serverId: serverId, channelId: threadId, memberId: replierId, kind: "thread", parentChannelId: channel, parentMessageId: parentId, name: "thread")
            accounts.oauth.addChannelHuman(channelId: threadId, userId: replierId)
            let reply = try await client.send(.post, headers: headers(replierToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(threadId)\",\"content\":\"thread reply\"}")
            }
            #expect(reply.status == .ok)

            let summary = try await client.send(.get, headers: headers(ownerToken), to: "/api/channels/\(channel)/threads")
            let summaryBody = try JSONSerialization.jsonObject(with: Data((summary.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let entry = summaryBody[parentId] as? [String: Any]
            #expect(entry?["threadChannelId"] as? String == threadId)
            #expect(entry?["replyCount"] as? Int == 1)
            #expect(Set(entry?["participantIds"] as? [String] ?? []) == Set([ownerId, replierId]))
        }
    }
}
