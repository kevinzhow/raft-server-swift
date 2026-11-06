import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif


/// Typed facade over the session, identity and app-login surface: the
/// authenticated profile readbacks, identity listing and unlink, and the
/// HarmonyOS handoff whose code is bound to an S256 challenge.
///
/// The state transitions stay on `EmailLoginDirectory` with unchanged
/// signatures; this type is the `Service` boundary the routes call.
public struct AuthIdentitiesService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    /// `GET /api/auth/identities`.
    public func identities(authorization: String?) -> HTTPReply {
        directory.authIdentities(authorization: authorization)
    }

    /// `DELETE /api/auth/identities/:provider`.
    public func unlink(authorization: String?, provider: String) -> HTTPReply {
        directory.unlinkAuthIdentity(authorization: authorization, provider: provider)
    }

    /// `GET /api/auth/me`.
    public func me(authorization: String?) -> HTTPReply {
        directory.me(authorization: authorization)
    }

    /// `PATCH /api/auth/me`.
    public func patch(authorization: String?, body: String) -> HTTPReply {
        directory.patch(authorization: authorization, body: body)
    }

    /// `POST /api/auth/app-login/start`.
    public func appLoginStart(_ body: AppLoginStartRequestDTO) -> HTTPReply {
        directory.appLoginStart(body: body.encodedBody())
    }

    /// `POST /api/auth/app-login/complete`.
    public func appLoginComplete(_ body: AppLoginCompleteRequestDTO) -> HTTPReply {
        directory.appLoginComplete(body: body.encodedBody())
    }
}

extension EmailLoginDirectory {

