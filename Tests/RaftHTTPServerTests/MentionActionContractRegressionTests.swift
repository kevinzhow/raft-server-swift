import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct MentionContractFixture {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let peerId: String
    let targetId: String
    let foreignId: String
    let serverId: String
    let foreignServerId: String
    let channelId: String
    let ownerToken: String
    let peerToken: String
    let agentId: String
    let agentKey: String

    init() {
        let accounts = EmailLoginDirectory()
        self.accounts = accounts
        ownerId = UUID().uuidString.lowercased()
        peerId = UUID().uuidString.lowercased()
        targetId = UUID().uuidString.lowercased()
        foreignId = UUID().uuidString.lowercased()
        serverId = UUID().uuidString.lowercased()
        foreignServerId = UUID().uuidString.lowercased()
        for (id, name) in [(ownerId, "contract_owner"), (peerId, "contract_peer"), (targetId, "contract_target"), (foreignId, "contract_foreign")] {
            accounts.addAccount(id: id, email: "\(name)@test.invalid", password: "password123")
            accounts.setAccountProfileForTesting(id: id, name: name)
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "mention-contract", name: "Mention Contract", ownerId: ownerId)
        accounts.oauth.addOwnedServer(id: foreignServerId, slug: "mention-contract-foreign", name: "Foreign", ownerId: foreignId)
        accounts.oauth.addMember(serverId: foreignServerId, userId: ownerId, role: "member")
        for id in [peerId, targetId] { accounts.oauth.addMember(serverId: serverId, userId: id, role: "member") }
        channelId = accounts.oauth.createChannel(serverId: serverId, name: "contract-room", creatorUserId: ownerId)
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "ContractSender", creatorUserId: ownerId)
        accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "contract-room",
            humanIds: [ownerId, peerId], agentIds: [agentId])
        ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
        peerToken = accounts.mintAccessTokenForTesting(userId: peerId)
        agentKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send", "mentions"], name: "mention-contract")
    }
}

private func withMentionContract(_ f: MentionContractFixture, _ body: @escaping (any Client) async throws -> Void) async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in try await body(client) }
    }
}

private func contractRequest(_ client: any Client, _ f: MentionContractFixture,
    method: HTTPRequest.Method = .post, path: String, token: String? = nil, serverId: String? = nil,
    body: [String: Any]? = nil
) async throws -> (status: HTTPResponse.Status, json: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token ?? f.ownerToken)"
    headers[HTTPField.Name("X-Server-Id")!] = serverId ?? f.serverId
    let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
    if data != nil { headers[.contentType] = "application/json" }
    let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let data { request.body = .init(data: data) }
    }
    let json = try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
    return (response.status, json)
}

