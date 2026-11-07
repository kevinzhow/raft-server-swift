import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    public func appInstallationAccess(authorization: String?) -> (serverId: String, clientId: String, groups: [String], official: Bool)? {
        return self.state.withLock { ledgerState in
            guard let raw = OAuthRequestParsing.bearerToken(authorization), let credential = installationCredentialLocked(raw, state: ledgerState) else { return nil }
            let official = ledgerState.officialAppClientIds.contains(credential.clientId)
            return (credential.serverId, credential.clientId, credential.groups, official)
        }
    }
    /// Records an active installation whose approved groups are also the App's current outbound groups.
    public func installClient(serverId: String, clientRecordId: String, installedByUserId: String, groups: [String]) -> String {
        let id = UUID().uuidString.lowercased()
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].outboundGroups = groups
            }
            ledgerState.installations.append(Installation(
                id: id,
                serverId: serverId,
                clientId: clientRecordId,
                installedByUserId: installedByUserId,
                approvedGroups: groups,
                grantRevision: 1,
                status: "active"
            ))
        }
        return id
    }
    /// Checks live App and installation eligibility, captures the effective
    /// groups/revision, and appends exactly one token in the same transaction.
    func mintInstallationCredential(_ attempt: InstallationMintAttempt) -> InstallationMintOutcome {
        return self.state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: {
                $0.clientId == attempt.clientId && isUserManaged($0) && $0.enabled && $0.secretHash == sha256(attempt.clientSecret)
            }) else {
                return .invalidClient
            }
            guard let installation = ledgerState.installations.first(where: {
                $0.id == attempt.installationId && $0.clientId == client.id && $0.status == "active"
            }) else {
                return .installationUnavailable
            }
            let groups = client.outboundGroups.filter { installation.approvedGroups.contains($0) }
            guard !groups.isEmpty else {
                return .noEffectiveGroups
            }
            var raw = Data(count: 32)
            for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
            let accessToken = "raft_installation_" + base64url(raw)
            ledgerState.installationTokens.append(InstallationToken(
                tokenHash: sha256(accessToken),
                installationId: installation.id,
                clientId: client.id,
                serverId: installation.serverId,
                grantRevision: installation.grantRevision,
                groups: groups,
                audience: "raft:app-installation-api",
                expiresAt: Date().addingTimeInterval(10 * 60)
            ))
            return .issued(InstallationMintReceipt(
                accessToken: accessToken,
                installationId: installation.id,
                serverId: installation.serverId,
                grantRevision: installation.grantRevision,
                groups: groups
            ))
        }
    }

    /// Intentionally a separate read after credential verification and the
    /// service's group check, retaining the original two-lock server projection.
    func liveInstallationServer(id: String) -> InstallationServerFacts? {
        self.state.withLock { ledgerState in
            guard let server = ledgerState.servers[id], !server.deleted else { return nil }
            return InstallationServerFacts(id: server.id, name: server.name, slug: server.slug)
        }
    }

    /// What `POST /api/oauth/installations/lookup` decided. The refusals keep
    /// the legacy order: credentials, client, Server id, then the installation.
    public enum InstallationLookupOutcome: Sendable, Equatable {
        case credentialsRequired
        case invalidCredentials
        case serverIdRequired
        case serverIdInvalid
        case notFound
        case found(installationId: String, serverId: String)
    }

    /// `POST /api/oauth/installations/lookup`. The authenticated client is the
    /// App boundary; a miss never discloses another App's installation.
    public func lookupInstallation(
        authorization: String?,
        clientId bodyClientId: String?,
        clientSecret bodyClientSecret: String?,
        serverId rawServerId: String?
    ) -> InstallationLookupOutcome {
        var fields: [String: String] = [:]
        if let bodyClientId { fields["client_id"] = bodyClientId }
        if let bodyClientSecret { fields["client_secret"] = bodyClientSecret }
        guard let credentials = OAuthRequestParsing.clientCredentials(authorization: authorization, fields: fields) else {
            return .credentialsRequired
        }
        return self.state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: {
                $0.clientId == credentials.clientId
                    && isUserManaged($0)
                    && ($0.appType != "third_party_global" || $0.enabled)
                    && $0.secretHash == sha256(credentials.clientSecret)
            }) else {
                return .invalidCredentials
            }
            let serverId = (rawServerId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serverId.isEmpty else {
                return .serverIdRequired
            }
            guard serverId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
                return .serverIdInvalid
            }
            guard client.enabled else {
                return .notFound
            }
            guard let installation = ledgerState.installations.first(where: {
                $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
            }) else {
                return .notFound
            }
            return .found(installationId: installation.id, serverId: installation.serverId)
        }
    }
    func verifiedInstallationCredential(rawToken: String) -> InstallationCredentialFacts? {
        self.state.withLock { ledgerState in
            installationCredentialLocked(rawToken, state: ledgerState)
        }
    }

    /// Reads the caller's borrowed State. Rechecks the live App class, installation status,
    /// grant revision, and that the token's groups are still granted.
    func installationCredentialLocked(_ raw: String, state ledgerState: State) -> InstallationCredentialFacts? {
        guard raw.hasPrefix("raft_installation_") else { return nil }
        guard let record = ledgerState.installationTokens.last(where: { $0.tokenHash == sha256(raw) }),
              record.expiresAt > Date(),
              record.audience == "raft:app-installation-api"
        else {
            return nil
        }
        guard let installation = ledgerState.installations.first(where: { $0.id == record.installationId }),
              installation.status == "active",
              installation.clientId == record.clientId,
              installation.serverId == record.serverId,
              installation.grantRevision == record.grantRevision
        else {
            return nil
        }
        guard let client = ledgerState.clients.first(where: { $0.id == record.clientId }),
              isUserManaged(client),
              client.enabled
        else {
            return nil
        }
        let currentGroups = client.outboundGroups.filter { installation.approvedGroups.contains($0) }
        guard record.groups.allSatisfy({ currentGroups.contains($0) }) else { return nil }
        return InstallationCredentialFacts(
            installationId: installation.id,
            clientId: client.id,
            serverId: installation.serverId,
            groups: record.groups
        )
    }
}
