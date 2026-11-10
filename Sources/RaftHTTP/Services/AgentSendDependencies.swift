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
                    // The agent reply auto-follows its sender (and, when
                    // eligible, the parent author) before the frontend emit,
                    // then grants the thread room to every human follower.
                    if let channel = channels.postableChannel(id: channelId) {
                        if channel.kind == "dm" {
                            let relay = RealtimeRelayService(messages: messages)
                            for participantId in channel.memberIds {
                                relay.joinUserServerSessions(
                                    participantId, channel.serverId, "channel:\(channelId)"
                                )
                            }
                        } else if channel.kind == "thread", let parentMessageId = channel.parentMessageId {
                            let parent = messages.humanMessageRows.first { $0.id == parentMessageId }
                            messages.recordThreadReplyJoinFollows(
                                serverId: channel.serverId,
                                threadChannelId: channelId,
                                parentMessageId: parentMessageId,
                                senderId: message.senderId,
                                parentAuthorId: ThreadFollowerRealtimeService.parentAuthorId(
                                    of: parent, replyingSenderId: message.senderId
                                )
                            )
                            ThreadFollowerRealtimeService(
                                messages: messages, channels: channels, oauth: mentionService.oauth
                            ).joinHumanFollowers(threadChannelId: channelId, serverId: channel.serverId)
                        }
                    }
                    let relay = RealtimeRelayService(messages: messages)
                    try AgentExecutionPublication.publish(room: "channel:\(channelId)", event: "message:new", identity: message.id,
                        payloadJSON: AgentExecutionPublication.messagePayload(committed, senderName: mentionService.oauth.agentRuntimeInfo(id: message.senderId).map { $0.displayName.isEmpty ? $0.name : $0.displayName } ?? "Unknown", includeAttachments: true),
                        emit: { relay.emit($0, $1, $2) })
                }
                return outcome
            }
        )
    }
}
