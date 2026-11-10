import Foundation

/// Session core: provider-completion login, register, staging retirement, the
/// device-grant flow, refresh rotation and logout, plus the bearer check the
/// unmigrated domains still share.
///
/// The service validates the decoded request, calls the account store (every
/// read-modify-write is one store critical section) and returns a DTO or
/// throws `AuthCoreError`; the feature owns the HTTP projection. There are no
/// cross-domain dependencies: the account, session, grant and legal rows all
/// live in `AuthProfileStore`.
public struct AuthCoreService: Sendable {
    let store: AuthProfileStore
    let now: @Sendable () -> Date
    private let transactionalEmail: TransactionalEmailIntentPort

    init(
        store: AuthProfileStore,
        now: @escaping @Sendable () -> Date = { Date() },
        transactionalEmail: TransactionalEmailIntentPort = .developmentOnly
    ) {
        self.store = store
        self.now = now
        self.transactionalEmail = transactionalEmail
    }

    /// Retains this owner's account/session data and clock. The production
    /// coordinator and real worker are wired by the composition root.
    public func bindingTransactionalEmail(_ port: TransactionalEmailIntentPort) -> Self {
        Self(store: store, now: now, transactionalEmail: port)
    }

    // MARK: Bearer check

    /// Realtime identity from one live account/session snapshot. Push keeps its
    /// separate token-table lookup; legacy familyless access remains supported.
    public func sessionIdentity(accessToken: String) -> (userId: String, familyId: String?)? {
        store.activeSessionPrincipal(accessToken: accessToken)
    }

    /// The user behind a live access token. A missing or non-bearer header is
    /// `missingAuthorization`; an unknown token or a revoked family is
    /// `invalidToken`.
    func authenticate(_ authorization: String?) throws -> String {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AuthCoreError.missingAuthorization
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let userId = store.userId(forAccessToken: token) else {
            throw AuthCoreError.invalidToken
        }
        return userId
    }

    // MARK: Social completion

    /// `POST /api/auth/:provider/complete`. A first login checks legal
    /// acceptance before the code is spent.
    public func completeSocial(
        provider: String, body: SocialCompleteRequest, userAgent: String?,
        acceptLanguage: String?, authorization: String?
    ) throws -> SocialCompleteResponse {
        let needed = try socialPlaceholderNeeded(provider: provider, body: body)
        let placeholder = needed ? try PasswordCredential.hash(AuthTokenCodec.randomHex(32)) : nil
        return try finishSocial(provider: provider, body: body, userAgent: userAgent,
                                acceptLanguage: acceptLanguage, authorization: authorization, passwordPlaceholder: placeholder)
    }

    public func completeSocialAsync(
        provider: String, body: SocialCompleteRequest, userAgent: String?,
        acceptLanguage: String?, authorization: String?
    ) async throws -> SocialCompleteResponse {
        let needed = try socialPlaceholderNeeded(provider: provider, body: body)
        let placeholder = needed ? try await PasswordWork.hash(AuthTokenCodec.randomHex(32)) : nil
        return try finishSocial(provider: provider, body: body, userAgent: userAgent,
                                acceptLanguage: acceptLanguage, authorization: authorization, passwordPlaceholder: placeholder)
    }

    private func socialPlaceholderNeeded(provider: String, body: SocialCompleteRequest) throws -> Bool {
        guard AuthRedirects.socialProviders.contains(provider) else { throw AuthCoreError.notFound }
        guard let code = body.code, !code.isEmpty else { throw AuthCoreError.socialCompletionCodeRequired }
        return store.socialPasswordPlaceholderNeeded(provider: provider, code: code)
    }

