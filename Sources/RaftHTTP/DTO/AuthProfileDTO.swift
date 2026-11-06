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

// MARK: - Phase 5 typed request bodies (Batch A)

/// A published JSON request body that already has a typed model.
///
/// The directory keeps its raw-body parser because that parser publishes the
/// upstream `issues` list for every malformed shape. `encodedBody()` hands the
/// parser back the canonical JSON for the shape that was just decoded, so the
/// typed route and the raw fallback read exactly the same keys.
protocol AuthRequestDTO: Codable, Sendable, Equatable {
    func encodedBody() -> String
}

extension AuthRequestDTO {
    func encodedBody() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `POST /api/auth/login`.
///
/// `email` and `password` are required strings. A body with any other shape
/// (missing key, JSON `null`, or a non-string value) fails to decode, and the
/// route keeps the directory's raw parser so the published issue list is
/// unchanged. `pendingLinkToken` is read with `as? String` upstream, so `null`
/// and an absent key already mean the same thing there.
public struct LoginRequestDTO: Codable, Sendable, Equatable, AuthRequestDTO {
    public var email: String
    public var password: String
    public var pendingLinkToken: String?

    public init(email: String, password: String, pendingLinkToken: String? = nil) {
        self.email = email
        self.password = password
        self.pendingLinkToken = pendingLinkToken
    }
}

/// `POST /api/auth/refresh`.
///
/// `refreshToken` is the only body field; the replay-binding attempt and
/// installation identifiers travel in headers.
public struct RefreshRequestDTO: Codable, Sendable, Equatable, AuthRequestDTO {
    public var refreshToken: String

    public init(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}

/// `POST /api/auth/logout`.
///
/// Upstream answers `{"ok":true}` even when the body carries no usable token,
/// so a body that does not decode keeps the raw path and its 200.
public struct LogoutRequestDTO: Codable, Sendable, Equatable, AuthRequestDTO {
    public var refreshToken: String

    public init(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}

/// `POST /api/auth/device/authorize`.
///
/// `clientName` is optional. The directory accepts a JSON `null` for it and
/// caps a string at 200 characters; a non-string value keeps the raw path and
/// its `client_name_invalid` reply.
public struct DeviceAuthorizeRequestDTO: Codable, Sendable, Equatable, AuthRequestDTO {
    public var clientName: String?

    public init(clientName: String? = nil) {
        self.clientName = clientName
    }
}

/// `POST /api/auth/device/approve`.
///
/// `approve` is tri-state upstream: an absent key approves, `true` approves and
/// `false` denies. An explicit JSON `null` reads as deny there because the raw
/// parser tests `object["approve"] == nil` before the `as? Bool` cast, so this
/// DTO refuses `null` and lets the route fall back to the raw parser.
public struct DeviceApproveRequestDTO: Codable, Sendable, Equatable, AuthRequestDTO {
    public var userCode: String
    public var approve: Bool?

    enum CodingKeys: String, CodingKey {
        case userCode
        case approve
    }

    public init(userCode: String, approve: Bool? = nil) {
        self.userCode = userCode
        self.approve = approve
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.userCode = try container.decode(String.self, forKey: .userCode)
        if container.contains(.approve), try container.decodeNil(forKey: .approve) {
            throw DecodingError.dataCorruptedError(
                forKey: .approve,
                in: container,
                debugDescription: "approve must be a boolean when present"
            )
        }
        self.approve = try container.decodeIfPresent(Bool.self, forKey: .approve)
    }
}

/// `POST /api/auth/device/token`.
public struct DeviceTokenPollRequestDTO: Codable, Sendable, Equatable, AuthRequestDTO {
    public var deviceCode: String

    public init(deviceCode: String) {
        self.deviceCode = deviceCode
    }
}

/// `POST /api/auth/app-login/start`.
///
/// `returnUri` and `codeChallenge` are required strings; `codeChallengeMethod`
/// is read with `as? String` upstream, so `null` and an absent key already mean
/// the same thing there.
public struct AppLoginStartRequestDTO: Codable, Sendable, Equatable, AuthRequestDTO {
    public var returnUri: String
    public var codeChallenge: String
    public var codeChallengeMethod: String?

    public init(returnUri: String, codeChallenge: String, codeChallengeMethod: String? = nil) {
        self.returnUri = returnUri
        self.codeChallenge = codeChallenge
        self.codeChallengeMethod = codeChallengeMethod
    }
}

/// `POST /api/auth/app-login/complete`.
public struct AppLoginCompleteRequestDTO: Codable, Sendable, Equatable, AuthRequestDTO {
    public var code: String
    public var codeVerifier: String

    public init(code: String, codeVerifier: String) {
        self.code = code
        self.codeVerifier = codeVerifier
    }
}

/// `POST /api/oauth/installations/lookup`.
///
/// The ledger reads `client_id`, `client_secret` and either `server_id` or its
/// `serverId` alias. Every field is read with `as? String`, so a `null` and an
/// absent key are interchangeable; encoding always normalizes the alias back to
/// `server_id`.
public struct OAuthInstallationLookupDTO: Codable, Sendable, Equatable, AuthRequestDTO {
    public var clientId: String?
    public var clientSecret: String?
    public var serverId: String?

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case serverId = "server_id"
        case serverIdAlias = "serverId"
    }

    public init(clientId: String? = nil, clientSecret: String? = nil, serverId: String? = nil) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.serverId = serverId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.clientId = try container.decodeIfPresent(String.self, forKey: .clientId)
        self.clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret)
        self.serverId = try container.decodeIfPresent(String.self, forKey: .serverId)
            ?? container.decodeIfPresent(String.self, forKey: .serverIdAlias)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(clientId, forKey: .clientId)
        try container.encodeIfPresent(clientSecret, forKey: .clientSecret)
        try container.encodeIfPresent(serverId, forKey: .serverId)
    }
}
