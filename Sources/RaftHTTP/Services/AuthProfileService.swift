import Foundation
import RaftShared

/// One account's retained first final onboarding handoff facts.
///
/// Upstream `serverService.markSetupHandoffAcknowledged` writes
/// `users.first_onboarding_completed_at` and
/// `users.first_onboarding_completed_session_family_id` only while the time is
/// null (`services/serverService.ts:1556-1570`), so a retry keeps the original
/// pair. The facts are account-global and are not part of the published `me`
/// user object (`services/userService.ts:54-96`).
public struct FirstOnboardingCompletion: Sendable, Equatable {
    public let completedAt: Date
    public let sessionFamilyId: String?

    public init(completedAt: Date, sessionFamilyId: String?) {
        self.completedAt = completedAt
        self.sessionFamilyId = sessionFamilyId
    }
}

/// Domain failure shared by the account-profile operations. The feature layer
/// owns the wire encoding; this type owns the status and published message.
public enum AuthProfileError: DomainError, Equatable {
    case emailRequired
    case missingResetCredentials
    case resetPasswordTooShort
    case invalidOrExpiredResetToken
    case unauthenticated
    case invalidTimezoneObservationBody([AuthRequestIssue])
    case timezoneEmpty
    case timezoneTooLong
    case timezoneNotIana
    case timezoneNotCanonical
    case observationNotStored

    public var status: UInt {
        switch self {
        case .unauthenticated:
            401
        case .observationNotStored:
            500
        case .emailRequired, .missingResetCredentials, .resetPasswordTooShort,
             .invalidOrExpiredResetToken, .invalidTimezoneObservationBody,
             .timezoneEmpty, .timezoneTooLong, .timezoneNotIana, .timezoneNotCanonical:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .emailRequired:
            "Email is required"
        case .missingResetCredentials:
            "Token and password are required"
        case .resetPasswordTooShort:
            "Password must be at least 8 characters"
        case .invalidOrExpiredResetToken:
            "Invalid or expired reset token"
        case .unauthenticated:
            "Unauthorized"
        case .invalidTimezoneObservationBody:
            "Invalid timezone observation body"
        case .timezoneEmpty:
            "timezone must be a non-empty IANA timezone"
        case .timezoneTooLong:
            "timezone must be at most 128 characters"
        case .timezoneNotIana:
            "timezone must be an IANA timezone"
        case .timezoneNotCanonical:
            "timezone must be a canonical IANA timezone"
        case .observationNotStored:
            "Timezone observation not stored"
        }
    }

    public var errorCode: String? {
        switch self {
        case .invalidTimezoneObservationBody: "timezone_observation_body_invalid"
        default: nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .invalidTimezoneObservationBody(let issues):
            // Pinned `routes/auth.ts:1370-1376` publishes `error`, `code`,
            // then `issues`.
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "timezone_observation_body_invalid"),
                OrderedJSONField("issues", .array(issues.map(\.json))),
            ])
        default:
            return nil
        }
    }
}

/// Store-backed account-profile operations.
///
/// `forgotPassword` mints a reset token for a known address without revealing
/// whether it exists. `cancelPendingLink` is the idempotent 204. `resetPassword`
/// spends one reset token and writes the new password in one store critical
/// section. `observeTimezone` validates the single-key IANA shape and stores the
/// first/last pair in one store critical section. `recordFirstOnboardingCompletion`
/// retains the account-global first handoff pair, writing it only once. The
/// service returns the published DTO or throws `AuthProfileError`; it never
/// builds a reply, JSON or header set.
public struct AuthProfileService: Sendable {
    private static let resetTokenLifetime: TimeInterval = 60 * 60
    private static let maximumTimezoneLength = 128

    private let store: AuthProfileStore
    private let now: @Sendable () -> Date
    private let makeToken: @Sendable () -> String
    private let hashToken: @Sendable (String) -> String
    private let hashPassword: @Sendable (String) throws -> String
    private let transactionalEmail: TransactionalEmailIntentPort

    init(
        store: AuthProfileStore,
        now: @escaping @Sendable () -> Date = { Date() },
        makeToken: @escaping @Sendable () -> String = { AuthTokenCodec.randomHex(32) },
        hashToken: @escaping @Sendable (String) -> String = { AuthTokenCodec.sha256($0) },
        hashPassword: @escaping @Sendable (String) throws -> String = { try PasswordCredential.hash($0) },
        transactionalEmail: TransactionalEmailIntentPort = .developmentOnly
    ) {
        self.store = store
        self.now = now
        self.makeToken = makeToken
        self.hashToken = hashToken
        self.hashPassword = hashPassword
        self.transactionalEmail = transactionalEmail
    }

