/// The scope policy shared by the scoped metadata and protocol routes. It
/// performs one live owner lookup, with no deployment, key or principal gate.
struct OAuthServerScopeResolver: Sendable {
    private let oauth: OAuthLedger

    init(oauth: OAuthLedger) {
        self.oauth = oauth
    }

    enum Lookup: Sendable {
        case resolved(ResolvedOAuthServerScope)
        case invalidSegment
        case notFound
    }

    func resolve(_ segment: String) -> Lookup {
        guard segment.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,63}$/) != nil else {
            return .invalidSegment
        }
        guard let serverId = oauth.serverScopeId(segment) else {
            return .notFound
        }
        return .resolved(ResolvedOAuthServerScope(segment: segment, serverId: serverId))
    }
}
