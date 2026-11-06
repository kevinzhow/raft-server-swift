import Foundation

// MARK: - Request bodies
//
// The retired handlers read these bodies with the Foundation JSON object parser and per-field
// `as? String` / `as? Bool` casts. The decoders below keep that tolerance: a
// value of the wrong JSON type reads as absent (or as the field-specific
// "invalid" state the old validation order reported), so a request the old
// routes accepted cannot become a different status. A body that is not a JSON
// object fails to decode; the feature maps that to the same published reply the
// old non-object cast produced.

/// The JSON shape of one value whose type the old parser reported by name.
///
/// Only `LoginRequest` needs it: the login issue list prints the received type
/// (`Expected string, received number`). the Foundation object parser bridged a JSON
/// `0` or `1` to `Bool`, so those two numbers read as `boolean`; the decoder
/// keeps that quirk because the published bytes carry it.
private enum JSONShape: Decodable {
    case null
    case string
    case boolean
    case number
    case array
    case object

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if (try? container.decode(String.self)) != nil {
            self = .string
        } else if (try? container.decode(Bool.self)) != nil {
            self = .boolean
        } else if let number = try? container.decode(Double.self) {
            self = (number == 0 || number == 1) ? .boolean : .number
        } else if (try? container.decode([JSONShape].self)) != nil {
            self = .array
        } else if (try? container.decode([String: JSONShape].self)) != nil {
            self = .object
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var name: String {
        switch self {
        case .null: "null"
        case .string: "string"
        case .boolean: "boolean"
        case .number: "number"
        case .array: "array"
        case .object: "object"
        }
    }
}

/// One required string of the login body, in the three states the issue list
/// distinguishes: absent, a string (possibly empty) and any other JSON type.
public enum LoginBodyField: Sendable, Equatable {
    case absent
    case string(String)
    case wrongType(String)
}

/// One entry of the published `issues` list of the login 400.
public struct AuthRequestIssue: Sendable, Equatable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// `POST /api/auth/login` request body.
public struct LoginRequest: Decodable, Sendable, Equatable {
    public var email: LoginBodyField
    public var password: LoginBodyField
    public var pendingLinkToken: String?

    public init(email: String, password: String, pendingLinkToken: String? = nil) {
        self.email = .string(email)
        self.password = .string(password)
        self.pendingLinkToken = pendingLinkToken
    }

    private enum CodingKeys: String, CodingKey {
        case email
        case password
        case pendingLinkToken
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = Self.field(.email, in: container)
        password = Self.field(.password, in: container)
        pendingLinkToken = (try? container.decodeIfPresent(String.self, forKey: .pendingLinkToken)) ?? nil
    }

    private static func field(
        _ key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> LoginBodyField {
        guard container.contains(key) else { return .absent }
        if let string = try? container.decode(String.self, forKey: key) { return .string(string) }
        let shape = (try? container.decode(JSONShape.self, forKey: key)) ?? .object
        return .wrongType(shape.name)
    }
}

/// `POST /api/auth/app-login/start` request body.
public struct AppLoginStartRequest: Decodable, Sendable, Equatable {
    public var returnUri: String?
    public var codeChallenge: String?
    public var codeChallengeMethod: String?

    public init(returnUri: String? = nil, codeChallenge: String? = nil, codeChallengeMethod: String? = nil) {
        self.returnUri = returnUri
        self.codeChallenge = codeChallenge
        self.codeChallengeMethod = codeChallengeMethod
    }

    private enum CodingKeys: String, CodingKey {
        case returnUri
        case codeChallenge
        case codeChallengeMethod
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        returnUri = (try? container.decodeIfPresent(String.self, forKey: .returnUri)) ?? nil
        codeChallenge = (try? container.decodeIfPresent(String.self, forKey: .codeChallenge)) ?? nil
        codeChallengeMethod = (try? container.decodeIfPresent(String.self, forKey: .codeChallengeMethod)) ?? nil
    }
}

/// `POST /api/auth/app-login/complete` request body.
public struct AppLoginCompleteRequest: Decodable, Sendable, Equatable {
    public var code: String?
    public var codeVerifier: String?

    public init(code: String? = nil, codeVerifier: String? = nil) {
        self.code = code
        self.codeVerifier = codeVerifier
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case codeVerifier
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? nil
        codeVerifier = (try? container.decodeIfPresent(String.self, forKey: .codeVerifier)) ?? nil
    }
}

/// One member of the `PATCH /api/auth/me` body.
///
/// The old handler tested `object[key] != nil` (so an explicit JSON `null` is a
/// present key) and then cast with `as? String` / `as? Bool`. `absent` is a
/// missing key, `null` a JSON null, `value` a correctly typed value and
/// `invalid` any other JSON type. A JSON `0` / `1` reads as a Bool, because
/// that is what the Foundation number bridge did.
public enum ProfileField<Value: Sendable & Equatable>: Sendable, Equatable {
    case absent
    case null
    case value(Value)
    case invalid
}

private extension KeyedDecodingContainer {
    func profileString(_ key: Key) -> ProfileField<String> {
        guard contains(key) else { return .absent }
        if (try? decodeNil(forKey: key)) == true { return .null }
        if let value = try? decode(String.self, forKey: key) { return .value(value) }
        return .invalid
    }

