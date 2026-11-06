import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The provider/OAuth flow boundary: provider discovery, the web start, link
/// start and callback legs, the native-Apple handoff, and the installation
/// lookup. The mobile handoff legs live in `OAuthFlowsMobileService.swift` and
/// the feature-flag evaluation in `OAuthFlowsFeatureFlagService.swift`.
///
/// Every state change is one `OAuthFlowsStore` critical section (the rows live
/// in `AuthProfileStore`); the routes only decode a body and project the
/// returned DTO or the thrown `OAuthFlowsError`. A web or mobile callback that
/// ends in a redirect returns an `OAuthRedirect`; the installation lookup is
/// the OAuth ledger's, reached through its typed outcome.
///
/// Cross-domain dependencies: none beyond the stores (`OAuthFlowsStore` over
/// `AuthProfileStore`, `AgentsRuntimeStore` for the flag rows) and the
/// `OAuthLedger` (installation lookup, server membership).
public struct OAuthFlowsService: Sendable {
    let store: OAuthFlowsStore
    let flags: AgentsRuntimeStore
    let oauth: OAuthLedger
    let now: @Sendable () -> Date

    init(
        store: OAuthFlowsStore,
        flags: AgentsRuntimeStore,
        oauth: OAuthLedger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.flags = flags
        self.oauth = oauth
        self.now = now
    }

    public init(directory source: EmailLoginDirectory) {
        self.init(
            store: OAuthFlowsStore(profiles: source.authProfileStore),
            flags: source.agentsRuntimeStore,
            oauth: source.oauth
        )
    }

    // MARK: - Provider discovery

    /// `GET /api/auth/providers`. A missing platform is web. Anything other than web or mobile is refused first.
    public func authProviders(platform raw: String?) throws -> AuthProvidersResponse {
        let platform = raw ?? "web"
        guard platform == "web" || platform == "mobile" else {
            throw OAuthFlowsError.platformInvalid
        }
        let config = store.config()
        let providers: [(id: String, label: String)] = [
            ("google", "Google"),
            ("github", "GitHub"),
            ("apple", "Apple"),
        ]
        return AuthProvidersResponse(providers: providers.map { provider in
            let enabled = config.configuredProviders.contains(provider.id)
                && (provider.id != "apple" || config.applePlatforms.contains(platform))
            return AuthProviderRow(id: provider.id, label: provider.label, enabled: enabled)
        })
    }

    // MARK: - Web start and link start

    /// `GET /api/auth/:provider/start`. Apple stays closed until its web platform rule is allowed.
    public func startWebOAuth(provider: String, returnTo: String?, linkOnConflict: Bool = false) throws -> OAuthRedirect {
        guard EmailLoginDirectory.socialProviders.contains(provider) else {
            throw OAuthFlowsError.notFound
        }
        let config = store.config()
        guard Self.webProviderAvailable(provider, config) else {
            throw OAuthFlowsError.providerNotConfigured(provider: provider)
        }
        let nonce = EmailLoginDirectory.randomHex(16)
        let safeReturn = EmailLoginDirectory.sanitizeReturnTo(returnTo)
        let state = EmailLoginDirectory.signSocialAuthState(SocialAuthState(
            provider: provider,
            mode: "login",
            nonce: nonce,
            kind: "web",
            mobileRequestId: "",
            desktopNonce: nil,
            returnTo: safeReturn,
            linkOnConflict: linkOnConflict
        ))
        return OAuthRedirect(
            location: Self.webAuthorizationURL(provider: provider, state: state, nonce: nonce, config: config),
            cookie: Self.stateCookie(provider: provider, nonce: nonce, config: config)
        )
    }

