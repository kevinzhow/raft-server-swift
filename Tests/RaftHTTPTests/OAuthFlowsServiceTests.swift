import Foundation
import RaftShared
import Testing
@testable import RaftHTTP

/// The OAuth flow service owns the published bodies and one store critical
/// section per handoff write. The HTTP tests lock statuses and headers; these
/// tests lock the exact bytes and the atomic decisions.

private let returnUri = "raft://oauth/callback"
private let verifier = String(repeating: "v", count: 43)

private func challenge() -> String { AuthTokenCodec.pkceS256(verifier) }

private func makeFixture() -> OAuthFlowsUnitFixture {
    let fixture = OAuthFlowsUnitFixture()
    fixture.setAppURL("https://app.raft.test")
    fixture.setServerURL("https://api.raft.test")
    fixture.setConfiguredProviders(["google", "github", "apple"])
    fixture.allowAppleLogin(on: ["web", "mobile"])
    fixture.setMobileProviderProfile(MobileProviderProfile(
        providerUserId: "google-sub-1", email: "Person@Flows.test", displayName: "Flow Person", emailVerified: true
    ))
    return fixture
}

private func verifiedBearer(_ fixture: OAuthFlowsUnitFixture, _ suffix: String) -> (userId: String, bearer: String) {
    let userId = "11111111-1111-4111-8111-0000030\(suffix)"
    fixture.addAccount(id: userId, email: "flows-\(suffix)@slock.test", password: "password123")
    fixture.markEmailVerified(userId: userId)
    return (userId, "Bearer " + fixture.mintAccessTokenForTesting(userId: userId))
}

private func queryItem(_ url: String, _ name: String) -> String? {
    URLComponents(string: url)?.queryItems?.first { $0.name == name }?.value
}

/// Runs a mobile login start and the provider callback and returns the handoff code.
private func handoffCode(_ service: OAuthFlowsService, provider: String = "google") async throws -> String {
    let started = try await service.startMobileOAuth(MobileOAuthStartRequest(
        isObject: true, returnUri: returnUri, provider: provider, mode: "login", codeChallenge: challenge()
    ))
    let state = try #require(queryItem(started.authorizationUrl, "state"))
    let redirect = try await service.mobileOAuthCallback(provider: provider, code: "provider-code", state: state)
    return try #require(queryItem(redirect.location, "code"))
}

private func seedHandoff(_ store: OAuthFlowsStore, id: String, code: String, mode: String, userId: String?, provider: String = "google") {
    var request = MobileOAuthRequest(
        id: id, provider: provider, mode: mode, status: "provider_completed",
        codeChallenge: challenge(), returnUri: returnUri, nonce: "n",
        expiresAt: Date().addingTimeInterval(600), userId: userId
    )
    request.handoffCode = code
    request.profileEmail = "seed-\(id)@flows.test"
    request.profileUserId = "sub-\(id)"
    store.insertMobileRequest(request)
}

// MARK: - Bytes

