import Foundation

/// `GET /api/oauth/.well-known/openid-configuration`.
///
/// The unscoped document uses the `SERVER_URL` origin. `scopes_supported` is the
/// public Raft set; reserved and legacy scopes stay off this list.
public enum OAuthDiscovery {
    public static let publicScopes = [
        "openid",
        "profile",
        "email",
        "identity",
        "agent:read",
        "agent:event:write",
        "agent:notification:write",
    ]

    public static func openIDConfiguration(serverURL: String, serverScope: String? = nil) -> HTTPReply {
        guard let origin = issuerOrigin(serverURL) else {
            return json(503, "{\"error\":\"oidc_not_configured\"}")
        }
        let issuer = serverScope.map { "\(origin)/oidc/\($0)" } ?? origin
        let scopes = publicScopes.map { jsonString($0) }.joined(separator: ",")
        let grants = ["authorization_code", "urn:slock:grant-type:agent_request"].map { jsonString($0) }.joined(separator: ",")
        let claims = [
            "sub", "name", "preferred_username", "picture", "email", "email_verified",
            "type", "server_id", "server_slug", "server_role",
        ].map { jsonString($0) }.joined(separator: ",")
        let body = """
        {"issuer":\(jsonString(issuer)),"authorization_endpoint":\(jsonString("\(issuer)/api/oauth/authorize")),"token_endpoint":\(jsonString("\(issuer)/api/oauth/token")),"userinfo_endpoint":\(jsonString("\(issuer)/api/oauth/userinfo")),"jwks_uri":\(jsonString("\(issuer)/api/oauth/jwks")),"agents_endpoint":\(jsonString("\(issuer)/api/oauth/agents")),"serverinfo_endpoint":\(jsonString("\(issuer)/api/oauth/serverinfo")),"grant_types_supported":[\(grants)],"scopes_supported":[\(scopes)],"response_types_supported":["code"],"response_modes_supported":["query"],"subject_types_supported":["public"],"id_token_signing_alg_values_supported":["ES256"],"token_endpoint_auth_methods_supported":["client_secret_basic","client_secret_post"],"code_challenge_methods_supported":["S256"],"claims_supported":[\(claims)]}
        """
        return json(200, body, cacheControl: "public, max-age=300")
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

    private static func json(_ status: Int, _ body: String, cacheControl: String? = nil) -> HTTPReply {
        var headers = [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(Data(body.utf8).count),
        ]
        if let cacheControl { headers["Cache-Control"] = cacheControl }
        return HTTPReply(status: status, headers: headers, body: body)
    }
}
