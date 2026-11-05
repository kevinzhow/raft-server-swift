import Foundation

/// Owns account-profile ledgers: linked identities, password-reset tokens and
/// legal acceptances. HTTP/session/account decisions stay in
/// `EmailLoginDirectory`; this store serializes only its own rows.
final class AuthProfileStore: @unchecked Sendable {
    private let lock = NSLock()
    private var identityRows: [String: [(provider: String, providerEmail: String)]] = [:]
    private var passwordResetTokens: [String: (userId: String, expiresAt: Date)] = [:]
    private var legalAcceptances: [String: EmailLegalAcceptance] = [:]

    func identities(userId: String) -> [(provider: String, providerEmail: String)] {
        lock.lock()
        defer { lock.unlock() }
        return identityRows[userId] ?? []
    }

    func replaceIdentities(userId: String, rows: [(provider: String, providerEmail: String)]) {
        lock.lock()
        identityRows[userId] = rows
        lock.unlock()
    }

    func appendIdentity(userId: String, provider: String, providerEmail: String) {
        lock.lock()
        identityRows[userId, default: []].append((provider, providerEmail))
        lock.unlock()
    }

    func identityCount(userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return identityRows[userId]?.count ?? 0
    }

    func resetToken(hash: String) -> (userId: String, expiresAt: Date)? {
        lock.lock()
        defer { lock.unlock() }
        return passwordResetTokens[hash]
    }

    func removeResetToken(hash: String) {
        lock.lock()
        passwordResetTokens.removeValue(forKey: hash)
        lock.unlock()
    }

    func setResetToken(hash: String, userId: String, expiresAt: Date) {
        lock.lock()
        passwordResetTokens[hash] = (userId, expiresAt)
        lock.unlock()
    }

    var legalAcceptanceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return legalAcceptances.count
    }

    func legalAcceptance(userId: String) -> EmailLegalAcceptance? {
        lock.lock()
        defer { lock.unlock() }
        return legalAcceptances[userId]
    }

    func setLegalAcceptance(_ acceptance: EmailLegalAcceptance, userId: String) {
        lock.lock()
        legalAcceptances[userId] = acceptance
        lock.unlock()
    }
}
