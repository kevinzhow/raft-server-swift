import Foundation
import RaftPersistence
import RaftShared
import Testing
import TestSupport
@testable import RaftHTTP

private let mentionPGEnabled = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_PG_ACCEPTANCE"] == "1"

/// Fresh owned local PG + actual HTTP/NIO, with a controlled protocol peer.
/// Run this exact filter alone. No official Computer, OS process, model result,
/// provider acceptance or real mailbox delivery is asserted by these ACKs.
@Test(.enabled(if: mentionPGEnabled), .serialized)
func postgresMentionActionsRequireActualAgentReceiptsAndAtomicClaims() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    var machine: ControlledMachineProtocolPeer?
    var offlineMachine: ControlledMachineProtocolPeer?
    var subscriber: ProtocolPGSocket?
    do {
        let owner = try await f.login(f.ownerEmail)
        let member = try await f.login(f.memberEmail)
        let ownerId = try #require(f.runtime.withCommittedReadView { f.accounts.authCore.sessionIdentity(accessToken: owner)?.userId })
        let memberId = try #require(f.runtime.withCommittedReadView { f.accounts.authCore.sessionIdentity(accessToken: member)?.userId })
        let humanName = "MentionHuman109"
        try await f.runtime.execute { f.accounts.setAccountProfileForTesting(id: memberId, name: humanName) }
        let attached = try await f.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Mention controlled protocol peer")]))
        try #require(attached.status == 201)
        let machineId = try attached.object().requireString("machineId")
        let machineKey = try attached.object().requireString("apiKey")
        let offlineAttached = try await f.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Mention real disconnect peer")]))
        try #require(offlineAttached.status == 201)
        let offlineMachineId = try offlineAttached.object().requireString("machineId")
        let offlineKey = try offlineAttached.object().requireString("apiKey")
        let runtimeConfig: JSONValue = .object(["version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")])])
        func createAgent(_ name: String, machine: String) async throws -> String {
            let reply = try await f.http("POST", "/api/agents", token: owner,
                body: .init(["name": .string(name), "machineId": .string(machine), "runtimeConfig": runtimeConfig]))
            try #require(reply.status == 200)
            #expect(try reply.object().string("name") == name)
            return try reply.object().requireString("id")
        }
        // All agent creations and actor membership precede real ready, so a
        // create-time automatic start cannot masquerade as mention delivery.
        let actorName = "MentionActor109"
        let receiverName = "MentionReceiver109"
        let offlineName = "MentionOffline109"
        let actor = try await createAgent(actorName, machine: machineId)
        let receiver = try await createAgent(receiverName, machine: machineId)
        let offlineReceiver = try await createAgent(offlineName, machine: offlineMachineId)
        func channel(_ name: String) async throws -> String {
            let reply = try await f.http("POST", "/api/channels", token: owner, body: .init(["name": .string(name)]))
            try #require(reply.status == 200)
            return try reply.object().requireString("id")
        }
        let agentRoomName = "mention-agent-group"
        let agentRoom = try await channel(agentRoomName)
        let humanRoom = try await channel("mention-human-group")
        let addAgentRoom = try await channel("mention-add-agent")
        let addHumanRoom = try await channel("mention-add-human")
        let deniedRoom = try await channel("mention-current-read")
        let offlineRoom = try await channel("mention-offline")
        let stoppedRoom = try await channel("mention-stopped")
        let rollbackRoom = try await channel("mention-rollback")
        let conflictRoom = try await channel("mention-real-cas")
        let joined = try await f.http("POST", "/api/channels/\(agentRoom)/members", token: owner,
            body: .init(["agentId": .string(actor)]))
        try #require(joined.status == 200)
        let updates = try await f.subscriber(token: owner); subscriber = updates
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: machineKey); machine = peer
        try await peer.sendControlledReady()
        print("mention109 diagnostic: inventorySnapshot.begin")
        let ready = try await MentionPGSnapshot.read(f)
        #expect(ready.execution.connections[machineId]?.ready == true)
        #expect(ready.execution.commands.isEmpty)
        print("mention109 diagnostic: inventorySnapshot.ok")
        print("mention109 diagnostic: actorStart.begin")
        let actorBoundary = peer.socket.count
        try #require(try await f.http("POST", "/api/agents/\(actor)/start", token: owner).status == 200)
        let actorFrame = try await mentionPGStartReceipt(f, peer: peer, agent: actor, since: actorBoundary, human: true)
        let actorConfig = try #require(actorFrame.object("config"))
        let actorKey = try actorConfig.requireString("agentCredentialKey")
        #expect(actorConfig.object("runtimeContext")?.string("agentId") == actor)
        print("mention109 diagnostic: actorStart.ok")

        // Original agent-target oracle: two different real agent-authored hosts,
        // one unique persisted mention each. Never seed duplicate same-host rows.
        print("mention109 diagnostic: firstSend.begin")
        let first = try await mentionPGAgentSend(f, key: actorKey, channelName: agentRoomName,
            target: receiver, name: receiverName, text: "First agent host", v2: false)
        print("mention109 diagnostic: firstSend.ok")
        print("mention109 diagnostic: secondSend.begin")
        let second = try await mentionPGAgentSend(f, key: actorKey, channelName: agentRoomName,
            target: receiver, name: receiverName, text: "Second agent host", v2: true)
        print("mention109 diagnostic: secondSend.ok")
        #expect(first.messageId != second.messageId && first.resolutionId != second.resolutionId)
        let pending = try await f.http("GET", "/internal/agent-api/mention-actions/pending", token: actorKey)
        try #require(pending.status == 200)
        let pendingRows = try mentionPGRows(pending.object(), "pendingMentionActions")
        #expect(Set(pendingRows.compactMap { $0.string("resolutionId") }) == [first.resolutionId, second.resolutionId])
        #expect(Set(pendingRows.compactMap { $0.string("messageId") }) == [first.messageId, second.messageId])
        let unclaimed = try await MentionPGSnapshot.read(f)
        try mentionPGClaim(unclaimed, hosts: [first, second], actor: actor, actorType: "agent", channel: agentRoom, target: receiver, action: nil)
        #expect(try !unclaimed.member("channelAgents", channel: agentRoom, id: receiver))
        #expect(unclaimed.execution.agents[receiver] == nil)
        let foreign = try await mentionPGAction(f, token: owner, ids: [first.resolutionId], action: "notify")
        #expect(foreign.string("status") == "not_found")
        #expect(!mentionPGHasValue(foreign, "messageId") && !mentionPGHasValue(foreign, "targetId"))
        let groupBoundary = peer.socket.count
        let group = try await mentionPGAction(f, token: actorKey, ids: [first.resolutionId], action: "notify", agent: true)
        #expect(group.string("status") == "queued")
        #expect(try mentionPGStrings(group, "dedupedResolutionIds") == [first.resolutionId, second.resolutionId])
        #expect(group.string("messageId") == first.messageId && group.string("channelId") == agentRoom)
        #expect(group.string("targetType") == "agent" && group.string("targetId") == receiver)
        let claimed = try await MentionPGSnapshot.read(f)
        try mentionPGClaim(claimed, hosts: [first, second], actor: actor, actorType: "agent", channel: agentRoom, target: receiver, action: "notify_only")
        #expect(try !claimed.member("channelAgents", channel: agentRoom, id: receiver))
        #expect(claimed.execution.commands.values.filter { $0.kind == .delivery && $0.agentId == receiver && [first.messageId, second.messageId].contains($0.messageId ?? "") }.count == 1)
        try await mentionPGStartReceipt(f, peer: peer, agent: receiver, since: groupBoundary, human: false)
        _ = try await mentionPGDeliveryReceipt(f, peer: peer, agent: receiver, host: first, channel: agentRoom, since: groupBoundary)
        let beforeRetry = try await MentionPGSnapshot.read(f)
        let retryBoundary = peer.socket.count
        let replay = try await mentionPGAction(f, token: actorKey, ids: [first.resolutionId, first.resolutionId], action: "notify", agent: true)
        #expect(replay.string("status") == "queued" && replay.string("reason") == "already_queued")
        #expect(try mentionPGStrings(replay, "dedupedResolutionIds") == [first.resolutionId])
        let rejectedAgentAdd = try await mentionPGAction(f, token: actorKey, ids: [first.resolutionId], action: "add", agent: true)
        #expect(rejectedAgentAdd.string("status") == "no_permission")
        #expect(rejectedAgentAdd.string("reason") == "add_requires_human_member_authority")
        let afterRetry = try await MentionPGSnapshot.read(f)
        #expect(Set(afterRetry.execution.commands.keys) == Set(beforeRetry.execution.commands.keys))
        try mentionPGClaim(afterRetry, hosts: [first, second], actor: actor, actorType: "agent", channel: agentRoom, target: receiver, action: "notify_only")
        #expect(try !afterRetry.member("channelAgents", channel: agentRoom, id: receiver))
        try await mentionPGNoAgentFrames(peer, since: retryBoundary)

        // The separate human v1/v2 group cannot absorb the agent-authored group.
        let humanFirst = try await mentionPGHumanSend(f, token: owner, channel: humanRoom,
            targetType: "agent", target: receiver, name: receiverName, text: "First human host")
        let humanSecond = try await mentionPGHumanSend(f, token: owner, channel: humanRoom,
            targetType: "agent", target: receiver, name: receiverName, text: "Second human host", v2: true)
        let humanBoundary = peer.socket.count
        let humanResult = try await mentionPGAction(f, token: owner, ids: [humanFirst.resolutionId], action: "notify")
        #expect(humanResult.string("status") == "queued")
        #expect(try mentionPGStrings(humanResult, "dedupedResolutionIds") == [humanFirst.resolutionId, humanSecond.resolutionId])
        let humanSQL = try await MentionPGSnapshot.read(f)
        try mentionPGClaim(humanSQL, hosts: [humanFirst, humanSecond], actor: ownerId, actorType: "user", channel: humanRoom, target: receiver, action: "notify_only")
        #expect(try !humanSQL.member("channelAgents", channel: humanRoom, id: receiver))
        _ = try await mentionPGDeliveryReceipt(f, peer: peer, agent: receiver, host: humanFirst, channel: humanRoom, since: humanBoundary)

        let addAgent = try await mentionPGHumanSend(f, token: owner, channel: addAgentRoom,
            targetType: "agent", target: receiver, name: receiverName, text: "Join via actual human authority")
        let addBoundary = peer.socket.count
        let added = try await mentionPGAction(f, token: owner, ids: [addAgent.resolutionId], action: "add")
        #expect(added.string("status") == "delivered")
        let addedSQL = try await MentionPGSnapshot.read(f)
        #expect(try addedSQL.member("channelAgents", channel: addAgentRoom, id: receiver))
        try mentionPGClaim(addedSQL, hosts: [addAgent], actor: ownerId, actorType: "user", channel: addAgentRoom, target: receiver, action: "add")
        // Membership delivered alone is not an agent receipt. Prove this ready
        // target's separate best-effort typed delivery through the real ACK.
        _ = try await mentionPGDeliveryReceipt(f, peer: peer, agent: receiver, host: addAgent, channel: addAgentRoom, since: addBoundary)
        let beforeAddReplay = try await MentionPGSnapshot.read(f)
        let addReplayBoundary = peer.socket.count
        let addReplay = try await mentionPGAction(f, token: owner, ids: [addAgent.resolutionId], action: "add")
        #expect(addReplay.string("status") == "delivered" && addReplay.string("reason") == "already_delivered")
        #expect(Set(try await MentionPGSnapshot.read(f).execution.commands.keys) == Set(beforeAddReplay.execution.commands.keys))
        try await mentionPGNoAgentFrames(peer, since: addReplayBoundary)
        let addHuman = try await mentionPGHumanSend(f, token: owner, channel: addHumanRoom,
            targetType: "user", target: memberId, name: humanName, text: "Human authority adds actual human")
        // This independent human-target axis carries the original 16-way ADD
        // oracle through real HTTP/BPR; the agent ADD receipt above stays intact.
        let humanBefore = try await MentionPGSnapshot.read(f)
        #expect(try !humanBefore.member("channelHumans", channel: addHumanRoom, id: memberId))
        try mentionPGClaim(humanBefore, hosts: [addHuman], actor: ownerId, actorType: "user", channel: addHumanRoom, target: memberId, action: nil)
        let humanAddBoundary = peer.socket.count
        let humanAdds = try await withThrowingTaskGroup(of: ProtocolPGObject.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await mentionPGAction(f, token: owner, ids: [addHuman.resolutionId], action: "add")
                }
            }
            var responses: [ProtocolPGObject] = []
            for try await response in group { responses.append(response) }
            return responses
        }
        #expect(humanAdds.count == 16)
        #expect(humanAdds.allSatisfy { $0.string("status") == "delivered" })
        #expect(humanAdds.filter { $0.string("status") == "delivered" && !mentionPGHasValue($0, "reason") }.count == 1)
        #expect(humanAdds.filter { $0.string("status") == "delivered" && $0.string("reason") == "already_delivered" }.count == 15)
        #expect(humanAdds.allSatisfy {
            $0.string("resolutionId") == addHuman.resolutionId && $0.string("action") == "add"
                && $0.string("messageId") == addHuman.messageId && $0.string("channelId") == addHumanRoom
                && $0.string("targetType") == "user" && $0.string("targetId") == memberId
        })
        let humanAddedSQL = try await MentionPGSnapshot.read(f)
        #expect(try humanAddedSQL.member("channelHumans", channel: addHumanRoom, id: memberId))
        let humanMembers = try #require(humanAddedSQL.oauth.array("channelHumans"))
        #expect(humanMembers.filter { $0 == .string("\(addHumanRoom)\n\(memberId)") }.count == 1)
        try mentionPGClaim(humanAddedSQL, hosts: [addHuman], actor: ownerId, actorType: "user", channel: addHumanRoom, target: memberId, action: "add")
        #expect(Set(humanAddedSQL.execution.commands.keys) == Set(humanBefore.execution.commands.keys))
        try await mentionPGNoAgentFrames(peer, since: humanAddBoundary)
        let humanReplayBoundary = peer.socket.count
        let humanReplay = try await mentionPGAction(f, token: owner, ids: [addHuman.resolutionId], action: "add")
        #expect(humanReplay.string("status") == "delivered" && humanReplay.string("reason") == "already_delivered")
        let humanRetriedSQL = try await MentionPGSnapshot.read(f)
        let unchangedHumanClaim = try humanRetriedSQL.mention(addHuman.resolutionId).fields == humanAddedSQL.mention(addHuman.resolutionId).fields
        #expect(unchangedHumanClaim)
        #expect(try humanRetriedSQL.member("channelHumans", channel: addHumanRoom, id: memberId))
        #expect(Set(humanRetriedSQL.execution.commands.keys) == Set(humanAddedSQL.execution.commands.keys))
        try await mentionPGNoAgentFrames(peer, since: humanReplayBoundary)

        // The pending row was legitimate at send. A public visibility transition
        // revokes current target read without granting a private participant.
        let restricted = try await mentionPGHumanSend(f, token: owner, channel: deniedRoom,
            targetType: "agent", target: receiver, name: receiverName, text: "Read permission changes after send")
        let changed = try await f.http("PATCH", "/api/channels/\(deniedRoom)", token: owner,
            body: .init(["visibility": .string("private")]))
        try #require(changed.status == 200)
        let deniedBefore = try await MentionPGSnapshot.read(f)
        let deniedBoundary = peer.socket.count
        let denied = try await mentionPGAction(f, token: owner, ids: [restricted.resolutionId], action: "notify")
        #expect(denied.string("status") == "no_permission" && denied.string("reason") == "target_lacks_read_access")
        let deniedSQL = try await MentionPGSnapshot.read(f)
        try mentionPGClaim(deniedSQL, hosts: [restricted], actor: ownerId, actorType: "user", channel: deniedRoom, target: receiver, action: nil)
        #expect(try !deniedSQL.member("channelAgents", channel: deniedRoom, id: receiver))
        #expect(Set(deniedSQL.execution.commands.keys) == Set(deniedBefore.execution.commands.keys))
        try await mentionPGNoAgentFrames(peer, since: deniedBoundary)

        // Authenticate and disconnect a separate real machine. The main peer
        // stays live for the other receipts and the two discard barriers.
        let disconnected = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: offlineKey)
        offlineMachine = disconnected
        try await disconnected.sendControlledReady()
        await disconnected.socket.close()
        try await protocolPGEventually { try await f.audit().execution.connections[offlineMachineId]?.online == false }
        let offlineHost = try await mentionPGHumanSend(f, token: owner, channel: offlineRoom,
            targetType: "agent", target: offlineReceiver, name: offlineName, text: "Readable when truly disconnected")
        let offlineBefore = try await MentionPGSnapshot.read(f)
        let offline = try await mentionPGAction(f, token: owner, ids: [offlineHost.resolutionId], action: "notify")
        #expect(offline.string("status") == "dropped" && offline.string("reason") == "target_not_queued")
        let offlineSQL = try await MentionPGSnapshot.read(f)
        try mentionPGClaim(offlineSQL, hosts: [offlineHost], actor: ownerId, actorType: "user", channel: offlineRoom, target: offlineReceiver, action: nil)
        #expect(Set(offlineSQL.execution.commands.keys) == Set(offlineBefore.execution.commands.keys))
        #expect(offlineSQL.execution.heldDeliveries?.count == offlineBefore.execution.heldDeliveries?.count)
        let offlineHistory = try await f.http("GET", "/api/messages/channel/\(offlineRoom)", token: owner)
        #expect(offlineHistory.status == 200 && String(decoding: offlineHistory.body, as: UTF8.self).contains(offlineHost.messageId))

        let stopBoundary = peer.socket.count
        let stop = try await f.http("POST", "/api/agents/\(receiver)/stop", token: owner)
        try #require(stop.status == 200)
        _ = try await peer.socket.nextObject(since: stopBoundary) { $0.string("type") == "agent:stop" && $0.string("agentId") == receiver }
        let stoppedSQL = try await MentionPGSnapshot.read(f)
        let stopIntent = try #require(stoppedSQL.execution.stopIntents?.values.first { $0.agentId == receiver && $0.clearedByHumanStart == nil })
        try await protocolPGEventually { try await f.outbox(stopIntent.commandId)?.deliveredAt != nil }
        #expect(stoppedSQL.oauth.object("agents")?.object(receiver)?.string("status") == "stopped")
        let stoppedHost = try await mentionPGHumanSend(f, token: owner, channel: stoppedRoom,
            targetType: "agent", target: receiver, name: receiverName, text: "Preserve readable work under manual stop")
        let stoppedBefore = try await MentionPGSnapshot.read(f)
        let stoppedBoundary = peer.socket.count
        let stopped = try await mentionPGAction(f, token: owner, ids: [stoppedHost.resolutionId], action: "notify")
        #expect(stopped.string("status") == "dropped" && stopped.string("reason") == "target_not_queued")
        let stoppedAfter = try await MentionPGSnapshot.read(f)
        try mentionPGClaim(stoppedAfter, hosts: [stoppedHost], actor: ownerId, actorType: "user", channel: stoppedRoom, target: receiver, action: nil)
        #expect(Set(stoppedAfter.execution.commands.keys) == Set(stoppedBefore.execution.commands.keys))
        #expect(stoppedAfter.execution.heldDeliveries?.count == stoppedBefore.execution.heldDeliveries?.count)
        #expect(stoppedAfter.oauth.object("agents")?.object(receiver)?.string("status") == "stopped")
        try await mentionPGNoAgentFrames(peer, since: stoppedBoundary, agent: receiver)
        let stoppedHistory = try await f.http("GET", "/api/messages/channel/\(stoppedRoom)", token: owner)
        #expect(stoppedHistory.status == 200 && String(decoding: stoppedHistory.body, as: UTF8.self).contains(stoppedHost.messageId))

        // Agent A remains legitimately active; B stays stopped. No fabricated
        // process exit or readiness change is used to make failure staging work.
        try await mentionPGDiscardBarriers(f, peer: peer, updates: updates, owner: owner,
            target: actor, name: actorName, rollbackRoom: rollbackRoom, conflictRoom: conflictRoom)
    } catch {
        await offlineMachine?.socket.close()
        await f.close(machine: machine, subscriber: subscriber)
        throw error
    }
    await offlineMachine?.socket.close()
    await f.close(machine: machine, subscriber: subscriber)
}
