import Foundation

/// Persisted event metadata keeps the legacy sorted-key member order. The
/// event vocabulary is typed; only the Messages owner appends the ledger row.
extension AttestedSendEventMetadata: JSONBodyConvertible {
    public var jsonBody: OrderedJSON {
        switch self {
        case .gateTriggered(let lastSeen, let latest, let replaced, let count, let source, let boundary, let seq):
            .object([
                .init("boundary_seq", boundary), .init("boundary_source", source),
                .init("draft_replaced_existing", replaced), .init("has_formal_mention_since_last_seen", false),
                .init("last_seen_msg_id", optional: lastSeen), .init("latest_msg_id", optional: latest),
                .init("latest_seq", seq), .init("new_message_count", count),
            ])
        case .mentionExemption(let messageId, let handle, let count):
            .object([
                .init("mention_message_id", messageId), .init("mentioned_handle", handle),
                .init("new_message_count_since_last_seen", count),
            ])
        }
    }
}