    func profileBool(_ key: Key) -> ProfileField<Bool> {
        guard contains(key) else { return .absent }
        if (try? decodeNil(forKey: key)) == true { return .null }
        if let value = try? decode(Bool.self, forKey: key) { return .value(value) }
        if let number = try? decode(Double.self, forKey: key), number == 0 || number == 1 {
            return .value(number == 1)
        }
        return .invalid
    }
}

/// `PATCH /api/auth/me` request body.
public struct UpdateProfileRequest: Decodable, Sendable, Equatable {
    public var currentPassword: ProfileField<String> = .absent
    public var newPassword: ProfileField<String> = .absent
    public var displayLanguage: ProfileField<String> = .absent
    public var shareUsageData: ProfileField<Bool> = .absent
    public var preferredLanguage: ProfileField<String> = .absent
    public var preferredTimezone: ProfileField<String> = .absent
    public var preferredTranslationMode: ProfileField<String> = .absent
    public var autoTranslationEnabled: ProfileField<Bool> = .absent
    public var preferredTranslationDisplay: ProfileField<String> = .absent
    public var preferredTimeFormat: ProfileField<String> = .absent
    public var preferredMessageBodyFontSize: ProfileField<String> = .absent
    public var referralSource: ProfileField<String> = .absent
    public var referralSourceOther: ProfileField<String> = .absent
    public var referralSourceSkipped: ProfileField<Bool> = .absent

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case currentPassword
        case newPassword
        case displayLanguage
        case shareUsageData
        case preferredLanguage
        case preferredTimezone
        case preferredTranslationMode
        case autoTranslationEnabled
        case preferredTranslationDisplay
        case preferredTimeFormat
        case preferredMessageBodyFontSize
        case referralSource
        case referralSourceOther
        case referralSourceSkipped
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPassword = container.profileString(.currentPassword)
        newPassword = container.profileString(.newPassword)
        displayLanguage = container.profileString(.displayLanguage)
        shareUsageData = container.profileBool(.shareUsageData)
        preferredLanguage = container.profileString(.preferredLanguage)
        preferredTimezone = container.profileString(.preferredTimezone)
        preferredTranslationMode = container.profileString(.preferredTranslationMode)
        autoTranslationEnabled = container.profileBool(.autoTranslationEnabled)
        preferredTranslationDisplay = container.profileString(.preferredTranslationDisplay)
        preferredTimeFormat = container.profileString(.preferredTimeFormat)
        preferredMessageBodyFontSize = container.profileString(.preferredMessageBodyFontSize)
        referralSource = container.profileString(.referralSource)
        referralSourceOther = container.profileString(.referralSourceOther)
        referralSourceSkipped = container.profileBool(.referralSourceSkipped)
    }
}

// MARK: - Response bodies
//
// Every body is a `JSONBodyConvertible` tree: the published member order is
// part of the contract and `OrderedJSON` keeps the legacy `jsonString`
// escaping (the sorted `JSONEncoder` would escape `/`).

/// One linked sign-in identity as the identity list publishes it.
public struct AuthIdentityRow: Sendable, Equatable {
    public let provider: String
    public let providerEmail: String

    public init(provider: String, providerEmail: String) {
        self.provider = provider
        self.providerEmail = providerEmail
    }

    var json: OrderedJSON {
        .object([
            OrderedJSONField("provider", provider),
            OrderedJSONField("providerEmail", providerEmail),
        ])
    }
}

/// `GET /api/auth/identities`.
public struct AuthIdentitiesResponse: JSONBodyConvertible, Equatable {
    public let identities: [AuthIdentityRow]
    public let passwordConfigured: Bool

    public init(identities: [AuthIdentityRow], passwordConfigured: Bool) {
        self.identities = identities
        self.passwordConfigured = passwordConfigured
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("identities", .array(identities.map(\.json))),
            OrderedJSONField("passwordConfigured", passwordConfigured),
        ])
    }
}

/// `DELETE /api/auth/identities/:provider`.
public struct UnlinkIdentityResponse: JSONBodyConvertible, Equatable {
    public let unlinked: Bool
    public let identities: [AuthIdentityRow]
    public let passwordConfigured: Bool

