import Foundation
import RaftPersistence
import RaftShared
import Testing
@testable import RaftHTTP

private let restartRecoveryPGEnabled =
    ProcessInfo.processInfo.environment["RAFT_RESTART_RECOVERY_PG_ACCEPTANCE"] == "1"

/// Real HTTP, PostgreSQL and authenticated machine socket. A controlled peer
/// supplies the process and turn facts; this is not proof of an official
/// Computer, a Codex process, a model turn or provider acceptance. Run this
/// filter in its own process with its own disposable database.
@Test(.enabled(if: restartRecoveryPGEnabled), .serialized)
func postgresIdleProcessSurvivesMainRestartAndAcceptsHumanDelivery() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_RESTART_RECOVERY_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    func phase(_ value: String) { print("RESTART_RECOVERY_PG \(value)") }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    phase("fixture-started")
    var machine: ControlledMachineProtocolPeer?
    let daemonId = "restart-recovery-daemon-\(UUID().uuidString.lowercased())"
    let sequence = ProtocolPGSequence()
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let attached = try await fixture.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("Restart recovery fixture")]))
        guard attached.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let computer = try attached.object()
        let machineID = try computer.requireString("machineId")
        let key = try computer.requireString("apiKey")
        let config: JSONValue = .object(["version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")])])
        let created = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Idle restart recipient"), "machineId": .string(machineID),
                         "runtimeConfig": config]))
        guard created.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let agentID = try created.object().requireString("id")
        let room = try await fixture.http("POST", "/api/channels", token: owner,
            body: .init(["name": .string("restart-recovery-room")]))
        guard room.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let channelID = try room.object().requireString("id")
        let join = try await fixture.http("POST", "/api/channels/\(channelID)/members", token: owner,
            body: .init(["agentId": .string(agentID)]))
        guard join.status == 200 else { throw ProtocolPGFailure.invalidResponse }

        phase("http-setup-complete")
        let peer = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: daemonId, sequence: sequence)
        machine = peer
        try await peer.sendControlledReady(runningAgentIds: [])
        phase("first-ready")
        let startBoundary = peer.socket.count
        let started = try await fixture.http("POST", "/api/agents/\(agentID)/start", token: owner)
        #expect(started.status == 200)
        let start = try await peer.socket.nextObject(since: startBoundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == agentID
        }
        let launchID = try start.requireString("launchId")
        phase("start-frame")
        try await peer.acknowledgeControlledStart(start)
        try await peer.sendProcessSpawned(agentId: agentID, launchId: launchID, processInstanceId: "process-1")
        try await peer.sendTurnCompleted(agentId: agentID, launchId: launchID, sessionId: "codex-session")
        phase("outcomes-sent")
        try await protocolPGEventually {
            let state = try await fixture.audit().execution.agents[agentID]
            return state?.launches[launchID]?.completed == true
                && state?.processes["process-1"]?.exited == false
        }

        // The real Main stop: the machine socket closes while the long-lived
        // process is idle between turns. Nothing is in flight.
        await peer.socket.close()
        machine = nil
        phase("socket-closed")
        try await protocolPGEventually {
            try await fixture.audit().execution.connections[machineID]?.online == false
        }
        phase("disconnect-committed")
        let disconnected = try await fixture.audit()
        #expect(disconnected.execution.agents[agentID]?.needsManual == nil,
                "an idle live process is not an unsettled execution on disconnect")
        #expect(disconnected.execution.commands.values.allSatisfy { $0.kind != .delivery })

        // The deployed production row: connection_lost was persisted before
        // the fix while these same real facts were retained.
        try await fixture.runtime.execute {
            fixture.accounts.agentsRuntimeStore.withState {
                $0.execution.agents[agentID]?.needsManual = "connection_lost_with_unsettled_execution"
            }
        }
        let flagged = try await fixture.audit()
        #expect(flagged.execution.agents[agentID]?.needsManual == "connection_lost_with_unsettled_execution")
        phase("production-flag-seeded")

        // Main restarted and the Computer reconnects with the same daemon
        // instance, reporting its still-running process.
        let reconnected = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: daemonId, sequence: sequence)
        machine = reconnected
        try await reconnected.sendControlledReady(runningAgentIds: [agentID])
        phase("second-ready")
        let ready = try await fixture.audit()
        #expect(ready.execution.connections[machineID]?.ready == true)
        #expect(ready.execution.agents[agentID]?.needsManual == nil,
                "ready reconciles a connection-derived flag from the retained settled facts")

        // A normal v2 human send now reaches the running agent. Upstream sends
        // `agent:deliver` directly: a resident process that finished its turn is
        // still the running runtime, and a Main restart did not end it.
        let deliveryBoundary = reconnected.socket.count
        let post = try await fixture.http("POST", "/api/v2/messages", token: owner,
            body: .init(["channelId": .string(channelID), "content": .string("Deliver after restart recovery")]))
        #expect(post.status == 200)
        guard let messageObject = try post.object().object("message") else { throw ProtocolPGFailure.missingField }
        let messageID = try messageObject.requireString("id")
        phase("message-posted")
        let staged = try await fixture.audit()
        let stagedCommand = try #require(staged.execution.commands.values.first {
            $0.kind == .delivery && $0.agentId == agentID && $0.messageId == messageID
        })
        #expect(stagedCommand.launchId == launchID, "the resident process keeps carrying its launch")
        let delivery = try await reconnected.socket.nextObject(since: deliveryBoundary) {
            $0.string("type") == "agent:deliver" && $0.string("agentId") == agentID
                && $0.object("message")?.string("message_id") == messageID
        }
        phase("delivery-frame")
        try await reconnected.acknowledgeControlledDelivery(delivery)
        let restartWire = try await reconnected.socket.wireFence(since: deliveryBoundary)
        #expect(!restartWire.contains { $0.contains("\"agent:start\"") },
                "no cold start after a Main restart with the process still resident")
        try await protocolPGEventually {
            let commands = try await fixture.audit().execution.commands
            return commands.values.contains {
                $0.kind == .delivery && $0.agentId == agentID && $0.messageId == messageID && $0.status == .accepted
            }
        }
        let accepted = try await fixture.audit()
        let command = try #require(accepted.execution.commands.values.first {
            $0.kind == .delivery && $0.agentId == agentID && $0.messageId == messageID
        })
        #expect(accepted.execution.dispatches?[command.commandId.uuidString]?.phase == .accepted)
        #expect(accepted.messages.contains { $0.string("id") == messageID })
        phase("complete")
    } catch {
        await fixture.close(machine: machine)
        throw error
    }
    await fixture.close(machine: machine)
}

