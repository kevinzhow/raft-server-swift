import Foundation

/// Domain failure for the two email-verification operations. The HTTP layer
/// owns the wire encoding; this type owns the status and published message.
public enum AuthVerificationFailure: Error, Equatable, Sendable {
    case missingToken
    case invalidOrExpiredToken
    case unauthenticated
    case invalidAccessToken
    case userNotFound
    case alreadyVerified
    case tooManyRequests
    case cooldown

    public var status: UInt {
        switch self {
        case .unauthenticated, .invalidAccessToken:
            401
        case .userNotFound:
            500
        case .tooManyRequests, .cooldown:
            429
        case .missingToken, .invalidOrExpiredToken, .alreadyVerified:
            400
        }
    }

    public var message: String {
        switch self {
        case .missingToken:
            "Token is required"
        case .invalidOrExpiredToken:
            "Invalid or expired verification token"
        case .unauthenticated:
            "Missing or invalid Authorization header"
        case .invalidAccessToken:
            "Invalid or expired token"
        case .userNotFound:
            "Failed to resend verification email"
        case .alreadyVerified:
            "Email is already verified"
        case .tooManyRequests:
            "Too many verification emails. Please try again later."
        case .cooldown:
            "Please wait before requesting another verification email."
        }
    }
}

/// Typed outcome of a verification operation. The success case names the
/// operation so the HTTP layer never infers a body from a bare boolean.
public enum AuthVerificationResult: Equatable, Sendable {
    case verified
    case sent
    case failure(AuthVerificationFailure)
}

/// Account facts the verification service needs from the session/account
/// directory. Kept as a protocol so the store-backed policy stays free of
/// HTTP and lock-owning code.
protocol AuthVerificationAccounts: Sendable {
    func accountExists(userId: String) -> Bool
    func isEmailVerified(userId: String) -> Bool
    func markEmailVerified(userId: String)
}

/// Store-backed email-verification policy.
///
/// `verifyEmail` spends a token and marks its owner verified. `resend` applies
/// the upstream order: unknown user, already verified, five-per-hour cap, then
/// the 60-second cooldown, before issuing a fresh 32-byte token.
struct AuthVerificationService: Sendable {
    private static let tokenLifetime: TimeInterval = 24 * 60 * 60
    private static let hourlyLimit = 5
    private static let cooldown: TimeInterval = 60

    private let store: AuthProfileStore
    private let accounts: any AuthVerificationAccounts
    private let now: @Sendable () -> Date
    private let makeToken: @Sendable () -> String
    private let hashToken: @Sendable (String) -> String

    init(
        store: AuthProfileStore,
        accounts: any AuthVerificationAccounts,
        now: @escaping @Sendable () -> Date = { Date() },
        makeToken: @escaping @Sendable () -> String,
        hashToken: @escaping @Sendable (String) -> String
    ) {
        self.store = store
        self.accounts = accounts
        self.now = now
        self.makeToken = makeToken
        self.hashToken = hashToken
    }

    func verifyEmail(token: String?) -> AuthVerificationResult {
        guard let token, !token.isEmpty else { return .failure(.missingToken) }
        guard let userId = store.consumeVerificationToken(tokenHash: hashToken(token), now: now()) else {
            return .failure(.invalidOrExpiredToken)
        }
        // The token proves ownership of the address even if the account row
        // vanished between issue and redemption; upstream still reports ok.
        if accounts.accountExists(userId: userId) {
            accounts.markEmailVerified(userId: userId)
        }
        return .verified
    }

    func resendVerificationEmail(userId: String) -> AuthVerificationResult {
        guard accounts.accountExists(userId: userId) else { return .failure(.userNotFound) }
        if accounts.isEmailVerified(userId: userId) { return .failure(.alreadyVerified) }

        let current = now()
        let recentIssued = store.recentVerificationTokensCount(
            userId: userId,
            since: current.addingTimeInterval(-60 * 60)
        )
        if recentIssued >= Self.hourlyLimit { return .failure(.tooManyRequests) }
        if recentIssued > 0,
           let latest = store.latestVerificationToken(userId: userId),
           current.timeIntervalSince(latest.createdAt) < Self.cooldown {
            return .failure(.cooldown)
        }

        let token = makeToken()
        store.issueVerificationToken(
            userId: userId,
            token: token,
            tokenHash: hashToken(token),
            now: current,
            ttl: Self.tokenLifetime
        )
        return .sent
    }
}
