import Foundation
@testable import RaftHTTP

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
        profiles.state.withLock { owned in
            owned.accountSurface.accounts[normalized] = Account(
                id: id,
                email: normalized,
                passwordHash: AuthTokenCodec.sha256(password),
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
    public var emailVerificationCount: Int { profiles.state.withLock { $0.accountSurface.emailVerifications } }

    public func userId(forEmail email: String) -> String? {
        profiles.accountState.accounts[AccountNaming.normalize(email)]?.id
    }

    public func analyticsId(userId: String) -> String? {
        profiles.state.withLock { $0.accountSurface.analyticsIds[userId] }
    }

    public func passwordCredentialEstablished(userId: String) -> Bool {
        profiles.identitySnapshot(userId: userId).passwordConfigured
    }

    public func setAccountProfileForTesting(id: String, name: String, displayName: String? = nil) {
        profiles.state.withLock { owned in
            if let key = owned.accountSurface.accounts.first(where: { $0.value.id == id })?.key,
               var account = owned.accountSurface.accounts[key] {
                account.name = name
                account.displayName = displayName ?? name
                owned.accountSurface.accounts[key] = account
            }
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

    public func configureOAuthForTesting(_ update: (inout OAuthFlowsService.DeploymentConfiguration) -> Void) {
        profiles.state.withLock { update(&$0.configSurface.oauthDeployment) }
    }

    public func configureAuthCoreForTesting(_ update: (inout AuthCoreService.DeploymentConfiguration) -> Void) {
        profiles.state.withLock { update(&$0.configSurface.authCoreDeployment) }
    }
}