    private func finishSocial(
        provider: String,
        body: SocialCompleteRequest,
        userAgent: String?,
        acceptLanguage: String?,
        authorization: String?,
        passwordPlaceholder: String?
    ) throws -> SocialCompleteResponse {
        guard AuthRedirects.socialProviders.contains(provider) else {
            throw AuthCoreError.notFound
        }
        guard let code = body.code, !code.isEmpty else {
            throw AuthCoreError.socialCompletionCodeRequired
        }
        let moment = now()
        let outcome = store.completeSocial(SocialCompletionAttempt(
            provider: provider,
            code: code,
            pendingLinkToken: body.pendingLinkToken,
            acceptTerms: body.acceptTerms,
            termsVersion: body.termsVersion,
            privacyVersion: body.privacyVersion,
            legalAcceptanceSource: body.legalAcceptanceSource,
            bearerToken: Self.bearerToken(authorization),
            userAgentHash: userAgent.flatMap { $0.isEmpty ? nil : AuthTokenCodec.sha256($0) },
            locale: acceptLanguage,
            now: moment,
            passwordPlaceholder: passwordPlaceholder
        ))
        switch outcome {
        case .invalidCompletion:
            throw AuthCoreError.socialCompletionInvalid
        case .linkAuthRequired:
            throw AuthCoreError.linkAuthRequired
        case .linkMismatch:
            throw AuthCoreError.linkUserMismatch
        case .linked(let returnTo, let identities):
            return .linked(
                provider: provider,
                returnTo: returnTo,
                identities: identities.map {
                    SocialLinkedIdentityDTO(provider: $0.provider, providerEmail: $0.providerEmail)
                }
            )
        case .pendingLinkExpired:
            throw AuthCoreError.pendingLinkExpired
        case .pendingLinkAccountMismatch:
            throw AuthCoreError.pendingLinkAccountMismatch
        case .pendingLinkLogin(let returnTo, let tokens, let linkedProvider):
            return .session(
                provider: provider,
                mode: "login",
                returnTo: returnTo,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                linkedProvider: linkedProvider
            )
        case .accountLinkRequired(let handle):
            throw AuthCoreError.accountLinkRequired(AccountLinkRequiredBody(
                pendingLinkToken: handle.pendingLinkToken,
                provider: provider,
                email: handle.email,
                expiresAt: ISO8601DateFormatter().string(from: moment.addingTimeInterval(600)),
                hasPassword: handle.hasPassword,
                providers: handle.linkedProviders,
                returnTo: handle.returnTo
            ))
        case .legalRequired:
            throw AuthCoreError.legalAcceptanceRequired
        case .termsChanged:
            throw AuthCoreError.termsChanged
        case .emailExists:
            throw AuthCoreError.socialEmailExists(provider: provider)
        case .loggedIn(let mode, let returnTo, let tokens):
            return .session(
                provider: provider,
                mode: mode,
                returnTo: returnTo,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                linkedProvider: nil
            )
        }
    }

    private static func bearerToken(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        return String(authorization.dropFirst("Bearer ".count))
    }

    // MARK: Register

    /// `POST /api/auth/register`. A non-string email, password, or name is 400
    /// before any account exists. Missing acceptance is 422. A stale version is
    /// 409 and creates no account.
    public func register(
        _ body: RegisterRequest?, userAgent: String?, acceptLanguage: String?
    ) throws -> RegisterResponse {
        let input = try registrationInput(body, userAgent: userAgent, acceptLanguage: acceptLanguage)
        var attempt = input.attempt
        attempt.passwordHash = try PasswordCredential.hash(input.password)
        attempt.now = now()
        return try finishRegistration(attempt)
    }

    public func registerAsync(
        _ body: RegisterRequest?, userAgent: String?, acceptLanguage: String?
    ) async throws -> RegisterResponse {
        let input = try registrationInput(body, userAgent: userAgent, acceptLanguage: acceptLanguage)
        var attempt = input.attempt
        attempt.passwordHash = try await PasswordWork.hash(input.password)
        attempt.now = now()
        return try finishRegistration(attempt)
    }

