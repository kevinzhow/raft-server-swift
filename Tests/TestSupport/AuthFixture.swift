import Foundation
import Synchronization
@testable import RaftHTTP

/// Immutable real PHCs reused by fixture setup. CPU work stays outside every
/// account/store/cache lock. Production credential paths never use this cache.
public enum AuthFixturePassword {
    private static let hashes = Mutex<[String: String]>([:])

    public static func encoded(_ password: String) -> String {
        if let existing = hashes.withLock({ $0[password] }) { return existing }
        let encoded = try! PasswordCredential.hash(password)
        return hashes.withLock { cache in
            if let existing = cache[password] { return existing }
            cache[password] = encoded
            return encoded
        }
    }
}

/// Direct auth seeds and readbacks over the same profile owner as the services.
/// These operations preserve the legacy fixture semantics; they do not use HTTP.
public struct AuthFixture: Sendable {
    private let profiles: AuthProfileStore

    init(profiles: AuthProfileStore) {
        self.profiles = profiles
    }

    public func addAccount(
        id: String, email: String, password: String, avatarUrl: String? = nil,
        passwordCredentialEstablished: Bool = true
    ) {
        let normalized = AccountNaming.normalize(email)
        let passwordHash = AuthFixturePassword.encoded(password)
        profiles.state.withLock { owned in
            owned.accountSurface.accounts[normalized] = Account(
                id: id,
                email: normalized,
                passwordHash: passwordHash,
                passwordCredentialEstablishedAt: passwordCredentialEstablished ? Date() : nil,
                displayLanguage: nil,
                name: String(normalized.split(separator: "@").first ?? "user"),
                profileSetupSuggestedHandle: nil,
                profileSetupProvider: nil,
                profileSetupCompletedAt: Date(),
                avatarUrl: avatarUrl
            )
            owned.accountSurface.analyticsIds[id] = UUID().uuidString.lowercased()
        }
    }

    public func markEmailVerified(userId: String) {
        profiles.markEmailVerified(userId: userId)
    }

    public func mintAccessTokenForTesting(userId: String) -> String {
        profiles.openSession(userId: userId).accessToken
    }

    public var sessionCount: Int { profiles.state.withLock { $0.accountSurface.sessions.count } }
    public var userCount: Int { profiles.state.withLock { $0.accountSurface.accounts.count } }
    public var totalEmailVerificationRecordCount: Int {
        profiles.state.withLock { $0.emailVerificationTokens.values.reduce(0) { $0 + $1.count } }
    }

    public func emailVerificationTokenHashes(userId: String) -> [String] {
        profiles.state.withLock { $0.emailVerificationTokens[userId]?.map(\.tokenHash) ?? [] }
    }

    public func userId(forEmail email: String) -> String? {
        profiles.accountState.accounts[AccountNaming.normalize(email)]?.id
    }

    public func analyticsId(userId: String) -> String? {
        profiles.state.withLock { $0.accountSurface.analyticsIds[userId] }
    }

    public func passwordCredentialEstablished(userId: String) -> Bool {
        profiles.identitySnapshot(userId: userId).passwordConfigured
    }

    public func setAccountProfileForTesting(
        id: String, name: String, displayName: String? = nil, description: String? = nil
    ) {
        profiles.state.withLock { owned in
            if let key = owned.accountSurface.accounts.first(where: { $0.value.id == id })?.key,
               var account = owned.accountSurface.accounts[key] {
                account.name = name
                account.displayName = displayName ?? name
                account.description = description
                owned.accountSurface.accounts[key] = account
            }
        }
    }

    public func linkSocialIdentityForTesting(
        userId: String, provider: String, providerUserId: String, providerEmail: String? = nil
    ) {
        profiles.state.withLock { owned in
            owned.accountSurface.linkedIdentities.append(LinkedIdentity(
                userId: userId, provider: provider, providerUserId: providerUserId,
                providerEmail: providerEmail
            ))
        }
    }

    public func setSignupSurveyForTesting(userId: String, role: String?, completedAt: Date) {
        profiles.state.withLock { owned in
            if let key = owned.accountSurface.accounts.first(where: { $0.value.id == userId })?.key {
                owned.accountSurface.accounts[key]?.signupRole = role
                owned.accountSurface.accounts[key]?.signupSurveyCompletedAt = completedAt
            }
        }
    }

