import Foundation

// MARK: - Phase 5 typed request bodies (Batch D)
//
// Wire shapes for the `api/servers...` JSON bodies registered by
// `ServersFeature`. Each route decodes the typed shape with
// `request.content.decode`; a body that does not decode keeps the directory's
// raw parser, so the upstream status/JSON projection is unchanged for untyped
// or malformed requests.
//
// `encodedBody()` re-encodes the decoded value back into the canonical JSON
// the directory parser reads, which keeps one validation path in
// `EmailLoginDirectory` instead of a second copy in the feature.

/// A published `api/servers...` JSON request body that already has a typed
/// model.
///
/// The directory keeps its raw-body parser because those parsers publish the
/// upstream `error` bodies for every malformed shape. `encodedBody()` hands the
/// parser back the canonical JSON for the shape that was just decoded, so the
/// typed route and the raw fallback read exactly the same keys.
public protocol ServersRequestDTO: Codable, Sendable, Equatable {
    func encodedBody() -> String
}

public extension ServersRequestDTO {
    func encodedBody() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `POST /api/servers` request body.
///
/// `name` and `slug` are required strings; a missing key or a non-string value
/// keeps the raw path and its `Invalid server request` 400. The directory trims
/// both and rejects empty values, so whitespace handling stays there.
public struct ServerCreateRequestDTO: Codable, Sendable, Equatable, ServersRequestDTO {
    public var name: String
    public var slug: String

    public init(name: String, slug: String) {
        self.name = name
        self.slug = slug
    }
}

/// `PATCH /api/servers/:id/members/:memberId` request body.
///
/// `role` is the only field the handler reads; the directory still enforces the
/// `owner|admin|member|guest` membership and the self-demotion rules, so an
/// unknown role keeps the raw path and its `Invalid member role` 400.
public struct ServerMemberRolePatchDTO: Codable, Sendable, Equatable, ServersRequestDTO {
    public var role: String

    public init(role: String) {
        self.role = role
    }
}

/// `POST /api/servers/:id/invites` request body.
///
/// `email` is required and validated by the directory (trimmed, then matched
/// against the address pattern). `role` is optional and defaults to `member`
/// both in the directory and here, so an absent key and an explicit `null`
/// stay equivalent.
public struct ServerInviteCreateDTO: Codable, Sendable, Equatable, ServersRequestDTO {
    public var email: String
    public var role: String?

    public init(email: String, role: String? = nil) {
        self.email = email
        self.role = role
    }
}

/// `POST /api/servers/:id/join-links` request body.
///
/// `expiresAt` is an ISO-8601 string the directory parses (empty means no
/// expiry). `maxUses` is an integer; a string, a fractional number or a value
/// below 1 does not decode as `Int`, so that request keeps the raw path and its
/// `maxUses must be a positive integer` 400. `null` means no cap in both
/// paths.
public struct JoinLinkCreateDTO: Codable, Sendable, Equatable, ServersRequestDTO {
    public var expiresAt: String?
    public var maxUses: Int?

    public init(expiresAt: String? = nil, maxUses: Int? = nil) {
        self.expiresAt = expiresAt
        self.maxUses = maxUses
    }
}

/// `POST /api/servers/:id/setup-reset` request body.
///
/// The reset selects its target by path and reads no fields, so the accepted
/// body is empty (absent, `{}`, or a JSON object whose keys are ignored). The
/// type exists so the route can state that contract and decode the body once
/// without letting a malformed body change the reply.
public struct ServerSetupResetDTO: Codable, Sendable, Equatable, ServersRequestDTO {
    public init() {}
}

/// `PATCH /api/servers/order` request body.
///
/// `serverOrder` is the requested id list. The directory keeps only the
/// servers the caller is a member of and appends the rest, so the sanitizing
/// and the version bump stay there; a missing key or a non-string element
/// keeps the raw path and its `Invalid server order` 400.
public struct ServerOrderPatchDTO: Codable, Sendable, Equatable, ServersRequestDTO {
    public var serverOrder: [String]

    public init(serverOrder: [String]) {
        self.serverOrder = serverOrder
    }
}
