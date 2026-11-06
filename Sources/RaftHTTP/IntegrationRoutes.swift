/// UUID path guards retain their published refusal before handler lookup.
public enum IntegrationRoutes {
    public static func mcpAgent(agentId: String) throws -> NoContentResponse {
        guard ServerScope.isUUID(agentId) else { throw IntegrationRouteError.agentMissing }
        throw IntegrationRouteError.managedMCPAgentMissing
    }
    public static func integrationAgent(agentId: String) throws -> NoContentResponse {
        throw IntegrationRouteError.agentMissing
    }
    public static func appNotifications(clientId: String) throws -> NoContentResponse {
        throw IntegrationRouteError.appMissing
    }
    public static func shareLink(clientId: String) throws -> NoContentResponse {
        guard ServerScope.isUUID(clientId) else { throw IntegrationRouteError.appMissing }
        throw IntegrationRouteError.shareLinkMissing
    }
    public static func marketplaceAppNotifications(clientId: String) throws -> NoContentResponse {
        guard ServerScope.isUUID(clientId) else { throw IntegrationRouteError.appMissing }
        throw IntegrationRouteError.installationMissing
    }
}
