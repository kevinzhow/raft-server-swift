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

/// The frozen daemon identity a tracked mention delivery is checked against.
/// Upstream `MentionDeliveryIdentitySnapshot`: the daemon rejects a frame whose
/// occurrence/message/machine/launch/session do not match its own process.
public struct MentionDeliveryIdentitySnapshot: Codable, Sendable, Equatable {
    public let occurrenceId: String
    public let messageId: String
    public let machineId: String
    public let launchId: String
    public let sessionId: String
    public init(occurrenceId: String, messageId: String, machineId: String,
                launchId: String, sessionId: String) {
        self.occurrenceId = occurrenceId
        self.messageId = messageId
        self.machineId = machineId
        self.launchId = launchId
        self.sessionId = sessionId
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

/// A transient, agent-only notice: the system sender's onboarding context.
///
/// It is never a `messages` row, never a channel event and never an unread fact.
/// Upstream delivers the same body through `agentOrchestrator.deliverMessage`
/// with `seq: 0` and a synthetic `message_id`
/// (`deliverSystemNoticeToAgent`, the opener-v2 ledger and the owner-facts
/// context). The body carries no `seq` member: `0` belongs to the frame
/// envelope, exactly as the pinned server sends it.
public struct AgentExecutionNotice: Codable, Sendable, Equatable {
    public let channelName: String
    public let channelType: String
    public let content: String
    /// ISO-8601 text captured when the notice was admitted. It survives an
    /// outbox retry so the frame carries the original wake time.
    public let timestamp: String
    public init(channelName: String, channelType: String, content: String, timestamp: String) {
        self.channelName = channelName
        self.channelType = channelType
        self.content = content
        self.timestamp = timestamp
    }
}

public struct AgentExecutionNoticeRequest: Sendable, Equatable {
    public let commandId: UUID
    public let serverId: String
    public let agentId: String
    /// A real channel id for the onboarding opener, or an upstream synthetic
    /// label such as `onboarding-context`. Admission never reads a channel row.
    public let channelId: String
    public let channelName: String
    public let channelType: String
    public let content: String
    public let messageId: String
    /// ISO-8601 text from the caller's clock. The body carries this exact
    /// wake time; a retried outbox entry never invents a newer one.
    public let timestamp: String
    public init(commandId: UUID = UUID(), serverId: String, agentId: String, channelId: String,
                channelName: String, channelType: String, content: String, messageId: String,
                timestamp: String) {
        self.commandId = commandId
        self.serverId = serverId
        self.agentId = agentId
        self.channelId = channelId
        self.channelName = channelName
        self.channelType = channelType
        self.content = content
        self.messageId = messageId
        self.timestamp = timestamp
    }
}

/// Why a transient notice was not admitted. A dropped notice is the honest
/// "the briefing did not happen" receipt: the caller must not stamp the
/// one-shot sent fact, so the next activation retries. It is never a queued
/// delivery and never starts or wakes a dead agent.
public enum AgentExecutionNoticeDropReason: String, Codable, Sendable, Equatable {
    case transactionRequired
    case agentUnavailable
    case machineNotReady
    case agentNotRunning
    case manuallyStopped
    case manualRecovery
    case resetInProgress
    case targetUnavailable
    case conflictingCommand
}

/// The delivery receipt a briefing trigger consumes. `accepted` means the
/// notice and its outbox reference were staged in the caller's durable
/// transaction for an agent with a live launch; it does not prove the daemon
/// consumed it (upstream's `queued` receipt makes the same distinction).
public enum AgentExecutionNoticeReceipt: Sendable, Equatable {
    case accepted(commandId: UUID)
    case dropped(AgentExecutionNoticeDropReason)
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
    public enum Kind: String, Codable, Sendable { case start, delivery, notice, stop }
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
    /// Transient notice body. Absent for start/delivery/stop commands and for
    /// every snapshot written before notices existed.
    public let notice: AgentExecutionNotice?
    /// The formal agent mention this delivery is tracked against. Absent for
    /// every non-mention delivery, for an untracked fallback (the occurrence was
    /// abandoned because its daemon identity was unknown) and for every snapshot
    /// written before the occurrence spine. The decision itself is recorded from
    /// the materializer immediately before the wire send.
    public var mentionDeliveryOccurrenceId: String? = nil
    public var status: Status
    public let createdAt: Date

    public var admission: AgentExecutionAdmission {
        AgentExecutionAdmission(commandId: commandId, launchId: launchId,
                                startDispatchId: startDispatchId, deliveryId: deliveryId)
    }
}