@Test func oauthFlowsErrorsPublishTheLegacyBytes() {
    func body(_ error: OAuthFlowsError) -> String { error.publishedErrorBody.render() }
    #expect(body(.platformInvalid) == #"{"code":"platform_invalid","error":"platform must be web or mobile"}"#)
    #expect(body(.invalidMobileStart) == #"{"error":"Invalid mobile OAuth start"}"#)
    #expect(body(.returnURINotAllowed) == #"{"code":"return_uri_not_allowed","error":"Mobile OAuth return URI is not allowed"}"#)
    #expect(body(.appleNotConfigured) == #"{"code":"provider_not_configured","error":"Apple sign-in is not configured"}"#)
    #expect(body(.notFound) == #"{"error":"Not found"}"#)
    #expect(body(.providerNotConfigured(provider: "github")) == #"{"error":"GitHub sign-in is not configured"}"#)
    #expect(body(.missingAuthorization) == #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#)
    #expect(body(.invalidToken) == #"{"error":"Invalid or expired token","code":"auth_required"}"#)
    #expect(body(.nativeAppleInvalidRequest) == #"{"code":"invalid_request","error":"Native Apple sign-in requires the iOS platform and app environment"}"#)
    #expect(body(.nativeAppleRequiresS256) == #"{"code":"invalid_request","error":"Native Apple sign-in requires an S256 challenge"}"#)
    #expect(body(.nativeAppleInvalidCredential) == #"{"code":"native_apple_invalid_credential","error":"Apple sign-in credential was invalid"}"#)
    #expect(body(.nativeAppleAuthRequired) == #"{"code":"auth_required","error":"Apple account linking requires authentication"}"#)
    #expect(body(.nativeAppleLinkMismatch) == #"{"code":"link_user_mismatch","error":"Apple account linking does not match the authenticated user"}"#)
    #expect(body(.nativeAppleRequestExpired) == #"{"code":"native_apple_request_expired","error":"Apple sign-in request expired"}"#)
    #expect(body(.nativeAppleRequestConsumed) == #"{"code":"native_apple_request_consumed","error":"Apple sign-in request was already used"}"#)
    #expect(body(.invalidMobileCompletion) == #"{"error":"Invalid mobile OAuth completion"}"#)
    #expect(body(.handoffCodeConsumed) == #"{"code":"handoff_code_consumed"}"#)
    #expect(body(.handoffCodeExpired) == #"{"code":"handoff_code_expired","error":"Mobile OAuth code has expired"}"#)
    #expect(body(.pkceMismatch) == #"{"code":"pkce_mismatch","error":"PKCE verifier did not match the OAuth request"}"#)
    #expect(body(.pendingLinkExpired) == #"{"error":"This sign-in link expired. Sign in again to connect the account.","code":"pending_link_expired"}"#)
    #expect(body(.pendingLinkAccountMismatch) == #"{"error":"The pending link belongs to a different account","code":"pending_link_account_mismatch"}"#)
    #expect(body(.providerMismatch) == #"{"code":"provider_mismatch","error":"Mobile OAuth code does not match the requested provider"}"#)
    #expect(body(.modeMismatch) == #"{"code":"mode_mismatch","error":"Mobile OAuth code does not match the requested mode"}"#)
    #expect(body(.mobileLinkMismatch) == #"{"code":"link_user_mismatch","error":"Mobile OAuth link request does not match the authenticated user"}"#)
    let legal = #""legal":{"termsVersion":"2026-05-12","privacyVersion":"2026-05-12","termsUrl":"https://raft.build/terms","privacyUrl":"https://raft.build/privacy"}"#
    #expect(body(.legalAcceptanceRequired) == #"{"error":"LEGAL_ACCEPTANCE_REQUIRED","# + legal + "}")
    #expect(body(.termsChanged) == #"{"error":"TERMS_CHANGED","# + legal + "}")
    #expect(body(.accountLinkRequired(
        pendingLinkToken: "tok", provider: "google", email: "a@b.test", expiresAt: "2026-01-01T00:00:00Z",
        hasPassword: true, providers: ["github", "google"], returnUri: returnUri
    )) == #"{"code":"account_link_required","pendingLinkToken":"tok","provider":"google","email":"a@b.test","expiresAt":"2026-01-01T00:00:00Z","signInMethods":{"password":true,"providers":["github","google"]},"returnUri":"raft://oauth/callback"}"#)
    #expect(body(.clientCredentialsRequired) == #"{"error":"Client credentials are required"}"#)
    #expect(body(.emailVerificationRequired) == #"{"error":"Email verification required"}"#)
    #expect(body(.featureFlagKeysInvalid) == #"{"error":"keys must contain 1-50 valid feature flag keys"}"#)
    #expect(body(.featureFlagPlatformInvalid) == #"{"error":"platform must be web or mobile"}"#)

    // The mobile callback answers plain text; the lookup refusals add a cache policy.
    #expect(body(.invalidMobileRequest) == "Invalid mobile OAuth request")
    #expect(OAuthFlowsError.invalidMobileRequest.errorHeaders
        == .exact(["X-Robots-Tag": AppFallback.robotsTag, "Content-Type": "text/plain; charset=utf-8"]))
    #expect(OAuthFlowsError.installationNotFound.errorHeaders == .standard(extra: ["Cache-Control": "private, no-store"]))
    #expect(OAuthFlowsError.notFound.errorHeaders == .standard())
    #expect(OAuthFlowsError.handoffCodeConsumed.status == 410)
    #expect(OAuthFlowsError.accountLinkRequired(
        pendingLinkToken: "", provider: "", email: "", expiresAt: "", hasPassword: false, providers: [], returnUri: ""
    ).status == 409)
}

