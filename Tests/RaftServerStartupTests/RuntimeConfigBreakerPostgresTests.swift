import Foundation
import RaftPersistence
import RaftShared
import Synchronization
import Testing
@testable import RaftHTTP

private let configBreakerPGEnabled = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_PG_ACCEPTANCE"] == "1"
private enum ConfigBreakerAbort: Error { case rollback }

/// Real owned fresh-PG, HTTP and NIO protocol evidence. The controlled peer
/// reports protocol facts; this does not qualify a real process, Codex or model.
@Test(.enabled(if: configBreakerPGEnabled), .serialized)
func postgresRuntimeConfigChangesLiftOnlyCommittedTerminalBlocks() async throws {
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
        let roots = try DurableDomain.allCases.map { try DurableKey(domain: $0, aggregateID: "root") }
        let native = try DurableKey(domain: .notifications, aggregateID: "native")
        let keys = roots + [native]
        func config(_ effort: String? = nil) -> JSONValue {
            .object(["version": .integer(1), "runtime": .string("codex"),
                     "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")]),
                     "mode": .object(["kind": .string("default")]),
                     "reasoningEffort": effort.map(JSONValue.string) ?? .null, "envVars": .object([:])])
        }
        let attached = try await f.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(f.slug), "name": .string("Config breaker controlled peer")]))
        guard attached.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let machineID = try attached.object().requireString("machineId")
        let key = try attached.object().requireString("apiKey")
        func create(_ name: String, assigned: Bool = true) async throws -> String {
            var fields: [String: JSONValue] = ["name": .string(name), "runtimeConfig": config()]
            if assigned { fields["machineId"] = .string(machineID) }
            let reply = try await f.http("POST", "/api/agents", token: owner, body: .init(fields))
            guard reply.status == 200 else { throw ProtocolPGFailure.invalidResponse }
            return try reply.object().requireString("id")
        }
        // All creations precede actual ready; no presence/inventory setters.
        let agent = try await create("Terminal retries")
        let busy = try await create("Unexited process")
        let human = try await create("Explicit human takeover")
        let pendingWritten = try await create("Written start before spawn")
        let pendingAck = try await create("Acknowledged start before spawn")
        let lateFailure = try await create("Old generation failure evidence")
        let lateSuccess = try await create("Old generation completed evidence")
        let lateExit = try await create("Old generation exit before outcome")
        let healthy = try await create("Healthy confirmed current process")
        let queued = try await create("Never attempted delivery")
        let manual = try await create("Evidence recovery")
        let absent = try await create("No execution state", assigned: false)
        func channel(_ name: String, agent: String) async throws -> String {
            let made = try await f.http("POST", "/api/channels", token: owner, body: .init(["name": .string(name)]))
            guard made.status == 200 else { throw ProtocolPGFailure.invalidResponse }
            let id = try made.object().requireString("id")
            let joined = try await f.http("POST", "/api/channels/\(id)/members", token: owner,
                body: .init(["agentId": .string(agent)]))
            guard joined.status == 200 else { throw ProtocolPGFailure.invalidResponse }
            return id
        }
        let room = try await channel("config-terminal", agent: agent)
        let busyRoom = try await channel("config-unexited", agent: busy)
        let manualRoom = try await channel("config-manual", agent: manual)
        let pendingWrittenRoom = try await channel("config-written", agent: pendingWritten)
        let pendingAckRoom = try await channel("config-ack", agent: pendingAck)
        let lateFailureRoom = try await channel("config-late-failure", agent: lateFailure)
        let lateSuccessRoom = try await channel("config-late-success", agent: lateSuccess)
        let lateExitRoom = try await channel("config-late-exit-first", agent: lateExit)
        let healthyRoom = try await channel("config-healthy", agent: healthy)
        let humanRoom = try await channel("config-human-takeover", agent: human)
        let queuedRoom = try await channel("config-never-attempted", agent: queued)
        let updates = try await f.subscriber(token: owner); subscriber = updates
        let peer = try await ControlledMachineProtocolPeer.connect(port: f.machineServer.port, key: key); machine = peer
        try await peer.sendControlledReady()
        func start(_ id: String, acknowledge: Bool = true) async throws -> ProtocolPGObject {
            let boundary = peer.socket.count
            let reply = try await f.http("POST", "/api/agents/\(id)/start", token: owner)
            guard reply.status == 200 else { throw ProtocolPGFailure.invalidResponse }
            let frame = try await peer.socket.nextObject(since: boundary) { $0.string("type") == "agent:start" && $0.string("agentId") == id }
            if acknowledge { try await peer.acknowledgeControlledStart(frame) }
            else { try await peer.socket.applicationFence() }
            return frame
        }
        func outcome(_ id: String, launch: String, sequence: Int64) async throws {
            let boundary = peer.socket.count
            try await peer.socket.send(.init(["type": .string("agent:runtime:outcome"), "v": .integer(1),
                "agentId": .string(id), "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(sequence),
                "launchId": .string(launch), "sessionId": .null,
                "outcome": .object(["kind": .string("terminal_failure"), "failureKind": .string("runtime_error"),
                                    "fingerprint": .string("same-controlled-failure-not-a-model-result")])]))
            let ack = try await peer.socket.nextObject(since: boundary) {
                $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == id && $0.integer("clientSeq") == sequence
            }
            #expect(ack.string("daemonInstanceId") == peer.daemonId)
        }
        func complete(_ id: String, launch: String, sequence: Int64, session: String? = nil) async throws {
            let boundary = peer.socket.count
            try await peer.socket.send(.init(["type": .string("agent:runtime:outcome"), "v": .integer(1),
                "agentId": .string(id), "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(sequence),
                "launchId": .string(launch), "sessionId": session.map(JSONValue.string) ?? .null,
                "outcome": .object(["kind": .string("turn_completed")])]))
            _ = try await peer.socket.nextObject(since: boundary) {
                $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == id && $0.integer("clientSeq") == sequence
            }
        }
        func processFrame(_ type: String, id: String, launch: String, process: String, sequence: Int64) async throws {
            let boundary = peer.socket.count
            var fields: [String: JSONValue] = ["type": .string(type), "agentId": .string(id),
                "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(sequence),
                "launchId": .string(launch), "processInstanceId": .string(process)]
            if type == "agent:process_exited" { fields["spawnLaunchId"] = .string(launch) }
            try await peer.socket.send(.init(fields))
            _ = try await peer.socket.nextObject(since: boundary) {
                $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == id && $0.integer("clientSeq") == sequence
            }
        }
        func message(_ room: String, _ content: String) async throws -> String {
            let reply = try await f.http("POST", "/api/messages", token: owner,
                body: .init(["channelId": .string(room), "content": .string(content)]))
            guard reply.status == 200 else { throw ProtocolPGFailure.invalidResponse }
            return try reply.object().requireString("id")
        }
        func bytes(_ value: AgentExecutionAgent?) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        }
        func noNewCommands(_ id: String, since boundary: Int) async throws {
            let frames = try await peer.socket.wireFence(since: boundary).compactMap { try? ProtocolPGObject(text: $0) }
            #expect(!frames.contains { $0.string("agentId") == id && ["agent:start", "agent:deliver"].contains($0.string("type") ?? "") })
        }
        print("configlift PG: terminal-noop-rollback")
        let initial = try await start(agent)
        let firstLaunch = try initial.requireString("launchId")
        // A real authenticated session report establishes the nonempty value
        // that configuration recovery must preserve.
        try await peer.socket.send(.init(["type": .string("agent:session"), "agentId": .string(agent),
            "launchId": .string(firstLaunch), "sessionId": .string("retained-protocol-session")]))
        try await peer.socket.applicationFence()
        let firstProcess = "controlled-first-\(UUID().uuidString.lowercased())"
        try await processFrame("agent:process_spawned", id: agent, launch: firstLaunch, process: firstProcess, sequence: 0)
        try await outcome(agent, launch: firstLaunch, sequence: 1)
        try await processFrame("agent:process_exited", id: agent, launch: firstLaunch, process: firstProcess, sequence: 2)
        let retryBoundary = peer.socket.count
        let retryMessage = try await message(room, "First failure can retry through an ordinary message")
        let retry = try await peer.socket.nextObject(since: retryBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agent }
        let retryLaunch = try retry.requireString("launchId")
        #expect(retryLaunch != firstLaunch)
        #expect(retry.bool("humanStart") == false)
        try await peer.acknowledgeControlledStart(retry)
        let delivered = try await peer.socket.nextObject(since: retryBoundary) {
            $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == retryMessage
        }
        #expect(delivered.string("agentId") == agent)
        let retryAudit = try await f.audit()
        let retryDelivery = try #require(retryAudit.execution.commands.values.first { $0.deliveryId == delivered.string("deliveryId") })
        #expect(retryDelivery.launchId == retryLaunch)
        try await peer.acknowledgeControlledDelivery(delivered)
        let retryProcess = "controlled-retry-\(UUID().uuidString.lowercased())"
        try await processFrame("agent:process_spawned", id: agent, launch: retryLaunch, process: retryProcess, sequence: 3)
        try await outcome(agent, launch: retryLaunch, sequence: 4)
        try await processFrame("agent:process_exited", id: agent, launch: retryLaunch, process: retryProcess, sequence: 5)
        let blockedAudit = try await f.audit()
        #expect(blockedAudit.execution.commands[retryDelivery.commandId.uuidString]?.status == .accepted)
        #expect(blockedAudit.execution.dispatches?[retryDelivery.commandId.uuidString]?.phase == .accepted)
        let blocked = try #require(blockedAudit.execution.agents[agent])
        #expect(blocked.failureCount == 2)
        #expect(blocked.sameFingerprintCount == 2)
        #expect(blocked.blockedUntil.map { $0 > Date() } == true)
        #expect(blocked.sessionId == "retained-protocol-session")
        let blockedBytes = try bytes(blocked)
        let refusedBoundary = peer.socket.count
        for body in [ProtocolPGObject(["runtimeConfig": config()]),
                     ProtocolPGObject(["model": .string("gpt-5.3-codex")]),
                     ProtocolPGObject(["reasoningEffort": .string("high")])] {
            let same = try await f.http("PATCH", "/api/agents/\(agent)", token: owner, body: body)
            #expect(same.status == 200)
            #expect(try same.object().fields["reasoningEffort"] == .null)
            let audit = try await f.audit()
            #expect(try bytes(audit.execution.agents[agent]) == blockedBytes)
        }
        let malformed = try await f.http("PATCH", "/api/agents/\(agent)", token: owner,
            body: .init(["runtimeConfig": config("high"), "reasoningEffort": .string("invalid-raw-effort")]))
        #expect(malformed.status == 400)
        let nonmember = try await f.http("PATCH", "/api/agents/\(agent)", token: outsider, body: .init(["runtimeConfig": config("high")]))
        #expect(nonmember.status == 403)
        let refusedAudit = try await f.audit()
        #expect(try bytes(refusedAudit.execution.agents[agent]) == blockedBytes)
        #expect(refusedAudit.execution.commands.count == blockedAudit.execution.commands.count)
        _ = try await message(room, "A no-op and refused patch must leave the automatic breaker closed to wakes")
        let stillBlocked = try await f.audit()
        #expect(stillBlocked.execution.commands.count == blockedAudit.execution.commands.count)
        try await noNewCommands(agent, since: refusedBoundary)

        let changedBody = ProtocolPGObject(["runtimeConfig": config("high")])
        let changedRequest = try JSONDecoder().decode(LegacyJSONObjectBody.self, from: changedBody.data)
        let discardedCommand = UUID()
        let rollbackBaseline = Mutex<[DurableDocument]?>(nil)
        // Real Shared rollback-only, not an ordinary throw (domain errors may
        // intentionally commit counters). Exercise the actual existing facade.
        do {
            try await f.runtime.execute {
                let documents = try await f.observer.readSnapshot(keys)
                guard documents.count == 14, Set(documents.map(\.key)) == Set(keys) else { throw ProtocolPGFailure.invalidSnapshot }
                rollbackBaseline.withLock { $0 = documents }
                _ = try f.accounts.agentSurface.bindingExecution(f.accounts.agentExecution(persistence: f.runtime))
                    .patchAgent(authorization: "Bearer \(owner)", agentId: agent, body: changedRequest, serverId: f.serverId)
                // An explicit existing producer supplies a known real effect ID
                // for discard inspection; configuration itself stages no start.
                _ = try f.accounts.agentExecution(persistence: f.runtime).requestStart(
                    .init(commandId: discardedCommand, serverId: f.serverId, agentId: agent)
                )
                DeferredEffects.markRollbackOnly()
                throw ConfigBreakerAbort.rollback
            }
            Issue.record("Expected real coordinator discard")
        } catch TransactionError.rollbackOnly {}
        let discarded = try await f.audit()
        #expect(try bytes(discarded.execution.agents[agent]) == blockedBytes)
        #expect(try await f.observer.outboxEffect(effectID: discardedCommand) == nil)
        let beforeRollback = try #require(rollbackBaseline.withLock { $0 })
        let afterRollback = try await f.observer.readSnapshot(keys)
        #expect(afterRollback.count == 14)
        let rollbackPayloadsEqual = Dictionary(uniqueKeysWithValues: beforeRollback.map { ($0.key, $0.json) }) == Dictionary(uniqueKeysWithValues: afterRollback.map { ($0.key, $0.json) })
        #expect(rollbackPayloadsEqual)
        let afterDiscard = try await f.http("GET", "/api/agents/\(agent)", token: owner)
        #expect(afterDiscard.status == 200)
        #expect(try afterDiscard.object().fields["reasoningEffort"] == .null)
        let liftBoundary = peer.socket.count
        let changed = try await f.http("PATCH", "/api/agents/\(agent)", token: owner, body: changedBody)
        #expect(changed.status == 200)
        #expect(try changed.object().string("reasoningEffort") == "high")
        let liftedAudit = try await f.audit()
        let lifted = try #require(liftedAudit.execution.agents[agent])
        #expect(lifted.generation == blocked.generation + 1)
        #expect(lifted.failureCount == 0 && lifted.sameFingerprint == nil && lifted.sameFingerprintCount == 0)
        #expect(lifted.backoffStep == 0 && lifted.blockedUntil == nil && lifted.probeLaunchId == nil && lifted.probeExpiresAt == nil)
        #expect(lifted.currentLaunchId == nil)
        #expect(lifted.needsManual == blocked.needsManual && lifted.takeoverEpoch == blocked.takeoverEpoch)
        #expect(lifted.sessionId == blocked.sessionId)
        #expect(liftedAudit.execution.commands.count == discarded.execution.commands.count)
        try await noNewCommands(agent, since: liftBoundary)
        let resumedBoundary = peer.socket.count
        let resumedMessage = try await message(room, "A committed real canonical change permits the next ordinary wake")
        let resumed = try await peer.socket.nextObject(since: resumedBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agent }
        #expect(resumed.string("launchId") != retryLaunch)
        try await peer.acknowledgeControlledStart(resumed)
        let resumedDelivery = try await peer.socket.nextObject(since: resumedBoundary) {
            $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == resumedMessage
        }
        #expect(resumedDelivery.string("agentId") == agent)
        #expect(resumed.bool("humanStart") == false)
        let resumedAudit = try await f.audit()
        let resumedCommand = try #require(resumedAudit.execution.commands.values.first { $0.deliveryId == resumedDelivery.string("deliveryId") })
        #expect(resumedCommand.launchId == resumed.string("launchId"))
        try await peer.acknowledgeControlledDelivery(resumedDelivery)
        let resumedLaunch = try resumed.requireString("launchId")
        let resumedProcess = "controlled-resumed-\(UUID().uuidString.lowercased())"
        try await processFrame("agent:process_spawned", id: agent, launch: resumedLaunch, process: resumedProcess, sequence: 6)
        let completedBoundary = peer.socket.count
        try await peer.socket.send(.init(["type": .string("agent:runtime:outcome"), "v": .integer(1),
            "agentId": .string(agent), "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(7),
            "launchId": .string(resumedLaunch), "sessionId": .string("retained-protocol-session"),
            "outcome": .object(["kind": .string("turn_completed")])]))
        _ = try await peer.socket.nextObject(since: completedBoundary) { $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == agent && $0.integer("clientSeq") == 7 }
        try await processFrame("agent:process_exited", id: agent, launch: resumedLaunch, process: resumedProcess, sequence: 8)

        print("configlift PG: unexited-exit-auto")
        let busyStart = try await start(busy)
        let busyLaunch = try busyStart.requireString("launchId")
        let process = "controlled-unexited-\(UUID().uuidString.lowercased())"
        let spawnBoundary = peer.socket.count
        try await peer.socket.send(.init(["type": .string("agent:process_spawned"), "agentId": .string(busy),
            "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(0), "launchId": .string(busyLaunch),
            "processInstanceId": .string(process)]))
        _ = try await peer.socket.nextObject(since: spawnBoundary) { $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == busy && $0.integer("clientSeq") == 0 }
        try await outcome(busy, launch: busyLaunch, sequence: 1)
        let beforeBusy = try #require(try await f.audit().execution.agents[busy])
        #expect(beforeBusy.processes[process]?.exited == false)
        let busyBoundary = peer.socket.count
        let busyChanged = try await f.http("PATCH", "/api/agents/\(busy)", token: owner, body: changedBody)
        #expect(busyChanged.status == 200)
        let busyLiftAudit = try await f.audit()
        let busyLift = try #require(busyLiftAudit.execution.agents[busy])
        #expect(busyLift.generation == beforeBusy.generation + 1 && busyLift.currentLaunchId == nil)
        #expect(busyLift.processes[process]?.exited == false)
        #expect(busyLift.takeoverEpoch == beforeBusy.takeoverEpoch && busyLift.needsManual == beforeBusy.needsManual)
        _ = try await message(busyRoom, "Unexited survives config lift and prohibits a second automatic spawn")
        let unexitedAudit = try await f.audit()
        #expect(unexitedAudit.execution.commands.count == busyLiftAudit.execution.commands.count)
        try await noNewCommands(busy, since: busyBoundary)
        let exitBoundary = peer.socket.count
        try await peer.socket.send(.init(["type": .string("agent:process_exited"), "agentId": .string(busy),
            "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(2), "launchId": .string(busyLaunch),
            "processInstanceId": .string(process), "spawnLaunchId": .string(busyLaunch)]))
        _ = try await peer.socket.nextObject(since: exitBoundary) { $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == busy && $0.integer("clientSeq") == 2 }
        #expect(try await f.audit().execution.agents[busy]?.processes[process]?.exited == true)
        let exitedBoundary = peer.socket.count
        let afterExitMessage = try await message(busyRoom, "Only the actual exit permits the next automatic launch")
        let afterExit = try await peer.socket.nextObject(since: exitedBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == busy }
        #expect(afterExit.string("launchId") != busyLaunch)
        #expect(afterExit.bool("humanStart") == false)
        try await peer.acknowledgeControlledStart(afterExit)
        let afterExitDelivery = try await peer.socket.nextObject(since: exitedBoundary) {
            $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == afterExitMessage
        }
        try await peer.acknowledgeControlledDelivery(afterExitDelivery)

        // Independent real unexited branch: Node explicitly allows the
        // authenticated human_start takeover that automatic wakes cannot claim.
        print("configlift PG: human-takeover")
        let humanStart = try await start(human)
        let humanLaunch = try humanStart.requireString("launchId")
        let humanProcess = "controlled-human-unexited-\(UUID().uuidString.lowercased())"
        let humanSpawnBoundary = peer.socket.count
        try await peer.socket.send(.init(["type": .string("agent:process_spawned"), "agentId": .string(human),
            "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(0), "launchId": .string(humanLaunch),
            "processInstanceId": .string(humanProcess)]))
        _ = try await peer.socket.nextObject(since: humanSpawnBoundary) { $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == human && $0.integer("clientSeq") == 0 }
        try await outcome(human, launch: humanLaunch, sequence: 1)
        let humanChanged = try await f.http("PATCH", "/api/agents/\(human)", token: owner, body: changedBody)
        #expect(humanChanged.status == 200)
        let beforeTakeover = try #require(try await f.audit().execution.agents[human])
        #expect(beforeTakeover.processes[humanProcess]?.exited == false)
        let takeover = try await start(human)
        let takeoverLaunch = try takeover.requireString("launchId")
        #expect(takeover.bool("humanStart") == true)
        #expect(takeoverLaunch != humanLaunch)
        let takeoverAudit = try await f.audit()
        let taken = try #require(takeoverAudit.execution.agents[human])
        let takeoverCommand = try #require(takeoverAudit.execution.commands.values.first { $0.startDispatchId == takeover.string("startDispatchId") })
        #expect(takeoverCommand.humanStart == true && takeoverCommand.launchId == takeoverLaunch)
        #expect(taken.takeoverEpoch == beforeTakeover.takeoverEpoch + 1)
        #expect(taken.generation == beforeTakeover.generation + 1)
        #expect(taken.processes[humanProcess]?.exited == false)
        let takenProcess = "controlled-taken-\(UUID().uuidString.lowercased())"
        try await processFrame("agent:process_spawned", id: human, launch: takeoverLaunch, process: takenProcess, sequence: 2)
        let takenCompletedBoundary = peer.socket.count
        try await peer.socket.send(.init(["type": .string("agent:runtime:outcome"), "v": .integer(1),
            "agentId": .string(human), "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(3),
            "launchId": .string(takeoverLaunch), "sessionId": .null,
            "outcome": .object(["kind": .string("turn_completed")])]))
        _ = try await peer.socket.nextObject(since: takenCompletedBoundary) { $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == human && $0.integer("clientSeq") == 3 }
        try await processFrame("agent:process_exited", id: human, launch: takeoverLaunch, process: takenProcess, sequence: 4)
        let takenNextBoundary = peer.socket.count
        let takenNextMessage = try await message(humanRoom, "An acknowledged old epoch does not block the new epoch automatic wake")
        let takenNext = try await peer.socket.nextObject(since: takenNextBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == human }
        #expect(takenNext.bool("humanStart") == false)
        #expect(takenNext.string("launchId") != takeoverLaunch)
        try await peer.acknowledgeControlledStart(takenNext)
        let takenNextDelivery = try await peer.socket.nextObject(since: takenNextBoundary) {
            $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == takenNextMessage
        }
        try await peer.acknowledgeControlledDelivery(takenNextDelivery)
        let takenNextState = try #require(try await f.audit().execution.agents[human])
        #expect(takenNextState.takeoverEpoch == taken.takeoverEpoch)
        #expect(takenNextState.processes[humanProcess]?.exited == false)

        // A written/ACKed start has pending unexited evidence even before the
        // daemon reports a process ID. Only a real negative outcome releases it.
        print("configlift PG: pending-written-ack")
        for (pending, pendingRoom, acknowledged) in [(pendingWritten, pendingWrittenRoom, false), (pendingAck, pendingAckRoom, true)] {
            let sent = try await start(pending, acknowledge: acknowledged)
            let pendingLaunch = try sent.requireString("launchId")
            let pendingAudit = try await f.audit()
            let pendingState = try #require(pendingAudit.execution.agents[pending])
            let sentCommand = try #require(pendingAudit.execution.commands.values.first { $0.startDispatchId == sent.string("startDispatchId") })
            #expect(pendingState.processes.isEmpty)
            #expect(pendingAudit.execution.dispatches?[sentCommand.commandId.uuidString] != nil)
            #expect(pendingState.launches[pendingLaunch]?.startAccepted == acknowledged)
            let boundary = peer.socket.count
            let pendingChanged = try await f.http("PATCH", "/api/agents/\(pending)", token: owner, body: changedBody)
            #expect(pendingChanged.status == 200)
            let afterPendingLift = try await f.audit()
            #expect(afterPendingLift.execution.agents[pending]?.generation == pendingState.generation + 1)
            _ = try await message(pendingRoom, "Pending start evidence survives a config lift without a process report")
            #expect(try await f.audit().execution.commands.count == afterPendingLift.execution.commands.count)
            try await noNewCommands(pending, since: boundary)
            let negativeBoundary = peer.socket.count
            try await peer.socket.send(.init(["type": .string("agent:start:outcome"), "agentId": .string(pending),
                "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(0), "launchId": .string(pendingLaunch),
                "result": .object(["kind": .string("not_spawned"), "reason": .string("cancelled")])]))
            _ = try await peer.socket.nextObject(since: negativeBoundary) { $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == pending && $0.integer("clientSeq") == 0 }
            #expect(try await f.audit().execution.agents[pending]?.launches[pendingLaunch]?.notSpawned == true)
            let releasedBoundary = peer.socket.count
            let releasedMessage = try await message(pendingRoom, "Actual not-spawned evidence releases the pending protection")
            let released = try await peer.socket.nextObject(since: releasedBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == pending }
            #expect(released.string("launchId") != pendingLaunch && released.bool("humanStart") == false)
            try await peer.acknowledgeControlledStart(released)
            let releaseDelivery = try await peer.socket.nextObject(since: releasedBoundary) {
                $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == releasedMessage
            }
            try await peer.acknowledgeControlledDelivery(releaseDelivery)
        }

        // Lift detaches the old launch from breaker accounting, but authentic
        // late outcomes remain termination evidence for its eventual real exit.
        print("configlift PG: late-outcome")
        for (late, lateRoom, completed) in [(lateFailure, lateFailureRoom, false), (lateSuccess, lateSuccessRoom, true)] {
            let old = try await start(late)
            let oldLaunch = try old.requireString("launchId")
            let oldProcess = "controlled-late-\(UUID().uuidString.lowercased())"
            try await processFrame("agent:process_spawned", id: late, launch: oldLaunch, process: oldProcess, sequence: 0)
            let nativeSession = "retained-session-\(late)"
            try await peer.socket.send(.init(["type": .string("agent:session"), "agentId": .string(late),
                "launchId": .string(oldLaunch), "sessionId": .string(nativeSession)]))
            try await peer.socket.applicationFence()
            let changedLate = try await f.http("PATCH", "/api/agents/\(late)", token: owner, body: changedBody)
            #expect(changedLate.status == 200)
            let liftedLate = try #require(try await f.audit().execution.agents[late])
            let lateBoundary = peer.socket.count
            let reported: JSONValue = completed ? .object(["kind": .string("turn_completed")])
                : .object(["kind": .string("terminal_failure"), "failureKind": .string("runtime_error"), "fingerprint": .string("old-generation-failure")])
            try await peer.socket.send(.init(["type": .string("agent:runtime:outcome"), "v": .integer(1),
                "agentId": .string(late), "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(1),
                "launchId": .string(oldLaunch), "sessionId": .string("different-late-session-must-not-replace-current"),
                "outcome": reported]))
            _ = try await peer.socket.nextObject(since: lateBoundary) { $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == late && $0.integer("clientSeq") == 1 }
            let afterLate = try #require(try await f.audit().execution.agents[late])
            #expect(afterLate.launches[oldLaunch]?.completed == completed)
            #expect(afterLate.launches[oldLaunch]?.terminalFailure == !completed)
            #expect(afterLate.generation == liftedLate.generation && afterLate.currentLaunchId == nil)
            #expect(afterLate.failureCount == liftedLate.failureCount && afterLate.sameFingerprint == liftedLate.sameFingerprint)
            #expect(afterLate.sameFingerprintCount == liftedLate.sameFingerprintCount && afterLate.blockedUntil == liftedLate.blockedUntil)
            #expect(afterLate.sessionId == nativeSession && afterLate.takeoverEpoch == liftedLate.takeoverEpoch)
            try await processFrame("agent:process_exited", id: late, launch: oldLaunch, process: oldProcess, sequence: 2)
            let afterLateExit = try #require(try await f.audit().execution.agents[late])
            #expect(afterLateExit.needsManual == liftedLate.needsManual)
            #expect(afterLateExit.processes[oldProcess]?.exited == true)
            let nextBoundary = peer.socket.count
            let nextMessage = try await message(lateRoom, "A real old-generation outcome and exit permit the next automatic launch")
            let next = try await peer.socket.nextObject(since: nextBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == late }
            #expect(next.string("launchId") != oldLaunch && next.bool("humanStart") == false)
            try await peer.acknowledgeControlledStart(next)
            let nextDelivery = try await peer.socket.nextObject(since: nextBoundary) {
                $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == nextMessage
            }
            try await peer.acknowledgeControlledDelivery(nextDelivery)
        }

        // A confirmed healthy current process is exempt after clean E2. The
        // next start is allowed, but the daemon must actually report rebind.
        print("configlift PG: healthy-rebind-attempted")
        let healthyStart = try await start(healthy)
        let healthyLaunch = try healthyStart.requireString("launchId")
        let healthyProcess = "controlled-healthy-\(UUID().uuidString.lowercased())"
        try await processFrame("agent:process_spawned", id: healthy, launch: healthyLaunch, process: healthyProcess, sequence: 0)
        try await complete(healthy, launch: healthyLaunch, sequence: 1)
        let clean = try #require(try await f.audit().execution.agents[healthy])
        #expect(clean.launches[healthyLaunch]?.completed == true && clean.processes[healthyProcess]?.exited == false)
        #expect(clean.needsManual == nil && clean.blockedUntil == nil)
        let healthyBoundary = peer.socket.count
        let healthyMessage = try await message(healthyRoom, "Clean E2 permits the next normal wake while its confirmed process remains live")
        let healthyNext = try await peer.socket.nextObject(since: healthyBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == healthy }
        let healthyNextLaunch = try healthyNext.requireString("launchId")
        #expect(healthyNextLaunch != healthyLaunch && healthyNext.bool("humanStart") == false)
        let reboundBoundary = peer.socket.count
        try await peer.socket.send(.init(["type": .string("agent:start:outcome"), "agentId": .string(healthy),
            "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(2), "launchId": .string(healthyNextLaunch),
            "result": .object(["kind": .string("rebound"), "processInstanceId": .string(healthyProcess)])]))
        _ = try await peer.socket.nextObject(since: reboundBoundary) { $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == healthy && $0.integer("clientSeq") == 2 }
        let healthyDelivery = try await peer.socket.nextObject(since: healthyBoundary) {
            $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == healthyMessage
        }
        try await peer.acknowledgeControlledDelivery(healthyDelivery)
        let rebound = try #require(try await f.audit().execution.agents[healthy])
        #expect(rebound.launches[healthyNextLaunch]?.processInstanceId == healthyProcess)
        #expect(rebound.processes[healthyProcess]?.exited == false)
        #expect(rebound.processes[healthyProcess]?.launchIds.contains(healthyNextLaunch) == true)
        let attemptedBoundary = peer.socket.count
        let attemptedMessage = try await message(healthyRoom, "An actually attempted delivery cannot be rewritten as never sent")
        let attemptedFrame = try await peer.socket.nextObject(since: attemptedBoundary) {
            $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == attemptedMessage
        }
        let attemptedAudit = try await f.audit()
        let attemptedCommand = try #require(attemptedAudit.execution.commands.values.first { $0.deliveryId == attemptedFrame.string("deliveryId") })
        #expect(attemptedAudit.execution.dispatches?[attemptedCommand.commandId.uuidString] != nil)
        try await outcome(healthy, launch: healthyNextLaunch, sequence: 3)
        let terminalAttempt = try await f.audit()
        #expect(terminalAttempt.execution.commands[attemptedCommand.commandId.uuidString]?.status != .superseded)
        #expect(terminalAttempt.execution.dispatches?[attemptedCommand.commandId.uuidString] != nil)
        try await peer.acknowledgeControlledDelivery(attemptedFrame)
        let acknowledgedAttempt = try await f.audit()
        #expect(acknowledgedAttempt.execution.commands[attemptedCommand.commandId.uuidString]?.status == .accepted)
        #expect(acknowledgedAttempt.execution.dispatches?[attemptedCommand.commandId.uuidString]?.phase == .accepted)

        // The old exit may arrive first; its missing outcome alone cannot
        // label the new generation manual. A still later E1 stays historical.
        print("configlift PG: exit-before-outcome")
        let exitFirstStart = try await start(lateExit)
        let exitFirstLaunch = try exitFirstStart.requireString("launchId")
        let exitFirstProcess = "controlled-exit-first-\(UUID().uuidString.lowercased())"
        try await processFrame("agent:process_spawned", id: lateExit, launch: exitFirstLaunch, process: exitFirstProcess, sequence: 0)
        let exitFirstChanged = try await f.http("PATCH", "/api/agents/\(lateExit)", token: owner, body: changedBody)
        #expect(exitFirstChanged.status == 200)
        let exitFirstLift = try #require(try await f.audit().execution.agents[lateExit])
        try await processFrame("agent:process_exited", id: lateExit, launch: exitFirstLaunch, process: exitFirstProcess, sequence: 1)
        #expect(try await f.audit().execution.agents[lateExit]?.needsManual == exitFirstLift.needsManual)
        let exitFirstBoundary = peer.socket.count
        let exitFirstMessage = try await message(lateExitRoom, "An old exit does not require an invented terminal outcome to release its process")
        let exitFirstNext = try await peer.socket.nextObject(since: exitFirstBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == lateExit }
        let exitFirstNextLaunch = try exitFirstNext.requireString("launchId")
        #expect(exitFirstNextLaunch != exitFirstLaunch && exitFirstNext.bool("humanStart") == false)
        try await peer.acknowledgeControlledStart(exitFirstNext)
        let beforeHistorical = try #require(try await f.audit().execution.agents[lateExit])
        try await outcome(lateExit, launch: exitFirstLaunch, sequence: 2)
        let afterHistorical = try #require(try await f.audit().execution.agents[lateExit])
        #expect(afterHistorical.launches[exitFirstLaunch]?.terminalFailure == true)
        #expect(afterHistorical.generation == beforeHistorical.generation && afterHistorical.currentLaunchId == exitFirstNextLaunch)
        #expect(afterHistorical.failureCount == beforeHistorical.failureCount && afterHistorical.needsManual == beforeHistorical.needsManual)
        #expect(afterHistorical.sessionId == beforeHistorical.sessionId)
        let exitFirstDelivery = try await peer.socket.nextObject(since: exitFirstBoundary) {
            $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == exitFirstMessage
        }
        try await peer.acknowledgeControlledDelivery(exitFirstDelivery)

        // Real queue boundary: withholding admission ACK makes delivery wait,
        // without pausing or replacing a worker. E1 cancels only no-attempt work.
        print("configlift PG: never-attempted-queue")
        let queuedStart = try await start(queued, acknowledge: false)
        let queuedLaunch = try queuedStart.requireString("launchId")
        let queuedMessage = try await message(queuedRoom, "Retained original message must not reach a failed launch")
        let queuedBefore = try await f.audit()
        let queuedCommand = try #require(queuedBefore.execution.commands.values.first { $0.kind == .delivery && $0.messageId == queuedMessage })
        #expect(queuedCommand.status == .pending)
        #expect(queuedBefore.execution.dispatches?[queuedCommand.commandId.uuidString] == nil)
        #expect(try await f.outbox(queuedCommand.commandId) != nil)
        let nonExecutionKeys = keys.filter { $0.domain != .agentsRuntime }
        let queuedFactsBefore = try await f.observer.readSnapshot(nonExecutionKeys)
        let cancelledBoundary = peer.socket.count
        try await outcome(queued, launch: queuedLaunch, sequence: 0)
        try await peer.acknowledgeControlledStart(queuedStart)
        try await protocolPGEventually { try await f.outbox(queuedCommand.commandId)?.lastFailure == .rejected }
        let rejectedDelivery = try #require(try await f.outbox(queuedCommand.commandId))
        #expect(rejectedDelivery.deliveredAt == nil && rejectedDelivery.lastFailure == .rejected)
        let cancelled = try await f.audit()
        #expect(cancelled.execution.commands[queuedCommand.commandId.uuidString]?.status == .superseded)
        #expect(cancelled.execution.dispatches?[queuedCommand.commandId.uuidString] == nil)
        #expect(cancelled.messages.contains { $0.string("id") == queuedMessage })
        let queuedFactsAfter = try await f.observer.readSnapshot(nonExecutionKeys)
        let nonExecutionFactsEqual = Dictionary(uniqueKeysWithValues: queuedFactsBefore.map { ($0.key, $0.json) }) == Dictionary(uniqueKeysWithValues: queuedFactsAfter.map { ($0.key, $0.json) })
        #expect(nonExecutionFactsEqual)
        try await noNewCommands(queued, since: cancelledBoundary)
        let queuedNegativeBoundary = peer.socket.count
        try await peer.socket.send(.init(["type": .string("agent:start:outcome"), "agentId": .string(queued),
            "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(1), "launchId": .string(queuedLaunch),
            "result": .object(["kind": .string("not_spawned"), "reason": .string("cancelled")])]))
        _ = try await peer.socket.nextObject(since: queuedNegativeBoundary) { $0.string("type") == "agent:outcome:ack" && $0.string("agentId") == queued && $0.integer("clientSeq") == 1 }
        let queuedChanged = try await f.http("PATCH", "/api/agents/\(queued)", token: owner, body: changedBody)
        #expect(queuedChanged.status == 200)
        let queuedFreshBoundary = peer.socket.count
        let queuedFreshMessage = try await message(queuedRoom, "Future fresh wake preserves the retained original history")
        let queuedFresh = try await peer.socket.nextObject(since: queuedFreshBoundary) { $0.string("type") == "agent:start" && $0.string("agentId") == queued }
        #expect(queuedFresh.string("launchId") != queuedLaunch && queuedFresh.bool("humanStart") == false)
        try await peer.acknowledgeControlledStart(queuedFresh)
        let queuedFreshDelivery = try await peer.socket.nextObject(since: queuedFreshBoundary) {
            $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == queuedFreshMessage
        }
        try await peer.acknowledgeControlledDelivery(queuedFreshDelivery)
        let history = try await f.http("GET", "/api/messages/channel/\(queuedRoom)", token: owner)
        #expect(history.status == 200)
        #expect(String(decoding: history.body, as: UTF8.self).contains(queuedMessage))
        #expect(try await f.audit().messages.contains { $0.string("id") == queuedMessage })

        print("configlift PG: needsmanual-env-absent")
        let manualStart = try await start(manual)
        let markerBoundary = peer.socket.count
        try await peer.socket.send(.init(["type": .string("agent:runtime:outcome_gap"), "agentId": .string(manual),
            "gapId": .string(UUID().uuidString.lowercased()), "takeoverEpoch": .integer(1),
            "counts": .object(["e1": .integer(1), "spawned": .integer(0), "exited": .integer(0), "startOutcome": .integer(0), "turnCompleted": .integer(0)])]))
        try await peer.socket.applicationFence()
        let beforeManual = try #require(try await f.audit().execution.agents[manual])
        #expect(beforeManual.needsManual == "outcome_evidence_lost")
        let manualChanged = try await f.http("PATCH", "/api/agents/\(manual)", token: owner, body: changedBody)
        #expect(manualChanged.status == 200)
        let afterManual = try #require(try await f.audit().execution.agents[manual])
        #expect(afterManual.generation == beforeManual.generation + 1)
        #expect(afterManual.needsManual == beforeManual.needsManual)
        #expect(afterManual.takeoverEpoch == beforeManual.takeoverEpoch)
        // Env values are also part of Node's runtimeProfileIdentityChanged;
        // this does not change runtime/model/effort and must still lift once.
        let envBody = ProtocolPGObject(["envVars": .object(["ORDINARY": .string("changed")])])
        let envChanged = try await f.http("PATCH", "/api/agents/\(manual)", token: owner, body: envBody)
        #expect(envChanged.status == 200)
        let afterEnv = try #require(try await f.audit().execution.agents[manual])
        #expect(afterEnv.generation == afterManual.generation + 1)
        #expect(afterEnv.needsManual == beforeManual.needsManual)
        let envSame = try await f.http("PATCH", "/api/agents/\(manual)", token: owner, body: envBody)
        #expect(envSame.status == 200)
        #expect(try await f.audit().execution.agents[manual]?.generation == afterEnv.generation)
        _ = try await message(manualRoom, "Config lift does not acknowledge missing outcome evidence")
        try await noNewCommands(manual, since: markerBoundary)
        #expect(manualStart.string("agentId") == manual)
        #expect(try await f.audit().execution.agents[absent] == nil)
        let absentChanged = try await f.http("PATCH", "/api/agents/\(absent)", token: owner, body: changedBody)
        #expect(absentChanged.status == 200)
        #expect(try await f.audit().execution.agents[absent] == nil)

        // Exact14 current owner documents, scoped to this fixture's mandatory
        // empty isolated DB. The actual lease-bound PG port performs a real
        // same-payload CAS while BPR's admitted producer is in flight, making
        // BPR's cached revisions stale. The independent observer only reads:
        // another backend cannot borrow an epoch past the real writer fence.
        // Capture actual PG bytes inside the admitted FIFO operation so an
        // unrelated dispatch callback cannot move an outside baseline first.
        print("configlift PG: real-cas-failure")
        let conflictBaseline = Mutex<[DurableDocument]?>(nil)
        let failedBoundary = peer.socket.count
        let publicationBoundary = updates.count
        let writer = await f.runtime.persistence
        let epoch = await f.runtime.lease.epoch
        let conflictBody = ProtocolPGObject(["runtimeConfig": config("max"), "serverRole": .string("admin")])
        let conflictRequest = try JSONDecoder().decode(LegacyJSONObjectBody.self, from: conflictBody.data)
        let failedCommand = UUID()
        do {
            try await f.runtime.execute {
                _ = try f.accounts.agentSurface.bindingExecution(f.accounts.agentExecution(persistence: f.runtime))
                    .patchAgent(authorization: "Bearer \(owner)", agentId: agent, body: conflictRequest, serverId: f.serverId)
                _ = try f.accounts.agentExecution(persistence: f.runtime).requestStart(
                    .init(commandId: failedCommand, serverId: f.serverId, agentId: agent)
                )
                let documents = try await f.observer.readSnapshot(keys)
                guard documents.count == 14, Set(documents.map(\.key)) == Set(keys) else { throw ProtocolPGFailure.invalidSnapshot }
                conflictBaseline.withLock { $0 = documents }
                let writes = try documents.map {
                    try DurableWrite.put($0.decode(Data.self, codecVersion: 1), key: $0.key, codecVersion: 1, expectedRevision: $0.revision)
                }
                _ = try await writer.compareAndSwap(writes, expectedWriterEpoch: epoch)
            }
            Issue.record("Expected the actual stale revision commit to fail")
        } catch PersistenceError.conflict {}
        let beforeConflict = try #require(conflictBaseline.withLock { $0 })
        let afterConflict = try await f.observer.readSnapshot(keys)
        #expect(afterConflict.count == 14)
        let failedPayloadsEqual = Dictionary(uniqueKeysWithValues: beforeConflict.map { ($0.key, $0.json) }) == Dictionary(uniqueKeysWithValues: afterConflict.map { ($0.key, $0.json) })
        #expect(failedPayloadsEqual)
        #expect(try await f.observer.outboxEffect(effectID: failedCommand) == nil)
        let closed = try await f.http("GET", "/api/agents/\(agent)", token: owner)
        #expect(closed.status == 503)
        let closedPatch = try await f.http("PATCH", "/api/agents/\(agent)", token: owner, body: conflictBody)
        #expect(closedPatch.status == 503)
        try await noNewCommands(agent, since: failedBoundary)
        let events = try await updates.wireFence(since: publicationBoundary)
        #expect(!events.contains { $0.contains("agent:updated") || $0.contains("message:created") || $0.contains("message:new") })
        await f.close(machine: machine, subscriber: subscriber)
    } catch {
        await f.close(machine: machine, subscriber: subscriber)
        throw error
    }
}
