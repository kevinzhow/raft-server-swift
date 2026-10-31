import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func followedThreadsCarryHumanReplyUnreadCount() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111563"
    let replierId = "11111111-1111-4111-8111-111111111564"
    let serverId = "33333333-3333-4333-8333-333333333629"
    accounts.addAccount(id: ownerId, email: "followed-unread-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: replierId, email: "followed-unread-replier@slock.test", password: "password123")
    accounts.markEmailVerified(userId: replierId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "followed-unread", name: "Followed Unread", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: replierId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "followed-unread-channel", creatorUserId: ownerId)
    for id in [ownerId, replierId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "followed-unread-channel")
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
            let ownerToken = try await login("followed-unread-owner@slock.test")
            let replierToken = try await login("followed-unread-replier@slock.test")
            func send(_ token: String, _ channelId: String, _ content: String) async throws {
                let response = try await client.send(.post, headers: headers(token), to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
                }
                #expect(response.status == .ok)
            }
            let parent = try await client.send(.post, headers: headers(ownerToken), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"parent task\"}")
            }
            let parentId = (try JSONSerialization.jsonObject(with: Data((parent.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let threadResponse = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/\(channel)/threads") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(parentId)\"}")
            }
            let threadId = (try JSONSerialization.jsonObject(with: Data((threadResponse.body.string ?? "").utf8)) as? [String: Any])?["threadChannelId"] as? String ?? ""
            try await send(ownerToken, threadId, "already read reply")
            try await send(replierToken, threadId, "unread reply")
            #expect(try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(threadId)\"}")
            }.status == .ok)
            #expect(try await client.send(.post, headers: headers(ownerToken), to: "/api/channels/\(threadId)/read") { request in
                request.body = .init(string: "{\"seq\":1}")
            }.status == .ok)

            let followed = try await client.send(.get, headers: headers(ownerToken), to: "/api/channels/threads/followed")
            let rows = (try JSONSerialization.jsonObject(with: Data((followed.body.string ?? "").utf8)) as? [String: Any])?["threads"] as? [[String: Any]] ?? []
            let row = rows.first { $0["threadChannelId"] as? String == threadId }
            #expect(row?["unreadCount"] as? Int == 1)
        }
    }
}
