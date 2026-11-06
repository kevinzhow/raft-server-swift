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

    public var status: UInt {
        switch self {
        case .invalidTaskClaim, .invalidTaskStatus:
            400
        case .channelNotFound, .taskNotFound:
            404
        case .inProgressToTodo, .todoToTerminal, .resourceReceiptRequired:
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
        }
    }
}

/// Everything the send service needs from domains that have not migrated.
struct AgentSendDependencies: Sendable {
    var assistantOwner: @Sendable (_ agentId: String, _ serverId: String) -> String?
    var threadByAnchor: @Sendable (_ parentId: String, _ anchorMessageId: String) -> String?
    var threadById: @Sendable (_ parentId: String, _ suffix: String) -> String?
    var threadByAnchorPrefix: @Sendable (_ parentId: String, _ suffix: String) -> String?
    var addPostableChannel: @Sendable (
        _ serverId: String,
        _ channelId: String,
        _ memberId: String,
        _ kind: String,
        _ parentChannelId: String?,
        _ parentMessageId: String?,
        _ name: String?
    ) -> Void
    var messageSuppressed: @Sendable (_ message: StoredHumanMessage, _ agentId: String) -> Bool
    var selfCausedExempt: @Sendable (_ message: StoredHumanMessage, _ agentId: String) -> Bool
    var resolvedMentions: @Sendable (
        _ serverId: String,
        _ senderId: String,
        _ content: String,
        _ typed: [MentionInput],
        _ warnUnresolved: Bool
    ) -> (mentions: [MentionInput], unresolved: [String])
    var recordMemberMentionRows: @Sendable (
        _ messageId: String,
        _ channelId: String,
        _ mentions: [MentionInput]
    ) -> Void
    var recordAttestedSendEvent: @Sendable (
        _ eventType: String,
        _ agentId: String,
        _ messageId: String?,
        _ metadata: AttestedSendEventMetadata
    ) -> Void
    var recordAgentSendActivity: @Sendable (
        _ agentId: String,
        _ title: String,
        _ text: String,
        _ producerFactId: String?
    ) -> Void
    var commitAgentSend: @Sendable (
        _ message: StoredHumanMessage,
        _ attachmentIds: [String],
        _ channelId: String,
        _ uploaderId: String
    ) -> AgentSendAppendOutcome

    /// Production wiring to the not-yet-migrated directory entry points.
    static func live(directory source: EmailLoginDirectory) -> AgentSendDependencies {
        AgentSendDependencies(
            assistantOwner: { agentId, serverId in
                source.assistantOwnerFor(agentId: agentId, serverId: serverId)
            },
            threadByAnchor: { parentId, anchorMessageId in
                source.serversAndChannelsStore.historyThread(parentId: parentId, anchorMessageId: anchorMessageId)
            },
            threadById: { parentId, suffix in
                source.serversAndChannelsStore.historyThread(parentId: parentId, idPrefix: suffix)
            },
            threadByAnchorPrefix: { parentId, suffix in
                source.serversAndChannelsStore.historyThread(parentId: parentId, anchorPrefix: suffix)
            },
            addPostableChannel: { serverId, channelId, memberId, kind, parentChannelId, parentMessageId, name in
                source.serversAndChannelsStore.addPostableChannel(
                    serverId: serverId,
                    channelId: channelId,
                    memberId: memberId,
                    kind: kind,
                    parentChannelId: parentChannelId,
                    parentMessageId: parentMessageId,
                    name: name
                )
            },
            messageSuppressed: { [suppression = MessageSuppressionService(messages: source.messagesAndThreadsStore, oauth: source.oauth)] message, agentId in
                suppression.isSuppressed(message, agentId: agentId)
            },
            selfCausedExempt: { message, agentId in
                source.isSelfCausedFreshnessExemptLocked(message, agentId: agentId)
            },
            resolvedMentions: { serverId, senderId, content, typed, warn in
                let resolved = source.messageMentions.resolve(
                    serverId: serverId,
                    senderId: senderId,
                    content: content,
                    typed: typed,
                    warnUnresolved: warn
                )
                return (resolved.mentions, resolved.unresolved)
            },
            recordMemberMentionRows: { messageId, channelId, mentions in
                source.messageMentions.register(
                    messageId: messageId,
                    channelId: channelId,
                    mentions: mentions
                )
            },
            recordAttestedSendEvent: { eventType, agentId, messageId, metadata in
                source.messagesAndThreadsStore.recordAttestedSendEvent(AttestedSendEventRecord(
                    eventType: eventType,
                    agentId: agentId,
                    messageId: messageId,
                    metadataJSON: metadata.jsonBody.render()
                ))
            },
            recordAgentSendActivity: { agentId, title, text, producerFactId in
                source.messagesAndThreadsStore.recordAgentSendActivity(
                    agentId: agentId,
                    title: title,
                    text: text,
                    producerFactId: producerFactId
                )
            },
            commitAgentSend: { [messages = source.messagesAndThreadsStore, ledger = MessageLedgerPort(oauth: source.oauth)] message, attachmentIds, channelId, uploaderId in
                messages.commitAgentSend(
                    message, attachmentIds: attachmentIds, channelId: channelId,
                    uploaderId: uploaderId, ledger: ledger
                )
            }
        )
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
    case dmTargetInvalidKind(kind: String)
    case dmTargetNotFound
    case migrationReceiptReadOnly
    case freshnessInterfaceDisabled
    case idempotencyKeyReused(mismatch: String)
    case mentionBindingConflict

    public var status: UInt {
        switch self {
        case .invalidSendRequest, .continueUnsupported, .continueAnywayRequiresDraft,
             .contentRequired, .attachmentIdInvalid, .attachmentDuplicate, .attachmentNotFound,
             .attachmentAlreadyLinked, .dmTargetInvalidKind, .mentionBindingConflict:
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
            "dm:@reminders is your private reminder conversation; nobody else reads it. Act at the reminder's anchor instead."
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
            "More than one DM peer is named \(name). Address it as dm:@\(name)~agent or dm:@\(name)~human."
        case .dmTargetInvalidKind(let kind):
            "Unknown DM peer kind \(kind)."
        case .dmTargetNotFound:
            "Channel not found or not visible"
        case .migrationReceiptReadOnly:
            "This migration receipt DM is a one-way notice; it cannot be replied to. Message your owner's DM instead."
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
        case .dmTargetInvalidKind:
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
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "DM_TARGET_AMBIGUOUS")
            body.append(
                "suggestedNextAction",
                "Retry with dm:@\(name)~agent for the agent or dm:@\(name)~human for the human."
            )
            return body.json
        case .dmTargetInvalidKind:
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "DM_TARGET_INVALID_PEER_KIND")
            body.append("suggestedNextAction", "Use dm:@<name>~human or dm:@<name>~agent.")
            return body.json
        case .migrationReceiptReadOnly:
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "MIGRATION_RECEIPT_READ_ONLY")
            body.append("suggestedNextAction", "Read the receipt, then continue in your owner's DM.")
            return body.json
        case .idempotencyKeyReused(let mismatch):
            var body = OrderedJSONObject()
            body.append("error", errorMessage)
            body.append("code", "idempotency_key_reused")
            body.append("mismatch", mismatch)
            body.append("suggestedNextAction", "Retry with a new idempotencyKey.")
            return body.json
        case .invalidSendRequest, .reminderTargetNotSendable, .continueUnsupported,
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