    public init(unlinked: Bool, identities: [AuthIdentityRow], passwordConfigured: Bool) {
        self.unlinked = unlinked
        self.identities = identities
        self.passwordConfigured = passwordConfigured
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("unlinked", unlinked),
            OrderedJSONField("identities", .array(identities.map(\.json))),
            OrderedJSONField("passwordConfigured", passwordConfigured),
        ])
    }
}

/// `POST /api/auth/login`.
public struct LoginResponse: JSONBodyConvertible, Equatable {
    public let userId: String
    public let email: String
    public let accessToken: String
    public let refreshToken: String
    public let linkedProvider: String?

    public init(
        userId: String,
        email: String,
        accessToken: String,
        refreshToken: String,
        linkedProvider: String?
    ) {
        self.userId = userId
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.linkedProvider = linkedProvider
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("user", .object([
                OrderedJSONField("id", userId),
                OrderedJSONField("email", email),
            ])),
            OrderedJSONField("accessToken", accessToken),
            OrderedJSONField("refreshToken", refreshToken),
            OrderedJSONField("linkedProvider", optional: linkedProvider),
        ])
    }
}

/// `POST /api/auth/app-login/start`.
public struct AppLoginStartResponse: JSONBodyConvertible, Equatable {
    public let requestId: String
    public let loginUrl: String
    public let expiresAt: String

    public init(requestId: String, loginUrl: String, expiresAt: String) {
        self.requestId = requestId
        self.loginUrl = loginUrl
        self.expiresAt = expiresAt
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("requestId", requestId),
            OrderedJSONField("loginUrl", loginUrl),
            OrderedJSONField("expiresAt", expiresAt),
        ])
    }
}

/// `GET /api/auth/app-login/requests/:requestId`.
public struct AppLoginRequestResponse: JSONBodyConvertible, Equatable {
    public let requestId: String
    public let status: String
    public let returnUri: String
    public let expiresAt: String

    public init(requestId: String, status: String, returnUri: String, expiresAt: String) {
        self.requestId = requestId
        self.status = status
        self.returnUri = returnUri
        self.expiresAt = expiresAt
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("requestId", requestId),
            OrderedJSONField("status", status),
            OrderedJSONField("returnUri", returnUri),
            OrderedJSONField("expiresAt", expiresAt),
        ])
    }
}

/// `POST /api/auth/app-login/requests/:requestId/approve` and `/deny`.
public struct AppLoginRedirectResponse: JSONBodyConvertible, Equatable {
    public let redirectUrl: String

    public init(redirectUrl: String) {
        self.redirectUrl = redirectUrl
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("redirectUrl", redirectUrl)])
    }
}

/// The full `user` object `GET /api/auth/me`, the avatar upload and the app
/// login completion publish. `AuthUserDTO(account:)` is the one place the
/// member order is written down; `EmailLoginDirectory.userJSON` renders it for
/// the domains that still embed the object in their own bodies.
public struct AuthUserDTO: JSONBodyConvertible, Equatable {
    public let id: String
    public let email: String
    public let name: String
    public let emailVerified: Bool
    public let displayName: String
    public let gravatarHash: String
    public let displayLanguage: String?
    public let profileSetupCompletedAt: String?
    public let profileSetupSuggestedHandle: String?
    public let profileSetupProvider: String?
    public let avatarUrl: String?
    public let shareUsageData: Bool?
    public let preferredLanguage: String?
    public let preferredTimezone: String?
    public let preferredTranslationMode: String
    public let autoTranslationEnabled: Bool
    public let preferredTranslationDisplay: String
    public let preferredTimeFormat: String?
    public let preferredMessageBodyFontSize: String?
    public let referralSource: String?
    public let referralSourceOther: String?
    public let referralSourceSkippedAt: String?

