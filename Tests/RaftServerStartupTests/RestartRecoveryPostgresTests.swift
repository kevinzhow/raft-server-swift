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
