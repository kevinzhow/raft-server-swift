import Foundation

extension ActionCardIntegrationRegisterService {
    /// Resolve the carrier before preparing its Marketplace install card. A
    /// missing target preserves the existing nil result without a card write.
    func prepareMarketplaceInstallCardForReference(
        agent: OAuthLedger.AgentRuntimeInfo,
        client: MarketplaceClientIdentity,
        scopes: [String],
        target: String
    ) -> String? {
        guard let resolved = actionCardTarget(
            serverId: agent.serverId, agentId: agent.id, target: target
        ) else { return nil }
        return prepareMarketplaceInstallCard(
            serverId: agent.serverId,
            agent: agent,
            client: client,
            scopes: scopes,
            target: resolved
        )
    }
}
