import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// `AuthCoreService` owns the session core. These tests lock the exact bytes
/// each DTO / `DomainError` renders and the one-critical-section contract of
/// every store write the service depends on.

private let userId = "11111111-1111-4111-8111-000003100001"

private func fixture() -> (scene: AuthServicesUnitFixture, service: AuthCoreService) {
    let scene = AuthServicesUnitFixture()
    scene.setAppURL("https://app.raft.test/")
    scene.addAccount(id: userId, email: "core@slock.test", password: "password123")
    return (scene, scene.core)
}

private func body(_ error: any DomainError) -> String { error.publishedErrorBody.render() }

private func thrown<T>(_ call: () throws -> T) -> AuthCoreError? {
    do { _ = try call() } catch let error as AuthCoreError { return error } catch { return nil }
    return nil
}

private func successes<T: Sendable>(
    _ count: Int,
    _ work: @escaping @Sendable (Int) -> T?
) async -> [T] {
    await withTaskGroup(of: T?.self) { group in
        for index in 0..<count { group.addTask { work(index) } }
        var results: [T] = []
        for await result in group { if let result { results.append(result) } }
        return results
    }
}

// MARK: - Bytes

@Test func authCoreDeviceFlowRendersTheLegacyBytes() throws {
    let (scene, service) = fixture()
    let bearer = scene.mintAccessTokenForTesting(userId: userId)

    let issued = try service.authorizeDevice(DeviceAuthorizeRequest(clientName: .string("cli")))
    let rendered = issued.jsonBody.render()
    #expect(rendered.hasPrefix("{\"deviceCode\":\"dvc_"))
    #expect(rendered.contains("\"verificationUri\":\"https:\\/\\/app.raft.test\\/login\\/device\"")
        || rendered.contains("\"verificationUri\":\"https://app.raft.test/login/device\""))
    #expect(rendered.hasSuffix(",\"expiresIn\":600,\"interval\":5}"))

    #expect(thrown { try service.authorizeDevice(DeviceAuthorizeRequest(clientName: .invalidType)) }
        == .clientNameInvalid)
    #expect(body(AuthCoreError.clientNameInvalid)
        == #"{"error":"clientName must be a string up to 200 chars","code":"client_name_invalid"}"#)
    #expect(thrown {
        try service.authorizeDevice(DeviceAuthorizeRequest(clientName: .string(String(repeating: "x", count: 201))))
    } == .clientNameInvalid)

    #expect(thrown { try service.pollDeviceToken(DeviceTokenRequest(deviceCode: issued.deviceCode)) }
        == .deviceNotReady(code: "authorization_pending", status: 400))
    #expect(body(AuthCoreError.deviceNotReady(code: "authorization_pending", status: 400))
        == #"{"error":"Device authorization not ready","code":"authorization_pending"}"#)

    #expect(thrown { try service.approveDevice(DeviceApproveRequest(userCode: issued.userCode), authorization: nil) }
        == .missingAuthorization)
    #expect(body(AuthCoreError.missingAuthorization)
        == #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#)
    #expect(thrown {
        try service.approveDevice(DeviceApproveRequest(userCode: issued.userCode), authorization: "Bearer nope")
    } == .invalidToken)
    #expect(thrown { try service.approveDevice(DeviceApproveRequest(userCode: "  "), authorization: "Bearer \(bearer)") }
        == .userCodeRequired)
    #expect(body(AuthCoreError.userCodeRequired) == #"{"error":"userCode is required","code":"user_code_required"}"#)

    let decision = try service.approveDevice(
        DeviceApproveRequest(userCode: " \(issued.userCode.lowercased()) "),
        authorization: "Bearer \(bearer)"
    )
    #expect(decision.jsonBody.render() == #"{"ok":true,"action":"approved"}"#)
    #expect(thrown {
        try service.approveDevice(DeviceApproveRequest(userCode: issued.userCode), authorization: "Bearer \(bearer)")
    } == .deviceUpdateFailed(code: "already_resolved", status: 409))
    #expect(body(AuthCoreError.deviceUpdateFailed(code: "already_resolved", status: 409))
        == #"{"error":"Device authorization could not be updated","code":"already_resolved"}"#)

    let token = try service.pollDeviceToken(DeviceTokenRequest(deviceCode: issued.deviceCode))
    #expect(token.jsonBody.render()
        == "{\"accessToken\":\"\(token.accessToken)\",\"refreshToken\":\"\(token.refreshToken)\",\"userId\":\"\(userId)\"}")
    #expect(thrown { try service.pollDeviceToken(DeviceTokenRequest(deviceCode: issued.deviceCode)) }
        == .deviceNotReady(code: "device_code_consumed", status: 410))
    #expect(DeviceDecisionResponse(approved: false).jsonBody.render() == #"{"ok":true,"action":"denied"}"#)
}

