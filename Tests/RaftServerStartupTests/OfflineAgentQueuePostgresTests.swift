import Foundation
import RaftPersistence
import RaftShared
import Testing
@testable import RaftHTTP

private let offlineQueuePGEnabled =
    ProcessInfo.processInfo.environment["RAFT_AGENT_OFFLINE_QUEUE_PG_ACCEPTANCE"] == "1"

/// Complete published path for an offline human DM: real HTTP create while the
/// Computer socket is absent, the durable pending delivery in PostgreSQL, the
/// authenticated machine socket reconnecting with `ready`, and exactly one
/// `agent:start` / `agent:deliver` pair whose delivery ACK settles the queue.
@Test(.enabled(if: offlineQueuePGEnabled), .serialized)
func postgresOfflineDmIsQueuedAndDeliveredExactlyOnceOnReady() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_AGENT_OFFLINE_QUEUE_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    func phase(_ value: String) { print("OFFLINE_QUEUE_PG \(value)") }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    phase("fixture-started")
    var machine: ControlledMachineProtocolPeer?
    let sequence = ProtocolPGSequence()
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let attached = try await fixture.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("Offline queue fixture")]))
        guard attached.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let computer = try attached.object()
        let machineId = try computer.requireString("machineId")
        let key = try computer.requireString("apiKey")
        let config: JSONValue = .object([
            "version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")]),
        ])
        let created = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Offline queue Cindy"), "machineId": .string(machineId),
                         "runtimeConfig": config]))
        guard created.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let agentId = try created.object().requireString("id")
        let dm = try await fixture.http("POST", "/api/channels/dm", token: owner,
            body: .init(["agentId": .string(agentId)]))
        #expect(dm.status == 200)
        let channelId = try dm.object().requireString("id")
        phase("http-setup-complete")

        // The Computer has never connected: the DM is accepted (200) and the
        // canonical message commits, while the recipient is not deliverable.
        let posted = try await fixture.http("POST", "/api/v2/messages", token: owner,
            body: .init(["channelId": .string(channelId), "content": .string("Queued while offline")]))
        #expect(posted.status == 200)
        guard let messageObject = try posted.object().object("message") else { throw ProtocolPGFailure.missingField }
        let messageId = try messageObject.requireString("id")
        let queued = try await fixture.audit()
        #expect(queued.messages.contains { $0.string("id") == messageId })
        let pending = try #require(queued.execution.pendingHumanDeliveries)
        #expect(pending.count == 1)
        let entry = try #require(pending.values.first)
        #expect(entry.agentId == agentId)
        #expect(entry.channelId == channelId)
        #expect(entry.messageId == messageId)
        #expect(entry.releasedCommandId == nil)
        phase("offline-dm-queued")

        // The official Computer reconnects and reports no running process. The
        // ready transaction releases the queued delivery through the existing
        // strict start/delivery path.
        let peer = try await ControlledMachineProtocolPeer.connect(
            port: fixture.machineServer.port, key: key,
            daemonId: "offline-queue-daemon-\(UUID().uuidString.lowercased())", sequence: sequence)
        machine = peer
        let boundary = peer.socket.count
        try await peer.sendControlledReady(runningAgentIds: [])
        let start = try await peer.socket.nextObject(since: boundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == agentId
        }
        phase("start-frame")
        // Upstream `attempt-wake`: the queued message is the start's first input,
        // not a separate agent:deliver. The daemon runs it as the spawn turn.
        let wakeMessage = try #require(start.object("wakeMessage"))
        #expect(wakeMessage.string("message_id") == messageId)
        #expect(wakeMessage.string("channel_id") == channelId)
        try await peer.acknowledgeControlledStart(start)
        try await protocolPGEventually {
            let audit = try await fixture.audit()
            let pendingReleased = (audit.execution.pendingHumanDeliveries ?? [:]).isEmpty
            let accepted = audit.execution.commands.values.contains {
                $0.kind == .start && $0.agentId == agentId && $0.wakeMessage?.messageId == messageId
                    && $0.status == .accepted
            }
            return pendingReleased && accepted
        }
        phase("wake-accepted")

        // The wake frame carries the body and no duplicate delivery follows even
        // when the queue is re-released by later triggers.
        try await peer.socket.applicationFence()
        try await peer.sendControlledReady(runningAgentIds: [])
        let replayBoundary = peer.socket.count
        try await peer.socket.applicationFence()
        let replayWire = try await peer.socket.wireFence(since: replayBoundary)
        #expect(!replayWire.contains { $0.contains("\"agent:start\"") })
        #expect(!replayWire.contains { $0.contains("\"agent:deliver\"") })
        let starts = peer.socket.texts.filter { $0.contains("\"agent:start\"") }
        let deliveries = peer.socket.texts.filter { $0.contains("\"agent:deliver\"") }
        #expect(starts.count == 1)
        #expect(deliveries.isEmpty, "the wake message is never also sent as agent:deliver")
        phase("complete")
    } catch {
        await fixture.close(machine: machine)
        throw error
    }
    await fixture.close(machine: machine)
}
