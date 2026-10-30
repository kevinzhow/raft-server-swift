import Crypto
import Foundation

public struct OAuthHuman: Sendable {
    public var id: String
    public var email: String
    public var name: String
    public var emailVerified: Bool
    public var avatarUrl: String?

    public init(id: String, email: String, name: String, emailVerified: Bool = false, avatarUrl: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.emailVerified = emailVerified
        self.avatarUrl = avatarUrl
    }
}

public enum OAuthSession: Sendable {
    case missing
    case invalid
    case user(OAuthHuman)
}

public struct CreatedOAuthClient: Sendable {
    public var id: String
    public var clientId: String
    public var clientSecret: String
}

public struct OAuthClientRejection: Error, Sendable {
    public var message: String
}

/// In-memory OAuth clients, human authorization codes, and access tokens.
/// `POST /api/oauth/authorize/human` and `POST /api/oauth/token` both use this ledger.
public final class OAuthLedger: @unchecked Sendable {
    public var jwtSecret: String = "test-jwt-secret"
    private let lock = NSLock()
    private var servers: [String: Server] = [:]
    private var agents: [String: Agent] = [:]
    private var members: [String: String] = [:]
    private var clients: [Client] = []
    private var requests: [AccessRequest] = []
    private var tokens: [AccessToken] = []
    private var installations: [Installation] = []
    private var installationTokens: [InstallationToken] = []

    public init() {}

    public func addOwnedServer(id: String, slug: String, name: String, ownerId: String) {
        lock.lock()
        servers[id] = Server(id: id, slug: slug, name: name)
        members["\(id)\n\(ownerId)"] = "owner"
        lock.unlock()
    }

    public func createAgent(serverId: String, name: String, displayName: String? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        agents[id] = Agent(id: id, serverId: serverId, name: name, displayName: displayName ?? name)
        lock.unlock()
        return id
    }

    public func addMember(serverId: String, userId: String, role: String) {
        lock.lock()
        members["\(serverId)\n\(userId)"] = role
        lock.unlock()
    }

    public func removeMember(serverId: String, userId: String) {
        lock.lock()
        members.removeValue(forKey: "\(serverId)\n\(userId)")
        lock.unlock()
    }

    public func updateServer(id: String, name: String, avatarUrl: String?) {
        lock.lock()
        if var server = servers[id] {
            server.name = name
            server.avatarUrl = avatarUrl
            servers[id] = server
        }
        lock.unlock()
    }

    public func setServerPlan(id: String, plan: String) {
        lock.lock()
        if var server = servers[id] {
            server.plan = plan
            servers[id] = server
        }
        lock.unlock()
    }

    public func deleteServer(id: String) {
        lock.lock()
        if var server = servers[id] {
            server.deleted = true
            servers[id] = server
        }
        lock.unlock()
    }

