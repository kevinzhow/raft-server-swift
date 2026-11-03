import Foundation

/// Manager-level facts for an agent with no live process: whether a wake may
/// restart, buffer for a queued/starting spawn, wait out cooldown, wait for
/// terminal recovery, or is hard inactive. Ported from the upstream daemon.
public struct AgentNoProcessResidencySnapshot: Sendable {
    public var runningAgentIds: [String]
    public var queuedAgentIds: [String]
    public var startingAgentIds: [String]
    public var idleAgentIds: [String]
    public var terminalFailureAgentIds: [String]
    public var activeCooldownAgentIds: [String]
    public var fingerprintFenceAgentIds: [String]
    public var pendingDeliveryAgentIds: [String]

    public init(
        runningAgentIds: [String] = [], queuedAgentIds: [String] = [], startingAgentIds: [String] = [],
        idleAgentIds: [String] = [], terminalFailureAgentIds: [String] = [], activeCooldownAgentIds: [String] = [],
        fingerprintFenceAgentIds: [String] = [], pendingDeliveryAgentIds: [String] = []
    ) {
        self.runningAgentIds = runningAgentIds
        self.queuedAgentIds = queuedAgentIds
        self.startingAgentIds = startingAgentIds
        self.idleAgentIds = idleAgentIds
        self.terminalFailureAgentIds = terminalFailureAgentIds
        self.activeCooldownAgentIds = activeCooldownAgentIds
        self.fingerprintFenceAgentIds = fingerprintFenceAgentIds
        self.pendingDeliveryAgentIds = pendingDeliveryAgentIds
    }
}

public struct StartPendingAllowedSnapshot: Sendable, Equatable {
    public var queuedAgentIds: [String]
    public var startingAgentIds: [String]
    public var terminalRecoveryAgentIds: [String]
    public var cooldownAgentIds: [String]

    public init(queuedAgentIds: [String], startingAgentIds: [String], terminalRecoveryAgentIds: [String], cooldownAgentIds: [String]) {
        self.queuedAgentIds = queuedAgentIds
        self.startingAgentIds = startingAgentIds
        self.terminalRecoveryAgentIds = terminalRecoveryAgentIds
        self.cooldownAgentIds = cooldownAgentIds
    }
}

public struct AgentResidencyInvariantViolation: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
    public init(message: String) { self.message = message }
}

public enum AgentNoProcessResidency {
    public static func allowedStartPendingSnapshot(_ snapshot: AgentNoProcessResidencySnapshot) -> StartPendingAllowedSnapshot {
        let idle = Set(snapshot.idleAgentIds)
        return StartPendingAllowedSnapshot(
            queuedAgentIds: snapshot.queuedAgentIds,
            startingAgentIds: snapshot.startingAgentIds,
            terminalRecoveryAgentIds: snapshot.terminalFailureAgentIds,
            cooldownAgentIds: snapshot.activeCooldownAgentIds.filter { idle.contains($0) }
        )
    }

