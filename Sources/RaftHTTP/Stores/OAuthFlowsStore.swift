import Foundation

/// The sign-in configuration one OAuth flow request reads, taken as one locked
/// snapshot so a request never mixes two configurations.
struct OAuthFlowsConfig: Sendable {
    var configuredProviders: Set<String>
    var applePlatforms: Set<String>
    var appleClientId: String
    var nativeAppleClientId: String
    var nativeAppleClientSecret: String
    var nativeAppleStateSecret: String
    var socialAuthStateSecret: String
    var nativeAppleTrustedJWKS: String?
    var serverURL: String
    var appURL: String
    var mobileOAuthReturnURI: String?
    var mobileOAuthAllowedReturnURIs: String?
    var exchangeNativeAppleCode: (@Sendable (NativeAppleCodeExchange) async -> String?)?
    var mobileProviderProfile: MobileProviderProfile?
    var webProviderProfile: MobileProviderProfile?
}

/// Why a mobile handoff completion was refused. The service maps each case to
/// its published `OAuthFlowsError`.
enum MobileHandoffRefusal: Sendable, Equatable {
    case consumed
    case invalid
    case expired
    case pkceMismatch
    case providerMismatch
    case modeMismatch
    case linkMismatch
    case pendingLinkExpired
    case pendingLinkAccountMismatch
    case legalRequired
    case termsChanged
}

/// The account a completed handoff signed in (an existing account or the one
/// just created) and the session it opened. The account value is the retained
/// row every published user member is projected from; a just-created account
/// has no signup-survey facts yet.
struct MobileSignedIn: Sendable {
    var account: Account
    var provider: String
    var mode: String
    var returnUri: String
    var tokens: IssuedSessionTokens
    /// Set only when this completion spent a pending link token.
    var linkedProvider: String?
}

/// What one `complete` call decided and wrote.
enum MobileCompletionOutcome: Sendable {
    case refused(MobileHandoffRefusal)
    /// The provider identity matches an existing account: a pending link token
    /// was issued and the handoff spent.
    case linkRequired(
        token: String,
        provider: String,
        email: String,
        expiresAt: Date,
        hasPassword: Bool,
        providers: [String],
        returnUri: String
    )
    case signedIn(MobileSignedIn)
}

/// What one `link/complete` call decided and wrote.
enum MobileLinkCompletionOutcome: Sendable {
    case refused(MobileHandoffRefusal)
    case linked(returnUri: String, identities: [(provider: String, providerEmail: String)])
}

/// What the provider callback of a mobile request decided and wrote.
enum MobileCallbackOutcome: Sendable, Equatable {
    case invalidRequest
    /// The request failed; redirect to the return URI with this error.
    case failed(returnUri: String, mode: String, error: String)
    /// The provider exchange succeeded; redirect with the handoff code.
    case completed(returnUri: String, mode: String)
}

/// What recording a web login completion decided.
enum WebLoginRecordOutcome: Sendable, Equatable {
    /// The email belongs to another account and the caller did not ask to link.
    case accountConflict
    case recorded
}

/// The OAuth flow rows: mobile handoff requests, social completions, pending
/// links, consumed handoffs and the sessions a completed handoff opens.
///
/// The rows live in `AuthProfileStore`; every read-modify-write here is one
/// `Mutex.withLock` critical section, the same atomicity the retired
/// handlers got from the directory lock. The store builds no JSON or HTTP
/// response: the service maps each outcome. A struct over the locked store is
/// `Sendable` without an `@unchecked` escape.
struct OAuthFlowsStore: Sendable {
    let profiles: AuthProfileStore

    init(profiles: AuthProfileStore) {
        self.profiles = profiles
    }

    // MARK: Reads

