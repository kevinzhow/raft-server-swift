import Foundation

public struct AgentExecutionMachineContext: Sendable, Equatable, Codable {
    public let machineId: String
    public let serverId: String
    public let connectionEpochId: String
    public init(machineId: String, serverId: String, connectionEpochId: String) {
        self.machineId = machineId
        self.serverId = serverId
        self.connectionEpochId = connectionEpochId
    }
}

public enum AgentExecutionAcknowledgement: Sendable, Equatable {
    case sequence(agentId: String, daemonInstanceId: String, clientSeq: Int64)
    case marker(agentId: String, gapId: String)
}

/// Only AgentExecutionService.consume returns an authorized commit result.
/// Domain staging results remain internal until the coordinator confirms COMMIT.
public enum AgentExecutionIngressResult: Sendable, Equatable {
    case hold(reason: String)
    case committed(ack: AgentExecutionAcknowledgement?)
}

public enum AgentExecutionError: Error, Sendable, Equatable {
    case durableTransactionRequired
    case ownershipMismatch
    case machineNotReady
    case manualRecoveryRequired
    case manuallyStopped
    case breakerPaused
    case launchInProgress
    case noActiveLaunch
    case conflictingCommand
    case invalidRequest
    case staleConnection
    case dispatchUnavailable
}

public enum AgentExecutionStartControl: String, Codable, Sendable {
    case automatic
    /// Only an explicitly authorized human control route may choose this value.
    case humanStart
}

public struct AgentExecutionStartRequest: Codable, Sendable, Equatable {
    public let commandId: UUID
    public let serverId: String
    public let agentId: String
    public let control: AgentExecutionStartControl
    public let resumePrompt: String?
    public init(commandId: UUID = UUID(), serverId: String, agentId: String,
                control: AgentExecutionStartControl = .automatic, resumePrompt: String? = nil) {
        self.commandId = commandId
        self.serverId = serverId
        self.agentId = agentId
        self.control = control
        self.resumePrompt = resumePrompt
    }
}

public struct AgentExecutionDeliveryRequest: Codable, Sendable, Equatable {
    public let commandId: UUID
    public let serverId: String
    public let agentId: String
    public let channelId: String
    public let messageId: String
    public init(commandId: UUID = UUID(), serverId: String, agentId: String, channelId: String, messageId: String) {
        self.commandId = commandId
        self.serverId = serverId
        self.agentId = agentId
        self.channelId = channelId
        self.messageId = messageId
    }
}

public struct AgentExecutionStopRequest: Codable, Sendable, Equatable {
    public let commandId: UUID
    public let serverId: String
    public let agentId: String
    public init(commandId: UUID = UUID(), serverId: String, agentId: String) {
        self.commandId = commandId
        self.serverId = serverId
        self.agentId = agentId
    }
}

/// The stop intent can be persisted without any machine dispatch target.
/// This is not an acknowledgement from a daemon or a fabricated launch.
public struct AgentExecutionStopAdmission: Codable, Sendable, Equatable {
    public let commandId: UUID
    public let requiresMachineDispatch: Bool
}

/// Admission means a command and its outbox reference are staged together.
/// It is neither a dispatch receipt nor process/turn/message/task completion.
public struct AgentExecutionAdmission: Codable, Sendable, Equatable {
    public let commandId: UUID
    public let launchId: String
    public let startDispatchId: String?
    public let deliveryId: String?
}

/// The outbox carries only an immutable reference. The worker resolves current
/// fenced business facts and builds credentials/config outside the business txn.
public struct AgentExecutionIntentReference: Codable, Sendable, Equatable {
    public let commandId: UUID
    public init(commandId: UUID) { self.commandId = commandId }
    enum CodingKeys: String, CodingKey { case commandId }
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: AgentExecutionReferenceCodingKey.self)
        guard Set(raw.allKeys.map(\.stringValue)) == Set(["commandId"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid execution reference keys"))
        }
        commandId = try decoder.container(keyedBy: CodingKeys.self).decode(UUID.self, forKey: .commandId)
    }
}

public struct AgentExecutionCommand: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case start, delivery, stop }
    public enum Status: String, Codable, Sendable { case pending, dispatched, accepted, superseded }
    public let commandId: UUID
    public let kind: Kind
    public let serverId: String
    public let machineId: String
    public let agentId: String
    public let launchId: String
    public let startDispatchId: String?
    public let deliveryId: String?
    public var connectionEpochId: String
    public let takeoverEpoch: Int64
    public let breakerGeneration: Int64
    public let humanStart: Bool
    public let sessionId: String?
    public let resumePrompt: String?
    public let channelId: String?
    public let messageId: String?
    public var status: Status
    public let createdAt: Date

    public var admission: AgentExecutionAdmission {
        AgentExecutionAdmission(commandId: commandId, launchId: launchId,
                                startDispatchId: startDispatchId, deliveryId: deliveryId)
    }
}