    private func registrationInput(
        _ body: RegisterRequest?,
        userAgent: String?,
        acceptLanguage: String?
    ) throws -> (attempt: RegistrationAttempt, password: String) {
        guard let body else {
            throw AuthCoreError.registerBodyInvalid([
                AuthRequestIssue(path: "", message: "Expected object, received string"),
            ])
        }
        var issues: [AuthRequestIssue] = []
        let email = Self.requiredString(body.email, path: "email", into: &issues)
        let password = Self.requiredString(body.password, path: "password", into: &issues)
        if body.name != .absent {
            _ = Self.requiredString(body.name, path: "name", into: &issues)
        }
        let capability = Self.stagingCapability(body.stagingSelfAccountCapability, into: &issues)
        guard let email, let password, issues.isEmpty else {
            throw AuthCoreError.registerBodyInvalid(issues)
        }
        if capability != nil {
            let stagingEmail = email.wholeMatch(of: /(?i).*@mail\.build/) != nil
            if deploymentConfiguration.releaseBranch != "staging" || !stagingEmail {
                throw AuthCoreError.stagingRegistrationUnavailable
            }
        }
        var requestedName: String?
        if case .string(let name) = body.name {
            if AccountNaming.isReservedAgentName(name) { throw AuthCoreError.reservedName }
            requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard body.acceptTerms else { throw AuthCoreError.legalAcceptanceRequired }
        if body.termsVersion != AuthLegalPolicy.termsVersion
            || body.privacyVersion != AuthLegalPolicy.privacyVersion {
            throw AuthCoreError.termsChanged
        }
        try transactionalEmail.requireReady(in: store.state.domain)
        let autoVerify = transactionalEmail.allowsDevelopmentAutoVerification(in: store.state.domain)
            && ProcessInfo.processInfo.environment["SLOCK_E2E_AUTO_VERIFY_EMAIL"] == "1"
            && body.e2eAutoVerify
        let moment = now()
        return (RegistrationAttempt(
            normalizedEmail: AccountNaming.normalize(email),
            passwordHash: "",
            requestedName: requestedName,
            capabilityHash: capability.map(AuthTokenCodec.sha256),
            legalAcceptanceSource: body.legalAcceptanceSource == "invite" ? "invite" : "signup",
            userAgentHash: userAgent.flatMap { $0.isEmpty ? nil : AuthTokenCodec.sha256($0) },
            locale: acceptLanguage,
            autoVerify: autoVerify,
            now: moment
        ), password)
    }

    private func finishRegistration(_ attempt: RegistrationAttempt) throws -> RegisterResponse {
        switch store.registerAccount(attempt) {
        case .emailTaken:
            throw AuthCoreError.emailAlreadyRegistered
        case .created(let registered):
            try transactionalEmail.verification(
                recipientEmail: registered.account.email, name: "there", rawToken: registered.verificationToken,
                issuedAt: attempt.now
            )
            return RegisterResponse(
                user: AuthUserDTO(account: registered.account),
                accessToken: registered.tokens.accessToken,
                refreshToken: registered.tokens.refreshToken
            )
        }
    }

    private static func requiredString(
        _ field: LoginBodyField,
        path: String,
        into issues: inout [AuthRequestIssue]
    ) -> String? {
        switch field {
        case .absent:
            issues.append(AuthRequestIssue(path: path, message: "Required"))
            return nil
        case .string(let value):
            if value.isEmpty {
                issues.append(AuthRequestIssue(path: path, message: "String must contain at least 1 character(s)"))
                return nil
            }
            return value
        case .wrongType(let shape):
            issues.append(AuthRequestIssue(path: path, message: "Expected string, received \(shape)"))
            return nil
        }
    }

    private static func stagingCapability(
        _ field: LoginBodyField,
        into issues: inout [AuthRequestIssue]
    ) -> String? {
        let path = "stagingSelfAccountCapability"
        switch field {
        case .absent:
            return nil
        case .wrongType(let shape):
            issues.append(AuthRequestIssue(path: path, message: "Expected string, received \(shape)"))
            return nil
        case .string(let text):
            if text.count < 32 {
                issues.append(AuthRequestIssue(path: path, message: "String must contain at least 32 character(s)"))
                return nil
            }
            if text.count > 256 {
                issues.append(AuthRequestIssue(path: path, message: "String must contain at most 256 character(s)"))
                return nil
            }
            return text
        }
    }

    // MARK: Staging retirement

    /// `POST /api/auth/staging-self-account/retire`. The caller's access token
    /// stays usable after the sessions are revoked.
    public func retireStagingSelfAccount(
        _ body: RetireStagingRequest,
        authorization: String?,
        onSessionsRevoked: @Sendable (SessionAccessRevocation) -> Void = { _ in }
    ) throws -> StagingRetirementResponse {
        guard let token = Self.bearerToken(authorization),
              let actorId = store.accessTokenOwner(token)
        else { throw AuthCoreError.invalidToken }
        guard deploymentConfiguration.releaseBranch == "staging" else { throw AuthCoreError.notFound }
        let userId = body.userId ?? ""
        let capability = body.capability ?? ""
        if userId != actorId { throw AuthCoreError.retirementOwnershipMismatch }
        if capability.isEmpty { throw AuthCoreError.invalidRetirementCapability }
        guard userId.wholeMatch(of: /(?i)[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil else {
            throw AuthCoreError.userNotFound
        }
        let outcome = store.retireStagingAccount(
            userId: userId,
            actorUserId: actorId,
            capabilityHash: AuthTokenCodec.sha256(capability),
            now: now()
        )
        switch outcome {
        case .userNotFound:
            throw AuthCoreError.userNotFound
        case .unsupportedAccount:
            throw AuthCoreError.unsupportedAccount
        case .invalidCapability:
            throw AuthCoreError.invalidRetirementCapability
        case .alreadyRetired(let receipt):
            guard let receipt else { throw AuthCoreError.retirementReceiptUnavailable }
            onSessionsRevoked(.user(userId: receipt.userId))
            return Self.response(receipt)
        case .retired(let receipt):
            onSessionsRevoked(.user(userId: receipt.userId))
            return Self.response(receipt)
        }
    }

    private static func response(_ receipt: RetirementReceipt) -> StagingRetirementResponse {
        StagingRetirementResponse(
            userId: receipt.userId,
            actorUserId: receipt.actorUserId,
            environment: receipt.environment,
            terminalState: receipt.terminalState,
            sessionsRevoked: receipt.sessionsRevoked
        )
    }

    // MARK: Device grants

    private func requireDeviceSurface() throws {
        guard AuthRedirects.deviceLoginEnabled(deploymentConfiguration.deviceLoginGate) else {
            throw AuthCoreError.deviceLoginDisabled
        }
    }

    /// `POST /api/auth/device/authorize`. The surface is on unless the gate is
    /// an explicit off value. The grant is stored before the login URL is
    /// checked, as before.
    public func authorizeDevice(_ body: DeviceAuthorizeRequest) throws -> DeviceAuthorizeResponse {
        try requireDeviceSurface()
        var clientName: String?
        switch body.clientName {
        case .absent:
            break
        case .string(let name):
            guard name.count <= 200 else { throw AuthCoreError.clientNameInvalid }
            clientName = name
        case .invalidType:
            throw AuthCoreError.clientNameInvalid
        }
        let userCode = Self.makeUserCode()
        let deviceCode = AuthTokenCodec.deviceSecret()
        store.registerDeviceGrant(
            deviceCode: deviceCode,
            userCode: userCode,
            clientName: clientName,
            expiresAt: now().addingTimeInterval(600)
        )
        guard let verification = deviceVerification(userCode: userCode) else {
            throw AuthCoreError.deviceLoginURLUnavailable
        }
        return DeviceAuthorizeResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationUri: verification.uri,
            verificationUriComplete: verification.complete
        )
    }

    /// `POST /api/auth/device/approve`. Only the signed-in user can approve or
    /// deny a code.
    public func approveDevice(
        _ body: DeviceApproveRequest,
        authorization: String?
    ) throws -> DeviceDecisionResponse {
        try requireDeviceSurface()
        let actor = try authenticate(authorization)
        guard let rawCode = body.userCode,
              !rawCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AuthCoreError.userCodeRequired }
        let normalized = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch store.decideDeviceGrant(
            userCode: normalized,
            approve: body.approve,
            actorUserId: actor,
            now: now()
        ) {
        case .userCodeInvalid:
            throw AuthCoreError.deviceUpdateFailed(code: "user_code_invalid", status: 404)
        case .alreadyResolved:
            throw AuthCoreError.deviceUpdateFailed(code: "already_resolved", status: 409)
        case .expired:
            throw AuthCoreError.deviceUpdateFailed(code: "expired", status: 410)
        case .decided:
            return DeviceDecisionResponse(approved: body.approve)
        }
    }

    /// `POST /api/auth/device/token`. A pending grant stays pending. Approval
    /// issues one session, then the code is spent.
    public func pollDeviceToken(_ body: DeviceTokenRequest) throws -> DeviceTokenResponse {
        try requireDeviceSurface()
        guard let deviceCode = body.deviceCode, !deviceCode.isEmpty else {
            throw AuthCoreError.deviceCodeRequired
        }
        switch store.consumeDeviceGrant(deviceCode: deviceCode, now: now()) {
        case .deviceCodeInvalid:
            throw AuthCoreError.deviceNotReady(code: "device_code_invalid", status: 400)
        case .consumed:
            throw AuthCoreError.deviceNotReady(code: "device_code_consumed", status: 410)
        case .expired:
            throw AuthCoreError.deviceNotReady(code: "expired_token", status: 410)
        case .denied:
            throw AuthCoreError.deviceNotReady(code: "access_denied", status: 403)
        case .pending:
            throw AuthCoreError.deviceNotReady(code: "authorization_pending", status: 400)
        case .issued(let userId, let tokens):
            return DeviceTokenResponse(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                userId: userId
            )
        }
    }

    private func deviceVerification(userCode: String) -> (uri: String, complete: String)? {
        let trimmed = store.appURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        let uri = "\(base)/login/device"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        let encoded = userCode.addingPercentEncoding(withAllowedCharacters: allowed) ?? userCode
        return (uri, "\(uri)?user_code=\(encoded)")
    }

    private static func makeUserCode() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var chars = ""
        for _ in 0..<8 {
            chars.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return "\(chars.prefix(4))-\(chars.dropFirst(4))"
    }

    // MARK: Refresh and logout

    /// `POST /api/auth/refresh`. A matching attempt and installation replay the
    /// same successor. The replay-binding identifiers stay headers.
    public func refresh(
        _ body: RefreshTokenRequest,
        attemptHeader: String?,
        installationHeader: String?
    ) throws -> RefreshResponse {
        guard let refreshToken = body.refreshToken, !refreshToken.isEmpty else {
            throw AuthCoreError.refreshTokenRequired
        }
        let attempt = AuthTokenCodec.refreshAttempt(attemptHeader)
        let installation = AuthTokenCodec.refreshInstallation(installationHeader)
        if installationHeader != nil, attempt == nil || installation == nil {
            throw AuthCoreError.invalidRefreshBinding
        }
        guard let rotation = store.rotateRefreshToken(
            refreshToken,
            attemptId: attempt,
            installationId: installation,
            now: now()
        ) else { throw AuthCoreError.invalidRefreshToken }
        return RefreshResponse(accessToken: rotation.accessToken, refreshToken: rotation.refreshToken)
    }

    /// `POST /api/auth/logout`. Revoking the predecessor's family blocks a later
    /// replay. A body without a usable token still answers `{"ok":true}`.
    public func logout(_ body: RefreshTokenRequest,
                       onSessionsRevoked: @Sendable (SessionAccessRevocation) -> Void = { _ in }) -> OkResponse {
        if let refreshToken = body.refreshToken, !refreshToken.isEmpty,
           let revoked = store.revokeRefreshFamily(refreshToken: refreshToken, now: now()) {
            onSessionsRevoked(revoked)
        }
        return OkResponse()
    }
}
