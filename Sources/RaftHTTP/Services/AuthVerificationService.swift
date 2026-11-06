import Foundation

/// Domain failure for the two email-verification operations. The feature layer
/// owns the wire encoding; this type owns the status and published message.
public enum AuthVerificationError: DomainError, Equatable {
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

    public var errorMessage: String {
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

/// Store-backed email-verification policy.
///
/// `verifyEmail` spends a token and marks its owner verified. `resend` applies
/// the upstream order: unknown user, already verified, five-per-hour cap, then
/// the 60-second cooldown, before issuing a fresh 32-byte token. The service
/// returns the published DTO or throws `AuthVerificationError`; it never builds
/// a reply, JSON or header set.
public struct AuthVerificationService: Sendable {
    private static let tokenLifetime: TimeInterval = 24 * 60 * 60
    private static let hourlyLimit = 5
    private static let cooldown: TimeInterval = 60

    private let store: AuthProfileStore
    private let now: @Sendable () -> Date
    private let makeToken: @Sendable () -> String
    private let hashToken: @Sendable (String) -> String

    init(
        store: AuthProfileStore,
        now: @escaping @Sendable () -> Date = { Date() },
        makeToken: @escaping @Sendable () -> String = { EmailLoginDirectory.randomHex(32) },
        hashToken: @escaping @Sendable (String) -> String = { EmailLoginDirectory.sha256($0) }
    ) {
        self.store = store
        self.now = now
        self.makeToken = makeToken
        self.hashToken = hashToken
    }

    /// `POST /api/auth/verify-email`. Spends a token and marks its owner verified.
    public func verifyEmail(token: String?) throws -> OkResponse {
        guard let token, !token.isEmpty else { throw AuthVerificationError.missingToken }
        guard let userId = store.consumeVerificationToken(tokenHash: hashToken(token), now: now()) else {
            throw AuthVerificationError.invalidOrExpiredToken
        }
        // The token proves ownership of the address even if the account row
        // vanished between issue and redemption; upstream still reports ok.
        if store.accountExists(userId: userId) {
            store.markEmailVerified(userId: userId)
        }
        return OkResponse()
    }

    /// `POST /api/auth/resend-verification`. `requireAuth` runs before the
    /// resend policy, so a missing or expired session is 401 and writes nothing.
    public func resendVerificationEmail(authorization: String?) throws -> OkResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AuthVerificationError.unauthenticated
        }
        let accessToken = String(authorization.dropFirst("Bearer ".count))
        guard let userId = store.userId(forAccessToken: accessToken) else {
            throw AuthVerificationError.invalidAccessToken
        }
        guard store.accountExists(userId: userId) else { throw AuthVerificationError.userNotFound }
        if store.isEmailVerified(userId: userId) { throw AuthVerificationError.alreadyVerified }

        let current = now()
        let token = makeToken()
        switch store.issueVerificationTokenIfAllowed(
            userId: userId,
            token: token,
            tokenHash: hashToken(token),
            now: current,
            ttl: Self.tokenLifetime,
            hourlyLimit: Self.hourlyLimit,
            cooldown: Self.cooldown
        ) {
        case .issued:
            return OkResponse()
        case .tooManyRequests:
            throw AuthVerificationError.tooManyRequests
        case .cooldown:
            throw AuthVerificationError.cooldown
        }
    }
}
