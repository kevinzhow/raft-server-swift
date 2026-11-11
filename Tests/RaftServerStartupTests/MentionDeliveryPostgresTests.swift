import Foundation
import RaftPersistence
import RaftShared
import Testing
@testable import RaftHTTP

private let mentionDeliveryPGEnabled =
    ProcessInfo.processInfo.environment["RAFT_MENTION_DELIVERY_PG_ACCEPTANCE"] == "1"

/// Complete published path for a formal mention whose target is offline when
/// the message is accepted, plus the `agent:start` resume context of the next
/// wake. Real HTTP, a real PostgreSQL writer and an authenticated machine
/// socket; a controlled peer supplies the daemon frames, which is not proof of
/// an official Computer, Codex process or model turn.
@Test(.enabled(if: mentionDeliveryPGEnabled), .serialized)
func postgresOfflineMentionIsRecordedRedrivenOnceAndAcked() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_MENTION_DELIVERY_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    func phase(_ value: String) { print("MENTION_DELIVERY_PG \(value)") }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    phase("fixture-started")
    var machine: ControlledMachineProtocolPeer?
    let daemonId = "mention-delivery-daemon-\(UUID().uuidString.lowercased())"
    let sequence = ProtocolPGSequence()
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let attached = try await fixture.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("Mention delivery fixture")]))
        guard attached.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let computer = try attached.object()
        let machineID = try computer.requireString("machineId")
        let key = try computer.requireString("apiKey")
        let config: JSONValue = .object(["version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")])])
        let created = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("MentionCindy"), "machineId": .string(machineID),
                         "runtimeConfig": config]))
        guard created.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let agentID = try created.object().requireString("id")
        let room = try await fixture.http("POST", "/api/channels", token: owner,
            body: .init(["name": .string("mention-delivery-room")]))
        guard room.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let roomID = try room.object().requireString("id")
        let join = try await fixture.http("POST", "/api/channels/\(roomID)/members", token: owner,
            body: .init(["agentId": .string(agentID)]))
        #expect(join.status == 200)
        phase("http-setup-complete")

        func postMention(_ content: String) async throws -> String {
            let response = try await fixture.http("POST", "/api/v2/messages", token: owner,
                body: .init(["channelId": .string(roomID), "content": .string(content),
                             "mentions": .array([.object([
                                 "type": .string("agent"), "id": .string(agentID),
                                 "name": .string("MentionCindy")])])]))
            guard response.status == 200, let message = try response.object().object("message") else {
                throw ProtocolPGFailure.invalidResponse
            }
            return try message.requireString("id")
        }

        // The Computer has never connected. The mention is accepted, its
        // occurrence is durable, and no delivery has been attempted.
        let mentionMessage = try await postMention("@MentionCindy send this while offline")
        let offlineAudit = try await fixture.audit()
        #expect(offlineAudit.messages.contains { $0.string("id") == mentionMessage })
        let recorded = try #require(mentionOccurrence(offlineAudit, messageID: mentionMessage, agentID: agentID))
        #expect(recorded.string("state") == "recorded")
        #expect(recorded.string("serverDecidedAt") == nil)
        #expect(recorded.string("deliveryPayloadJSON") == nil)
        let pending = try #require(offlineAudit.execution.pendingHumanDeliveries)
        #expect(pending.values.contains { $0.agentId == agentID && $0.messageId == mentionMessage })
        phase("offline-mention-recorded")

        // Machine ready. The queued wake starts the runtime; a tracked mention
        // is not embedded in the start (its session identity does not exist yet).
        let peer = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: daemonId, sequence: sequence)
        machine = peer
        let boundary = peer.socket.count
        try await peer.sendControlledReady(runningAgentIds: [])
        let start = try await peer.socket.nextObject(since: boundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == agentID
        }
        let launchID = try start.requireString("launchId")
        #expect(start.array("resumeMessages") == nil, "a session-less start has no resume catch-up")
        try await peer.acknowledgeControlledStart(start)
        try await peer.sendProcessSpawned(agentId: agentID, launchId: launchID,
                                          processInstanceId: "mention-process")
        phase("ready-start")

        // The session identity that just became known rebuilds the ACK
        // obligation from the durable occurrence and sends exactly one tracked
        // delivery.
        try await peer.sendSession(agentId: agentID, launchId: launchID, sessionId: "mention-session")
        let delivery = try await peer.socket.nextObject(since: boundary) {
            $0.string("type") == "agent:deliver" && $0.string("agentId") == agentID
                && $0.object("message")?.string("message_id") == mentionMessage
        }
        let identity = try #require(delivery.object("mentionDelivery"))
        let occurrenceID = try identity.requireString("occurrenceId")
        #expect(delivery.string("deliveryId") == occurrenceID, "the occurrence id is the delivery id")
        #expect(identity.string("messageId") == mentionMessage)
        #expect(identity.string("machineId") == machineID)
        #expect(identity.string("launchId") == launchID)
        #expect(identity.string("sessionId") == "mention-session")
        let delivered = try await fixture.audit()
        let decided = try #require(mentionOccurrence(delivered, messageID: mentionMessage, agentID: agentID))
        #expect(decided.string("state") == "server_decided")
        #expect(decided.string("machineIdSnapshot") == machineID)
        #expect(decided.string("launchIdSnapshot") == launchID)
        #expect(decided.string("sessionIdSnapshot") == "mention-session")
        #expect(decided.string("deliveryPayloadJSON") != nil)
        phase("session-redriven-once")

        // Daemon receipts: received -> drained -> ACK with the same identity.
        try await peer.acknowledgeControlledMentionDelivery(delivery)
        try await protocolPGEventually {
            let audit = try await fixture.audit()
            return mentionOccurrence(audit, messageID: mentionMessage, agentID: agentID)?.string("state") == "acked"
                && (audit.execution.pendingHumanDeliveries ?? [:]).isEmpty
        }
        let ackedAudit = try await fixture.audit()
        let acked = try #require(mentionOccurrence(ackedAudit, messageID: mentionMessage, agentID: agentID))
        #expect(acked.object("ackedAt") != nil)
        #expect(acked.object("daemonDrainedAt") != nil)
        let commands = ackedAudit.execution.commands.values.filter {
            $0.kind == .delivery && $0.agentId == agentID && $0.messageId == mentionMessage
        }
        #expect(commands.count == 1)
        #expect(commands.first?.deliveryId == occurrenceID)
        #expect(commands.first?.status == .accepted)
        let projection = try await fixture.http(
            "GET", "/api/messages/\(mentionMessage)/mention-deliveries", token: owner)
        #expect(projection.status == 200)
        let row = try #require(try projection.object().array("deliveries")?.first)
        guard case .object(let rowFields) = row else { throw ProtocolPGFailure.missingField }
        #expect(ProtocolPGObject(rowFields).string("outcome") == "delivered")
        // The acknowledged delivery started a turn; settle it before the
        // disconnect so the next ready is a clean wake rather than an
        // in-flight turn that a human must recover.
        try await peer.sendTurnCompleted(agentId: agentID, launchId: launchID, sessionId: "mention-session")
        try await protocolPGEventually {
            try await fixture.audit().execution.agents[agentID]?.launches[launchID]?.completed == true
        }
        // The daemon's process exits (the next wake is a fresh start).
        try await peer.sendProcessExited(agentId: agentID, launchId: launchID,
                                         processInstanceId: "mention-process", spawnLaunchId: launchID)
        try await protocolPGEventually {
            try await fixture.audit().execution.agents[agentID]?.processes["mention-process"]?.exited == true
        }
        phase("mention-delivered")

        // A second ready with the same live occurrence re-sends nothing.
        let replayBoundary = peer.socket.count
        try await peer.sendControlledReady(runningAgentIds: [])
        try await peer.socket.applicationFence()
        let replayWire = try await peer.socket.wireFence(since: replayBoundary)
        #expect(!replayWire.contains { $0.contains("\"agent:deliver\"") && $0.contains(mentionMessage) })
        phase("acked-occurrence-not-redriven")

        // ---- Resume context for the next wake after an offline period.
        // The agent now has a session. It disconnects; a DM arrives while it is
        // not running; the next start carries the unread catch-up.
        let dm = try await fixture.http("POST", "/api/channels/dm", token: owner,
            body: .init(["agentId": .string(agentID)]))
        #expect(dm.status == 200)
        let dmID = try dm.object().requireString("id")
        await peer.socket.close()
        machine = nil
        try await protocolPGEventually {
            try await fixture.audit().execution.connections[machineID]?.online == false
        }
        let dmResponse = try await fixture.http("POST", "/api/v2/messages", token: owner,
            body: .init(["channelId": .string(dmID),
                         "content": .string("Arrived while MentionCindy was not running")]))
        #expect(dmResponse.status == 200)
        guard let dmMessage = try dmResponse.object().object("message") else {
            throw ProtocolPGFailure.missingField
        }
        let dmMessageID = try dmMessage.requireString("id")
        phase("offline-dm-committed")

        let reconnected = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key, daemonId: daemonId, sequence: sequence)
        machine = reconnected
        let resumeBoundary = reconnected.socket.count
        try await reconnected.sendControlledReady(runningAgentIds: [])
        let resumedStart = try await reconnected.socket.nextObject(since: resumeBoundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == agentID
        }
        let resumeMessages = try #require(resumedStart.array("resumeMessages"))
        let resumeObjects = resumeMessages.compactMap { value -> ProtocolPGObject? in
            guard case .object(let fields) = value else { return nil }
            return ProtocolPGObject(fields)
        }
        #expect(resumeObjects.contains { $0.string("message_id") == dmMessageID },
                "the start carries the message that arrived while the agent was offline")
        let unreadSummary = try #require(resumedStart.object("unreadSummary"))
        #expect(unreadSummary.fields.keys.contains { $0.hasPrefix("dm:@") })
        let resumedLaunch = try resumedStart.requireString("launchId")
        try await reconnected.acknowledgeControlledStart(resumedStart)
        try await reconnected.sendSession(agentId: agentID, launchId: resumedLaunch, sessionId: "mention-session-2")
        phase("resume-context-carried")
        phase("complete")
    } catch {
        await fixture.close(machine: machine)
        throw error
    }
    await fixture.close(machine: machine)
}

private func mentionOccurrence(_ audit: ProtocolPGAudit, messageID: String,
                               agentID: String) -> ProtocolPGObject? {
    audit.mentions.first {
        $0.string("messageId") == messageID && $0.string("targetId") == agentID
    }?.object("mentionDeliveryOccurrence")
}
