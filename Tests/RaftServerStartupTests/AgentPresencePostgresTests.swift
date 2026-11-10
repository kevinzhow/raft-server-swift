import Foundation
import RaftShared
import Testing
@testable import RaftHTTP

private let presencePGEnabled = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_PG_ACCEPTANCE"] == "1"

/// Complete published path: an authenticated daemon socket sends the official
/// Computer's `agent:status` / `agent:activity` frames, the server's production
/// ingress commits them to the real PG-backed owners, `GET /api/agents` serves
/// the projection, and the Socket.IO room receives the activity push.
///
/// Controlled peer inputs only. This does not prove official Computer inventory,
/// a logged-in Codex process, or a model turn.
@Test(.enabled(if: presencePGEnabled), .serialized)
func postgresDaemonPresenceFramesProjectToAgentListAndRealtime() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_AGENT_EXECUTION_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    var machine: ControlledMachineProtocolPeer?
    var subscriber: ProtocolPGSocket?
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let attach = try await fixture.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("Presence protocol peer")]))
        #expect(attach.status == 201)
        let attached = try attach.object()
        let machineId = try attached.requireString("machineId")
        let computerKey = try attached.requireString("apiKey")
        let runtimeConfig: JSONValue = .object([
            "version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")]),
        ])
        let created = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Presence Cindy"), "machineId": .string(machineId),
                         "runtimeConfig": runtimeConfig]))
        #expect(created.status == 200)
        let agentId = try created.object().requireString("id")

        let updates = try await fixture.subscriber(token: owner)
        subscriber = updates
        let peer = try await ControlledMachineProtocolPeer.connect(port: fixture.machineServer.port, key: computerKey)
        machine = peer
        // The official Computer advertises sequenced status; activity is then a
        // display fact and never infers the process state (RFC 069 §8).
        try await peer.socket.send(.init([
            "type": .string("ready"), "daemonInstanceId": .string(peer.daemonId),
            "capabilities": .array(["agent:start", "agent:deliver", "agent:stop", "agent:status-sequenced",
                                    "agent:runtime-outcome-v1"].map(JSONValue.string)),
            "runtimes": .array([.string("codex")]), "runningAgents": .array([]),
            "runtimeDetection": .object(["status": .string("complete")]),
        ]))
        try await peer.socket.applicationFence()

        func listedAgent() async throws -> ProtocolPGObject {
            let response = try await fixture.http("GET", "/api/agents", token: owner)
            #expect(response.status == 200)
            guard case .array(let rows) = try JSONDecoder().decode(JSONValue.self, from: response.body) else {
                throw ProtocolPGFailure.invalidResponse
            }
            for row in rows {
                guard case .object(let fields) = row else { continue }
                if fields["id"] == .string(agentId) { return ProtocolPGObject(fields) }
            }
            throw ProtocolPGFailure.missingField
        }

        // Baseline: the agent is inactive and no daemon fact has been retained.
        let baseline = try await listedAgent()
        #expect(baseline.string("status") == "inactive")
        #expect(baseline.string("activity") == "offline")
        #expect(baseline.string("activityDetail") == "")

        // `agent:status active` is the daemon's process-state channel. It
        // persists through the real transaction and the list serves it.
        let statusBoundary = peer.socket.count
        try await peer.socket.send(.init([
            "type": .string("agent:status"), "agentId": .string(agentId), "status": .string("active"),
            "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(1),
        ]))
        try await peer.socket.applicationFence()
        // Presence frames are not durable-outcome outbox entries: the wire must
        // carry no fabricated outcome ACK for them.
        let statusWire = try await peer.socket.wireFence(since: statusBoundary)
        #expect(!statusWire.contains { $0.contains("agent:outcome:ack") })
        let activeAudit = try await fixture.audit()
        #expect(activeAudit.status(agent: agentId) == "active")
        let active = try await listedAgent()
        #expect(active.string("status") == "active")
        // A reachable machine with an active process derives online before the
        // first activity frame (upstream resolveDerivedActivity).
        #expect(active.string("activity") == "online")

        // Activity is derived from the canonical detailKind and pushed live.
        let thinkingBoundary = peer.socket.count
        try await peer.socket.send(.init([
            "type": .string("agent:activity"), "agentId": .string(agentId),
            "detail": .string("Preparing the answer"), "detailKind": .string("thinking_started"),
            "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(2),
        ]))
        try await peer.socket.applicationFence()
        let thinking = try await listedAgent()
        #expect(thinking.string("activity") == "thinking")
        #expect(thinking.string("activityDetail") == "Preparing the answer")
        let pushed = try await updates.nextText(since: thinkingBoundary) {
            $0.hasPrefix("42[\"agent:activity\"") && $0.contains(agentId)
        }
        #expect(pushed.contains("\"activity\":\"thinking\""))
        #expect(pushed.contains("\"detailKind\":\"thinking_started\""))
        #expect(pushed.contains("\"serverSeq\""))

        // `idle` is the canonical online state.
        try await peer.socket.send(.init([
            "type": .string("agent:activity"), "agentId": .string(agentId),
            "detail": .string(""), "detailKind": .string("idle"),
            "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(3),
        ]))
        try await peer.socket.applicationFence()
        let online = try await listedAgent()
        #expect(online.string("activity") == "online")

        // A manual stop is operator intent: a daemon that reports active again
        // must not reopen the agent, and the projection reads offline/Stopped.
        let stopped = try await fixture.http("POST", "/api/agents/\(agentId)/stop", token: owner)
        #expect(stopped.status == 200)
        try await peer.socket.send(.init([
            "type": .string("agent:status"), "agentId": .string(agentId), "status": .string("active"),
            "daemonInstanceId": .string(peer.daemonId), "clientSeq": .integer(4),
        ]))
        try await peer.socket.applicationFence()
        let stoppedAudit = try await fixture.audit()
        #expect(stoppedAudit.status(agent: agentId) == "stopped")
        let stoppedRow = try await listedAgent()
        #expect(stoppedRow.string("status") == "stopped")
        #expect(stoppedRow.string("activity") == "offline")
        #expect(stoppedRow.string("activityDetail") == "Stopped")
    } catch {
        await fixture.close(machine: machine, subscriber: subscriber); throw error
    }
    await fixture.close(machine: machine, subscriber: subscriber)
}
