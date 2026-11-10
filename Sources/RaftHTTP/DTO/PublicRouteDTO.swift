import Foundation

public struct PublicServerJoinedResponse: JSONBodyConvertible {
    public let serverId: String
    public let serverName: String
    public var jsonBody: OrderedJSON { .object([
        .init("serverId", serverId), .init("serverName", serverName),
    ]) }
}

public struct PublicJoinResponse: JSONBodyConvertible {
    public let serverId: String
    public let serverName: String
    public let serverSlug: String
    public let role: String
    public let joined: Bool
    public var jsonBody: OrderedJSON { .object([
        .init("serverId", serverId), .init("serverName", serverName),
        .init("serverSlug", serverSlug), .init("role", role), .init("joined", joined),
    ]) }
}

public struct PublicServerListResponse: JSONBodyConvertible {
    public struct Server: Sendable {
        public let id: String
        public let slug: String
        public let role: String
        public let publicPageLive: Bool

        public init(id: String, slug: String, role: String, publicPageLive: Bool) {
            self.id = id
            self.slug = slug
            self.role = role
            self.publicPageLive = publicPageLive
        }
    }
    public let servers: [Server]

    public init(servers: [Server]) {
        self.servers = servers
    }

    public var jsonBody: OrderedJSON { .array(servers.map { .object([
        .init("id", $0.id), .init("slug", $0.slug), .init("role", $0.role),
        .init("publicPageLive", $0.publicPageLive),
    ]) }) }
}

public struct PublicPageResponse: JSONBodyConvertible {
    public struct Channel: Sendable {
        public let id: String
        public let name: String
    }
    public let serverId: String
    public let serverName: String
    public let slug: String
    public let avatarUrl: String?
    public let translationEnabled: Bool
    public let channels: [Channel]
    public let canJoinAsGuest: Bool
    public let translationAvailable: Bool
    public let visitorIdMode: String?
    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject([
            .init("server", .object([
                .init("id", serverId), .init("name", serverName), .init("slug", slug),
                .init("avatarUrl", optional: avatarUrl), .init("translationEnabled", translationEnabled),
            ])),
            .init("channels", .array(channels.map { .object([
                .init("id", $0.id), .init("name", $0.name), .init("description", .null),
            ]) })),
            .init("canJoinAsGuest", canJoinAsGuest), .init("translationAvailable", translationAvailable),
        ])
        body.append("visitorIdMode", ifPresent: visitorIdMode)
        return body.json
    }
}

public struct PublicAgreementDTO: JSONBodyConvertible, Equatable {
    public let id: String
    public let version: Int
    public let title: String
    public let bodyMarkdown: String
    public var jsonBody: OrderedJSON { .object([
        .init("id", id), .init("version", version), .init("title", title),
        .init("bodyMarkdown", bodyMarkdown), .init("enabled", true),
    ]) }
}

public enum PublicVisitError: DomainError, Equatable {
    case authentication(invalidToken: Bool)
    case notFound
    case unsupportedCommunity
    case communityUnavailable
    case alreadyMember
    case agreementRequired(PublicAgreementDTO)
    case agreementChanged(PublicAgreementDTO)
    public var status: UInt {
        switch self {
        case .authentication: 401
        case .notFound, .communityUnavailable: 404
        case .agreementRequired, .agreementChanged: 409
        case .unsupportedCommunity, .alreadyMember: 400
        }
    }
    public var errorMessage: String {
        switch self {
        case .authentication(let invalid): invalid ? "Invalid or expired token" : "Missing or invalid Authorization header"
        case .notFound: "Not found"
        case .unsupportedCommunity: "Unsupported community"
        case .communityUnavailable: "Community server is not available"
        case .alreadyMember: "Already a member of this community"
        case .agreementRequired: "agreement_required"
        case .agreementChanged: "agreement_changed"
        }
    }
    public var errorCode: String? { if case .authentication = self { "auth_required" } else { nil } }
    public var responseHeaders: [String: String] { ["Cache-Control": "no-store"] }
    public var errorBody: OrderedJSON? {
        switch self {
        case .agreementRequired(let agreement), .agreementChanged(let agreement):
            .object([.init("error", errorMessage), .init("agreement", agreement)])
        default: nil
        }
    }
}

