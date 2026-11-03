import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct MentionActionFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let channelName: String
    let ownerId: String
    let ownerToken: String
    let agentId: String
    let agentKey: String
    let otherAgentId: String
    let targetAgentId: String
}

private func makeMentionActionFixture() -> MentionActionFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111637"
    let serverId = "33333333-3333-4333-8333-333333333677"
    accounts.addAccount(id: ownerId, email: "mention-actions@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "mention-actions", name: "Mention Actions", ownerId: ownerId)
    let channelName = "mention-actions-room"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "MentionSender", creatorUserId: ownerId)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    let otherAgentId = accounts.oauth.createAgent(serverId: serverId, name: "OtherSender", creatorUserId: ownerId)
    let targetAgentId = accounts.oauth.createAgent(serverId: serverId, name: "MentionTarget", creatorUserId: ownerId)
    return MentionActionFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channelId,
        channelName: channelName,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send"], name: "mention-actions"),
        otherAgentId: otherAgentId,
        targetAgentId: targetAgentId
    )
}

/// Posts a human message so pending mentions have a live host message.
@discardableResult
private func mentionHostMessage(
    _ client: any Client,
    _ f: MentionActionFixture,
    content: String = "host message",
    channelId: String? = nil
) async throws -> String {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.ownerToken)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = f.serverId
    let response = try await client.send(.post, headers: headers, to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(channelId ?? f.channelId)\",\"content\":\"\(content)\"}")
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return try #require(json["id"] as? String)
}

private func mentionActionsRequest(
    _ client: any Client,
    _ f: MentionActionFixture,
    method: HTTPRequest.Method,
    path: String,
    body: String? = nil
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.agentKey)"
    if body != nil { headers[.contentType] = "application/json" }
    let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@Test func mentionActionsPendingListsOnlyUnresolvedSenderOwnedRows() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let messageId = try await mentionHostMessage(client, f)
            let pendingId = f.accounts.addPendingAgentMentionForTesting(
                messageId: messageId, channelId: f.channelId, senderAgentId: f.agentId,
                targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget"
            )
            // A resolved row, another sender's row and a stale row are not pending.
            let resolvedMessageId = try await mentionHostMessage(client, f, content: "already notified")
            let notified = f.accounts.addPendingAgentMentionForTesting(
                messageId: resolvedMessageId, channelId: f.channelId, senderAgentId: f.agentId,
                targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget"
            )
            _ = f.accounts.addPendingAgentMentionForTesting(
                messageId: messageId, channelId: f.channelId, senderAgentId: f.otherAgentId,
                targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget"
            )
            _ = f.accounts.addPendingAgentMentionForTesting(
                messageId: messageId, channelId: f.channelId, senderAgentId: f.agentId,
                targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget",
                createdAt: Date().addingTimeInterval(-8 * 24 * 60 * 60)
            )
            _ = try await mentionActionsRequest(
                client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                body: "{\"action\":\"notify\",\"resolutionIds\":[\"\(notified)\"]}"
            )

            let res = try await mentionActionsRequest(client, f, method: .get, path: "/internal/agent-api/mention-actions/pending")
            #expect(res.status == .ok)
            let rows = (res.body["pendingMentionActions"] as? [[String: Any]]) ?? []
            #expect(rows.map { $0["resolutionId"] as? String } == [pendingId])
            let row = try #require(rows.first)
            #expect(row["messageId"] as? String == messageId)
            #expect(row["channelId"] as? String == f.channelId)
            #expect(row["channelName"] as? String == f.channelName)
            #expect(row["availableActions"] as? [String] == ["notify"])
            #expect(res.body["has_more"] as? Bool == false)
        }
    }
}

@Test func mentionActionsPendingUsesALimitPlusOneProbe() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let messageId = try await mentionHostMessage(client, f)
            var ids: [String] = []
            for index in 0..<51 {
                ids.append(f.accounts.addPendingAgentMentionForTesting(
                    messageId: messageId, channelId: f.channelId, senderAgentId: f.agentId,
                    targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget",
                    createdAt: Date().addingTimeInterval(TimeInterval(index))
                ))
            }
            let res = try await mentionActionsRequest(client, f, method: .get, path: "/internal/agent-api/mention-actions/pending")
            let rows = (res.body["pendingMentionActions"] as? [[String: Any]]) ?? []
            #expect(rows.count == 50)
            #expect(res.body["has_more"] as? Bool == true)
            #expect(rows.first?["resolutionId"] as? String == ids.last, "newest first")
        }
    }
}

