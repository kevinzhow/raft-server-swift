import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func mintAccessTokenForTesting(userId: String) -> String {
        authProfileStore.openSession(userId: userId).accessToken
    }

    public func addAuthIdentityForTesting(userId: String, provider: String, providerEmail: String) {
        lock.lock()
        authProfileStore.appendIdentity(userId: userId, provider: provider, providerEmail: providerEmail)
        lock.unlock()
    }

    public func addPasswordResetTokenForTesting(userId: String, token: String, expiresAt: Date) {
        lock.lock()
        authProfileStore.setResetToken(hash: Self.sha256(token), userId: userId, expiresAt: expiresAt)
        lock.unlock()
    }

    public func expireAppLoginRequestForTesting(requestId: String) {
        var state = authProfileStore.accountState
        state.appLoginRequests[requestId]?.expiresAt = Date().addingTimeInterval(-1)
        authProfileStore.accountState = state
    }

    public func authIdentityCount(userId: String) -> Int {
        authProfileStore.identityCount(userId: userId)
    }

    public func passwordCredentialEstablished(userId: String) -> Bool {
        authProfileStore.identitySnapshot(userId: userId).passwordConfigured
    }
}
