import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// `AuthCoreService` owns the session core. These tests lock the exact bytes
/// each DTO / `DomainError` renders and the one-critical-section contract of
/// every store write the service depends on.

private let userId = "11111111-1111-4111-8111-000003100001"

private func fixture() -> (directory: EmailLoginDirectory, service: AuthCoreService) {
    let directory = EmailLoginDirectory()
    directory.appURL = "https://app.raft.test/"
    directory.addAccount(id: userId, email: "core@slock.test", password: "password123")
    return (directory, directory.authCore)
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
    let (directory, service) = fixture()
    let bearer = directory.mintAccessTokenForTesting(userId: userId)

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
    let (directory, service) = fixture()
    directory.appURL = "  "
    #expect(thrown { try service.authorizeDevice(DeviceAuthorizeRequest()) } == .deviceLoginURLUnavailable)
    #expect(directory.authProfileStore.accountState.deviceGrants.count == 1)
    #expect(body(AuthCoreError.deviceLoginURLUnavailable)
        == #"{"error":"Device login URL is not configured","code":"DEVICE_LOGIN_URL_UNAVAILABLE"}"#)
    directory.deviceLoginGate = "off"
    #expect(thrown { try service.authorizeDevice(DeviceAuthorizeRequest()) } == .deviceLoginDisabled)
    #expect(body(AuthCoreError.deviceLoginDisabled)
        == #"{"error":"Device login is not enabled","code":"device_login_disabled"}"#)
}

@Test func authCoreRefreshAndLogoutRenderTheLegacyBytes() throws {
    let (directory, service) = fixture()
    let session = directory.authProfileStore.openSession(userId: userId)

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
    let (directory, service) = fixture()
    let session = directory.authProfileStore.openSession(userId: userId)
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
    let (directory, service) = fixture()
    #expect(thrown { try service.register(nil, userAgent: nil, acceptLanguage: nil) }
        == .registerBodyInvalid([AuthRequestIssue(path: "", message: "Expected object, received string")]))
    #expect(body(AuthCoreError.registerBodyInvalid([
        AuthRequestIssue(path: "email", message: "Required"),
        AuthRequestIssue(path: "password", message: "Expected string, received number"),
    ])) == #"{"error":"Invalid email registration body","code":"email_register_body_invalid","issues":[{"path":"email","message":"Required"},{"path":"password","message":"Expected string, received number"}]}"#)

    func request(acceptTerms: Bool = true, terms: String? = AuthLegalPolicy.termsVersion) -> RegisterRequest {
        RegisterRequest(
            email: .string("New@Slock.test"),
            password: .string("password123"),
            name: .string("Newbie"),
            acceptTerms: acceptTerms,
            termsVersion: terms,
            privacyVersion: AuthLegalPolicy.privacyVersion
        )
    }
    #expect(thrown { try service.register(request(acceptTerms: false), userAgent: nil, acceptLanguage: nil) }
        == .legalAcceptanceRequired)
    #expect(thrown { try service.register(request(terms: "old"), userAgent: nil, acceptLanguage: nil) }
        == .termsChanged)
    #expect(!directory.hasAccount(email: "new@slock.test"))
    let legal = "{\"termsVersion\":\"\(AuthLegalPolicy.termsVersion)\",\"privacyVersion\":\"\(AuthLegalPolicy.privacyVersion)\",\"termsUrl\":\"\(AuthLegalPolicy.termsURL)\",\"privacyUrl\":\"\(AuthLegalPolicy.privacyURL)\"}"
    #expect(body(AuthCoreError.legalAcceptanceRequired) == "{\"error\":\"LEGAL_ACCEPTANCE_REQUIRED\",\"legal\":\(legal)}")
    #expect(body(AuthCoreError.termsChanged) == "{\"error\":\"TERMS_CHANGED\",\"legal\":\(legal)}")

    let created = try service.register(request(), userAgent: "ua", acceptLanguage: "en")
    let rendered = created.jsonBody.render()
    #expect(rendered.hasPrefix("{\"user\":{\"id\":\"\(created.id)\",\"email\":\"new@slock.test\",\"name\":\"pending_"))
    #expect(rendered.contains("\"emailVerified\":false,\"profileSetupCompletedAt\":null,\"profileSetupSuggestedHandle\":\"newbie\",\"profileSetupProvider\":null},\"accessToken\":\""))
    #expect(directory.legalAcceptance(userId: created.id)?.source == "signup")
    #expect(directory.emailVerificationCount == 1)
    #expect(thrown { try service.register(request(), userAgent: nil, acceptLanguage: nil) }
        == .emailAlreadyRegistered)
    #expect(body(AuthCoreError.emailAlreadyRegistered) == #"{"error":"Email already registered"}"#)
}