    init(account: Account) {
        id = account.id
        email = account.email
        name = account.name
        emailVerified = account.emailVerified
        displayName = account.displayName ?? account.name
        gravatarHash = EmailLoginDirectory.sha256(
            account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        displayLanguage = account.displayLanguage
        profileSetupCompletedAt = account.profileSetupCompletedAt.map(EmailLoginDirectory.iso8601)
        profileSetupSuggestedHandle = account.profileSetupSuggestedHandle
        profileSetupProvider = account.profileSetupProvider
        avatarUrl = account.avatarUrl
        shareUsageData = account.shareUsageData
        preferredLanguage = account.preferredLanguage
        preferredTimezone = account.preferredTimezone
        preferredTranslationMode = account.preferredTranslationMode
        autoTranslationEnabled = account.autoTranslationEnabled
        preferredTranslationDisplay = account.preferredTranslationDisplay
        preferredTimeFormat = account.preferredTimeFormat
        preferredMessageBodyFontSize = account.preferredMessageBodyFontSize
        referralSource = account.referralSource
        referralSourceOther = account.referralSourceOther
        referralSourceSkippedAt = account.referralSourceSkippedAt.map(EmailLoginDirectory.iso8601)
    }

    var fields: [OrderedJSONField] {
        [
            OrderedJSONField("id", id),
            OrderedJSONField("email", email),
            OrderedJSONField("name", name),
            OrderedJSONField("emailVerified", emailVerified),
            OrderedJSONField("displayName", displayName),
            OrderedJSONField("gravatarHash", gravatarHash),
            OrderedJSONField("displayLanguage", optional: displayLanguage),
            OrderedJSONField("profileSetupCompletedAt", optional: profileSetupCompletedAt),
            OrderedJSONField("profileSetupSuggestedHandle", optional: profileSetupSuggestedHandle),
            OrderedJSONField("profileSetupProvider", optional: profileSetupProvider),
            OrderedJSONField("avatarUrl", optional: avatarUrl),
            OrderedJSONField("shareUsageData", optional: shareUsageData),
            OrderedJSONField("preferredLanguage", optional: preferredLanguage),
            OrderedJSONField("preferredTimezone", optional: preferredTimezone),
            OrderedJSONField("preferredTranslationMode", preferredTranslationMode),
            OrderedJSONField("autoTranslationEnabled", autoTranslationEnabled),
            OrderedJSONField("preferredTranslationDisplay", preferredTranslationDisplay),
            OrderedJSONField("preferredTimeFormat", optional: preferredTimeFormat),
            OrderedJSONField("preferredMessageBodyFontSize", optional: preferredMessageBodyFontSize),
            OrderedJSONField("referralSource", optional: referralSource),
            OrderedJSONField("referralSourceOther", optional: referralSourceOther),
            OrderedJSONField("referralSourceSkippedAt", optional: referralSourceSkippedAt),
        ]
    }

    public var jsonBody: OrderedJSON {
        .object(fields)
    }
}

/// `GET /api/auth/me`: the user object, with the four observed-timezone
/// members appended to the same object once the user has reported one.
public struct AuthMeResponse: JSONBodyConvertible, Equatable {
    public let user: AuthUserDTO
    public let observedTimezone: TimezoneObservationResponse?

    public var jsonBody: OrderedJSON {
        var fields = user.fields
        if let observed = observedTimezone {
            fields.append(OrderedJSONField("firstObservedTimezone", observed.firstObservedTimezone))
            fields.append(OrderedJSONField("firstObservedTimezoneAt", observed.firstObservedTimezoneAt))
            fields.append(OrderedJSONField("lastObservedTimezone", observed.lastObservedTimezone))
            fields.append(OrderedJSONField("lastObservedTimezoneAt", observed.lastObservedTimezoneAt))
        }
        return .object(fields)
    }
}

/// `PATCH /api/auth/me` and `POST /api/auth/me/avatar`: the bare user object.
public struct AuthProfileUserResponse: JSONBodyConvertible, Equatable {
    public let user: AuthUserDTO

    public var jsonBody: OrderedJSON { user.jsonBody }
}

/// `POST /api/auth/app-login/complete`.
public struct AppLoginCompleteResponse: JSONBodyConvertible, Equatable {
    public let user: AuthUserDTO
    public let accessToken: String
    public let refreshToken: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("user", user.jsonBody),
            OrderedJSONField("accessToken", accessToken),
            OrderedJSONField("refreshToken", refreshToken),
        ])
    }
}

/// One App row of `GET /api/integrations/clients`.
public struct IntegrationSettingsClient: Sendable, Equatable {
    public let id: String
    public let clientId: String
    public let name: String
    public let appType: String
    public let description: String?
    public let homepageUrl: String?
    public let publishStatus: String

    public init(
        id: String,
        clientId: String,
        name: String,
        appType: String,
        description: String?,
        homepageUrl: String?,
        publishStatus: String
    ) {
        self.id = id
        self.clientId = clientId
        self.name = name
        self.appType = appType
        self.description = description
        self.homepageUrl = homepageUrl
        self.publishStatus = publishStatus
    }

    var json: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("clientId", clientId),
            OrderedJSONField("name", name),
            OrderedJSONField("appType", appType),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("homepageUrl", optional: homepageUrl),
            OrderedJSONField("publishStatus", publishStatus),
        ])
    }
}

/// `GET /api/integrations/clients`: a bare JSON array.
public struct IntegrationSettingsClientsResponse: JSONBodyConvertible, Equatable {
    public let clients: [IntegrationSettingsClient]

    public init(clients: [IntegrationSettingsClient]) {
        self.clients = clients
    }

    public var jsonBody: OrderedJSON {
        .array(clients.map(\.json))
    }
}