@Test func oauthFlowsPublishProviderListRedirectAndLinkStartBytes() async throws {
    let fixture = makeFixture()
    let service = fixture.service

    // A fixture with github unconfigured and Apple allowed on mobile only.
    let gated = OAuthFlowsUnitFixture()
    gated.setConfiguredProviders(["google", "apple"])
    gated.allowAppleLogin(on: ["mobile"])
    #expect(try gated.service.authProviders(platform: nil).jsonBody.render()
        == #"{"providers":[{"id":"google","label":"Google","enabled":true},{"id":"github","label":"GitHub","enabled":false},{"id":"apple","label":"Apple","enabled":false}]}"#)
    #expect(try gated.service.authProviders(platform: "mobile").jsonBody.render()
        == #"{"providers":[{"id":"google","label":"Google","enabled":true},{"id":"github","label":"GitHub","enabled":false},{"id":"apple","label":"Apple","enabled":true}]}"#)
    #expect(throws: OAuthFlowsError.platformInvalid) { try gated.service.authProviders(platform: "desktop") }

    let redirect = try await service.startWebOAuth(provider: "google", returnTo: "/inbox")
    #expect(redirect.status == 302)
    #expect(redirect.jsonBody.render() == "")
    #expect(redirect.location.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"))
    let cookie = try #require(redirect.cookie)
    #expect(cookie.hasPrefix("slock_google_oauth_nonce="))
    #expect(cookie.hasSuffix("; Path=/api/auth/google/callback; Max-Age=600; HttpOnly; SameSite=Lax; Secure"))
    #expect(redirect.headers == .exact([
        "X-Robots-Tag": AppFallback.robotsTag, "Location": redirect.location, "Set-Cookie": cookie,
    ]))
    await #expect(throws: OAuthFlowsError.notFound) { try await service.startWebOAuth(provider: "nope", returnTo: nil) }
    await #expect(throws: OAuthFlowsError.providerNotConfigured(provider: "github")) {
        try await gated.service.startWebOAuth(provider: "github", returnTo: nil)
    }

    let (_, bearer) = verifiedBearer(fixture, "01")
    let link = try await service.startWebOAuthLink(provider: "github", body: WebOAuthLinkStartRequest(returnTo: "/x"), authorization: bearer)
    #expect(link.jsonBody.render().hasPrefix(#"{"url":"https://github.com/login/oauth/authorize?"#))
    #expect(link.headers.values["Set-Cookie"]?.contains("slock_github_oauth_nonce=") == true)
    await #expect(throws: OAuthFlowsError.missingAuthorization) {
        try await service.startWebOAuthLink(provider: "github", body: WebOAuthLinkStartRequest(), authorization: nil)
    }
    await #expect(throws: OAuthFlowsError.invalidToken) {
        try await service.startWebOAuthLink(provider: "github", body: WebOAuthLinkStartRequest(), authorization: "Bearer nope")
    }
}

