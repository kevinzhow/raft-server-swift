import Foundation

/// Domain failure for the session, identity, app-login and profile surface.
///
/// Every case publishes the bytes the retired handler built: the canonical
/// `{"error": …}` body, the same object plus `code`, or an explicit
/// `errorBody` where the legacy object put `code` first or carried more keys.
public enum AuthIdentitiesError: DomainError, Equatable {
    case unauthorized
    case missingAuthorization
    case invalidToken
    case passwordCredentialRequired
    case notAServerMember
    case invalidLoginBody([AuthRequestIssue])
    case invalidCredentials
    case pendingLinkExpired
    case pendingLinkAccountMismatch
    case invalidAppLoginRequest
    case returnUriNotAllowed
    case challengeMethodInvalid
    case challengeInvalid
    case requestNotFound
    case requestExpired(redirectUrl: String)
    case requestNotPending
    case invalidAppLoginCompletion
    case codeNotFound
    case codeConsumed
    case codeExpired
    case pkceMismatch
    case requestNotApproved
    case profileUpdateFailed
    case invalidProfile(String)
    case wrongCurrentPassword
    case noAvatarProvided
    case avatarTooLarge(maxBytes: Int)

    public var status: UInt {
        switch self {
        case .unauthorized, .missingAuthorization, .invalidToken, .invalidCredentials,
             .wrongCurrentPassword:
            401
        case .notAServerMember, .pendingLinkAccountMismatch:
            403
        case .requestNotFound, .codeNotFound:
            404
        case .passwordCredentialRequired, .requestNotPending, .requestNotApproved:
            409
        case .pendingLinkExpired, .requestExpired, .codeConsumed, .codeExpired:
            410
        case .invalidLoginBody, .invalidAppLoginRequest, .returnUriNotAllowed,
             .challengeMethodInvalid, .challengeInvalid, .invalidAppLoginCompletion, .pkceMismatch,
             .profileUpdateFailed, .invalidProfile, .noAvatarProvided, .avatarTooLarge:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized: "Unauthorized"
        case .missingAuthorization: "Missing or invalid Authorization header"
        case .invalidToken: "Invalid or expired token"
        case .passwordCredentialRequired: "Set a password before disconnecting your final sign-in account."
        case .notAServerMember: "Not a member of this server"
        case .invalidLoginBody: "Invalid email login body"
        case .invalidCredentials: "Invalid email or password"
        case .pendingLinkExpired: "This sign-in link expired. Sign in again to connect the account."
        case .pendingLinkAccountMismatch: "The pending link belongs to a different account"
        case .invalidAppLoginRequest: "Invalid app login request"
        case .returnUriNotAllowed: "Return URI is not allowed"
        case .challengeMethodInvalid: "PKCE challenge method must be S256"
        case .challengeInvalid: "PKCE challenge is invalid"
        case .requestNotFound: "App login request not found"
        case .requestExpired: "App login request expired"
        case .requestNotPending: "App login request is not pending"
        case .invalidAppLoginCompletion: "Invalid app login completion"
        case .codeNotFound: "App login code not found"
        case .codeConsumed: "App login code was already used"
        case .codeExpired: "App login code expired"
        case .pkceMismatch: "PKCE verifier does not match"
        case .requestNotApproved: "App login request is not approved"
        case .profileUpdateFailed: "Failed to update profile"
        case .invalidProfile(let message): message
        case .wrongCurrentPassword: "Current password is incorrect"
        case .noAvatarProvided: "No avatar file provided"
        case .avatarTooLarge: "Avatar image must be 5 MB or smaller"
        }
    }