    public func createClient(
        serverId: String,
        createdByUserId: String,
        name: String,
        clientId: String,
        appType: String = "server_local",
        description: String? = nil,
        homepageUrl: String? = nil,
        returnUrl: String? = nil
    ) throws -> CreatedOAuthClient {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OAuthClientRejection(message: "name is required") }
        let normalized = clientId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.wholeMatch(of: /^[a-z][a-z0-9-]{2,63}$/) != nil else {
            throw OAuthClientRejection(message: "clientId must start with a letter and contain only lowercase letters, numbers, and hyphens")
        }
        var bytes = Data(count: 24)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let secret = "raft_secret_" + bytes.map { String(format: "%02x", $0) }.joined()
        let id = UUID().uuidString.lowercased()
        lock.lock()
        clients.append(Client(
            id: id,
            serverId: serverId,
            clientId: normalized,
            secretHash: sha256(secret),
            appType: appType,
            name: trimmed,
            createdByUserId: createdByUserId,
            descriptionText: description,
            homepageUrl: homepageUrl,
            returnUrl: returnUrl
        ))
        lock.unlock()
        return CreatedOAuthClient(id: id, clientId: normalized, clientSecret: secret)
    }

    /// Moves a human authorization code one second past its 10-minute life. The token endpoint must not mint.
    public func expireAuthorizationCode(id: String) {
        lock.lock()
        if let index = requests.firstIndex(where: { $0.id == id }) {
            requests[index].createdAt = Date().addingTimeInterval(-(10 * 60 + 1))
        }
        lock.unlock()
    }

    /// Records an active installation whose approved groups are also the App's current outbound groups.
    public func installClient(serverId: String, clientRecordId: String, installedByUserId: String, groups: [String]) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].outboundGroups = groups
        }
        installations.append(Installation(
            id: id,
            serverId: serverId,
            clientId: clientRecordId,
            installedByUserId: installedByUserId,
            approvedGroups: groups,
            grantRevision: 1,
            status: "active"
        ))
        lock.unlock()
        return id
    }

    /// Test and retirement support: App class and platform registration are
    /// live authorities, never copied onto a token row.
    public func setClientAppType(clientRecordId: String, appType: String) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].appType = appType
        }
        lock.unlock()
    }

    public func registerExternalApp(clientRecordId: String, provider: String, state: String) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].externalProvider = provider
            clients[index].externalState = state
        }
        lock.unlock()
    }

    public func installationTokenCount(clientRecordId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return installationTokens.filter { $0.clientId == clientRecordId }.count
    }

    public func setInstallationStatus(id: String, status: String) {
        lock.lock()
        if let index = installations.firstIndex(where: { $0.id == id }) {
            installations[index].status = status
        }
        lock.unlock()
    }

    public func setClientEnabled(clientRecordId: String, enabled: Bool) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].enabled = enabled
        }
        lock.unlock()
    }

    public func accessTokenCount(requestId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tokens.filter { $0.requestId == requestId }.count
    }

    /// `POST /api/oauth/installation-token`. Client credentials mint a token for one active installation.
    public func mintInstallationToken(authorization: String?, body: String) -> HTTPReply {
        let fields = tokenFields(body)
        guard let credentials = clientCredentials(authorization: authorization, fields: fields) else {
            return json(401, "{\"error\":\"Client credentials are required\"}", cacheControl: "private, no-store")
        }
        let installationId = fields["installation_id"] ?? fields["installationId"] ?? ""
        guard !installationId.isEmpty else {
            return json(400, "{\"error\":\"installation_id is required\"}", cacheControl: "private, no-store")
        }
        lock.lock()
        guard let client = clients.first(where: {
            $0.clientId == credentials.clientId && isUserManaged($0) && $0.enabled && $0.secretHash == sha256(credentials.clientSecret)
        }) else {
            lock.unlock()
            return json(401, "{\"error\":\"Invalid client credentials\"}", cacheControl: "private, no-store")
        }
        guard let installation = installations.first(where: {
            $0.id == installationId && $0.clientId == client.id && $0.status == "active"
        }) else {
            lock.unlock()
            return json(404, "{\"error\":\"Active installation not found\"}", cacheControl: "private, no-store")
        }
        let groups = client.outboundGroups.filter { installation.approvedGroups.contains($0) }
        guard !groups.isEmpty else {
            lock.unlock()
            return json(400, "{\"error\":\"Installation has no effective read groups\"}", cacheControl: "private, no-store")
        }
        var raw = Data(count: 32)
        for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
        let accessToken = "raft_installation_" + base64url(raw)
        installationTokens.append(InstallationToken(
            tokenHash: sha256(accessToken),
            installationId: installation.id,
            clientId: client.id,
            serverId: installation.serverId,
            grantRevision: installation.grantRevision,
            groups: groups,
            audience: "raft:app-installation-api",
            expiresAt: Date().addingTimeInterval(10 * 60)
        ))
        lock.unlock()
        let groupJSON = groups.map { jsonString($0) }.joined(separator: ",")
        let document = "{\"access_token\":\(jsonString(accessToken)),\"token_type\":\"Bearer\",\"expires_in\":600,\"installation_id\":\(jsonString(installation.id)),\"server_id\":\(jsonString(installation.serverId)),\"grant_revision\":\(installation.grantRevision),\"groups\":[\(groupJSON)],\"audience\":\"raft:app-installation-api\"}"
        return json(200, document, cacheControl: "private, no-store")
    }

    /// `GET /api/oauth/userinfo`. Only principal access tokens resolve; an App
    /// installation credential is not a principal and stays 401.
    public func userinfo(authorization: String?, baseURL: String) -> HTTPReply {
        guard let raw = bearerToken(authorization) else {
            return json(401, "{\"error\":\"Missing bearer token\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let token = principalTokenLocked(raw),
              let client = clients.first(where: { $0.id == token.clientId }),
              let server = servers[token.serverId], !server.deleted,
              let request = requests.first(where: { $0.id == token.requestId }),
              let role = members["\(token.serverId)\n\(token.userId)"]
        else {
            return json(401, "{\"error\":\"Invalid or expired access token\"}")
        }
        let avatar = request.humanAvatarUrl
        let avatarJSON = avatar.map { jsonString($0) } ?? "null"
        let pictureJSON = userinfoPicture(avatar: avatar, baseURL: baseURL).map { jsonString($0) } ?? "null"
        var document = "{\"scope\":\(jsonString(token.scopes.joined(separator: " "))),\"client_id\":\(jsonString(client.clientId)),\"client_name\":\(jsonString(client.name)),\"server_id\":\(jsonString(server.id)),\"server_slug\":\(jsonString(server.slug)),\"sub\":\(jsonString(token.userId)),\"type\":\"human\",\"server_role\":\(jsonString(role)),\"preferred_username\":\(jsonString(request.humanName)),\"name\":\(jsonString(request.humanName)),\"avatar_url\":\(avatarJSON),\"picture\":\(pictureJSON),\"description\":null"
        if token.scopes.contains("email"), !request.humanEmail.isEmpty {
            document += ",\"email\":\(jsonString(request.humanEmail)),\"email_verified\":\(request.humanEmailVerified ? "true" : "false")"
        }
        document += "}"
        return json(200, document)
    }

    /// Only a Raft-uploaded user avatar becomes a picture URL.
    private func userinfoPicture(avatar: String?, baseURL: String) -> String? {
        guard let avatar,
              avatar.wholeMatch(of: /^(?i)\/(?:api\/)?avatars\/users\/[0-9a-f]+\.webp$/) != nil
        else { return nil }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + avatar
    }

    /// `GET /api/oauth/serverinfo`. The token names the Server; a query cannot
    /// redirect the read. Fields come from the live Server row.
    public func serverinfo(authorization: String?, baseURL: String) -> HTTPReply {
        guard let raw = bearerToken(authorization) else {
            return json(401, "{\"error\":\"Missing bearer token\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let token = principalTokenLocked(raw),
              let server = servers[token.serverId], !server.deleted
        else {
            return json(401, "{\"error\":\"Invalid or expired access token\"}")
        }
        if token.principalType == "agent" {
            guard let agentId = token.agentId,
                  let agent = agents[agentId],
                  agent.serverId == server.id,
                  !agent.deleted
            else {
                return json(401, "{\"error\":\"Invalid or expired access token\"}")
            }
        } else {
            guard members["\(token.serverId)\n\(token.userId)"] != nil else {
                return json(401, "{\"error\":\"Invalid or expired access token\"}")
            }
        }
        let avatarJSON = server.avatarUrl.map { jsonString($0) } ?? "null"
        let pictureJSON = absolutePicture(server.avatarUrl, baseURL: baseURL).map { jsonString($0) } ?? "null"
        let paid = server.plan != "free"
        let document = "{\"id\":\(jsonString(server.id)),\"slug\":\(jsonString(server.slug)),\"name\":\(jsonString(server.name)),\"avatar_url\":\(avatarJSON),\"picture\":\(pictureJSON),\"is_paid\":\(paid ? "true" : "false"),\"plan_tier\":\(jsonString(paid ? "paid" : "free"))}"
        return json(200, document)
    }

    private func absolutePicture(_ path: String?, baseURL: String) -> String? {
        guard let path else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        guard path.hasPrefix("/") else { return nil }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + path
    }

    /// `GET /api/oauth/agents`. Directory authority is the `agent:read` login
    /// scope, never an installation credential.
    public func agentDirectory(authorization: String?) -> HTTPReply {
        guard let raw = bearerToken(authorization) else {
            return json(401, "{\"error\":\"Missing bearer token\"}", cacheControl: "no-store")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let token = principalTokenLocked(raw),
              let client = clients.first(where: { $0.id == token.clientId }),
              let server = servers[token.serverId], !server.deleted,
              members["\(token.serverId)\n\(token.userId)"] != nil
        else {
            return json(401, "{\"error\":\"Invalid or expired access token\"}", cacheControl: "no-store")
        }
        guard client.enabled, token.scopes.contains("agent:read") else {
            return json(403, "{\"error\":\"agent:read permission is required from an enabled App\"}", cacheControl: "no-store")
        }
        return json(200, "{\"agents\":[]}", cacheControl: "no-store")
    }

    /// `POST /api/oauth/authorize/human`. A member receives a one-time human code.
    public func issueHumanAuthorization(session: OAuthSession, body: String) -> HTTPReply {
        switch session {
        case .missing:
            return json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        case .invalid:
            return json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        case .user(let human):
            return issueHumanAuthorization(human: human, body: body)
        }
    }

    /// `GET /api/app-installation/server`. A user session is not an App
    /// credential; only an active installation token resolves here.
    public func appInstallationServer(authorization: String?) -> HTTPReply {
        switch installationCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let credential):
            guard credential.groups.contains("server") else {
                return json(403, "{\"error\":\"Installation credential lacks server read authority\"}", cacheControl: "private, no-store")
            }
            lock.lock()
            guard let server = servers[credential.serverId], !server.deleted else {
                lock.unlock()
                return json(404, "{\"error\":\"Server not found\"}", cacheControl: "private, no-store")
            }
            let id = server.id
            let name = server.name
            let slug = server.slug
            lock.unlock()
            let document = "{\"installation_id\":\(jsonString(credential.installationId)),\"server\":{\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),\"slug\":\(jsonString(slug)),\"avatar_url\":null}}"
            return json(200, document, cacheControl: "private, no-store")
        }
    }

    /// `GET /api/app-installation/channels`. The `channel` group is separate
    /// from the `server` group an installation may have approved.
    public func appInstallationChannels(authorization: String?) -> HTTPReply {
        switch installationCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let credential):
            guard credential.groups.contains("channel") else {
                return json(403, "{\"error\":\"Installation credential lacks channel read authority\"}", cacheControl: "private, no-store")
            }
            return json(200, "{\"installation_id\":\(jsonString(credential.installationId)),\"channels\":[]}", cacheControl: "private, no-store")
        }
    }

    /// `POST /api/oauth/installations/lookup`. The authenticated client is the
    /// App boundary; a miss never discloses another App's installation.
    public func installationLookup(authorization: String?, body: String) -> HTTPReply {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        var fields: [String: String] = [:]
        if let value = object?["client_id"] as? String { fields["client_id"] = value }
        if let value = object?["client_secret"] as? String { fields["client_secret"] = value }
        guard let credentials = clientCredentials(authorization: authorization, fields: fields) else {
            return json(401, "{\"error\":\"Client credentials are required\"}", cacheControl: "private, no-store")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: {
            $0.clientId == credentials.clientId
                && isUserManaged($0)
                && ($0.appType != "third_party_global" || $0.enabled)
                && $0.secretHash == sha256(credentials.clientSecret)
        }) else {
            return json(401, "{\"error\":\"Invalid client credentials\"}", cacheControl: "private, no-store")
        }
        let raw = object?["server_id"] ?? object?["serverId"]
        let serverId = (raw as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverId.isEmpty else {
            return json(400, "{\"error\":\"server_id is required\"}", cacheControl: "private, no-store")
        }
        guard serverId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return json(400, "{\"error\":\"server_id must be a Server ID\"}", cacheControl: "private, no-store")
        }
        guard client.enabled else {
            return json(404, "{\"error\":\"Active installation not found\"}", cacheControl: "private, no-store")
        }
        guard let installation = installations.first(where: {
            $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
        }) else {
            return json(404, "{\"error\":\"Active installation not found\"}", cacheControl: "private, no-store")
        }
        let document = "{\"installation_id\":\(jsonString(installation.id)),\"server_id\":\(jsonString(installation.serverId)),\"setup\":{\"status\":\"not_required\",\"url\":null,\"description\":null,\"revision\":1,\"completedAt\":null}}"
        return json(200, document, cacheControl: "private, no-store")
    }

    /// `POST /api/oauth/requests/agent`. A server-local or installed App asks
    /// for an Agent; the owner behind the App may auto-grant.
    public func requestAgentAccess(authorization: String?, body: String) -> HTTPReply {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        var fields: [String: String] = [:]
        if let value = object?["client_id"] as? String { fields["client_id"] = value }
        if let value = object?["clientId"] as? String { fields["clientId"] = value }
        if let value = object?["client_secret"] as? String { fields["client_secret"] = value }
        if let value = object?["clientSecret"] as? String { fields["clientSecret"] = value }
        guard let credentials = clientCredentials(authorization: authorization, fields: fields) else {
            return json(401, "{\"error\":\"Client credentials are required\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: {
            $0.clientId == credentials.clientId
                && isUserManaged($0)
                && ($0.appType != "third_party_global" || $0.enabled)
                && $0.secretHash == sha256(credentials.clientSecret)
        }) else {
            return json(401, "{\"error\":\"Invalid client credentials\"}")
        }
        let serverSlug = (object?["serverSlug"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = servers.values.first(where: { $0.slug == serverSlug && !$0.deleted }) else {
            return json(404, "{\"error\":\"Server not found\"}")
        }
        let agent: Agent?
        if let rawId = object?["agentId"] as? String, !rawId.isEmpty {
            guard rawId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
                return json(404, "{\"error\":\"Agent not found\"}")
            }
            agent = agents[rawId.lowercased()].flatMap { $0.serverId == server.id && !$0.deleted ? $0 : nil }
        } else {
            let agentName = (object?["agentName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            agent = agents.values.first(where: { $0.serverId == server.id && $0.name == agentName && !$0.deleted })
        }
        guard let agent else {
            return json(404, "{\"error\":\"Agent not found\"}")
        }
        let installed = installations.contains(where: {
            $0.clientId == client.id && $0.serverId == server.id && $0.status == "active"
        })
        guard (client.appType == "server_local" && client.serverId == server.id) || installed else {
            return json(404, "{\"error\":\"OAuth client not found for server\"}")
        }
        guard let scopes = normalizeScopes(object?["scopes"], allowed: client.allowedScopes ?? ["openid", "profile", "identity"], clientId: client.clientId) else {
            return json(400, "{\"error\":\"invalid_scope\"}")
        }
        let requestId = UUID().uuidString.lowercased()
        requests.append(AccessRequest(
            id: requestId,
            serverId: server.id,
            userId: client.createdByUserId,
            clientId: client.id,
            scopes: scopes,
            humanName: "",
            humanEmail: "",
            humanEmailVerified: false,
            humanAvatarUrl: nil,
            agentId: agent.id,
            status: "approved",
            createdAt: Date()
        ))
        let scopeJSON = scopes.map { jsonString($0) }.joined(separator: ",")
        let document = "{\"requestId\":\(jsonString(requestId)),\"status\":\"approved\",\"client\":{\"clientId\":\(jsonString(client.clientId)),\"appType\":\(jsonString(client.appType)),\"name\":\(jsonString(client.name)),\"description\":null,\"homepageUrl\":null},\"agent\":{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"serverId\":\(jsonString(server.id)),\"serverSlug\":\(jsonString(server.slug))},\"scopes\":[\(scopeJSON)]}"
        return json(200, document)
    }

    /// `GET /api/oauth/clients/lookup`. A server member reads one App and the
    /// requested scopes it may not ask for.
    public func clientLookup(session: OAuthSession, clientId: String, serverId: String, scope: String) -> HTTPReply {
        switch session {
        case .missing:
            return json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        case .invalid:
            return json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        case .user(let human):
            lock.lock()
            defer { lock.unlock() }
            guard members["\(serverId)\n\(human.id)"] != nil else {
                return json(404, "{\"error\":\"OAuth client not found for server\"}")
            }
            guard let client = clients.first(where: { candidate in
                guard candidate.clientId == clientId, isUserManaged(candidate) else { return false }
                if candidate.appType == "server_local" && candidate.serverId == serverId { return true }
                return installations.contains(where: {
                    $0.clientId == candidate.id && $0.serverId == serverId && $0.status == "active"
                })
            }) else {
                return json(404, "{\"error\":\"OAuth client not found for server\"}")
            }
            let allowed = client.allowedScopes ?? ["openid", "profile", "identity"]
            let requested = scope.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let validation = validateScopes(requested, allowed: allowed, clientId: client.clientId)
            let allowedJSON = allowed.map { jsonString($0) }.joined(separator: ",")
            let descriptionJSON = client.descriptionText.map { jsonString($0) } ?? "null"
            let homepageJSON = client.homepageUrl.map { jsonString($0) } ?? "null"
            let returnJSON = client.returnUrl.map { jsonString($0) } ?? "null"
            var document = "{\"clientId\":\(jsonString(client.clientId)),\"appType\":\(jsonString(client.appType)),\"name\":\(jsonString(client.name)),\"description\":\(descriptionJSON),\"homepageUrl\":\(homepageJSON),\"returnUrl\":\(returnJSON),\"logoUrl\":null,\"setupUrl\":null,\"setupDescription\":null,\"allowedScopes\":[\(allowedJSON)],\"availability\":\"ready\""
            if !requested.isEmpty {
                let reasonJSON = validation.reason.map { jsonString($0) } ?? "null"
                let disallowedJSON = validation.disallowed.map { jsonString($0) }.joined(separator: ",")
                document += ",\"scopeValidation\":{\"allowed\":\(validation.allowed ? "true" : "false"),\"reason\":\(reasonJSON),\"disallowedScopes\":[\(disallowedJSON)]}"
            }
            document += "}"
            return json(200, document)
        }
    }

    /// `POST /api/oauth/token`. Form fields, camelCase JSON, and HTTP Basic all name the same client.
    public func exchangeToken(authorization: String?, body: String, issuer: String) -> HTTPReply {
        let fields = tokenFields(body)
        if fields["code_verifier"] != nil {
            return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization code, redirect URI, or PKCE verifier is invalid\"}")
        }
        guard let credentials = clientCredentials(authorization: authorization, fields: fields) else {
            return json(401, "{\"error\":\"Client credentials are required\"}")
        }
        let grantType = fields["grantType"] ?? fields["grant_type"] ?? ""
        if grantType == "urn:slock:grant-type:agent_request" {
            return exchangeAgentRequest(fields: fields, credentials: credentials)
        }
        guard grantType == "authorization_code" else {
            return json(400, "{\"error\":\"Unsupported grant type\"}")
        }
        let code = (fields["code"] ?? "").lowercased()
        guard !code.isEmpty else { return json(400, "{\"error\":\"code is required\"}") }
        guard code.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) != nil else {
            return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization request is invalid or has expired\"}")
        }

        lock.lock()
        guard let client = clients.first(where: { $0.clientId == credentials.clientId && $0.appType != "slock_builtin" && $0.secretHash == sha256(credentials.clientSecret) }) else {
            lock.unlock()
            return json(401, "{\"error\":\"Invalid client credentials\"}")
        }
        guard let index = requests.firstIndex(where: { $0.id == code && $0.clientId == client.id }) else {
            lock.unlock()
            return json(404, "{\"error\":\"Access request not found\"}")
        }
        let request = requests[index]
        if request.consumedAt != nil {
            lock.unlock()
            return json(409, "{\"error\":\"request_already_consumed\",\"error_description\":\"This Login with Raft request is one-time and has already been exchanged. Discard it and obtain a fresh request before retrying.\",\"next_action\":\"obtain_fresh_request\"}")
        }
        let now = Date()
        if now.timeIntervalSince(request.createdAt) > 10 * 60 {
            lock.unlock()
            return json(400, "{\"error\":\"authorization_code_expired\",\"error_description\":\"This Login with Raft authorization code has expired. Obtain a fresh human authorization before retrying.\",\"next_action\":\"obtain_fresh_authorization\"}")
        }
        guard let server = servers[request.serverId], !server.deleted,
              let role = members["\(request.serverId)\n\(request.userId)"]
        else {
            lock.unlock()
            return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization identity is no longer available\"}")
        }
        var raw = Data(count: 32)
        for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
        let accessToken = "slock_at_" + raw.map { String(format: "%02x", $0) }.joined()
        let expiresAt = now.addingTimeInterval(60 * 60)
        tokens.append(AccessToken(
            serverId: request.serverId,
            userId: request.userId,
            clientId: client.id,
            requestId: request.id,
            tokenHash: sha256(accessToken),
            scopes: request.scopes,
            expiresAt: expiresAt
        ))
        requests[index].consumedAt = now
        let humanName = request.humanName
        let humanEmail = request.humanEmail
        let scopes = request.scopes
        let clientKey = client.clientId
        let serverId = server.id
        let serverSlug = server.slug
        lock.unlock()

        let expiresIn = max(1, Int(expiresAt.timeIntervalSince(now)))
        let identity = OAuthIdentity(
            sub: request.userId,
            clientId: clientKey,
            scopes: scopes,
            name: humanName,
            email: humanEmail,
            serverId: serverId,
            serverSlug: serverSlug,
            serverRole: role
        )
        let idToken: String
        if scopes.contains("openid") {
            guard let signed = OAuthIDToken.sign(identity: identity, issuer: issuer, expiresIn: expiresIn, secret: jwtSecret) else {
                return json(500, "{\"error\":\"Failed to issue access token\"}")
            }
            idToken = signed
        } else {
            idToken = ""
        }
        let scope = scopes.joined(separator: " ")
        var document = "{\"access_token\":\(jsonString(accessToken)),\"token_type\":\"Bearer\",\"expires_in\":\(expiresIn),\"scope\":\(jsonString(scope))"
        if !idToken.isEmpty { document += ",\"id_token\":\(jsonString(idToken))" }
        document += "}"
        return json(200, document, cacheControl: "no-store")
    }

    private func exchangeAgentRequest(
        fields: [String: String],
        credentials: (clientId: String, clientSecret: String)
    ) -> HTTPReply {
        let requestId = (fields["requestId"] ?? fields["request_id"] ?? "").lowercased()
        guard !requestId.isEmpty else {
            return json(400, "{\"error\":\"requestId is required\"}")
        }
        guard requestId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) != nil else {
            return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization request is invalid or has expired\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: {
            $0.clientId == credentials.clientId
                && isUserManaged($0)
                && ($0.appType != "third_party_global" || $0.enabled)
                && $0.secretHash == sha256(credentials.clientSecret)
        }) else {
            return json(401, "{\"error\":\"Invalid client credentials\"}")
        }
        guard let index = requests.firstIndex(where: { $0.id == requestId && $0.clientId == client.id && $0.agentId != nil }) else {
            return json(404, "{\"error\":\"Access request not found\"}")
        }
        let request = requests[index]
        if request.consumedAt != nil {
            return json(409, "{\"error\":\"request_already_consumed\",\"error_description\":\"This access request is one-time and has already been exchanged.\",\"next_action\":\"obtain_fresh_request\"}")
        }
        guard request.status == "approved" else {
            return json(400, "{\"error\":\"authorization_pending\"}")
        }
        guard let agentId = request.agentId, let agent = agents[agentId], !agent.deleted else {
            return json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization identity is no longer available\"}")
        }
        var raw = Data(count: 32)
        for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
        let accessToken = "slock_at_" + raw.map { String(format: "%02x", $0) }.joined()
        let now = Date()
        tokens.append(AccessToken(
            serverId: request.serverId,
            userId: request.userId,
            clientId: client.id,
            requestId: request.id,
            tokenHash: sha256(accessToken),
            scopes: request.scopes,
            expiresAt: now.addingTimeInterval(60 * 60),
            principalType: "agent",
            agentId: agent.id
        ))
        requests[index].consumedAt = now
        let scope = request.scopes.joined(separator: " ")
        let document = "{\"access_token\":\(jsonString(accessToken)),\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\(jsonString(scope))}"
        return json(200, document, cacheControl: "no-store")
    }

    private func issueHumanAuthorization(human: OAuthHuman, body: String) -> HTTPReply {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        guard let clientKey = object?["clientId"] as? String, !clientKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return json(400, "{\"error\":\"clientId is required\"}")
        }
        guard let serverId = object?["serverId"] as? String, !serverId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return json(400, "{\"error\":\"serverId is required\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: {
            $0.clientId == clientKey.trimmingCharacters(in: .whitespacesAndNewlines) && $0.appType == "server_local" && $0.serverId == serverId && $0.appType != "slock_builtin"
        }) else {
            return json(404, "{\"error\":\"OAuth client not found for server\"}")
        }
        let requested = object?["scopes"]
        let scopes: [String]
        if requested == nil || requested is NSNull {
            scopes = ["openid", "profile"]
        } else {
            let validation = validateScopes(requested, allowed: client.allowedScopes ?? ["openid", "profile", "identity"], clientId: client.clientId)
            guard validation.allowed, !validation.scopes.isEmpty else {
                if validation.disallowed.isEmpty {
                    return json(400, "{\"error\":\"invalid_scope\"}")
                }
                return scopeError(validation)
            }
            scopes = validation.scopes
        }
        guard let server = servers[serverId], !server.deleted, let role = members["\(serverId)\n\(human.id)"] else {
            return json(404, "{\"error\":\"User is not a member of this server\"}")
        }
        let code = UUID().uuidString.lowercased()
        requests.append(AccessRequest(
            id: code,
            serverId: serverId,
            userId: human.id,
            clientId: client.id,
            scopes: scopes,
            humanName: human.name,
            humanEmail: human.email,
            humanEmailVerified: human.emailVerified,
            humanAvatarUrl: human.avatarUrl,
            createdAt: Date()
        ))
        let scopeJSON = scopes.map { jsonString($0) }.joined(separator: ",")
        let document = "{\"code\":\(jsonString(code)),\"client\":{\"clientId\":\(jsonString(client.clientId)),\"appType\":\(jsonString(client.appType)),\"name\":\(jsonString(client.name)),\"description\":null,\"homepageUrl\":null},\"server\":{\"id\":\(jsonString(server.id)),\"slug\":\(jsonString(server.slug)),\"role\":\(jsonString(role))},\"scopes\":[\(scopeJSON)],\"returnUrl\":null}"
        return json(200, document)
    }

    private struct ScopeValidation {
        var scopes: [String]
        var allowed: Bool
        var reason: String?
        var disallowed: [String]
    }

    private func validateScopes(_ value: Any?, allowed: [String], clientId: String) -> ScopeValidation {
        let rawList: [Any]
        if let list = value as? [String] {
            rawList = list
        } else if let list = value as? [Any] {
            rawList = list
        } else {
            return ScopeValidation(scopes: [], allowed: false, reason: nil, disallowed: [])
        }
        var seen = Set<String>()
        var scopes: [String] = []
        var unsupported = false
        var notAllowed = false
        var disallowed: [String] = []
        for item in rawList {
            guard let text = item as? String else {
                return ScopeValidation(scopes: [], allowed: false, reason: nil, disallowed: [])
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            if Self.legacyScopeAllowlist[clientId]?.contains(trimmed) == true {
                scopes.append(trimmed)
                continue
            }
            if !Self.raftScopes.contains(trimmed) {
                unsupported = true
                disallowed.append(trimmed)
                continue
            }
            if !allowed.contains(trimmed) {
                notAllowed = true
                disallowed.append(trimmed)
                continue
            }
            scopes.append(trimmed)
        }
        let reason: String?
        if unsupported && notAllowed {
            reason = "mixed"
        } else if unsupported {
            reason = "unsupported"
        } else if notAllowed {
            reason = "not_allowed"
        } else {
            reason = nil
        }
        return ScopeValidation(scopes: scopes, allowed: disallowed.isEmpty, reason: reason, disallowed: disallowed)
    }

    private func scopeError(_ validation: ScopeValidation) -> HTTPReply {
        let scopeList = validation.disallowed.joined(separator: ", ")
        let code: String
        let description: String
        switch validation.reason {
        case "unsupported":
            code = "OAUTH_SCOPE_UNSUPPORTED"
            description = "Raft does not support the requested OAuth scope: \(scopeList). Update the requested scopes and try again."
        case "not_allowed":
            code = "OAUTH_SCOPE_NOT_ALLOWED"
            description = "This OAuth client is not allowed to request: \(scopeList). Update the client's allowed scopes and try again."
        default:
            code = "OAUTH_SCOPE_INVALID"
            description = "Some requested OAuth scopes are unsupported or not allowed for this client: \(scopeList). Update the requested scopes or client permissions and try again."
        }
        let disallowedJSON = validation.disallowed.map { jsonString($0) }.joined(separator: ",")
        return json(400, "{\"error\":\"invalid_scope\",\"errorCode\":\(jsonString(code)),\"error_description\":\(jsonString(description)),\"disallowedScopes\":[\(disallowedJSON)]}")
    }

    private func normalizeScopes(_ value: Any?, allowed: [String], clientId: String) -> [String]? {
        let validation = validateScopes(value, allowed: allowed, clientId: clientId)
        guard validation.allowed, !validation.scopes.isEmpty else { return nil }
        return validation.scopes.sorted()
    }

    private static let raftScopes: Set<String> = [
        "openid", "profile", "email", "identity", "agent:read",
        "agent:event:write", "agent:notification:write", "agent:action_request:write",
    ]

    /// Exact legacy tuples still accepted for their original client only.
    private static let legacyScopeAllowlist: [String: Set<String>] = [
        "local-collabdoc-1": ["creator", "owner"],
        "linkerdog-796e47": ["meetings:read"],
        "winbox": [
            "winbox:opencli:google", "winbox:opencli:nga",
            "winbox:opencli:qixin", "winbox:opencli:twitter",
        ],
        "winbox-315c18": [
            "winbox:opencli:nga", "winbox:opencli:qixin", "winbox:opencli:slock",
            "winbox:opencli:twitter", "winbox:opencli:wcl", "winbox:python:exec",
        ],
    ]

    private func bearerToken(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }

    /// Caller holds `lock`. Installation tokens live in a different table and never match.
    private func principalTokenLocked(_ raw: String) -> AccessToken? {
        let hash = sha256(raw)
        guard let token = tokens.last(where: { $0.tokenHash == hash }), token.expiresAt > Date() else {
            return nil
        }
        return token
    }

    private func installationCredential(_ authorization: String?) -> InstallationCredentialResult {
        guard let raw = bearerToken(authorization) else {
            return .failure(json(401, "{\"error\":\"Installation bearer token is required\"}"))
        }
        lock.lock()
        defer { lock.unlock() }
        guard let credential = installationCredentialLocked(raw) else {
            return .failure(json(401, "{\"error\":\"Invalid, expired, or stale installation credential\"}"))
        }
        return .success(credential)
    }

    private enum InstallationCredentialResult {
        case failure(HTTPReply)
        case success(VerifiedInstallationCredential)
    }

    /// Caller holds `lock`. Rechecks the live App class, installation status,
    /// grant revision, and that the token's groups are still granted.
    private func installationCredentialLocked(_ raw: String) -> VerifiedInstallationCredential? {
        guard raw.hasPrefix("raft_installation_") else { return nil }
        guard let record = installationTokens.last(where: { $0.tokenHash == sha256(raw) }),
              record.expiresAt > Date(),
              record.audience == "raft:app-installation-api"
        else {
            return nil
        }
        guard let installation = installations.first(where: { $0.id == record.installationId }),
              installation.status == "active",
              installation.clientId == record.clientId,
              installation.serverId == record.serverId,
              installation.grantRevision == record.grantRevision
        else {
            return nil
        }
        guard let client = clients.first(where: { $0.id == record.clientId }),
              isUserManaged(client),
              client.enabled
        else {
            return nil
        }
        let currentGroups = client.outboundGroups.filter { installation.approvedGroups.contains($0) }
        guard record.groups.allSatisfy({ currentGroups.contains($0) }) else { return nil }
        return VerifiedInstallationCredential(
            installationId: installation.id,
            clientId: client.id,
            serverId: installation.serverId,
            groups: record.groups
        )
    }

    private struct VerifiedInstallationCredential {
        var installationId: String
        var clientId: String
        var serverId: String
        var groups: [String]
    }

    private func clientCredentials(authorization: String?, fields: [String: String]) -> (clientId: String, clientSecret: String)? {
        if let authorization, authorization.hasPrefix("Basic ") {
            let encoded = String(authorization.dropFirst("Basic ".count))
            if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8),
               let separator = decoded.firstIndex(of: ":"), separator != decoded.startIndex {
                return (String(decoded[..<separator]), String(decoded[decoded.index(after: separator)...]))
            }
        }
        let clientId = fields["client_id"] ?? fields["clientId"]
        let clientSecret = fields["client_secret"] ?? fields["clientSecret"]
        if let clientId, let clientSecret, !clientId.isEmpty, !clientSecret.isEmpty {
            return (clientId, clientSecret)
        }
        return nil
    }

    private func tokenFields(_ body: String) -> [String: String] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
            var fields: [String: String] = [:]
            for (key, value) in object {
                if let text = value as? String { fields[key] = text }
            }
            if object["code_verifier"] != nil { fields["code_verifier"] = fields["code_verifier"] ?? "" }
            return fields
        }
        var fields: [String: String] = [:]
        for part in trimmed.split(separator: "&", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = formDecode(pieces.first ?? "")
            let value = formDecode(pieces.count > 1 ? pieces[1] : "")
            if !name.isEmpty { fields[name] = value }
        }
        return fields
    }

    private func formDecode(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    private struct Server {
        var id: String
        var slug: String
        var name: String
        var avatarUrl: String? = nil
        var plan: String = "free"
        var deleted = false
    }

    private struct Agent {
        var id: String
        var serverId: String
        var name: String
        var displayName: String
        var deleted = false
    }

    private struct Client {
        var id: String
        var serverId: String
        var clientId: String
        var secretHash: String
        var appType: String
        var name: String
        var createdByUserId: String
        var descriptionText: String? = nil
        var homepageUrl: String? = nil
        var returnUrl: String? = nil
        var allowedScopes: [String]? = nil
        var outboundGroups: [String] = []
        var enabled: Bool = true
        var externalProvider: String? = nil
        var externalState: String? = nil
    }

    /// Mirrors `oauthClientIsUserManagedPredicate`: the tombstone class and
    /// any platform registration both remove installation authority.
    private func isUserManaged(_ client: Client) -> Bool {
        client.appType != "slock_builtin" && client.externalProvider == nil
    }

    private struct InstallationToken {
        var tokenHash: String
        var installationId: String
        var clientId: String
        var serverId: String
        var grantRevision: Int
        var groups: [String]
        var audience: String
        var expiresAt: Date
    }

    private struct Installation {
        var id: String
        var serverId: String
        var clientId: String
        var installedByUserId: String
        var approvedGroups: [String]
        var grantRevision: Int
        var status: String
    }

    private struct AccessRequest {
        var id: String
        var serverId: String
        var userId: String
        var clientId: String
        var scopes: [String]
        var humanName: String
        var humanEmail: String
        var humanEmailVerified: Bool
        var humanAvatarUrl: String?
        var agentId: String? = nil
        var status: String = "approved"
        var createdAt: Date
        var consumedAt: Date? = nil
    }

    private struct AccessToken {
        var serverId: String
        var userId: String
        var clientId: String
        var requestId: String
        var tokenHash: String
        var scopes: [String]
        var expiresAt: Date
        var principalType: String = "human"
        var agentId: String? = nil
    }

    private func json(_ status: Int, _ body: String, cacheControl: String? = nil) -> HTTPReply {
        var headers = [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(Data(body.utf8).count),
        ]
        if let cacheControl { headers["Cache-Control"] = cacheControl }
        return HTTPReply(status: status, headers: headers, body: body)
    }
}

