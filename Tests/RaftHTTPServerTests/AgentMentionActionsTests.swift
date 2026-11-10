import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
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
    let otherAgentKey: String
    let targetAgentId: String
    let targetHumanId: String
}

private func makeMentionActionFixture() -> MentionActionFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111637"
    let humanId = "11111111-1111-4111-8111-111111111638"
    let serverId = "33333333-3333-4333-8333-333333333677"
    for (id, name) in [(ownerId, "MentionOwner"), (humanId, "MentionHuman")] {
        accounts.addAccount(id: id, email: "\(name)@slock.test", password: "password123")
        accounts.setAccountProfileForTesting(id: id, name: name)
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "mention-actions", name: "Mention Actions", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: humanId, role: "member")
    let channelName = "mention-actions-room"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "MentionSender", creatorUserId: ownerId)
    let otherAgentId = accounts.oauth.createAgent(serverId: serverId, name: "OtherSender", creatorUserId: ownerId)
    let targetAgentId = accounts.oauth.createAgent(serverId: serverId, name: "MentionTarget", creatorUserId: ownerId)
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: channelName,
        humanIds: [ownerId], agentIds: [agentId, otherAgentId])
    return MentionActionFixture(accounts: accounts, serverId: serverId, channelId: channelId, channelName: channelName,
        ownerId: ownerId, ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId), agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send", "mentions"], name: "mention-actions"),
        otherAgentId: otherAgentId,
        otherAgentKey: accounts.mintAgentCredential(agentId: otherAgentId, scopes: ["read", "send", "mentions"], name: "mention-actions-other"),
        targetAgentId: targetAgentId, targetHumanId: humanId)
}

/// Every host and resolution is produced by the registered agent send route.
private func mentionHostMessage(
    _ client: any Client, _ f: MentionActionFixture, content: String = "host @MentionHuman",
    target: String? = nil, agentKey: String? = nil, targetType: String = "user",
    targetId: String? = nil, handle: String = "MentionHuman", v2: Bool = false
) async throws -> (messageId: String, resolutionId: String, messageSeq: Int, pending: [String: Any]) {
    let response = try await mentionActionsRequest(client, f, method: .post,
        path: v2 ? "/internal/agent-api/v2/send" : "/internal/agent-api/send", agentKey: agentKey,
        object: ["target": target ?? "#\(f.channelName)", "content": content,
            "mentions": [["type": targetType, "id": targetId ?? f.targetHumanId, "name": handle]]])
    #expect(response.status == .ok)
    #expect(response.body["state"] as? String == "sent")
    let messageId = try #require(response.body["messageId"] as? String)
    let messageSeq = try #require(response.body["messageSeq"] as? Int)
    let pending = try #require((response.body["pendingMentionActions"] as? [[String: Any]])?.first)
    let resolutionId = try #require(pending["resolutionId"] as? String)
    #expect(pending["messageId"] as? String == messageId)
    let retained = try #require(f.accounts.messagesAndThreadsStore.state.storedMentions.first { $0.id == resolutionId })
    #expect(retained.messageId == messageId)
    #expect(retained.senderId == (agentKey == f.otherAgentKey ? f.otherAgentId : f.agentId))
    #expect(retained.targetType == targetType)
    #expect(retained.targetId == (targetId ?? f.targetHumanId))
    #expect(retained.notifiableAtSend == false)
    return (messageId, resolutionId, messageSeq, pending)
}

private func mentionActionsRequest(
    _ client: any Client, _ f: MentionActionFixture, method: HTTPRequest.Method, path: String,
    body: String? = nil, agentKey: String? = nil, object: [String: Any]? = nil
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(agentKey ?? f.agentKey)"
    let data = try object.map { try JSONSerialization.data(withJSONObject: $0) }
    if body != nil || data != nil { headers[.contentType] = "application/json" }
    let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let data { request.body = .init(data: data) }
        else if let body { request.body = .init(string: body) }
    }
    let json = try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
    return (response.status, json)
}

private func mentionActionResult(_ response: (status: HTTPResponse.Status, body: [String: Any])) throws -> [String: Any] {
    #expect(response.status == .ok)
    #expect(response.body["ok"] as? Bool == true)
    return try #require((response.body["results"] as? [[String: Any]])?.first)
}

