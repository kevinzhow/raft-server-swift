import Crypto
import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The identity/session/app-login service owns byte-exact bodies and one store
/// critical section per write. The HTTP tests lock status codes and headers;
/// these tests lock the published bytes and the atomic decisions.

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makeDirectory(_ suffix: String, passwordEstablished: Bool = true) -> (directory: EmailLoginDirectory, userId: String, bearer: String) {
    let directory = EmailLoginDirectory()
    directory.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    let userId = "11111111-1111-4111-8111-0000020\(suffix)"
    directory.addAccount(
        id: userId,
        email: "Identity-\(suffix)@slock.test",
        password: "password123",
        passwordCredentialEstablished: passwordEstablished
    )
    directory.markEmailVerified(userId: userId)
    return (directory, userId, directory.mintAccessTokenForTesting(userId: userId))
}

private func pkcePair() -> (verifier: String, challenge: String) {
    let verifier = String(repeating: "v", count: 43)
    let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
    let challenge = digest.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return (verifier, challenge)
}

private func render(_ error: AuthIdentitiesError) -> String {
    error.publishedErrorBody.render()
}

// MARK: - Bodies

@Test func authIdentitiesPublishTheLegacyBytesAndTheFinalIdentityGuard() throws {
    let (directory, userId, bearer) = makeDirectory("01", passwordEstablished: false)
    let service = directory.authIdentities
    directory.addAuthIdentityForTesting(userId: userId, provider: "github", providerEmail: "a/b@example.com")

    #expect(try service.identities(authorization: "Bearer \(bearer)").jsonBody.render()
        == #"{"identities":[{"provider":"github","providerEmail":"a/b@example.com"}],"passwordConfigured":false}"#)
    #expect(throws: AuthIdentitiesError.unauthorized) { try service.identities(authorization: nil) }
    #expect(render(.unauthorized) == #"{"error":"Unauthorized"}"#)

    #expect(throws: AuthIdentitiesError.passwordCredentialRequired) {
        try service.unlink(authorization: "Bearer \(bearer)", provider: "github")
    }
    #expect(render(.passwordCredentialRequired)
        == #"{"code":"PASSWORD_CREDENTIAL_REQUIRED","error":"Set a password before disconnecting your final sign-in account."}"#)
    #expect(try service.unlink(authorization: "Bearer \(bearer)", provider: "apple").jsonBody.render()
        == #"{"unlinked":false,"identities":[{"provider":"github","providerEmail":"a/b@example.com"}],"passwordConfigured":false}"#)

    directory.markPasswordCredentialEstablished(userId: userId)
    #expect(try service.unlink(authorization: "Bearer \(bearer)", provider: "github").jsonBody.render()
        == #"{"unlinked":true,"identities":[],"passwordConfigured":true}"#)
}

@Test func authIdentitiesErrorBodiesKeepTheirLegacyMemberOrder() {
    #expect(render(.invalidCredentials)
        == #"{"code":"AUTH_INVALID_CREDENTIALS","error":"Invalid email or password"}"#)
    #expect(render(.wrongCurrentPassword)
        == #"{"code":"AUTH_CURRENT_PASSWORD_INCORRECT","error":"Current password is incorrect"}"#)
    #expect(render(.invalidToken) == #"{"error":"Invalid or expired token","code":"auth_required"}"#)
    #expect(render(.missingAuthorization)
        == #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#)
    #expect(render(.avatarTooLarge(maxBytes: 5_242_880))
        == #"{"error":"Avatar image must be 5 MB or smaller","errorCode":"PROFILE_AVATAR_TOO_LARGE","maxBytes":5242880}"#)
    #expect(render(.requestExpired(redirectUrl: "raft://login/callback?requestId=r&error=expired"))
        == #"{"error":"App login request expired","code":"request_expired","redirectUrl":"raft:\/\/login\/callback?requestId=r&error=expired"}"#
        .replacingOccurrences(of: "\\/", with: "/"))
    #expect(render(.invalidLoginBody([
        AuthRequestIssue(path: "email", message: "Required"),
        AuthRequestIssue(path: "password", message: "Expected string, received boolean"),
    ])) == #"{"error":"Invalid email login body","code":"email_login_body_invalid","issues":[{"path":"email","message":"Required"},{"path":"password","message":"Expected string, received boolean"}]}"#)
    #expect(AuthIdentitiesError.requestNotFound.status == 404)
    #expect(AuthIdentitiesError.codeConsumed.status == 410)
    #expect(AuthIdentitiesError.requestNotApproved.status == 409)
}

