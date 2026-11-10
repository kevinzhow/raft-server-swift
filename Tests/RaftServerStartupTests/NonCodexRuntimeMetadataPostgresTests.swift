import Foundation
import RaftPersistence
import RaftShared
import Testing
@testable import RaftHTTP

private let nonCodexMetadataPGEnabled = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_PG_ACCEPTANCE"] == "1"

private func metadataReleasedSample(_ name: String) throws -> ProtocolPGObject {
    let path = FileManager.default.currentDirectoryPath + "/Tests/RaftHTTPServerTests/Fixtures/mobile-v1.12.0-save-requests.json"
    let fixture = try ProtocolPGObject(data: Data(contentsOf: URL(fileURLWithPath: path)))
    return try #require(fixture.object("samples")?.object(name))
}

private func metadataStoredConfig(_ audit: ProtocolPGAudit, agent: String) throws -> ProtocolPGObject {
    let raw = try #require(audit.canonicalAgents.object(agent)?.string("runtimeConfigJSON"))
    return try ProtocolPGObject(text: raw)
}

private func metadataProcess(_ peer: ControlledMachineProtocolPeer, agent: String, launch: String, process: String) async throws {
    let boundary = peer.socket.count
    try await peer.socket.send(.init(["type": .string("agent:process_spawned"), "agentId": .string(agent),
        "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(0), "launchId": .string(launch), "processInstanceId": .string(process)]))
    _ = try await peer.socket.nextObject(since: boundary) {
        $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == agent && $0.integer("clientSeq") == 0
    }
}

private func metadataNullSession(_ text: String, agent: String) -> Bool {
    guard text.hasPrefix("42"),
          let values = try? JSONDecoder().decode([JSONValue].self, from: Data(text.dropFirst(2).utf8)),
          values.count == 2, values[0] == .string("agent:session"), case .object(let fields) = values[1] else { return false }
    return fields["agentId"] == .string(agent) && fields["sessionId"] == .null
}

/// Exact released metadata requests on fresh owned PG; controlled Codex guard facts only.
/// Saved200 and protocol ACKs are not Builtin/Codex/provider execution acceptance.
@Test(.enabled(if: nonCodexMetadataPGEnabled), .serialized)
func postgresReleasedNonCodexMetadataSavesPreserveSecretsAndOwnedControlBoundaries() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProtocolPGFailure.missingDedicatedDatabase }
    let f = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    var machine: ControlledMachineProtocolPeer?
    var subscriber: ProtocolPGSocket?
    do {
        let owner = try await f.login(f.ownerEmail)
        let attached = try await f.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Runtime metadata owned computer")]))
        try #require(attached.status == 201)
        let machineId = try attached.object().requireString("machineId")
        let key = try attached.object().requireString("apiKey")
        let updates = try await f.subscriber(token: owner); subscriber = updates
        let metadataEvents = updates.count
        let gateway = try metadataReleasedSample("create.builtin.gateway")
        var createFields = gateway.fields
        // The only sample adaptation is replacing its placeholder with the actual owned attachment.
        createFields["machineId"] = .string(machineId)
        let created = try await f.http("POST", "/api/agents", token: owner, body: .init(createFields))
        try #require(created.status == 200)
        let builtin = try created.object().requireString("id")
        let originalKey = try #require(gateway.object("runtimeConfig")?.object("provider")?.string("apiKey"))
        let replacementSample = try metadataReleasedSample("edit.builtin.replace-secret")
        let replacementKey = try #require(replacementSample.object("runtimeConfig")?.object("provider")?.string("apiKey"))
        #expect(try created.object().object("runtimeConfig")?.object("provider")?.string("apiKey") == "")
        let createText = String(decoding: created.body, as: UTF8.self)
        let createResponseRedacted = ![originalKey, replacementKey].contains { createText.contains($0) }
        #expect(createResponseRedacted)
        func verifyMetadata(expectedKey: String, plugins: Bool) async throws {
            let profile = try await f.http("GET", "/api/agents/\(builtin)", token: owner)
            try #require(profile.status == 200)
            let body = try profile.object()
            #expect(body.string("id") == builtin && body.string("runtime") == "builtin" && body.string("model") == "example-model")
            #expect(body.string("machineId") == machineId && body.string("status") == "inactive")
            let published = try #require(body.object("runtimeConfig"))
            #expect(published.object("provider")?.string("apiKey") == "")
            #expect(published.object("provider")?.string("kind") == "gateway")
            #expect(published.object("provider")?.string("providerId") == "openai-compatible")
            #expect(published.object("provider")?.string("baseUrl") == "https://gateway.example.test/v1")
            #expect(published.object("provider")?.bool("supportsImageInput") == true)
            #expect(published.bool("loadLocalPlugins") == plugins && published.string("hostUserState") == "forbidden")
            #expect(published.object("envVars")?.string("EXAMPLE_FLAG") == "1")
            let text = String(decoding: profile.body, as: UTF8.self)
            let responseRedacted = ![originalKey, replacementKey].contains { text.contains($0) }
            #expect(responseRedacted)
            let audit = try await f.audit()
            let raw = try metadataStoredConfig(audit, agent: builtin)
            let storedKeyMatches = raw.object("provider")?.string("apiKey") == expectedKey
            #expect(storedKeyMatches)
            #expect(raw.object("provider")?.string("kind") == "gateway" && raw.object("provider")?.string("baseUrl") == "https://gateway.example.test/v1")
            #expect(raw.bool("loadLocalPlugins") == plugins && raw.string("hostUserState") == "forbidden")
            #expect(raw.object("envVars")?.string("EXAMPLE_FLAG") == "1" && raw.object("model")?.string("name") == "example-model")
            let envText = try #require(audit.canonicalAgents.object(builtin)?.string("envVarsJSON"))
            #expect(try ProtocolPGObject(text: envText).string("EXAMPLE_FLAG") == "1")
            // A saved config does not manufacture an execution owner, session, launch or readiness.
            #expect(audit.execution.agents[builtin] == nil && audit.execution.connections.isEmpty)
            #expect(audit.execution.commands.isEmpty && audit.execution.receipts.isEmpty && audit.execution.watermarks.isEmpty)
            #expect((audit.execution.resetIntents ?? [:]).isEmpty && (audit.execution.stopIntents ?? [:]).isEmpty)
            #expect((audit.execution.heldDeliveries ?? [:]).isEmpty && (audit.execution.dispatches ?? [:]).isEmpty)
        }
        try await verifyMetadata(expectedKey: originalKey, plugins: true)
        for (sample, expectedKey) in [("edit.builtin.keep-secret", originalKey), ("edit.builtin.replace-secret", replacementKey)] {
            let payload = try metadataReleasedSample(sample)
            let saved = try await f.http("PATCH", "/api/agents/\(builtin)", token: owner, body: payload)
            // Source-before fails here through the real producer/BPR, before any guard tail is claimed.
            try #require(saved.status == 200, "released same-Builtin metadata save must commit with its machine and restartMode intact")
            #expect(try saved.object().object("runtimeConfig")?.object("provider")?.string("apiKey") == "")
            let text = String(decoding: saved.body, as: UTF8.self)
            let responseRedacted = ![originalKey, replacementKey].contains { text.contains($0) }
            #expect(responseRedacted)
            try await verifyMetadata(expectedKey: expectedKey, plugins: false)
        }
        let beforeReplay = try await f.audit()
        let replay = try await f.http("PATCH", "/api/agents/\(builtin)", token: owner,
            body: metadataReleasedSample("edit.builtin.keep-secret"))
        try #require(replay.status == 200)
        try await verifyMetadata(expectedKey: replacementKey, plugins: false)
        let afterReplay = try await f.audit()
        let noOpConfigUnchanged = beforeReplay.canonicalAgents.object(builtin)?.string("runtimeConfigJSON") == afterReplay.canonicalAgents.object(builtin)?.string("runtimeConfigJSON")
        #expect(noOpConfigUnchanged)
        let metadataPublications = try await updates.wireFence(since: metadataEvents)
        #expect(!metadataPublications.contains { metadataNullSession($0, agent: builtin) })

        let roots = try DurableDomain.allCases.map { try DurableKey(domain: $0, aggregateID: "root") }
        let keys = roots + [try DurableKey(domain: .notifications, aggregateID: "native")]
        func snapshot14() async throws -> [DurableKey: Data] {
            let documents = try await f.observer.readSnapshot(keys)
            try #require(documents.count == 14 && Set(documents.map(\.key)) == Set(keys))
            return Dictionary(uniqueKeysWithValues: documents.map { ($0.key, $0.json) })
        }
        let codexConfig: JSONValue = .object(["version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")]),
            "mode": .object(["kind": .string("default")]), "reasoningEffort": .null, "envVars": .object([:])])
        func createCodex(_ name: String) async throws -> String {
            let reply = try await f.http("POST", "/api/agents", token: owner,
                body: .init(["name": .string(name), "machineId": .string(machineId), "runtimeConfig": codexConfig]))
            try #require(reply.status == 200)
            return try reply.object().requireString("id")
        }
        // Both guards are actual assigned agents created before the first controlled ready.
        let historical = try await createCodex("Runtime metadata historical control")
        let active = try await createCodex("Runtime metadata active control")
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key); machine = peer
        try await peer.sendControlledReady()
        func start(_ agent: String) async throws -> (launch: String, process: String, session: String) {
            let boundary = peer.socket.count
            try #require(try await f.http("POST", "/api/agents/\(agent)/start", token: owner).status == 200)
            let frame = try await peer.socket.nextObject(since: boundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agent }
            let launch = try frame.requireString("launchId")
            try await peer.acknowledgeControlledStart(frame)
            let session = "controlled-metadata-session-\(agent)"
            try await peer.socket.send(.init(["type": .string("agent:session"), "agentId": .string(agent), "launchId": .string(launch), "sessionId": .string(session)]))
            try await peer.socket.applicationFence()
            let process = "controlled-metadata-process-\(agent)"
            try await metadataProcess(peer, agent: agent, launch: launch, process: process)
            let audit = try await f.audit()
            let command = try #require(audit.execution.commands.values.first { $0.agentId == agent && $0.kind == .start && $0.launchId == launch })
            try await protocolPGEventually { try await f.outbox(command.commandId)?.deliveredAt != nil }
            #expect(audit.execution.agents[agent]?.currentLaunchId == launch && audit.execution.agents[agent]?.sessionId == session)
            #expect(audit.execution.agents[agent]?.processes[process]?.exited == false)
            return (launch, process, session)
        }
        let native = try await start(historical)
        var transition = createFields
        transition["displayName"] = .string("Unsupported transition must not partially commit")
        transition["restartMode"] = .string("restart")
        let refusalWire = peer.socket.count
        let beforeRefusal = try await snapshot14()
        let refused = try await f.http("PATCH", "/api/agents/\(historical)", token: owner, body: .init(transition))
        #expect(refused.status == 503)
        #expect(try refused.object().fields == ["error": .string("Business persistence unavailable")])
        let afterRefusal = try await snapshot14()
        let refusedPayloadsUnchanged = beforeRefusal == afterRefusal
        #expect(refusedPayloadsUnchanged)
        let refusedFrames = try await peer.socket.wireFence(since: refusalWire).compactMap { try? ProtocolPGObject(text: $0) }
        #expect(!refusedFrames.contains { $0.string("agentId") == historical && ["agent:start", "agent:stop", "agent:reset-workspace"].contains($0.string("type") ?? "") })
        // Existing104's published omitted-mode lift is a genuine way to retain execution history on a new runtime.
        var omitted = transition
        omitted.removeValue(forKey: "restartMode")
        let moved = try await f.http("PATCH", "/api/agents/\(historical)", token: owner, body: .init(omitted))
        try #require(moved.status == 200)
        let history = try await f.audit()
        let retained = try #require(history.execution.agents[historical])
        #expect(history.canonicalAgents.object(historical)?.string("runtime") == "builtin")
        #expect(retained.currentLaunchId == nil && retained.sessionId == native.session)
        #expect(retained.launches[native.launch] != nil && retained.processes[native.process]?.exited == false)
        let secondBefore = try await snapshot14()
        let historicalPatch = try await f.http("PATCH", "/api/agents/\(historical)", token: owner, body: .init(transition))
        #expect(historicalPatch.status == 503)
        #expect(try historicalPatch.object().fields == ["error": .string("Business persistence unavailable")])
        let secondAfter = try await snapshot14()
        let historyPayloadsUnchanged = secondBefore == secondAfter
        #expect(historyPayloadsUnchanged)
        let stillHistorical = try await f.audit()
        #expect(stillHistorical.execution.agents[historical]?.processes[native.process]?.exited == false)
        #expect(stillHistorical.execution.agents[historical]?.sessionId == native.session)

        let activeNative = try await start(active)
        // Actual pending inventory holds the original reset without changing daemon or epoch.
        try await peer.socket.send(.init(["type": .string("ready"), "daemonInstanceId": .string(peer.daemonId),
            "capabilities": .array(["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"].map(JSONValue.string)),
            "runningAgents": .array([.string(historical), .string(active)]), "runtimeDetection": .object(["status": .string("pending")])]))
        try await peer.socket.applicationFence()
        let pending = try await f.audit()
        try #require(pending.execution.connections[machineId]?.ready == false)
        #expect(pending.execution.connections[machineId]?.connectionEpochId == peer.context.string("connectionEpochId"))
        #expect(pending.execution.connections[machineId]?.daemonInstanceId == peer.daemonId)
        let oldIds = Set((pending.execution.resetIntents ?? [:]).keys)
        let resetWire = peer.socket.count
        let resetEvents = updates.count
        let reset = try await f.http("POST", "/api/agents/\(active)/reset", token: owner, body: .init(["mode": .string("restart")]))
        try #require(reset.status == 202)
        let admitted = try await f.audit()
        let intent = try #require((admitted.execution.resetIntents ?? [:]).values.first { !oldIds.contains($0.operationId.uuidString) && $0.agentId == active })
        _ = try await peer.socket.nextObject(since: resetWire) { $0.string("type") == "agent:stop" && $0.string("agentId") == active }
        try await protocolPGEventually {
            let audit = try await f.audit()
            let written = try await f.outbox(intent.stopPhaseId)?.deliveredAt != nil
            return audit.execution.resetIntents?[intent.operationId.uuidString]?.stopAttempt == .written
                && audit.execution.resetIntents?[intent.operationId.uuidString]?.phase == .restart && written
        }
        let beforeCoalesce = try await f.audit()
        let original = try #require(beforeCoalesce.execution.agents[active])
        #expect(original.sessionId == activeNative.session && original.processes[activeNative.process]?.exited == false)
        // Preserve the actual existing strict coalescing path:200 is save, not a fabricated Builtin start.
        let coalesced = try await f.http("PATCH", "/api/agents/\(active)", token: owner, body: .init(transition))
        try #require(coalesced.status == 200)
        let afterCoalesce = try await f.audit()
        let record = try #require(afterCoalesce.execution.resetIntents?[intent.operationId.uuidString])
        let controlled = try #require(afterCoalesce.execution.agents[active])
        #expect(afterCoalesce.canonicalAgents.object(active)?.string("runtime") == "builtin")
        #expect(Set((afterCoalesce.execution.resetIntents ?? [:]).keys) == oldIds.union([intent.operationId.uuidString]))
        #expect(record.stopAttempt == .written && record.phase == .restart && record.sessionCleared)
        #expect(record.stopPhaseId == intent.stopPhaseId && record.restartPhaseId == intent.restartPhaseId && record.startCommandId == intent.startCommandId)
        #expect(controlled.generation == original.generation + 1 && controlled.takeoverEpoch == original.takeoverEpoch)
        #expect(controlled.sessionId == nil && controlled.processes[activeNative.process]?.exited == false && controlled.launches[activeNative.launch] != nil)
        #expect(afterCoalesce.execution.commands[intent.startCommandId.uuidString] == nil)
        #expect(Set(afterCoalesce.execution.commands.keys) == Set(beforeCoalesce.execution.commands.keys))
        _ = try await updates.nextText(since: resetEvents) { metadataNullSession($0, agent: active) }
        try await protocolPGEventually { try await f.outbox(intent.sessionPublicationId)?.deliveredAt != nil }
        let publications = try await updates.wireFence(since: resetEvents)
        #expect(publications.filter { metadataNullSession($0, agent: active) }.count == 1)
        let frames = try await peer.socket.wireFence(since: resetWire).compactMap { try? ProtocolPGObject(text: $0) }
        #expect(frames.filter { $0.string("type") == "agent:stop" && $0.string("agentId") == active }.count == 1)
        #expect(!frames.contains { $0.string("agentId") == active && ["agent:start", "agent:reset-workspace"].contains($0.string("type") ?? "") })
        #expect(afterCoalesce.execution.agents[builtin] == nil)
        // Readiness stays genuinely pending: no unsupported Builtin physical execution is claimed.
        await f.close(machine: machine, subscriber: subscriber)
    } catch {
        await f.close(machine: machine, subscriber: subscriber)
        throw error
    }
}
