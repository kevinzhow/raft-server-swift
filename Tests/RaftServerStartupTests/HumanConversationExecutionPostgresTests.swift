import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RaftPersistence
import RaftShared
import Testing
@testable import RaftHTTP

private let conversationExecutionPGEnabled = ProcessInfo.processInfo.environment["RAFT_HUMAN_MESSAGE_EXECUTION_PG_ACCEPTANCE"] == "1"

/// Published sends and authoritative PG/outbox/NIO results. The controlled peer
/// supplies protocol evidence only; no official Computer or model turn is claimed.
/// Run this filter alone against its own fresh disposable database/process.
@Test(.enabled(if: conversationExecutionPGEnabled))
func postgresHumanDMAndThreadDeliveryUsesActualParticipantsAndFollows() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_HUMAN_MESSAGE_EXECUTION_TEST_DATABASE_URL"], !databaseURL.isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    var machine: ControlledMachineProtocolPeer?
    do {
        let owner = try await f.login(f.ownerEmail)
        let member = try await f.login(f.memberEmail)
        let attach = try await f.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Conversation protocol peer")]))
        try #require(attach.status == 201)
        let machineId = try attach.object().requireString("machineId")
        let machineKey = try attach.object().requireString("apiKey")
        // Create before ready: no synthetic online setter or automatic start.
        let a = try await conversationAgent(f, owner: owner, name: "ConversationRecipientA", machineId: machineId)
        let b = try await conversationAgent(f, owner: owner, name: "ConversationParentMemberB", machineId: machineId)
        let outsider = try await conversationAgent(f, owner: owner, name: "ConversationNonMember", machineId: machineId)
        let unassigned = try await conversationAgent(f, owner: owner, name: "ConversationUnassigned", machineId: nil)
        let aId = try a.requireString("id"), bId = try b.requireString("id")
        let aName = try a.requireString("name"), outsiderId = try outsider.requireString("id")
        let dm = try await conversationCreatorDM(f, owner: owner, agentId: aId)
        let bDM = try await conversationCreatorDM(f, owner: owner, agentId: bId)
        let unassignedDM = try await conversationCreatorDM(f, owner: owner, agentId: unassigned.requireString("id"))
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: machineKey)
        machine = peer
        try await peer.sendControlledReady()
        let startBoundary = peer.socket.count
        #expect(try await f.http("POST", "/api/agents/\(aId)/start", token: owner).status == 200)
        let start = try await peer.socket.nextObject(since: startBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == aId }
        try await peer.acknowledgeControlledStart(start)

        // RED on the old producer: HTTP200/message exists but no durable delivery.
        let dmBoundary = peer.socket.count
        let dmRequest = ProtocolPGObject(["channelId": .string(dm), "content": .string("Default creator DM needs no mention"), "randomId": .string("creator-dm-once")])
        let sent = try await f.http("POST", "/api/messages", token: owner, body: dmRequest)
        try #require(sent.status == 200)
        let dmMessageId = try sent.object().requireString("id")
        try await conversationAssertCommittedDelivery(f, messageId: dmMessageId, channelId: dm, agentIds: [aId])
        let dmFrame = try await conversationDelivery(f, peer, since: dmBoundary, messageId: dmMessageId, agentId: aId)
        #expect(dmFrame.object("message")?.string("channel_type") == "dm")
        #expect(dmFrame.object("message")?.string("channel_id") == dm)
        #expect(dmFrame.object("message")?.bool("mentioned") == false)
        let replay = try await f.http("POST", "/api/messages", token: owner, body: dmRequest)
        #expect(replay.status == 200)
        #expect(try replay.object().string("id") == dmMessageId)
        try await conversationAssertCommittedDelivery(f, messageId: dmMessageId, channelId: dm, agentIds: [aId])
        let denied = try await f.http("POST", "/api/messages", token: member,
            body: .init(["channelId": .string(dm), "content": .string("Nonparticipant must not send")]))
        #expect(denied.status == 403)
        #expect(!(try await f.audit()).messages.contains { $0.string("content") == "Nonparticipant must not send" })
        let v2Boundary = peer.socket.count
        let v2 = try await f.http("POST", "/api/v2/messages", token: owner,
            body: .init(["channelId": .string(dm), "content": .string("Second creator DM through v2")]))
        try #require(v2.status == 200)
        let v2Id = try #require(try v2.object().object("message")).requireString("id")
        try await conversationAssertCommittedDelivery(f, messageId: v2Id, channelId: dm, agentIds: [aId])
        _ = try await conversationDelivery(f, peer, since: v2Boundary, messageId: v2Id, agentId: aId)

        let parent = try await conversationChannel(f, owner: owner, name: "conversation-parent")
        let parentMessage = try await conversationSend(f, owner: owner, channel: parent, content: "Thread parent before agents join")
        let thread = try await conversationThread(f, owner: owner, parent: parent, message: parentMessage)
        for id in [aId, bId] {
            #expect(try await f.http("POST", "/api/channels/\(parent)/members", token: owner, body: .init(["agentId": .string(id)])).status == 200)
        }
        let noFollowers = try await conversationSend(f, owner: owner, channel: thread, content: "Parent membership alone is not a thread audience")
        try await conversationAssertNoDelivery(f, messageId: noFollowers)
        let mentionedBoundary = peer.socket.count
        let mentioned = try await conversationMention(f, owner: owner, channel: thread, id: aId, name: aName, randomId: "thread-mention-once")
        try await conversationAssertCommittedDelivery(f, messageId: mentioned, channelId: thread, agentIds: [aId])
        let mentionFrame = try await conversationDelivery(f, peer, since: mentionedBoundary, messageId: mentioned, agentId: aId)
        #expect(mentionFrame.object("message")?.string("channel_type") == "thread")
        #expect(mentionFrame.object("message")?.string("parent_channel_id") == parent)
        #expect(mentionFrame.object("message")?.string("parent_channel_type") == "channel")
        #expect(mentionFrame.object("message")?.bool("mentioned") == true)
        // Commit the actual retained agent preference through the same BPR, as
        // in the existing channel PG test; assertions use published sends/PG/NIO.
        try await f.runtime.execute {
            _ = f.accounts.oauth.setActivityMuted(channelId: thread, receiverId: aId, muted: true, muteFromSeq: 0)
        }
        let muted = try await conversationSend(f, owner: owner, channel: thread, content: "Muted ordinary thread activity has no delivery")
        try await conversationAssertNoDelivery(f, messageId: muted)
        let piercingBoundary = peer.socket.count
        let piercing = try await conversationMention(f, owner: owner, channel: thread, id: aId, name: aName)
        try await conversationAssertCommittedDelivery(f, messageId: piercing, channelId: thread, agentIds: [aId])
        _ = try await conversationDelivery(f, peer, since: piercingBoundary, messageId: piercing, agentId: aId)
        try await f.runtime.execute {
            _ = f.accounts.oauth.setActivityMuted(channelId: thread, receiverId: aId, muted: false, muteFromSeq: nil)
        }
        let followBoundary = peer.socket.count
        let followed = try await conversationSend(f, owner: owner, channel: thread, content: "Ordinary reply reaches the retained follower only", v2: true)
        try await conversationAssertCommittedDelivery(f, messageId: followed, channelId: thread, agentIds: [aId])
        _ = try await conversationDelivery(f, peer, since: followBoundary, messageId: followed, agentId: aId)
        let outsiderMentionBoundary = peer.socket.count
        let outsiderMention = try await conversationMention(f, owner: owner, channel: thread, id: outsiderId, name: outsider.requireString("name"))
        // Existing follower A still receives; the outsider mention cannot autojoin.
        try await conversationAssertCommittedDelivery(f, messageId: outsiderMention, channelId: thread, agentIds: [aId])
        _ = try await conversationDelivery(f, peer, since: outsiderMentionBoundary, messageId: outsiderMention, agentId: aId)
        let removed = try await f.http("DELETE", "/api/channels/threads/\(thread)/followers/agents/\(aId)", token: owner)
        try #require(removed.status == 200)
        let undoToken = try removed.object().requireString("undoToken")
        let mentionReplay = try await conversationMention(f, owner: owner, channel: thread, id: aId, name: aName, randomId: "thread-mention-once")
        #expect(mentionReplay == mentioned)
        try await conversationAssertCommittedDelivery(f, messageId: mentioned, channelId: thread, agentIds: [aId])
        let unfollowed = try await conversationSend(f, owner: owner, channel: thread, content: "An explicit unfollow suppresses ordinary thread traffic")
        try await conversationAssertNoDelivery(f, messageId: unfollowed)
        let restore = try await f.http("POST", "/api/channels/threads/\(thread)/followers/agents/\(aId)/restore", token: owner,
            body: .init(["undoToken": .string(undoToken)]))
        try #require(restore.status == 200)
        #expect(try restore.object().bool("restored") == true)
        let restoredBoundary = peer.socket.count
        let restored = try await conversationSend(f, owner: owner, channel: thread, content: "A real undo restores the authoritative follower")
        try await conversationAssertCommittedDelivery(f, messageId: restored, channelId: thread, agentIds: [aId])
        _ = try await conversationDelivery(f, peer, since: restoredBoundary, messageId: restored, agentId: aId)
        let staleRestore = try await f.http("POST", "/api/channels/threads/\(thread)/followers/agents/\(aId)/restore", token: owner,
            body: .init(["undoToken": .string(undoToken)]))
        #expect(staleRestore.status == 200)
        #expect(try staleRestore.object().bool("restored") == false)
        let removedAgain = try await f.http("DELETE", "/api/channels/threads/\(thread)/followers/agents/\(aId)", token: owner)
        try #require(removedAgain.status == 200)
        let secondUndo = try removedAgain.object().requireString("undoToken")
        #expect(secondUndo != undoToken)
        let removalReplay = try await f.http("DELETE", "/api/channels/threads/\(thread)/followers/agents/\(aId)", token: owner)
        #expect(try removalReplay.object().string("undoToken") == secondUndo)
        let suppressedAgain = try await conversationSend(f, owner: owner, channel: thread, content: "A second real removal suppresses activity again")
        try await conversationAssertNoDelivery(f, messageId: suppressedAgain)
        let reactivateBoundary = peer.socket.count
        let reactivated = try await conversationMention(f, owner: owner, channel: thread, id: aId, name: aName)
        try await conversationAssertCommittedDelivery(f, messageId: reactivated, channelId: thread, agentIds: [aId])
        _ = try await conversationDelivery(f, peer, since: reactivateBoundary, messageId: reactivated, agentId: aId)
        let supersededRestore = try await f.http("POST", "/api/channels/threads/\(thread)/followers/agents/\(aId)/restore", token: owner,
            body: .init(["undoToken": .string(secondUndo)]))
        #expect(supersededRestore.status == 200)
        #expect(try supersededRestore.object().bool("restored") == false)
        // A fresh actual agent reply reactivates the same follow owner. A
        // receipt replay cannot undo a later removal. No process/model is faked.
        let selfRemoved = try await f.http("DELETE", "/api/channels/threads/\(thread)/followers/agents/\(aId)", token: owner)
        try #require(selfRemoved.status == 200)
        let selfUndo = try selfRemoved.object().requireString("undoToken")
        let aRunner = try #require(start.object("config")).requireString("agentCredentialKey")
        let selfDraft = ProtocolPGObject(["target": .string("#conversation-parent:\(parentMessage.prefix(8))"),
            "content": .string("Actual agent self reply"), "idempotencyKey": .string("agent-self-once")])
        let selfReply = try await f.http("POST", "/internal/agent-api/send", token: aRunner, body: selfDraft)
        try #require(selfReply.status == 200)
        try #require(try selfReply.object().string("state") == "sent")
        let selfId = try selfReply.object().requireString("messageId")
        try await conversationAssertNoDelivery(f, messageId: selfId)
        let selfStale = try await f.http("POST", "/api/channels/threads/\(thread)/followers/agents/\(aId)/restore", token: owner,
            body: .init(["undoToken": .string(selfUndo)]))
        #expect(try selfStale.object().bool("restored") == false)
        let afterSelfBoundary = peer.socket.count
        let afterSelf = try await conversationSend(f, owner: owner, channel: thread, content: "Ordinary human reply after actual agent self-reply")
        try await conversationAssertCommittedDelivery(f, messageId: afterSelf, channelId: thread, agentIds: [aId])
        _ = try await conversationDelivery(f, peer, since: afterSelfBoundary, messageId: afterSelf, agentId: aId)
        let beforeReplay = try await f.http("DELETE", "/api/channels/threads/\(thread)/followers/agents/\(aId)", token: owner)
        try #require(beforeReplay.status == 200)
        let replayUndo = try beforeReplay.object().requireString("undoToken")
        let selfReplay = try await f.http("POST", "/internal/agent-api/send", token: aRunner, body: selfDraft)
        #expect(selfReplay.status == 200)
        #expect(try selfReplay.object().string("messageId") == selfId)
        let replayBlocked = try await conversationSend(f, owner: owner, channel: thread, content: "Agent receipt replay cannot reactivate a removed follow")
        try await conversationAssertNoDelivery(f, messageId: replayBlocked)
        // B needs a real admitted start for its actual runner credential. Start
        // ACK is protocol evidence; it does not assert a spawned/model process.
        let bStartBoundary = peer.socket.count
        #expect(try await f.http("POST", "/api/agents/\(bId)/start", token: owner).status == 200)
        let bStart = try await peer.socket.nextObject(since: bStartBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == bId }
        try await peer.acknowledgeControlledStart(bStart)
        let bRunner = try #require(bStart.object("config")).requireString("agentCredentialKey")
        let agentMention = try await f.http("POST", "/internal/agent-api/v2/send", token: bRunner,
            body: .init(["target": .string("#conversation-parent:\(parentMessage.prefix(8))"),
                "content": .string("Actual B mention @\(aName)"), "idempotencyKey": .string("agent-mention-once"),
                "mentions": .array([.object(["type": .string("agent"), "id": .string(aId), "name": .string(aName)])])]))
        try #require(agentMention.status == 200)
        try #require(try agentMention.object().string("state") == "sent")
        let agentMentionId = try agentMention.object().requireString("messageId")
        try await conversationAssertNoDelivery(f, messageId: agentMentionId)
        let mentionStale = try await f.http("POST", "/api/channels/threads/\(thread)/followers/agents/\(aId)/restore", token: owner,
            body: .init(["undoToken": .string(replayUndo)]))
        #expect(try mentionStale.object().bool("restored") == false)
        let afterAgentMentionBoundary = peer.socket.count
        let afterAgentMention = try await conversationSend(f, owner: owner, channel: thread, content: "Ordinary human reply after actual agent direct mention")
        try await conversationAssertCommittedDelivery(f, messageId: afterAgentMention, channelId: thread, agentIds: [aId, bId])
        var remaining = Set([aId, bId])
        do {
            while !remaining.isEmpty {
                let pending = remaining
                let frame = try await peer.socket.nextObject(since: afterAgentMentionBoundary) {
                    $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == afterAgentMention
                        && pending.contains($0.string("agentId") ?? "")
                }
                let actualAgent = try frame.requireString("agentId")
                let matched = remaining.remove(actualAgent)
                #expect(matched != nil)
                try await peer.acknowledgeControlledDelivery(frame)
            }
        } catch {
            let failed = try await f.audit()
            let matching = failed.execution.commands.values.filter { $0.messageId == afterAgentMention }
            Issue.record(Comment(rawValue: "multi-recipient wait failed: remaining=\(remaining.sorted()) commands=\(matching.map { "\($0.agentId):\($0.launchId):\($0.status)" })"))
            throw error
        }
        let bRemoved = try await f.http("DELETE", "/api/channels/threads/\(thread)/followers/agents/\(bId)", token: owner)
        try #require(bRemoved.status == 200)
        let afterReactivationBoundary = peer.socket.count
        let afterReactivation = try await conversationSend(f, owner: owner, channel: thread, content: "Actual parent-agent membership reactivated the follow")
        try await conversationAssertCommittedDelivery(f, messageId: afterReactivation, channelId: thread, agentIds: [aId])
        _ = try await conversationDelivery(f, peer, since: afterReactivationBoundary, messageId: afterReactivation, agentId: aId)
        #expect(try await f.http("DELETE", "/api/channels/\(parent)/members/agent/\(aId)", token: owner).status == 200)
        let publicFollowerBoundary = peer.socket.count
        let publicFollower = try await conversationSend(f, owner: owner, channel: thread, content: "An existing public-parent follower has separate Node eligibility")
        try await conversationAssertCommittedDelivery(f, messageId: publicFollower, channelId: thread, agentIds: [aId])
        _ = try await conversationDelivery(f, peer, since: publicFollowerBoundary, messageId: publicFollower, agentId: aId)

        let privateParent = try await conversationChannel(f, owner: owner, name: "conversation-private")
        #expect(try await f.http("PATCH", "/api/channels/\(privateParent)", token: owner, body: .init(["visibility": .string("private")])).status == 200)
        let privateMessage = try await conversationSend(f, owner: owner, channel: privateParent, content: "Private parent before the agent joins")
        let privateThread = try await conversationThread(f, owner: owner, parent: privateParent, message: privateMessage)
        #expect(try await f.http("POST", "/api/channels/\(privateParent)/members", token: owner, body: .init(["agentId": .string(aId)])).status == 200)
        let privateBoundary = peer.socket.count
        let privateMention = try await conversationMention(f, owner: owner, channel: privateThread, id: aId, name: aName)
        try await conversationAssertCommittedDelivery(f, messageId: privateMention, channelId: privateThread, agentIds: [aId])
        let privateFrame = try await conversationDelivery(f, peer, since: privateBoundary, messageId: privateMention, agentId: aId)
        #expect(privateFrame.object("message")?.string("parent_channel_type") == "private")
        #expect(try await f.http("DELETE", "/api/channels/\(privateParent)/members/agent/\(aId)", token: owner).status == 200)
        let revoked = try await conversationSend(f, owner: owner, channel: privateThread, content: "A stale follow cannot bypass revoked private parent access")
        try await conversationAssertNoDelivery(f, messageId: revoked)

        // Runtime completion is its own durable ingress fact, never a chat reply.
        let beforeOutcome = try await f.audit()
        let outcomeBoundary = peer.socket.count
        try await peer.socket.send(.init(["type": .string("agent:runtime:outcome"), "v": .integer(1), "agentId": .string(aId),
            "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(0), "launchId": .string(try start.requireString("launchId")),
            "sessionId": .null, "outcome": .object(["kind": .string("turn_completed")])]))
        do {
            _ = try await peer.socket.nextObject(since: outcomeBoundary) {
                $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == aId
                    && $0.string("daemonInstanceId") == peer.daemonId && $0.integer("clientSeq") == 0
            }
        } catch {
            let failed = try await f.audit()
            let state = failed.execution.agents[aId]
            let launchId = try start.requireString("launchId")
            Issue.record(Comment(rawValue: "outcome wait failed: agent=\(aId) launch=\(launchId) current=\(state?.currentLaunchId ?? "nil") daemon=\(state?.launches[launchId]?.daemonInstanceId ?? "nil") recovery=\(state?.needsManual ?? "nil")"))
            throw error
        }
        let afterOutcome = try await f.audit()
        #expect(afterOutcome.messages.map(\.fields) == beforeOutcome.messages.map(\.fields))
        #expect(afterOutcome.execution.agents[aId]?.launches[try start.requireString("launchId")]?.completed == true)
        let me = try await f.http("GET", "/api/auth/me", token: owner)
        #expect(me.status == 200)
        let ownerName = try me.object().requireString("name")
        let runnerKey = try #require(start.object("config")).requireString("agentCredentialKey")
        let responseText = "Independent internal-send response, not generated from an outcome"
        let response = try await f.http("POST", "/internal/agent-api/send", token: runnerKey,
            body: .init(["target": .string("dm:@\(ownerName)~human"), "content": .string(responseText), "idempotencyKey": .string("conversation-reply-once")]))
        #expect(response.status == 200)
        #expect((try await f.audit()).messages.contains { $0.string("channelId") == dm && $0.string("senderId") == aId && $0.string("content") == responseText })

        try await conversationJointRefusals(f, owner: owner, member: member, ownerName: ownerName)

        // Unassigned and offline are readable-only, with no hidden future queue.
        let noMachine = try await conversationSend(f, owner: owner, channel: unassignedDM, content: "Unassigned DM stays readable only")
        try await conversationAssertNoDelivery(f, messageId: noMachine)
        #expect(try await f.http("POST", "/api/agents/\(aId)/stop", token: owner).status == 200)
        let held = try await conversationSend(f, owner: owner, channel: dm, content: "Manual stop retains an explicit held DM")
        let heldAudit = try await f.audit()
        #expect(heldAudit.execution.heldDeliveries?.values.contains { $0.messageId == held && $0.agentId == aId } == true)
        #expect(!heldAudit.execution.commands.values.contains { $0.messageId == held })
        await peer.socket.close()
        machine = nil
        try await protocolPGEventually { try await f.audit().execution.connections[machineId]?.online == false }
        let offlineBody = ProtocolPGObject(["channelId": .string(bDM), "content": .string("Offline DM has no future delivery"), "randomId": .string("offline-dm-once")])
        let offline = try await f.http("POST", "/api/messages", token: owner, body: offlineBody)
        try #require(offline.status == 200)
        let offlineId = try offline.object().requireString("id")
        try await conversationAssertNoDelivery(f, messageId: offlineId)
        let reconnected = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: machineKey)
        machine = reconnected
        try await reconnected.sendControlledReady()
        let offlineReplay = try await f.http("POST", "/api/messages", token: owner, body: offlineBody)
        #expect(offlineReplay.status == 200)
        #expect(try offlineReplay.object().string("id") == offlineId)
        try await conversationAssertNoDelivery(f, messageId: offlineId)
    } catch {
        await f.close(machine: machine)
        throw error
    }
    await f.close(machine: machine)
}

