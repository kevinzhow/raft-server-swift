import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The not-yet-migrated session lookup and the public origin the OAuth
/// metadata documents print. Both enter as closures wired by the accessor.
public struct ManagedMCPControlPlaneDependencies: Sendable {
    var sessionUserId: @Sendable (_ authorization: String?) -> String?
    var serverURL: @Sendable () -> String

    init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        serverURL: @escaping @Sendable () -> String
    ) {
        self.sessionUserId = sessionUserId
        self.serverURL = serverURL
    }
}

/// The managed MCP control plane (`/api/mcp/*`).
///
/// Server rows and assignments live in `ManagedMCPAndCardsStore`; every
/// read-modify-write is one critical section there. This type authorizes the
/// caller, validates the request shape and maps rows to ordered DTOs.
public struct ManagedMCPControlPlaneService: Sendable {
    let servers: ManagedMCPAndCardsStore
    let oauth: OAuthLedger
    let dependencies: ManagedMCPControlPlaneDependencies

    init(
        servers: ManagedMCPAndCardsStore,
        oauth: OAuthLedger,
        dependencies: ManagedMCPControlPlaneDependencies
    ) {
        self.servers = servers
        self.oauth = oauth
        self.dependencies = dependencies
    }

    // MARK: - Servers

    public func listServers(authorization: String?, serverId: String) throws -> ManagedMCPServerListResponse {
        _ = try authenticate(authorization: authorization, serverId: serverId)
        return ManagedMCPServerListResponse(
            servers: servers.managedMCPServers(serverId: serverId).map(Self.serverResponse)
        )
    }

    public func createServer(
        authorization: String?, serverId: String, body: ManagedMCPServerCreateRequest?
    ) throws -> ManagedMCPServerResponse {
        try requireManager(authorization: authorization, serverId: serverId)
        guard let body,
              let name = body.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpointUrl = body.endpointUrl
        else {
            throw ManagedMCPControlPlaneError.requestInvalid("name and endpointUrl are required")
        }
        if let code = Self.endpointError(endpointUrl) {
            throw ManagedMCPControlPlaneError.endpointInvalid(code: code)
        }
        if body.provider == "notion", body.authMode == "oauth", endpointUrl != "https://mcp.notion.com/mcp" {
            throw ManagedMCPControlPlaneError.providerMustUseManagedEndpoint
        }
        var headerNames: [String] = []
        var headers: [String: String] = [:]
        if let rawHeaders = body.headers {
            for (key, value) in rawHeaders {
                guard let text = value.castString else {
                    throw ManagedMCPControlPlaneError.requestInvalid("Header values must be strings")
                }
                headerNames.append(key)
                headers[key] = text
            }
        }
        let record = ManagedMCPServerRecord(
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: body.provider,
            authMode: body.authMode,
            oauthStatus: body.authMode == "oauth" ? "disconnected" : nil,
            endpointUrl: endpointUrl,
            toolCatalogJSON: "[]",
            catalogVersion: 1,
            credentialHeaderNames: headerNames,
            credentialHeaders: headers
        )
        servers.appendManagedMCPServer(record)
        return Self.serverResponse(record)
    }

