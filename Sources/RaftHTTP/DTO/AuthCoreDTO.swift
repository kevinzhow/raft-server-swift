import Foundation
import RaftShared

// Request and response shapes of the session core: social completion,
// register, staging retirement, device grants, refresh and logout.
//
// The retired handlers read every body with the Foundation JSON object parser
// and per-field `as? String` / `as? Bool` casts. The request decoders keep that
// tolerance: a value of the wrong JSON type reads as absent (or as the
// field-specific state the old validation order reported), so a request the old
// routes accepted cannot become a different status. A body that is not a JSON
// object fails to decode; the feature maps it to an empty request and the
// service publishes the reply the old non-object cast produced.

private extension KeyedDecodingContainer {
    /// `as? String`: anything else (including `null`) reads as absent.
    func lenientString(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    /// `as? Bool`: the Foundation parser bridged a JSON `0` or `1` to `Bool`,
    /// so those two numbers read as a boolean.
    func lenientBool(_ key: Key) -> Bool? {
        if let value = (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil { return value }
        if let number = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil, number == 0 || number == 1 {
            return number == 1
        }
        return nil
    }
}

// MARK: - Requests

/// `POST /api/auth/:provider/complete` request body.
public struct SocialCompleteRequest: Decodable, Sendable, Equatable {
    public var code: String?
    public var pendingLinkToken: String?
    /// `acceptTerms as? Bool == true`.
    public var acceptTerms: Bool
    public var termsVersion: String?
    public var privacyVersion: String?
    public var legalAcceptanceSource: String?

    public init(
        code: String? = nil,
        pendingLinkToken: String? = nil,
        acceptTerms: Bool = false,
        termsVersion: String? = nil,
        privacyVersion: String? = nil,
        legalAcceptanceSource: String? = nil
    ) {
        self.code = code
        self.pendingLinkToken = pendingLinkToken
        self.acceptTerms = acceptTerms
        self.termsVersion = termsVersion
        self.privacyVersion = privacyVersion
        self.legalAcceptanceSource = legalAcceptanceSource
    }

    private enum CodingKeys: String, CodingKey {
        case code, pendingLinkToken, acceptTerms, termsVersion, privacyVersion, legalAcceptanceSource
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = container.lenientString(.code)
        pendingLinkToken = container.lenientString(.pendingLinkToken)
        acceptTerms = container.lenientBool(.acceptTerms) == true
        termsVersion = container.lenientString(.termsVersion)
        privacyVersion = container.lenientString(.privacyVersion)
        legalAcceptanceSource = container.lenientString(.legalAcceptanceSource)
    }
}

/// `POST /api/auth/register` request body.
///
/// Pinned `routes/auth.ts:102` is a zod 4.3.6 passthrough object: `email` and
/// `password` are required non-empty strings, `name` and
/// `stagingSelfAccountCapability` are optional, and unknown members pass
/// through. The decoder keeps the raw JSON value so the service publishes the
/// exact issue list before any account exists.
public struct RegisterRequest: Decodable, Sendable, Equatable {
    /// The valid string values; `nil` when the member was absent or invalid
    /// (the reason is one of `issues`).
    public var email: String?
    public var password: String?
    public var name: String?
    public var stagingSelfAccountCapability: String?
    /// The zod schema issues, in issue order. Empty exactly when the body is a
    /// valid object.
    public var issues: [AuthRequestIssue]
    public var acceptTerms: Bool
    public var termsVersion: String?
    public var privacyVersion: String?
    public var legalAcceptanceSource: String?
    public var e2eAutoVerify: Bool

    public init(
        email: String? = nil,
        password: String? = nil,
        name: String? = nil,
        stagingSelfAccountCapability: String? = nil,
        issues: [AuthRequestIssue] = [],
        acceptTerms: Bool = false,
        termsVersion: String? = nil,
        privacyVersion: String? = nil,
        legalAcceptanceSource: String? = nil,
        e2eAutoVerify: Bool = false
    ) {
        self.email = email
        self.password = password
        self.name = name
        self.stagingSelfAccountCapability = stagingSelfAccountCapability
        self.issues = issues
        self.acceptTerms = acceptTerms
        self.termsVersion = termsVersion
        self.privacyVersion = privacyVersion
        self.legalAcceptanceSource = legalAcceptanceSource
        self.e2eAutoVerify = e2eAutoVerify
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self.parse(try container.decode(JSONValue.self))
    }

    /// Pinned `emailRegisterRequestSchema`. The issue order is the schema's
    /// member order (`email`, `password`, `name`,
    /// `stagingSelfAccountCapability`).
    static func parse(_ raw: JSONValue?) -> RegisterRequest {
        let (fields, rootIssue) = AuthRequestSchema.objectFields(raw)
        if let rootIssue {
            return RegisterRequest(issues: [rootIssue])
        }
        var issues: [AuthRequestIssue] = []
        let email = AuthRequestSchema.string(fields["email"], path: "email", min: 1)
        issues += email.issues
        let password = AuthRequestSchema.string(fields["password"], path: "password", min: 1)
        issues += password.issues
        let name = AuthRequestSchema.optionalString(fields["name"], path: "name", min: 1)
        issues += name.issues
        let capability = AuthRequestSchema.optionalString(
            fields["stagingSelfAccountCapability"],
            path: "stagingSelfAccountCapability",
            min: 32,
            max: 256
        )
        issues += capability.issues
        return RegisterRequest(
            email: email.value,
            password: password.value,
            name: name.value,
            stagingSelfAccountCapability: capability.value,
            issues: issues,
            acceptTerms: Self.legacyBool(fields["acceptTerms"]) == true,
            termsVersion: Self.legacyString(fields["termsVersion"]),
            privacyVersion: Self.legacyString(fields["privacyVersion"]),
            legalAcceptanceSource: Self.legacyString(fields["legalAcceptanceSource"]),
            e2eAutoVerify: Self.legacyBool(fields["__e2eAutoVerify"]) == true
        )
    }

    /// The retired parser's `as? String` for a passthrough member: only a JSON
    /// string reads as a value.
    private static func legacyString(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    /// The retired parser's `as? Bool`, including the `0`/`1` number bridge.
    private static func legacyBool(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let flag)?: return flag
        case .integer(let number)?: return number == 0 || number == 1 ? number == 1 : nil
        case .number(let number)?: return number == 0 || number == 1 ? number == 1 : nil
        default: return nil
        }
    }
}

/// `POST /api/auth/staging-self-account/retire` request body.
public struct RetireStagingRequest: Decodable, Sendable, Equatable {
    public var userId: String?
    public var capability: String?

