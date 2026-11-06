import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The managed MCP control plane (`/api/mcp/*`) and agent history.
/// Migrated verbatim from the first half of `EmailLogin+ManagedMCP1.swift`.
///
/// The handlers stay on `EmailLoginDirectory`, which owns the lock and the
/// domain ledgers. This type is the named, `Sendable` handle a route can hold
/// instead of reaching for the composition root; it carries no state of its own.
public struct ManagedMCPControlPlaneService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {

    // MARK: - Managed MCP control plane (`/api/mcp/*`)


    func managedMCPControlAuth(authorization: String?, serverId: String) -> ManagedMCPControlAuth {
        guard let userId = sessionUserId(authorization: authorization) else {
            return .refused(Self.json(401, "{\"error\":\"Unauthorized\"}"))
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return .refused(Self.json(404, "{\"error\":\"Server not found\"}"))
        }
        return .ok(userId: userId, role: role)
    }



    func managedMCPServerJSON(_ record: ManagedMCPServerRecord) -> String {
        let names = record.credentialHeaderNames.sorted().map(jsonString).joined(separator: ",")
        let provider = record.provider.map(jsonString) ?? "null"
        let authMode = record.authMode.map(jsonString) ?? "null"
        let oauthStatus = record.oauthStatus.map(jsonString) ?? "null"
        return "{\"id\":\(jsonString(record.id)),\"name\":\(jsonString(record.name)),\"provider\":\(provider),\"authMode\":\(authMode),\"oauthStatus\":\(oauthStatus),\"endpointUrl\":\(jsonString(Self.managedMCPEndpointSanitized(record.endpointUrl))),\"hasCredentials\":\(!record.credentialHeaders.isEmpty),\"credentialHeaderNames\":[\(names)],\"assignment\":null}"
    }

    func managedMCPAgentJSON(agentId: String, serverId: String) -> String {
        guard let agent = oauth.agentRuntimeInfo(id: agentId) else { return "null" }
        return "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName))}"
    }

    public func listManagedMCPServers(authorization: String?, serverId: String) -> HTTPReply {
        let auth: (userId: String, role: String)
        switch managedMCPControlAuth(authorization: authorization, serverId: serverId) {
        case .refused(let reply): return reply
        case .ok(let userId, let role): auth = (userId, role)
        }
        lock.lock()
        let rows = managedMCPServers.filter { $0.serverId == serverId }.map { managedMCPServerJSON($0) }
        lock.unlock()
        _ = auth
        return Self.json(200, "{\"servers\":[\(rows.joined(separator: ","))],\"recommendations\":[{\"id\":\"notion\"},{\"id\":\"linear\"}]}")
    }