@Test func oauthFlowsMobileHandoffPublishesTheLegacyBodies() async throws {
    let fixture = makeFixture()
    let service = fixture.service

    let started = try await service.startMobileOAuth(MobileOAuthStartRequest(
        isObject: true, returnUri: returnUri, provider: "google", mode: "login", codeChallenge: challenge()
    ))
    let startedBody = started.jsonBody.render()
    #expect(startedBody.hasPrefix(#"{"requestId":""#))
    #expect(startedBody.contains(#","authorizationUrl":"https://accounts.google.com/o/oauth2/v2/auth?"#))
    #expect(startedBody.contains(#","returnUri":"raft://oauth/callback","expiresAt":""#))
    await #expect(throws: OAuthFlowsError.invalidMobileStart) { try await service.startMobileOAuth(MobileOAuthStartRequest()) }
    await #expect(throws: OAuthFlowsError.returnURINotAllowed) {
        try await service.startMobileOAuth(MobileOAuthStartRequest(isObject: true))
    }

    // Callback: a bad state is the plain-text refusal; a good one redirects with the code.
    await #expect(throws: OAuthFlowsError.invalidMobileRequest) {
        try await service.mobileOAuthCallback(provider: "google", code: "c", state: "bad")
    }
    let state = try #require(queryItem(started.authorizationUrl, "state"))
    let cancelled = try await service.mobileOAuthCallback(provider: "google", code: nil, state: state, providerError: "denied")
    #expect(cancelled.location == "raft://oauth/callback?provider=google&mode=login&error=denied")

    // Complete without a stored account: sign up. Legal acceptance is checked first.
    let code = try await handoffCode(service)
    #expect(throws: OAuthFlowsError.legalAcceptanceRequired) {
        try service.completeMobileOAuth(MobileOAuthCompleteRequest(code: code, codeVerifier: verifier))
    }
    #expect(throws: OAuthFlowsError.termsChanged) {
        try service.completeMobileOAuth(MobileOAuthCompleteRequest(
            code: code, codeVerifier: verifier, acceptTerms: true, termsVersion: "old", privacyVersion: "old"
        ))
    }
    #expect(throws: OAuthFlowsError.pkceMismatch) {
        try service.completeMobileOAuth(MobileOAuthCompleteRequest(code: code, codeVerifier: "wrong"))
    }
    let fresh = try await handoffCode(service)
    let completed = try service.completeMobileOAuth(MobileOAuthCompleteRequest(
        code: fresh, codeVerifier: verifier, acceptTerms: true,
        termsVersion: AuthLegalPolicy.termsVersion, privacyVersion: AuthLegalPolicy.privacyVersion
    ))
    let rendered = completed.jsonBody.render()
    #expect(rendered.hasPrefix(#"{"user":{"id":""#))
    #expect(rendered.contains(#","email":"person@flows.test","name":"pending_"#))
    #expect(rendered.contains(#","profileSetupCompletedAt":null,"profileSetupProvider":"google""#))
    #expect(rendered.contains(#","signupSurveyCompletedAt":null,"signupRole":null},"accessToken":""#))
    #expect(rendered.hasSuffix(#","mode":"login","returnUri":"raft://oauth/callback"}"#))
    #expect(throws: OAuthFlowsError.handoffCodeConsumed) {
        try service.completeMobileOAuth(MobileOAuthCompleteRequest(code: fresh, codeVerifier: verifier))
    }
    #expect(fixture.sessionCount == 1)
}

@Test func oauthFlowsLinkCompleteListsTheLinkedIdentities() async throws {
    let fixture = makeFixture()
    let service = fixture.service
    let (userId, bearer) = verifiedBearer(fixture, "02")

    let started = try await service.startMobileOAuthLink(
        provider: "google",
        body: MobileOAuthStartRequest(isObject: true, returnUri: returnUri, codeChallenge: challenge()),
        authorization: bearer
    )
    let state = try #require(queryItem(started.authorizationUrl, "state"))
    let redirect = try await service.mobileOAuthCallback(provider: "google", code: "c", state: state)
    let code = try #require(queryItem(redirect.location, "code"))

    let other = verifiedBearer(fixture, "03").bearer
    #expect(throws: OAuthFlowsError.mobileLinkMismatch) {
        try service.completeMobileOAuthLink(
            provider: "google", body: MobileOAuthCompleteRequest(code: code, codeVerifier: verifier), authorization: other
        )
    }
    #expect(throws: OAuthFlowsError.providerMismatch) {
        try service.completeMobileOAuthLink(
            provider: "github", body: MobileOAuthCompleteRequest(code: code, codeVerifier: verifier), authorization: bearer
        )
    }
    let linked = try service.completeMobileOAuthLink(
        provider: "google", body: MobileOAuthCompleteRequest(code: code, codeVerifier: verifier), authorization: bearer
    )
    #expect(linked.jsonBody.render()
        == #"{"provider":"google","mode":"link","returnUri":"raft://oauth/callback","identities":[{"provider":"google","providerEmail":"person@flows.test"}]}"#)
    #expect(fixture.linkedProviderUserIds(userId: userId, provider: "google") == ["google-sub-1"])
    #expect(throws: OAuthFlowsError.handoffCodeConsumed) {
        try service.completeMobileOAuthLink(
            provider: "google", body: MobileOAuthCompleteRequest(code: code, codeVerifier: verifier), authorization: bearer
        )
    }
}

