import Crypto
import Foundation
import RaftShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif


/// Typed facade over the email/password session core: login, refresh rotation,
/// logout, device grants and the test seams around them.
///
/// The state transitions stay on `EmailLoginDirectory` with unchanged
/// signatures, so every existing caller and test compiles untouched. This type
/// exists so a route can hand over a decoded request DTO instead of a JSON
/// string, and so the domain has a `Service` boundary of its own.
public struct AuthCoreService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    /// `POST /api/auth/login`.
    public func login(_ body: LoginRequestDTO) -> HTTPReply {
        directory.login(body: body.encodedBody())
    }

    /// `POST /api/auth/refresh`. The replay-binding identifiers stay headers.
    public func refresh(
        _ body: RefreshRequestDTO,
        attemptHeader: String?,
        installationHeader: String?
    ) -> HTTPReply {
        directory.refresh(
            body: body.encodedBody(),
            attemptHeader: attemptHeader,
            installationHeader: installationHeader
        )
    }

    /// `POST /api/auth/logout`.
    public func logout(_ body: LogoutRequestDTO) -> HTTPReply {
        directory.logout(body: body.encodedBody())
    }

    /// `POST /api/auth/device/authorize`.
    public func authorizeDevice(_ body: DeviceAuthorizeRequestDTO) -> HTTPReply {
        directory.authorizeDevice(body: body.encodedBody())
    }

    /// `POST /api/auth/device/approve`.
    public func approveDevice(_ body: DeviceApproveRequestDTO, authorization: String?) -> HTTPReply {
        directory.approveDevice(body: body.encodedBody(), authorization: authorization)
    }

    /// `POST /api/auth/device/token`.
    public func pollDeviceToken(_ body: DeviceTokenPollRequestDTO) -> HTTPReply {
        directory.pollDeviceToken(body: body.encodedBody())
    }
}

extension EmailLoginDirectory {


    public func markPasswordCredentialEstablished(userId: String) {
        lock.lock()
        if let key = accounts.first(where: { $0.value.id == userId })?.key {
            var account = accounts[key]!
            account.passwordCredentialEstablishedAt = Date()
            accounts[key] = account
        }
        lock.unlock()
    }

    public func hasAccount(email: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accounts[Self.normalize(email)] != nil
    }

    public func legalAcceptance(userId: String) -> EmailLegalAcceptance? {
        lock.lock()
        defer { lock.unlock() }
        return authProfileStore.legalAcceptance(userId: userId)
    }

    public func userId(forEmail email: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return accounts[Self.normalize(email)]?.id
    }

    /// A provider callback already exchanged. The raw code is what `POST /:provider/complete` spends.

    public func addSocialCompletion(
        provider: String,
        code: String,
        email: String,
        mode: String = "login",
        intendedAction: String = "login",
        returnTo: String = "/",
        userId: String? = nil,
        providerUserId: String? = nil,
        linkOnConflict: Bool = false
    ) {
        lock.lock()
        socialCompletions.append(SocialCompletion(
            provider: provider,
            code: code,
            mode: mode,
            intendedAction: intendedAction,
            email: Self.normalize(email),
            returnTo: returnTo,
            userId: userId,
            providerUserId: providerUserId,
            linkOnConflict: linkOnConflict
        ))
        lock.unlock()
    }

    public func linkedProviderUserIds(userId: String, provider: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return linkedIdentities.filter { $0.userId == userId && $0.provider == provider }.map(\.providerUserId)
    }

    public func linkedProviderEmail(userId: String, provider: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return linkedIdentities.first { $0.userId == userId && $0.provider == provider }?.providerEmail
    }

