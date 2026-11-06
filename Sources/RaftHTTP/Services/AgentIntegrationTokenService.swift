import Foundation

/// `POST /internal/agent-api/integrations/token`: an agent exchanges its `read`
/// credential for a short-lived audience token of one enabled App.
///
/// The decision order is the legacy order: credential, body shape, derived
/// fields, service name, agent status, Server membership, App availability,
/// grant. The grant check and the first-use write share one `claim` critical
/// section in the store.
public struct AgentIntegrationTokenService: Sendable {
    private let agents: AgentsRuntimeStore
    private let grants: ManagedMCPAndCardsStore
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger

    init(
        agents: AgentsRuntimeStore,
        grants: ManagedMCPAndCardsStore,
        profiles: AuthProfileStore,
        oauth: OAuthLedger
    ) {
        self.agents = agents
        self.grants = grants
        self.profiles = profiles
        self.oauth = oauth
    }

    public func issue(
        authorization: String?,
        body: LenientJSONObjectRequest?
    ) throws -> AgentIntegrationTokenIssued {
        guard let token = NativeNotificationCredentials.bearer(authorization) else {
            throw AgentIntegrationTokenError.missingAuthorization
        }
        guard let credential = agents.agentCredentials[token], credential.revokedAt == nil,
              credential.scopes.contains("read"),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { throw AgentIntegrationTokenError.invalidToken }
        guard let body else { throw AgentIntegrationTokenError.invalidRequest }
        for field in ["agentId", "serverId", "audience", "issuer", "expires_in", "scopes", "claims"]
        where body[field] != nil {
            throw AgentIntegrationTokenError.derivedFields
        }
        guard let service = body["service"]?.legacyString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !service.isEmpty
        else { throw AgentIntegrationTokenError.serviceRequired }
        guard grants.agentAudienceStatus(agentId: agent.id) == "active" else {
            throw AgentIntegrationTokenError.agentInactive
        }
        guard oauth.agentRole(serverId: agent.serverId, agentId: agent.id) != nil else {
            throw AgentIntegrationTokenError.agentNotMember
        }
        guard let client = oauth.localClientForAgentAudience(clientId: service, serverId: agent.serverId),
              client.enabled,
              client.allowedScopes.contains("openid"),
              client.allowedScopes.contains("profile")
        else { throw AgentIntegrationTokenError.appUnavailable }
        guard grants.claimAgentIntegrationGrant(key: "\(agent.id)\n\(client.clientId)") else {
            throw AgentIntegrationTokenError.grantRevoked
        }
        guard let slug = oauth.serverProfile(id: agent.serverId)?.slug,
              let origin = OAuthDiscovery.issuerOrigin(profiles.serverURL),
              let signed = oauth.signAgentAudienceToken(
                  agentId: agent.id,
                  agentName: agent.name,
                  clientKey: client.clientId,
                  serverId: agent.serverId,
                  serverSlug: slug,
                  issuer: "\(origin)/oidc/\(slug)"
              )
        else { throw AgentIntegrationTokenError.issueFailed }
        return AgentIntegrationTokenIssued(accessToken: signed.token, audience: client.clientId)
    }
}
