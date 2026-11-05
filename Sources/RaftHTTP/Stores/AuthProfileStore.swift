import Foundation

/// One issued email-verification token.
///
/// `rawToken` is retained so the in-process acceptance seam can hand the token
/// back without an email transport; no HTTP handler ever exposes it.
struct EmailVerificationRecord: Sendable, Equatable {
    public let userId: String
    public let tokenHash: String
    public let rawToken: String
    public let createdAt: Date
    public let expiresAt: Date
}

/// Owns account-profile ledgers: linked identities, password-reset tokens,
/// email-verification tokens and legal acceptances. HTTP/session/account
/// decisions stay in `EmailLoginDirectory`; this store serializes only its own
/// rows and returns strong Swift values, never JSON or `HTTPReply`.
final class AuthProfileStore: @unchecked Sendable {
    private let lock = NSLock()
    private var identityRows: [String: [(provider: String, providerEmail: String)]] = [:]
    private var passwordResetTokens: [String: (userId: String, expiresAt: Date)] = [:]
    private var legalAcceptances: [String: EmailLegalAcceptance] = [:]
    /// Live tokens keyed by user id. `issueVerificationToken` replaces the
    /// user's set, which is the upstream insert-after-delete behavior.
    private var emailVerificationTokens: [String: [EmailVerificationRecord]] = [:]
    /// Issue history per user. It survives token replacement so the resend
    /// rate limit can count sends from the last hour even after old rows go.
    private var emailVerificationIssueDates: [String: [Date]] = [:]

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

    // MARK: - Email verification

    /// Replaces every live verification token for `userId` with one fresh
    /// record and records the issue time for the hourly rate limit.
    func issueVerificationToken(
        userId: String,
        token: String,
        tokenHash: String,
        now: Date = Date(),
        ttl: TimeInterval = 24 * 60 * 60
    ) {
        let record = EmailVerificationRecord(
            userId: userId,
            tokenHash: tokenHash,
            rawToken: token,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
        lock.lock()
        emailVerificationTokens[userId] = [record]
        emailVerificationIssueDates[userId, default: []].append(now)
        lock.unlock()
    }

    /// Spends one token. An unknown hash returns `nil`. An expired token is
    /// removed and returns `nil`. A valid token removes every verification
    /// token for its owner and returns the owner id.
    func consumeVerificationToken(tokenHash: String, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let userId = emailVerificationTokens.first(where: { _, records in
            records.contains { $0.tokenHash == tokenHash }
        })?.key,
            let record = emailVerificationTokens[userId]?.first(where: { $0.tokenHash == tokenHash })
        else { return nil }
        guard record.expiresAt >= now else {
            emailVerificationTokens[userId]?.removeAll { $0.tokenHash == tokenHash }
            if emailVerificationTokens[userId]?.isEmpty == true {
                emailVerificationTokens.removeValue(forKey: userId)
            }
            return nil
        }
        emailVerificationTokens.removeValue(forKey: userId)
        return userId
    }

    /// The most recently issued live token for inspection and cooldown checks.
    func latestVerificationToken(userId: String) -> EmailVerificationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return emailVerificationTokens[userId]?.max { $0.createdAt < $1.createdAt }
    }

    /// How many verification tokens were issued for `userId` at or after
    /// `since`, including tokens that have since been replaced or consumed.
    func recentVerificationTokensCount(userId: String, since: Date) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return emailVerificationIssueDates[userId]?.filter { $0 >= since }.count ?? 0
    }
}