@Test func authIdentitiesLoginDecodesEveryLegacyIssueShape() throws {
    let (directory, userId, _) = makeDirectory("02")
    let service = directory.authIdentities
    let decoder = JSONDecoder()
    func decode(_ json: String) -> LoginRequest? {
        try? decoder.decode(LoginRequest.self, from: Data(json.utf8))
    }

    #expect(throws: AuthIdentitiesError.invalidLoginBody([
        AuthRequestIssue(path: "", message: "Expected object, received string"),
    ])) { try service.login(decode("[1]")) }
    #expect(throws: AuthIdentitiesError.invalidLoginBody([
        AuthRequestIssue(path: "email", message: "Required"),
        AuthRequestIssue(path: "password", message: "String must contain at least 1 character(s)"),
    ])) { try service.login(decode(#"{"password":""}"#)) }
    // A JSON 0 or 1 read as a boolean through the old number bridge.
    #expect(throws: AuthIdentitiesError.invalidLoginBody([
        AuthRequestIssue(path: "email", message: "Expected string, received number"),
        AuthRequestIssue(path: "password", message: "Expected string, received boolean"),
    ])) { try service.login(decode(#"{"email":5,"password":1}"#)) }
    #expect(throws: AuthIdentitiesError.invalidLoginBody([
        AuthRequestIssue(path: "email", message: "Expected string, received null"),
        AuthRequestIssue(path: "password", message: "Expected string, received object"),
    ])) { try service.login(decode(#"{"email":null,"password":{}}"#)) }
    #expect(throws: AuthIdentitiesError.invalidCredentials) {
        try service.login(LoginRequest(email: "identity-02@slock.test", password: "wrong"))
    }

    let response = try service.login(LoginRequest(email: " IDENTITY-02@slock.test ", password: "password123"))
    let body = response.jsonBody.render()
    #expect(body.hasPrefix(#"{"user":{"id":"\#(userId)","email":"identity-02@slock.test"},"accessToken":""#))
    #expect(body.hasSuffix(#","linkedProvider":null}"#))
    #expect(directory.sessionUserId(authorization: "Bearer \(response.accessToken)") == userId)
}

@Test func authIdentitiesMeRendersTheUserObjectInOrderWithTheObservedTimezone() throws {
    let (directory, userId, bearer) = makeDirectory("03")
    let service = directory.authIdentities
    directory.authProfileStore.state.withLock { state in
        state.accountSurface.accounts["identity-03@slock.test"] = Account(
            id: userId,
            email: "identity-03@slock.test",
            passwordHash: AuthTokenCodec.sha256("password123"),
            displayLanguage: "en",
            name: "identity-03",
            profileSetupSuggestedHandle: "ident",
            profileSetupProvider: "google",
            profileSetupCompletedAt: fixedDate,
            avatarUrl: "/api/avatars/users/x.webp",
            shareUsageData: true,
            emailVerified: true
        )
    }
    let gravatar = AuthTokenCodec.sha256("identity-03@slock.test")
    let user = #"{"id":"\#(userId)","email":"identity-03@slock.test","name":"identity-03","emailVerified":true,"displayName":"identity-03","gravatarHash":"\#(gravatar)","displayLanguage":"en","profileSetupCompletedAt":"2023-11-14T22:13:20.000Z","profileSetupSuggestedHandle":"ident","profileSetupProvider":"google","avatarUrl":"/api/avatars/users/x.webp","shareUsageData":true,"preferredLanguage":null,"preferredTimezone":null,"preferredTranslationMode":"off","autoTranslationEnabled":false,"preferredTranslationDisplay":"translated","preferredTimeFormat":null,"preferredMessageBodyFontSize":null,"referralSource":null,"referralSourceOther":null,"referralSourceSkippedAt":null"#

    #expect(try service.me(authorization: "Bearer \(bearer)").jsonBody.render() == user + "}")
    // The standalone user payload other domains embed renders the same bytes.
    #expect(AuthUserDTO(account: directory.authProfileStore.account(userId: userId)!).jsonBody.render() == user + "}")

    directory.authProfileStore.state.withLock { state in
        state.profile.timezoneObservations[userId] = TimezoneObservation(
            firstTimezone: "Asia/Tokyo", firstAt: fixedDate, lastTimezone: "UTC", lastAt: fixedDate
        )
    }
    #expect(try service.me(authorization: "Bearer \(bearer)").jsonBody.render()
        == user + #","firstObservedTimezone":"Asia/Tokyo","firstObservedTimezoneAt":"2023-11-14T22:13:20.000Z","lastObservedTimezone":"UTC","lastObservedTimezoneAt":"2023-11-14T22:13:20.000Z"}"#)

    #expect(throws: AuthIdentitiesError.missingAuthorization) { try service.me(authorization: nil) }
    #expect(throws: AuthIdentitiesError.invalidToken) { try service.me(authorization: "Bearer nope") }
}

// MARK: - Profile patch

@Test func authIdentitiesPatchKeepsTheLegacyValidationOrderAndLeniency() throws {
    let (directory, userId, bearer) = makeDirectory("04")
    let service = directory.authIdentities
    let auth = "Bearer \(bearer)"
    func patch(_ json: String) throws -> AuthProfileUserResponse {
        let request = try? JSONDecoder().decode(UpdateProfileRequest.self, from: Data(json.utf8))
        return try service.updateProfile(authorization: auth, request)
    }

    #expect(throws: AuthIdentitiesError.profileUpdateFailed) { try patch("[]") }
    #expect(throws: AuthIdentitiesError.missingAuthorization) {
        try service.updateProfile(authorization: nil, UpdateProfileRequest())
    }
    #expect(throws: AuthIdentitiesError.invalidProfile("Invalid preferredTimezone")) {
        try patch(#"{"preferredTimezone":"Mars/Base"}"#)
    }
    // null is a present key: it clears the mode-less fields and is invalid for the enums.
    #expect(throws: AuthIdentitiesError.invalidProfile("Invalid preferredTranslationMode")) {
        try patch(#"{"preferredTranslationMode":null}"#)
    }
    #expect(throws: AuthIdentitiesError.invalidProfile("referralSource is required when referralSourceOther is provided")) {
        try patch(#"{"referralSourceOther":null}"#)
    }
    #expect(throws: AuthIdentitiesError.invalidProfile("referralSourceSkipped must be a boolean")) {
        try patch(#"{"referralSourceSkipped":null}"#)
    }

    // A JSON 1 / 0 reads as a Bool, as the old `as? Bool` cast did.
    let updated = try patch(#"{"shareUsageData":1,"autoTranslationEnabled":1,"preferredLanguage":"EN-us","preferredTimeFormat":"24H","preferredMessageBodyFontSize":"LG","displayLanguage":" zh-CN "}"#)
    #expect(updated.user.shareUsageData == true)
    #expect(updated.user.autoTranslationEnabled)
    #expect(updated.user.preferredLanguage == "en-us")
    #expect(updated.user.preferredTimeFormat == "24h")
    #expect(updated.user.preferredMessageBodyFontSize == "lg")
    #expect(updated.user.displayLanguage == "zh-cn")

    let other = try patch(#"{"referralSource":"other","referralSourceOther":"  podcast  "}"#)
    #expect(other.user.referralSource == "other")
    #expect(other.user.referralSourceOther == "podcast")
    #expect(try patch(#"{"referralSource":"search","referralSourceOther":"x"}"#).user.referralSourceOther == nil)
    #expect(try patch(#"{"referralSource":null}"#).user.referralSource == nil)
    #expect(try patch(#"{"referralSourceSkipped":true}"#).user.referralSourceSkippedAt != nil)

    // The usage opt-in mints an analytics id once; opting out removes it.
    let before = directory.authProfileStore.analyticsIds[userId]
    #expect(before != nil)
    _ = try patch(#"{"shareUsageData":true}"#)
    #expect(directory.authProfileStore.analyticsIds[userId] == before)
    _ = try patch(#"{"shareUsageData":false}"#)
    #expect(directory.authProfileStore.analyticsIds[userId] == nil)
    _ = try patch(#"{"shareUsageData":null}"#)
    #expect(directory.authProfileStore.analyticsIds[userId] == nil)
    _ = try patch(#"{"shareUsageData":true}"#)
    #expect(directory.authProfileStore.analyticsIds[userId] != nil && directory.authProfileStore.analyticsIds[userId] != before)
}

@Test func authIdentitiesPatchWritesThePasswordBeforeLaterFieldsAreValidated() throws {
    let (directory, _, bearer) = makeDirectory("05")
    let service = directory.authIdentities
    let auth = "Bearer \(bearer)"
    func patch(_ json: String) throws {
        _ = try service.updateProfile(
            authorization: auth,
            try? JSONDecoder().decode(UpdateProfileRequest.self, from: Data(json.utf8))
        )
    }
    #expect(throws: AuthIdentitiesError.invalidProfile("New password must be at least 8 characters")) {
        try patch(#"{"currentPassword":"password123","newPassword":"short"}"#)
    }
    #expect(throws: AuthIdentitiesError.wrongCurrentPassword) {
        try patch(#"{"currentPassword":"nope","newPassword":"longenough1"}"#)
    }
    // The password is changed, then the invalid field still answers its 400.
    #expect(throws: AuthIdentitiesError.invalidProfile("Invalid preferredTimezone")) {
        try patch(#"{"currentPassword":"password123","newPassword":"longenough1","preferredTimezone":"x"}"#)
    }
    #expect(throws: AuthIdentitiesError.invalidCredentials) {
        try service.login(LoginRequest(email: "identity-05@slock.test", password: "password123"))
    }
    #expect((try? service.login(LoginRequest(email: "identity-05@slock.test", password: "longenough1"))) != nil)
}

// MARK: - App login atomic sections

private func startedRequest(_ service: AuthIdentitiesService, challenge: String) throws -> String {
    let started = try service.appLoginStart(AppLoginStartRequest(
        returnUri: "raft://login/callback",
        codeChallenge: challenge
    ))
    #expect(started.loginUrl == "https://app.raft.test/login/app?request=\(started.requestId)")
    return started.requestId
}

@Test func appLoginCompleteSpendsTheCodeOnceAndAWrongVerifierBurnsNothing() throws {
    let (directory, userId, bearer) = makeDirectory("06")
    let service = directory.authIdentities
    let pair = pkcePair()
    let requestId = try startedRequest(service, challenge: pair.challenge)
    let auth = "Bearer \(bearer)"

    #expect(throws: AuthIdentitiesError.requestNotFound) {
        try service.appLoginApprove(authorization: auth, requestId: "missing")
    }
    #expect(throws: AuthIdentitiesError.invalidToken) {
        try service.appLoginDescribe(authorization: nil, requestId: requestId)
    }
    #expect(try service.appLoginDescribe(authorization: auth, requestId: requestId).status == "pending")

    let approved = try service.appLoginApprove(authorization: auth, requestId: requestId)
    #expect(approved.redirectUrl.hasPrefix("raft://login/callback?requestId=\(requestId)&code="))
    let code = String(approved.redirectUrl.split(separator: "=").last ?? "")
    #expect(throws: AuthIdentitiesError.requestNotPending) {
        try service.appLoginDeny(authorization: auth, requestId: requestId)
    }

    #expect(throws: AuthIdentitiesError.pkceMismatch) {
        try service.appLoginComplete(AppLoginCompleteRequest(code: code, codeVerifier: "wrong"))
    }
    #expect(throws: AuthIdentitiesError.codeNotFound) {
        try service.appLoginComplete(AppLoginCompleteRequest(code: "nope", codeVerifier: pair.verifier))
    }
    #expect(throws: AuthIdentitiesError.invalidAppLoginCompletion) {
        try service.appLoginComplete(AppLoginCompleteRequest(code: code))
    }

    let completed = try service.appLoginComplete(AppLoginCompleteRequest(code: code, codeVerifier: pair.verifier))
    #expect(completed.user.id == userId)
    #expect(completed.jsonBody.render().hasPrefix(#"{"user":{"id":"\#(userId)""#))
    #expect(directory.sessionUserId(authorization: "Bearer \(completed.accessToken)") == userId)
    #expect(throws: AuthIdentitiesError.codeConsumed) {
        try service.appLoginComplete(AppLoginCompleteRequest(code: code, codeVerifier: pair.verifier))
    }
}

