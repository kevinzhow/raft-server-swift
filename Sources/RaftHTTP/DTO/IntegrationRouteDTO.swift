public enum IntegrationRouteError: DomainError {
    case agentMissing, managedMCPAgentMissing, appMissing, shareLinkMissing, installationMissing
    public var status: UInt { 404 }
    public var errorMessage: String {
        switch self {
        case .agentMissing, .managedMCPAgentMissing: "Agent not found"
        case .appMissing: "App not found"
        case .shareLinkMissing: "OAuth client share link not found"
        case .installationMissing: "Active app installation not found"
        }
    }
    public var errorCode: String? { if case .managedMCPAgentMissing = self { "managed_mcp_agent_not_found" } else { nil } }
}