// MARK: - Request leniency

@Test func oauthFlowsRequestsReadFieldsLikeTheLegacyCasts() throws {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    // `server_id` shadows the alias even when it is null or not a string.
    #expect(try decode(OAuthInstallationLookupDTO.self, #"{"server_id":null,"serverId":"abc"}"#).serverId == nil)
    #expect(try decode(OAuthInstallationLookupDTO.self, #"{"server_id":4,"serverId":"abc"}"#).serverId == nil)
    #expect(try decode(OAuthInstallationLookupDTO.self, #"{"serverId":"abc","client_id":3}"#)
        == OAuthInstallationLookupDTO(clientId: nil, clientSecret: nil, serverId: "abc"))
    #expect(try decode(OAuthInstallationLookupDTO.self, "[1]") == OAuthInstallationLookupDTO())

    #expect(try decode(MobileOAuthStartRequest.self, "[1]").isObject == false)
    let start = try decode(MobileOAuthStartRequest.self, #"{"returnUri":1,"provider":"google","linkOnConflict":1}"#)
    #expect(start.isObject && start.returnUri == nil && start.provider == "google" && start.linkOnConflict)
    #expect(try decode(MobileOAuthCompleteRequest.self, #"{"acceptTerms":"true"}"#).acceptTerms == nil)

    let flags = try decode(FeatureFlagsEvaluateRequest.self, #"{"keys":["a",3],"serverId":null,"platform":7,"buildNumber":"12"}"#)
    #expect(flags.keys == [.string("a"), .integer(3)])
    #expect(flags.serverId == .absent)
    #expect(flags.platform == .invalid)
}

// MARK: - Feature flags

@Test func oauthFlowsEvaluateFeatureFlagsPublishTheLegacyBytes() throws {
    let fixture = makeFixture()
    let service = fixture.service
    let (userId, bearer) = verifiedBearer(fixture, "04")
    fixture.createFeatureFlagForTesting(key: "alpha.flag", defaultEnabled: true)
    fixture.createFeatureFlagForTesting(key: "beta_flag", defaultEnabled: false)
    fixture.createFeatureFlagForTesting(key: "kill", defaultEnabled: true, killSwitch: true)
    fixture.addFeatureFlagRuleForTesting(key: "beta_flag", stage: "user", decision: "allow", values: [userId])
    fixture.addFeatureFlagRuleForTesting(
        key: "alpha.flag", stage: "platform", decision: "deny", values: ["mobile"]
    )

    func evaluate(_ json: String) throws -> String {
        let body = try JSONDecoder().decode(FeatureFlagsEvaluateRequest.self, from: Data(json.utf8))
        return try service.evaluateFeatureFlags(body, authorization: bearer).jsonBody.render()
    }
    #expect(try evaluate(#"{"keys":["alpha.flag"," beta_flag ","kill","missing","alpha.flag"]}"#)
        == #"{"evaluations":[{"key":"alpha.flag","enabled":true,"reason":"default"},{"key":"beta_flag","enabled":true,"reason":"user_rule"},{"key":"kill","enabled":false,"reason":"kill_switch"},{"key":"missing","enabled":false,"reason":"missing_flag"}]}"#)
    #expect(try evaluate(#"{"key":"alpha.flag","platform":"mobile","serverId":null}"#)
        == #"{"evaluations":[{"key":"alpha.flag","enabled":false,"reason":"platform_rule"}]}"#)
    for bad in [#"{}"#, #"{"keys":[]}"#, #"{"keys":[1]}"#, #"{"keys":["Bad Key"]}"#] {
        #expect(throws: OAuthFlowsError.featureFlagKeysInvalid) { try evaluate(bad) }
    }
    #expect(throws: OAuthFlowsError.featureFlagServerIdInvalid) { try evaluate(#"{"key":"kill","serverId":"nope"}"#) }
    #expect(throws: OAuthFlowsError.notAServerMember) {
        try evaluate(#"{"key":"kill","serverId":"22222222-2222-4222-8222-222222222222"}"#)
    }
    #expect(throws: OAuthFlowsError.featureFlagPlatformInvalid) { try evaluate(#"{"key":"kill","platform":"tv"}"#) }

    let unverified = OAuthFlowsUnitFixture()
    unverified.addAccount(id: "11111111-1111-4111-8111-000003000099", email: "nv@slock.test", password: "password123")
    let token = unverified.mintAccessTokenForTesting(userId: "11111111-1111-4111-8111-000003000099")
    #expect(throws: OAuthFlowsError.emailVerificationRequired) {
        try unverified.service.evaluateFeatureFlags(FeatureFlagsEvaluateRequest(key: "kill"), authorization: "Bearer " + token)
    }
}

