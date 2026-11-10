import Foundation
import RaftPersistence
import RaftShared
import Testing
@testable import RaftHTTP

private let residentDeliveryPGEnabled =
    ProcessInfo.processInfo.environment["RAFT_RESIDENT_DELIVERY_PG_ACCEPTANCE"] == "1"

/// Real HTTP, PostgreSQL and authenticated machine sockets for the production
/// defect: after a turn completes the official Computer keeps its `codex
/// app-server` process resident, so every later human message must be delivered
/// to that process without a cold start. A controlled peer supplies the daemon
/// frames; this is not proof of an official Computer, Codex process or model
/// turn. Run this filter in its own process with its own disposable database.
@Test(.enabled(if: residentDeliveryPGEnabled), .serialized)
func postgresResidentAgentReceivesEveryLaterHumanMessageWithoutAColdStart() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_RESIDENT_DELIVERY_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    func phase(_ value: String) { print("RESIDENT_DELIVERY_PG \(value)") }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    phase("fixture-started")
    var machine: ControlledMachineProtocolPeer?
    let daemonId = "resident-delivery-daemon-\(UUID().uuidString.lowercased())"
    let sequence = ProtocolPGSequence()
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let attached = try await fixture.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("Resident delivery fixture")]))
        guard attached.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let computer = try attached.object()
        let machineID = try computer.requireString("machineId")
        let key = try computer.requireString("apiKey")
        let config: JSONValue = .object(["version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")])])
        let created = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Cindy"), "machineId": .string(machineID),
                         "runtimeConfig": config]))
        guard created.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let agentID = try created.object().requireString("id")
        let dm = try await fixture.http("POST", "/api/channels/dm", token: owner,
            body: .init(["agentId": .string(agentID)]))
        guard dm.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let dmID = try dm.object().requireString("id")
        let room = try await fixture.http("POST", "/api/channels", token: owner,
            body: .init(["name": .string("resident-delivery-room")]))
        guard room.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let roomID = try room.object().requireString("id")
        let join = try await fixture.http("POST", "/api/channels/\(roomID)/members", token: owner,
            body: .init(["agentId": .string(agentID)]))
        #expect(join.status == 200)
        phase("http-setup-complete")

        let peer = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: daemonId, sequence: sequence)
        machine = peer
        try await peer.sendControlledReady(runningAgentIds: [])
        phase("first-ready")

        /// Post a v2 human message and return its id.
        func post(_ channel: String, _ content: String, mentions: [JSONValue] = []) async throws -> String {
            var fields: [String: JSONValue] = [
                "channelId": .string(channel), "content": .string(content),
            ]
            if !mentions.isEmpty { fields["mentions"] = .array(mentions) }
            let response = try await fixture.http("POST", "/api/v2/messages", token: owner, body: .init(fields))
            guard response.status == 200, let message = try response.object().object("message") else {
                throw ProtocolPGFailure.invalidResponse
            }
            return try message.requireString("id")
        }
        func deliver(_ peer: ControlledMachineProtocolPeer, since boundary: Int, messageID: String) async throws -> Int {
            let delivery = try await peer.socket.nextObject(since: boundary) {
                $0.string("type") == "agent:deliver" && $0.string("agentId") == agentID
                    && $0.object("message")?.string("message_id") == messageID
            }
            try await peer.acknowledgeControlledDelivery(delivery)
            return peer.socket.count
        }

        // DM 1: the first wake starts the runtime. The official daemon rebinds
        // its start onto the process it registered and names that identity in
        // the start ack and the rebound outcome.
        let firstBoundary = peer.socket.count
        let firstMessage = try await post(dmID, "First DM after enrollment")
        let start = try await peer.socket.nextObject(since: firstBoundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == agentID
        }
        let launchID = try start.requireString("launchId")
        try await peer.acknowledgeControlledRebind(start, processInstanceId: "process-1", queueState: "running")
        try await peer.sendRebound(agentId: agentID, launchId: launchID, processInstanceId: "process-1")
        _ = try await deliver(peer, since: firstBoundary, messageID: firstMessage)
        try await peer.sendTurnCompleted(agentId: agentID, launchId: launchID, sessionId: "codex-session")
        try await protocolPGEventually {
            let state = try await fixture.audit().execution.agents[agentID]
            return state?.launches[launchID]?.completed == true
                && state?.launches[launchID]?.processInstanceId == "process-1"
                && state?.processes["process-1"]?.exited == false
        }
        phase("first-turn-completed")

        // DM 2: the resident process is idle. Upstream sends `agent:deliver`
        // with no new start (the wedge sent a start that was refused, or a start
        // the daemon rebound, and then delivered nothing later).
        let secondBoundary = peer.socket.count
        let secondMessage = try await post(dmID, "Second DM after the first turn")
        _ = try await deliver(peer, since: secondBoundary, messageID: secondMessage)
        let secondWire = try await peer.socket.wireFence(since: secondBoundary)
        #expect(!secondWire.contains { $0.contains("\"agent:start\"") }, "an idle resident runtime is not started again")
        phase("second-dm-delivered-without-start")

        // Channel @mention: the same producer path for a formal mention.
        let mentionBoundary = peer.socket.count
        let mentionMessage = try await post(roomID, "@Cindy third check with a structured mention",
            mentions: [.object(["type": .string("agent"), "id": .string(agentID), "name": .string("Cindy")])])
        _ = try await deliver(peer, since: mentionBoundary, messageID: mentionMessage)
        let mentionWire = try await peer.socket.wireFence(since: mentionBoundary)
        #expect(!mentionWire.contains { $0.contains("\"agent:start\"") })
        let deliveries = try await fixture.http("GET", "/api/messages/\(mentionMessage)/mention-deliveries", token: owner)
        #expect(deliveries.status == 200)
        let mentionRows = try deliveries.object().array("deliveries") ?? []
        let firstRow = try #require(mentionRows.first)
        guard case .object(let rowFields) = firstRow else { throw ProtocolPGFailure.missingField }
        #expect(ProtocolPGObject(rowFields).string("outcome") == "delivered")
        phase("mention-delivered")

        // A message while the turn is in flight: the daemon accepts and queues
        // it; the server still sends the delivery and writes exactly one
        // command. No turn completion has been observed for the last two
        // deliveries.
        let busyBoundary = peer.socket.count
        let busyMessage = try await post(dmID, "Sent while the previous turn is still running")
        _ = try await deliver(peer, since: busyBoundary, messageID: busyMessage)
        let busyWire = try await peer.socket.wireFence(since: busyBoundary)
        #expect(!busyWire.contains { $0.contains("\"agent:start\"") })
        try await peer.sendTurnCompleted(agentId: agentID, launchId: launchID, sessionId: "codex-session")
        try await protocolPGEventually {
            let inFlight = try await fixture.audit().execution.agents[agentID]?
                .launches[launchID]?.inFlightDeliveryCommandIds ?? []
            return inFlight.isEmpty
        }
        phase("busy-delivery-accepted")

        // Main restart while the process stays resident: the durable state has
        // one completed turn, one live process and no unsettled delivery.
        await peer.socket.close()
        machine = nil
        try await protocolPGEventually {
            try await fixture.audit().execution.connections[machineID]?.online == false
        }
        let stopped = try await fixture.audit()
        #expect(stopped.execution.agents[agentID]?.needsManual == nil,
                "an idle resident process is not unsettled when Main stops")
        #expect(stopped.execution.pendingHumanDeliveries?.isEmpty ?? true)
        phase("main-stopped")

        let reconnected = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: daemonId, sequence: sequence)
        machine = reconnected
        try await reconnected.sendControlledReady(runningAgentIds: [agentID])
        phase("reconnected-with-resident-process")
        let restartBoundary = reconnected.socket.count
        let restartMessage = try await post(dmID, "Delivered after the Main restart")
        _ = try await deliver(reconnected, since: restartBoundary, messageID: restartMessage)
        let restartWire = try await reconnected.socket.wireFence(since: restartBoundary)
        #expect(!restartWire.contains { $0.contains("\"agent:start\"") })
        try await reconnected.sendTurnCompleted(agentId: agentID, launchId: launchID, sessionId: "codex-session")

        try await protocolPGEventually {
            let audit = try await fixture.audit()
            let accepted = audit.execution.commands.values.filter {
                $0.kind == .delivery && $0.agentId == agentID && $0.status == .accepted
            }
            return accepted.count == 5 && (audit.execution.pendingHumanDeliveries ?? [:]).isEmpty
        }
        let final = try await fixture.audit()
        let starts = final.execution.commands.values.filter { $0.kind == .start && $0.agentId == agentID }
        #expect(starts.count == 1, "one cold start serves all later messages")
        #expect(final.execution.agents[agentID]?.launches.count == 1,
                "the resident process keeps carrying its one launch")
        #expect(final.execution.agents[agentID]?.needsManual == nil)
        #expect(final.execution.agents[agentID]?.launches[launchID]?.inFlightDeliveryCommandIds?.isEmpty ?? true)
        let messageRows = final.messages.compactMap { $0.string("id") }
        for id in [firstMessage, secondMessage, mentionMessage, busyMessage, restartMessage] {
            #expect(messageRows.contains(id), "every delivered message stays in the durable inbox/read history")
        }

        // ---- Durable wake queue: a start admitted without its process identity.
        // A second agent on the same machine admits a start the daemon never
        // attributes to a process; its human message is durably queued and the
        // identity that settles later releases it exactly once.
        let queuedCreated = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Queued Cindy"), "machineId": .string(machineID),
                         "runtimeConfig": config]))
        guard queuedCreated.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let queuedAgent = try queuedCreated.object().requireString("id")
        let queuedDM = try await fixture.http("POST", "/api/channels/dm", token: owner,
            body: .init(["agentId": .string(queuedAgent)]))
        guard queuedDM.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let queuedDMID = try queuedDM.object().requireString("id")
        let queuedStartBoundary = reconnected.socket.count
        let queuedStarted = try await fixture.http("POST", "/api/agents/\(queuedAgent)/start", token: owner)
        #expect(queuedStarted.status == 200)
        let queuedStart = try await reconnected.socket.nextObject(since: queuedStartBoundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == queuedAgent
        }
        let queuedLaunch = try queuedStart.requireString("launchId")
        try await reconnected.acknowledgeControlledStart(queuedStart)
        try await reconnected.sendTurnCompleted(agentId: queuedAgent, launchId: queuedLaunch, sessionId: "codex-session-2")
        try await protocolPGEventually {
            try await fixture.audit().execution.agents[queuedAgent]?.launches[queuedLaunch]?.completed == true
        }
        phase("queued-agent-start-admitted-without-identity")

        let queuedBoundary = reconnected.socket.count
        let queuedResponse = try await fixture.http("POST", "/api/v2/messages", token: owner,
            body: .init(["channelId": .string(queuedDMID),
                         "content": .string("Queued until the process identity settles")]))
        #expect(queuedResponse.status == 200)
        guard let queuedMessageObject = try queuedResponse.object().object("message") else {
            throw ProtocolPGFailure.missingField
        }
        let queuedMessageID = try queuedMessageObject.requireString("id")
        let queuedAudit = try await fixture.audit()
        let pendingEntry = try #require(queuedAudit.execution.pendingHumanDeliveries?.values.first {
            $0.agentId == queuedAgent && $0.messageId == queuedMessageID
        })
        #expect(pendingEntry.releasedCommandId == nil)
        let quietWire = try await reconnected.socket.wireFence(since: queuedBoundary)
        #expect(!quietWire.contains { $0.contains("\"agent:deliver\"") },
                "no delivery is attempted while the wake is refused")
        phase("human-message-queued")

        // The daemon names the process. The committed admission releases the
        // queued delivery through the ordinary strict path, without a start.
        try await reconnected.sendProcessSpawned(agentId: queuedAgent, launchId: queuedLaunch,
                                                 processInstanceId: "process-queued")
        let queuedDelivery = try await reconnected.socket.nextObject(since: queuedBoundary) {
            $0.string("type") == "agent:deliver" && $0.string("agentId") == queuedAgent
                && $0.object("message")?.string("message_id") == queuedMessageID
        }
        try await reconnected.acknowledgeControlledDelivery(queuedDelivery)
        let releasedWire = try await reconnected.socket.wireFence(since: queuedBoundary)
        #expect(!releasedWire.contains { $0.contains("\"agent:start\"") })
        try await protocolPGEventually {
            let audit = try await fixture.audit()
            return (audit.execution.pendingHumanDeliveries ?? [:]).isEmpty
                && audit.execution.commands.values.contains {
                    $0.kind == .delivery && $0.agentId == queuedAgent
                        && $0.messageId == queuedMessageID && $0.status == .accepted
                }
        }
        let queuedFinal = try await fixture.audit()
        let queuedDeliveryCommand = try #require(queuedFinal.execution.commands.values.first {
            $0.kind == .delivery && $0.agentId == queuedAgent && $0.messageId == queuedMessageID
        })
        #expect(queuedDeliveryCommand.launchId == queuedLaunch,
                "the settled identity releases the queue on the admitted launch")
        #expect(queuedFinal.execution.commands.values.filter {
            $0.kind == .delivery && $0.agentId == queuedAgent && $0.messageId == queuedMessageID
        }.count == 1)
        #expect(queuedFinal.messages.contains { $0.string("id") == queuedMessageID })
        phase("queued-wake-released-once")
        phase("complete")
    } catch {
        await fixture.close(machine: machine)
        throw error
    }
    await fixture.close(machine: machine)
}
