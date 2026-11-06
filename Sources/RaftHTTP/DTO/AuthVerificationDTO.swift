import Foundation

/// `POST /api/auth/verify-email` request body. A malformed or empty body is
/// allowed to decode to `VerifyEmailRequest()` so the route can still answer
/// the upstream `Token is required` 400.
public struct VerifyEmailRequest: Codable, Sendable, Equatable {
    public var token: String?

    public init(token: String? = nil) {
        self.token = token
    }
}

/// The `{"ok":true}` body shared by the verification routes.
public struct OkResponse: Codable, Sendable, Equatable {
    public var ok: Bool

    public init(ok: Bool = true) {
        self.ok = ok
    }
}