    /// `POST /api/auth/:provider/complete`. A first login checks legal acceptance before the code is spent.
    public func completeSocial(
        provider: String,
        body: String,
        userAgent: String?,
        acceptLanguage: String?,
        authorization: String? = nil
    ) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.json(400, "{\"error\":\"Sign-in completion code is required\"}")
        }
        guard let code = object["code"] as? String, !code.isEmpty else {
            return Self.json(400, "{\"error\":\"Sign-in completion code is required\"}")
        }
        lock.lock()
        guard let index = socialCompletions.firstIndex(where: { $0.provider == provider && $0.code == code }) else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid or expired social auth completion\"}")
        }
        let completion = socialCompletions[index]
        if completion.mode == "link" {
            guard let authorization, authorization.hasPrefix("Bearer ") else {
                lock.unlock()
                return Self.linkAuthRequired
            }
            let token = String(authorization.dropFirst("Bearer ".count))
            guard let caller = accessTokens[token] else {
                lock.unlock()
                return Self.linkAuthRequired
            }
            guard completion.userId == caller else {
                lock.unlock()
                return Self.linkMismatch
            }
            socialCompletions.remove(at: index)
            let providerUserId = completion.providerUserId ?? ""
            if !linkedIdentities.contains(where: {
                $0.userId == caller && $0.provider == provider && $0.providerUserId == providerUserId
            }) {
                linkedIdentities.append(LinkedIdentity(
                    userId: caller,
                    provider: provider,
                    providerUserId: providerUserId
                ))
            }
            let rows = linkedIdentities.filter { $0.userId == caller }
            lock.unlock()
            let listed = rows.map {
                "{\"provider\":\(jsonString($0.provider)),\"providerUserId\":\(jsonString($0.providerUserId))}"
            }.joined(separator: ",")
            let linked = "{\"provider\":\(jsonString(provider)),\"mode\":\"link\",\"returnTo\":\(jsonString(completion.returnTo)),\"identities\":[\(listed)]}"
            return Self.json(200, linked)
        }
        if let rawToken = object["pendingLinkToken"] as? String, !rawToken.isEmpty {
            guard var pending = pendingSocialLinks[rawToken], !pending.consumed, !pending.cancelled,
                  pending.expiresAt > Date()
            else {
                lock.unlock()
                return Self.json(410, "{\"error\":\"This sign-in link expired. Sign in again to connect the account.\",\"code\":\"pending_link_expired\"}")
            }
            let identityOwner = linkedIdentities.first {
                $0.provider == provider && $0.providerUserId == (completion.providerUserId ?? "")
            }?.userId
            let pendingOwner = accounts[pending.email]?.id
            guard let identityOwner, identityOwner == pendingOwner else {
                lock.unlock()
                return Self.json(403, "{\"error\":\"The pending link belongs to a different account\",\"code\":\"pending_link_account_mismatch\"}")
            }
            pending.consumed = true
            pendingSocialLinks[rawToken] = pending
            if !linkedIdentities.contains(where: {
                $0.userId == identityOwner && $0.provider == pending.provider && $0.providerUserId == pending.providerUserId
            }) {
                linkedIdentities.append(LinkedIdentity(
                    userId: identityOwner, provider: pending.provider,
                    providerUserId: pending.providerUserId, providerEmail: pending.email
                ))
            }
            socialCompletions.remove(at: index)
            let accessToken = Self.token()
            let refreshToken = Self.token()
            sessions[refreshToken] = LiveSession(userId: identityOwner, familyId: UUID().uuidString.lowercased())
            accessTokens[accessToken] = identityOwner
            lock.unlock()
            return Self.json(200, "{\"provider\":\(jsonString(provider)),\"mode\":\"login\",\"returnTo\":\(jsonString(completion.returnTo)),\"accessToken\":\(jsonString(accessToken)),\"refreshToken\":\(jsonString(refreshToken)),\"linkedProvider\":\(jsonString(pending.provider))}")
        }
        if completion.userId == nil, completion.intendedAction == "link",
           completion.linkOnConflict, let existing = accounts[completion.email] {
            let token = Self.randomHex(32)
            pendingSocialLinks[token] = PendingSocialLink(
                token: token, provider: provider,
                providerUserId: completion.providerUserId ?? "",
                email: completion.email, returnTo: completion.returnTo, returnUri: nil,
                expiresAt: Date().addingTimeInterval(600)
            )
            let linkedProviders = Set(linkedIdentities.filter { $0.userId == existing.id }.map(\.provider)).sorted()
            let providersJSON = linkedProviders.map(jsonString).joined(separator: ",")
            let hasPassword = existing.passwordCredentialEstablishedAt != nil
            let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
            lock.unlock()
            return Self.json(409, "{\"code\":\"account_link_required\",\"pendingLinkToken\":\(jsonString(token)),\"provider\":\(jsonString(provider)),\"email\":\(jsonString(existing.email)),\"expiresAt\":\(jsonString(expiry)),\"signInMethods\":{\"password\":\(hasPassword ? "true" : "false"),\"providers\":[\(providersJSON)]},\"returnTo\":\(jsonString(completion.returnTo))}")
        }
        if completion.mode == "login", completion.userId == nil {
            if object["acceptTerms"] as? Bool != true {
                lock.unlock()
                return Self.legalRequired
            }
            let terms = object["termsVersion"] as? String
            let privacy = object["privacyVersion"] as? String
            if terms != Self.termsVersion || privacy != Self.privacyVersion {
                lock.unlock()
                return Self.termsChanged
            }
        }
        socialCompletions.remove(at: index)
        let id = completion.userId ?? UUID().uuidString.lowercased()
        let taken = Set(accounts.values.map(\.name))
        let pendingName = Self.pendingHandle(taken: taken)
        let suggested = Self.availableUserName(
            seed: String(completion.email.split(separator: "@").first ?? "user"),
            taken: taken
        )
        if completion.userId == nil, accounts[completion.email] != nil {
            lock.unlock()
            return Self.json(409, "{\"error\":\"An account with this email already exists. Sign in with email and password first, then connect \(provider) in Settings.\"}")
        }
        if completion.userId == nil {
            accounts[completion.email] = Account(
                id: id,
                email: completion.email,
                passwordHash: Self.sha256(Self.token()),
                displayLanguage: nil,
                name: pendingName,
                profileSetupSuggestedHandle: suggested
            )
            let source = (object["legalAcceptanceSource"] as? String) == "invite" ? "invite" : "oauth"
            authProfileStore.setLegalAcceptance(EmailLegalAcceptance(
                termsVersion: Self.termsVersion,
                privacyVersion: Self.privacyVersion,
                termsUrl: Self.termsURL,
                privacyUrl: Self.privacyURL,
                source: source,
                userAgentHash: userAgent.flatMap { $0.isEmpty ? nil : Self.sha256($0) },
                locale: acceptLanguage
            ), userId: id)
        }
        let accessToken = Self.token()
        let refreshToken = Self.token()
        sessions[refreshToken] = LiveSession(userId: id, familyId: UUID().uuidString.lowercased())
        accessTokens[accessToken] = id
        lock.unlock()
        let response = "{\"provider\":\(jsonString(provider)),\"mode\":\(jsonString(completion.mode)),\"returnTo\":\(jsonString(completion.returnTo)),\"accessToken\":\(jsonString(accessToken)),\"refreshToken\":\(jsonString(refreshToken))}"
        return Self.json(200, response)
    }

    /// `POST /api/auth/register`. A non-string email, password, or name is 400 before any account exists. Missing acceptance is 422. A stale version is 409 and creates no account.
    public func register(body: String, userAgent: String?, acceptLanguage: String?) -> HTTPReply {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.registerInvalid([Issue(path: "", message: "Expected object, received string")])
        }
        var issues: [Issue] = []
        let email = Self.stringField(object["email"], path: "email", into: &issues)
        let password = Self.stringField(object["password"], path: "password", into: &issues)
        if object["name"] != nil {
            _ = Self.stringField(object["name"], path: "name", into: &issues)
        }
        let capability = Self.stagingCapability(object["stagingSelfAccountCapability"], into: &issues)
        guard let email, let password, issues.isEmpty else {
            return Self.registerInvalid(issues)
        }
        if capability != nil {
            let stagingEmail = email.wholeMatch(of: /(?i).*@mail\.build/) != nil
            if releaseBranch != "staging" || !stagingEmail {
                return Self.json(403, "{\"error\":\"Staging self-account registration is unavailable\"}")
            }
        }
        if let name = object["name"] as? String, Self.isReservedAgentName(name) {
            return Self.json(400, "{\"error\":\"This username is reserved. Choose another name.\"}")
        }
        if object["acceptTerms"] as? Bool != true {
            return Self.legalRequired
        }
        let terms = object["termsVersion"] as? String
        let privacy = object["privacyVersion"] as? String
        if terms != Self.termsVersion || privacy != Self.privacyVersion {
            return Self.termsChanged
        }

        let normalized = Self.normalize(email)
        let source = (object["legalAcceptanceSource"] as? String) == "invite" ? "invite" : "signup"
        let requestedName = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if accounts[normalized] != nil {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Email already registered\"}")
        }
        let taken = Set(accounts.values.map(\.name))
        let pendingName = Self.pendingHandle(taken: taken)
        let suggested = Self.availableUserName(
            seed: (requestedName?.isEmpty == false ? requestedName! : String(normalized.split(separator: "@").first ?? "user")),
            taken: taken
        )
        let id = UUID().uuidString.lowercased()
        accounts[normalized] = Account(
            id: id,
            email: normalized,
            passwordHash: Self.sha256(password),
            displayLanguage: nil,
            name: pendingName,
            profileSetupSuggestedHandle: suggested,
            stagingSelfAccountCapabilityHash: capability.map(Self.sha256)
        )
        authProfileStore.setLegalAcceptance(EmailLegalAcceptance(
            termsVersion: Self.termsVersion,
            privacyVersion: Self.privacyVersion,
            termsUrl: Self.termsURL,
            privacyUrl: Self.privacyURL,
            source: source,
            userAgentHash: userAgent.flatMap { $0.isEmpty ? nil : Self.sha256($0) },
            locale: acceptLanguage
        ), userId: id)
        // Upstream inserts a 24h `email_verifications` row during createUser.
        // The E2E-only double gate (env flag AND per-request opt-in) can mark
        // the account verified immediately; the normal signup stays unverified.
        let verificationToken = Self.randomHex(32)
        authProfileStore.issueVerificationToken(
            userId: id,
            token: verificationToken,
            tokenHash: Self.sha256(verificationToken)
        )
        let autoVerified = ProcessInfo.processInfo.environment["SLOCK_E2E_AUTO_VERIFY_EMAIL"] == "1"
            && object["__e2eAutoVerify"] as? Bool == true
        if autoVerified {
            accounts[normalized]?.emailVerified = true
        }
        let issued = openSessionLocked(userId: id)
        emailVerifications += 1
        lock.unlock()
        let user = "{\"id\":\(jsonString(id)),\"email\":\(jsonString(normalized)),\"name\":\(jsonString(pendingName)),\"emailVerified\":\(autoVerified ? "true" : "false"),\"profileSetupCompletedAt\":null,\"profileSetupSuggestedHandle\":\(jsonString(suggested)),\"profileSetupProvider\":null}"
        let response = "{\"user\":\(user),\"accessToken\":\(jsonString(issued.accessToken)),\"refreshToken\":\(jsonString(issued.refreshToken))}"
        return Self.json(200, response)
    }

    /// `POST /api/auth/staging-self-account/retire`. The caller's access token stays usable after the sessions are revoked.
    public func retireStagingSelfAccount(body: String, authorization: String?) -> HTTPReply {
        guard let actorId = retirementActor(authorization) else { return Self.invalidToken }
        if releaseBranch != "staging" {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let userId = object?["userId"] as? String ?? ""
        let capability = object?["capability"] as? String ?? ""
        if userId != actorId {
            return Self.json(403, "{\"error\":\"User ownership mismatch\"}")
        }
        if capability.isEmpty {
            return Self.json(403, "{\"error\":\"Invalid retirement capability\"}")
        }
        guard userId.wholeMatch(of: /(?i)[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil else {
            return Self.json(404, "{\"error\":\"User not found\"}")
        }
        lock.lock()
        guard let key = accounts.first(where: { $0.value.id == userId })?.key, var account = accounts[key] else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"User not found\"}")
        }
        if !account.emailVerified || account.email.wholeMatch(of: /(?i).*@mail\.build/) == nil {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Unsupported account\"}")
        }
        if account.stagingSelfAccountCapabilityHash == nil || account.stagingSelfAccountCapabilityHash != Self.sha256(capability) {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Invalid retirement capability\"}")
        }
        if account.retiredAt != nil {
            let receipt = retirementReceipts[userId]
            lock.unlock()
            guard let receipt else { return Self.json(500, "{\"error\":\"Retirement receipt unavailable\"}") }
            return Self.retirementJSON(receipt)
        }
        let now = Date()
        account.retiredAt = now
        accounts[key] = account
        let live = sessions.filter { $0.value.userId == userId }
        for (token, session) in live {
            sessions.removeValue(forKey: token)
            revokedFamilies.insert(session.familyId)
        }
        let familyIds = sessionFamilies.compactMap { $0.value.userId == userId ? $0.key : nil }
        for familyId in familyIds {
            revokedFamilies.insert(familyId)
            if sessionFamilies[familyId]?.revokedAt == nil {
                sessionFamilies[familyId]?.revokedAt = now
            }
        }
        let receipt = RetirementReceipt(
            userId: userId,
            actorUserId: actorId,
            environment: "staging",
            terminalState: "retired",
            sessionsRevoked: live.count
        )
        retirementReceipts[userId] = receipt
        lock.unlock()
        return Self.retirementJSON(receipt)
    }

    /// `POST /api/auth/device/authorize`. The surface is on unless the gate is an explicit off value.
    public func authorizeDevice(body: String) -> HTTPReply {
        if let disabled = deviceSurfaceDisabled() { return disabled }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        var clientName: String?
        if object.keys.contains("clientName"), !(object["clientName"] is NSNull) {
            guard let name = object["clientName"] as? String, name.count <= 200 else {
                return Self.json(400, "{\"error\":\"clientName must be a string up to 200 chars\",\"code\":\"client_name_invalid\"}")
            }
            clientName = name
        }
        let userCode = makeUserCode()
        let deviceCode = Self.deviceSecret()
        let expiresAt = Date(timeIntervalSinceNow: 600)
        lock.lock()
        deviceGrants[deviceCode] = DeviceGrant(
            deviceCode: deviceCode,
            userCode: userCode,
            status: "pending",
            approvedByUserId: nil,
            expiresAt: expiresAt,
            clientName: clientName
        )
        deviceUserCodes[userCode] = deviceCode
        lock.unlock()
        guard let verification = deviceVerification(userCode: userCode) else {
            return Self.json(503, "{\"error\":\"Device login URL is not configured\",\"code\":\"DEVICE_LOGIN_URL_UNAVAILABLE\"}")
        }
        let response = "{\"deviceCode\":\(jsonString(deviceCode)),\"userCode\":\(jsonString(userCode)),\"verificationUri\":\(jsonString(verification.uri)),\"verificationUriComplete\":\(jsonString(verification.complete)),\"expiresIn\":600,\"interval\":5}"
        return Self.json(201, response)
    }

    /// `POST /api/auth/device/approve`. Only the signed-in user can approve or deny a code.
    public func approveDevice(body: String, authorization: String?) -> HTTPReply {
        if let disabled = deviceSurfaceDisabled() { return disabled }
        let actor: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            actor = id
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        guard let rawCode = object["userCode"] as? String, !rawCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.json(400, "{\"error\":\"userCode is required\",\"code\":\"user_code_required\"}")
        }
        let approve = object["approve"] == nil ? true : (object["approve"] as? Bool == true)
        let normalized = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        lock.lock()
        guard let deviceCode = deviceUserCodes[normalized], var grant = deviceGrants[deviceCode] else {
            lock.unlock()
            return Self.deviceUpdateFailed("user_code_invalid", status: 404)
        }
        if grant.status != "pending" {
            lock.unlock()
            return Self.deviceUpdateFailed("already_resolved", status: 409)
        }
        if grant.expiresAt <= Date() {
            lock.unlock()
            return Self.deviceUpdateFailed("expired", status: 410)
        }
        if approve {
            grant.status = "approved"
            grant.approvedByUserId = actor
        } else {
            grant.status = "denied"
            grant.approvedByUserId = nil
        }
        deviceGrants[deviceCode] = grant
        lock.unlock()
        let action = approve ? "approved" : "denied"
        return Self.json(200, "{\"ok\":true,\"action\":\(jsonString(action))}")
    }

    /// `POST /api/auth/device/token`. A pending grant stays pending. Approval issues one session, then the code is spent.
    public func pollDeviceToken(body: String) -> HTTPReply {
        if let disabled = deviceSurfaceDisabled() { return disabled }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        guard let deviceCode = object["deviceCode"] as? String, !deviceCode.isEmpty else {
            return Self.json(400, "{\"error\":\"deviceCode is required\",\"code\":\"device_code_required\"}")
        }
        lock.lock()
        guard var grant = deviceGrants[deviceCode] else {
            lock.unlock()
            return Self.deviceNotReady("device_code_invalid", status: 400)
        }
        if grant.status == "consumed" {
            lock.unlock()
            return Self.deviceNotReady("device_code_consumed", status: 410)
        }
        if grant.expiresAt <= Date() {
            lock.unlock()
            return Self.deviceNotReady("expired_token", status: 410)
        }
        if grant.status == "denied" {
            lock.unlock()
            return Self.deviceNotReady("access_denied", status: 403)
        }
        guard grant.status == "approved", let userId = grant.approvedByUserId else {
            lock.unlock()
            return Self.deviceNotReady("authorization_pending", status: 400)
        }
        grant.status = "consumed"
        deviceGrants[deviceCode] = grant
        let issued = openSessionLocked(userId: userId)
        lock.unlock()
        let response = "{\"accessToken\":\(jsonString(issued.accessToken)),\"refreshToken\":\(jsonString(issued.refreshToken)),\"userId\":\(jsonString(userId))}"
        return Self.json(200, response)
    }

    /// `POST /api/auth/refresh`. A matching attempt and installation replay the same successor.
    public func refresh(body: String, attemptHeader: String?, installationHeader: String?) -> HTTPReply {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refreshToken = object["refreshToken"] as? String, !refreshToken.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Refresh token is required\"}")
        }
        let attempt = Self.refreshAttempt(attemptHeader)
        let installation = Self.refreshInstallation(installationHeader)
        if installationHeader != nil, attempt == nil || installation == nil {
            return Self.json(400, "{\"error\":\"Invalid refresh replay binding\"}")
        }
        lock.lock()
        let outcome = refreshLocked(
            refreshToken: refreshToken,
            attemptId: attempt,
            installationId: installation
        )
        lock.unlock()
        switch outcome {
        case .rejected:
            return Self.json(401, "{\"error\":\"Invalid or expired refresh token\"}")
        case .rotated(let userId, let successor):
            return Self.json(200, "{\"accessToken\":\(jsonString(userId.accessToken)),\"refreshToken\":\(jsonString(successor))}")
        }
    }

    public func refreshRotationReceipts() -> [RefreshRotationReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return rotationReceipts.values.map {
            RefreshRotationReceipt(
                attemptId: $0.attemptId,
                installationId: $0.installationId,
                successorTokenCiphertext: $0.ciphertext
            )
        }
    }

    public func expireRefreshReceipts() {
        lock.lock()
        for key in rotationReceipts.keys {
            rotationReceipts[key]?.expiresAt = Date(timeIntervalSinceNow: -1)
        }
        lock.unlock()
    }

    /// Moves one mobile OAuth request's expiry into the past. Completion then reports `handoff_code_expired`.
    public func expireMobileOAuthRequest(id: String) {
        lock.lock()
        mobileRequests[id]?.expiresAt = Date(timeIntervalSinceNow: -1)
        lock.unlock()
    }

    /// `POST /api/auth/logout`. Revoking the predecessor's family blocks a later replay.
    public func logout(body: String) -> HTTPReply {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let refreshToken = object["refreshToken"] as? String, !refreshToken.isEmpty {
            lock.lock()
            if let live = sessions.removeValue(forKey: refreshToken) {
                revokedFamilies.insert(live.familyId)
                sessionFamilies[live.familyId]?.revokedAt = Date()
                sessionFamilies[live.familyId]?.revokedReason = "logout"
                sessionFamilies[live.familyId]?.capabilityRetainUntil = Date().addingTimeInterval(30 * 24 * 60 * 60)
                let familyTokens = sessions.filter { $0.value.familyId == live.familyId }.map { $0.key }
                for token in familyTokens { sessions.removeValue(forKey: token) }
            } else if let predecessorFamily = predecessorFamilies[Self.sha256(refreshToken)] {
                revokedFamilies.insert(predecessorFamily)
                sessionFamilies[predecessorFamily]?.revokedAt = Date()
                sessionFamilies[predecessorFamily]?.revokedReason = "logout"
                sessionFamilies[predecessorFamily]?.capabilityRetainUntil = Date().addingTimeInterval(30 * 24 * 60 * 60)
                let familyTokens = sessions.filter { $0.value.familyId == predecessorFamily }.map { $0.key }
                for token in familyTokens { sessions.removeValue(forKey: token) }
            } else if let receipt = rotationReceipts[Self.sha256(refreshToken)] {
                revokedFamilies.insert(receipt.familyId)
                sessionFamilies[receipt.familyId]?.revokedAt = Date()
                sessionFamilies[receipt.familyId]?.revokedReason = "logout"
                sessionFamilies[receipt.familyId]?.capabilityRetainUntil = Date().addingTimeInterval(30 * 24 * 60 * 60)
            }
            lock.unlock()
        }
        return Self.json(200, "{\"ok\":true}")
    }

    public func oauthRequestStatus(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.status
    }

    public func oauthRequestReturnUri(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.returnUri
    }

    public func oauthRequestCodeHash(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.codeHash
    }

    public func oauthRequestExpiresAt(id: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.expiresAt
    }

    public func oauthRequestProviderUserId(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.profileUserId
    }

    public func oauthRequestProviderEmail(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.profileEmail
    }

    /// `requireVerified` reads this from the profile store; the verification
    /// service writes it through the same locked store.
    public func isEmailVerified(userId: String) -> Bool {
        authProfileStore.isEmailVerified(userId: userId)
    }

    /// The Node fixture marks a row verified without an HTTP call. Retirement refuses an unverified account.
    public func markEmailVerified(userId: String) {
        authProfileStore.markEmailVerified(userId: userId)
    }

    public func stagingSelfAccountCapabilityHash(userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return accounts.values.first { $0.id == userId }?.stagingSelfAccountCapabilityHash
    }

    public func retiredAt(userId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return accounts.values.first { $0.id == userId }?.retiredAt
    }

    public func sessionCount(for userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.filter { $0.userId == userId }.count
    }

    public func sessionFamilyRevokedAts(userId: String) -> [Date?] {
        lock.lock()
        defer { lock.unlock() }
        return sessionFamilies.values.filter { $0.userId == userId }.map(\.revokedAt)
    }

    public func oauthRequestCodeChallenge(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.codeChallenge
    }

    /// Adds platform allow rules for Apple sign-in. An empty set leaves Apple disabled on every platform.
    public func allowAppleLogin(on platforms: [String]) {
        lock.lock()
        appleLoginPlatforms.formUnion(platforms)
        lock.unlock()
    }

}