private func conversationAgent(_ f: AgentExecutionPostgresFixture, owner: String, name: String, machineId: String?) async throws -> ProtocolPGObject {
    var fields: [String: JSONValue] = ["name": .string(name), "runtimeConfig": .object(["version": .integer(1), "runtime": .string("codex"), "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")])])]
    if let machineId { fields["machineId"] = .string(machineId) }
    let reply = try await f.http("POST", "/api/agents", token: owner, body: .init(fields))
    try #require(reply.status == 200)
    return try reply.object()
}
private func conversationCreatorDM(_ f: AgentExecutionPostgresFixture, owner: String, agentId: String) async throws -> String {
    let reply = try await f.http("GET", "/api/channels/dm", token: owner)
    try #require(reply.status == 200)
    guard case .array(let values) = try JSONDecoder().decode(JSONValue.self, from: reply.body) else { throw ProtocolPGFailure.invalidResponse }
    let rows = values.compactMap { value -> ProtocolPGObject? in guard case .object(let fields) = value else { return nil }; return .init(fields) }
    return try #require(rows.first { $0.string("peerType") == "agent" && $0.string("peerId") == agentId }).requireString("id")
}
private func conversationChannel(_ f: AgentExecutionPostgresFixture, owner: String, name: String) async throws -> String {
    let reply = try await f.http("POST", "/api/channels", token: owner, body: .init(["name": .string(name)]))
    try #require(reply.status == 200)
    return try reply.object().requireString("id")
}
private func conversationThread(_ f: AgentExecutionPostgresFixture, owner: String, parent: String, message: String) async throws -> String {
    let reply = try await f.http("POST", "/api/channels/\(parent)/threads", token: owner, body: .init(["parentMessageId": .string(message)]))
    try #require(reply.status == 200)
    return try reply.object().requireString("threadChannelId")
}
private func conversationSend(_ f: AgentExecutionPostgresFixture, owner: String, channel: String, content: String, v2: Bool = false) async throws -> String {
    let reply = try await f.http("POST", v2 ? "/api/v2/messages" : "/api/messages", token: owner, body: .init(["channelId": .string(channel), "content": .string(content)]))
    try #require(reply.status == 200)
    let object = try reply.object()
    return try (object.object("message") ?? object).requireString("id")
}
private func conversationMention(_ f: AgentExecutionPostgresFixture, owner: String, channel: String, id: String, name: String, randomId: String? = nil) async throws -> String {
    var fields: [String: JSONValue] = ["channelId": .string(channel), "content": .string("@\(name) explicit thread mention"),
        "mentions": .array([.object(["type": .string("agent"), "id": .string(id), "name": .string(name)])])]
    if let randomId { fields["randomId"] = .string(randomId) }
    let reply = try await f.http("POST", "/api/messages", token: owner, body: .init(fields))
    try #require(reply.status == 200)
    let object = try reply.object()
    return try (object.object("message") ?? object).requireString("id")
}
private func conversationAssertCommittedDelivery(_ f: AgentExecutionPostgresFixture, messageId: String, channelId: String, agentIds: Set<String>) async throws {
    let audit = try await f.audit()
    #expect(audit.messages.filter { $0.string("id") == messageId && $0.string("channelId") == channelId }.count == 1)
    let commands = audit.execution.commands.values.filter { $0.kind == .delivery && $0.messageId == messageId }
    #expect(commands.count == agentIds.count)
    try #require(Set(commands.map(\.agentId)) == agentIds)
    for command in commands {
        #expect(command.serverId == f.serverId && command.channelId == channelId)
        let effect = try #require(try await f.outbox(command.commandId))
        #expect(effect.writerEpoch > 0 && effect.effect.kind.rawValue == "agent.execution")
        #expect(try JSONDecoder().decode(AgentExecutionIntentReference.self, from: effect.effect.payload).commandId == command.commandId)
    }
}
private func conversationAssertNoDelivery(_ f: AgentExecutionPostgresFixture, messageId: String,
    sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let audit = try await f.audit()
    let row = audit.messages.first { $0.string("id") == messageId }
    let commands = audit.execution.commands.values.filter { $0.messageId == messageId }
    let detail = Comment(rawValue: "message=\(messageId) content=\(row?.string("content") ?? "missing") commands=\(commands.map { "\($0.agentId):\($0.launchId):\($0.status)" })")
    #expect(audit.messages.contains { $0.string("id") == messageId }, detail, sourceLocation: sourceLocation)
    #expect(!audit.execution.commands.values.contains { $0.messageId == messageId }, detail, sourceLocation: sourceLocation)
    #expect(audit.execution.heldDeliveries?.values.contains { $0.messageId == messageId } != true, detail, sourceLocation: sourceLocation)
}
private func conversationDelivery(_ f: AgentExecutionPostgresFixture, _ peer: ControlledMachineProtocolPeer, since: Int, messageId: String, agentId: String,
    sourceLocation: SourceLocation = #_sourceLocation) async throws -> ProtocolPGObject {
    do {
        let frame = try await peer.socket.nextObject(since: since) { $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == messageId && $0.string("agentId") == agentId }
        #expect(frame.string("agentId") == agentId, sourceLocation: sourceLocation)
        try await peer.acknowledgeControlledDelivery(frame)
        return frame
    } catch {
        let audit = try await f.audit()
        let state = audit.execution.agents[agentId]
        let commands = audit.execution.commands.values.filter { $0.messageId == messageId }
        let row = audit.messages.first { $0.string("id") == messageId }
        Issue.record(Comment(rawValue: "delivery wait failed: message=\(messageId) content=\(row?.string("content") ?? "missing") agent=\(agentId) current=\(state?.currentLaunchId ?? "nil") recovery=\(state?.needsManual ?? "nil") commands=\(commands.map { "\($0.launchId):\($0.status)" })"), sourceLocation: sourceLocation)
        throw error
    }
}

