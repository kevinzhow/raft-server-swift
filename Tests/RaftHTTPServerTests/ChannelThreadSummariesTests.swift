import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func channelThreadSummariesAggregateRepliesAndParticipants() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111430"
    let replierId = "11111111-1111-4111-8111-111111111431"
    let serverId = "33333333-3333-4333-8333-333333333553"
    accounts.addAccount(id: ownerId, email: "threads-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: replierId, email: "threads-replier@slock.test", password: "password123")
    accounts.markEmailVerified(userId: replierId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "threads", name: "Threads", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: replierId, role: "member")

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
            let ownerToken = try await login("threads-owner@slock.test")
            let replierToken = try await login("threads-replier@slock.test")
            let channel = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"thread-summary-channel\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            func post(_ token: String, _ channel: String, _ content: String) async throws -> String {
                let response = try await client.send(.post, headers: headers(token), to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"\(content)\"}")
                }
                #expect(response.status == .ok)
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            }

            accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: replierId)
            let parentOne = try await post(ownerToken, channelId, "parent one")
            let parentTwo = try await post(replierToken, channelId, "parent two")
            let threadOne = UUID().uuidString.lowercased()
            let threadTwo = UUID().uuidString.lowercased()
            for (thread, parent) in [(threadOne, parentOne), (threadTwo, parentTwo)] {
                accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: channelId, parentMessageId: parent, name: "thread")
                accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: replierId, kind: "thread", parentChannelId: channelId, parentMessageId: parent, name: "thread")
            }
            _ = try await post(ownerToken, threadOne, "reply one")
            _ = try await post(replierToken, threadOne, "reply two")
            _ = try await post(replierToken, threadTwo, "reply three")

            let response = try await client.send(.get, headers: headers(ownerToken), to: "/api/channels/\(channelId)/threads")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let first = body[parentOne] as? [String: Any]
            let second = body[parentTwo] as? [String: Any]
            #expect(first?["threadChannelId"] as? String == threadOne)
            #expect(first?["replyCount"] as? Int == 2)
            #expect((first?["participantIds"] as? [String])?.count == 2)
            #expect(second?["threadChannelId"] as? String == threadTwo)
            #expect(second?["replyCount"] as? Int == 1)
            #expect((second?["participantIds"] as? [String])?.count == 1)
        }
    }
}
