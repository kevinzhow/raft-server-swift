import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RaftShared

/// Domain failure for the action-card, provider-connection and managed-MCP tool
/// operations.
///
/// Every case names the published error object the route answers with; the
/// feature layer only projects `status` and `body`. The legacy `{"error": …}`
/// and `{"code": …}` shapes are kept as separate DTOs so their key order does
/// not drift.
public enum ActionCardServiceError: DomainErrorWithBody, Equatable {
    case unauthorized
    case forbidden
    case notAMember
    case actionCardNotFound
    case invalidResult
    case incompatibleResult
    case invalidAgentId
    case providerConnectionNotFound
    case providerAgentAssignmentNotFound
    case providerAgentAssignmentActive
    case providerConnectionAssignmentsActive
    case invalidAuthorizationHeader
    case invalidAccessToken
    case capabilityNotAuthorized(capability: String)
    case invalidAgentCredential
    case managedMCPInvalidRequest
    case managedMCPServerNotFound
    case managedMCPReconnectRequired
    case managedMCPConfigStale(String)
    case managedMCPUpstreamUnavailable

    public var status: UInt {
        switch self {
        case .unauthorized, .invalidAuthorizationHeader, .invalidAccessToken, .invalidAgentCredential:
            401
        case .forbidden, .notAMember, .capabilityNotAuthorized:
            403
        case .actionCardNotFound, .providerConnectionNotFound,
             .providerAgentAssignmentNotFound, .managedMCPServerNotFound:
            404
        case .invalidResult, .invalidAgentId, .managedMCPInvalidRequest:
            400
        case .incompatibleResult, .providerAgentAssignmentActive,
             .providerConnectionAssignmentsActive, .managedMCPReconnectRequired,
             .managedMCPConfigStale:
            409
        case .managedMCPUpstreamUnavailable:
            502
        }
    }

    public var body: any Encodable {
        switch self {
        case .unauthorized:
            ActionCardErrorBody(error: "Unauthorized")
        case .forbidden:
            ActionCardErrorBody(error: "Forbidden")
        case .notAMember:
            ActionCardErrorBody(error: "Not a member of this server")
        case .actionCardNotFound:
            ActionCardErrorBody(error: "Action card not found", code: "NOT_FOUND")
        case .invalidResult:
            ActionCardErrorBody(error: "A result is required", code: "INVALID_RESULT")
        case .incompatibleResult:
            ActionCardErrorBody(error: "The result kind does not match this action", code: "INCOMPATIBLE_RESULT")
        case .invalidAgentId:
            ActionCardErrorBody(error: "Invalid agent id")
        case .providerConnectionNotFound:
            ActionCardErrorBody(error: "Provider connection not found")
        case .providerAgentAssignmentNotFound:
            ActionCardErrorBody(error: "Provider agent assignment not found")
        case .providerAgentAssignmentActive:
            ActionCardErrorBody(
                error: "The Agent still uses this provider connection",
                code: "provider_connection_assignment_active"
            )
        case .providerConnectionAssignmentsActive:
            ActionCardErrorBody(
                error: "Agents still use this provider connection",
                code: "provider_connection_assignment_active"
            )
        case .invalidAuthorizationHeader:
            ActionCardErrorBody(error: "Missing or invalid Authorization header", code: "auth_required")
        case .invalidAccessToken:
            ActionCardErrorBody(error: "Invalid or expired token", code: "auth_required")
        case .capabilityNotAuthorized(let capability):
            ActionCardErrorBody(
                error: "Agent credential is not authorized for this capability",
                code: "capability_not_authorized",
                requiredCapability: capability
            )
        case .invalidAgentCredential:
            ActionCardErrorBody(error: "Invalid agent credential", code: "auth_required")
        case .managedMCPInvalidRequest:
            ManagedMCPErrorBody(
                code: "managed_mcp_invalid_request",
                error: "mcpServerId must be a UUID and toolName is required"
            )
        case .managedMCPServerNotFound:
            ManagedMCPErrorBody(code: "managed_mcp_server_not_found", error: "MCP server not found")
        case .managedMCPReconnectRequired:
            ManagedMCPErrorBody(
                code: "managed_mcp_reconnect_required",
                error: "The managed MCP connector needs to be reconnected",
                suggestedNextAction: "Ask a server admin to reconnect the connector, then retry."
            )
        case .managedMCPConfigStale(let text):
            ManagedMCPErrorBody(
                code: "managed_mcp_config_stale",
                error: text,
                suggestedNextAction: text
            )
        case .managedMCPUpstreamUnavailable:
            ManagedMCPErrorBody(
                code: "managed_mcp_upstream_unavailable",
                error: "The managed MCP transport is not available in this build"
            )
        }
    }
}

