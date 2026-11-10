import Foundation

/// The credential outcome the inbox routes need, without an HTTP reply.
enum InboxAuthorization: Sendable, Equatable {
    case user(String)
    case missingAuthorization
    case invalidAccessToken
}

/// The channel-probe outcome without an HTTP reply.
enum InboxChannelProbe: Sendable, Equatable {
    case allowed
    case residue
    case hidden
}

/// Every cross-domain decision the inbox service needs, as injected closures.
///
/// The message, channel and mention rows live in their own stores and the
/// service reads them directly. Session lookup, email-verification policy, the
/// attachment-comments flag, the channel probe, guest scope visibility, message
/// search visibility, and the four per-message fragments owned by unmigrated
/// domains (reaction buckets, forward metadata, action-card metadata, thread
/// summaries) enter as ordered trees from typed projection readers. The
/// composition root supplies their owning stores; the service places each
/// projection at its published position.
struct InboxAndWakeDependencies: Sendable {
    var authorize: @Sendable (String?) -> InboxAuthorization
    var isEmailVerified: @Sendable (String) -> Bool
    var readFacts: @Sendable (_ message: StoredHumanMessage, _ channelId: String, _ commentsVisible: Bool, _ serverId: String?, _ userId: String?) -> MessageReadFactsDTO
    var attachmentCommentsEnabled: @Sendable (_ serverId: String, _ userId: String?) -> Bool
    var channelProbeAccess: @Sendable (_ channelId: String, _ serverId: String, _ userId: String) -> InboxChannelProbe
    var guestCanSeeScope: @Sendable (_ scopeId: String) -> Bool
    var messageSearchVisible: @Sendable (_ messageChannelId: String, _ serverId: String?, _ userId: String) -> Bool
    var commentRef: @Sendable (String) -> InboxCommentRefDTO?
    var forwardMetadata: @Sendable (_ messageId: String, _ userId: String, _ serverId: String?) -> OrderedJSON?
    var actionCardMetadata: @Sendable (_ messageId: String) -> OrderedJSON?
    var threadSummaries: @Sendable (_ parentChannelId: String, _ parentIds: [String], _ userId: String?, _ serverId: String?) -> OrderedJSON

}

extension InboxAuthorization {
    static func resolve(_ authorization: String?, auth: AuthCoreService) -> Self {
        do { return .user(try auth.authenticate(authorization)) }
        catch AuthCoreError.missingAuthorization { return .missingAuthorization }
        catch { return .invalidAccessToken }
    }
}

extension InboxChannelProbe {
    init(_ access: ChannelProbeAccess) {
        switch access {
        case .allowed: self = .allowed
        case .residue: self = .residue
        case .hidden: self = .hidden
        }
    }
}

extension InboxAndWakeDependencies {
    init(
        auth: AuthCoreService,
        profiles: AuthProfileStore,
        channelProbeAccess: @escaping @Sendable (String, String, String) -> ChannelProbeAccess,
        guestCanSeeScope: @escaping @Sendable (String) -> Bool,
        search: SearchMentionsService,
        projection: MessageReadProjection,
        cards: ActionCardMetadataProjection
    ) {
        self.init(
            authorize: { InboxAuthorization.resolve($0, auth: auth) },
            isEmailVerified: { profiles.isEmailVerified(userId: $0) },
            readFacts: { projection.readFacts($0, channelId: $1, commentsVisible: $2, serverId: $3, userId: $4) },
            attachmentCommentsEnabled: { projection.commentsEnabled(serverId: $0, userId: $1) },
            channelProbeAccess: { InboxChannelProbe(channelProbeAccess($0, $1, $2)) },
            guestCanSeeScope: guestCanSeeScope,
            messageSearchVisible: { search.messageVisible(messageChannelId: $0, serverId: $1, viewer: .user($2)) },
            commentRef: { projection.comment(messageId: $0) },
            forwardMetadata: { projection.forward(messageId: $0, userId: $1, serverId: $2) },
            actionCardMetadata: { cards.metadata(messageId: $0).map(OrderedJSON.raw) },
            threadSummaries: { projection.threadSummaries(parentChannelId: $0, parentIds: $1, userId: $2, serverId: $3) }
        )
    }
}