    /// `POST /api/auth/:provider/link/start`. The bearer is required before the web gate is checked.
    public func startWebOAuthLink(
        provider: String,
        body: WebOAuthLinkStartRequest,
        authorization: String?
    ) throws -> WebOAuthLinkStarted {
        guard EmailLoginDirectory.socialProviders.contains(provider) else {
            throw OAuthFlowsError.notFound
        }
        let userId = try authorizedUser(authorization)
        let config = store.config()
        guard Self.webProviderAvailable(provider, config) else {
            throw OAuthFlowsError.providerNotConfigured(provider: provider)
        }
        let nonce = EmailLoginDirectory.randomHex(16)
        let safeReturn = EmailLoginDirectory.sanitizeReturnTo(body.returnTo)
        let state = EmailLoginDirectory.signSocialAuthState(SocialAuthState(
            provider: provider,
            mode: "link",
            nonce: nonce,
            kind: "web",
            mobileRequestId: "",
            desktopNonce: nil,
            returnTo: safeReturn,
            linkUserId: userId
        ))
        return WebOAuthLinkStarted(
            url: Self.webAuthorizationURL(provider: provider, state: state, nonce: nonce, config: config),
            cookie: Self.stateCookie(provider: provider, nonce: nonce, config: config)
        )
    }

    // MARK: - Web callback

    /// `POST /api/auth/:provider/callback`. A cancelled Apple form post redirects back with that error.
    ///
    /// The body is a form post (`application/x-www-form-urlencoded`), not JSON,
    /// and the legacy field parser does not fold `+` into a space, so it stays
    /// raw text rather than going through a typed content decoder.
    public func webOAuthCallback(provider: String, body: String, cookie: String?) throws -> OAuthRedirect {
        guard EmailLoginDirectory.socialProviders.contains(provider) else {
            throw OAuthFlowsError.notFound
        }
        let fields = EmailLoginDirectory.formFields(body)
        if let stateToken = fields["state"],
           let parsed = EmailLoginDirectory.verifySocialAuthState(stateToken),
           parsed.kind == "mobile" {
            return try mobileOAuthCallback(
                provider: provider,
                code: fields["code"],
                state: stateToken,
                providerError: fields["error"]
            )
        }
        let config = store.config()
        let appURL = config.appURL
        let invalid = OAuthRedirect(location: EmailLoginDirectory.socialCallbackURL(
            appURL: appURL,
            provider: provider,
            mode: "login",
            returnTo: "/",
            error: "This sign-in link is invalid or expired. Please try again."
        ))
        guard let stateToken = fields["state"],
              let state = EmailLoginDirectory.verifySocialAuthState(stateToken),
              state.kind != "mobile",
              state.provider == provider,
              state.mode == "login" || state.mode == "link"
        else {
            return invalid
        }
        let returnTo = state.returnTo ?? "/"
        func redirect(mode: String, error: String? = nil, code: String? = nil) -> OAuthRedirect {
            OAuthRedirect(location: EmailLoginDirectory.socialCallbackURL(
                appURL: appURL, provider: provider, mode: mode,
                returnTo: returnTo, error: error, code: code
            ))
        }
        if state.mode == "login" {
            let nonce = EmailLoginDirectory.cookieValue(cookie, name: "slock_\(provider)_oauth_nonce")
            if nonce != state.nonce { return invalid }
        }
        let code = fields["code"] ?? ""
        if code.isEmpty {
            let provided = fields["error"] ?? ""
            let error = provided.isEmpty ? "\(EmailLoginDirectory.providerLabel(provider)) sign-in was cancelled" : provided
            return redirect(mode: state.mode, error: error)
        }
        guard let profile = config.webProviderProfile,
              !profile.providerUserId.isEmpty,
              !profile.email.isEmpty
        else { return invalid }
        if state.mode == "link", state.linkUserId == nil { return invalid }
        if !profile.emailVerified {
            return redirect(mode: state.mode, error: "\(provider) account email is not verified")
        }
        let completionCode = EmailLoginDirectory.randomHex(32)
        if state.mode == "login" {
            let outcome = store.recordWebLogin(
                provider: provider,
                providerUserId: profile.providerUserId,
                email: EmailLoginDirectory.normalize(profile.email),
                linkOnConflict: state.linkOnConflict,
                returnTo: returnTo,
                code: completionCode
            )
            switch outcome {
            case .accountConflict:
                return redirect(
                    mode: "login",
                    error: "An account with this email already exists. Sign in with email and password first, then connect \(provider) in Settings."
                )
            case .recorded:
                return redirect(mode: "login", code: completionCode)
            }
        }
        guard let linkUserId = state.linkUserId else { return invalid }
        store.appendSocialCompletion(SocialCompletion(
            provider: provider,
            code: completionCode,
            mode: "link",
            intendedAction: "link",
            email: EmailLoginDirectory.normalize(profile.email),
            returnTo: returnTo,
            userId: linkUserId,
            providerUserId: profile.providerUserId
        ))
        return redirect(mode: "link", code: completionCode)
    }

