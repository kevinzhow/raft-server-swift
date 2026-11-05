import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    public func leaveChannel(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(userId)
        lock.unlock()
        _ = oauth.removeChannelHuman(channelId: channelId, userId: userId)
        return Self.json(200, "{\"ok\":true}")
    }

    public func agentLeaveChannel(authorization: String?, channelId: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        return leaveChannelForAgent(agentId: agent.id, serverId: agent.serverId, channelId: channelId)
    }

    public func addChannelMembersBatch(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard role == "owner" || role == "admin" || oauth.isChannelParticipant(channelId: channelId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel members\"}")
        }
        let rawUserIds = (object["userIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        let rawAgentIds = (object["agentIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        var seenUsers = Set<String>()
        var seenAgents = Set<String>()
        let uniqueUserIds = rawUserIds.filter { seenUsers.insert($0).inserted }
        let invalidUserIds = uniqueUserIds.filter { oauth.memberRole(serverId: serverId, userId: $0) == nil }
        if !invalidUserIds.isEmpty {
            let invalid = invalidUserIds.map { jsonString($0) }.joined(separator: ",")
            return Self.json(400, "{\"error\":\"One or more users are not members of this server\",\"code\":\"users_not_in_server\",\"invalidUserIds\":[\(invalid)]}")
        }
        var addedUsers: [String] = []
        var addedAgents: [String] = []
        var alreadyUsers: [String] = []
        var alreadyAgents: [String] = []
        for agentId in rawAgentIds where assistantOwnerRaw(agentId) != nil {
            return Self.json(403, "{\"code\":\"assistant_channel_forbidden\",\"error\":\"An assistant can only be in its DM with its owner\"}")
        }
        for target in uniqueUserIds {
            guard oauth.memberRole(serverId: serverId, userId: target) != nil else { continue }
            if oauth.channelHumanIds(channelId: channelId).contains(target) {
                alreadyUsers.append(target)
            } else {
                accountsForInvite(userId: target, serverId: serverId, channelId: channelId)
                let name = accounts.values.first { $0.id == target }?.name ?? target
                recordBatchMembershipNotice(channelId: channelId, name: name)
                addedUsers.append(target)
            }
        }
        for agentId in rawAgentIds where seenAgents.insert(agentId).inserted {
            guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else { continue }
            if oauth.channelAgentIds(channelId: channelId).contains(agentId) {
                alreadyAgents.append(agentId)
            } else {
                oauth.addChannelAgent(channelId: channelId, agentId: agentId)
                addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, kind: "channel")
                let name = oauth.agentRuntimeInfo(id: agentId)?.name ?? agentId
                recordBatchMembershipNotice(channelId: channelId, name: name)
                addedAgents.append(agentId)
            }
        }
        func array(_ values: [String]) -> String {
            values.map { jsonString($0) }.joined(separator: ",")
        }
        return Self.json(200, "{\"ok\":true,\"added\":{\"userIds\":[\("\(array(addedUsers))")],\"agentIds\":[\("\(array(addedAgents))")]},\"alreadyMembers\":{\"userIds\":[\("\(array(alreadyUsers))")],\"agentIds\":[\("\(array(alreadyAgents))")]}}")
    }

    func recordBatchMembershipNotice(channelId: String, name: String) {
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            senderId: "system",
            content: "@\(name) was added to this channel.",
            randomId: nil,
            messageType: "system",
            senderType: "system"
        ))
        lock.unlock()
    }

    func accountsForInvite(userId: String, serverId: String, channelId: String) {
        lock.lock()
        postableChannels[channelId, default: PostableChannel(serverId: serverId, memberIds: [])].memberIds.insert(userId)
        lock.unlock()
        oauth.addChannelHuman(channelId: channelId, userId: userId)
    }

    public func createThreadFromChannel(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let probeAccess = channelProbeAccessLocked(channelId: channelId, serverId: serverId, userId: userId)
        lock.unlock()
        if probeAccess == .residue {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard probeAccess == .allowed else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let parentMessageId = object["parentMessageId"] as? String
        else {
            return Self.json(400, "{\"error\":\"parentMessageId is required\"}")
        }
        lock.lock()
        guard humanMessageRows.contains(where: { $0.id == parentMessageId && $0.channelId == channelId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Parent message not found\"}")
        }
        if let existing = postableChannels.first(where: { _, candidate in
            candidate.serverId == serverId && candidate.kind == "thread"
                && candidate.parentChannelId == channelId && candidate.parentMessageId == parentMessageId
                && candidate.deletedAt == nil
        }) {
            let replies = humanMessageRows.filter { $0.channelId == existing.key }
            let participants = Array(Set(replies.map(\.senderId))).sorted()
            lock.unlock()
            let participantJSON = participants.map { jsonString($0) }.joined(separator: ",")
            return Self.json(200, "{\"threadChannelId\":\(jsonString(existing.key)),\"replyCount\":\(replies.count),\"lastReplyAt\":\(replies.last.map { jsonString(ISO8601DateFormatter().string(from: $0.createdAt)) } ?? "null"),\"participantIds\":[\(participantJSON)]}")
        }
        let threadId = oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parentMessageId)
        postableChannels[threadId] = PostableChannel(
            serverId: serverId,
            memberIds: [userId],
            kind: "thread",
            parentChannelId: channelId,
            parentMessageId: parentMessageId,
            name: "thread"
        )
        threadOrder.append(threadId)
        var messageId: String?
        if let content = object["content"] as? String, !content.isEmpty {
            let id = UUID().uuidString.lowercased()
            appendHumanMessageLocked(StoredHumanMessage(
                id: id,
                channelId: threadId,
                senderId: userId,
                content: content,
                randomId: nil
            ))
            messageId = id
        }
        let parentAuthorId = humanMessageRows.first(where: { $0.id == parentMessageId })?.senderId
        lock.unlock()
        if messageId != nil {
            threadFollows["\(serverId)\n\(userId)\n\(threadId)"] = (serverId, userId, threadId, parentMessageId)
            if let parentAuthorId, parentAuthorId != userId,
               parentAuthorId != "system",
               accounts.values.contains(where: { $0.id == parentAuthorId }),
               oauth.memberRole(serverId: serverId, userId: parentAuthorId) != nil {
                threadFollows["\(serverId)\n\(parentAuthorId)\n\(threadId)"] = (serverId, parentAuthorId, threadId, parentMessageId)
            }
        }
        let messageJSON = messageId.map { jsonString($0) } ?? "null"
        return Self.json(200, "{\"threadChannelId\":\(jsonString(threadId)),\"messageId\":\(messageJSON),\"replyCount\":0,\"lastReplyAt\":null,\"participantIds\":[]}")
    }

    public func addChannelMember(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        if let reply = archivedChannelReply(channelId) { return reply }
        lock.lock()
        let actorChannelAdmin = channelHumanRoles["\(channelId)\n\(userId)"] == "admin"
        lock.unlock()
        if role != "owner" && role != "admin" && !actorChannelAdmin {
            if !oauth.isChannelParticipant(channelId: channelId, userId: userId) {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel member\"}")
        }
        if let agentId = object["agentId"] as? String {
            guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
                return Self.json(400, "{\"error\":\"Invalid agent\"}")
            }
            if assistantOwnerRaw(agentId) != nil {
                return Self.json(403, "{\"code\":\"assistant_channel_forbidden\",\"error\":\"An assistant can only be in its DM with its owner\"}")
            }
            oauth.addChannelAgent(channelId: channelId, agentId: agentId)
            // A human adding an agent is shared channel activity: announce it,
            // and keep it born-read for the acting human only. The added agent
            // stays unread on every transport (its own actions are the only
            // ones born-read for it).
            lock.lock()
            let noticeSeq = appendHumanMessageLocked(StoredHumanMessage(
                id: UUID().uuidString.lowercased(),
                channelId: channelId,
                senderId: "system",
                content: "@\(agent.name) was added to this channel.",
                randomId: nil,
                messageType: "system",
                senderType: "system"
            ))
            oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: noticeSeq)
            lock.unlock()
            return Self.json(200, "{\"ok\":true}")
        }
        if let targetUserId = object["userId"] as? String {
            guard oauth.memberRole(serverId: serverId, userId: targetUserId) != nil else {
                return Self.json(400, "{\"error\":\"Invalid member\"}")
            }
            accountsForInvite(userId: targetUserId, serverId: serverId, channelId: channelId)
            return Self.json(200, "{\"ok\":true}")
        }
        return Self.json(400, "{\"error\":\"Invalid channel member\"}")
    }

    public func removeChannelHuman(authorization: String?, serverId: String, channelId: String, memberId: String) -> HTTPReply {
        if let authorization, let userId = sessionUserId(authorization: authorization) {
            lock.lock()
            let jointRemove = jointProjections.contains { $0.localChannelId == channelId }
            lock.unlock()
            let actorServerRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
            if jointRemove, actorServerRole != "owner", actorServerRole != "admin" {
                return Self.json(403, "{\"error\":\"Only a server admin can remove joint channel members\",\"code\":\"joint_channel_admin_limited\"}")
            }
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let actorChannelAdmin = channelHumanRoles["\(channelId)\n\(userId)"] == "admin"
        lock.unlock()
        guard role == "owner" || role == "admin" || actorChannelAdmin || userId == memberId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(memberId)
        lock.unlock()
        _ = oauth.removeChannelHuman(channelId: channelId, userId: memberId)
        return Self.json(200, "{\"ok\":true}")
    }

    public func removeChannelMember(authorization: String?, serverId: String, channelId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard role == "owner" || role == "admin" || oauth.isChannelParticipant(channelId: channelId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        oauth.removeChannelAgent(channelId: channelId, agentId: agentId)
        return Self.json(200, "{\"ok\":true}")
    }

    func threadMemberMutationReply(_ channelId: String) -> HTTPReply? {
        lock.lock()
        let kind = postableChannels[channelId]?.kind ?? oauth.channelType(id: channelId)
        lock.unlock()
        guard kind == "thread" else { return nil }
        return Self.json(400, "{\"error\":\"Thread members are managed with follow/unfollow\"}")
    }

    func channelActorCanSee(channelId: String, userId: String) -> Bool {
        lock.lock()
        let postable = postableChannels[channelId]
        lock.unlock()
        if let postable {
            return postable.kind == "channel" || postable.memberIds.contains(userId)
        }
        return oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId)
    }

    /// Guests may only see channels they explicitly joined; a hidden public
    /// channel must stay cloaked for the guest role.
    func guestDeniedHiddenChannel(channelId: String, serverId: String, userId: String) -> Bool {
        guard oauth.memberRole(serverId: serverId, userId: userId) == "guest" else { return false }
        return !oauth.channelHumanIds(channelId: channelId).contains(userId)
    }

    public func channelAgentsRoute(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              channelActorCanSee(channelId: channelId, userId: userId)
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let agents = oauth.channelAgentIds(channelId: channelId).map { agentId -> String in
            let info = oauth.agentRuntimeInfo(id: agentId)
            let activity = agentActivities[agentId] ?? (activity: "offline", detail: "")
            return "{\"id\":\(jsonString(agentId)),\"name\":\(jsonString(info?.name ?? "")),\"activity\":\(jsonString(activity.activity)),\"activityDetail\":\(jsonString(activity.detail))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"agents\":[\("\(agents)")]}")
    }

    public func updateChannelHumanRole(authorization: String?, serverId: String, channelId: String, memberId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              oauth.isChannelParticipant(channelId: channelId, userId: userId)
                  || oauth.channelType(id: channelId) == "channel"
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        lock.lock()
        let actorRole = channelHumanRoles["\(channelId)\n\(userId)"]
        lock.unlock()
        let actorServerRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        guard actorRole == "admin" || actorServerRole == "owner" || actorServerRole == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let role = object["role"] as? String, role == "admin" || role == "member"
        else {
            return Self.json(400, "{\"error\":\"Invalid channel role\"}")
        }
        guard let targetRoleValue = oauth.memberRole(serverId: serverId, userId: memberId) else {
            return Self.json(404, "{\"error\":\"Member not found\"}")
        }
        let targetServerRole = targetRoleValue
        if targetServerRole == "owner" || targetServerRole == "admin" {
            return Self.json(403, "{\"error\":\"Server role is managed separately\",\"code\":\"protected_server_role\"}")
        }
        if userId == memberId, role == "member" {
            return Self.json(409, "{\"error\":\"A channel admin cannot demote themselves\",\"code\":\"channel_admin_self_demote_forbidden\"}")
        }
        lock.lock()
        channelHumanRoles["\(channelId)\n\(memberId)"] = role
        let revision = (channelAuthorityRevisions[channelId] ?? 1) + 1
        channelAuthorityRevisions[channelId] = revision
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"authorityRevision\":\(revision)}")
    }

    public func channelMembers(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              oauth.isChannelParticipant(channelId: channelId, userId: userId)
                  || oauth.channelType(id: channelId) == "channel"
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let scopeChannelId: String = {
            if let channel = postableChannels[channelId], channel.kind == "thread", let parentId = channel.parentChannelId {
                return parentId
            }
            return channelId
        }()
        lock.unlock()
        let agents = oauth.channelAgentIds(channelId: scopeChannelId).map { agentId -> String in
            let info = oauth.agentRuntimeInfo(id: agentId)
            let name = info?.name ?? ""
            let activity = agentActivities[agentId] ?? (activity: "offline", detail: "")
            return "{\"id\":\(jsonString(agentId)),\"name\":\(jsonString(name)),\"activity\":\(jsonString(activity.activity)),\"activityDetail\":\(jsonString(activity.detail))}"
        }.joined(separator: ",")
        let viewerServerRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        lock.lock()
        let viewerLocalRole = channelHumanRoles["\(channelId)\n\(userId)"]
        lock.unlock()
        let viewerIsChannelAdmin = viewerLocalRole == "admin" || viewerServerRole == "owner" || viewerServerRole == "admin"
        lock.lock()
        var rosterHumanIds = oauth.channelHumanIds(channelId: scopeChannelId)
        if let canonical = jointProjections.first(where: { $0.localChannelId == scopeChannelId })?.canonicalChannelId {
            var seen = Set(rosterHumanIds)
            for link in jointProjections where link.canonicalChannelId == canonical {
                for humanId in oauth.channelHumanIds(channelId: link.localChannelId) where seen.insert(humanId).inserted {
                    rosterHumanIds.append(humanId)
                }
            }
        }
        let rosterIds = rosterHumanIds
        lock.unlock()
        let humans = rosterIds.map { humanId -> String in
            let targetServerRole = oauth.memberRole(serverId: serverId, userId: humanId) ?? "member"
            let isLocalMember = oauth.memberRole(serverId: serverId, userId: humanId) != nil
            lock.lock()
            let targetLocalRole = channelHumanRoles["\(channelId)\n\(humanId)"]
            let displayName = accounts.values.first { $0.id == humanId }?.name ?? humanId
            lock.unlock()
            let basis: String? = targetLocalRole == "admin" ? "channel_role"
                : ((targetServerRole == "owner" || targetServerRole == "admin") ? "server_role" : nil)
            let effectiveRole = basis == nil ? "member" : "admin"
            let canChange = viewerIsChannelAdmin && isLocalMember && targetServerRole != "owner" && targetServerRole != "admin" && humanId != userId
            return "{\"id\":\(jsonString(humanId)),\"name\":\(jsonString(displayName)),\"serverRole\":\(jsonString(targetServerRole)),\"effectiveChannelRole\":\(jsonString(effectiveRole)),\"channelAdminBasis\":\(basis.map { jsonString($0) } ?? "null"),\"canChangeChannelRole\":\(canChange)}"
        }.joined(separator: ",")
        return Self.json(200, "{\"agents\":[\("\(agents)")],\"humans\":[\("\(humans)")]}")
    }

    public func deleteTask(authorization: String?, serverId: String, taskId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        let creatorId = taskRecords[index].creatorId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        if role != "owner" && role != "admin" && creatorId != userId {
            return Self.json(403, "{\"error\":\"Only the task creator can delete it\"}")
        }
        lock.lock()
        let removed = taskRecords.remove(at: index)
        if removed.hasHostMessage,
           let shadow = humanMessageRows.firstIndex(where: { $0.id == removed.messageId }) {
            humanMessageRows[shadow].taskStatus = nil
            humanMessageRows[shadow].taskNumber = nil
            humanMessageRows[shadow].taskAssigneeType = nil
            humanMessageRows[shadow].taskAssigneeId = nil
            humanMessageRows[shadow].taskClaimedAt = nil
            humanMessageRows[shadow].taskCompletedAt = nil
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func claimTask(authorization: String?, serverId: String, taskId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        lock.lock()
        guard postableChannels[channelId]?.deletedAt == nil else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"This channel was deleted; the task can only be closed\",\"code\":\"channel_deleted_terminal_only\"}")
        }
        taskRecords[index].assigneeId = userId
        taskRecords[index].assigneeType = "user"
        taskRecords[index].claimedAt = Date()
        taskRecords[index].revision += 1
        if taskRecords[index].status == "todo" { taskRecords[index].status = "in_progress" }
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    public func unclaimTask(authorization: String?, serverId: String, taskId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        lock.lock()
        let previousAssigneeId = taskRecords[index].assigneeId
        let previousAssigneeType = taskRecords[index].assigneeType
        taskRecords[index].assigneeId = nil
        taskRecords[index].assigneeType = nil
        taskRecords[index].claimedAt = nil
        taskRecords[index].revision += 1
        assigneeChangeEvents.append((
            taskId: taskId, assigneeId: nil, assigneeType: nil,
            previousAssigneeId: previousAssigneeId, previousAssigneeType: previousAssigneeType,
            actorType: "user", actorId: userId
        ))
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    public func updateTaskStatus(authorization: String?, serverId: String, taskId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let status = object["status"] as? String, Self.validTaskStatuses.contains(status)
        else {
            return Self.json(400, "{\"error\":\"Invalid task status\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        lock.lock()
        let current = taskRecords[index]
        if postableChannels[channelId]?.deletedAt != nil,
           !["done", "closed", "cancelled"].contains(status) {
            lock.unlock()
            return Self.json(409, "{\"error\":\"This channel was deleted; only terminal task statuses are allowed\",\"code\":\"channel_deleted_terminal_only\"}")
        }
        if status == "todo", current.status == "in_progress", current.assigneeId != userId {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Only the current assignee can return this task to todo\"}")
        }
        taskRecords[index].status = status
        if status == "done", taskRecords[index].completedAt == nil {
            taskRecords[index].completedAt = Date()
        }
        if status == "closed" || status == "cancelled" {
            taskRecords[index].closedAt = Date()
        }
        if status == "in_progress", taskRecords[index].claimedAt == nil {
            taskRecords[index].claimedAt = Date()
        }
        if status == "todo" {
            taskRecords[index].claimedAt = nil
        }
        taskRecords[index].revision += 1
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    public func convertMessageToTask(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let messageId = object["messageId"] as? String
        else {
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        let storedChannelId: String?
        if let known = oauth.messageChannelId(messageId) {
            storedChannelId = known
        } else {
            lock.lock()
            storedChannelId = humanMessageRows.first { $0.id == messageId }?.channelId
            lock.unlock()
        }
        guard let channelId = storedChannelId else {
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Message not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        let ids = addTasks(channelId: channelId, titles: ["Converted message"], creatorId: userId)
        lock.lock()
        for index in taskRecords.indices where ids.contains(taskRecords[index].id) {
            taskRecords[index].messageId = messageId
        }
        lock.unlock()
        return Self.json(200, "{\"taskIds\":[\("\(ids.map { jsonString($0) }.joined(separator: ","))")]}")
    }

    @discardableResult
    public func addTaskWithDescriptionForTesting(channelId: String, title: String, description: String) -> String {
        lock.lock()
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        let id = UUID().uuidString.lowercased()
        taskRecords.append(TaskRecord(
            id: id, channelId: channelId, title: title, description: description,
            status: "todo", taskNumber: taskNumber, messageId: UUID().uuidString.lowercased(),
            createdAt: Date()
        ))
        lock.unlock()
        return id
    }

    public func lastTaskServerQueryForTesting() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastTaskServerQuery
    }

    public func lastTaskServerWarningForTesting() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastTaskServerWarning
    }

    static let tasksServerResponseWarnBytes = 8 * 1024 * 1024

    func taskServerReply(_ body: String, serverId: String, newShape: Bool) -> HTTPReply {
        let bytes = Data(body.utf8).count
        if newShape, bytes > Self.tasksServerResponseWarnBytes {
            let warning = "[tasks/server] paginated/summary response for server \(serverId) is \(bytes) bytes"
            lock.lock()
            lastTaskServerWarning = warning
            lock.unlock()
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
        return HTTPReply(status: 200, headers: [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(bytes),
            "x-response-bytes": String(bytes),
        ], body: body)
    }

    public func listServerTasks(authorization: String?, serverId: String, rawQuery: String?) -> HTTPReply {
        lock.lock()
        lastTaskServerQuery = rawQuery
        lock.unlock()
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        func repeated(_ name: String) -> Bool {
            guard let rawQuery else { return false }
            return rawQuery.split(separator: "&").filter { $0.hasPrefix(name + "=") }.count > 1
        }
        if ["limit", "cursor", "detail", "status"].contains(where: repeated) {
            return Self.json(400, "{\"error\":\"Repeated query parameter\"}")
        }
        let status: String?
        switch Self.taskStatusFilter(rawQuery) {
        case .invalid(let reply): return reply
        case .valid(let value): status = value
        }
        guard let rawQuery else {
            let body = legacyTasksBody(serverId: serverId, userId: userId, status: status)
            return taskServerReply(body, serverId: serverId, newShape: false)
        }
        var params: [String: String] = [:]
        for pair in rawQuery.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { params[parts[0]] = parts[1].removingPercentEncoding ?? parts[1] }
        }
        let detail = params["detail"] ?? "full"
        guard detail == "full" || detail == "summary" else {
            return Self.json(400, "{\"error\":\"detail must be full or summary\"}")
        }
        var limit: Int?
        if let rawLimit = params["limit"] {
            guard let value = Int(rawLimit), (1...500).contains(value) else {
                return Self.json(400, "{\"error\":\"limit must be between 1 and 500\"}")
            }
            limit = value
        }
        var cursor: (channelId: String, taskNumber: Int)?
        if let rawCursor = params["cursor"] {
            guard limit != nil else {
                return Self.json(400, "{\"error\":\"cursor requires limit\"}")
            }
            guard let decoded = Self.decodeCursor(rawCursor) else {
                return Self.json(400, "{\"error\":\"Invalid cursor\"}")
            }
            cursor = decoded
        }
        let ordered = orderedTasks(serverId: serverId, userId: userId, status: status)
        var startIndex = 0
        if let cursor {
            guard let index = ordered.firstIndex(where: {
                $0.task.channelId == cursor.channelId && $0.task.taskNumber == cursor.taskNumber
            }) else {
                return Self.json(400, "{\"error\":\"Invalid cursor\"}")
            }
            startIndex = index + 1
        }
        var page = ordered
        var nextCursor: String?
        if let limit {
            let slice = Array(ordered.dropFirst(startIndex).prefix(limit))
            page = slice
            if let last = slice.last, startIndex + slice.count < ordered.count {
                nextCursor = Self.encodeCursor(channelId: last.task.channelId, taskNumber: last.task.taskNumber)
            }
        } else {
            page = Array(ordered.dropFirst(0))
        }
        let items = page.map { entry in
            detail == "summary"
                ? summaryTaskJSON(entry.task, channelName: entry.channelName, channelType: entry.channelType)
                : fullTaskJSON(entry.task, channelName: entry.channelName, channelType: entry.channelType)
        }.joined(separator: ",")
        if limit == nil {
            return taskServerReply("{\"tasks\":[\("\(items)")]}", serverId: serverId, newShape: true)
        }
        let cursorJSON = nextCursor.map { jsonString($0) } ?? "null"
        return taskServerReply("{\"tasks\":[\("\(items)")],\"next_cursor\":\(cursorJSON)}", serverId: serverId, newShape: true)
    }

    func orderedTasks(
        serverId: String,
        userId: String,
        status: String?
    ) -> [(task: TaskRecord, channelName: String, channelType: String)] {
        let visible = oauth.channelsForServer(serverId: serverId, userId: userId).filter {
            $0.joined && ($0.type == "channel" || $0.type == "joint")
                && oauth.channelArchivedAt(id: $0.id) == nil
        }
        let names = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.name) })
        let types = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.type) })
        lock.lock()
        let rows = taskRecords.filter {
            names[$0.channelId] != nil && (status == nil || $0.status == status)
        }
        lock.unlock()
        return rows
            .map { (task: $0, channelName: names[$0.channelId] ?? "", channelType: types[$0.channelId] ?? "channel") }
            .sorted {
                if $0.channelName != $1.channelName { return $0.channelName < $1.channelName }
                if $0.task.taskNumber != $1.task.taskNumber { return $0.task.taskNumber < $1.task.taskNumber }
                return $0.task.id < $1.task.id
            }
    }

    func legacyTasksBody(serverId: String, userId: String, status: String?) -> String {
        let ordered = orderedTasks(serverId: serverId, userId: userId, status: status)
        let items = ordered.map { entry in
            fullTaskJSON(entry.task, channelName: entry.channelName, channelType: entry.channelType)
        }.joined(separator: ",")
        return "{\"tasks\":[\("\(items)")]}"
    }



    func fullTaskJSON(_ task: TaskRecord, channelName: String, channelType: String) -> String {
        let description = task.description.map { jsonString($0) } ?? "null"
        return "{\"id\":\(jsonString(task.id)),\"channelId\":\(jsonString(task.channelId)),\"channelName\":\(jsonString(channelName)),\"channelType\":\(jsonString(channelType)),\"title\":\(jsonString(task.title)),\"description\":\(description),\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber),\"messageId\":\(jsonString(task.messageId)),\"revision\":\(task.revision)}"
    }

    func summaryTaskJSON(_ task: TaskRecord, channelName: String, channelType: String) -> String {
        let descriptionBytes = task.description.map { Data($0.utf8).count } ?? 0
        let hasDescription = task.description != nil && !(task.description ?? "").isEmpty
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let claimed = task.claimedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        let completed = task.completedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        let updated = task.updatedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        let createdAt = jsonString(formatter.string(from: task.createdAt))
        let assignee = task.assigneeId.map { jsonString($0) } ?? "null"
        let assigneeType = task.assigneeType.map { jsonString($0) } ?? "null"
        var claimedByName = "null"
        if let assigneeId = task.assigneeId {
            lock.lock()
            if task.assigneeType == "agent", let agent = oauth.agentRuntimeInfo(id: assigneeId) {
                claimedByName = jsonString(agent.name)
            } else if let name = accounts.values.first(where: { $0.id == assigneeId })?.name {
                claimedByName = jsonString(name)
            }
            lock.unlock()
        }
        var createdById = "null"
        var createdByName = "null"
        var createdByType = "null"
        if let creatorId = task.creatorId {
            lock.lock()
            if let agent = oauth.agentRuntimeInfo(id: creatorId) {
                createdById = jsonString(creatorId)
                createdByName = jsonString(agent.name)
                createdByType = jsonString("agent")
            } else if let name = accounts.values.first(where: { $0.id == creatorId })?.name {
                createdById = jsonString(creatorId)
                createdByName = jsonString(name)
                createdByType = jsonString("user")
            }
            lock.unlock()
        }
        return "{\"channelId\":\(jsonString(task.channelId)),\"channelName\":\(jsonString(channelName)),\"channelType\":\(jsonString(channelType)),\"claimedAt\":\(claimed),\"claimedById\":\(assignee),\"claimedByName\":\(claimedByName),\"claimedByType\":\(assigneeType),\"completedAt\":\(completed),\"createdAt\":\(createdAt),\"createdById\":\(createdById),\"createdByName\":\(createdByName),\"createdByType\":\(createdByType),\"descriptionBytes\":\(descriptionBytes),\"hasDescription\":\(hasDescription),\"id\":\(jsonString(task.id)),\"isLegacy\":false,\"messageId\":\(jsonString(task.messageId)),\"readOnlyReason\":null,\"revision\":\(task.revision),\"source\":\"tasks\",\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber),\"title\":\(jsonString(task.title)),\"updatedAt\":\(updated)}"
    }








    public func taskRevisionForTesting(taskId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first(where: { $0.id == taskId })?.revision
    }

    public func taskClaimedAtForTesting(taskId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first(where: { $0.id == taskId })?.claimedAt
    }

    public func setTaskStatusForTesting(taskId: String, status: String) {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].status = status
        }
        lock.unlock()
    }


    static let agentApiIdempotencyTTL: TimeInterval = 24 * 60 * 60



    func agentApiIdempotencyReply(agentId: String, route: String, object: [String: Any]) -> HTTPReply? {
        let rawKey = (object["idempotencyKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawKey.isEmpty else { return nil }
        let fingerprint = Self.agentApiRequestFingerprint(object)
        let now = Date()
        lock.lock()
        let existing = agentApiIdempotencyKeys.first { $0.agentId == agentId && $0.route == route && $0.key == rawKey }
        if let existing, now.timeIntervalSince(existing.createdAt) < Self.agentApiIdempotencyTTL {
            let reply: HTTPReply
            if existing.fingerprint == fingerprint {
                reply = HTTPReply(status: existing.status, headers: ["Content-Type": AppFallback.jsonContentType, "Cache-Control": "no-store", "Content-Length": String(existing.responseBody.utf8.count)], body: existing.responseBody)
            } else {
                reply = Self.json(409, "{\"error\":\"This idempotencyKey was already used for a different request\",\"code\":\"idempotency_key_reused\",\"mismatch\":\"request\",\"suggestedNextAction\":\"Retry with a new idempotencyKey.\"}")
            }
            lock.unlock()
            return reply
        }
        lock.unlock()
        return nil
    }

    func storeAgentApiIdempotency(agentId: String, route: String, object: [String: Any], reply: HTTPReply) {
        guard reply.status == 200 || reply.status == 201 else { return }
        let rawKey = (object["idempotencyKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawKey.isEmpty else { return }
        let fingerprint = Self.agentApiRequestFingerprint(object)
        lock.lock()
        if let index = agentApiIdempotencyKeys.firstIndex(where: { $0.agentId == agentId && $0.route == route && $0.key == rawKey }) {
            agentApiIdempotencyKeys.remove(at: index)
        }
        agentApiIdempotencyKeys.append(AgentApiIdempotencyRecord(
            agentId: agentId, route: route, key: rawKey, fingerprint: fingerprint,
            status: reply.status, responseBody: reply.body, createdAt: Date()
        ))
        lock.unlock()
    }

    public func taskCountForTesting(channelId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return taskRecords.filter { $0.channelId == channelId }.count
    }

    public func actionCardCountForTesting(agentId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return actionCardRecords.values.filter { $0.requesterAgentId == agentId }.count
    }

    public func agentApiIdempotencyKeysForTesting(agentId: String, route: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return agentApiIdempotencyKeys.filter { $0.agentId == agentId && $0.route == route }.map(\.key)
    }

    public func ageAgentApiIdempotencyKeysForTesting(agentId: String, seconds: TimeInterval) {
        lock.lock()
        for index in agentApiIdempotencyKeys.indices where agentApiIdempotencyKeys[index].agentId == agentId {
            agentApiIdempotencyKeys[index].createdAt = agentApiIdempotencyKeys[index].createdAt.addingTimeInterval(-seconds)
        }
        lock.unlock()
    }

    @discardableResult
    public func pruneAgentApiIdempotencyKeysForTesting(now: Date = Date(), batchSize: Int = 3, maxBatches: Int = Int.max) -> Int {
        var deleted = 0
        var batches = 0
        lock.lock()
        while batches < maxBatches {
            let expired = agentApiIdempotencyKeys.enumerated()
                .filter { now.timeIntervalSince($0.element.createdAt) >= Self.agentApiIdempotencyTTL }
                .sorted { $0.element.createdAt < $1.element.createdAt }
            guard !expired.isEmpty else { break }
            let slice = expired.prefix(max(1, batchSize))
            for entry in slice.reversed() { agentApiIdempotencyKeys.remove(at: entry.offset) }
            deleted += slice.count
            batches += 1
            if slice.count < batchSize { break }
        }
        lock.unlock()
        return deleted
    }

    public func assigneeChangeEventsForTesting(taskId: String) -> [(
        assigneeId: String?, assigneeType: String?, previousAssigneeId: String?,
        previousAssigneeType: String?, actorType: String, actorId: String
    )] {
        lock.lock()
        defer { lock.unlock() }
        return assigneeChangeEvents.filter { $0.taskId == taskId }.map {
            ($0.assigneeId, $0.assigneeType, $0.previousAssigneeId, $0.previousAssigneeType, $0.actorType, $0.actorId)
        }
    }

    public func taskStatusForTesting(taskId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.status
    }

    public func taskCompletedAtForTesting(taskId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.completedAt
    }

    public func taskClosedAtForTesting(taskId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.closedAt
    }

    public func setTaskAssigneeForTesting(taskId: String, type: String, id: String) {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].assigneeType = type
            taskRecords[index].assigneeId = id
            taskRecords[index].claimedAt = Date()
        }
        lock.unlock()
    }

    public func reopenTaskForTesting(taskId: String, status: String) {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].status = status
            taskRecords[index].completedAt = nil
            taskRecords[index].closedAt = nil
        }
        lock.unlock()
    }

    public func taskEventTypesForTesting(taskId: String) -> [(eventType: String, actorType: String)] {
        lock.lock()
        defer { lock.unlock() }
        return taskEvents.filter { $0.taskId == taskId }.map { ($0.eventType, $0.actorType) }
    }

    func closeOrphanTasksLocked(channelId: String, now: Date) {
        for index in taskRecords.indices where taskRecords[index].channelId == channelId {
            let status = taskRecords[index].status
            guard status != "done", status != "closed", status != "cancelled" else { continue }
            taskRecords[index].status = "closed"
            taskRecords[index].completedAt = now
            taskRecords[index].closedAt = now
            taskRecords[index].revision += 1
            taskEvents.append((taskId: taskRecords[index].id, eventType: "closed", actorType: "system"))
        }
    }

    public func addReminder(serverId: String, ownerAgentId: String, title: String, fireAt: Date) {
        lock.lock()
        reminderRecords.append(ReminderRecord(
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            ownerAgentId: ownerAgentId,
            title: title,
            fireAt: fireAt
        ))
        lock.unlock()
    }

    public func listReminders(authorization: String?, serverId: String, ownerAgentId: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let agents = oauth.serverAgents(serverId: serverId)
        if let ownerAgentId, !ownerAgentId.isEmpty {
            guard let agent = agents.first(where: { $0.id == ownerAgentId }) else {
                return Self.json(404, "{\"error\":\"Agent not found\"}")
            }
            guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            return Self.reminderListJSON(remindersFor([ownerAgentId]))
        }
        let visibleAgentIds: Set<String>
        if role == "owner" || role == "admin" {
            visibleAgentIds = Set(agents.map { $0.id })
        } else {
            visibleAgentIds = Set(agents.filter { $0.creatorUserId == userId }.map { $0.id })
        }
        return Self.reminderListJSON(remindersFor(visibleAgentIds))
    }

    func remindersFor(_ agentIds: Set<String>) -> [ReminderRecord] {
        lock.lock()
        defer { lock.unlock() }
        return reminderRecords.filter { agentIds.contains($0.ownerAgentId) }
    }




    public enum ReminderMutationOutcome: Sendable {
        case ok(version: Int)
        case notFound
        case conflict(currentVersion: Int)
        case invalid(String)
    }

    @discardableResult
    func appendReminderEventLocked(
        _ reminder: ReminderRecord, type: String, actorType: String, actorId: String? = nil,
        fireAt: Date? = nil
    ) -> ReminderRecord {
        var updated = reminder
        updated.updatedAt = Date()
        reminderEvents.append(ReminderEvent(
            reminderId: reminder.id, serverId: reminder.serverId, ownerAgentId: reminder.ownerAgentId,
            type: type, version: updated.version, actorType: actorType, actorId: actorId,
            createdAt: updated.updatedAt, fireAt: fireAt
        ))
        return updated
    }

    @discardableResult
    public func createAppReminderForTesting(
        serverId: String, ownerAgentId: String, title: String, fireAt: Date,
        notes: String? = nil, recurrenceJSON: String? = nil,
        channelId: String? = nil, threadId: String? = nil,
        actorType: String = "agent", actorId: String? = nil
    ) -> String {
        lock.lock()
        let reminder = ReminderRecord(
            id: UUID().uuidString.lowercased(), serverId: serverId, ownerAgentId: ownerAgentId,
            title: title, fireAt: fireAt, status: "scheduled", version: 1, notes: notes,
            recurrenceJSON: recurrenceJSON, channelId: channelId, threadId: threadId,
            createdAt: Date(), updatedAt: Date()
        )
        reminderRecords.append(appendReminderEventLocked(reminder, type: "scheduled", actorType: actorType, actorId: actorId))
        lock.unlock()
        return reminder.id
    }

    public func appReminderRowForTesting(id: String) -> (status: String, version: Int, title: String, fireAt: Date)? {
        lock.lock()
        defer { lock.unlock() }
        guard let reminder = reminderRecords.first(where: { $0.id == id }) else { return nil }
        return (reminder.status, reminder.version, reminder.title, reminder.fireAt)
    }

    public func appReminderEventsForTesting(reminderId: String) -> [(type: String, version: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return reminderEvents.filter { $0.reminderId == reminderId }.map { ($0.type, $0.version) }
    }

    public func cancelAppReminder(reminderId: String, ownerAgentId: String, expectedVersion: Int) -> ReminderMutationOutcome {
        mutateAppReminder(reminderId: reminderId, ownerAgentId: ownerAgentId, expectedVersion: expectedVersion, type: "canceled") { reminder in
            reminder.status = "canceled"
        }
    }

    public func snoozeAppReminder(
        reminderId: String, ownerAgentId: String, expectedVersion: Int, fireAt: Date
    ) -> ReminderMutationOutcome {
        mutateAppReminder(reminderId: reminderId, ownerAgentId: ownerAgentId, expectedVersion: expectedVersion, type: "snoozed") { reminder in
            reminder.status = "scheduled"
            reminder.fireAt = fireAt
        }
    }

    public func updateAppReminder(
        reminderId: String, ownerAgentId: String, expectedVersion: Int,
        title: String?, fireAt: Date?, notes: String?
    ) -> ReminderMutationOutcome {
        guard title != nil || fireAt != nil || notes != nil else {
            return .invalid("no update fields")
        }
        return mutateAppReminder(reminderId: reminderId, ownerAgentId: ownerAgentId, expectedVersion: expectedVersion, type: "updated") { reminder in
            if let title { reminder.title = title }
            if let fireAt { reminder.fireAt = fireAt }
            if let notes { reminder.notes = notes }
        }
    }

    func mutateAppReminder(
        reminderId: String, ownerAgentId: String, expectedVersion: Int, type: String,
        mutate: (inout ReminderRecord) -> Void
    ) -> ReminderMutationOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let index = reminderRecords.firstIndex(where: { $0.id == reminderId && $0.ownerAgentId == ownerAgentId }) else {
            return .notFound
        }
        if type == "updated", reminderRecords[index].status == "fired" {
            return .invalid("cannot update a fired reminder; snooze it back to scheduled first")
        }
        if type == "snoozed", reminderRecords[index].status == "canceled" {
            return .invalid("cannot snooze a canceled reminder")
        }
        guard reminderRecords[index].version == expectedVersion else {
            return .conflict(currentVersion: reminderRecords[index].version)
        }
        var reminder = reminderRecords[index]
        mutate(&reminder)
        reminder.version += 1
        let updated = appendReminderEventLocked(reminder, type: type, actorType: "agent", actorId: ownerAgentId)
        reminderRecords[index] = updated
        return .ok(version: updated.version)
    }

    public func listAppReminders(
        serverId: String, ownerAgentId: String, status: String?
    ) -> (rows: [(id: String, status: String, version: Int, title: String, fireAt: Date)], invalidStatus: Bool) {
        let allowed = Set(["scheduled", "canceled", "fired", "all"])
        var wanted: Set<String>?
        if let status, !status.isEmpty {
            let parts = status.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !parts.isEmpty, parts.allSatisfy({ allowed.contains($0) }) else {
                return ([], true)
            }
            if !parts.contains("all") { wanted = Set(parts) }
        }
        lock.lock()
        defer { lock.unlock() }
        let rows = reminderRecords.filter { reminder in
            reminder.serverId == serverId && reminder.ownerAgentId == ownerAgentId
                && (wanted == nil || wanted!.contains(reminder.status))
        }.map { ($0.id, $0.status, $0.version, $0.title, $0.fireAt) }
        return (rows, false)
    }

    public func fireAppReminderForTesting(reminderId: String) -> ReminderMutationOutcome {
        mutateAppReminder(reminderId: reminderId, ownerAgentId: ownerAgentIdForReminder(reminderId) ?? "",
                          expectedVersion: appReminderRowForTesting(id: reminderId)?.version ?? 0, type: "fired") { reminder in
            reminder.status = "fired"
        }
    }

    public func agentIdForReminderTesting(reminderId: String) -> String? {
        ownerAgentIdForReminder(reminderId)
    }

    public func ownerAgentIdForReminder(_ reminderId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return reminderRecords.first(where: { $0.id == reminderId })?.ownerAgentId
    }

    public func appReminderEventLogForTesting(reminderId: String) -> [(eventType: String, version: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return reminderEvents.filter { $0.reminderId == reminderId }
            .sorted { $0.createdAt > $1.createdAt }
            .map { ($0.type, $0.version) }
    }

    public func serverMemberRoles(serverId: String) -> [(userId: String, role: String)] {
        oauth.memberRoles(serverId: serverId)
    }

    static let remindersMovedReply = json(409, "{\"error\":\"Reminders are managed by the Reminder App now\",\"code\":\"reminders_moved_to_app\"}")

    func legacyReminderWritesMoved(serverId: String) -> Bool {
        featureFlagEnabledForServer("reminder_app", serverId: serverId)
    }

    func legacyReminderMachine(_ authorization: String?) -> (machineId: String, serverId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let key = String(authorization.dropFirst("Bearer ".count))
        guard let machine = machineCredential(apiKey: key) else { return nil }
        return (machine.machineId, machine.serverId)
    }

    func reminderAgentOnServer(_ agentId: String, serverId: String) -> OAuthLedger.AgentRuntimeInfo? {
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return nil
        }
        return agent
    }


    public func legacyReminderList(authorization: String?, agentId: String, status: String?) -> HTTPReply {
        guard let machine = legacyReminderMachine(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard reminderAgentOnServer(agentId, serverId: machine.serverId) != nil else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        let listed = listAppReminders(serverId: machine.serverId, ownerAgentId: agentId, status: status)
        if listed.invalidStatus {
            return Self.json(400, "{\"error\":\"Invalid status filter\"}")
        }
        let rows = listed.rows.map {
            Self.reminderSummaryJSON(($0.id, $0.status, $0.version, $0.title), ownerAgentId: agentId, fireAt: $0.fireAt)
        }.joined(separator: ",")
        return Self.json(200, "{\"reminders\":[\(rows)]}")
    }

    public func legacyReminderCreate(authorization: String?, agentId: String, body: String) -> HTTPReply {
        guard let machine = legacyReminderMachine(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let agent = reminderAgentOnServer(agentId, serverId: machine.serverId) else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        if legacyReminderWritesMoved(serverId: machine.serverId) { return Self.remindersMovedReply }
        guard agent.runtime != "external" else {
            return Self.json(409, "{\"error\":\"External agents cannot create reminders\",\"code\":\"reminders_unsupported_for_external_agents\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else {
            return Self.json(400, "{\"error\":\"title is required\"}")
        }
        guard let messageId = object["msgId"] as? String, !messageId.isEmpty else {
            return Self.json(400, "{\"error\":\"msgId is required for agent-created reminders\"}")
        }
        let fireAt: Date
        if let raw = object["fireAt"] as? String, let parsed = ISO8601DateFormatter().date(from: raw) {
            fireAt = parsed
        } else if let delay = object["delaySeconds"] as? Int, delay >= 0 {
            fireAt = Date().addingTimeInterval(Double(delay))
        } else {
            return Self.json(400, "{\"error\":\"fireAt or delaySeconds is required\"}")
        }
        let id = createAppReminderForTesting(
            serverId: machine.serverId, ownerAgentId: agentId, title: title, fireAt: fireAt,
            notes: object["notes"] as? String, recurrenceJSON: object["recurrence"] as? String,
            channelId: object["channelId"] as? String, threadId: object["threadId"] as? String,
            actorType: "agent", actorId: agentId
        )
        let row = (id: id, status: "scheduled", version: 1, title: title)
        return Self.json(200, "{\"reminder\":\(Self.reminderSummaryJSON(row))}")
    }

    public func legacyReminderCancel(authorization: String?, agentId: String, reminderId: String, body: String) -> HTTPReply {
        guard legacyReminderMachine(authorization) != nil else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let expected = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["expectedVersion"] as? Int ?? 0
        switch cancelAppReminder(reminderId: reminderId, ownerAgentId: agentId, expectedVersion: expected) {
        case .notFound:
            return Self.json(404, "{\"error\":\"Reminder not found\"}")
        case .conflict(let current):
            return Self.json(409, "{\"error\":\"Reminder version conflict\",\"currentVersion\":\(current)}")
        case .invalid:
            return Self.json(400, "{\"error\":\"Invalid reminder update\"}")
        case .ok(let version):
            let row = (id: reminderId, status: "canceled", version: version, title: appReminderRowForTesting(id: reminderId)?.title ?? "")
            return Self.json(200, "{\"reminder\":\(Self.reminderSummaryJSON(row))}")
        }
    }

    func reminderMutationReply(_ outcome: ReminderMutationOutcome, reminderId: String, ownerAgentId: String) -> HTTPReply {
        switch outcome {
        case .notFound:
            return Self.json(404, "{\"error\":\"Reminder not found\"}")
        case .conflict(let current):
            return Self.json(409, "{\"error\":\"Reminder version conflict\",\"currentVersion\":\(current)}")
        case .invalid(let message):
            return Self.json(409, "{\"error\":\(jsonString(message))}")
        case .ok:
            let row = appReminderRowForTesting(id: reminderId)
            let summary = Self.reminderSummaryJSON(
                (reminderId, row?.status ?? "scheduled", row?.version ?? 0, row?.title ?? ""),
                ownerAgentId: ownerAgentId, fireAt: row?.fireAt
            )
            return Self.json(200, "{\"reminder\":\(summary)}")
        }
    }

    public func legacyReminderSnooze(authorization: String?, agentId: String, reminderId: String, body: String) -> HTTPReply {
        guard let machine = legacyReminderMachine(authorization) else { return Self.json(401, "{\"error\":\"Unauthorized\"}") }
        if legacyReminderWritesMoved(serverId: machine.serverId) { return Self.remindersMovedReply }
        guard let row = appReminderRowForTesting(id: reminderId), row.status != "canceled" else {
            return Self.json(404, "{\"error\":\"Reminder not found\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let fireAt: Date
        if let raw = object["fireAt"] as? String, let parsed = ISO8601DateFormatter().date(from: raw) {
            fireAt = parsed
        } else if let delay = object["delaySeconds"] as? Int, delay >= 0 {
            fireAt = Date().addingTimeInterval(Double(delay))
        } else {
            return Self.json(400, "{\"error\":\"fireAt or delaySeconds is required\"}")
        }
        let outcome = snoozeAppReminder(reminderId: reminderId, ownerAgentId: agentId, expectedVersion: row.version, fireAt: fireAt)
        return reminderMutationReply(outcome, reminderId: reminderId, ownerAgentId: agentId)
    }

    public func legacyReminderUpdate(authorization: String?, agentId: String, reminderId: String, body: String) -> HTTPReply {
        guard let machine = legacyReminderMachine(authorization) else { return Self.json(401, "{\"error\":\"Unauthorized\"}") }
        if legacyReminderWritesMoved(serverId: machine.serverId) { return Self.remindersMovedReply }
        guard let row = appReminderRowForTesting(id: reminderId) else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid reminder update\"}")
        }
        let fireAt = (object["fireAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let outcome = updateAppReminder(
            reminderId: reminderId, ownerAgentId: agentId, expectedVersion: row.version,
            title: object["title"] as? String, fireAt: fireAt, notes: object["notes"] as? String
        )
        return reminderMutationReply(outcome, reminderId: reminderId, ownerAgentId: agentId)
    }


    public func legacyReminderLog(authorization: String?, agentId: String, reminderId: String) -> HTTPReply {
        guard legacyReminderMachine(authorization) != nil else { return Self.json(401, "{\"error\":\"Unauthorized\"}") }
        guard ownerAgentIdForReminder(reminderId) == agentId else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        return Self.json(200, Self.reminderLogJSON(appReminderEventLogForTesting(reminderId: reminderId)))
    }

    public func agentApiReminderCancel(authorization: String?, reminderId: String) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}") }
        guard let row = appReminderRowForTesting(id: reminderId) else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        return reminderMutationReply(
            cancelAppReminder(reminderId: reminderId, ownerAgentId: agent.id, expectedVersion: row.version),
            reminderId: reminderId, ownerAgentId: agent.id
        )
    }

    public func agentApiReminderSnooze(authorization: String?, reminderId: String, body: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}") }
        guard let row = appReminderRowForTesting(id: reminderId) else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let fireAt: Date
        if let raw = object["fireAt"] as? String, let parsed = ISO8601DateFormatter().date(from: raw) {
            fireAt = parsed
        } else if let delay = object["delaySeconds"] as? Int, delay >= 0 {
            fireAt = Date().addingTimeInterval(Double(delay))
        } else {
            return Self.json(400, "{\"error\":\"fireAt or delaySeconds is required\"}")
        }
        return reminderMutationReply(
            snoozeAppReminder(reminderId: reminderId, ownerAgentId: agent.id, expectedVersion: row.version, fireAt: fireAt),
            reminderId: reminderId, ownerAgentId: agent.id
        )
    }

    public func agentApiReminderUpdate(authorization: String?, reminderId: String, body: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}") }
        guard let row = appReminderRowForTesting(id: reminderId) else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid reminder update\"}")
        }
        let fireAt = (object["fireAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return reminderMutationReply(
            updateAppReminder(
                reminderId: reminderId, ownerAgentId: agent.id, expectedVersion: row.version,
                title: object["title"] as? String, fireAt: fireAt, notes: object["notes"] as? String
            ),
            reminderId: reminderId, ownerAgentId: agent.id
        )
    }

    public func agentApiReminderLog(authorization: String?, reminderId: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}") }
        guard ownerAgentIdForReminder(reminderId) == agent.id else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        return Self.json(200, Self.reminderLogJSON(appReminderEventLogForTesting(reminderId: reminderId)))
    }

    public func agentApiReminderList(authorization: String?, status: String?) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let listed = listAppReminders(serverId: agent.serverId, ownerAgentId: agent.id, status: status)
        if listed.invalidStatus {
            return Self.json(400, "{\"error\":\"Invalid status filter\"}")
        }
        let rows = listed.rows.map {
            Self.reminderSummaryJSON(($0.id, $0.status, $0.version, $0.title), ownerAgentId: agent.id, fireAt: $0.fireAt)
        }.joined(separator: ",")
        return Self.json(200, "{\"reminders\":[\(rows)]}")
    }

    public func agentApiReminderCreate(authorization: String?, body: String) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard agent.runtime != "external" else {
            return Self.json(409, "{\"error\":\"External agents cannot create reminders\",\"code\":\"reminders_unsupported_for_external_agents\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else {
            return Self.json(400, "{\"error\":\"title is required\"}")
        }
        guard let messageId = object["msgId"] as? String, !messageId.isEmpty else {
            return Self.json(400, "{\"error\":\"msgId is required for agent-created reminders\"}")
        }
        _ = messageId
        let fireAt: Date
        if let raw = object["fireAt"] as? String, let parsed = ISO8601DateFormatter().date(from: raw) {
            fireAt = parsed
        } else if let delay = object["delaySeconds"] as? Int, delay >= 0 {
            fireAt = Date().addingTimeInterval(Double(delay))
        } else {
            return Self.json(400, "{\"error\":\"fireAt or delaySeconds is required\"}")
        }
        let id = createAppReminderForTesting(
            serverId: agent.serverId, ownerAgentId: agent.id, title: title, fireAt: fireAt,
            notes: object["notes"] as? String, recurrenceJSON: object["recurrence"] as? String,
            channelId: object["channelId"] as? String, threadId: object["threadId"] as? String,
            actorType: "agent", actorId: agent.id
        )
        let row = (id: id, status: "scheduled", version: 1, title: title)
        return Self.json(200, "{\"reminder\":\(Self.reminderSummaryJSON(row))}")
    }

    public func saveChannelMessage(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let messageId = object["messageId"] as? String,
              oauth.saveMessage(userId: userId, messageId: messageId)
        else {
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        return Self.json(200, "{\"ok\":true}")
    }

    public func checkSavedMessages(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let messageIds = object["messageIds"] as? [String]
        else {
            return Self.json(400, "{\"error\":\"Invalid saved check request\"}")
        }
        let saved = Set(oauth.savedMessages(userId: userId).map(\.messageId))
        lock.lock()
        let visible = messageIds.filter { id in
            guard saved.contains(id) else { return false }
            guard let entry = oauth.savedMessages(userId: userId).first(where: { $0.messageId == id }) else { return false }
            if let scope = postableChannels[entry.channelId] {
                guard scope.serverId == serverId, scope.deletedAt == nil, !scope.archived else { return false }
                return scope.kind == "channel" || scope.memberIds.contains(userId)
            }
            return true
        }
        lock.unlock()
        let ids = visible.map { jsonString($0) }.joined(separator: ",")
        return Self.json(200, "{\"savedIds\":[\("\(ids)")]}")
    }

    public func listSavedMessages(
        authorization: String?,
        serverId: String,
        query: String?,
        channelId: String?,
        sort: String?,
        limit: Int,
        offset: Int
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        var entries = oauth.savedMessages(userId: userId)
        lock.lock()
        entries = entries.filter { entry in
            if let scope = postableChannels[entry.channelId] {
                guard scope.serverId == serverId, scope.deletedAt == nil, !scope.archived else { return false }
                if scope.kind == "channel" { return true }
                return scope.memberIds.contains(userId)
            }
            if let parentChannelId = entry.parentChannelId, let parent = postableChannels[parentChannelId] {
                guard parent.serverId == serverId, parent.deletedAt == nil, !parent.archived else { return false }
                return parent.kind == "channel" || parent.memberIds.contains(userId)
            }
            return true
        }
        lock.unlock()
        if let channelId, !channelId.isEmpty {
            entries = entries.filter { $0.channelId == channelId || $0.parentChannelId == channelId }
        }
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needle = query.lowercased()
            entries = entries.filter {
                $0.content.lowercased().contains(needle)
                    || ($0.parentMessagePreview?.lowercased().contains(needle) ?? false)
            }
        }
        if sort == "asc" {
            entries.sort { $0.savedAt < $1.savedAt }
        } else {
            entries.sort { $0.savedAt > $1.savedAt }
        }
        let total = entries.count
        let page = Array(entries.dropFirst(max(0, offset)).prefix(max(0, limit)))
        let rows = page.map { entry -> String in
            let parentChannel = entry.parentChannelId.map { jsonString($0) } ?? "null"
            let parentMessage = entry.parentMessageId.map { jsonString($0) } ?? "null"
            let preview = entry.parentMessagePreview.map { jsonString($0) } ?? "null"
            return "{\"messageId\":\(jsonString(entry.messageId)),\"channelId\":\(jsonString(entry.channelId)),\"channelType\":\(jsonString(entry.channelType)),\"content\":\(jsonString(entry.content)),\"parentChannelId\":\(parentChannel),\"parentMessageId\":\(parentMessage),\"parentMessagePreview\":\(preview),\"replyCount\":\(entry.replyCount)}"
        }.joined(separator: ",")
        return Self.json(200, "{\"saved\":[\("\(rows)")],\"total\":\(total),\"hasMore\":\(offset + page.count < total)}")
    }

    public func setAllChannelVisibility(authorization: String?, serverId: String, visible: Bool) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let allChannelId = oauth.allChannelId(serverId: serverId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        oauth.setChannelType(id: allChannelId, type: visible ? "channel" : "private")
        return Self.json(200, "{\"id\":\(jsonString(allChannelId)),\"visible\":\(visible)}")
    }

    public func createDirectChannelRoute(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid DM peer\"}")
        }
        if let agentId = object["agentId"] as? String {
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
                return Self.json(404, "{\"error\":\"Agent not found in this server\"}")
            }
            let channelId = oauth.createDirectChannel(serverId: serverId, firstUserId: userId, secondUserId: agentId)
            oauth.addChannelAgent(channelId: channelId, agentId: agentId)
            lock.lock()
            postableChannels[channelId] = PostableChannel(serverId: serverId, memberIds: [userId, agentId], kind: "dm", name: "dm")
            lock.unlock()
            emitRealtime("channel:\(channelId)", "dm:new", "{\"channelId\":\(jsonString(channelId))}")
            emitRealtime("user:\(userId)", "dm:new", "{\"channelId\":\(jsonString(channelId))}")
            return Self.json(200, "{\"id\":\(jsonString(channelId)),\"type\":\"dm\",\"activityMuteSupported\":false,\"peerId\":\(jsonString(agentId)),\"peerType\":\"agent\"}")
        }
        guard let peerId = object["userId"] as? String,
              oauth.memberRole(serverId: serverId, userId: peerId) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid DM peer\"}")
        }
        let existingDm = oauth.channelsForServer(serverId: serverId, userId: userId).first { channel in
            channel.type == "dm"
                && oauth.channelHumanIds(channelId: channel.id).contains(userId)
                && oauth.channelHumanIds(channelId: channel.id).contains(peerId)
        }
        lock.lock()
        let hiddenDirectory = hideHumansFromMembers[serverId] == true
        lock.unlock()
        if existingDm == nil, hiddenDirectory, peerId != userId {
            return Self.json(404, "{\"error\":\"DM target not found\"}")
        }
        let channelId = oauth.createDirectChannel(serverId: serverId, firstUserId: userId, secondUserId: peerId)
        oauth.addChannelHuman(channelId: channelId, userId: userId)
        oauth.addChannelHuman(channelId: channelId, userId: peerId)
        if existingDm == nil, peerId != userId {
            var order = oauth.sanitizedSidebarOrder(serverId: serverId, userId: peerId)
            if !order.hiddenDmIds.contains(channelId) {
                order.hiddenDmIds.append(channelId)
                oauth.setSidebarOrder(serverId: serverId, userId: peerId, order: order)
            }
        }
        lock.lock()
        postableChannels[channelId] = PostableChannel(serverId: serverId, memberIds: [userId, peerId], kind: "dm", name: "dm")
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"type\":\"dm\",\"activityMuteSupported\":false,\"peerId\":\(jsonString(peerId)),\"peerType\":\"user\"}")
    }

    public func listDirectChannels(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = oauth.channelsForServer(serverId: serverId, userId: userId)
            .filter { $0.type == "dm" }
            .compactMap { channel -> String? in
                let agentIds = oauth.channelAgentIds(channelId: channel.id)
                let humanIds = oauth.channelHumanIds(channelId: channel.id)
                let peerId: String
                let peerType: String
                if let agent = agentIds.first(where: { $0 != userId }) {
                    // A deleted agent peer stays hydratable by detail id but must
                    // not reappear in the normal DM list.
                    if oauth.agentRuntimeInfo(id: agent)?.deleted == true { return nil }
                    peerId = agent
                    peerType = "agent"
                } else if let human = humanIds.first(where: { $0 != userId }) {
                    peerId = human
                    peerType = "user"
                } else {
                    peerId = userId
                    peerType = "self"
                }
                let last = channel.lastMessageAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
                lock.lock()
                let lastRow = humanMessageRows.last { $0.channelId == channel.id }
                lock.unlock()
                let preview = lastRow.map { jsonString(String($0.content.prefix(120))) } ?? "null"
                let senderName: String
                if let lastRow, lastRow.senderId != "system" {
                    if lastRow.senderType == "agent" {
                        if let agent = oauth.agentRuntimeInfo(id: lastRow.senderId) {
                            senderName = agent.displayName.isEmpty ? agent.name : agent.displayName
                        } else {
                            senderName = ""
                        }
                    } else {
                        lock.lock()
                        let account = accounts.values.first { $0.id == lastRow.senderId }
                        lock.unlock()
                        senderName = account.map { ($0.displayName ?? "").isEmpty ? $0.name : ($0.displayName ?? $0.name) } ?? ""
                    }
                } else {
                    senderName = ""
                }
                let senderJSON = senderName.isEmpty ? "null" : jsonString(senderName)
                return "{\"id\":\(jsonString(channel.id)),\"type\":\"dm\",\"joined\":\(channel.joined),\"activityMuteSupported\":false,\"peerId\":\(jsonString(peerId)),\"peerType\":\(jsonString(peerType)),\"lastMessageAt\":\(last),\"lastMessagePreview\":\(preview),\"lastMessageSenderName\":\(senderJSON)}"
            }
            .joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func enableReadReceiptsForServer(_ serverId: String) {
        lock.lock()
        readReceiptsServers.insert(serverId)
        lock.unlock()
    }

    public func emitAgentScopeRead(serverId: String, channelId: String, agentId: String, maxReadSeq: Int) {
        lock.lock()
        let enabled = readReceiptsServers.contains(serverId)
        let peer = oauth.channelAgentIds(channelId: channelId).contains(agentId)
        lock.unlock()
        guard enabled, peer else { return }
        let payload = "{\"scopeId\":\(jsonString(channelId)),\"peerKind\":\"agent\",\"peerId\":\(jsonString(agentId)),\"maxReadSeq\":\(maxReadSeq)}"
        emitRealtime("channel:\(channelId)", "scope_read:updated", payload)
    }

    public func readReceiptsEnabled(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readReceiptsServers.contains(serverId)
    }

    public func agentReadCursor(channelId: String, agentId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return agentChannelReadCursors["\(channelId)\n\(agentId)"]?.seq ?? 0
    }

    public func humanReadCursor(channelId: String, userId: String) -> Int {
        return oauth.channelReadCursor(channelId: channelId, userId: userId)
    }

    public func agentMuteStateForTesting(channelId: String, agentId: String) -> (serverId: String, muteFromSeq: Int)? {
        let prefs = oauth.notificationPrefs(channelId: channelId, userId: agentId)
        guard prefs.activityMuted, let muteFromSeq = prefs.muteFromSeq else { return nil }
        return (oauth.channelServerId(channelId) ?? "", muteFromSeq)
    }

    func agentMessageSuppressedLocked(_ message: StoredHumanMessage, agentId: String) -> Bool {
        let prefs = oauth.notificationPrefs(channelId: message.channelId, userId: agentId)
        guard prefs.activityMuted, let from = prefs.muteFromSeq, message.seq >= from else {
            return false
        }
        let mentioned = storedMentions.contains {
            $0.messageId == message.id && $0.targetType == "agent" && $0.targetId == agentId
        }
        return !mentioned
    }

    /// `POST /internal/agent-api/channels/:id/mute|unmute`. The mute is keyed by
    /// the agent receiver, not the channel, and only channel members may set it.
    public func agentChannelArchive(authorization: String?, body: String, archive: Bool) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "channels") { return denial }
        guard let writer = agentTaskWriter(authorization, legacyAgentId: nil) else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let target = object["target"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: target)
        else {
            return Self.json(400, "{\"error\":\"Invalid channel target\"}")
        }
        lock.lock()
        postableChannels[channelId]?.archived = archive
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"archived\":\(archive)}")
    }

    public func agentSetChannelMute(authorization: String?, channelId: String, muted: Bool) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "channels") { return denial }
        guard let writer = agentWriterAndRole(authorization: authorization, legacyAgentId: nil, scopes: []),
              let agent = oauth.agentRuntimeInfo(id: writer.agent.id), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let isMember = postableChannels[channelId]?.memberIds.contains(agent.id) == true
            || channelAgentMembers[channelId]?.contains(agent.id) == true
            || oauth.channelAgentIds(channelId: channelId).contains(agent.id)
        guard isMember else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Agent is not a member of this channel\",\"code\":\"not_channel_member\"}")
        }
        let latest = humanMessageRows.filter { $0.channelId == channelId }.map(\.seq).max() ?? 0
        lock.unlock()
        let state = oauth.setActivityMuted(
            channelId: channelId,
            receiverId: agent.id,
            muted: muted,
            muteFromSeq: muted ? latest + 1 : nil
        )
        let name = channel.name
        if muted {
            let muteFromSeq = state.prefs.muteFromSeq ?? (latest + 1)
            let attention = "{\"state\":\"muted\",\"unmuteCommand\":\(jsonString("raft channel unmute #\(name)")),\"unmuteApi\":\(jsonString("POST /internal/agent-api/channels/\(channelId)/unmute")),\"stillArrives\":[\"Personal @mentions still arrive.\",\"Direct messages still arrive.\",\"Threads you follow deliver independently.\"],\"threadBoundary\":\(jsonString("Channel mute suppresses ordinary Activity from this channel only. Threads you follow keep delivering independently until you unfollow them.")),\"catchUp\":\(jsonString("Run `raft channel history #\(name)` or GET /internal/agent-api/history to catch up."))}"
            return Self.json(200, "{\"activityMuted\":true,\"muteFromSeq\":\(muteFromSeq),\"attention\":\(attention)}")
        }
        let attention = "{\"state\":\"unmuted\",\"muteCommand\":\(jsonString("raft channel mute #\(name)"))}"
        return Self.json(200, "{\"activityMuted\":false,\"muteFromSeq\":null,\"attention\":\(attention)}")
    }

    public func systemMessageContents(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows
            .filter { $0.channelId == channelId && $0.messageType == "system" }
            .map(\.content)
    }

    public func humanMessageSequence(id: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.first(where: { $0.id == id })?.seq
    }

    public func setAgentReadCursorForTesting(agentId: String, channelId: String, seq: Int, version: Int = 1) {
        lock.lock()
        agentChannelReadCursors["\(channelId)\n\(agentId)"] = (seq, version)
        lock.unlock()
    }

    public func setChannelHumanRoleForTesting(channelId: String, userId: String, role: String) {
        lock.lock()
        channelHumanRoles["\(channelId)\n\(userId)"] = role
        lock.unlock()
    }

    public func getChannelRoute(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let type = oauth.channelType(id: channelId) ?? "channel"
        // A thread is visible to whoever can see its parent; a private parent
        // must not leak its child thread's existence or metadata.
        let threadParentId = type == "thread" ? oauth.channelParentChannelId(id: channelId) : nil
        let canSee = threadParentId.map { channelActorCanSee(channelId: $0, userId: userId) }
            ?? channelActorCanSee(channelId: channelId, userId: userId)
        guard canSee else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let joined = channel.name == "all"
            || postableChannels[channelId]?.memberIds.contains(userId) == true
            || oauth.channelHumanIds(channelId: channelId).contains(userId)
        lock.unlock()
        let supported = type == "channel"
        let info = oauth.channelUnreadInfo(channelId: channelId, userId: userId)
        lock.lock()
        let version = channelReadVersions["\(channelId)\n\(userId)"] ?? 0
        let receiptsEnabled = readReceiptsServers.contains(serverId)
        let agentIds = oauth.channelAgentIds(channelId: channelId)
        let peerSeqs = agentIds.map { agentId in
            (agentId, agentChannelReadCursors["\(channelId)\n\(agentId)"]?.seq ?? 0)
        }
        lock.unlock()
        let serverRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        lock.lock()
        let localRole = channelHumanRoles["\(channelId)\n\(userId)"]
        let authorityRevision = channelAuthorityRevisions[channelId] ?? 1
        lock.unlock()
        let basis: String? = localRole == "admin" ? "channel_role"
            : ((serverRole == "owner" || serverRole == "admin") ? "server_role" : nil)
        let channelRole = basis == nil ? "member" : "admin"
        let serverAdmin = serverRole == "owner" || serverRole == "admin"
        let capability = basis != nil
        let isJoint = jointProjections.contains { $0.localChannelId == channelId }
        let metadataCap = capability
        let roleCap = capability
        let archiveCap = capability && !isJoint
        let addCap = capability && !isJoint
        let capsJSON = "{\"editChannelMetadata\":\(metadataCap),\"archiveChannels\":\(archiveCap),\"addChannelMembers\":\(addCap),\"removeChannelMembers\":\(addCap),\"changeChannelMemberRoles\":\(roleCap),\"manageGuestAccess\":\(serverAdmin && !isJoint),\"deleteChannels\":\(serverAdmin),\"changeChannelVisibility\":\(serverAdmin),\"federateChannels\":\(serverAdmin)}"
        var peersJSON = ""
        if receiptsEnabled {
            if peerSeqs.count > 50 {
                var counts: [Int: Int] = [:]
                for (_, seq) in peerSeqs { counts[seq, default: 0] += 1 }
                let buckets = counts.keys.sorted().map { seq in
                    "{\"seq\":\(seq),\"count\":\(counts[seq] ?? 0)}"
                }.joined(separator: ",")
                peersJSON = ",\"peerReadSummary\":{\"peerCount\":\(peerSeqs.count),\"readCountAtSeq\":[\("\(buckets)")]}"
            } else {
                let peers = peerSeqs.map { agentId, seq in
                    "{\"peerKind\":\"agent\",\"peerId\":\(jsonString(agentId)),\"maxReadSeq\":\(seq)}"
                }.joined(separator: ",")
                peersJSON = ",\"peerReadStates\":[\("\(peers)")]"
            }
        }
        let displayPrefs = oauth.channelDisplayPrefs(channelId: channelId, userId: userId)
        var dmFields = ""
        if type == "dm" {
            lock.lock()
            let peerId = postableChannels[channelId]?.memberIds.first { $0 != userId }
            lock.unlock()
            if let peerId {
                if let agent = oauth.agentRuntimeInfo(id: peerId) {
                    dmFields = ",\"peerType\":\"agent\",\"peerId\":\(jsonString(peerId)),\"peerName\":\(jsonString(agent.name))"
                } else if let account = accounts.values.first(where: { $0.id == peerId }) {
                    dmFields = ",\"peerType\":\"human\",\"peerId\":\(jsonString(peerId)),\"peerName\":\(jsonString(account.name))"
                }
            }
        }
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(jsonString(channel.name)),\"type\":\(jsonString(type)),\"joined\":\(joined)\(dmFields),\"maxReadSeq\":\(info.maxReadSeq),\"readStateVersion\":\(version),\"activityMuteSupported\":\(supported),\"collapseLongMessages\":\(displayPrefs.collapseLongMessages),\"displayPrefsVersion\":\(displayPrefs.prefsVersion),\"channelRole\":\(jsonString(channelRole)),\"channelAdminBasis\":\(basis.map { jsonString($0) } ?? "null"),\"channelAuthorityRevision\":\(authorityRevision),\"channelCapabilities\":\(capsJSON)\(peersJSON)}")
    }

    public func channelDisplaySettings(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if oauth.channelType(id: channelId) == "thread" {
            return Self.json(400, "{\"error\":\"Display preferences are stored on the parent channel\"}")
        }
        guard oauth.canAccessChannelPrefs(channelId: channelId, userId: userId, serverId: serverId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let prefs = oauth.channelDisplayPrefs(channelId: channelId, userId: userId)
        return Self.json(200, "{\"collapseLongMessages\":\(prefs.collapseLongMessages),\"prefsVersion\":\(prefs.prefsVersion)}")
    }

    public func patchChannelDisplaySettings(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if oauth.channelType(id: channelId) == "thread" {
            return Self.json(400, "{\"error\":\"Display preferences are stored on the parent channel\"}")
        }
        guard oauth.canAccessChannelPrefs(channelId: channelId, userId: userId, serverId: serverId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let collapse = object["collapseLongMessages"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"collapseLongMessages must be a boolean\"}")
        }
        let prefs = oauth.setCollapseLongMessages(channelId: channelId, userId: userId, collapse: collapse)
        return Self.json(200, "{\"collapseLongMessages\":\(prefs.collapseLongMessages),\"prefsVersion\":\(prefs.prefsVersion)}")
    }

    public func setAccountDescriptionForTesting(userId: String, description: String?) {
        lock.lock()
        if let index = accounts.values.firstIndex(where: { $0.id == userId }) {
            var account = accounts.values[index]
            account.description = description
            accounts.values[index] = account
        }
        lock.unlock()
    }

    public func seedDMForTesting(serverId: String, humanUserId: String, agentId: String, name: String = "dm") -> String {
        let channelId = oauth.createDirectChannel(serverId: serverId, firstUserId: humanUserId, secondUserId: agentId)
        addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, kind: "dm", name: name)
        addPostableChannel(serverId: serverId, channelId: channelId, memberId: humanUserId, kind: "dm", name: name)
        oauth.addChannelHuman(channelId: channelId, userId: humanUserId)
        return channelId
    }

    public func channelCardRevisionForTesting(channelId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return channelCardSnapshotLocked(channelId: channelId)?.rev
    }

    public func mentionsForTesting(messageId: String) -> [(targetType: String, targetId: String, handle: String)] {
        lock.lock(); defer { lock.unlock() }
        return storedMentions.filter { $0.messageId == messageId }.map { ($0.targetType, $0.targetId, $0.handle) }
    }

    public func addStoredMentionForTesting(
        channelId: String,
        messageId: String,
        targetId: String,
        targetType: String = "user",
        handle: String = "peer",
        terminalCode: String? = nil
    ) {
        lock.lock()
        storedMentions.append(StoredMention(
            id: UUID().uuidString.lowercased(),
            messageId: messageId,
            channelId: channelId,
            senderId: "peer",
            targetType: targetType,
            targetId: targetId,
            handle: handle,
            notifiableAtSend: true,
            notifiedAt: nil,
            notifiedByType: nil,
            notifiedById: nil,
            notifiedAction: nil,
            terminalCode: terminalCode
        ))
        lock.unlock()
    }

    public func updateChannelReadState(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let readable = postableChannels[channelId].map { $0.kind == "channel" || $0.memberIds.contains(userId) }
            ?? (oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId))
        lock.unlock()
        guard readable else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let seq = object["seq"] as? Int, seq >= 0
        else {
            return Self.json(400, "{\"error\":\"seq must be a non-negative integer\"}")
        }
        let key = "\(channelId)\n\(userId)"
        lock.lock()
        let info = oauth.channelUnreadInfo(channelId: channelId, userId: userId)
        let current = max(info.maxReadSeq, channelReadVersions[key] == nil ? 0 : info.maxReadSeq)
        if seq <= info.maxReadSeq {
            let version = channelReadVersions[key] ?? 0
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"maxReadSeq\":\(current),\"readStateVersion\":\(version)}")
        }
        channelReadVersions[key] = (channelReadVersions[key] ?? 0) + 1
        let version = channelReadVersions[key] ?? 1
        lock.unlock()
        oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: seq)
        return Self.json(200, "{\"ok\":true,\"maxReadSeq\":\(seq),\"readStateVersion\":\(version)}")
    }


    /// Synchronous context gathering for the resume handler; the async method
    /// only awaits the dispatch callback.
    func resumeAllAgentsContext(
        userId: String,
        serverId: String,
        channelId: String,
        requestedAgentIds: Set<String>?
    ) -> ResumeAllAgentsContext {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = postableChannels[channelId], channel.serverId == serverId else {
            return ResumeAllAgentsContext(targets: [], dispatch: nil, error: Self.json(404, "{\"error\":\"Channel not found\"}"))
        }
        let readable = channel.kind == "channel"
            || channel.memberIds.contains(userId)
            || oauth.isChannelParticipant(channelId: channelId, userId: userId)
        guard readable else {
            return ResumeAllAgentsContext(targets: [], dispatch: nil, error: Self.json(404, "{\"error\":\"Channel not found\"}"))
        }
        let channelAgentIds = Array(channelAgentMembers[channelId] ?? []).sorted()
        let targets = requestedAgentIds.map { requested in channelAgentIds.filter { requested.contains($0) } } ?? channelAgentIds
        return ResumeAllAgentsContext(targets: targets, dispatch: agentStartDispatch, error: nil)
    }

    /// `POST /api/channels/:id/resume-all-agents`. Sends an optional resume
    /// prompt to every agent in the channel (or the explicit `agentIds` subset)
    /// and reports an agent whose start was skipped instead of counting it
    /// resumed.
    public func resumeAllAgents(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: String
    ) async -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let object: [String: Any]
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object = [:]
        } else if let parsed = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] {
            object = parsed
        } else {
            return Self.json(400, "{\"error\":\"Invalid resume request\"}")
        }
        let prompt = object["prompt"] as? String
        var requestedAgentIds: Set<String>?
        if let raw = object["agentIds"], !(raw is NSNull) {
            guard let ids = raw as? [String] else {
                return Self.json(400, "{\"error\":\"agentIds must be an array of agent ids\"}")
            }
            requestedAgentIds = Set(ids)
        }
        let context = resumeAllAgentsContext(
            userId: userId,
            serverId: serverId,
            channelId: channelId,
            requestedAgentIds: requestedAgentIds
        )
        if let error = context.error { return error }
        var results: [String] = []
        var started = 0
        for agentId in context.targets {
            var dispatched = false
            var skipReason: String?
            if let dispatch = context.dispatch {
                do {
                    switch try await dispatch(agentId, prompt) {
                    case .dispatched:
                        dispatched = true
                    case .skipped:
                        skipReason = "start_in_flight"
                    }
                } catch {
                    skipReason = "start_failed"
                }
            } else {
                dispatched = true
            }
            if dispatched { started += 1 }
            if let skipReason {
                results.append("{\"agentId\":\(jsonString(agentId)),\"ok\":false,\"reason\":\(jsonString(skipReason))}")
            } else {
                results.append("{\"agentId\":\(jsonString(agentId)),\"ok\":true}")
            }
        }
        let allStarted = started == context.targets.count
        return Self.json(200, "{\"ok\":\(allStarted ? "true" : "false"),\"started\":\(started),\"total\":\(context.targets.count),\"results\":[\(results.joined(separator: ","))]}")
    }

    public func markChannelReadAll(authorization: String?, serverId: String, channelId: String, body: String = "{}") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        // A kinded receiver delegates the read to that agent. Authority is the
        // server role or the agent's creator, never the caller's own membership:
        // the human caller's read state must stay untouched.
        if let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
           let receiver = object["receiver"] as? [String: Any],
           let kind = receiver["kind"] as? String,
           let receiverId = receiver["id"] as? String {
            guard kind == "agent",
                  let agent = oauth.agentRuntimeInfo(id: receiverId),
                  agent.serverId == serverId
            else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            let canDelegate = role == "owner" || role == "admin" || agent.creatorUserId == userId
            guard canDelegate, oauth.channelAgentIds(channelId: channelId).contains(agent.id) else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            let latestSeq = oauth.channelUnreadInfo(channelId: channelId, userId: userId).latestSeq ?? 0
            lock.lock()
            let key = "\(channelId)\n\(receiverId)"
            let previous = agentChannelReadCursors[key] ?? (seq: 0, version: 0)
            let advanced = latestSeq > previous.seq
            let version = advanced ? previous.version + 1 : previous.version
            agentChannelReadCursors[key] = (seq: max(previous.seq, latestSeq), version: version)
            lock.unlock()
            if advanced {
                onAgentReadUpdated?(serverId, channelId, receiverId, latestSeq)
            }
            return Self.json(200, "{\"ok\":true,\"seq\":\(max(previous.seq, latestSeq)),\"readStateVersion\":\(max(version, 1))}")
        }
        lock.lock()
        let readableAll = postableChannels[channelId].map { $0.kind == "channel" || $0.memberIds.contains(userId) }
            ?? (oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId))
        lock.unlock()
        guard readableAll else {
            lock.lock()
            let facts = inboxFactStore.all().filter {
                $0.receiverType == "user" && $0.receiverId == userId
                    && $0.channelId == channelId && $0.serverId == serverId
            }
            lock.unlock()
            var ownedSeq = oauth.channelUnreadInfo(channelId: channelId, userId: userId).maxReadSeq
            if let lastFact = facts.last,
               let owned = oauth.historyMessages(channelId: channelId).first(where: { $0.id == lastFact.messageId }) {
                ownedSeq = max(ownedSeq, owned.seq)
            }
            guard ownedSeq > 0 else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: ownedSeq)
            let key = "\(channelId)\n\(userId)"
            lock.lock()
            inboxDoneScopes.insert("\(userId)\n\(channelId)")
            inboxDoneAt["\(userId)\n\(channelId)"] = Date()
            channelReadVersions[key] = (channelReadVersions[key] ?? 0) + 1
            let version = channelReadVersions[key] ?? 1
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"seq\":\(ownedSeq),\"readStateVersion\":\(version)}")
        }
        let latest = oauth.channelUnreadInfo(channelId: channelId, userId: userId).latestSeq ?? 0
        let key = "\(channelId)\n\(userId)"
        lock.lock()
        channelReadVersions[key] = (channelReadVersions[key] ?? 0) + 1
        let version = channelReadVersions[key] ?? 1
        lock.unlock()
        oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: latest)
        return Self.json(200, "{\"ok\":true,\"seq\":\(latest),\"readStateVersion\":\(version)}")
    }

    @discardableResult
    public func setAnnouncementAudienceForTesting(id: String, serverIds: [String]) {
        lock.lock()
        if let index = announcements.firstIndex(where: { $0.id == id }) {
            announcements[index].audienceServerIds = serverIds
        }
        lock.unlock()
    }

    /// A targeted announcement is only visible inside one of its servers; the
    /// audience itself is never echoed to the client.
    func announcementVisibleLocked(
        _ announcement: (id: String, title: String, pages: [String], startsAt: Date, expiresAt: Date?, status: String, publishedAt: Date?, imageId: String?, audienceServerIds: [String]),
        userId: String,
        serverId: String?
    ) -> Bool {
        guard !announcement.audienceServerIds.isEmpty else { return true }
        guard let serverId else { return false }
        return announcement.audienceServerIds.contains(serverId)
            && oauth.memberRole(serverId: serverId, userId: userId) != nil
    }


    /// `server_id` must appear at most once and be a UUID; a duplicate or a
    /// malformed value never degrades into an unscoped answer.

    public func addAnnouncementForTesting(
        title: String,
        pages: [String],
        startsAt: Date = Date(),
        expiresAt: Date? = nil,
        status: String = "published",
        publishedAt: Date? = nil,
        imageId: String? = nil,
        audienceServerIds: [String] = []
    ) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        announcements.append((
            id: id,
            title: title,
            pages: pages,
            startsAt: startsAt,
            expiresAt: expiresAt,
            status: status,
            publishedAt: publishedAt ?? (status == "draft" ? nil : Date()),
            imageId: imageId,
            audienceServerIds: audienceServerIds
        ))
        lock.unlock()
        return id
    }

    public func setAnnouncementStateForTesting(
        id: String,
        status: String,
        publishedAt: Date?,
        startsAt: Date
    ) {
        lock.lock()
        if let index = announcements.firstIndex(where: { $0.id == id }) {
            announcements[index].status = status
            announcements[index].publishedAt = publishedAt
            announcements[index].startsAt = startsAt
        }
        lock.unlock()
    }

    public func addAnnouncementImageForTesting(id: String, announcementId: String, contentType: String, bytes: Data) {
        lock.lock()
        announcementImageAssets[id] = AnnouncementImageAsset(
            id: id,
            announcementId: announcementId,
            contentType: contentType,
            bytes: bytes
        )
        lock.unlock()
    }





    public func addExternalAvatarForTesting(
        id: String,
        contentType: String = "image/webp",
        bytes: Data,
        sourceDigest: String,
        active: Bool = true
    ) {
        lock.lock()
        externalAvatarAssets[id] = ExternalAvatarAsset(
            id: id,
            contentType: contentType,
            bytes: bytes,
            sourceDigest: sourceDigest,
            active: active
        )
        lock.unlock()
    }

    public func setExternalAvatarStorageAvailableForTesting(_ available: Bool) {
        lock.lock()
        externalAvatarStorageAvailable = available
        lock.unlock()
    }

    public func externalAvatar(file: String) -> HTTPReply {
        guard file.hasSuffix(".webp") else {
            return Self.avatarPlainText(404, "Not found")
        }
        let id = String(file.dropLast(".webp".count))
        guard ServerScope.isUUID(id) else {
            return Self.avatarPlainText(404, "Not found")
        }
        lock.lock()
        let asset = externalAvatarAssets[id]
        let storageAvailable = externalAvatarStorageAvailable
        lock.unlock()
        guard let asset, asset.active else {
            return Self.avatarPlainText(404, "Not found")
        }
        guard storageAvailable else {
            return Self.avatarPlainText(503, "Avatar storage is unavailable")
        }
        return HTTPReply(
            status: 200,
            headers: [
                "Content-Type": asset.contentType,
                "Content-Length": String(asset.bytes.count),
                "Content-Disposition": "inline",
                "Cache-Control": "public, no-cache, must-revalidate",
                "ETag": "\"sha256-\(asset.sourceDigest)\"",
                "X-Content-Type-Options": "nosniff",
                "Cross-Origin-Resource-Policy": "cross-origin",
            ],
            body: String(decoding: asset.bytes, as: UTF8.self)
        )
    }


    public func setAnnouncementImageStorageAvailableForTesting(_ available: Bool) {
        lock.lock()
        announcementImageStorageAvailable = available
        lock.unlock()
    }

    public func announcementImage(id: String) -> HTTPReply {
        guard ServerScope.isUUID(id) else {
            return Self.json(404, "{\"error\":\"Announcement image not found\"}")
        }
        lock.lock()
        let asset = announcementImageAssets[id]
        let announcement = announcements.first { $0.id == asset?.announcementId }
        let storageAvailable = announcementImageStorageAvailable
        lock.unlock()
        guard let asset, let announcement,
              announcement.publishedAt != nil,
              announcement.status != "draft",
              announcement.startsAt <= Date()
        else {
            return Self.json(404, "{\"error\":\"Announcement image not found\"}")
        }
        guard storageAvailable else {
            return Self.json(503, "{\"error\":\"Announcement image storage unavailable\"}")
        }
        return HTTPReply(
            status: 200,
            headers: [
                "Content-Type": asset.contentType,
                "Cache-Control": "public, max-age=31536000, immutable",
                "Cross-Origin-Resource-Policy": "cross-origin",
                "Content-Length": String(asset.bytes.count),
            ],
            body: String(decoding: asset.bytes, as: UTF8.self)
        )
    }

    public func activeAnnouncements(authorization: String?, after: String?, query: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        if let after, !after.isEmpty, !ServerScope.isUUID(after) {
            return Self.json(400, "{\"error\":\"Invalid announcement cursor\"}")
        }
        let scopedServer: String?
        switch Self.announcementContextQuery(query) {
        case .failure(let reply):
            return reply
        case .success(let serverId):
            scopedServer = serverId
        }
        let now = Date()
        lock.lock()
        // Drafts never surface; a published row only surfaces once published and
        // until it expires. Expiring the newest row falls through to the next
        // unread one, which is what makes scheduled windows queue.
        let rows = announcements
            .filter { $0.status == "published" && $0.publishedAt != nil }
            .filter { $0.startsAt <= now && ($0.expiresAt == nil || $0.expiresAt! > now) }
            .filter { announcementVisibleLocked($0, userId: userId, serverId: scopedServer) }
            .filter { !announcementDismissals.contains("\(userId)\n\($0.id)") }
            .filter { after == nil || $0.id != after }
            .sorted { $0.startsAt < $1.startsAt }
            .prefix(1)
        let documents = rows.map { announcement -> String in
            let pages = announcement.pages.map { jsonString($0) }.joined(separator: ",")
            return "{\"id\":\(jsonString(announcement.id)),\"title\":\(jsonString(announcement.title)),\"pages\":[\(pages)]}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"announcements\":[\(documents)]}")
    }

    public func dismissAnnouncement(
        authorization: String?,
        announcementId: String,
        query: String? = nil,
        headerServerId: String? = nil
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let scopedServer: String?
        switch Self.announcementContextQuery(query, headerServerId: headerServerId) {
        case .failure(let reply):
            return reply
        case .success(let serverId):
            scopedServer = serverId
        }
        lock.lock()
        guard let announcement = announcements.first(where: { $0.id == announcementId }),
              announcementVisibleLocked(announcement, userId: userId, serverId: scopedServer)
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Announcement not found\"}")
        }
        announcementDismissals.insert("\(userId)\n\(announcementId)")
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func setAgentActivity(agentId: String, activity: String, detail: String) {
        lock.lock()
        agentActivities[agentId] = (activity, detail)
        lock.unlock()
    }

    public func agentReadCursor(agentId: String, channelId: String) -> (seq: Int, version: Int) {
        lock.lock()
        defer { lock.unlock() }
        return agentChannelReadCursors["\(channelId)\n\(agentId)"] ?? (0, 0)
    }

    public func markChannelUnread(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if guestDeniedHiddenChannel(channelId: channelId, serverId: serverId, userId: userId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let readableUnread = postableChannels[channelId].map { $0.kind == "channel" || $0.memberIds.contains(userId) }
            ?? (oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId))
        lock.unlock()
        guard readableUnread else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let cursor = max(0, (oauth.latestPeerMessageSeq(channelId: channelId, excluding: userId) ?? 1) - 1)
        oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: cursor)
        let info = oauth.channelUnreadInfo(channelId: channelId, userId: userId)
        return Self.json(200, "{\"channelId\":\(jsonString(channelId)),\"unreadCount\":\(info.unreadCount),\"maxReadSeq\":\(info.maxReadSeq)}")
    }

    public func channelUnread(authorization: String?, serverId: String, summary: Bool) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let channels = oauth.channelsForServer(serverId: serverId, userId: userId).filter { channel in
            guard channel.joined else { return false }
            if let thread = postableChannels[channel.id], thread.kind == "thread" {
                guard let parentId = thread.parentChannelId,
                      let parent = postableChannels[parentId],
                      parent.deletedAt == nil
                else { return false }
            }
            return true
        }
        if !summary {
            let pairs = channels.compactMap { channel -> String? in
                let info = oauth.channelUnreadInfo(channelId: channel.id, userId: userId)
                guard info.unreadCount > 0 else { return nil }
                return "\(jsonString(channel.id)):\(info.unreadCount)"
            }.joined(separator: ",")
            return Self.privateJSON("{\(pairs)}")
        }
        var entries: [String] = []
        var threadUnread: [String: (count: Int, hasMention: Bool)] = [:]
        for channel in channels {
            let info = oauth.channelUnreadInfo(channelId: channel.id, userId: userId)
            let thread = postableChannels[channel.id].flatMap { $0.kind == "thread" ? $0 : nil }
            if thread != nil {
                guard threadFollows["\(serverId)\n\(userId)\n\(channel.id)"] != nil,
                      !inboxDoneScopes.contains("\(userId)\n\(channel.id)")
                else { continue }
            }
            let threadReplies = thread == nil ? [] : humanMessageRows.filter { $0.channelId == channel.id }
            var unreadCount = info.unreadCount
            var latestMessageId = info.latestMessageId
            var latestSeq = info.latestSeq
            if !threadReplies.isEmpty {
                unreadCount = threadReplies.filter { $0.seq > info.maxReadSeq && $0.senderId != userId }.count
                latestMessageId = threadReplies.last?.id
                latestSeq = threadReplies.count
            }
            let mentions = storedMentions.filter { $0.channelId == channel.id && $0.targetType == "user" && $0.targetId == userId }
            let hasAny = !mentions.isEmpty
            if let thread, unreadCount > 0, let parentId = thread.parentChannelId {
                var aggregate = threadUnread[parentId] ?? (count: 0, hasMention: false)
                aggregate.count += 1
                aggregate.hasMention = aggregate.hasMention || hasAny
                threadUnread[parentId] = aggregate
            }
            guard unreadCount > 0 else { continue }
            let latest: String
            if let messageId = latestMessageId, let seq = latestSeq {
                latest = "{\"messageId\":\(jsonString(messageId)),\"seq\":\"\(seq)\"}"
            } else {
                latest = "null"
            }
            var entry = "{\"unreadCount\":\(unreadCount),\"hasMention\":\(hasAny),\"hasAnyMention\":\(hasAny),\"readState\":{\"kind\":\"present\",\"readStateVersion\":0,\"maxReadSeq\":\"\(info.maxReadSeq)\",\"latestActivity\":\(latest)}"
            if let thread, let parentId = thread.parentChannelId {
                entry += ",\"parentChannelId\":\(jsonString(parentId))"
                if let parentMessageId = thread.parentMessageId {
                    entry += ",\"parentMessageId\":\(jsonString(parentMessageId))"
                }
            }
            entry += "}"
            entries.append("\(jsonString(channel.id)):\(entry)")
        }
        let threadJSON = threadUnread.keys.sorted().map { parentId -> String in
            let value = threadUnread[parentId] ?? (count: 0, hasMention: false)
            return "\(jsonString(parentId)):{\"count\":\(value.count),\"hasMention\":\(value.hasMention)}"
        }.joined(separator: ",")
        return Self.privateJSON("{\"channels\":{\(entries.joined(separator: ","))},\"threadUnread\":{\(threadJSON)}}")
    }

    public func channelNotificationSettings(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let channelType = oauth.channelType(id: channelId) ?? "channel"
        guard channelType != "thread" else {
            return Self.json(400, "{\"error\":\"Threads use follow/unfollow instead of activity mute\"}")
        }
        let supported = channelType == "channel"
        let prefs = oauth.notificationPrefs(channelId: channelId, userId: userId)
        let muteSeq = prefs.muteFromSeq.map(String.init) ?? "null"
        return Self.json(200, "{\"activityMuted\":\(prefs.activityMuted),\"muteFromSeq\":\(muteSeq),\"prefsVersion\":\(prefs.prefsVersion),\"activityMuteSupported\":\(supported)}")
    }

    public func patchChannelNotificationSettings(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        let channelType = oauth.channelType(id: channelId) ?? "channel"
        guard channelType != "thread" else {
            return Self.json(400, "{\"error\":\"Threads use follow/unfollow instead of activity mute\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let muted = object["activityMuted"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"activityMuted must be a boolean\"}")
        }
        let result = oauth.setActivityMuted(channelId: channelId, userId: userId, muted: muted)
        let muteSeq = result.prefs.muteFromSeq.map(String.init) ?? "null"
        let supported = channelType == "channel"
        return Self.json(200, "{\"activityMuted\":\(result.prefs.activityMuted),\"muteFromSeq\":\(muteSeq),\"prefsVersion\":\(result.prefs.prefsVersion),\"activityMuteSupported\":\(supported)}")
    }

    public func patchChannelRoute(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil,
              let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel update\"}")
        }
        if object["guestVisible"] != nil || object["guestJoinable"] != nil {
            guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            lock.lock()
            if let visible = object["guestVisible"] as? Bool { guestVisibleChannels[channelId] = visible }
            if let joinable = object["guestJoinable"] as? Bool { guestJoinableChannels[channelId] = joinable }
            let visibleNow = guestVisibleChannels[channelId] ?? false
            let joinableNow = guestJoinableChannels[channelId] ?? false
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"id\":\(jsonString(channelId)),\"guestVisible\":\(visibleNow),\"guestJoinable\":\(joinableNow)}")
        }
        if let rawVisibility = object["visibility"] {
            guard let visibility = rawVisibility as? String, ["private", "public"].contains(visibility) else {
                return Self.json(400, "{\"error\":\"Invalid channel visibility\"}")
            }
            if oauth.allChannelId(serverId: serverId) == channelId {
                return Self.json(403, "{\"error\":\"Only a human can do it, from channel settings or server settings\",\"code\":\"all_channel_visibility_managed_separately\"}")
            }
            guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            lock.lock()
            let isMember = postableChannels[channelId]?.memberIds.contains(userId) == true
            lock.unlock()
            guard isMember || oauth.isChannelParticipant(channelId: channelId, userId: userId) else {
                return Self.json(403, "{\"error\":\"You must be a channel member\",\"code\":\"channel_membership_required\"}")
            }
            _ = oauth.setChannelType(id: channelId, type: visibility == "private" ? "private" : "channel")
            lock.lock()
            postableChannels[channelId]?.kind = visibility == "private" ? "private" : "channel"
            if visibility == "private" {
                let snapshot = postableChannels[channelId]?.memberIds ?? []
                let threadIds = Set(postableChannels.filter { $0.value.kind == "thread" && $0.value.parentChannelId == channelId }.keys)
                for (key, follow) in threadFollows where threadIds.contains(follow.threadChannelId) && !snapshot.contains(follow.userId) {
                    threadFollows.removeValue(forKey: key)
                }
            }
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"id\":\(jsonString(channelId)),\"visibility\":\(jsonString(visibility)),\"type\":\(jsonString(visibility == "private" ? "private" : "channel"))}")
        }
        let serverRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        lock.lock()
        let actorChannelRole = channelHumanRoles["\(channelId)\n\(userId)"]
        let jointCanonical = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId
        let jointLinks = jointCanonical.map { canonical in
            jointProjections.filter { $0.canonicalChannelId == canonical }.map(\.localChannelId)
        } ?? []
        let actorName = accounts.values.first(where: { $0.id == userId })?.name ?? "Someone"
        lock.unlock()
        guard actorChannelRole == "admin" || serverRole == "owner" || serverRole == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        if !jointLinks.isEmpty {
            if object["visibility"] != nil || object["archived"] != nil {
                return Self.json(403, "{\"error\":\"Only a server admin can change joint visibility or archive\",\"code\":\"joint_channel_admin_limited\"}")
            }
            let jointName = object["name"] as? String
            let jointDescription = object["description"] as? String
            if let jointName, jointName.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) == nil {
                return Self.json(400, "{\"error\":\"Invalid channel name\"}")
            }
            var systemSeq: Int?
            for linkId in jointLinks {
                let seq = oauth.updateChannel(id: linkId, name: jointName, description: jointDescription, systemMessage: nil)
                systemSeq = seq ?? systemSeq
                lock.lock()
                if let jointName { postableChannels[linkId]?.name = jointName }
                lock.unlock()
            }
            let latest = oauth.channelInfo(id: channelId)
            let nameJSON = jsonString(latest?.name ?? channel.name)
            let descriptionJSON = latest?.description.map(jsonString) ?? "null"
            return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(nameJSON),\"description\":\(descriptionJSON),\"systemMessageSeq\":\(systemSeq.map(String.init) ?? "null")}")
        }
        var newName: String?
        if let name = object["name"] as? String, name != channel.name {
            guard name.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) != nil else {
                return Self.json(400, "{\"error\":\"Invalid channel name\"}")
            }
            newName = name
        }
        let newDescription = object["description"] as? String
        var systemMessage: String?
        if let newName {
            systemMessage = "@\(actorName) renamed this channel from #\(channel.name) to #\(newName)."
        }
        let seq = oauth.updateChannel(
            id: channelId,
            name: newName,
            description: newDescription,
            systemMessage: systemMessage
        )
        let latest = oauth.channelInfo(id: channelId)
        let nameJSON = jsonString(latest?.name ?? channel.name)
        let descriptionJSON = latest?.description.map { jsonString($0) } ?? "null"
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(nameJSON),\"description\":\(descriptionJSON),\"systemMessageSeq\":\(seq.map(String.init) ?? "null")}")
    }

    public func createChannelRoute(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String,
              name.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) != nil,
              name != "all"
        else {
            return Self.json(400, "{\"error\":\"Invalid channel\"}")
        }
        if (object["visibility"] as? String) == "joint" {
            guard let targetSlug = (object["targetServerSlug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let targetServerId = oauth.serverIdForSlug(targetSlug),
                  targetServerId != serverId,
                  let targetServer = oauth.serverDetailsValue(id: targetServerId)
            else {
                return Self.json(400, "{\"error\":\"targetServerSlug is required\"}")
            }
            let invited = object["invitedPeople"] as? [String] ?? []
            let inviteHandle = invited.first.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 } ?? ""
            let targetOwnerId = accounts.values.first { $0.name.caseInsensitiveCompare(inviteHandle) == .orderedSame }?.id
            guard let targetOwnerId, oauth.memberRole(serverId: targetServerId, userId: targetOwnerId) != nil else {
                return Self.json(400, "{\"error\":\"invited person must belong to the target server\"}")
            }
            let hostChannelId = oauth.createChannel(serverId: serverId, name: name, creatorUserId: userId)
            _ = oauth.setChannelType(id: hostChannelId, type: "joint")
            let targetChannelId = oauth.createChannel(serverId: targetServerId, name: name, creatorUserId: targetOwnerId)
            _ = oauth.setChannelType(id: targetChannelId, type: "joint")
            addJointChannelProjection(localChannelId: hostChannelId, canonicalChannelId: hostChannelId, serverId: serverId)
            addJointChannelProjection(localChannelId: targetChannelId, canonicalChannelId: hostChannelId, serverId: targetServerId)
            lock.lock()
            postableChannels[hostChannelId] = PostableChannel(serverId: serverId, memberIds: [userId], kind: "joint", name: name)
            postableChannels[targetChannelId] = PostableChannel(serverId: targetServerId, memberIds: [], kind: "joint", name: name)
            let inviteId = UUID().uuidString.lowercased()
            jointInvites.append((inviteId, serverId, hostChannelId, targetServerId, targetChannelId, targetOwnerId, "pending"))
            lock.unlock()
            return Self.json(200, "{\"id\":\(jsonString(hostChannelId)),\"name\":\(jsonString(name)),\"type\":\"joint\",\"targetServerSlug\":\(jsonString(targetServer.slug)),\"jointInvite\":{\"id\":\(jsonString(inviteId)),\"status\":\"pending\"},\"joined\":true}")
        }
        lock.lock()
        let collision = postableChannels.first { _, channel in
            channel.serverId == serverId && channel.name == name && channel.deletedAt == nil
                && (channel.kind == "channel" || channel.kind == "private")
        }
        if let collision {
            let canUnarchive = collision.value.archived
                && channelHumanRoles["\(collision.key)\n\(userId)"] == "admin"
            lock.unlock()
            return Self.json(409, "{\"error\":\"A channel named #\(name) already exists\",\"canUnarchiveArchivedChannel\":\(canUnarchive)}")
        }
        lock.unlock()
        let description = object["description"] as? String
        let channelId = oauth.createChannel(
            serverId: serverId,
            name: name,
            creatorUserId: userId,
            description: description
        )
        lock.lock()
        postableChannels[channelId] = PostableChannel(serverId: serverId, memberIds: [userId], name: name)
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(jsonString(name)),\"joined\":true,\"activityMuteSupported\":true,\"activityMuted\":false,\"muteFromSeq\":null,\"prefsVersion\":0,\"maxReadSeq\":0,\"readStateVersion\":0}")
    }

    public func setUserChannelReadCursorForTesting(userId: String, channelId: String, seq: Int) {
        lock.lock()
        userChannelReadCursorsForTesting["\(userId)\n\(channelId)"] = seq
        lock.unlock()
    }

    func agentUserPageValues(limit: String?, offset: String?) -> (limit: Int, offset: Int)? {
        if let limit, Int(limit) == nil { return nil }
        if let offset, Int(offset) == nil { return nil }
        let resolvedLimit = limit.flatMap(Int.init) ?? 50
        let resolvedOffset = offset.flatMap(Int.init) ?? 0
        guard (1...200).contains(resolvedLimit), resolvedOffset >= 0 else { return nil }
        return (resolvedLimit, resolvedOffset)
    }

    func agentUserChannelsPayload(identity: (agentId: String, serverId: String), name: String, limit: String?, offset: String?) -> (text: String, json: String, status: Int)? {
        let normalized = name.hasPrefix("@") ? String(name.dropFirst()) : name
        guard !normalized.isEmpty else { return nil }
        guard let page = agentUserPageValues(limit: limit, offset: offset) else { return nil }
        lock.lock()
        let hidden = hideHumansFromMembers[identity.serverId] ?? false
        lock.unlock()
        let callerAgentRole = oauth.agentRole(serverId: identity.serverId, agentId: identity.agentId) ?? "member"
        guard let subject = accounts.values.first(where: { $0.name == normalized }) else { return nil }
        if hidden, callerAgentRole != "owner", callerAgentRole != "admin" { return nil }
        let subjectServerRole = oauth.memberRole(serverId: identity.serverId, userId: subject.id)
        guard let subjectServerRole else { return nil }
        var unchecked = 0
        lock.lock()
        let postableSnapshot = postableChannels
        let jointSnapshot = jointProjections
        lock.unlock()
        let callerReadsRoster: (String) -> Bool = { [self] channelId in
            if postableSnapshot[channelId]?.memberIds.contains(identity.agentId) == true { return true }
            return oauth.channelAgentIds(channelId: channelId).contains(identity.agentId)
        }
        let channels = oauth.channelsForServer(serverId: identity.serverId, userId: subject.id, includeArchived: false)
        var rows: [String] = []
        for channel in channels {
            let type = oauth.channelType(id: channel.id) ?? channel.type
            if type == "joint" {
                guard let link = jointSnapshot.first(where: { $0.localChannelId == channel.id && $0.serverId == identity.serverId }),
                      link.status == "active",
                      callerReadsRoster(channel.id)
                else {
                    unchecked += 1
                    continue
                }
            }
            let role: String? = {
                guard (type == "channel" || type == "private"), channel.name != "all" else { return nil }
                lock.lock()
                let channelRole = channelHumanRoles["\(channel.id)\n\(subject.id)"]
                lock.unlock()
                return channelRole == "admin" ? "admin" : "member"
            }()
            let roleJSON = role.map(jsonString) ?? "null"
            rows.append("{\"id\":\(jsonString(channel.id)),\"name\":\(jsonString(channel.name)),\"type\":\(jsonString(type)),\"joined\":\(channel.joined),\"channelRole\":\(roleJSON)}")
        }
        let pageRows = Array(rows.dropFirst(page.offset).prefix(page.limit))
        let json = "{\"kind\":\"human\",\"name\":\(jsonString(subject.name)),\"uncheckedCount\":\(unchecked),\"memberships\":[\("\(pageRows.joined(separator: ","))")],\"page\":{\"total\":\(rows.count),\"offset\":\(page.offset),\"limit\":\(page.limit)}}"
        var text = pageRows.map { row -> String in
            let name = (try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any])?["name"] as? String ?? ""
            return "#\(name)"
        }.joined(separator: "\n")
        if unchecked > 0 {
            text += (text.isEmpty ? "" : "\n") + "Skipped \(unchecked) visible channel roster checks because the server rejected them."
        }
        return (text, json, 200)
    }

    public func appAgentReminderMessage(authorization: String?, body: String) -> HTTPReply {
        guard let access = oauth.appInstallationAccess(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Invalid installation credential\"}")
        }
        guard access.official, access.groups.contains("agent_reminder_write") else {
            return Self.json(403, "{\"error\":\"Agent reminder write is not authorized for this app\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let agentId = object["agentId"] as? String, ServerScope.isUUID(agentId),
              let key = object["idempotencyKey"] as? String, (1...200).contains(key.count),
              let text = object["text"] as? String, (1...8000).contains(text.count)
        else {
            return Self.json(400, "{\"error\":\"Invalid agent reminder request\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == access.serverId else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        let ledgerKey = "\(access.clientId)\n\(agentId)\n\(key)"
        lock.lock()
        if let existing = appAgentReminderLedger[ledgerKey] {
            lock.unlock()
            return Self.json(200, "{\"created\":false,\"messageId\":\(jsonString(existing)),\"surface\":{\"channelType\":\"dm\",\"channelName\":\"reminders\",\"target\":\"dm:@reminders\"}}")
        }
        var channelId = agentReminderSurfaceChannels[agentId]
        if let existing = channelId, postableChannels[existing]?.deletedAt != nil {
            agentReminderSurfaceChannels.removeValue(forKey: agentId)
            channelId = nil
        }
        lock.unlock()
        if channelId == nil {
            let createdChannel = oauth.createChannel(serverId: access.serverId, name: "reminders", creatorUserId: agentId, type: "dm")
            oauth.addChannelAgent(channelId: createdChannel, agentId: agentId)
            lock.lock()
            postableChannels[createdChannel] = PostableChannel(serverId: access.serverId, memberIds: [agentId], kind: "dm", name: "reminders")
            agentReminderSurfaceChannels[agentId] = createdChannel
            lock.unlock()
            channelId = createdChannel
        }
        guard let channelId else { return Self.json(500, "{\"error\":\"reminder surface unavailable\"}") }
        let message = oauth.createMessageRecord(
            channelId: channelId,
            content: text,
            senderId: "system",
            senderType: "user",
            messageType: "system",
            systemSubtype: "agent.reminder_due"
        )
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: message.id,
            channelId: channelId,
            senderId: "system",
            content: text,
            randomId: nil,
            messageType: "system",
            senderType: "user",
            systemSubtype: "agent.reminder_due"
        ))
        appAgentReminderLedger[ledgerKey] = message.id
        lock.unlock()
        return Self.json(200, "{\"created\":true,\"messageId\":\(jsonString(message.id)),\"surface\":{\"channelType\":\"dm\",\"channelName\":\"reminders\",\"target\":\"dm:@reminders\"}}")
    }

    public func softDeleteAgentReminderSurfaceForTesting(agentId: String) {
        lock.lock()
        if let channelId = agentReminderSurfaceChannels[agentId] {
            postableChannels[channelId]?.deletedAt = Date()
        }
        lock.unlock()
    }

    public func agentReminderSurfaceForTesting(agentId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return agentReminderSurfaceChannels[agentId]
    }

    public func agentUserChannels(authorization: String?, name: String, limit: String?, offset: String?) -> HTTPReply {
        guard let identity = agentCredentialIdentity(authorization: authorization, capability: "channels") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        guard agentCredentialScopes(authorization: authorization)?.contains("read") == true else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"read\"}")
        }
        let scopes = agentCredentialScopes(authorization: authorization) ?? []
        for required in ["channel:read", "server:read"] where !scopes.contains(required) {
            return Self.json(403, "{\"error\":\"missing required scope\",\"requiredScope\":\(jsonString(required)),\"reason\":\"missing_scope\"}")
        }
        guard agentUserPageValues(limit: limit, offset: offset) != nil else {
            return Self.json(400, "{\"error\":\"Invalid page window\",\"code\":\"agent_api_contract_invalid\"}")
        }
        guard let payload = agentUserChannelsPayload(identity: identity, name: name, limit: limit, offset: offset) else {
            return Self.json(404, "{\"error\":\"User not found or not visible\",\"code\":\"user_not_found\"}")
        }
        return Self.json(payload.status, payload.json)
    }

    public func agentUserInfo(authorization: String?, name: String, limit: String?, offset: String?) -> HTTPReply {
        guard let identity = agentCredentialIdentity(authorization: authorization, capability: "channels") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        guard agentCredentialScopes(authorization: authorization)?.contains("read") == true else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"read\"}")
        }
        let scopes = agentCredentialScopes(authorization: authorization) ?? []
        for required in ["channel:read", "server:read"] where !scopes.contains(required) {
            return Self.json(403, "{\"error\":\"missing required scope\",\"requiredScope\":\(jsonString(required)),\"reason\":\"missing_scope\"}")
        }
        let normalized = name.hasPrefix("@") ? String(name.dropFirst()) : name
        if normalized.isEmpty || agentUserPageValues(limit: limit, offset: offset) == nil {
            return Self.json(400, "{\"error\":\"User not found or not visible\",\"code\":\"user_not_found\"}")
        }
        guard let payload = agentUserChannelsPayload(identity: identity, name: name, limit: limit, offset: offset) else {
            return Self.json(404, "{\"error\":\"User not found or not visible\",\"code\":\"user_not_found\"}")
        }
        return HTTPReply(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store"], body: payload.text)
    }

    public func conversationReadAll(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = sidebarReadAllEnabled
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil,
              let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let hasAccess = postableChannels[channelId]?.memberIds.contains(userId) == true
            || oauth.channelHumanIds(channelId: channelId).contains(userId)
            || oauth.channelType(id: channelId) == "channel"
        guard hasAccess else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        var scopeIds = [channelId]
        for (_, follow) in threadFollows where follow.userId == userId && follow.parentMessageId != "" {
            guard let parentRow = humanMessageRows.first(where: { $0.id == follow.parentMessageId }),
                  parentRow.channelId == channelId
            else { continue }
            if !scopeIds.contains(follow.threadChannelId) { scopeIds.append(follow.threadChannelId) }
        }
        let rows = scopeIds.map { scope -> String in
            let latest = humanMessageRows.filter { $0.channelId == scope }.map(\.seq).max() ?? 0
            let key = "\(userId)\n\(scope)"
            let previous = userChannelReadCursorsForTesting[key] ?? 0
            let version = previous + 1
            userChannelReadCursorsForTesting[key] = max(previous, latest)
            return "{\"scopeId\":\(jsonString(scope)),\"maxReadSeq\":\(latest),\"readStateVersion\":\(version)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"serverId\":\(jsonString(serverId)),\"scopes\":[\(rows)]}")
    }

    public func postReadMutation(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let mutationId = object["mutationId"] as? String,
              ServerScope.isUUID(mutationId)
        else {
            return Self.json(400, "{\"error\":\"Invalid mutation id\",\"code\":\"INVALID_MUTATION_ID\"}")
        }
        guard mutationId != "00000000-0000-1000-8000-000000000000" else {
            return Self.json(400, "{\"error\":\"Invalid mutation id\",\"code\":\"INVALID_MUTATION_ID\"}")
        }
        guard let rawKind = object["kind"] as? String else {
            return Self.json(400, "{\"error\":\"Invalid mutation payload\",\"code\":\"INVALID_MUTATION_PAYLOAD\"}")
        }
        let rawScope = (object["scopeId"] as? String).flatMap { ServerScope.isUUID($0) ? $0 : nil }
        let rawThrough = (object["throughSeq"] as? NSNumber)?.stringValue ?? (object["throughSeq"] as? String)
        let fingerprint = "\(rawKind):\(rawScope ?? ""):\(rawThrough ?? "")"
        let key = "\(serverId)\n\(userId)\n\(mutationId)"
        lock.lock()
        if let existing = readMutationRecords[key] {
            guard existing.fingerprint == fingerprint else {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Mutation id reused with a different payload\",\"code\":\"MUTATION_ID_PAYLOAD_MISMATCH\"}")
            }
            let cursor = userChannelReadCursorsForTesting["\(userId)\n\(existing.scopeId ?? "")"] ?? 0
            lock.unlock()
            if existing.kind == "channel_read_all", cursor > 0 {
                return Self.json(200, "{\"outcome\":\"ALREADY_TERMINAL\",\"ack\":{\"terminalReason\":\"completed\",\"capturedBoundary\":[{\"scopeId\":\(jsonString(existing.scopeId ?? "")),\"throughSeq\":\(cursor)}],\"scopes\":[{\"scopeId\":\(jsonString(existing.scopeId ?? "")),\"maxReadSeq\":\(cursor)}]}}")
            }
            return Self.json(200, "{\"outcome\":\"ALREADY_ADMITTED\"}")
        }
        lock.unlock()
        guard rawKind == "global_read_all" || rawKind == "channel_read_all" else {
            return Self.json(400, "{\"error\":\"Invalid mutation payload\",\"code\":\"INVALID_MUTATION_PAYLOAD\"}")
        }
        var scopeId: String?
        if rawKind == "channel_read_all" {
            guard let rawScope else {
                return Self.json(400, "{\"error\":\"Invalid mutation payload\",\"code\":\"INVALID_MUTATION_PAYLOAD\"}")
            }
            guard let channelType = oauth.channelType(id: rawScope), oauth.channelInfo(id: rawScope) != nil else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            lock.lock()
            let hasOwnedCursor = userChannelReadCursorsForTesting["\(userId)\n\(rawScope)"] != nil
            let visible = postableChannels[rawScope]?.memberIds.contains(userId) == true
                || oauth.channelHumanIds(channelId: rawScope).contains(userId)
                || (channelType == "channel" && oauth.memberRole(serverId: serverId, userId: userId) != nil)
                || (hasOwnedCursor && oauth.memberRole(serverId: serverId, userId: userId) != nil)
            lock.unlock()
            guard visible else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            scopeId = rawScope
        }
        lock.lock()
        let sequenceKey = "\(serverId)\n\(userId)"
        let seq = (readMutationAuthoritySeq[sequenceKey] ?? 0) + 1
        readMutationAuthoritySeq[sequenceKey] = seq
        readMutationRecords[key] = ReadMutationRecord(
            mutationId: mutationId, serverId: serverId, principalId: userId,
            kind: rawKind, scopeId: scopeId, fingerprint: fingerprint,
            authoritySeq: seq, state: "admitted"
        )
        readMutationOrder.append(key)
        lock.unlock()
        return Self.json(201, "{\"outcome\":\"ADMITTED\",\"serverId\":\(jsonString(serverId)),\"principalId\":\(jsonString(userId)),\"authoritySeq\":\(seq),\"mutationId\":\(jsonString(mutationId))}")
    }

    public func readMutationFrontier(authorization: String?, scopeIds: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let sequences = readMutationAuthoritySeq.filter { $0.key.hasSuffix("\n\(userId)") || $0.key.contains("\n\(userId)") }
        let upper = sequences.values.max() ?? 0
        let keys = readMutationOrder.filter { readMutationRecords[$0]?.principalId == userId }
        let records = keys.compactMap { readMutationRecords[$0] }
        var lastTerminal = 0
        let items = records.map { record -> String in
            if record.state != "admitted" { lastTerminal = max(lastTerminal, record.authoritySeq) }
            return "{\"mutationId\":\(jsonString(record.mutationId)),\"authoritySeq\":\(record.authoritySeq),\"state\":\(jsonString(record.state))}"
        }.joined(separator: ",")
        var scopesJSON: String?
        if let scopeIds {
            let rows = scopeIds.split(separator: ",").map(String.init).map { scope -> String in
                let cursor = userChannelReadCursorsForTesting["\(userId)\n\(scope)"] ?? 0
                return "{\"scopeId\":\(jsonString(scope)),\"maxReadSeq\":\(cursor)}"
            }.joined(separator: ",")
            scopesJSON = "[\("\(rows)")]"
        }
        lock.unlock()
        let scopesField = scopesJSON.map { ",\"scopes\":\($0)" } ?? ""
        return Self.json(200, "{\"nextAuthoritySeq\":\(upper + 1),\"lastTerminalAuthoritySeq\":\(lastTerminal),\"snapshotUpperAuthoritySeq\":\(upper),\"items\":[\(items)]\(scopesField)}")
    }


    public func acceptJointChannelInvite(authorization: String?, inviteId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        guard let index = jointInvites.firstIndex(where: { $0.id == inviteId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Invite not found\"}")
        }
        let invite = jointInvites[index]
        lock.unlock()
        guard oauth.memberRole(serverId: invite.targetServerId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        oauth.addChannelHuman(channelId: invite.targetChannelId, userId: userId)
        lock.lock()
        jointInvites[index].status = "accepted"
        postableChannels[invite.targetChannelId]?.memberIds.insert(userId)
        let channel = postableChannels[invite.targetChannelId]
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(invite.targetChannelId)),\"name\":\(jsonString(channel?.name ?? "")),\"type\":\"joint\",\"joined\":true}")
    }

    public func listChannels(authorization: String?, serverId: String, archived: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let guestVisibleSnapshot = guestVisibleChannels
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = oauth.channelsForServer(serverId: serverId, userId: userId, includeArchived: archived == "include")
            .filter { archived == "include" || oauth.channelArchivedAt(id: $0.id) == nil }
            .filter { role != "guest" || (guestVisibleSnapshot[$0.id] ?? true) }
            .map { channel -> String in
            let last = channel.lastMessageAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
            let muteSeq = channel.muteFromSeq.map(String.init) ?? "null"
            let archivedAt = oauth.channelArchivedAt(id: channel.id).map { jsonString(formatter.string(from: $0)) } ?? "null"
            let displayPrefs = oauth.channelDisplayPrefs(channelId: channel.id, userId: userId)
            lock.lock()
            let localRole = channelHumanRoles["\(channel.id)\n\(userId)"]
            let isJoint = jointProjections.contains { $0.localChannelId == channel.id }
            lock.unlock()
            let serverAdmin = role == "owner" || role == "admin"
            let capability = localRole == "admin" || serverAdmin
            let basis: String? = localRole == "admin" ? "channel_role" : (serverAdmin ? "server_role" : nil)
            let channelRole = basis == nil ? "member" : "admin"
            let caps = "{\"editChannelMetadata\":\(capability),\"archiveChannels\":\(capability && !isJoint),\"addChannelMembers\":\(capability && !isJoint),\"removeChannelMembers\":\(capability && !isJoint),\"changeChannelMemberRoles\":\(capability),\"manageGuestAccess\":\(serverAdmin && !isJoint),\"deleteChannels\":\(serverAdmin),\"changeChannelVisibility\":\(serverAdmin),\"federateChannels\":\(serverAdmin)}"
            return "{\"id\":\(jsonString(channel.id)),\"name\":\(jsonString(channel.name)),\"type\":\(jsonString(channel.type)),\"joined\":\(channel.name == "all" || channel.joined),\"archivedAt\":\(archivedAt),\"lastMessageAt\":\(last),\"activityMuted\":\(channel.activityMuted),\"muteFromSeq\":\(muteSeq),\"prefsVersion\":\(channel.prefsVersion),\"activityMuteSupported\":\(channel.type == "channel"),\"collapseLongMessages\":\(displayPrefs.collapseLongMessages),\"displayPrefsVersion\":\(displayPrefs.prefsVersion),\"channelRole\":\(jsonString(channelRole)),\"channelAdminBasis\":\(basis.map { jsonString($0) } ?? "null"),\"channelCapabilities\":\(caps)}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func completeProfile(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawName = object["name"] as? String,
              let rawDisplay = object["displayName"] as? String
        else {
            return Self.json(400, "{\"error\":\"name and displayName are required\",\"code\":\"PROFILE_SETUP_INVALID\"}")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !displayName.isEmpty else {
            return Self.json(400, "{\"error\":\"name and displayName are required\",\"code\":\"PROFILE_SETUP_INVALID\"}")
        }
        let lowered = name.lowercased()
        if lowered.hasPrefix("pending_") || Self.reservedAgentNames.contains(lowered) {
            return Self.json(400, "{\"error\":\"This username is reserved. Choose another name.\",\"code\":\"PROFILE_SETUP_NAME_RESERVED\"}")
        }
        lock.lock()
        guard let key = accounts.first(where: { $0.value.id == userId })?.key, var account = accounts[key] else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        if let completedAt = account.profileSetupCompletedAt {
            let replay = account.name == name && (account.displayName ?? account.name) == displayName
            lock.unlock()
            if replay {
                let user = Self.userJSON(accounts[key] ?? account)
                return Self.json(200, "{\"name\":\(jsonString(account.name)),\"displayName\":\(jsonString(account.displayName ?? account.name)),\"profileSetupCompletedAt\":\(jsonString(Self.isoString(completedAt))),\"user\":\(user)}")
            }
            return Self.json(409, "{\"error\":\"Profile setup is already completed\",\"code\":\"PROFILE_SETUP_ALREADY_COMPLETED\"}")
        }
        let taken = Set(accounts.values.filter { $0.id != userId }.map { $0.name.lowercased() })
        guard !taken.contains(lowered) else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"That username is taken\",\"code\":\"PROFILE_SETUP_NAME_TAKEN\"}")
        }
        account.name = name
        account.displayName = displayName
        account.profileSetupCompletedAt = Date()
        accounts[key] = account
        lock.unlock()
        let completed = account.profileSetupCompletedAt ?? Date()
        let user = Self.userJSON(account)
        return Self.json(200, "{\"name\":\(jsonString(name)),\"displayName\":\(jsonString(displayName)),\"profileSetupCompletedAt\":\(jsonString(Self.isoString(completed))),\"user\":\(user)}")
    }

    public func createServer(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let profileSetupPending = accounts.values.first { $0.id == userId }.map {
            $0.emailVerified && $0.profileSetupCompletedAt == nil
        } ?? false
        lock.unlock()
        if profileSetupPending {
            return Self.json(403, "{\"error\":\"Profile setup required\",\"code\":\"PROFILE_SETUP_REQUIRED\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawName = object["name"] as? String,
              let rawSlug = object["slug"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid server request\"}")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !slug.isEmpty else {
            return Self.json(400, "{\"error\":\"Invalid server request\"}")
        }
        if let existing = oauth.serverIdForSlug(slug) {
            if let profile = oauth.serverProfile(id: existing), let role = oauth.memberRole(serverId: existing, userId: userId) {
                return Self.json(200, "{\"id\":\(jsonString(profile.id)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"role\":\(jsonString(role))}")
            }
            return Self.json(409, "{\"error\":\"Slug is already taken\"}")
        }
        guard slug.count >= 5 else {
            return Self.json(400, "{\"error\":\"Slug must be at least 5 characters\"}")
        }
        let serverId = UUID().uuidString.lowercased()
        oauth.addOwnedServer(id: serverId, slug: slug, name: name, ownerId: userId)
        return Self.json(200, "{\"id\":\(jsonString(serverId)),\"name\":\(jsonString(name)),\"slug\":\(jsonString(slug)),\"role\":\"owner\"}")
    }

    public func serverProductAnalyticsSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let enabled = oauth.serverAnalyticsAllowed(id: serverId) ?? true
        let canManage = role == "owner" || role == "admin"
        return Self.json(200, "{\"productAnalyticsEnabled\":\(enabled),\"canManageProductAnalytics\":\(canManage)}")
    }

    public func patchServerProductAnalyticsSettings(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["productAnalyticsEnabled"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"productAnalyticsEnabled must be a boolean\"}")
        }
        oauth.setServerProductAnalytics(id: serverId, enabled: enabled)
        return Self.json(200, "{\"productAnalyticsEnabled\":\(enabled),\"canManageProductAnalytics\":true}")
    }

    public func serverDetails(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let profile = oauth.serverProfile(id: serverId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        if role == "guest" {
            return Self.json(200, "{\"id\":\(jsonString(profile.id)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"avatarUrl\":null}")
        }
        let avatar = profile.avatarUrl.map { jsonString($0) } ?? "null"
        let body = "{\"id\":\(jsonString(profile.id)),\"ownerId\":\(jsonString(profile.ownerId)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"avatarUrl\":\(avatar),\"plan\":\(jsonString(profile.plan)),\"translationEnabled\":\(profile.translationEnabled),\"publiclyVisible\":\(profile.publiclyVisible),\"publicGuestJoinEnabled\":\(profile.publicGuestJoinEnabled)}"
        return Self.json(200, body)
    }

    public func setProviderConnectionsEnabled(serverId: String, enabled: Bool) {
        lock.lock()
        if enabled {
            providerConnectionsEnabledServers.insert(serverId)
        } else {
            providerConnectionsEnabledServers.remove(serverId)
        }
        lock.unlock()
    }

    public static let providerConnectionProviderIds = [
        "deepseek", "minimax", "minimax-cn", "zai", "zai-coding-cn", "moonshotai",
        "moonshotai-cn", "kimi-coding", "qwen-token-plan", "qwen-token-plan-cn",
        "openrouter", "openai", "anthropic", "google", "xai", "xiaomi",
        "openai-compatible", "anthropic-compatible",
    ]

    public func listProviderConnections(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let rows = providerConnections.filter { $0.serverId == serverId }
        lock.unlock()
        let connections = rows.map { Self.providerConnectionJSON($0) }.joined(separator: ",")
        let options = Self.providerConnectionProviderIds.map { id -> String in
            let kind = id.hasSuffix("-compatible") ? "gateway" : "preset"
            return "{\"id\":\(jsonString(id)),\"label\":\(jsonString(Self.providerConnectionLabel(id))),\"providerKind\":\(jsonString(kind))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"connections\":[\(connections)],\"providerOptions\":[\(options)]}")
    }

    public func createProviderConnection(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let providerId = object["providerId"] as? String,
              Self.providerConnectionProviderIds.contains(providerId),
              let apiKey = object["apiKey"] as? String, !apiKey.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let allowedKeys: Set<String> = ["name", "providerId", "apiKey", "endpointUrl", "supportsImageInput", "authMethod"]
        guard Set(object.keys).isSubset(of: allowedKeys) else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let now = Date()
        let connection = ProviderConnection(
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            providerId: providerId,
            endpointUrl: object["endpointUrl"] as? String,
            supportsImageInput: object["supportsImageInput"] as? Bool ?? false,
            status: "unchecked",
            configVersion: 1,
            credentialVersion: 1,
            hasCredential: true,
            createdAt: now,
            updatedAt: now
        )
        lock.lock()
        providerConnections.append(connection)
        lock.unlock()
        return Self.json(201, Self.providerConnectionJSON(connection))
    }

    public func retiredProviderProbe(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        return Self.json(410, "{\"error\":\"Provider probing is retired\"}")
    }

    public func patchProviderConnection(authorization: String?, serverId: String, connectionId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let allowedKeys: Set<String> = ["name", "providerId", "apiKey", "endpointUrl", "supportsImageInput", "authMethod"]
        guard Set(object.keys).isSubset(of: allowedKeys) else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        if object["apiKey"] != nil, object["providerId"] != nil {
            return Self.json(400, "{\"error\":\"Rotate the credential separately from provider configuration\"}")
        }
        lock.lock()
        guard let index = providerConnections.firstIndex(where: { $0.id == connectionId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        if let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providerConnections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let endpoint = object["endpointUrl"] as? String {
            providerConnections[index].endpointUrl = endpoint
        }
        if let supports = object["supportsImageInput"] as? Bool {
            providerConnections[index].supportsImageInput = supports
        }
        if let apiKey = object["apiKey"] as? String, !apiKey.isEmpty {
            providerConnections[index].credentialVersion += 1
            providerConnections[index].status = "unchecked"
            providerConnections[index].hasCredential = true
        }
        providerConnections[index].updatedAt = Date()
        let updated = providerConnections[index]
        lock.unlock()
        return Self.json(200, Self.providerConnectionJSON(updated))
    }

    public func rotateProviderConnectionCredential(authorization: String?, serverId: String, connectionId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let apiKey = object["apiKey"] as? String, !apiKey.isEmpty
        else {
            return Self.json(400, "{\"error\":\"apiKey is required\"}")
        }
        lock.lock()
        guard let index = providerConnections.firstIndex(where: { $0.id == connectionId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        providerConnections[index].credentialVersion += 1
        providerConnections[index].status = "unchecked"
        providerConnections[index].hasCredential = true
        providerConnections[index].updatedAt = Date()
        let updated = providerConnections[index]
        lock.unlock()
        return Self.json(200, Self.providerConnectionJSON(updated))
    }

    public func pushRegistration(installationId: String, provider: String) -> PushRegistration? {
        lock.lock()
        defer { lock.unlock() }
        return pushRegistrations.first { $0.installationId == installationId && $0.provider == provider }
    }

    public func registerPushDevice(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let installationId = object["installationId"] as? String,
              installationId.wholeMatch(of: /^[A-Za-z0-9._:-]{1,128}$/) != nil,
              let provider = object["provider"] as? String, provider == "apns" || provider == "fcm",
              let topic = object["topic"] as? String,
              topic.wholeMatch(of: /^[A-Za-z0-9.-]{1,155}$/) != nil,
              let deviceToken = object["deviceToken"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid push registration\"}")
        }
        let env = object["env"] as? String ?? ""
        if provider == "apns" {
            guard env == "sandbox" || env == "production",
                  deviceToken.wholeMatch(of: /^[A-Za-z0-9._-]{1,256}$/) != nil
            else {
                return Self.json(400, "{\"error\":\"Invalid push registration\"}")
            }
        } else {
            guard env == "production",
                  deviceToken.wholeMatch(of: /^[A-Za-z0-9._:-]{1,4096}$/) != nil
            else {
                return Self.json(400, "{\"error\":\"Invalid push registration\"}")
            }
        }
        let appVersion = object["appVersion"] as? String
        lock.lock()
        let familyId = principal.familyId ?? UUID().uuidString.lowercased()
        if sessionFamilies[familyId] == nil {
            sessionFamilies[familyId] = SessionFamily(userId: principal.userId)
        }
        var nonce = sessionFamilies[familyId]?.revokeCapabilityNonce
        if nonce == nil {
            let minted = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            sessionFamilies[familyId]?.revokeCapabilityNonce = minted
            nonce = minted
        }
        let revokeCapability = "\(familyId).\(nonce ?? "")"
        if let index = pushRegistrations.firstIndex(where: {
            $0.installationId == installationId && $0.provider == provider
        }) {
            pushRegistrations[index].env = env
            pushRegistrations[index].topic = topic
            pushRegistrations[index].deviceToken = deviceToken
            pushRegistrations[index].appVersion = appVersion
            pushRegistrations[index].userId = principal.userId
            pushRegistrations[index].serverId = serverId
            pushRegistrations[index].sessionFamilyId = familyId
            pushRegistrations[index].revokeCapability = revokeCapability
        } else {
            pushRegistrations.append(PushRegistration(
                installationId: installationId,
                provider: provider,
                env: env,
                topic: topic,
                deviceToken: deviceToken,
                appVersion: appVersion,
                userId: principal.userId,
                serverId: serverId,
                sessionFamilyId: familyId,
                revokeCapability: revokeCapability
            ))
        }
        lock.unlock()
        let registration = "{\"installationId\":\(jsonString(installationId)),\"provider\":\(jsonString(provider)),\"env\":\(jsonString(env)),\"topic\":\(jsonString(topic))}"
        return Self.json(200, "{\"revoke_capability\":\(jsonString(revokeCapability)),\"registration\":\(registration)}")
    }

    public func webPushEndpoints(userId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return webPushSubscriptions.filter { $0.userId == userId }.map { $0.endpoint }
    }

    public func recordWebPushSubscription(authorization: String?, body: String) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let endpoint = object["endpoint"] as? String,
              Self.isPublicHTTPSPushEndpoint(endpoint),
              let keys = object["keys"] as? [String: Any],
              let p256dh = keys["p256dh"] as? String, !p256dh.isEmpty,
              let auth = keys["auth"] as? String, !auth.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid push subscription\"}")
        }
        lock.lock()
        if !webPushSubscriptions.contains(where: { $0.userId == principal.userId && $0.endpoint == endpoint }) {
            webPushSubscriptions.append(WebPushSubscription(userId: principal.userId, endpoint: endpoint))
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }


    public func revokePushFamily(body: String) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let capability = object["capability"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid capability\"}")
        }
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              parts[0].wholeMatch(of: /^[A-Za-z0-9-]+$/) != nil,
              parts[1].wholeMatch(of: /^[A-Za-z0-9]+$/) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid capability\"}")
        }
        lock.lock()
        guard let familyId = sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key,
              var family = sessionFamilies[familyId]
        else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Capability is no longer valid\"}")
        }
        let now = Date()
        if let revokedAt = family.revokedAt {
            if let retain = family.capabilityRetainUntil, retain > now {
                lock.unlock()
                return Self.json(204, "")
            }
            _ = revokedAt
            lock.unlock()
            return Self.json(403, "{\"error\":\"Capability is no longer valid\"}")
        }
        family.revokedAt = now
        family.revokedReason = "push_family"
        family.capabilityRetainUntil = now.addingTimeInterval(30 * 24 * 60 * 60)
        sessionFamilies[familyId] = family
        let refreshTokens = sessions.filter { $0.value.familyId == familyId }.map { $0.key }
        for token in refreshTokens { sessions.removeValue(forKey: token) }
        let accessTokensToDrop = accessTokenFamilies.filter { $0.value == familyId }.map { $0.key }
        for token in accessTokensToDrop {
            accessTokens.removeValue(forKey: token)
            accessTokenFamilies.removeValue(forKey: token)
        }
        lock.unlock()
        return Self.json(204, "")
    }

    public func pushFamilyStatus(capability: String) -> (revoked: Bool, reason: String?, retainUntil: Date?)? {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let family = sessionFamilies.values.first(where: { $0.revokeCapabilityNonce == parts[1] }) else {
            return nil
        }
        return (family.revokedAt != nil, family.revokedReason, family.capabilityRetainUntil)
    }

    public func expirePushFamilyCapability(capability: String) {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return }
        lock.lock()
        if let familyId = sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key {
            sessionFamilies[familyId]?.capabilityRetainUntil = Date().addingTimeInterval(-1)
        }
        lock.unlock()
    }

    public func pushDeliveryStatus(authorization: String?, installationId: String?) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let installationId, installationId.wholeMatch(of: /^[A-Za-z0-9._:-]{1,128}$/) != nil else {
            return Self.json(400, "{\"error\":\"Valid installationId is required\"}")
        }
        lock.lock()
        let active = fcmPushAvailable && pushRegistrations.contains {
            $0.installationId == installationId
                && $0.provider == "fcm"
                && $0.userId == principal.userId
        }
        lock.unlock()
        let servers = oauth.serverIdsForMember(userId: principal.userId).sorted()
        let rows = servers.map { "\"\($0)\":{\"fcmActive\":\(active ? "true" : "false")}" }.joined(separator: ",")
        return Self.json(200, "{\"servers\":{\(rows)}}")
    }

    public func unbindPushInstallation(authorization: String?, serverId: String, installationId: String) -> HTTPReply {
        guard pushPrincipal(authorization) != nil else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        var unbound = 0
        for index in pushRegistrations.indices where pushRegistrations[index].installationId == installationId {
            pushRegistrations[index].userId = nil
            pushRegistrations[index].serverId = nil
            pushRegistrations[index].sessionFamilyId = nil
            unbound += 1
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"unbound\":\(unbound)}")
    }

    func pushPrincipal(_ authorization: String?) -> (userId: String, familyId: String?)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let userId = accessTokens[token]
        let familyId = accessTokenFamilies[token]
        lock.unlock()
        guard let userId else { return nil }
        return (userId, familyId)
    }

    public func assignAgentToProviderConnection(connectionId: String, serverId: String, agentId: String, computerName: String?) {
        lock.lock()
        providerAssignments.append(ProviderAssignment(
            connectionId: connectionId,
            serverId: serverId,
            agentId: agentId,
            computerName: computerName
        ))
        lock.unlock()
    }

    public func listAssignedProviderAgents(authorization: String?, serverId: String, connectionId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let known = providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assignments = providerAssignments.filter { $0.connectionId == connectionId && $0.serverId == serverId }
        lock.unlock()
        guard known else {
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        var rows: [String] = []
        for assignment in assignments {
            guard let info = oauth.providerAgentInfo(serverId: serverId, agentId: assignment.agentId) else { continue }
            let computer = assignment.computerName.map { jsonString($0) } ?? "null"
            rows.append("{\"id\":\(jsonString(assignment.agentId)),\"name\":\(jsonString(info.name)),\"displayName\":\(jsonString(info.displayName)),\"runtime\":\(jsonString(info.runtime)),\"status\":\(jsonString(info.status)),\"computerName\":\(computer),\"deleted\":\(info.deleted)}")
        }
        return Self.json(200, "{\"agents\":[\(rows.joined(separator: ","))]}")
    }

    public func detachProviderAgent(authorization: String?, serverId: String, connectionId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard agentId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return Self.json(400, "{\"error\":\"Invalid agent id\"}")
        }
        lock.lock()
        let known = providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assigned = providerAssignments.contains { $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId }
        lock.unlock()
        guard known else {
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        guard assigned else {
            return Self.json(404, "{\"error\":\"Provider agent assignment not found\"}")
        }
        let live = oauth.providerAgentInfo(serverId: serverId, agentId: agentId).map { !$0.deleted } ?? false
        if live {
            return Self.json(409, "{\"error\":\"The Agent still uses this provider connection\",\"code\":\"provider_connection_assignment_active\"}")
        }
        lock.lock()
        providerAssignments.removeAll { $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func deleteProviderConnection(authorization: String?, serverId: String, connectionId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let known = providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assignments = providerAssignments.filter { $0.connectionId == connectionId && $0.serverId == serverId }
        lock.unlock()
        guard known else {
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        let liveAssignments = assignments.filter { assignment in
            oauth.providerAgentInfo(serverId: serverId, agentId: assignment.agentId).map { !$0.deleted } ?? false
        }
        guard liveAssignments.isEmpty else {
            return Self.json(409, "{\"error\":\"Agents still use this provider connection\",\"code\":\"provider_connection_assignment_active\"}")
        }
        lock.lock()
        providerConnections.removeAll { $0.id == connectionId && $0.serverId == serverId }
        providerAssignments.removeAll { $0.connectionId == connectionId && $0.serverId == serverId }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
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