    public init(userId: String? = nil, capability: String? = nil) {
        self.userId = userId
        self.capability = capability
    }

    private enum CodingKeys: String, CodingKey { case userId, capability }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = container.lenientString(.userId)
        capability = container.lenientString(.capability)
    }
}

/// The `clientName` member of the device-authorize body: an absent key and a
/// JSON `null` publish no name, a string is capped at 200 characters and any
/// other type is the `client_name_invalid` 400.
public enum DeviceClientNameField: Sendable, Equatable {
    case absent
    case string(String)
    case invalidType
}

/// `POST /api/auth/device/authorize` request body.
public struct DeviceAuthorizeRequest: Decodable, Sendable, Equatable {
    public var clientName: DeviceClientNameField

    public init(clientName: DeviceClientNameField = .absent) {
        self.clientName = clientName
    }

    private enum CodingKeys: String, CodingKey { case clientName }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.clientName), (try? container.decodeNil(forKey: .clientName)) != true else {
            clientName = .absent
            return
        }
        if let name = try? container.decode(String.self, forKey: .clientName) {
            clientName = .string(name)
        } else {
            clientName = .invalidType
        }
    }
}

/// `POST /api/auth/device/approve` request body.
public struct DeviceApproveRequest: Decodable, Sendable, Equatable {
    public var userCode: String?
    /// An absent key approves, `true` approves, and every other value (an
    /// explicit `null` included) denies.
    public var approve: Bool

    public init(userCode: String? = nil, approve: Bool = true) {
        self.userCode = userCode
        self.approve = approve
    }

    private enum CodingKeys: String, CodingKey { case userCode, approve }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userCode = container.lenientString(.userCode)
        approve = container.contains(.approve) ? container.lenientBool(.approve) == true : true
    }
}

/// `POST /api/auth/device/token` request body.
public struct DeviceTokenRequest: Decodable, Sendable, Equatable {
    public var deviceCode: String?

    public init(deviceCode: String? = nil) {
        self.deviceCode = deviceCode
    }

    private enum CodingKeys: String, CodingKey { case deviceCode }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceCode = container.lenientString(.deviceCode)
    }
}

/// `POST /api/auth/refresh` and `POST /api/auth/logout` request body.
public struct RefreshTokenRequest: Decodable, Sendable, Equatable {
    public var refreshToken: String?