    public func createManagedMCPServer(authorization: String?, serverId: String, body: String) -> HTTPReply {
        let auth: (userId: String, role: String)
        switch managedMCPControlAuth(authorization: authorization, serverId: serverId) {
        case .refused(let reply): return reply
        case .ok(let userId, let role): auth = (userId, role)
        }
        guard auth.role == "owner" || auth.role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can manage MCP servers\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpointUrl = object["endpointUrl"] as? String
        else {
            return Self.json(400, "{\"error\":\"name and endpointUrl are required\",\"code\":\"managed_mcp_request_invalid\"}")
        }
        if let code = Self.managedMCPEndpointError(endpointUrl) {
            return Self.json(400, "{\"error\":\"Endpoint must be a public HTTPS URL without credentials, query, or fragment\",\"code\":\(jsonString(code))}")
        }
        let provider = (object["provider"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authMode = (object["authMode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "notion", authMode == "oauth", endpointUrl != "https://mcp.notion.com/mcp" {
            return Self.json(409, "{\"error\":\"That provider must use its managed endpoint\",\"code\":\"managed_mcp_auth_invalid\"}")
        }
        var headerNames: [String] = []
        var headers: [String: String] = [:]
        if let rawHeaders = object["headers"] as? [String: Any] {
            for (key, value) in rawHeaders {
                guard let text = value as? String else {
                    return Self.json(400, "{\"error\":\"Header values must be strings\",\"code\":\"managed_mcp_request_invalid\"}")
                }
                headerNames.append(key)
                headers[key] = text
            }
        }
        let id = UUID().uuidString.lowercased()
        let record = ManagedMCPServerRecord(
            id: id,
            serverId: serverId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider,
            authMode: authMode,
            oauthStatus: authMode == "oauth" ? "disconnected" : nil,
            endpointUrl: endpointUrl,
            toolCatalogJSON: "[]",
            catalogVersion: 1,
            credentialHeaderNames: headerNames,
            credentialHeaders: headers
        )
        lock.lock()
        managedMCPServers.append(record)
        lock.unlock()
        return Self.json(201, managedMCPServerJSON(record))
    }

    public func patchManagedMCPServer(authorization: String?, serverId: String, serverIdPath: String, body: String) -> HTTPReply {
        let auth: (userId: String, role: String)
        switch managedMCPControlAuth(authorization: authorization, serverId: serverId) {
        case .refused(let reply): return reply
        case .ok(let userId, let role): auth = (userId, role)
        }
        guard auth.role == "owner" || auth.role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can manage MCP servers\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid request\",\"code\":\"managed_mcp_request_invalid\"}")
        }
        lock.lock()
        guard let index = managedMCPServers.firstIndex(where: { $0.id == serverIdPath && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"MCP server not found\",\"code\":\"managed_mcp_server_not_found\"}")
        }
        if let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            managedMCPServers[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let endpointUrl = object["endpointUrl"] as? String {
            if let code = Self.managedMCPEndpointError(endpointUrl) {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Endpoint must be a public HTTPS URL without credentials, query, or fragment\",\"code\":\(jsonString(code))}")
            }
            managedMCPServers[index].endpointUrl = endpointUrl
        }
        if let patch = object["credentialPatch"] as? [String: Any] {
            if let removals = patch["removeHeaderNames"] as? [Any] {
                for raw in removals {
                    guard let headerName = raw as? String else { continue }
                    managedMCPServers[index].credentialHeaders.removeValue(forKey: headerName)
                    managedMCPServers[index].credentialHeaderNames.removeAll { $0.caseInsensitiveCompare(headerName) == .orderedSame }
                }
            }
            if let upserts = patch["upsertHeaders"] as? [String: Any] {
                for (key, value) in upserts {
                    guard let text = value as? String else {
                        lock.unlock()
                        return Self.json(400, "{\"error\":\"Header values must be strings\",\"code\":\"managed_mcp_request_invalid\"}")
                    }
                    managedMCPServers[index].credentialHeaders[key] = text
                    if !managedMCPServers[index].credentialHeaderNames.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                        managedMCPServers[index].credentialHeaderNames.append(key)
                    }
                }
            }
        }
        let record = managedMCPServers[index]
        lock.unlock()
        return Self.json(200, managedMCPServerJSON(record))
    }