/// Build native joint facts through the published management/task/thread paths.
/// These assertions prove an honest refusal, not Node joint participant parity.
private func conversationJointRefusals(_ f: AgentExecutionPostgresFixture, owner: String, member: String, ownerName: String) async throws {
    let slug = "conversation-joint-\(UUID().uuidString.lowercased().prefix(8))"
    let server = try await f.http("POST", "/api/servers", token: owner, body: .init(["name": .string("Joint peer"), "slug": .string(slug)]))
    try #require(server.status == 200 || server.status == 201)
    let peerServer = try server.object().requireString("id")
    let created = try await f.http("POST", "/api/channels", token: owner,
        body: .init(["name": .string("conversation-joint"), "visibility": .string("joint"), "targetServerSlug": .string(slug), "invitedPeople": .array([.string("@\(ownerName)")])]))
    try #require(created.status == 200)
    let canonical = try created.object().requireString("id")
    let invitation = try #require(try created.object().object("jointInvite")).requireString("id")
    let accepted = try await conversationScopedHTTP(f, "POST", "/api/channels/joint-invites/\(invitation)/accept", token: owner, serverId: peerServer)
    try #require(accepted.status == 200)
    let local = try accepted.object().requireString("id")
    // The existing task writer supplies a real canonical parent without relying
    // on the unsupported human-send path or injecting a message/store callback.
    let tasks = try await f.http("POST", "/api/tasks/channel/\(canonical)", token: owner,
        body: .init(["tasks": .array([.object(["title": .string("Joint thread refusal parent")])])]))
    try #require(tasks.status == 200)
    let first = try #require(try tasks.object().array("tasks")?.first)
    guard case .object(let task) = first else { throw ProtocolPGFailure.invalidResponse }
    let parent = try ProtocolPGObject(task).requireString("messageId")
    let canonicalThread = try await conversationThread(f, owner: owner, parent: canonical, message: parent)
    let before = try await f.audit()
    for (serverId, channelId) in [(f.serverId, canonical), (peerServer, local), (f.serverId, canonicalThread)] {
        for path in ["/api/messages", "/api/v2/messages"] {
            let refused = try await conversationScopedHTTP(f, "POST", path, token: owner, serverId: serverId,
                body: .init(["channelId": .string(channelId), "content": .string("Unsupported joint mutation sentinel"), "randomId": .string("joint-refusal-\(channelId)")]))
            #expect(refused.status == 503)
            #expect(try refused.object().string("code") == "human_delivery_scope_unsupported")
        }
    }
    // Authorization retains precedence over disclosure of capability limits.
    let forbidden = try await f.http("POST", "/api/messages", token: member,
        body: .init(["channelId": .string(canonical), "content": .string("Unauthorized joint caller")]))
    #expect(forbidden.status == 403)
    let wrongServer = try await conversationScopedHTTP(f, "POST", "/api/messages", token: owner, serverId: peerServer,
        body: .init(["channelId": .string(canonical), "content": .string("Foreign canonical caller")]))
    #expect(wrongServer.status == 404)
    let after = try await f.audit()
    #expect(after.messages.map(\.fields) == before.messages.map(\.fields))
    #expect(after.tasks.map(\.fields) == before.tasks.map(\.fields))
    #expect(after.execution.commands.count == before.execution.commands.count)
    #expect(after.execution.heldDeliveries?.count == before.execution.heldDeliveries?.count)
}

/// Explicit second-server header on the same fixture's actual loopback listener.
private func conversationScopedHTTP(_ f: AgentExecutionPostgresFixture, _ method: String, _ path: String,
    token: String, serverId: String, body: ProtocolPGObject? = nil) async throws -> ProtocolPGHTTPResponse {
    guard path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: path, relativeTo: f.baseURL),
          url.host == "127.0.0.1", url.port == f.baseURL.port else { throw ProtocolPGFailure.invalidResponse }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(serverId, forHTTPHeaderField: "X-Server-Id")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body { request.httpBody = try body.data }
    let (bytes, response) = try await f.session.data(for: request)
    guard let response = response as? HTTPURLResponse, response.url?.host == "127.0.0.1",
          response.url?.port == f.baseURL.port, bytes.count <= 2 * 1024 * 1024 else { throw ProtocolPGFailure.invalidResponse }
    return .init(status: response.statusCode, body: bytes)
}