/// The regression the deployed `15219ef` release exposed: the Computer process
/// is stopped, a human DM is accepted while it is offline, and a new Computer
/// process starts with a new daemon instance and an empty `runningAgents`.
/// The previous instance's accepted delivery never got `turn_completed`, so the
/// retained in-flight set marked the agent on disconnect. RFC 071 §4.3 rule 4
/// and upstream `planWakeAction` make the new complete ready authoritative: the
/// old launch cannot be admitted, the message is not re-written, and the queued
/// DM starts the runtime on the retained session exactly once.
@Test(.enabled(if: restartRecoveryPGEnabled), .serialized)
func postgresComputerRestartWithoutRunningAgentDeliversTheQueuedDMOnce() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_RESTART_RECOVERY_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    func phase(_ value: String) { print("RESTART_RECOVERY_PG \(value)") }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    phase("fixture-started")
    var machine: ControlledMachineProtocolPeer?
    let firstDaemon = "restart-offline-daemon-\(UUID().uuidString.lowercased())"
    let secondDaemon = "restart-offline-daemon-\(UUID().uuidString.lowercased())"
    let sequence = ProtocolPGSequence()
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let attached = try await fixture.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("Computer restart fixture")]))
        guard attached.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let computer = try attached.object()
        let machineID = try computer.requireString("machineId")
        let key = try computer.requireString("apiKey")
        let config: JSONValue = .object(["version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")])])
        let created = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Computer restart recipient"), "machineId": .string(machineID),
                         "runtimeConfig": config]))
        guard created.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let agentID = try created.object().requireString("id")
        let dm = try await fixture.http("POST", "/api/channels/dm", token: owner,
            body: .init(["agentId": .string(agentID)]))
        guard dm.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let channelID = try dm.object().requireString("id")
        phase("http-setup-complete")

        let first = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: firstDaemon, sequence: sequence)
        machine = first
        try await first.sendControlledReady(runningAgentIds: [])
        let startBoundary = first.socket.count
        let wake = try await postHumanRestart(fixture, owner: owner, channel: channelID,
                                              content: "Wake the old Computer runtime")
        let start = try await first.socket.nextObject(since: startBoundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == agentID
        }
        let oldLaunch = try start.requireString("launchId")
        #expect(start.object("wakeMessage")?.string("message_id") == wake.messageId)
        try await first.acknowledgeControlledStart(start)
        try await first.sendProcessSpawned(agentId: agentID, launchId: oldLaunch, processInstanceId: "old-process")
        try await first.sendSession(agentId: agentID, launchId: oldLaunch, sessionId: "codex-session")
        try await first.sendTurnCompleted(agentId: agentID, launchId: oldLaunch, sessionId: "codex-session")
        try await protocolPGEventually {
            let state = try await fixture.audit().execution.agents[agentID]
            return state?.launches[oldLaunch]?.completed == true && state?.sessionId == "codex-session"
        }
        phase("old-runtime-idle")

        // The delivery the old Computer acknowledged but never completed. The
        // daemon routed it and dropped it as already consumed, so no turn ever
        // starts; the server retains it as the launch's in-flight evidence.
        let inFlightBoundary = first.socket.count
        let inFlight = try await postHumanRestart(fixture, owner: owner, channel: channelID,
                                                  content: "Acknowledged by the old Computer")
        let inFlightFrame = try await first.socket.nextObject(since: inFlightBoundary) {
            $0.string("type") == "agent:deliver" && $0.string("agentId") == agentID
                && $0.object("message")?.string("message_id") == inFlight.messageId
        }
        try await first.acknowledgeControlledDelivery(inFlightFrame)
        let inFlightAudit = try await fixture.audit()
        let inFlightCommand = try #require(inFlightAudit.execution.commands.values.first {
            $0.kind == .delivery && $0.agentId == agentID && $0.messageId == inFlight.messageId
        })
        try await protocolPGEventually {
            (try await fixture.audit()).execution.agents[agentID]?
                .launches[oldLaunch]?.inFlightDeliveryCommandIds?.contains(inFlightCommand.commandId) == true
        }
        phase("old-in-flight-delivery")

        // The Computer service stops. Nothing was in flight for a turn that can
        // still complete; the connection-derived flag is the production row.
        await first.socket.close()
        machine = nil
        try await protocolPGEventually {
            try await fixture.audit().execution.connections[machineID]?.online == false
        }
        let disconnected = try await fixture.audit()
        #expect(disconnected.execution.agents[agentID]?.needsManual == "connection_lost_with_unsettled_execution")
        phase("computer-stopped")

        // A human DM accepted while the Computer is offline. It must remain
        // readable and durably queued, never a fake delivery.
        let offline = try await postHumanRestart(fixture, owner: owner, channel: channelID,
                                                 content: "Sent while the Computer was offline")
        try await protocolPGEventually {
            (try await fixture.audit()).execution.pendingHumanDeliveries?.values.contains {
                $0.agentId == agentID && $0.messageId == offline.messageId
            } == true
        }
        phase("offline-message-queued")

        // A new Computer process with a new daemon instance and a complete
        // inventory that reports no running agents.
        let second = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: secondDaemon, sequence: sequence)
        machine = second
        let restartWire = second.socket.count
        try await second.sendControlledReady(runningAgentIds: [])
        let restartStart = try await second.socket.nextObject(since: restartWire) {
            $0.string("type") == "agent:start" && $0.string("agentId") == agentID
                && $0.object("wakeMessage")?.string("message_id") == offline.messageId
        }
        let newLaunch = try restartStart.requireString("launchId")
        #expect(newLaunch != oldLaunch)
        #expect(restartStart.object("config")?.string("sessionId") == "codex-session",
                "the restarted runtime resumes the retained session")
        let startWire = try await second.socket.wireFence(since: restartWire)
        #expect(!startWire.contains {
            $0.contains("\"agent:deliver\"") && $0.contains(offline.messageId)
        }, "the queued DM rides the start and is not also written as agent:deliver")
        phase("second-ready-start")

        try await second.acknowledgeControlledStart(restartStart)
        try await second.sendProcessSpawned(agentId: agentID, launchId: newLaunch, processInstanceId: "new-process")
        try await second.sendSession(agentId: agentID, launchId: newLaunch, sessionId: "codex-session")
        try await second.sendTurnCompleted(agentId: agentID, launchId: newLaunch, sessionId: "codex-session")
        try await protocolPGEventually {
            let execution = (try await fixture.audit()).execution
            let settled = execution.agents[agentID]?.needsManual == nil
            let noPending = !(execution.pendingHumanDeliveries ?? [:]).values.contains { $0.agentId == agentID }
            let completed = execution.agents[agentID]?.launches[newLaunch]?.completed == true
            return settled && noPending && completed
        }
        let after = try await fixture.audit()
        let retired = try #require(after.execution.agents[agentID]?.launches[oldLaunch])
        #expect(retired.retiredAfterDaemonRestart == true)
        #expect(retired.completed == true, "a retired launch is never rewritten as a failed or incomplete turn")
        #expect(after.execution.agents[agentID]?.processes["old-process"]?.exited == true)
        #expect(after.execution.commands[inFlightCommand.commandId.uuidString]?.status == .accepted,
                "the old accepted delivery is historical, not a second pending attempt")
        try await second.socket.applicationFence()
        let wire = try await second.socket.wireFence(since: restartWire)
        #expect(wire.filter { $0.contains("\"agent:start\"") && $0.contains(offline.messageId) }.count == 1,
                "the queued DM is started exactly once")
        #expect(!wire.contains { $0.contains("\"agent:deliver\"") && $0.contains(offline.messageId) },
                "the queued DM is never delivered twice")
        #expect(!wire.contains { $0.contains(inFlight.messageId) },
                "the old acknowledged delivery is historical and is never resent after retirement")
        phase("complete")
    } catch {
        await fixture.close(machine: machine)
        throw error
    }
    await fixture.close(machine: machine)
}