    func config() -> OAuthFlowsConfig {
        profiles.state.withLock { state in
            OAuthFlowsConfig(
                configuredProviders: state.configSurface.oauthDeployment.configuredSocialAuthProviders,
                applePlatforms: state.accountSurface.appleLoginPlatforms,
                appleClientId: state.configSurface.oauthDeployment.appleClientId,
                nativeAppleClientId: state.configSurface.oauthDeployment.nativeAppleClientId,
                nativeAppleClientSecret: state.configSurface.oauthDeployment.nativeAppleClientSecret,
                nativeAppleStateSecret: state.configSurface.oauthDeployment.nativeAppleStateSecret,
                socialAuthStateSecret: state.configSurface.oauthDeployment.socialAuthStateSecret,
                nativeAppleTrustedJWKS: state.configSurface.oauthDeployment.nativeAppleTrustedJWKS,
                serverURL: state.configSurface.oauthDeployment.serverURL,
                appURL: state.configSurface.oauthDeployment.appURL,
                mobileOAuthReturnURI: state.configSurface.oauthDeployment.mobileOAuthReturnURI,
                mobileOAuthAllowedReturnURIs: state.configSurface.oauthDeployment.mobileOAuthAllowedReturnURIs,
                exchangeNativeAppleCode: state.configSurface.exchangeNativeAppleCode,
                mobileProviderProfile: state.configSurface.mobileProviderProfile,
                webProviderProfile: state.configSurface.webProviderProfile
            )
        }
    }

    /// The account behind a bearer access token, or `nil` for an unknown token
    /// or a revoked session family.
    func userId(forAccessToken token: String) -> String? {
        profiles.userId(forAccessToken: token)
    }

    /// The observed-timezone pair published on every full user object.
    func timezoneObservation(userId: String) -> TimezoneObservation? {
        profiles.timezoneObservation(userId: userId)
    }

    func profileSetupProvider(userId: String) -> String? {
        profiles.profileSetupProvider(userId: userId)
    }

    func isEmailVerified(userId: String) -> Bool {
        profiles.isEmailVerified(userId: userId)
    }

    // MARK: Request rows

    func insertMobileRequest(_ request: MobileOAuthRequest) {
        profiles.state.withLock { state in
            state.accountSurface.mobileRequests[request.id] = request
        }
    }

    /// Records the completion a web callback hands back as a one-time code.
    func appendSocialCompletion(_ completion: SocialCompletion) {
        profiles.state.withLock { state in
            state.accountSurface.socialCompletions.append(completion)
        }
    }

    /// The web login completion: whether the verified email collides with an
    /// account that does not already own this provider identity, and the row
    /// written when it does not (or when the caller asked to link on conflict).
    func recordWebLogin(
        provider: String,
        providerUserId: String,
        email: String,
        linkOnConflict: Bool,
        returnTo: String,
        code: String
    ) -> WebLoginRecordOutcome {
        profiles.state.withLock { state in
            let existing = state.accountSurface.accounts[email]
            let existingIdentity = state.accountSurface.linkedIdentities.first {
                $0.provider == provider && $0.providerUserId == providerUserId
            }
            if let existing, existingIdentity?.userId != existing.id {
                guard linkOnConflict else { return .accountConflict }
                state.accountSurface.socialCompletions.append(SocialCompletion(
                    provider: provider, code: code, mode: "login",
                    intendedAction: "link", email: email,
                    returnTo: returnTo, userId: nil,
                    providerUserId: providerUserId, linkOnConflict: true
                ))
                return .recorded
            }
            state.accountSurface.socialCompletions.append(SocialCompletion(
                provider: provider, code: code, mode: "login",
                intendedAction: "login", email: email,
                returnTo: returnTo,
                userId: existing?.id, providerUserId: providerUserId
            ))
            return .recorded
        }
    }

    // MARK: Native Apple