@Test func authCoreDeviceAuthorizeStoresTheGrantBeforeTheUrlCheck() {
    let (scene, service) = fixture()
    scene.setAppURL("  ")
    #expect(thrown { try service.authorizeDevice(DeviceAuthorizeRequest()) } == .deviceLoginURLUnavailable)
    #expect(scene.deviceGrantCount == 1)
    #expect(body(AuthCoreError.deviceLoginURLUnavailable)
        == #"{"error":"Device login URL is not configured","code":"DEVICE_LOGIN_URL_UNAVAILABLE"}"#)
    scene.setDeviceLoginGate("off")
    #expect(thrown { try service.authorizeDevice(DeviceAuthorizeRequest()) } == .deviceLoginDisabled)
    #expect(body(AuthCoreError.deviceLoginDisabled)
        == #"{"error":"Device login is not enabled","code":"device_login_disabled"}"#)
}

@Test func authCoreRefreshAndLogoutRenderTheLegacyBytes() throws {
    let (scene, service) = fixture()
    let session = scene.openSession(userId: userId)

    #expect(thrown { try service.refresh(RefreshTokenRequest(), attemptHeader: nil, installationHeader: nil) }
        == .refreshTokenRequired)
    #expect(body(AuthCoreError.refreshTokenRequired) == #"{"error":"Refresh token is required"}"#)
    #expect(thrown {
        try service.refresh(
            RefreshTokenRequest(refreshToken: session.refreshToken),
            attemptHeader: "arf_0123456789abcdef",
            installationHeader: "bad"
        )
    } == .invalidRefreshBinding)
    #expect(body(AuthCoreError.invalidRefreshBinding) == #"{"error":"Invalid refresh replay binding"}"#)

    let rotated = try service.refresh(
        RefreshTokenRequest(refreshToken: session.refreshToken),
        attemptHeader: nil,
        installationHeader: nil
    )
    #expect(rotated.jsonBody.render()
        == "{\"accessToken\":\"\(rotated.accessToken)\",\"refreshToken\":\"\(rotated.refreshToken)\"}")
    #expect(thrown {
        try service.refresh(
            RefreshTokenRequest(refreshToken: session.refreshToken),
            attemptHeader: nil,
            installationHeader: nil
        )
    } == .invalidRefreshToken)
    #expect(body(AuthCoreError.invalidRefreshToken) == #"{"error":"Invalid or expired refresh token"}"#)

    // Logout of the predecessor revokes the family the successor lives in.
    #expect(service.logout(RefreshTokenRequest(refreshToken: session.refreshToken)) == OkResponse())
    #expect(thrown {
        try service.refresh(
            RefreshTokenRequest(refreshToken: rotated.refreshToken),
            attemptHeader: nil,
            installationHeader: nil
        )
    } == .invalidRefreshToken)
    #expect(service.logout(RefreshTokenRequest()) == OkResponse())
}

