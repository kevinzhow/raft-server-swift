import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {

    // MARK: - Product feedback locators (`POST/GET /internal/agent-api/feedback-locators`)

    static let feedbackLocatorForbiddenKeys: Set<String> = [
        "body", "content", "content_window", "context", "context_window", "feedback_body",
        "l3", "message_body", "path", "prompt", "raw", "raw_args", "raw_argv", "raw_error",
        "raw_value", "raw_values", "searched_paths", "searchedpaths", "session_content",
        "session_text", "stderr", "stdin", "stdout", "trajectory", "transcript", "value",
        "values", "wider_window", "window",
    ]




    public func setAgentGrantsForTesting(agentId: String, scopes: [String]) {
        lock.lock()
        agentGrantSets[agentId] = Set(scopes)
        lock.unlock()
    }

    public func resetAgentGrantsForTesting(agentId: String) {
        lock.lock()
        agentGrantSets.removeValue(forKey: agentId)
        lock.unlock()
    }

    func agentCapabilityDenial(_ authorization: String?, required: String) -> HTTPReply? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil else { return nil }
        if credential.scopes.contains(required) { return nil }
        return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\(jsonString(required))}")
    }

    func agentGrantDenial(agentId: String, scope: String) -> HTTPReply? {
        lock.lock()
        let grants = agentGrantSets[agentId]
        lock.unlock()
        guard let grants, !grants.contains(scope) else { return nil }
        return Self.json(403, "{\"error\":\"missing required scope\",\"requiredScope\":\(jsonString(scope)),\"reason\":\"missing_scope\"}")
    }


    func agentCredentialIdentity(authorization: String?, capability: String) -> (agentId: String, serverId: String)? {
        guard case .success(let agentId, let serverId) = feedbackLocatorIdentity(authorization: authorization, capability: capability) else {
            return nil
        }
        return (agentId, serverId)
    }

    func agentCredentialScopes(authorization: String?) -> [String]? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock(); defer { lock.unlock() }
        return agentCredentials[token].map { Array($0.scopes) }
    }

    func feedbackLocatorIdentity(
        authorization: String?,
        capability: String
    ) -> FeedbackLocatorIdentityResult {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .refused(Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"))
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil else {
            return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        }
        guard credential.scopes.contains(capability) else {
            return .refused(Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\(jsonString(capability))}"))
        }
        guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return .refused(Self.json(401, "{\"error\":\"Invalid agent credential\",\"code\":\"auth_required\"}"))
        }
        return .success(agentId: credential.agentId, serverId: agent.serverId)
    }

    func feedbackLocatorFailure(_ status: Int, _ reason: String) -> HTTPReply {
        Self.json(status, "{\"status\":\"failed\",\"reason_code\":\(jsonString(reason))}")
    }

    public func ingestFeedbackLocator(authorization: String?, body: String) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "send") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let envelope = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return feedbackLocatorFailure(400, "invalid_payload")
        }
        guard (envelope["artifact_kind"] as? String) == "raft-feedback-locator-v0" else {
            return feedbackLocatorFailure(400, "unknown_artifact_kind")
        }
        guard (envelope["event_kind"] as? String) == "feedback-locator:created" else {
            return feedbackLocatorFailure(400, "unknown_event_kind")
        }
        guard let payload = envelope["payload"] as? [String: Any] else {
            return feedbackLocatorFailure(400, "invalid_payload")
        }
        if Self.feedbackContainsForbiddenKey(payload) {
            return feedbackLocatorFailure(400, "forbidden_field")
        }
        let route = payload["route"] as? [String: Any]
        let resolution = route?["resolution"] as? [String: Any]
        if let resolution, (resolution["status"] as? String) != "resolved",
           resolution["target"] != nil || resolution["ref"] != nil {
            return feedbackLocatorFailure(400, "invalid_route_ref")
        }
        if let target = resolution?["target"] as? [String: Any] {
            guard (target["kind"] as? String) == "public_channel",
                  let ref = target["ref"] as? String,
                  ref.range(of: "^#[a-z0-9][a-z0-9_-]{0,126}$", options: [.regularExpression, .caseInsensitive]) != nil
            else {
                return feedbackLocatorFailure(400, "invalid_route_ref")
            }
        }
        guard (payload["schema_version"] as? String) == "raft.feedback.locator.v0" else {
            return feedbackLocatorFailure(400, "unknown_schema_version")
        }
        guard let reportId = payload["report_id"] as? String,
              ServerScope.isUUID(reportId),
              let capturedRaw = payload["captured_at"] as? String,
              let capturedAt = Self.isoDate(capturedRaw),
              let producer = payload["producer"] as? [String: Any],
              (producer["server_id"] as? String) == identity.serverId,
              (producer["agent_id"] as? String) == identity.agentId,
              let locators = payload["locators"] as? [String: Any],
              let l0 = locators["l0"] as? [String: Any],
              let runtime = l0["runtime"] as? String,
              let native = l0["native"] as? [String: Any],
              let nativeStatus = native["status"] as? String
        else {
            return feedbackLocatorFailure(400, "invalid_payload")
        }
        if (resolution?["status"] as? String) == "resolved" {
            if let delivery = route?["delivery"] as? [String: Any],
               let status = delivery["status"] as? String,
               status == "accepted" || status == "failed" {
                return feedbackLocatorFailure(400, "invalid_payload")
            }
            guard let ref = (resolution?["target"] as? [String: Any])?["ref"] as? String,
                  ref == "#proj-feedback"
            else {
                return feedbackLocatorFailure(400, "invalid_route_ref")
            }
            let name = String(ref.dropFirst())
            lock.lock()
            let exists = postableChannels.values.contains {
                $0.serverId == identity.serverId && $0.kind == "channel" && $0.name == name && $0.deletedAt == nil
            }
            lock.unlock()
            guard exists else {
                return feedbackLocatorFailure(400, "invalid_route_ref")
            }
        }
        let nativeLookupMethod = native["lookup_method"] as? String ?? "not_attempted"
        let nativeLocatorKind = native["locator_kind"] as? String ?? "none"
        var servedExactSha256: [String] = []
        if let exacts = payload["exacts"] as? [Any] {
            for entry in exacts {
                guard let row = entry as? [String: Any],
                      (row["status"] as? String) == "retained",
                      let sha = row["sha256"] as? String
                else { continue }
                servedExactSha256.append(sha)
            }
        }
        let routeBasis = (resolution?["status"] as? String) == "resolved" ? resolution?["basis"] as? String : nil
        let routeTarget = (resolution?["status"] as? String) == "resolved"
            ? (resolution?["target"] as? [String: Any])?["ref"] as? String
            : nil
        let digest = Self.sha256(Self.feedbackStableJSON(payload))
        lock.lock()
        if let existing = feedbackLocatorRecords.first(where: {
            $0.serverId == identity.serverId && $0.reportId == reportId
        }) {
            let same = existing.payloadSha256 == digest
            let receipt = existing.receiptId
            lock.unlock()
            if !same {
                return feedbackLocatorFailure(409, "report_identity_conflict")
            }
            return Self.json(200, "{\"status\":\"accepted\",\"receipt_id\":\(jsonString(receipt)),\"report_id\":\(jsonString(reportId)),\"duplicate\":true}")
        }
        let receiptId = UUID().uuidString.lowercased()
        feedbackLocatorRecords.append(FeedbackLocatorRecord(
            serverId: identity.serverId,
            producerAgentId: identity.agentId,
            reportId: reportId,
            receiptId: receiptId,
            capturedAt: capturedAt,
            runtime: runtime,
            nativeStatus: nativeStatus,
            nativeLookupMethod: nativeLookupMethod,
            nativeLocatorKind: nativeLocatorKind,
            hasServedExact: !servedExactSha256.isEmpty,
            servedExactSha256: servedExactSha256,
            routeBasis: routeBasis,
            routeTarget: routeTarget,
            payloadSha256: digest,
            createdAt: Date()
        ))
        lock.unlock()
        return Self.json(200, "{\"status\":\"accepted\",\"receipt_id\":\(jsonString(receiptId)),\"report_id\":\(jsonString(reportId)),\"duplicate\":false}")
    }

    public func listFeedbackLocators(
        authorization: String?,
        reportId: String?,
        runtime: String?,
        nativeStatus: String?,
        nativeLookupMethod: String?,
        servedExactSha256: String?,
        routeBasis: String?,
        limit rawLimit: String?
    ) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        let limit = min(max(Int(rawLimit ?? "") ?? 50, 1), 100)
        lock.lock()
        var rows = feedbackLocatorRecords
            .filter { $0.serverId == identity.serverId }
            .sorted { $0.createdAt > $1.createdAt }
        if let reportId, !reportId.isEmpty { rows = rows.filter { $0.reportId == reportId } }
        if let runtime, !runtime.isEmpty { rows = rows.filter { $0.runtime == runtime } }
        if let nativeStatus, !nativeStatus.isEmpty { rows = rows.filter { $0.nativeStatus == nativeStatus } }
        if let nativeLookupMethod, !nativeLookupMethod.isEmpty {
            rows = rows.filter { $0.nativeLookupMethod == nativeLookupMethod }
        }
        if let servedExactSha256, !servedExactSha256.isEmpty {
            rows = rows.filter { $0.servedExactSha256.contains(servedExactSha256) }
        }
        if let routeBasis, !routeBasis.isEmpty { rows = rows.filter { $0.routeBasis == routeBasis } }
        rows = Array(rows.prefix(limit))
        let locators = rows.map { row -> String in
            let shas = row.servedExactSha256.map { jsonString($0) }.joined(separator: ",")
            let basis = row.routeBasis.map(jsonString) ?? "null"
            let target = row.routeTarget.map(jsonString) ?? "null"
            return "{\"report_id\":\(jsonString(row.reportId)),\"receipt_id\":\(jsonString(row.receiptId)),\"captured_at\":\(jsonString(Self.isoString(row.capturedAt))),\"runtime\":\(jsonString(row.runtime)),\"native_status\":\(jsonString(row.nativeStatus)),\"native_lookup_method\":\(jsonString(row.nativeLookupMethod)),\"native_locator_kind\":\(jsonString(row.nativeLocatorKind)),\"has_served_exact\":\(row.hasServedExact),\"served_exact_sha256\":[\(shas)],\"route_basis\":\(basis),\"route_target\":\(target)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"locators\":[\(locators)]}")
    }

    public func addManagedMCPServerForTesting(
        serverId: String,
        name: String,
        provider: String? = nil,
        authMode: String? = nil,
        oauthStatus: String? = nil,
        endpointUrl: String = "https://example.com/mcp",
        tools: [(name: String, inputSchemaJSON: String)] = [],
        catalogVersion: Int = 1
    ) -> String {
        let id = UUID().uuidString.lowercased()
        let catalog = tools.map { tool in
            "{\"name\":\(jsonString(tool.name)),\"inputSchema\":\(tool.inputSchemaJSON)}"
        }.joined(separator: ",")
        lock.lock()
        managedMCPServers.append(ManagedMCPServerRecord(
            id: id,
            serverId: serverId,
            name: name,
            provider: provider,
            authMode: authMode,
            oauthStatus: oauthStatus,
            endpointUrl: endpointUrl,
            toolCatalogJSON: "[\(catalog)]",
            catalogVersion: catalogVersion
        ))
        lock.unlock()
        return id
    }

    func managedMCPUnavailable(_ record: ManagedMCPServerRecord) -> Bool {
        record.authMode == "oauth" && record.oauthStatus != "connected"
    }

    func managedMCPTools(_ record: ManagedMCPServerRecord) -> [(name: String, schemaJSON: String)] {
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

    public func managedMCPToolSnapshot(authorization: String?) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "mcp") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        lock.lock()
        let records = managedMCPServers.filter { $0.serverId == identity.serverId }
        lock.unlock()
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
        return Self.json(200, document)
    }

    public func callManagedMCPTool(authorization: String?, body: String) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "mcp") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawServerId = object["mcpServerId"] as? String,
              ServerScope.isUUID(rawServerId),
              let toolName = object["toolName"] as? String, !toolName.isEmpty
        else {
            return Self.json(400, "{\"code\":\"managed_mcp_invalid_request\",\"error\":\"mcpServerId must be a UUID and toolName is required\"}")
        }
        lock.lock()
        let record = managedMCPServers.first { $0.id == rawServerId && $0.serverId == identity.serverId }
        lock.unlock()
        guard let record else {
            return Self.json(404, "{\"code\":\"managed_mcp_server_not_found\",\"error\":\"MCP server not found\"}")
        }
        guard !managedMCPUnavailable(record) else {
            return Self.json(409, "{\"code\":\"managed_mcp_reconnect_required\",\"error\":\"The managed MCP connector needs to be reconnected\",\"suggestedNextAction\":\"Ask a server admin to reconnect the connector, then retry.\"}")
        }
        let staleText = "\"\(toolName)\" is no longer offered by \"\(record.name)\"; don't call it again. If you still need it, tell the person who asked."
        let offered = managedMCPTools(record).map(\.name)
        let staleVersion = object["expectedConfigVersion"] as? NSNumber
        let staleAssignment = object["expectedAssignmentVersion"] as? NSNumber
        if !offered.contains(toolName)
            || (staleVersion != nil && staleVersion?.intValue != record.catalogVersion)
            || (staleAssignment != nil && staleAssignment?.intValue != 1) {
            return Self.json(409, "{\"code\":\"managed_mcp_config_stale\",\"error\":\(jsonString(staleText)),\"suggestedNextAction\":\(jsonString(staleText))}")
        }
        return Self.json(502, "{\"code\":\"managed_mcp_upstream_unavailable\",\"error\":\"The managed MCP transport is not available in this build\"}")
    }

}
