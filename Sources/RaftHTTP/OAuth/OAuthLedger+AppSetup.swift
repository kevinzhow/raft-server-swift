import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    public struct AppSetupConflictError: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Update the App-owned setup declaration. A changed setup URL is a new
    /// declaration revision and invalidates completions of earlier revisions;
    /// a wording-only change does not require configuration again.
    @discardableResult
    public func updateClientSetupDeclaration(
        clientRecordId: String, setupUrl: String?, setupDescription: String?
    ) throws -> Bool {
        let normalizedUrl = try AppSetupContract.normalizeSetupUrl(setupUrl)
        let normalizedDescription = try AppSetupContract.normalizeSetupDescription(setupDescription)
        lock.lock()
        defer { lock.unlock() }
        guard let index = clients.firstIndex(where: { $0.id == clientRecordId }) else { return false }
        let urlChanged = clients[index].setupUrl != normalizedUrl
        clients[index].setupUrl = normalizedUrl
        clients[index].setupDescription = normalizedDescription
        guard urlChanged else { return true }
        clients[index].setupRevision += 1
        for installationIndex in installations.indices where installations[installationIndex].clientId == clientRecordId {
            installations[installationIndex].setupCompletedRevision = nil
            installations[installationIndex].setupCompletedAt = nil
        }
        return true
    }

    /// The setup state of one server's active installation. Callers establish
    /// human Server access (or App authentication) first.
    public func getAppInstallationSetup(clientRecordId: String, serverId: String) -> AppSetupState? {
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: { $0.id == clientRecordId && $0.enabled }) else { return nil }
        guard let installation = installations.first(where: {
            $0.clientId == clientRecordId && $0.serverId == serverId && $0.status == "active"
        }) else { return nil }
        return try? AppSetupContract.project(
            setupUrl: client.setupUrl,
            setupDescription: client.setupDescription,
            setupRevision: client.setupRevision,
            installationId: installation.id,
            serverId: installation.serverId,
            completedRevision: installation.setupCompletedRevision,
            completedAt: installation.setupCompletedAt
        )
    }

    /// App-authenticated, revision-bound and idempotent; never a permissions
    /// grant. Returns nil when the client/installation is not usable.
    public func updateAppInstallationSetup(
        clientRecordId: String, installationId: String, revision: Int, status: String
    ) throws -> AppSetupState? {
        guard status == "pending" || status == "complete" else {
            throw OAuthClientRejection(message: "status must be pending or complete")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let clientIndex = clients.firstIndex(where: { $0.id == clientRecordId && $0.enabled }) else { return nil }
        guard let installationIndex = installations.firstIndex(where: {
            $0.id == installationId && $0.clientId == clientRecordId && $0.status == "active"
        }) else { return nil }
        let client = clients[clientIndex]
        guard let setupUrl = client.setupUrl, !setupUrl.isEmpty, revision == client.setupRevision else {
            throw AppSetupConflictError("Setup declaration changed; read current setup state before reporting completion")
        }
        let complete = status == "complete"
        let desiredRevision: Int? = complete ? client.setupRevision : nil
        if installations[installationIndex].setupCompletedRevision != desiredRevision {
            installations[installationIndex].setupCompletedRevision = desiredRevision
            installations[installationIndex].setupCompletedAt = complete ? Date() : nil
            integrationAuditEvents.append(IntegrationAuditEvent(
                eventType: "installation.setup_updated", clientRecordId: client.id,
                installationId: installationId, serverId: installations[installationIndex].serverId
            ))
        }
        let installation = installations[installationIndex]
        return try? AppSetupContract.project(
            setupUrl: client.setupUrl,
            setupDescription: client.setupDescription,
            setupRevision: client.setupRevision,
            installationId: installation.id,
            serverId: installation.serverId,
            completedRevision: installation.setupCompletedRevision,
            completedAt: installation.setupCompletedAt
        )
    }

    /// Marketplace uninstall: drops the active installation; a later install
    /// creates a new installation id and therefore a fresh setup state.
    @discardableResult
    public func uninstallClient(serverId: String, clientRecordId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = installations.count
        installations.removeAll {
            $0.clientId == clientRecordId && $0.serverId == serverId && $0.status == "active"
        }
        return installations.count != before
    }

    /// App backend authentication for the setup report: the owning App's
    /// client id + secret, enabled and user-managed.
    public func verifyClientSecret(clientKey: String, clientSecret: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return clients.first {
            ($0.clientId == clientKey || $0.id == clientKey) && $0.enabled
                && $0.appType != "slock_builtin" && $0.secretHash == sha256(clientSecret)
        }?.id
    }
    /// Resolves an App by client key or record id for a target Server, whether
    /// the App is owned by that Server or installed on it from a publisher.
    public func setupClientRecordId(serverId: String, clientKey: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return clients.first { client in
            (client.clientId == clientKey || client.id == clientKey)
                && (client.serverId == serverId || installations.contains {
                    $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
                })
        }?.id
    }

    public func clientRecordIdForServer(serverId: String, clientKey: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return clients.first {
            $0.serverId == serverId && ($0.clientId == clientKey || $0.id == clientKey)
        }?.id
    }

    public func integrationAuditEventCount(eventType: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return integrationAuditEvents.filter { $0.eventType == eventType }.count
    }

    public func clientSetupDeclaration(clientRecordId: String) -> (url: String?, description: String?, revision: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: { $0.id == clientRecordId }) else { return nil }
        return (client.setupUrl, client.setupDescription, client.setupRevision)
    }

    public func addClientMaintainer(clientRecordId: String, agentId: String, role: String = "owner") {
        guard role == "owner" else { return }
        lock.lock()
        clientMaintainerOwners[clientRecordId, default: []].insert(agentId)
        lock.unlock()
    }

    public func isClientMaintainerOwner(clientRecordId: String, agentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return clientMaintainerOwners[clientRecordId]?.contains(agentId) == true
    }

    public func installationId(serverId: String, clientRecordId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return installations.first {
            $0.clientId == clientRecordId && $0.serverId == serverId && $0.status == "active"
        }?.id
    }

    /// The agent-facing projection of Apps this agent may manage: every
    /// user-managed app of the Server for an admin agent, otherwise only the
    /// ones this agent owns. Installation ids never cross the Server boundary.
    public func ownedIntegrationApps(serverId: String, agentId: String, admin: Bool) -> [IntegrationAppProjection] {
        lock.lock()
        defer { lock.unlock() }
        return clients.filter { client in
            guard client.serverId == serverId, isUserManaged(client),
                  client.appType == "server_local" || client.appType == "third_party_global"
            else { return false }
            return admin || clientMaintainerOwners[client.id]?.contains(agentId) == true
        }.map { client in
            integrationAppProjection(client, serverId: serverId, admin: admin)
        }
    }

    public func ownedIntegrationApp(serverId: String, agentId: String, clientKey: String, admin: Bool) -> IntegrationAppProjection? {
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: { candidate in
            candidate.serverId == serverId
                && (candidate.clientId == clientKey || candidate.id == clientKey)
                && isUserManaged(candidate)
                && (candidate.appType == "server_local" || candidate.appType == "third_party_global")
        }) else { return nil }
        guard admin || clientMaintainerOwners[client.id]?.contains(agentId) == true else { return nil }
        return integrationAppProjection(client, serverId: serverId, admin: admin)
    }

    func setupProjection(client: Client, serverId: String) -> IntegrationAppSetupProjection? {
        guard let installation = installations.first(where: {
            $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
        }) else { return nil }
        guard let state = try? AppSetupContract.project(
            setupUrl: client.setupUrl, setupDescription: client.setupDescription,
            setupRevision: client.setupRevision, installationId: installation.id,
            serverId: installation.serverId,
            completedRevision: installation.setupCompletedRevision,
            completedAt: installation.setupCompletedAt
        ) else { return nil }
        return IntegrationAppSetupProjection(
            status: state.status.rawValue,
            url: state.url,
            description: state.description,
            revision: state.revision,
            completedAt: state.completedAt
        )
    }

    func integrationAppProjection(_ client: Client, serverId: String, admin: Bool) -> IntegrationAppProjection {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = formatter.string(from: Date())
        return IntegrationAppProjection(
            installationId: installations.first {
                $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
            }?.id,
            name: client.name,
            clientKey: client.clientId,
            createdAt: now,
            updatedAt: now,
            description: client.descriptionText,
            homepageUrl: client.homepageUrl,
            callbackUrl: client.returnUrl,
            agentManifestUrl: client.agentManifestUrl,
            setupUrl: client.setupUrl,
            setupDescription: client.setupDescription,
            setupRevision: client.setupRevision,
            setup: setupProjection(client: client, serverId: serverId),
            scopes: client.allowedScopes ?? [],
            appType: client.appType,
            publishStatus: client.publishStatus,
            enabled: client.enabled,
            authority: admin ? "admin" : "owner",
            recoveryCommand: "raft integration app rotate-secret --client \(client.clientId) --output <new-private-path>"
        )
    }
}
