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

}