    /// I1 cooldown is wakeable only with idle config; I2 terminal excludes
    /// auto-restart; I3 terminal excludes running; I4 pending has residency;
    /// I5 a fingerprint fence is evidence, not residency.
    public static func assertInvariants(_ context: String, _ snapshot: AgentNoProcessResidencySnapshot) throws {
        let running = Set(snapshot.runningAgentIds)
        let idle = Set(snapshot.idleAgentIds)
        let terminal = Set(snapshot.terminalFailureAgentIds)
        let queued = Set(snapshot.queuedAgentIds)
        let starting = Set(snapshot.startingAgentIds)

        for agentId in snapshot.activeCooldownAgentIds where !idle.contains(agentId) {
            throw AgentResidencyInvariantViolation(message: "Agent no-process residency invariant violation after \(context): active cooldown without restart config for \(agentId)")
        }
        for agentId in terminal {
            if idle.contains(agentId) {
                throw AgentResidencyInvariantViolation(message: "Agent no-process residency invariant violation after \(context): terminal failure and idle restart config both present for \(agentId)")
            }
            if running.contains(agentId) {
                throw AgentResidencyInvariantViolation(message: "Agent no-process residency invariant violation after \(context): terminal failure while process is still registered for \(agentId)")
            }
        }
        let allowedPending = allowedStartPendingSnapshot(snapshot)
        let allowed = Set(
            allowedPending.queuedAgentIds + allowedPending.startingAgentIds
                + allowedPending.terminalRecoveryAgentIds + allowedPending.cooldownAgentIds
        )
        for agentId in snapshot.pendingDeliveryAgentIds where !allowed.contains(agentId) {
            throw AgentResidencyInvariantViolation(message: "Agent no-process residency invariant violation after \(context): pending delivery without queued/starting/terminal/cooldown residency for \(agentId)")
        }
        for agentId in snapshot.fingerprintFenceAgentIds
        where !running.contains(agentId) && !idle.contains(agentId) && !terminal.contains(agentId) {
            throw AgentResidencyInvariantViolation(message: "Agent no-process residency invariant violation after \(context): fingerprint fence without running process, idle retry config, or terminal failure for \(agentId)")
        }
        for agentId in queued where starting.contains(agentId) {
            throw AgentResidencyInvariantViolation(message: "Agent no-process residency invariant violation after \(context): queued and starting facts overlap for \(agentId)")
        }
    }
}

// MARK: - exported transition rows

public struct ResidencyTransitionIdentity: Sendable {
    public var agentId: String
    public var agentLaunchId: String
    public var agentLaunchIdPresent: Bool
    public var serverId: String
    public var machineId: String
    public var runtime: String
    public var driver: String
    public var launchSource: String
    public init(
        agentId: String, agentLaunchId: String, agentLaunchIdPresent: Bool, serverId: String,
        machineId: String, runtime: String, driver: String, launchSource: String
    ) {
        self.agentId = agentId
        self.agentLaunchId = agentLaunchId
        self.agentLaunchIdPresent = agentLaunchIdPresent
        self.serverId = serverId
        self.machineId = machineId
        self.runtime = runtime
        self.driver = driver
        self.launchSource = launchSource
    }
}

public struct ResidencyTransitionEnter: Sendable {
    public var identity: ResidencyTransitionIdentity
    public var state: String
    public var isWaitState: Bool
    public var fenceKind: String?
    public var deadlineUnixMs: Int?
    public var failureKind: String?
    public var negativeEvidenceBucket: String?
    public init(
        identity: ResidencyTransitionIdentity, state: String, isWaitState: Bool, fenceKind: String? = nil,
        deadlineUnixMs: Int? = nil, failureKind: String? = nil, negativeEvidenceBucket: String? = nil
    ) {
        self.identity = identity
        self.state = state
        self.isWaitState = isWaitState
        self.fenceKind = fenceKind
        self.deadlineUnixMs = deadlineUnixMs
        self.failureKind = failureKind
        self.negativeEvidenceBucket = negativeEvidenceBucket
    }
}

public struct ResidencyTransitionClose: Sendable {
    public var closeResult: String
    public var failureKind: String?
    public var negativeEvidenceBucket: String?
    public init(closeResult: String, failureKind: String? = nil, negativeEvidenceBucket: String? = nil) {
        self.closeResult = closeResult
        self.failureKind = failureKind
        self.negativeEvidenceBucket = negativeEvidenceBucket
    }
}