    /// Moves `pending_provider` to `provider_processing` before any Apple call.
    /// A past row expiry and a link-owner mismatch are decided before that claim.
    func claimNativeApple(
        requestId: String,
        mode: String,
        codeChallenge: String,
        tokenUserId: String?,
        callerId: String?,
        now: Date
    ) -> NativeAppleClaim {
        profiles.state.withLock { state in
            guard var request = state.accountSurface.mobileRequests[requestId],
                  request.provider == "apple",
                  request.mode == mode,
                  request.codeChallenge == codeChallenge,
                  request.userId == tokenUserId
            else { return .missing }
            if request.mode == "link" {
                guard let callerId else { return .authRequired }
                guard request.userId == callerId else { return .userMismatch }
            }
            if request.expiresAt < now {
                request.status = "expired"
                state.accountSurface.mobileRequests[requestId] = request
                return .expired
            }
            guard request.status == "pending_provider" else { return .consumed }
            request.status = "provider_processing"
            state.accountSurface.mobileRequests[requestId] = request
            return .claimed(request.codeChallenge)
        }
    }

    /// A previously linked Apple subject can supply the verified email Apple
    /// omits on a later login.
    func storedAppleIdentity(subject: String) -> (userId: String, email: String)? {
        profiles.state.withLock { state in
            guard let row = state.accountSurface.linkedIdentities.first(where: {
                $0.provider == "apple" && $0.providerUserId == subject
            }) else { return nil }
            let email = row.providerEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !email.isEmpty else { return nil }
            return (row.userId, email)
        }
    }

    func failNativeAppleIfProcessing(requestId: String) {
        profiles.state.withLock { state in
            guard var request = state.accountSurface.mobileRequests[requestId],
                  request.status == "provider_processing"
            else { return }
            request.status = "failed"
            state.accountSurface.mobileRequests[requestId] = request
        }
    }

    /// Completes a claimed native Apple request and publishes its handoff code.
    func finishNativeApple(
        requestId: String,
        email: String,
        subject: String,
        loginUserId: String?,
        handoff: String
    ) -> String? {
        profiles.state.withLock { state in
            guard var request = state.accountSurface.mobileRequests[requestId],
                  request.status == "provider_processing"
            else { return nil }
            request.status = "provider_completed"
            request.handoffCode = handoff
            request.codeHash = AuthTokenCodec.sha256(handoff)
            request.profileEmail = email
            request.profileUserId = subject
            if request.mode == "login" {
                request.userId = loginUserId
            }
            let mode = request.mode
            state.accountSurface.mobileRequests[requestId] = request
            return mode
        }
    }

    // MARK: Mobile provider callback

    /// The mobile provider callback: the request match, the desktop nonce, the
    /// cancelled and unverified-profile failures, the account-conflict rule and
    /// the handoff publication are one critical section.
    func mobileCallback(
        requestId: String,
        provider: String,
        mode: String,
        stateDesktopNonce: String?,
        code: String?,
        providerError: String?,
        profile: MobileProviderProfile?,
        handoff: String
    ) -> MobileCallbackOutcome {
        profiles.state.withLock { state in
            guard var request = state.accountSurface.mobileRequests[requestId],
                  request.provider == provider,
                  request.mode == mode,
                  !request.codeChallenge.isEmpty
            else { return .invalidRequest }
            guard AuthRedirects.desktopNonce(from: request.returnUri) == stateDesktopNonce else {
                return .invalidRequest
            }
            func fail(_ error: String) -> MobileCallbackOutcome {
                request.status = "failed"
                state.accountSurface.mobileRequests[requestId] = request
                return .failed(returnUri: request.returnUri, mode: request.mode, error: error)
            }
            if code == nil || code?.isEmpty == true {
                return fail(providerError?.isEmpty == false ? providerError ?? "" : "provider_cancelled")
            }
            guard let profile, profile.emailVerified else {
                return fail("provider_exchange_failed")
            }
            let email = AccountNaming.normalize(profile.email)
            var intendedAction = "login"
            var existingUserId: String?
            if request.mode == "login", let existing = state.accountSurface.accounts[email] {
                let linkedOwner = state.accountSurface.linkedIdentities.first {
                    $0.provider == provider && $0.providerUserId == profile.providerUserId
                }?.userId
                if linkedOwner == existing.id {
                    existingUserId = existing.id
                } else {
                    guard request.linkOnConflict else { return fail("account_conflict") }
                    intendedAction = "link"
                }
            }
            state.accountSurface.providerExchanges += 1
            request.status = "provider_completed"
            request.intendedAction = intendedAction
            // A conflict completion carries no userId, so a server that
            // predates pending links cannot read it as "sign in to the
            // existing account". Link-mode starts keep the authenticated owner.
            request.userId = request.mode == "link" ? request.userId
                : (intendedAction == "link" ? nil : existingUserId)
            request.handoffCode = handoff
            request.codeHash = AuthTokenCodec.sha256(handoff)
            request.profileEmail = email
            request.profileUserId = profile.providerUserId
            request.profileName = profile.displayName
            state.accountSurface.mobileRequests[requestId] = request
            return .completed(returnUri: request.returnUri, mode: request.mode)
        }
    }

