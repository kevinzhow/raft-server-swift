import Foundation
import RaftShared

/// Domain failure for the migrated agent task routes.
///
/// Every case publishes the legacy `{"error": …}` body; the shared
/// `FeedbackLocatorError` covers the credential/grant refusals the old helpers
/// produced.
public enum ActionCardExecuteError: DomainError, Equatable {
    case invalidTaskClaim
    case invalidTaskStatus
    case channelNotFound
    case taskNotFound
    case inProgressToTodo
    case todoToTerminal(status: String)
    case resourceReceiptRequired
    /// `assertAgentApiTaskWritableChannel` refuses every thread target.
    case threadTaskClaim
    /// A bare `dm:@name` held by both a human and an agent.
    case dmTargetAmbiguous(peerName: String)
    /// A `dm:@name~<suffix>` whose suffix is neither `agent` nor `human`.
    case dmTargetInvalidPeerKind(rawPeer: String, suffix: String?)

    public var status: UInt {
        switch self {
        case .invalidTaskClaim, .invalidTaskStatus, .dmTargetInvalidPeerKind:
            400
        case .channelNotFound, .taskNotFound:
            404
        case .inProgressToTodo, .todoToTerminal, .resourceReceiptRequired,
             .threadTaskClaim, .dmTargetAmbiguous:
            409
        }
    }

    public var errorMessage: String {
        switch self {
        case .invalidTaskClaim:
            "Invalid task claim request"
        case .invalidTaskStatus:
            "Invalid task status request"
        case .channelNotFound:
            "Channel not found"
        case .taskNotFound:
            "Task not found"
        case .inProgressToTodo:
            "Task cannot transition from in_progress to todo"
        case .todoToTerminal(let status):
            "Task cannot transition from todo to \(status)"
        case .resourceReceiptRequired:
            "resource receipt required before task can move to done"
        case .threadTaskClaim:
            "Thread messages cannot be claimed as tasks"
        case .dmTargetAmbiguous(let peerName):
            DMTargetResolutionWire.ambiguous(peerName).message
        case .dmTargetInvalidPeerKind(let rawPeer, let suffix):
            DMTargetResolutionWire.invalidPeerKind(rawPeer: rawPeer, suffix: suffix).message
        }
    }

    public var errorCode: String? {
        switch self {
        case .threadTaskClaim, .invalidTaskClaim, .invalidTaskStatus, .channelNotFound,
             .taskNotFound, .inProgressToTodo, .todoToTerminal, .resourceReceiptRequired:
            nil
        case .dmTargetAmbiguous:
            "DM_TARGET_AMBIGUOUS"
        case .dmTargetInvalidPeerKind:
            "DM_TARGET_INVALID_PEER_KIND"
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .dmTargetAmbiguous(let peerName):
            return DMTargetResolutionWire.ambiguous(peerName).body
        case .dmTargetInvalidPeerKind(let rawPeer, let suffix):
            return DMTargetResolutionWire.invalidPeerKind(rawPeer: rawPeer, suffix: suffix).body
        case .threadTaskClaim, .invalidTaskClaim, .invalidTaskStatus, .channelNotFound,
             .taskNotFound, .inProgressToTodo, .todoToTerminal, .resourceReceiptRequired:
            return nil
        }
    }
}

/// Domain failure for the action-card execute / agent send surface.
public enum AgentSendError: DomainError, Equatable {
    case invalidSendRequest
    case reminderTargetNotSendable
    case continueUnsupported
    case continueAnywayRequiresDraft
    case assistantChannelForbidden
    case contentRequired
    case attachmentIdInvalid(entry: Int)
    case attachmentDuplicate(String)
    case attachmentNotFound(String)
    case attachmentAlreadyLinked(String)
    case channelNotFound
    case threadTargetNotFound(detail: String)
    case agentNotParentMember
    case dmTargetAmbiguous(name: String)
    /// The exact pinned projection for the agent send surface.
    case dmTargetInvalidPeerKind(rawPeer: String, suffix: String?)
    /// A plain DM target whose peer does not exist.
    case dmTargetNotFound(peer: String)
    /// A one-way migration receipt named by the caller's actual target.
    case migrationReceiptReadOnly(target: String)
    case freshnessInterfaceDisabled
    case idempotencyKeyReused(mismatch: String)
    case mentionBindingConflict

    public var status: UInt {
        switch self {
        case .invalidSendRequest, .continueUnsupported, .continueAnywayRequiresDraft,
             .contentRequired, .attachmentIdInvalid, .attachmentDuplicate, .attachmentNotFound,
             .attachmentAlreadyLinked, .dmTargetInvalidPeerKind,
             .mentionBindingConflict:
            400
        case .reminderTargetNotSendable, .assistantChannelForbidden, .agentNotParentMember,
             .freshnessInterfaceDisabled:
            403
        case .channelNotFound, .threadTargetNotFound, .dmTargetNotFound:
            404
        case .dmTargetAmbiguous, .migrationReceiptReadOnly, .idempotencyKeyReused:
            409
        }
    }