    public func bindingTransactionalEmail(_ port: TransactionalEmailIntentPort) -> Self {
        Self(
            store: store, now: now, makeToken: makeToken, hashToken: hashToken,
            hashPassword: hashPassword, transactionalEmail: port
        )
    }

    /// `POST /api/auth/forgot-password`. A missing or empty address is the only
    /// rejected shape. Every other address gets the same acceptance answer, and
    /// only a known account grows a reset token.
    public func forgotPassword(_ request: ForgotPasswordRequest) throws -> ForgotPasswordResponse {
        guard let email = request.email, !email.isEmpty else {
            throw AuthProfileError.emailRequired
        }
        try transactionalEmail.requireReady(in: store.state.domain)
        let token = makeToken()
        let tokenHash = hashToken(token)
        let current = now()
        // The raw token is retained until its typed intent has been staged.
        // Unknown addresses still insert nothing and return the same response.
        let recipient = store.transactionalEmailRecipient(email: email)
        let inserted = store.insertResetTokenIfAccountExists(
            email: email,
            tokenHash: tokenHash,
            now: current,
            ttl: Self.resetTokenLifetime
        )
        if inserted {
            guard let recipient else { throw TransactionalEmailError.durableOutboxUnavailable }
            try transactionalEmail.passwordReset(
                recipientEmail: recipient.email, name: recipient.name,
                rawToken: token, issuedAt: current
            )
        }
        return ForgotPasswordResponse()
    }

    /// `POST /api/auth/pending-link/cancel` for a token the route already
    /// checked. Always 204, including a second cancel and an unknown token.
    public func cancelPendingLink(_ request: CancelPendingLinkRequest) -> NoContentResponse {
        if let token = request.pendingLinkToken {
            store.markPendingSocialLinkCancelled(token: token)
        }
        return NoContentResponse()
    }

    /// `POST /api/auth/reset-password`. The token consume and the password write
    /// are one store critical section, so only one concurrent request wins.
    public func resetPassword(_ request: ResetPasswordRequest) throws -> OkResponse {
        let input = try resetInput(request)
        _ = try finishReset(input.candidate, tokenHash: input.tokenHash, encoded: hashPassword(input.password))
        return OkResponse()
    }

    public func resetPasswordAsync(
        _ request: ResetPasswordRequest,
        onSessionsRevoked: @escaping @Sendable (PasswordSessionRevocation) -> Void
    ) async throws -> OkResponse {
        let input = try resetInput(request)
        let hasher = hashPassword
        let encoded = try await PasswordWork.run { try hasher(input.password) }
        let revocation = try finishReset(input.candidate, tokenHash: input.tokenHash, encoded: encoded)
        DeferredEffects.emit(in: store.state.domain) { onSessionsRevoked(revocation) }
        return OkResponse()
    }

    private func resetInput(_ request: ResetPasswordRequest) throws -> (candidate: PasswordCredentialCandidate, tokenHash: String, password: String) {
        guard let token = request.token, !token.isEmpty,
              let password = request.password, !password.isEmpty else { throw AuthProfileError.missingResetCredentials }
        // Pinned `routes/auth.ts:1776-1779`: the eight-character floor runs
        // before the token is looked up, so an unknown token with a short
        // password is the password refusal.
        guard password.utf16.count >= 8 else { throw AuthProfileError.resetPasswordTooShort }
        let tokenHash = hashToken(token)
        guard let candidate = store.resetPasswordCandidate(tokenHash: tokenHash, now: now()) else {
            throw AuthProfileError.invalidOrExpiredResetToken
        }
        return (candidate, tokenHash, password)
    }

