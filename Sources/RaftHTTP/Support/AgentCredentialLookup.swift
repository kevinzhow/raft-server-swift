import Foundation

public struct AgentCredentialLookup: Sendable {
    let agents: AgentsRuntimeStore
    let channels: AgentChannelsService
    let surface: AgentPrivateSurfaceService

    public init(directory: EmailLoginDirectory) {
        agents = directory.agentsRuntimeStore
        channels = directory.agentChannels
        surface = directory.agentSurface
    }

    func profileReadOutcome(_ authorization: String?) -> ProfileAgentReadOutcome {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return .missingAuthorization }
        let token = String(authorization.dropFirst("Bearer ".count))
        // This legacy read requires the read scope; it does not reject revocation.
        guard let agentId = agents.profileReadCredential(token: token) else { return .invalidCredential }
        surface.recordAgentCredentialUse(token: token)
        return .success(agentId: agentId)
    }

    func agentCredentialAgent(_ authorization: String?) -> (agentId: String, scopes: [String])? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return agents.useAgentCredential(token: token, now: Date())
    }

    func agentWriterAndRole(
        authorization: String?,
        legacyAgentId: String?,
        scopes: [String]
    ) -> (agent: OAuthLedger.AgentRuntimeInfo, role: String?)? {
        channels.writerAndRole(authorization: authorization, legacyAgentId: legacyAgentId, scopes: scopes)
    }
}