/// The deployed `restart-main` failure: Main restarted while an acknowledged
/// delivery's turn was still in flight. The same daemon reconnected with its
/// resident process, the post-restart human DM was durably queued behind the
/// restart fence, and the turn then completed. That completion is the retained
/// fact that settles the accepted delivery; the queued DM must be released
/// through the ordinary strict delivery path exactly once. The old in-flight
/// message stays historical and is never resent.
@Test(.enabled(if: restartRecoveryPGEnabled), .serialized)
func postgresTurnCompletionSettlesServerRestartFenceAndReleasesQueuedDM() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_RESTART_RECOVERY_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    func phase(_ value: String) { print("RESTART_RECOVERY_PG \(value)") }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    phase("fixture-started")
    var machine: ControlledMachineProtocolPeer?
    let daemonId = "restart-inflight-daemon-\(UUID().uuidString.lowercased())"
    let sequence = ProtocolPGSequence()
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let attached = try await fixture.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("In-flight restart fixture")]))
        guard attached.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let computer = try attached.object()
        let machineID = try computer.requireString("machineId")
        let key = try computer.requireString("apiKey")
        let config: JSONValue = .object(["version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")])])
        let created = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("In-flight restart recipient"), "machineId": .string(machineID),
                         "runtimeConfig": config]))
        guard created.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let agentID = try created.object().requireString("id")
        let dm = try await fixture.http("POST", "/api/channels/dm", token: owner,
            body: .init(["agentId": .string(agentID)]))
        guard dm.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let channelID = try dm.object().requireString("id")
        phase("http-setup-complete")

        let first = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: daemonId, sequence: sequence)
        machine = first
        try await first.sendControlledReady(runningAgentIds: [])
        let startBoundary = first.socket.count
        let wake = try await postHumanRestart(fixture, owner: owner, channel: channelID,
                                              content: "Wake the resident runtime")
        let start = try await first.socket.nextObject(since: startBoundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == agentID
        }
        let launch = try start.requireString("launchId")
        #expect(start.object("wakeMessage")?.string("message_id") == wake.messageId)
        try await first.acknowledgeControlledStart(start)
        try await first.sendProcessSpawned(agentId: agentID, launchId: launch, processInstanceId: "process-1")
        try await first.sendSession(agentId: agentID, launchId: launch, sessionId: "codex-session")
        try await first.sendTurnCompleted(agentId: agentID, launchId: launch, sessionId: "codex-session")
        try await protocolPGEventually {
            (try await fixture.audit()).execution.agents[agentID]?.launches[launch]?.completed == true
        }
        phase("resident-idle")

        // The delivery the daemon acknowledges but whose turn never completes
        // before Main stops. This is the accepted in-flight evidence.
        let inFlightBoundary = first.socket.count
        let inFlight = try await postHumanRestart(fixture, owner: owner, channel: channelID,
                                                  content: "Acknowledged in-flight turn")
        let inFlightFrame = try await first.socket.nextObject(since: inFlightBoundary) {
            $0.string("type") == "agent:deliver" && $0.string("agentId") == agentID
                && $0.object("message")?.string("message_id") == inFlight.messageId
        }
        try await first.acknowledgeControlledDelivery(inFlightFrame)
        let inFlightCommand = try #require(try await fixture.audit().execution.commands.values.first {
            $0.kind == .delivery && $0.agentId == agentID && $0.messageId == inFlight.messageId
        })
        try await protocolPGEventually {
            (try await fixture.audit()).execution.agents[agentID]?
                .launches[launch]?.inFlightDeliveryCommandIds?.contains(inFlightCommand.commandId) == true
        }
        phase("in-flight-turn")

        // Main stops. The production restore row is the server-restart fence for
        // the accepted delivery that has no observed completion yet.
        await first.socket.close()
        machine = nil
        try await protocolPGEventually {
            try await fixture.audit().execution.connections[machineID]?.online == false
        }
        try await fixture.runtime.execute {
            fixture.accounts.agentsRuntimeStore.withState {
                $0.execution.agents[agentID]?.needsManual = "server_restarted_with_unsettled_execution"
            }
        }
        phase("restore-fenced")

        // The post-restart DM is accepted while the Computer socket is gone.
        // It must stay readable and durably queued, never a fake delivery.
        let restart = try await postHumanRestart(fixture, owner: owner, channel: channelID,
                                                 content: "Post-restart DM")
        try await protocolPGEventually {
            (try await fixture.audit()).execution.pendingHumanDeliveries?.values.contains {
                $0.agentId == agentID && $0.messageId == restart.messageId
            } == true
        }
        phase("restart-dm-queued")

        // The same daemon (one instance id, one outcome sequence) reconnects and
        // reports its resident process. Ready cannot settle the acknowledged
        // turn, so the fence and the queued DM remain until the outcome arrives.
        let second = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: daemonId, sequence: sequence)
        machine = second
        try await second.sendControlledReady(runningAgentIds: [agentID])
        let ready = try await fixture.audit()
        #expect(ready.execution.connections[machineID]?.ready == true)
        #expect(ready.execution.agents[agentID]?.needsManual != nil)
        #expect(ready.execution.pendingHumanDeliveries?.values.contains {
            $0.agentId == agentID && $0.messageId == restart.messageId
        } == true)
        #expect(!ready.execution.commands.values.contains {
            $0.kind == .delivery && $0.agentId == agentID && $0.messageId == restart.messageId
        }, "ready cannot write the queued DM while the accepted turn is unresolved")
        phase("ready-kept-fence")

        // The in-flight turn completes. The accepted delivery was consumed, the
        // fence clears, and the queued DM is released as one ordinary delivery.
        let completionBoundary = second.socket.count
        try await second.sendTurnCompleted(agentId: agentID, launchId: launch, sessionId: "codex-session")
        let released = try await second.socket.nextObject(since: completionBoundary) {
            $0.string("type") == "agent:deliver" && $0.string("agentId") == agentID
                && $0.object("message")?.string("message_id") == restart.messageId
        }
        #expect(released.integer("seq") == Int64(restart.seq))
        try await second.acknowledgeControlledDelivery(released)
        try await protocolPGEventually {
            let execution = (try await fixture.audit()).execution
            return execution.agents[agentID]?.needsManual == nil
                && !(execution.pendingHumanDeliveries ?? [:]).values.contains {
                    $0.agentId == agentID && $0.messageId == restart.messageId
                }
        }
        let wire = try await second.socket.wireFence(since: completionBoundary)
        #expect(wire.filter { $0.contains("\"agent:deliver\"") && $0.contains(restart.messageId) }.count == 1,
                "the post-restart DM is delivered exactly once")
        #expect(!wire.contains { $0.contains(inFlight.messageId) },
                "the acknowledged pre-restart delivery is historical and is never resent")
        phase("complete")
    } catch {
        await fixture.close(machine: machine)
        throw error
    }
    await fixture.close(machine: machine)
}

private func postHumanRestart(_ fixture: AgentExecutionPostgresFixture, owner: String, channel: String,
                              content: String) async throws -> (messageId: String, seq: Int) {
    let posted = try await fixture.http("POST", "/api/v2/messages", token: owner,
        body: .init(["channelId": .string(channel), "content": .string(content)]))
    guard posted.status == 200, let message = try posted.object().object("message") else {
        throw ProtocolPGFailure.invalidResponse
    }
    let messageId = try message.requireString("id")
    let audit = try await fixture.audit()
    guard let row = audit.messages.first(where: { $0.string("id") == messageId }),
          let seq = row.integer("seq") else { throw ProtocolPGFailure.missingField }
    return (messageId, Int(seq))
}
