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
///
/// The decoder mirrors the published `as? String` reads: a missing key, JSON
/// `null` and a non-string value all read as absent, and a malformed alias does
/// not reject the body. That keeps the typed route's replies identical to the
/// retired raw parser for every JSON object shape.
public struct ResetPasswordRequest: Codable, Sendable, Equatable {
    public var token: String?
    public var password: String?
    public var newPassword: String?

    public init(token: String? = nil, password: String? = nil, newPassword: String? = nil) {
        self.token = token
        self.password = password
        self.newPassword = newPassword
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try? container.decode(String.self, forKey: .token)
        self.password = try? container.decode(String.self, forKey: .password)
        self.newPassword = try? container.decode(String.self, forKey: .newPassword)
    }
}

/// `POST /api/auth/me/timezone-observation` request body.
///
/// The published shape is exactly one key, `timezone`, holding a string. The
/// decoder rejects any other key set so the typed route keeps the upstream
/// `{"timezone": …, "source": …}` 400 without a raw JSON parser.
public struct TimezoneObservationRequest: Codable, Sendable, Equatable {
    public var timezone: String?

    public init(timezone: String? = nil) {
        self.timezone = timezone
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard container.allKeys.map(\.stringValue) == ["timezone"] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "timezone must be the only key"
            ))
        }
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "timezone is required"
            ))
        }
        // A null or non-string value reads as absent; the service answers the
        // published 400 either way.
        self.timezone = try? container.decode(String.self, forKey: key)
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// The `POST /api/auth/me/timezone-observation` success body.
///
/// Timestamps stay preformatted ISO-8601 strings: the published bytes carry
/// fractional seconds, which `JSONEncoder`'s date strategies do not reproduce.
public struct TimezoneObservationResponse: Codable, Sendable, Equatable {
    public var firstObservedTimezone: String
    public var firstObservedTimezoneAt: String
    public var lastObservedTimezone: String
    public var lastObservedTimezoneAt: String

    public init(
        firstObservedTimezone: String,
        firstObservedTimezoneAt: String,
        lastObservedTimezone: String,
        lastObservedTimezoneAt: String
    ) {
        self.firstObservedTimezone = firstObservedTimezone
        self.firstObservedTimezoneAt = firstObservedTimezoneAt
        self.lastObservedTimezone = lastObservedTimezone
        self.lastObservedTimezoneAt = lastObservedTimezoneAt
    }
}

/// A successful operation whose published reply carries no body (204).
///
/// `Respond.swift` has a dedicated overload for this type so it maps to the
/// empty 204 reply instead of encoding the `{}` a `Codable` marker would emit.
public struct NoContentResponse: Codable, Sendable, Equatable {
    public init() {}
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

/// `POST /api/oauth/installations/lookup`.
///
/// The lookup reads `client_id`, `client_secret` and the Server id from
/// `server_id`, falling back to its `serverId` alias only when `server_id` is
/// absent: a present `server_id` of any type (`null` included) shadows the
/// alias. Every member is read with `as? String`, so a value of another type
/// reads as absent, and a body that is not a JSON object reads as an empty one.
public struct OAuthInstallationLookupDTO: Decodable, Sendable, Equatable {
    public var clientId: String?
    public var clientSecret: String?
    public var serverId: String?

    public init(clientId: String? = nil, clientSecret: String? = nil, serverId: String? = nil) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.serverId = serverId
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        clientId = object.string("client_id")
        clientSecret = object.string("client_secret")
        serverId = object.has("server_id") ? object.string("server_id") : object.string("serverId")
    }
}
