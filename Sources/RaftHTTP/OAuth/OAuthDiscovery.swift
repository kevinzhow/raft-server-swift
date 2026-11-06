import Foundation

/// `GET /api/oauth/.well-known/openid-configuration` and its OIDC mounts.
public enum OAuthDiscovery {
    public static let publicScopes = [
        "openid", "profile", "email", "identity", "agent:read",
        "agent:event:write", "agent:notification:write",
    ]

    public static func openIDConfiguration(
        serverURL: String,
        serverScope: String? = nil
    ) throws -> OAuthDiscoveryResponse {
        guard let origin = issuerOrigin(serverURL) else {
            throw OAuthLedgerError(.oidcNotConfigured)
        }
        return OAuthDiscoveryResponse(issuer: serverScope.map { "\(origin)/oidc/\($0)" } ?? origin)
    }

    /// Node `URL.origin` for an HTTP(S) `SERVER_URL`. A bad value is not configured.
    public static func issuerOrigin(_ serverURL: String) -> String? {
        var trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}