@Test func appLoginExpiredRequestAnswersTheRedirectAndNothingElseChanges() throws {
    let (directory, _, bearer) = makeDirectory("07")
    let service = directory.authIdentities
    let requestId = try startedRequest(service, challenge: pkcePair().challenge)
    directory.expireAppLoginRequestForTesting(requestId: requestId)
    #expect(throws: AuthIdentitiesError.requestExpired(
        redirectUrl: "raft://login/callback?requestId=\(requestId)&error=expired"
    )) { try service.appLoginDeny(authorization: "Bearer \(bearer)", requestId: requestId) }
    #expect(try service.appLoginDescribe(authorization: "Bearer \(bearer)", requestId: requestId).status == "pending")
}

@Test func appLoginStartValidatesInTheLegacyOrder() {
    let (directory, _, _) = makeDirectory("08")
    let service = directory.authIdentities
    let challenge = pkcePair().challenge
    #expect(throws: AuthIdentitiesError.invalidAppLoginRequest) {
        try service.appLoginStart(AppLoginStartRequest(returnUri: "", codeChallenge: challenge))
    }
    #expect(throws: AuthIdentitiesError.returnUriNotAllowed) {
        try service.appLoginStart(AppLoginStartRequest(returnUri: "https://evil.test", codeChallenge: "x"))
    }
    #expect(throws: AuthIdentitiesError.challengeMethodInvalid) {
        try service.appLoginStart(AppLoginStartRequest(
            returnUri: "raft-debug://login/callback", codeChallenge: "x", codeChallengeMethod: "plain"
        ))
    }
    #expect(throws: AuthIdentitiesError.challengeInvalid) {
        try service.appLoginStart(AppLoginStartRequest(returnUri: "raft://login/callback", codeChallenge: "short"))
    }
}

