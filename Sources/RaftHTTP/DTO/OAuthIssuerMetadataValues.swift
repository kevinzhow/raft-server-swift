/// Facts from the live scope lookup. The requested segment addresses the
/// issuer/redirect; only serverId binds the token or principal to its owner.
public struct ResolvedOAuthServerScope: Sendable, Equatable {
    public let segment: String
    public let serverId: String
}

public enum OAuthServerScopeResolution: Sendable {
    case resolved(ResolvedOAuthServerScope)
    case failure(OAuthServerScopeError)
}

public enum OAuthServerScopeError: DomainError {
    case invalidSegment
    case notFound

    public var status: UInt {
        switch self {
        case .invalidSegment: 400
        case .notFound: 404
        }
    }

    public var errorMessage: String {
        switch self {
        case .invalidSegment: "invalid_server_scope"
        case .notFound: "Not found"
        }
    }
}

/// Public key facts only. HTTP projection belongs to the metadata service.
struct OAuthVerificationKeyFacts: Sendable {
    let kid: String
    let x: String
    let y: String
}
