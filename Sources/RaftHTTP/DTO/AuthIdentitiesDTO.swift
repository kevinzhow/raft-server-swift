import Foundation
import RaftShared

// MARK: - Request bodies
//
// The pinned login and register bodies are zod 4.3.6 schemas
// (`routes/auth.ts:102-126`). The decoders keep the raw JSON value and hand it
// to `AuthRequestSchema`, so a wrong member type becomes one published `issues`
// entry (with zod's exact wording) instead of a decode failure, and an unknown
// member still passes through the passthrough schemas. A body that is not a
// JSON object at all is one `expected object` issue; a missing or malformed
// body reads as `{}` (`req.body ?? {}`).

/// `POST /api/auth/login` request body.
public struct LoginRequest: Decodable, Sendable, Equatable {
    /// The valid string values; `nil` when the member was absent or invalid
    /// (the reason is one of `issues`).
    public var email: String?
    public var password: String?
    public var pendingLinkToken: String?
    /// Whether `pendingLinkToken` was present but is not a string or is over
    /// 256 UTF-16 units. Pinned `routes/auth.ts:169-178` answers that shape
    /// with `pending_link_token_invalid` after the body schema succeeds; an
    /// absent, null or empty token is the same "no link requested" state.
    public var pendingLinkTokenInvalid: Bool
    /// The zod schema issues, in issue order. Empty exactly when the body is a
    /// valid object.
    public var issues: [AuthRequestIssue]

    public init(
        email: String,
        password: String,
        pendingLinkToken: String? = nil,
        pendingLinkTokenInvalid: Bool = false
    ) {
        self.email = email
        self.password = password
        self.pendingLinkToken = pendingLinkToken
        self.pendingLinkTokenInvalid = pendingLinkTokenInvalid
        self.issues = []
    }

    init(
        email: String?,
        password: String?,
        pendingLinkToken: String?,
        pendingLinkTokenInvalid: Bool = false,
        issues: [AuthRequestIssue]
    ) {
        self.email = email
        self.password = password
        self.pendingLinkToken = pendingLinkToken
        self.pendingLinkTokenInvalid = pendingLinkTokenInvalid
        self.issues = issues
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self.parse(try container.decode(JSONValue.self))
    }

    /// Pinned `emailLoginRequestSchema`: a passthrough object with two required
    /// non-empty strings.
    static func parse(_ raw: JSONValue?) -> LoginRequest {
        let (fields, rootIssue) = AuthRequestSchema.objectFields(raw)
        if let rootIssue {
            return LoginRequest(email: nil, password: nil, pendingLinkToken: nil, issues: [rootIssue])
        }
        var issues: [AuthRequestIssue] = []
        let email = AuthRequestSchema.string(fields["email"], path: "email", min: 1)
        issues += email.issues
        let password = AuthRequestSchema.string(fields["password"], path: "password", min: 1)
        issues += password.issues
        var pendingLinkToken: String?
        var pendingLinkTokenInvalid = false
        if let rawToken = fields["pendingLinkToken"] {
            if case .string(let token) = rawToken {
                if token.utf16.count > 256 {
                    pendingLinkTokenInvalid = true
                } else {
                    pendingLinkToken = token.isEmpty ? nil : token
                }
            } else if case .null = rawToken {
                // `null` is the same "not sent" state as `undefined`.
            } else {
                pendingLinkTokenInvalid = true
            }
        }
        return LoginRequest(
            email: email.value,
            password: password.value,
            pendingLinkToken: pendingLinkToken,
            pendingLinkTokenInvalid: pendingLinkTokenInvalid,
            issues: issues
        )
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
    /// The upstream `displayName` profile field: absent leaves it alone, JSON
    /// null clears it, and a string is written exactly as sent (the pinned
    /// handler copies it into the update without trimming or deriving it from
    /// the handle).
    public var displayName: ProfileField<String> = .absent
    /// The upstream `description` profile field: absent leaves it alone, JSON
    /// null clears it, and a string is trimmed (empty becomes null).
    public var description: ProfileField<String> = .absent
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
    /// Present null is legal and clears the stored role; absent leaves the role
    /// and its completion time untouched.
    public var signupRole: ProfileField<String> = .absent
    /// Trigger-only back-compat field (`routes/auth.ts:1499,1628-1644`): it is
    /// never persisted. It names the server whose onboarding agent should be
    /// briefed after this profile update, and only the server's owner may cause
    /// that.
    public var signupSurveyServerId: ProfileField<String> = .absent

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case currentPassword
        case newPassword
        case displayName
        case description
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
        case signupRole
        case signupSurveyServerId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPassword = container.profileString(.currentPassword)
        newPassword = container.profileString(.newPassword)
        displayName = container.profileString(.displayName)
        description = container.profileString(.description)
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
        signupRole = container.profileString(.signupRole)
        signupSurveyServerId = container.profileString(.signupSurveyServerId)
    }
}

