import Foundation
@testable import RaftHTTP

/// Test-only seams over the in-memory OAuth ledger (clients, installations,
/// tokens, authorization codes, agent grants and app events). They poke or read
/// back ledger state that has no HTTP-visible setter; production code never
/// calls them.
extension OAuthLedger {
    public func setClientAgentJWTEnabledForTesting(clientRecordId: String, enabled: Bool?) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].agentJwtEnabled = enabled
        }
        lock.unlock()
    }

    /// Conversion into a private share: the App keeps issuing for its source
    /// because conversion installs it there too.
    @discardableResult
    public func convertClientToPrivateShareForTesting(
        clientRecordId: String,
        installedByUserId: String
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = clients.firstIndex(where: { $0.id == clientRecordId }) else { return nil }
        clients[index].appType = "third_party_global"
        clients[index].humanMarketplaceVisible = false
        if !installations.contains(where: { $0.clientId == clientRecordId && $0.serverId == clients[index].serverId }) {
            installations.append(Installation(
                id: UUID().uuidString.lowercased(),
                serverId: clients[index].serverId,
                clientId: clientRecordId,
                installedByUserId: installedByUserId,
                approvedGroups: [],
                grantRevision: 0,
                status: "active"
            ))
        }
        return "raft_share_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func installSharedClientForTesting(
        clientRecordId: String,
        serverId: String,
        installedByUserId: String
    ) {
        lock.lock()
        if !installations.contains(where: { $0.clientId == clientRecordId && $0.serverId == serverId }) {
            installations.append(Installation(
                id: UUID().uuidString.lowercased(),
                serverId: serverId,
                clientId: clientRecordId,
                installedByUserId: installedByUserId,
                approvedGroups: [],
                grantRevision: 0,
                status: "active"
            ))
        }
        lock.unlock()
    }

    public func setInstallationStatusForTesting(clientRecordId: String, serverId: String, status: String) {
        lock.lock()
        if let index = installations.firstIndex(where: { $0.clientId == clientRecordId && $0.serverId == serverId }) {
            installations[index].status = status
        }
        lock.unlock()
    }

    public func removeInstallationForTesting(clientRecordId: String, serverId: String) {
        lock.lock()
        installations.removeAll { $0.clientId == clientRecordId && $0.serverId == serverId }
        lock.unlock()
    }

    public func markOfficialAppForTesting(clientRecordId: String) {
        lock.lock(); officialAppClientIds.insert(clientRecordId); lock.unlock()
    }

    public func setClientOutboundGroupsForTesting(clientRecordId: String, groups: [String]) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].outboundGroups = groups
        }
        lock.unlock()
    }

    /// Seeds a legacy-shaped secret hash so HTTP client authentication can be
    /// exercised without exposing the private client store.
    public func setClientSecretForTesting(clientRecordId: String, secret: String) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].secretHash = sha256(secret)
        }
        lock.unlock()
    }

    /// Drops a human authorization code so the token endpoint cannot redeem it.
    public func removeAuthorizationCodeForTesting(id: String) {
        lock.lock()
        requests.removeAll { $0.id == id }
        lock.unlock()
    }

    public func setClientPublishStatusForTesting(clientRecordId: String, status: String) {
        lock.lock()
        if let index = clients.firstIndex(where: { $0.id == clientRecordId }) {
            clients[index].publishStatus = status
        }
        lock.unlock()
    }

    public func removeInstallationsForTesting(clientRecordId: String) {
        lock.lock()
        installations.removeAll { $0.clientId == clientRecordId }
        lock.unlock()
    }

    public func installationGroupsForTesting(clientRecordId: String, serverId: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return installations.first {
            $0.clientId == clientRecordId && $0.serverId == serverId && $0.status == "active"
        }?.approvedGroups
    }

    public func seedRevokedOAuthAccessTokenForTesting(
        serverId: String,
        clientRecordId: String,
        userId: String,
        rawToken: String
    ) {
        lock.lock()
        tokens.append(AccessToken(
            serverId: serverId,
            userId: userId,
            clientId: clientRecordId,
            requestId: UUID().uuidString.lowercased(),
            tokenHash: sha256(rawToken),
            scopes: ["openid"],
            expiresAt: Date().addingTimeInterval(3600),
            revokedAt: Date()
        ))
        lock.unlock()
    }

    public func revokedOAuthTokenCountForTesting(clientRecordId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tokens.filter { $0.clientId == clientRecordId && $0.revokedAt != nil }.count
    }

    public func expireAccessTokensForTesting(clientRecordId: String) {
        lock.lock()
        for index in tokens.indices where tokens[index].clientId == clientRecordId {
            tokens[index].expiresAt = Date(timeIntervalSince1970: 0)
        }
        lock.unlock()
    }

    public func agentGrantRowsForTesting(agentId: String) -> [AgentGrantRow] {
        lock.lock()
        defer { lock.unlock() }
        return agentGrants.filter { $0.agentId == agentId && $0.revokedAt == nil }.map {
            AgentGrantRow(id: $0.id, clientRecordId: $0.clientRecordId, scopes: $0.scopes,
                          grantSource: $0.grantSource, grantedByUserId: $0.grantedByUserId)
        }
    }

    public func autoGrantBlockCountForTesting(agentId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return autoGrantBlocked.filter { $0.hasPrefix("\(agentId)\n") }.count
    }

    public func addThirdPartyAgentEventForTesting(
        id: String,
        serverId: String,
        agentId: String,
        clientRecordId: String,
        kind: String = "notification",
        summary: String,
        payloadJSON: String = "{}",
        expiresAt: Date,
        status: String = "delivered"
    ) {
        lock.lock()
        agentEvents.append(AgentEvent(
            id: id.lowercased(),
            serverId: serverId,
            agentId: agentId,
            clientId: clientRecordId,
            kind: kind,
            summary: summary,
            payloadHash: sha256(payloadJSON),
            payloadJSON: payloadJSON,
            externalEventId: nil,
            status: status,
            expiresAt: expiresAt,
            createdAt: Date()
        ))
        lock.unlock()
    }

    public func seedAgentAppEventForTesting(
        id: String, agentId: String, clientRecordId: String, summary: String,
        status: String, expiresAt: Date, createdAt: Date, payloadJSON: String = "{}",
        externalEventId: String? = nil
    ) {
        lock.lock()
        agentEvents.append(AgentEvent(
            id: id.lowercased(), serverId: agents[agentId]?.serverId ?? "",
            agentId: agentId, clientId: clientRecordId, kind: "notification",
            summary: summary, payloadHash: sha256(payloadJSON), payloadJSON: payloadJSON,
            externalEventId: externalEventId, status: status,
            expiresAt: expiresAt, createdAt: createdAt
        ))
        lock.unlock()
    }
}