@Test func authCoreSocialCompletionRendersTheLegacyBytes() throws {
    let (directory, service) = fixture()
    directory.addSocialCompletion(provider: "google", code: "c1", email: "social@slock.test", returnTo: "/x")
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
    let (directory, service) = fixture()
    let bearer = directory.mintAccessTokenForTesting(userId: userId)
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
    let (directory, service) = fixture()
    let bearer = directory.mintAccessTokenForTesting(userId: userId)
    let issued = try service.authorizeDevice(DeviceAuthorizeRequest())
    _ = try service.approveDevice(DeviceApproveRequest(userCode: issued.userCode), authorization: "Bearer \(bearer)")
    let sessionsBefore = directory.sessionCount(for: userId)
    let tokens = await successes(24) { _ in
        try? service.pollDeviceToken(DeviceTokenRequest(deviceCode: issued.deviceCode))
    }
    #expect(tokens.count == 1)
    #expect(directory.sessionCount(for: userId) == sessionsBefore + 1)
}

@Test func authCoreConcurrentRefreshRotatesATokenOnce() async throws {
    let (directory, service) = fixture()
    let session = directory.authProfileStore.openSession(userId: userId)
    let rotated = await successes(24) { _ in
        try? service.refresh(
            RefreshTokenRequest(refreshToken: session.refreshToken),
            attemptHeader: nil,
            installationHeader: nil
        )
    }
    #expect(rotated.count == 1)
    #expect(directory.sessionCount(for: userId) == 1)
}

@Test func authCoreConcurrentRegistrationsCreateOneAccount() async throws {
    let (directory, service) = fixture()
    let request = RegisterRequest(
        email: .string("race@slock.test"),
        password: .string("password123"),
        acceptTerms: true,
        termsVersion: AuthLegalPolicy.termsVersion,
        privacyVersion: AuthLegalPolicy.privacyVersion
    )
    let created = await successes(24) { _ in
        try? service.register(request, userAgent: nil, acceptLanguage: nil)
    }
    #expect(created.count == 1)
    #expect(directory.emailVerificationCount == 1)
    #expect(directory.legalAcceptanceCount == 1)
}

@Test func authCoreConcurrentSocialCompletionsSpendACodeOnce() async throws {
    let (directory, service) = fixture()
    directory.addSocialCompletion(provider: "google", code: "race", email: "race-social@slock.test")
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
    #expect(directory.legalAcceptanceCount == 1)
}

@Test func authCoreConcurrentRetirementsWriteOneReceipt() async throws {
    let (directory, _) = fixture()
    directory.releaseBranch = "staging"
    let capability = String(repeating: "c", count: 40)
    var state = directory.authProfileStore.accountState
    let key = AccountNaming.normalize("core@slock.test")
    state.accounts[key]?.emailVerified = true
    state.accounts[key]?.email = "core@mail.build"
    state.accounts["core@mail.build"] = state.accounts.removeValue(forKey: key)
    state.accounts["core@mail.build"]?.stagingSelfAccountCapabilityHash = AuthTokenCodec.sha256(capability)
    directory.authProfileStore.accountState = state
    _ = directory.authProfileStore.openSession(userId: userId)
    let outcomes = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<24 {
            group.addTask {
                if case .retired = directory.authProfileStore.retireStagingAccount(
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
    #expect(directory.retirementReceiptCount == 1)
}
