import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func readAllCanDelegateToAnAgentWithoutTouchingTheHumanCursor() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111452"
    let memberId = "11111111-1111-4111-8111-111111111453"
    let serverId = "33333333-3333-4333-8333-333333333565"
    accounts.addAccount(id: ownerId, email: "delegated-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "delegated-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "delegated", name: "Delegated", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

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
            let ownerToken = try await login("delegated-owner@slock.test")
            let memberToken = try await login("delegated-member@slock.test")
            let channel = try await client.send(.post, headers: headers(ownerToken), to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"delegated-private\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let agent = accounts.oauth.createAgent(serverId: serverId, name: "delegated-agent")
            accounts.oauth.addChannelAgent(channelId: channelId, agentId: agent)
            let message = accounts.oauth.createMessageRecord(channelId: channelId, content: "delegated read", senderId: ownerId)

            func readAll(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: "/api/channels/\(channelId)/read-all") { request in
                    request.body = .init(string: body)
                }
            }

            let delegated = try await readAll(ownerToken, "{\"receiver\":{\"kind\":\"agent\",\"id\":\"\(agent)\"}}")
            #expect(delegated.status == .ok)
            let delegatedBody = try JSONSerialization.jsonObject(with: Data((delegated.body.string ?? "").utf8)) as? [String: Any]
            #expect(delegatedBody?["ok"] as? Bool == true)
            #expect(delegatedBody?["seq"] as? Int == message.seq)
            #expect(delegatedBody?["readStateVersion"] as? Int == 1)
            #expect(accounts.oauth.channelUnreadInfo(channelId: channelId, userId: ownerId).maxReadSeq == 0)
            let cursor = accounts.agentReadCursor(agentId: agent, channelId: channelId)
            #expect(cursor.seq == message.seq)
            #expect(cursor.version == 1)

            #expect(try await readAll(memberToken, "{\"receiver\":{\"kind\":\"agent\",\"id\":\"\(agent)\"}}").status == .forbidden)
            #expect(accounts.agentReadCursor(agentId: agent, channelId: channelId).seq == message.seq)
            #expect(try await readAll(ownerToken, "{\"receiver\":{\"kind\":\"human\",\"id\":\"\(memberId)\"}}").status == .forbidden)
            #expect(accounts.oauth.channelUnreadInfo(channelId: channelId, userId: ownerId).maxReadSeq == 0)
        }
    }
}
