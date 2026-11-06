import Foundation
import RaftShared

/// Typed collaborators for human sends, mentions and forward reads.
struct HumanMessageCreateDependencies: Sendable {
    var agentReadOutcome: @Sendable (_ authorization: String?) -> ProfileAgentReadOutcome
    var storeHumanMessage: @Sendable (
        _ channelId: String,
        _ senderId: String,
        _ content: String,
        _ randomId: String?,
        _ attachmentIds: [String],
        _ senderTimezone: String?,
        _ mentions: [MentionInput]
    ) -> HumanMessageWrite
    var resolveMentions: @Sendable (
        _ serverId: String,
        _ senderId: String,
        _ content: String,
        _ typed: [MentionInput],
        _ warnUnresolved: Bool
    ) -> ResolvedMentions
    var recordMemberMentionRows: @Sendable (
        _ messageId: String,
        _ channelId: String,
        _ mentions: [MentionInput]
    ) -> Void
    var jointLocalChannelId: @Sendable (
        _ canonicalChannelId: String,
        _ serverId: String?,
        _ userId: String
    ) -> String?
    var messageVisibleToUser: @Sendable (_ channelId: String, _ serverId: String?, _ userId: String) -> Bool
    var renderForwardItem: @Sendable (_ item: ForwardItemRecord) -> String
    var mentionBindingConflict: @Sendable (_ mentions: [MentionInput]) -> Bool
    var now: @Sendable () -> Date
}

extension HumanMessageCreateDependencies {
    init(
        credentials: AgentCredentialLookup,
        writer: HumanMessageCommitService,
        mentions: MessageMentionsService,
        channels: ServersAndChannelsStore,
        search: SearchMentionsService,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            agentReadOutcome: { credentials.profileReadOutcome($0) },
            storeHumanMessage: { channelId, senderId, content, randomId, attachmentIds, timezone, mentions in
                writer.store(channelId: channelId, senderId: senderId, content: content, randomId: randomId,
                    attachmentIds: attachmentIds, senderTimezone: timezone, mentions: mentions)
            },
            resolveMentions: { serverId, senderId, content, typed, warn in
                mentions.resolve(serverId: serverId, senderId: senderId, content: content, typed: typed, warnUnresolved: warn)
            },
            recordMemberMentionRows: { mentions.register(messageId: $0, channelId: $1, mentions: $2) },
            jointLocalChannelId: { MessageChannelFacts(channels.state).localChannel(canonical: $0, serverId: $1, userId: $2) },
            messageVisibleToUser: { search.messageVisible(messageChannelId: $0, serverId: $1, viewer: .user($2)) },
            renderForwardItem: { MessageForwardProjection.forwardItemJSON($0) },
            mentionBindingConflict: { MessageMentionRules.mentionBindingConflict($0) },
            now: now
        )
    }
}
