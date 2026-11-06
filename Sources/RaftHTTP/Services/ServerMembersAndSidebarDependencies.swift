import Foundation

/// Every cross-domain decision the server-member surface needs.
///
/// The server/channel and task ledgers belong to their stores; the human session
/// lookup and the realtime emitter belong to the auth and realtime domains and
/// enter through explicit auth, realtime and profile owners.
struct ServerMembersAndSidebarDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var emitRealtime: @Sendable (String, String, String?) -> Void
    var humanExists: @Sendable (String) -> Bool
    var oauth: OAuthLedger
    var channels: ServersAndChannelsStore
    var tasks: TasksAndRemindersStore
    var now: @Sendable () -> Date
}

extension ServerMembersAndSidebarDependencies {
    init(
        auth: AuthCoreService,
        realtime: RealtimeRelayService,
        profiles: AuthProfileStore,
        oauth: OAuthLedger,
        channels: ServersAndChannelsStore,
        tasks: TasksAndRemindersStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            sessionUserId: { try? auth.authenticate($0) },
            emitRealtime: { realtime.emit($0, $1, $2) },
            humanExists: { userId in profiles.accounts.values.contains { $0.id == userId } },
            oauth: oauth,
            channels: channels,
            tasks: tasks,
            now: now
        )
    }
}