    // MARK: Handoff completion

    /// `POST /api/auth/mobile/oauth/complete`: the handoff checks, the
    /// pending-link spend, the link-required hand-back, the existing-account
    /// sign-in and the new-account sign-up are one critical section, so a
    /// handoff code is spent at most once.
    func mobilePasswordPlaceholderNeeded(code: String) -> Bool {
        profiles.state.withLock { state in
            guard let request = state.accountSurface.mobileRequests.values.first(where: { $0.handoffCode == code }),
                  request.status == "provider_completed", request.userId == nil,
                  let email = request.profileEmail else { return false }
            return state.accountSurface.accounts[email] == nil
        }
    }

    func completeMobile(
        code: String,
        verifier: String,
        pendingLinkToken: String?,
        acceptTerms: Bool,
        termsVersion: String?,
        privacyVersion: String?,
        now: Date,
        passwordPlaceholder: String? = nil
    ) -> MobileCompletionOutcome {
        profiles.state.withLock { state in
            if state.accountSurface.consumedHandoffs.contains(code) { return .refused(.consumed) }
            guard let requestId = state.accountSurface.mobileRequests.first(where: { $0.value.handoffCode == code })?.key,
                  var request = state.accountSurface.mobileRequests[requestId],
                  request.status == "provider_completed"
            else { return .refused(.invalid) }
            if request.expiresAt < now {
                request.status = "expired"
                state.accountSurface.mobileRequests[requestId] = request
                return .refused(.expired)
            }
            if verifier.isEmpty { return .refused(.invalid) }
            if AuthTokenCodec.pkceS256(verifier) != request.codeChallenge {
                request.status = "failed"
                state.accountSurface.mobileRequests[requestId] = request
                return .refused(.pkceMismatch)
            }
            if let rawToken = pendingLinkToken, !rawToken.isEmpty {
                guard var pending = state.accountSurface.pendingSocialLinks[rawToken], !pending.consumed, !pending.cancelled,
                      pending.expiresAt > now
                else { return .refused(.pendingLinkExpired) }
                let identityOwner = state.accountSurface.linkedIdentities.first {
                    $0.provider == request.provider && $0.providerUserId == (request.profileUserId ?? "")
                }?.userId
                let pendingOwner = state.accountSurface.accounts[pending.email]?.id
                guard let identityOwner, identityOwner == pendingOwner else {
                    request.status = "failed"
                    state.accountSurface.mobileRequests[requestId] = request
                    return .refused(.pendingLinkAccountMismatch)
                }
                pending.consumed = true
                state.accountSurface.pendingSocialLinks[rawToken] = pending
                if !state.accountSurface.linkedIdentities.contains(where: {
                    $0.userId == identityOwner && $0.provider == pending.provider
                        && $0.providerUserId == pending.providerUserId
                }) {
                    state.accountSurface.linkedIdentities.append(LinkedIdentity(
                        userId: identityOwner, provider: pending.provider,
                        providerUserId: pending.providerUserId, providerEmail: pending.email
                    ))
                }
                guard let signedInAccount = state.accountSurface.accounts.values.first(where: { $0.id == identityOwner }) else {
                    return .refused(.invalid)
                }
                request.status = "completed"
                state.accountSurface.mobileRequests[requestId] = request
                state.accountSurface.consumedHandoffs.insert(code)
                let tokens = Self.openSession(&state.accountSurface, userId: identityOwner)
                return .signedIn(MobileSignedIn(
                    account: signedInAccount,
                    provider: request.provider,
                    mode: request.mode,
                    returnUri: request.returnUri,
                    tokens: tokens,
                    linkedProvider: pending.provider
                ))
            }
            if request.intendedAction == "link", let email = request.profileEmail,
               let existing = state.accountSurface.accounts[email] {
                let token = AuthTokenCodec.randomHex(32)
                let expiresAt = now.addingTimeInterval(600)
                state.accountSurface.pendingSocialLinks[token] = PendingSocialLink(
                    token: token, provider: request.provider, providerUserId: request.profileUserId ?? "",
                    email: email, returnTo: nil, returnUri: request.returnUri,
                    expiresAt: expiresAt
                )
                request.status = "completed"
                state.accountSurface.mobileRequests[requestId] = request
                state.accountSurface.consumedHandoffs.insert(code)
                let providers = Set(state.accountSurface.linkedIdentities.filter { $0.userId == existing.id }.map(\.provider)).sorted()
                return .linkRequired(
                    token: token,
                    provider: request.provider,
                    email: email,
                    expiresAt: expiresAt,
                    hasPassword: existing.passwordCredentialEstablishedAt != nil,
                    providers: providers,
                    returnUri: request.returnUri
                )
            }
            if request.mode == "login", let existingId = request.userId {
                guard let account = state.accountSurface.accounts.values.first(where: { $0.id == existingId }) else {
                    return .refused(.invalid)
                }
                let tokens = Self.openSession(&state.accountSurface, userId: account.id)
                request.status = "completed"
                request.handoffCode = nil
                state.accountSurface.mobileRequests[requestId] = request
                state.accountSurface.consumedHandoffs.insert(code)
                return .signedIn(MobileSignedIn(
                    account: account,
                    provider: request.provider,
                    mode: request.mode,
                    returnUri: request.returnUri,
                    tokens: tokens,
                    linkedProvider: nil
                ))
            }
            if !acceptTerms { return .refused(.legalRequired) }
            if termsVersion != AuthLegalPolicy.termsVersion || privacyVersion != AuthLegalPolicy.privacyVersion {
                return .refused(.termsChanged)
            }
            let email = request.profileEmail ?? ""
            guard !email.isEmpty, let passwordPlaceholder else { return .refused(.invalid) }
            let taken = Set(state.accountSurface.accounts.values.map(\.name))
            let pendingName = AccountNaming.pendingHandle(taken: taken)
            let suggestedHandle = AccountNaming.availableUserName(
                seed: request.profileName ?? email, taken: taken
            )
            let providerDisplayName = request.profileName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let id = UUID().uuidString.lowercased()
            state.accountSurface.accounts[email] = Account(
                id: id,
                email: email,
                passwordHash: passwordPlaceholder,
                passwordCredentialEstablishedAt: nil,
                displayLanguage: nil,
                name: pendingName,
                displayName: providerDisplayName.flatMap { $0.isEmpty ? nil : $0 } ?? suggestedHandle,
                profileSetupSuggestedHandle: suggestedHandle,
                profileSetupProvider: request.provider,
                emailVerified: true
            )
            state.legalAcceptances[id] = EmailLegalAcceptance(
                termsVersion: AuthLegalPolicy.termsVersion,
                privacyVersion: AuthLegalPolicy.privacyVersion,
                termsUrl: AuthLegalPolicy.termsURL,
                privacyUrl: AuthLegalPolicy.privacyURL,
                source: "oauth",
                userAgentHash: nil,
                locale: nil
            )
            let tokens = Self.openSession(&state.accountSurface, userId: id)
            let providerUserId = request.profileUserId ?? ""
            if !providerUserId.isEmpty, !state.accountSurface.linkedIdentities.contains(where: {
                $0.userId == id && $0.provider == request.provider && $0.providerUserId == providerUserId
            }) {
                state.accountSurface.linkedIdentities.append(LinkedIdentity(
                    userId: id,
                    provider: request.provider,
                    providerUserId: providerUserId,
                    providerEmail: email
                ))
            }
            request.status = "completed"
            request.handoffCode = nil
            state.accountSurface.mobileRequests[requestId] = request
            state.accountSurface.consumedHandoffs.insert(code)
            guard let created = state.accountSurface.accounts[email] else {
                return .refused(.invalid)
            }
            return .signedIn(MobileSignedIn(
                account: created,
                provider: request.provider,
                mode: request.mode,
                returnUri: request.returnUri,
                tokens: tokens,
                linkedProvider: nil
            ))
        }
    }

