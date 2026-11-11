import Crypto
import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The identity/session/app-login service owns byte-exact bodies and one store
/// critical section per write. The HTTP tests lock status codes and headers;
/// these tests lock the published bytes and the atomic decisions.

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makeFixture(_ suffix: String, passwordEstablished: Bool = true) -> (scene: AuthServicesUnitFixture, userId: String, bearer: String) {
    let scene = AuthServicesUnitFixture()
    scene.setAppURL("https://app.raft.test")
    let userId = "11111111-1111-4111-8111-0000020\(suffix)"
    scene.addAccount(
        id: userId,
        email: "Identity-\(suffix)@slock.test",
        password: "password123",
        passwordCredentialEstablished: passwordEstablished
    )
    scene.markEmailVerified(userId: userId)
    return (scene, userId, scene.mintAccessTokenForTesting(userId: userId))
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
    let (scene, userId, bearer) = makeFixture("01", passwordEstablished: false)
    let service = scene.identities
    scene.addAuthIdentityForTesting(userId: userId, provider: "github", providerEmail: "a/b@example.com")

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

    scene.markPasswordCredentialEstablished(userId: userId)
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
    let (scene, userId, _) = makeFixture("02")
    let service = scene.identities
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
    let expectedUser = try service.me(authorization: "Bearer \(response.accessToken)").user.jsonBody.render()
    #expect(body.hasPrefix("{\"user\":\(expectedUser),\"accessToken\":\""))
    #expect(response.user.emailVerified)
    #expect(response.user.name == "identity-02")
    #expect(response.user.profileSetupCompletedAt != nil)
    #expect(body.hasSuffix(#","linkedProvider":null}"#))
    #expect(scene.sessionUserId(authorization: "Bearer \(response.accessToken)") == userId)
}

@Test func authIdentitiesMeRendersTheUserObjectInOrderWithTheObservedTimezone() throws {
    let (scene, userId, bearer) = makeFixture("03")
    let service = scene.identities
    scene.seedMeAccount(
        userId: userId, email: "identity-03@slock.test", password: "password123", completedAt: fixedDate
    )
    let gravatar = AuthTokenCodec.sha256("identity-03@slock.test")
    // Pinned `services/userService.ts` `toPublicUser`: every member is present
    // in this order; nullable members print null, `displayName` is not derived
    // from `name`, and the observed-timezone pair sits after `preferredTimezone`.
    let user = #"{"id":"\#(userId)","email":"identity-03@slock.test","gravatarHash":"\#(gravatar)","name":"identity-03","displayName":null,"description":null,"avatarUrl":"/api/avatars/users/x.webp","emailVerified":true,"preferredLanguage":null,"displayLanguage":"en","preferredTimezone":null,"firstObservedTimezone":null,"firstObservedTimezoneAt":null,"lastObservedTimezone":null,"lastObservedTimezoneAt":null,"preferredTranslationMode":"off","autoTranslationEnabled":false,"preferredTranslationDisplay":"translated","preferredTimeFormat":null,"preferredMessageBodyFontSize":null,"shareUsageData":true,"referralSource":null,"referralSourceOther":null,"referralSourceSkippedAt":null,"profileSetupCompletedAt":"2023-11-14T22:13:20.000Z","profileSetupSuggestedHandle":"ident","signupSurveyCompletedAt":null,"signupRole":null,"profileSetupProvider":"google"}"#

    #expect(try service.me(authorization: "Bearer \(bearer)").jsonBody.render() == user)
    // The standalone user payload other domains embed renders the same bytes.
    #expect(scene.userDTO(userId: userId)!.jsonBody.render() == user)

    scene.seedTimezoneObservation(
        userId: userId, firstTimezone: "Asia/Tokyo", firstAt: fixedDate, lastTimezone: "UTC", lastAt: fixedDate
    )
    let observed = #"{"id":"\#(userId)","email":"identity-03@slock.test","gravatarHash":"\#(gravatar)","name":"identity-03","displayName":null,"description":null,"avatarUrl":"/api/avatars/users/x.webp","emailVerified":true,"preferredLanguage":null,"displayLanguage":"en","preferredTimezone":null,"firstObservedTimezone":"Asia/Tokyo","firstObservedTimezoneAt":"2023-11-14T22:13:20.000Z","lastObservedTimezone":"UTC","lastObservedTimezoneAt":"2023-11-14T22:13:20.000Z","preferredTranslationMode":"off","autoTranslationEnabled":false,"preferredTranslationDisplay":"translated","preferredTimeFormat":null,"preferredMessageBodyFontSize":null,"shareUsageData":true,"referralSource":null,"referralSourceOther":null,"referralSourceSkippedAt":null,"profileSetupCompletedAt":"2023-11-14T22:13:20.000Z","profileSetupSuggestedHandle":"ident","signupSurveyCompletedAt":null,"signupRole":null,"profileSetupProvider":"google"}"#
    #expect(try service.me(authorization: "Bearer \(bearer)").jsonBody.render() == observed)

    #expect(throws: AuthIdentitiesError.missingAuthorization) { try service.me(authorization: nil) }
    #expect(throws: AuthIdentitiesError.invalidToken) { try service.me(authorization: "Bearer nope") }
}

