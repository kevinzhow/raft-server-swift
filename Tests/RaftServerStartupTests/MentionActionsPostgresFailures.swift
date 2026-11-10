import Foundation
import RaftPersistence
import RaftShared
import Synchronization
import Testing
@testable import RaftHTTP
@testable import RaftServer

/// Retains only actual staged IDs and the independent SQL baseline. This is
/// failure evidence, never an authorization decision or a delivery receipt.
private struct MentionPGDiscardEvidence: Sendable, CustomStringConvertible {
    let documents: [DurableDocument]
    let host: MentionPGHost
    let commands: [UUID]
    var description: String { "MentionPGDiscardEvidence(redacted)" }
}

private func mentionPGEqualSQL(_ before: [DurableDocument], _ after: [DurableDocument], revisionBump: Int64) {
    #expect(before.count == 14 && after.count == 14)
    #expect(Set(before.map(\.key)) == Set(after.map(\.key)))
    let samePayloads = Dictionary(uniqueKeysWithValues: before.map { ($0.key, $0.json) })
        == Dictionary(uniqueKeysWithValues: after.map { ($0.key, $0.json) })
    // Payloads contain credentials: never feed their bytes to a failure macro.
    #expect(samePayloads, "All fourteen full SQL owner payloads must remain unchanged")
    for prior in before {
        let next = after.first { $0.key == prior.key }
        #expect(next?.codecVersion == prior.codecVersion)
        #expect(next?.revision == prior.revision + revisionBump)
    }
}

private func mentionPGStageAction(_ f: AgentExecutionPostgresFixture, owner: String, target: String,
                                  request: HumanMessageCreateRequest, documents: [DurableDocument]) throws -> MentionPGDiscardEvidence {
    // This is the existing retained production facade, not a producer-only
    // fixture, replacement writer, callback, or post-activate owner allocation.
    let service = f.accounts.humanMessageCreate.bindingExecution(f.accounts.agentExecution(persistence: f.runtime))
    let before = Set(f.accounts.agentsRuntimeStore.state.execution.commands.keys)
    let created = try service.createHumanMessage(request, authorization: "Bearer \(owner)", serverId: f.serverId, contract: .v2)
    let pending = try #require(created.pendingMentionActions.first)
    let actionBody = ProtocolPGObject(["action": .string("notify"), "resolutionIds": .array([.string(pending.resolutionId)])])
    let action = try JSONDecoder().decode(MentionActionsRequest.self, from: actionBody.data)
    let result = try service.executeMentionActions(action, authorization: "Bearer \(owner)", serverId: f.serverId)
    #expect(result.results.first?.status == "queued")
    let staged = f.accounts.agentsRuntimeStore.state.execution.commands.values.filter { !before.contains($0.commandId.uuidString) }
    try #require(!staged.isEmpty)
    #expect(staged.contains { $0.kind == .delivery && $0.agentId == target && $0.messageId == pending.messageId })
    return .init(documents: documents, host: .init(messageId: pending.messageId, resolutionId: pending.resolutionId), commands: staged.map(\.commandId))
}

private func mentionPGAssertDiscarded(_ f: AgentExecutionPostgresFixture, evidence: MentionPGDiscardEvidence,
                                      peer: ControlledMachineProtocolPeer, updates: ProtocolPGSocket,
                                      machineBoundary: Int, subscriberBoundary: Int, revisionBump: Int64) async throws {
    let after = try await MentionPGSnapshot.read(f)
    mentionPGEqualSQL(evidence.documents, after.documents, revisionBump: revisionBump)
    #expect(!after.messages.contains { $0.string("id") == evidence.host.messageId })
    #expect(!after.mentions.contains { $0.string("id") == evidence.host.resolutionId })
    for command in evidence.commands {
        #expect(after.execution.commands[command.uuidString] == nil)
        let effect = try await f.observer.outboxEffect(effectID: command)
        #expect(effect == nil)
    }
    try await mentionPGNoAgentFrames(peer, since: machineBoundary)
    let frames = try await updates.wireFence(since: subscriberBoundary)
    #expect(!frames.contains { $0.contains("message:new") || $0.contains("message:created") || $0.contains("agent:updated") })
}

