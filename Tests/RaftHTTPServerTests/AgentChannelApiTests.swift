import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentResolvesAndCreatesChannels() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111498"
    let serverId = "33333333-3333-4333-8333-333333333594"
    accounts.addAccount(id: ownerId, email: "agent-channel-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-channel", name: "Agent Channel", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "agent-api-channel", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "agent-api-channel")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "channel-agent")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["channels", "read", "send"], name: "channel-api")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            let resolve = try await client.send(.post, headers: headers, to: "/internal/agent-api/resolve-channel") { request in
                request.body = .init(string: "{\"target\":\"#agent-api-channel\"}")
            }
            #expect(resolve.status == .ok)
            let resolveBody = try JSONSerialization.jsonObject(with: Data((resolve.body.string ?? "").utf8)) as? [String: Any]
            #expect(resolveBody?["channelId"] as? String == channel)

            let create = try await client.send(.post, headers: headers, to: "/internal/agent-api/channels") { request in
                request.body = .init(string: "{\"name\":\"agent-api-member-create\"}")
            }
            #expect(create.status == .ok)
            let createBody = try JSONSerialization.jsonObject(with: Data((create.body.string ?? "").utf8)) as? [String: Any]
            let createdId = createBody?["id"] as? String ?? ""
            #expect(!createdId.isEmpty)
            #expect(accounts.oauth.channelAgentIds(channelId: createdId).contains(agent))
            #expect(!accounts.oauth.channelHumanIds(channelId: createdId).contains(agent))
            #expect(createBody?["type"] as? String == "channel")
            #expect(createBody?["createdByAgentId"] as? String == agent)

            let privateCreate = try await client.send(.post, headers: headers, to: "/internal/agent-api/channels") { request in
                request.body = .init(string: "{\"name\":\"agent-api-private-create\",\"visibility\":\"private\"}")
            }
            #expect(privateCreate.status == .ok)
            let privateBody = try JSONSerialization.jsonObject(with: Data((privateCreate.body.string ?? "").utf8)) as? [String: Any]
            #expect(privateBody?["type"] as? String == "private")
            let privateId = privateBody?["id"] as? String ?? ""
            #expect(accounts.oauth.channelType(id: privateId) == "private")

            let invalid = try await client.send(.post, headers: headers, to: "/internal/agent-api/channels") { request in
                request.body = .init(string: "{\"name\":\"Bad Name\"}")
            }
            #expect(invalid.status == .badRequest)
        }
    }
}
