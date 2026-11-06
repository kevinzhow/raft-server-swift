import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func mintFamilyRevokeCapabilityForTesting(refreshToken: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let live = sessions[refreshToken], let family = sessionFamilies[live.familyId] else { return nil }
        let nonce = family.revokeCapabilityNonce ?? Self.randomHex(16)
        var updated = family
        updated.revokeCapabilityNonce = nonce
        sessionFamilies[live.familyId] = updated
        return "\(live.familyId).\(nonce)"
    }

    public static func pkceChallengeForTesting(_ verifier: String) -> String {
        pkceS256(verifier)
    }

    public func setPasswordForTesting(userId: String, password: String) {
        lock.lock()
        if let key = accounts.first(where: { $0.value.id == userId })?.key {
            var account = accounts[key]!
            account.passwordHash = Self.sha256(password)
            account.passwordCredentialEstablishedAt = Date()
            accounts[key] = account
        }
        lock.unlock()
    }

    public func linkIdentityForTesting(userId: String, provider: String, providerUserId: String, providerEmail: String? = nil) {
        lock.lock()
        linkedIdentities.append(LinkedIdentity(
            userId: userId, provider: provider, providerUserId: providerUserId, providerEmail: providerEmail
        ))
        lock.unlock()
    }

    @discardableResult
    public func issuePendingSocialLinkForTesting(
        provider: String, providerUserId: String, email: String,
        returnTo: String? = nil, returnUri: String? = nil,
        expiresAt: Date = Date().addingTimeInterval(600)
    ) -> String {
        let token = Self.randomHex(32)
        lock.lock()
        pendingSocialLinks[token] = PendingSocialLink(
            token: token, provider: provider, providerUserId: providerUserId,
            email: Self.normalize(email), returnTo: returnTo, returnUri: returnUri,
            expiresAt: expiresAt
        )
        lock.unlock()
        return token
    }

    public func latestEmailVerificationTokenForTesting(userId: String) -> String? {
        authProfileStore.latestVerificationToken(userId: userId)?.rawToken
    }
}
