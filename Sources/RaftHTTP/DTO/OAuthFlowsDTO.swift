import Foundation
import RaftShared

// Request and response shapes of the provider/OAuth flow surface.
//
// Requests: the retired handlers read each body through the untyped Foundation
// parser and a per-field `as?` cast, so a member of the wrong JSON type read as
// absent. These types keep that through `LegacyJSONObject`; the one place the
// object-vs-not-an-object distinction was observable (the two mobile start
// routes) is `isObject`.
//
// Responses: every body publishes an exact member order, so each conforms to
// `JSONBodyConvertible` and renders an `OrderedJSON` tree.

// MARK: - Requests

private func isJSONObject(_ decoder: any Decoder) -> Bool {
    (try? decoder.container(keyedBy: LegacyJSONKey.self)) != nil
}

/// `POST /api/auth/mobile/oauth/start` and
/// `POST /api/auth/mobile/oauth/:provider/link/start`.
public struct MobileOAuthStartRequest: Decodable, Sendable, Equatable {
    /// The body parsed as a JSON object. A body that is not one answers the
    /// `Invalid mobile OAuth start` refusal before any field is read.
    public var isObject: Bool
    public var returnUri: String?
    public var provider: String?
    public var mode: String?
    public var codeChallenge: String?
    public var linkOnConflict: Bool

    public init(
        isObject: Bool = false,
        returnUri: String? = nil,
        provider: String? = nil,
        mode: String? = nil,
        codeChallenge: String? = nil,
        linkOnConflict: Bool = false
    ) {
        self.isObject = isObject
        self.returnUri = returnUri
        self.provider = provider
        self.mode = mode
        self.codeChallenge = codeChallenge
        self.linkOnConflict = linkOnConflict
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        isObject = isJSONObject(decoder)
        returnUri = object.string("returnUri")
        provider = object.string("provider")
        mode = object.string("mode")
        codeChallenge = object.string("codeChallenge")
        linkOnConflict = object.bool("linkOnConflict") ?? false
    }
}

/// `POST /api/auth/mobile/oauth/apple/native/start`.
public struct NativeAppleStartRequest: Decodable, Sendable, Equatable {
    public var platform: String?
    public var appEnv: String?
    public var codeChallengeMethod: String?
    public var mode: String?
    public var returnUri: String?
    public var codeChallenge: String?

    public init(
        platform: String? = nil,
        appEnv: String? = nil,
        codeChallengeMethod: String? = nil,
        mode: String? = nil,
        returnUri: String? = nil,
        codeChallenge: String? = nil
    ) {
        self.platform = platform
        self.appEnv = appEnv
        self.codeChallengeMethod = codeChallengeMethod
        self.mode = mode
        self.returnUri = returnUri
        self.codeChallenge = codeChallenge
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        platform = object.string("platform")
        appEnv = object.string("appEnv")
        codeChallengeMethod = object.string("codeChallengeMethod")
        mode = object.string("mode")
        returnUri = object.string("returnUri")
        codeChallenge = object.string("codeChallenge")
    }
}

/// `POST /api/auth/mobile/oauth/apple/native/authorize`.
public struct NativeAppleAuthorizeRequest: Decodable, Sendable, Equatable {
    public var requestId: String?
    public var requestToken: String?
    public var authorizationCode: String?
    public var identityToken: String?

    public init(
        requestId: String? = nil,
        requestToken: String? = nil,
        authorizationCode: String? = nil,
        identityToken: String? = nil
    ) {
        self.requestId = requestId
        self.requestToken = requestToken
        self.authorizationCode = authorizationCode
        self.identityToken = identityToken
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        requestId = object.string("requestId")
        requestToken = object.string("requestToken")
        authorizationCode = object.string("authorizationCode")
        identityToken = object.string("identityToken")
    }
}

/// `POST /api/auth/mobile/oauth/complete` and
/// `POST /api/auth/mobile/oauth/:provider/link/complete`.
public struct MobileOAuthCompleteRequest: Decodable, Sendable, Equatable {
    public var code: String?
    public var codeVerifier: String?
    public var pendingLinkToken: String?
    /// `acceptTerms as? Bool`: a JSON boolean, or a `0`/`1` number.
    public var acceptTerms: Bool?
    public var termsVersion: String?
    public var privacyVersion: String?

    public init(
        code: String? = nil,
        codeVerifier: String? = nil,
        pendingLinkToken: String? = nil,
        acceptTerms: Bool? = nil,
        termsVersion: String? = nil,
        privacyVersion: String? = nil
    ) {
        self.code = code
        self.codeVerifier = codeVerifier
        self.pendingLinkToken = pendingLinkToken
        self.acceptTerms = acceptTerms
        self.termsVersion = termsVersion
        self.privacyVersion = privacyVersion
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        code = object.string("code")
        codeVerifier = object.string("codeVerifier")
        pendingLinkToken = object.string("pendingLinkToken")
        acceptTerms = object.bool("acceptTerms")
        termsVersion = object.string("termsVersion")
        privacyVersion = object.string("privacyVersion")
    }
}

