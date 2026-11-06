import Foundation

// Success bodies of the OAuth ledger's HTTP operations.
//
// Each body's member order is the published order of the retired hand-built
// `"{…}"` literals, so every DTO conforms to `JSONBodyConvertible` only (never
// `Encodable`, which would select the sorted-key overload in `Respond.swift`).
// Nullable members publish JSON `null` exactly where the legacy bodies did; a
// member the legacy body omitted is appended with `ifPresent:`.

/// `POST /api/oauth/installation-token`.
public struct OAuthInstallationTokenResponse: JSONBodyConvertible, Equatable {
    public var accessToken: String
    public var installationId: String
    public var serverId: String
    public var grantRevision: Int
    public var groups: [String]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("access_token", accessToken),
            OrderedJSONField("token_type", "Bearer"),
            OrderedJSONField("expires_in", 600),
            OrderedJSONField("installation_id", installationId),
            OrderedJSONField("server_id", serverId),
            OrderedJSONField("grant_revision", grantRevision),
            OrderedJSONField("groups", .array(groups.map(OrderedJSON.string))),
            OrderedJSONField("audience", "raft:app-installation-api"),
        ])
    }
}

/// `GET /api/oauth/userinfo` (agent and human principals share the shape).
public struct OAuthUserinfoResponse: JSONBodyConvertible, Equatable {
    public struct Email: Sendable, Equatable {
        public var address: String
        public var verified: Bool
    }

    public var scope: String
    public var clientId: String
    public var clientName: String
    public var serverId: String
    public var serverSlug: String
    public var sub: String
    /// `agent` or `human`.
    public var type: String
    public var serverRole: String
    public var preferredUsername: String
    public var name: String
    public var avatarUrl: String?
    public var picture: String?
    public var description: String?
    /// Published only for a human token that carries the `email` scope.
    public var email: Email?

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("scope", scope)
        body.append("client_id", clientId)
        body.append("client_name", clientName)
        body.append("server_id", serverId)
        body.append("server_slug", serverSlug)
        body.append("sub", sub)
        body.append("type", type)
        body.append("server_role", serverRole)
        body.append("preferred_username", preferredUsername)
        body.append("name", name)
        body.append("avatar_url", optional: avatarUrl)
        body.append("picture", optional: picture)
        body.append("description", optional: description)
        if let email {
            body.append("email", email.address)
            body.append("email_verified", email.verified)
        }
        return body.json
    }
}

/// `GET /api/oauth/serverinfo`.
public struct OAuthServerinfoResponse: JSONBodyConvertible, Equatable {
    public var id: String
    public var slug: String
    public var name: String
    public var avatarUrl: String?
    public var picture: String?
    public var isPaid: Bool

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", id)
        body.append("slug", slug)
        body.append("name", name)
        body.append("avatar_url", optional: avatarUrl)
        body.append("picture", optional: picture)
        body.append("is_paid", isPaid)
        body.append("plan_tier", isPaid ? "paid" : "free")
        return body.json
    }
}

/// `GET /api/oauth/agents`.
public struct OAuthAgentDirectoryResponse: JSONBodyConvertible, Equatable {
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var handle: String
        public var displayName: String
        public var avatarUrl: String?
        public var picture: String?
    }

    public var agents: [Entry]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("agents", .array(agents.map { entry in
                var member = OrderedJSONObject()
                member.append("id", entry.id)
                member.append("handle", entry.handle)
                member.append("display_name", entry.displayName)
                member.append("avatar_url", optional: entry.avatarUrl)
                member.append("picture", optional: entry.picture)
                return member.json
            })),
        ])
    }
}

/// `GET /api/oauth/authorize`: a `302` to the web app's setup page. The body is
/// empty but the reply keeps the JSON header set plus `Location`.
public struct OAuthAuthorizeRedirect: JSONBodyConvertible, Equatable {
    public var location: String

    public var status: UInt { 302 }

    public var headers: ResponseHeaders { .standard(extra: ["Location": location]) }

    public var jsonBody: OrderedJSON { .raw("") }
}

/// OpenID discovery uses the issuer origin and the published member order.
public struct OAuthDiscoveryResponse: JSONBodyConvertible, Equatable {
    public var issuer: String

