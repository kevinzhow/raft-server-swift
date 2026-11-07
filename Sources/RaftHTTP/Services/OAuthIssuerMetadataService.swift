/// Public issuer documents and verification keys over the actual deployment
/// and OAuth owners. Scope lookup, deployment reads and key derivation remain
/// separate operations; constructing this service snapshots none of them.
public struct OAuthIssuerMetadataService: Sendable {
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger

    init(profiles: AuthProfileStore, oauth: OAuthLedger) {
        self.profiles = profiles
        self.oauth = oauth
    }

    /// Called before a scoped route reads configuration, authentication or body.
    public func resolveServerScope(_ segment: String) -> OAuthServerScopeResolution {
        switch OAuthServerScopeResolver(oauth: oauth).resolve(segment) {
        case .resolved(let scope): .resolved(scope)
        case .invalidSegment: .failure(.invalidSegment)
        case .notFound: .failure(.notFound)
        }
    }

    /// A resolved scoped request uses its original segment. An unscoped request
    /// only reads the live deployment URL and does not query the OAuth owner.
    public func discovery(scope: ResolvedOAuthServerScope? = nil) throws -> OAuthDiscoveryResponse {
        try OAuthDiscovery.openIDConfiguration(
            serverURL: profiles.oauthDeploymentConfiguration.serverURL,
            serverScope: scope?.segment
        )
    }

    /// The verification-key gate is independent of discovery's origin gate.
    public func jwks() throws -> OAuthJWKSResponse {
        guard let facts = oauth.issuerVerificationKey() else {
            throw OAuthLedgerError(.oidcNotConfigured)
        }
        return OAuthJWKSResponse(kid: facts.kid, x: facts.x, y: facts.y)
    }
}
