import Foundation
@testable import RaftHTTP

/// Installation setup and live-state changes over the scene's actual OAuth
/// owner. No owner, State, generic mutation closure or alternate graph escapes.
public struct InstallationFixture: Sendable {
    private let oauth: OAuthLedger

    init(oauth: OAuthLedger) {
        self.oauth = oauth
    }

    public func seedServer(id: String, slug: String, name: String, ownerId: String) {
        oauth.addOwnedServer(id: id, slug: slug, name: name, ownerId: ownerId)
    }

    public func seedApp(
        serverId: String, createdByUserId: String, name: String,
        clientId: String, appType: String = "third_party_global"
    ) throws -> CreatedOAuthClient {
        try oauth.createClient(
            serverId: serverId, createdByUserId: createdByUserId, name: name,
            clientId: clientId, appType: appType
        )
    }

    /// The existing owner operation also sets the App's outbound groups, then
    /// appends an active revision-one installation in its original transaction.
    public func seedActiveInstallation(
        serverId: String, clientRecordId: String, installedByUserId: String, groups: [String]
    ) -> String {
        oauth.installClient(
            serverId: serverId, clientRecordId: clientRecordId,
            installedByUserId: installedByUserId, groups: groups
        )
    }

    public func installationTokenCount(clientRecordId: String) -> Int {
        oauth.installationTokenCount(clientRecordId: clientRecordId)
    }

    public func setAppType(clientRecordId: String, appType: String) {
        oauth.setClientAppType(clientRecordId: clientRecordId, appType: appType)
    }

    public func registerExternalApp(clientRecordId: String, provider: String, state: String) {
        oauth.registerExternalApp(clientRecordId: clientRecordId, provider: provider, state: state)
    }

    public func deleteServer(id: String) {
        oauth.deleteServer(id: id)
    }

    public func setOutboundReadGroups(clientRecordId: String, groups: [String]) {
        oauth.setClientOutboundGroupsForTesting(clientRecordId: clientRecordId, groups: groups)
    }

    public func setApprovedReadGroups(installationId: String, groups: [String]) {
        oauth.state.withLock { owned in
            guard let index = owned.installations.firstIndex(where: { $0.id == installationId }) else { return }
            owned.installations[index].approvedGroups = groups
        }
    }

    public func advanceGrantRevision(installationId: String) {
        oauth.state.withLock { owned in
            guard let index = owned.installations.firstIndex(where: { $0.id == installationId }) else { return }
            owned.installations[index].grantRevision += 1
        }
    }

    public func expireCredentials(installationId: String) {
        oauth.state.withLock { owned in
            for index in owned.installationTokens.indices where owned.installationTokens[index].installationId == installationId {
                owned.installationTokens[index].expiresAt = .distantPast
            }
        }
    }

    public func setCredentialAudience(installationId: String, audience: String) {
        oauth.state.withLock { owned in
            for index in owned.installationTokens.indices where owned.installationTokens[index].installationId == installationId {
                owned.installationTokens[index].audience = audience
            }
        }
    }

    public func setAppEnabled(clientRecordId: String, enabled: Bool) {
        oauth.setClientEnabled(clientRecordId: clientRecordId, enabled: enabled)
    }
}
