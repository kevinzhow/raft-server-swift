import Foundation

/// `POST /api/auth/pending-link/cancel` request body.
///
/// The route decodes this and falls back to `CancelPendingLinkRequest()` on an
/// empty or malformed body, so cancel stays idempotent and always answers 204.
public struct CancelPendingLinkRequest: Codable, Sendable, Equatable {
    public var pendingLinkToken: String?

    public init(pendingLinkToken: String? = nil) {
        self.pendingLinkToken = pendingLinkToken
    }
}

/// `POST /api/auth/forgot-password` request body. Upstream treats a missing or
/// empty `email` as the only invalid shape; anything else answers the same
/// acceptance message so account existence never leaks.
public struct ForgotPasswordRequest: Codable, Sendable, Equatable {
    public var email: String?

    public init(email: String? = nil) {
        self.email = email
    }
}

/// The non-revealing `POST /api/auth/forgot-password` success body.
public struct ForgotPasswordResponse: Codable, Sendable, Equatable {
    public static let acceptedMessage =
        "If an account exists with that email, a reset link has been sent."

    public var ok: Bool
    public var message: String

    public init(ok: Bool = true, message: String = ForgotPasswordResponse.acceptedMessage) {
        self.ok = ok
        self.message = message
    }
}

/// `POST /api/auth/reset-password` request body. `newPassword` is accepted as an
/// alias shape the clients already send; only `token` and `password` select the
/// reset.
public struct ResetPasswordRequest: Codable, Sendable, Equatable {
    public var token: String?
    public var password: String?
    public var newPassword: String?

    public init(token: String? = nil, password: String? = nil, newPassword: String? = nil) {
        self.token = token
        self.password = password
        self.newPassword = newPassword
    }
}

/// `POST /api/auth/me/timezone-observation` request body.
///
/// The mounted route deliberately validates the raw `{"timezone": ...}` key set
/// before it stores anything; this type is the typed shape for callers that
/// already enforce the same single-key contract.
public struct TimezoneObservationRequest: Codable, Sendable, Equatable {
    public var timezone: String?

    public init(timezone: String? = nil) {
        self.timezone = timezone
    }
}