private struct OAuthIdentity {
    var sub: String
    var clientId: String
    var scopes: [String]
    var name: String
    var email: String
    var serverId: String
    var serverSlug: String
    var serverRole: String
}

private enum OAuthIDToken {
    static func sign(identity: OAuthIdentity, issuer: String, expiresIn: Int, secret: String) -> String? {
        guard !secret.isEmpty, let privateKey = signingKey(secret: secret) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        var payload = "{\"iss\":\(jsonString(issuer)),\"sub\":\(jsonString(identity.sub)),\"aud\":\(jsonString(identity.clientId)),\"iat\":\(now),\"exp\":\(now + expiresIn)"
        if identity.scopes.contains("profile"), !identity.name.isEmpty {
            payload += ",\"name\":\(jsonString(identity.name)),\"preferred_username\":\(jsonString(identity.name))"
        }
        if identity.scopes.contains("email"), !identity.email.isEmpty {
            payload += ",\"email\":\(jsonString(identity.email)),\"email_verified\":true"
        }
        payload += ",\"type\":\"human\",\"server_id\":\(jsonString(identity.serverId)),\"server_slug\":\(jsonString(identity.serverSlug)),\"server_role\":\(jsonString(identity.serverRole))}"
        let publicBytes = privateKey.publicKey.x963Representation
        let kid = base64url(Data(SHA256.hash(data: publicBytes).prefix(16)))
        let header = "{\"alg\":\"ES256\",\"typ\":\"JWT\",\"kid\":\(jsonString(kid))}"
        let signingInput = "\(base64url(Data(header.utf8))).\(base64url(Data(payload.utf8)))"
        guard let signature = try? privateKey.signature(for: Data(signingInput.utf8)) else { return nil }
        return "\(signingInput).\(base64url(signature.rawRepresentation))"
    }

