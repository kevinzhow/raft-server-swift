import Foundation
import RaftShared

/// `POST /api/auth/me/complete-profile` request body.
///
/// Pinned `routes/auth.ts:109` parses this body with a strict zod object:
/// `name` is a non-empty string, `displayName` is trimmed and must then be
/// 1...80 characters, and any other member is an unrecognized key. The route
/// publishes every schema failure as `PROFILE_SETUP_BODY_INVALID` with one
/// `issues` entry per failure, so the decoder keeps the raw JSON value and
/// produces the same ordered issue list (and zod 4's exact messages) instead of
/// letting a typed decode turn it into a different refusal.
public struct CompleteProfileRequest: Sendable, Equatable {
    /// The zod schema issues, in issue order. Empty exactly when the body is a
    /// valid object. `displayName` is already trimmed when it is valid.
    public var issues: [AuthRequestIssue]
    public var name: String
    public var displayName: String

    public init(
        issues: [AuthRequestIssue] = [],
        name: String = "",
        displayName: String = ""
    ) {
        self.issues = issues
        self.name = name
        self.displayName = displayName
    }

    /// The refusal for a body that never reached the schema (no body or invalid
    /// JSON). Upstream parses `req.body ?? {}`, so both required members are
    /// missing.
    public static let missingBody = CompleteProfileRequest(issues: [
        AuthRequestIssue(
            path: "name",
            message: "Invalid input: expected string, received undefined"
        ),
        AuthRequestIssue(
            path: "displayName",
            message: "Invalid input: expected string, received undefined"
        ),
    ])

    private static func issue(_ path: String, _ message: String) -> AuthRequestIssue {
        AuthRequestIssue(path: path, message: message)
    }

    private static func stringIssue(_ value: JSONValue, path: String) -> AuthRequestIssue {
        issue(path, "Invalid input: expected string, received \(value.zodKind)")
    }

    static func parse(_ raw: JSONValue) -> CompleteProfileRequest {
        guard case .object(let fields) = raw else {
            // Upstream `req.body ?? {}` rewrites a JSON null to the empty
            // object, so a null body reports the two required members rather
            // than an object-type issue.
            if case .null = raw { return parse(.object([:])) }
            return CompleteProfileRequest(issues: [
                issue("", "Invalid input: expected object, received \(raw.zodKind)"),
            ])
        }

        var issues: [AuthRequestIssue] = []
        var name = ""
        switch fields["name"] {
        case nil:
            issues.append(issue("name", "Invalid input: expected string, received undefined"))
        case .string(let value)?:
            if value.isEmpty {
                issues.append(issue("name", "Too small: expected string to have >=1 characters"))
            } else {
                name = value
            }
        case .some(let value):
            issues.append(stringIssue(value, path: "name"))
        }

        var displayName = ""
        switch fields["displayName"] {
        case nil:
            issues.append(issue("displayName", "Invalid input: expected string, received undefined"))
        case .string(let value)?:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.utf16.count == 0 {
                issues.append(issue("displayName", "Too small: expected string to have >=1 characters"))
            } else if trimmed.utf16.count > 80 {
                issues.append(issue("displayName", "Too big: expected string to have <=80 characters"))
            } else {
                displayName = trimmed
            }
        case .some(let value):
            issues.append(stringIssue(value, path: "displayName"))
        }

        // `.strict()` reports one issue for every member the shape does not
        // know, after the shape's own issues. The dictionary has no source
        // order, so the keys are sorted to keep the published bytes stable.
        let unknown = fields.keys
            .filter { $0 != "name" && $0 != "displayName" }
            .sorted()
        if !unknown.isEmpty {
            let label = unknown.count > 1 ? "Unrecognized keys" : "Unrecognized key"
            let keys = unknown.map { "\"\($0)\"" }.joined(separator: ", ")
            issues.append(issue("", "\(label): \(keys)"))
        }
        return CompleteProfileRequest(issues: issues, name: name, displayName: displayName)
    }
}

extension CompleteProfileRequest: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(JSONValue.self)
        self = Self.parse(raw)
    }
}

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
public struct ForgotPasswordResponse: Codable, JSONBodyConvertible, Sendable, Equatable {
    public static let acceptedMessage =
        "If an account exists with that email, a reset link has been sent."

    public var ok: Bool
    public var message: String

    public init(ok: Bool = true, message: String = ForgotPasswordResponse.acceptedMessage) {
        self.ok = ok
        self.message = message
    }

    /// Upstream `res.json({ ok, message })` keeps `ok` before `message`.
    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", ok),
            OrderedJSONField("message", message),
        ])
    }
}

/// `GET /api/auth/me/username-available` answer.
///
/// `reason` and `message` are absent on success (`res.json` serializes the
/// `undefined` values away) and present for every refusal.
public struct UsernameAvailabilityResponse: Codable, JSONBodyConvertible, Sendable, Equatable {
    public var available: Bool
    public var reason: String?
    public var message: String?

    public init(available: Bool, reason: String? = nil, message: String? = nil) {
        self.available = available
        self.reason = reason
        self.message = message
    }

    public var jsonBody: OrderedJSON {
        var fields = [OrderedJSONField("available", available)]
        if let reason { fields.append(OrderedJSONField("reason", reason)) }
        if let message { fields.append(OrderedJSONField("message", message)) }
        return .object(fields)
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