    public var errorCode: String? {
        switch self {
        case .missingAuthorization, .invalidToken: "auth_required"
        case .pendingLinkExpired: "pending_link_expired"
        case .pendingLinkAccountMismatch: "pending_link_account_mismatch"
        case .invalidAppLoginRequest, .invalidAppLoginCompletion: "invalid_request"
        case .returnUriNotAllowed: "return_uri_not_allowed"
        case .challengeMethodInvalid: "code_challenge_method_invalid"
        case .challengeInvalid: "code_challenge_invalid"
        case .requestNotFound: "request_not_found"
        case .requestExpired: "request_expired"
        case .requestNotPending: "request_not_pending"
        case .codeNotFound: "code_not_found"
        case .codeConsumed: "code_consumed"
        case .codeExpired: "code_expired"
        case .pkceMismatch: "pkce_mismatch"
        case .requestNotApproved: "request_not_approved"
        default: nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .passwordCredentialRequired:
            .object([
                OrderedJSONField("code", "PASSWORD_CREDENTIAL_REQUIRED"),
                OrderedJSONField("error", errorMessage),
            ])
        case .invalidCredentials:
            .object([
                OrderedJSONField("code", "AUTH_INVALID_CREDENTIALS"),
                OrderedJSONField("error", errorMessage),
            ])
        case .wrongCurrentPassword:
            .object([
                OrderedJSONField("code", "AUTH_CURRENT_PASSWORD_INCORRECT"),
                OrderedJSONField("error", errorMessage),
            ])
        case .invalidLoginBody(let issues):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "email_login_body_invalid"),
                OrderedJSONField("issues", .array(issues.map {
                    .object([
                        OrderedJSONField("path", $0.path),
                        OrderedJSONField("message", $0.message),
                    ])
                })),
            ])
        case .requestExpired(let redirectUrl):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "request_expired"),
                OrderedJSONField("redirectUrl", redirectUrl),
            ])
        case .avatarTooLarge(let maxBytes):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("errorCode", "PROFILE_AVATAR_TOO_LARGE"),
                OrderedJSONField("maxBytes", maxBytes),
            ])
        default:
            nil
        }
    }
}

/// Session, identity, app-login and profile operations.
///
/// Every state change is one `AuthProfileStore` critical section; this type
/// validates the request, asks the store to decide and write, and maps the
/// outcome to its DTO or to `AuthIdentitiesError`. The OAuth ledger only
/// supplies the server membership check and the settings App rows.
public struct AuthIdentitiesService: Sendable {
    private let store: AuthProfileStore
    private let oauth: OAuthLedger
    private let now: @Sendable () -> Date

    init(
        store: AuthProfileStore,
        oauth: OAuthLedger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.oauth = oauth
        self.now = now
    }

    // MARK: Session lookups

    /// The user behind a live access token, or nil.
    private func sessionUserId(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        return store.userId(forAccessToken: String(authorization.dropFirst("Bearer ".count)))
    }