    // MARK: - Native Apple

    /// `POST /api/auth/mobile/oauth/apple/native/start`. No browser URL is returned. Link mode requires the owner before a row is written.
    public func startNativeApple(_ body: NativeAppleStartRequest, authorization: String? = nil) throws -> NativeAppleStarted {
        let config = store.config()
        guard Self.nativeAppleAvailable(config) else { throw OAuthFlowsError.appleNotConfigured }
        let appEnv = body.appEnv?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard body.platform == "ios", !appEnv.isEmpty else { throw OAuthFlowsError.nativeAppleInvalidRequest }
        guard body.codeChallengeMethod == "S256" else { throw OAuthFlowsError.nativeAppleRequiresS256 }
        guard let mode = body.mode, mode == "login" || mode == "link" else {
            throw OAuthFlowsError.nativeAppleInvalidCredential
        }
        let linkUserId: String?
        if mode == "link" {
            guard let owner = try? authorizedUser(authorization) else {
                throw OAuthFlowsError.nativeAppleAuthRequired
            }
            linkUserId = owner
        } else {
            linkUserId = nil
        }
        guard let returnUri = body.returnUri,
              Self.returnURIAllowed(returnUri, config),
              let challenge = body.codeChallenge,
              Self.isPKCEChallenge(challenge)
        else {
            throw OAuthFlowsError.nativeAppleInvalidCredential
        }
        let id = UUID().uuidString.lowercased()
        let expiresAt = now().addingTimeInterval(600)
        store.insertMobileRequest(MobileOAuthRequest(
            id: id,
            provider: "apple",
            mode: mode,
            status: "pending_provider",
            codeChallenge: challenge,
            returnUri: returnUri,
            nonce: "",
            expiresAt: expiresAt,
            userId: linkUserId
        ))
        let token = EmailLoginDirectory.signNativeAppleRequestToken(
            secret: config.nativeAppleStateSecret,
            requestId: id,
            mode: mode,
            codeChallenge: challenge,
            expiresAt: expiresAt,
            userId: linkUserId
        )
        return NativeAppleStarted(
            requestId: id,
            requestToken: token,
            returnUri: returnUri,
            expiresAt: ISO8601DateFormatter().string(from: expiresAt)
        )
    }