public struct ResidencyTransitionRow: Sendable, Equatable {
    public var spanName = "launch_residency_transition"
    public var phase = "process_residency"
    public var agentLaunchId: String
    public var agentId: String
    public var serverId: String
    public var machineId: String
    public var runtime: String
    public var driver: String
    public var launchSource: String
    public var stateInstanceId: String
    public var residencyStateInstanceId: String
    public var transitionSeq: Int
    public var residencyTransitionSeq: Int
    public var transitionKind: String
    public var state: String
    public var residency: String
    public var agentLaunchIdPresent: Bool
    public var phaseResult: String?
    public var isWaitState: Bool?
    public var fenceKind: String?
    public var deadlineUnixMs: Int?
    public var closeResult: String?
    public var failureKind: String?
    public var negativeEvidenceBucket: String?
}

public final class AgentNoProcessResidencyTransitions {
    private struct OpenTransition {
        var identity: ResidencyTransitionIdentity
        var state: String
        var stateInstanceId: String
        var isWaitState: Bool
        var fenceKind: String?
        var deadlineUnixMs: Int?
        var failureKind: String?
        var negativeEvidenceBucket: String?
    }

    private var open: [String: OpenTransition] = [:]
    private var transitionSeq = 0

    public init() {}

    public func enter(_ input: ResidencyTransitionEnter) -> [ResidencyTransitionRow] {
        let agentId = input.identity.agentId
        var rows: [ResidencyTransitionRow] = []
        if let existing = open[agentId] {
            if existing.state == input.state, existing.identity.agentLaunchId == input.identity.agentLaunchId {
                return []
            }
            rows.append(closeRow(existing, .init(closeResult: "advanced")))
        }
        let current = OpenTransition(
            identity: input.identity, state: input.state, stateInstanceId: UUID().uuidString.lowercased(),
            isWaitState: input.isWaitState, fenceKind: input.fenceKind,
            deadlineUnixMs: input.deadlineUnixMs, failureKind: input.failureKind,
            negativeEvidenceBucket: input.negativeEvidenceBucket
        )
        open[agentId] = current
        rows.append(enterRow(current))
        return rows
    }

    public func close(agentId: String, _ input: ResidencyTransitionClose) -> [ResidencyTransitionRow] {
        guard let existing = open[agentId] else { return [] }
        open[agentId] = nil
        return [closeRow(existing, input)]
    }

    private func enterRow(_ open: OpenTransition) -> ResidencyTransitionRow {
        baseRow(open, kind: "enter", phaseResult: "entered", closeResult: nil,
                failureKind: open.failureKind, negativeEvidenceBucket: open.negativeEvidenceBucket)
    }

    private func closeRow(_ open: OpenTransition, _ input: ResidencyTransitionClose) -> ResidencyTransitionRow {
        baseRow(open, kind: "close", phaseResult: nil, closeResult: input.closeResult,
                failureKind: input.failureKind ?? open.failureKind,
                negativeEvidenceBucket: input.negativeEvidenceBucket ?? open.negativeEvidenceBucket)
    }

    private func baseRow(
        _ open: OpenTransition, kind: String, phaseResult: String?, closeResult: String?,
        failureKind: String?, negativeEvidenceBucket: String?
    ) -> ResidencyTransitionRow {
        transitionSeq += 1
        let seq = transitionSeq
        return ResidencyTransitionRow(
            agentLaunchId: open.identity.agentLaunchId,
            agentId: open.identity.agentId,
            serverId: open.identity.serverId,
            machineId: open.identity.machineId,
            runtime: open.identity.runtime,
            driver: open.identity.driver,
            launchSource: open.identity.launchSource,
            stateInstanceId: open.stateInstanceId,
            residencyStateInstanceId: open.stateInstanceId,
            transitionSeq: seq,
            residencyTransitionSeq: seq,
            transitionKind: kind,
            state: open.state,
            residency: open.state,
            agentLaunchIdPresent: open.identity.agentLaunchIdPresent,
            phaseResult: phaseResult,
            isWaitState: open.isWaitState,
            fenceKind: open.fenceKind,
            deadlineUnixMs: open.deadlineUnixMs,
            closeResult: closeResult,
            failureKind: failureKind,
            negativeEvidenceBucket: negativeEvidenceBucket
        )
    }
}
