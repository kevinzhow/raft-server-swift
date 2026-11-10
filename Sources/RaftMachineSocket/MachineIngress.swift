import Foundation

/// These fields come from credential resolution and the live connection, never
/// from daemon-supplied JSON. The epoch is an opaque server-generated string.
public struct MachineIngressContext: Sendable, Equatable {
    public let machineId: String
    public let serverId: String
    public let connectionEpochId: String

    public init(machineId: String, serverId: String, connectionEpochId: String) {
        self.machineId = machineId
        self.serverId = serverId
        self.connectionEpochId = connectionEpochId
    }
}

public struct MachineRuntimeDetection: Decodable, Sendable, Equatable {
    public enum Status: String, Decodable, Sendable { case pending, complete, incomplete }
    public let status: Status
    public let reason: String?
    public let unfinishedRuntimes: [String]?
    public let durationMs: Double?
}

/// A pending ready deliberately omits runtimes. Missing inventory is distinct
/// from an empty completed inventory, including for synchronous older daemons.
public struct MachineDaemonReady: Decodable, Sendable, Equatable {
    public let daemonInstanceId: String?
    public let capabilities: [String]?
    public let runtimes: [String]?
    public let runtimeVersions: [String: String]?
    public let runtimeDetection: MachineRuntimeDetection?
    public let runningAgents: [String]?
    public let runtimeOutcomeUnreliableAgents: [String]?

    public var hasCompleteInventory: Bool {
        guard let daemonInstanceId, !daemonInstanceId.isEmpty,
              let capabilities, capabilities.allSatisfy({ !$0.isEmpty }),
              let runtimes, runtimes.allSatisfy({ !$0.isEmpty }),
              let runningAgents, runningAgents.allSatisfy({ !$0.isEmpty }) else { return false }
        return runtimeDetection == nil || runtimeDetection?.status == .complete
    }
}

/// The original complete JSON is retained for durable semantic validation.
/// Transport decodes only its discriminant and the optional ready inventory;
/// malformed outcome evidence is still delivered to the authorized consumer.
public struct MachineIngressMessage: Sendable {
    public let type: String
    public let payload: Data
    public let ready: MachineDaemonReady?

    init(type: String, payload: Data) {
        self.type = type
        self.payload = payload
        ready = type == "ready" ? (try? JSONDecoder().decode(MachineDaemonReady.self, from: payload)) : nil
    }

    var isOutcomeOutboxEntry: Bool {
        Self.outcomeTypes.contains(type)
    }

    private static let outcomeTypes: Set<String> = [
        "agent:start:outcome", "agent:process_spawned", "agent:process_exited", "agent:runtime:outcome",
        "agent:runtime:outcome_gap", "agent:runtime:outcome_cross_instance_unknown",
    ]
}

/// Only the authorized durable consumer can supply this descriptor, after its
/// ownership checks and state/deduplication/watermark transaction have committed.
public enum MachineOutcomeAcknowledgement: Sendable, Equatable {
    case sequence(agentId: String, daemonInstanceId: String, clientSeq: Int64)
    case marker(agentId: String, gapId: String)

    func encoded() throws -> Data {
        struct Wire: Encodable {
            let type = "agent:outcome:ack"
            let agentId: String
            var daemonInstanceId: String?
            var clientSeq: Int64?
            var gapId: String?
        }
        let wire: Wire
        switch self {
        case .sequence(let agentId, let daemon, let sequence):
            guard !agentId.isEmpty, !daemon.isEmpty, sequence >= 0, sequence <= 9_007_199_254_740_991 else {
                throw MachineCommandError.protocolViolation
            }
            wire = Wire(agentId: agentId, daemonInstanceId: daemon, clientSeq: sequence)
        case .marker(let agentId, let gapId):
            guard !agentId.isEmpty, !gapId.isEmpty else { throw MachineCommandError.protocolViolation }
            wire = Wire(agentId: agentId, gapId: gapId)
        }
        return try JSONEncoder().encode(wire)
    }
}

public enum MachineIngressCommitResult: Sendable, Equatable {
    case hold(reason: String)
    case committed(ack: MachineOutcomeAcknowledgement?)
}

/// Durable mode requires the full lifecycle, including ready/inventory and
/// session/status/activity/profile projection through onMessage. A thrown
/// callback holds evidence without ACK, allowing the daemon's outbox to retry.
public struct MachineDurableIngress: Sendable {
    public typealias Opened = @Sendable (MachineIngressContext) async throws -> Void
    public typealias Message = @Sendable (MachineIngressContext, MachineIngressMessage) async throws -> MachineIngressCommitResult
    public typealias Closed = @Sendable (MachineIngressContext) async throws -> Void
    let onOpened: Opened
    let onMessage: Message
    let onClosed: Closed

    public init(onOpened: @escaping Opened, onMessage: @escaping Message, onClosed: @escaping Closed) {
        self.onOpened = onOpened
        self.onMessage = onMessage
        self.onClosed = onClosed
    }
}

func machineIngressCapabilities(_ requested: [String], durable: Bool) -> [String] {
    let outcome = "agent:runtime-outcome-ack-v1"
    let spawn = "agent:start-spawn-error-v1"
    let base = requested.filter { $0 != outcome && $0 != spawn }
    return durable ? [outcome, spawn] + base : base
}
