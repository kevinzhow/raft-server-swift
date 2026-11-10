import Foundation
import RaftPersistence
import RaftShared
import Synchronization
import Testing
@testable import RaftHTTP

private let runtimePatchResetPGEnabled = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_PG_ACCEPTANCE"] == "1"
private enum RuntimePatchResetAbort: Error { case rollback }

private func resetPatchConfig(_ model: String, effort: String? = nil, env: String = "original") -> JSONValue {
    .object(["version": .integer(1), "runtime": .string("codex"),
        "model": .object(["kind": .string("preset"), "id": .string(model)]),
        "mode": .object(["kind": .string("default")]),
        "reasoningEffort": effort.map(JSONValue.string) ?? .null,
        "envVars": .object(["ORDINARY": .string(env)])])
}

private func resetPatchBody(_ model: String, effort: String? = nil, env: String = "original", mode: String? = nil) -> ProtocolPGObject {
    var body: [String: JSONValue] = ["runtimeConfig": resetPatchConfig(model, effort: effort, env: env),
        "runtime": .string("codex"), "model": .string(model),
        "reasoningEffort": effort.map(JSONValue.string) ?? .null,
        "envVars": .object(["ORDINARY": .string(env)])]
    if let mode { body["restartMode"] = .string(mode) }
    return .init(body)
}

private func resetPatchSessionEvent(_ text: String, agent: String) -> Bool {
    guard text.hasPrefix("42"),
          let values = try? JSONDecoder().decode([JSONValue].self, from: Data(text.dropFirst(2).utf8)),
          values.count == 2, values[0] == .string("agent:session"), case .object(let body) = values[1] else { return false }
    return body["agentId"] == .string(agent) && body["sessionId"] == .null
}

private func resetPatchProcess(_ peer: ControlledMachineProtocolPeer, agent: String, launch: String,
    process: String, sequence: Int64, exited: Bool) async throws {
    let boundary = peer.socket.count
    var body: [String: JSONValue] = ["type": .string(exited ? "agent:process_exited" : "agent:process_spawned"),
        "agentId": .string(agent), "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(sequence),
        "launchId": .string(launch), "processInstanceId": .string(process)]
    if exited { body["spawnLaunchId"] = .string(launch) }
    try await peer.socket.send(.init(body))
    _ = try await peer.socket.nextObject(since: boundary) {
        $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == agent && $0.integer("clientSeq") == sequence
    }
}

private func resetPatchSession(_ peer: ControlledMachineProtocolPeer, agent: String, launch: String, session: String) async throws {
    try await peer.socket.send(.init(["type": .string("agent:session"), "agentId": .string(agent),
        "launchId": .string(launch), "sessionId": .string(session)]))
    try await peer.socket.applicationFence()
}

private func resetPatchStoredConfig(_ audit: ProtocolPGAudit, agent: String) throws -> ProtocolPGObject {
    guard let json = audit.canonicalAgents.object(agent)?.string("runtimeConfigJSON") else { throw ProtocolPGFailure.invalidSnapshot }
    return try ProtocolPGObject(text: json)
}

private struct RuntimePatchNativeEvidence: Sendable {
    let start: ProtocolPGObject
    let process: String
    let nextSequence: Int64
}