@Test func oauthFlowsClientFactsKeepTheLegacyBuildNumberCasts() {
    func facts(_ number: JSONValue?) -> Int? {
        OAuthFlowsService.clientFacts(FeatureFlagsEvaluateRequest(buildNumber: number)).buildNumber
    }
    #expect(facts(.string("123")) == 123)
    #expect(facts(.string("1234567890123456")) == nil)
    #expect(facts(.string("-1")) == nil)
    #expect(facts(.integer(42)) == 42)
    #expect(facts(.integer(-1)) == nil)
    #expect(facts(.number(7.0)) == 7)
    #expect(facts(.number(7.5)) == nil)
    #expect(facts(.bool(true)) == nil)
    #expect(OAuthFlowsService.clientFacts(FeatureFlagsEvaluateRequest(os: "ios", buildType: "nightly")).os == "ios")
    #expect(OAuthFlowsService.clientFacts(FeatureFlagsEvaluateRequest(os: "ios", buildType: "nightly")).buildType == nil)
}

// MARK: - Atomic sections

/// A handoff code is spent once: the consumed check, the PKCE check and the
/// sign-up are one store critical section, so a burst of simultaneous
/// completions creates one account and one session.
@Test func oauthFlowsCompleteMobileSpendsAHandoffExactlyOnce() async throws {
    let fixture = makeFixture()
    let store = fixture.store
    seedHandoff(store, id: "req-1", code: "code-1", mode: "login", userId: nil)
    let passwordPlaceholder = try await PasswordWork.hash(AuthTokenCodec.randomHex(32))

    let outcomes = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<24 {
            group.addTask {
                if case .signedIn = store.completeMobile(
                    code: "code-1", verifier: verifier, pendingLinkToken: nil, acceptTerms: true,
                    termsVersion: AuthLegalPolicy.termsVersion,
                    privacyVersion: AuthLegalPolicy.privacyVersion, now: Date(),
                    passwordPlaceholder: passwordPlaceholder
                ) { return true }
                return false
            }
        }
        var collected: [Bool] = []
        for await outcome in group { collected.append(outcome) }
        return collected
    }
    #expect(outcomes.filter { $0 }.count == 1)
    #expect(fixture.sessionCount == 1)
    #expect(fixture.accountCount == 1)
}

@Test func oauthFlowsCompleteMobileLinkSpendsAHandoffExactlyOnce() async {
    let fixture = makeFixture()
    let store = fixture.store
    let caller = "11111111-1111-4111-8111-000003000010"
    seedHandoff(store, id: "req-2", code: "code-2", mode: "link", userId: caller)

    let outcomes = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<24 {
            group.addTask {
                if case .linked = store.completeMobileLink(
                    provider: "google", callerId: caller, code: "code-2", verifier: verifier, now: Date()
                ) { return true }
                return false
            }
        }
        var collected: [Bool] = []
        for await outcome in group { collected.append(outcome) }
        return collected
    }
    #expect(outcomes.filter { $0 }.count == 1)
    #expect(fixture.linkedIdentityCount(userId: caller) == 1)
}