    /// The bearer check the profile routes share: a missing header and an
    /// unknown token publish different bodies.
    private func authorizedUser(_ authorization: String?) throws -> String {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw AuthIdentitiesError.missingAuthorization
        }
        guard let userId = store.userId(forAccessToken: String(authorization.dropFirst("Bearer ".count))) else {
            throw AuthIdentitiesError.invalidToken
        }
        return userId
    }

    /// The user behind a normal access token for the OAuth authorize routes.
    /// `requireAuth` there does not demand a verified email and ignores a
    /// revoked session family, exactly like the retired directory lookup.
    public func oauthSession(authorization: String?) -> OAuthSession {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return .missing }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let account = store.account(forAnyAccessToken: token) else { return .invalid }
        return .user(OAuthHuman(
            id: account.id,
            email: account.email,
            name: account.name,
            emailVerified: account.emailVerified,
            avatarUrl: account.avatarUrl
        ))
    }

    // MARK: Identities

    /// `GET /api/auth/identities`.
    public func identities(authorization: String?) throws -> AuthIdentitiesResponse {
        guard let userId = sessionUserId(authorization) else { throw AuthIdentitiesError.unauthorized }
        let snapshot = store.identitySnapshot(userId: userId)
        return AuthIdentitiesResponse(
            identities: Self.rows(snapshot),
            passwordConfigured: snapshot.passwordConfigured
        )
    }

    /// `DELETE /api/auth/identities/:provider`. The final sign-in identity of a
    /// passwordless user cannot be unlinked.
    public func unlink(authorization: String?, provider: String) throws -> UnlinkIdentityResponse {
        guard let userId = sessionUserId(authorization) else { throw AuthIdentitiesError.unauthorized }
        switch store.unlinkIdentity(userId: userId, provider: provider) {
        case .notLinked(let snapshot):
            return UnlinkIdentityResponse(
                unlinked: false,
                identities: Self.rows(snapshot),
                passwordConfigured: snapshot.passwordConfigured
            )
        case .passwordCredentialRequired:
            throw AuthIdentitiesError.passwordCredentialRequired
        case .unlinked(let snapshot):
            return UnlinkIdentityResponse(
                unlinked: true,
                identities: Self.rows(snapshot),
                passwordConfigured: snapshot.passwordConfigured
            )
        }
    }

    private static func rows(_ snapshot: AuthIdentitySnapshot) -> [AuthIdentityRow] {
        snapshot.rows.map { AuthIdentityRow(provider: $0.provider, providerEmail: $0.providerEmail) }
    }

    // MARK: Integration settings

    /// `GET /api/integrations/clients`: every App this Server owns or has
    /// installed, for a Server member.
    public func integrationSettingsClients(
        authorization: String?,
        serverId: String
    ) throws -> IntegrationSettingsClientsResponse {
        guard let userId = sessionUserId(authorization) else { throw AuthIdentitiesError.unauthorized }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw AuthIdentitiesError.notAServerMember
        }
        return IntegrationSettingsClientsResponse(clients: oauth.integrationSettingsClientRows(serverId: serverId))
    }

    // MARK: Password login

    /// `POST /api/auth/login`. A non-string or empty email or password is
    /// refused before any account lookup; a missing account and a wrong
    /// password share one 401.
    public func login(_ request: LoginRequest?) throws -> LoginResponse {
        guard let request else {
            throw AuthIdentitiesError.invalidLoginBody([
                AuthRequestIssue(path: "", message: "Expected object, received string"),
            ])
        }
        var issues: [AuthRequestIssue] = []
        let email = Self.requiredString(request.email, path: "email", into: &issues)
        let password = Self.requiredString(request.password, path: "password", into: &issues)
        if !issues.isEmpty { throw AuthIdentitiesError.invalidLoginBody(issues) }
        switch store.authenticate(
            email: EmailLoginDirectory.normalize(email ?? ""),
            passwordHash: EmailLoginDirectory.sha256(password ?? ""),
            pendingLinkToken: request.pendingLinkToken,
            now: now()
        ) {
        case .authenticated(let userId, let accountEmail, let tokens, let linkedProvider):
            return LoginResponse(
                userId: userId,
                email: accountEmail,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                linkedProvider: linkedProvider
            )
        case .pendingLinkExpired:
            throw AuthIdentitiesError.pendingLinkExpired
        case .pendingLinkAccountMismatch:
            throw AuthIdentitiesError.pendingLinkAccountMismatch
        case .rejected:
            throw AuthIdentitiesError.invalidCredentials
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
        case .string(let value) where value.isEmpty:
            issues.append(AuthRequestIssue(path: path, message: "String must contain at least 1 character(s)"))
            return nil
        case .string(let value):
            return value
        case .wrongType(let name):
            issues.append(AuthRequestIssue(path: path, message: "Expected string, received \(name)"))
            return nil
        }
    }

    // MARK: App login

    /// `POST /api/auth/app-login/start`. The handoff accepts only the shipped
    /// HarmonyOS return URIs and an S256 PKCE challenge.
    public func appLoginStart(_ request: AppLoginStartRequest) throws -> AppLoginStartResponse {
        guard let returnUri = request.returnUri, !returnUri.isEmpty,
              let codeChallenge = request.codeChallenge, !codeChallenge.isEmpty
        else { throw AuthIdentitiesError.invalidAppLoginRequest }
        guard EmailLoginDirectory.appLoginReturnUris.contains(returnUri) else {
            throw AuthIdentitiesError.returnUriNotAllowed
        }
        if let method = request.codeChallengeMethod, method != "S256" {
            throw AuthIdentitiesError.challengeMethodInvalid
        }
        guard codeChallenge.wholeMatch(of: /^[A-Za-z0-9_-]{43}$/) != nil else {
            throw AuthIdentitiesError.challengeInvalid
        }
        let requestId = UUID().uuidString.lowercased()
        let expiresAt = EmailLoginDirectory.appLoginExpiresAt(now())
        store.insertAppLoginRequest(AppLoginRequest(
            id: requestId,
            returnUri: returnUri,
            codeChallenge: codeChallenge,
            status: "pending",
            code: nil,
            userId: nil,
            expiresAt: expiresAt,
            consumedAt: nil
        ))
        return AppLoginStartResponse(
            requestId: requestId,
            loginUrl: "\(store.appURL)/login/app?request=\(requestId)",
            expiresAt: EmailLoginDirectory.iso8601(expiresAt)
        )
    }

    /// The signed-in user for the request routes. A missing and an unknown
    /// bearer publish the same invalid-token body.
    private func appLoginActor(_ authorization: String?) throws -> String {
        guard let userId = sessionUserId(authorization) else { throw AuthIdentitiesError.invalidToken }
        return userId
    }

    /// `GET /api/auth/app-login/requests/:requestId`. Only a signed-in user may read the request.
    public func appLoginDescribe(authorization: String?, requestId: String) throws -> AppLoginRequestResponse {
        _ = try appLoginActor(authorization)
        guard let request = store.appLoginRequest(id: requestId) else {
            throw AuthIdentitiesError.requestNotFound
        }
        return AppLoginRequestResponse(
            requestId: request.id,
            status: request.status,
            returnUri: request.returnUri,
            expiresAt: EmailLoginDirectory.iso8601(request.expiresAt)
        )
    }

    /// `POST /api/auth/app-login/requests/:requestId/approve`.
    public func appLoginApprove(authorization: String?, requestId: String) throws -> AppLoginRedirectResponse {
        let userId = try appLoginActor(authorization)
        let request = try decide(requestId: requestId, .approve(userId: userId, code: EmailLoginDirectory.token()))
        return AppLoginRedirectResponse(redirectUrl: EmailLoginDirectory.appLoginRedirect(
            request.returnUri,
            requestId: request.id,
            query: "code=\(request.code ?? "")"
        ))
    }

    /// `POST /api/auth/app-login/requests/:requestId/deny`.
    public func appLoginDeny(authorization: String?, requestId: String) throws -> AppLoginRedirectResponse {
        _ = try appLoginActor(authorization)
        let request = try decide(requestId: requestId, .deny)
        return AppLoginRedirectResponse(redirectUrl: EmailLoginDirectory.appLoginRedirect(
            request.returnUri,
            requestId: request.id,
            query: "error=access_denied"
        ))
    }

    private func decide(requestId: String, _ decision: AppLoginDecision) throws -> AppLoginRequest {
        switch store.decideAppLogin(requestId: requestId, decision: decision, now: now()) {
        case .decided(let request):
            return request
        case .notFound:
            throw AuthIdentitiesError.requestNotFound
        case .expired(let request):
            throw AuthIdentitiesError.requestExpired(redirectUrl: EmailLoginDirectory.appLoginRedirect(
                request.returnUri,
                requestId: request.id,
                query: "error=expired"
            ))
        case .notPending:
            throw AuthIdentitiesError.requestNotPending
        }
    }

    /// `POST /api/auth/app-login/complete`. The one-time code is bound to the
    /// request's S256 challenge and request expiry; a wrong verifier does not burn it.
    public func appLoginComplete(_ request: AppLoginCompleteRequest) throws -> AppLoginCompleteResponse {
        guard let code = request.code, !code.isEmpty,
              let verifier = request.codeVerifier, !verifier.isEmpty
        else { throw AuthIdentitiesError.invalidAppLoginCompletion }
        switch store.completeAppLogin(
            code: code,
            verifierChallenge: EmailLoginDirectory.pkceS256(verifier),
            now: now()
        ) {
        case .completed(let account, let tokens):
            return AppLoginCompleteResponse(
                user: AuthUserDTO(account: account),
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken
            )
        case .codeNotFound:
            throw AuthIdentitiesError.codeNotFound
        case .codeConsumed:
            throw AuthIdentitiesError.codeConsumed
        case .codeExpired:
            throw AuthIdentitiesError.codeExpired
        case .pkceMismatch:
            throw AuthIdentitiesError.pkceMismatch
        case .notApproved:
            throw AuthIdentitiesError.requestNotApproved
        case .accountMissing:
            throw AuthIdentitiesError.invalidToken
        }
    }

    // MARK: Profile

    /// `GET /api/auth/me`. The gravatar hash is SHA-256 of the stored email,
    /// trimmed and lowercased.
    public func me(authorization: String?) throws -> AuthMeResponse {
        let userId = try authorizedUser(authorization)
        guard let account = store.account(userId: userId), account.retiredAt == nil else {
            throw AuthIdentitiesError.invalidToken
        }
        let observed = store.timezoneObservation(userId: userId).map {
            TimezoneObservationResponse(
                firstObservedTimezone: $0.firstTimezone,
                firstObservedTimezoneAt: EmailLoginDirectory.iso8601($0.firstAt),
                lastObservedTimezone: $0.lastTimezone,
                lastObservedTimezoneAt: EmailLoginDirectory.iso8601($0.lastAt)
            )
        }
        return AuthMeResponse(user: AuthUserDTO(account: account), observedTimezone: observed)
    }

    /// `POST /api/auth/me/avatar`. A file over 5 MB is refused before the stored path changes.
    public func uploadAvatar(
        authorization: String?,
        contentType: String?,
        body: Data
    ) throws -> AuthProfileUserResponse {
        let userId = try authorizedUser(authorization)
        guard let file = EmailLoginDirectory.multipartFile(named: "avatar", contentType: contentType, body: body) else {
            throw AuthIdentitiesError.noAvatarProvided
        }
        if file.count > EmailLoginDirectory.maxProfileAvatarBytes {
            throw AuthIdentitiesError.avatarTooLarge(maxBytes: EmailLoginDirectory.maxProfileAvatarBytes)
        }
        let hash = String(EmailLoginDirectory.sha256(file).prefix(32))
        guard let account = store.setAvatarURL(userId: userId, url: "/api/avatars/users/\(hash).webp") else {
            throw AuthIdentitiesError.invalidToken
        }
        return AuthProfileUserResponse(user: AuthUserDTO(account: account))
    }

    /// `PATCH /api/auth/me`. A wrong current password is refused before any
    /// profile write; the password change itself is written before the other
    /// fields are validated, as the retired handler did. Display language
    /// accepts only the shipped UI catalogs. A body that is not a JSON object
    /// reaches here as `nil`.
    public func updateProfile(
        authorization: String?,
        _ request: UpdateProfileRequest?
    ) throws -> AuthProfileUserResponse {
        let userId = try authorizedUser(authorization)
        guard let request else { throw AuthIdentitiesError.profileUpdateFailed }

        if case .value(let current) = request.currentPassword, !current.isEmpty,
           case .value(let newPassword) = request.newPassword, !newPassword.isEmpty {
            if newPassword.count < 8 {
                throw AuthIdentitiesError.invalidProfile("New password must be at least 8 characters")
            }
            switch store.changePassword(
                userId: userId,
                currentHash: EmailLoginDirectory.sha256(current),
                newHash: EmailLoginDirectory.sha256(newPassword)
            ) {
            case .changed: break
            case .accountMissing: throw AuthIdentitiesError.invalidToken
            case .wrongPassword: throw AuthIdentitiesError.wrongCurrentPassword
            }
        }

        let update = try Self.validatedUpdate(request)
        guard let account = store.applyProfileUpdate(
            userId: userId,
            update: update,
            now: now(),
            newAnalyticsId: UUID().uuidString.lowercased()
        ) else { throw AuthIdentitiesError.invalidToken }
        return AuthProfileUserResponse(user: AuthUserDTO(account: account))
    }

    /// The per-field checks in the order the retired handler ran them: the
    /// first failing field decides the 400.
    private static func validatedUpdate(_ request: UpdateProfileRequest) throws -> AccountProfileUpdate {
        var update = AccountProfileUpdate()

        switch request.displayLanguage {
        case .absent:
            break
        case .null:
            update.displayLanguage = .some(nil)
        case .invalid:
            throw AuthIdentitiesError.invalidProfile("displayLanguage must be a string or null")
        case .value(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                update.displayLanguage = .some(nil)
            } else if let normalized = EmailLoginDirectory.normalizeDisplayLocale(trimmed) {
                update.displayLanguage = .some(normalized)
            } else {
                throw AuthIdentitiesError.invalidProfile("displayLanguage must be a supported UI display locale")
            }
        }

        switch request.shareUsageData {
        case .absent: break
        case .null: update.shareUsageData = .some(nil)
        case .value(let share): update.shareUsageData = .some(share)
        case .invalid:
            throw AuthIdentitiesError.invalidProfile("shareUsageData must be a boolean or null")
        }

        switch request.preferredLanguage {
        case .absent: break
        case .null: update.preferredLanguage = .some(nil)
        case .value(let value) where value.wholeMatch(of: /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/) != nil:
            update.preferredLanguage = .some(value.lowercased())
        default:
            throw AuthIdentitiesError.invalidProfile("Unsupported preferredLanguage")
        }

        switch request.preferredTimezone {
        case .absent: break
        case .null: update.preferredTimezone = .some(nil)
        case .value(let value) where TimeZone(identifier: value) != nil:
            update.preferredTimezone = .some(value)
        default:
            throw AuthIdentitiesError.invalidProfile("Invalid preferredTimezone")
        }

        switch request.preferredTranslationMode {
        case .absent: break
        case .value(let value) where ["off", "manual", "auto"].contains(value):
            update.preferredTranslationMode = value
        default:
            throw AuthIdentitiesError.invalidProfile("Invalid preferredTranslationMode")
        }

        switch request.autoTranslationEnabled {
        case .absent: break
        case .value(let value): update.autoTranslationEnabled = value
        default:
            throw AuthIdentitiesError.invalidProfile("Invalid autoTranslationEnabled")
        }

        switch request.preferredTranslationDisplay {
        case .absent: break
        case .value(let value) where ["translated", "bilingual", "original"].contains(value):
            update.preferredTranslationDisplay = value
        default:
            throw AuthIdentitiesError.invalidProfile("Invalid preferredTranslationDisplay")
        }

        switch request.preferredTimeFormat {
        case .absent: break
        case .null: update.preferredTimeFormat = .some(nil)
        case .value(let value) where ["12h", "24h"].contains(value.lowercased()):
            update.preferredTimeFormat = .some(value.lowercased())
        default:
            throw AuthIdentitiesError.invalidProfile("Invalid preferredTimeFormat")
        }

        switch request.preferredMessageBodyFontSize {
        case .absent: break
        case .null: update.preferredMessageBodyFontSize = .some(nil)
        case .value(let value) where ["sm", "md", "lg", "xl"].contains(value.lowercased()):
            update.preferredMessageBodyFontSize = .some(value.lowercased())
        default:
            throw AuthIdentitiesError.invalidProfile("Invalid preferredMessageBodyFontSize")
        }

        let referralSources = [
            "twitter_x", "linkedin", "friend_colleague", "search", "hn_reddit",
            "podcast_blog_newsletter", "other",
        ]
        switch request.referralSource {
        case .null:
            update.referralSource = .some(nil)
            update.referralSourceOther = .some(nil)
        case .value(let value) where referralSources.contains(value):
            update.referralSource = .some(value)
            if value == "other", case .value(let other) = request.referralSourceOther {
                let trimmed = String(other.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                update.referralSourceOther = .some(trimmed.isEmpty ? nil : trimmed)
            } else {
                update.referralSourceOther = .some(nil)
            }
        case .absent:
            if request.referralSourceOther != .absent {
                throw AuthIdentitiesError.invalidProfile(
                    "referralSource is required when referralSourceOther is provided"
                )
            }
        default:
            throw AuthIdentitiesError.invalidProfile("Invalid referralSource")
        }
        switch request.referralSourceSkipped {
        case .absent: break
        case .value(let skipped): update.referralSourceSkipped = skipped
        default:
            throw AuthIdentitiesError.invalidProfile("referralSourceSkipped must be a boolean")
        }
        return update
    }
}
