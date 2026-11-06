import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: Directory helpers

/// Locale, slug, social/Apple token and model helpers shared by the services.
extension EmailLoginDirectory {

    /// Shipped UI catalogs only. Region tags collapse inside `en` and `zh-cn`; `zh-TW` and `fr` do not.
    static func normalizeDisplayLocale(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return nil }
        if value == "en" || value.hasPrefix("en-") { return "en" }
        if value == "zh-cn" || value == "zh" || value == "zh-hans" || value == "zh-hans-cn" { return "zh-cn" }
        return nil
    }



    static let reservedAgentNames: Set<String> = [
        "all", "human", "humans", "agent", "agents", "here", "idle", "busy", "system", "reminders",
    ]

    /// Final handles stay unclaimed until profile setup. The stored name is `pending_` plus 20 hex characters.
    static func pendingHandle(taken: Set<String>) -> String {
        for _ in 0..<10 {
            let handle = "pending_\(randomHex(10))"
            if !taken.contains(handle) { return handle }
        }
        return "pending_\(randomHex(10))"
    }

    static func slugifyUserName(_ seed: String) -> String {
        let lowered = seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var normalized = ""
        for scalar in lowered.unicodeScalars {
            let value = scalar.value
            let allowed = (value >= 97 && value <= 122) || (value >= 48 && value <= 57) || value == 95 || value == 45
            normalized.append(allowed ? Character(scalar) : "-")
        }
        normalized = trimHyphens(normalized)
        let prefixed = normalized.first?.isLetter == true ? normalized : "user-\(normalized)"
        var compact = ""
        var previousHyphen = false
        for character in prefixed {
            if character == "-" {
                if previousHyphen { continue }
                previousHyphen = true
            } else {
                previousHyphen = false
            }
            compact.append(character)
        }
        compact = trimHyphens(compact)
        let fallback = compact.isEmpty ? "user-account" : compact
        return fallback.count >= 5 ? fallback : "\(fallback)-user"
    }

    static func availableUserName(seed: String, taken: Set<String>) -> String {
        let base = slugifyUserName(seed)
        if !taken.contains(base) { return base }
        for suffix in 1..<100 {
            let candidate = "\(base)-\(suffix + 1)"
            if !taken.contains(candidate) { return candidate }
        }
        return "\(base)-\(randomHex(2))"
    }



    /// `dm:@reminders` names an agent's private reminder conversation, so the handle is reserved.
    static func isReservedAgentName(_ name: String) -> Bool {
        var normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("@") { normalized.removeFirst() }
        return reservedAgentNames.contains(normalized.lowercased())
    }


    static let maxProfileAvatarBytes = 5 * 1024 * 1024

    public static func sha256Hex(_ value: String) -> String {
        sha256(value)
    }





    static func refreshAttempt(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^arf_[0-9a-f]{16}$/) != nil else { return nil }
        return trimmed
    }

    static func refreshInstallation(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^ari_[0-9a-f]{32}$/) != nil else { return nil }
        return trimmed
    }

    public static func signSocialAuthState(_ state: SocialAuthState) -> String {
        let header = base64url(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8))
        var payload: [String: Any] = [
            "provider": state.provider,
            "mode": state.mode,
            "nonce": state.nonce,
            "kind": state.kind,
            "mobileRequestId": state.mobileRequestId,
            "iss": "slock-social-auth",
            "aud": "social-auth-state",
            "exp": Int(Date().timeIntervalSince1970) + 600,
        ]
        if let desktopNonce = state.desktopNonce {
            payload["desktopNonce"] = desktopNonce
        }
        if let returnTo = state.returnTo {
            payload["returnTo"] = returnTo
        }
        if let linkUserId = state.linkUserId {
            payload["linkUserId"] = linkUserId
        }
        if state.linkOnConflict {
            payload["linkOnConflict"] = true
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let body = base64url(encoded)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("\(header).\(body)".utf8), using: stateKey))
        return "\(header).\(body).\(base64url(mac))"
    }

    public static func verifySocialAuthState(_ token: String) -> SocialAuthState? {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3 else { return nil }
        let signing = Data("\(parts[0]).\(parts[1])".utf8)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: signing, using: stateKey))
        guard let given = base64urlDecode(parts[2]), given == expected else { return nil }
        guard let payload = base64urlDecode(parts[1]),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let provider = object["provider"] as? String,
              let mode = object["mode"] as? String,
              let nonce = object["nonce"] as? String,
              let kind = object["kind"] as? String,
              let requestId = object["mobileRequestId"] as? String,
              (object["iss"] as? String) == "slock-social-auth",
              (object["aud"] as? String) == "social-auth-state"
        else { return nil }
        let exp = (object["exp"] as? NSNumber)?.intValue ?? (object["exp"] as? Int) ?? 0
        if exp < Int(Date().timeIntervalSince1970) { return nil }
        return SocialAuthState(
            provider: provider,
            mode: mode,
            nonce: nonce,
            kind: kind,
            mobileRequestId: requestId,
            desktopNonce: object["desktopNonce"] as? String,
            returnTo: object["returnTo"] as? String,
            linkUserId: object["linkUserId"] as? String,
            linkOnConflict: object["linkOnConflict"] as? Bool ?? false
        )
    }

    static let stateKey = SymmetricKey(data: Data(SHA256.hash(data: Data("slock-social-auth-state".utf8))))











    func verifyMobileAppEmailUnsubscribeToken(_ token: String) -> (userId: String, locale: String)? {
        guard !token.isEmpty, token.count <= 512 else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let expected = Self.mobileAppUnsubscribeSignature(payload: parts[0], secret: mobileAppEmailUnsubscribeSecret)
        guard parts[1] == expected else { return nil }
        guard let data = Self.base64urlDecode(parts[0]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.sorted().joined(separator: ",") == "locale,sub,typ,v"
        else { return nil }
        let version = (object["v"] as? NSNumber)?.intValue ?? (object["v"] as? Int)
        guard version == 1,
              (object["typ"] as? String) == "mobile-app-email-unsubscribe",
              let userId = object["sub"] as? String,
              Self.isMobileUnsubscribeUserId(userId),
              let locale = object["locale"] as? String,
              locale == "en" || locale == "zh-cn"
        else { return nil }
        return (userId, locale)
    }

    /// `GET /api/email/mobile-app/unsubscribe`. A valid token shows the confirmation page and writes nothing.
    public func mobileAppEmailUnsubscribePage(token: String?) -> HTTPReply {
        guard let token, let identity = verifyMobileAppEmailUnsubscribeToken(token) else {
            return Self.mobileAppUnsubscribeInvalid()
        }
        let copy = Self.mobileAppUnsubscribeCopy(identity.locale)
        let action = "/api/email/mobile-app/unsubscribe?token=\(Self.urlQuery(token))&source=visible"
        let body = "<h1 style=\"margin:0 0 12px;font-size:22px;\">\(copy.confirmationHeading)</h1><p style=\"margin:0 0 20px;line-height:1.5;\">\(copy.confirmationBody)</p><form method=\"post\" action=\"\(action)\"><input type=\"hidden\" name=\"List-Unsubscribe\" value=\"One-Click\"><button type=\"submit\" style=\"cursor:pointer;padding:10px 16px;border:2px solid #141111;border-radius:8px;background:#fe7da8;color:#141111;font:inherit;font-weight:700;box-shadow:2px 2px 0 #141111;\">\(copy.submit)</button></form>"
        return Self.mobileAppUnsubscribeHTML(lang: copy.htmlLang, title: copy.confirmationTitle, body: body)
    }

    /// `POST /api/email/mobile-app/unsubscribe`. One-click is an empty 200. A visible submit is the success page.
    public func mobileAppEmailUnsubscribeSubmit(token: String?, source: String?, body: String) -> HTTPReply {
        guard let token, let identity = verifyMobileAppEmailUnsubscribeToken(token),
              Self.formField(body, "List-Unsubscribe") == "One-Click"
        else { return Self.mobileAppUnsubscribeInvalid() }
        recordMobileAppEmailOptOut(userId: identity.userId)
        let copy = Self.mobileAppUnsubscribeCopy(identity.locale)
        if source == "visible" {
            let page = "<h1 style=\"margin:0 0 12px;font-size:22px;\">\(copy.successHeading)</h1><p style=\"margin:0;line-height:1.5;\">\(copy.successBody)</p>"
            return Self.mobileAppUnsubscribeHTML(lang: copy.htmlLang, title: copy.successTitle, body: page)
        }
        return Self.text(200, "")
    }

    func recordMobileAppEmailOptOut(userId: String) {
        lock.lock()
        guard let account = accounts.values.first(where: { $0.id == userId }) else {
            lock.unlock()
            return
        }
        let email = Self.normalize(account.email)
        guard !email.isEmpty else {
            lock.unlock()
            return
        }
        let audienceId = "mobile-app-lifecycle"
        mobileAppEmailContactsByKey["\(audienceId)\n\(email)"] = MobileAppEmailContact(
            userId: userId,
            email: email,
            audienceId: audienceId,
            status: "unsubscribed",
            optedOutAt: Date()
        )
        let emailIds = storedMobileAppEmailJourneys.compactMap { row -> String? in
            guard row.journeyKey == "first_computer_mobile_app_48h",
                  row.day1Status == "scheduled",
                  let emailId = row.day1EmailId,
                  !emailId.isEmpty,
                  row.userId == userId || Self.normalize(row.email) == email
            else { return nil }
            return emailId
        }
        let cancel = cancelMobileAppEmail
        lock.unlock()
        for emailId in emailIds {
            cancel?(emailId)
        }
        guard !emailIds.isEmpty else { return }
        lock.lock()
        let canceledAt = Date()
        for index in storedMobileAppEmailJourneys.indices {
            let row = storedMobileAppEmailJourneys[index]
            guard row.journeyKey == "first_computer_mobile_app_48h",
                  row.day1Status == "scheduled",
                  let emailId = row.day1EmailId,
                  emailIds.contains(emailId),
                  row.userId == userId || Self.normalize(row.email) == email
            else { continue }
            storedMobileAppEmailJourneys[index].day1Status = "skipped"
            storedMobileAppEmailJourneys[index].suppressedReason = "unsubscribed"
            storedMobileAppEmailJourneys[index].canceledAt = canceledAt
        }
        lock.unlock()
    }











    static let appleNotConfigured = json(404, "{\"code\":\"provider_not_configured\",\"error\":\"Apple sign-in is not configured\"}")
    static let nativeAppleInvalidRequest = json(400, "{\"code\":\"invalid_request\",\"error\":\"Native Apple sign-in requires the iOS platform and app environment\"}")
    static let nativeAppleInvalidCredential = json(400, "{\"code\":\"native_apple_invalid_credential\",\"error\":\"Apple sign-in credential was invalid\"}")
    static let nativeAppleAuthRequired = json(401, "{\"code\":\"auth_required\",\"error\":\"Apple account linking requires authentication\"}")
    static let nativeAppleLinkMismatch = json(403, "{\"code\":\"link_user_mismatch\",\"error\":\"Apple account linking does not match the authenticated user\"}")
    static let nativeAppleRequestExpired = json(410, "{\"code\":\"native_apple_request_expired\",\"error\":\"Apple sign-in request expired\"}")
    static let nativeAppleRequestConsumed = json(410, "{\"code\":\"native_apple_request_consumed\",\"error\":\"Apple sign-in request was already used\"}")




    func nativeAppleAvailable() -> Bool {
        lock.lock()
        let configured = !nativeAppleClientId.isEmpty && !nativeAppleClientSecret.isEmpty
        let gate = appleLoginPlatforms.contains("mobile")
        lock.unlock()
        return configured && gate
    }

    public static func signNativeAppleRequestToken(secret: String, requestId: String, mode: String, codeChallenge: String, expiresAt: Date, userId: String? = nil) -> String {
        let header = base64url(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8))
        var payload: [String: Any] = [
            "kind": "native_apple_ios",
            "requestId": requestId,
            "mode": mode,
            "codeChallenge": codeChallenge,
            "iss": "slock-native-apple-auth",
            "aud": "native-apple-auth-request",
            "exp": Int(expiresAt.timeIntervalSince1970),
        ]
        if let userId { payload["userId"] = userId }
        let encoded = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let body = base64url(encoded)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("\(header).\(body)".utf8), using: key))
        return "\(header).\(body).\(base64url(mac))"
    }


    func parseAppleIdentity(_ token: String) -> AppleIdentityClaims? {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let headerData = Self.base64urlDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let payloadData = Self.base64urlDecode(parts[1]),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              object["iss"] as? String == "https://appleid.apple.com",
              object["aud"] as? String == nativeAppleClientId,
              let subject = object["sub"] as? String, !subject.isEmpty,
              let nonce = object["nonce"] as? String, !nonce.isEmpty
        else { return nil }
        let exp = (object["exp"] as? NSNumber)?.intValue ?? (object["exp"] as? Int) ?? 0
        if exp < Int(Date().timeIntervalSince1970) { return nil }
        let rawEmail = (object["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if rawEmail.isEmpty {
            return AppleIdentityClaims(subject: subject, nonce: nonce, email: nil)
        }
        let verified: Bool
        if let flag = object["email_verified"] as? Bool {
            verified = flag
        } else if let flag = object["email_verified"] as? String {
            verified = flag == "true"
        } else {
            verified = false
        }
        guard verified else { return nil }
        return AppleIdentityClaims(subject: subject, nonce: nonce, email: rawEmail)
    }

    func mobileAppleAvailable() -> Bool {
        lock.lock()
        let configured = configuredSocialAuthProviders.contains("apple")
        let allowed = appleLoginPlatforms.contains("mobile")
        lock.unlock()
        return configured && allowed
    }

    func webProviderAvailable(_ provider: String) -> Bool {
        lock.lock()
        let configured = configuredSocialAuthProviders.contains(provider)
        let allowed = appleLoginPlatforms.contains("web")
        lock.unlock()
        guard configured else { return false }
        if provider == "apple" { return allowed }
        return true
    }

    func webAuthorizationURL(provider: String, state: String, nonce: String) -> String {
        guard provider == "apple" else {
            return Self.authorizationURL(provider: provider, state: state)
        }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        var components = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appleClientId),
            URLQueryItem(name: "redirect_uri", value: "\(base)/api/auth/apple/callback"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "form_post"),
            URLQueryItem(name: "scope", value: "email"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        return components.string ?? ""
    }

    func stateCookie(provider: String, nonce: String) -> String {
        let encoded = nonce.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? nonce
        var parts = [
            "slock_\(provider)_oauth_nonce=\(encoded)",
            "Path=/api/auth/\(provider)/callback",
            "Max-Age=600",
            "HttpOnly",
            "SameSite=\(provider == "apple" ? "None" : "Lax")",
        ]
        if provider == "apple" || serverURL.hasPrefix("https://") {
            parts.append("Secure")
        }
        return parts.joined(separator: "; ")
    }

    // MARK: - Agent credential and grant projections (legacy)

    // The decisions live in `FeedbackLocatorService`; these untyped HTTP
    // projections stay only for the agent-API handlers that have not moved to
    // the typed service yet. Each body is the service error's exact bytes.

    func agentCapabilityDenial(_ authorization: String?, required: String) -> HTTPReply? {
        let service = FeedbackLocatorService(directory: self)
        switch service.capabilityDecision(authorization: authorization, capability: required) {
        case .allowed:
            return nil
        case .denied(let capability):
            return Self.json(
                403,
                FeedbackLocatorError.capabilityNotAuthorized(capability: capability)
                    .publishedErrorBody.render()
            )
        }
    }

    func agentGrantDenial(agentId: String, scope: String) -> HTTPReply? {
        let service = FeedbackLocatorService(directory: self)
        switch service.grantDecision(agentId: agentId, scope: scope) {
        case .allowed:
            return nil
        case .missingScope(let scope):
            return Self.json(
                403,
                FeedbackLocatorError.missingScope(scope: scope).publishedErrorBody.render()
            )
        }
    }

    func agentCredentialIdentity(
        authorization: String?,
        capability: String
    ) -> (agentId: String, serverId: String)? {
        switch FeedbackLocatorService(directory: self)
            .identityResolution(authorization: authorization, capability: capability) {
        case .success(let agentId, let serverId):
            return (agentId: agentId, serverId: serverId)
        case .missingAuthorization, .invalidAccessToken, .capabilityNotAuthorized,
             .invalidAgentCredential:
            return nil
        }
    }

    func agentCredentialScopes(authorization: String?) -> [String]? {
        FeedbackLocatorService(directory: self).credentialScopes(authorization: authorization)
    }

    func feedbackLocatorIdentity(
        authorization: String?,
        capability: String
    ) -> FeedbackLocatorIdentityResult {
        switch FeedbackLocatorService(directory: self)
            .identityResolution(authorization: authorization, capability: capability) {
        case .success(let agentId, let serverId):
            return .success(agentId: agentId, serverId: serverId)
        case .missingAuthorization:
            return .refused(Self.json(
                401,
                FeedbackLocatorError.missingAuthorization.publishedErrorBody.render()
            ))
        case .invalidAccessToken:
            return .refused(Self.json(
                401,
                FeedbackLocatorError.invalidAccessToken.publishedErrorBody.render()
            ))
        case .capabilityNotAuthorized(let capability):
            return .refused(Self.json(
                403,
                FeedbackLocatorError.capabilityNotAuthorized(capability: capability)
                    .publishedErrorBody.render()
            ))
        case .invalidAgentCredential:
            return .refused(Self.json(
                401,
                FeedbackLocatorError.invalidAgentCredential.publishedErrorBody.render()
            ))
        }
    }








}

