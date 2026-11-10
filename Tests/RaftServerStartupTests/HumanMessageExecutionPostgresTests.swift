import Foundation
import RaftPersistence
import RaftShared
import Testing
@testable import RaftHTTP

private let humanExecutionPGEnabled =
    ProcessInfo.processInfo.environment["RAFT_HUMAN_MESSAGE_EXECUTION_PG_ACCEPTANCE"] == "1"

// Published HTTP + real PG + machine transport. The existing peer supplies
// controlled protocol inputs; this is not official Computer/Codex/model proof.
// Run this one filter in a fresh process with its own disposable database.
@Test(.enabled(if: humanExecutionPGEnabled), .serialized)
func postgresHumanChannelMessagesStageDeliveryOnceAndPreserveSuppressedMessages() async throws {
    guard let databaseURL = ProcessInfo.processInfo.environment["RAFT_HUMAN_MESSAGE_EXECUTION_TEST_DATABASE_URL"],
          !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProtocolPGFailure.missingDedicatedDatabase
    }
    let fixture = try await AgentExecutionPostgresFixture.start(databaseURL: databaseURL)
    var machine: ControlledMachineProtocolPeer?
    do {
        let owner = try await fixture.login(fixture.ownerEmail)
        let attached = try await fixture.http("POST", "/api/computer/attach", token: owner,
            body: .init(["serverSlug": .string(fixture.slug), "name": .string("Human delivery protocol fixture")]))
        guard attached.status == 201 else { throw ProtocolPGFailure.invalidResponse }
        let computer = try attached.object()
        let machineID = try computer.requireString("machineId")
        let key = try computer.requireString("apiKey")
        let config: JSONValue = .object(["version": .integer(1), "runtime": .string("codex"),
            "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")])])
        let created = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Joined human recipient"), "machineId": .string(machineID), "runtimeConfig": config]))
        guard created.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let agentID = try created.object().requireString("id")
        let unassigned = try await fixture.http("POST", "/api/agents", token: owner,
            body: .init(["name": .string("Unassigned human recipient"), "runtimeConfig": config]))
        guard unassigned.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let unassignedID = try unassigned.object().requireString("id")
        let room = try await fixture.http("POST", "/api/channels", token: owner,
            body: .init(["name": .string("human-execution-room")]))
        guard room.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let channelID = try room.object().requireString("id")
        let join = try await fixture.http("POST", "/api/channels/\(channelID)/members", token: owner,
            body: .init(["agentId": .string(agentID)]))
        guard join.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let peer = try await ControlledMachineProtocolPeer.connect(port: fixture.machineServer.port, key: key)
        machine = peer
        try await peer.sendControlledReady()
        let startBoundary = peer.socket.count
        let started = try await fixture.http("POST", "/api/agents/\(agentID)/start", token: owner)
        guard started.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let start = try await peer.socket.nextObject(since: startBoundary) {
            $0.string("type") == "agent:start" && $0.string("agentId") == agentID
        }
        try await peer.acknowledgeControlledStart(start)
        let boundary = peer.socket.count
        let randomID = "human-execution-once"
        let post = try await fixture.http("POST", "/api/messages", token: owner,
            body: .init(["channelId": .string(channelID), "content": .string("Ordinary clarification without mentions"),
                         "randomId": .string(randomID)]))
        guard post.status == 200 else { throw ProtocolPGFailure.invalidResponse }
        let messageID = try post.object().requireString("id")
        // This must already be in PG when HTTP completes, before any polling for
        // a daemon frame: message creation and execution reference share the UoW.
        let initial = try await fixture.audit()
        let deliveries = initial.execution.commands.values.filter { $0.kind == .delivery && $0.messageId == messageID }
        #expect(deliveries.count == 1)
        let command = try #require(deliveries.first)
        #expect(command.agentId == agentID)
        #expect(initial.messages.contains { $0.string("id") == messageID && $0.string("content") == "Ordinary clarification without mentions" })
        let entry = try #require(try await fixture.outbox(command.commandId))
        #expect(entry.effect.kind.rawValue == "agent.execution")
        let reference = try JSONDecoder().decode(AgentExecutionIntentReference.self, from: entry.effect.payload)
        #expect(reference.commandId == command.commandId)
        let frame = try await peer.socket.nextObject(since: boundary) {
            $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == messageID
        }
        #expect(frame.string("agentId") == agentID)
        try await peer.acknowledgeControlledDelivery(frame)
        let replay = try await fixture.http("POST", "/api/messages", token: owner,
            body: .init(["channelId": .string(channelID), "content": .string("Ordinary clarification without mentions"),
                         "randomId": .string(randomID)]))
        #expect(replay.status == 200)
        #expect(try replay.object().requireString("id") == messageID)
        let replayed = try await fixture.audit()
        #expect(replayed.messages.filter { $0.string("id") == messageID }.count == 1)
        #expect(replayed.execution.commands.values.filter { $0.kind == .delivery && $0.messageId == messageID }.count == 1)
        #expect(!replayed.execution.commands.values.contains { $0.agentId == unassignedID && $0.messageId == messageID })
        let v2Boundary = peer.socket.count
        let v2 = try await fixture.http("POST", "/api/v2/messages", token: owner,
            body: .init(["channelId": .string(channelID), "content": .string("New ordinary v2 clarification without randomId")]))
        #expect(v2.status == 200)
        let v2Message = try #require(try v2.object().object("message"))
        let v2ID = try v2Message.requireString("id")
        let v2Audit = try await fixture.audit()
        #expect(v2Audit.execution.commands.values.filter { $0.kind == .delivery && $0.messageId == v2ID && $0.agentId == agentID }.count == 1)
        let v2Frame = try await peer.socket.nextObject(since: v2Boundary) {
            $0.string("type") == "agent:deliver" && $0.object("message")?.string("message_id") == v2ID
        }
        try await peer.acknowledgeControlledDelivery(v2Frame)

        // A real retained preference, committed through the same BPR. The send
        // still goes through the published HTTP route, without a query/emit spy.
        try await fixture.runtime.execute {
            _ = fixture.accounts.oauth.setActivityMuted(channelId: channelID, receiverId: agentID, muted: true, muteFromSeq: 0)
        }
        let muted = try await fixture.http("POST", "/api/messages", token: owner,
            body: .init(["channelId": .string(channelID), "content": .string("Muted ordinary activity")]))
        #expect(muted.status == 200)
        let mutedID = try muted.object().requireString("id")
        let muteAudit = try await fixture.audit()
        #expect(muteAudit.messages.contains { $0.string("id") == mutedID })
        #expect(!muteAudit.execution.commands.values.contains { $0.messageId == mutedID })
        try await fixture.runtime.execute {
            _ = fixture.accounts.oauth.setActivityMuted(channelId: channelID, receiverId: agentID, muted: false, muteFromSeq: nil)
        }
        let unassignedJoin = try await fixture.http("POST", "/api/channels/\(channelID)/members", token: owner,
            body: .init(["agentId": .string(unassignedID)]))
        #expect(unassignedJoin.status == 200)
        let stopped = try await fixture.http("POST", "/api/agents/\(agentID)/stop", token: owner)
        #expect(stopped.status == 200)
        let heldReply = try await fixture.http("POST", "/api/messages", token: owner,
            body: .init(["channelId": .string(channelID), "content": .string("Readable while manually stopped or unassigned")]))
        #expect(heldReply.status == 200)
        let heldID = try heldReply.object().requireString("id")
        let held = try await fixture.audit()
        #expect(held.messages.contains { $0.string("id") == heldID })
        #expect(held.execution.heldDeliveries?.values.contains { $0.agentId == agentID && $0.messageId == heldID } == true)
        #expect(!held.execution.commands.values.contains { $0.messageId == heldID })
        #expect(held.execution.agents[agentID]?.processes.isEmpty == true)
    } catch {
        await fixture.close(machine: machine)
        throw error
    }
    await fixture.close(machine: machine)
}
