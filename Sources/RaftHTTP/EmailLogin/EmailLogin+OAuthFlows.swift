import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EmailLoginDirectory {


    /// `GET /api/auth/providers`. A missing platform is web. Anything other than web or mobile is refused first.
    public func authProviders(platform raw: String?) -> HTTPReply {
        let platform = raw ?? "web"
        guard platform == "web" || platform == "mobile" else {
            return Self.json(400, "{\"code\":\"platform_invalid\",\"error\":\"platform must be web or mobile\"}")
        }
        lock.lock()
        let configured = configuredSocialAuthProviders
        let allowed = appleLoginPlatforms
        lock.unlock()
        let providers: [(id: String, label: String)] = [
            ("google", "Google"),
            ("github", "GitHub"),
            ("apple", "Apple"),
        ]
        let listed = providers.map { provider in
            let enabled = configured.contains(provider.id) && (provider.id != "apple" || allowed.contains(platform))
            return "{\"id\":\(jsonString(provider.id)),\"label\":\(jsonString(provider.label)),\"enabled\":\(enabled ? "true" : "false")}"
        }.joined(separator: ",")
        return Self.json(200, "{\"providers\":[\(listed)]}")
    }

    /// `POST /api/auth/mobile/oauth/start`. The desktop nonce is taken from the loopback return URI.
    public func startMobileOAuth(body: String) -> HTTPReply {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth start\"}")
        }
        guard let returnUri = object["returnUri"] as? String,
              Self.isDesktopLoopback(returnUri) || configuredMobileReturnURIs().contains(returnUri)
        else {
            return Self.returnURINotAllowed
        }
        guard let provider = object["provider"] as? String,
              Self.socialProviders.contains(provider),
              let mode = object["mode"] as? String, mode == "login" || mode == "link",
              let challenge = object["codeChallenge"] as? String,
              challenge.wholeMatch(of: /^[A-Za-z0-9_-]{32,256}$/) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth start\"}")
        }
        if provider == "apple", !mobileAppleAvailable() {
            return Self.appleNotConfigured
        }
        return openedMobileOAuth(
            provider: provider, mode: mode, returnUri: returnUri, challenge: challenge, userId: nil,
            linkOnConflict: object["linkOnConflict"] as? Bool ?? false
        )
    }

    /// `GET /api/auth/:provider/start`. Apple stays closed until its web platform rule is allowed.
    public func startWebOAuth(provider: String, returnTo: String?, linkOnConflict: Bool = false) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        guard webProviderAvailable(provider) else {
            return Self.json(404, "{\"error\":\"\(Self.providerLabel(provider)) sign-in is not configured\"}")
        }
        let nonce = Self.randomHex(16)
        let safeReturn = Self.sanitizeReturnTo(returnTo)
        let state = Self.signSocialAuthState(SocialAuthState(
            provider: provider,
            mode: "login",
            nonce: nonce,
            kind: "web",
            mobileRequestId: "",
            desktopNonce: nil,
            returnTo: safeReturn,
            linkOnConflict: linkOnConflict
        ))
        let url = webAuthorizationURL(provider: provider, state: state, nonce: nonce)
        return Self.redirect(url, cookie: stateCookie(provider: provider, nonce: nonce))
    }

    /// `POST /api/auth/:provider/link/start`. The bearer is required before the web gate is checked.
    public func startWebOAuthLink(provider: String, body: String, authorization: String?) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard webProviderAvailable(provider) else {
            return Self.json(404, "{\"error\":\"\(Self.providerLabel(provider)) sign-in is not configured\"}")
        }
        let returnTo = Self.returnToField(body)
        let nonce = Self.randomHex(16)
        let safeReturn = Self.sanitizeReturnTo(returnTo)
        let state = Self.signSocialAuthState(SocialAuthState(
            provider: provider,
            mode: "link",
            nonce: nonce,
            kind: "web",
            mobileRequestId: "",
            desktopNonce: nil,
            returnTo: safeReturn,
            linkUserId: userId
        ))
        let url = webAuthorizationURL(provider: provider, state: state, nonce: nonce)
        let payload = "{\"url\":\(jsonString(url))}"
        return Self.json(200, payload, cookie: stateCookie(provider: provider, nonce: nonce))
    }

    /// `POST /api/auth/:provider/callback`. A cancelled Apple form post redirects back with that error.
    public func webOAuthCallback(provider: String, body: String, cookie: String?) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let fields = Self.formFields(body)
        if let stateToken = fields["state"],
           let parsed = Self.verifySocialAuthState(stateToken),
           parsed.kind == "mobile" {
            return mobileOAuthCallback(
                provider: provider,
                code: fields["code"],
                state: stateToken,
                providerError: fields["error"]
            )
        }
        let invalid = Self.socialCallbackURL(
            appURL: appURL,
            provider: provider,
            mode: "login",
            returnTo: "/",
            error: "This sign-in link is invalid or expired. Please try again."
        )
        guard let stateToken = fields["state"],
              let state = Self.verifySocialAuthState(stateToken),
              state.kind != "mobile",
              state.provider == provider,
              state.mode == "login" || state.mode == "link"
        else {
            return Self.redirect(invalid)
        }
        if state.mode == "login" {
            let nonce = Self.cookieValue(cookie, name: "slock_\(provider)_oauth_nonce")
            if nonce != state.nonce {
                return Self.redirect(invalid)
            }
        }
        let code = fields["code"] ?? ""
        if code.isEmpty {
            let provided = fields["error"] ?? ""
            let error = provided.isEmpty ? "\(Self.providerLabel(provider)) sign-in was cancelled" : provided
            return Self.redirect(Self.socialCallbackURL(
                appURL: appURL,
                provider: provider,
                mode: state.mode,
                returnTo: state.returnTo ?? "/",
                error: error
            ))
        }
        if state.mode == "login" {
            guard let profile = webProviderProfile,
                  !profile.providerUserId.isEmpty,
                  !profile.email.isEmpty
            else { return Self.redirect(invalid) }
            if !profile.emailVerified {
                return Self.redirect(Self.socialCallbackURL(
                    appURL: appURL, provider: provider, mode: "login",
                    returnTo: state.returnTo ?? "/",
                    error: "\(provider) account email is not verified"
                ))
            }
            let email = Self.normalize(profile.email)
            let completionCode = Self.randomHex(32)
            let existing = accounts[email]
            let existingIdentity = linkedIdentities.first {
                $0.provider == provider && $0.providerUserId == profile.providerUserId
            }
            if let existing, existingIdentity?.userId != existing.id {
                if !state.linkOnConflict {
                    return Self.redirect(Self.socialCallbackURL(
                        appURL: appURL, provider: provider, mode: "login",
                        returnTo: state.returnTo ?? "/",
                        error: "An account with this email already exists. Sign in with email and password first, then connect \(provider) in Settings."
                    ))
                }
                lock.lock()
                socialCompletions.append(SocialCompletion(
                    provider: provider, code: completionCode, mode: "login",
                    intendedAction: "link", email: email,
                    returnTo: state.returnTo ?? "/", userId: nil,
                    providerUserId: profile.providerUserId, linkOnConflict: true
                ))
                lock.unlock()
                return Self.redirect(Self.socialCallbackURL(
                    appURL: appURL, provider: provider, mode: "login",
                    returnTo: state.returnTo ?? "/", code: completionCode
                ))
            }
            lock.lock()
            socialCompletions.append(SocialCompletion(
                provider: provider, code: completionCode, mode: "login",
                intendedAction: "login", email: email,
                returnTo: state.returnTo ?? "/",
                userId: existing?.id, providerUserId: profile.providerUserId
            ))
            lock.unlock()
            return Self.redirect(Self.socialCallbackURL(
                appURL: appURL, provider: provider, mode: "login",
                returnTo: state.returnTo ?? "/", code: completionCode
            ))
        }
        guard state.mode == "link",
              let linkUserId = state.linkUserId,
              let profile = webProviderProfile,
              !profile.providerUserId.isEmpty,
              !profile.email.isEmpty
        else {
            return Self.redirect(invalid)
        }
        if !profile.emailVerified {
            return Self.redirect(Self.socialCallbackURL(
                appURL: appURL,
                provider: provider,
                mode: state.mode,
                returnTo: state.returnTo ?? "/",
                error: "\(provider) account email is not verified"
            ))
        }
        let completionCode = Self.randomHex(32)
        lock.lock()
        socialCompletions.append(SocialCompletion(
            provider: provider,
            code: completionCode,
            mode: "link",
            intendedAction: "link",
            email: Self.normalize(profile.email),
            returnTo: state.returnTo ?? "/",
            userId: linkUserId,
            providerUserId: profile.providerUserId
        ))
        lock.unlock()
        return Self.redirect(Self.socialCallbackURL(
            appURL: appURL,
            provider: provider,
            mode: "link",
            returnTo: state.returnTo ?? "/",
            code: completionCode
        ))
    }

    /// `POST /api/auth/mobile/oauth/apple/native/start`. No browser URL is returned. Link mode requires the owner before a row is written.
    public func startNativeApple(body: String, authorization: String? = nil) -> HTTPReply {
        guard nativeAppleAvailable() else { return Self.appleNotConfigured }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.nativeAppleInvalidRequest
        }
        let platform = object["platform"] as? String
        let appEnv = (object["appEnv"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard platform == "ios", !appEnv.isEmpty else { return Self.nativeAppleInvalidRequest }
        guard object["codeChallengeMethod"] as? String == "S256" else {
            return Self.json(400, "{\"code\":\"invalid_request\",\"error\":\"Native Apple sign-in requires an S256 challenge\"}")
        }
        guard let mode = object["mode"] as? String, mode == "login" || mode == "link" else {
            return Self.nativeAppleInvalidCredential
        }
        let linkUserId: String?
        if mode == "link" {
            switch authorize(authorization) {
            case .rejected:
                return Self.nativeAppleAuthRequired
            case .user(let id):
                linkUserId = id
            }
        } else {
            linkUserId = nil
        }
        guard let returnUri = object["returnUri"] as? String,
              Self.isDesktopLoopback(returnUri) || configuredMobileReturnURIs().contains(returnUri),
              let challenge = object["codeChallenge"] as? String,
              challenge.wholeMatch(of: /^[A-Za-z0-9_-]{32,256}$/) != nil
        else {
            return Self.nativeAppleInvalidCredential
        }
        let id = UUID().uuidString.lowercased()
        let expiresAt = Date(timeIntervalSinceNow: 600)
        lock.lock()
        mobileRequests[id] = MobileOAuthRequest(
            id: id,
            provider: "apple",
            mode: mode,
            status: "pending_provider",
            codeChallenge: challenge,
            returnUri: returnUri,
            nonce: "",
            expiresAt: expiresAt,
            userId: linkUserId
        )
        lock.unlock()
        let token = Self.signNativeAppleRequestToken(
            secret: nativeAppleStateSecret,
            requestId: id,
            mode: mode,
            codeChallenge: challenge,
            expiresAt: expiresAt,
            userId: linkUserId
        )
        let expires = ISO8601DateFormatter().string(from: expiresAt)
        let response = "{\"requestId\":\(jsonString(id)),\"requestToken\":\(jsonString(token)),\"returnUri\":\(jsonString(returnUri)),\"expiresAt\":\(jsonString(expires))}"
        return Self.json(201, response)
    }

    /// `POST /api/auth/mobile/oauth/apple/native/authorize`. Both the supplied identity token and the exchanged code must agree before a handoff exists.
    /// Link mode checks the owner before the row is claimed. The row is claimed as `provider_processing` before the code exchange, so a second caller is already consumed.
    public func authorizeNativeApple(body: String, authorization: String? = nil) async -> HTTPReply {
        guard nativeAppleAvailable() else { return Self.appleNotConfigured }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestId = object["requestId"] as? String, !requestId.isEmpty,
              let requestToken = object["requestToken"] as? String, !requestToken.isEmpty,
              let authorizationCode = object["authorizationCode"] as? String, !authorizationCode.isEmpty,
              let identityToken = object["identityToken"] as? String, !identityToken.isEmpty
        else {
            return Self.nativeAppleInvalidCredential
        }
        let claims: NativeAppleRequestClaims
        switch Self.verifyNativeAppleRequestToken(requestToken, secret: nativeAppleStateSecret) {
        case .expired:
            return Self.nativeAppleRequestExpired
        case .invalid:
            return Self.nativeAppleInvalidCredential
        case .valid(let parsed):
            claims = parsed
        }
        guard claims.requestId == requestId else { return Self.nativeAppleInvalidCredential }
        let callerId: String?
        if case .user(let id) = authorize(authorization) {
            callerId = id
        } else {
            callerId = nil
        }
        let challenge: String
        switch claimNativeApple(
            requestId: requestId,
            mode: claims.mode,
            codeChallenge: claims.codeChallenge,
            tokenUserId: claims.userId,
            callerId: callerId
        ) {
        case .missing:
            return Self.nativeAppleInvalidCredential
        case .authRequired:
            return Self.nativeAppleAuthRequired
        case .userMismatch:
            return Self.nativeAppleLinkMismatch
        case .expired:
            return Self.nativeAppleRequestExpired
        case .consumed:
            return Self.nativeAppleRequestConsumed
        case .claimed(let storedChallenge):
            challenge = storedChallenge
        }

        let exchange = NativeAppleCodeExchange(
            code: authorizationCode,
            clientId: nativeAppleClientId,
            clientSecret: nativeAppleClientSecret,
            grantType: "authorization_code",
            redirectUri: nil
        )
        let exchangedToken = await exchangeNativeAppleCode?(exchange)
        guard let exchangedToken, !exchangedToken.isEmpty,
              let supplied = parseAppleIdentity(identityToken),
              let exchanged = parseAppleIdentity(exchangedToken),
              supplied.subject == exchanged.subject,
              supplied.nonce == challenge,
              exchanged.nonce == challenge
        else {
            failNativeAppleIfProcessing(requestId: requestId)
            return Self.nativeAppleInvalidCredential
        }
        if let left = supplied.email, let right = exchanged.email, left != right {
            failNativeAppleIfProcessing(requestId: requestId)
            return Self.nativeAppleInvalidCredential
        }
        let stored = storedAppleIdentity(subject: supplied.subject)
        guard let email = supplied.email ?? exchanged.email ?? stored?.email else {
            failNativeAppleIfProcessing(requestId: requestId)
            return Self.nativeAppleInvalidCredential
        }
        let loginUserId = claims.mode == "login" ? stored?.userId : nil
        guard let completed = finishNativeApple(
            requestId: requestId,
            email: email,
            subject: supplied.subject,
            loginUserId: loginUserId
        ) else {
            failNativeAppleIfProcessing(requestId: requestId)
            return Self.nativeAppleInvalidCredential
        }
        let response = "{\"requestId\":\(jsonString(requestId)),\"handoffCode\":\(jsonString(completed.handoff)),\"provider\":\"apple\",\"mode\":\(jsonString(completed.mode))}"
        return Self.json(200, response)
    }


    /// Moves `pending_provider` to `provider_processing` before any Apple call. A past row expiry and a link-owner mismatch are decided before that claim.
    func claimNativeApple(
        requestId: String,
        mode: String,
        codeChallenge: String,
        tokenUserId: String?,
        callerId: String?
    ) -> NativeAppleClaim {
        lock.lock()
        defer { lock.unlock() }
        guard var request = mobileRequests[requestId],
              request.provider == "apple",
              request.mode == mode,
              request.codeChallenge == codeChallenge,
              request.userId == tokenUserId
        else { return .missing }
        if request.mode == "link" {
            guard let callerId else { return .authRequired }
            guard request.userId == callerId else { return .userMismatch }
        }
        if request.expiresAt < Date() {
            request.status = "expired"
            mobileRequests[requestId] = request
            return .expired
        }
        guard request.status == "pending_provider" else { return .consumed }
        request.status = "provider_processing"
        mobileRequests[requestId] = request
        return .claimed(request.codeChallenge)
    }

    /// A previously linked Apple subject can supply the verified email Apple omits on a later login.
    func storedAppleIdentity(subject: String) -> (userId: String, email: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = linkedIdentities.first(where: { $0.provider == "apple" && $0.providerUserId == subject }) else {
            return nil
        }
        let email = row.providerEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !email.isEmpty else { return nil }
        return (row.userId, email)
    }

    func failNativeAppleIfProcessing(requestId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var request = mobileRequests[requestId], request.status == "provider_processing" else { return }
        request.status = "failed"
        mobileRequests[requestId] = request
    }

    func finishNativeApple(requestId: String, email: String, subject: String, loginUserId: String?) -> (handoff: String, mode: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard var request = mobileRequests[requestId], request.status == "provider_processing" else { return nil }
        let handoff = Self.randomHex(32)
        request.status = "provider_completed"
        request.handoffCode = handoff
        request.codeHash = Self.sha256(handoff)
        request.profileEmail = email
        request.profileUserId = subject
        if request.mode == "login" {
            request.userId = loginUserId
        }
        let mode = request.mode
        mobileRequests[requestId] = request
        return (handoff, mode)
    }

    /// `POST /api/auth/mobile/oauth/:provider/link/start`. The bearer is required before a request row is written.
    public func startMobileOAuthLink(provider: String, body: String, authorization: String?) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth start\"}")
        }
        guard let returnUri = object["returnUri"] as? String,
              Self.isDesktopLoopback(returnUri) || configuredMobileReturnURIs().contains(returnUri)
        else {
            return Self.returnURINotAllowed
        }
        guard let challenge = object["codeChallenge"] as? String,
              challenge.wholeMatch(of: /^[A-Za-z0-9_-]{32,256}$/) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth start\"}")
        }
        return openedMobileOAuth(provider: provider, mode: "link", returnUri: returnUri, challenge: challenge, userId: userId)
    }

    func openedMobileOAuth(provider: String, mode: String, returnUri: String, challenge: String, userId: String?, linkOnConflict: Bool = false) -> HTTPReply {
        let id = UUID().uuidString.lowercased()
        let nonce = Self.randomHex(16)
        let desktopNonce = Self.desktopNonce(from: returnUri)
        lock.lock()
        mobileRequests[id] = MobileOAuthRequest(
            id: id,
            provider: provider,
            mode: mode,
            status: "pending_provider",
            codeChallenge: challenge,
            returnUri: returnUri,
            nonce: nonce,
            expiresAt: Date(timeIntervalSinceNow: 600),
            userId: userId,
            linkOnConflict: linkOnConflict
        )
        lock.unlock()
        let state = Self.signSocialAuthState(SocialAuthState(
            provider: provider,
            mode: mode,
            nonce: nonce,
            kind: "mobile",
            mobileRequestId: id,
            desktopNonce: desktopNonce
        ))
        let authorizationUrl = Self.authorizationURL(provider: provider, state: state)
        let expires = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: 600))
        let response = "{\"requestId\":\(jsonString(id)),\"authorizationUrl\":\(jsonString(authorizationUrl)),\"returnUri\":\(jsonString(returnUri)),\"expiresAt\":\(jsonString(expires))}"
        return Self.json(201, response)
    }

    /// `GET /api/auth/:provider/callback`. A desktop nonce that does not match the stored return URI is refused before any provider exchange.
    public func mobileOAuthCallback(provider: String, code: String?, state: String?, providerError: String? = nil) -> HTTPReply {
        guard let state, let parsed = Self.verifySocialAuthState(state),
              parsed.kind == "mobile", parsed.provider == provider
        else {
            return Self.text(400, "Invalid mobile OAuth request")
        }
        lock.lock()
        guard var request = mobileRequests[parsed.mobileRequestId],
              request.provider == provider,
              request.mode == parsed.mode,
              !request.codeChallenge.isEmpty
        else {
            lock.unlock()
            return Self.text(400, "Invalid mobile OAuth request")
        }
        let expected = Self.desktopNonce(from: request.returnUri)
        if expected != parsed.desktopNonce {
            lock.unlock()
            return Self.text(400, "Invalid mobile OAuth request")
        }
        if code == nil || code?.isEmpty == true {
            let error = (providerError?.isEmpty == false) ? providerError! : "provider_cancelled"
            request.status = "failed"
            let returnUri = request.returnUri
            let mode = request.mode
            mobileRequests[parsed.mobileRequestId] = request
            lock.unlock()
            return Self.redirect(Self.failureLocation(returnUri: returnUri, provider: provider, mode: mode, error: error))
        }
        guard let profile = mobileProviderProfile, profile.emailVerified else {
            request.status = "failed"
            let returnUri = request.returnUri
            let mode = request.mode
            mobileRequests[parsed.mobileRequestId] = request
            lock.unlock()
            return Self.redirect(Self.failureLocation(
                returnUri: returnUri,
                provider: provider,
                mode: mode,
                error: "provider_exchange_failed"
            ))
        }
        var intendedAction = "login"
        if request.mode == "login",
           let existing = accounts[Self.normalize(profile.email)],
           linkedIdentities.first(where: {
               $0.provider == provider && $0.providerUserId == profile.providerUserId
           })?.userId != existing.id {
            if !request.linkOnConflict {
                request.status = "failed"
                let returnUri = request.returnUri
                let mode = request.mode
                mobileRequests[parsed.mobileRequestId] = request
                lock.unlock()
                return Self.redirect(Self.failureLocation(
                    returnUri: returnUri, provider: provider, mode: mode, error: "account_conflict"
                ))
            }
            intendedAction = "link"
        }
        providerExchanges += 1
        let handoff = Self.randomHex(32)
        request.status = "provider_completed"
        request.intendedAction = intendedAction
        request.handoffCode = handoff
        request.codeHash = Self.sha256(handoff)
        request.profileEmail = Self.normalize(profile.email)
        request.profileUserId = profile.providerUserId
        request.profileName = profile.displayName
        let returnUri = request.returnUri
        let mode = request.mode
        mobileRequests[parsed.mobileRequestId] = request
        lock.unlock()
        return Self.redirect(Self.loopbackLocation(returnUri: returnUri, provider: provider, mode: mode, code: handoff))
    }

    /// `POST /api/auth/mobile/oauth/complete`. The handoff code is spent only after the PKCE verifier matches.
    public func completeMobileOAuth(body: String) -> HTTPReply {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        lock.lock()
        if consumedHandoffs.contains(code) {
            lock.unlock()
            return Self.json(410, "{\"code\":\"handoff_code_consumed\"}")
        }
        guard let requestId = mobileRequests.first(where: { $0.value.handoffCode == code })?.key,
              var request = mobileRequests[requestId],
              request.status == "provider_completed"
        else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        if request.expiresAt < Date() {
            request.status = "expired"
            mobileRequests[requestId] = request
            lock.unlock()
            return Self.json(410, "{\"code\":\"handoff_code_expired\",\"error\":\"Mobile OAuth code has expired\"}")
        }
        let verifier = object["codeVerifier"] as? String ?? ""
        if verifier.isEmpty {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        if Self.pkceS256(verifier) != request.codeChallenge {
            request.status = "failed"
            mobileRequests[requestId] = request
            lock.unlock()
            return Self.json(400, "{\"code\":\"pkce_mismatch\",\"error\":\"PKCE verifier did not match the OAuth request\"}")
        }
        if let rawToken = object["pendingLinkToken"] as? String, !rawToken.isEmpty {
            guard var pending = pendingSocialLinks[rawToken], !pending.consumed, !pending.cancelled,
                  pending.expiresAt > Date()
            else {
                lock.unlock()
                return Self.json(410, "{\"error\":\"This sign-in link expired. Sign in again to connect the account.\",\"code\":\"pending_link_expired\"}")
            }
            let identityOwner = linkedIdentities.first {
                $0.provider == request.provider && $0.providerUserId == (request.profileUserId ?? "")
            }?.userId
            let pendingOwner = accounts[pending.email]?.id
            guard let identityOwner, identityOwner == pendingOwner else {
                request.status = "failed"
                mobileRequests[requestId] = request
                lock.unlock()
                return Self.json(403, "{\"error\":\"The pending link belongs to a different account\",\"code\":\"pending_link_account_mismatch\"}")
            }
            pending.consumed = true
            pendingSocialLinks[rawToken] = pending
            if !linkedIdentities.contains(where: {
                $0.userId == identityOwner && $0.provider == pending.provider && $0.providerUserId == pending.providerUserId
            }) {
                linkedIdentities.append(LinkedIdentity(
                    userId: identityOwner, provider: pending.provider,
                    providerUserId: pending.providerUserId, providerEmail: pending.email
                ))
            }
            request.status = "completed"
            mobileRequests[requestId] = request
            consumedHandoffs.insert(code)
            let accessToken = Self.token()
            let refreshToken = Self.token()
            sessions[refreshToken] = LiveSession(userId: identityOwner, familyId: UUID().uuidString.lowercased())
            accessTokens[accessToken] = identityOwner
            lock.unlock()
            return Self.json(200, "{\"user\":{\"id\":\(jsonString(identityOwner))},\"accessToken\":\(jsonString(accessToken)),\"refreshToken\":\(jsonString(refreshToken)),\"linkedProvider\":\(jsonString(pending.provider))}")
        }
        if request.intendedAction == "link", let email = request.profileEmail,
           let existing = accounts[email] {
            let token = Self.randomHex(32)
            pendingSocialLinks[token] = PendingSocialLink(
                token: token, provider: request.provider, providerUserId: request.profileUserId ?? "",
                email: email, returnTo: nil, returnUri: request.returnUri,
                expiresAt: Date().addingTimeInterval(600)
            )
            request.status = "completed"
            mobileRequests[requestId] = request
            consumedHandoffs.insert(code)
            let linkedProviders = Set(linkedIdentities.filter { $0.userId == existing.id }.map(\.provider)).sorted()
            let providersJSON = linkedProviders.map(jsonString).joined(separator: ",")
            let hasPassword = existing.passwordCredentialEstablishedAt != nil
            let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
            lock.unlock()
            return Self.json(409, "{\"code\":\"account_link_required\",\"pendingLinkToken\":\(jsonString(token)),\"provider\":\(jsonString(request.provider)),\"email\":\(jsonString(email)),\"expiresAt\":\(jsonString(expiry)),\"signInMethods\":{\"password\":\(hasPassword ? "true" : "false"),\"providers\":[\(providersJSON)]},\"returnUri\":\(jsonString(request.returnUri))}")
        }
        if request.mode == "login", let existingId = request.userId {
            guard let account = accounts.values.first(where: { $0.id == existingId }) else {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
            }
            let accessToken = Self.token()
            let refreshToken = Self.token()
            sessions[refreshToken] = LiveSession(userId: account.id, familyId: UUID().uuidString.lowercased())
            accessTokens[accessToken] = account.id
            request.status = "completed"
            request.handoffCode = nil
            mobileRequests[requestId] = request
            consumedHandoffs.insert(code)
            let returnUri = request.returnUri
            let mode = request.mode
            let provider = request.provider
            lock.unlock()
            let user = "{\"id\":\(jsonString(account.id)),\"email\":\(jsonString(account.email)),\"name\":\(jsonString(account.name)),\"profileSetupCompletedAt\":null,\"profileSetupProvider\":\(jsonString(provider))}"
            let response = "{\"user\":\(user),\"accessToken\":\(jsonString(accessToken)),\"refreshToken\":\(jsonString(refreshToken)),\"mode\":\(jsonString(mode)),\"returnUri\":\(jsonString(returnUri))}"
            return Self.json(200, response)
        }
        if object["acceptTerms"] as? Bool != true {
            lock.unlock()
            return Self.legalRequired
        }
        let terms = object["termsVersion"] as? String
        let privacy = object["privacyVersion"] as? String
        if terms != Self.termsVersion || privacy != Self.privacyVersion {
            lock.unlock()
            return Self.termsChanged
        }
        let email = request.profileEmail ?? ""
        guard !email.isEmpty else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        let taken = Set(accounts.values.map(\.name))
        let pendingName = Self.pendingHandle(taken: taken)
        let id = UUID().uuidString.lowercased()
        accounts[email] = Account(
            id: id,
            email: email,
            passwordHash: Self.sha256(Self.token()),
            displayLanguage: nil,
            name: pendingName,
            profileSetupSuggestedHandle: Self.availableUserName(seed: request.profileName ?? email, taken: taken),
            profileSetupProvider: request.provider
        )
        authProfileStore.setLegalAcceptance(EmailLegalAcceptance(
            termsVersion: Self.termsVersion,
            privacyVersion: Self.privacyVersion,
            termsUrl: Self.termsURL,
            privacyUrl: Self.privacyURL,
            source: "oauth",
            userAgentHash: nil,
            locale: nil
        ), userId: id)
        let accessToken = Self.token()
        let refreshToken = Self.token()
        sessions[refreshToken] = LiveSession(userId: id, familyId: UUID().uuidString.lowercased())
        accessTokens[accessToken] = id
        let providerUserId = request.profileUserId ?? ""
        if !providerUserId.isEmpty, !linkedIdentities.contains(where: {
            $0.userId == id && $0.provider == request.provider && $0.providerUserId == providerUserId
        }) {
            linkedIdentities.append(LinkedIdentity(
                userId: id,
                provider: request.provider,
                providerUserId: providerUserId
            ))
        }
        request.status = "completed"
        request.handoffCode = nil
        mobileRequests[requestId] = request
        consumedHandoffs.insert(code)
        let returnUri = request.returnUri
        let mode = request.mode
        let provider = request.provider
        lock.unlock()
        let user = "{\"id\":\(jsonString(id)),\"email\":\(jsonString(email)),\"name\":\(jsonString(pendingName)),\"profileSetupCompletedAt\":null,\"profileSetupProvider\":\(jsonString(provider))}"
        let response = "{\"user\":\(user),\"accessToken\":\(jsonString(accessToken)),\"refreshToken\":\(jsonString(refreshToken)),\"mode\":\(jsonString(mode)),\"returnUri\":\(jsonString(returnUri))}"
        return Self.json(200, response)
    }

    /// `POST /api/auth/mobile/oauth/:provider/link/complete`. A different account is refused before the handoff is spent.
    public func completeMobileOAuthLink(provider: String, body: String, authorization: String?) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let caller: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            caller = id
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        let verifier = object["codeVerifier"] as? String ?? ""
        lock.lock()
        if consumedHandoffs.contains(code) {
            lock.unlock()
            return Self.json(410, "{\"code\":\"handoff_code_consumed\"}")
        }
        guard let requestId = mobileRequests.first(where: { $0.value.handoffCode == code })?.key,
              var request = mobileRequests[requestId],
              request.status == "provider_completed"
        else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        if request.expiresAt < Date() {
            request.status = "expired"
            mobileRequests[requestId] = request
            lock.unlock()
            return Self.json(410, "{\"code\":\"handoff_code_expired\",\"error\":\"Mobile OAuth code has expired\"}")
        }
        if verifier.isEmpty {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        if Self.pkceS256(verifier) != request.codeChallenge {
            request.status = "failed"
            mobileRequests[requestId] = request
            lock.unlock()
            return Self.json(400, "{\"code\":\"pkce_mismatch\",\"error\":\"PKCE verifier did not match the OAuth request\"}")
        }
        if request.provider != provider {
            lock.unlock()
            return Self.json(400, "{\"code\":\"provider_mismatch\",\"error\":\"Mobile OAuth code does not match the requested provider\"}")
        }
        if request.mode != "link" {
            lock.unlock()
            return Self.json(400, "{\"code\":\"mode_mismatch\",\"error\":\"Mobile OAuth code does not match the requested mode\"}")
        }
        guard request.userId == caller else {
            lock.unlock()
            return Self.mobileLinkMismatch
        }
        let providerUserId = request.profileUserId ?? ""
        let providerEmail = request.profileEmail ?? ""
        if !linkedIdentities.contains(where: {
            $0.userId == caller && $0.provider == provider && $0.providerUserId == providerUserId
        }) {
            linkedIdentities.append(LinkedIdentity(
                userId: caller,
                provider: provider,
                providerUserId: providerUserId,
                providerEmail: providerEmail
            ))
        }
        request.status = "completed"
        request.handoffCode = nil
        mobileRequests[requestId] = request
        consumedHandoffs.insert(code)
        let returnUri = request.returnUri
        let listed = linkedIdentities.filter { $0.userId == caller }.map {
            "{\"provider\":\(jsonString($0.provider)),\"providerEmail\":\(jsonString($0.providerEmail ?? ""))}"
        }.joined(separator: ",")
        lock.unlock()
        let response = "{\"provider\":\(jsonString(provider)),\"mode\":\"link\",\"returnUri\":\(jsonString(returnUri)),\"identities\":[\(listed)]}"
        return Self.json(200, response)
    }

    /// `POST /api/feature-flags/evaluate`. Admin flag routes are not mounted. An empty key list is rejected before any flag read.
    public func createFeatureFlagForTesting(
        key: String,
        defaultEnabled: Bool = false,
        enabled: Bool = true,
        killSwitch: Bool = false
    ) {
        lock.lock()
        featureFlagRecords[key] = FeatureFlagRecord(
            key: key,
            enabled: enabled,
            killSwitch: killSwitch,
            defaultEnabled: defaultEnabled
        )
        lock.unlock()
    }

    public func addFeatureFlagRuleForTesting(
        key: String,
        stage: String,
        decision: String,
        values: [String],
        clientOs: [String]? = nil,
        minClientBuild: Int? = nil,
        clientBuildTypes: [String]? = nil,
        priority: Int = 0
    ) {
        lock.lock()
        featureFlagRuleRecords.append(FeatureFlagRuleRecord(
            key: key,
            stage: stage,
            decision: decision,
            values: values,
            clientOs: clientOs,
            minClientBuild: minClientBuild,
            clientBuildTypes: clientBuildTypes,
            priority: priority
        ))
        lock.unlock()
    }

    public func setFeatureFlagDefaultForTesting(key: String, defaultEnabled: Bool) {
        lock.lock()
        featureFlagRecords[key]?.defaultEnabled = defaultEnabled
        lock.unlock()
    }

    public func setFeatureFlagKillSwitchForTesting(key: String, killSwitch: Bool) {
        lock.lock()
        featureFlagRecords[key]?.killSwitch = killSwitch
        lock.unlock()
    }



    func featureFlagRules(key: String, stage: String) -> [FeatureFlagRuleRecord] {
        featureFlagRuleRecords
            .filter { $0.key == key && $0.stage == stage }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func featureFlagRuleReply(key: String, rule: FeatureFlagRuleRecord, stage: String) -> HTTPReply {
        Self.json(200, "{\"evaluations\":[{\"key\":\(jsonString(key)),\"enabled\":\(rule.decision == "allow"),\"reason\":\(jsonString(stage + "_rule"))}]}")
    }

    func evaluateFeatureFlagKey(
        key: String,
        userId: String,
        serverId: String?,
        platform: String?,
        client: FeatureFlagClientFacts
    ) -> (enabled: Bool, reason: String) {
        guard let flag = featureFlagRecords[key] else {
            return (false, "missing_flag")
        }
        if flag.killSwitch { return (false, "kill_switch") }
        if !flag.enabled { return (false, "flag_disabled") }
        if let rule = featureFlagRules(key: key, stage: "user").first(where: { $0.values.contains(userId) }) {
            return (rule.decision == "allow", "user_rule")
        }
        if let platform,
           let rule = featureFlagRules(key: key, stage: "platform").first(where: { $0.values.contains(platform) }) {
            return (rule.decision == "allow", "platform_rule")
        }
        if let serverId {
            for rule in featureFlagRules(key: key, stage: "client") where rule.values.contains(serverId) {
                let hasConstraint = rule.clientOs != nil || rule.minClientBuild != nil || rule.clientBuildTypes != nil
                guard hasConstraint else { continue }
                if let clientOs = rule.clientOs {
                    guard let os = client.os, clientOs.contains(os) else { continue }
                }
                if let buildTypes = rule.clientBuildTypes {
                    guard let buildType = client.buildType, buildTypes.contains(buildType) else { continue }
                }
                if let minimum = rule.minClientBuild {
                    guard let buildNumber = client.buildNumber, buildNumber >= minimum else { continue }
                }
                return (rule.decision == "allow", "client_rule")
            }
        }
        if let serverId,
           let rule = featureFlagRules(key: key, stage: "server").first(where: { $0.values.contains(serverId) }) {
            return (rule.decision == "allow", "server_rule")
        }
        return (flag.defaultEnabled, "default")
    }

    /// `POST /api/feature-flags/evaluate`. Admin flag routes are not mounted.
    public func evaluateFeatureFlags(body: String, authorization: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let rawKeys: [Any]
        if let keys = object["keys"] as? [Any] {
            rawKeys = keys
        } else if let key = object["key"] as? String {
            rawKeys = [key]
        } else {
            rawKeys = []
        }
        let parsed = rawKeys.map { Self.featureFlagKey($0) }
        if parsed.isEmpty || parsed.count > 50 || parsed.contains(where: { $0 == nil }) {
            return Self.json(400, "{\"error\":\"keys must contain 1-50 valid feature flag keys\"}")
        }
        var serverId: String?
        if let rawServerId = object["serverId"], !(rawServerId is NSNull) {
            guard let value = rawServerId as? String, ServerScope.isUUID(value) else {
                return Self.json(400, "{\"error\":\"serverId must be a valid UUID\"}")
            }
            serverId = value
        }
        if let serverId, oauth.memberRole(serverId: serverId, userId: userId) == nil {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        var platform: String?
        if let rawPlatform = object["platform"], !(rawPlatform is NSNull) {
            guard let value = rawPlatform as? String, value == "web" || value == "mobile" else {
                return Self.json(400, "{\"error\":\"platform must be web or mobile\"}")
            }
            platform = value
        }
        let client = Self.featureFlagClientFacts(object)
        let unique = parsed.compactMap { $0 }.reduce(into: [String]()) { list, key in
            if !list.contains(key) { list.append(key) }
        }
        lock.lock()
        let evaluations = unique.map { key -> String in
            let result = evaluateFeatureFlagKey(key: key, userId: userId, serverId: serverId, platform: platform, client: client)
            return "{\"key\":\(jsonString(key)),\"enabled\":\(result.enabled),\"reason\":\(jsonString(result.reason))}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"evaluations\":[\(evaluations)]}")
    }

}
