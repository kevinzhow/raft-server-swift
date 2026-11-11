import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    // MARK: - Client lookup

    func userManagedClient(recordId: String) -> Client? {
        state.withLock { ledgerState in
            ledgerState.clients.first { $0.id == recordId && isUserManaged($0) }
        }
    }

    func sourceOwnedClient(serverId: String, recordId: String) -> Client? {
        state.withLock { ledgerState in
            ledgerState.clients.first {
                $0.id == recordId && $0.serverId == serverId && isUserManaged($0)
                    && ($0.appType == "server_local" || $0.appType == "third_party_global")
            }
        }
    }

    func managedClientRows(serverId: String) -> [Client] {
        state.withLock { ledgerState in
            ledgerState.clients.filter { client in
                guard client.enabled, isUserManaged(client) else { return false }
                if client.serverId == serverId { return true }
                return ledgerState.installations.contains {
                    $0.clientId == client.id && $0.serverId == serverId && $0.status == "active"
                }
            }
        }
    }

    var hasOfficialApp: Bool {
        state.withLock { !$0.officialAppClientIds.isEmpty }
    }

    func replaceClientLogo(_ client: Client) {
        state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: { $0.id == client.id }) else { return }
            ledgerState.clients[index].logoUrl = client.logoUrl
            ledgerState.clients[index].logoStorageKey = client.logoStorageKey
            ledgerState.clients[index].updatedAt = client.updatedAt
        }
    }

    func shareLinkActive(serverId: String, recordId: String) -> ClientShareLink? {
        state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: {
                $0.id == recordId && $0.serverId == serverId && isUserManaged($0)
            }) else { return nil }
            return ledgerState.clientShareLinks
                .filter { $0.clientRecordId == client.id && $0.revokedAt == nil }
                .sorted { $0.createdAt > $1.createdAt }
                .first
        }
    }

    // MARK: - Create / delete / secret

    func createManagedClient(
        serverId: String,
        createdByUserId: String,
        name: String,
        description: String?,
        whenToUse: String?,
        homepageUrl: String?,
        returnUrl: String?,
        agentManifestUrl: String?,
        setupUrl: String?,
        setupDescription: String?,
        clientKey: String?,
        allowedScopes: [String]?,
        category: String
    ) throws -> (client: Client, secret: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OAuthClientRejection(message: "name is required") }
        let normalizedKey: String
        if let clientKey, !clientKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let value = clientKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard value.wholeMatch(of: /^[a-z][a-z0-9-]{2,63}$/) != nil else {
                throw OAuthClientRejection(message: "clientId must start with a letter and contain only lowercase letters, numbers, and hyphens")
            }
            normalizedKey = value
        } else {
            let base = trimmed.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let slug = base.isEmpty ? "client" : String(base.prefix(40))
            normalizedKey = "\(slug)-\(Self.randomHex(3))"
        }
        if let returnUrl, !returnUrl.isEmpty, !Self.isSafeReturnURL(returnUrl) {
            throw OAuthClientRejection(message: "returnUrl must be HTTPS (or loopback HTTP), without credentials or fragment")
        }
        if let agentManifestUrl, !agentManifestUrl.isEmpty {
            guard let components = URLComponents(string: agentManifestUrl),
                  components.scheme?.lowercased() == "https",
                  components.host != nil,
                  components.user == nil, components.password == nil
            else {
                throw OAuthClientRejection(message: "agentManifestUrl must be an HTTPS URL")
            }
        }
        let normalizedSetupUrl = try AppSetupContract.normalizeSetupUrl(setupUrl)
        let normalizedSetupDescription = try AppSetupContract.normalizeSetupDescription(setupDescription)
        let secret = "raft_secret_" + Self.randomHex(24)
        let id = UUID().uuidString.lowercased()
        let now = Date()
        let client = Client(
            id: id,
            serverId: serverId,
            clientId: normalizedKey,
            secretHash: sha256(secret),
            appType: "server_local",
            name: trimmed,
            createdByUserId: createdByUserId,
            descriptionText: description,
            homepageUrl: homepageUrl,
            returnUrl: returnUrl,
            allowedScopes: allowedScopes,
            publishStatus: "private",
            agentManifestUrl: agentManifestUrl,
            agentManifestUrlSource: agentManifestUrl.map { _ in "explicit" },
            whenToUse: whenToUse,
            setupUrl: normalizedSetupUrl,
            setupDescription: normalizedSetupUrl == nil ? nil : normalizedSetupDescription,
            category: category,
            createdAt: now,
            updatedAt: now
        )
        state.withLock { ledgerState in
            ledgerState.clients.append(client)
        }
        return (client, secret)
    }

    @discardableResult
    func deleteManagedClient(serverId: String, recordId: String) -> Client? {
        state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: {
                $0.id == recordId && $0.serverId == serverId && isUserManaged($0)
                    && ($0.appType == "server_local" || $0.appType == "third_party_global")
                    && ["private", "publish_requested", "in_review", "rejected"].contains($0.publishStatus)
            }) else { return nil }
            let removed = ledgerState.clients.remove(at: index)
            ledgerState.installations.removeAll { $0.clientId == recordId }
            ledgerState.clientShareLinks.removeAll { $0.clientRecordId == recordId }
            ledgerState.appWebhookConfigs[recordId] = nil
            ledgerState.appPermissionRevisions.removeAll { $0.clientRecordId == recordId }
            for index in ledgerState.agentGrants.indices where ledgerState.agentGrants[index].clientRecordId == recordId {
                if ledgerState.agentGrants[index].revokedAt == nil {
                    ledgerState.agentGrants[index].revokedAt = Date()
                }
            }
            for index in ledgerState.tokens.indices where ledgerState.tokens[index].clientId == recordId {
                if ledgerState.tokens[index].revokedAt == nil {
                    ledgerState.tokens[index].revokedAt = Date()
                }
            }
            return removed
        }
    }

    func regenerateManagedSecret(serverId: String, recordId: String) -> (client: Client, secret: String)? {
        let secret = "raft_secret_" + Self.randomHex(24)
        return state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: {
                $0.id == recordId && $0.serverId == serverId && isUserManaged($0)
                    && ($0.appType == "server_local" || $0.appType == "third_party_global")
            }) else { return nil }
            ledgerState.clients[index].secretHash = sha256(secret)
            ledgerState.clients[index].updatedAt = Date()
            return (ledgerState.clients[index], secret)
        }
    }

    // MARK: - Marketplace lifecycle

    func requestManagedPublish(serverId: String, recordId: String) throws -> Client? {
        try state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: {
                $0.id == recordId && $0.serverId == serverId && isUserManaged($0)
                    && ($0.appType == "server_local" || $0.appType == "third_party_global")
                    && ["private", "rejected", "publish_requested", "in_review"].contains($0.publishStatus)
            }) else { return nil }
            let description = ledgerState.clients[index].descriptionText ?? ""
            guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OAuthClientRejection(message: "description is required before requesting marketplace review")
            }
            ledgerState.clients[index].publishStatus = "publish_requested"
            ledgerState.clients[index].dataAccessSummary = nil
            ledgerState.clients[index].publishRejectionReason = nil
            ledgerState.clients[index].publishRequestedAt = Date()
            ledgerState.clients[index].updatedAt = Date()
            return ledgerState.clients[index]
        }
    }

    func requestManagedUnpublish(serverId: String, recordId: String) -> Client? {
        state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: {
                $0.id == recordId && $0.serverId == serverId && isUserManaged($0)
                    && $0.appType == "third_party_global" && $0.enabled
                    && ["published", "unpublish_requested"].contains($0.publishStatus)
            }) else { return nil }
            if ledgerState.clients[index].publishStatus == "published" {
                ledgerState.clients[index].publishStatus = "unpublish_requested"
                ledgerState.clients[index].publishRejectionReason = nil
                ledgerState.clients[index].publishRequestedAt = Date()
                ledgerState.clients[index].publishReviewedAt = nil
                ledgerState.clients[index].updatedAt = Date()
            }
            return ledgerState.clients[index]
        }
    }

    // MARK: - Private share links

    func createManagedShareLink(
        serverId: String,
        recordId: String,
        createdByUserId: String,
        expiresInDays: Int?
    ) -> (client: Client, link: ClientShareLink, token: String)? {
        state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: {
                $0.id == recordId && $0.serverId == serverId && $0.enabled && isUserManaged($0)
                    && ($0.appType == "server_local" || $0.appType == "third_party_global")
            }) else { return nil }
            let now = Date()
            let days = min(max(expiresInDays ?? 30, 1), 365)
            let expiresAt = now.addingTimeInterval(Double(days) * 24 * 60 * 60)
            let token = "raft_share_" + Self.randomHex(32)
            ledgerState.clients[index].appType = "third_party_global"
            ledgerState.clients[index].humanMarketplaceVisible = false
            ledgerState.clients[index].updatedAt = now
            let client = ledgerState.clients[index]
            if !ledgerState.installations.contains(where: {
                $0.clientId == client.id && $0.serverId == client.serverId && $0.status == "active"
            }) {
                ledgerState.installations.append(Installation(
                    id: UUID().uuidString.lowercased(), serverId: client.serverId, clientId: client.id,
                    installedByUserId: createdByUserId, approvedGroups: client.outboundGroups,
                    grantRevision: client.outboundCurrentRevisionId == nil ? 0 : 1,
                    status: "active", createdAt: now,
                    approvedRequestRevisionId: client.outboundCurrentRevisionId,
                    subscribedEvents: client.outboundEvents
                ))
            }
            for linkIndex in ledgerState.clientShareLinks.indices
            where ledgerState.clientShareLinks[linkIndex].clientRecordId == client.id
                && ledgerState.clientShareLinks[linkIndex].revokedAt == nil {
                ledgerState.clientShareLinks[linkIndex].revokedAt = now
                ledgerState.clientShareLinks[linkIndex].updatedAt = now
            }
            let link = ClientShareLink(
                id: UUID().uuidString.lowercased(),
                clientRecordId: client.id,
                tokenHash: sha256(token),
                expiresAt: expiresAt,
                revokedAt: nil,
                lastUsedAt: nil,
                createdAt: now,
                updatedAt: now
            )
            ledgerState.clientShareLinks.append(link)
            return (client, link, token)
        }
    }

    func revokeManagedShareLink(serverId: String, recordId: String) -> ClientShareLink? {
        state.withLock { ledgerState in
            guard ledgerState.clients.contains(where: {
                $0.id == recordId && $0.serverId == serverId && isUserManaged($0)
            }) else { return nil }
            guard let index = ledgerState.clientShareLinks.lastIndex(where: {
                $0.clientRecordId == recordId && $0.revokedAt == nil
            }) else { return nil }
            ledgerState.clientShareLinks[index].revokedAt = Date()
            ledgerState.clientShareLinks[index].updatedAt = Date()
            return ledgerState.clientShareLinks[index]
        }
    }

    struct ManagedShareInvite: Sendable {
        var client: Client
        var link: ClientShareLink
        var publisherName: String?
        var sourceServerName: String
        var manageableServers: [ManagedShareServer]
        var installedAt: Date?
    }

    struct ManagedShareServer: Sendable {
        var id: String
        var name: String
        var slug: String
        var role: String
        var installedAt: Date?
    }

    func managedShareInvite(token: String, userId: String, targetServerId: String?) -> ManagedShareInvite? {
        state.withLock { ledgerState in
            let hash = sha256(token.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let link = ledgerState.clientShareLinks.first(where: {
                $0.tokenHash == hash && $0.revokedAt == nil
            }) else { return nil }
            if let expires = link.expiresAt, expires.timeIntervalSinceNow <= 0 { return nil }
            guard let client = ledgerState.clients.first(where: {
                $0.id == link.clientRecordId && $0.appType == "third_party_global"
                    && $0.enabled && isUserManaged($0)
            }) else { return nil }
            guard let server = ledgerState.servers[client.serverId], !server.deleted else { return nil }
            var servers: [ManagedShareServer] = []
            for (key, role) in ledgerState.members {
                let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[1] == userId, role == "owner" || role == "admin" else { continue }
                if let targetServerId, parts[0] != targetServerId { continue }
                guard let memberServer = ledgerState.servers[parts[0]], !memberServer.deleted else { continue }
                let installedAt = ledgerState.installations.first(where: {
                    $0.clientId == client.id && $0.serverId == parts[0] && $0.status == "active"
                })?.createdAt
                servers.append(ManagedShareServer(
                    id: memberServer.id, name: memberServer.name, slug: memberServer.slug,
                    role: role, installedAt: installedAt
                ))
            }
            servers.sort { $0.name < $1.name }
            let installedAt = targetServerId.flatMap { target in
                ledgerState.installations.first(where: {
                    $0.clientId == client.id && $0.serverId == target && $0.status == "active"
                })?.createdAt
            }
            return ManagedShareInvite(
                client: client, link: link, publisherName: nil,
                sourceServerName: server.name, manageableServers: servers, installedAt: installedAt
            )
        }
    }

    func installManagedShareInvite(token: String, userId: String, serverId: String) -> ManagedShareInvite? {
        guard let invite = managedShareInvite(token: token, userId: userId, targetServerId: serverId),
              !invite.manageableServers.isEmpty
        else { return nil }
        state.withLock { ledgerState in
            let now = Date()
            if !ledgerState.installations.contains(where: {
                $0.clientId == invite.client.id && $0.serverId == serverId && $0.status == "active"
            }) {
                ledgerState.installations.append(Installation(
                    id: UUID().uuidString.lowercased(), serverId: serverId, clientId: invite.client.id,
                    installedByUserId: userId, approvedGroups: invite.client.outboundGroups,
                    grantRevision: invite.client.outboundCurrentRevisionId == nil ? 0 : 1,
                    status: "active", createdAt: now,
                    approvedRequestRevisionId: invite.client.outboundCurrentRevisionId,
                    subscribedEvents: invite.client.outboundEvents
                ))
            }
            if let index = ledgerState.clientShareLinks.firstIndex(where: { $0.id == invite.link.id }) {
                ledgerState.clientShareLinks[index].lastUsedAt = now
                ledgerState.clientShareLinks[index].updatedAt = now
            }
        }
        return managedShareInvite(token: token, userId: userId, targetServerId: serverId)
    }

    // MARK: - App Notifications permissions

    struct ManagedPermissionOutcome: Sendable {
        var revision: AppPermissionRevision
        var currentGroups: [String]
        var currentEvents: [String]
        var requiresReview: Bool
        var invalidatedInstallationCount: Int
    }

    func createManagedPermissionRevision(
        serverId: String,
        recordId: String,
        groups: [String],
        events: [String]
    ) -> ManagedPermissionOutcome? {
        state.withLock { ledgerState -> ManagedPermissionOutcome? in
            guard let index = ledgerState.clients.firstIndex(where: {
                $0.id == recordId && $0.serverId == serverId && isUserManaged($0)
            }) else { return nil }
            let client = ledgerState.clients[index]
            let priorGroups = client.outboundGroups.sorted()
            let priorEvents = client.outboundEvents.sorted()
            let requestedGroups = Array(Set(groups)).sorted()
            let requestedEvents = Array(Set(events)).sorted()
            let survivingGroups = priorGroups.filter { requestedGroups.contains($0) }
            let survivingEvents = priorEvents.filter { requestedEvents.contains($0) }
            let additions = requestedGroups.filter { !priorGroups.contains($0) }
                + requestedEvents.filter { !priorEvents.contains($0) }
            let requiresReview = client.appType == "third_party_global"
                && (client.publishStatus == "published" || client.publishStatus == "unpublish_requested")
                && !additions.isEmpty
            let currentGroups = requiresReview ? survivingGroups : requestedGroups
            let currentEvents = requiresReview ? survivingEvents : requestedEvents
            let revisionNumber = client.outboundRequestRevision + 1
            let now = Date()
            for revisionIndex in ledgerState.appPermissionRevisions.indices
            where ledgerState.appPermissionRevisions[revisionIndex].clientRecordId == client.id
                && ledgerState.appPermissionRevisions[revisionIndex].state != "superseded" {
                ledgerState.appPermissionRevisions[revisionIndex].state = "superseded"
            }
            let revision = AppPermissionRevision(
                id: UUID().uuidString.lowercased(), clientRecordId: client.id,
                revision: revisionNumber, requestedGroups: requestedGroups, requestedEvents: requestedEvents,
                state: requiresReview ? "pending_review" : "active", createdAt: now
            )
            ledgerState.appPermissionRevisions.append(revision)
            ledgerState.clients[index].outboundRequestRevision = revisionNumber
            ledgerState.clients[index].outboundCurrentRevisionId = revision.id
            ledgerState.clients[index].pendingOutboundRevisionId = requiresReview ? revision.id : nil
            ledgerState.clients[index].outboundPendingRevisionState = requiresReview ? "pending_review" : nil
            ledgerState.clients[index].outboundGroups = currentGroups
            ledgerState.clients[index].outboundEvents = currentEvents
            ledgerState.clients[index].pendingOutboundGroups = requiresReview ? requestedGroups : []
            ledgerState.clients[index].outboundPendingEvents = requiresReview ? requestedEvents : []
            ledgerState.clients[index].updatedAt = now
            let groupsContracted = priorGroups.contains { !currentGroups.contains($0) }
            var invalidated = 0
            if groupsContracted {
                for installIndex in ledgerState.installations.indices
                where ledgerState.installations[installIndex].clientId == client.id
                    && ledgerState.installations[installIndex].status == "active" {
                    invalidated += 1
                    ledgerState.installations[installIndex].approvedGroups =
                        ledgerState.installations[installIndex].approvedGroups.filter { currentGroups.contains($0) }
                    ledgerState.installations[installIndex].grantRevision += 1
                }
            }
            if !requiresReview {
                let hasSource = ledgerState.installations.contains(where: {
                    $0.clientId == client.id && $0.serverId == client.serverId && $0.status == "active"
                })
                if !hasSource {
                    ledgerState.installations.append(Installation(
                        id: UUID().uuidString.lowercased(), serverId: client.serverId, clientId: client.id,
                        installedByUserId: client.createdByUserId, approvedGroups: currentGroups,
                        grantRevision: 1, status: "active", createdAt: now,
                        approvedRequestRevisionId: revision.id, subscribedEvents: currentEvents
                    ))
                }
                for installIndex in ledgerState.installations.indices
                where ledgerState.installations[installIndex].clientId == client.id
                    && ledgerState.installations[installIndex].serverId == client.serverId
                    && ledgerState.installations[installIndex].status == "active" {
                    let groupsChanged = ledgerState.installations[installIndex].approvedGroups.sorted() != currentGroups
                    let eventsChanged = ledgerState.installations[installIndex].subscribedEvents.sorted() != currentEvents
                    ledgerState.installations[installIndex].approvedRequestRevisionId = revision.id
                    ledgerState.installations[installIndex].approvedGroups = currentGroups
                    if groupsChanged { ledgerState.installations[installIndex].grantRevision += 1 }
                    ledgerState.installations[installIndex].subscribedEvents = currentEvents
                    if eventsChanged { ledgerState.installations[installIndex].subscriptionRevision += 1 }
                }
            }
            return ManagedPermissionOutcome(
                revision: revision, currentGroups: currentGroups, currentEvents: currentEvents,
                requiresReview: requiresReview, invalidatedInstallationCount: invalidated
            )
        }
    }

    func updateManagedInstallationGrant(serverId: String, recordId: String) -> Installation? {
        state.withLock { ledgerState in
            guard let index = ledgerState.installations.firstIndex(where: {
                $0.serverId == serverId && $0.clientId == recordId && $0.status == "active"
            }), let client = ledgerState.clients.first(where: { $0.id == recordId })
            else { return nil }
            let now = Date()
            let revisionId = client.outboundCurrentRevisionId
            let approvedGroups = client.outboundGroups
            let subscribedEvents = client.outboundEvents
            let groupsChanged = ledgerState.installations[index].approvedGroups.sorted() != approvedGroups
            let eventsChanged = ledgerState.installations[index].subscribedEvents.sorted() != subscribedEvents
            ledgerState.installations[index].approvedRequestRevisionId = revisionId
            ledgerState.installations[index].approvedGroups = approvedGroups
            if groupsChanged { ledgerState.installations[index].grantRevision += 1 }
            ledgerState.installations[index].subscribedEvents = subscribedEvents
            if eventsChanged { ledgerState.installations[index].subscriptionRevision += 1 }
            _ = now
            return ledgerState.installations[index]
        }
    }

    // MARK: - Webhook configuration

    func configureManagedWebhook(serverId: String, recordId: String, endpointUrl: String) -> AppWebhookConfig? {
        state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: {
                $0.id == recordId && $0.serverId == serverId && isUserManaged($0)
            }) else { return nil }
            let now = Date()
            if !ledgerState.installations.contains(where: {
                $0.clientId == client.id && $0.serverId == client.serverId && $0.status == "active"
            }) {
                ledgerState.installations.append(Installation(
                    id: UUID().uuidString.lowercased(), serverId: client.serverId, clientId: client.id,
                    installedByUserId: client.createdByUserId, approvedGroups: [],
                    grantRevision: 0, status: "active", createdAt: now
                ))
            }
            if var existing = ledgerState.appWebhookConfigs[client.id] {
                existing.endpointUrl = endpointUrl
                existing.enabled = true
                existing.revision += 1
                existing.updatedAt = now
                ledgerState.appWebhookConfigs[client.id] = existing
                return existing
            }
            let config = AppWebhookConfig(
                clientRecordId: client.id, endpointUrl: endpointUrl,
                secret: "raft_webhook_secret_" + Self.randomBase64URL(32),
                previousSecret: nil, previousValidUntil: nil,
                revision: 1, enabled: true, updatedAt: now
            )
            ledgerState.appWebhookConfigs[client.id] = config
            return config
        }
    }

    func rotateManagedWebhookSecret(serverId: String, recordId: String, emergency: Bool) -> AppWebhookConfig? {
        state.withLock { ledgerState in
            guard ledgerState.clients.contains(where: {
                $0.id == recordId && $0.serverId == serverId && isUserManaged($0)
            }) else { return nil }
            guard var config = ledgerState.appWebhookConfigs[recordId], config.enabled else { return nil }
            let now = Date()
            config.previousSecret = emergency ? nil : config.secret
            config.previousValidUntil = emergency ? nil : now.addingTimeInterval(6 * 60)
            config.secret = "raft_webhook_secret_" + Self.randomBase64URL(32)
            config.revision += 1
            config.updatedAt = now
            ledgerState.appWebhookConfigs[recordId] = config
            return config
        }
    }

    func disableManagedWebhook(serverId: String, recordId: String) -> AppWebhookConfig? {
        state.withLock { ledgerState in
            guard ledgerState.clients.contains(where: {
                $0.id == recordId && $0.serverId == serverId && isUserManaged($0)
            }) else { return nil }
            guard var config = ledgerState.appWebhookConfigs[recordId] else { return nil }
            config.enabled = false
            config.previousSecret = nil
            config.previousValidUntil = nil
            config.revision += 1
            config.updatedAt = Date()
            ledgerState.appWebhookConfigs[recordId] = config
            return config
        }
    }

    // MARK: - Overview / deny

    struct ManagedOverviewEntry: Sendable {
        var id: String
        var type: String
        var serverId: String
        var agentId: String
        var agentName: String
        var agentDisplayName: String?
        var clientId: String
        var clientKey: String
        var clientName: String
        var clientDescription: String?
        var clientHomepageUrl: String?
        var clientReturnUrl: String?
        var clientAgentManifestUrl: String?
        var scopes: [String]
        var remember: Bool
        var createdAt: Date
        var resolvedAt: Date?
        var resolvedByUserId: String?
        var revokedAt: Date?
        var grantSource: String?
    }

    func managedIntegrationsOverview(serverId: String) -> [ManagedOverviewEntry] {
        state.withLock { ledgerState in
            var rows: [ManagedOverviewEntry] = []
            for request in ledgerState.requests where request.serverId == serverId && request.status == "pending" {
                guard let agentId = request.agentId, let agent = ledgerState.agents[agentId], !agent.deleted,
                      let client = ledgerState.clients.first(where: { $0.id == request.clientId }),
                      isUserManaged(client)
                else { continue }
                rows.append(ManagedOverviewEntry(
                    id: request.id, type: "pending", serverId: request.serverId, agentId: agentId,
                    agentName: agent.name, agentDisplayName: agent.displayName,
                    clientId: client.id, clientKey: client.clientId, clientName: client.name,
                    clientDescription: client.descriptionText, clientHomepageUrl: client.homepageUrl,
                    clientReturnUrl: client.returnUrl, clientAgentManifestUrl: client.agentManifestUrl,
                    scopes: request.scopes, remember: request.remember, createdAt: request.createdAt,
                    resolvedAt: request.resolvedAt, resolvedByUserId: request.resolvedByUserId,
                    revokedAt: nil, grantSource: nil
                ))
            }
            for grant in ledgerState.agentGrants where grant.serverId == serverId && grant.revokedAt == nil {
                guard let agent = ledgerState.agents[grant.agentId], !agent.deleted,
                      let client = ledgerState.clients.first(where: { $0.id == grant.clientRecordId }),
                      isUserManaged(client)
                else { continue }
                rows.append(ManagedOverviewEntry(
                    id: grant.id, type: "active", serverId: grant.serverId, agentId: grant.agentId,
                    agentName: agent.name, agentDisplayName: agent.displayName,
                    clientId: client.id, clientKey: client.clientId, clientName: client.name,
                    clientDescription: client.descriptionText, clientHomepageUrl: client.homepageUrl,
                    clientReturnUrl: client.returnUrl, clientAgentManifestUrl: client.agentManifestUrl,
                    scopes: grant.scopes, remember: false, createdAt: grant.createdAt,
                    resolvedAt: nil, resolvedByUserId: grant.grantedByUserId,
                    revokedAt: grant.revokedAt, grantSource: grant.grantSource
                ))
            }
            return rows.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func denyManagedAccessRequest(userId: String, requestId: String) -> AccessRequest? {
        state.withLock { ledgerState in
            guard let index = ledgerState.requests.firstIndex(where: { $0.id == requestId }) else {
                return nil
            }
            if let agentId = ledgerState.requests[index].agentId,
               let agent = ledgerState.agents[agentId], !agent.deleted {
                guard isAgentAuthorityLocked(
                    userId: userId, agent: agent, serverId: agent.serverId, state: ledgerState
                ) else { return nil }
            } else {
                let role = ledgerState.members["\(ledgerState.requests[index].serverId)\n\(userId)"]
                guard role == "owner" || role == "admin" else { return nil }
            }
            if ledgerState.requests[index].status == "pending" {
                ledgerState.requests[index].status = "denied"
                ledgerState.requests[index].remember = false
                ledgerState.requests[index].resolvedByUserId = userId
                ledgerState.requests[index].resolvedAt = Date()
                ledgerState.requests[index].updatedAt = Date()
            }
            return ledgerState.requests[index]
        }
    }

    static func randomHex(_ byteCount: Int) -> String {
        var bytes = Data(count: byteCount)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func randomBase64URL(_ byteCount: Int) -> String {
        var bytes = Data(count: byteCount)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return base64url(bytes)
    }
}
