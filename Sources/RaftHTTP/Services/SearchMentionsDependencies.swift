import Foundation

/// One agent credential resolved by the unmigrated agent-api domain.
struct SearchMentionsAgentCredential: Sendable, Equatable {
    var agentId: String
    var scopes: [String]
}

/// Every cross-domain decision the search service needs, as injected closures.
///
/// The channel, message, machine, agent, task, profile and feedback rows all
/// live in their migrated stores; these closures bridge the domains that have
/// not moved yet: sessions, machine/agent credential resolution, the
/// attachment-comment and action-card projections, and the thread-summary
/// renderer. Explicit owners and named capabilities provide the production wiring.
struct SearchMentionsDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var machineIdForCredential: @Sendable (String?) -> String?
    var agentCredential: @Sendable (String?) -> SearchMentionsAgentCredential?
    var canMachineServeAgent: @Sendable (String, OAuthLedger.AgentRuntimeInfo) -> Bool
    var attachmentCommentsEnabled: @Sendable (_ serverId: String, _ userId: String) -> Bool
    var attachmentChips: @Sendable (_ ids: [String], _ commentsVisible: Bool) -> [InboxAttachmentChipDTO]
    var commentRef: @Sendable (_ messageId: String) -> InboxCommentRefDTO?
    var forwardMetadata: @Sendable (_ messageId: String, _ userId: String, _ serverId: String?) -> OrderedJSON?
    var actionCardMetadataJSON: @Sendable (_ messageId: String) -> String?
    var threadSummaries: @Sendable (_ parentChannelId: String, _ parentIds: [String]) -> OrderedJSON
    var now: @Sendable () -> Date

}

extension SearchMentionsDependencies {
    init(
        auth: AuthCoreService,
        credentials: AgentCredentialLookup,
        machineIdForCredential: @escaping @Sendable (String?) -> String?,
        canMachineServeAgent: @escaping @Sendable (String, OAuthLedger.AgentRuntimeInfo) -> Bool,
        projection: MessageReadProjection,
        cards: ActionCardMetadataProjection,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            sessionUserId: { try? auth.authenticate($0) },
            machineIdForCredential: machineIdForCredential,
            agentCredential: { authorization in
                credentials.agentCredentialAgent(authorization).map {
                    SearchMentionsAgentCredential(agentId: $0.agentId, scopes: $0.scopes)
                }
            },
            canMachineServeAgent: canMachineServeAgent,
            attachmentCommentsEnabled: { projection.commentsEnabled(serverId: $0, userId: $1) },
            attachmentChips: { projection.attachments($0, commentsVisible: $1) },
            commentRef: { projection.comment(messageId: $0) },
            forwardMetadata: { projection.forward(messageId: $0, userId: $1, serverId: $2) },
            actionCardMetadataJSON: { cards.metadata(messageId: $0) },
            threadSummaries: { projection.threadSummaries(parentChannelId: $0, parentIds: $1) },
            now: now
        )
    }
}
