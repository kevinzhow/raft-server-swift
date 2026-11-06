import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Action-card execution plus the provider-connection and managed-MCP tool
/// operations that share its authorization model.
///
/// The service reads the card, provider and MCP ledgers through the
/// directory's forwarding accessors; the directory keeps only the delegating
/// entry points and the `PushRegistration` value type.
struct ActionCardService {
    let directory: EmailLoginDirectory

    init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    // MARK: - Action cards (`POST /api/actions/:id/execute`)

    func markActionCardExecuted(authorization: String?, serverId: String, messageId: String, body: String) -> HTTPReply {
        guard let userId = directory.sessionUserId(authorization: authorization) else {
            return EmailLoginDirectory.json(401, "{\"error\":\"Unauthorized\"}")
        }
        if directory.oauth.memberRole(serverId: serverId, userId: userId) == "guest" {
            return EmailLoginDirectory.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard directory.oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return EmailLoginDirectory.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        directory.lock.lock()
        let stored = directory.actionCardRecords[messageId]
        directory.lock.unlock()
        guard let stored else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
        }
        if let refusal = directory.actionCardWriteAuthorization(userId: userId, card: stored) { return refusal }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        guard let result = object["result"] as? [String: Any], let kind = result["kind"] as? String else {
            return EmailLoginDirectory.json(400, "{\"error\":\"A result is required\",\"code\":\"INVALID_RESULT\"}")
        }
        if stored.actionType == "channel:create", kind != "channel" {
            return EmailLoginDirectory.json(409, "{\"error\":\"The result kind does not match this action\",\"code\":\"INCOMPATIBLE_RESULT\"}")
        }
        directory.lock.lock()
        guard var card = directory.actionCardRecords[messageId] else {
            directory.lock.unlock()
            return EmailLoginDirectory.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
        }
        if card.state != "executed" {
            card.state = "executed"
            card.executedByUserId = userId
            directory.actionCardRecords[messageId] = card
        }
        let metadata = directory.actionCardMetadataLocked(messageId: messageId) ?? "{\"kind\":\"action-card\",\"state\":\"executed\"}"
        directory.lock.unlock()
        return EmailLoginDirectory.json(200, "{\"messageId\":\(jsonString(messageId)),\"metadata\":\(metadata)}")
    }

    // MARK: - Provider connections (`/api/integrations/provider-connections`)