@Test func mentionActionsPendingListsOnlyUnresolvedSenderOwnedRows() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            // Resolve this real host before creating the later pending host: grouping
            // legitimately spans messages, so ordering is part of the fixture.
            let notified = try await mentionHostMessage(client, f)
            let resolved = try await mentionActionsRequest(client, f, method: .post,
                path: "/internal/agent-api/mention-actions/execute",
                object: ["action": "notify", "resolutionIds": [notified.resolutionId]])
            #expect(try mentionActionResult(resolved)["status"] as? String == "queued")
            let pending = try await mentionHostMessage(client, f)
            let foreign = try await mentionHostMessage(client, f, agentKey: f.otherAgentKey)
            #expect(Set([notified.messageId, pending.messageId, foreign.messageId]).count == 3)
            let response = try await mentionActionsRequest(client, f, method: .get, path: "/internal/agent-api/mention-actions/pending")
            #expect(response.status == .ok)
            let rows = (response.body["pendingMentionActions"] as? [[String: Any]]) ?? []
            #expect(rows.map { $0["resolutionId"] as? String } == [pending.resolutionId])
            let row = try #require(rows.first)
            #expect(Set(row.keys) == ["resolutionId", "messageId", "messageSeq", "channelId", "channelName", "targetType", "targetId", "targetHandle", "reason", "availableActions", "createdAt", "expiresAt"])
            #expect(row["messageId"] as? String == pending.messageId)
            #expect(row["messageSeq"] as? Int == pending.messageSeq)
            #expect(row["channelId"] as? String == f.channelId)
            #expect(row["channelName"] as? String == f.channelName)
            #expect(row["targetType"] as? String == "user")
            #expect(row["targetId"] as? String == f.targetHumanId)
            #expect(row["targetHandle"] as? String == "MentionHuman")
            #expect(row["reason"] as? String == "not_member")
            #expect(row["availableActions"] as? [String] == ["notify"])
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let createdText = try #require(row["createdAt"] as? String)
            let created = try #require(formatter.date(from: createdText))
            let expiresText = try #require(row["expiresAt"] as? String)
            let expires = try #require(formatter.date(from: expiresText))
            #expect(abs(expires.timeIntervalSince(created) - 7 * 24 * 60 * 60) < 0.01)
            #expect(response.body["has_more"] as? Bool == false)
        }
    }
}

@Test func mentionActionsPendingUsesALimitPlusOneProbe() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            var ids: [String] = []
            var messageIds: [String] = []
            for index in 0..<51 {
                let sent = try await mentionHostMessage(client, f, content: "page \(index) @MentionHuman", v2: index.isMultiple(of: 2))
                ids.append(sent.resolutionId)
                messageIds.append(sent.messageId)
            }
            #expect(Set(ids).count == 51)
            #expect(Set(messageIds).count == 51)
            let response = try await mentionActionsRequest(client, f, method: .get, path: "/internal/agent-api/mention-actions/pending")
            let rows = (response.body["pendingMentionActions"] as? [[String: Any]]) ?? []
            #expect(response.status == .ok)
            #expect(rows.count == 50)
            #expect(response.body["has_more"] as? Bool == true)
            #expect(Set(rows.compactMap { $0["resolutionId"] as? String }) == Set(ids.suffix(50)))
            #expect(Set(rows.compactMap { $0["messageId"] as? String }) == Set(messageIds.suffix(50)))
            let retained = f.accounts.messagesAndThreadsStore.state.storedMentions
            let created = try rows.map { row in
                let id = try #require(row["resolutionId"] as? String)
                return try #require(retained.first { $0.id == id }).createdAt
            }
            #expect(zip(created, created.dropFirst()).allSatisfy { $0.0 >= $0.1 }, "the page must remain newest first")
            #expect(created.first == retained.filter { ids.contains($0.id) }.map(\.createdAt).max())
            for (query, count, more) in [("20", 20, true), ("2", 2, true), ("-5", 1, true), ("0", 50, true), ("200", 51, false), ("Infinity", 51, false), ("-Infinity", 1, true), ("not-a-number", 50, true), ("inf", 50, true), ("infinity", 50, true), ("INF", 50, true), ("0x14", 20, true), ("0b10", 2, true), ("0o24", 20, true)] {
                let page = try await mentionActionsRequest(client, f, method: .get,
                    path: "/internal/agent-api/mention-actions/pending?limit=\(query)")
                #expect(page.status == .ok)
                let selected = try #require(page.body["pendingMentionActions"] as? [[String: Any]])
                #expect(selected.count == count, "query=\(query)")
                #expect(page.body["has_more"] as? Bool == more)
                let dates = try selected.map { row in
                    let id = try #require(row["resolutionId"] as? String)
                    return try #require(retained.first { $0.id == id }).createdAt
                }
                #expect(zip(dates, dates.dropFirst()).allSatisfy { $0.0 >= $0.1 })
            }
        }
    }
}

