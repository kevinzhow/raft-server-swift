import Foundation

/// Domain failure shared by the account-profile operations. The feature layer
/// owns the wire encoding; this type owns the status and published message.
public enum AuthProfileError: DomainError, Equatable {
    case emailRequired
    case missingResetCredentials
    case invalidOrExpiredResetToken
    case unauthenticated
    case invalidTimezoneObservation
    case observationNotStored

    public var status: UInt {
        switch self {
        case .unauthenticated:
            401
        case .observationNotStored:
            500
        case .emailRequired, .missingResetCredentials, .invalidOrExpiredResetToken,
             .invalidTimezoneObservation:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .emailRequired:
            "Email is required"
        case .missingResetCredentials:
            "token and password are required"
        case .invalidOrExpiredResetToken:
            "Invalid or expired reset token"
        case .unauthenticated:
            "Unauthorized"
        case .invalidTimezoneObservation:
            "Invalid timezone observation"
        case .observationNotStored:
            "Timezone observation not stored"
        }
    }
}

/// Store-backed account-profile operations.
///
/// `forgotPassword` mints a reset token for a known address without revealing
/// whether it exists. `cancelPendingLink` is the idempotent 204. `resetPassword`
/// spends one reset token and writes the new password in one store critical
/// section. `observeTimezone` validates the single-key IANA shape and stores the
/// first/last pair in one store critical section. The service returns the
/// published DTO or throws `AuthProfileError`; it never builds a reply, JSON or
/// header set.
public struct AuthProfileService: Sendable {
    private static let resetTokenLifetime: TimeInterval = 60 * 60
    private static let maximumTimezoneLength = 128

    private let store: AuthProfileStore
    private let now: @Sendable () -> Date
    private let makeToken: @Sendable () -> String
    private let hashToken: @Sendable (String) -> String
    private let hashPassword: @Sendable (String) -> String

    init(
        store: AuthProfileStore,
        now: @escaping @Sendable () -> Date = { Date() },
        makeToken: @escaping @Sendable () -> String = { AuthTokenCodec.randomHex(32) },
        hashToken: @escaping @Sendable (String) -> String = { AuthTokenCodec.sha256($0) },
        hashPassword: @escaping @Sendable (String) -> String = { AuthTokenCodec.sha256($0) }
    ) {
        self.store = store
        self.now = now
        self.makeToken = makeToken
        self.hashToken = hashToken
        self.hashPassword = hashPassword
    }

    /// `POST /api/auth/forgot-password`. A missing or empty address is the only
    /// rejected shape. Every other address gets the same acceptance answer, and
    /// only a known account grows a reset token.
    public func forgotPassword(_ request: ForgotPasswordRequest) throws -> ForgotPasswordResponse {
        guard let email = request.email, !email.isEmpty else {
            throw AuthProfileError.emailRequired
        }
        store.insertResetTokenIfAccountExists(
            email: email,
            tokenHash: hashToken(makeToken()),
            now: now(),
            ttl: Self.resetTokenLifetime
        )
        return ForgotPasswordResponse()
    }

    /// `POST /api/auth/pending-link/cancel`. Always 204, including a second
    /// cancel and an unknown or absent token.
    public func cancelPendingLink(_ request: CancelPendingLinkRequest) -> NoContentResponse {
        if let token = request.pendingLinkToken {
            store.markPendingSocialLinkCancelled(token: token)
        }
        return NoContentResponse()
    }

    /// `POST /api/auth/reset-password`. The token consume and the password write
    /// are one store critical section, so only one concurrent request wins.
    public func resetPassword(_ request: ResetPasswordRequest) throws -> OkResponse {
        guard let token = request.token, !token.isEmpty,
              let password = request.password, !password.isEmpty
        else {
            throw AuthProfileError.missingResetCredentials
        }
        switch store.consumeResetToken(
            tokenHash: hashToken(token),
            passwordHash: hashPassword(password),
            now: now()
        ) {
        case .reset:
            return OkResponse()
        case .invalidOrExpiredToken:
            throw AuthProfileError.invalidOrExpiredResetToken
        }
    }

    /// `POST /api/auth/me/timezone-observation`. Authentication runs before the
    /// body policy, so an expired session is 401 and writes nothing.
    public func observeTimezone(
        authorization: String?,
        _ request: TimezoneObservationRequest
    ) throws -> TimezoneObservationResponse {
        guard let userId = userId(authorization: authorization) else {
            throw AuthProfileError.unauthenticated
        }
        guard let raw = request.timezone else {
            throw AuthProfileError.invalidTimezoneObservation
        }
        let timezone = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !timezone.isEmpty,
              timezone.count <= Self.maximumTimezoneLength,
              timezone == "UTC" || timezone.contains("/"),
              let zone = TimeZone(identifier: timezone)
        else {
            throw AuthProfileError.invalidTimezoneObservation
        }
        let canonicalTimezone = AccountNaming.timezoneAliases[timezone] ?? zone.identifier
        let observation = store.recordTimezoneObservation(
            userId: userId,
            timezone: canonicalTimezone,
            now: now()
        )
        return TimezoneObservationResponse(
            firstObservedTimezone: observation.firstTimezone,
            firstObservedTimezoneAt: Self.timestamp(observation.firstAt),
            lastObservedTimezone: observation.lastTimezone,
            lastObservedTimezoneAt: Self.timestamp(observation.lastAt)
        )
    }

    /// The user behind a normal access token, matching the `requireAuth` check
    /// the route used before the migration.
    private func userId(authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return store.userId(forAccessToken: token)
    }

    /// The published timestamp shape: ISO-8601 with fractional seconds.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
