import Foundation

/// OAuth protocol parsing and published responses over the actual profile and
/// OAuth owners. Construction captures no session, configuration or signing key.
public struct OAuthAuthorizationService: Sendable {
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger

    init(profiles: AuthProfileStore, oauth: OAuthLedger) {
        self.profiles = profiles
        self.oauth = oauth
    }

    /// Nonthrowing and called before body collection. Only the flat human
    /// snapshot crosses that await; generic session-family policy is not used.
    public func beginSession(authorization: String?) -> OAuthSession {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return .missing }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let account = profiles.account(forAnyAccessToken: token) else { return .invalid }
        return .user(OAuthHuman(id: account.id, email: account.email, name: account.name,
            emailVerified: account.emailVerified, avatarUrl: account.avatarUrl))
    }

    /// Unscoped callers capture this after body collection, scoped callers
    /// after G7 resolution and before body collection. No discovery 503 gate.
    public func tokenContext(scope: ResolvedOAuthServerScope? = nil) -> OAuthAuthorizationTokenContext {
        let origin = OAuthDiscovery.issuerOrigin(profiles.oauthDeploymentConfiguration.serverURL) ?? ""
        return OAuthAuthorizationTokenContext(
            issuer: scope.map { "\(origin)/oidc/\($0.segment)" } ?? origin,
            scopeServerId: scope?.serverId
        )
    }

    /// `GET /api/oauth/authorize`. The browser flow hands off to the web app
    /// after shape checks; the setup page owns client lookup.
    public func browserAuthorize(query: String, scope: ResolvedOAuthServerScope? = nil) throws -> OAuthAuthorizeRedirect {
        let appURL = profiles.oauthDeploymentConfiguration.appURL
        let serverScope = scope?.segment
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

    public func issueHumanAuthorization(session: OAuthSession, body: String) throws -> OAuthHumanAuthorizationResponse {
        let human = try sessionHuman(session)
        let object = OAuthRequestBody.parse(body)
        guard let clientKey = object?.string("clientId"), !clientKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OAuthLedgerError(.clientIdRequired)
        }
        guard let serverId = object?.string("serverId"), !serverId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OAuthLedgerError(.serverIdRequired)
        }
        let scopes: OAuthHumanScopeSelection
        switch object?.value("scopes") {
        case nil, .null?: scopes = .defaults
        case .array(let list)?:
            var strings: [String] = []
            var valid = true
            for item in list {
                guard case .string(let text) = item else { valid = false; break }
                strings.append(text)
            }
            scopes = valid ? .values(strings) : .invalid
        default: scopes = .invalid
        }
        let attempt = OAuthHumanAuthorizationAttempt(human: human, clientKey: clientKey, serverId: serverId,
            oidc: object?.bool("oidc") ?? false, serverHint: object?.string("server"), nonce: object?.string("nonce"),
            codeChallenge: object?.string("codeChallenge"), codeChallengeMethod: object?.string("codeChallengeMethod"),
            scopes: scopes, returnUrl: object?.string("returnUrl"))
        do {
            let receipt = try oauth.createHumanAuthorization(attempt)
            return OAuthHumanAuthorizationResponse(code: receipt.code,
                client: OAuthClientSummary(clientId: receipt.clientId, appType: receipt.clientAppType, name: receipt.clientName),
                serverId: receipt.serverId, serverSlug: receipt.serverSlug, role: receipt.role,
                scopes: receipt.scopes, returnUrl: receipt.returnUrl)
        } catch let failure as OAuthAuthorizationFailure { throw published(failure) }
    }

    /// The Feature keeps desktopQuery's raw-name/first-match dialect and its
    /// original argument-evaluation point; it does not use the browser reader.
    public func clientLookup(session: OAuthSession, clientId: String, serverId: String, scope: String) throws -> OAuthClientLookupResponse {
        let human = try sessionHuman(session)
        do {
            switch try oauth.lookupConsent(.init(userId: human.id, clientId: clientId, serverId: serverId, scope: scope)) {
            case let .ready(clientId, appType, name, description, homepageUrl, returnUrl, allowedScopes, marketplace, validation):
                return .ready(clientId: clientId, appType: appType, name: name, description: description,
                    homepageUrl: homepageUrl, returnUrl: returnUrl, allowedScopes: allowedScopes, marketplace: marketplace,
                    scopeValidation: validation.map { .init(allowed: $0.allowed, reason: $0.reason, disallowedScopes: $0.disallowedScopes) })
            case let .installRequired(id, clientId, appType, name, description, homepageUrl, returnUrl, allowedScopes, serverId, canInstall):
                return .installRequired(id: id, clientId: clientId, appType: appType, name: name, description: description,
                    homepageUrl: homepageUrl, returnUrl: returnUrl, allowedScopes: allowedScopes, serverId: serverId, canInstall: canInstall)
            }
        } catch let failure as OAuthAuthorizationFailure { throw published(failure) }
    }

    public func exchangeToken(authorization: String?, body: String, context: OAuthAuthorizationTokenContext) throws -> OAuthTokenResponse {
        let fields = OAuthRequestParsing.tokenFields(body)
        guard let credentials = OAuthRequestParsing.clientCredentials(authorization: authorization, fields: fields) else {
            throw OAuthLedgerError(.clientCredentialsRequired)
        }
        let grantType = fields["grantType"] ?? fields["grant_type"] ?? ""
        let verifierPresent = fields["code_verifier"] != nil || OAuthRequestParsing.jsonBodyHasKey(body, "code_verifier")
        do {
            if grantType == "urn:slock:grant-type:agent_request" {
                if verifierPresent { throw OAuthLedgerError(.invalidGrant(.notPKCERequest)) }
                let requestId = (fields["requestId"] ?? fields["request_id"] ?? "").lowercased()
                guard !requestId.isEmpty else { throw OAuthLedgerError(.requestIdRequired) }
                guard requestId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) != nil else {
                    throw OAuthLedgerError(.invalidGrant(.requestInvalidOrExpired))
                }
                let receipt = try oauth.redeemAgentRequest(.init(requestId: requestId, clientId: credentials.clientId,
                    clientSecret: credentials.clientSecret, scopeServerId: context.scopeServerId, resource: fields["resource"]))
                return OAuthTokenResponse(accessToken: receipt.accessToken, expiresIn: 3600,
                    scope: receipt.scopes.joined(separator: " "), idToken: nil, resource: receipt.resource)
            }
            guard grantType == "authorization_code" else { throw OAuthLedgerError(.unsupportedGrantType) }
            let rawCode = (fields["code"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isOIDC = rawCode.hasPrefix("raft_oidc_")
            if !isOIDC, verifierPresent { throw OAuthLedgerError(.invalidGrant(.codeRedirectOrVerifierInvalid)) }
            let code = isOIDC ? rawCode : rawCode.lowercased()
            guard !code.isEmpty else { throw OAuthLedgerError(.codeRequired) }
            if !isOIDC {
                guard code.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) != nil else {
                    throw OAuthLedgerError(.invalidGrant(.requestInvalidOrExpired))
                }
            }
            let redeemed = try oauth.redeemAuthorizationCode(.init(code: code, isOIDC: isOIDC,
                verifierPresent: verifierPresent, verifier: fields["code_verifier"], redirectURI: fields["redirect_uri"],
                clientId: credentials.clientId, clientSecret: credentials.clientSecret, scopeServerId: context.scopeServerId))
            let expiresIn = max(1, Int(redeemed.expiresAt.timeIntervalSince(redeemed.issuedAt)))
            let identity = OAuthIdentity(sub: redeemed.userId, clientId: redeemed.clientKey, scopes: redeemed.scopes,
                name: redeemed.humanName, email: redeemed.humanEmail, serverId: redeemed.serverId,
                serverSlug: redeemed.serverSlug, serverRole: redeemed.role)
            var idToken: String?
            if redeemed.scopes.contains("openid") {
                guard let signed = OAuthIDToken.sign(identity: identity, issuer: context.issuer, expiresIn: expiresIn,
                    secret: oauth.jwtSecret, nonce: isOIDC ? redeemed.nonce : nil) else {
                    throw OAuthLedgerError(.tokenIssueFailed)
                }
                idToken = signed
            }
            return OAuthTokenResponse(accessToken: redeemed.accessToken, expiresIn: expiresIn,
                scope: redeemed.scopes.joined(separator: " "), idToken: idToken, resource: nil)
        } catch let failure as OAuthAuthorizationFailure { throw published(failure) }
    }

    private func sessionHuman(_ session: OAuthSession) throws -> OAuthHuman {
        switch session {
        case .missing: throw OAuthLedgerError(.authorizationHeaderMissing)
        case .invalid: throw OAuthLedgerError(.sessionTokenInvalid)
        case .user(let human): return human
        }
    }

    private func published(_ failure: OAuthAuthorizationFailure) -> OAuthLedgerError {
        let reason: OAuthLedgerError.Reason
        switch failure {
        case .clientNotFoundForServer: reason = .clientNotFoundForServer
        case .serverHintMismatch: reason = .serverHintMismatch
        case .invalidRequestBare: reason = .invalidRequestBare
        case .invalidScopeBare: reason = .invalidScopeBare
        case .scopeRejected(let rejection): reason = .scopeRejected(.init(reason: rejection.reason, disallowed: rejection.disallowed))
        case .returnUrlNotAllowed: reason = .returnUrlNotAllowed
        case .notServerMember: reason = .notServerMember
        case .invalidClientCredentials: reason = .invalidClientCredentials
        case .invalidGrant(let grant):
            let detail: OAuthLedgerError.Grant
            switch grant {
            case .requestInvalidOrExpired: detail = .requestInvalidOrExpired
            case .codeRedirectOrVerifierInvalid: detail = .codeRedirectOrVerifierInvalid
            case .notPKCERequest: detail = .notPKCERequest
            case .differentServer: detail = .differentServer
            case .identityUnavailable: detail = .identityUnavailable
            }
            reason = .invalidGrant(detail)
        case .accessRequestNotFound: reason = .accessRequestNotFound
        case .requestAlreadyConsumed: reason = .requestAlreadyConsumed
        case .authorizationCodeExpired: reason = .authorizationCodeExpired
        case .authorizationPending: reason = .authorizationPending
        case .resourceRequired: reason = .resourceRequired
        case .resourceMismatch: reason = .resourceMismatch
        }
        return OAuthLedgerError(reason)
    }
}