/// One stored agent runtime profile row: the machine it runs on plus any
/// pending migration release state. The delete-machine path treats these as
/// the authority on which Computers may still be removed.
public struct AgentRuntimeProfileFact: Sendable, Equatable {
    public var agentId: String
    public var machineId: String
    public var baselineMachineId: String?
    public var pendingBeforeMachineId: String?
    public var pendingAfterMachineId: String?
    public var migrationStatus: String?
    public var pendingKind: String?
    public var pendingReleaseNotesUrl: String?

    public init(
        agentId: String,
        machineId: String,
        baselineMachineId: String? = nil,
        pendingBeforeMachineId: String? = nil,
        pendingAfterMachineId: String? = nil,
        migrationStatus: String? = nil,
        pendingKind: String? = nil,
        pendingReleaseNotesUrl: String? = nil
    ) {
        self.agentId = agentId
        self.machineId = machineId
        self.baselineMachineId = baselineMachineId
        self.pendingBeforeMachineId = pendingBeforeMachineId
        self.pendingAfterMachineId = pendingAfterMachineId
        self.migrationStatus = migrationStatus
        self.pendingKind = pendingKind
        self.pendingReleaseNotesUrl = pendingReleaseNotesUrl
    }
}

/// Outcome of a target-side agent start attempt during migration arrival.
public enum MachineMigrationAgentStartOutcome: Sendable, Equatable {
    /// The daemon accepted the launch; the migration completes.
    case dispatched
    /// A gate (for example a held wake lock) suppressed the launch; the
    /// migration stays in `starting` so the arrival callback can retry.
    case skipped(String)
}