    public func deleteManagedMCPServer(authorization: String?, serverId: String, serverIdPath: String) -> HTTPReply {
        let auth: (userId: String, role: String)
        switch managedMCPControlAuth(authorization: authorization, serverId: serverId) {
        case .refused(let reply): return reply
        case .ok(let userId, let role): auth = (userId, role)
        }
        guard auth.role == "owner" || auth.role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can manage MCP servers\"}")
        }
        lock.lock()
        let before = managedMCPServers.count
        managedMCPServers.removeAll { $0.id == serverIdPath && $0.serverId == serverId }
        let removed = managedMCPServers.count != before
        lock.unlock()
        guard removed else {
            return Self.json(404, "{\"error\":\"MCP server not found\",\"code\":\"managed_mcp_server_not_found\"}")
        }
        return Self.json(200, "{\"ok\":true}")
    }

    public func managedMCPAgentCatalog(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard ServerScope.isUUID(agentId) else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\",\"code\":\"managed_mcp_agent_not_found\"}")
        }
        switch managedMCPControlAuth(authorization: authorization, serverId: serverId) {
        case .refused(let reply): return reply
        case .ok: break
        }
        lock.lock()
        let rows = managedMCPServers.filter { $0.serverId == serverId }.map { managedMCPServerJSON($0) }
        lock.unlock()
        return Self.json(200, "{\"agent\":\(managedMCPAgentJSON(agentId: agentId, serverId: serverId)),\"servers\":[\(rows.joined(separator: ","))]}")
    }

    public func setManagedMCPAssignments(authorization: String?, serverId: String, agentId: String, body: String) -> HTTPReply {
        switch managedMCPControlAuth(authorization: authorization, serverId: serverId) {
        case .refused(let reply): return reply
        case .ok: break
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let raw = object["assignments"] as? [Any]
        else {
            return Self.json(400, "{\"error\":\"assignments is required\",\"code\":\"managed_mcp_request_invalid\"}")
        }
        lock.lock()
        let serverIds = Set(managedMCPServers.filter { $0.serverId == serverId }.map(\.id))
        var stored: [String: (enabled: Bool, allowedTools: [String]?)] = [:]
        var response: [String] = []
        for entry in raw {
            guard let row = entry as? [String: Any], let id = row["mcpServerId"] as? String, serverIds.contains(id) else {
                lock.unlock()
                return Self.json(404, "{\"error\":\"MCP server not found\",\"code\":\"managed_mcp_server_not_found\"}")
            }
            let enabled = row["enabled"] as? Bool ?? true
            let tools = (row["allowedTools"] as? [Any])?.compactMap { $0 as? String }
            stored[id] = (enabled, tools)
            let toolJSON = tools.map { $0.map(jsonString).joined(separator: ",") } ?? "null"
            response.append("{\"mcpServerId\":\(jsonString(id)),\"enabled\":\(enabled),\"allowedTools\":\(tools == nil ? "null" : "[\(toolJSON)]")}")
        }
        managedMCPAssignments[agentId] = stored
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"assignments\":[\(response.joined(separator: ","))]}")
    }

    public func setSingleManagedMCPAssignment(authorization: String?, serverId: String, agentId: String, mcpServerId: String, body: String) -> HTTPReply {
        switch managedMCPControlAuth(authorization: authorization, serverId: serverId) {
        case .refused(let reply): return reply
        case .ok: break
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid request\",\"code\":\"managed_mcp_request_invalid\"}")
        }
        lock.lock()
        guard managedMCPServers.contains(where: { $0.id == mcpServerId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"MCP server not found\",\"code\":\"managed_mcp_server_not_found\"}")
        }
        let enabled = object["enabled"] as? Bool ?? true
        let tools = (object["allowedTools"] as? [Any])?.compactMap { $0 as? String }
        managedMCPAssignments[agentId, default: [:]][mcpServerId] = (enabled, tools)
        lock.unlock()
        let toolJSON = tools.map { $0.map(jsonString).joined(separator: ",") } ?? "null"
        return Self.json(200, "{\"assignment\":{\"mcpServerId\":\(jsonString(mcpServerId)),\"enabled\":\(enabled),\"allowedTools\":\(tools == nil ? "null" : "[\(toolJSON)]")}}")
    }

    public func testManagedMCPConfiguration(authorization: String?, serverId: String, body: String) -> HTTPReply {
        let auth: (userId: String, role: String)
        switch managedMCPControlAuth(authorization: authorization, serverId: serverId) {
        case .refused(let reply): return reply
        case .ok(let userId, let role): auth = (userId, role)
        }
        guard auth.role == "owner" || auth.role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can test MCP servers\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let endpointUrl = object["endpointUrl"] as? String
        else {
            return Self.json(400, "{\"error\":\"endpointUrl is required\",\"code\":\"managed_mcp_request_invalid\"}")
        }
        if let code = Self.managedMCPEndpointError(endpointUrl) {
            return Self.json(400, "{\"error\":\"Endpoint must be a public HTTPS URL without credentials, query, or fragment\",\"code\":\(jsonString(code))}")
        }
        return Self.json(200, "{\"ok\":true}")
    }

    public func managedMCPOAuthCallback() -> HTTPReply {
        let body = """
        <!doctype html><html><head><title>RAFT MCP</title></head><body><main><h1>RAFT</h1><p>MCP was not connected.</p><p>Close window</p><div id=\"raft-managed-mcp-oauth-result\"></div><script type=\"application/json\" id=\"managed-mcp-oauth-result\">{}</script></main></body></html>
        """
        var reply = HTTPReply(
            status: 400,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'",
            ],
            body: body
        )
        reply.headers["Cache-Control"] = "no-store"
        return reply
    }

    public func managedMCPOAuthClientMetadata() -> HTTPReply {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let clientId = base + "/api/mcp/oauth/client-metadata"
        let redirect = base + "/api/mcp/oauth/callback"
        var reply = Self.json(200, "{\"client_id\":\(jsonString(clientId)),\"redirect_uris\":[\"\(redirect)\"]}")
        reply.headers["Cache-Control"] = "no-store"
        return reply
    }

    public func setManagedMCPServerEndpointForTesting(id: String, endpointUrl: String) {
        lock.lock()
        if let index = managedMCPServers.firstIndex(where: { $0.id == id }) {
            managedMCPServers[index].endpointUrl = endpointUrl
        }
        lock.unlock()
    }

    /// History anchors accept a sequence number, a full message UUID, or the
    /// 8-character short id. `pagination` keeps decimal values as seqs even at
    /// short-id width; `around` is a locator and prefers the short id first.
    func resolveHistoryAnchor(
        channelId: String,
        anchor: String,
        channelRef: String,
        purpose: String
    ) -> (seq: Int, failure: HTTPReply?) {
        let trimmed = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitsOnly = !trimmed.isEmpty && trimmed.allSatisfy { $0.isASCII && $0.isNumber }
        let shortIdShape = trimmed.count == 8 && trimmed.allSatisfy { $0.isHexDigit }
        let uuidShape = ServerScope.isUUID(trimmed)
        let messages = oauth.historyMessages(channelId: channelId)

        func notFound() -> (seq: Int, failure: HTTPReply?) {
            let message = "Message not found in \(channelRef): \(trimmed)"
            return (0, Self.json(404, "{\"error\":\(jsonString(message)),\"errorCode\":\"NOT_FOUND\"}"))
        }

        if purpose == "pagination", digitsOnly, let value = Int(trimmed) {
            return (value, nil)
        }
        if shortIdShape {
            let matches = messages.filter { $0.id.lowercased().hasPrefix(trimmed.lowercased()) }
            if matches.count > 1 {
                let message = "Message anchor is ambiguous in \(channelRef): \(trimmed)"
                let body = "{\"error\":\(jsonString(message)),\"errorCode\":\"AMBIGUOUS_ID\",\"suggestedNextAction\":\"Use the full message UUID instead of the 8-character short id.\"}"
                return (0, Self.json(400, body))
            }
            if let match = matches.first { return (match.seq, nil) }
            return notFound()
        }
        if digitsOnly, let value = Int(trimmed) {
            return (value, nil)
        }
        if uuidShape {
            if let match = messages.first(where: { $0.id.lowercased() == trimmed.lowercased() }) {
                return (match.seq, nil)
            }
            return notFound()
        }
        if purpose == "around" {
            let message = "Message anchor must be a seq, full UUID, or 8-character short id in \(channelRef): \(trimmed)"
            let body = "{\"error\":\(jsonString(message)),\"errorCode\":\"INVALID_ARG\"}"
            return (0, Self.json(400, body))
        }
        return notFound()
    }




    public func setReadPositionSettleForTesting(_ milliseconds: Int) {
        lock.lock(); readPositionSettleMs = milliseconds; lock.unlock()
    }

    public func agentHistory(authorization: String?, agentId: String? = nil, channelRef: String?, before: String?, after: String?, around: String? = nil, limit: String?, consume: String? = nil, unread: Bool = false) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        let machine = machines.first { $0.apiKey == token }
        lock.unlock()
        let resolvedAgentId: String
        if let credential {
            guard credential.scopes.contains("read") else {
                return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            }
            resolvedAgentId = credential.agentId
        } else if let machine, let requestedAgentId = agentId,
                  let candidate = oauth.agentRuntimeInfo(id: requestedAgentId),
                  !candidate.deleted,
                  candidate.serverId == machine.serverId {
            resolvedAgentId = requestedAgentId
        } else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: resolvedAgentId), !agent.deleted else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let reference = (channelRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else {
            return Self.json(400, "{\"error\":\"channel is required\"}")
        }
        if reference.hasPrefix("agent-event:") {
            let rawRef = String(reference.dropFirst("agent-event:".count))
            switch oauth.readThirdPartyAgentEventForAgent(agentId: agent.id, ref: rawRef) {
            case .ambiguous:
                return Self.json(409, "{\"error\":\"That 8-character event address matches more than one of your events. Use the full event id, printed as `event_id:` in the event body.\",\"errorCode\":\"AMBIGUOUS_ID\",\"suggestedNextAction\":\"raft message read --target 'agent-event:<full-event-id>'\"}")
            case .expired:
                return Self.json(410, "{\"error\":\"This third-party event has expired and its payload is no longer retained.\",\"errorCode\":\"EXPIRED\"}")
            case .absent:
                return Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
            case .found(let message):
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let id = jsonString(message.id)
                let external = message.externalEventId.map(jsonString) ?? "null"
                let payload = message.payloadJSON.isEmpty ? "{}" : message.payloadJSON
                let row = "{\"id\":\(id),\"content\":\(jsonString(message.content)),\"seq\":1,\"senderType\":\"third_party_app\",\"senderId\":\(jsonString(message.clientKey)),\"senderName\":\(jsonString(message.clientName)),\"createdAt\":\(jsonString(formatter.string(from: message.createdAt))),\"attachments\":[],\"third_party_event\":{\"id\":\(id),\"kind\":\(jsonString(message.kind)),\"client_id\":\(jsonString(message.clientKey)),\"client_name\":\(jsonString(message.clientName)),\"external_event_id\":\(external),\"payload_hash\":\(jsonString(message.payloadHash)),\"payload\":\(payload),\"expires_at\":\(jsonString(formatter.string(from: message.expiresAt)))}}"
                return Self.json(200, "{\"messages\":[\(row)],\"has_more\":false,\"has_older\":false,\"has_newer\":false}")
            }
        }
        lock.lock()
        var channelId: String?
        var canonicalTarget: String?
        var consumptionScope: String?
        var refusal: HTTPReply?
        if reference.hasPrefix("#") {
            let raw = String(reference.dropFirst())
            let segments = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = segments.first ?? raw
            let suffix = segments.count > 1 ? segments[1] : nil
            var parentId: String?
            let candidates = postableChannels.filter { _, channel in
                channel.serverId == agent.serverId
                    && channel.name == name
                    && channel.deletedAt == nil
                    && (channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint")
            }
            for (id, channel) in candidates {
                if channel.kind == "channel" {
                    parentId = id
                    break
                }
                if channel.memberIds.contains(agent.id) {
                    parentId = id
                    break
                }
                if oauth.channelAgentIds(channelId: id).contains(agent.id) {
                    parentId = id
                    break
                }
            }
            if let parentId {
                if let suffix, !suffix.isEmpty {
                    let anchor = oauth.historyMessages(channelId: parentId).first { $0.id.hasPrefix(suffix) }
                    var threadId: String?
                    if let anchor {
                        threadId = agentHistoryThread(parentId: parentId, anchorMessageId: anchor.id)
                        if threadId == nil {
                            let nextAction = "raft message read --target '#\(name)' --around \(suffix)"
                            refusal = Self.json(404, "{\"error\":\"There is no thread on message \(suffix) in #\(name)\",\"suggestedNextAction\":\(jsonString(nextAction))}")
                        }
                    } else {
                        threadId = agentHistoryThreadById(parentId: parentId, suffix: suffix)
                        if threadId == nil {
                            threadId = agentHistoryThreadByAnchorPrefix(parentId: parentId, suffix: suffix)
                        }
                        if threadId == nil {
                            refusal = Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
                        }
                    }
                    if let threadId, let thread = postableChannels[threadId] {
                        channelId = threadId
                        let anchorShort = thread.parentMessageId.map { String($0.prefix(8)) } ?? suffix
                        canonicalTarget = "#\(name):\(anchorShort)"
                    }
                } else {
                    channelId = parentId
                    canonicalTarget = "#\(name)"
                }
            } else {
                refusal = Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
            }
        } else if reference.hasPrefix("dm:@") {
            if reference.lowercased().hasPrefix("dm:@reminders") {
                let surface = agentReminderSurfaceChannels[agent.id]
                if let surface {
                    channelId = surface
                    canonicalTarget = "dm:@reminders"
                    consumptionScope = "{\"agent_id\":\(jsonString(agent.id)),\"channel_id\":\(jsonString(surface)),\"channel_type\":\"dm\",\"target\":\"dm:@reminders\"}"
                } else {
                    refusal = Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
                }
            } else {
            var raw = String(reference.dropFirst("dm:@".count))
            var suffix: String?
            if let colon = raw.lastIndex(of: ":") {
                suffix = String(raw[raw.index(after: colon)...])
                raw = String(raw[..<colon])
            }
            var kind: String?
            if let tilde = raw.firstIndex(of: "~") {
                kind = String(raw[raw.index(after: tilde)...])
                raw = String(raw[..<tilde])
            }
            let resolution = resolveDMPeerLocked(serverId: agent.serverId, agentId: agent.id, name: raw, kind: kind)
            if let failure = dmPeerFailure(resolution) {
                refusal = failure
            } else if case .resolved(let peerId, _, _) = resolution {
                if let dmId = dmChannelIdLocked(serverId: agent.serverId, agentId: agent.id, peerId: peerId) {
                    if let suffix, !suffix.isEmpty {
                        let anchor = oauth.historyMessages(channelId: dmId).first { $0.id.hasPrefix(suffix) }
                        var threadId = anchor.flatMap { found in
                            agentHistoryThread(parentId: dmId, anchorMessageId: found.id)
                        }
                        if threadId == nil {
                            threadId = agentHistoryThreadById(parentId: dmId, suffix: suffix)
                        }
                        if let threadId {
                            channelId = threadId
                            canonicalTarget = reference
                            consumptionScope = "{\"agent_id\":\(jsonString(agent.id)),\"channel_id\":\(jsonString(threadId)),\"channel_type\":\"thread\",\"target\":\(jsonString(reference))}"
                        } else {
                            refusal = Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
                        }
                    } else {
                        channelId = dmId
                        canonicalTarget = reference
                        consumptionScope = "{\"agent_id\":\(jsonString(agent.id)),\"channel_id\":\(jsonString(dmId)),\"channel_type\":\"dm\",\"target\":\(jsonString(reference))}"
                    }
                } else {
                    refusal = Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
                }
            }
            }
        } else {
            channelId = postableChannels.keys.first { $0 == reference }
        }
        let visible = channelId.flatMap { id -> Bool? in
            guard let channel = postableChannels[id] else { return nil }
            if channel.kind == "dm" {
                return channel.memberIds.contains(agent.id)
            }
            if channel.kind == "thread", let parentId = channel.parentChannelId,
               let parent = postableChannels[parentId], parent.kind == "dm" {
                return parent.memberIds.contains(agent.id)
            }
            return channel.kind == "channel" || channel.memberIds.contains(agent.id) || oauth.channelAgentIds(channelId: id).contains(agent.id)
        } ?? false
        lock.unlock()
        if let refusal { return refusal }
        guard let channelId, visible else {
            return Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
        }
        let channelCard: String = {
            lock.lock()
            defer { lock.unlock() }
            guard let channel = postableChannels[channelId], channel.kind != "dm" else { return "" }
            let cardId: String
            if channel.kind == "thread", let parent = channel.parentChannelId {
                cardId = parent
            } else {
                cardId = channelId
            }
            guard let info = oauth.channelInfo(id: cardId) else { return "" }
            let type = oauth.channelType(id: cardId) ?? "channel"
            let archived = oauth.channelArchivedAt(id: cardId) != nil || postableChannels[cardId]?.archived == true
            let description = info.description.map(jsonString) ?? "null"
            return ",\"channel_card\":{\"id\":\(jsonString(cardId)),\"name\":\(jsonString(info.name)),\"type\":\(jsonString(type)),\"description\":\(description),\"archived\":\(archived)}"
        }()
        let peerCard: String = {
            lock.lock()
            defer { lock.unlock() }
            guard let card = peerCardJSONLocked(channelId: channelId, agentId: agent.id) else { return "" }
            return ",\"peer_card\":\(card)"
        }()
        let messages = oauth.historyMessages(channelId: channelId)
        let pageLimit = min(max(Int(limit ?? "") ?? 50, 1), 100)
        // `consume=false`: return the page without marking it read, for reads
        // whose output may never reach the model.
        let consumeValue = (consume ?? "true").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard consumeValue == "true" || consumeValue == "false" else {
            return Self.json(400, "{\"error\":\"consume must be true or false\",\"errorCode\":\"INVALID_ARG\"}")
        }
        let consumePage = consumeValue == "true"
        if unread {
            guard (after ?? "").isEmpty, (before ?? "").isEmpty, (around ?? "").isEmpty else {
                let nextAction = "raft message read --target '\(canonicalTarget ?? reference)' --unread"
                return Self.json(400, "{\"error\":\"unread cannot be combined with an anchor\",\"errorCode\":\"INVALID_ARG\",\"suggestedNextAction\":\(jsonString(nextAction))}")
            }
            lock.lock()
            let priorSeq = agentChannelReadCursors["\(channelId)\n\(agent.id)"]?.seq ?? 0
            let settleMs = readPositionSettleMs
            let pendingDeferred = deferredUnreadAdvance["\(channelId)\n\(agent.id)"]
            lock.unlock()
            var priorBoundary = priorSeq
            let settledCutoff = Date().addingTimeInterval(-Double(settleMs) / 1000)
            if let pendingDeferred {
                var advanced = priorSeq
                for message in messages where message.seq > priorSeq && message.seq <= pendingDeferred && message.createdAt <= settledCutoff {
                    advanced = max(advanced, message.seq)
                }
                if advanced > priorSeq {
                    lock.lock()
                    let version = agentChannelReadCursors["\(channelId)\n\(agent.id)"]?.version ?? 0
                    agentChannelReadCursors["\(channelId)\n\(agent.id)"] = (advanced, version + 1)
                    deferredUnreadAdvance.removeValue(forKey: "\(channelId)\n\(agent.id)")
                    lock.unlock()
                    onAgentReadUpdated?(agent.serverId, channelId, agent.id, advanced)
                    priorBoundary = advanced
                } else if messages.contains(where: { $0.seq == pendingDeferred && $0.createdAt <= settledCutoff }) {
                    lock.lock()
                    deferredUnreadAdvance.removeValue(forKey: "\(channelId)\n\(agent.id)")
                    lock.unlock()
                }
            }
            let candidates = messages.filter { $0.seq > priorBoundary }
            let visible = candidates.filter { $0.senderId != agent.id }
            let page = Array(visible.prefix(pageLimit))
            let hasNewer = visible.count > page.count
            var advanceSeq = priorBoundary
            let boundary = page.map(\.seq).max() ?? priorBoundary
            for message in candidates where message.seq <= boundary && message.createdAt <= settledCutoff {
                advanceSeq = max(advanceSeq, message.seq)
            }
            if advanceSeq == priorBoundary, !page.isEmpty, let lastSeq = page.map(\.seq).max() {
                lock.lock()
                deferredUnreadAdvance["\(channelId)\n\(agent.id)"] = lastSeq
                lock.unlock()
            }
            if advanceSeq > priorBoundary {
                lock.lock()
                let version = agentChannelReadCursors["\(channelId)\n\(agent.id)"]?.version ?? 0
                agentChannelReadCursors["\(channelId)\n\(agent.id)"] = (advanceSeq, version + 1)
                lock.unlock()
                onAgentReadUpdated?(agent.serverId, channelId, agent.id, advanceSeq)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let json = page.map { message -> String in
                let senderType: String
                if message.senderId == agent.id || message.senderType == "agent" {
                    senderType = "agent"
                } else {
                    senderType = "user"
                }
                let senderName: String
                if senderType == "agent" {
                    senderName = oauth.agentRuntimeInfo(id: message.senderId)?.name ?? message.senderId
                } else {
                    lock.lock()
                    senderName = accounts.values.first { $0.id == message.senderId }?.name ?? message.senderId
                    lock.unlock()
                }
                return "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(channelId)),\"content\":\(jsonString(message.content)),\"seq\":\(message.seq),\"senderType\":\(jsonString(senderType)),\"senderId\":\(jsonString(message.senderId)),\"senderName\":\(jsonString(senderName)),\"senderTimezone\":null,\"createdAt\":\(jsonString(formatter.string(from: message.createdAt))),\"attachments\":[]}"
            }.joined(separator: ",")
            let modelSeen = page.map(\.seq).max() ?? advanceSeq
            return Self.json(200, "{\"messages\":[\(json)],\"has_more\":\(hasNewer),\"has_older\":false,\"has_newer\":\(hasNewer),\"last_read_seq\":\(priorSeq),\"unread_after_seq\":\(priorSeq),\"model_seen_up_to_seq\":\(modelSeen),\"target\":\(jsonString(canonicalTarget ?? reference))}")
        }
        var beforeSeq: Int?
        if let before, !before.isEmpty {
            let resolution = resolveHistoryAnchor(channelId: channelId, anchor: before, channelRef: reference, purpose: "pagination")
            if let failure = resolution.failure { return failure }
            beforeSeq = resolution.seq
        }
        var afterSeq: Int?
        if let after, !after.isEmpty {
            let resolution = resolveHistoryAnchor(channelId: channelId, anchor: after, channelRef: reference, purpose: "pagination")
            if let failure = resolution.failure { return failure }
            afterSeq = resolution.seq
        }
        var page: [OAuthLedger.HistoryMessage] = []
        var hasOlder = false
        var hasNewer = false
        var isAroundPage = false
        if let around, !around.isEmpty {
            let resolution = resolveHistoryAnchor(channelId: channelId, anchor: around, channelRef: reference, purpose: "around")
            if let failure = resolution.failure { return failure }
            guard let index = messages.firstIndex(where: { $0.seq == resolution.seq }) else {
                let message = "Message not found in \(reference): \(around)"
                return Self.json(404, "{\"error\":\(jsonString(message)),\"errorCode\":\"NOT_FOUND\"}")
            }
            let beforeCount = (pageLimit - 1) / 2
            let afterCount = pageLimit - beforeCount - 1
            let start = max(0, index - beforeCount)
            let end = min(messages.count, index + afterCount + 1)
            page = Array(messages[start..<end])
            hasOlder = start > 0
            hasNewer = end < messages.count
            isAroundPage = true
        } else {
            var filtered = messages
            if let beforeSeq { filtered = filtered.filter { $0.seq < beforeSeq } }
            if let afterSeq { filtered = filtered.filter { $0.seq > afterSeq } }
            let probed = filtered.count > pageLimit
            if afterSeq != nil {
                page = Array(filtered.prefix(pageLimit))
                hasOlder = false
                hasNewer = probed
            } else {
                page = Array(filtered.suffix(pageLimit))
                hasOlder = probed
                hasNewer = false
            }
        }
        let hasMore = hasOlder || hasNewer
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.lock()
        let priorSeq = agentChannelReadCursors["\(channelId)\n\(agent.id)"]?.seq ?? 0
        lock.unlock()

        // A read may advance the read position only when its window joins the
        // prior boundary without a hidden gap: an `after` page only when its
        // exclusive anchor is at/below the cursor, a latest/before page only
        // when it reaches the oldest row or overlaps the cursor. Otherwise the
        // bodies remain useful but earlier unseen rows stay unread.
        var modelSeenSeq: Int?
        if consumePage, !isAroundPage, let maximum = page.map(\.seq).max(), maximum > 0 {
            let minimum = page.map(\.seq).min() ?? maximum
            let canAdvance = afterSeq.map { $0 <= priorSeq } ?? (!hasOlder || minimum <= priorSeq)
            if canAdvance, maximum > priorSeq {
                lock.lock()
                let version = agentChannelReadCursors["\(channelId)\n\(agent.id)"]?.version ?? 0
                agentChannelReadCursors["\(channelId)\n\(agent.id)"] = (maximum, version + 1)
                lock.unlock()
                modelSeenSeq = maximum
                onAgentReadUpdated?(agent.serverId, channelId, agent.id, maximum)
            }
        }

        lock.lock()
        let pageIds = Set(page.map(\.id))
        let externalFacts: [String: (messageId: String?, provider: String?, actor: String?)] = Dictionary(
            uniqueKeysWithValues: humanMessageRows.filter { pageIds.contains($0.id) }.map {
                ($0.id, ($0.externalMessageId, $0.externalProvider, $0.externalSenderName))
            }
        )
        let mentionedIds = Set(storedMentions.filter { $0.targetType == "agent" && $0.targetId == agent.id }.map(\.messageId))
        lock.unlock()
        let json = page.map { message -> String in
            let senderType: String
            if message.messageType == "system" || message.senderId == "system" {
                senderType = "system"
            } else if message.senderType == "external_projection" {
                senderType = "third_party_app"
            } else if message.senderId == agent.id || message.senderType == "agent" {
                senderType = "agent"
            } else {
                senderType = "user"
            }
            let senderName: String
            if senderType == "agent" {
                senderName = oauth.agentRuntimeInfo(id: message.senderId)?.name ?? message.senderId
            } else {
                lock.lock()
                senderName = accounts.values.first { $0.id == message.senderId }?.name ?? message.senderId
                lock.unlock()
            }
            let senderTimezone = message.senderTimezone.map(jsonString) ?? "null"
            let mentioned = mentionedIds.contains(message.id)
            var row = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(channelId)),\"content\":\(jsonString(message.content)),\"seq\":\(message.seq),\"senderType\":\(jsonString(senderType)),\"senderId\":\(jsonString(message.senderId)),\"senderName\":\(jsonString(senderName)),\"senderTimezone\":\(senderTimezone),\"createdAt\":\(jsonString(formatter.string(from: message.createdAt))),\"attachments\":[],\"mentioned\":\(mentioned ? "true" : "false")"
            if senderType == "third_party_app", let external = externalFacts[message.id] {
                row += ",\"external_message\":{\"message_id\":\(external.messageId.map(jsonString) ?? "null"),\"provider\":\(external.provider.map(jsonString) ?? "null"),\"actor_name\":\(external.actor.map(jsonString) ?? "null")}"
            }
            return row + "}"
        }.joined(separator: ",")
        let modelSeenJSON = modelSeenSeq.map(String.init) ?? "null"
        return Self.json(200, "{\"messages\":[\(json)],\"has_more\":\(hasMore),\"has_older\":\(hasOlder),\"has_newer\":\(hasNewer),\"last_read_seq\":\(priorSeq),\"model_seen_up_to_seq\":\(modelSeenJSON),\"target\":\(jsonString(canonicalTarget ?? reference))\(consumptionScope.map { ",\"consumption_scope\":\($0)" } ?? "")\(channelCard)\(peerCard)}")
    }

    public func agentChannelMembershipFromMachine(authorization: String?, agentId: String, channelId: String, join: Bool) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let machine = machines.first { $0.apiKey == apiKey }
        let legacy = machineKeys[apiKey]
        lock.unlock()
        guard let machineServerId = machine?.serverId ?? legacy?.serverId else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == machineServerId else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        if join {
            return joinPublicChannelForAgent(agentId: agent.id, serverId: agent.serverId, channelId: channelId)
        }
        return leaveChannelForAgent(agentId: agent.id, serverId: agent.serverId, channelId: channelId)
    }
}
