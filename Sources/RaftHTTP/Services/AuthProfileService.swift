import Foundation

/// Domain failure shared by the account-profile operations. The HTTP layer
/// owns the wire encoding; this type owns the status and published message.
public enum AuthProfileFailure: Error, Equatable, Sendable {
    case emailRequired
    case missingResetCredentials
    case invalidOrExpiredResetToken

    public var status: UInt {
        switch self {
        case .emailRequired, .missingResetCredentials, .invalidOrExpiredResetToken:
            400
        }
    }

    public var message: String {
        switch self {
        case .emailRequired:
            "Email is required"
        case .missingResetCredentials:
            "token and password are required"
        case .invalidOrExpiredResetToken:
            "Invalid or expired reset token"
        }
    }
}

/// Typed outcome of `POST /api/auth/forgot-password`. `.accepted` is the
/// non-revealing 200 body; any failure is the upstream `400 {"error": ...}`.
public enum ForgotPasswordResult: Equatable, Sendable {
    case accepted(ForgotPasswordResponse)
    case failure(AuthProfileFailure)
}

/// Typed facade over the account-profile surface.
///
/// The directory extensions own the state transitions; this service accepts the
/// decoded DTOs so a route never hand-builds a JSON body, and it keeps the
/// upstream order and wording in one place.
public struct AuthProfileService: Sendable {
    public let emailAccounts: EmailLoginDirectory

    public init(emailAccounts: EmailLoginDirectory) {
        self.emailAccounts = emailAccounts
    }

    /// `POST /api/auth/forgot-password`. A missing or empty address is the only
    /// rejected shape. Every other address gets the same acceptance answer, and
    /// only a known account grows a reset token.
    public func forgotPassword(_ request: ForgotPasswordRequest) -> ForgotPasswordResult {
        guard let email = request.email, !email.isEmpty else { return .failure(.emailRequired) }
        emailAccounts.requestPasswordReset(email: email)
        return .accepted(ForgotPasswordResponse())
    }

    /// Convenience overload for callers that already hold the address.
    public func forgotPassword(email: String?) -> ForgotPasswordResult {
        forgotPassword(ForgotPasswordRequest(email: email))
    }

    /// `POST /api/auth/pending-link/cancel`. Always 204, including a second
    /// cancel and an unknown or absent token.
    public func cancelPendingLink(_ request: CancelPendingLinkRequest) -> HTTPReply {
        emailAccounts.cancelPendingSocialLink(token: request.pendingLinkToken)
    }

    /// `POST /api/auth/reset-password`. Re-encodes the typed request into the
    /// directory's existing body seam so the reset-and-session order stays the
    /// one the store already enforces.
    public func resetPassword(_ request: ResetPasswordRequest) -> HTTPReply {
        emailAccounts.resetPassword(body: Self.jsonBody(request))
    }

    /// `POST /api/auth/me/timezone-observation`. Delegates to the directory,
    /// which keeps the exact single-key `{"timezone": ...}` validation.
    public func observeTimezone(
        authorization: String?,
        _ request: TimezoneObservationRequest
    ) -> HTTPReply {
        emailAccounts.observeTimezone(authorization: authorization, body: Self.jsonBody(request))
    }

    private static func jsonBody(_ value: some Encodable) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
