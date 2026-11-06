import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    /// `GET /api/oauth/authorize`. The browser flow hands off to the web app
    /// after shape checks; the setup page owns client lookup.
    public func browserAuthorize(query: String, appURL: String, serverScope: String? = nil) throws -> OAuthAuthorizeRedirect {
        let params = OAuthRequestParsing.queryParameters(query)
        func invalidRequest(_ message: String) -> OAuthLedgerError {
            OAuthLedgerError(.invalidRequest(description: message))
        }
        if serverScope == nil, let legacyServer = params["server"], !legacyServer.isEmpty {
            throw invalidRequest("The server query parameter is no longer supported; use the /oidc/<server> mount")
        }
        guard params["response_type"] == "code" else { throw invalidRequest("response_type must be code") }
        let clientKey = (params["client_id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientKey.isEmpty else { throw invalidRequest("client_id is required") }
        let redirectURI = params["redirect_uri"] ?? ""
        guard !redirectURI.isEmpty, !redirectURI.contains("#"), let redirectURL = URLComponents(string: redirectURI),
              let redirectScheme = redirectURL.scheme?.lowercased(), redirectScheme == "https" || redirectScheme == "http"
        else { throw invalidRequest("redirect_uri is invalid") }
        let scopeText = (params["scope"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scopeText.isEmpty else { throw invalidRequest("scope is required") }
        let challenge = params["code_challenge"] ?? ""
        if !challenge.isEmpty {
            guard challenge.wholeMatch(of: /^[A-Za-z0-9_-]{43}$/) != nil else {
                throw invalidRequest("code_challenge must be a SHA-256 challenge")
            }
            guard params["code_challenge_method"] == "S256" else {
                throw invalidRequest("code_challenge_method must be S256")
            }
        }
        let nonce = params["nonce"] ?? ""
        guard nonce.utf8.count <= 512 else { throw invalidRequest("nonce is too long") }
        var components = URLComponents(string: appURL.hasSuffix("/") ? String(appURL.dropLast()) : appURL)
        let basePath = components?.path ?? ""
        components?.path = basePath + "/login-with-raft/setup"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "flow", value: "oidc"),
            URLQueryItem(name: "client_id", value: clientKey),
            URLQueryItem(name: "return_to", value: redirectURI),
            URLQueryItem(name: "scope", value: scopeText),
        ]
        if let state = params["state"], !state.isEmpty { items.append(URLQueryItem(name: "state", value: state)) }
        if !nonce.isEmpty { items.append(URLQueryItem(name: "nonce", value: nonce)) }
        if !challenge.isEmpty {
            items.append(URLQueryItem(name: "code_challenge", value: challenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        if let serverScope, !serverScope.isEmpty {
            items.append(URLQueryItem(name: "server", value: serverScope))
        }
        components?.queryItems = items
        guard let location = components?.string else {
            throw OAuthLedgerError(.oidcNotConfigured)
        }
        return OAuthAuthorizeRedirect(location: location)
    }

    /// `GET /api/oauth/jwks`. Public ES256 verification key for the ID tokens.
    public func jwks() throws -> OAuthJWKSResponse {
        guard let body = OAuthIDToken.jwks(secret: jwtSecret) else {
            throw OAuthLedgerError(.oidcNotConfigured)
        }
        return body
    }

    /// `POST /api/oauth/authorize/human`. A member receives a one-time human code.
    public func issueHumanAuthorization(session: OAuthSession, body: String) throws -> OAuthHumanAuthorizationResponse {
        switch session {
        case .missing:
            throw OAuthLedgerError(.authorizationHeaderMissing)
        case .invalid:
            throw OAuthLedgerError(.sessionTokenInvalid)
        case .user(let human):
            return try issueHumanAuthorization(human: human, body: body)
        }
    }
    /// `GET /api/oauth/clients/lookup`. A server member reads one App and the
    /// requested scopes it may not ask for.
    public func clientLookup(session: OAuthSession, clientId: String, serverId: String, scope: String) throws -> OAuthClientLookupResponse {
        switch session {
        case .missing:
            throw OAuthLedgerError(.authorizationHeaderMissing)
        case .invalid:
            throw OAuthLedgerError(.sessionTokenInvalid)
        case .user(let human):
            lock.lock()
            defer { lock.unlock() }
            guard let role = members["\(serverId)\n\(human.id)"] else {
                throw OAuthLedgerError(.clientNotFoundForServer)
            }
            let requested = scope.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let client = clients.first(where: { candidate in
                guard candidate.clientId == clientId, isUserManaged(candidate) else { return false }
                if candidate.appType == "server_local" && candidate.serverId == serverId { return true }
                return installations.contains(where: {
                    $0.clientId == candidate.id && $0.serverId == serverId && $0.status == "active"
                })
            }) {
                let allowed = client.allowedScopes ?? ["openid", "profile", "identity"]
                var scopeValidation: OAuthClientLookupResponse.ScopeValidation?
                if !requested.isEmpty {
                    let validation = validateScopes(requested, allowed: allowed, clientId: client.clientId)
                    scopeValidation = OAuthClientLookupResponse.ScopeValidation(
                        allowed: validation.allowed,
                        reason: validation.reason,
                        disallowedScopes: validation.disallowed
                    )
                }
                return .ready(
                    clientId: client.clientId,
                    appType: client.appType,
                    name: client.name,
                    description: client.descriptionText,
                    homepageUrl: client.homepageUrl,
                    returnUrl: client.returnUrl,
                    allowedScopes: allowed,
                    marketplace: isMarketplaceVisible(client),
                    scopeValidation: scopeValidation
                )
            }
            guard let published = clients.first(where: {
                $0.clientId == clientId && isUserManaged($0) && isMarketplaceVisible($0)
            }) else {
                throw OAuthLedgerError(.clientNotFoundForServer)
            }
            return .installRequired(
                id: published.id,
                clientId: published.clientId,
                appType: published.appType,
                name: published.name,
                description: published.descriptionText,
                homepageUrl: published.homepageUrl,
                returnUrl: published.returnUrl,
                allowedScopes: published.allowedScopes,
                serverId: serverId,
                canInstall: role == "owner" || role == "admin"
            )
        }
    }
    func issueHumanAuthorization(human: OAuthHuman, body: String) throws -> OAuthHumanAuthorizationResponse {
        let object = OAuthRequestBody.parse(body)
        guard let clientKey = object?.string("clientId"), !clientKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OAuthLedgerError(.clientIdRequired)
        }
        guard let serverId = object?.string("serverId"), !serverId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OAuthLedgerError(.serverIdRequired)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: { candidate in
            guard candidate.clientId == clientKey.trimmingCharacters(in: .whitespacesAndNewlines),
                  isUserManaged(candidate)
            else { return false }
            if candidate.appType == "server_local" && candidate.serverId == serverId { return true }
            return candidate.appType == "third_party_global" && installations.contains(where: {
                $0.clientId == candidate.id && $0.serverId == serverId && $0.status == "active"
            })
        }) else {
            throw OAuthLedgerError(.clientNotFoundForServer)
        }
        let requested = object?.value("scopes")
        let oidc = object?.bool("oidc") ?? false
        var nonce: String?
        var challenge: String?
        if oidc {
            if let hint = object?.string("server"), !hint.isEmpty {
                guard let hinted = servers.values.first(where: { ($0.id == hint || $0.slug == hint) && !$0.deleted }),
                      hinted.id == serverId
                else {
                    throw OAuthLedgerError(.serverHintMismatch)
                }
            }
            nonce = object?.string("nonce")
            if let nonce, nonce.utf8.count > 512 {
                throw OAuthLedgerError(.invalidRequestBare)
            }
            challenge = object?.string("codeChallenge")
            if let challenge {
                guard challenge.wholeMatch(of: /^[A-Za-z0-9_-]{43}$/) != nil,
                      object?.string("codeChallengeMethod") == "S256"
                else {
                    throw OAuthLedgerError(.invalidRequestBare)
                }
            }
        }
        let scopes: [String]
        switch requested {
        case nil, .null?:
            scopes = ["openid", "profile"]
        case let value?:
            let validation = validateScopes(value, allowed: client.allowedScopes ?? ["openid", "profile", "identity"], clientId: client.clientId)
            guard validation.allowed, !validation.scopes.isEmpty else {
                if validation.disallowed.isEmpty {
                    throw OAuthLedgerError(.invalidScopeBare)
                }
                throw OAuthLedgerError(.scopeRejected(.init(reason: validation.reason, disallowed: validation.disallowed)))
            }
            scopes = validation.scopes.sorted()
        }
        if let requestedReturnURL = object?.string("returnUrl").flatMap({ $0.isEmpty ? nil : $0 }) {
            guard client.returnUrl == requestedReturnURL, Self.isSafeReturnURL(requestedReturnURL) else {
                throw OAuthLedgerError(.returnUrlNotAllowed)
            }
        }
        guard let server = servers[serverId], !server.deleted, let role = members["\(serverId)\n\(human.id)"] else {
            throw OAuthLedgerError(.notServerMember)
        }
        let code: String
        if oidc {
            var raw = Data(count: 24)
            for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
            code = "raft_oidc_" + base64url(raw)
        } else {
            code = UUID().uuidString.lowercased()
        }
        requests.append(AccessRequest(
            id: code,
            serverId: serverId,
            userId: human.id,
            clientId: client.id,
            scopes: scopes,
            humanName: human.name,
            humanEmail: human.email,
            humanEmailVerified: human.emailVerified,
            humanAvatarUrl: human.avatarUrl,
            oidc: oidc,
            nonce: nonce,
            codeChallenge: challenge,
            oidcRedirectURI: oidc ? client.returnUrl : nil,
            createdAt: Date()
        ))
        return OAuthHumanAuthorizationResponse(
            code: code,
            client: OAuthClientSummary(clientId: client.clientId, appType: client.appType, name: client.name),
            serverId: server.id,
            serverSlug: server.slug,
            role: role,
            scopes: scopes,
            returnUrl: client.returnUrl
        )
    }

    struct ScopeValidation: Sendable {
        var scopes: [String]
        var allowed: Bool
        var reason: String?
        var disallowed: [String]
    }

    static func pkceChallenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A JSON scope list: anything but an array of strings validates as an
    /// empty, disallowed-free refusal, as the any-typed reader did.
    func validateScopes(_ value: JSONValue, allowed: [String], clientId: String) -> ScopeValidation {
        guard case .array(let list) = value else {
            return ScopeValidation(scopes: [], allowed: false, reason: nil, disallowed: [])
        }
        var strings: [String] = []
        for item in list {
            guard case .string(let text) = item else {
                return ScopeValidation(scopes: [], allowed: false, reason: nil, disallowed: [])
            }
            strings.append(text)
        }
        return validateScopes(strings, allowed: allowed, clientId: clientId)
    }

    func validateScopes(_ rawList: [String], allowed: [String], clientId: String) -> ScopeValidation {
        var seen = Set<String>()
        var scopes: [String] = []
        var unsupported = false
        var notAllowed = false
        var disallowed: [String] = []
        for text in rawList {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            if Self.legacyScopeAllowlist[clientId]?.contains(trimmed) == true {
                scopes.append(trimmed)
                continue
            }
            if !Self.raftScopes.contains(trimmed) {
                unsupported = true
                disallowed.append(trimmed)
                continue
            }
            if !allowed.contains(trimmed) {
                notAllowed = true
                disallowed.append(trimmed)
                continue
            }
            scopes.append(trimmed)
        }
        let reason: String?
        if unsupported && notAllowed {
            reason = "mixed"
        } else if unsupported {
            reason = "unsupported"
        } else if notAllowed {
            reason = "not_allowed"
        } else {
            reason = nil
        }
        return ScopeValidation(scopes: scopes, allowed: disallowed.isEmpty, reason: reason, disallowed: disallowed)
    }

    func normalizeScopes(_ value: JSONValue?, allowed: [String], clientId: String) -> [String]? {
        guard let value else { return nil }
        let validation = validateScopes(value, allowed: allowed, clientId: clientId)
        guard validation.allowed, !validation.scopes.isEmpty else { return nil }
        return validation.scopes.sorted()
    }

    static let raftScopes: Set<String> = [
        "openid", "profile", "email", "identity", "agent:read",
        "agent:event:write", "agent:notification:write", "agent:action_request:write",
    ]

    /// Exact legacy tuples still accepted for their original client only.
    static let legacyScopeAllowlist: [String: Set<String>] = [
        "local-collabdoc-1": ["creator", "owner"],
        "linkerdog-796e47": ["meetings:read"],
        "winbox": [
            "winbox:opencli:google", "winbox:opencli:nga",
            "winbox:opencli:qixin", "winbox:opencli:twitter",
        ],
        "winbox-315c18": [
            "winbox:opencli:nga", "winbox:opencli:qixin", "winbox:opencli:slock",
            "winbox:opencli:twitter", "winbox:opencli:wcl", "winbox:python:exec",
        ],
    ]
}
