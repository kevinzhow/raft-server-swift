@testable import RaftHTTP

/// Only the existing OAuth setup, readback and mutations used by this batch.
/// The actual owner is private; no State, Root or generic callback escapes.
public struct OAuthFixture: Sendable {
    private let oauth: OAuthLedger

    init(oauth: OAuthLedger) {
        self.oauth = oauth
    }

    public func addOwnedServer(id: String, slug: String, name: String, ownerId: String) {
        oauth.addOwnedServer(id: id, slug: slug, name: name, ownerId: ownerId)
    }

    public func addMember(serverId: String, userId: String, role: String) {
        oauth.addMember(serverId: serverId, userId: userId, role: role)
    }

    public func removeMember(serverId: String, userId: String) {
        oauth.removeMember(serverId: serverId, userId: userId)
    }

    public func createClient(
        serverId: String, createdByUserId: String, name: String, clientId: String,
        appType: String = "server_local", description: String? = nil,
        homepageUrl: String? = nil, returnUrl: String? = nil, allowedScopes: [String]? = nil
    ) throws -> CreatedOAuthClient {
        try oauth.createClient(serverId: serverId, createdByUserId: createdByUserId,
            name: name, clientId: clientId, appType: appType, description: description,
            homepageUrl: homepageUrl, returnUrl: returnUrl, allowedScopes: allowedScopes)
    }

    public func setClientSecretForTesting(clientRecordId: String, secret: String) {
        oauth.setClientSecretForTesting(clientRecordId: clientRecordId, secret: secret)
    }

    public func setClientReturnUrl(clientRecordId: String, returnUrl: String?) {
        oauth.setClientReturnUrl(clientRecordId: clientRecordId, returnUrl: returnUrl)
    }

    public func updateClientReturnUrl(clientRecordId: String, returnUrl: String?) throws {
        try oauth.updateClientReturnUrl(clientRecordId: clientRecordId, returnUrl: returnUrl)
    }

    public func createAgent(
        serverId: String, name: String, displayName: String? = nil,
        avatarUrl: String? = nil, creatorUserId: String? = nil, runtime: String = "managed"
    ) -> String {
        oauth.createAgent(serverId: serverId, name: name, displayName: displayName,
            avatarUrl: avatarUrl, creatorUserId: creatorUserId, runtime: runtime)
    }

    public func deleteAgent(id: String) {
        oauth.deleteAgent(id: id)
    }

    public func removeAgentMember(serverId: String, agentId: String) {
        oauth.removeAgentMember(serverId: serverId, agentId: agentId)
    }

    public func setAgentRole(serverId: String, agentId: String, role: String) {
        oauth.setAgentRole(serverId: serverId, agentId: agentId, role: role)
    }

    public func setClientEnabled(clientRecordId: String, enabled: Bool) {
        oauth.setClientEnabled(clientRecordId: clientRecordId, enabled: enabled)
    }

    public func setClientAllowedScopes(clientRecordId: String, scopes: [String]?) {
        oauth.setClientAllowedScopes(clientRecordId: clientRecordId, scopes: scopes)
    }

    public func updateServer(id: String, name: String, avatarUrl: String?) {
        oauth.updateServer(id: id, name: name, avatarUrl: avatarUrl)
    }

    public func setServerPlan(id: String, plan: String) {
        oauth.setServerPlan(id: id, plan: plan)
    }

    public func deleteServer(id: String) {
        oauth.deleteServer(id: id)
    }

    public func expireAuthorizationCode(id: String) {
        oauth.expireAuthorizationCode(id: id)
    }

    public func accessTokenCount(requestId: String) -> Int {
        oauth.accessTokenCount(requestId: requestId)
    }

    public func installClient(
        serverId: String, clientRecordId: String, installedByUserId: String, groups: [String]
    ) -> String {
        oauth.installClient(serverId: serverId, clientRecordId: clientRecordId,
            installedByUserId: installedByUserId, groups: groups)
    }

    public func uninstallClient(serverId: String, clientRecordId: String) -> Bool {
        oauth.uninstallClient(serverId: serverId, clientRecordId: clientRecordId)
    }

    public func revokeAccessTokens(clientRecordId: String) {
        oauth.revokeAccessTokens(clientRecordId: clientRecordId)
    }

    public func revokeAgentGrants(clientRecordId: String) {
        oauth.revokeAgentGrants(clientRecordId: clientRecordId)
    }

    public func expireAccessTokensForTesting(clientRecordId: String) {
        oauth.expireAccessTokensForTesting(clientRecordId: clientRecordId)
    }

    public func removeAuthorizationCodeForTesting(id: String) {
        oauth.removeAuthorizationCodeForTesting(id: id)
    }
}
