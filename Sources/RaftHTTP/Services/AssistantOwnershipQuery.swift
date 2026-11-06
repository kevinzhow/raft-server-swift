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
