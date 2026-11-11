import Foundation
import RaftPersistence
import RaftShared
import Testing
@testable import RaftHTTP

/// Independent SQL/network evidence. No Store graph is allocated after activate.
struct MentionPGSnapshot: Sendable, CustomStringConvertible {
    let documents: [DurableDocument]
    let messages: [ProtocolPGObject]
    let mentions: [ProtocolPGObject]
    let oauth: ProtocolPGObject
    let execution: AgentExecutionState
    var description: String { "MentionPGSnapshot(redacted)" }

    static func keys() throws -> [DurableKey] {
        let roots = try DurableDomain.allCases.map { try DurableKey(domain: $0, aggregateID: "root") }
        let native = try DurableKey(domain: .notifications, aggregateID: "native")
        return roots + [native]
    }
    static func read(_ f: AgentExecutionPostgresFixture) async throws -> Self {
        let keys = try keys()
        let documents = try await f.observer.readSnapshot(keys)
        // Since the fail-closed fix, a commit writes only owners whose bytes
        // changed while its CAS conditions still pin all fourteen. Per-owner
        // revisions therefore legitimately diverge; a single shared revision
        // was an artifact of the old write-every-owner behavior, never a
        // contract. What a coherent current snapshot must prove is all
        // fourteen keys present, each with a live revision.
        guard documents.count == 14, Set(documents.map(\.key)) == Set(keys),
              documents.allSatisfy({ $0.revision > 0 }) else { throw ProtocolPGFailure.invalidSnapshot }
        func bytes(_ domain: DurableDomain) throws -> Data {
            guard let document = documents.first(where: { $0.key.domain == domain && $0.key.aggregateID == "root" }),
                  document.codecVersion == 1 else { throw ProtocolPGFailure.invalidSnapshot }
            return try document.decode(Data.self, codecVersion: 1)
        }
        let messageOwner = try ProtocolPGObject(data: bytes(.messagesAndThreads))
        let oauthOwner = try ProtocolPGObject(data: bytes(.oauthLedger))
        guard messageOwner.string("owner") == "messages-and-threads", messageOwner.integer("version") == 1,
              let payload = messageOwner.object("payload"), oauthOwner.string("format") == "raft.oauth-ledger",
              oauthOwner.integer("version") == 1, let oauth = oauthOwner.object("businessState") else {
            throw ProtocolPGFailure.invalidSnapshot
        }
        let runtime = try RuntimePersistenceFormat.decode(MentionPGRuntimePayload.self,
            from: bytes(.agentsRuntime), domain: "raft.agents-runtime")
        guard let execution = runtime.execution else { throw ProtocolPGFailure.invalidSnapshot }
        try execution.validate()
        return try Self(documents: documents, messages: mentionPGRows(payload, "humanMessageRows"),
                        mentions: mentionPGRows(payload, "storedMentions"), oauth: oauth, execution: execution)
    }
    func mention(_ id: String) throws -> ProtocolPGObject {
        let rows = mentions.filter { $0.string("id") == id }
        return try #require(rows.count == 1 ? rows.first : nil)
    }
    func message(_ id: String) throws -> ProtocolPGObject {
        let rows = messages.filter { $0.string("id") == id }
        return try #require(rows.count == 1 ? rows.first : nil)
    }
    func member(_ kind: String, channel: String, id: String) throws -> Bool {
        try mentionPGStrings(oauth, kind).contains("\(channel)\n\(id)")
    }
}

private struct MentionPGRuntimePayload: Codable, Sendable { let execution: AgentExecutionState? }

func mentionPGRows(_ object: ProtocolPGObject, _ key: String) throws -> [ProtocolPGObject] {
    guard let array = object.array(key) else { print("mention109 diagnostic: missing-or-non-array field=\(key)"); throw ProtocolPGFailure.missingField }
    return try array.map {
        guard case .object(let fields) = $0 else { throw ProtocolPGFailure.invalidResponse }
        return ProtocolPGObject(fields)
    }
}
func mentionPGStrings(_ object: ProtocolPGObject, _ key: String) throws -> Set<String> {
    guard let array = object.array(key) else { print("mention109 diagnostic: missing-or-non-array field=\(key)"); throw ProtocolPGFailure.missingField }
    return try Set(array.map {
        guard case .string(let value) = $0 else { throw ProtocolPGFailure.invalidResponse }
        return value
    })
}
func mentionPGHasValue(_ object: ProtocolPGObject, _ key: String) -> Bool {
    guard let value = object.fields[key] else { return false }
    return value != .null
}