    public func setTimezoneObservationForTesting(
        userId: String, firstTimezone: String, firstAt: Date, lastTimezone: String, lastAt: Date
    ) {
        profiles.state.withLock { owned in
            owned.profile.timezoneObservations[userId] = TimezoneObservation(
                firstTimezone: firstTimezone, firstAt: firstAt,
                lastTimezone: lastTimezone, lastAt: lastAt
            )
        }
    }

    public func revokeSessionFamilies(userId: String) {
        profiles.state.withLock { owned in
            let now = Date()
            for key in owned.accountSurface.sessionFamilies.keys where owned.accountSurface.sessionFamilies[key]?.userId == userId {
                if owned.accountSurface.sessionFamilies[key]?.revokedAt == nil {
                    owned.accountSurface.sessionFamilies[key]?.revokedAt = now
                }
                owned.accountSurface.revokedFamilies.insert(key)
            }
        }
    }

    public var legalAcceptanceCount: Int { profiles.state.withLock { $0.legalAcceptances.count } }
    public var retirementReceiptCount: Int { profiles.state.withLock { $0.accountSurface.retirementReceipts.count } }

    public func stagingSelfAccountCapabilityHash(userId: String) -> String? {
        profiles.account(userId: userId)?.stagingSelfAccountCapabilityHash
    }

    public func retiredAt(userId: String) -> Date? {
        profiles.account(userId: userId)?.retiredAt
    }

    public func sessionCount(for userId: String) -> Int {
        profiles.accountState.sessions.values.filter { $0.userId == userId }.count
    }

    public func sessionFamilyRevokedAts(userId: String) -> [Date?] {
        profiles.accountState.sessionFamilies.values.filter { $0.userId == userId }.map(\.revokedAt)
    }

    public func hasAccount(email: String) -> Bool {
        profiles.accountState.accounts[AccountNaming.normalize(email)] != nil
    }

    public func legalAcceptance(userId: String) -> EmailLegalAcceptance? {
        profiles.legalAcceptance(userId: userId)
    }

    public func addSocialCompletion(
        provider: String, code: String, email: String, mode: String = "login",
        intendedAction: String = "login", returnTo: String = "/", userId: String? = nil,
        providerUserId: String? = nil, linkOnConflict: Bool = false
    ) {
        profiles.state.withLock { owned in
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
        profiles.accountState.linkedIdentities
            .filter { $0.userId == userId && $0.provider == provider }.map(\.providerUserId)
    }

    public func linkedProviderEmail(userId: String, provider: String) -> String? {
        profiles.accountState.linkedIdentities
            .first { $0.userId == userId && $0.provider == provider }?.providerEmail
    }

    public func refreshRotationReceipts() -> [RefreshRotationReceipt] {
        profiles.accountState.rotationReceipts.values.map {
            RefreshRotationReceipt(
                attemptId: $0.attemptId,
                installationId: $0.installationId,
                successorTokenCiphertext: $0.ciphertext
            )
        }
    }

    public func expireRefreshReceipts() {
        profiles.state.withLock { owned in
            for key in owned.accountSurface.rotationReceipts.keys {
                owned.accountSurface.rotationReceipts[key]?.expiresAt = Date(timeIntervalSinceNow: -1)
            }
        }
    }

    public func isEmailVerified(userId: String) -> Bool {
        profiles.isEmailVerified(userId: userId)
    }

    public func configureOAuthForTesting(_ update: (inout OAuthFlowsService.DeploymentConfiguration) -> Void) {
        profiles.state.withLock { state in
            if state.configSurface.oauthDeployment.socialAuthStateSecret.isEmpty {
                state.configSurface.oauthDeployment.socialAuthStateSecret = AuthJWTFixture.socialSigningSecret
            }
            update(&state.configSurface.oauthDeployment)
        }
    }

    public func configureAuthCoreForTesting(_ update: (inout AuthCoreService.DeploymentConfiguration) -> Void) {
        profiles.state.withLock { update(&$0.configSurface.authCoreDeployment) }
    }
}