/// Action-card execution plus the provider-connection and managed-MCP tool
/// operations that share its authorization model.
///
/// The service owns no state: the card, provider-connection and MCP rows live in
/// `ManagedMCPAndCardsStore`, and every lookup-plus-write runs in one store
/// critical section. The three injected closures are bridges to domains that
/// still live on `EmailLoginDirectory` (session lookup, the action-card write
/// policy and the agent-credential capability check).
public struct ActionCardService: Sendable {
    private let store: ManagedMCPAndCardsStore
    private let oauth: OAuthLedger
    private let sessionUserId: @Sendable (String?) -> String?
    private let cardWriteDecision: @Sendable (String, ActionCardRecord) -> ActionCardWriteDecision
    private let mcpIdentity: @Sendable (String?) -> FeedbackLocatorService.IdentityResolution

    init(
        store: ManagedMCPAndCardsStore,
        oauth: OAuthLedger,
        sessionUserId: @escaping @Sendable (String?) -> String?,
        cardWriteDecision: @escaping @Sendable (String, ActionCardRecord) -> ActionCardWriteDecision,
        mcpIdentity: @escaping @Sendable (String?) -> FeedbackLocatorService.IdentityResolution
    ) {
        self.store = store
        self.oauth = oauth
        self.sessionUserId = sessionUserId
        self.cardWriteDecision = cardWriteDecision
        self.mcpIdentity = mcpIdentity
    }

    // MARK: - Action cards (`POST /api/actions/:id/mark-executed`)

    /// Records an action card as carried out by the authenticated human.
    ///
    /// The upstream order is authorization (401), guest/membership (403), card
    /// lookup (404), the shared write policy, then the result-kind checks. Only
    /// `actionCardRecords` rows can be found here; prepared marketplace and
    /// integration-registration cards live in their own maps.
    public func markActionCardExecuted(
        authorization: String?,
        serverId: String,
        messageId: String,
        body: MarkActionCardExecutedRequest
    ) throws -> MarkActionCardExecutedResponse {
        guard let userId = sessionUserId(authorization) else {
            throw ActionCardServiceError.unauthorized
        }
        if oauth.memberRole(serverId: serverId, userId: userId) == "guest" {
            throw ActionCardServiceError.forbidden
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ActionCardServiceError.notAMember
        }
        guard let stored = store.actionCard(messageId: messageId) else {
            throw ActionCardServiceError.actionCardNotFound
        }
        switch cardWriteDecision(userId, stored) {
        case .allowed:
            break
        case .notMember:
            throw ActionCardServiceError.notAMember
        case .forbidden:
            throw ActionCardServiceError.forbidden
        case .notFound:
            throw ActionCardServiceError.actionCardNotFound
        }
        guard let kind = body.result?.kind else {
            throw ActionCardServiceError.invalidResult
        }
        if stored.actionType == "channel:create", kind != "channel" {
            throw ActionCardServiceError.incompatibleResult
        }
        guard store.markActionCardExecuted(messageId: messageId, userId: userId) != nil else {
            throw ActionCardServiceError.actionCardNotFound
        }
        return MarkActionCardExecutedResponse(messageId: messageId)
    }

