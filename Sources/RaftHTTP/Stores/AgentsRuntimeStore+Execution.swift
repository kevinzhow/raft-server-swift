import Foundation

/// Codable business facts inside the retained Agents owner. No transport,
/// credential, provider key or mutable Store escapes through this record.
struct AgentExecutionState: Codable, Sendable {
    var connections: [String: AgentExecutionConnection] = [:]
    var agents: [String: AgentExecutionAgent] = [:]
    var commands: [String: AgentExecutionCommand] = [:]
    var receipts: [String: String] = [:]
    var watermarks: [String: Int64] = [:]
    /// Optional for snapshots written before production dispatch was connected.
    var dispatches: [String: AgentExecutionDispatch]?
    /// Optional additions preserve decoding of snapshots predating manual stop.
    /// These facts do not require a machine, launch, process or socket receipt.
    var stopIntents: [String: AgentExecutionStopIntent]?
    var heldDeliveries: [String: AgentExecutionHeldDelivery]?
    /// Human messages accepted while the recipient was not deliverable. The
    /// canonical message row is the durable inbox; this owner records the
    /// pending delivery so a later machine `ready` releases it through the
    /// ordinary strict delivery path exactly once.
    var pendingHumanDeliveries: [String: AgentExecutionPendingDelivery]?
    /// Optional to decode every snapshot predating durable reset.
    var resetIntents: [String: AgentExecutionResetIntent]?

    /// Called inside the same Agents owner borrow as the assignment write.
    /// A nil authority is the legacy Bool entry: it cannot move tracked execution.
    mutating func prepareNeverLaunchedAssignment(agentId: String, serverId: String?, machineId: String?,
                                                targetServerId: String?, bindingChanged: Bool) -> Bool {
        let history = commands.values.filter { $0.agentId == agentId }
        guard var owner = agents[agentId] else { return history.isEmpty }
        let movingContext = bindingChanged || machineId.map { $0 != owner.machineId } == true
        if !movingContext { return true }
        guard let serverId, owner.serverId == serverId,
              machineId == nil || targetServerId == serverId,
              owner.currentLaunchId == nil, owner.launches.isEmpty, owner.processes.isEmpty,
              owner.generation == 0, owner.sessionId == nil, owner.needsManual == nil,
              owner.takeoverEpoch >= 0, owner.takeoverEpoch < 9_007_199_254_740_991,
              (stopIntents ?? [:]).values.contains(where: {
                  $0.agentId == agentId && $0.serverId == serverId && $0.clearedByHumanStart == nil
              }),
              history.allSatisfy({ command in
                  guard command.kind == .stop, command.serverId == serverId,
                        command.breakerGeneration == 0,
                        command.status == .pending || command.status == .superseded,
                        dispatches?[command.commandId.uuidString] == nil,
                        let receipt = stopIntents?[command.commandId.uuidString] else { return false }
                  return receipt.agentId == agentId && receipt.serverId == serverId && receipt.machineId == command.machineId
              }) else { return false }
        owner.takeoverEpoch += 1
        if let machineId { owner.machineId = machineId }
        for command in history {
            let key = command.commandId.uuidString
            commands[key]?.status = .superseded
            if stopIntents?[key]?.retiredByAssignmentEpoch == nil {
                stopIntents?[key]?.retiredByAssignmentEpoch = owner.takeoverEpoch
            }
        }
        agents[agentId] = owner
        return true
    }

    mutating func fenceAfterRestore() {
        if var resets = resetIntents {
            for key in Array(resets.keys) {
                guard var reset = resets[key], reset.phase.isActive, reset.connectionEpochId != nil else { continue }
                if reset.stopAttempt == .attempting { reset.stopAttempt = .ambiguous }
                if reset.workspaceAttempt == .attempting { reset.workspaceAttempt = .ambiguous }
                reset.phase = .held
                reset.holdReason = "server_restarted_with_unsettled_reset"
                resets[key] = reset
                if agents[reset.agentId]?.serverId == reset.serverId,
                   agents[reset.agentId]?.generation == reset.expectedGeneration,
                   agents[reset.agentId]?.machineId == reset.machineId {
                    agents[reset.agentId]?.needsManual = "server_restarted_with_unsettled_reset"
                }
            }
            resetIntents = resets
        }
        for key in Array(connections.keys) {
            connections[key]?.online = false
            connections[key]?.ready = false
        }
        for key in Array(agents.keys) {
            if agents[key]?.hasUnsettledExecution == true {
                agents[key]?.needsManual = "server_restarted_with_unsettled_execution"
            }
        }
        for (key, dispatch) in dispatches ?? [:] where dispatch.phase == .attempting || dispatch.phase == .ambiguous {
            guard let command = commands[key], command.kind != .notice,
                  agents[command.agentId]?.currentLaunchId == command.launchId,
                  agents[command.agentId]?.generation == command.breakerGeneration else { continue }
            agents[command.agentId]?.needsManual = "server_restarted_with_unsettled_dispatch"
        }
    }