@Test func mentionActionsNotifyWritesNotifiedFieldsWithoutAddingMembership() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let first = try await mentionHostMessage(client, f)
            let second = try await mentionHostMessage(client, f, v2: true)
            #expect(first.messageId != second.messageId)
            #expect(first.resolutionId != second.resolutionId)
            let response = try await mentionActionsRequest(client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                object: ["action": "notify", "resolutionIds": [first.resolutionId]])
            let result = try mentionActionResult(response)
            #expect(result["status"] as? String == "queued")
            #expect(result["reason"] == nil)
            #expect(result["messageId"] as? String == first.messageId)
            #expect(result["channelId"] as? String == f.channelId)
            #expect(result["targetType"] as? String == "user")
            #expect(result["targetId"] as? String == f.targetHumanId)
            let deduped = Set((result["dedupedResolutionIds"] as? [String]) ?? [])
            #expect(deduped == Set([first.resolutionId, second.resolutionId]), "Node groups two actual messages by server/channel/target/real actor")
            #expect(f.accounts.mentionNotifiedActionForTesting(id: first.resolutionId) == "notify_only")
            #expect(f.accounts.mentionNotifiedActionForTesting(id: second.resolutionId) == "notify_only")
            #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetHumanId), "notify never adds membership")
            let replay = try await mentionActionsRequest(client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                object: ["action": "notify", "resolutionIds": [first.resolutionId, first.resolutionId]])
            let replayRows = try #require(replay.body["results"] as? [[String: Any]])
            #expect(replayRows.count == 1)
            #expect(replayRows.first?["status"] as? String == "queued")
            #expect(replayRows.first?["reason"] as? String == "already_queued")
            #expect(replayRows.first?["dedupedResolutionIds"] as? [String] == [first.resolutionId])
            let add = try await mentionActionsRequest(client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                object: ["action": "add", "resolutionIds": [first.resolutionId]])
            #expect(try mentionActionResult(add)["reason"] as? String == "add_requires_human_member_authority")
            #expect(f.accounts.mentionNotifiedActionForTesting(id: first.resolutionId) == "notify_only")
            #expect(f.accounts.mentionNotifiedActionForTesting(id: second.resolutionId) == "notify_only")
            #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetHumanId))
        }
    }
}

@Test func mentionActionsNotifyCloaksPrivateThreadContentFromNonMembers() async throws {
    let f = makeMentionActionFixture()
    let parent = f.accounts.oauth.createChannel(serverId: f.serverId, name: "mention-actions-closing", creatorUserId: f.ownerId)
    f.accounts.seedPostableChannelForTesting(serverId: f.serverId, channelId: parent, name: "mention-actions-closing",
        humanIds: [f.ownerId], agentIds: [f.agentId])
    let parentMessage = f.accounts.addHumanMessageForTesting(channelId: parent, senderId: f.ownerId, content: "actual public parent")
    let threadId = f.accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: parentMessage)
    f.accounts.addThreadChannel(serverId: f.serverId, threadChannelId: threadId, parentChannelId: parent, parentMessageId: parentMessage, memberId: f.ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let sent = try await mentionHostMessage(client, f, content: "before privacy transition @MentionTarget",
                target: "#mention-actions-closing:\(threadId.prefix(8))", targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget")
            #expect(f.accounts.oauth.setChannelType(id: parent, type: "private"))
            f.accounts.setChannelPostablePrivateForTesting(channelId: parent)
            let response = try await mentionActionsRequest(client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                object: ["action": "notify", "resolutionIds": [sent.resolutionId]])
            let result = try mentionActionResult(response)
            #expect(result["status"] as? String == "no_permission")
            #expect(result["reason"] as? String == "target_lacks_read_access", "real retained thread reply rechecks its now-private parent")
            #expect(f.accounts.mentionNotifiedActionForTesting(id: sent.resolutionId) == nil)
            #expect(!f.accounts.oauth.channelAgentIds(channelId: parent).contains(f.targetAgentId))
            #expect(f.accounts.agentDeliveries(agentId: f.targetAgentId).isEmpty)
        }
    }
}

@Test func mentionActionsAddRefusesAgentSenders() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let sent = try await mentionHostMessage(client, f, content: "add @MentionTarget", targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget")
            let response = try await mentionActionsRequest(client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                object: ["action": "add", "resolutionIds": [sent.resolutionId]])
            let result = try mentionActionResult(response)
            #expect(result["status"] as? String == "no_permission")
            #expect(result["reason"] as? String == "add_requires_human_member_authority")
            #expect(result["dedupedResolutionIds"] == nil)
            #expect(f.accounts.mentionNotifiedActionForTesting(id: sent.resolutionId) == nil, "refused add writes nothing")
            #expect(!f.accounts.oauth.channelAgentIds(channelId: f.channelId).contains(f.targetAgentId))
        }
    }
}

