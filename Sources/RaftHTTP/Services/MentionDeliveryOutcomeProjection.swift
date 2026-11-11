import Foundation

/// Upstream `senderMentionDeliveryProjection.ts` over the durable occurrence
/// spine. This is a projection of retained receipts, never a guess from
/// unrelated delivery facts:
///
/// - `delivered` is the daemon ACK after `daemon_drained`.
/// - `pending` is a broken hop (in flight; a terminal row would be `lost`).
/// - `lost` is a terminal daemon/server code with its closed category.
/// - `unknown` is an instrumentation failure or a missing occurrence.
public enum MentionDeliveryOutcome: Equatable, Sendable {
    case delivered
    case pending
    case lost(reasonCategory: String)
    case unknown
}

enum MentionDeliverySenderProjection {
    /// The closed category table. A code that is not one of the three
    /// seat-availability causes is deliberately `unclassified`: saying `quota`
    /// would send the sender to wait for a reset that does not exist.
    static func category(_ terminalCode: String) -> String {
        switch terminalCode {
        case "QUOTA_LIMITED": "quota"
        case "DELIVERY_REJECTED": "runtime_error"
        default: "unclassified"
        }
    }

    /// `projectMentionDeliveryForSender(targetHandle, result)`.
    static func outcome(_ result: MentionDeliveryLookupResult) -> MentionDeliveryOutcome {
        switch result {
        case .acked:
            return .delivered
        case .terminalError(let code, _):
            // A terminal code that is itself "the instrument broke" must not be
            // dressed as a statement about the target.
            return code == "INSTRUMENT_FAILED" ? .unknown : .lost(reasonCategory: category(code))
        case .brokenHop:
            // A hop is missing but nothing is terminal: still in flight.
            return .pending
        case .instrumentFailed, .notJoinable:
            return .unknown
        }
    }

    /// Missing occurrence is upstream `{status: NOT_JOINABLE}` at the route's
    /// join step, which the projection maps to `unknown`.
    static func outcome(occurrence: MentionDeliveryOccurrence?) -> MentionDeliveryOutcome {
        guard let occurrence else { return .unknown }
        return outcome(MentionDeliveryOccurrenceEvaluation.evaluate(occurrence))
    }
}