/// Outcome of an agent start dispatch (for example a resume-all prompt).
public enum AgentStartDispatchOutcome: Sendable, Equatable {
    /// The daemon accepted the start and will run the agent.
    case dispatched
    /// A gate (for example a held wake lock) suppressed the start.
    case skipped(String)
}

/// Outcome of the Built-in model catalog check for a target Computer.
public enum BuiltinModelCatalogResult: Sendable, Equatable {
    case supported
    case modelAbsent
    case catalogUnavailable
}

/// Result of one machine-backed agent surface read.
public enum AgentSurfaceResult: Sendable, Equatable {
    case ok(String)
    case machineUnassigned
    case machineOffline
    case machineTimeout
}

/// A code-shaped source-archive failure reported by the source Computer.
public struct MachineMigrationArchiveFailure: Error, Sendable, Equatable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

/// Test-observable mirror of the in-memory machine migration row.
public struct MachineMigrationStateSnapshot: Sendable, Equatable {
    public var state: String
    public var revision: Int
    public var agentId: String
    public var sourceMachineId: String
    public var targetMachineId: String
    public var transportGeneration: String
    public var flippedAt: Date?
    public var arrivedAt: Date?
    public var completedAt: Date?
    public var updatedAt: Date
    public var failureReason: String?
    public var transportErrorCode: String?
    public var transportErrorMessage: String?
    public var autoStartFailureStage: String?
    public var autoStartFailureCode: String?
    public var sourceWorkspaceArchivedAt: Date?
    public var sourceWorkspaceArchiveAttempts: Int
    public var sourceWorkspaceArchiveLastError: String?
    public var sourceWorkspaceArchiveRetryAt: Date?
    public var sourceWorkspaceArchiveAbandonedAt: Date?
    public var cancelDisposition: String?
    public var cancelSourceAck: String?
    public var cancelTargetAck: String?
    public var cancelSourceAckAt: Date?
    public var cancelTargetAckAt: Date?
    public var canceledAt: Date?
    public var transportTeardownAt: Date?
}