@Test func authCoreDurableRefreshReplaysTheSameSuccessorForOneBinding() throws {
    let (scene, service) = fixture()
    let session = scene.openSession(userId: userId)
    let attempt = "arf_0123456789abcdef"
    let installation = "ari_0123456789abcdef0123456789abcdef"
    let first = try service.refresh(
        RefreshTokenRequest(refreshToken: session.refreshToken),
        attemptHeader: attempt,
        installationHeader: installation
    )
    let replay = try service.refresh(
        RefreshTokenRequest(refreshToken: session.refreshToken),
        attemptHeader: attempt,
        installationHeader: installation
    )
    #expect(replay.refreshToken == first.refreshToken)
    #expect(replay.accessToken != first.accessToken)
    #expect(thrown {
        try service.refresh(
            RefreshTokenRequest(refreshToken: session.refreshToken),
            attemptHeader: "arf_ffffffffffffffff",
            installationHeader: installation
        )
    } == .invalidRefreshToken)
}

@Test func authCoreRegisterRendersTheLegacyBytes() throws {
    let (scene, service) = fixture()
    #expect(thrown { try service.register(nil, userAgent: nil, acceptLanguage: nil) }
        == .registerBodyInvalid([
            AuthRequestIssue(path: "email", message: "Invalid input: expected string, received undefined"),
            AuthRequestIssue(path: "password", message: "Invalid input: expected string, received undefined"),
        ]))
    #expect(body(AuthCoreError.registerBodyInvalid([
        AuthRequestIssue(path: "email", message: "Invalid input: expected string, received undefined"),
        AuthRequestIssue(path: "password", message: "Invalid input: expected string, received number"),
    ])) == #"{"error":"Invalid email registration body","code":"email_register_body_invalid","issues":[{"path":"email","message":"Invalid input: expected string, received undefined"},{"path":"password","message":"Invalid input: expected string, received number"}]}"#)

    func request(
        acceptTerms: Bool = true,
        terms: String? = AuthLegalPolicy.termsVersion,
        password: String = "password123",
        name: String? = "Newbie"
    ) -> RegisterRequest {
        RegisterRequest(
            email: "New@Slock.test",
            password: password,
            name: name,
            acceptTerms: acceptTerms,
            termsVersion: terms,
            privacyVersion: AuthLegalPolicy.privacyVersion
        )
    }
    #expect(thrown { try service.register(request(acceptTerms: false), userAgent: nil, acceptLanguage: nil) }
        == .legalAcceptanceRequired)
    #expect(thrown { try service.register(request(terms: "old"), userAgent: nil, acceptLanguage: nil) }
        == .termsChanged)
    // Pinned `routes/auth.ts:659-661`: the eight-character floor comes after the
    // name checks and before account creation.
    #expect(thrown { try service.register(request(password: "short"), userAgent: nil, acceptLanguage: nil) }
        == .passwordTooShort)
    #expect(body(AuthCoreError.passwordTooShort) == #"{"error":"Password must be at least 8 characters"}"#)
    #expect(thrown { try service.register(request(password: "short", name: "1badname"), userAgent: nil, acceptLanguage: nil) }
        == .nameInvalid("Name must start with a letter and can only contain letters, numbers, hyphens, and underscores"))
    #expect(!scene.hasAccount(email: "new@slock.test"))
    let legal = "{\"termsVersion\":\"\(AuthLegalPolicy.termsVersion)\",\"privacyVersion\":\"\(AuthLegalPolicy.privacyVersion)\",\"termsUrl\":\"\(AuthLegalPolicy.termsURL)\",\"privacyUrl\":\"\(AuthLegalPolicy.privacyURL)\"}"
    #expect(body(AuthCoreError.legalAcceptanceRequired) == "{\"error\":\"LEGAL_ACCEPTANCE_REQUIRED\",\"legal\":\(legal)}")
    #expect(body(AuthCoreError.termsChanged) == "{\"error\":\"TERMS_CHANGED\",\"legal\":\(legal)}")

    let created = try service.register(request(), userAgent: "ua", acceptLanguage: "en")
    let rendered = created.jsonBody.render()
    let gravatar = AuthTokenCodec.sha256("new@slock.test")
    let userJSON = created.user.jsonBody.render()
    #expect(userJSON.hasPrefix("{\"id\":\"\(created.id)\",\"email\":\"new@slock.test\",\"gravatarHash\":\"\(gravatar)\",\"name\":\"pending_"))
    #expect(userJSON.contains("\",\"displayName\":null,\"description\":null,\"avatarUrl\":null,\"emailVerified\":false,\"preferredLanguage\":null,\"displayLanguage\":null,\"preferredTimezone\":null,\"firstObservedTimezone\":null,\"firstObservedTimezoneAt\":null,\"lastObservedTimezone\":null,\"lastObservedTimezoneAt\":null,\"preferredTranslationMode\":\"off\",\"autoTranslationEnabled\":false,\"preferredTranslationDisplay\":\"translated\","))
    #expect(userJSON.hasSuffix(",\"profileSetupCompletedAt\":null,\"profileSetupSuggestedHandle\":\"newbie\",\"signupSurveyCompletedAt\":null,\"signupRole\":null,\"profileSetupProvider\":null}"))
    #expect(rendered == "{\"user\":\(userJSON),\"accessToken\":\"\(created.accessToken)\",\"refreshToken\":\"\(created.refreshToken)\"}")
    #expect(scene.legalAcceptance(userId: created.id)?.source == "signup")
    #expect(scene.emailVerificationRecordCount(userId: created.id) == 1)
    #expect(thrown { try service.register(request(), userAgent: nil, acceptLanguage: nil) }
        == .emailAlreadyRegistered)
    #expect(body(AuthCoreError.emailAlreadyRegistered) == #"{"error":"Email already registered"}"#)
}

