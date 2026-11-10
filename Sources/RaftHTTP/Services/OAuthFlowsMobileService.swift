import Foundation

/// The mobile handoff legs of the OAuth flow surface (pure move out of
/// `OAuthFlowsService.swift`): the start routes, the provider callback and the
/// two completion routes. Every state change is one `OAuthFlowsStore` critical
/// section; this file only validates a request shape, calls it and maps the
/// outcome to a DTO or an `OAuthFlowsError`.
extension OAuthFlowsService {
    /// `POST /api/auth/mobile/oauth/start`. The desktop nonce is taken from the loopback return URI.
    public func startMobileOAuth(_ body: MobileOAuthStartRequest) async throws -> MobileOAuthStarted {
        guard body.isObject else { throw OAuthFlowsError.invalidMobileStart }
        let config = store.config()
        guard let returnUri = body.returnUri, Self.returnURIAllowed(returnUri, config) else {
            throw OAuthFlowsError.returnURINotAllowed
        }
        guard let provider = body.provider,
              AuthRedirects.socialProviders.contains(provider),
              let mode = body.mode, mode == "login" || mode == "link",
              let challenge = body.codeChallenge,
              Self.isPKCEChallenge(challenge)
        else {
            throw OAuthFlowsError.invalidMobileStart
        }
        if provider == "apple", !Self.mobileAppleAvailable(config) {
            throw OAuthFlowsError.appleNotConfigured
        }
        return try await openedMobileOAuth(
            provider: provider, mode: mode, returnUri: returnUri, challenge: challenge, userId: nil,
            linkOnConflict: body.linkOnConflict
        )
    }

    /// `POST /api/auth/mobile/oauth/:provider/link/start`. The bearer is required before a request row is written.
    public func startMobileOAuthLink(
        provider: String,
        body: MobileOAuthStartRequest,
        authorization: String?
    ) async throws -> MobileOAuthStarted {
        guard AuthRedirects.socialProviders.contains(provider) else {
            throw OAuthFlowsError.notFound
        }
        let userId = try authorizedUser(authorization)
        guard body.isObject else { throw OAuthFlowsError.invalidMobileStart }
        let config = store.config()
        guard let returnUri = body.returnUri, Self.returnURIAllowed(returnUri, config) else {
            throw OAuthFlowsError.returnURINotAllowed
        }
        guard let challenge = body.codeChallenge, Self.isPKCEChallenge(challenge) else {
            throw OAuthFlowsError.invalidMobileStart
        }
        return try await openedMobileOAuth(
            provider: provider, mode: "link", returnUri: returnUri, challenge: challenge, userId: userId
        )
    }

    private func openedMobileOAuth(
        provider: String,
        mode: String,
        returnUri: String,
        challenge: String,
        userId: String?,
        linkOnConflict: Bool = false
    ) async throws -> MobileOAuthStarted {
        let id = UUID().uuidString.lowercased()
        let nonce = AuthTokenCodec.randomHex(16)
        let desktopNonce = AuthRedirects.desktopNonce(from: returnUri)
        let expiresAt = now().addingTimeInterval(600)
        let state = try await AuthTokenCodec.signSocialAuthState(SocialAuthState(
            provider: provider,
            mode: mode,
            nonce: nonce,
            kind: "mobile",
            mobileRequestId: id,
            desktopNonce: desktopNonce
        ), secret: store.config().socialAuthStateSecret)
        store.insertMobileRequest(MobileOAuthRequest(
            id: id,
            provider: provider,
            mode: mode,
            status: "pending_provider",
            codeChallenge: challenge,
            returnUri: returnUri,
            nonce: nonce,
            expiresAt: expiresAt,
            userId: userId,
            linkOnConflict: linkOnConflict
        ))
        return MobileOAuthStarted(
            requestId: id,
            authorizationUrl: AuthRedirects.authorizationURL(provider: provider, state: state),
            returnUri: returnUri,
            expiresAt: ISO8601DateFormatter().string(from: expiresAt)
        )
    }

    /// `GET /api/auth/:provider/callback`. A desktop nonce that does not match the stored return URI is refused before any provider exchange.
    public func mobileOAuthCallback(
        provider: String,
        code: String?,
        state: String?,
        providerError: String? = nil
    ) async throws -> OAuthRedirect {
        let config = store.config()
        guard let state, let parsed = await AuthTokenCodec.verifySocialAuthState(state, secret: config.socialAuthStateSecret),
              parsed.kind == "mobile", parsed.provider == provider
        else {
            throw OAuthFlowsError.invalidMobileRequest
        }
        let handoff = AuthTokenCodec.randomHex(32)
        switch store.mobileCallback(
            requestId: parsed.mobileRequestId,
            provider: provider,
            mode: parsed.mode,
            stateDesktopNonce: parsed.desktopNonce,
            code: code,
            providerError: providerError,
            profile: config.mobileProviderProfile,
            handoff: handoff
        ) {
        case .invalidRequest:
            throw OAuthFlowsError.invalidMobileRequest
        case .failed(let returnUri, let mode, let error):
            return OAuthRedirect(location: AuthRedirects.failureLocation(
                returnUri: returnUri, provider: provider, mode: mode, error: error
            ))
        case .completed(let returnUri, let mode):
            return OAuthRedirect(location: AuthRedirects.loopbackLocation(
                returnUri: returnUri, provider: provider, mode: mode, code: handoff
            ))
        }
    }

