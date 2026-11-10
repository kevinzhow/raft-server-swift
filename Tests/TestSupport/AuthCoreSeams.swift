import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func mintFamilyRevokeCapabilityForTesting(refreshToken: String) -> String? {
        return authProfileStore.state.withLock { owned in
            guard let live = owned.accountSurface.sessions[refreshToken], let family = owned.accountSurface.sessionFamilies[live.familyId] else { return nil }
            let nonce = family.revokeCapabilityNonce ?? AuthTokenCodec.randomHex(16)
            var updated = family
            updated.revokeCapabilityNonce = nonce
            owned.accountSurface.sessionFamilies[live.familyId] = updated
            return "\(live.familyId).\(nonce)"
        }
    }

    public static func pkceChallengeForTesting(_ verifier: String) -> String {
        AuthTokenCodec.pkceS256(verifier)
    }

    public func setPasswordForTesting(userId: String, password: String) {
        let passwordHash = AuthFixturePassword.encoded(password)
        authProfileStore.state.withLock { owned in
            if let key = owned.accountSurface.accounts.first(where: { $0.value.id == userId })?.key {
                var account = owned.accountSurface.accounts[key]!
                account.passwordHash = passwordHash
                account.passwordCredentialEstablishedAt = Date()
                owned.accountSurface.accounts[key] = account
            }
        }
    }

    public func linkIdentityForTesting(userId: String, provider: String, providerUserId: String, providerEmail: String? = nil) {
        authProfileStore.state.withLock { owned in
            owned.accountSurface.linkedIdentities.append(LinkedIdentity(
                userId: userId, provider: provider, providerUserId: providerUserId, providerEmail: providerEmail
            ))
        }
    }

    @discardableResult
    public func issuePendingSocialLinkForTesting(
        provider: String, providerUserId: String, email: String,
        returnTo: String? = nil, returnUri: String? = nil,
        expiresAt: Date = Date().addingTimeInterval(600)
    ) -> String {
        let token = AuthTokenCodec.randomHex(32)
        authProfileStore.state.withLock { owned in
            owned.accountSurface.pendingSocialLinks[token] = PendingSocialLink(
                token: token, provider: provider, providerUserId: providerUserId,
                email: AccountNaming.normalize(email), returnTo: returnTo, returnUri: returnUri,
                expiresAt: expiresAt
            )
        }
        return token
    }

    public func latestEmailVerificationTokenForTesting(userId: String) -> String? {
        authProfileStore.latestVerificationToken(userId: userId)?.rawToken
    }

    // MARK: Account and session readbacks (moved out of AuthCoreService.swift)

    public func markPasswordCredentialEstablished(userId: String) {
        authProfileStore.state.withLock { owned in
            if let key = owned.accountSurface.accounts.first(where: { $0.value.id == userId })?.key {
                owned.accountSurface.accounts[key]?.passwordCredentialEstablishedAt = Date()
            }
        }
    }

    public func hasAccount(email: String) -> Bool {
        authProfileStore.accountState.accounts[AccountNaming.normalize(email)] != nil
    }

    public func legalAcceptance(userId: String) -> EmailLegalAcceptance? {
        authProfileStore.legalAcceptance(userId: userId)
    }

    public func userId(forEmail email: String) -> String? {
        authProfileStore.accountState.accounts[AccountNaming.normalize(email)]?.id
    }

    /// A provider callback already exchanged. The raw code is what
    /// `POST /:provider/complete` spends.
    public func addSocialCompletion(
        provider: String,
        code: String,
        email: String,
        mode: String = "login",
        intendedAction: String = "login",
        returnTo: String = "/",
        userId: String? = nil,
        providerUserId: String? = nil,
        linkOnConflict: Bool = false
    ) {
        authProfileStore.state.withLock { owned in
            owned.accountSurface.socialCompletions.append(SocialCompletion(
                provider: provider,
                code: code,
                mode: mode,
                intendedAction: intendedAction,
                email: AccountNaming.normalize(email),
                returnTo: returnTo,
                userId: userId,
                providerUserId: providerUserId,
                linkOnConflict: linkOnConflict
            ))
        }
    }

    public func linkedProviderUserIds(userId: String, provider: String) -> [String] {
        authProfileStore.accountState.linkedIdentities
            .filter { $0.userId == userId && $0.provider == provider }.compactMap(\.providerUserId)
    }

    public func linkedProviderEmail(userId: String, provider: String) -> String? {
        authProfileStore.accountState.linkedIdentities
            .first { $0.userId == userId && $0.provider == provider }?.providerEmail
    }

    public func refreshRotationReceipts() -> [RefreshRotationReceipt] {
        authProfileStore.accountState.rotationReceipts.values.map {
            RefreshRotationReceipt(
                attemptId: $0.attemptId,
                installationId: $0.installationId,
                successorTokenCiphertext: $0.ciphertext
            )
        }
    }

    public func expireRefreshReceipts() {
        authProfileStore.state.withLock { owned in
            for key in owned.accountSurface.rotationReceipts.keys {
                owned.accountSurface.rotationReceipts[key]?.expiresAt = Date(timeIntervalSinceNow: -1)
            }
        }
    }

    /// Moves one mobile OAuth request's expiry into the past. Completion then
    /// reports `handoff_code_expired`.
    public func expireMobileOAuthRequest(id: String) {
        authProfileStore.state.withLock { owned in
            owned.accountSurface.mobileRequests[id]?.expiresAt = Date(timeIntervalSinceNow: -1)
        }
    }

    public func oauthRequestStatus(id: String) -> String? {
        authProfileStore.accountState.mobileRequests[id]?.status
    }

    public func oauthRequestReturnUri(id: String) -> String? {
        authProfileStore.accountState.mobileRequests[id]?.returnUri
    }

    public func oauthRequestCodeHash(id: String) -> String? {
        authProfileStore.accountState.mobileRequests[id]?.codeHash
    }

    public func oauthRequestExpiresAt(id: String) -> Date? {
        authProfileStore.accountState.mobileRequests[id]?.expiresAt
    }

    public func oauthRequestProviderUserId(id: String) -> String? {
        authProfileStore.accountState.mobileRequests[id]?.profileUserId
    }

    public func oauthRequestProviderEmail(id: String) -> String? {
        authProfileStore.accountState.mobileRequests[id]?.profileEmail
    }

    public func oauthRequestCodeChallenge(id: String) -> String? {
        authProfileStore.accountState.mobileRequests[id]?.codeChallenge
    }

    /// The Node fixture marks a row verified without an HTTP call. Retirement
    /// refuses an unverified account.
    public func markEmailVerified(userId: String) {
        authProfileStore.markEmailVerified(userId: userId)
    }

    public func stagingSelfAccountCapabilityHash(userId: String) -> String? {
        authProfileStore.account(userId: userId)?.stagingSelfAccountCapabilityHash
    }

    public func retiredAt(userId: String) -> Date? {
        authProfileStore.account(userId: userId)?.retiredAt
    }

    public func sessionCount(for userId: String) -> Int {
        authProfileStore.accountState.sessions.values.filter { $0.userId == userId }.count
    }

    public func sessionFamilyRevokedAts(userId: String) -> [Date?] {
        authProfileStore.accountState.sessionFamilies.values.filter { $0.userId == userId }.map(\.revokedAt)
    }

    /// Adds platform allow rules for Apple sign-in. An empty set leaves Apple
    /// disabled on every platform.
    public func allowAppleLogin(on platforms: [String]) {
        authProfileStore.state.withLock { owned in
            owned.accountSurface.appleLoginPlatforms.formUnion(platforms)
        }
    }
}