func mentionPGDiscardBarriers(_ f: AgentExecutionPostgresFixture, peer: ControlledMachineProtocolPeer,
                              updates: ProtocolPGSocket, owner: String, target: String, name: String,
                              rollbackRoom: String, conflictRoom: String) async throws {
    // Finish all ordinary receipts before this call. Stop and await actual
    // consumers, so no unrelated worker commit moves the fourteen SQL revisions.
    await f.executionConnection.worker.stop()
    await f.pausePublications()
    try await peer.socket.applicationFence()
    _ = try await updates.wireFence(since: updates.count)
    let keys = try MentionPGSnapshot.keys()
    let rollbackInput = mentionPGInput(channel: rollbackRoom, targetType: "agent", target: target, name: name, text: "Real rollback-only host")
    let rollbackRequest = try JSONDecoder().decode(HumanMessageCreateRequest.self, from: rollbackInput.data)
    let rollbackEvidence = Mutex<MentionPGDiscardEvidence?>(nil)
    let rollbackMachineBoundary = peer.socket.count
    let rollbackSubscriberBoundary = updates.count
    do {
        try await f.runtime.execute {
            let baseline = try await f.observer.readSnapshot(keys)
            guard baseline.count == 14 else { throw ProtocolPGFailure.invalidSnapshot }
            let actual = try mentionPGStageAction(f, owner: owner, target: target, request: rollbackRequest, documents: baseline)
            rollbackEvidence.withLock { $0 = actual }
            DeferredEffects.markRollbackOnly()
        }
        Issue.record("Expected actual rollback-only prepare rejection")
        throw ProtocolPGFailure.invalidResponse
    } catch TransactionError.rollbackOnly {}
    let rolledBack = try #require(rollbackEvidence.withLock { $0 })
    try await mentionPGAssertDiscarded(f, evidence: rolledBack, peer: peer, updates: updates,
        machineBoundary: rollbackMachineBoundary, subscriberBoundary: rollbackSubscriberBoundary, revisionBump: 0)
    // The prior rollback does not fail-close admission; the second actual
    // transaction must reach its real claim/typed producer, not just return503.
    let writer = await f.runtime.persistence
    let epoch = await f.runtime.lease.epoch
    let conflictInput = mentionPGInput(channel: conflictRoom, targetType: "agent", target: target, name: name, text: "Real stale-CAS host")
    let conflictRequest = try JSONDecoder().decode(HumanMessageCreateRequest.self, from: conflictInput.data)
    let conflictEvidence = Mutex<MentionPGDiscardEvidence?>(nil)
    let conflictMachineBoundary = peer.socket.count
    let conflictSubscriberBoundary = updates.count
    do {
        try await f.runtime.execute {
            let baseline = try await f.observer.readSnapshot(keys)
            guard baseline.count == 14, Set(baseline.map(\.key)) == Set(keys) else { throw ProtocolPGFailure.invalidSnapshot }
            let actual = try mentionPGStageAction(f, owner: owner, target: target, request: conflictRequest, documents: baseline)
            conflictEvidence.withLock { $0 = actual }
            // Use the *actual lease-holding writer port* to commit identical
            // current payloads once. The observer never writes or borrows epoch.
            // BPR then really fails its own stale expected-revision CAS; this is
            // not a fake persistence result or a direct revision-minus-one probe.
            let writes = try baseline.map {
                try DurableWrite.put($0.decode(Data.self, codecVersion: 1), key: $0.key,
                                     codecVersion: $0.codecVersion, expectedRevision: $0.revision)
            }
            let bumped = try await writer.compareAndSwap(writes, expectedWriterEpoch: epoch)
            #expect(bumped.count == 14)
        }
        Issue.record("Expected the coordinator's actual stale revision CAS to fail")
        throw ProtocolPGFailure.invalidResponse
    } catch PersistenceError.conflict {}
    let conflicted = try #require(conflictEvidence.withLock { $0 })
    try await mentionPGAssertDiscarded(f, evidence: conflicted, peer: peer, updates: updates,
        machineBoundary: conflictMachineBoundary, subscriberBoundary: conflictSubscriberBoundary, revisionBump: 1)
    // This is the actual failure response, not a substitute for SQL evidence.
    let closed = try await f.http("GET", "/api/agents/\(target)", token: owner)
    #expect(closed.status == 503)
}
