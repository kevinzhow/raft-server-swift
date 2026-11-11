import Foundation

/// Typed refusals of the managed MCP control plane.
public enum ManagedMCPControlPlaneError: DomainError, Equatable {
    case unauthorized
    case serverNotFound
    case ownersOnlyManage
    case ownersOnlyTest
    case requestInvalid(String)
    case endpointInvalid(code: String)
    case providerMustUseManagedEndpoint
    case mcpServerNotFound
    case agentNotFound
    case agentNotFoundInServer
    case oauthRequired
    case oauthUnavailable

    public var status: UInt {
        switch self {
        case .unauthorized: 401
        case .ownersOnlyManage, .ownersOnlyTest: 403
        case .serverNotFound, .mcpServerNotFound, .agentNotFound, .agentNotFoundInServer: 404
        case .requestInvalid, .endpointInvalid: 400
        case .providerMustUseManagedEndpoint: 409
        case .oauthRequired: 400
        case .oauthUnavailable: 502
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized: "Unauthorized"
        case .serverNotFound: "Server not found"
        case .ownersOnlyManage: "Only server owners and admins can manage MCP servers"
        case .ownersOnlyTest: "Only server owners and admins can test MCP servers"
        case .requestInvalid(let message): message
        case .endpointInvalid: "Endpoint must be a public HTTPS URL without credentials, query, or fragment"
        case .providerMustUseManagedEndpoint: "That provider must use its managed endpoint"
        case .mcpServerNotFound: "MCP server not found"
        case .agentNotFound: "Agent not found"
        case .agentNotFoundInServer: "Agent not found"
        case .oauthRequired: "MCP server does not use OAuth"
        case .oauthUnavailable: "MCP server is unreachable"
        }
    }

    public var errorCode: String? {
        switch self {
        case .requestInvalid: "managed_mcp_request_invalid"
        case .endpointInvalid(let code): code
        case .providerMustUseManagedEndpoint: "managed_mcp_auth_invalid"
        case .mcpServerNotFound: "managed_mcp_server_not_found"
        case .agentNotFoundInServer: "managed_mcp_agent_not_found"
        case .oauthRequired: "managed_mcp_oauth_required"
        case .oauthUnavailable: "managed_mcp_unreachable"
        default: nil
        }
    }
}