/// Pinned `routes/auth.ts:102` is a zod 4.3.6 passthrough object: the schema
/// names the received JSON type, runs the string-length checks on arrays too,
/// and ignores unknown members.
@Test func authCoreRegisterSchemaIssuesUseThePinnedZodMessages() throws {
    let (_, service) = fixture()
    func decode(_ json: String) -> RegisterRequest? {
        try? JSONDecoder().decode(RegisterRequest.self, from: Data(json.utf8))
    }
    func issues(_ json: String) -> [AuthRequestIssue]? {
        guard let body = decode(json) else { return nil }
        return thrown { try service.register(body, userAgent: nil, acceptLanguage: nil) }.flatMap {
            if case .registerBodyInvalid(let issues) = $0 { return issues }
            return nil
        }
    }

    #expect(issues("[1]") == [
        AuthRequestIssue(path: "", message: "Invalid input: expected object, received array"),
    ])
    #expect(issues(#"{"email":[]}"#) == [
        AuthRequestIssue(path: "email", message: "Invalid input: expected string, received array"),
        AuthRequestIssue(path: "email", message: "Too small: expected array to have >=1 items"),
        AuthRequestIssue(path: "password", message: "Invalid input: expected string, received undefined"),
    ])
    #expect(issues(#"{"email":true,"password":2,"name":[],"stagingSelfAccountCapability":[]}"#) == [
        AuthRequestIssue(path: "email", message: "Invalid input: expected string, received boolean"),
        AuthRequestIssue(path: "password", message: "Invalid input: expected string, received number"),
        AuthRequestIssue(path: "name", message: "Invalid input: expected string, received array"),
        AuthRequestIssue(path: "name", message: "Too small: expected array to have >=1 items"),
        AuthRequestIssue(path: "stagingSelfAccountCapability", message: "Invalid input: expected string, received array"),
        AuthRequestIssue(path: "stagingSelfAccountCapability", message: "Too small: expected array to have >=32 items"),
    ])
    #expect(issues(#"{"email":"a@b.test","password":"password123","stagingSelfAccountCapability":"short"}"#) == [
        AuthRequestIssue(
            path: "stagingSelfAccountCapability",
            message: "Too small: expected string to have >=32 characters"
        ),
    ])
    #expect(issues(#"{"email":"a@b.test","password":"password123","stagingSelfAccountCapability":"\#(String(repeating: "x", count: 257))"}"#) == [
        AuthRequestIssue(
            path: "stagingSelfAccountCapability",
            message: "Too big: expected string to have <=256 characters"
        ),
    ])
    // `.passthrough()` ignores an unknown member, so the short password is the
    // next refusal.
    #expect(thrown { try service.register(decode(#"{"email":"x@y.test","password":"short","unknown":1}"#),
                                         userAgent: nil, acceptLanguage: nil) } == .passwordTooShort)
}

