import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func firstChannelPostReturnsDriveByAttentionOnce() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001111001"
    let ownerId = "11111111-1111-4111-8111-000001111001"
    accounts.addAccount(id: ownerId, email: "attention-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "attention", name: "Attention", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "AttentionBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "attention-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "attention-room", humanIds: [ownerId], agentIds: [agentId])
    accounts.setAgentChannelJoinedAtForTesting(agentId: agentId, channelId: channelId, at: Date())
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "attention")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ body: [String: Any]) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
                    request.body = .init(data: data)
                }
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let first = try await send(["target": "#attention-room", "content": "first channel post"])
            #expect(first["state"] as? String == "sent")
            let attention = try #require((first["attention"] as? [String: Any])?["driveByJoinedToPost"] as? [String: Any])
            #expect(attention["reason"] as? String == "first_agent_message_with_recent_channel_join")
            #expect(attention["muteCommand"] as? String == "raft channel mute \"#attention-room\"")
            #expect(attention["stillArrives"] as? [String] == ["@mentions still reach you, and threads you started stay followed and keep delivering until you unfollow them."])

            let second = try await send(["target": "#attention-room", "content": "second channel post", "seenUpToSeq": first["messageSeq"] as? Int ?? 0])
            #expect(second["state"] as? String == "sent")
            #expect(second["attention"] == nil)
        }
    }
}

@Test func pendingMentionActionsAreSenderOnly() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001111002"
    let ownerId = "11111111-1111-4111-8111-000001111002"
    accounts.addAccount(id: ownerId, email: "pending-mention-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "pending-mention", name: "Pending Mention", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "PendingBot", creatorUserId: ownerId, runtime: "claude")
    let outsiderId = accounts.oauth.createAgent(serverId: serverId, name: "AgentApiMentionOutsider", creatorUserId: ownerId, runtime: "claude")
    _ = outsiderId
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "pending-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "pending-room", humanIds: [ownerId], agentIds: [agentId])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "pending")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            let body = try JSONSerialization.data(withJSONObject: ["target": "#pending-room", "content": "please coordinate with @AgentApiMentionOutsider", "seenUpToSeq": 0])
            let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
                request.body = .init(data: body)
            }
            let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(json["state"] as? String == "sent")
            let actions = try #require(json["pendingMentionActions"] as? [[String: Any]])
            #expect(actions.count == 1)
            let action = actions[0]
            #expect(action["messageId"] as? String == json["messageId"] as? String)
            #expect(action["targetType"] as? String == "agent")
            #expect(action["targetHandle"] as? String == "AgentApiMentionOutsider")
            #expect(action["reason"] as? String == "not_member")
            #expect(action["availableActions"] as? [String] == ["notify"])
        }
    }
}

@Test func hiddenTypedMentionAndDeletedAgentFailClosed() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001111003"
    let ownerId = "11111111-1111-4111-8111-000001111003"
    let hiddenId = "11111111-1111-4111-8111-000001111004"
    accounts.addAccount(id: ownerId, email: "hidden-owner@test.invalid", password: "password123")
    accounts.addAccount(id: hiddenId, email: "hidden-human@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: hiddenId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "hidden-send", name: "Hidden Send", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: hiddenId, role: "member")
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "HiddenSendBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "hidden-send-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "hidden-send-room", humanIds: [ownerId], agentIds: [agentId])
    accounts.setHideHumansFromMembers(serverId: serverId, hidden: true)
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "hidden")
    let hiddenName = "hidden-human"
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ body: [String: Any]) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/v2/send")) { request in
                    request.body = .init(data: data)
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let typed = try await send([
                "target": "#hidden-send-room", "content": "hidden human @\(hiddenName)",
                "mentions": [["type": "user", "id": hiddenId, "name": hiddenName]],
                "seenUpToSeq": 0,
            ])
            #expect(typed.1["state"] as? String == "sent")
            #expect(typed.1["pendingMentionActions"] == nil)
            #expect(typed.1["unresolvedMentionHandles"] == nil)
            #expect(accounts.mentionsForTesting(messageId: typed.1["messageId"] as? String ?? "").isEmpty)

            let raw = try await send(["target": "#hidden-send-room", "content": "hidden human raw @\(hiddenName)", "seenUpToSeq": typed.1["messageSeq"] as? Int ?? 0])
            #expect(raw.1["unresolvedMentionHandles"] as? [String] == ["@\(hiddenName)"])

            accounts.oauth.deleteAgent(id: agentId)
            let deleted = try await send(["target": "#hidden-send-room", "content": "deleted agent", "seenUpToSeq": raw.1["messageSeq"] as? Int ?? 0])
            #expect(deleted.0.status == .unauthorized)
            #expect(deleted.1["error"] as? String == "Invalid agent credential")
        }
    }
}