@Test func mentionActionsNotifyWritesNotifiedFieldsWithoutAddingMembership() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let messageId = try await mentionHostMessage(client, f)
            let first = f.accounts.addPendingAgentMentionForTesting(
                messageId: messageId, channelId: f.channelId, senderAgentId: f.agentId,
                targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget"
            )
            let second = f.accounts.addPendingAgentMentionForTesting(
                messageId: messageId, channelId: f.channelId, senderAgentId: f.agentId,
                targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget"
            )
            let res = try await mentionActionsRequest(
                client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                body: "{\"action\":\"notify\",\"resolutionIds\":[\"\(first)\"]}"
            )
            #expect(res.status == .ok)
            let results = (res.body["results"] as? [[String: Any]]) ?? []
            #expect(results.first?["status"] as? String == "queued")
            let deduped = Set((results.first?["dedupedResolutionIds"] as? [String]) ?? [])
            #expect(deduped == Set([first, second]), "notify dedupes every unresolved row for the same target and message")
            #expect(f.accounts.mentionNotifiedActionForTesting(id: first) == "notify_only")
            #expect(f.accounts.mentionNotifiedActionForTesting(id: second) == "notify_only")
            #expect(!f.accounts.channelAgentIds(channelId: f.channelId).contains(f.targetAgentId), "notify never adds membership")
        }
    }
}

@Test func mentionActionsAddRefusesAgentSenders() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let messageId = try await mentionHostMessage(client, f)
            let id = f.accounts.addPendingAgentMentionForTesting(
                messageId: messageId, channelId: f.channelId, senderAgentId: f.agentId,
                targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget"
            )
            let res = try await mentionActionsRequest(
                client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                body: "{\"action\":\"add\",\"resolutionIds\":[\"\(id)\"]}"
            )
            let results = (res.body["results"] as? [[String: Any]]) ?? []
            #expect(results.first?["status"] as? String == "no_permission")
            #expect(results.first?["reason"] as? String == "add_requires_human_member_authority")
            #expect(results.first?["dedupedResolutionIds"] == nil)
            #expect(f.accounts.mentionNotifiedActionForTesting(id: id) == nil, "refused add writes nothing")
            #expect(!f.accounts.channelAgentIds(channelId: f.channelId).contains(f.targetAgentId))
        }
    }
}

@Test func mentionActionsExecuteRevalidatesSenderAccessAndDeletedMessages() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let messageId = try await mentionHostMessage(client, f)
            let id = f.accounts.addPendingAgentMentionForTesting(
                messageId: messageId, channelId: f.channelId, senderAgentId: f.agentId,
                targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget"
            )
            // The sender loses access to the channel: add is refused before the
            // authority check, with the channel-access reason.
            f.accounts.oauth.removeChannelAgent(channelId: f.channelId, agentId: f.agentId)
            let denied = try await mentionActionsRequest(
                client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                body: "{\"action\":\"add\",\"resolutionIds\":[\"\(id)\"]}"
            )
            let deniedResults = (denied.body["results"] as? [[String: Any]]) ?? []
            #expect(deniedResults.first?["reason"] as? String == "sender_lacks_channel_access")
            #expect(f.accounts.mentionNotifiedActionForTesting(id: id) == nil)

            // Unknown ids and rows whose host message disappeared are typed
            // not_found instead of failing the batch.
            f.accounts.removeMessageForTesting(messageId: messageId)
            let missing = try await mentionActionsRequest(
                client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                body: "{\"action\":\"notify\",\"resolutionIds\":[\"\(id)\",\"\(UUID().uuidString.lowercased())\"]}"
            )
            let missingResults = (missing.body["results"] as? [[String: Any]]) ?? []
            #expect(missingResults.allSatisfy { $0["status"] as? String == "not_found" })

            let pending = try await mentionActionsRequest(client, f, method: .get, path: "/internal/agent-api/mention-actions/pending")
            #expect(((pending.body["pendingMentionActions"] as? [[String: Any]]) ?? []).isEmpty, "deleted messages cascade out of pending")
        }
    }
}

@Test func mentionActionsRejectInvalidBatches() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let badAction = try await mentionActionsRequest(
                client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                body: "{\"action\":\"shrug\",\"resolutionIds\":[\"x\"]}"
            )
            #expect(badAction.status == .badRequest)
            let empty = try await mentionActionsRequest(
                client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                body: "{\"action\":\"notify\",\"resolutionIds\":[]}"
            )
            #expect(empty.status == .badRequest)
        }
    }
}
