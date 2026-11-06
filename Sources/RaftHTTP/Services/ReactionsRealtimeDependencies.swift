import Foundation

/// The agent credential facts the mentions inbox reads.
struct ReactionsAgentCredential: Sendable, Equatable {
    var agentId: String
    var scopes: Set<String>
}

/// Every cross-domain decision this service needs, as injected closures.
///
/// The message, channel, inbox-fact and card rows live in their own stores and
/// the OAuth ledger owns read state, so the service reads those directly.
/// Session lookup, the agent read credential (which records a credential use),
/// the mentions-scope credential lookup, guest scope visibility and account
/// display names enter through typed owners and narrow access capabilities.
struct ReactionsRealtimeDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var agentReadOutcome: @Sendable (String?) -> ProfileAgentReadOutcome
    var agentCredential: @Sendable (_ token: String) -> ReactionsAgentCredential?
    var guestCanSeeScope: @Sendable (_ scopeId: String) -> Bool
    var userName: @Sendable (_ userId: String) -> String?
    var now: @Sendable () -> Date

}

extension ReactionsRealtimeDependencies {
    init(
        auth: AuthCoreService,
        credentials: AgentCredentialLookup,
        agents: AgentsRuntimeStore,
        profiles: AuthProfileStore,
        guestCanSeeScope: @escaping @Sendable (String) -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            sessionUserId: { try? auth.authenticate($0) },
            agentReadOutcome: { credentials.profileReadOutcome($0) },
            agentCredential: { token in
                agents.agentCredential(token: token).map {
                    ReactionsAgentCredential(agentId: $0.agentId, scopes: Set($0.scopes))
                }
            },
            guestCanSeeScope: guestCanSeeScope,
            userName: { profiles.account(userId: $0)?.name },
            now: now
        )
    }
}