public struct PublicVisibilityUpdateResponse: JSONBodyConvertible {
    public let publiclyVisible: Bool
    public let publicGuestJoinEnabled: Bool
    public let publicSearchEnabled: Bool
    public var jsonBody: OrderedJSON { .object([
        .init("publiclyVisible", publiclyVisible), .init("publicGuestJoinEnabled", publicGuestJoinEnabled),
        .init("publicSearchEnabled", publicSearchEnabled),
    ]) }
}
public struct PublicSearchSettingResponse: JSONBodyConvertible {
    public let publicSearchEnabled: Bool
    public var jsonBody: OrderedJSON { .object([.init("publicSearchEnabled", publicSearchEnabled)]) }
}
public struct PublicGuestJoinSettingResponse: JSONBodyConvertible {
    public let publicGuestJoinEnabled: Bool
    public var jsonBody: OrderedJSON { .object([.init("publicGuestJoinEnabled", publicGuestJoinEnabled)]) }
}
public struct PublicVisibilityResponse: JSONBodyConvertible {
    public struct Channel: Sendable {
        public let id: String
        public let name: String
        public let description: String?
    }
    public let settings: PublicVisibilityUpdateResponse
    public let slug: String
    public let exposedChannels: [Channel]
    public var jsonBody: OrderedJSON { .object([
        .init("publiclyVisible", settings.publiclyVisible),
        .init("publicGuestJoinEnabled", settings.publicGuestJoinEnabled),
        .init("publicSearchEnabled", settings.publicSearchEnabled),
        .init("slug", slug), .init("exposedChannels", .array(exposedChannels.map { .object([
            .init("id", $0.id), .init("name", $0.name), .init("description", optional: $0.description),
        ]) })),
    ]) }
}
public struct PublicDirectoryCardResponse: JSONBodyConvertible {
    public let serverId: String
    public let serverName: String
    public let slug: String
    public let translationEnabled: Bool
    public let channelIds: [String]
    public let canJoinAsGuest: Bool
    public let translationAvailable: Bool
    public var jsonBody: OrderedJSON { .object([
        .init("server", .object([
            .init("id", serverId), .init("name", serverName), .init("slug", slug),
            .init("avatarUrl", .null), .init("translationEnabled", translationEnabled),
        ])),
        .init("channels", .array(channelIds.map { .object([.init("id", $0)]) })),
        .init("canJoinAsGuest", canJoinAsGuest), .init("translationAvailable", translationAvailable),
    ]) }
}
public enum PublicSettingsError: DomainError {
    case forbiddenVisibility, forbiddenSearch, forbiddenGuestJoin, notFound, serverNotFound
    case invalidVisibility, invalidSearch, invalidGuestJoin, publicRequired
    case authentication(invalidToken: Bool), inviteTokenRequired, invalidInvite, wrongEmail, alreadyMember
    public var status: UInt {
        switch self {
        case .forbiddenVisibility, .forbiddenSearch, .forbiddenGuestJoin: 403
        case .notFound, .serverNotFound: 404
        case .publicRequired: 409
        case .authentication: 401
        default: 400
        }
    }
    public var errorMessage: String {
        switch self {
        case .forbiddenVisibility: "Only the server owner can manage public visibility"
        case .forbiddenSearch: "Only the server owner can manage public search"
        case .forbiddenGuestJoin: "Only the server owner can manage public Guest admission"
        case .notFound: "Not found"
        case .serverNotFound: "Server not found"
        case .invalidVisibility: "publiclyVisible must be a boolean"
        case .invalidSearch: "publicSearchEnabled must be a boolean"
        case .invalidGuestJoin: "publicGuestJoinEnabled must be a boolean"
        case .publicRequired: "Public access must be enabled before visitors can join as Guest"
        case .authentication(let invalid): invalid ? "Invalid or expired token" : "Missing or invalid Authorization header"
        case .inviteTokenRequired: "Invite token is required"
        case .invalidInvite: "Invalid invite token"
        case .wrongEmail: "This invite was sent to a different email address"
        case .alreadyMember: "You are already a member of this server"
        }
    }
    public var errorCode: String? { if case .authentication = self { "auth_required" } else { nil } }
}