    public var errorMessage: String {
        switch self {
        case .invalidSendRequest:
            "Invalid send request"
        case .reminderTargetNotSendable:
            DMTargetResolutionWire.privateReminderSurface().message
        case .continueUnsupported:
            "--continue is no longer supported. Use normal message send to update a draft, or --send-draft to send the current saved draft."
        case .continueAnywayRequiresDraft:
            "--send-draft --anyway requires a saved draft"
        case .assistantChannelForbidden:
            "An assistant can only post in its DM with its owner"
        case .contentRequired:
            "Content is required"
        case .attachmentIdInvalid(let entry):
            "Not sent: attachmentIds entry \(entry) is not a single attachment ID. Send one ID per --attachment-id."
        case .attachmentDuplicate(let id):
            "Attachment \(id) was requested more than once. Send each attachment ID exactly once."
        case .attachmentNotFound(let id):
            "Attachment \(id) is not available for this sender. Re-upload the file and send the new attachment ID."
        case .attachmentAlreadyLinked(let id):
            "Attachment \(id) is already attached to another message. Re-upload the file and send the new attachment ID."
        case .channelNotFound:
            "Channel not found"
        case .threadTargetNotFound(let detail):
            "Thread target not found or not replyable: \(detail)"
        case .agentNotParentMember:
            "Agent is not a member of the parent channel"
        case .dmTargetAmbiguous(let name):
            DMTargetResolutionWire.ambiguous(name).message
        case .dmTargetInvalidPeerKind(let rawPeer, let suffix):
            DMTargetResolutionWire.invalidPeerKind(rawPeer: rawPeer, suffix: suffix).message
        case .dmTargetNotFound(let peer):
            "User or agent not found: @\(peer)"
        case .migrationReceiptReadOnly(let target):
            DMTargetResolutionWire.migrationReceiptReadOnly(target: target).message
        case .freshnessInterfaceDisabled:
            "Send freshness interface is not enabled for this agent."
        case .idempotencyKeyReused:
            "This idempotencyKey was already used for a different send"
        case .mentionBindingConflict:
            "A mention handle is bound to more than one target"
        }
    }

    public var errorCode: String? {
        switch self {
        case .reminderTargetNotSendable:
            "DM_TARGET_NOT_SENDABLE"
        case .attachmentIdInvalid:
            "attachment_id_invalid"
        case .attachmentDuplicate:
            "attachment_duplicate"
        case .attachmentNotFound:
            "attachment_not_found"
        case .attachmentAlreadyLinked:
            "attachment_already_linked"
        case .dmTargetAmbiguous:
            "DM_TARGET_AMBIGUOUS"
        case .dmTargetInvalidPeerKind:
            "DM_TARGET_INVALID_PEER_KIND"
        case .migrationReceiptReadOnly:
            "MIGRATION_RECEIPT_READ_ONLY"
        case .idempotencyKeyReused:
            "idempotency_key_reused"
        case .mentionBindingConflict:
            "mention_binding_conflict"
        case .invalidSendRequest, .continueUnsupported, .continueAnywayRequiresDraft,
             .assistantChannelForbidden, .contentRequired, .channelNotFound,
             .threadTargetNotFound, .agentNotParentMember, .dmTargetNotFound,
             .freshnessInterfaceDisabled:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .assistantChannelForbidden:
            return .object([
                OrderedJSONField("code", "assistant_channel_forbidden"),
                OrderedJSONField("error", errorMessage),
            ])
        case .dmTargetAmbiguous(let name):
            return DMTargetResolutionWire.ambiguous(name).body
        case .dmTargetInvalidPeerKind(let rawPeer, let suffix):
            return DMTargetResolutionWire.invalidPeerKind(rawPeer: rawPeer, suffix: suffix).body
        case .reminderTargetNotSendable:
            return DMTargetResolutionWire.privateReminderSurface().body
        case .migrationReceiptReadOnly(let target):
            return DMTargetResolutionWire.migrationReceiptReadOnly(target: target).body
        case .idempotencyKeyReused(let mismatch):
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "idempotency_key_reused")
            body.append("mismatch", mismatch)
            body.append("suggestedNextAction", "Retry with a new idempotencyKey.")
            return body.json
        case .invalidSendRequest, .continueUnsupported,
             .continueAnywayRequiresDraft, .contentRequired, .attachmentIdInvalid,
             .attachmentDuplicate, .attachmentNotFound, .attachmentAlreadyLinked,
             .channelNotFound, .threadTargetNotFound, .agentNotParentMember,
             .dmTargetNotFound, .freshnessInterfaceDisabled, .mentionBindingConflict:
            return nil
        }
    }
}

/// The attachment-validating append outcome. The legacy handler validated the
/// attachment set, appended the row and linked the ids in one transaction.
/// The message owner now keeps that whole section in its State Mutex.
enum AgentSendAppendOutcome: Sendable, Equatable {
    case duplicate(String)
    case unavailable(String)
    case alreadyLinked(String)
    case committed(seq: Int)
}