    func detachProviderAgent(authorization: String?, serverId: String, connectionId: String, agentId: String) -> HTTPReply {
        guard let userId = directory.sessionUserId(authorization: authorization) else {
            return EmailLoginDirectory.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard directory.oauth.memberRole(serverId: serverId, userId: userId) == "owner" || directory.oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return EmailLoginDirectory.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard agentId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return EmailLoginDirectory.json(400, "{\"error\":\"Invalid agent id\"}")
        }
        directory.lock.lock()
        let known = directory.providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assigned = directory.providerAssignments.contains { $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId }
        directory.lock.unlock()
        guard known else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        guard assigned else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Provider agent assignment not found\"}")
        }
        let live = directory.oauth.providerAgentInfo(serverId: serverId, agentId: agentId).map { !$0.deleted } ?? false
        if live {
            return EmailLoginDirectory.json(409, "{\"error\":\"The Agent still uses this provider connection\",\"code\":\"provider_connection_assignment_active\"}")
        }
        directory.lock.lock()
        directory.providerAssignments.removeAll { $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId }
        directory.lock.unlock()
        return EmailLoginDirectory.json(200, "{\"ok\":true}")
    }

    func deleteProviderConnection(authorization: String?, serverId: String, connectionId: String) -> HTTPReply {
        guard let userId = directory.sessionUserId(authorization: authorization) else {
            return EmailLoginDirectory.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard directory.oauth.memberRole(serverId: serverId, userId: userId) == "owner" || directory.oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return EmailLoginDirectory.json(403, "{\"error\":\"Forbidden\"}")
        }
        directory.lock.lock()
        let known = directory.providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assignments = directory.providerAssignments.filter { $0.connectionId == connectionId && $0.serverId == serverId }
        directory.lock.unlock()
        guard known else {
            return EmailLoginDirectory.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        let liveAssignments = assignments.filter { assignment in
            directory.oauth.providerAgentInfo(serverId: serverId, agentId: assignment.agentId).map { !$0.deleted } ?? false
        }
        guard liveAssignments.isEmpty else {
            return EmailLoginDirectory.json(409, "{\"error\":\"Agents still use this provider connection\",\"code\":\"provider_connection_assignment_active\"}")
        }
        directory.lock.lock()
        directory.providerConnections.removeAll { $0.id == connectionId && $0.serverId == serverId }
        directory.providerAssignments.removeAll { $0.connectionId == connectionId && $0.serverId == serverId }
        directory.lock.unlock()
        return EmailLoginDirectory.json(200, "{\"ok\":true}")
    }

    // MARK: - Managed MCP agent tools

    private func managedMCPUnavailable(_ record: ManagedMCPServerRecord) -> Bool {
        record.authMode == "oauth" && record.oauthStatus != "connected"
    }

    private func managedMCPTools(_ record: ManagedMCPServerRecord) -> [(name: String, schemaJSON: String)] {
        guard let data = record.toolCatalogJSON.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            let schema = row["inputSchema"] ?? ["type": "object"]
            let schemaData = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{}".utf8)
            return (name, String(decoding: schemaData, as: UTF8.self))
        }
    }

    func managedMCPToolSnapshot(authorization: String?) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch directory.feedbackLocatorIdentity(authorization: authorization, capability: "mcp") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        directory.lock.lock()
        let records = directory.managedMCPServers.filter { $0.serverId == identity.serverId }
        directory.lock.unlock()
        var tools: [String] = []
        var unavailable: [String] = []
        var catalogVersion = 1
        for record in records {
            if managedMCPUnavailable(record) {
                unavailable.append("{\"mcpServerId\":\(jsonString(record.id)),\"serverName\":\(jsonString(record.name)),\"status\":\"reconnect_required\"}")
                continue
            }
            catalogVersion = max(catalogVersion, record.catalogVersion)
            for tool in managedMCPTools(record) {
                tools.append("{\"mcpServerId\":\(jsonString(record.id)),\"serverName\":\(jsonString(record.name)),\"toolName\":\(jsonString(tool.name)),\"inputSchema\":\(tool.schemaJSON),\"assignmentVersion\":1,\"catalogVersion\":\(record.catalogVersion)}")
            }
        }
        var document = "{\"catalogVersion\":\(catalogVersion),\"tools\":[\(tools.joined(separator: ","))]"
        if !unavailable.isEmpty {
            document += ",\"unavailable\":[\(unavailable.joined(separator: ","))]"
        }
        document += "}"
        return EmailLoginDirectory.json(200, document)
    }

    func callManagedMCPTool(authorization: String?, body: String) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch directory.feedbackLocatorIdentity(authorization: authorization, capability: "mcp") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawServerId = object["mcpServerId"] as? String,
              ServerScope.isUUID(rawServerId),
              let toolName = object["toolName"] as? String, !toolName.isEmpty
        else {
            return EmailLoginDirectory.json(400, "{\"code\":\"managed_mcp_invalid_request\",\"error\":\"mcpServerId must be a UUID and toolName is required\"}")
        }
        directory.lock.lock()
        let record = directory.managedMCPServers.first { $0.id == rawServerId && $0.serverId == identity.serverId }
        directory.lock.unlock()
        guard let record else {
            return EmailLoginDirectory.json(404, "{\"code\":\"managed_mcp_server_not_found\",\"error\":\"MCP server not found\"}")
        }
        guard !managedMCPUnavailable(record) else {
            return EmailLoginDirectory.json(409, "{\"code\":\"managed_mcp_reconnect_required\",\"error\":\"The managed MCP connector needs to be reconnected\",\"suggestedNextAction\":\"Ask a server admin to reconnect the connector, then retry.\"}")
        }
        let staleText = "\"\(toolName)\" is no longer offered by \"\(record.name)\"; don't call it again. If you still need it, tell the person who asked."
        let offered = managedMCPTools(record).map(\.name)
        let staleVersion = object["expectedConfigVersion"] as? NSNumber
        let staleAssignment = object["expectedAssignmentVersion"] as? NSNumber
        if !offered.contains(toolName)
            || (staleVersion != nil && staleVersion?.intValue != record.catalogVersion)
            || (staleAssignment != nil && staleAssignment?.intValue != 1) {
            return EmailLoginDirectory.json(409, "{\"code\":\"managed_mcp_config_stale\",\"error\":\(jsonString(staleText)),\"suggestedNextAction\":\(jsonString(staleText))}")
        }
        return EmailLoginDirectory.json(502, "{\"code\":\"managed_mcp_upstream_unavailable\",\"error\":\"The managed MCP transport is not available in this build\"}")
    }
}

// MARK: - Directory entry points

extension EmailLoginDirectory {
    public func markActionCardExecuted(authorization: String?, serverId: String, messageId: String, body: String) -> HTTPReply {
        ActionCardService(directory: self).markActionCardExecuted(
            authorization: authorization,
            serverId: serverId,
            messageId: messageId,
            body: body
        )
    }

    public func detachProviderAgent(authorization: String?, serverId: String, connectionId: String, agentId: String) -> HTTPReply {
        ActionCardService(directory: self).detachProviderAgent(
            authorization: authorization,
            serverId: serverId,
            connectionId: connectionId,
            agentId: agentId
        )
    }

    public func deleteProviderConnection(authorization: String?, serverId: String, connectionId: String) -> HTTPReply {
        ActionCardService(directory: self).deleteProviderConnection(
            authorization: authorization,
            serverId: serverId,
            connectionId: connectionId
        )
    }

    public func managedMCPToolSnapshot(authorization: String?) -> HTTPReply {
        ActionCardService(directory: self).managedMCPToolSnapshot(authorization: authorization)
    }

    public func callManagedMCPTool(authorization: String?, body: String) -> HTTPReply {
        ActionCardService(directory: self).callManagedMCPTool(authorization: authorization, body: body)
    }

    public struct PushRegistration: Sendable {
        public var installationId: String
        public var provider: String
        public var env: String
        public var topic: String
        public var deviceToken: String
        public var appVersion: String?
        public var userId: String?
        public var serverId: String?
        public var sessionFamilyId: String?
        public var revokeCapability: String
    }
}
