import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func selfCausedNoticesExemptOnlyTheAllowlistedKind() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001116001"
    let ownerId = "11111111-1111-4111-8111-000001116001"
    accounts.addAccount(id: ownerId, email: "notice-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "notice-fresh", name: "Notice Fresh", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "NoticeBot", creatorUserId: ownerId, runtime: "claude")
    let otherAgentId = accounts.oauth.createAgent(serverId: serverId, name: "OtherNoticeBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "notice-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "notice-room", humanIds: [ownerId], agentIds: [agentId, otherAgentId])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "notice-fresh")
    let baseline = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "baseline")
    let baselineSeq = accounts.messageSeqForTesting(messageId: baseline) ?? 0
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ content: String) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: ["target": "#notice-room", "content": content, "seenUpToSeq": baselineSeq])
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
                    request.body = .init(data: data)
                }
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            _ = accounts.addSystemNoticeForTesting(channelId: channelId, subtype: "task.created_summary", content: "own summary", causalActorType: "agent", causalActorId: agentId)
            let ownExempt = try await send("after own exempt")
            #expect(ownExempt["state"] as? String == "sent")

            _ = accounts.addSystemNoticeForTesting(channelId: channelId, subtype: "task.created_summary", content: "other summary", causalActorType: "agent", causalActorId: otherAgentId)
            let otherHeld = try await send("after other summary")
            #expect(otherHeld["state"] as? String == "held")
            #expect(otherHeld["newMessageCount"] as? Int == 1)

            _ = accounts.addSystemNoticeForTesting(channelId: channelId, subtype: "task.created_summary", content: "actorless")
            let actorless = try await send("after actorless")
            #expect(actorless["state"] as? String == "held")

            _ = accounts.addSystemNoticeForTesting(channelId: channelId, subtype: "task.created_summary", content: "human summary", causalActorType: "human", causalActorId: ownerId)
            let human = try await send("after human summary")
            #expect(human["state"] as? String == "held")

            _ = accounts.addSystemNoticeForTesting(channelId: channelId, subtype: "task.lifecycle_thread", content: "own lifecycle", causalActorType: "agent", causalActorId: agentId)
            let ownLifecycle = try await send("after own lifecycle")
            #expect(ownLifecycle["state"] as? String == "held")
        }
    }
}

@Test func threadSelfCausedNoticesKeepLifecycleHolding() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001116002"
    let ownerId = "11111111-1111-4111-8111-000001116002"
    accounts.addAccount(id: ownerId, email: "notice-thread-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "notice-thread", name: "Notice Thread", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "ThreadNoticeBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "notice-thread-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "notice-thread-room", humanIds: [ownerId], agentIds: [agentId])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "notice-thread")
    let parent = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "thread parent")
    let parentSeq = accounts.messageSeqForTesting(messageId: parent) ?? 0
    let threadId = accounts.oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parent)
    accounts.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: channelId, parentMessageId: parent, memberId: agentId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ content: String) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: ["target": "#notice-thread-room:\(parent.prefix(8))", "content": content, "seenUpToSeq": parentSeq])
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
                    request.body = .init(data: data)
                }
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            _ = accounts.addSystemNoticeForTesting(channelId: threadId, subtype: "task.created_summary", content: "own exempt", causalActorType: "agent", causalActorId: agentId)
            let exempt = try await send("after own exempt")
            #expect(exempt["state"] as? String == "sent")

            _ = accounts.addSystemNoticeForTesting(channelId: threadId, subtype: "task.lifecycle_thread", content: "own lifecycle", causalActorType: "agent", causalActorId: agentId)
            let lifecycle = try await send("after own lifecycle")
            #expect(lifecycle["state"] as? String == "held")
        }
    }
}

@Test func seenHumanCausedNoticeDoesNotHold() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001116003"
    let ownerId = "11111111-1111-4111-8111-000001116003"
    accounts.addAccount(id: ownerId, email: "notice-seen-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "notice-seen", name: "Notice Seen", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "SeenNoticeBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "notice-seen-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "notice-seen-room", humanIds: [ownerId], agentIds: [agentId])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "notice-seen")
    let notice = accounts.addSystemNoticeForTesting(channelId: channelId, subtype: "task.created_summary", content: "human summary", causalActorType: "human", causalActorId: ownerId)
    let noticeSeq = accounts.messageSeqForTesting(messageId: notice) ?? 0
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            let data = try JSONSerialization.data(withJSONObject: ["target": "#notice-seen-room", "content": "seen human notice", "seenUpToSeq": noticeSeq])
            let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/send")) { request in
                request.body = .init(data: data)
            }
            let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(json["state"] as? String == "sent")
        }
    }
}