    // MARK: - Provider connections (`/api/integrations/provider-connections`)

    /// Detaches one Agent from a provider connection.
    public func detachProviderAgent(
        authorization: String?,
        serverId: String,
        connectionId: String,
        agentId: String
    ) throws -> OkResponse {
        guard let userId = sessionUserId(authorization) else {
            throw ActionCardServiceError.unauthorized
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
            || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
        else {
            throw ActionCardServiceError.forbidden
        }
        guard agentId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            throw ActionCardServiceError.invalidAgentId
        }
        switch store.providerAssignmentLookup(
            serverId: serverId,
            connectionId: connectionId,
            agentId: agentId
        ) {
        case .connectionNotFound:
            throw ActionCardServiceError.providerConnectionNotFound
        case .assignmentNotFound:
            throw ActionCardServiceError.providerAgentAssignmentNotFound
        case .ok:
            break
        }
        let live = oauth.providerAgentInfo(serverId: serverId, agentId: agentId).map { !$0.deleted } ?? false
        if live {
            throw ActionCardServiceError.providerAgentAssignmentActive
        }
        store.removeProviderAssignment(serverId: serverId, connectionId: connectionId, agentId: agentId)
        return OkResponse()
    }

    /// Deletes a provider connection once no live Agent still uses it.
    public func deleteProviderConnection(
        authorization: String?,
        serverId: String,
        connectionId: String
    ) throws -> OkResponse {
        guard let userId = sessionUserId(authorization) else {
            throw ActionCardServiceError.unauthorized
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
            || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
        else {
            throw ActionCardServiceError.forbidden
        }
        switch store.providerConnectionLookup(serverId: serverId, connectionId: connectionId) {
        case .connectionNotFound:
            throw ActionCardServiceError.providerConnectionNotFound
        case .found(let assignments):
            let liveAssignments = assignments.filter { assignment in
                oauth.providerAgentInfo(serverId: serverId, agentId: assignment.agentId)
                    .map { !$0.deleted } ?? false
            }
            if !liveAssignments.isEmpty {
                throw ActionCardServiceError.providerConnectionAssignmentsActive
            }
        }
        store.deleteProviderConnection(serverId: serverId, connectionId: connectionId)
        return OkResponse()
    }

    // MARK: - Managed MCP agent tools

    /// `GET /internal/agent-api/mcp/tools`.
    public func managedMCPToolSnapshot(authorization: String?) throws -> ManagedMCPToolsResponse {
        let identity = try mcpScopeIdentity(authorization)
        let records = store.managedMCPServers(serverId: identity.serverId)
        var tools: [ManagedMCPTool] = []
        var unavailable: [ManagedMCPUnavailable] = []
        var catalogVersion = 1
        for record in records {
            if Self.managedMCPUnavailable(record) {
                unavailable.append(ManagedMCPUnavailable(
                    mcpServerId: record.id,
                    serverName: record.name,
                    status: "reconnect_required"
                ))
                continue
            }
            catalogVersion = max(catalogVersion, record.catalogVersion)
            for tool in Self.managedMCPTools(record) {
                tools.append(ManagedMCPTool(
                    mcpServerId: record.id,
                    serverName: record.name,
                    toolName: tool.name,
                    inputSchema: tool.inputSchema,
                    assignmentVersion: 1,
                    catalogVersion: record.catalogVersion
                ))
            }
        }
        return ManagedMCPToolsResponse(
            catalogVersion: catalogVersion,
            tools: tools,
            unavailable: unavailable.isEmpty ? nil : unavailable
        )
    }

    /// `POST /internal/agent-api/mcp/call`.
    ///
    /// The transport is not available in this build, so a request that passes
    /// the credential, connector and staleness checks still answers the
    /// upstream 502 instead of returning a DTO.
    public func callManagedMCPTool(
        authorization: String?,
        body: ManagedMCPToolCallRequest
    ) throws -> OkResponse {
        let identity = try mcpScopeIdentity(authorization)
        guard let serverId = body.mcpServerId,
              ServerScope.isUUID(serverId),
              let toolName = body.toolName,
              !toolName.isEmpty
        else {
            throw ActionCardServiceError.managedMCPInvalidRequest
        }
        guard let record = store.managedMCPServer(id: serverId, serverId: identity.serverId) else {
            throw ActionCardServiceError.managedMCPServerNotFound
        }
        guard !Self.managedMCPUnavailable(record) else {
            throw ActionCardServiceError.managedMCPReconnectRequired
        }
        let staleText = "\"\(toolName)\" is no longer offered by \"\(record.name)\"; don't call it again. If you still need it, tell the person who asked."
        let offered = Self.managedMCPTools(record).map(\.name)
        let stale = !offered.contains(toolName)
            || (body.expectedConfigVersion != nil && body.expectedConfigVersion != record.catalogVersion)
            || (body.expectedAssignmentVersion != nil && body.expectedAssignmentVersion != 1)
        if stale {
            throw ActionCardServiceError.managedMCPConfigStale(staleText)
        }
        throw ActionCardServiceError.managedMCPUpstreamUnavailable
    }

    // MARK: - Helpers

    private func mcpScopeIdentity(_ authorization: String?) throws -> (agentId: String, serverId: String) {
        switch mcpIdentity(authorization) {
        case .success(let agentId, let serverId):
            return (agentId, serverId)
        case .missingAuthorization:
            throw ActionCardServiceError.invalidAuthorizationHeader
        case .invalidAccessToken:
            throw ActionCardServiceError.invalidAccessToken
        case .capabilityNotAuthorized(let capability):
            throw ActionCardServiceError.capabilityNotAuthorized(capability: capability)
        case .invalidAgentCredential:
            throw ActionCardServiceError.invalidAgentCredential
        }
    }

    private static func managedMCPUnavailable(_ record: ManagedMCPServerRecord) -> Bool {
        record.authMode == "oauth" && record.oauthStatus != "connected"
    }

    /// The stored catalog is a JSON array of `{"name", "inputSchema"}` rows.
    /// A missing schema falls back to `{"type":"object"}`; a scalar schema
    /// falls back to `{}` exactly like the legacy serializer.
    private static func managedMCPTools(
        _ record: ManagedMCPServerRecord
    ) -> [(name: String, inputSchema: JSONValue)] {
        guard let data = record.toolCatalogJSON.data(using: .utf8),
              let rows = try? JSONDecoder().decode([[String: JSONValue]].self, from: data)
        else { return [] }
        return rows.compactMap { row in
            guard case .string(let name)? = row["name"] else { return nil }
            let schema: JSONValue
            if let raw = row["inputSchema"] {
                switch raw {
                case .object, .array:
                    schema = raw
                default:
                    schema = .object([:])
                }
            } else {
                schema = .object(["type": .string("object")])
            }
            return (name, schema)
        }
    }
}

// MARK: - Directory entry point

extension EmailLoginDirectory {
    /// Action-card execution, provider connections and managed-MCP tools.
    ///
    /// The service is stateless; the directory only supplies its store and the
    /// bridges to the not-yet-migrated auth and policy domains.
    public var actionCards: ActionCardService {
        ActionCardService(
            store: managedMCPAndCardsStore,
            oauth: oauth,
            sessionUserId: { self.sessionUserId(authorization: $0) },
            cardWriteDecision: { userId, card in
                self.actionCardIntegrationRegister.actionCardWriteDecision(
                    userId: userId,
                    card: card
                )
            },
            mcpIdentity: { authorization in
                FeedbackLocatorService(directory: self).identityResolution(
                    authorization: authorization,
                    capability: "mcp"
                )
            }
        )
    }
}