@Test func appLoginApproveAndDenyRaceDecidesOneRequestOnce() async throws {
    let (directory, _, bearer) = makeDirectory("09")
    let service = directory.authIdentities
    let auth = "Bearer \(bearer)"
    for round in 0..<30 {
        let requestId = try startedRequest(service, challenge: pkcePair().challenge)
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<6 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        return (try? service.appLoginApprove(authorization: auth, requestId: requestId)) != nil
                    }
                    return (try? service.appLoginDeny(authorization: auth, requestId: requestId)) != nil
                }
            }
            var wins = 0
            for await won in group where won { wins += 1 }
            return wins
        }
        #expect(outcomes == 1, "round \(round)")
    }
}

@Test func appLoginCompleteRaceOpensOneSession() async throws {
    let (directory, userId, bearer) = makeDirectory("10")
    let service = directory.authIdentities
    let pair = pkcePair()
    let requestId = try startedRequest(service, challenge: pair.challenge)
    let redirect = try service.appLoginApprove(authorization: "Bearer \(bearer)", requestId: requestId).redirectUrl
    let code = String(redirect.split(separator: "=").last ?? "")
    let sessionsBefore = directory.sessionCount(for: userId)
    let wins = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<8 {
            group.addTask {
                (try? service.appLoginComplete(AppLoginCompleteRequest(code: code, codeVerifier: pair.verifier))) != nil
            }
        }
        var wins = 0
        for await won in group where won { wins += 1 }
        return wins
    }
    #expect(wins == 1)
    #expect(directory.sessionCount(for: userId) == sessionsBefore + 1)
}