    /// `POST /api/auth/mobile/oauth/apple/native/authorize`. Both the supplied identity token and the exchanged code must agree before a handoff exists.
    /// Link mode checks the owner before the row is claimed. The row is claimed as `provider_processing` before the code exchange, so a second caller is already consumed.
    public func authorizeNativeApple(
        _ body: NativeAppleAuthorizeRequest,
        authorization: String? = nil
    ) async throws -> NativeAppleAuthorized {
        let config = store.config()
        guard Self.nativeAppleAvailable(config) else { throw OAuthFlowsError.appleNotConfigured }
        guard let requestId = body.requestId, !requestId.isEmpty,
              let requestToken = body.requestToken, !requestToken.isEmpty,
              let authorizationCode = body.authorizationCode, !authorizationCode.isEmpty,
              let identityToken = body.identityToken, !identityToken.isEmpty
        else {
            throw OAuthFlowsError.nativeAppleInvalidCredential
        }
        let claims: NativeAppleRequestClaims
        switch EmailLoginDirectory.verifyNativeAppleRequestToken(requestToken, secret: config.nativeAppleStateSecret) {
        case .expired:
            throw OAuthFlowsError.nativeAppleRequestExpired
        case .invalid:
            throw OAuthFlowsError.nativeAppleInvalidCredential
        case .valid(let parsed):
            claims = parsed
        }
        guard claims.requestId == requestId else { throw OAuthFlowsError.nativeAppleInvalidCredential }
        let callerId = try? authorizedUser(authorization)
        let challenge: String
        switch store.claimNativeApple(
            requestId: requestId,
            mode: claims.mode,
            codeChallenge: claims.codeChallenge,
            tokenUserId: claims.userId,
            callerId: callerId,
            now: now()
        ) {
        case .missing:
            throw OAuthFlowsError.nativeAppleInvalidCredential
        case .authRequired:
            throw OAuthFlowsError.nativeAppleAuthRequired
        case .userMismatch:
            throw OAuthFlowsError.nativeAppleLinkMismatch
        case .expired:
            throw OAuthFlowsError.nativeAppleRequestExpired
        case .consumed:
            throw OAuthFlowsError.nativeAppleRequestConsumed
        case .claimed(let storedChallenge):
            challenge = storedChallenge
        }

        let exchange = NativeAppleCodeExchange(
            code: authorizationCode,
            clientId: config.nativeAppleClientId,
            clientSecret: config.nativeAppleClientSecret,
            grantType: "authorization_code",
            redirectUri: nil
        )
        let exchangedToken = await config.exchangeNativeAppleCode?(exchange)
        guard let exchangedToken, !exchangedToken.isEmpty,
              let supplied = EmailLoginDirectory.parseAppleIdentity(identityToken, clientId: config.nativeAppleClientId),
              let exchanged = EmailLoginDirectory.parseAppleIdentity(exchangedToken, clientId: config.nativeAppleClientId),
              supplied.subject == exchanged.subject,
              supplied.nonce == challenge,
              exchanged.nonce == challenge
        else {
            store.failNativeAppleIfProcessing(requestId: requestId)
            throw OAuthFlowsError.nativeAppleInvalidCredential
        }
        if let left = supplied.email, let right = exchanged.email, left != right {
            store.failNativeAppleIfProcessing(requestId: requestId)
            throw OAuthFlowsError.nativeAppleInvalidCredential
        }
        let stored = store.storedAppleIdentity(subject: supplied.subject)
        guard let email = supplied.email ?? exchanged.email ?? stored?.email else {
            store.failNativeAppleIfProcessing(requestId: requestId)
            throw OAuthFlowsError.nativeAppleInvalidCredential
        }
        let loginUserId = claims.mode == "login" ? stored?.userId : nil
        let handoff = EmailLoginDirectory.randomHex(32)
        guard let mode = store.finishNativeApple(
            requestId: requestId,
            email: email,
            subject: supplied.subject,
            loginUserId: loginUserId,
            handoff: handoff
        ) else {
            store.failNativeAppleIfProcessing(requestId: requestId)
            throw OAuthFlowsError.nativeAppleInvalidCredential
        }
        return NativeAppleAuthorized(requestId: requestId, handoffCode: handoff, mode: mode)
    }

    // MARK: - Installation lookup