    public init(refreshToken: String? = nil) {
        self.refreshToken = refreshToken
    }

    private enum CodingKeys: String, CodingKey { case refreshToken }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshToken = container.lenientString(.refreshToken)
    }
}

// MARK: - Responses

/// One identity row of the link-completion reply. Upstream returns the same
/// `{provider, providerEmail}` rows as `GET /api/auth/identities`
/// (`services/userService.ts:658-681`, `routes/auth.ts:1173-1188`).
public struct SocialLinkedIdentityDTO: Sendable, Equatable {
    public var provider: String
    public var providerEmail: String?

    public init(provider: String, providerEmail: String?) {
        self.provider = provider
        self.providerEmail = providerEmail
    }
}

/// `POST /api/auth/:provider/complete` success body: the link confirmation or
/// the signed-in session.
public enum SocialCompleteResponse: JSONBodyConvertible, Equatable {
    case linked(provider: String, returnTo: String, identities: [SocialLinkedIdentityDTO])
    case session(
        provider: String,
        mode: String,
        returnTo: String,
        accessToken: String,
        refreshToken: String,
        linkedProvider: String?
    )

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        switch self {
        case .linked(let provider, let returnTo, let identities):
            body.append("provider", provider)
            body.append("mode", "link")
            body.append("returnTo", returnTo)
            body.append("identities", .array(identities.map {
                .object([
                    OrderedJSONField("provider", $0.provider),
                    OrderedJSONField("providerEmail", optional: $0.providerEmail),
                ])
            }))
        case .session(let provider, let mode, let returnTo, let accessToken, let refreshToken, let linkedProvider):
            body.append("provider", provider)
            body.append("mode", mode)
            body.append("returnTo", returnTo)
            body.append("accessToken", accessToken)
            body.append("refreshToken", refreshToken)
            body.append("linkedProvider", ifPresent: linkedProvider)
        }
        return body.json
    }
}

/// `POST /api/auth/register` success body. Upstream returns the complete
/// `toPublicUser` projection, not a registration-only subset.
public struct RegisterResponse: JSONBodyConvertible, Equatable {
    public var user: AuthUserDTO
    public var accessToken: String
    public var refreshToken: String

    public var id: String { user.id }
    public var email: String { user.email }

    public init(user: AuthUserDTO, accessToken: String, refreshToken: String) {
        self.user = user
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("user", user.jsonBody),
            OrderedJSONField("accessToken", accessToken),
            OrderedJSONField("refreshToken", refreshToken),
        ])
    }
}

/// `POST /api/auth/staging-self-account/retire` success body.
public struct StagingRetirementResponse: JSONBodyConvertible, Equatable {
    public var userId: String
    public var actorUserId: String
    public var environment: String
    public var terminalState: String
    public var sessionsRevoked: Int

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("receipt", .object([
                OrderedJSONField("userId", userId),
                OrderedJSONField("actorUserId", actorUserId),
                OrderedJSONField("environment", environment),
                OrderedJSONField("terminalState", terminalState),
                OrderedJSONField("sessionsRevoked", sessionsRevoked),
            ])),
        ])
    }
}

/// `POST /api/auth/device/authorize` success body (`201`).
public struct DeviceAuthorizeResponse: JSONBodyConvertible, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationUri: String
    public var verificationUriComplete: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("deviceCode", deviceCode),
            OrderedJSONField("userCode", userCode),
            OrderedJSONField("verificationUri", verificationUri),
            OrderedJSONField("verificationUriComplete", verificationUriComplete),
            OrderedJSONField("expiresIn", 600),
            OrderedJSONField("interval", 5),
        ])
    }
}

/// `POST /api/auth/device/approve` success body.
public struct DeviceDecisionResponse: JSONBodyConvertible, Equatable {
    public var approved: Bool

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("action", approved ? "approved" : "denied"),
        ])
    }
}

/// `POST /api/auth/device/token` success body.
public struct DeviceTokenResponse: JSONBodyConvertible, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var userId: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("accessToken", accessToken),
            OrderedJSONField("refreshToken", refreshToken),
            OrderedJSONField("userId", userId),
        ])
    }
}

/// `POST /api/auth/refresh` success body.
public struct RefreshResponse: JSONBodyConvertible, Equatable {
    public var accessToken: String
    public var refreshToken: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("accessToken", accessToken),
            OrderedJSONField("refreshToken", refreshToken),
        ])
    }
}
