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
    /// `POST /api/oauth/installation-token`. Client credentials mint a token for one active installation.
    public func mintInstallationToken(authorization: String?, body: String) throws -> OAuthInstallationTokenResponse {
        let noStore = "private, no-store"
        let fields = OAuthRequestParsing.tokenFields(body)
        guard let credentials = OAuthRequestParsing.clientCredentials(authorization: authorization, fields: fields) else {
            throw OAuthLedgerError(.clientCredentialsRequired, cacheControl: noStore)
        }
        let installationId = fields["installation_id"] ?? fields["installationId"] ?? ""
        guard !installationId.isEmpty else {
            throw OAuthLedgerError(.installationIdRequired, cacheControl: noStore)
        }
        return try self.state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: {
                $0.clientId == credentials.clientId && isUserManaged($0) && $0.enabled && $0.secretHash == sha256(credentials.clientSecret)
            }) else {
                throw OAuthLedgerError(.invalidClientCredentials, cacheControl: noStore)
            }
            guard let installation = ledgerState.installations.first(where: {
                $0.id == installationId && $0.clientId == client.id && $0.status == "active"
            }) else {
                throw OAuthLedgerError(.activeInstallationNotFound, cacheControl: noStore)
            }
            let groups = client.outboundGroups.filter { installation.approvedGroups.contains($0) }
            guard !groups.isEmpty else {
                throw OAuthLedgerError(.noEffectiveReadGroups, cacheControl: noStore)
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
            return OAuthInstallationTokenResponse(
                accessToken: accessToken,
                installationId: installation.id,
                serverId: installation.serverId,
                grantRevision: installation.grantRevision,
                groups: groups
            )
        }
    }
    /// `GET /api/app-installation/server`. A user session is not an App
    /// credential; only an active installation token resolves here.
    public func appInstallationServer(authorization: String?) throws -> OAuthAppInstallationServerResponse {
        let credential = try installationCredential(authorization)
        guard credential.groups.contains("server") else {
            throw OAuthLedgerError(.lacksServerReadAuthority, cacheControl: "private, no-store")
        }
        return try self.state.withLock { ledgerState in
            guard let server = ledgerState.servers[credential.serverId], !server.deleted else {
                throw OAuthLedgerError(.serverNotFound, cacheControl: "private, no-store")
            }
            return OAuthAppInstallationServerResponse(
                installationId: credential.installationId,
                serverId: server.id,
                name: server.name,
                slug: server.slug
            )
        }
    }

    /// `GET /api/app-installation/channels`. The `channel` group is separate
    /// from the `server` group an installation may have approved.
    public func appInstallationChannels(authorization: String?) throws -> OAuthAppInstallationChannelsResponse {
        let credential = try installationCredential(authorization)
        guard credential.groups.contains("channel") else {
            throw OAuthLedgerError(.lacksChannelReadAuthority, cacheControl: "private, no-store")
        }
        return OAuthAppInstallationChannelsResponse(installationId: credential.installationId)
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
    func installationCredential(_ authorization: String?) throws -> VerifiedInstallationCredential {
        guard let raw = OAuthRequestParsing.bearerToken(authorization) else {
            throw OAuthLedgerError(.installationBearerRequired)
        }
        return try self.state.withLock { ledgerState in
            guard let credential = installationCredentialLocked(raw, state: ledgerState) else {
                throw OAuthLedgerError(.invalidInstallationCredential)
            }
            return credential
        }
    }

    /// Reads the caller's borrowed State. Rechecks the live App class, installation status,
    /// grant revision, and that the token's groups are still granted.
    func installationCredentialLocked(_ raw: String, state ledgerState: State) -> VerifiedInstallationCredential? {
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
        return VerifiedInstallationCredential(
            installationId: installation.id,
            clientId: client.id,
            serverId: installation.serverId,
            groups: record.groups
        )
    }

    struct VerifiedInstallationCredential: Sendable {
        var installationId: String
        var clientId: String
        var serverId: String
        var groups: [String]
    }
}