    /// `POST /api/auth/mobile/oauth/complete`. The handoff code is spent only after the PKCE verifier matches.
    public func completeMobileOAuth(_ body: MobileOAuthCompleteRequest) throws -> MobileOAuthCompleted {
        guard let code = body.code, !code.isEmpty else { throw OAuthFlowsError.invalidMobileCompletion }
        let needed = store.mobilePasswordPlaceholderNeeded(code: code)
        let placeholder = needed ? try PasswordCredential.hash(AuthTokenCodec.randomHex(32)) : nil
        return try finishMobileOAuth(body, passwordPlaceholder: placeholder)
    }

    public func completeMobileOAuthAsync(_ body: MobileOAuthCompleteRequest) async throws -> MobileOAuthCompleted {
        guard let code = body.code, !code.isEmpty else { throw OAuthFlowsError.invalidMobileCompletion }
        let needed = store.mobilePasswordPlaceholderNeeded(code: code)
        let placeholder = needed ? try await PasswordWork.hash(AuthTokenCodec.randomHex(32)) : nil
        return try finishMobileOAuth(body, passwordPlaceholder: placeholder)
    }

    private func finishMobileOAuth(_ body: MobileOAuthCompleteRequest, passwordPlaceholder: String?) throws -> MobileOAuthCompleted {
        guard let code = body.code, !code.isEmpty else {
            throw OAuthFlowsError.invalidMobileCompletion
        }
        let outcome = store.completeMobile(
            code: code,
            verifier: body.codeVerifier ?? "",
            pendingLinkToken: body.pendingLinkToken,
            acceptTerms: body.acceptTerms == true,
            termsVersion: body.termsVersion,
            privacyVersion: body.privacyVersion,
            now: now(),
            passwordPlaceholder: passwordPlaceholder
        )
        switch outcome {
        case .refused(let refusal):
            throw Self.error(for: refusal)
        case .pendingLinkSpent(let userId, let linkedProvider, let tokens):
            return .pendingLinkSpent(
                userId: userId,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                linkedProvider: linkedProvider
            )
        case .linkRequired(let token, let provider, let email, let expiresAt, let hasPassword, let providers, let returnUri):
            throw OAuthFlowsError.accountLinkRequired(
                pendingLinkToken: token,
                provider: provider,
                email: email,
                expiresAt: ISO8601DateFormatter().string(from: expiresAt),
                hasPassword: hasPassword,
                providers: providers,
                returnUri: returnUri
            )
        case .signedIn(let signedIn):
            return .signedIn(
                id: signedIn.userId,
                email: signedIn.email,
                name: signedIn.name,
                provider: signedIn.provider,
                mode: signedIn.mode,
                returnUri: signedIn.returnUri,
                accessToken: signedIn.tokens.accessToken,
                refreshToken: signedIn.tokens.refreshToken,
                signupSurveyCompletedAt: signedIn.signupSurveyCompletedAt,
                signupRole: signedIn.signupRole
            )
        }
    }

    /// `POST /api/auth/mobile/oauth/:provider/link/complete`. A different account is refused before the handoff is spent.
    public func completeMobileOAuthLink(
        provider: String,
        body: MobileOAuthCompleteRequest,
        authorization: String?
    ) throws -> MobileOAuthLinkCompleted {
        guard AuthRedirects.socialProviders.contains(provider) else {
            throw OAuthFlowsError.notFound
        }
        let caller = try authorizedUser(authorization)
        guard let code = body.code, !code.isEmpty else {
            throw OAuthFlowsError.invalidMobileCompletion
        }
        switch store.completeMobileLink(
            provider: provider,
            callerId: caller,
            code: code,
            verifier: body.codeVerifier ?? "",
            now: now()
        ) {
        case .refused(let refusal):
            throw Self.error(for: refusal)
        case .linked(let returnUri, let identities):
            return MobileOAuthLinkCompleted(
                provider: provider,
                returnUri: returnUri,
                identities: identities.map {
                    MobileLinkedIdentity(provider: $0.provider, providerEmail: $0.providerEmail)
                }
            )
        }
    }

    private static func error(for refusal: MobileHandoffRefusal) -> OAuthFlowsError {
        switch refusal {
        case .consumed: .handoffCodeConsumed
        case .invalid: .invalidMobileCompletion
        case .expired: .handoffCodeExpired
        case .pkceMismatch: .pkceMismatch
        case .providerMismatch: .providerMismatch
        case .modeMismatch: .modeMismatch
        case .linkMismatch: .mobileLinkMismatch
        case .pendingLinkExpired: .pendingLinkExpired
        case .pendingLinkAccountMismatch: .pendingLinkAccountMismatch
        case .legalRequired: .legalAcceptanceRequired
        case .termsChanged: .termsChanged
        }
    }
}
