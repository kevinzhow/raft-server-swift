import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func v2SendBindsTypedMentionsAndV1KeepsRawHandles() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001107001"
    let ownerId = "11111111-1111-4111-8111-000001107001"
    let humanId = "11111111-1111-4111-8111-000001107002"
    for (id, name) in [(ownerId, "owner"), (humanId, "same_handle")] {
        accounts.addAccount(id: id, email: "\(name)@test.invalid", password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "mention-bind", name: "Mention Bind", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: humanId, role: "member")
    let senderAgentId = accounts.oauth.createAgent(serverId: serverId, name: "SenderBot", creatorUserId: ownerId, runtime: "claude")
    let otherAgentId = accounts.oauth.createAgent(serverId: serverId, name: "same_handle", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "bind-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "bind-room", humanIds: [ownerId], agentIds: [senderAgentId])
    let key = accounts.mintAgentCredential(agentId: senderAgentId, scopes: ["send", "read"], name: "bind")

    #expect(accounts.oauth.memberRole(serverId: serverId, userId: humanId) != nil)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ path: String, _ body: [String: Any]) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(data: data)
                }
                let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                return (response, json)
            }
            let v1 = try await send("/internal/agent-api/send", [
                "target": "#bind-room", "content": "v1 @same_handle",
                "mentions": [["type": "agent", "id": otherAgentId, "name": "same_handle"]],
            ])
            #expect(v1.1["state"] as? String == "sent")
            #expect(v1.1["unresolvedMentionHandles"] == nil)
            let v1Rows = accounts.mentionsForTesting(messageId: v1.1["messageId"] as? String ?? "")
            #expect(Set(v1Rows.map { "\($0.targetType):\($0.targetId)" }) == ["user:\(humanId)", "agent:\(otherAgentId)"])

            let ambiguous = try await send("/internal/agent-api/v2/send", ["target": "#bind-room", "content": "hello @same_handle", "idempotencyKey": "raw-same-handle"])
            #expect(ambiguous.1["state"] as? String == "sent")
            #expect(ambiguous.1["unresolvedMentionHandles"] as? [String] == ["@same_handle"])
            #expect(accounts.mentionsForTesting(messageId: ambiguous.1["messageId"] as? String ?? "").isEmpty)

            let human = try await send("/internal/agent-api/v2/send", [
                "target": "#bind-room", "content": "human @same_handle",
                "mentions": [["type": "user", "id": humanId, "name": "same_handle"]], "idempotencyKey": "typed-human",
            ])
            #expect(human.1["state"] as? String == "sent")
            let humanRows = accounts.mentionsForTesting(messageId: human.1["messageId"] as? String ?? "")
            #expect(humanRows.map { "\($0.targetType):\($0.targetId)" } == ["user:\(humanId)"])

            let agent = try await send("/internal/agent-api/v2/send", [
                "target": "#bind-room", "content": "agent @same_handle",
                "mentions": [["type": "agent", "id": otherAgentId, "name": "same_handle"]], "idempotencyKey": "typed-agent",
            ])
            #expect(agent.1["state"] as? String == "sent")
            #expect(accounts.mentionsForTesting(messageId: agent.1["messageId"] as? String ?? "").map { "\($0.targetType):\($0.targetId)" } == ["agent:\(otherAgentId)"])

            let conflict = try await send("/internal/agent-api/v2/send", [
                "target": "#bind-room", "content": "conflict @same_handle",
                "mentions": [
                    ["type": "user", "id": humanId, "name": "same_handle"],
                    ["type": "agent", "id": otherAgentId, "name": "same_handle"],
                ], "idempotencyKey": "typed-conflict",
            ])
            #expect(conflict.0.status == .badRequest)
            #expect(conflict.1["code"] as? String == "mention_binding_conflict")
        }
    }
}