/// `POST /api/auth/:provider/link/start`: only `returnTo` is read.
public struct WebOAuthLinkStartRequest: Decodable, Sendable, Equatable {
    public var returnTo: String?

    public init(returnTo: String? = nil) {
        self.returnTo = returnTo
    }

    public init(from decoder: any Decoder) throws {
        returnTo = LegacyJSONObject(decoder).string("returnTo")
    }
}

/// How one optional member of the feature-flag request read: absent or JSON
/// `null`, a string, or a present value of another type.
public enum FeatureFlagStringField: Sendable, Equatable {
    case absent
    case value(String)
    case invalid

    init(_ object: LegacyJSONObject, _ name: String) {
        guard object.has(name), !object.isNull(name) else {
            self = .absent
            return
        }
        self = object.string(name).map(FeatureFlagStringField.value) ?? .invalid
    }
}

/// `POST /api/feature-flags/evaluate`.
///
/// `keys` keeps the raw elements (a non-string element is an invalid key);
/// `key` is the single-key alias read only when `keys` is not an array. The
/// client facts are validated by the service against the published allow-lists.
public struct FeatureFlagsEvaluateRequest: Decodable, Sendable, Equatable {
    public var keys: [JSONValue]?
    public var key: String?
    public var serverId: FeatureFlagStringField
    public var platform: FeatureFlagStringField
    public var os: String?
    public var buildType: String?
    public var buildNumber: JSONValue?

    public init(
        keys: [JSONValue]? = nil,
        key: String? = nil,
        serverId: FeatureFlagStringField = .absent,
        platform: FeatureFlagStringField = .absent,
        os: String? = nil,
        buildType: String? = nil,
        buildNumber: JSONValue? = nil
    ) {
        self.keys = keys
        self.key = key
        self.serverId = serverId
        self.platform = platform
        self.os = os
        self.buildType = buildType
        self.buildNumber = buildNumber
    }

    public init(from decoder: any Decoder) throws {
        let object = LegacyJSONObject(decoder)
        if let container = try? decoder.container(keyedBy: LegacyJSONKey.self) {
            keys = LegacyJSONKey(stringValue: "keys").flatMap {
                (try? container.decodeIfPresent([JSONValue].self, forKey: $0)) ?? nil
            }
            buildNumber = LegacyJSONKey(stringValue: "buildNumber").flatMap {
                (try? container.decodeIfPresent(JSONValue.self, forKey: $0)) ?? nil
            }
        } else {
            keys = nil
            buildNumber = nil
        }
        key = object.string("key")
        serverId = FeatureFlagStringField(object, "serverId")
        platform = FeatureFlagStringField(object, "platform")
        os = object.string("os")
        buildType = object.string("buildType")
    }
}

// MARK: - Responses

/// One `{"id","label","enabled"}` row of `GET /api/auth/providers`.
public struct AuthProviderRow: Sendable, Equatable {
    public var id: String
    public var label: String
    public var enabled: Bool
}

/// `GET /api/auth/providers`.
public struct AuthProvidersResponse: JSONBodyConvertible, Equatable {
    public var providers: [AuthProviderRow]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("providers", .array(providers.map { provider in
                .object([
                    OrderedJSONField("id", provider.id),
                    OrderedJSONField("label", provider.label),
                    OrderedJSONField("enabled", provider.enabled),
                ])
            })),
        ])
    }
}

/// A `302` with an empty body: the web OAuth start, the web callback and the
/// mobile callback answer these. The legacy reply published `X-Robots-Tag`,
/// `Location` and (for the web start) `Set-Cookie`, with no `Content-Type`.
public struct OAuthRedirect: JSONBodyConvertible, Equatable {
    public var location: String
    public var cookie: String?

    public init(location: String, cookie: String? = nil) {
        self.location = location
        self.cookie = cookie
    }

    public var status: UInt { 302 }

    public var headers: ResponseHeaders {
        var values = [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Location": location,
        ]
        if let cookie { values["Set-Cookie"] = cookie }
        return .exact(values)
    }

    public var jsonBody: OrderedJSON { .raw("") }
}

/// `POST /api/auth/:provider/link/start`: `{"url"}` and the nonce cookie.
public struct WebOAuthLinkStarted: JSONBodyConvertible, Equatable {
    public var url: String
    public var cookie: String

    public var headers: ResponseHeaders { .standard(extra: ["Set-Cookie": cookie]) }