/// This peer reports protocol facts. No OS process, Codex or provider is run.
private func proveCommittedPatchReset(_ f: AgentExecutionPostgresFixture, peer: ControlledMachineProtocolPeer,
    updates: ProtocolPGSocket, owner: String, agent: String, machine: String, old: RuntimePatchNativeEvidence,
    model: String, effort: String? = nil, env: String = "original", session: String?, human: Bool) async throws -> RuntimePatchNativeEvidence {
    let before = try await f.audit()
    let previous = try #require(before.execution.agents[agent])
    let oldIds = Set((before.execution.resetIntents ?? [:]).keys)
    let wireBoundary = peer.socket.count
    let publicationBoundary = updates.count
    let response = try await f.http("PATCH", "/api/agents/\(agent)", token: owner,
        body: resetPatchBody(model, effort: effort, env: env, mode: "restart"))
    try #require(response.status == 200)
    #expect(try response.object().string("model") == model)
    let committed = try await f.audit()
    #expect(try resetPatchStoredConfig(committed, agent: agent).object("model")?.string("id") == model)
    let added = (committed.execution.resetIntents ?? [:]).filter { !oldIds.contains($0.key) && $0.value.agentId == agent }
    // Current Source-before saves metadata and lifts, but stages no reset.
    // Fail here promptly; never wait for a nonexistent stop/start to time out.
    try #require(added.count == 1, "canonical PATCH must commit one owned reset, not merely return profile 200")
    let intent = try #require(added.values.first)
    #expect(intent.serverId == f.serverId && intent.agentId == agent && intent.machineId == machine)
    #expect(intent.mode == (session == nil ? .session : .restart))
    #expect(intent.restart)
    if previous.currentLaunchId != nil { #expect(intent.priorLaunchId == previous.currentLaunchId) }
    _ = try await peer.socket.nextObject(since: wireBoundary) { $0.string("type") == "agent:stop" && $0.string("agentId") == agent }
    // Stop is ACK-less. Only this authenticated historical exit report proves
    // the server received an exit fact; no workspace-cleanup receipt is invented.
    try await resetPatchProcess(peer, agent: agent, launch: old.start.requireString("launchId"),
        process: old.process, sequence: old.nextSequence, exited: true)
    let start = try await peer.socket.nextObject(since: wireBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agent }
    let launch = try start.requireString("launchId")
    #expect(launch != old.start.string("launchId"))
    #expect(start.bool("humanStart") == human)
    #expect(start.string("connectionEpochId") == peer.context.string("connectionEpochId"))
    let config = try #require(start.object("config"))
    #expect(config.string("model") == model && config.string("runtime") == "codex")
    #expect(config.fields["sessionId"] == (session.map(JSONValue.string) ?? .null))
    #expect(config.fields["reasoningEffort"] == (effort.map(JSONValue.string) ?? .null))
    #expect(config.object("envVars")?.string("ORDINARY") == env)
    try await peer.acknowledgeControlledStart(start)
    let process = "controlled-patch-\(UUID().uuidString.lowercased())"
    try await resetPatchProcess(peer, agent: agent, launch: launch, process: process, sequence: old.nextSequence + 1, exited: false)
    for id in [intent.stopPhaseId, intent.restartPhaseId, intent.startCommandId] {
        try await protocolPGEventually { try await f.outbox(id)?.deliveredAt != nil }
    }
    let settled = try await f.audit()
    let record = try #require(settled.execution.resetIntents?[intent.operationId.uuidString])
    let current = try #require(settled.execution.agents[agent])
    let command = try #require(settled.execution.commands[intent.startCommandId.uuidString])
    #expect(record.stopAttempt == .written && record.workspaceAttempt == .notAttempted)
    #expect(record.phase == .restartStaged && record.sessionCleared == (session == nil))
    #expect(record.connectionEpochId == peer.context.string("connectionEpochId") && record.daemonInstanceId == peer.daemonId)
    #expect(command.kind == .start && command.humanStart == human && command.sessionId == session)
    #expect(command.serverId == f.serverId && command.machineId == machine && command.launchId == launch)
    #expect(command.startDispatchId == start.string("startDispatchId") && command.status == .accepted)
    #expect(settled.execution.dispatches?[command.commandId.uuidString]?.phase == .accepted)
    #expect(current.currentLaunchId == launch && current.sessionId == session)
    #expect(current.processes[old.process]?.exited == true && current.processes[process]?.exited == false)
    #expect(current.launches[old.start.string("launchId") ?? ""] != nil)
    #expect(Set(before.execution.commands.keys).isSubset(of: Set(settled.execution.commands.keys)))
    #expect(settled.execution.stopIntents?.count == before.execution.stopIntents?.count)
    if !human {
        // One canonical new launch increments generation; no extra terminal lift.
        #expect(current.generation == previous.generation + 1 && current.takeoverEpoch == previous.takeoverEpoch)
        #expect(current.failureCount == previous.failureCount && current.needsManual == previous.needsManual)
    }
    let stopRow = try #require(try await f.outbox(intent.stopPhaseId))
    let reference = try JSONDecoder().decode(AgentExecutionResetReference.self, from: stopRow.effect.payload)
    #expect(stopRow.effect.kind.rawValue == "agent.execution" && stopRow.writerEpoch > 0)
    #expect(reference.resetOperationId == intent.operationId && reference.phase == .stop && reference.phaseId == intent.stopPhaseId)
    #expect(try await f.outbox(intent.workspacePhaseId) == nil)
    if session == nil {
        _ = try await updates.nextText(since: publicationBoundary) { resetPatchSessionEvent($0, agent: agent) }
        try await protocolPGEventually { try await f.outbox(intent.sessionPublicationId)?.deliveredAt != nil }
        let publicationRow = try #require(try await f.outbox(intent.sessionPublicationId))
        let publication = try JSONDecoder().decode(RealtimePublication.self, from: publicationRow.effect.payload)
        #expect(publication.eventId == intent.sessionPublicationId && publication.event == "agent:session")
        #expect(publication.room == "server:\(f.serverId)")
        #expect(try ProtocolPGObject(text: publication.payloadJSON).fields == ["agentId": .string(agent), "sessionId": .null])
    } else { #expect(try await f.outbox(intent.sessionPublicationId) == nil) }
    let events = try await updates.wireFence(since: publicationBoundary)
    #expect(events.filter { resetPatchSessionEvent($0, agent: agent) }.count == (session == nil ? 1 : 0))
    let frames = try await peer.socket.wireFence(since: wireBoundary).compactMap { try? ProtocolPGObject(text: $0) }
        .filter { $0.string("agentId") == agent }
    let stopIndex = try #require(frames.firstIndex { $0.string("type") == "agent:stop" })
    let startIndex = try #require(frames.firstIndex { $0.string("type") == "agent:start" })
    #expect(stopIndex < startIndex)
    #expect(frames.filter { $0.string("type") == "agent:stop" }.count == 1)
    #expect(frames.filter { $0.string("type") == "agent:start" }.count == 1)
    #expect(!frames.contains { $0.string("type") == "agent:reset-workspace" })
    return .init(start: start, process: process, nextSequence: old.nextSequence + 2)
}

/// Fresh dedicated PG + published HTTP + production BPR/outbox + controlled NIO.
/// This proves control/config correlation, not native Codex/model acceptance.
@Test(.enabled(if: runtimePatchResetPGEnabled), .serialized)
func postgresRuntimePatchRequestsOwnedResetForCommittedCodexModel() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    var machine: ControlledMachineProtocolPeer?
    var subscriber: ProtocolPGSocket?
    do {
        let owner = try await f.login(f.ownerEmail)
        let outsider = try await f.login(f.outsiderEmail)
        let attached = try await f.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Runtime PATCH controlled peer")]))
        try #require(attached.status == 201)
        let machineId = try attached.object().requireString("machineId")
        let key = try attached.object().requireString("apiKey")
        // Native assignment exists before actual ready. No business/presence setter.
        let created = try await f.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Runtime PATCH reset"), "runtimeConfig": resetPatchConfig("gpt-5.3-codex"), "machineId": .string(machineId)]))
        try #require(created.status == 200)
        let agent = try created.object().requireString("id")
        let updates = try await f.subscriber(token: owner); subscriber = updates
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key); machine = peer
        try await peer.sendControlledReady()
        let boundary = peer.socket.count
        let started = try await f.http("POST", "/api/agents/\(agent)/start", token: owner)
        try #require(started.status == 200)
        let initial = try await peer.socket.nextObject(since: boundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agent }
        try await peer.acknowledgeControlledStart(initial)
        let launch = try initial.requireString("launchId")
        let initialProcess = "controlled-original-\(UUID().uuidString.lowercased())"
        try await resetPatchSession(peer, agent: agent, launch: launch, session: "controlled-original-session")
        try await resetPatchProcess(peer, agent: agent, launch: launch, process: initialProcess, sequence: 0, exited: false)
        let running = try await f.audit()
        let runningAgent = try #require(running.execution.agents[agent])
        #expect(running.status(agent: agent) == "active")
        #expect(runningAgent.currentLaunchId == launch && runningAgent.sessionId == "controlled-original-session")
        #expect(runningAgent.processes[initialProcess]?.exited == false)
        #expect(running.execution.connections[machineId]?.ready == true)
        var native = RuntimePatchNativeEvidence(start: initial, process: initialProcess, nextSequence: 1)

        // Main BeforeRED: the client says restart; a real Codex model delta
        // must force session, persist reset and dispatch the committed new model.
        native = try await proveCommittedPatchReset(f, peer: peer, updates: updates, owner: owner,
            agent: agent, machine: machineId, old: native, model: "gpt-5.4", session: nil, human: true)
        let retainedSession = "controlled-session-after-model"
        try await resetPatchSession(peer, agent: agent, launch: native.start.requireString("launchId"), session: retainedSession)
        #expect(try await f.audit().execution.agents[agent]?.sessionId == retainedSession)

        // Effort-only restart retains the actual native session; no session-null.
        native = try await proveCommittedPatchReset(f, peer: peer, updates: updates, owner: owner,
            agent: agent, machine: machineId, old: native, model: "gpt-5.4", effort: "high", session: retainedSession, human: true)

        // Omitted mode keeps 104's lift-only boundary for accepted model/effort/env.
        let beforeOmitted = try await f.audit()
        let beforeOmittedAgent = try #require(beforeOmitted.execution.agents[agent])
        let omittedWire = peer.socket.count
        let omittedEvents = updates.count
        let omitted = try await f.http("PATCH", "/api/agents/\(agent)", token: owner,
            body: resetPatchBody("gpt-5.2-codex", effort: "medium", env: "saved-without-reset"))
        try #require(omitted.status == 200)
        let afterOmitted = try await f.audit()
        let omittedAgent = try #require(afterOmitted.execution.agents[agent])
        #expect(omittedAgent.generation == beforeOmittedAgent.generation + 1 && omittedAgent.currentLaunchId == nil)
        #expect(omittedAgent.sessionId == retainedSession && omittedAgent.takeoverEpoch == beforeOmittedAgent.takeoverEpoch)
        #expect(omittedAgent.needsManual == beforeOmittedAgent.needsManual)
        #expect(omittedAgent.processes[native.process]?.exited == false)
        #expect(Set((afterOmitted.execution.resetIntents ?? [:]).keys) == Set((beforeOmitted.execution.resetIntents ?? [:]).keys))
        #expect(Set(afterOmitted.execution.commands.keys) == Set(beforeOmitted.execution.commands.keys))
        let omittedFrames = try await peer.socket.wireFence(since: omittedWire).compactMap { try? ProtocolPGObject(text: $0) }
        #expect(!omittedFrames.contains { $0.string("agentId") == agent && ["agent:start", "agent:stop", "agent:reset-workspace"].contains($0.string("type") ?? "") })
        let omittedPublications = try await updates.wireFence(since: omittedEvents)
        #expect(!omittedPublications.contains { resetPatchSessionEvent($0, agent: agent) })

        // Same-value explicit restart is still a reset, but not terminal E3 or
        // human takeover. Current APIs expose this on command/wire/generation.
        native = try await proveCommittedPatchReset(f, peer: peer, updates: updates, owner: owner,
            agent: agent, machine: machineId, old: native, model: "gpt-5.2-codex", effort: "medium",
            env: "saved-without-reset", session: retainedSession, human: false)

        // A published manual Stop and authenticated exit establish stopped;
        // PATCH must not inherit public reset's default restart=true.
        let stopBoundary = peer.socket.count
        let stopped = try await f.http("POST", "/api/agents/\(agent)/stop", token: owner)
        try #require(stopped.status == 200)
        _ = try await peer.socket.nextObject(since: stopBoundary) { $0.string("type") == "agent:stop" && $0.string("agentId") == agent }
        try await resetPatchProcess(peer, agent: agent, launch: native.start.requireString("launchId"),
            process: native.process, sequence: native.nextSequence, exited: true)
        let beforeStopped = try await f.audit()
        #expect(beforeStopped.status(agent: agent) == "stopped")
        let stoppedIds = Set((beforeStopped.execution.resetIntents ?? [:]).keys)
        let stoppedWire = peer.socket.count
        let stoppedEvents = updates.count
        let saved = try await f.http("PATCH", "/api/agents/\(agent)", token: owner,
            body: resetPatchBody("gpt-5.3-codex", effort: "medium", env: "saved-without-reset", mode: "restart"))
        try #require(saved.status == 200)
        let admitted = try await f.audit()
        let stoppedReset = try #require((admitted.execution.resetIntents ?? [:]).first { !stoppedIds.contains($0.key) && $0.value.agentId == agent }?.value)
        #expect(!stoppedReset.restart && stoppedReset.priorStatus == "stopped" && stoppedReset.mode == .session)
        try await protocolPGEventually { try await f.outbox(stoppedReset.stopPhaseId)?.deliveredAt != nil }
        try await protocolPGEventually { try await f.outbox(stoppedReset.sessionPublicationId)?.deliveredAt != nil }
        let afterStopped = try await f.audit()
        #expect(afterStopped.status(agent: agent) == "stopped" && afterStopped.execution.agents[agent]?.sessionId == nil)
        #expect(afterStopped.execution.commands[stoppedReset.startCommandId.uuidString] == nil)
        #expect(try await f.outbox(stoppedReset.restartPhaseId) == nil)
        #expect(try await f.outbox(stoppedReset.startCommandId) == nil)
        _ = try await updates.nextText(since: stoppedEvents) { resetPatchSessionEvent($0, agent: agent) }
        let stoppedPublications = try await updates.wireFence(since: stoppedEvents)
        #expect(stoppedPublications.filter { resetPatchSessionEvent($0, agent: agent) }.count == 1)
        let stoppedFrames = try await peer.socket.wireFence(since: stoppedWire).compactMap { try? ProtocolPGObject(text: $0) }
        #expect(!stoppedFrames.contains { $0.string("agentId") == agent && ["agent:start", "agent:reset-workspace"].contains($0.string("type") ?? "") })

        // Refusals cannot write canonical/execution facts or escape controls.
        let refusedWire = peer.socket.count
        let refusedEvents = updates.count
        let refusalBaseline = try await f.audit()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let refusedAgentBytes = try encoder.encode(refusalBaseline.execution.agents[agent])
        let unauthorized = try await f.http("PATCH", "/api/agents/\(agent)", token: outsider,
            body: resetPatchBody("gpt-5.4", mode: "restart"))
        #expect(unauthorized.status == 403)
        let malformed = try await f.http("PATCH", "/api/agents/\(agent)", token: owner,
            body: resetPatchBody("gpt-5.4", mode: "invalid-mode"))
        #expect(malformed.status == 400)
        let refused = try await f.audit()
        #expect(refused.canonicalAgents.fields[agent] == refusalBaseline.canonicalAgents.fields[agent])
        #expect(try encoder.encode(refused.execution.agents[agent]) == refusedAgentBytes)
        #expect(Set(refused.execution.commands.keys) == Set(refusalBaseline.execution.commands.keys))
        #expect(Set((refused.execution.resetIntents ?? [:]).keys) == Set((refusalBaseline.execution.resetIntents ?? [:]).keys))
        let refusedFrames = try await peer.socket.wireFence(since: refusedWire).compactMap { try? ProtocolPGObject(text: $0) }
        #expect(!refusedFrames.contains { $0.string("agentId") == agent && ["agent:start", "agent:stop", "agent:reset-workspace"].contains($0.string("type") ?? "") })
        let refusedPublications = try await updates.wireFence(since: refusedEvents)
        #expect(!refusedPublications.contains { resetPatchSessionEvent($0, agent: agent) })

        // Supplemental real Shared rollback-only, not a failpoint or an HTTP
        // success proof. Read uncommitted real intent references, then discard.
        let roots = try DurableDomain.allCases.map { try DurableKey(domain: $0, aggregateID: "root") }
        let keys = roots + [try DurableKey(domain: .notifications, aggregateID: "native")]
        let baseline = Mutex<[DurableDocument]?>(nil)
        let discardedIds = Mutex<[UUID]>([])
        let request = try JSONDecoder().decode(LegacyJSONObjectBody.self, from: resetPatchBody("gpt-5.4", mode: "restart").data)
        let rollbackWire = peer.socket.count
        let rollbackEvents = updates.count
        do {
            try await f.runtime.execute {
                let documents = try await f.observer.readSnapshot(keys)
                guard documents.count == 14, Set(documents.map(\.key)) == Set(keys) else { throw ProtocolPGFailure.invalidSnapshot }
                baseline.withLock { $0 = documents }
                let oldIds = Set((f.accounts.agentsRuntimeStore.state.execution.resetIntents ?? [:]).keys)
                _ = try f.accounts.agentSurface.bindingExecution(f.accounts.agentExecution(persistence: f.runtime))
                    .patchAgent(authorization: "Bearer \(owner)", agentId: agent, body: request, serverId: f.serverId)
                let intent = (f.accounts.agentsRuntimeStore.state.execution.resetIntents ?? [:]).values.first {
                    !oldIds.contains($0.operationId.uuidString) && $0.agentId == agent
                }
                guard let intent else { throw ProtocolPGFailure.invalidSnapshot }
                discardedIds.withLock { $0 = [intent.stopPhaseId, intent.workspacePhaseId, intent.restartPhaseId, intent.startCommandId, intent.sessionPublicationId] }
                DeferredEffects.markRollbackOnly()
                throw RuntimePatchResetAbort.rollback
            }
            Issue.record("Expected existing coordinator rollback-only discard")
        } catch TransactionError.rollbackOnly {}
        let rollbackBefore = try #require(baseline.withLock { $0 })
        let rollbackAfter = try await f.observer.readSnapshot(keys)
        #expect(rollbackAfter.count == 14)
        let rollbackPayloadsEqual = Dictionary(uniqueKeysWithValues: rollbackBefore.map { ($0.key, $0.json) }) == Dictionary(uniqueKeysWithValues: rollbackAfter.map { ($0.key, $0.json) })
        #expect(rollbackPayloadsEqual)
        let ids = discardedIds.withLock { $0 }
        #expect(ids.count == 5)
        for id in ids { #expect(try await f.outbox(id) == nil) }
        let rollbackFrames = try await peer.socket.wireFence(since: rollbackWire).compactMap { try? ProtocolPGObject(text: $0) }
        #expect(!rollbackFrames.contains { $0.string("agentId") == agent && ["agent:start", "agent:stop", "agent:reset-workspace"].contains($0.string("type") ?? "") })
        let rollbackPublications = try await updates.wireFence(since: rollbackEvents)
        #expect(!rollbackPublications.contains { resetPatchSessionEvent($0, agent: agent) })
        await f.close(machine: machine, subscriber: subscriber)
    } catch {
        await f.close(machine: machine, subscriber: subscriber)
        throw error
    }
}


/// Full-ready normal active no-op: actual held work must survive automatic replacement.
/// Controlled protocol receipts prove server admission, never OS/Codex/provider acceptance.
@Test(.enabled(if: runtimePatchResetPGEnabled), .serialized)
func postgresRuntimePatchNoopResetReleasesHeldHumanMessageAfterAutomaticStart() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    var machine: ControlledMachineProtocolPeer?
    var subscriber: ProtocolPGSocket?
    do {
        let owner = try await f.login(f.ownerEmail)
        let attached = try await f.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Held reset protocol peer")]))
        try #require(attached.status == 201)
        let machineId = try attached.object().requireString("machineId")
        let key = try attached.object().requireString("apiKey")
        let created = try await f.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Held reset recipient"), "runtimeConfig": resetPatchConfig("gpt-5.3-codex"), "machineId": .string(machineId)]))
        try #require(created.status == 200)
        let agent = try created.object().requireString("id")
        let listed = try await f.http("GET", "/api/channels/dm", token: owner)
        try #require(listed.status == 200)
        guard case .array(let values) = try JSONDecoder().decode(JSONValue.self, from: listed.body) else { throw ProtocolPGFailure.invalidResponse }
        let rows = values.compactMap { value -> ProtocolPGObject? in
            guard case .object(let fields) = value else { return nil }; return .init(fields)
        }
        let dm = try #require(rows.first { $0.string("peerType") == "agent" && $0.string("peerId") == agent }).requireString("id")
        let updates = try await f.subscriber(token: owner); subscriber = updates
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key); machine = peer
        try await peer.sendControlledReady()
        let initialBoundary = peer.socket.count
        try #require(try await f.http("POST", "/api/agents/\(agent)/start", token: owner).status == 200)
        let initial = try await peer.socket.nextObject(since: initialBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agent }
        try await peer.acknowledgeControlledStart(initial)
        let oldLaunch = try initial.requireString("launchId")
        let oldProcess = "controlled-held-old-\(UUID().uuidString.lowercased())"
        let session = "controlled-held-session"
        try await resetPatchSession(peer, agent: agent, launch: oldLaunch, session: session)
        try await resetPatchProcess(peer, agent: agent, launch: oldLaunch, process: oldProcess, sequence: 0, exited: false)
        let before = try await f.audit()
        let original = try #require(before.execution.agents[agent])
        try #require(before.status(agent: agent) == "active" && original.currentLaunchId == oldLaunch)
        try #require(before.execution.connections[machineId]?.ready == true && original.processes[oldProcess]?.exited == false)
        #expect(original.sessionId == session && original.needsManual == nil)
        let oldResetIds = Set((before.execution.resetIntents ?? [:]).keys)
        let wireBoundary = peer.socket.count
        let eventBoundary = updates.count
        let patched = try await f.http("PATCH", "/api/agents/\(agent)", token: owner,
            body: resetPatchBody("gpt-5.3-codex", mode: "restart"))
        try #require(patched.status == 200)
        let admitted = try await f.audit()
        let added = (admitted.execution.resetIntents ?? [:]).filter { !oldResetIds.contains($0.key) && $0.value.agentId == agent }
        try #require(added.count == 1, "same-value active PATCH must admit the owned reset")
        let intent = try #require(added.values.first)
        #expect(intent.mode == .restart && intent.restart && intent.priorLaunchId == oldLaunch)
        _ = try await peer.socket.nextObject(since: wireBoundary) { $0.string("type") == "agent:stop" && $0.string("agentId") == agent }
        try await protocolPGEventually {
            let state = try await f.audit()
            let stopDelivered = try await f.outbox(intent.stopPhaseId)?.deliveredAt != nil
            return state.execution.resetIntents?[intent.operationId.uuidString]?.stopAttempt == .written
                && state.execution.resetIntents?[intent.operationId.uuidString]?.phase == .restart
                && stopDelivered
        }
        let stopped = try await f.audit()
        let waiting = try #require(stopped.execution.agents[agent])
        try #require(stopped.execution.commands[intent.startCommandId.uuidString] == nil)
        #expect(waiting.currentLaunchId == nil && waiting.launches[oldLaunch]?.stopRequested == true)
        #expect(waiting.processes[oldProcess]?.exited == false && stopped.execution.connections[machineId]?.ready == true)
        #expect(waiting.generation == original.generation && waiting.takeoverEpoch == original.takeoverEpoch)
        #expect(waiting.failureCount == original.failureCount && waiting.needsManual == original.needsManual)
        let request = ProtocolPGObject(["channelId": .string(dm), "content": .string("Retain this human work across automatic reset"), "randomId": .string("reset-held-once")])
        let sent = try await f.http("POST", "/api/messages", token: owner, body: request)
        try #require(sent.status == 200)
        let messageId = try sent.object().requireString("id")
        let heldAudit = try await f.audit()
        let hosts = heldAudit.messages.filter { $0.string("id") == messageId }
        try #require(hosts.count == 1)
        #expect(hosts.first?.string("content") == "Retain this human work across automatic reset")
        let heldEntries = (heldAudit.execution.heldDeliveries ?? [:]).values.filter {
            $0.serverId == f.serverId && $0.agentId == agent && $0.channelId == dm && $0.messageId == messageId
        }
        try #require(heldEntries.count == 1)
        let held = try #require(heldEntries.first)
        #expect(held.releasedCommandId == nil && !held.cancelled)
        #expect(!heldAudit.execution.commands.values.contains { $0.kind == .delivery && $0.agentId == agent && $0.messageId == messageId })
        #expect(try await f.outbox(held.commandId) == nil)
        let pendingFrames = try await peer.socket.wireFence(since: wireBoundary).compactMap { try? ProtocolPGObject(text: $0) }
        #expect(!pendingFrames.contains { $0.string("agentId") == agent && ["agent:start", "agent:deliver"].contains($0.string("type") ?? "") })
        // The old process exit is real authenticated ingress; there is no stop ACK.
        try await resetPatchProcess(peer, agent: agent, launch: oldLaunch, process: oldProcess, sequence: 1, exited: true)
        let replacement = try await peer.socket.nextObject(since: wireBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agent }
        let newLaunch = try replacement.requireString("launchId")
        #expect(newLaunch != oldLaunch && replacement.bool("humanStart") == false)
        #expect(replacement.string("connectionEpochId") == peer.context.string("connectionEpochId"))
        #expect(replacement.object("config")?.string("sessionId") == session)
        try await peer.acknowledgeControlledStart(replacement)
        let newProcess = "controlled-held-new-\(UUID().uuidString.lowercased())"
        try await resetPatchProcess(peer, agent: agent, launch: newLaunch, process: newProcess, sequence: 2, exited: false)
        // A start ACK is insufficient: consume the actual released message frame.
        let delivery = try await peer.socket.nextObject(since: wireBoundary) {
            $0.string("type") == "agent:deliver" && $0.string("agentId") == agent && $0.object("message")?.string("message_id") == messageId
        }
        let deliveryId = try delivery.requireString("deliveryId")
        let materialized = try await f.audit()
        let releasedId = try #require(materialized.execution.heldDeliveries?[held.commandId.uuidString]?.releasedCommandId)
        let command = try #require(materialized.execution.commands[releasedId.uuidString])
        let host = try #require(materialized.messages.first { $0.string("id") == messageId })
        #expect(releasedId != held.commandId && command.kind == .delivery && command.deliveryId == deliveryId)
        #expect(command.serverId == f.serverId && command.machineId == machineId && command.agentId == agent)
        #expect(command.launchId == newLaunch && command.connectionEpochId == peer.context.string("connectionEpochId"))
        #expect(command.takeoverEpoch == original.takeoverEpoch && command.breakerGeneration == original.generation + 1)
        #expect(delivery.object("message")?.string("channel_id") == dm && delivery.object("message")?.string("channel_type") == "dm")
        #expect(delivery.integer("seq") == host.integer("seq"))
        #expect(materialized.execution.dispatches?[releasedId.uuidString]?.deliverySequence == host.integer("seq"))
        try await peer.acknowledgeControlledDelivery(delivery)
        // Replay the actual ACK and public message identity; neither creates work twice.
        try await peer.acknowledgeControlledDelivery(delivery)
        let replay = try await f.http("POST", "/api/messages", token: owner, body: request)
        #expect(replay.status == 200)
        #expect(try replay.object().string("id") == messageId)
        for id in [intent.stopPhaseId, intent.restartPhaseId, intent.startCommandId, releasedId] {
            try await protocolPGEventually { try await f.outbox(id)?.deliveredAt != nil }
        }
        let settled = try await f.audit()
        let current = try #require(settled.execution.agents[agent])
        #expect(current.generation == original.generation + 1 && current.takeoverEpoch == original.takeoverEpoch)
        #expect(current.failureCount == original.failureCount && current.needsManual == original.needsManual)
        #expect(current.currentLaunchId == newLaunch && current.sessionId == session)
        #expect(current.processes[oldProcess]?.exited == true && current.processes[newProcess]?.exited == false)
        #expect(settled.execution.commands[intent.startCommandId.uuidString]?.humanStart == false)
        #expect(settled.execution.commands[releasedId.uuidString]?.status == .accepted)
        #expect(settled.execution.dispatches?[releasedId.uuidString]?.phase == .accepted)
        #expect(settled.execution.heldDeliveries?[held.commandId.uuidString]?.releasedCommandId == releasedId)
        #expect(settled.execution.heldDeliveries?[held.commandId.uuidString]?.cancelled == false)
        #expect(settled.execution.commands.values.filter { $0.kind == .delivery && $0.agentId == agent && $0.messageId == messageId }.count == 1)
        #expect(settled.messages.filter { $0.string("id") == messageId }.count == 1)
        #expect(Set(settled.execution.stopIntents?.keys.map { $0 } ?? []) == Set(before.execution.stopIntents?.keys.map { $0 } ?? []))
        #expect(Set((settled.execution.resetIntents ?? [:]).keys) == oldResetIds.union([intent.operationId.uuidString]))
        #expect(try await f.outbox(intent.sessionPublicationId) == nil)
        let history = try await f.http("GET", "/api/messages/channel/\(dm)", token: owner)
        #expect(history.status == 200)
        let historyRows = try history.object().array("messages") ?? []
        #expect(historyRows.filter { value in
            guard case .object(let row) = value else { return false }; return row["id"] == .string(messageId)
        }.count == 1)
        let frames = try await peer.socket.wireFence(since: wireBoundary).compactMap { try? ProtocolPGObject(text: $0) }
        #expect(frames.filter { $0.string("agentId") == agent && $0.string("type") == "agent:stop" }.count == 1)
        #expect(frames.filter { $0.string("agentId") == agent && $0.string("type") == "agent:start" }.count == 1)
        #expect(frames.filter { $0.string("agentId") == agent && $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == messageId }.count == 1)
        #expect(!frames.contains { $0.string("agentId") == agent && $0.string("type") == "agent:reset-workspace" })
        let publications = try await updates.wireFence(since: eventBoundary)
        #expect(!publications.contains { resetPatchSessionEvent($0, agent: agent) })
        await f.close(machine: machine, subscriber: subscriber)
    } catch {
        await f.close(machine: machine, subscriber: subscriber)
        throw error
    }
}