public struct PublicFeatureFlagsResponse: JSONBodyConvertible {
    public struct Flag: Sendable { public let key: String; public let enabled: Bool }
    public let flags: [Flag]
    public var jsonBody: OrderedJSON { .object([
        .init("flags", .object(flags.map { .init($0.key, $0.enabled) })),
    ]) }
}
public enum PublicFeatureFlagsError: DomainError {
    case invalidKeys, invalidPlatform
    public var status: UInt { 400 }
    public var errorMessage: String {
        switch self {
        case .invalidKeys: "keys must contain 1-\(PublicFeatureFlags.maxKeys) valid feature flag keys"
        case .invalidPlatform: "platform must be web or mobile"
        }
    }
}

public struct PublicTranslationResponse: JSONBodyConvertible {
    public let results: [[String: String]]
    public var jsonBody: OrderedJSON {
        let leadingKeys = ["messageId", "status", "targetLanguage"]
        return .object([.init("results", .array(results.map { row in
            let keys = leadingKeys + row.keys.sorted().filter { !leadingKeys.contains($0) }
            return .object(keys.compactMap { key in row[key].map { .init(key, $0) } })
        }))])
    }
}
public enum PublicTranslationError: DomainError {
    case tooMany, invalidRequest, notFound, unavailable
    public var status: UInt {
        switch self { case .tooMany: 429; case .invalidRequest: 400; case .notFound: 404; case .unavailable: 403 }
    }
    public var errorMessage: String {
        switch self {
        case .tooMany: "Too many public translation requests, please slow down"
        case .invalidRequest: "Invalid public translation request"
        case .notFound: "Not found"
        case .unavailable: "LLM translation is not available for this server"
        }
    }
    public var responseHeaders: [String: String] { ["Cache-Control": "no-store"] }
}

public enum PublicHistoryError: DomainError {
    case channelMissing, threadMissing, notFound
    public var status: UInt { 404 }
    public var errorMessage: String {
        switch self { case .channelMissing: "Channel not found"; case .threadMissing: "Thread not found"; case .notFound: "Not found" }
    }
    public var responseHeaders: [String: String] { ["Cache-Control": "no-store"] }
}

public enum PublicAttachmentError: DomainError {
    case tooMany, invalidId, notFound
    public var status: UInt { self == .tooMany ? 429 : 404 }
    public var errorMessage: String {
        switch self {
        case .tooMany: "Too many public attachment requests, please slow down"
        case .invalidId: "Attachment not found"
        case .notFound: "Not found"
        }
    }
    public var responseHeaders: [String: String] { ["Cache-Control": "no-store"] }
}
public enum PublicAttachmentResponse: JSONBodyConvertible {
    case file(bytes: String, contentType: String, disposition: String, contentSecurityPolicy: String, inlinePDF: Bool)
    case redirect(location: String)
    public var status: UInt { if case .redirect = self { 302 } else { 200 } }
    public var jsonBody: OrderedJSON {
        switch self { case .file(let bytes, _, _, _, _): .raw(bytes); case .redirect: .raw("") }
    }
    public var headers: ResponseHeaders {
        var values = ["X-Robots-Tag": AppFallback.robotsTag, "Cache-Control": "no-store", "Cross-Origin-Resource-Policy": "cross-origin"]
        switch self {
        case .redirect(let location): values["Location"] = location
        case .file(_, let contentType, let disposition, let policy, let inlinePDF):
            values["Content-Type"] = contentType
            values["Content-Disposition"] = disposition
            values["X-Content-Type-Options"] = "nosniff"
            values["Content-Security-Policy"] = policy
            if inlinePDF { values["Referrer-Policy"] = "no-referrer" }
        }
        return .exact(values)
    }
}
