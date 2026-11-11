import Foundation
import RaftPersistence
import RaftShared
import Testing
@testable import RaftHTTP

private let queuedRestartPGEnabled =
    ProcessInfo.processInfo.environment["RAFT_QUEUED_RESTART_PG_ACCEPTANCE"] == "1"

/// D7 published-path acceptance on a real PostgreSQL writer and a real
/// authenticated machine socket:
///
/// - a keep-session restart of an agent whose launch is still starting carries
///   the oldest queued human message inside `agent:start` (`wakeMessage`) and
///   never emits a separate `agent:deliver` for it;
/// - a session reset with several queued messages delivers each of them exactly
///   once across every release trigger (start ACK, process report, session,
///   repeated ready), never a second identical frame;
/// - neither flow leaves `needsManual` behind.
@Test(.enabled(if: queuedRestartPGEnabled), .serialized)
func postgresQueuedRestartDeliversEachMessageExactlyOnce() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_QUEUED_RESTART_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    func phase(_ value: String) { print("QUEUED_RESTART_PG \(value)") }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    phase("fixture-started")
    var machine: ControlledMachineProtocolPeer?
    let sequence = ProtocolPGSequence()
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let attached = try await fixture.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("Queued restart fixture")]))
        guard attached.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let computer = try attached.object()
        let machineId = try computer.requireString("machineId")
        let key = try computer.requireString("apiKey")
        let config: JSONValue = .object([
            "version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")]),
        ])
        func createAgent(_ name: String) async throws -> (agent: String, channel: String) {
            let created = try await fixture.http("POST", "/api/agents", token: owner,
                body: .init(["name": .string(name), "machineId": .string(machineId), "runtimeConfig": config]))
            guard created.status == 200 else { throw ProtocolPGFailure.invalidResponse }
            let agentId = try created.object().requireString("id")
            let dm = try await fixture.http("POST", "/api/channels/dm", token: owner,
                body: .init(["agentId": .string(agentId)]))
            guard dm.status == 200 else { throw ProtocolPGFailure.invalidResponse }
            return (agentId, try dm.object().requireString("id"))
        }
        let restartAgent = try await createAgent("Restart keep session")
        let resetAgent = try await createAgent("Reset session")
        phase("http-setup-complete")

        let peer = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key,
            daemonId: "queued-restart-daemon-\(UUID().uuidString.lowercased())", sequence: sequence)
        machine = peer
        try await peer.sendControlledReady(runningAgentIds: [])
        phase("ready")

        // MARK: - Keep-session restart
        //
        // The first message starts the runtime and is carried as its wake. The
        // next messages arrive while that launch is starting: the daemon buffers
        // such frames during the start and does not acknowledge them, so the
        // server queues them instead of writing into the start window.
        let boundary = peer.socket.count
        let firstWake = try await postHuman(fixture, owner: owner, channel: restartAgent.channel,
                                            content: "Wake for the restart agent")
        let firstStart = try await peer.socket.nextObject(since: boundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == restartAgent.agent
        }
        #expect(firstStart.object("wakeMessage")?.string("message_id") == firstWake.messageId)
        try await peer.acknowledgeControlledStart(firstStart)
        let queuedOne = try await postHuman(fixture, owner: owner, channel: restartAgent.channel,
                                            content: "Queued before keep-session restart")
        let queuedTwo = try await postHuman(fixture, owner: owner, channel: restartAgent.channel,
                                            content: "Also queued before keep-session restart")
        try await protocolPGEventually {
            ((try await fixture.audit()).execution.pendingHumanDeliveries ?? [:]).values.contains {
                $0.agentId == restartAgent.agent && $0.messageId == queuedTwo.messageId
            }
        }
        phase("restart-messages-queued")

        let restartWire = peer.socket.count
        let restart = try await fixture.http("POST", "/api/agents/\(restartAgent.agent)/reset", token: owner,
            body: .init(["mode": .string("restart")]))
        #expect(restart.status == 202)
        _ = try await peer.socket.nextObject(since: restartWire) {
            $0.string("type") == "agent:stop" && $0.string("agentId") == restartAgent.agent
        }
        let restartStart = try await peer.socket.nextObject(since: restartWire) {
            $0.string("type") == "agent:start" && $0.string("agentId") == restartAgent.agent
        }
        #expect(restartStart.object("wakeMessage")?.string("message_id") == queuedOne.messageId,
                "the oldest queued message rides the restart start")
        #expect(restartStart.object("wakeMessage")?.string("channel_id") == restartAgent.channel)
        try await peer.acknowledgeControlledStart(restartStart)
        try await protocolPGEventually {
            let state = (try await fixture.audit()).execution
            return !(state.pendingHumanDeliveries ?? [:]).values.contains {
                $0.agentId == restartAgent.agent && $0.messageId == queuedOne.messageId
            }
        }
        phase("restart-wake-settled")

        // The remaining message is released exactly once once the launch names
        // its process; a session and a repeated ready must not send it again.
        try await peer.sendProcessSpawned(agentId: restartAgent.agent,
                                          launchId: try restartStart.requireString("launchId"),
                                          processInstanceId: "restart-process")
        let restartDelivery = try await peer.socket.nextObject(since: restartWire) {
            $0.string("type") == "agent:deliver" && $0.string("agentId") == restartAgent.agent
                && $0.object("message")?.string("message_id") == queuedTwo.messageId
        }
        #expect(restartDelivery.integer("seq") == Int64(queuedTwo.seq))
        try await peer.acknowledgeControlledDelivery(restartDelivery)
        try await peer.sendSession(agentId: restartAgent.agent,
                                   launchId: try restartStart.requireString("launchId"),
                                   sessionId: "restart-session")
        try await peer.sendControlledReady(runningAgentIds: [restartAgent.agent])
        try await peer.socket.applicationFence()
        let restartWireAfter = try await peer.socket.wireFence(since: restartWire)
        #expect(restartWireAfter.filter {
            $0.contains("\"agent:deliver\"") && $0.contains(queuedTwo.messageId)
        }.count == 1, "the queued message is delivered exactly once")
        #expect(!restartWireAfter.contains {
            $0.contains("\"agent:deliver\"") && $0.contains(firstWake.messageId)
        }, "a wake message is never also sent as agent:deliver")
        try await protocolPGEventually {
            let state = (try await fixture.audit()).execution
            let noPending = !(state.pendingHumanDeliveries ?? [:]).values.contains { $0.agentId == restartAgent.agent }
            let settled = state.agents[restartAgent.agent]?.needsManual == nil
            return noPending && settled
        }
        phase("restart-exactly-once")

        // MARK: - Session reset with several queued messages
        let sessionBoundary = peer.socket.count
        let sessionWake = try await postHuman(fixture, owner: owner, channel: resetAgent.channel,
                                              content: "Wake for the session-reset agent")
        let sessionStart = try await peer.socket.nextObject(since: sessionBoundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == resetAgent.agent
        }
        #expect(sessionStart.object("wakeMessage")?.string("message_id") == sessionWake.messageId)
        try await peer.acknowledgeControlledStart(sessionStart)
        let sessionQueued = [
            try await postHuman(fixture, owner: owner, channel: resetAgent.channel,
                                content: "Queued one before session reset"),
            try await postHuman(fixture, owner: owner, channel: resetAgent.channel,
                                content: "Queued two before session reset"),
            try await postHuman(fixture, owner: owner, channel: resetAgent.channel,
                                content: "Queued three before session reset"),
        ]
        try await protocolPGEventually {
            let pending = ((try await fixture.audit()).execution.pendingHumanDeliveries ?? [:]).values
            return sessionQueued.allSatisfy { message in
                pending.contains { $0.agentId == resetAgent.agent && $0.messageId == message.messageId }
            }
        }
        phase("session-messages-queued")

        let resetWire = peer.socket.count
        let sessionReset = try await fixture.http("POST", "/api/agents/\(resetAgent.agent)/reset", token: owner,
            body: .init(["mode": .string("session")]))
        #expect(sessionReset.status == 202)
        _ = try await peer.socket.nextObject(since: resetWire) {
            $0.string("type") == "agent:stop" && $0.string("agentId") == resetAgent.agent
        }
        let resetStart = try await peer.socket.nextObject(since: resetWire) {
            $0.string("type") == "agent:start" && $0.string("agentId") == resetAgent.agent
        }
        #expect(resetStart.object("wakeMessage")?.string("message_id") == sessionQueued[0].messageId,
                "the oldest queued message rides the reset start")
        #expect(resetStart.bool("humanStart") == true)
        try await peer.acknowledgeControlledStart(resetStart)

        // No delivery may be written into the start window; the process report
        // is the signal the port releases on.
        try await peer.socket.applicationFence()
        let startWindow = try await peer.socket.wireFence(since: resetWire)
        #expect(!startWindow.contains { $0.contains("\"agent:deliver\"") && $0.contains(sessionQueued[1].messageId) })

        try await peer.sendProcessSpawned(agentId: resetAgent.agent,
                                          launchId: try resetStart.requireString("launchId"),
                                          processInstanceId: "reset-process")
        for message in sessionQueued.dropFirst() {
            let delivery = try await peer.socket.nextObject(since: resetWire) {
                $0.string("type") == "agent:deliver" && $0.string("agentId") == resetAgent.agent
                    && $0.object("message")?.string("message_id") == message.messageId
            }
            #expect(delivery.integer("seq") == Int64(message.seq))
            try await peer.acknowledgeControlledDelivery(delivery)
        }
        // Late triggers: the session frame and repeated ready must not emit a
        // second frame for any of the queued messages.
        try await peer.sendSession(agentId: resetAgent.agent,
                                   launchId: try resetStart.requireString("launchId"),
                                   sessionId: "reset-session")
        for _ in 0..<2 { try await peer.sendControlledReady(runningAgentIds: [resetAgent.agent, restartAgent.agent]) }
        try await peer.socket.applicationFence()
        let resetWireAfter = try await peer.socket.wireFence(since: resetWire)
        for message in sessionQueued.dropFirst() {
            #expect(resetWireAfter.filter {
                $0.contains("\"agent:deliver\"") && $0.contains(message.messageId)
            }.count == 1, "each queued message is delivered exactly once after the reset")
        }
        #expect(!resetWireAfter.contains {
            $0.contains("\"agent:deliver\"") && $0.contains(sessionQueued[0].messageId)
        }, "the carried wake is not also sent as agent:deliver")
        try await protocolPGEventually {
            let state = (try await fixture.audit()).execution
            return !(state.pendingHumanDeliveries ?? [:]).values.contains { $0.agentId == resetAgent.agent }
                && state.agents[resetAgent.agent]?.needsManual == nil
                && state.agents[restartAgent.agent]?.needsManual == nil
        }
        phase("session-exactly-once")
        phase("complete")
    } catch {
        await fixture.close(machine: machine)
        throw error
    }
    await fixture.close(machine: machine)
}

/// One human DM through the published v2 route. The message `seq` participates
/// in the delivery envelope, so it is read back from the canonical row.
private func postHuman(_ fixture: AgentExecutionPostgresFixture, owner: String, channel: String,
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
