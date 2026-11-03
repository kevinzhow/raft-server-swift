import Foundation

/// Owns messages accepted while an agent is between "wake accepted" and
/// "runtime can receive input". I1: every pending key belongs to the current
/// start-state snapshot; I2: a buffered wake is delivered exactly once
/// (rebind appends, spawn drains and clears, suppression removes consumed).
/// Ported from the upstream daemon buffer.
public struct PendingDeliveryMessage: Sendable, Equatable {
    public var messageId: String
    public var content: String
    public init(messageId: String, content: String) {
        self.messageId = messageId
        self.content = content
    }
}

public struct StartStateSnapshot: Sendable {
    public var queuedAgentIds: [String]
    public var startingAgentIds: [String]
    public var terminalRecoveryAgentIds: [String]
    public var cooldownAgentIds: [String]
    public init(
        queuedAgentIds: [String] = [], startingAgentIds: [String] = [],
        terminalRecoveryAgentIds: [String] = [], cooldownAgentIds: [String] = []
    ) {
        self.queuedAgentIds = queuedAgentIds
        self.startingAgentIds = startingAgentIds
        self.terminalRecoveryAgentIds = terminalRecoveryAgentIds
        self.cooldownAgentIds = cooldownAgentIds
    }
}

public final class AgentStartPendingDeliveryBuffer {
    private var pending: [String: [PendingDeliveryMessage]] = [:]

    public init() {}

    public func count(_ agentId: String) -> Int { pending[agentId]?.count ?? 0 }
    public func has(_ agentId: String) -> Bool { pending[agentId] != nil }
    public var size: Int { pending.count }
    public func agentIds() -> [String] { Array(pending.keys) }

    /// A snapshot copy; mutating it cannot change the owner.
    public func values(_ agentId: String) -> [PendingDeliveryMessage] { pending[agentId] ?? [] }

    @discardableResult
    public func bufferDuringStart(_ agentId: String, _ message: PendingDeliveryMessage) -> Int {
        append(agentId, [message])
    }

    @discardableResult
    public func bufferMessagesDuringStart(_ agentId: String, _ messages: [PendingDeliveryMessage]) -> Int {
        append(agentId, messages)
    }

    /// Appends the previous wake instead of replacing pending delivery when the
    /// wake is rebound (DROP regression).
    @discardableResult
    public func rebindWake(
        _ agentId: String,
        previousWake: PendingDeliveryMessage?,
        nextWake: PendingDeliveryMessage?,
        sameWake: (PendingDeliveryMessage, PendingDeliveryMessage) -> Bool
    ) -> Int {
        guard let previousWake, let nextWake, !sameWake(previousWake, nextWake) else { return count(agentId) }
        return append(agentId, [previousWake])
    }

    /// Returns each pending wake once and clears the owner buffer (DUP regression).
    @discardableResult
    public func drainOnSpawn(_ agentId: String) -> [PendingDeliveryMessage] {
        let messages = pending[agentId] ?? []
        pending[agentId] = nil
        try? assertInternalInvariants("drainOnSpawn")
        return messages
    }

    public func cancelStart(_ agentId: String) {
        pending[agentId] = nil
        try? assertInternalInvariants("cancelStart")
    }

    public func cancelAllStarts() {
        pending = [:]
        try? assertInternalInvariants("cancelAllStarts")
    }

    @discardableResult
    public func suppressConsumed(_ agentId: String, predicate: (PendingDeliveryMessage) -> Bool) -> Int {
        guard let messages = pending[agentId], !messages.isEmpty else { return 0 }
        var removed = 0
        let retained = messages.filter { message in
            if predicate(message) {
                removed += 1
                return false
            }
            return true
        }
        pending[agentId] = retained.isEmpty ? nil : retained
        try? assertInternalInvariants("suppressConsumed")
        return removed
    }

    @discardableResult
    public func purge(_ agentId: String, predicate: (PendingDeliveryMessage) -> Bool) -> Int {
        suppressConsumed(agentId, predicate: predicate)
    }

    /// I1 membership: every pending key must belong to the start-state snapshot.
    public func assertInvariants(_ context: String, snapshot: StartStateSnapshot) throws {
        try assertInternalInvariants(context)
        let allowed = Set(
            snapshot.queuedAgentIds + snapshot.startingAgentIds
                + snapshot.terminalRecoveryAgentIds + snapshot.cooldownAgentIds
        )
        for agentId in pending.keys where !allowed.contains(agentId) {
            throw PendingDeliveryInvariantViolation(
                message: "Agent start pending delivery invariant violation after \(context): pending messages for non-starting agent \(agentId)"
            )
        }
    }

    private func append(_ agentId: String, _ messages: [PendingDeliveryMessage]) -> Int {
        guard !messages.isEmpty else { return count(agentId) }
        pending[agentId, default: []].append(contentsOf: messages)
        try? assertInternalInvariants("append")
        return count(agentId)
    }

    private func assertInternalInvariants(_ context: String) throws {
        for (agentId, messages) in pending {
            if agentId.isEmpty {
                throw PendingDeliveryInvariantViolation(
                    message: "Agent start pending delivery invariant violation after \(context): empty agent id"
                )
            }
            if messages.isEmpty {
                throw PendingDeliveryInvariantViolation(
                    message: "Agent start pending delivery invariant violation after \(context): empty pending buffer for \(agentId)"
                )
            }
        }
    }
}

public struct PendingDeliveryInvariantViolation: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
    public init(message: String) { self.message = message }
}
