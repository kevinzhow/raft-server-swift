import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func mintAccessTokenForTesting(userId: String) -> String {
        authProfileStore.openSession(userId: userId).accessToken
    }

    public func addAuthIdentityForTesting(userId: String, provider: String, providerEmail: String) {
        authProfileStore.appendIdentity(userId: userId, provider: provider, providerEmail: providerEmail)
    }

    public func addPasswordResetTokenForTesting(userId: String, token: String, expiresAt: Date) {
        authProfileStore.setResetToken(hash: AuthTokenCodec.sha256(token), userId: userId, expiresAt: expiresAt)
    }

    public func expireAppLoginRequestForTesting(requestId: String) {
        authProfileStore.state.withLock { owned in
            owned.accountSurface.appLoginRequests[requestId]?.expiresAt = Date().addingTimeInterval(-1)
        }
    }

    public func authIdentityCount(userId: String) -> Int {
        authProfileStore.identityCount(userId: userId)
    }

    public func passwordCredentialEstablished(userId: String) -> Bool {
        authProfileStore.identitySnapshot(userId: userId).passwordConfigured
    }
}