// MARK: - Profile patch

@Test func authIdentitiesPatchKeepsTheLegacyValidationOrderAndLeniency() throws {
    let (scene, userId, bearer) = makeFixture("04")
    let service = scene.identities
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
    let before = scene.analyticsId(userId: userId)
    #expect(before != nil)
    _ = try patch(#"{"shareUsageData":true}"#)
    #expect(scene.analyticsId(userId: userId) == before)
    _ = try patch(#"{"shareUsageData":false}"#)
    #expect(scene.analyticsId(userId: userId) == nil)
    _ = try patch(#"{"shareUsageData":null}"#)
    #expect(scene.analyticsId(userId: userId) == nil)
    _ = try patch(#"{"shareUsageData":true}"#)
    #expect(scene.analyticsId(userId: userId) != nil && scene.analyticsId(userId: userId) != before)
}

@Test func authIdentitiesPatchWritesDisplayNameVerbatimAndNeverDerivesItFromTheHandle() throws {
    let (scene, _, bearer) = makeFixture("12")
    let service = scene.identities
    let auth = "Bearer \(bearer)"
    func patch(_ json: String) throws -> AuthProfileUserResponse {
        try service.updateProfile(
            authorization: auth,
            try? JSONDecoder().decode(UpdateProfileRequest.self, from: Data(json.utf8))
        )
    }

    // A fresh completed row has no display name. The public body prints null;
    // it is not back-filled from `name`.
    #expect(try service.me(authorization: auth).user.displayName == nil)

    // Upstream copies a present string verbatim: no trim and no validation.
    #expect(try patch(#"{"displayName":"  Kevin  "}"#).user.displayName == "  Kevin  ")
    #expect(try service.me(authorization: auth).user.displayName == "  Kevin  ")

    // An absent key leaves the stored value alone.
    #expect(try patch(#"{"shareUsageData":true}"#).user.displayName == "  Kevin  ")

    // The empty string is a present string, so it is stored as sent.
    #expect(try patch(#"{"displayName":""}"#).user.displayName == "")

    // JSON null clears it; the published body goes back to null.
    #expect(try patch(#"{"displayName":null}"#).user.displayName == nil)
    #expect(try service.me(authorization: auth).user.displayName == nil)
}

@Test func authIdentitiesPatchWritesThePasswordBeforeLaterFieldsAreValidated() throws {
    let (scene, _, bearer) = makeFixture("05")
    let service = scene.identities
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
    let relogin = try #require(try? service.login(LoginRequest(
        email: "identity-05@slock.test", password: "longenough1"
    )))
    let freshAuth = "Bearer \(relogin.accessToken)"
    // Survey validation is later than the password write too: the second change
    // is committed even though the request answers its published 400.
    #expect(throws: AuthIdentitiesError.invalidProfile("Invalid signupRole")) {
        _ = try service.updateProfile(
            authorization: freshAuth,
            try? JSONDecoder().decode(UpdateProfileRequest.self,
                                      from: Data(#"{"currentPassword":"longenough1","newPassword":"longenough2","signupRole":"Bad"}"#.utf8))
        )
    }
    #expect(throws: AuthIdentitiesError.invalidCredentials) {
        try service.login(LoginRequest(email: "identity-05@slock.test", password: "longenough1"))
    }
    #expect((try? service.login(LoginRequest(email: "identity-05@slock.test", password: "longenough2"))) != nil)
}

// MARK: - Signup survey

@Test func authIdentitiesPatchStampsTheSignupSurveyAndPublishesIt() throws {
    let (scene, userId, bearer) = makeFixture("09")
    let service = scene.makeIdentitiesService(now: { fixedDate })
    let auth = "Bearer \(bearer)"
    func patch(_ json: String) throws -> AuthProfileUserResponse {
        try service.updateProfile(
            authorization: auth,
            try? JSONDecoder().decode(UpdateProfileRequest.self, from: Data(json.utf8))
        )
    }
    func me() throws -> AuthUserDTO {
        try service.me(authorization: auth).user
    }

    // A verified email and a completed profile do not answer the survey.
    #expect(scene.account(userId: userId)?.emailVerified == true)
    #expect(scene.account(userId: userId)?.profileSetupCompletedAt != nil)
    #expect(try me().signupRole == nil)
    #expect(try me().signupSurveyCompletedAt == nil)

    // The referral half does not stamp the survey either.
    _ = try patch(#"{"referralSource":"search"}"#)
    #expect(try me().signupSurveyCompletedAt == nil)

    // The role alone is legal; it stamps the one request time and is published
    // on both the PATCH reply and the following `me`.
    let recorded = try patch(#"{"signupRole":"engineering_leader"}"#)
    #expect(recorded.user.signupRole == "engineering_leader")
    #expect(recorded.user.signupSurveyCompletedAt == "2023-11-14T22:13:20.000Z")
    #expect(recorded.user.referralSource == "search")
    #expect(try me().signupRole == "engineering_leader")
    #expect(try me().signupSurveyCompletedAt == "2023-11-14T22:13:20.000Z")

    // The exact upstream id set is accepted as-is.
    for role in [
        "software_engineer", "engineering_leader", "founder", "product", "design",
        "data_ml", "devops_it", "student", "other",
    ] {
        #expect(try patch("{\"signupRole\":\"\(role)\"}").user.signupRole == role)
    }

    // An absent key leaves both facts alone, including on a later request with a
    // different clock. Explicit null is legal and stamps the new request time.
    let later = scene.makeIdentitiesService(now: { fixedDate.addingTimeInterval(120) })
    let untouched = try later.updateProfile(
        authorization: auth,
        try? JSONDecoder().decode(UpdateProfileRequest.self, from: Data(#"{"referralSourceSkipped":true}"#.utf8))
    )
    #expect(untouched.user.signupRole == "other")
    #expect(untouched.user.signupSurveyCompletedAt == "2023-11-14T22:13:20.000Z")
    let cleared = try later.updateProfile(
        authorization: auth,
        try? JSONDecoder().decode(UpdateProfileRequest.self, from: Data(#"{"signupRole":null}"#.utf8))
    )
    #expect(cleared.user.signupRole == nil)
    #expect(cleared.user.signupSurveyCompletedAt == "2023-11-14T22:15:20.000Z")
}

@Test func authIdentitiesPatchRejectsInvalidSignupRolesBeforeAnySurveyOrReferralWrite() throws {
    let (scene, userId, bearer) = makeFixture("10")
    let service = scene.makeIdentitiesService(now: { fixedDate })
    let auth = "Bearer \(bearer)"
    func patch(_ json: String) throws -> AuthProfileUserResponse {
        try service.updateProfile(
            authorization: auth,
            try? JSONDecoder().decode(UpdateProfileRequest.self, from: Data(json.utf8))
        )
    }

    #expect(render(.invalidProfile("Invalid signupRole")) == #"{"error":"Invalid signupRole"}"#)
    for body in [
        #"{"signupRole":"Software_Engineer"}"#,
        #"{"signupRole":" software_engineer"}"#,
        #"{"signupRole":"software_engineer "}"#,
        #"{"signupRole":"student_or_learner"}"#,
        #"{"signupRole":""}"#,
        #"{"signupRole":1}"#,
        #"{"signupRole":true}"#,
        #"{"signupRole":{}}"#,
        #"{"signupRole":[]}"#,
    ] {
        #expect(throws: AuthIdentitiesError.invalidProfile("Invalid signupRole"), Comment(rawValue: body)) {
            try patch(body)
        }
    }

    // A rejected role leaves the valid referral in the same request unwritten.
    #expect(throws: AuthIdentitiesError.invalidProfile("Invalid signupRole")) {
        try patch(#"{"signupRole":"intern","referralSource":"search"}"#)
    }
    var account = try #require(scene.account(userId: userId))
    #expect(account.referralSource == nil)
    #expect(account.referralSourceSkippedAt == nil)
    #expect(account.signupRole == nil)
    #expect(account.signupSurveyCompletedAt == nil)

    // A rejected referral leaves the valid role in the same request unwritten.
    #expect(throws: AuthIdentitiesError.invalidProfile("Invalid referralSource")) {
        try patch(#"{"signupRole":"founder","referralSource":"wechat"}"#)
    }
    account = try #require(scene.account(userId: userId))
    #expect(account.referralSource == nil)
    #expect(account.signupRole == nil)
    #expect(account.signupSurveyCompletedAt == nil)

    // The API does not require the referral and the role together.
    let roleOnly = try patch(#"{"signupRole":"founder"}"#)
    #expect(roleOnly.user.signupRole == "founder")
    #expect(roleOnly.user.referralSource == nil)
    #expect(roleOnly.user.signupSurveyCompletedAt == "2023-11-14T22:13:20.000Z")
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
    let (scene, userId, bearer) = makeFixture("06")
    let service = scene.identities
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
    #expect(scene.sessionUserId(authorization: "Bearer \(completed.accessToken)") == userId)
    #expect(throws: AuthIdentitiesError.codeConsumed) {
        try service.appLoginComplete(AppLoginCompleteRequest(code: code, codeVerifier: pair.verifier))
    }
}

@Test func appLoginExpiredRequestAnswersTheRedirectAndNothingElseChanges() throws {
    let (scene, _, bearer) = makeFixture("07")
    let service = scene.identities
    let requestId = try startedRequest(service, challenge: pkcePair().challenge)
    scene.expireAppLoginRequestForTesting(requestId: requestId)
    #expect(throws: AuthIdentitiesError.requestExpired(
        redirectUrl: "raft://login/callback?requestId=\(requestId)&error=expired"
    )) { try service.appLoginDeny(authorization: "Bearer \(bearer)", requestId: requestId) }
    #expect(try service.appLoginDescribe(authorization: "Bearer \(bearer)", requestId: requestId).status == "pending")
}

@Test func appLoginStartValidatesInTheLegacyOrder() {
    let (scene, _, _) = makeFixture("08")
    let service = scene.identities
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
    let (scene, _, bearer) = makeFixture("09")
    let service = scene.identities
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
    let (scene, userId, bearer) = makeFixture("10")
    let service = scene.identities
    let pair = pkcePair()
    let requestId = try startedRequest(service, challenge: pair.challenge)
    let redirect = try service.appLoginApprove(authorization: "Bearer \(bearer)", requestId: requestId).redirectUrl
    let code = String(redirect.split(separator: "=").last ?? "")
    let sessionsBefore = scene.sessionCount(for: userId)
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
    #expect(scene.sessionCount(for: userId) == sessionsBefore + 1)
}

// MARK: - Identity and login races

@Test func concurrentUnlinksOfTheLastTwoIdentitiesLeaveOne() async throws {
    let (scene, userId, bearer) = makeFixture("11", passwordEstablished: false)
    scene.addAuthIdentityForTesting(userId: userId, provider: "google", providerEmail: "g@example.com")
    scene.addAuthIdentityForTesting(userId: userId, provider: "github", providerEmail: "h@example.com")
    let service = scene.identities
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
    #expect(scene.authIdentityCount(userId: userId) == 1)
}

@Test func pendingLinkIsSpentOnceByConcurrentLoginsAndLinksTheIdentity() async throws {
    let (scene, userId, _) = makeFixture("12")
    scene.seedPendingSocialLink(
        token: "pending-token",
        provider: "github",
        providerUserId: "gh-1",
        email: "identity-12@slock.test"
    )
    let service = scene.identities

    #expect(throws: AuthIdentitiesError.invalidCredentials) {
        try service.login(LoginRequest(email: "other@slock.test", password: "x", pendingLinkToken: "pending-token"))
    }
    #expect(throws: AuthIdentitiesError.invalidCredentials) {
        try service.login(LoginRequest(email: "identity-12@slock.test", password: "x", pendingLinkToken: "unknown"))
    }
    #expect(throws: AuthIdentitiesError.pendingLinkExpired) {
        try service.login(LoginRequest(email: "identity-12@slock.test", password: "password123", pendingLinkToken: "unknown"))
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
    #expect(scene.linkedProviderUserIds(userId: userId, provider: "github") == ["gh-1"])
}

@Test func integrationSettingsClientsRequiresASessionAndServerMembership() throws {
    let (scene, userId, bearer) = makeFixture("13")
    let service = scene.identities
    let serverId = "33333333-3333-4333-8333-333333339013"
    scene.addOwnedServer(id: serverId, slug: "identity-13", name: "Identity", ownerId: userId)
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
        == #"[{"id":"1","clientId":"c","name":"n","appType":"t","description":null,"homepageUrl":"https://x.test","publishStatus":"draft","logoUrl":null}]"#)
}

@Test func oauthSessionIgnoresRevokedFamiliesLikeTheRetiredLookup() {
    let (scene, userId, bearer) = makeFixture("14")
    let service = scene.authorization
    guard case .missing = service.beginSession(authorization: nil) else { Issue.record("expected missing"); return }
    guard case .invalid = service.beginSession(authorization: "Bearer nope") else { Issue.record("expected invalid"); return }
    guard case .invalid = service.beginSession(authorization: "Bearer ") else { Issue.record("raw empty tail must be invalid"); return }
    guard case .invalid = service.beginSession(authorization: "Bearer \(bearer) ") else { Issue.record("raw trailing SP must not trim"); return }
    guard case .invalid = service.beginSession(authorization: "Bearer  \(bearer)") else { Issue.record("raw leading token SP must not trim"); return }
    scene.revokeSessionFamilies(userId: userId)
    guard case .user(let human) = service.beginSession(authorization: "Bearer \(bearer)") else {
        Issue.record("expected user")
        return
    }
    #expect(human.id == userId)
    #expect(human.emailVerified)
}

@Test func oauthAuthorizationFromMandatoryComposerSharesProfileSnapshotAndOAuthTransactions() throws {
    let profiles = AuthProfileStore()
    let notifications = NotificationsStore()
    let productEvents = ProductEventStore()
    let inboxFacts = InboxFactStore()
    let threadFollows = ThreadFollowStore()
    let messages = MessagesAndThreadsStore()
    let agents = AgentsRuntimeStore()
    let tasks = TasksAndRemindersStore()
    let machines = MachinesAndComputersStore()
    let channels = ServersAndChannelsStore()
    let cards = ManagedMCPAndCardsStore()
    let feedback = FeedbackStore()
    let oauth = OAuthLedger()
    let services = composeServices(
        profiles: profiles, notifications: notifications, productEvents: productEvents,
        inboxFacts: inboxFacts, threadFollows: threadFollows, messages: messages,
        agents: agents, tasks: tasks, machines: machines, channels: channels,
        cards: cards, feedback: feedback, oauth: oauth
    )
    let authorization = services.identity.authorization
    let flows = services.identity.oauthFlows
    let ownerId = "11111111-1111-4111-8111-111111111646"
    let serverId = "33333333-3333-4333-8333-333333333672"
    let email = "composed-protocol-646@test.invalid"
    let passwordHash = AuthFixturePassword.encoded("password123")
    profiles.state.withLock { owned in
        owned.accountSurface.accounts[email] = Account(
            id: ownerId, email: email, passwordHash: passwordHash,
            displayLanguage: nil, name: "Before snapshot", profileSetupSuggestedHandle: nil
        )
    }
    let bearer = profiles.openSession(userId: ownerId).accessToken
    let snapshot = authorization.beginSession(authorization: "Bearer \(bearer)")
    guard case .user(let human) = snapshot else { Issue.record("must read the supplied profile owner"); return }
    #expect(human.id == ownerId && !human.emailVerified)
    // A real profile borrow after beginSession proves the lock is released;
    // signing later must still use the captured five-field human value.
    profiles.state.withLock { $0.accountSurface.accounts[email]?.name = "After snapshot" }
    oauth.addOwnedServer(id: serverId, slug: "composed-protocol-646", name: "Composed Protocol", ownerId: ownerId)
    let app = try oauth.createClient(serverId: serverId, createdByUserId: ownerId,
        name: "Composed Protocol App", clientId: "composed-protocol-client-646")
    flows.configureDeployment(.init(serverURL: "https://before.protocol.test/base"))
    let context = authorization.tokenContext()
    flows.configureDeployment(.init(serverURL: "https://after.protocol.test/base"))
    #expect(authorization.tokenContext().issuer == "https://after.protocol.test")
    let issued = try authorization.issueHumanAuthorization(session: snapshot,
        body: "{\"clientId\":\"\(app.clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\"openid\",\"profile\"],\"oidc\":true,\"nonce\":\"composed-nonce\"}")
    #expect(issued.serverId == serverId)
    #expect(issued.code.hasPrefix("raft_oidc_"))
    // Redemption must read this live role and the independently live key from
    // the exact supplied OAuth owner, after the original request was created.
    oauth.addMember(serverId: serverId, userId: ownerId, role: "admin")
    flows.configureSigningSecret("composed-protocol-live-signing-key")
    let body = "{\"clientId\":\"\(app.clientId)\",\"clientSecret\":\"\(app.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(issued.code)\"}"
    let token = try authorization.exchangeToken(authorization: nil, body: body, context: context)
    let published = try #require(JSONSerialization.jsonObject(with: Data(token.jsonBody.render().utf8)) as? [String: Any])
    let jwt = try #require(published["id_token"] as? String)
    let parts = jwt.split(separator: ".").map(String.init)
    try #require(parts.count == 3)
    func decode(_ encoded: String) throws -> Data {
        var value = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return try #require(Data(base64Encoded: value))
    }
    let claims = try #require(JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any])
    #expect(claims["iss"] as? String == "https://before.protocol.test")
    #expect(claims["sub"] as? String == ownerId)
    #expect(claims["name"] as? String == "Before snapshot")
    #expect(claims["server_role"] as? String == "admin")
    #expect(claims["nonce"] as? String == "composed-nonce")
    let jwks = try services.identity.issuerMetadata.jwks()
    let key = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + decode(jwks.x) + decode(jwks.y))
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
    #expect(key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    #expect(throws: OAuthLedgerError(.invalidGrant(.requestInvalidOrExpired))) {
        try services.identity.authorization.exchangeToken(authorization: nil, body: body, context: context)
    }
}