/// A written public reset can strengthen session semantics while runtime readiness waits.
/// Same-value PATCH must not repeat terminal control, replay stop, or replace the operation.
@Test(.enabled(if: runtimePatchResetPGEnabled), .serialized)
func postgresRuntimePatchSessionStrengtheningPreservesWrittenStopTerminalState() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    var machine: ControlledMachineProtocolPeer?
    var subscriber: ProtocolPGSocket?
    do {
        let owner = try await f.login(f.ownerEmail)
        let outsider = try await f.login(f.outsiderEmail)
        let attached = try await f.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Session strengthening protocol peer")]))
        try #require(attached.status == 201)
        let machineId = try attached.object().requireString("machineId")
        let key = try attached.object().requireString("apiKey")
        let created = try await f.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Session strengthening recipient"), "runtimeConfig": resetPatchConfig("gpt-5.3-codex"), "machineId": .string(machineId)]))
        try #require(created.status == 200)
        let agent = try created.object().requireString("id")
        let updates = try await f.subscriber(token: owner); subscriber = updates
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key); machine = peer
        try await peer.sendControlledReady()
        let initialBoundary = peer.socket.count
        try #require(try await f.http("POST", "/api/agents/\(agent)/start", token: owner).status == 200)
        let initial = try await peer.socket.nextObject(since: initialBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agent }
        try await peer.acknowledgeControlledStart(initial)
        let oldLaunch = try initial.requireString("launchId")
        let process = "controlled-strengthen-old-\(UUID().uuidString.lowercased())"
        let session = "controlled-session-before-strengthening"
        try await resetPatchSession(peer, agent: agent, launch: oldLaunch, session: session)
        try await resetPatchProcess(peer, agent: agent, launch: oldLaunch, process: process, sequence: 0, exited: false)
        let before = try await f.audit()
        let original = try #require(before.execution.agents[agent])
        try #require(before.status(agent: agent) == "active" && original.currentLaunchId == oldLaunch)
        try #require(original.processes[process]?.exited == false && before.execution.connections[machineId]?.ready == true)
        // Official pending inventory omits runtimes; same connection/daemon retains its real process.
        try await peer.socket.send(.init([
            "type": .string("ready"), "daemonInstanceId": .string(peer.daemonId),
            "capabilities": .array(["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"].map(JSONValue.string)),
            "runningAgents": .array([.string(agent)]), "runtimeDetection": .object(["status": .string("pending")]),
        ]))
        try await peer.socket.applicationFence()
        let pending = try await f.audit()
        let connection = try #require(pending.execution.connections[machineId])
        try #require(connection.online && !connection.ready && connection.capabilities?.contains("agent:stop") == true)
        #expect(connection.connectionEpochId == peer.context.string("connectionEpochId") && connection.daemonInstanceId == peer.daemonId)
        #expect(pending.execution.agents[agent]?.currentLaunchId == oldLaunch && pending.execution.agents[agent]?.processes[process]?.exited == false)
        #expect(pending.execution.agents[agent]?.generation == original.generation && pending.execution.agents[agent]?.takeoverEpoch == original.takeoverEpoch)
        let oldResetIds = Set((pending.execution.resetIntents ?? [:]).keys)
        let wireBoundary = peer.socket.count
        let eventBoundary = updates.count
        let reset = try await f.http("POST", "/api/agents/\(agent)/reset", token: owner, body: .init(["mode": .string("restart")]))
        try #require(reset.status == 202)
        let admitted = try await f.audit()
        let added = (admitted.execution.resetIntents ?? [:]).filter { !oldResetIds.contains($0.key) && $0.value.agentId == agent }
        try #require(added.count == 1)
        let intent = try #require(added.values.first)
        #expect(intent.mode == .restart && intent.restart && intent.priorLaunchId == oldLaunch)
        _ = try await peer.socket.nextObject(since: wireBoundary) { $0.string("type") == "agent:stop" && $0.string("agentId") == agent }
        try await protocolPGEventually {
            let state = try await f.audit()
            let stopDelivered = try await f.outbox(intent.stopPhaseId)?.deliveredAt != nil
            return state.execution.resetIntents?[intent.operationId.uuidString]?.stopAttempt == .written
                && state.execution.resetIntents?[intent.operationId.uuidString]?.phase == .restart
                && stopDelivered
        }
        let written = try await f.audit()
        let terminal = try #require(written.execution.agents[agent])
        let writtenIntent = try #require(written.execution.resetIntents?[intent.operationId.uuidString])
        try #require(written.execution.commands[intent.startCommandId.uuidString] == nil)
        #expect(terminal.generation > original.generation && terminal.currentLaunchId == nil)
        #expect(terminal.takeoverEpoch == original.takeoverEpoch && terminal.sessionId == session)
        #expect(!writtenIntent.sessionCleared && writtenIntent.stopAttempt == .written)
        #expect(try await f.outbox(intent.restartPhaseId)?.deliveredAt == nil)
        // Exit only after the written predecessor's terminal effect has committed.
        try await resetPatchProcess(peer, agent: agent, launch: oldLaunch, process: process, sequence: 1, exited: true)
        for _ in 0..<2 {
            let strengthened = try await f.http("PATCH", "/api/agents/\(agent)", token: owner,
                body: resetPatchBody("gpt-5.3-codex", mode: "session"))
            try #require(strengthened.status == 200)
            let state = try await f.audit()
            let current = try #require(state.execution.agents[agent])
            let record = try #require(state.execution.resetIntents?[intent.operationId.uuidString])
            #expect(Set((state.execution.resetIntents ?? [:]).keys) == oldResetIds.union([intent.operationId.uuidString]))
            #expect(record.mode == intent.mode && record.restart == intent.restart && record.priorLaunchId == intent.priorLaunchId)
            #expect(record.stopPhaseId == intent.stopPhaseId && record.workspacePhaseId == intent.workspacePhaseId)
            #expect(record.restartPhaseId == intent.restartPhaseId && record.startCommandId == intent.startCommandId && record.sessionPublicationId == intent.sessionPublicationId)
            #expect(record.stopAttempt == .written && record.workspaceAttempt == .notAttempted && record.phase == .restart && record.sessionCleared)
            #expect(current.generation == terminal.generation && current.takeoverEpoch == terminal.takeoverEpoch)
            #expect(current.failureCount == terminal.failureCount && current.sameFingerprint == terminal.sameFingerprint && current.sameFingerprintCount == terminal.sameFingerprintCount)
            #expect(current.backoffStep == terminal.backoffStep && current.blockedUntil == terminal.blockedUntil)
            #expect(current.probeLaunchId == terminal.probeLaunchId && current.probeExpiresAt == terminal.probeExpiresAt && current.needsManual == terminal.needsManual)
            #expect(current.currentLaunchId == nil && current.sessionId == nil && current.processes[process]?.exited == true)
            #expect(state.execution.commands[intent.startCommandId.uuidString] == nil && state.execution.connections[machineId]?.ready == false)
            #expect(record.expectedGeneration == writtenIntent.expectedGeneration && record.expectedTakeoverEpoch == writtenIntent.expectedTakeoverEpoch)
        }
        let forbidden = try await f.http("PATCH", "/api/agents/\(agent)", token: outsider,
            body: resetPatchBody("gpt-5.3-codex", mode: "session"))
        #expect(forbidden.status == 403)
        _ = try await updates.nextText(since: eventBoundary) { resetPatchSessionEvent($0, agent: agent) }
        try await protocolPGEventually { try await f.outbox(intent.sessionPublicationId)?.deliveredAt != nil }
        let publicationRow = try #require(try await f.outbox(intent.sessionPublicationId))
        let publication = try JSONDecoder().decode(RealtimePublication.self, from: publicationRow.effect.payload)
        #expect(publication.eventId == intent.sessionPublicationId && publication.event == "agent:session")
        let heldFrames = try await peer.socket.wireFence(since: wireBoundary).compactMap { try? ProtocolPGObject(text: $0) }
        #expect(heldFrames.filter { $0.string("agentId") == agent && $0.string("type") == "agent:stop" }.count == 1)
        #expect(!heldFrames.contains { $0.string("agentId") == agent && ["agent:start", "agent:reset-workspace"].contains($0.string("type") ?? "") })
        #expect(try await f.outbox(intent.workspacePhaseId) == nil)
        // Restore actual complete inventory; original public-human restart authority remains.
        try await peer.sendControlledReady()
        let replacement = try await peer.socket.nextObject(since: wireBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agent }
        let newLaunch = try replacement.requireString("launchId")
        #expect(newLaunch != oldLaunch && replacement.bool("humanStart") == true)
        #expect(replacement.string("connectionEpochId") == peer.context.string("connectionEpochId"))
        #expect(replacement.object("config")?.fields["sessionId"] == .null)
        try await peer.acknowledgeControlledStart(replacement)
        let newProcess = "controlled-strengthen-new-\(UUID().uuidString.lowercased())"
        try await resetPatchProcess(peer, agent: agent, launch: newLaunch, process: newProcess, sequence: 2, exited: false)
        for id in [intent.stopPhaseId, intent.restartPhaseId, intent.startCommandId, intent.sessionPublicationId] {
            try await protocolPGEventually { try await f.outbox(id)?.deliveredAt != nil }
        }
        let settled = try await f.audit()
        let current = try #require(settled.execution.agents[agent])
        let record = try #require(settled.execution.resetIntents?[intent.operationId.uuidString])
        #expect(Set((settled.execution.resetIntents ?? [:]).keys) == oldResetIds.union([intent.operationId.uuidString]))
        #expect(record.stopAttempt == .written && record.workspaceAttempt == .notAttempted && record.phase == .restartStaged && record.sessionCleared)
        // Only the canonical new launch increments after the written-stop baseline.
        #expect(current.generation == terminal.generation + 1 && current.takeoverEpoch == terminal.takeoverEpoch + 1)
        #expect(current.currentLaunchId == newLaunch && current.sessionId == nil && current.needsManual == nil)
        #expect(current.processes[process]?.exited == true && current.processes[newProcess]?.exited == false)
        #expect(settled.execution.commands[intent.startCommandId.uuidString]?.humanStart == true)
        #expect(settled.execution.commands[intent.startCommandId.uuidString]?.status == .accepted)
        #expect(Set(settled.execution.stopIntents?.keys.map { $0 } ?? []) == Set(before.execution.stopIntents?.keys.map { $0 } ?? []))
        #expect(settled.execution.connections[machineId]?.ready == true && settled.execution.connections[machineId]?.connectionEpochId == connection.connectionEpochId)
        #expect(try await f.outbox(intent.sessionPublicationId)?.effect.payload == publicationRow.effect.payload)
        let frames = try await peer.socket.wireFence(since: wireBoundary).compactMap { try? ProtocolPGObject(text: $0) }
        #expect(frames.filter { $0.string("agentId") == agent && $0.string("type") == "agent:stop" }.count == 1)
        #expect(frames.filter { $0.string("agentId") == agent && $0.string("type") == "agent:start" }.count == 1)
        #expect(!frames.contains { $0.string("agentId") == agent && $0.string("type") == "agent:reset-workspace" })
        let publications = try await updates.wireFence(since: eventBoundary)
        #expect(publications.filter { resetPatchSessionEvent($0, agent: agent) }.count == 1)
        await f.close(machine: machine, subscriber: subscriber)
    } catch {
        await f.close(machine: machine, subscriber: subscriber)
        throw error
    }
}
