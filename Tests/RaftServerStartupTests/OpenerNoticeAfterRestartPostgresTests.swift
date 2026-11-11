import Foundation
import RaftPersistence
import RaftShared
import Testing
@testable import RaftHTTP

private let openerNoticePGEnabled =
    ProcessInfo.processInfo.environment["RAFT_OPENER_NOTICE_PG_ACCEPTANCE"] == "1"

/// Real HTTP, PostgreSQL and authenticated machine socket for the production
/// defect: Main restarts while the official Computer keeps its resident agent
/// process, and the owner briefing trigger then posts the visible opener but
/// never delivers the transient ledger notice or stamps the sent fact.
///
/// The retained production shape is reproduced from real facts: a completed
/// turn whose process stays resident, followed by a start staged on that
/// connection whose dispatch never happened (the production outbox row was
/// rejected after the restart). The same daemon reconnects with `runningAgents`
/// naming the agent, Main is restored from the durable documents, and the ready
/// trigger must deliver the ledger notice on the launch the process carries.
///
/// A controlled peer supplies the daemon frames; this is not proof of an
/// official Computer, a Codex process or a model turn. Run this filter in its
/// own process with its own disposable database.
@Test(.enabled(if: openerNoticePGEnabled), .serialized)
func postgresOwnerOpenerLedgerNoticeReachesAResidentAgentAfterMainRestart() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_OPENER_NOTICE_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    func phase(_ value: String) { print("OPENER_NOTICE_PG \(value)") }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    phase("fixture-started")
    var machine: ControlledMachineProtocolPeer?
    let daemonId = "opener-notice-daemon-\(UUID().uuidString.lowercased())"
    let sequence = ProtocolPGSequence()
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let attached = try await fixture.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("Opener notice fixture")]))
        guard attached.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let computer = try attached.object()
        let machineID = try computer.requireString("machineId")
        let key = try computer.requireString("apiKey")
        let config: JSONValue = .object(["version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")])])

        // The first ready happens before an onboarding agent exists, so the
        // trigger claims nothing and the visible opener is not posted early.
        let peer = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: daemonId, sequence: sequence)
        machine = peer
        try await peer.sendControlledReady(runningAgentIds: [])
        phase("first-ready-without-onboarding-agent")

        // The owner answers the signup survey, then creates the official
        // onboarding agent through the published route on this Computer.
        let survey = try await fixture.http("PATCH", "/api/auth/me", token: owner,
            body: .init(["signupRole": .string("founder")]))
        guard survey.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let createdBoundary = peer.socket.count
        let created = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Cindy"), "onboarding": .bool(true),
                         "machineId": .string(machineID), "runtimeConfig": config]))
        guard created.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let agentID = try created.object().requireString("id")

        // One cold start serves the resident runtime; the daemon rebinds the
        // start onto its registered process, then completes a turn.
        let start = try await peer.socket.nextObject(since: createdBoundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == agentID
        }
        let launchID = try start.requireString("launchId")
        try await peer.acknowledgeControlledRebind(start, processInstanceId: "process-1")
        try await peer.sendRebound(agentId: agentID, launchId: launchID, processInstanceId: "process-1")
        try await peer.sendTurnCompleted(agentId: agentID, launchId: launchID, sessionId: "codex-session")
        try await protocolPGEventually {
            let state = try await fixture.audit().execution.agents[agentID]
            return state?.launches[launchID]?.completed == true
                && state?.launches[launchID]?.processInstanceId == "process-1"
                && state?.processes["process-1"]?.exited == false
        }
        phase("resident-turn-completed")

        // The deployed production shape: a later automatic start was staged on
        // the old connection and its dispatch never happened (the production
        // outbox row stayed pending, then was rejected). It is current but the
        // daemon never admitted it; the resident process carries the completed
        // launch above.
        let staleLaunchID = UUID().uuidString.lowercased()
        let staleDispatchID = UUID().uuidString.lowercased()
        let staleCommandID = UUID()
        try await fixture.runtime.execute {
            fixture.accounts.agentsRuntimeStore.withState { state in
                guard var agent = state.execution.agents[agentID],
                      let connection = state.execution.connections[machineID] else { return }
                agent.generation += 1
                agent.currentLaunchId = staleLaunchID
                agent.launches[staleLaunchID] = AgentExecutionLaunch(
                    launchId: staleLaunchID, startDispatchId: staleDispatchID,
                    daemonInstanceId: daemonId, connectionEpochId: connection.connectionEpochId,
                    generation: agent.generation, takeoverEpoch: agent.takeoverEpoch)
                state.execution.agents[agentID] = agent
                state.execution.commands[staleCommandID.uuidString] = AgentExecutionCommand(
                    commandId: staleCommandID, kind: .start, serverId: fixture.serverId,
                    machineId: machineID, agentId: agentID, launchId: staleLaunchID,
                    startDispatchId: staleDispatchID, deliveryId: nil,
                    connectionEpochId: connection.connectionEpochId,
                    takeoverEpoch: agent.takeoverEpoch, breakerGeneration: agent.generation,
                    humanStart: false, sessionId: agent.sessionId, resumePrompt: nil,
                    channelId: nil, messageId: nil, notice: nil, status: .pending, createdAt: Date())
            }
        }
        let staged = try await fixture.audit()
        #expect(staged.execution.agents[agentID]?.currentLaunchId == staleLaunchID)
        #expect(staged.execution.dispatches?[staleCommandID.uuidString] == nil)
        phase("stale-start-staged")

        // Main stops: the socket closes, the resident process lives on. The
        // never-admitted current launch is what makes the agent unsettled.
        await peer.socket.close()
        machine = nil
        try await protocolPGEventually {
            try await fixture.audit().execution.connections[machineID]?.online == false
        }
        let disconnected = try await fixture.audit()
        #expect(disconnected.execution.agents[agentID]?.needsManual == "connection_lost_with_unsettled_execution")
        phase("main-stopped")

        // Main restores the same durable documents. Restore fences every
        // connection and every genuinely unsettled launch.
        try await fixture.runtime.execute {
            let data = try fixture.accounts.agentsRuntimeStore.exportPersistenceData()
            try fixture.accounts.agentsRuntimeStore.restorePersistenceData(data)
        }
        let restored = try await fixture.audit()
        #expect(restored.execution.connections[machineID]?.online == false)
        #expect(restored.execution.agents[agentID]?.needsManual == "server_restarted_with_unsettled_execution")
        phase("main-restored")

        // The same daemon instance reconnects and reports the process running.
        let reconnected = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: daemonId, sequence: sequence)
        machine = reconnected
        let readyBoundary = reconnected.socket.count
        try await reconnected.sendControlledReady(runningAgentIds: [agentID])
        try await protocolPGEventually {
            try await fixture.audit().execution.connections[machineID]?.ready == true
        }
        phase("second-ready-with-resident-process")

        // The ready-reported process is the daemon-admitted runtime. The launch
        // it carries must become current again, the unsent start must be
        // retired, and the transient notice must be admissible.
        let atReady = try await fixture.audit()
        #expect(atReady.execution.agents[agentID]?.needsManual == nil,
                "ready must clear the connection-loss fence from the resident process")
        try await protocolPGEventually {
            try await fixture.audit().execution.agents[agentID]?.needsManual == nil
        }
        let recovered = try await fixture.audit()
        let agent = try #require(recovered.execution.agents[agentID])
        #expect(agent.currentLaunchId == launchID,
                "the launch the resident process carries becomes current again")
        #expect(agent.launches[staleLaunchID]?.notSpawned == true,
                "the start that never reached the daemon is retired, not a live launch")
        #expect(recovered.execution.commands[staleCommandID.uuidString]?.status == .superseded)
        phase("resident-launch-adopted")

        let ledgerMessageID = "opener-v2-ledger-\(fixture.serverId)"
        var cursor = readyBoundary
        var ledgerSeen = false
        while !ledgerSeen {
            let delivery = try await reconnected.socket.nextObject(since: cursor) {
                $0.string("type") == "agent:deliver" && $0.string("agentId") == agentID
            }
            let messageID = try #require(delivery.object("message")?.string("message_id"))
            #expect(delivery.integer("seq") == 0, "a transient notice is acknowledged at seq 0")
            try await reconnected.acknowledgeControlledDelivery(delivery)
            if messageID == ledgerMessageID { ledgerSeen = true }
            cursor = reconnected.socket.count
        }
        phase("ledger-notice-delivered")

        try await protocolPGEventually {
            let commands = try await fixture.audit().execution.commands
            return commands.values.contains {
                $0.kind == .notice && $0.agentId == agentID && $0.messageId == ledgerMessageID
                    && $0.status == .accepted
            }
        }
        let ledgerKey = "\(fixture.serverId)\n\(fixture.ownerId)"
        try await protocolPGEventually {
            let business = try await fixture.serversAndChannels().object("business")
            guard let ledger = business?.object("ownerOpenerLedgers")?.object(ledgerKey) else { return false }
            return ledger.fields["openerV2SentAt"] != nil
                && (ledger.array("openerV2MessageIds") ?? []).count == 4
        }
        let ledgerDocument = try await fixture.serversAndChannels()
        let business = try #require(ledgerDocument.object("business"))
        let ledger = try #require(business.object("ownerOpenerLedgers")?.object(ledgerKey))
        #expect((ledger.array("openerV2Topics") ?? []).count == 4)
        let final = try await fixture.audit()
        let notices = final.execution.commands.values.filter {
            $0.kind == .notice && $0.agentId == agentID && $0.status == .accepted
        }
        #expect(notices.contains { $0.messageId == ledgerMessageID })
        #expect(notices.contains { $0.messageId == "onboarding-owner-facts-\(fixture.serverId)" },
                "the owner-facts context re-established on the same ready is accepted too")
        phase("ledger-stamped")
        phase("complete")
    } catch {
        await fixture.close(machine: machine)
        throw error
    }
    await fixture.close(machine: machine)
}
