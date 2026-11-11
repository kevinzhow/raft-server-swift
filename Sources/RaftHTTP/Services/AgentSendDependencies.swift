import Foundation
import RaftShared

/// Send operations supplied by their actual owners and domain capabilities.
struct AgentSendDependencies: Sendable {
    /// The retained posting-owner binding (`agents.assistantOwnerUserId`), not
    /// the live display/borrowing owner. Post authority uses this raw link.
    var postingOwner: @Sendable (_ agentId: String, _ serverId: String) -> String?
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
        _ channelId: String,
        _ senderId: String,
        _ content: String,
        _ typed: [MentionInput],
        _ warnUnresolved: Bool,
        _ surface: MessageMentionSurface
    ) throws -> ResolvedMentions
    var recordThreadReplyFollows: @Sendable (_ messageId: String, _ channelId: String,
        _ serverId: String, _ senderId: String, _ resolution: ResolvedMentions) -> Void
    var recordMemberMentionRows: @Sendable (
        _ messageId: String,
        _ channelId: String,
        _ resolution: ResolvedMentions
    ) -> Void
    var targetAvatar: @Sendable (_ type: String, _ id: String) -> String?
    var commitAgentSend: @Sendable (
        _ message: StoredHumanMessage,
        _ attachmentIds: [String],
        _ channelId: String,
        _ uploaderId: String
    ) throws -> AgentSendAppendOutcome
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
            postingOwner: { agentId, _ in
                ownership.postingOwner(agentId: agentId)
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
            resolvedMentions: { serverId, channelId, senderId, content, typed, warn, surface in
                try mentionService.resolve(
                    serverId: serverId,
                    channelId: channelId,
                    senderId: senderId,
                    content: content,
                    typed: typed,
                    warnUnresolved: warn,
                    surface: surface
                )
            },
            recordThreadReplyFollows: mentionService.recordThreadReplyFollows,
            recordMemberMentionRows: { messageId, channelId, resolution in
                mentionService.register(messageId: messageId, channelId: channelId, resolution: resolution)
            },
            targetAvatar: { type, id in
                type == "user" ? mentionService.profiles.account(userId: id)?.avatarUrl
                    : mentionService.oauth.agentRuntimeInfo(id: id)?.avatarUrl
            },
            commitAgentSend: { message, attachmentIds, channelId, uploaderId in
                let outcome = messages.commitAgentSend(
                    message, attachmentIds: attachmentIds, channelId: channelId,
                    uploaderId: uploaderId, ledger: ledger
                )
                if case .committed(let seq) = outcome {
                    var committed = message
                    committed.seq = seq
                    // The same persisted frontend pipeline as a human send:
                    // DM/thread room grants and reply follows first, then the
                    // canonical `message:new`, `dm:new` or `thread:updated`.
                    let realtime = MessageRealtimeService(
                        messages: messages, channels: channels, profiles: mentionService.profiles,
                        oauth: mentionService.oauth
                    )
                    let relay = RealtimeRelayService(messages: messages)
                    for frame in realtime.frames(for: committed) {
                        try AgentExecutionPublication.publish(
                            room: frame.room, event: frame.event, identity: frame.identity,
                            payloadJSON: frame.payload, emit: { relay.emit($0, $1, $2) }
                        )
                    }
                }
                return outcome
            }
        )
    }
}
