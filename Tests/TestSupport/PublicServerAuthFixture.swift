import Foundation
@testable import RaftHTTP

/// Bind standalone route fixtures' existing token strings to real verified
/// profile accounts and live session families on the Root passed to the app.
/// Directory-owned role/visibility data and all request tokens stay unchanged.
public func publicServerAuthAccounts(
    _ principals: [(userId: String, token: String)],
    emails: [String: String] = [:]
) -> EmailLoginDirectory {
    let accounts = EmailLoginDirectory()
    var seeded: Set<String> = []
    for (userId, token) in principals {
        if seeded.insert(userId).inserted {
            accounts.addAccount(id: userId, email: emails[userId] ?? "public-\(userId)@example.com", password: "password123")
            accounts.markEmailVerified(userId: userId)
        }
        let session = accounts.authProfileStore.openSession(userId: userId)
        accounts.authProfileStore.state.withLock { owned in
            // Keep the actual refresh row and family created by openSession;
            // only rename its access token to the fixture's published input.
            guard let family = owned.accountSurface.accessTokenFamilies.removeValue(forKey: session.accessToken) else {
                preconditionFailure("Opened fixture session has no family")
            }
            owned.accountSurface.accessTokens.removeValue(forKey: session.accessToken)
            owned.accountSurface.accessTokens[token] = userId
            owned.accountSurface.accessTokenFamilies[token] = family
        }
    }
    return accounts
}