// MARK: - Identity and login races

@Test func concurrentUnlinksOfTheLastTwoIdentitiesLeaveOne() async throws {
    let (directory, userId, bearer) = makeDirectory("11", passwordEstablished: false)
    directory.addAuthIdentityForTesting(userId: userId, provider: "google", providerEmail: "g@example.com")
    directory.addAuthIdentityForTesting(userId: userId, provider: "github", providerEmail: "h@example.com")
    let service = directory.authIdentities
    let unlinked = await withTaskGroup(of: Bool.self) { group in
        for provider in ["google", "github"] {
            group.addTask {
                (try? service.unlink(authorization: "Bearer \(bearer)", provider: provider))?.unlinked == true
            }
        }
        var count = 0
        for await done in group where done { count += 1 }
        return count
    }
    #expect(unlinked == 1)
    #expect(directory.authIdentityCount(userId: userId) == 1)
}

@Test func pendingLinkIsSpentOnceByConcurrentLoginsAndLinksTheIdentity() async throws {
    let (directory, userId, _) = makeDirectory("12")
    var state = directory.authProfileStore.accountState
    state.pendingSocialLinks["pending-token"] = PendingSocialLink(
        token: "pending-token",
        provider: "github",
        providerUserId: "gh-1",
        email: "identity-12@slock.test",
        expiresAt: Date().addingTimeInterval(600)
    )
    directory.authProfileStore.accountState = state
    let service = directory.authIdentities

    #expect(throws: AuthIdentitiesError.pendingLinkAccountMismatch) {
        try service.login(LoginRequest(email: "other@slock.test", password: "x", pendingLinkToken: "pending-token"))
    }
    #expect(throws: AuthIdentitiesError.pendingLinkExpired) {
        try service.login(LoginRequest(email: "identity-12@slock.test", password: "x", pendingLinkToken: "unknown"))
    }
    let linked = await withTaskGroup(of: String?.self) { group in
        for _ in 0..<6 {
            group.addTask {
                try? service.login(LoginRequest(
                    email: "identity-12@slock.test", password: "password123", pendingLinkToken: "pending-token"
                )).linkedProvider
            }
        }
        var providers: [String] = []
        for await provider in group { if let provider { providers.append(provider) } }
        return providers.count == 1 ? providers[0] : "wins=\(providers.count)"
    }
    #expect(linked == "github")
    #expect(directory.linkedProviderUserIds(userId: userId, provider: "github") == ["gh-1"])
}

