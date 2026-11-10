import Foundation
import RaftHTTP
import RaftShared

/// Configuration/message data is ephemeral. Checked Codable values retain the
/// complete supplied objects, including optional fields not interpreted here.
enum ProductionAgentExecutionWire {
    enum Error: Swift.Error, Sendable, Equatable {
        case invalidCommandIdentity
        case invalidConfiguration
        case invalidMessage
    }

    static func start(_ command: AgentExecutionCommand, configuration: Data) throws -> Data {
        guard command.kind == .start, !command.agentId.isEmpty, !command.launchId.isEmpty,
              let dispatch = command.startDispatchId, !dispatch.isEmpty, !command.connectionEpochId.isEmpty else {
            throw Error.invalidCommandIdentity
        }
        guard let config = object(configuration), nonempty(config["name"]), nonempty(config["model"]),
              string(config["runtime"]) == "codex", nullableString(config["displayName"]), nullableString(config["description"]),
              nullableString(config["reasoningEffort"]), nullableString(config["sessionId"]),
              string(config["sessionId"]) == command.sessionId, string(config["authToken"]) == "",
              nonempty(config["agentCredentialKey"]), nonempty(config["agentCredentialId"]),
              validServerURL(string(config["serverUrl"])), validEnvironment(config["envVars"]),
              let context = dictionary(config["runtimeContext"]), string(context["agentId"]) == command.agentId,
              string(context["serverId"]) == command.serverId, string(context["machineId"]) == command.machineId else {
            throw Error.invalidConfiguration
        }
        if let runtimeConfig = config["runtimeConfig"], runtimeConfig != .null, dictionary(runtimeConfig) == nil {
            throw Error.invalidConfiguration
        }
        let envelope = StartEnvelope(agentId: command.agentId, config: .object(config), launchId: command.launchId,
                                     startDispatchId: dispatch, breakerGeneration: command.breakerGeneration,
                                     takeoverEpoch: command.takeoverEpoch, humanStart: command.humanStart,
                                     connectionEpochId: command.connectionEpochId, resumePrompt: command.resumePrompt)
        return try encode(envelope.value, failure: .invalidConfiguration)
    }

    static func delivery(_ command: AgentExecutionCommand, message: Data, sequence: Int64) throws -> Data {
        guard command.kind == .delivery, let deliveryId = command.deliveryId, !deliveryId.isEmpty,
              let channelId = command.channelId, let messageId = command.messageId,
              !command.agentId.isEmpty, sequence >= 0, sequence <= 9_007_199_254_740_991 else { throw Error.invalidCommandIdentity }
        guard let body = object(message), string(body["channel_id"]) == channelId, string(body["message_id"]) == messageId,
              string(body["channel_name"]) != nil, string(body["sender_name"]) != nil,
              nonempty(body["sender_id"]), string(body["content"]) != nil, nonempty(body["timestamp"]),
              ["channel", "private", "joint", "dm", "thread"].contains(string(body["channel_type"]) ?? ""),
              ["human", "agent", "system", "third_party_app"].contains(string(body["sender_type"]) ?? "") else {
            throw Error.invalidMessage
        }
        if let raw = body["seq"], safeSequence(raw) != sequence { throw Error.invalidMessage }
        let envelope = DeliveryEnvelope(agentId: command.agentId, message: .object(body), seq: sequence, deliveryId: deliveryId)
        return try encode(envelope.value, failure: .invalidMessage)
    }

    private struct StartEnvelope: Encodable, Sendable {
        let agentId: String
        let config: JSONValue
        let launchId: String
        let startDispatchId: String
        let breakerGeneration: Int64
        let takeoverEpoch: Int64
        let humanStart: Bool
        let connectionEpochId: String
        let resumePrompt: String?

        var value: JSONValue {
            var members: [String: JSONValue] = [
                "type": .string("agent:start"), "agentId": .string(agentId), "config": config,
                "launchId": .string(launchId), "startDispatchId": .string(startDispatchId),
                "breakerGeneration": .integer(breakerGeneration), "takeoverEpoch": .integer(takeoverEpoch),
                "humanStart": .bool(humanStart), "connectionEpochId": .string(connectionEpochId)
            ]
            if let resumePrompt { members["resumePrompt"] = .string(resumePrompt) }
            return .object(members)
        }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    private struct DeliveryEnvelope: Encodable, Sendable {
        let agentId: String
        let message: JSONValue
        let seq: Int64
        let deliveryId: String

        var value: JSONValue {
            .object(["type": .string("agent:deliver"), "agentId": .string(agentId), "message": message,
                     "seq": .integer(seq), "deliveryId": .string(deliveryId)])
        }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    private static func object(_ data: Data) -> [String: JSONValue]? {
        guard data.count <= 1024 * 1024, AgentExecutionJSONNumberPolicy.accepts(data) else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }
    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }
    private static func dictionary(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let members)? = value else { return nil }
        return members
    }
    private static func nonempty(_ value: JSONValue?) -> Bool { string(value)?.isEmpty == false }
    private static func nullableString(_ value: JSONValue?) -> Bool { value == .null || string(value) != nil }
    private static func validEnvironment(_ value: JSONValue?) -> Bool {
        if value == .null { return true }
        guard let values = dictionary(value) else { return false }
        return values.values.allSatisfy { string($0) != nil }
    }
    private static func safeSequence(_ value: JSONValue) -> Int64? {
        switch value {
        case .integer(let number) where number >= 0 && number <= 9_007_199_254_740_991: return number
        case .number(let number) where number.isFinite && number >= 0 && number <= 9_007_199_254_740_991
            && number.rounded(.towardZero) == number: return Int64(number)
        default: return nil
        }
    }
    private static func validServerURL(_ value: String?) -> Bool {
        guard let value, let url = URLComponents(string: value), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return true
    }
    private static func encode(_ value: JSONValue, failure: Error) throws -> Data {
        guard let text = LegacySortedJSON.render(value) else { throw failure }
        let encoded = Data(text.utf8)
        guard encoded.count <= 1024 * 1024 else { throw failure }
        return encoded
    }
}