/// Directory services and counters the startup log and acceptance tests read.
/// Every counter is a locked snapshot; none mutates the row it counts.
extension EmailLoginDirectory {

    /// The bearer access-token check shared by the domain services that have
    /// not migrated yet. It lives here, next to the other shared auth
    /// primitives; the product-feedback submission slice only inherited it.
    func authorize(_ authorization: String?) -> Auth {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .rejected(Self.missingAuthorization)
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let id = accessTokens[token]
        let family = accessTokenFamilies[token]
        let familyRevoked = family.map { revokedFamilies.contains($0) } ?? false
        lock.unlock()
        guard let id, !familyRevoked else { return .rejected(Self.invalidToken) }
        return .user(id)
    }

    /// Email-verification policy for `POST /api/auth/verify-email` and
    /// `POST /api/auth/resend-verification`. The feature calls this service;
    /// the directory only supplies the profile store it reads.
    public var authVerification: AuthVerificationService {
        AuthVerificationService(store: authProfileStore)
    }

    /// Socket room membership: connect-time visibility, thread-room
    /// enumeration, `sync:resume` catch-up and membership revocation. The
    /// directory supplies the channel/message stores and the OAuth ledger; the
    /// attachment-comments feature flag is owned by the unmigrated integrations
    /// domain, so it enters the service as a closure.
    public var socketMembership: SocketMembershipService {
        SocketMembershipService(
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            oauth: oauth,
            attachmentCommentsEnabled: { [self] serverId, userId in
                attachmentCommentsEnabled(serverId: serverId, userId: userId)
            }
        )
    }