/// The native Apple claim moves `pending_provider` to `provider_processing`
/// once; every other simultaneous caller sees the request already consumed.
@Test func oauthFlowsNativeAppleClaimIsExclusive() async {
    let fixture = makeFixture()
    let store = fixture.store
    store.insertMobileRequest(MobileOAuthRequest(
        id: "native-1", provider: "apple", mode: "login", status: "pending_provider",
        codeChallenge: challenge(), returnUri: returnUri, nonce: "",
        expiresAt: Date().addingTimeInterval(600), userId: nil
    ))

    let claims = await withTaskGroup(of: String.self) { group in
        for _ in 0..<24 {
            group.addTask {
                switch store.claimNativeApple(
                    requestId: "native-1", mode: "login", codeChallenge: challenge(),
                    tokenUserId: nil, callerId: nil, now: Date()
                ) {
                case .claimed: return "claimed"
                case .consumed: return "consumed"
                default: return "other"
                }
            }
        }
        var collected: [String] = []
        for await claim in group { collected.append(claim) }
        return collected
    }
    #expect(claims.filter { $0 == "claimed" }.count == 1)
    #expect(claims.filter { $0 == "consumed" }.count == 23)
}

/// Every valid callback completes; the stored handoff code and its hash are
/// written together, even when callbacks target the same request.
@Test func oauthFlowsMobileCallbackPublishesOneHandoffPerRequest() async {
    let fixture = makeFixture()
    let store = fixture.store
    store.insertMobileRequest(MobileOAuthRequest(
        id: "cb-1", provider: "google", mode: "login", status: "pending_provider",
        codeChallenge: challenge(), returnUri: returnUri, nonce: "n",
        expiresAt: Date().addingTimeInterval(600), userId: nil
    ))
    let profile = MobileProviderProfile(providerUserId: "sub", email: "cb@flows.test", displayName: nil)

    let outcomes = await withTaskGroup(of: MobileCallbackOutcome.self) { group in
        for index in 0..<24 {
            group.addTask {
                store.mobileCallback(
                    requestId: "cb-1", provider: "google", mode: "login", stateDesktopNonce: nil,
                    code: "c", providerError: nil, profile: profile, handoff: "handoff-\(index)"
                )
            }
        }
        var collected: [MobileCallbackOutcome] = []
        for await outcome in group { collected.append(outcome) }
        return collected
    }
    // Every callback is accepted (the legacy route has no single-use rule), but
    // each one is a whole write: the stored code and its hash always agree.
    let request = fixture.mobileHandoffFacts(id: "cb-1")
    #expect(outcomes.count == 24)
    #expect(outcomes.allSatisfy { $0 == .completed(returnUri: returnUri, mode: "login") })
    #expect(request?.codeHash == request?.handoffCode.map { AuthTokenCodec.sha256($0) })
}

/// Recording a web login is one decision: simultaneous callbacks for a free
/// email each append their own completion, none is lost.
@Test func oauthFlowsRecordWebLoginKeepsEveryCompletion() async {
    let fixture = makeFixture()
    let store = fixture.store
    let existing = "11111111-1111-4111-8111-000003000020"
    fixture.addAccount(id: existing, email: "taken@flows.test", password: "password123")

    let outcomes = await withTaskGroup(of: WebLoginRecordOutcome.self) { group in
        for index in 0..<24 {
            group.addTask {
                store.recordWebLogin(
                    provider: "google", providerUserId: "sub-\(index)",
                    email: index.isMultiple(of: 2) ? "taken@flows.test" : "free-\(index)@flows.test",
                    linkOnConflict: false, returnTo: "/", code: "code-\(index)"
                )
            }
        }
        var collected: [WebLoginRecordOutcome] = []
        for await outcome in group { collected.append(outcome) }
        return collected
    }
    #expect(outcomes.filter { $0 == .accountConflict }.count == 12)
    #expect(outcomes.filter { $0 == .recorded }.count == 12)
    #expect(fixture.socialCompletionCount == 12)
}