    static func key(_ parts: String...) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

struct AgentExecutionStopIntent: Codable, Sendable {
    let commandId: UUID
    let serverId: String
    let agentId: String
    let machineId: String?
    let createdAt: Date
    var clearedByHumanStart: UUID?
    /// Only an atomic, proven never-launched assignment may retire an unsent
    /// stop. The original target and receipt remain; the epoch fences replay.
    var retiredByAssignmentEpoch: Int64? = nil

    var admission: AgentExecutionStopAdmission {
        .init(commandId: commandId, requiresMachineDispatch: machineId != nil)
    }
}

/// A human message queued because its recipient agent's machine was offline (or
/// the agent was unassigned) at commit time. `releasedCommandId` links the one
/// strict delivery attempt staged when the machine becomes ready.
struct AgentExecutionPendingDelivery: Codable, Sendable {
    let serverId: String
    let agentId: String
    let channelId: String
    let messageId: String
    let createdAt: Date
    var releasedCommandId: UUID?
}

/// A real delivery request held without inventing a launch or daemon admission.
/// releasedCommandId links its later, separately fenced attempt; history remains.
struct AgentExecutionHeldDelivery: Codable, Sendable {
    let commandId: UUID
    let serverId: String
    let agentId: String
    let channelId: String
    let messageId: String
    let createdAt: Date
    var releasedCommandId: UUID?
    var cancelled = false
}

struct AgentExecutionConnection: Codable, Sendable {
    let serverId: String
    let connectionEpochId: String
    var online: Bool
    var ready: Bool
    var daemonInstanceId: String?
    var runtimes: Set<String>
    var capabilities: Set<String>?
}

struct AgentExecutionAgent: Codable, Sendable {
    let serverId: String
    var machineId: String
    var currentLaunchId: String?
    var sessionId: String?
    var takeoverEpoch: Int64 = 0
    var generation: Int64 = 0
    var needsManual: String?
    var failureCount: Int = 0
    var sameFingerprint: String?
    var sameFingerprintCount: Int = 0
    var backoffStep: Int = 0
    var blockedUntil: Date?
    var probeLaunchId: String?
    var probeExpiresAt: Date?
    var launches: [String: AgentExecutionLaunch] = [:]
    var processes: [String: AgentExecutionProcess] = [:]

    /// A launch whose turn has not completed is in flight (or its start result
    /// is still unknown), and a delivery the daemon acknowledged on a resident
    /// launch whose turn has not been observed complete is also in flight. A
    /// process that stays alive between turns is the upstream idle runtime, not
    /// an in-flight turn, so it is not unsettled by itself:
    /// `connectionClosed`/restore must not turn an idle agent into manual
    /// recovery merely because its long-lived process survived.
    var hasUnsettledExecution: Bool {
        launches.values.contains {
            (!$0.completed && !$0.notSpawned) || $0.inFlightDeliveryCommandIds?.isEmpty == false
        }
    }
}

extension AgentExecutionState {
    /// A delivery the daemon acknowledged on a launch whose turn the server has
    /// not observed complete. A resident runtime keeps one launch across turns,
    /// so this retained set (not `launch.completed`) is the in-flight-turn fact.
    func hasAcceptedTurnWithoutCompletion(agentId: String) -> Bool {
        guard let agent = agents[agentId] else { return false }
        return commands.values.contains { command in
            guard command.agentId == agentId, command.kind == .delivery, command.status == .accepted,
                  let launch = agent.launches[command.launchId] else { return false }
            return launch.inFlightDeliveryCommandIds?.contains(command.commandId) == true
        }
    }

    /// A command write was attempted without a durable daemon acknowledgement.
    /// A `.pending` delivery without a dispatch record is provably unsent; it
    /// is retryable rather than ambiguous.
    func hasUnsettledDeliveryWrite(agentId: String) -> Bool {
        commands.contains { key, command in
            // A transient onboarding notice never blocks agent recovery: its
            // own sent fact is stamped elsewhere and the wake is lost.
            guard command.agentId == agentId, command.kind != .notice else { return false }
            if let dispatch = dispatches?[key] { return dispatch.phase != .accepted }
            return command.kind == .delivery && command.status == .dispatched
        }
    }
}

struct AgentExecutionLaunch: Codable, Sendable {
    let launchId: String
    let startDispatchId: String
    let daemonInstanceId: String
    let connectionEpochId: String
    let generation: Int64
    let takeoverEpoch: Int64
    var startAccepted = false
    var processInstanceId: String?
    var completed = false
    var notSpawned = false
    var terminalFailure = false
    var stopRequested = false
    var runnerCredentialId: String?
    /// Deliveries the daemon acknowledged on this launch without a later
    /// observed turn completion. A resident `codex app-server` keeps carrying
    /// the same launch across turns, so this set (cleared by `turn_completed`
    /// or a terminal turn) is the only retained in-flight-turn evidence.
    var inFlightDeliveryCommandIds: Set<UUID>?
}

struct AgentExecutionProcess: Codable, Sendable {
    let processInstanceId: String
    let daemonInstanceId: String
    /// nil means an internal daemon respawn had no server launch at birth.
    let spawnLaunchId: String?
    var launchIds: Set<String>
    var exited = false
}

struct AgentExecutionDispatch: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case attempting, written, accepted, ambiguous }
    let connectionEpochId: String
    let deliverySequence: Int64?
    var phase: Phase
}
