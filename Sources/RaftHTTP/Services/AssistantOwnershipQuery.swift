import Foundation

/// Assistant link facts, independent of the private-surface service.
/// Each live query rechecks membership and the current flag decision.
struct AssistantOwnershipQuery: Sendable {
    private let agents: AgentsRuntimeStore
    private let oauth: OAuthLedger

    init(agents: AgentsRuntimeStore, oauth: OAuthLedger) {
        self.agents = agents
        self.oauth = oauth
    }

    func rawOwner(agentId: String) -> String? {
        agents.assistantOwner(agentId: agentId)
    }

    /// The retained owner binding used by post authority.
    ///
    /// Upstream `assistantMayPostTo` reads `agents.assistantOwnerUserId`
    /// directly: the link governs posting even while `identity_borrowing` is
    /// off or the owner has left the server. The DM's own participant rows
    /// (`channel_humans` for the owner, `channel_agents` for the assistant)
    /// remain the membership gate. `liveOwner` stays the display/borrowing
    /// decision so the owner-facing UI does not change behavior here.
    func postingOwner(agentId: String) -> String? {
        rawOwner(agentId: agentId)
    }

    func liveOwner(agentId: String, serverId: String) -> String? {
        guard let owner = rawOwner(agentId: agentId),
              oauth.memberRole(serverId: serverId, userId: owner) != nil
        else { return nil }
        guard agents.featureFlagEnabled(key: "identity_borrowing", serverId: serverId) else {
            return nil
        }
        return owner
    }
}