    public func patchServer(
        authorization: String?, serverId: String, serverIdPath: String, body: ManagedMCPServerPatchRequest?
    ) throws -> ManagedMCPServerResponse {
        try requireManager(authorization: authorization, serverId: serverId)
        guard let body else { throw ManagedMCPControlPlaneError.requestInvalid("Invalid request") }
        let updated = try servers.updateManagedMCPServer(serverId: serverId, id: serverIdPath) { record in
            if let name = body.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let endpointUrl = body.endpointUrl {
                if let code = Self.endpointError(endpointUrl) {
                    throw ManagedMCPControlPlaneError.endpointInvalid(code: code)
                }
                record.endpointUrl = endpointUrl
            }
            guard let patch = body.credentialPatch else { return }
            for raw in patch.removeHeaderNames ?? [] {
                guard let headerName = raw.castString else { continue }
                record.credentialHeaders.removeValue(forKey: headerName)
                record.credentialHeaderNames.removeAll { $0.caseInsensitiveCompare(headerName) == .orderedSame }
            }
            for (key, value) in patch.upsertHeaders ?? [:] {
                guard let text = value.castString else {
                    throw ManagedMCPControlPlaneError.requestInvalid("Header values must be strings")
                }
                record.credentialHeaders[key] = text
                if !record.credentialHeaderNames.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                    record.credentialHeaderNames.append(key)
                }
            }
        }
        guard let updated else { throw ManagedMCPControlPlaneError.mcpServerNotFound }
        return Self.serverResponse(updated)
    }

    public func deleteServer(
        authorization: String?, serverId: String, serverIdPath: String
    ) throws -> OkResponse {
        try requireManager(authorization: authorization, serverId: serverId)
        guard servers.removeManagedMCPServer(serverId: serverId, id: serverIdPath) else {
            throw ManagedMCPControlPlaneError.mcpServerNotFound
        }
        return OkResponse()
    }

    public func testConfiguration(
        authorization: String?, serverId: String, body: ManagedMCPTestConfigurationRequest?
    ) throws -> OkResponse {
        let auth = try authenticate(authorization: authorization, serverId: serverId)
        guard auth.role == "owner" || auth.role == "admin" else {
            throw ManagedMCPControlPlaneError.ownersOnlyTest
        }
        guard let endpointUrl = body?.endpointUrl else {
            throw ManagedMCPControlPlaneError.requestInvalid("endpointUrl is required")
        }
        if let code = Self.endpointError(endpointUrl) {
            throw ManagedMCPControlPlaneError.endpointInvalid(code: code)
        }
        return OkResponse()
    }

    // MARK: - Agent catalog and assignments

    public func agentCatalog(
        authorization: String?, serverId: String, agentId: String
    ) throws -> ManagedMCPAgentCatalogResponse {
        guard ServerScope.isUUID(agentId) else { throw ManagedMCPControlPlaneError.agentNotFound }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            throw ManagedMCPControlPlaneError.agentNotFoundInServer
        }
        _ = try authenticate(authorization: authorization, serverId: serverId)
        return ManagedMCPAgentCatalogResponse(
            agentId: agent.id,
            agentName: agent.name,
            agentDisplayName: agent.displayName,
            servers: servers.managedMCPServers(serverId: serverId).map(Self.serverResponse)
        )
    }

    public func setAssignments(
        authorization: String?, serverId: String, agentId: String, body: ManagedMCPAssignmentsRequest?
    ) throws -> ManagedMCPAssignmentsResponse {
        _ = try authenticate(authorization: authorization, serverId: serverId)
        try requireLiveAgent(agentId, serverId: serverId)
        guard let entries = body?.assignments else {
            throw ManagedMCPControlPlaneError.requestInvalid("assignments is required")
        }
        let written = servers.replaceManagedMCPAssignments(
            serverId: serverId,
            agentId: agentId,
            entries: entries.map { ($0.mcpServerId, $0.enabled, $0.allowedTools) }
        )
        guard written == .stored else { throw ManagedMCPControlPlaneError.mcpServerNotFound }
        return ManagedMCPAssignmentsResponse(assignments: entries.compactMap { entry in
            entry.mcpServerId.map {
                ManagedMCPAssignmentResponse(mcpServerId: $0, enabled: entry.enabled, allowedTools: entry.allowedTools)
            }
        })
    }

    public func setSingleAssignment(
        authorization: String?, serverId: String, agentId: String, mcpServerId: String,
        body: ManagedMCPSingleAssignmentRequest?
    ) throws -> ManagedMCPSingleAssignmentResponse {
        _ = try authenticate(authorization: authorization, serverId: serverId)
        try requireLiveAgent(agentId, serverId: serverId)
        guard let body else { throw ManagedMCPControlPlaneError.requestInvalid("Invalid request") }
        let written = servers.setManagedMCPAssignment(
            serverId: serverId, agentId: agentId, mcpServerId: mcpServerId,
            enabled: body.enabled, allowedTools: body.allowedTools
        )
        guard written == .stored else { throw ManagedMCPControlPlaneError.mcpServerNotFound }
        return ManagedMCPSingleAssignmentResponse(assignment: ManagedMCPAssignmentResponse(
            mcpServerId: mcpServerId, enabled: body.enabled, allowedTools: body.allowedTools
        ))
    }

    // MARK: - OAuth documents

    public func oauthCallbackPage() -> ManagedMCPOAuthCallbackPage {
        ManagedMCPOAuthCallbackPage()
    }

    public func oauthClientMetadata() -> ManagedMCPOAuthClientMetadataResponse {
        let base = dependencies.serverURL().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ManagedMCPOAuthClientMetadataResponse(
            clientId: base + "/api/mcp/oauth/client-metadata",
            redirectUri: base + "/api/mcp/oauth/callback"
        )
    }

    // MARK: - Shared steps

    private func authenticate(
        authorization: String?, serverId: String
    ) throws -> (userId: String, role: String) {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ManagedMCPControlPlaneError.unauthorized
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ManagedMCPControlPlaneError.serverNotFound
        }
        return (userId, role)
    }

    private func requireManager(authorization: String?, serverId: String) throws {
        let auth = try authenticate(authorization: authorization, serverId: serverId)
        guard auth.role == "owner" || auth.role == "admin" else {
            throw ManagedMCPControlPlaneError.ownersOnlyManage
        }
    }

    private func requireLiveAgent(_ agentId: String, serverId: String) throws {
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            throw ManagedMCPControlPlaneError.agentNotFound
        }
    }

    private static func serverResponse(_ record: ManagedMCPServerRecord) -> ManagedMCPServerResponse {
        ManagedMCPServerResponse(
            id: record.id,
            name: record.name,
            provider: record.provider,
            authMode: record.authMode,
            oauthStatus: record.oauthStatus,
            endpointUrl: endpointSanitized(record.endpointUrl),
            hasCredentials: !record.credentialHeaders.isEmpty,
            credentialHeaderNames: record.credentialHeaderNames.sorted()
        )
    }

    /// The published refusal code for an endpoint that is not a public HTTPS
    /// URL without credentials, query or fragment; nil when it is acceptable.
    static func endpointError(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !raw.contains("?"), !raw.contains("#")
        else { return "managed_mcp_endpoint_invalid" }
        return nil
    }

    static func endpointSanitized(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? raw
    }
}
