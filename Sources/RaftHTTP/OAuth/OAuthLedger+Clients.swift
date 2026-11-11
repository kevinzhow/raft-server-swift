import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    public func createClient(
        serverId: String,
        createdByUserId: String,
        name: String,
        clientId: String,
        appType: String = "server_local",
        description: String? = nil,
        homepageUrl: String? = nil,
        returnUrl: String? = nil,
        allowedScopes: [String]? = nil,
        agentManifestUrl: String? = nil,
        agentManifestUrlSource: String? = nil,
        setupUrl: String? = nil,
        setupDescription: String? = nil
    ) throws -> CreatedOAuthClient {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OAuthClientRejection(message: "name is required") }
        let normalized = clientId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.wholeMatch(of: /^[a-z][a-z0-9-]{2,63}$/) != nil else {
            throw OAuthClientRejection(message: "clientId must start with a letter and contain only lowercase letters, numbers, and hyphens")
        }
        if let returnUrl, !Self.isSafeReturnURL(returnUrl) {
            throw OAuthClientRejection(message: "returnUrl must be HTTPS (or loopback HTTP), without credentials or fragment")
        }
        let normalizedSetupUrl = try AppSetupContract.normalizeSetupUrl(setupUrl)
        let normalizedSetupDescription = try AppSetupContract.normalizeSetupDescription(setupDescription)
        var bytes = Data(count: 24)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let secret = "raft_secret_" + bytes.map { String(format: "%02x", $0) }.joined()
        let id = UUID().uuidString.lowercased()
        self.state.withLock { ledgerState in
            ledgerState.clients.append(Client(
                id: id,
                serverId: serverId,
                clientId: normalized,
                secretHash: sha256(secret),
                appType: appType,
                name: trimmed,
                createdByUserId: createdByUserId,
                descriptionText: description,
                homepageUrl: homepageUrl,
                returnUrl: returnUrl,
                allowedScopes: allowedScopes,
                agentManifestUrl: agentManifestUrl,
                agentManifestUrlSource: agentManifestUrlSource ?? (agentManifestUrl == nil ? nil : "explicit"),
                setupUrl: normalizedSetupUrl,
                setupDescription: normalizedSetupDescription
            ))
        }
        return CreatedOAuthClient(id: id, clientId: normalized, clientSecret: secret)
    }

    public func integrationServices(serverId: String) -> [IntegrationServiceRow] {
        return self.state.withLock { ledgerState in
            return ledgerState.clients.filter { client in
                client.appType != "slock_builtin" && client.enabled
                    && (client.serverId == serverId || ledgerState.installations.contains {
                        $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
                    })
            }.map { serviceRow($0, includeWhenToUse: true) }
        }
    }

    public func setClientWhenToUse(clientRecordId: String, whenToUse: String?) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].whenToUse = whenToUse
            }
        }
    }

    public func clientRecordId(serverId: String, clientKey: String) -> String? {
        return self.state.withLock { ledgerState in
            return ledgerState.clients.first {
                $0.serverId == serverId && ($0.clientId == clientKey || $0.id == clientKey)
            }?.id
        }
    }

    /// The live Marketplace row an install card must still bind to at
    /// execution time: same record id, enabled, published, human-visible.
    public func marketplaceInstallableClientIdentity(recordId: String) -> MarketplaceClientIdentity? {
        return self.state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: { $0.id == recordId }),
                  client.appType == "third_party_global",
                  client.enabled,
                  isUserManaged(client),
                  client.humanMarketplaceVisible,
                  client.publishStatus == "published" || client.publishStatus == "unpublish_requested"
            else { return nil }
            return MarketplaceClientIdentity(recordId: client.id, clientKey: client.clientId, name: client.name)
        }
    }

    /// The Marketplace-visible App `clientId` names (client key or record id).
    public func publicIntegrationClientIdentity(clientId: String) -> MarketplaceClientIdentity? {
        return self.state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: { candidate in
                (candidate.clientId == clientId || candidate.id == clientId) && isMarketplaceVisible(candidate)
            }) else { return nil }
            return MarketplaceClientIdentity(recordId: client.id, clientKey: client.clientId, name: client.name)
        }
    }

    public func isClientInstalled(serverId: String, clientRecordId: String) -> Bool {
        return self.state.withLock { ledgerState in
            return ledgerState.installations.contains {
                $0.clientId == clientRecordId && $0.serverId == serverId && $0.status == "active"
            }
        }
    }

    /// One client as an integration service row. `whenToUse` is only published
    /// for the installed-service listing, so callers pass whether to carry it.
    func serviceRow(_ client: Client, includeWhenToUse: Bool) -> IntegrationServiceRow {
        let manifest = manifestFields(client)
        return IntegrationServiceRow(
            id: client.id,
            clientId: client.clientId,
            name: client.name,
            description: client.descriptionText,
            homepageUrl: client.homepageUrl,
            agentManifestUrl: manifest.url,
            agentManifestUrlSource: manifest.source,
            allowedScopes: client.allowedScopes,
            whenToUse: includeWhenToUse ? client.whenToUse : nil,
            appType: client.appType
        )
    }

    /// The service an agent logs into on `serverId`: an enabled service of the
    /// Server (own or installed) first, then an installed one that is not the
    /// built-in tombstone class.
    public func integrationLoginServiceRow(serverId: String, clientId: String) -> IntegrationServiceRow? {
        return self.state.withLock { ledgerState in
            let installed: (Client) -> Bool = { [installations = ledgerState.installations] candidate in
                installations.contains {
                    $0.clientId == candidate.id && $0.serverId == serverId && $0.status == "active"
                }
            }
            if let client = ledgerState.clients.first(where: { client in
                client.appType != "slock_builtin" && client.enabled
                    && (client.serverId == serverId || installed(client))
                    && (client.clientId == clientId || client.id == clientId)
            }) {
                return serviceRow(client, includeWhenToUse: true)
            }
            guard let client = ledgerState.clients.first(where: { candidate in
                (candidate.clientId == clientId || candidate.id == clientId)
                    && candidate.appType != "slock_builtin"
                    && installed(candidate)
            }) else { return nil }
            return serviceRow(client, includeWhenToUse: false)
        }
    }

    /// The Marketplace-visible service `clientId` names, when no installed one
    /// does.
    public func publicIntegrationServiceRow(clientId: String) -> IntegrationServiceRow? {
        return self.state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: { candidate in
                (candidate.clientId == clientId || candidate.id == clientId) && isMarketplaceVisible(candidate)
            }) else { return nil }
            return serviceRow(client, includeWhenToUse: false)
        }
    }

    public func expireAuthorizationCode(id: String) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.requests.firstIndex(where: { $0.id == id }) {
                ledgerState.requests[index].createdAt = Date().addingTimeInterval(-(10 * 60 + 1))
            }
        }
    }
    /// live authorities, never copied onto a token row.
    public func setClientAppType(clientRecordId: String, appType: String) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].appType = appType
            }
        }
    }

    /// Reviewer transition used by the publish/moderation flow. Publishing or
    /// returning the App to private restores the owning Server's installation;
    /// the in-between requested states touch only the declaration.
    @discardableResult
    public func reviewClientPublish(clientRecordId: String, status: String) -> Bool {
        return self.state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) else { return false }
            ledgerState.clients[index].publishStatus = status
            if status == "published" {
                ledgerState.clients[index].humanMarketplaceVisible = true
            }
            guard status == "published" || status == "private" else { return true }
            let client = ledgerState.clients[index]
            let hasInstall = ledgerState.installations.contains {
                $0.clientId == client.id && $0.serverId == client.serverId && $0.status == "active"
            }
            if !hasInstall {
                ledgerState.installations.append(Installation(
                    id: UUID().uuidString.lowercased(),
                    serverId: client.serverId,
                    clientId: client.id,
                    installedByUserId: client.createdByUserId,
                    approvedGroups: [],
                    grantRevision: 1,
                    status: "active"
                ))
            }
            return true
        }
    }

    /// Settings list: every App this Server owns or has installed. A published
    /// marketplace App without a local installation is not listed.
    public func integrationSettingsClientRows(serverId: String) -> [IntegrationSettingsClient] {
        return self.state.withLock { ledgerState in
            return ledgerState.clients.filter { client in
                guard client.enabled, isUserManaged(client) else { return false }
                if client.serverId == serverId { return true }
                return ledgerState.installations.contains {
                    $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
                }
            }.map { client in
                IntegrationSettingsClient(
                    id: client.id,
                    clientId: client.clientId,
                    name: client.name,
                    appType: client.appType,
                    description: client.descriptionText,
                    homepageUrl: client.homepageUrl,
                    publishStatus: client.publishStatus,
                    logoUrl: client.logoUrl
                )
            }
        }
    }

    public func publishClient(clientRecordId: String, humanMarketplaceVisible: Bool = true) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].publishStatus = "published"
                ledgerState.clients[index].humanMarketplaceVisible = humanMarketplaceVisible
            }
        }
    }

    public struct AppPermissionReviewRow: Sendable {
        public var id: String
        public var clientId: String
        public var name: String
        public var pendingGroups: [String]
        public var pendingRevisionId: String?
    }

    public enum AppPermissionReviewError: Error, Sendable {
        case notFound
        case stale
    }

    public func appPermissionReviewRows(serverId: String) -> [AppPermissionReviewRow] {
        return self.state.withLock { ledgerState in
            return ledgerState.clients
                .filter {
                    $0.serverId == serverId
                        && $0.appType == "third_party_global"
                        && $0.publishStatus == "published"
                        && $0.enabled
                }
                .map {
                    AppPermissionReviewRow(
                        id: $0.id,
                        clientId: $0.clientId,
                        name: $0.name,
                        pendingGroups: $0.pendingOutboundGroups,
                        pendingRevisionId: $0.pendingOutboundRevisionId
                    )
                }
        }
    }

    @discardableResult
    public func createAppOutboundPermissionRevision(clientRecordId: String, groups: [String]) -> String? {
        return self.state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) else { return nil }
            let revisionId = UUID().uuidString.lowercased()
            ledgerState.clients[index].pendingOutboundRevisionId = revisionId
            ledgerState.clients[index].pendingOutboundGroups = groups
            return revisionId
        }
    }

    public func approveAppOutboundPermission(clientRecordId: String, expectedRevisionId: String) throws -> [String] {
        return try self.state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) else {
                throw AppPermissionReviewError.notFound
            }
            guard ledgerState.clients[index].pendingOutboundRevisionId == expectedRevisionId else {
                throw AppPermissionReviewError.stale
            }
            let groups = ledgerState.clients[index].pendingOutboundGroups
            ledgerState.clients[index].outboundGroups = groups
            ledgerState.clients[index].pendingOutboundRevisionId = nil
            ledgerState.clients[index].pendingOutboundGroups = []
            return groups
        }
    }

    public func registerExternalApp(clientRecordId: String, provider: String, state: String) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].externalProvider = provider
                ledgerState.clients[index].externalState = state
            }
        }
    }

    public func installationTokenCount(clientRecordId: String) -> Int {
        return self.state.withLock { ledgerState in
            return ledgerState.installationTokens.filter { $0.clientId == clientRecordId }.count
        }
    }

    public func setInstallationStatus(id: String, status: String) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.installations.firstIndex(where: { $0.id == id }) {
                ledgerState.installations[index].status = status
            }
        }
    }

    public func setClientEnabled(clientRecordId: String, enabled: Bool) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].enabled = enabled
            }
        }
    }

    public func setClientAllowedScopes(clientRecordId: String, scopes: [String]?) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].allowedScopes = scopes
            }
        }
    }

    /// `updateOAuthClient`'s return-URL guard: an existing client cannot be
    /// moved to a script or data URL either.
    public func updateClientReturnUrl(clientRecordId: String, returnUrl: String?) throws {
        if let returnUrl, !Self.isSafeReturnURL(returnUrl) {
            throw OAuthClientRejection(message: "returnUrl must be HTTPS (or loopback HTTP), without credentials or fragment")
        }
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].returnUrl = returnUrl
            }
        }
    }

    public func setClientReturnUrl(clientRecordId: String, returnUrl: String?) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) {
                ledgerState.clients[index].returnUrl = returnUrl
            }
        }
    }

    public func revokeAccessTokens(clientRecordId: String) {
        self.state.withLock { ledgerState in
            for index in ledgerState.tokens.indices where ledgerState.tokens[index].clientId == clientRecordId {
                ledgerState.tokens[index].revokedAt = Date()
            }
        }
    }

    public func revokeAgentGrants(clientRecordId: String) {
        _ = self.state.withLock { ledgerState in
            ledgerState.revokedGrantClients.insert(clientRecordId)
        }
    }

    public func accessTokenCount(requestId: String) -> Int {
        return self.state.withLock { ledgerState in
            return ledgerState.tokens.filter { $0.requestId == requestId }.count
        }
    }
    /// An App that declares no manifest still points agents at its own
    /// well-known document, derived from the homepage origin.
    static func wellKnownAgentManifestUrl(homepageUrl: String?) -> String? {
        guard let homepageUrl,
              let components = URLComponents(string: homepageUrl),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        return "https://\(host)/.well-known/raft-agent-manifest.json"
    }

    func manifestFields(_ client: Client) -> (url: String?, source: String?) {
        if let url = client.agentManifestUrl, !url.isEmpty {
            return (url, client.agentManifestUrlSource ?? "explicit")
        }
        if let derived = Self.wellKnownAgentManifestUrl(homepageUrl: client.homepageUrl) {
            return (derived, "well_known")
        }
        return (nil, nil)
    }

    /// Mirrors `oauthClientIsUserManagedPredicate`: the tombstone class and
    /// any platform registration both remove installation authority.
    func isUserManaged(_ client: Client) -> Bool {
        client.appType != "slock_builtin" && client.externalProvider == nil
    }

    static func isSafeReturnURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else { return false }
        if scheme == "https" { return true }
        if scheme == "http" {
            return ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        }
        return false
    }

    func isMarketplaceVisible(_ client: Client) -> Bool {
        client.appType == "third_party_global"
            && client.enabled
            && client.publishStatus == "published"
            && client.humanMarketplaceVisible
    }

    public func marketplaceClients(serverId: String, query: String?) -> [MarketplaceClientRow] {
        return self.state.withLock { ledgerState in
            let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ledgerState.clients.filter { client in
                guard isMarketplaceVisible(client) else { return false }
                guard !needle.isEmpty else { return true }
                return client.name.lowercased().contains(needle)
                    || (client.descriptionText ?? "").lowercased().contains(needle)
                    || client.clientId.lowercased().contains(needle)
            }.map { client in
                MarketplaceClientRow(
                    id: client.id,
                    clientId: client.clientId,
                    name: client.name,
                    description: client.descriptionText,
                    homepageUrl: client.homepageUrl,
                    allowedScopes: client.allowedScopes ?? ["openid", "profile", "identity"],
                    installedOnServer: ledgerState.installations.contains {
                        $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
                    }
                )
            }
        }
    }
}