@Test func authCoreSocialCompletionRendersTheLegacyBytes() throws {
    let (scene, service) = fixture()
    scene.addSocialCompletion(provider: "google", code: "c1", email: "social@slock.test", returnTo: "/x")
    let request = SocialCompleteRequest(
        code: "c1",
        acceptTerms: true,
        termsVersion: AuthLegalPolicy.termsVersion,
        privacyVersion: AuthLegalPolicy.privacyVersion
    )
    #expect(thrown { try service.completeSocial(provider: "nope", body: request, userAgent: nil, acceptLanguage: nil, authorization: nil) }
        == .notFound)
    #expect(thrown { try service.completeSocial(provider: "google", body: SocialCompleteRequest(), userAgent: nil, acceptLanguage: nil, authorization: nil) }
        == .socialCompletionCodeRequired)
    #expect(thrown { try service.completeSocial(provider: "google", body: SocialCompleteRequest(code: "zz"), userAgent: nil, acceptLanguage: nil, authorization: nil) }
        == .socialCompletionInvalid)
    #expect(thrown { try service.completeSocial(provider: "google", body: SocialCompleteRequest(code: "c1"), userAgent: nil, acceptLanguage: nil, authorization: nil) }
        == .legalAcceptanceRequired)
    let done = try service.completeSocial(provider: "google", body: request, userAgent: nil, acceptLanguage: nil, authorization: nil)
    guard case .session(_, _, _, let access, let refresh, nil) = done else {
        Issue.record("expected a session")
        return
    }
    #expect(done.jsonBody.render()
        == "{\"provider\":\"google\",\"mode\":\"login\",\"returnTo\":\"\\/x\",\"accessToken\":\"\(access)\",\"refreshToken\":\"\(refresh)\"}"
        || done.jsonBody.render()
        == "{\"provider\":\"google\",\"mode\":\"login\",\"returnTo\":\"/x\",\"accessToken\":\"\(access)\",\"refreshToken\":\"\(refresh)\"}")
    // The code is spent.
    #expect(thrown { try service.completeSocial(provider: "google", body: request, userAgent: nil, acceptLanguage: nil, authorization: nil) }
        == .socialCompletionInvalid)

    #expect(body(AuthCoreError.linkAuthRequired)
        == #"{"code":"auth_required","error":"Authentication is required to link an account"}"#)
    #expect(body(AuthCoreError.linkUserMismatch)
        == #"{"code":"link_user_mismatch","error":"Social auth link does not match the authenticated user"}"#)
    #expect(body(AuthCoreError.pendingLinkExpired)
        == #"{"error":"This sign-in link expired. Sign in again to connect the account.","code":"pending_link_expired"}"#)
    #expect(body(AuthCoreError.socialEmailExists(provider: "github"))
        == #"{"error":"An account with this email already exists. Sign in with email and password first, then connect github in Settings."}"#)
    #expect(body(AuthCoreError.accountLinkRequired(AccountLinkRequiredBody(
        pendingLinkToken: "t", provider: "google", email: "a@b.c", expiresAt: "2026-01-01T00:00:00Z",
        hasPassword: true, providers: ["github"], returnTo: "/"
    ))) == #"{"code":"account_link_required","pendingLinkToken":"t","provider":"google","email":"a@b.c","expiresAt":"2026-01-01T00:00:00Z","signInMethods":{"password":true,"providers":["github"]},"returnTo":"/"}"#)
}

@Test func authCoreRetirementRendersTheLegacyBytes() {
    #expect(StagingRetirementResponse(
        userId: "u", actorUserId: "a", environment: "staging", terminalState: "retired", sessionsRevoked: 2
    ).jsonBody.render()
        == #"{"receipt":{"userId":"u","actorUserId":"a","environment":"staging","terminalState":"retired","sessionsRevoked":2}}"#)
    #expect(body(AuthCoreError.retirementReceiptUnavailable) == #"{"error":"Retirement receipt unavailable"}"#)
    #expect(AuthCoreError.retirementReceiptUnavailable.status == 500)
}

