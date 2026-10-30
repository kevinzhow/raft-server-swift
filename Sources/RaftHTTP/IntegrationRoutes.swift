import Foundation

/// MCP and integration id guards from `guardUuidPathParams`.
///
/// A non-UUID `:agentId` is `Agent not found` and a non-UUID `:clientId` is
/// `App not found`, before the handler. A UUID that names nothing uses that
/// handler's own not-found body. The MCP catalog adds `managed_mcp_agent_not_found`.

public enum IntegrationRoutes {
    public static func mcpAgent(agentId: String) -> HTTPReply {
        guard ServerScope.isUUID(agentId) else {
            return missing("Agent not found")
        }
        let body = "{\"error\":\(jsonString("Agent not found")),\"code\":\(jsonString("managed_mcp_agent_not_found"))}"
        return json(404, body)
    }

    public static func integrationAgent(agentId: String) -> HTTPReply {
        guard ServerScope.isUUID(agentId) else {
            return missing("Agent not found")
        }
        return missing("Agent not found")
    }

    public static func appNotifications(clientId: String) -> HTTPReply {
        guard ServerScope.isUUID(clientId) else {
            return missing("App not found")
        }
        return missing("App not found")
    }

    public static func shareLink(clientId: String) -> HTTPReply {
        guard ServerScope.isUUID(clientId) else {
            return missing("App not found")
        }
        return missing("OAuth client share link not found")
    }

    public static func marketplaceAppNotifications(clientId: String) -> HTTPReply {
        guard ServerScope.isUUID(clientId) else {
            return missing("App not found")
        }
        return missing("Active app installation not found")
    }

    private static func missing(_ error: String) -> HTTPReply {
        json(404, "{\"error\":\(jsonString(error))}")
    }

    private static func json(_ status: Int, _ body: String) -> HTTPReply {
        HTTPReply(
            status: status,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }
}
