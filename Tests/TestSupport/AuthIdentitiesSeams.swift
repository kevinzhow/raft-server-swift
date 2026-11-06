import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func mintAccessTokenForTesting(userId: String) -> String {
        lock.lock()
        let token = openSessionLocked(userId: userId).accessToken
        lock.unlock()
        return token
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
        lock.lock()
        appLoginRequests[requestId]?.expiresAt = Date().addingTimeInterval(-1)
        lock.unlock()
    }
}