    private func finishReset(_ candidate: PasswordCredentialCandidate, tokenHash: String, encoded: String) throws -> PasswordSessionRevocation {
        guard let revocation = store.commitPasswordReset(candidate: candidate, tokenHash: tokenHash, newHash: encoded, now: now()) else {
            throw AuthProfileError.invalidOrExpiredResetToken
        }
        return revocation
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
        // Pinned `routes/auth.ts:1406-1413`: the strict schema runs before the
        // zone value is parsed, and its failures publish an issue list.
        guard request.issues.isEmpty else {
            throw AuthProfileError.invalidTimezoneObservationBody(request.issues)
        }
        guard let raw = request.timezone else {
            throw AuthProfileError.timezoneEmpty
        }
        // Pinned `lib/ianaTimezone.ts` `parseCanonicalBrowserTimezone`: trim
        // and non-empty, length, Intl validity, then the Area/Location shape
        // and the resolved canonical shape. Each failure has its own sentence.
        let timezone = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !timezone.isEmpty else {
            throw AuthProfileError.timezoneEmpty
        }
        guard timezone.utf16.count <= Self.maximumTimezoneLength else {
            throw AuthProfileError.timezoneTooLong
        }
        guard let resolved = Self.resolveBrowserTimezone(timezone) else {
            throw AuthProfileError.timezoneNotIana
        }
        guard timezone == "UTC" || timezone.contains("/") else {
            throw AuthProfileError.timezoneNotCanonical
        }
        guard resolved == "UTC" || resolved.contains("/") else {
            throw AuthProfileError.timezoneNotCanonical
        }
        let canonicalTimezone = Self.canonicalBrowserTimezone(resolved)
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

    /// The ICU `resolvedOptions().timeZone` shape for an Intl-accepted id.
    ///
    /// Foundation's `TimeZone(identifier:)` also accepts strings Node's Intl
    /// rejects (`UTC+0`), so no-slash values go through the abbreviation map
    /// first and offset spellings are accepted explicitly. The caller applies
    /// the raw canonical-shape check afterwards, which rejects every no-slash
    /// value except `UTC`.
    private static func resolveBrowserTimezone(_ timezone: String) -> String? {
        if timezone == "UTC" { return "UTC" }
        if timezone.contains("/") {
            return TimeZone(identifier: timezone)?.identifier
        }
        if timezone.range(of: #"^[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil {
            return timezone
        }
        // Foundation accepts `UTC+0` as an identifier; Intl does not.
        if timezone.hasPrefix("UTC") { return nil }
        if let zone = TimeZone(abbreviation: timezone) {
            return zone.identifier
        }
        return TimeZone(identifier: timezone)?.identifier
    }

    /// The zones ICU's canonical id differs from Foundation's alias.
    ///
    /// Foundation on this platform does not canonicalize `TimeZone(identifier:)`
    /// (it returns the input id), so this stays a finite table; see
    /// `docs/DEVIATIONS.md#d24` for the residual and the re-evaluate trigger.
    private static func canonicalBrowserTimezone(_ resolved: String) -> String {
        switch resolved {
        case "Etc/UTC", "Etc/GMT", "Etc/UCT", "Etc/GMT+0", "Etc/GMT-0",
             "Etc/GMT0", "Etc/Universal", "Etc/Zulu":
            return "UTC"
        case "Asia/Kolkata":
            return "Asia/Calcutta"
        default:
            return AccountNaming.timezoneAliases[resolved] ?? resolved
        }
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

    // MARK: First onboarding completion

    /// The account-global first final onboarding handoff call site for domains
    /// that do not own the auth store (for example `POST
    /// /api/servers/:id/setup-handoff`). Only the first call writes; a retry
    /// returns the retained time and session family unchanged. `nil` means the
    /// account row no longer exists.
    ///
    /// The caller passes the command's real time and the access token's session
    /// family, or `nil` when the request has no real family. This is not
    /// briefing delivery acceptance.
    @discardableResult
    public func recordFirstOnboardingCompletion(
        userId: String,
        at: Date,
        sessionFamilyId: String?
    ) -> FirstOnboardingCompletion? {
        store.recordFirstOnboardingCompletion(userId: userId, at: at, sessionFamilyId: sessionFamilyId)
            .map { FirstOnboardingCompletion(completedAt: $0.completedAt, sessionFamilyId: $0.sessionFamilyId) }
    }

    /// The retained first-onboarding pair, or `nil` when the account is missing
    /// or has not completed onboarding.
    public func firstOnboardingCompletion(userId: String) -> FirstOnboardingCompletion? {
        store.firstOnboardingCompletion(userId: userId)
            .map { FirstOnboardingCompletion(completedAt: $0.completedAt, sessionFamilyId: $0.sessionFamilyId) }
    }
}