@Test func mentionActionsExecuteRevalidatesSenderAccessAndDeletedMessages() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let sent = try await mentionHostMessage(client, f, content: "access @MentionTarget", targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget")
            f.accounts.oauth.removeChannelAgent(channelId: f.channelId, agentId: f.agentId)
            f.accounts.removeChannelMember(channelId: f.channelId, memberId: f.agentId)
            let denied = try await mentionActionsRequest(client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                object: ["action": "add", "resolutionIds": [sent.resolutionId]])
            #expect(try mentionActionResult(denied)["reason"] as? String == "sender_lacks_channel_access")
            #expect(f.accounts.mentionNotifiedActionForTesting(id: sent.resolutionId) == nil)
            f.accounts.removeMessageForTesting(messageId: sent.messageId)
            let missing = try await mentionActionsRequest(client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                object: ["action": "notify", "resolutionIds": [sent.resolutionId, UUID().uuidString.lowercased()]])
            let missingResults = try #require(missing.body["results"] as? [[String: Any]])
            #expect(missingResults.count == 2)
            #expect(missingResults.allSatisfy { $0["status"] as? String == "not_found" })
            #expect(missingResults.allSatisfy { $0["messageId"] == nil && $0["channelId"] == nil && $0["targetType"] == nil && $0["targetId"] == nil })
            let pending = try await mentionActionsRequest(client, f, method: .get, path: "/internal/agent-api/mention-actions/pending")
            #expect(((pending.body["pendingMentionActions"] as? [[String: Any]]) ?? []).isEmpty, "deleted messages cascade out of pending")
        }
    }
}

@Test func mentionActionsAgentTargetWithoutQueueStaysUnclaimed() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for v2 in [false, true] {
                let sent = try await mentionHostMessage(client, f, content: "no executor @MentionTarget", targetType: "agent", targetId: f.targetAgentId, handle: "MentionTarget", v2: v2)
                let response = try await mentionActionsRequest(client, f, method: .post, path: "/internal/agent-api/mention-actions/execute",
                    object: ["action": "notify", "resolutionIds": [sent.resolutionId]])
                let result = try mentionActionResult(response)
                #expect(result["status"] as? String == "dropped")
                #expect(result["reason"] as? String == "delivery_unavailable")
                #expect(result["dedupedResolutionIds"] == nil)
                #expect(f.accounts.mentionNotifiedActionForTesting(id: sent.resolutionId) == nil)
                #expect(!f.accounts.oauth.channelAgentIds(channelId: f.channelId).contains(f.targetAgentId))
                #expect(f.accounts.agentDeliveries(agentId: f.targetAgentId).isEmpty)
            }
        }
    }
}

@Test func mentionActionsRejectInvalidBatches() async throws {
    let f = makeMentionActionFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let badAction = try await mentionActionsRequest(client, f, method: .post, path: "/internal/agent-api/mention-actions/execute", body: "{\"action\":\"shrug\",\"resolutionIds\":[\"x\"]}")
            #expect(badAction.status == .badRequest)
            let empty = try await mentionActionsRequest(client, f, method: .post, path: "/internal/agent-api/mention-actions/execute", body: "{\"action\":\"notify\",\"resolutionIds\":[]}")
            #expect(empty.status == .badRequest)
        }
    }
}

@Test func mentionActionsRequireLiveMentionsCapabilityBeforeQueryOrBodyValidation() async throws {
    let f = makeMentionActionFixture()
    let readOnly = f.accounts.mintAgentCredential(agentId: f.agentId, scopes: ["read"], name: "read-only")
    let sendOnly = f.accounts.mintAgentCredential(agentId: f.agentId, scopes: ["send"], name: "send-only")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let sent = try await mentionHostMessage(client, f)
            for key in [readOnly, sendOnly] {
                for (method, path, body) in [(HTTPRequest.Method.get, "/internal/agent-api/mention-actions/pending?limit=not-a-number", Optional<String>.none),
                    (HTTPRequest.Method.post, "/internal/agent-api/mention-actions/execute", "{}" as String?)] {
                    let denied = try await mentionActionsRequest(client, f, method: method, path: path, body: body, agentKey: key)
                    #expect(denied.status == .forbidden)
                    #expect(denied.body["code"] as? String == "capability_not_authorized")
                    #expect(denied.body["requiredCapability"] as? String == "mentions")
                    #expect(denied.body["pendingMentionActions"] == nil)
                    #expect(denied.body["results"] == nil)
                }
            }
            f.accounts.revokeAgentCredentialForTesting(apiKey: f.agentKey)
            let revokedPending = try await mentionActionsRequest(client, f, method: .get,
                path: "/internal/agent-api/mention-actions/pending", agentKey: f.agentKey)
            #expect(revokedPending.status == .unauthorized)
            let revokedExecute = try await mentionActionsRequest(client, f, method: .post,
                path: "/internal/agent-api/mention-actions/execute", agentKey: f.agentKey,
                object: ["action": "notify", "resolutionIds": [sent.resolutionId]])
            #expect(revokedExecute.status == .unauthorized)
            #expect(f.accounts.mentionActionRecord(id: sent.resolutionId)?.notified == false)
            #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetHumanId))
        }
    }
}
