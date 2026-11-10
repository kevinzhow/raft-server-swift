import Foundation
import RaftShared

enum MentionActionAgentOutcome: Sendable {
    case success(agentId: String)
    case missingAuthorization
    case invalidCredential
    case capabilityNotAuthorized
}

/// Typed collaborators for human sends, mentions and forward reads.
struct HumanMessageCreateDependencies: Sendable {
    var agentReadOutcome: @Sendable (_ authorization: String?) -> MentionActionAgentOutcome
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
        _ channelId: String,
        _ senderId: String,
        _ content: String,
        _ typed: [MentionInput],
        _ warnUnresolved: Bool
    ) throws -> ResolvedMentions
    var recordThreadReplyFollows: @Sendable (_ messageId: String, _ channelId: String,
        _ serverId: String, _ senderId: String, _ resolution: ResolvedMentions) -> Void
    var recordMemberMentionRows: @Sendable (
        _ messageId: String,
        _ channelId: String,
        _ resolution: ResolvedMentions
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
            agentReadOutcome: { authorization in
                guard let authorization, authorization.hasPrefix("Bearer ") else { return .missingAuthorization }
                guard let credential = credentials.agentCredentialAgent(authorization),
                      let actor = mentions.oauth.agentRuntimeInfo(id: credential.agentId), !actor.deleted else { return .invalidCredential }
                guard credential.scopes.contains("mentions") else { return .capabilityNotAuthorized }
                return .success(agentId: credential.agentId)
            },
            storeHumanMessage: { channelId, senderId, content, randomId, attachmentIds, timezone, mentions in
                writer.store(channelId: channelId, senderId: senderId, content: content, randomId: randomId,
                    attachmentIds: attachmentIds, senderTimezone: timezone, mentions: mentions)
            },
            resolveMentions: { serverId, channelId, senderId, content, typed, warn in
                try mentions.resolve(serverId: serverId, channelId: channelId, senderId: senderId, content: content, typed: typed, warnUnresolved: warn)
            },
            recordThreadReplyFollows: mentions.recordThreadReplyFollows,
            recordMemberMentionRows: { mentions.register(messageId: $0, channelId: $1, resolution: $2) },
            jointLocalChannelId: { MessageChannelFacts(channels.state).localChannel(canonical: $0, serverId: $1, userId: $2) },
            messageVisibleToUser: { search.messageVisible(messageChannelId: $0, serverId: $1, viewer: .user($2)) },
            renderForwardItem: { MessageForwardProjection.forwardItemJSON($0) },
            mentionBindingConflict: { MessageMentionRules.mentionBindingConflict($0) },
            now: now
        )
    }
}
