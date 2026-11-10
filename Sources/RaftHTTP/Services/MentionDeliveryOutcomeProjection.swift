import Foundation

/// Upstream `projectMentionDeliveryForSender` over the facts this port retains.
///
/// The canonical message row is the durable agent inbox, so a formal mention is
/// already readable once it is committed. The execution owner adds the real
/// delivery facts: at most one strict attempt per (agent, message), the durable
/// pending-delivery queue for an owed wake, and a held delivery behind a manual
/// stop. A mention with none of those facts (and no terminal code) is `unknown`:
/// the same state upstream reports as an instrumentation failure, never a
/// fabricated `delivered` or `pending`.
public enum MentionDeliveryOutcome: Equatable, Sendable {
    case delivered
    case pending
    case lost(reasonCategory: String)
    case unknown
}

struct MentionDeliveryOutcomeProjection: Sendable {
    private let delivered: Set<String>
    private let pending: Set<String>

    init(execution: AgentExecutionState) {
        var delivered: Set<String> = []
        var pending: Set<String> = []
        for command in execution.commands.values where command.kind == .delivery {
            guard let messageId = command.messageId else { continue }
            let key = Self.key(command.agentId, messageId)
            if command.status == .accepted { delivered.insert(key) } else { pending.insert(key) }
        }
        for entry in (execution.pendingHumanDeliveries ?? [:]).values {
            pending.insert(Self.key(entry.agentId, entry.messageId))
        }
        for entry in (execution.heldDeliveries ?? [:]).values where !entry.cancelled {
            pending.insert(Self.key(entry.agentId, entry.messageId))
        }
        self.delivered = delivered
        self.pending = pending
    }

    /// A terminal code is the daemon's real permanent refusal; it outranks an
    /// earlier attempt. `INSTRUMENT_FAILED` answers "the instrument broke", so it
    /// stays `unknown` rather than claiming the target's seat was lost.
    func outcome(agentId: String, messageId: String, terminalCode: String?) -> MentionDeliveryOutcome {
        if let terminalCode {
            guard terminalCode != "INSTRUMENT_FAILED" else { return .unknown }
            return .lost(reasonCategory: Self.category(terminalCode))
        }
        let key = Self.key(agentId, messageId)
        if delivered.contains(key) { return .delivered }
        if pending.contains(key) { return .pending }
        return .unknown
    }

    /// The closed category table from `senderMentionDeliveryProjection.ts`.
    static func category(_ terminalCode: String) -> String {
        switch terminalCode {
        case "QUOTA_LIMITED": "quota"
        case "DELIVERY_REJECTED": "runtime_error"
        default: "unclassified"
        }
    }

    private static func key(_ agentId: String, _ messageId: String) -> String {
        "\(agentId)\u{0}\(messageId)"
    }
}