struct MentionPGHost: Sendable {
    let messageId: String
    let resolutionId: String
}

func mentionPGInput(channel: String, targetType: String, target: String, name: String, text: String) -> ProtocolPGObject {
    .init(["channelId": .string(channel), "content": .string("\(text) @\(name)"),
           "randomId": .string(UUID().uuidString.lowercased()),
           "mentions": .array([.object(["type": .string(targetType), "id": .string(target), "name": .string(name)])])])
}
func mentionPGHost(_ response: ProtocolPGHTTPResponse, agent: Bool, targetType: String, name: String) throws -> MentionPGHost {
    try #require(response.status == 200)
    let object = try response.object()
    if agent { #expect(object.string("state") == "sent") }
    let message = object.object("message") ?? object
    let messageId: String
    if agent { messageId = try object.requireString("messageId") }
    else { messageId = try message.requireString("id") }
    let pending = try mentionPGRows(object, "pendingMentionActions")
    let selected = try #require(pending.first { $0.string("targetType") == targetType && $0.string("targetHandle") == name })
    #expect(selected.string("messageId") == messageId)
    let id = try selected.requireString("resolutionId")
    try #require(UUID(uuidString: id) != nil)
    return .init(messageId: messageId, resolutionId: id)
}
func mentionPGHumanSend(_ f: AgentExecutionPostgresFixture, token: String, channel: String,
                        targetType: String, target: String, name: String, text: String, v2: Bool = false) async throws -> MentionPGHost {
    let response = try await f.http("POST", v2 ? "/api/v2/messages" : "/api/messages", token: token,
        body: mentionPGInput(channel: channel, targetType: targetType, target: target, name: name, text: text))
    return try mentionPGHost(response, agent: false, targetType: targetType, name: name)
}
func mentionPGAgentSend(_ f: AgentExecutionPostgresFixture, key: String, channelName: String,
                        target: String, name: String, text: String, v2: Bool) async throws -> MentionPGHost {
    let response = try await f.http("POST", v2 ? "/internal/agent-api/v2/send" : "/internal/agent-api/send", token: key,
        body: .init(["target": .string("#\(channelName)"), "content": .string("\(text) @\(name)"),
                     "idempotencyKey": .string(UUID().uuidString.lowercased()),
                     "mentions": .array([.object(["type": .string("agent"), "id": .string(target), "name": .string(name)])])]))
    return try mentionPGHost(response, agent: true, targetType: "agent", name: name)
}
func mentionPGAction(_ f: AgentExecutionPostgresFixture, token: String, ids: [String], action: String,
                     agent: Bool = false) async throws -> ProtocolPGObject {
    let response = try await f.http("POST", agent ? "/internal/agent-api/mention-actions/execute" : "/api/messages/mention-actions/execute",
        token: token, body: .init(["action": .string(action), "resolutionIds": .array(ids.map(JSONValue.string))]))
    try #require(response.status == 200)
    let object = try response.object()
    #expect(object.bool("ok") == true)
    #expect(object.string("action") == action)
    return try #require(mentionPGRows(object, "results").first)
}
func mentionPGClaim(_ sql: MentionPGSnapshot, hosts: [MentionPGHost], actor: String, actorType: String,
                    channel: String, target: String, action: String?) throws {
    for host in hosts {
        let message = try sql.message(host.messageId)
        #expect(message.string("senderId") == actor)
        #expect(message.string("senderType") == actorType)
        #expect(message.string("channelId") == channel)
        let row = try sql.mention(host.resolutionId)
        #expect(row.string("messageId") == host.messageId)
        #expect(row.string("senderId") == actor)
        #expect(row.string("channelId") == channel)
        #expect(row.string("targetId") == target)
        #expect(row.bool("notifiableAtSend") == false)
        #expect(sql.mentions.filter { $0.string("messageId") == host.messageId && $0.string("targetId") == target }.count == 1)
        if let action {
            #expect(mentionPGHasValue(row, "notifiedAt"))
            #expect(row.string("notifiedById") == actor)
            #expect(row.string("notifiedByType") == actorType)
            #expect(row.string("notifiedAction") == action)
        } else {
            #expect(!mentionPGHasValue(row, "notifiedAt"))
        }
    }
}

@discardableResult
func mentionPGStartReceipt(_ f: AgentExecutionPostgresFixture, peer: ControlledMachineProtocolPeer,
                           agent: String, since boundary: Int, human: Bool) async throws -> ProtocolPGObject {
    let frame = try await peer.socket.nextObject(since: boundary) { $0.string("type") == "agent:start" && $0.string("agentId") == agent }
    let dispatch = try frame.requireString("startDispatchId")
    let sql = try await MentionPGSnapshot.read(f)
    let command = try #require(sql.execution.commands.values.first { $0.kind == .start && $0.agentId == agent && $0.startDispatchId == dispatch })
    #expect(frame.string("launchId") == command.launchId)
    #expect(frame.string("connectionEpochId") == command.connectionEpochId)
    #expect(frame.integer("takeoverEpoch") == command.takeoverEpoch)
    #expect(frame.integer("breakerGeneration") == command.breakerGeneration)
    #expect(frame.bool("humanStart") == human)
    #expect(command.humanStart == human)
    #expect(sql.execution.dispatches?[command.commandId.uuidString]?.phase == .attempting)
    #expect(sql.execution.agents[agent]?.launches[command.launchId]?.startAccepted == false)
    let effect = try #require(try await f.outbox(command.commandId))
    #expect(effect.effect.kind.rawValue == "agent.execution")
    #expect(effect.deliveredAt == nil)
    let reference = try JSONDecoder().decode(AgentExecutionIntentReference.self, from: effect.effect.payload)
    #expect(reference.commandId == command.commandId)
    try await peer.acknowledgeControlledStart(frame)
    try await protocolPGEventually { try await f.outbox(command.commandId)?.deliveredAt != nil }
    let accepted = try await MentionPGSnapshot.read(f)
    #expect(accepted.execution.commands[command.commandId.uuidString]?.status == .accepted)
    #expect(accepted.execution.dispatches?[command.commandId.uuidString]?.phase == .accepted)
    #expect(accepted.execution.agents[agent]?.launches[command.launchId]?.startAccepted == true)
    #expect(accepted.execution.agents[agent]?.processes.isEmpty == true)
    return frame
}
@discardableResult
func mentionPGDeliveryReceipt(_ f: AgentExecutionPostgresFixture, peer: ControlledMachineProtocolPeer,
                              agent: String, host: MentionPGHost, channel: String, since boundary: Int) async throws -> AgentExecutionCommand {
    let frame = try await peer.socket.nextObject(since: boundary) {
        $0.string("type") == "agent:deliver" && $0.string("agentId") == agent && $0.object("message")?.string("message_id") == host.messageId
    }
    let sql = try await MentionPGSnapshot.read(f)
    let id = try frame.requireString("deliveryId")
    let command = try #require(sql.execution.commands.values.first { $0.kind == .delivery && $0.deliveryId == id })
    let message = try sql.message(host.messageId)
    #expect(command.agentId == agent && command.messageId == host.messageId && command.channelId == channel)
    #expect(frame.object("message")?.string("channel_id") == channel)
    #expect(frame.integer("seq") == message.integer("seq"))
    #expect(sql.execution.dispatches?[command.commandId.uuidString]?.deliverySequence == message.integer("seq"))
    #expect(sql.execution.dispatches?[command.commandId.uuidString]?.phase == .attempting)
    let outbox = try #require(try await f.outbox(command.commandId))
    #expect(outbox.deliveredAt == nil && outbox.effect.kind.rawValue == "agent.execution")
    let reference = try JSONDecoder().decode(AgentExecutionIntentReference.self, from: outbox.effect.payload)
    #expect(reference.commandId == command.commandId)
    try await peer.acknowledgeControlledDelivery(frame)
    try await protocolPGEventually { try await f.outbox(command.commandId)?.deliveredAt != nil }
    let accepted = try await MentionPGSnapshot.read(f)
    #expect(accepted.execution.commands[command.commandId.uuidString]?.status == .accepted)
    #expect(accepted.execution.dispatches?[command.commandId.uuidString]?.phase == .accepted)
    #expect(accepted.execution.agents[agent]?.processes.isEmpty == true)
    return command
}
func mentionPGNoAgentFrames(_ peer: ControlledMachineProtocolPeer, since boundary: Int, agent: String? = nil) async throws {
    let frames = try await peer.socket.wireFence(since: boundary).compactMap { try? ProtocolPGObject(text: $0) }
    #expect(!frames.contains { frame in
        ["agent:start", "agent:deliver"].contains(frame.string("type") ?? "") && (agent == nil || frame.string("agentId") == agent)
    })
}
