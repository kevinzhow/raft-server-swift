import Foundation
@testable import RaftHTTP

/// Test-only seams over the in-memory OAuth ledger (clients, installations,
/// tokens, authorization codes, agent grants and app events). They poke or read
/// back ledger state that has no HTTP-visible setter; production code never
/// calls them.
extension OAuthLedger {
    public func setClientAgentJWTEnabledForTesting(clientRecordId: String, enabled: Bool?) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].agentJwtEnabled = enabled
            }
        }
    }

    /// Conversion into a private share: the App keeps issuing for its source
    /// because conversion installs it there too.
    @discardableResult
    public func convertClientToPrivateShareForTesting(
        clientRecordId: String,
        installedByUserId: String
    ) -> String? {
        return self.state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) else { return nil }
            ledgerState.clients[index].appType = "third_party_global"
            ledgerState.clients[index].humanMarketplaceVisible = false
            if !ledgerState.installations.contains(where: { $0.clientId == clientRecordId && $0.serverId == ledgerState.clients[index].serverId }) {
                ledgerState.installations.append(Installation(
                    id: UUID().uuidString.lowercased(),
                    serverId: ledgerState.clients[index].serverId,
                    clientId: clientRecordId,
                    installedByUserId: installedByUserId,
                    approvedGroups: [],
                    grantRevision: 0,
                    status: "active"
                ))
            }
            return "raft_share_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    }

    public func installSharedClientForTesting(
        clientRecordId: String,
        serverId: String,
        installedByUserId: String
    ) {
        self.state.withLock { ledgerState in
            if !ledgerState.installations.contains(where: { $0.clientId == clientRecordId && $0.serverId == serverId }) {
                ledgerState.installations.append(Installation(
                    id: UUID().uuidString.lowercased(),
                    serverId: serverId,
                    clientId: clientRecordId,
                    installedByUserId: installedByUserId,
                    approvedGroups: [],
                    grantRevision: 0,
                    status: "active"
                ))
            }
        }
    }

    public func setInstallationStatusForTesting(clientRecordId: String, serverId: String, status: String) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.installations.firstIndex(where: { $0.clientId == clientRecordId && $0.serverId == serverId }) {
                ledgerState.installations[index].status = status
            }
        }
    }

    public func removeInstallationForTesting(clientRecordId: String, serverId: String) {
        self.state.withLock { ledgerState in
            ledgerState.installations.removeAll { $0.clientId == clientRecordId && $0.serverId == serverId }
        }
    }

    public func markOfficialAppForTesting(clientRecordId: String) {
        _ = self.state.withLock { ledgerState in
            ledgerState.officialAppClientIds.insert(clientRecordId)
        }
    }

    public func setClientOutboundGroupsForTesting(clientRecordId: String, groups: [String]) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].outboundGroups = groups
            }
        }
    }

    /// Seeds a legacy-shaped secret hash so HTTP client authentication can be
    /// exercised without exposing the private client store.
    public func setClientSecretForTesting(clientRecordId: String, secret: String) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].secretHash = sha256(secret)
            }
        }
    }

    /// Drops a human authorization code so the token endpoint cannot redeem it.
    public func removeAuthorizationCodeForTesting(id: String) {
        self.state.withLock { ledgerState in
            ledgerState.requests.removeAll { $0.id == id }
        }
    }

    public func setClientPublishStatusForTesting(clientRecordId: String, status: String) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].publishStatus = status
            }
        }
    }

    public func removeInstallationsForTesting(clientRecordId: String) {
        self.state.withLock { ledgerState in
            ledgerState.installations.removeAll { $0.clientId == clientRecordId }
        }
    }

    public func installationGroupsForTesting(clientRecordId: String, serverId: String) -> [String]? {
        return self.state.withLock { ledgerState in
            return ledgerState.installations.first {
                $0.clientId == clientRecordId && $0.serverId == serverId && $0.status == "active"
            }?.approvedGroups
        }
    }

    public func seedRevokedOAuthAccessTokenForTesting(
        serverId: String,
        clientRecordId: String,
        userId: String,
        rawToken: String
    ) {
        self.state.withLock { ledgerState in
            ledgerState.tokens.append(AccessToken(
                serverId: serverId,
                userId: userId,
                clientId: clientRecordId,
                requestId: UUID().uuidString.lowercased(),
                tokenHash: sha256(rawToken),
                scopes: ["openid"],
                expiresAt: Date().addingTimeInterval(3600),
                revokedAt: Date()
            ))
        }
    }

    public func revokedOAuthTokenCountForTesting(clientRecordId: String) -> Int {
        return self.state.withLock { ledgerState in
            return ledgerState.tokens.filter { $0.clientId == clientRecordId && $0.revokedAt != nil }.count
        }
    }

    public func expireAccessTokensForTesting(clientRecordId: String) {
        self.state.withLock { ledgerState in
            for index in ledgerState.tokens.indices where ledgerState.tokens[index].clientId == clientRecordId {
                ledgerState.tokens[index].expiresAt = Date(timeIntervalSince1970: 0)
            }
        }
    }

    public func agentGrantRowsForTesting(agentId: String) -> [AgentGrantRow] {
        return self.state.withLock { ledgerState in
            return ledgerState.agentGrants.filter { $0.agentId == agentId && $0.revokedAt == nil }.map {
                AgentGrantRow(id: $0.id, clientRecordId: $0.clientRecordId, scopes: $0.scopes,
                              grantSource: $0.grantSource, grantedByUserId: $0.grantedByUserId)
            }
        }
    }

    public func autoGrantBlockCountForTesting(agentId: String) -> Int {
        return self.state.withLock { ledgerState in
            return ledgerState.autoGrantBlocked.filter { $0.hasPrefix("\(agentId)\n") }.count
        }
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
        self.state.withLock { ledgerState in
            ledgerState.agentEvents.append(AgentEvent(
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
        }
    }

    public func seedAgentAppEventForTesting(
        id: String, agentId: String, clientRecordId: String, summary: String,
        status: String, expiresAt: Date, createdAt: Date, payloadJSON: String = "{}",
        externalEventId: String? = nil
    ) {
        self.state.withLock { ledgerState in
            ledgerState.agentEvents.append(AgentEvent(
                id: id.lowercased(), serverId: ledgerState.agents[agentId]?.serverId ?? "",
                agentId: agentId, clientId: clientRecordId, kind: "notification",
                summary: summary, payloadHash: sha256(payloadJSON), payloadJSON: payloadJSON,
                externalEventId: externalEventId, status: status,
                expiresAt: expiresAt, createdAt: createdAt
            ))
        }
    }
}