    /// The user behind a normal access token. `requireAuth` does not demand a verified email.
    public func oauthSession(authorization: String?) -> OAuthSession {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return .missing }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        defer { lock.unlock() }
        guard let userId = accessTokens[token],
              let account = accounts.values.first(where: { $0.id == userId })
        else { return .invalid }
        return .user(OAuthHuman(
            id: account.id,
            email: account.email,
            name: account.name,
            emailVerified: account.emailVerified,
            avatarUrl: account.avatarUrl
        ))
    }

    func identitiesJSONLocked(userId: String) -> (identities: String, passwordConfigured: Bool) {
        let rows = authProfileStore.identities(userId: userId).map { row in
            "{\"provider\":\(jsonString(row.provider)),\"providerEmail\":\(jsonString(row.providerEmail))}"
        }.joined(separator: ",")
        let account = accounts.values.first { $0.id == userId }
        return (rows, account?.passwordCredentialEstablishedAt != nil)
    }

    public func authIdentities(authorization: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let state = identitiesJSONLocked(userId: userId)
        lock.unlock()
        return Self.json(200, "{\"identities\":[\(state.identities)],\"passwordConfigured\":\(state.passwordConfigured)}")
    }

    public func unlinkAuthIdentity(authorization: String?, provider: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        var rows = authProfileStore.identities(userId: userId)
        guard let index = rows.firstIndex(where: { $0.provider == provider }) else {
            let state = identitiesJSONLocked(userId: userId)
            lock.unlock()
            return Self.json(200, "{\"unlinked\":false,\"identities\":[\(state.identities)],\"passwordConfigured\":\(state.passwordConfigured)}")
        }
        let passwordConfigured = identitiesJSONLocked(userId: userId).passwordConfigured
        if rows.count == 1, !passwordConfigured {
            lock.unlock()
            return Self.json(409, "{\"code\":\"PASSWORD_CREDENTIAL_REQUIRED\",\"error\":\"Set a password before disconnecting your final sign-in account.\"}")
        }
        rows.remove(at: index)
        authProfileStore.replaceIdentities(userId: userId, rows: rows)
        let state = identitiesJSONLocked(userId: userId)
        lock.unlock()
        return Self.json(200, "{\"unlinked\":true,\"identities\":[\(state.identities)],\"passwordConfigured\":\(state.passwordConfigured)}")
    }

    public func resetPassword(body: String) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty,
              let password = object["password"] as? String, !password.isEmpty
        else {
            return Self.json(400, "{\"error\":\"token and password are required\"}")
        }
        let hash = Self.sha256(token)
        lock.lock()
        guard let reset = authProfileStore.resetToken(hash: hash), reset.expiresAt > Date(),
              let email = accounts.first(where: { $0.value.id == reset.userId })?.key
        else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid or expired reset token\"}")
        }
        authProfileStore.removeResetToken(hash: hash)
        accounts[email]?.passwordHash = Self.sha256(password)
        accounts[email]?.passwordCredentialEstablishedAt = Date()
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func authIdentityCount(userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return authProfileStore.identityCount(userId: userId)
    }

    public func passwordCredentialEstablished(userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accounts.values.first { $0.id == userId }?.passwordCredentialEstablishedAt != nil
    }

    public func integrationSettingsClients(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let data = try? JSONSerialization.data(withJSONObject: oauth.integrationSettingsClients(serverId: serverId))
        return Self.json(200, String(decoding: data ?? Data("[]".utf8), as: UTF8.self))
    }

    public func login(body: String) -> HTTPReply {
        switch Self.parse(body) {
        case .invalid(let issues):
            return Self.invalid(issues)
        case .request(let request):
            return authenticate(request)
        }
    }




    /// `POST /api/auth/app-login/start`. The handoff accepts only the shipped
    /// HarmonyOS return URIs and an S256 PKCE challenge.
    public func appLoginStart(body: String) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let returnUri = object["returnUri"] as? String, !returnUri.isEmpty,
              let codeChallenge = object["codeChallenge"] as? String, !codeChallenge.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid app login request\",\"code\":\"invalid_request\"}")
        }
        guard Self.appLoginReturnUris.contains(returnUri) else {
            return Self.json(400, "{\"error\":\"Return URI is not allowed\",\"code\":\"return_uri_not_allowed\"}")
        }
        if let method = object["codeChallengeMethod"] as? String, method != "S256" {
            return Self.json(400, "{\"error\":\"PKCE challenge method must be S256\",\"code\":\"code_challenge_method_invalid\"}")
        }
        guard codeChallenge.wholeMatch(of: /^[A-Za-z0-9_-]{43}$/) != nil else {
            return Self.json(400, "{\"error\":\"PKCE challenge is invalid\",\"code\":\"code_challenge_invalid\"}")
        }
        let requestId = UUID().uuidString.lowercased()
        let expiresAt = Self.appLoginExpiresAt()
        lock.lock()
        appLoginRequests[requestId] = AppLoginRequest(
            id: requestId,
            returnUri: returnUri,
            codeChallenge: codeChallenge,
            status: "pending",
            code: nil,
            userId: nil,
            expiresAt: expiresAt,
            consumedAt: nil
        )
        lock.unlock()
        let loginUrl = "\(appURL)/login/app?request=\(requestId)"
        return Self.json(201, "{\"requestId\":\(jsonString(requestId)),\"loginUrl\":\(jsonString(loginUrl)),\"expiresAt\":\(jsonString(Self.iso8601(expiresAt)))}")
    }

    func appLoginActor(_ authorization: String?) -> String? {
        if case .user(let id) = authorize(authorization) { return id }
        return nil
    }

    func appLoginRequestLocked(_ requestId: String) -> AppLoginRequest? {
        appLoginRequests[requestId]
    }

    /// `GET /api/auth/app-login/requests/:requestId`. Only a signed-in user may read the request.
    public func appLoginDescribe(authorization: String?, requestId: String) -> HTTPReply {
        guard appLoginActor(authorization) != nil else { return Self.invalidToken }
        lock.lock()
        let request = appLoginRequestLocked(requestId)
        lock.unlock()
        guard let request else { return Self.json(404, "{\"error\":\"App login request not found\",\"code\":\"request_not_found\"}") }
        return Self.json(200, "{\"requestId\":\(jsonString(request.id)),\"status\":\(jsonString(request.status)),\"returnUri\":\(jsonString(request.returnUri)),\"expiresAt\":\(jsonString(Self.iso8601(request.expiresAt)))}")
    }

    /// `POST /api/auth/app-login/requests/:requestId/approve`.
    public func appLoginApprove(authorization: String?, requestId: String) -> HTTPReply {
        guard let userId = appLoginActor(authorization) else { return Self.invalidToken }
        let now = Date()
        lock.lock()
        guard var request = appLoginRequestLocked(requestId) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"App login request not found\",\"code\":\"request_not_found\"}")
        }
        if request.expiresAt <= now {
            lock.unlock()
            return Self.json(410, "{\"error\":\"App login request expired\",\"code\":\"request_expired\",\"redirectUrl\":\(jsonString(Self.appLoginRedirect(request.returnUri, requestId: request.id, query: "error=expired")))}")
        }
        guard request.status == "pending" else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"App login request is not pending\",\"code\":\"request_not_pending\"}")
        }
        let code = Self.token()
        request.status = "approved"
        request.code = code
        request.userId = userId
        appLoginRequests[requestId] = request
        lock.unlock()
        let redirectUrl = Self.appLoginRedirect(request.returnUri, requestId: request.id, query: "code=\(code)")
        return Self.json(200, "{\"redirectUrl\":\(jsonString(redirectUrl))}")
    }

    /// `POST /api/auth/app-login/requests/:requestId/deny`.
    public func appLoginDeny(authorization: String?, requestId: String) -> HTTPReply {
        guard appLoginActor(authorization) != nil else { return Self.invalidToken }
        let now = Date()
        lock.lock()
        guard var request = appLoginRequestLocked(requestId) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"App login request not found\",\"code\":\"request_not_found\"}")
        }
        if request.expiresAt <= now {
            lock.unlock()
            return Self.json(410, "{\"error\":\"App login request expired\",\"code\":\"request_expired\",\"redirectUrl\":\(jsonString(Self.appLoginRedirect(request.returnUri, requestId: request.id, query: "error=expired")))}")
        }
        guard request.status == "pending" else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"App login request is not pending\",\"code\":\"request_not_pending\"}")
        }
        request.status = "denied"
        appLoginRequests[requestId] = request
        lock.unlock()
        let redirectUrl = Self.appLoginRedirect(request.returnUri, requestId: request.id, query: "error=access_denied")
        return Self.json(200, "{\"redirectUrl\":\(jsonString(redirectUrl))}")
    }

    /// `POST /api/auth/app-login/complete`. The one-time code is bound to the
    /// request's S256 challenge and request expiry; a wrong verifier does not burn it.
    public func appLoginComplete(body: String) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty,
              let verifier = object["codeVerifier"] as? String, !verifier.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid app login completion\",\"code\":\"invalid_request\"}")
        }
        let now = Date()
        lock.lock()
        guard let request = appLoginRequests.values.first(where: { $0.code == code }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"App login code not found\",\"code\":\"code_not_found\"}")
        }
        if request.consumedAt != nil {
            lock.unlock()
            return Self.json(410, "{\"error\":\"App login code was already used\",\"code\":\"code_consumed\"}")
        }
        if request.expiresAt <= now {
            lock.unlock()
            return Self.json(410, "{\"error\":\"App login code expired\",\"code\":\"code_expired\"}")
        }
        guard Self.pkceS256(verifier) == request.codeChallenge else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"PKCE verifier does not match\",\"code\":\"pkce_mismatch\"}")
        }
        guard let userId = request.userId else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"App login request is not approved\",\"code\":\"request_not_approved\"}")
        }
        var approved = request
        approved.consumedAt = now
        appLoginRequests[approved.id] = approved
        guard let account = accounts.values.first(where: { $0.id == userId }) else {
            lock.unlock()
            return Self.invalidToken
        }
        let issued = openSessionLocked(userId: userId)
        let user = Self.userJSON(account)
        lock.unlock()
        return Self.json(200, "{\"user\":\(user),\"accessToken\":\(jsonString(issued.accessToken)),\"refreshToken\":\(jsonString(issued.refreshToken))}")
    }

    func authenticate(_ request: Request) -> HTTPReply {
        let email = Self.normalize(request.email)
        lock.lock()
        var pendingLink: PendingSocialLink?
        if let token = request.pendingLinkToken, !token.isEmpty {
            guard var pending = pendingSocialLinks[token], !pending.consumed, !pending.cancelled,
                  pending.expiresAt > Date()
            else {
                lock.unlock()
                return Self.json(410, "{\"error\":\"This sign-in link expired. Sign in again to connect the account.\",\"code\":\"pending_link_expired\"}")
            }
            guard pending.email == email else {
                lock.unlock()
                return Self.json(403, "{\"error\":\"The pending link belongs to a different account\",\"code\":\"pending_link_account_mismatch\"}")
            }
            pendingLink = pending
        }
        let account = accounts[email]
        let matches = account.map { $0.passwordHash == Self.sha256(request.password) } ?? false
        guard var accountSnapshot = account, matches, accountSnapshot.retiredAt == nil else {
            lock.unlock()
            return Self.rejected
        }
        if accountSnapshot.passwordCredentialEstablishedAt == nil {
            accountSnapshot.passwordCredentialEstablishedAt = Date()
            accounts[email] = accountSnapshot
        }
        let issued = openSessionLocked(userId: accountSnapshot.id)
        var linkedProviderJSON = "null"
        if var pending = pendingLink {
            pending.consumed = true
            pendingSocialLinks[pending.token] = pending
            if !linkedIdentities.contains(where: {
                $0.userId == accountSnapshot.id && $0.provider == pending.provider && $0.providerUserId == pending.providerUserId
            }) {
                linkedIdentities.append(LinkedIdentity(
                    userId: accountSnapshot.id, provider: pending.provider,
                    providerUserId: pending.providerUserId, providerEmail: pending.email
                ))
            }
            linkedProviderJSON = jsonString(pending.provider)
        }
        let body = "{\"user\":{\"id\":\(jsonString(accountSnapshot.id)),\"email\":\(jsonString(accountSnapshot.email))},\"accessToken\":\(jsonString(issued.accessToken)),\"refreshToken\":\(jsonString(issued.refreshToken)),\"linkedProvider\":\(linkedProviderJSON)}"
        lock.unlock()
        return Self.json(200, body)
    }

    /// `POST /api/auth/me/avatar`. A file over 5 MB is refused before the stored path changes.
    public func uploadAvatar(authorization: String?, contentType: String?, body: Data) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard let file = Self.multipartFile(named: "avatar", contentType: contentType, body: body) else {
            return Self.json(400, "{\"error\":\"No avatar file provided\"}")
        }
        if file.count > Self.maxProfileAvatarBytes {
            return Self.json(400, "{\"error\":\"Avatar image must be 5 MB or smaller\",\"errorCode\":\"PROFILE_AVATAR_TOO_LARGE\",\"maxBytes\":\(Self.maxProfileAvatarBytes)}")
        }
        let hash = String(Self.sha256(file).prefix(32))
        let avatarURL = "/api/avatars/users/\(hash).webp"
        lock.lock()
        guard var account = accounts.values.first(where: { $0.id == userId }) else {
            lock.unlock()
            return Self.invalidToken
        }
        account.avatarUrl = avatarURL
        accounts[account.email] = account
        let snapshot = account
        lock.unlock()
        return Self.json(200, Self.userJSON(snapshot))
    }

    /// `GET /api/auth/me`. The hash is SHA-256 of the stored email, trimmed and lowercased.
    public func me(authorization: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        lock.lock()
        let account = accounts.values.first { $0.id == userId }
        lock.unlock()
        guard let account, account.retiredAt == nil else { return Self.invalidToken }
        var json = Self.userJSON(account)
        lock.lock()
        let observation = timezoneObservations[userId]
        lock.unlock()
        if let observation {
            let extra = String(Self.timezoneJSON(observation).dropFirst())
            if let closing = json.lastIndex(of: "}") {
                json = String(json[..<closing]) + "," + extra
            }
        }
        return Self.json(200, json)
    }

    /// `PATCH /api/auth/me`. A wrong current password is refused before any profile write.
    /// Display language accepts only the shipped UI catalogs, `en` and `zh-cn`.
    public func patch(authorization: String?, body: String) -> HTTPReply {
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
            return Self.json(400, "{\"error\":\"Failed to update profile\"}")
        }

        if let current = object["currentPassword"] as? String, !current.isEmpty,
           let newPassword = object["newPassword"] as? String, !newPassword.isEmpty {
            if newPassword.count < 8 {
                return Self.json(400, "{\"error\":\"New password must be at least 8 characters\"}")
            }
            lock.lock()
            guard var account = accounts.values.first(where: { $0.id == userId }) else {
                lock.unlock()
                return Self.invalidToken
            }
            guard account.passwordHash == Self.sha256(current) else {
                lock.unlock()
                return Self.wrongPassword
            }
            account.passwordHash = Self.sha256(newPassword)
            accounts[account.email] = account
            lock.unlock()
        }

        var languageUpdate: String??
        if object["displayLanguage"] != nil {
            switch Self.parseDisplayLanguage(object["displayLanguage"]!) {
            case .invalid(let message):
                return Self.json(400, "{\"error\":\(jsonString(message))}")
            case .value(let language):
                languageUpdate = language
            }
        } else {
            languageUpdate = nil
        }

        var shareUpdate: Bool?? = nil
        if let raw = object["shareUsageData"] {
            if raw is NSNull {
                shareUpdate = .some(nil)
            } else if let bool = raw as? Bool {
                shareUpdate = .some(bool)
            } else {
                return Self.json(400, "{\"error\":\"shareUsageData must be a boolean or null\"}")
            }
        }

        var languagePreference: String?? = nil
        if let raw = object["preferredLanguage"] {
            if raw is NSNull {
                languagePreference = .some(nil)
            } else if let value = raw as? String,
                      value.wholeMatch(of: /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/) != nil {
                languagePreference = .some(value.lowercased())
            } else {
                return Self.json(400, "{\"error\":\"Unsupported preferredLanguage\"}")
            }
        }
        var timezonePreference: String?? = nil
        if let raw = object["preferredTimezone"] {
            if raw is NSNull {
                timezonePreference = .some(nil)
            } else if let value = raw as? String, TimeZone(identifier: value) != nil {
                timezonePreference = .some(value)
            } else {
                return Self.json(400, "{\"error\":\"Invalid preferredTimezone\"}")
            }
        }
        var modePreference: String? = nil
        if let raw = object["preferredTranslationMode"] {
            guard let value = raw as? String, ["off", "manual", "auto"].contains(value) else {
                return Self.json(400, "{\"error\":\"Invalid preferredTranslationMode\"}")
            }
            modePreference = value
        }
        var autoPreference: Bool? = nil
        if let raw = object["autoTranslationEnabled"] {
            guard let value = raw as? Bool else {
                return Self.json(400, "{\"error\":\"Invalid autoTranslationEnabled\"}")
            }
            autoPreference = value
        }
        var displayPreference: String? = nil
        if let raw = object["preferredTranslationDisplay"] {
            guard let value = raw as? String, ["translated", "bilingual", "original"].contains(value) else {
                return Self.json(400, "{\"error\":\"Invalid preferredTranslationDisplay\"}")
            }
            displayPreference = value
        }
        var timeFormatPreference: String?? = nil
        if let raw = object["preferredTimeFormat"] {
            if raw is NSNull {
                timeFormatPreference = .some(nil)
            } else if let value = raw as? String, ["12h", "24h"].contains(value.lowercased()) {
                timeFormatPreference = .some(value.lowercased())
            } else {
                return Self.json(400, "{\"error\":\"Invalid preferredTimeFormat\"}")
            }
        }
        var fontSizePreference: String?? = nil
        if let raw = object["preferredMessageBodyFontSize"] {
            if raw is NSNull {
                fontSizePreference = .some(nil)
            } else if let value = raw as? String, ["sm", "md", "lg", "xl"].contains(value.lowercased()) {
                fontSizePreference = .some(value.lowercased())
            } else {
                return Self.json(400, "{\"error\":\"Invalid preferredMessageBodyFontSize\"}")
            }
        }

        var referralSourceUpdate: String?? = nil
        var referralOtherUpdate: String?? = nil
        var referralSkipped = false
        if let raw = object["referralSource"] {
            if raw is NSNull {
                referralSourceUpdate = .some(nil)
                referralOtherUpdate = .some(nil)
            } else if let value = raw as? String,
                      ["twitter_x", "linkedin", "friend_colleague", "search", "hn_reddit", "podcast_blog_newsletter", "other"].contains(value) {
                referralSourceUpdate = .some(value)
                if value == "other", let other = object["referralSourceOther"] as? String {
                    let trimmed = String(other.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                    referralOtherUpdate = .some(trimmed.isEmpty ? nil : trimmed)
                } else {
                    referralOtherUpdate = .some(nil)
                }
            } else {
                return Self.json(400, "{\"error\":\"Invalid referralSource\"}")
            }
        } else if object["referralSourceOther"] != nil {
            return Self.json(400, "{\"error\":\"referralSource is required when referralSourceOther is provided\"}")
        }
        if let raw = object["referralSourceSkipped"] {
            guard let value = raw as? Bool else {
                return Self.json(400, "{\"error\":\"referralSourceSkipped must be a boolean\"}")
            }
            referralSkipped = value
        }

        lock.lock()
        guard var account = accounts.values.first(where: { $0.id == userId }) else {
            lock.unlock()
            return Self.invalidToken
        }
        var changed = false
        if let value = referralSourceUpdate {
            account.referralSource = value
            account.referralSourceSkippedAt = nil
            changed = true
        }
        if let value = referralOtherUpdate {
            account.referralSourceOther = value
            changed = true
        }
        if referralSkipped {
            account.referralSourceSkippedAt = Date()
            changed = true
        }
        if let value = languagePreference { account.preferredLanguage = value; changed = true }
        if let value = timezonePreference { account.preferredTimezone = value; changed = true }
        if let value = modePreference { account.preferredTranslationMode = value; changed = true }
        if let value = autoPreference { account.autoTranslationEnabled = value; changed = true }
        if let value = displayPreference { account.preferredTranslationDisplay = value; changed = true }
        if let value = timeFormatPreference { account.preferredTimeFormat = value; changed = true }
        if let value = fontSizePreference { account.preferredMessageBodyFontSize = value; changed = true }
        if let language = languageUpdate {
            account.displayLanguage = language
            changed = true
        }
        if let share = shareUpdate {
            account.shareUsageData = share
            if share == true {
                if analyticsIds[account.id] == nil {
                    analyticsIds[account.id] = UUID().uuidString.lowercased()
                }
            } else if share == false {
                analyticsIds.removeValue(forKey: account.id)
            }
            changed = true
        }
        if changed {
            accounts[account.email] = account
        }
        let snapshot = account
        lock.unlock()
        return Self.json(200, Self.userJSON(snapshot))
    }

}