    /// `POST /api/oauth/installations/lookup`. The OAuth ledger owns the
    /// client and installation rows and answers with a typed outcome.
    public func installationLookup(
        _ body: OAuthInstallationLookupDTO,
        authorization: String?
    ) throws -> OAuthInstallationLookupResponse {
        switch oauth.lookupInstallation(
            authorization: authorization,
            clientId: body.clientId,
            clientSecret: body.clientSecret,
            serverId: body.serverId
        ) {
        case .credentialsRequired: throw OAuthFlowsError.clientCredentialsRequired
        case .invalidCredentials: throw OAuthFlowsError.invalidClientCredentials
        case .serverIdRequired: throw OAuthFlowsError.serverIdRequired
        case .serverIdInvalid: throw OAuthFlowsError.serverIdMustBeServerId
        case .notFound: throw OAuthFlowsError.installationNotFound
        case .found(let installationId, let serverId):
            return OAuthInstallationLookupResponse(installationId: installationId, serverId: serverId)
        }
    }

    // MARK: - Shared helpers

    /// The bearer check of the link routes: a missing header and an unknown
    /// token publish different `401` bodies.
    func authorizedUser(_ authorization: String?) throws -> String {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw OAuthFlowsError.missingAuthorization
        }
        guard let userId = store.userId(forAccessToken: String(authorization.dropFirst("Bearer ".count))) else {
            throw OAuthFlowsError.invalidToken
        }
        return userId
    }

    static func isPKCEChallenge(_ challenge: String) -> Bool {
        challenge.wholeMatch(of: /^[A-Za-z0-9_-]{32,256}$/) != nil
    }

    /// Primary env wins when it parses to at least one URI. Otherwise the legacy
    /// list replaces the defaults. An empty parse falls through.
    static func returnURIAllowed(_ returnUri: String, _ config: OAuthFlowsConfig) -> Bool {
        if EmailLoginDirectory.isDesktopLoopback(returnUri) { return true }
        let primary = EmailLoginDirectory.parseConfiguredMobileReturnURIs(config.mobileOAuthReturnURI)
        if !primary.isEmpty { return primary.contains(returnUri) }
        let legacy = EmailLoginDirectory.parseConfiguredMobileReturnURIs(config.mobileOAuthAllowedReturnURIs)
        if !legacy.isEmpty { return legacy.contains(returnUri) }
        return EmailLoginDirectory.defaultMobileReturnURIs.contains(returnUri)
    }

    static func nativeAppleAvailable(_ config: OAuthFlowsConfig) -> Bool {
        !config.nativeAppleClientId.isEmpty && !config.nativeAppleClientSecret.isEmpty
            && config.applePlatforms.contains("mobile")
    }

    static func mobileAppleAvailable(_ config: OAuthFlowsConfig) -> Bool {
        config.configuredProviders.contains("apple") && config.applePlatforms.contains("mobile")
    }

    static func webProviderAvailable(_ provider: String, _ config: OAuthFlowsConfig) -> Bool {
        guard config.configuredProviders.contains(provider) else { return false }
        if provider == "apple" { return config.applePlatforms.contains("web") }
        return true
    }

    static func webAuthorizationURL(
        provider: String,
        state: String,
        nonce: String,
        config: OAuthFlowsConfig
    ) -> String {
        guard provider == "apple" else {
            return EmailLoginDirectory.authorizationURL(provider: provider, state: state)
        }
        let serverURL = config.serverURL
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        var components = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.appleClientId),
            URLQueryItem(name: "redirect_uri", value: "\(base)/api/auth/apple/callback"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "form_post"),
            URLQueryItem(name: "scope", value: "email"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        return components.string ?? ""
    }

    static func stateCookie(provider: String, nonce: String, config: OAuthFlowsConfig) -> String {
        let encoded = nonce.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? nonce
        var parts = [
            "slock_\(provider)_oauth_nonce=\(encoded)",
            "Path=/api/auth/\(provider)/callback",
            "Max-Age=600",
            "HttpOnly",
            "SameSite=\(provider == "apple" ? "None" : "Lax")",
        ]
        if provider == "apple" || config.serverURL.hasPrefix("https://") {
            parts.append("Secure")
        }
        return parts.joined(separator: "; ")
    }
}