private func contractSend(_ client: any Client, _ f: MentionContractFixture,
    agent: Bool = false, v2: Bool = true, token: String? = nil, channelId: String? = nil, agentTarget: String? = nil,
    content: String = "hello @contract_target", typedId: String? = nil, typedName: String = "contract_target", randomId: String? = nil, typed: Bool = true
) async throws -> (messageId: String, pending: [[String: Any]], json: [String: Any]) {
    var body: [String: Any] = ["content": content]
    if typed { body["mentions"] = [["type": "user", "id": typedId ?? f.targetId, "name": typedName]] }
    if agent { body["target"] = agentTarget ?? "#contract-room" }
    else { body["channelId"] = channelId ?? f.channelId }
    if let randomId { body[agent ? "idempotencyKey" : "randomId"] = randomId }
    let path = agent ? (v2 ? "/internal/agent-api/v2/send" : "/internal/agent-api/send") : (v2 ? "/api/v2/messages" : "/api/messages")
    let response = try await contractRequest(client, f, path: path, token: token ?? (agent ? f.agentKey : f.ownerToken), body: body)
    #expect(response.status == .ok)
    let messageId: String
    if agent {
        #expect(response.json["state"] as? String == "sent")
        messageId = try #require(response.json["messageId"] as? String)
    } else if let message = response.json["message"] as? [String: Any] {
        messageId = try #require(message["id"] as? String)
        #expect(message["pendingMentionActions"] == nil)
    } else { messageId = try #require(response.json["id"] as? String) }
    return (messageId, response.json["pendingMentionActions"] as? [[String: Any]] ?? [], response.json)
}

private func contractExecute(_ client: any Client, _ f: MentionContractFixture, ids: [String],
    action: String = "notify", agent: Bool = false, token: String? = nil, serverId: String? = nil
) async throws -> [[String: Any]] {
    let response = try await contractRequest(client, f,
        path: agent ? "/internal/agent-api/mention-actions/execute" : "/api/messages/mention-actions/execute",
        token: token ?? (agent ? f.agentKey : f.ownerToken), serverId: serverId,
        body: ["action": action, "resolutionIds": ids])
    #expect(response.status == .ok)
    #expect(response.json["ok"] as? Bool == true)
    #expect(response.json["action"] as? String == action)
    return try #require(response.json["results"] as? [[String: Any]])
}

@Test func publicMentionHumanAndAgentV1V2UseTheActualPersistedResolution() async throws {
    let f = MentionContractFixture()
    try await withMentionContract(f) { client in
        for agent in [false, true] {
            for v2 in [false, true] {
                let sent = try await contractSend(client, f, agent: agent, v2: v2)
                #expect(sent.pending.count == 1)
                let pending = try #require(sent.pending.first)
                #expect(Set(pending.keys) == ["resolutionId", "messageId", "targetType", "targetHandle", "targetAvatarUrl", "reason", "availableActions", "expiresAt"])
                #expect(pending["messageId"] as? String == sent.messageId)
                #expect(pending["targetType"] as? String == "user")
                #expect(pending["targetHandle"] as? String == "contract_target")
                #expect(pending["targetAvatarUrl"] is NSNull)
                #expect(pending["reason"] as? String == "not_member")
                #expect(pending["availableActions"] as? [String] == (agent ? ["notify"] : ["notify", "add"]))
                let id = try #require(pending["resolutionId"] as? String)
                let row = try #require(f.accounts.messagesAndThreadsStore.state.storedMentions.first { $0.id == id })
                #expect(row.messageId == sent.messageId)
                #expect(row.channelId == f.channelId)
                #expect(row.senderId == (agent ? f.agentId : f.ownerId))
                #expect(row.targetId == f.targetId)
                #expect(row.handle == "contract_target")
                #expect(!row.notifiableAtSend)
                #expect(row.notifiedAt == nil)
                let host = try #require(f.accounts.messagesAndThreadsStore.state.humanMessageRows.first { $0.id == sent.messageId })
                #expect(host.senderType == (agent ? "agent" : "user"))
                #expect(host.senderId == row.senderId)
                let result = try #require(try await contractExecute(client, f, ids: [id], agent: agent).first)
                #expect(Set(result.keys) == ["resolutionId", "action", "messageId", "channelId", "targetType", "targetId", "status", "dedupedResolutionIds"])
                #expect(result["resolutionId"] as? String == id)
                #expect(result["messageId"] as? String == sent.messageId)
                #expect(result["channelId"] as? String == f.channelId)
                #expect(result["targetType"] as? String == "user")
                #expect(result["targetId"] as? String == f.targetId)
                #expect(result["status"] as? String == "queued")
                #expect(result["dedupedResolutionIds"] as? [String] == [id])
                let facts = f.accounts.mentionActionRecord(id: id)
                #expect(facts?.notified == true)
                #expect(facts?.notifiedByType == (agent ? "agent" : "user"))
                #expect(facts?.notifiedById == row.senderId)
                #expect(facts?.notifiedAction == "notify_only")
                #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
                let replay = try #require(try await contractExecute(client, f, ids: [id], agent: agent).first)
                #expect(replay["status"] as? String == "queued")
                #expect(replay["reason"] as? String == "already_queued")
                #expect(replay["dedupedResolutionIds"] as? [String] == [id])
                let short = try #require(try await contractExecute(client, f, ids: [String(id.prefix(8))], agent: agent).first)
                #expect(short["resolutionId"] as? String == id)
                #expect(short["status"] as? String == "queued")
                #expect(short["reason"] as? String == "already_queued")
                #expect(short["dedupedResolutionIds"] as? [String] == [id])
            }
        }
        let targetToken = f.accounts.mintAccessTokenForTesting(userId: f.targetId)
        let cold = try await contractRequest(client, f, method: .get, path: "/api/messages/channel/\(f.channelId)", token: targetToken)
        #expect(cold.status == .ok)
        let messages = try #require(cold.json["messages"] as? [[String: Any]])
        #expect(messages.count == 4)
        #expect(messages.allSatisfy { (($0["mentions"] as? [[String: Any]])?.first?["id"] as? String) == f.targetId })
        #expect(messages.allSatisfy { $0["pendingMentionActions"] == nil })
    }
}

@Test func publicMentionActionsCloakWrongActorAndServerThenRecheckRemovedTarget() async throws {
    let f = MentionContractFixture()
    try await withMentionContract(f) { client in
        let sent = try await contractSend(client, f)
        let id = try #require(sent.pending.first?["resolutionId"] as? String)
        for (token, server) in [(f.peerToken, f.serverId), (f.ownerToken, f.foreignServerId)] {
            let result = try #require(try await contractExecute(client, f, ids: [id], token: token, serverId: server).first)
            #expect(Set(result.keys) == ["resolutionId", "action", "status"])
            #expect(result["resolutionId"] as? String == id)
            #expect(result["status"] as? String == "not_found")
        }
        let unknown = UUID().uuidString.lowercased()
        let missing = try #require(try await contractExecute(client, f, ids: [unknown]).first)
        #expect(Set(missing.keys) == ["resolutionId", "action", "status"])
        #expect(missing["status"] as? String == "not_found")
        f.accounts.oauth.removeMember(serverId: f.serverId, userId: f.targetId)
        let removed = try #require(try await contractExecute(client, f, ids: [id]).first)
        #expect(removed["status"] as? String == "stale")
        #expect(removed["reason"] as? String == "target_unavailable")
        #expect(f.accounts.mentionActionRecord(id: id)?.notified == false)
        #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
    }
}

@Test func publicMentionTypedClaimsNeedCanonicalNameServerAndVisibleBodyToken() async throws {
    let f = MentionContractFixture()
    try await withMentionContract(f) { client in
        for agent in [false, true] {
            let invalid: [(String, String, String)] = [
                ("@CONTRACT_TARGET", f.targetId, "CONTRACT_TARGET"),
                ("@contract_foreign", f.foreignId, "contract_foreign"),
                ("no visible token", f.targetId, "contract_target"),
                ("`@contract_target`", f.targetId, "contract_target"),
                ("```\n@contract_target\n```", f.targetId, "contract_target"),
                ("https://example.test/@contract_target", f.targetId, "contract_target"),
            ]
            for (content, targetId, name) in invalid {
                let sent = try await contractSend(client, f, agent: agent, content: content, typedId: targetId, typedName: name)
                #expect(sent.pending.isEmpty, "rejected typed claim must not recover through lexical fallback")
                #expect(f.accounts.messageMentionRows(messageId: sent.messageId).isEmpty)
                #expect(f.accounts.inboxFacts(messageId: sent.messageId, receiverIds: [f.targetId, f.foreignId]).isEmpty)
            }
            // A typed name absent from prose never claims a different visible token.
            let independentRaw = try await contractSend(client, f, agent: agent, content: "@contract_target", typedName: "CONTRACT_TARGET")
            #expect(independentRaw.pending.count == 1)
            #expect(independentRaw.pending.first?["targetHandle"] as? String == "contract_target")
            let actual = f.accounts.messageMentionRows(messageId: independentRaw.messageId)
            #expect(actual.count == 1)
            #expect(actual.first?.targetId == f.targetId)
            #expect(actual.first?.notifiableAtSend == false)
        }
    }
}

@Test func publicMentionRenameAndRandomIdReplayPreserveTheOriginalTargetSnapshot() async throws {
    let f = MentionContractFixture()
    try await withMentionContract(f) { client in
        let sent = try await contractSend(client, f, randomId: "contract-retry")
        let id = try #require(sent.pending.first?["resolutionId"] as? String)
        let original = try #require(f.accounts.messagesAndThreadsStore.state.storedMentions.first { $0.id == id })
        f.accounts.setAccountProfileForTesting(id: f.targetId, name: "contract_renamed")
        let replay = try await contractSend(client, f, content: "retry @contract_renamed", typedName: "contract_renamed", randomId: "contract-retry")
        #expect(replay.messageId == sent.messageId)
        #expect(replay.pending.isEmpty)
        let retained = try #require(f.accounts.messagesAndThreadsStore.state.storedMentions.first { $0.id == id })
        #expect(retained.id == original.id)
        #expect(retained.targetId == original.targetId)
        #expect(retained.handle == original.handle)
        #expect(retained.createdAt == original.createdAt)
        #expect(retained.senderId == original.senderId)
        #expect(retained.messageId == sent.messageId)
        #expect(retained.notifiableAtSend == original.notifiableAtSend)
        #expect(retained.notifiedAt == original.notifiedAt)
        #expect(f.accounts.messagesAndThreadsStore.state.storedMentions.filter { $0.messageId == sent.messageId }.count == 1)
        let result = try #require(try await contractExecute(client, f, ids: [id]).first)
        #expect(result["status"] as? String == "queued")
        #expect(result["targetId"] as? String == f.targetId)
        let row = try #require(f.accounts.messagesAndThreadsStore.state.storedMentions.first { $0.id == id })
        #expect(row.handle == "contract_target")
        #expect(row.targetId == f.targetId)
        let staleTyped = try await contractSend(client, f, content: "old @contract_target")
        #expect(staleTyped.pending.isEmpty)
        #expect(f.accounts.messageMentionRows(messageId: staleTyped.messageId).isEmpty)
    }
}

@Test func publicMentionAddCommitsActualOAuthMembershipAndRetryIsIdempotent() async throws {
    let f = MentionContractFixture()
    try await withMentionContract(f) { client in
        let sent = try await contractSend(client, f, v2: false)
        let id = try #require(sent.pending.first?["resolutionId"] as? String)
        let added = try #require(try await contractExecute(client, f, ids: [id], action: "add").first)
        #expect(added["status"] as? String == "delivered")
        #expect(added["reason"] == nil)
        #expect(added["dedupedResolutionIds"] as? [String] == [id])
        #expect(f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
        #expect(f.accounts.channelMemberIds(channelId: f.channelId).contains(f.targetId))
        #expect(f.accounts.mentionActionRecord(id: id)?.notifiedAction == "add")
        let replay = try #require(try await contractExecute(client, f, ids: [id], action: "add").first)
        #expect(replay["status"] as? String == "delivered")
        #expect(replay["reason"] as? String == "already_delivered")
        #expect(replay["dedupedResolutionIds"] as? [String] == [id])
        #expect(f.accounts.oauth.channelHumanIds(channelId: f.channelId).filter { $0 == f.targetId }.count == 1)
    }
}

@Test func publicMentionAddRechecksCurrentGuestMemberManagementAuthority() async throws {
    let f = MentionContractFixture()
    try await withMentionContract(f) { client in
        let sent = try await contractSend(client, f, token: f.peerToken)
        let id = try #require(sent.pending.first?["resolutionId"] as? String)
        f.accounts.oauth.addMember(serverId: f.serverId, userId: f.peerId, role: "guest")
        let result = try #require(try await contractExecute(client, f, ids: [id], action: "add", token: f.peerToken).first)
        #expect(result["status"] as? String == "no_permission")
        #expect(result["reason"] as? String == "add_requires_member_management_authority")
        #expect(f.accounts.mentionActionRecord(id: id)?.notified == false)
        #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
    }
}

@Test func publicMentionAlreadyJoinedAndRemovedSenderAreRevalidated() async throws {
    let f = MentionContractFixture()
    try await withMentionContract(f) { client in
        let sent = try await contractSend(client, f)
        let id = try #require(sent.pending.first?["resolutionId"] as? String)
        f.accounts.oauth.addChannelHuman(channelId: f.channelId, userId: f.targetId)
        f.accounts.addPostableChannel(serverId: f.serverId, channelId: f.channelId, memberId: f.targetId)
        let joined = try #require(try await contractExecute(client, f, ids: [id]).first)
        #expect(joined["status"] as? String == "stale")
        #expect(joined["reason"] as? String == "target_already_member")
        f.accounts.removeChannelMemberForTesting(channelId: f.channelId, userId: f.ownerId)
        let removed = try #require(try await contractExecute(client, f, ids: [id], action: "add").first)
        #expect(removed["status"] as? String == "no_permission")
        #expect(removed["reason"] as? String == "sender_lacks_channel_access")
        #expect(f.accounts.mentionActionRecord(id: id)?.notified == false)
    }
}

@Test func publicMentionGroupsExcludeDifferentActualActorsChannelsAndServers() async throws {
    for agent in [false, true] {
        let f = MentionContractFixture()
        let otherChannel = f.accounts.oauth.createChannel(serverId: f.serverId, name: "contract-other", creatorUserId: f.ownerId)
        f.accounts.seedPostableChannelForTesting(serverId: f.serverId, channelId: otherChannel, name: "contract-other",
            humanIds: [f.ownerId], agentIds: [f.agentId])
        f.accounts.oauth.addMember(serverId: f.foreignServerId, userId: f.targetId, role: "member")
        let foreignChannel = f.accounts.oauth.createChannel(serverId: f.foreignServerId, name: "contract-foreign-room", creatorUserId: f.ownerId)
        f.accounts.addPostableChannel(serverId: f.foreignServerId, channelId: foreignChannel, memberId: f.ownerId, name: "contract-foreign-room")
        try await withMentionContract(f) { client in
            let first = try await contractSend(client, f, agent: agent)
            let second = try await contractSend(client, f, agent: agent)
            let peer = try await contractSend(client, f, token: f.peerToken)
            let other = try await contractSend(client, f, agent: agent, channelId: otherChannel, agentTarget: "#contract-other")
            let foreign = try await contractRequest(client, f, path: "/api/v2/messages", serverId: f.foreignServerId,
                body: ["channelId": foreignChannel, "content": "foreign @contract_target",
                    "mentions": [["type": "user", "id": f.targetId, "name": "contract_target"]]])
            #expect(foreign.status == .ok)
            let foreignId = try #require((foreign.json["pendingMentionActions"] as? [[String: Any]])?.first?["resolutionId"] as? String)
            let firstId = try #require(first.pending.first?["resolutionId"] as? String)
            let secondId = try #require(second.pending.first?["resolutionId"] as? String)
            let peerId = try #require(peer.pending.first?["resolutionId"] as? String)
            let otherId = try #require(other.pending.first?["resolutionId"] as? String)
            #expect(first.messageId != second.messageId)
            #expect(Set([firstId, secondId, peerId, otherId, foreignId]).count == 5)
            let result = try #require(try await contractExecute(client, f, ids: [firstId], agent: agent).first)
            #expect(result["status"] as? String == "queued")
            #expect(Set(result["dedupedResolutionIds"] as? [String] ?? []) == [firstId, secondId])
            for id in [firstId, secondId] { #expect(f.accounts.mentionActionRecord(id: id)?.notifiedAction == "notify_only") }
            for id in [peerId, otherId, foreignId] { #expect(f.accounts.mentionActionRecord(id: id)?.notified == false) }
            #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
        }
    }
}

@Test func publicMentionHiddenDirectoryBlocksHumanAndAgentTypedLeaks() async throws {
    let f = MentionContractFixture()
    f.accounts.setHideHumansFromMembers(serverId: f.serverId, hidden: true)
    try await withMentionContract(f) { client in
        for agent in [false, true] {
            for v2 in [false, true] {
                let sent = try await contractSend(client, f, agent: agent, v2: v2, token: agent ? f.agentKey : f.peerToken)
                #expect(sent.pending.isEmpty)
                #expect(f.accounts.messageMentionRows(messageId: sent.messageId).isEmpty)
                #expect(f.accounts.inboxFacts(messageId: sent.messageId, receiverIds: [f.targetId]).isEmpty)
            }
        }
        f.accounts.setHideHumansFromMembers(serverId: f.serverId, hidden: false)
        let visible = try await contractSend(client, f, agent: true)
        let id = try #require(visible.pending.first?["resolutionId"] as? String)
        #expect(visible.pending.count == 1)
        #expect(try await contractExecute(client, f, ids: [id], agent: true).first?["status"] as? String == "queued")
    }
}

@Test func publicMentionThreadAddCommitsParentMembershipAndActualFollow() async throws {
    let f = MentionContractFixture()
    try await withMentionContract(f) { client in
        let parent = try await contractRequest(client, f, path: "/api/messages",
            body: ["channelId": f.channelId, "content": "actual thread parent"])
        #expect(parent.status == .ok)
        let parentId = try #require(parent.json["id"] as? String)
        let thread = f.accounts.oauth.createThreadChannel(parentChannelId: f.channelId, parentMessageId: parentId)
        f.accounts.addThreadChannel(serverId: f.serverId, threadChannelId: thread, parentChannelId: f.channelId,
            parentMessageId: parentId, memberId: f.ownerId)
        let sent = try await contractSend(client, f, channelId: thread)
        let id = try #require(sent.pending.first?["resolutionId"] as? String)
        #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
        let added = try #require(try await contractExecute(client, f, ids: [id], action: "add").first)
        #expect(added["status"] as? String == "delivered")
        #expect(added["messageId"] as? String == sent.messageId)
        #expect(added["channelId"] as? String == thread)
        #expect(f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
        #expect(f.accounts.threadFollowerIdsForTesting(threadChannelId: thread).contains(f.targetId))
        let targetToken = f.accounts.mintAccessTokenForTesting(userId: f.targetId)
        let followed = try await contractRequest(client, f, method: .get, path: "/api/channels/threads/followed", token: targetToken)
        #expect(followed.status == .ok)
        #expect((followed.json["threads"] as? [[String: Any]] ?? []).contains { $0["threadChannelId"] as? String == thread })
        let cold = try await contractRequest(client, f, method: .get, path: "/api/messages/channel/\(thread)", token: targetToken)
        #expect(cold.status == .ok)
        #expect((cold.json["messages"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == sent.messageId })
    }
}

@Test func publicMentionLexicalBoundariesKeepOutsideProseEligible() async throws {
    let f = MentionContractFixture()
    let prose = [
        "```\r\ncode\r\n```\r\n@contract_target",
        "> ```\n> code\n@contract_target",
        "- ```\n  code\n@contract_target",
        "[@contract_target]:",
        "[@contract_target](please review)",
    ]
    try await withMentionContract(f) { client in
        for agent in [false, true] {
            for typed in [false, true] {
                for content in prose {
                    let sent = try await contractSend(client, f, agent: agent, content: content, typed: typed)
                    #expect(sent.pending.count == 1, "agent=\(agent) typed=\(typed) content=\(content)")
                    let pending = try #require(sent.pending.first)
                    let id = try #require(pending["resolutionId"] as? String)
                    #expect(pending["messageId"] as? String == sent.messageId)
                    #expect(pending["targetHandle"] as? String == "contract_target")
                    #expect(pending["targetType"] as? String == "user")
                    #expect(sent.json["unresolvedMentionHandles"] == nil)
                    let rows = f.accounts.messagesAndThreadsStore.state.storedMentions.filter { $0.messageId == sent.messageId }
                    #expect(rows.count == 1)
                    let row = try #require(rows.first)
                    #expect(row.id == id)
                    #expect(row.targetId == f.targetId)
                    #expect(row.handle == "contract_target")
                    #expect(row.senderId == (agent ? f.agentId : f.ownerId))
                    #expect(!row.notifiableAtSend)
                    #expect(row.notifiedAt == nil)
                    #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
                }
            }
        }
    }
}

@Test func publicMentionTypedCJKHandleDoesNotInventAnUnresolvedWarning() async throws {
    let f = MentionContractFixture()
    f.accounts.setAccountProfileForTesting(id: f.targetId, name: "Ops")
    try await withMentionContract(f) { client in
        for agent in [false, true] {
            let sent = try await contractSend(client, f, agent: agent, content: "@Ops的", typedName: "Ops")
            #expect(sent.pending.count == 1)
            #expect(sent.json["unresolvedMentionHandles"] == nil)
            let pending = try #require(sent.pending.first)
            #expect(pending["targetHandle"] as? String == "Ops")
            let id = try #require(pending["resolutionId"] as? String)
            let row = try #require(f.accounts.messagesAndThreadsStore.state.storedMentions.first { $0.id == id })
            #expect(row.messageId == sent.messageId)
            #expect(row.targetId == f.targetId)
            #expect(row.handle == "Ops")
            #expect(!row.notifiableAtSend)
            #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
        }
    }
}

@Test func publicMentionMarkdownProfileKeepsIndentedProseAndGFMExclusions() async throws {
    let f = MentionContractFixture()
    let samples: [(String, Bool)] = [
        ("    @contract_target", true),
        ("    ~~~\n    @contract_target\n    ~~~", false),
        ("    [@contract_target](https://example.invalid)", false),
        ("www.example.invalid/@contract_target", false),
        ("someone@contract_target.invalid", false),
        ("opening `\n\n@contract_target\n\nclosing `", true),
        ("```\r\n@contract_target\r\n````", false),
        ("😀``@contract_target``中文", false),
        ("😀 [label](<@contract_target>)", true),
        ("[label][id]\n\n[id]: <@contract_target>", false),
        ("![label](<@contract_target>)", false),
        ("[![label](image)](<@contract_target>)", true),
        ("[label](<@contract_target> \"title\")", false),
        ("[id]: <@contract_target>\n\n@contract_target", true),
        ("> <![alt @contract_target](url)", false),
        ("> a@contract_target.inval(id", false),
        ("a@contract_target.invalid> after", false),
        ("\ta@contract_target.invali\\d after", false),
        ("*[foo* www.example.invalid/@contract_target", true),
        ("**[foo** www.example.invalid/@contract_target", true),
        ("~~[foo~~ www.example.invalid/@contract_target", true),
        ("*[foo* HTTP://example.invalid/@contract_target", true),
    ]
    try await withMentionContract(f) { client in
        for agent in [false, true] {
            for typed in [false, true] {
                for (content, eligible) in samples {
                    let sent = try await contractSend(client, f, agent: agent, content: content, typed: typed)
                    let host = try #require(f.accounts.messagesAndThreadsStore.state.humanMessageRows.first { $0.id == sent.messageId })
                    #expect(host.content == content)
                    #expect(host.senderId == (agent ? f.agentId : f.ownerId))
                    let rows = f.accounts.messagesAndThreadsStore.state.storedMentions.filter { $0.messageId == sent.messageId }
                    #expect(sent.pending.count == (eligible ? 1 : 0), "agent=\(agent) typed=\(typed) content=\(content)")
                    #expect(rows.count == (eligible ? 1 : 0))
                    #expect(sent.json["unresolvedMentionHandles"] == nil)
                    #expect(f.accounts.inboxFacts(messageId: sent.messageId, receiverIds: [f.targetId]).isEmpty)
                    #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
                    if eligible {
                        let pending = try #require(sent.pending.first)
                        let row = try #require(rows.first)
                        #expect(pending["resolutionId"] as? String == row.id)
                        #expect(pending["messageId"] as? String == sent.messageId)
                        #expect(pending["targetHandle"] as? String == "contract_target")
                        #expect(row.targetId == f.targetId)
                        #expect(row.senderId == host.senderId)
                        #expect(row.handle == "contract_target")
                        #expect(!row.notifiableAtSend)
                        #expect(row.notifiedAt == nil)
                    }
                }
            }
        }
    }
}

@Test func publicMentionFootnoteAndEntityProfilesUseTheOriginalVisibleIntent() async throws {
    let f = MentionContractFixture()
    let samples: [(String, Bool)] = [
        ("[^id]: @contract_target", true),
        ("[^@contract_target]: elsewhere\n\n[^@contract_target]", true),
        ("[label](<&commat;contract_target>)", true),
        ("prose\n    ~~~\n    @contract_target", false),
        ("&#64;contract_target", false),
    ]
    try await withMentionContract(f) { client in
        for agent in [false, true] {
            for typed in [false, true] {
                for (content, eligible) in samples {
                    let sent = try await contractSend(client, f, agent: agent, content: content, typed: typed)
                    let host = try #require(f.accounts.messagesAndThreadsStore.state.humanMessageRows.first { $0.id == sent.messageId })
                    #expect(host.content == content)
                    #expect(host.senderId == (agent ? f.agentId : f.ownerId))
                    let rows = f.accounts.messagesAndThreadsStore.state.storedMentions.filter { $0.messageId == sent.messageId }
                    #expect(sent.pending.count == (eligible ? 1 : 0), "agent=\(agent) typed=\(typed) content=\(content)")
                    #expect(rows.count == (eligible ? 1 : 0))
                    #expect(sent.json["unresolvedMentionHandles"] == nil)
                    #expect(f.accounts.inboxFacts(messageId: sent.messageId, receiverIds: [f.targetId]).isEmpty)
                    #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
                    if eligible {
                        let pending = try #require(sent.pending.first)
                        let row = try #require(rows.first)
                        #expect(pending["resolutionId"] as? String == row.id)
                        #expect(pending["messageId"] as? String == host.id)
                        #expect(pending["targetHandle"] as? String == "contract_target")
                        #expect(row.targetId == f.targetId)
                        #expect(row.senderId == host.senderId)
                        #expect(row.handle == "contract_target")
                        #expect(!row.notifiableAtSend)
                        #expect(row.notifiedAt == nil)
                    }
                }
            }
        }
    }
}

@Test func publicMentionEscapedAnglesAndDecodedHrefWhitespaceKeepNodeBoundaries() async throws {
    let f = MentionContractFixture()
    let samples: [(String, Bool, Bool)] = [
        (#"@contract\<@ignored>_target"#, true, true),
        (#"prefix\<@ignored>@contract_target"#, false, true),
        ("[label](< @contract_target >)", true, true),
        ("[label](<&nbsp;@contract_target&#32;>)", true, true),
    ]
    try await withMentionContract(f) { client in
        for agent in [false, true] {
            for typed in [false, true] {
                for (content, rawEligible, typedEligible) in samples {
                    let eligible = typed ? typedEligible : rawEligible
                    let sent = try await contractSend(client, f, agent: agent, content: content, typed: typed)
                    let host = try #require(f.accounts.messagesAndThreadsStore.state.humanMessageRows.first { $0.id == sent.messageId })
                    #expect(host.content == content)
                    #expect(host.senderId == (agent ? f.agentId : f.ownerId))
                    let rows = f.accounts.messagesAndThreadsStore.state.storedMentions.filter { $0.messageId == sent.messageId }
                    #expect(sent.pending.count == (eligible ? 1 : 0), "agent=\(agent) typed=\(typed) content=\(content)")
                    #expect(rows.count == (eligible ? 1 : 0))
                    #expect(sent.json["unresolvedMentionHandles"] == nil)
                    #expect(f.accounts.inboxFacts(messageId: sent.messageId, receiverIds: [f.targetId]).isEmpty)
                    #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
                    if eligible {
                        let pending = try #require(sent.pending.first)
                        let row = try #require(rows.first)
                        #expect(pending["resolutionId"] as? String == row.id)
                        #expect(pending["messageId"] as? String == host.id)
                        #expect(pending["targetHandle"] as? String == "contract_target")
                        #expect(row.targetId == f.targetId)
                        #expect(row.senderId == host.senderId)
                        #expect(row.handle == "contract_target")
                        #expect(!row.notifiableAtSend)
                        #expect(row.notifiedAt == nil)
                    }
                }
            }
        }
    }
}

@Test func publicMentionJSTrimKeepsNELInTypedNamesAndActionIDs() async throws {
    let f = MentionContractFixture()
    try await withMentionContract(f) { client in
        for agent in [false, true] {
            let sent = try await contractSend(client, f, agent: agent, typedId: f.foreignId, typedName: "contract_target\u{0085}")
            #expect(sent.pending.count == 1)
            let pending = try #require(sent.pending.first)
            let id = try #require(pending["resolutionId"] as? String)
            #expect(pending["targetHandle"] as? String == "contract_target")
            let rows = f.accounts.messagesAndThreadsStore.state.storedMentions.filter { $0.messageId == sent.messageId }
            #expect(rows.count == 1)
            let original = try #require(rows.first)
            #expect(original.id == id)
            #expect(original.targetId == f.targetId)
            #expect(original.targetId != f.foreignId)
            #expect(original.senderId == (agent ? f.agentId : f.ownerId))
            #expect(sent.json["unresolvedMentionHandles"] == nil)
            let tainted = id + "\u{0085}"
            let denied = try #require(try await contractExecute(client, f, ids: [tainted], agent: agent).first)
            #expect(denied["status"] as? String == "not_found")
            #expect(denied["resolutionId"] as? String == tainted)
            for field in ["messageId", "channelId", "targetType", "targetId"] { #expect(denied[field] == nil) }
            let retained = try #require(f.accounts.messagesAndThreadsStore.state.storedMentions.first { $0.id == id })
            #expect(retained.notifiedAt == nil)
            #expect(retained.createdAt == original.createdAt)
            #expect(!retained.notifiableAtSend)
            #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
            #expect(f.accounts.inboxFacts(messageId: sent.messageId, receiverIds: [f.targetId]).isEmpty)
        }
    }
}

@Test func publicMentionBareURLUsesJSWhitespaceForNELAndBOM() async throws {
    let f = MentionContractFixture()
    let samples: [(String, Bool)] = [
        ("seehttps://example.invalid/\u{0085}@contract_target", false),
        ("seehttps://example.invalid/\u{FEFF}@contract_target", true),
    ]
    try await withMentionContract(f) { client in
        for agent in [false, true] {
            for typed in [false, true] {
                for (content, eligible) in samples {
                    let sent = try await contractSend(client, f, agent: agent, content: content, typed: typed)
                    let host = try #require(f.accounts.messagesAndThreadsStore.state.humanMessageRows.first { $0.id == sent.messageId })
                    #expect(host.content == content)
                    #expect(host.senderId == (agent ? f.agentId : f.ownerId))
                    let rows = f.accounts.messagesAndThreadsStore.state.storedMentions.filter { $0.messageId == sent.messageId }
                    #expect(sent.pending.count == (eligible ? 1 : 0))
                    #expect(rows.count == (eligible ? 1 : 0))
                    #expect(sent.json["unresolvedMentionHandles"] == nil)
                    #expect(f.accounts.inboxFacts(messageId: sent.messageId, receiverIds: [f.targetId]).isEmpty)
                    #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: f.targetId))
                    if eligible {
                        let pending = try #require(sent.pending.first)
                        let row = try #require(rows.first)
                        #expect(pending["resolutionId"] as? String == row.id)
                        #expect(pending["messageId"] as? String == host.id)
                        #expect(pending["targetHandle"] as? String == "contract_target")
                        #expect(row.targetId == f.targetId)
                        #expect(row.senderId == host.senderId)
                        #expect(row.notifiedAt == nil)
                        #expect(!row.notifiableAtSend)
                    }
                }
            }
        }
    }
}
