import Foundation

/// One fixable DM-target refusal, ready for the HTTP boundary.
///
/// The published body is exactly `{error, code, suggestedNextAction}` in that
/// order. `errorMessage` repeats the body's `error` so a `DomainError` has one
/// source for both the rendered body and any log/diagnostic line.
struct DMTargetWireRefusal: Sendable, Equatable {
    let status: UInt
    let message: String
    let body: OrderedJSON
}

/// Pinned `packages/server/src/services/dmTargetResolutionError.ts`.
///
/// `parseDmPeerRef` owns the target grammar, not the wire prose: every
/// agent-facing route reports a malformed or ambiguous DM target through
/// `DmTargetResolutionError` and its `toResponseBody()`. History, search, the
/// legacy machine send, the modern send routes, the task-claim resolver and
/// action-card prepare all render these bytes through this one helper so the
/// prose, code and member order cannot drift between routes that resolve the
/// same target.
enum DMTargetResolutionWire {
    static func ambiguous(_ peerName: String) -> DMTargetWireRefusal {
        let agentRef = "dm:@\(peerName)~agent"
        let humanRef = "dm:@\(peerName)~human"
        let message = "dm:@\(peerName) matches both a human and an agent named \(peerName). "
            + "Name the one you mean: \(agentRef) for the agent, or \(humanRef) for the human "
            + "(for example: raft message read --target \"\(agentRef)\")."
        return DMTargetWireRefusal(
            status: 409,
            message: message,
            body: .object([
                OrderedJSONField("error", message),
                OrderedJSONField("code", "DM_TARGET_AMBIGUOUS"),
                OrderedJSONField(
                    "suggestedNextAction",
                    "retry with \(agentRef) for the agent or \(humanRef) for the human"
                ),
            ])
        )
    }

    static func invalidPeerKind(rawPeer: String, suffix: String?) -> DMTargetWireRefusal {
        let kind = suffix.map { " \"\($0)\"" } ?? ""
        let message = "dm:@\(rawPeer) has an unknown peer kind\(kind). "
            + "Use dm:@<name>, dm:@<name>~agent or dm:@<name>~human."
        return DMTargetWireRefusal(
            status: 400,
            message: message,
            body: .object([
                OrderedJSONField("error", message),
                OrderedJSONField("code", "DM_TARGET_INVALID_PEER_KIND"),
                OrderedJSONField(
                    "suggestedNextAction",
                    "retry with dm:@<name>, dm:@<name>~agent or dm:@<name>~human"
                ),
            ])
        )
    }

    /// `DmTargetResolutionError.privateReminderSurface`.
    static func privateReminderSurface() -> DMTargetWireRefusal {
        let message = "dm:@reminders is your private reminder conversation; nobody else reads it. "
            + "Act at the reminder's anchor instead."
        return DMTargetWireRefusal(
            status: 403,
            message: message,
            body: .object([
                OrderedJSONField("error", message),
                OrderedJSONField("code", "DM_TARGET_NOT_SENDABLE"),
                OrderedJSONField(
                    "suggestedNextAction",
                    "send to the reminder's anchor target instead of dm:@reminders"
                ),
            ])
        )
    }

    /// `DmTargetResolutionError.migrationReceiptReadOnly`.
    static func migrationReceiptReadOnly(target: String) -> DMTargetWireRefusal {
        let message = "\(target) is a migration receipt: a one-way notice from Raft about your move, "
            + "with no one on the other side. No reply is needed. To tell your owner something, "
            + "send it to their DM."
        return DMTargetWireRefusal(
            status: 409,
            message: message,
            body: .object([
                OrderedJSONField("error", message),
                OrderedJSONField("code", "MIGRATION_RECEIPT_READ_ONLY"),
                OrderedJSONField(
                    "suggestedNextAction",
                    "send to your owner's DM (dm:@<owner>) instead of the migration receipt"
                ),
            ])
        )
    }
}