    public var jsonBody: OrderedJSON {
        func strings(_ values: [String]) -> OrderedJSON { .array(values.map(OrderedJSON.string)) }
        return .object([
            OrderedJSONField("issuer", issuer),
            OrderedJSONField("authorization_endpoint", "\(issuer)/api/oauth/authorize"),
            OrderedJSONField("token_endpoint", "\(issuer)/api/oauth/token"),
            OrderedJSONField("userinfo_endpoint", "\(issuer)/api/oauth/userinfo"),
            OrderedJSONField("jwks_uri", "\(issuer)/api/oauth/jwks"),
            OrderedJSONField("agents_endpoint", "\(issuer)/api/oauth/agents"),
            OrderedJSONField("serverinfo_endpoint", "\(issuer)/api/oauth/serverinfo"),
            OrderedJSONField("grant_types_supported", strings(["authorization_code", "urn:slock:grant-type:agent_request"])),
            OrderedJSONField("scopes_supported", strings(OAuthDiscovery.publicScopes)),
            OrderedJSONField("response_types_supported", strings(["code"])),
            OrderedJSONField("response_modes_supported", strings(["query"])),
            OrderedJSONField("subject_types_supported", strings(["public"])),
            OrderedJSONField("id_token_signing_alg_values_supported", strings(["ES256"])),
            OrderedJSONField("token_endpoint_auth_methods_supported", strings(["client_secret_basic", "client_secret_post"])),
            OrderedJSONField("code_challenge_methods_supported", strings(["S256"])),
            OrderedJSONField("claims_supported", strings([
                "sub", "name", "preferred_username", "picture", "email", "email_verified",
                "type", "server_id", "server_slug", "server_role",
            ])),
        ])
    }
}

/// `GET /api/oauth/jwks`: the key set document the ID-token signer rendered.
public struct OAuthJWKSResponse: JSONBodyConvertible, Equatable {
    public var kid: String
    public var x: String
    public var y: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("keys", .array([
                .object([
                    OrderedJSONField("kty", "EC"),
                    OrderedJSONField("crv", "P-256"),
                    OrderedJSONField("use", "sig"),
                    OrderedJSONField("alg", "ES256"),
                    OrderedJSONField("kid", kid),
                    OrderedJSONField("x", x),
                    OrderedJSONField("y", y),
                ]),
            ])),
        ])
    }
}

/// The App summary a human authorization or an agent access request echoes.
struct OAuthClientSummary: Sendable, Equatable {
    var clientId: String
    var appType: String
    var name: String

    var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("clientId", clientId),
            OrderedJSONField("appType", appType),
            OrderedJSONField("name", name),
            OrderedJSONField("description", .null),
            OrderedJSONField("homepageUrl", .null),
        ])
    }
}

/// `POST /api/oauth/authorize/human`.
public struct OAuthHumanAuthorizationResponse: JSONBodyConvertible, Equatable {
    public var code: String
    var client: OAuthClientSummary
    public var serverId: String
    public var serverSlug: String
    public var role: String
    public var scopes: [String]
    public var returnUrl: String?

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("code", code),
            OrderedJSONField("client", client.jsonBody),
            OrderedJSONField("server", .object([
                OrderedJSONField("id", serverId),
                OrderedJSONField("slug", serverSlug),
                OrderedJSONField("role", role),
            ])),
            OrderedJSONField("scopes", .array(scopes.map(OrderedJSON.string))),
            OrderedJSONField("returnUrl", optional: returnUrl),
        ])
    }
}

/// `GET /api/app-installation/server`.
public struct OAuthAppInstallationServerResponse: JSONBodyConvertible, Equatable {
    public var installationId: String
    public var serverId: String
    public var name: String
    public var slug: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("installation_id", installationId),
            OrderedJSONField("server", .object([
                OrderedJSONField("id", serverId),
                OrderedJSONField("name", name),
                OrderedJSONField("slug", slug),
                OrderedJSONField("avatar_url", .null),
            ])),
        ])
    }
}

/// `GET /api/app-installation/channels`. The list is always empty: the
/// `channel` group is granted but this ledger exposes no channel rows to Apps.
public struct OAuthAppInstallationChannelsResponse: JSONBodyConvertible, Equatable {
    public var installationId: String

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("installation_id", installationId),
            OrderedJSONField("channels", .array([])),
        ])
    }
}