    /// `POST /api/auth/mobile/oauth/:provider/link/complete`: the handoff
    /// checks, the provider and mode match, the owner check, the identity
    /// append and the handoff spend are one critical section.
    func completeMobileLink(
        provider: String,
        callerId: String,
        code: String,
        verifier: String,
        now: Date
    ) -> MobileLinkCompletionOutcome {
        profiles.state.withLock { state in
            if state.accountSurface.consumedHandoffs.contains(code) { return .refused(.consumed) }
            guard let requestId = state.accountSurface.mobileRequests.first(where: { $0.value.handoffCode == code })?.key,
                  var request = state.accountSurface.mobileRequests[requestId],
                  request.status == "provider_completed"
            else { return .refused(.invalid) }
            if request.expiresAt < now {
                request.status = "expired"
                state.accountSurface.mobileRequests[requestId] = request
                return .refused(.expired)
            }
            if verifier.isEmpty { return .refused(.invalid) }
            if AuthTokenCodec.pkceS256(verifier) != request.codeChallenge {
                request.status = "failed"
                state.accountSurface.mobileRequests[requestId] = request
                return .refused(.pkceMismatch)
            }
            if request.provider != provider { return .refused(.providerMismatch) }
            if request.mode != "link" { return .refused(.modeMismatch) }
            guard request.userId == callerId else { return .refused(.linkMismatch) }
            let providerUserId = request.profileUserId ?? ""
            let providerEmail = request.profileEmail ?? ""
            if !state.accountSurface.linkedIdentities.contains(where: {
                $0.userId == callerId && $0.provider == provider && $0.providerUserId == providerUserId
            }) {
                state.accountSurface.linkedIdentities.append(LinkedIdentity(
                    userId: callerId,
                    provider: provider,
                    providerUserId: providerUserId,
                    providerEmail: providerEmail
                ))
            }
            request.status = "completed"
            request.handoffCode = nil
            state.accountSurface.mobileRequests[requestId] = request
            state.accountSurface.consumedHandoffs.insert(code)
            let identities = state.accountSurface.linkedIdentities.filter { $0.userId == callerId }.map {
                (provider: $0.provider, providerEmail: $0.providerEmail ?? "")
            }
            return .linked(returnUri: request.returnUri, identities: identities)
        }
    }

    /// Opens a refresh session and its access token for `userId`. The handoff
    /// sessions never created a session family row, and that is kept.
    private static func openSession(
        _ accounts: inout AuthProfileStore.AccountState,
        userId: String
    ) -> IssuedSessionTokens {
        let accessToken = AuthTokenCodec.token()
        let refreshToken = AuthTokenCodec.token()
        accounts.sessions[refreshToken] = LiveSession(userId: userId, familyId: UUID().uuidString.lowercased())
        accounts.accessTokens[accessToken] = userId
        return IssuedSessionTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
}
