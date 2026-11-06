import Foundation
import RaftShared

/// Send operations supplied by their actual owners and domain capabilities.
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
}

extension AgentSendDependencies {
    init(
        ownership: AssistantOwnershipQuery,
        channels: ServersAndChannelsStore,
        messages: MessagesAndThreadsStore,
        suppression: MessageSuppressionService,
        mentionService: MessageMentionsService,
        ledger: MessageLedgerPort
    ) {
        self.init(
            assistantOwner: { agentId, serverId in
                ownership.liveOwner(agentId: agentId, serverId: serverId)
            },
            threadByAnchor: { parentId, anchorMessageId in
                channels.historyThread(parentId: parentId, anchorMessageId: anchorMessageId)
            },
            threadById: { parentId, suffix in
                channels.historyThread(parentId: parentId, idPrefix: suffix)
            },
            threadByAnchorPrefix: { parentId, suffix in
                channels.historyThread(parentId: parentId, anchorPrefix: suffix)
            },
            addPostableChannel: { serverId, channelId, memberId, kind, parentChannelId, parentMessageId, name in
                channels.addPostableChannel(
                    serverId: serverId,
                    channelId: channelId,
                    memberId: memberId,
                    kind: kind,
                    parentChannelId: parentChannelId,
                    parentMessageId: parentMessageId,
                    name: name
                )
            },
            messageSuppressed: { message, agentId in
                suppression.isSuppressed(message, agentId: agentId)
            },
            selfCausedExempt: { message, agentId in
                AgentSendFreshnessPolicy.isSelfCausedExempt(message, agentId: agentId)
            },
            resolvedMentions: { serverId, senderId, content, typed, warn in
                let resolved = mentionService.resolve(
                    serverId: serverId,
                    senderId: senderId,
                    content: content,
                    typed: typed,
                    warnUnresolved: warn
                )
                return (resolved.mentions, resolved.unresolved)
            },
            recordMemberMentionRows: { messageId, channelId, mentions in
                mentionService.register(messageId: messageId, channelId: channelId, mentions: mentions)
            },
            recordAttestedSendEvent: { eventType, agentId, messageId, metadata in
                messages.recordAttestedSendEvent(AttestedSendEventRecord(
                    eventType: eventType,
                    agentId: agentId,
                    messageId: messageId,
                    metadataJSON: metadata.jsonBody.render()
                ))
            },
            recordAgentSendActivity: { agentId, title, text, producerFactId in
                messages.recordAgentSendActivity(
                    agentId: agentId,
                    title: title,
                    text: text,
                    producerFactId: producerFactId
                )
            },
            commitAgentSend: { message, attachmentIds, channelId, uploaderId in
                messages.commitAgentSend(
                    message, attachmentIds: attachmentIds, channelId: channelId,
                    uploaderId: uploaderId, ledger: ledger
                )
            }
        )
    }
}
