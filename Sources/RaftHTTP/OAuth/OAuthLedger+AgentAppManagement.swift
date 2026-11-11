import Crypto
import Foundation

/// The agent credential surface's integration-app management reads and writes.
///
/// The OAuth ledger stays the owner of the app rows, maintainers, publish status
/// and private share links. These helpers are the narrow mutations the agent
/// routes need; authorization stays in `AgentIntegrationAppsService` because it
/// owns the credential and server-role decisions.
extension OAuthLedger {
    /// The user-managed App `clientKey` names on `serverId`, without disclosing
    /// whether a cross-server or built-in client exists.
    struct AgentManagedIntegrationClient: Sendable, Equatable {
        var id: String
        var clientKey: String
        var name: String
        var appType: String
        var publishStatus: String
        var descriptionText: String?
        var logoUrl: String?
        var enabled: Bool
    }

    func agentManagedIntegrationClient(serverId: String, clientKey: String) -> AgentManagedIntegrationClient? {
        state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: { candidate in
                candidate.serverId == serverId
                    && (candidate.clientId == clientKey || candidate.id == clientKey)
                    && isUserManaged(candidate)
                    && (candidate.appType == "server_local" || candidate.appType == "third_party_global")
            }) else { return nil }
            return AgentManagedIntegrationClient(
                id: client.id,
                clientKey: client.clientId,
                name: client.name,
                appType: client.appType,
                publishStatus: client.publishStatus,
                descriptionText: client.descriptionText,
                logoUrl: client.logoUrl,
                enabled: client.enabled
            )
        }
    }

    func agentManagedIntegrationClient(clientRecordId: String) -> AgentManagedIntegrationClient? {
        state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: { $0.id == clientRecordId }) else { return nil }
            return AgentManagedIntegrationClient(
                id: client.id,
                clientKey: client.clientId,
                name: client.name,
                appType: client.appType,
                publishStatus: client.publishStatus,
                descriptionText: client.descriptionText,
                logoUrl: client.logoUrl,
                enabled: client.enabled
            )
        }
    }

    /// `getAgentAppAuthority`: a current server admin, or an app owner
    /// maintainer. The port stores owner maintainers as agent ids only.
    func isAgentIntegrationAppManager(serverId: String, agentId: String, clientRecordId: String) -> Bool {
        state.withLock { ledgerState in
            // Upstream `getAgentAppAuthority` accepts an `admin` server-agent
            // role, then an owner maintainer. The port stores owner maintainers
            // as agent ids; there is no separate `rotate` maintainer role.
            if ledgerState.agentRoles["\(serverId)\n\(agentId)"] == "admin" { return true }
            return ledgerState.clientMaintainerOwners[clientRecordId]?.contains(agentId) == true
        }
    }

    func clientMaintainerOwnerId(clientRecordId: String) -> String? {
        state.withLock { ledgerState in
            ledgerState.clientMaintainerOwners[clientRecordId]?.sorted().first
        }
    }

    /// Replace the owner maintainer with `agentId`, returning the previous owner
    /// and whether the target already owned the app. `nil` means the app had no
    /// owner (upstream `owner_required`).
    func transferAgentManagedIntegrationClient(
        clientRecordId: String,
        to agentId: String
    ) -> (previousOwner: String?, outcome: String)? {
        state.withLock { ledgerState in
            let current = ledgerState.clientMaintainerOwners[clientRecordId]?.sorted().first
            guard let current else { return nil }
            if current == agentId {
                return (current, "already_owner")
            }
            ledgerState.clientMaintainerOwners[clientRecordId] = [agentId]
            return (current, "transferred")
        }
    }

    /// Rotate the client secret and return the one-time plaintext. Only the hash
    /// is retained.
    func rotateAgentManagedIntegrationClientSecret(clientRecordId: String) -> String? {
        var bytes = Data(count: 24)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let secret = "raft_secret_" + bytes.map { String(format: "%02x", $0) }.joined()
        return state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) else { return nil }
            ledgerState.clients[index].secretHash = sha256(secret)
            return secret
        }
    }

    func setAgentManagedIntegrationClientLogo(clientRecordId: String, logoUrl: String?) {
        state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) else { return }
            ledgerState.clients[index].logoUrl = logoUrl
        }
    }

    /// One publish or unpublish request transition. The guard is the upstream
    /// UPDATE's status predicate; `nil` means the app is not in a requestable
    /// state.
    func requestAgentManagedIntegrationClientPublish(clientRecordId: String, status: String) -> Bool {
        state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) else { return false }
            if status == "publish_requested" {
                // `draft` is this port's stored projection for a not-yet-published
                // App; upstream stores the same state as `private`.
                guard ["private", "draft", "rejected"].contains(ledgerState.clients[index].publishStatus) else { return false }
            } else if status == "unpublish_requested" {
                guard ledgerState.clients[index].appType == "third_party_global",
                      ledgerState.clients[index].enabled,
                      ledgerState.clients[index].publishStatus == "published"
                else { return false }
            }
            ledgerState.clients[index].publishStatus = status
            return true
        }
    }

    /// Remove a non-published user-managed App, its share links and its
    /// installation. `false` means the app is published (or absent).
    func deleteAgentManagedIntegrationClient(clientRecordId: String) -> Bool {
        state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: { $0.id == clientRecordId }) else { return false }
            let client = ledgerState.clients[index]
            guard ["private", "draft", "publish_requested", "in_review", "rejected"].contains(client.publishStatus) else {
                return false
            }
            ledgerState.clients.remove(at: index)
            ledgerState.clientMaintainerOwners[clientRecordId] = nil
            ledgerState.clientShareLinks.removeAll { $0.clientId == clientRecordId }
            ledgerState.installations.removeAll { $0.clientId == clientRecordId }
            ledgerState.installationTokens.removeAll { $0.clientId == clientRecordId }
            return true
        }
    }

    // MARK: Private share links

    func activeAgentManagedIntegrationShareLink(clientRecordId: String) -> ClientShareLink? {
        state.withLock { ledgerState in
            ledgerState.clientShareLinks
                .filter { $0.clientId == clientRecordId && $0.revokedAt == nil }
                .max { $0.createdAt < $1.createdAt }
        }
    }

    /// The upstream create: convert a server-local App to a distributable one,
    /// make sure the owning Server has an installation, revoke the previous
    /// active link and issue a new token. Only the token hash is stored.
    func createAgentManagedIntegrationShareLink(
        serverId: String,
        clientRecordId: String,
        actorAgentId: String?,
        actorUserId: String?,
        expiresInDays: Int?,
        now: Date = Date()
    ) -> (link: ClientShareLink, token: String)? {
        let days = min(max(expiresInDays ?? 30, 1), 365)
        var bytes = Data(count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let token = "raft_share_" + bytes.map { String(format: "%02x", $0) }.joined()
        let tokenHash = sha256(token)
        return state.withLock { ledgerState in
            guard let index = ledgerState.clients.firstIndex(where: {
                $0.id == clientRecordId && $0.serverId == serverId && $0.enabled
                    && isUserManaged($0)
                    && ($0.appType == "server_local" || $0.appType == "third_party_global")
            }) else { return nil }
            ledgerState.clients[index].appType = "third_party_global"
            if !ledgerState.installations.contains(where: {
                $0.clientId == clientRecordId && $0.serverId == serverId && $0.status == "active"
            }) {
                ledgerState.installations.append(Installation(
                    id: UUID().uuidString.lowercased(),
                    serverId: serverId,
                    clientId: clientRecordId,
                    installedByUserId: actorUserId ?? ledgerState.clients[index].createdByUserId,
                    approvedGroups: [],
                    grantRevision: 1,
                    status: "active"
                ))
            }
            for linkIndex in ledgerState.clientShareLinks.indices where
                ledgerState.clientShareLinks[linkIndex].clientId == clientRecordId
                && ledgerState.clientShareLinks[linkIndex].revokedAt == nil {
                ledgerState.clientShareLinks[linkIndex].revokedAt = now
                ledgerState.clientShareLinks[linkIndex].updatedAt = now
            }
            let link = ClientShareLink(
                id: UUID().uuidString.lowercased(),
                clientId: clientRecordId,
                tokenHash: tokenHash,
                createdByUserId: actorAgentId == nil ? actorUserId : nil,
                createdByAgentId: actorAgentId,
                expiresAt: now.addingTimeInterval(Double(days) * 24 * 60 * 60),
                createdAt: now,
                updatedAt: now,
                revokedAt: nil,
                lastUsedAt: nil
            )
            ledgerState.clientShareLinks.append(link)
            return (link, token)
        }
    }

    func revokeAgentManagedIntegrationShareLink(clientRecordId: String, now: Date = Date()) -> ClientShareLink? {
        state.withLock { ledgerState in
            guard let index = ledgerState.clientShareLinks.lastIndex(where: {
                $0.clientId == clientRecordId && $0.revokedAt == nil
            }) else { return nil }
            ledgerState.clientShareLinks[index].revokedAt = now
            ledgerState.clientShareLinks[index].updatedAt = now
            return ledgerState.clientShareLinks[index]
        }
    }

    /// Append the audit row and return its id, which the transfer receipt
    /// publishes as `auditEventId`.
    @discardableResult
    func recordAgentManagedIntegrationAudit(
        serverId: String,
        clientRecordId: String?,
        installationId: String,
        eventType: String
    ) -> String {
        let event = IntegrationAuditEvent(
            eventType: eventType,
            clientRecordId: clientRecordId ?? "",
            installationId: installationId,
            serverId: serverId
        )
        state.withLock { ledgerState in
            ledgerState.integrationAuditEvents.append(event)
        }
        return event.id
    }
}
