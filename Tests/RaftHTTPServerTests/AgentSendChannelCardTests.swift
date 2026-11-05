import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func sendHoldsOnlyForAnUnseenChannelCardTheClientNamed() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001109001"
    let ownerId = "11111111-1111-4111-8111-000001109001"
    accounts.addAccount(id: ownerId, email: "card-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "card-send", name: "Card Send", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "CardBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "card-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "card-room", humanIds: [ownerId], agentIds: [agentId])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "card")
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
            let plain = try await send(["target": "#card-room", "content": "no card field"])
            #expect(plain.1["state"] as? String == "sent")
            #expect(plain.1["channelCard"] == nil)
            let plainSeq = try #require(plain.1["messageSeq"] as? Int)
            let before = accounts.messageCountForTesting(channelId: channelId)

            let unseen = try await send(["target": "#card-room", "content": "first post", "seenUpToSeq": plainSeq, "seenCards": ["channel": NSNull()]])
            #expect(unseen.1["state"] as? String == "held")
            #expect(unseen.1["holdReasons"] as? [String] == ["channel_card"])
            #expect(unseen.1["newMessageCount"] as? Int == 0)
            #expect((unseen.1["channelCard"] as? [String: Any])?["id"] as? String == channelId)
            #expect(unseen.1["channelCardChanged"] == nil)
            #expect(accounts.messageCountForTesting(channelId: channelId) == before)

            let rev = try #require(accounts.channelCardRevisionForTesting(channelId: channelId))

            let seen = try await send(["target": "#card-room", "content": "card seen", "seenUpToSeq": plainSeq, "seenCards": ["channel": rev]])
            #expect(seen.1["state"] as? String == "sent")
            #expect(seen.1["channelCard"] == nil)
            let seenSeq = try #require(seen.1["messageSeq"] as? Int)

            accounts.oauth.setChannelArchived(id: channelId, archivedAt: Date())
            let changed = try await send(["target": "#card-room", "content": "card changed", "seenUpToSeq": seenSeq, "seenCards": ["channel": rev]])
            #expect(changed.1["state"] as? String == "sent")
            #expect((changed.1["channelCard"] as? [String: Any])?["archived"] as? Bool == true)
            #expect(changed.1["channelCardChanged"] as? Bool == true)
        }
    }
}

@Test func unreadMessagesAndAnUnseenCardShareOneHold() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001109002"
    let ownerId = "11111111-1111-4111-8111-000001109002"
    accounts.addAccount(id: ownerId, email: "combined-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "card-combined", name: "Card Combined", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "CardCombinedBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "combined-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "combined-room", humanIds: [ownerId], agentIds: [agentId])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "combined")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ body: [String: Any]) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/v2/send")) { request in
                    request.body = .init(data: data)
                }
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let first = try await send(["target": "#combined-room", "content": "before"])
            _ = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "news the agent has not seen")
            let held = try await send([
                "target": "#combined-room", "content": "reply",
                "seenUpToSeq": first["messageSeq"] as? Int ?? 0,
                "seenCards": ["channel": NSNull()],
            ])
            #expect(held["state"] as? String == "held")
            #expect(held["holdReasons"] as? [String] == ["unread_messages", "channel_card"])
            #expect(held["newMessageCount"] as? Int == 1)
            #expect((held["channelCard"] as? [String: Any])?["id"] as? String == channelId)
            #expect((held["heldMessages"] as? [[String: Any]])?.first?["content"] as? String == "news the agent has not seen")
        }
    }
}

@Test func anywayAndIdempotentRetryAreNotHeldForTheCard() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001109003"
    let ownerId = "11111111-1111-4111-8111-000001109003"
    accounts.addAccount(id: ownerId, email: "card-anyway@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "card-anyway", name: "Card Anyway", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "CardAnywayBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "anyway-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "anyway-room", humanIds: [ownerId], agentIds: [agentId])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "anyway")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ body: [String: Any]) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/v2/send")) { request in
                    request.body = .init(data: data)
                }
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let anyway = try await send(["target": "#anyway-room", "content": "anyway", "sendDraft": true, "continueAnyway": true, "seenCards": ["channel": NSNull()]])
            #expect(anyway["state"] as? String == "sent")
            #expect((anyway["channelCard"] as? [String: Any])?["id"] as? String == channelId)
            #expect(anyway["channelCardChanged"] == nil)

            let idempotencyKey = UUID().uuidString
            let original = try await send(["target": "#anyway-room", "content": "once", "idempotencyKey": idempotencyKey, "seenUpToSeq": anyway["messageSeq"] as? Int ?? 0])
            #expect(original["state"] as? String == "sent")
            let retry = try await send(["target": "#anyway-room", "content": "once", "idempotencyKey": idempotencyKey, "seenUpToSeq": anyway["messageSeq"] as? Int ?? 0, "seenCards": ["channel": NSNull()]])
            #expect(retry["state"] as? String == "sent")
            #expect(retry["messageId"] as? String == original["messageId"] as? String)
        }
    }
}

@Test func threadSendAcceptsTheParentCardVersion() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001109004"
    let ownerId = "11111111-1111-4111-8111-000001109004"
    accounts.addAccount(id: ownerId, email: "card-thread@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "card-thread", name: "Card Thread", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "CardThreadBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "card-thread-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "card-thread-room", humanIds: [ownerId], agentIds: [agentId])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "card-thread")
    let parent = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "thread root")
    let parentSeq = accounts.messageSeqForTesting(messageId: parent) ?? 0
    let rev = accounts.channelCardRevisionForTesting(channelId: channelId) ?? ""
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ body: [String: Any]) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/v2/send")) { request in
                    request.body = .init(data: data)
                }
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let target = "#card-thread-room:\(parent.prefix(8))"
            let unseen = try await send(["target": target, "content": "in thread", "seenUpToSeq": parentSeq, "seenCards": ["channel": NSNull()]])
            #expect(unseen["state"] as? String == "held")
            #expect(unseen["holdReasons"] as? [String] == ["channel_card"])
            #expect((unseen["channelCard"] as? [String: Any])?["id"] as? String == channelId)

            let seen = try await send(["target": target, "content": "in thread", "seenUpToSeq": parentSeq, "seenCards": ["channel": rev]])
            #expect(seen["state"] as? String == "sent")
            #expect(seen["channelCard"] == nil)
        }
    }
}