/// `POST /api/oauth/requests/agent`.
public struct OAuthAgentAccessRequestResponse: JSONBodyConvertible, Equatable {
    public var requestId: String
    public var status: String
    var client: OAuthClientSummary
    public var agentId: String
    public var agentName: String
    public var agentDisplayName: String
    public var serverId: String
    public var serverSlug: String
    public var scopes: [String]

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("requestId", requestId),
            OrderedJSONField("status", status),
            OrderedJSONField("client", client.jsonBody),
            OrderedJSONField("agent", .object([
                OrderedJSONField("id", agentId),
                OrderedJSONField("name", agentName),
                OrderedJSONField("displayName", agentDisplayName),
                OrderedJSONField("serverId", serverId),
                OrderedJSONField("serverSlug", serverSlug),
            ])),
            OrderedJSONField("scopes", .array(scopes.map(OrderedJSON.string))),
        ])
    }
}

/// `GET /api/oauth/clients/lookup`: either the App the Server already uses
/// (`ready`) or a published Marketplace App that still has to be installed.
public enum OAuthClientLookupResponse: JSONBodyConvertible, Equatable {
    public struct ScopeValidation: Sendable, Equatable {
        public var allowed: Bool
        public var reason: String?
        public var disallowedScopes: [String]
    }

    case ready(
        clientId: String, appType: String, name: String, description: String?,
        homepageUrl: String?, returnUrl: String?, allowedScopes: [String],
        marketplace: Bool, scopeValidation: ScopeValidation?
    )
    case installRequired(
        id: String, clientId: String, appType: String, name: String, description: String?,
        homepageUrl: String?, returnUrl: String?, allowedScopes: [String]?,
        serverId: String, canInstall: Bool
    )

    public var jsonBody: OrderedJSON {
        switch self {
        case let .ready(clientId, appType, name, description, homepageUrl, returnUrl, allowedScopes, marketplace, validation):
            var body = OrderedJSONObject()
            body.append("clientId", clientId)
            body.append("appType", appType)
            body.append("name", name)
            body.append("description", optional: description)
            body.append("homepageUrl", optional: homepageUrl)
            body.append("returnUrl", optional: returnUrl)
            body.append("logoUrl", .null)
            body.append("setupUrl", .null)
            body.append("setupDescription", .null)
            body.append("allowedScopes", .array(allowedScopes.map(OrderedJSON.string)))
            if marketplace { body.append("marketplace", true) }
            body.append("availability", "ready")
            if let validation {
                body.append("scopeValidation", .object([
                    OrderedJSONField("allowed", validation.allowed),
                    OrderedJSONField("reason", optional: validation.reason),
                    OrderedJSONField("disallowedScopes", .array(validation.disallowedScopes.map(OrderedJSON.string))),
                ]))
            }
            return body.json
        case let .installRequired(id, clientId, appType, name, description, homepageUrl, returnUrl, allowedScopes, serverId, canInstall):
            var body = OrderedJSONObject()
            body.append("id", id)
            body.append("clientId", clientId)
            body.append("appType", appType)
            body.append("name", name)
            body.append("description", optional: description)
            body.append("homepageUrl", optional: homepageUrl)
            body.append("returnUrl", optional: returnUrl)
            body.append("logoUrl", .null)
            body.append("allowedScopes", allowedScopes.map { .array($0.map(OrderedJSON.string)) } ?? .null)
            body.append("marketplace", true)
            body.append("availability", "install_required")
            body.append("setupUrl", .null)
            body.append("setupDescription", .null)
            body.append("installation", .object([
                OrderedJSONField("serverId", serverId),
                OrderedJSONField("canInstall", canInstall),
            ]))
            return body.json
        }
    }
}

/// `POST /api/oauth/agent-events`: `202` for a new event, `200` for a replay of
/// an external event id.
public struct OAuthAgentEventResponse: JSONBodyConvertible, Equatable {
    public var id: String
    public var status: String
    public var deduped: Bool
    public var expiresAt: String
    public var payloadHash: String

    public var httpStatus: UInt { deduped ? 200 : 202 }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("status", status),
            OrderedJSONField("deduped", deduped),
            OrderedJSONField("expiresAt", expiresAt),
            OrderedJSONField("payloadHash", payloadHash),
        ])
    }
}

/// `POST /api/oauth/token`: a human code exchange (optionally with an ID token)
/// or an agent request exchange (optionally resource-bound).
public struct OAuthTokenResponse: JSONBodyConvertible, Equatable {
    public var accessToken: String
    public var expiresIn: Int
    public var scope: String
    public var idToken: String?
    public var resource: String?

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("access_token", accessToken)
        body.append("token_type", "Bearer")
        body.append("expires_in", expiresIn)
        body.append("scope", scope)
        body.append("id_token", ifPresent: idToken)
        body.append("resource", ifPresent: resource)
        return body.json
    }
}