// MARK: - One critical section per write

@Test func authCoreConcurrentDeviceDecisionsResolveTheGrantOnce() async throws {
    let (scene, service) = fixture()
    let bearer = scene.mintAccessTokenForTesting(userId: userId)
    let issued = try service.authorizeDevice(DeviceAuthorizeRequest())
    let decided = await successes(24) { index in
        try? service.approveDevice(
            DeviceApproveRequest(userCode: issued.userCode, approve: index % 2 == 0),
            authorization: "Bearer \(bearer)"
        )
    }
    #expect(decided.count == 1)
}

@Test func authCoreConcurrentDevicePollsIssueExactlyOneSession() async throws {
    let (scene, service) = fixture()
    let bearer = scene.mintAccessTokenForTesting(userId: userId)
    let issued = try service.authorizeDevice(DeviceAuthorizeRequest())
    _ = try service.approveDevice(DeviceApproveRequest(userCode: issued.userCode), authorization: "Bearer \(bearer)")
    let sessionsBefore = scene.sessionCount(for: userId)
    let tokens = await successes(24) { _ in
        try? service.pollDeviceToken(DeviceTokenRequest(deviceCode: issued.deviceCode))
    }
    #expect(tokens.count == 1)
    #expect(scene.sessionCount(for: userId) == sessionsBefore + 1)
}

@Test func authCoreConcurrentRefreshRotatesATokenOnce() async throws {
    let (scene, service) = fixture()
    let session = scene.openSession(userId: userId)
    let rotated = await successes(24) { _ in
        try? service.refresh(
            RefreshTokenRequest(refreshToken: session.refreshToken),
            attemptHeader: nil,
            installationHeader: nil
        )
    }
    #expect(rotated.count == 1)
    #expect(scene.sessionCount(for: userId) == 1)
}

@Test func authCoreConcurrentRegistrationsCreateOneAccount() async throws {
    let (scene, service) = fixture()
    let request = RegisterRequest(
        email: "race@slock.test",
        password: "password123",
        acceptTerms: true,
        termsVersion: AuthLegalPolicy.termsVersion,
        privacyVersion: AuthLegalPolicy.privacyVersion
    )
    let created = await successes(24) { _ in
        try? service.register(request, userAgent: nil, acceptLanguage: nil)
    }
    #expect(created.count == 1)
    #expect(created.first.map { scene.emailVerificationRecordCount(userId: $0.id) } == 1)
    #expect(scene.legalAcceptanceCount == 1)
}

@Test func authCoreConcurrentSocialCompletionsSpendACodeOnce() async throws {
    let (scene, service) = fixture()
    scene.addSocialCompletion(provider: "google", code: "race", email: "race-social@slock.test")
    let request = SocialCompleteRequest(
        code: "race",
        acceptTerms: true,
        termsVersion: AuthLegalPolicy.termsVersion,
        privacyVersion: AuthLegalPolicy.privacyVersion
    )
    let done = await successes(24) { _ in
        try? service.completeSocial(
            provider: "google", body: request, userAgent: nil, acceptLanguage: nil, authorization: nil
        )
    }
    #expect(done.count == 1)
    #expect(scene.legalAcceptanceCount == 1)
}

@Test func authCoreConcurrentRetirementsWriteOneReceipt() async throws {
    let (scene, _) = fixture()
    scene.setReleaseBranch("staging")
    let capability = String(repeating: "c", count: 40)
    scene.prepareStagingRetirementAccount(
        currentEmail: "core@slock.test", retirementEmail: "core@mail.build", capability: capability
    )
    _ = scene.openSession(userId: userId)
    let outcomes = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<24 {
            group.addTask {
                if case .retired = scene.retireStagingAccount(
                    userId: userId,
                    actorUserId: userId,
                    capabilityHash: AuthTokenCodec.sha256(capability),
                    now: Date()
                ) { return true }
                return false
            }
        }
        var retired = 0
        for await first in group where first { retired += 1 }
        return retired
    }
    #expect(outcomes == 1)
    #expect(scene.retirementReceiptCount == 1)
}