@Test func integrationSettingsClientsRequiresASessionAndServerMembership() throws {
    let (directory, userId, bearer) = makeDirectory("13")
    let service = directory.authIdentities
    let serverId = "33333333-3333-4333-8333-333333339013"
    directory.oauth.addOwnedServer(id: serverId, slug: "identity-13", name: "Identity", ownerId: userId)
    #expect(throws: AuthIdentitiesError.unauthorized) {
        try service.integrationSettingsClients(authorization: nil, serverId: serverId)
    }
    #expect(throws: AuthIdentitiesError.notAServerMember) {
        try service.integrationSettingsClients(authorization: "Bearer \(bearer)", serverId: "other-server")
    }
    #expect(try service.integrationSettingsClients(authorization: "Bearer \(bearer)", serverId: serverId)
        .jsonBody.render() == "[]")
    #expect(IntegrationSettingsClientsResponse(clients: [IntegrationSettingsClient(
        id: "1", clientId: "c", name: "n", appType: "t", description: nil, homepageUrl: "https://x.test", publishStatus: "draft"
    )]).jsonBody.render()
        == #"[{"id":"1","clientId":"c","name":"n","appType":"t","description":null,"homepageUrl":"https://x.test","publishStatus":"draft"}]"#)
}

@Test func oauthSessionIgnoresRevokedFamiliesLikeTheRetiredLookup() {
    let (directory, userId, bearer) = makeDirectory("14")
    let service = directory.authIdentities
    guard case .missing = service.oauthSession(authorization: nil) else { Issue.record("expected missing"); return }
    guard case .invalid = service.oauthSession(authorization: "Bearer nope") else { Issue.record("expected invalid"); return }
    guard case .user(let human) = service.oauthSession(authorization: "Bearer \(bearer)") else {
        Issue.record("expected user")
        return
    }
    #expect(human.id == userId)
    #expect(human.emailVerified)
}
