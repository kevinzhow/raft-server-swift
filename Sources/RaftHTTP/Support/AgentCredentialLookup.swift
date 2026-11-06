import Foundation

public struct AgentCredentialLookup: Sendable {
    let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) { self.directory = directory }

    func agentCredentialAgent(_ authorization: String?) -> (agentId: String, scopes: [String])? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return directory.agentsRuntimeStore.useAgentCredential(token: token, now: Date())
    }

    func agentWriterAndRole(
        authorization: String?,
        legacyAgentId: String?,
        scopes: [String]
    ) -> (agent: OAuthLedger.AgentRuntimeInfo, role: String?)? {
        directory.agentChannels.writerAndRole(authorization: authorization, legacyAgentId: legacyAgentId, scopes: scopes)
    }
}
