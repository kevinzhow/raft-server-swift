import Foundation

public enum AgentExecutionResetMode: String, Codable, Sendable { case restart, session, full }
public enum AgentExecutionResetPhase: String, Codable, Sendable { case stop, workspace, restart }

/// Server-selected reset policy. Missing policy in historical rows retains the
/// public human-reset behavior; explicit `none` must never become human takeover.
public enum AgentExecutionResetTerminalControl: String, Codable, Sendable {
    case none
    case runtimeConfigChanged = "runtime_config_changed"
    case humanReset = "human_reset"
}

public struct AgentExecutionResetPolicy: Codable, Sendable, Equatable {
    public var terminalControl: AgentExecutionResetTerminalControl
    /// Strengthening a coalesced restart does not rewrite its original mode/ID.
    public var sessionRequired: Bool
    public init(terminalControl: AgentExecutionResetTerminalControl, sessionRequired: Bool = false) {
        self.terminalControl = terminalControl; self.sessionRequired = sessionRequired
    }
}

public struct AgentExecutionResetRequest: Sendable {
    public let operationId: UUID
    public let serverId: String
    public let agentId: String
    public let mode: AgentExecutionResetMode
    public let restart: Bool
    public let policy: AgentExecutionResetPolicy?
    /// Only an already-authorized control/settings producer may select policy.
    /// The public reset route keeps its original defaults and omitted policy.
    public init(operationId: UUID = UUID(), serverId: String, agentId: String,
                mode: AgentExecutionResetMode, restart: Bool = true, policy: AgentExecutionResetPolicy? = nil) {
        self.operationId = operationId; self.serverId = serverId; self.agentId = agentId
        self.mode = mode; self.restart = restart; self.policy = policy
    }
}

public struct AgentExecutionResetAdmission: Sendable, Equatable {
    public let operationId: UUID
    public let requiresMachineDispatch: Bool
}

struct AgentExecutionReferenceCodingKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

/// This shape deliberately has no commandId. Exact keys and codec prohibit
/// cross-decoding mixed reset/normal envelopes under the existing outbox kind.
public struct AgentExecutionResetReference: Codable, Sendable, Equatable {
    public let codec: String
    public let resetOperationId: UUID
    public let phase: AgentExecutionResetPhase
    public let phaseId: UUID
    public init(resetOperationId: UUID, phase: AgentExecutionResetPhase, phaseId: UUID) {
        codec = "raft-agent-reset-phase-v1"
        self.resetOperationId = resetOperationId; self.phase = phase; self.phaseId = phaseId
    }
    enum CodingKeys: String, CodingKey { case codec, resetOperationId, phase, phaseId }
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: AgentExecutionReferenceCodingKey.self)
        guard Set(raw.allKeys.map(\.stringValue)) == Set(["codec", "resetOperationId", "phase", "phaseId"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid reset reference keys"))
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        codec = try fields.decode(String.self, forKey: .codec)
        guard codec == "raft-agent-reset-phase-v1" else {
            throw DecodingError.dataCorruptedError(forKey: .codec, in: fields, debugDescription: "Unsupported reset reference codec")
        }
        resetOperationId = try fields.decode(UUID.self, forKey: .resetOperationId)
        phase = try fields.decode(AgentExecutionResetPhase.self, forKey: .phase)
        phaseId = try fields.decode(UUID.self, forKey: .phaseId)
    }
}

public struct AgentExecutionResetControl: Sendable, Equatable {
    public let reference: AgentExecutionResetReference
    public let context: AgentExecutionMachineContext
    public let agentId: String
}
public enum AgentExecutionResetResolution: Sendable, Equatable {
    case ready(AgentExecutionResetControl)
    case wait(reason: String)
    case hold(reason: String)
    case settled
    case cancelled
}

public enum AgentExecutionResetDispatchAdmission: Sendable, Equatable {
    case granted, alreadyWritten, cancelled, uncertain
}

enum AgentExecutionResetAttempt: String, Codable, Sendable { case notAttempted, attempting, written, ambiguous }
enum AgentExecutionResetProgress: String, Codable, Sendable {
    case stop, workspace, restart, restartStaged, localOnly, dispatched, held, cancelled
    var isActive: Bool { self == .stop || self == .workspace || self == .restart || self == .held }
}

/// Business facts in the existing retained Agents owner, never a new owner.
/// written proves local socket dispatch only; no cleanup-confirmed state exists
/// because the official workspace-reset protocol has no completion receipt.
struct AgentExecutionResetIntent: Codable, Sendable {
    let operationId: UUID
    let serverId: String
    let agentId: String
    let machineId: String?
    let mode: AgentExecutionResetMode
    let restart: Bool
    let createdAt: Date
    let stopPhaseId: UUID
    let workspacePhaseId: UUID
    let restartPhaseId: UUID
    let startCommandId: UUID
    let sessionPublicationId: UUID
    let priorLaunchId: String?
    var expectedLaunchId: String?
    let priorStopIntentIds: Set<UUID>
    let priorStatus: String
    var expectedGeneration: Int64
    let expectedTakeoverEpoch: Int64
    var connectionEpochId: String?
    var daemonInstanceId: String?
    var phase: AgentExecutionResetProgress
    var stopAttempt: AgentExecutionResetAttempt = .notAttempted
    var workspaceAttempt: AgentExecutionResetAttempt = .notAttempted
    var holdReason: String?
    var cancelledByStopId: UUID?
    var sessionCleared = false
    /// Optional Codable storage omits the key for every historical/public row.
    var policy: AgentExecutionResetPolicy?

    var effectiveMode: AgentExecutionResetMode {
        mode == .full ? .full : policy?.sessionRequired == true ? .session : mode
    }
    var terminalControl: AgentExecutionResetTerminalControl { policy?.terminalControl ?? .humanReset }
    var usesHumanStart: Bool { terminalControl != .none }

    var hasUnconfirmedControl: Bool {
        stopAttempt == .attempting || stopAttempt == .ambiguous || workspaceAttempt == .attempting || workspaceAttempt == .ambiguous
    }
    var admission: AgentExecutionResetAdmission { .init(operationId: operationId, requiresMachineDispatch: machineId != nil) }
    func reference(_ phase: AgentExecutionResetPhase) -> AgentExecutionResetReference {
        .init(resetOperationId: operationId, phase: phase,
              phaseId: phase == .stop ? stopPhaseId : phase == .workspace ? workspacePhaseId : restartPhaseId)
    }
    func attempt(_ phase: AgentExecutionResetPhase) -> AgentExecutionResetAttempt {
        switch phase {
        case .stop: stopAttempt
        case .workspace: workspaceAttempt
        case .restart: self.phase == .restartStaged ? .written : .notAttempted
        }
    }
}
