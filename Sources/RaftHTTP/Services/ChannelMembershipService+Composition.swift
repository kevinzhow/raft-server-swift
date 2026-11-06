import Foundation

extension ChannelMembershipService {
    /// Typed production assembly for callers that already have the real owners.
    /// The existing service keeps its validation and membership/notice policy.
    init(
        auth: AuthCoreService,
        oauth: OAuthLedger,
        channels: ServersAndChannelsStore,
        agents: AgentsRuntimeStore,
        feedbackLocators: FeedbackLocatorService,
        visibility: ManagedMCPChannelVisibility,
        notices: SystemNoticeAppender,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            sessionUserId: { try? auth.authenticate($0) },
            oauth: oauth,
            channels: channels,
            agents: agents,
            feedbackLocators: feedbackLocators,
            channelActorCanSee: { visibility.actorCanSee(channelId: $0, userId: $1) },
            appendSystemNotice: { notices.append($0, $1) },
            now: now
        )
    }
}