// MARK: - Response bodies
//
// Every body is a `JSONBodyConvertible` tree: the published member order is
// part of the contract and `OrderedJSON` keeps the legacy `jsonString`
// escaping (the sorted `JSONEncoder` would escape `/`).

/// One linked sign-in identity as the identity list publishes it. The pinned
/// `user_auth_identities.provider_email` column is nullable; a retained row
/// without one publishes JSON null.
public struct AuthIdentityRow: Sendable, Equatable {
    public let provider: String
    public let providerEmail: String?

    public init(provider: String, providerEmail: String?) {
        self.provider = provider
        self.providerEmail = providerEmail
    }

    var json: OrderedJSON {
        .object([
            OrderedJSONField("provider", provider),
            OrderedJSONField("providerEmail", optional: providerEmail),
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

/// `POST /api/auth/login`. The browser uses this user immediately, before
/// any `/me` read, so it must carry the stored verification/profile projection.
public struct LoginResponse: JSONBodyConvertible, Equatable {
    public let user: AuthUserDTO
    public let accessToken: String
    public let refreshToken: String
    public let linkedProvider: String?

    public var userId: String { user.id }
    public var email: String { user.email }

    public init(
        user: AuthUserDTO,
        accessToken: String,
        refreshToken: String,
        linkedProvider: String?
    ) {
        self.user = user
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.linkedProvider = linkedProvider
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("user", user.jsonBody),
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

/// The full `user` object `toPublicUser` publishes: register, login,
/// `GET`/`PATCH /api/auth/me`, complete-profile, the avatar upload, app-login
/// completion and both mobile OAuth completion paths embed this one value.
///
/// Member order, presence and nullability follow `services/userService.ts`
/// `toPublicUser` exactly: every member is always present, nullable members
/// print JSON null, `displayName` is not derived from `name`, and the four
/// observed-timezone members sit between `preferredTimezone` and
/// `preferredTranslationMode`. `autoTranslationEnabled` is derived from the
/// stored mode, as upstream does, rather than read independently.
public struct AuthUserDTO: JSONBodyConvertible, Equatable {
    public let id: String
    public let email: String
    public let gravatarHash: String
    public let name: String
    public let displayName: String?
    public let description: String?
    public let avatarUrl: String?
    public let emailVerified: Bool
    public let preferredLanguage: String?
    public let displayLanguage: String?
    public let preferredTimezone: String?
    public let firstObservedTimezone: String?
    public let firstObservedTimezoneAt: String?
    public let lastObservedTimezone: String?
    public let lastObservedTimezoneAt: String?
    public let preferredTranslationMode: String
    public let autoTranslationEnabled: Bool
    public let preferredTranslationDisplay: String
    public let preferredTimeFormat: String?
    public let preferredMessageBodyFontSize: String?
    public let shareUsageData: Bool?
    public let referralSource: String?
    public let referralSourceOther: String?
    public let referralSourceSkippedAt: String?
    public let profileSetupCompletedAt: String?
    public let profileSetupSuggestedHandle: String?
    /// Signup survey state. Both members are always present, matching
    /// `toPublicUser`'s `?? null`; `signupSurveyCompletedAt` is the gate the
    /// client reads. The account-global first-onboarding pair is not published.
    public let signupSurveyCompletedAt: String?
    public let signupRole: String?
    public let profileSetupProvider: String?

    init(
        account: Account,
        observation: TimezoneObservation? = nil,
        profileSetupProvider: String? = nil
    ) {
        id = account.id
        email = account.email
        gravatarHash = AuthTokenCodec.sha256(
            account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        name = account.name
        displayName = account.displayName
        description = account.description
        avatarUrl = account.avatarUrl
        emailVerified = account.emailVerified
        preferredLanguage = account.preferredLanguage
        displayLanguage = account.displayLanguage
        preferredTimezone = account.preferredTimezone
        firstObservedTimezone = observation?.firstTimezone
        firstObservedTimezoneAt = observation.map { DateText.iso8601($0.firstAt) }
        // During a rolling deploy, a pre-0187 row can populate only the first
        // pair; upstream treats that accepted state as the latest observation.
        lastObservedTimezone = observation?.lastTimezone ?? observation?.firstTimezone
        lastObservedTimezoneAt = observation.map { DateText.iso8601($0.lastAt) }
        preferredTranslationMode = account.preferredTranslationMode
        autoTranslationEnabled = account.preferredTranslationMode == "auto"
        preferredTranslationDisplay = account.preferredTranslationDisplay
        preferredTimeFormat = account.preferredTimeFormat
        preferredMessageBodyFontSize = account.preferredMessageBodyFontSize
        shareUsageData = account.shareUsageData
        referralSource = account.referralSource
        referralSourceOther = account.referralSourceOther
        referralSourceSkippedAt = account.referralSourceSkippedAt.map(DateText.iso8601)
        profileSetupCompletedAt = account.profileSetupCompletedAt.map(DateText.iso8601)
        profileSetupSuggestedHandle = account.profileSetupSuggestedHandle
        signupSurveyCompletedAt = account.signupSurveyCompletedAt.map(DateText.iso8601)
        signupRole = account.signupRole
        self.profileSetupProvider = profileSetupProvider
    }

    var fields: [OrderedJSONField] {
        [
            OrderedJSONField("id", id),
            OrderedJSONField("email", email),
            OrderedJSONField("gravatarHash", gravatarHash),
            OrderedJSONField("name", name),
            OrderedJSONField("displayName", optional: displayName),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("avatarUrl", optional: avatarUrl),
            OrderedJSONField("emailVerified", emailVerified),
            OrderedJSONField("preferredLanguage", optional: preferredLanguage),
            OrderedJSONField("displayLanguage", optional: displayLanguage),
            OrderedJSONField("preferredTimezone", optional: preferredTimezone),
            OrderedJSONField("firstObservedTimezone", optional: firstObservedTimezone),
            OrderedJSONField("firstObservedTimezoneAt", optional: firstObservedTimezoneAt),
            OrderedJSONField("lastObservedTimezone", optional: lastObservedTimezone),
            OrderedJSONField("lastObservedTimezoneAt", optional: lastObservedTimezoneAt),
            OrderedJSONField("preferredTranslationMode", preferredTranslationMode),
            OrderedJSONField("autoTranslationEnabled", autoTranslationEnabled),
            OrderedJSONField("preferredTranslationDisplay", preferredTranslationDisplay),
            OrderedJSONField("preferredTimeFormat", optional: preferredTimeFormat),
            OrderedJSONField("preferredMessageBodyFontSize", optional: preferredMessageBodyFontSize),
            OrderedJSONField("shareUsageData", optional: shareUsageData),
            OrderedJSONField("referralSource", optional: referralSource),
            OrderedJSONField("referralSourceOther", optional: referralSourceOther),
            OrderedJSONField("referralSourceSkippedAt", optional: referralSourceSkippedAt),
            OrderedJSONField("profileSetupCompletedAt", optional: profileSetupCompletedAt),
            OrderedJSONField("profileSetupSuggestedHandle", optional: profileSetupSuggestedHandle),
            OrderedJSONField("signupSurveyCompletedAt", optional: signupSurveyCompletedAt),
            OrderedJSONField("signupRole", optional: signupRole),
            OrderedJSONField("profileSetupProvider", optional: profileSetupProvider),
        ]
    }

    public var jsonBody: OrderedJSON {
        .object(fields)
    }
}

/// `GET /api/auth/me`: the bare user object, unchanged from `toPublicUser`.
public struct AuthMeResponse: JSONBodyConvertible, Equatable {
    public let user: AuthUserDTO

    public init(user: AuthUserDTO) {
        self.user = user
    }

    public var jsonBody: OrderedJSON { user.jsonBody }
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
public struct IntegrationSettingsClient: Sendable, Equatable, JSONBodyConvertible {
    public let id: String
    public let clientId: String
    public let name: String
    public let appType: String
    public let description: String?
    public let homepageUrl: String?
    public let publishStatus: String
    public let logoUrl: String?

    public init(
        id: String,
        clientId: String,
        name: String,
        appType: String,
        description: String?,
        homepageUrl: String?,
        publishStatus: String,
        logoUrl: String? = nil
    ) {
        self.id = id
        self.clientId = clientId
        self.name = name
        self.appType = appType
        self.description = description
        self.homepageUrl = homepageUrl
        self.publishStatus = publishStatus
        self.logoUrl = logoUrl
    }

    public var jsonBody: OrderedJSON { json }

    var json: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("clientId", clientId),
            OrderedJSONField("name", name),
            OrderedJSONField("appType", appType),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("homepageUrl", optional: homepageUrl),
            OrderedJSONField("publishStatus", publishStatus),
            OrderedJSONField("logoUrl", optional: logoUrl),
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
