import Foundation

/// One snapshot of the channel rows plus their creation order.
///
/// `postableChannels` and `threadOrder` live in `ServersAndChannelsStore`; the
/// thread service reads them as one value so the roster, canonical selection
/// and summary cap all see the same channel set.
struct ThreadsChannelSnapshot: Sendable {
    var channels: [String: PostableChannel]
    var order: [String]
}

/// The agent facts the roster and reply previews publish.
struct ThreadsAgentInfo: Sendable, Equatable {
    var id: String
    var name: String
    var displayName: String
}

/// The two unread facts the followed-thread projection needs.
struct ThreadsUnreadInfo: Sendable, Equatable {
    var unreadCount: Int
    var maxReadSeq: Int
}

/// The task claim facts `GET /api/channels/threads/followed` publishes.
struct ThreadsTaskInfo: Sendable, Equatable {
    var id: String
    var assigneeType: String?
    var assigneeId: String?
}

/// The channel-probe outcome without an HTTP reply.
enum ThreadsChannelProbe: Sendable, Equatable {
    case allowed
    case residue
    case hidden
}

/// Every cross-domain decision the thread service needs, as injected closures.
///
/// The thread ledger itself is the one store the service owns. Membership,
/// account names, agent metadata, channel rows, unread read state, task claims
/// and the channel-probe / guest-visibility policies belong to other domains
/// and enter through explicit owners and named access capabilities.
struct ThreadsDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var memberRole: @Sendable (_ serverId: String, _ userId: String) -> String?
    var channels: @Sendable () -> ThreadsChannelSnapshot
    var channelServerId: @Sendable (_ channelId: String) -> String?
    var channelAgentIds: @Sendable (_ channelId: String) -> [String]
    var agentInfo: @Sendable (_ agentId: String) -> ThreadsAgentInfo?
    var channelUnread: @Sendable (_ channelId: String, _ userId: String) -> ThreadsUnreadInfo
    var firstUnreadMessageId: @Sendable (_ channelId: String, _ userId: String) -> String?
    var messageChannelId: @Sendable (_ messageId: String) -> String?
    var channelProbeAccess: @Sendable (_ channelId: String, _ serverId: String, _ userId: String) -> ThreadsChannelProbe
    var channelActorCanSee: @Sendable (_ channelId: String, _ userId: String) -> Bool
    var guestCanSeeScope: @Sendable (_ scopeId: String) -> Bool
    var userName: @Sendable (_ userId: String) -> String?
    var taskForMessage: @Sendable (_ messageId: String) -> ThreadsTaskInfo?
    var now: @Sendable () -> Date
}

extension ThreadsChannelProbe {
    init(_ access: ChannelProbeAccess) {
        switch access {
        case .allowed: self = .allowed
        case .residue: self = .residue
        case .hidden: self = .hidden
        }
    }
}

extension ThreadsDependencies {
    init(
        auth: AuthCoreService,
        channels: ServersAndChannelsStore,
        profiles: AuthProfileStore,
        tasks: TasksAndRemindersStore,
        oauth: OAuthLedger,
        channelProbeAccess: @escaping @Sendable (String, String, String) -> ChannelProbeAccess,
        guestCanSeeScope: @escaping @Sendable (String) -> Bool,
        visibility: ManagedMCPChannelVisibility,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            sessionUserId: { try? auth.authenticate($0) },
            memberRole: { oauth.memberRole(serverId: $0, userId: $1) },
            channels: {
                let state = channels.state
                return ThreadsChannelSnapshot(channels: state.postableChannels, order: state.threadOrder)
            },
            channelServerId: { oauth.channelInfo(id: $0)?.serverId },
            channelAgentIds: { oauth.channelAgentIds(channelId: $0) },
            agentInfo: { agentId in
                oauth.agentRuntimeInfo(id: agentId).map {
                    ThreadsAgentInfo(id: $0.id, name: $0.name, displayName: $0.displayName)
                }
            },
            channelUnread: { channelId, userId in
                let info = oauth.channelUnreadInfo(channelId: channelId, userId: userId)
                return ThreadsUnreadInfo(unreadCount: info.unreadCount, maxReadSeq: info.maxReadSeq)
            },
            firstUnreadMessageId: { oauth.firstUnreadMessageId(channelId: $0, userId: $1) },
            messageChannelId: { oauth.messageChannelId($0) },
            channelProbeAccess: { ThreadsChannelProbe(channelProbeAccess($0, $1, $2)) },
            channelActorCanSee: { visibility.actorCanSee(channelId: $0, userId: $1) },
            guestCanSeeScope: guestCanSeeScope,
            userName: { profiles.account(userId: $0)?.name },
            taskForMessage: { messageId in
                tasks.task(messageId: messageId).map {
                    ThreadsTaskInfo(id: $0.id, assigneeType: $0.assigneeType, assigneeId: $0.assigneeId)
                }
            },
            now: now
        )
    }
}