/// One agent migration row. Terminal rows stay behind as history after the
/// source Computer is deleted.
public struct AgentMigrationFact: Sendable, Equatable {
    public var agentId: String
    public var sourceMachineId: String
    public var targetMachineId: String
    public var state: String

    public init(agentId: String, sourceMachineId: String, targetMachineId: String, state: String) {
        self.agentId = agentId
        self.sourceMachineId = sourceMachineId
        self.targetMachineId = targetMachineId
        self.state = state
    }
}

/// One probed runtime model with its optional reasoning metadata.
public struct RuntimeModelProbeModel: Sendable, Equatable {
    public var id: String
    public var label: String
    public var supportedReasoningEfforts: [String]?
    public var defaultReasoningEffort: String?

    public init(
        id: String,
        label: String,
        supportedReasoningEfforts: [String]? = nil,
        defaultReasoningEffort: String? = nil
    ) {
        self.id = id
        self.label = label
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

/// The Computer's answer to a runtime model probe.
public enum RuntimeModelProbeOutcome: Sendable, Equatable {
    case live(models: [RuntimeModelProbeModel], default: String?)
    case models(models: [RuntimeModelProbeModel], default: String?)
    case missingConfig
    case noModels
    case unsupported
    case error(code: String, retryable: Bool)
    case failed
}

/// One agent (runner) thread follow row.
public struct AgentThreadFollowRecord: Sendable, Equatable {
    public var serverId: String
    public var agentId: String
    public var threadChannelId: String
    public var parentMessageId: String
    public var followedAt: Date
    public var reason: String
    public var doneAt: Date?
    public var unfollowedAt: Date?

    public init(
        serverId: String,
        agentId: String,
        threadChannelId: String,
        parentMessageId: String,
        followedAt: Date,
        reason: String,
        doneAt: Date? = nil,
        unfollowedAt: Date? = nil
    ) {
        self.serverId = serverId
        self.agentId = agentId
        self.threadChannelId = threadChannelId
        self.parentMessageId = parentMessageId
        self.followedAt = followedAt
        self.reason = reason
        self.doneAt = doneAt
        self.unfollowedAt = unfollowedAt
    }
}

/// One agent login into a server integration service.
public struct AgentIntegrationLoginRecord: Sendable, Equatable {
    public var serverId: String
    public var agentId: String
    public var clientId: String
    public var scopes: [String]
    public var loggedInAt: Date

    public init(serverId: String, agentId: String, clientId: String, scopes: [String], loggedInAt: Date) {
        self.serverId = serverId
        self.agentId = agentId
        self.clientId = clientId
        self.scopes = scopes
        self.loggedInAt = loggedInAt
    }
}

/// One attachment comment row.
public struct AttachmentCommentRecord: Sendable, Equatable {
    public var id: String
    public var attachmentId: String
    public var content: String
    public var anchorJSON: String?
    public var senderId: String
    public var senderType: String
    public var createdAt: Date
    public var threadChannelId: String?
    public var hostMessageId: String?
    public var hostChannelId: String?

    public init(
        id: String,
        attachmentId: String,
        content: String,
        anchorJSON: String?,
        senderId: String,
        senderType: String,
        createdAt: Date,
        threadChannelId: String? = nil,
        hostMessageId: String? = nil,
        hostChannelId: String? = nil
    ) {
        self.id = id
        self.attachmentId = attachmentId
        self.content = content
        self.anchorJSON = anchorJSON
        self.senderId = senderId
        self.senderType = senderType
        self.createdAt = createdAt
        self.threadChannelId = threadChannelId
        self.hostMessageId = hostMessageId
        self.hostChannelId = hostChannelId
    }
}