    private static func signingKey(secret: String) -> P256.Signing.PrivateKey? {
        let seed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Data("raft-oidc-v1".utf8),
            info: Data("id-token-es256-private".utf8),
            outputByteCount: 32
        )
        let seedBytes: [UInt8] = seed.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: UInt8.self))
        }
        let scalar = p256Scalar(seedBytes)
        return try? P256.Signing.PrivateKey(rawRepresentation: scalar)
    }

    /// `(seed mod (n-1)) + 1`, matching the Node P-256 reduction.
    private static func p256Scalar(_ seed: [UInt8]) -> Data {
        let modulus = hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550")
        var reduced = seed
        if compare(reduced, modulus) >= 0 {
            reduced = subtract(reduced, modulus)
        }
        return Data(addOne(reduced))
    }

    private static func hex(_ value: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            bytes.append(UInt8(value[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    private static func compare(_ left: [UInt8], _ right: [UInt8]) -> Int {
        for (lhs, rhs) in zip(left, right) where lhs != rhs {
            return lhs < rhs ? -1 : 1
        }
        return 0
    }

    private static func subtract(_ value: [UInt8], _ modulus: [UInt8]) -> [UInt8] {
        var result = value
        var borrow = 0
        for index in stride(from: result.count - 1, through: 0, by: -1) {
            let diff = Int(result[index]) - Int(modulus[index]) - borrow
            if diff < 0 {
                result[index] = UInt8(diff + 256)
                borrow = 1
            } else {
                result[index] = UInt8(diff)
                borrow = 0
            }
        }
        return result
    }

    private static func addOne(_ value: [UInt8]) -> [UInt8] {
        var result = value
        var carry = 1
        for index in stride(from: result.count - 1, through: 0, by: -1) {
            let sum = Int(result[index]) + carry
            result[index] = UInt8(sum & 0xff)
            carry = sum >> 8
            if carry == 0 { break }
        }
        return result
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