    public var jsonBody: OrderedJSON { .object([OrderedJSONField("url", url)]) }
}

/// `201` of `POST /api/auth/mobile/oauth/start` and the mobile link start.
public struct MobileOAuthStarted: JSONBodyConvertible, Equatable {
    public var requestId: String
    public var authorizationUrl: String
    public var returnUri: String
    public var expiresAt: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("requestId", requestId),
            OrderedJSONField("authorizationUrl", authorizationUrl),
            OrderedJSONField("returnUri", returnUri),
            OrderedJSONField("expiresAt", expiresAt),
        ])
    }
}

/// `201` of `POST /api/auth/mobile/oauth/apple/native/start`.
public struct NativeAppleStarted: JSONBodyConvertible, Equatable {
    public var requestId: String
    public var requestToken: String
    public var returnUri: String
    public var expiresAt: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("requestId", requestId),
            OrderedJSONField("requestToken", requestToken),
            OrderedJSONField("returnUri", returnUri),
            OrderedJSONField("expiresAt", expiresAt),
        ])
    }
}

/// `200` of `POST /api/auth/mobile/oauth/apple/native/authorize`.
public struct NativeAppleAuthorized: JSONBodyConvertible, Equatable {
    public var requestId: String
    public var handoffCode: String
    public var mode: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("requestId", requestId),
            OrderedJSONField("handoffCode", handoffCode),
            OrderedJSONField("provider", "apple"),
            OrderedJSONField("mode", mode),
        ])
    }
}

/// `200` of `POST /api/auth/mobile/oauth/complete`. Both the existing-account
/// sign-in, the just-created account and the spent pending-link handoff publish
/// the same body: the complete `toPublicUser` projection, then the provider,
/// mode, return URI, session tokens and the optional linked provider.
public struct MobileOAuthCompleted: JSONBodyConvertible, Equatable {
    public var user: AuthUserDTO
    public var provider: String
    public var mode: String
    public var returnUri: String
    public var accessToken: String
    public var refreshToken: String
    public var linkedProvider: String?

    public init(
        user: AuthUserDTO,
        provider: String,
        mode: String,
        returnUri: String,
        accessToken: String,
        refreshToken: String,
        linkedProvider: String? = nil
    ) {
        self.user = user
        self.provider = provider
        self.mode = mode
        self.returnUri = returnUri
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.linkedProvider = linkedProvider
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("user", user.jsonBody)
        body.append("provider", provider)
        body.append("mode", mode)
        body.append("returnUri", returnUri)
        body.append("accessToken", accessToken)
        body.append("refreshToken", refreshToken)
        body.append("linkedProvider", ifPresent: linkedProvider)
        return body.json
    }
}

/// One linked identity of `POST /api/auth/mobile/oauth/:provider/link/complete`.
public struct MobileLinkedIdentity: Sendable, Equatable {
    public var provider: String
    public var providerEmail: String
}

/// `200` of `POST /api/auth/mobile/oauth/:provider/link/complete`.
public struct MobileOAuthLinkCompleted: JSONBodyConvertible, Equatable {
    public var provider: String
    public var returnUri: String
    public var identities: [MobileLinkedIdentity]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("provider", provider),
            OrderedJSONField("mode", "link"),
            OrderedJSONField("returnUri", returnUri),
            OrderedJSONField("identities", .array(identities.map { identity in
                .object([
                    OrderedJSONField("provider", identity.provider),
                    OrderedJSONField("providerEmail", identity.providerEmail),
                ])
            })),
        ])
    }
}

/// `200` of `POST /api/oauth/installations/lookup`.
public struct OAuthInstallationLookupResponse: JSONBodyConvertible, Equatable {
    public var installationId: String
    public var serverId: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("installation_id", installationId),
            OrderedJSONField("server_id", serverId),
            OrderedJSONField("setup", .object([
                OrderedJSONField("status", "not_required"),
                OrderedJSONField("url", .null),
                OrderedJSONField("description", .null),
                OrderedJSONField("revision", 1),
                OrderedJSONField("completedAt", .null),
            ])),
        ])
    }
}

/// One `{"key","enabled","reason"}` evaluation.
public struct FeatureFlagEvaluation: Sendable, Equatable {
    public var key: String
    public var enabled: Bool
    public var reason: String
}

/// `200` of `POST /api/feature-flags/evaluate`.
public struct FeatureFlagEvaluations: JSONBodyConvertible, Equatable {
    public var evaluations: [FeatureFlagEvaluation]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("evaluations", .array(evaluations.map { evaluation in
                .object([
                    OrderedJSONField("key", evaluation.key),
                    OrderedJSONField("enabled", evaluation.enabled),
                    OrderedJSONField("reason", evaluation.reason),
                ])
            })),
        ])
    }
}