    /// Server usage, system attention, mention-delivery diagnostics, session
    /// transcripts, transcript feedback and share artifacts. The directory
    /// supplies the machine/agent/message stores and the OAuth ledger; session
    /// lookup and the unmigrated channel access policy enter as closures.
    public var runtimeUsageAttestations: RuntimeUsageAndAttestationsService {
        RuntimeUsageAndAttestationsService(
            machines: machinesAndComputersStore,
            messages: messagesAndThreadsStore,
            channels: serversAndChannelsStore,
            agents: agentsRuntimeStore,
            oauth: oauth,
            sessionUserId: { [self] authorization in
                sessionUserId(authorization: authorization)
            },
            channelAccess: { [self] serverId, channelId, userId in
                switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
                case .missing: false
                case .readOnly, .write: true
                }
            }
        )
    }

    /// Account-profile policy for `POST /api/auth/reset-password`,
    /// `POST /api/auth/pending-link/cancel` and
    /// `POST /api/auth/me/timezone-observation`. The feature calls this
    /// service; the directory only supplies the profile store it reads.
    public var authProfile: AuthProfileService {
        AuthProfileService(store: authProfileStore)
    }

    /// Agent migration status, cancellation, provider position and the external
    /// diagnostics view. The service owns the three published operations; the
    /// directory supplies the two migration stores, the OAuth ledger, and the
    /// realtime/cancel relay seams the unmigrated migration domains own.
    public var agentMigrationStatus: AgentMigrationStatusService {
        let accounts = self
        return AgentMigrationStatusService(
            sessionUserId: { accounts.sessionUserId(authorization: $0) },
            oauth: oauth,
            agents: agentsRuntimeStore,
            machines: machinesAndComputersStore,
            emitRealtime: { room, event, payload in
                accounts.emitRealtime(room, event, payload)
            },
            cancelDispatch: { machineId, role, migrationRef, transportGeneration, stopAgent in
                accounts.agentMigrationCancelDispatch?(
                    machineId,
                    role,
                    migrationRef,
                    transportGeneration,
                    stopAgent
                )
            }
        )
    }

    /// Agent send, delivery-ack, activity, thread-follow and integration
    /// operations. The directory supplies the stores; the closures bridge the
    /// not-yet-migrated message-visibility, message-append and OAuth
    /// integration-projection domains.
    public var agentSendDelivery: AgentSendDeliveryService {
        AgentSendDeliveryService(
            machines: machinesAndComputersStore,
            channels: serversAndChannelsStore,
            messages: messagesAndThreadsStore,
            agents: agentsRuntimeStore,
            threadFollows: threadFollowStore,
            managedMCP: managedMCPAndCardsStore,
            oauth: oauth,
            searchVisible: { [self] messageChannelId, serverId, viewer in
                lock.lock()
                defer { lock.unlock() }
                return messageSearchVisibleLocked(
                    messageChannelId: messageChannelId,
                    serverId: serverId,
                    viewer: viewer
                )
            },
            appendHumanMessage: { [self] message in
                lock.lock()
                let seq = appendHumanMessageLocked(message)
                lock.unlock()
                return seq
            },
            integrationServices: { [self] serverId in
                oauth.integrationServices(serverId: serverId).map(AgentIntegrationProjection.snapshot)
            }
        )
    }

    /// Action-card prepare, the agent context / app-config surface, and the
    /// agent-target projections the execute/send domains still call. The
    /// service reads the domain stores; the session lookup and the
    /// assistant-owner policy belong to unmigrated domains and enter as
    /// closures.
    public var actionCardPrepare: ActionCardPrepareService {
        ActionCardPrepareService(
            oauth: oauth,
            cards: managedMCPAndCardsStore,
            feedback: feedbackStore,
            agents: agentsRuntimeStore,
            channels: serversAndChannelsStore,
            accounts: authProfileStore,
            messages: messagesAndThreadsStore,
            sessionUserId: { self.sessionUserId(authorization: $0) },
            assistantOwner: { [self] agentId, serverId in
                assistantOwnerFor(agentId: agentId, serverId: serverId)
            }
        )
    }

    /// Agent task create/convert/delete/assign/resource-receipt and the agent
    /// inbox conversation list. The directory supplies the domain stores and
    /// the OAuth ledger; the idempotency ledger (managed-MCP catalog) and the
    /// message-append policy (messaging) are not-yet-migrated dependencies and
    /// enter as the two closures below.
    public var actionCardMarketplace: ActionCardMarketplaceService {
        ActionCardMarketplaceService(
            tasks: tasksAndRemindersStore,
            messages: messagesAndThreadsStore,
            inboxFacts: inboxFactStore,
            channels: serversAndChannelsStore,
            accounts: authProfileStore,
            agents: agentsRuntimeStore,
            machines: machinesAndComputersStore,
            cards: managedMCPAndCardsStore,
            oauth: oauth,
            locator: FeedbackLocatorService(directory: self),
            idempotency: ActionCardTaskIdempotency(
                lookup: { [self] agentId, route, rawBody in
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(rawBody.utf8))) as? [String: Any],
                          let reply = agentApiIdempotencyReply(agentId: agentId, route: route, object: object)
                    else { return .miss }
                    if reply.status == 409 { return .conflict(body: reply.body) }
                    return .replay(body: reply.body)
                },
                store: { [self] agentId, route, rawBody, body in
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(rawBody.utf8))) as? [String: Any]
                    else { return }
                    storeAgentApiIdempotency(
                        agentId: agentId,
                        route: route,
                        object: object,
                        reply: HTTPReply(status: 200, headers: [:], body: body)
                    )
                }
            ),
            appendHumanMessage: { [self] message in
                lock.lock()
                let seq = appendHumanMessageLocked(message)
                lock.unlock()
                return seq
            },
            serializeReceipt: { payload in
                guard let object = legacyJSONObject(payload) as? [String: Any] else { return "{}" }
                return EmailLoginDirectory.serializeJSON(object)
            }
        )
    }

    /// Product feedback locators for `POST/GET /internal/agent-api/feedback-locators`
    /// plus the agent credential/grant decisions the rest of the agent API
    /// shares. The directory only supplies its stores and the OAuth ledger.
    public var feedbackLocators: FeedbackLocatorService {
        FeedbackLocatorService(directory: self)
    }

    public var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    public var userCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accounts.count
    }

    public var legalAcceptanceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return authProfileStore.legalAcceptanceCount
    }

    public var emailVerificationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return emailVerifications
    }

    public var providerExchangeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return providerExchanges
    }

    public var retirementReceiptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retirementReceipts.count
    }

    public var mobileOAuthRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests.count
    }

    /// Rows the directory holds for `GET /api/messages` style readbacks.
    public var humanMessageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.count
    }

    /// Product-feedback submission and onboarding-wizard event recording. The
    /// Hands transport and route binding are still owned by the not-yet-migrated
    /// `FeedbackService`, so they enter as closures; the account row, the
    /// feature-flag decision and product-event rows come from their stores.
    public var productFeedbackSubmissions: ProductFeedbackSubmissionService {
        let feedback = FeedbackService(directory: self)
        return ProductFeedbackSubmissionService(
            dependencies: ProductFeedbackSubmissionDependencies(
                account: { [authProfileStore] userId in
                    authProfileStore.account(userId: userId)
                },
                userId: { [self] authorization in
                    sessionUserId(authorization: authorization)
                },
                resolveAttribution: { [self] serverId, userId in
                    guard ServerScope.isUUID(serverId),
                          let profile = oauth.serverProfile(id: serverId),
                          oauth.memberRole(serverId: serverId, userId: userId) != nil,
                          !profile.slug.isEmpty
                    else { return nil }
                    return ProductFeedbackReporterAttribution(
                        serverSlug: profile.slug,
                        handle: authProfileStore.account(userId: userId)?.name ?? ""
                    )
                },
                multiAppEnabled: { [self] userId in
                    evaluateFeatureFlagKey(
                        key: EmailLoginDirectory.productFeedbackMultiAppFlag,
                        userId: userId,
                        serverId: nil,
                        platform: nil,
                        client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)
                    ).enabled
                },
                configuration: { [self, feedbackStore] in
                    let snapshot = feedbackStore.handsFeedbackSubmissionConfiguration(
                        base: ProcessInfo.processInfo.environment,
                        conversationSessionEnabled: authProfileStore.handsConversationSessionEnabled
                    )
                    return ProductFeedbackRelayConfiguration(
                        environment: snapshot.environment,
                        appsJSON: snapshot.appsJSON,
                        configured: snapshot.configured
                            || snapshot.environment["HANDS_FEEDBACK_BASE_URL"] != nil
                    )
                },
                multiRouteEnvironment: { source, appsJSON, environment in
                    try EmailLoginDirectory.feedbackMultiRouteEnvironment(
                        source: source,
                        appsJSON: appsJSON,
                        environment: environment
                    )
                },
                legacyRouteEnvironment: { environment in
                    EmailLoginDirectory.feedbackLegacyRouteEnvironment(environment)
                },
                ensureRouteBinding: { userId, environment in
                    try await feedback.ensureRouteBindingAsync(userId: userId, environment: environment)
                },
                send: { request in
                    await feedback.sendAsync(request)
                },
                warn: { message in
                    feedback.warn(message)
                },
                appendProductEvent: { [productEventStore] event in
                    productEventStore.append(event)
                },
                serverAnalyticsAllowed: { [self] serverId in
                    oauth.serverAnalyticsAllowed(id: serverId)
                }
            )
        )
    }

}

/// Bridges a decoded `JSONValue` back to the `Any` tree the legacy
/// `serializeJSON` helper expects. Only the resource-receipt notes field uses
/// it; the value was produced by the same JSON decoder the raw parser fed.
private func legacyJSONObject(_ value: JSONValue) -> Any {
    switch value {
    case .object(let members):
        return members.mapValues(legacyJSONObject)
    case .array(let values):
        return values.map(legacyJSONObject)
    case .string(let string):
        return string
    case .number(let number):
        return number
    case .integer(let integer):
        return integer
    case .bool(let boolean):
        return boolean
    case .null:
        return NSNull()
    }
}
