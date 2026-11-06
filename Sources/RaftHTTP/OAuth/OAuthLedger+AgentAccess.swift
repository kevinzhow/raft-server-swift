import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    public struct AgentGrantRow: Sendable, Equatable {
        public var id: String
        public var clientRecordId: String
        public var scopes: [String]
        public var grantSource: String
        public var grantedByUserId: String?
    }

    public struct AgentAccessDecision: Sendable {
        public var status: String
        public var requestId: String
    }

    func agentGrantKey(_ agentId: String, _ clientRecordId: String) -> String {
        "\(agentId)\n\(clientRecordId)"
    }

    func isAgentAuthorityLocked(userId: String, agent: Agent, serverId: String) -> Bool {
        if agent.creatorUserId == userId { return true }
        let role = members["\(serverId)\n\(userId)"]
        return role == "owner" || role == "admin"
    }

    func activeAgentGrantLocked(agentId: String, clientRecordId: String) -> AgentGrant? {
        agentGrants.first {
            $0.agentId == agentId && $0.clientRecordId == clientRecordId && $0.revokedAt == nil
        }
    }

    func appUsableOnServerLocked(_ client: Client, serverId: String) -> Bool {
        (client.appType == "server_local" && client.serverId == serverId)
            || installations.contains {
                $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
            }
    }

    /// The decision of an approve or revoke the caller was allowed to try.
    public enum AgentAccessMutationOutcome: Sendable, Equatable {
        case done
        case forbidden
    }

    /// Approve a pending agent access request. The agent's creator or an
    /// owner/admin may approve; `remember` turns the request into a grant.
    /// `nil` means the request does not exist.
    public func approveAgentAccessRequest(userId: String, requestId: String, remember: Bool) -> AgentAccessMutationOutcome? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = requests.firstIndex(where: { $0.id == requestId }), let agentId = requests[index].agentId,
              let agent = agents[agentId], !agent.deleted,
              let client = clients.first(where: { $0.id == requests[index].clientId })
        else { return nil }
        guard isAgentAuthorityLocked(userId: userId, agent: agent, serverId: agent.serverId) else {
            return .forbidden
        }
        requests[index].status = "approved"
        if remember, activeAgentGrantLocked(agentId: agentId, clientRecordId: client.id) == nil {
            agentGrants.append(AgentGrant(
                id: UUID().uuidString.lowercased(), serverId: agent.serverId, agentId: agentId,
                clientRecordId: client.id, scopes: requests[index].scopes, grantSource: "person",
                grantedByUserId: userId, createdAt: Date()
            ))
        }
        autoGrantBlocked.remove(agentGrantKey(agentId, client.id))
        return .done
    }

    /// Revoke one grant. A person's revoke blocks automatic re-granting until a
    /// person grants again. `nil` means the grant does not exist or is already
    /// revoked.
    public func revokeAgentGrant(userId: String, grantId: String) -> AgentAccessMutationOutcome? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = agentGrants.firstIndex(where: { $0.id == grantId }), agentGrants[index].revokedAt == nil,
              let agent = agents[agentGrants[index].agentId]
        else { return nil }
        guard isAgentAuthorityLocked(userId: userId, agent: agent, serverId: agent.serverId) else {
            return .forbidden
        }
        agentGrants[index].revokedAt = Date()
        autoGrantBlocked.insert(agentGrantKey(agentGrants[index].agentId, agentGrants[index].clientRecordId))
        return .done
    }

    public struct AgentGrantCreateResult: Sendable {
        public var status: Int
        public var grantId: String
        public var created: Bool
    }

    /// A person grants an app access to an agent's behalf.
    public func createAgentGrant(
        userId: String, agentId: String, clientRecordId: String, scopes: [String]
    ) -> AgentGrantCreateResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let agent = agents[agentId], !agent.deleted else { return nil }
        guard isAgentAuthorityLocked(userId: userId, agent: agent, serverId: agent.serverId) else {
            return AgentGrantCreateResult(status: 403, grantId: "", created: false)
        }
        guard let client = clients.first(where: { $0.id == clientRecordId }), isUserManaged(client),
              client.enabled, appUsableOnServerLocked(client, serverId: agent.serverId)
        else { return AgentGrantCreateResult(status: 404, grantId: "", created: false) }
        let allowed = Set(client.allowedScopes ?? ["openid", "profile", "identity"])
        guard !scopes.isEmpty, Set(scopes).isSubset(of: allowed) else {
            return AgentGrantCreateResult(status: 400, grantId: "", created: false)
        }
        if let existing = activeAgentGrantLocked(agentId: agentId, clientRecordId: client.id) {
            autoGrantBlocked.remove(agentGrantKey(agentId, client.id))
            return AgentGrantCreateResult(status: 200, grantId: existing.id, created: false)
        }
        let grant = AgentGrant(
            id: UUID().uuidString.lowercased(), serverId: agent.serverId, agentId: agentId,
            clientRecordId: client.id, scopes: scopes, grantSource: "person",
            grantedByUserId: userId, createdAt: Date()
        )
        agentGrants.append(grant)
        autoGrantBlocked.remove(agentGrantKey(agentId, client.id))
        return AgentGrantCreateResult(status: 201, grantId: grant.id, created: true)
    }

    public struct GrantableApp: Sendable {
        public var recordId: String
        public var clientKey: String
        public var name: String
        public var scopes: [String]
    }

    public func grantableApps(userId: String, agentId: String) -> [GrantableApp]? {
        lock.lock()
        defer { lock.unlock() }
        guard let agent = agents[agentId], !agent.deleted else { return nil }
        guard isAgentAuthorityLocked(userId: userId, agent: agent, serverId: agent.serverId) else { return [] }
        return clients.filter { isUserManaged($0) && $0.enabled && appUsableOnServerLocked($0, serverId: agent.serverId) }
            .map {
                GrantableApp(
                    recordId: $0.id, clientKey: $0.clientId, name: $0.name,
                    scopes: $0.allowedScopes ?? ["openid", "profile", "identity"]
                )
            }
    }

    public func agentGrantListVisible(userId: String, agentId: String) -> [AgentGrantRow]? {
        lock.lock()
        defer { lock.unlock() }
        guard let agent = agents[agentId], !agent.deleted else { return nil }
        guard isAgentAuthorityLocked(userId: userId, agent: agent, serverId: agent.serverId) else { return [] }
        return agentGrants.filter { $0.agentId == agentId && $0.revokedAt == nil }.map {
            AgentGrantRow(id: $0.id, clientRecordId: $0.clientRecordId, scopes: $0.scopes,
                          grantSource: $0.grantSource, grantedByUserId: $0.grantedByUserId)
        }
    }

    /// `POST /api/oauth/requests/agent`. A server-local or installed App asks
    /// for an Agent; the owner behind the App may auto-grant.
    public func requestAgentAccess(authorization: String?, body: String) throws -> OAuthAgentAccessRequestResponse {
        let object = OAuthRequestBody.parse(body)
        var fields: [String: String] = [:]
        for key in ["client_id", "clientId", "client_secret", "clientSecret"] {
            if let value = object?.string(key) { fields[key] = value }
        }
        guard let credentials = OAuthRequestParsing.clientCredentials(authorization: authorization, fields: fields) else {
            throw OAuthLedgerError(.clientCredentialsRequired)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: {
            $0.clientId == credentials.clientId
                && isUserManaged($0)
                && ($0.appType != "third_party_global" || $0.enabled)
                && $0.secretHash == sha256(credentials.clientSecret)
        }) else {
            throw OAuthLedgerError(.invalidClientCredentials)
        }
        let serverSlug = (object?.string("serverSlug") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = servers.values.first(where: { $0.slug == serverSlug && !$0.deleted }) else {
            throw OAuthLedgerError(.serverNotFound)
        }
        let agent: Agent?
        if let rawId = object?.string("agentId"), !rawId.isEmpty {
            guard rawId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
                throw OAuthLedgerError(.agentNotFound)
            }
            agent = agents[rawId.lowercased()].flatMap { $0.serverId == server.id && !$0.deleted ? $0 : nil }
        } else {
            let agentName = (object?.string("agentName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            agent = agents.values.first(where: { $0.serverId == server.id && $0.name == agentName && !$0.deleted })
        }
        guard let agent else {
            throw OAuthLedgerError(.agentNotFound)
        }
        let installed = installations.contains(where: {
            $0.clientId == client.id && $0.serverId == server.id && $0.status == "active"
        })
        guard (client.appType == "server_local" && client.serverId == server.id) || installed else {
            throw OAuthLedgerError(.clientNotFoundForServer)
        }
        guard let scopes = normalizeScopes(object?.value("scopes"), allowed: client.allowedScopes ?? ["openid", "profile", "identity"], clientId: client.clientId) else {
            throw OAuthLedgerError(.invalidScopeBare)
        }
        let requestId = UUID().uuidString.lowercased()
        let existingGrant = activeAgentGrantLocked(agentId: agent.id, clientRecordId: client.id)
        let blocked = autoGrantBlocked.contains(agentGrantKey(agent.id, client.id))
        let initiatedByAgent = object?.bool("initiatedByAgent") == true
        let hasAuthority = isAgentAuthorityLocked(userId: client.createdByUserId, agent: agent, serverId: server.id)
        var status = "pending"
        if existingGrant != nil {
            status = "approved"
        } else if !blocked && (hasAuthority || initiatedByAgent) {
            let source = initiatedByAgent ? "agent_login" : "app_request"
            agentGrants.append(AgentGrant(
                id: UUID().uuidString.lowercased(), serverId: server.id, agentId: agent.id,
                clientRecordId: client.id, scopes: scopes, grantSource: source,
                grantedByUserId: initiatedByAgent ? nil : client.createdByUserId, createdAt: Date()
            ))
            status = "approved"
        }
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
            status: status,
            createdAt: Date()
        ))
        return OAuthAgentAccessRequestResponse(
            requestId: requestId,
            status: status,
            client: OAuthClientSummary(clientId: client.clientId, appType: client.appType, name: client.name),
            agentId: agent.id,
            agentName: agent.name,
            agentDisplayName: agent.displayName,
            serverId: server.id,
            serverSlug: server.slug,
            scopes: scopes
        )
    }
}
