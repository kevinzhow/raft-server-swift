import Foundation

// The session core's read-modify-write sections: social completion, register,
// staging retirement, device grants, refresh rotation and logout. Each one used
// to run under the directory lock; each is now exactly one critical section of
// this store's lock, so two concurrent requests cannot both pass a check that
// the first one's write invalidates. Nothing here builds JSON or an HTTP reply.

/// One linked identity row as the link-completion reply lists it.
struct LinkedIdentityRow: Sendable, Equatable {
    var provider: String
    var providerUserId: String
}

/// The pending-link handle the `account_link_required` 409 publishes.
struct AccountLinkRequired: Sendable, Equatable {
    var pendingLinkToken: String
    var email: String
    var hasPassword: Bool
    var linkedProviders: [String]
    var returnTo: String
}

/// The decoded facts of one `POST /api/auth/:provider/complete` request.
struct SocialCompletionAttempt: Sendable {
    var provider: String
    var code: String
    var pendingLinkToken: String?
    var acceptTerms: Bool
    var termsVersion: String?
    var privacyVersion: String?
    var legalAcceptanceSource: String?
    /// The bearer token after `Bearer `, or `nil` when the header was absent or
    /// not a bearer credential.
    var bearerToken: String?
    var userAgentHash: String?
    var locale: String?
    var now: Date
}

enum SocialCompletionOutcome: Sendable, Equatable {
    case invalidCompletion
    case linkAuthRequired
    case linkMismatch
    case linked(returnTo: String, identities: [LinkedIdentityRow])
    case pendingLinkExpired
    case pendingLinkAccountMismatch
    case pendingLinkLogin(returnTo: String, tokens: IssuedSessionTokens, linkedProvider: String)
    case accountLinkRequired(AccountLinkRequired)
    case legalRequired
    case termsChanged
    case emailExists
    case loggedIn(mode: String, returnTo: String, tokens: IssuedSessionTokens)
}

/// The decoded facts of one `POST /api/auth/register` request.
struct RegistrationAttempt: Sendable {
    var normalizedEmail: String
    var passwordHash: String
    var requestedName: String?
    var capabilityHash: String?
    var legalAcceptanceSource: String
    var userAgentHash: String?
    var locale: String?
    var autoVerify: Bool
    var now: Date
}

struct RegisteredAccount: Sendable, Equatable {
    var id: String
    var email: String
    var name: String
    var suggestedHandle: String
    var emailVerified: Bool
    var tokens: IssuedSessionTokens
}

enum RegistrationOutcome: Sendable, Equatable {
    case emailTaken
    case created(RegisteredAccount)
}

enum StagingRetirementOutcome: Sendable {
    case userNotFound
    case unsupportedAccount
    case invalidCapability
    case alreadyRetired(RetirementReceipt?)
    case retired(RetirementReceipt)
}

enum DeviceDecisionOutcome: Sendable, Equatable {
    case userCodeInvalid
    case alreadyResolved
    case expired
    case decided
}

enum DeviceTokenOutcome: Sendable, Equatable {
    case deviceCodeInvalid
    case consumed
    case expired
    case denied
    case pending
    case issued(userId: String, tokens: IssuedSessionTokens)
}

struct RefreshRotation: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
}

extension AuthProfileStore {
    // MARK: - Access tokens

    /// The account id behind an access token without the revoked-family check
    /// (the staging retirement keeps working after its own revoke).
    func accessTokenOwner(_ token: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return accountSurface.accessTokens[token]
    }

    /// Opens one session family for `userId` (one critical section).
    func openSession(userId: String) -> IssuedSessionTokens {
        lock.lock()
        defer { lock.unlock() }
        return openSessionLocked(userId: userId)
    }

    // MARK: - Social completion

    /// Spends one provider completion. The code lookup, the link/pending-link
    /// checks, the legal gate, the completion consume, the account insert and
    /// the session open are one critical section: two concurrent requests with
    /// one code cannot both spend it.
    func completeSocial(_ attempt: SocialCompletionAttempt) -> SocialCompletionOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let index = accountSurface.socialCompletions.firstIndex(where: {
            $0.provider == attempt.provider && $0.code == attempt.code
        }) else { return .invalidCompletion }
        let completion = accountSurface.socialCompletions[index]
        if completion.mode == "link" {
            guard let token = attempt.bearerToken,
                  let caller = accountSurface.accessTokens[token]
            else { return .linkAuthRequired }
            guard completion.userId == caller else { return .linkMismatch }
            accountSurface.socialCompletions.remove(at: index)
            let providerUserId = completion.providerUserId ?? ""
            if !accountSurface.linkedIdentities.contains(where: {
                $0.userId == caller && $0.provider == attempt.provider && $0.providerUserId == providerUserId
            }) {
                accountSurface.linkedIdentities.append(LinkedIdentity(
                    userId: caller,
                    provider: attempt.provider,
                    providerUserId: providerUserId
                ))
            }
            let rows = accountSurface.linkedIdentities.filter { $0.userId == caller }
            return .linked(
                returnTo: completion.returnTo,
                identities: rows.map { LinkedIdentityRow(provider: $0.provider, providerUserId: $0.providerUserId) }
            )
        }
        if let rawToken = attempt.pendingLinkToken, !rawToken.isEmpty {
            guard var pending = accountSurface.pendingSocialLinks[rawToken], !pending.consumed,
                  !pending.cancelled, pending.expiresAt > attempt.now
            else { return .pendingLinkExpired }
            let identityOwner = accountSurface.linkedIdentities.first {
                $0.provider == attempt.provider && $0.providerUserId == (completion.providerUserId ?? "")
            }?.userId
            let pendingOwner = accountSurface.accounts[pending.email]?.id
            guard let identityOwner, identityOwner == pendingOwner else { return .pendingLinkAccountMismatch }
            pending.consumed = true
            accountSurface.pendingSocialLinks[rawToken] = pending
            if !accountSurface.linkedIdentities.contains(where: {
                $0.userId == identityOwner && $0.provider == pending.provider
                    && $0.providerUserId == pending.providerUserId
            }) {
                accountSurface.linkedIdentities.append(LinkedIdentity(
                    userId: identityOwner, provider: pending.provider,
                    providerUserId: pending.providerUserId, providerEmail: pending.email
                ))
            }
            accountSurface.socialCompletions.remove(at: index)
            let tokens = bareSessionLocked(userId: identityOwner)
            return .pendingLinkLogin(
                returnTo: completion.returnTo,
                tokens: tokens,
                linkedProvider: pending.provider
            )
        }
        if completion.userId == nil, completion.intendedAction == "link",
           completion.linkOnConflict, let existing = accountSurface.accounts[completion.email] {
            let token = AuthTokenCodec.randomHex(32)
            accountSurface.pendingSocialLinks[token] = PendingSocialLink(
                token: token, provider: attempt.provider,
                providerUserId: completion.providerUserId ?? "",
                email: completion.email, returnTo: completion.returnTo, returnUri: nil,
                expiresAt: attempt.now.addingTimeInterval(600)
            )
            let linkedProviders = Set(
                accountSurface.linkedIdentities.filter { $0.userId == existing.id }.map(\.provider)
            ).sorted()
            return .accountLinkRequired(AccountLinkRequired(
                pendingLinkToken: token,
                email: existing.email,
                hasPassword: existing.passwordCredentialEstablishedAt != nil,
                linkedProviders: linkedProviders,
                returnTo: completion.returnTo
            ))
        }
        if completion.mode == "login", completion.userId == nil {
            if !attempt.acceptTerms { return .legalRequired }
            if attempt.termsVersion != AuthLegalPolicy.termsVersion
                || attempt.privacyVersion != AuthLegalPolicy.privacyVersion {
                return .termsChanged
            }
        }
        accountSurface.socialCompletions.remove(at: index)
        let id = completion.userId ?? UUID().uuidString.lowercased()
        let taken = Set(accountSurface.accounts.values.map(\.name))
        let pendingName = AccountNaming.pendingHandle(taken: taken)
        let suggested = AccountNaming.availableUserName(
            seed: String(completion.email.split(separator: "@").first ?? "user"),
            taken: taken
        )
        if completion.userId == nil, accountSurface.accounts[completion.email] != nil {
            return .emailExists
        }
        if completion.userId == nil {
            accountSurface.accounts[completion.email] = Account(
                id: id,
                email: completion.email,
                passwordHash: AuthTokenCodec.sha256(AuthTokenCodec.token()),
                displayLanguage: nil,
                name: pendingName,
                profileSetupSuggestedHandle: suggested
            )
            legalAcceptances[id] = EmailLegalAcceptance(
                termsVersion: AuthLegalPolicy.termsVersion,
                privacyVersion: AuthLegalPolicy.privacyVersion,
                termsUrl: AuthLegalPolicy.termsURL,
                privacyUrl: AuthLegalPolicy.privacyURL,
                source: attempt.legalAcceptanceSource == "invite" ? "invite" : "oauth",
                userAgentHash: attempt.userAgentHash,
                locale: attempt.locale
            )
        }
        return .loggedIn(
            mode: completion.mode,
            returnTo: completion.returnTo,
            tokens: bareSessionLocked(userId: id)
        )
    }

    /// A session without a family row: the social-completion login published
    /// no `sessionFamilies` entry, and that stays the observable shape.
    private func bareSessionLocked(userId: String) -> IssuedSessionTokens {
        let accessToken = AuthTokenCodec.token()
        let refreshToken = AuthTokenCodec.token()
        accountSurface.sessions[refreshToken] = LiveSession(userId: userId, familyId: UUID().uuidString.lowercased())
        accountSurface.accessTokens[accessToken] = userId
        return IssuedSessionTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    // MARK: - Register

    /// Creates one account with its legal acceptance, verification token and
    /// session in one critical section, so two concurrent registrations of one
    /// address cannot both create it.
    func registerAccount(_ attempt: RegistrationAttempt) -> RegistrationOutcome {
        lock.lock()
        defer { lock.unlock() }
        let normalized = attempt.normalizedEmail
        if accountSurface.accounts[normalized] != nil { return .emailTaken }
        let taken = Set(accountSurface.accounts.values.map(\.name))
        let pendingName = AccountNaming.pendingHandle(taken: taken)
        let suggested = AccountNaming.availableUserName(
            seed: (attempt.requestedName?.isEmpty == false
                ? attempt.requestedName!
                : String(normalized.split(separator: "@").first ?? "user")),
            taken: taken
        )
        let id = UUID().uuidString.lowercased()
        accountSurface.accounts[normalized] = Account(
            id: id,
            email: normalized,
            passwordHash: attempt.passwordHash,
            displayLanguage: nil,
            name: pendingName,
            profileSetupSuggestedHandle: suggested,
            stagingSelfAccountCapabilityHash: attempt.capabilityHash
        )
        legalAcceptances[id] = EmailLegalAcceptance(
            termsVersion: AuthLegalPolicy.termsVersion,
            privacyVersion: AuthLegalPolicy.privacyVersion,
            termsUrl: AuthLegalPolicy.termsURL,
            privacyUrl: AuthLegalPolicy.privacyURL,
            source: attempt.legalAcceptanceSource,
            userAgentHash: attempt.userAgentHash,
            locale: attempt.locale
        )
        // Upstream inserts a 24h `email_verifications` row during createUser.
        let verificationToken = AuthTokenCodec.randomHex(32)
        issueVerificationTokenLocked(
            userId: id,
            token: verificationToken,
            tokenHash: AuthTokenCodec.sha256(verificationToken),
            now: attempt.now,
            ttl: 24 * 60 * 60
        )
        if attempt.autoVerify {
            accountSurface.accounts[normalized]?.emailVerified = true
        }
        let tokens = openSessionLocked(userId: id)
        accountSurface.emailVerifications += 1
        return .created(RegisteredAccount(
            id: id,
            email: normalized,
            name: pendingName,
            suggestedHandle: suggested,
            emailVerified: attempt.autoVerify,
            tokens: tokens
        ))
    }

    // MARK: - Staging retirement

    /// Retires one staging self-account: the row checks, the retired stamp, the
    /// session and family revocation and the receipt write are one critical
    /// section, so a replay sees the first receipt.
    func retireStagingAccount(
        userId: String,
        actorUserId: String,
        capabilityHash: String,
        now: Date
    ) -> StagingRetirementOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let key = accountSurface.accounts.first(where: { $0.value.id == userId })?.key,
              var account = accountSurface.accounts[key]
        else { return .userNotFound }
        if !account.emailVerified || account.email.wholeMatch(of: /(?i).*@mail\.build/) == nil {
            return .unsupportedAccount
        }
        if account.stagingSelfAccountCapabilityHash == nil
            || account.stagingSelfAccountCapabilityHash != capabilityHash {
            return .invalidCapability
        }
        if account.retiredAt != nil {
            return .alreadyRetired(accountSurface.retirementReceipts[userId])
        }
        account.retiredAt = now
        accountSurface.accounts[key] = account
        let live = accountSurface.sessions.filter { $0.value.userId == userId }
        for (token, session) in live {
            accountSurface.sessions.removeValue(forKey: token)
            accountSurface.revokedFamilies.insert(session.familyId)
        }
        let familyIds = accountSurface.sessionFamilies.compactMap { $0.value.userId == userId ? $0.key : nil }
        for familyId in familyIds {
            accountSurface.revokedFamilies.insert(familyId)
            if accountSurface.sessionFamilies[familyId]?.revokedAt == nil {
                accountSurface.sessionFamilies[familyId]?.revokedAt = now
            }
        }
        let receipt = RetirementReceipt(
            userId: userId,
            actorUserId: actorUserId,
            environment: "staging",
            terminalState: "retired",
            sessionsRevoked: live.count
        )
        accountSurface.retirementReceipts[userId] = receipt
        return .retired(receipt)
    }

    // MARK: - Device grants

    func registerDeviceGrant(
        deviceCode: String,
        userCode: String,
        clientName: String?,
        expiresAt: Date
    ) {
        lock.lock()
        accountSurface.deviceGrants[deviceCode] = DeviceGrant(
            deviceCode: deviceCode,
            userCode: userCode,
            status: "pending",
            approvedByUserId: nil,
            expiresAt: expiresAt,
            clientName: clientName
        )
        accountSurface.deviceUserCodes[userCode] = deviceCode
        lock.unlock()
    }

    /// Approves or denies one pending grant. The lookup, the pending and expiry
    /// checks and the status write are one critical section, so a grant cannot
    /// be both approved and denied.
    func decideDeviceGrant(
        userCode: String,
        approve: Bool,
        actorUserId: String,
        now: Date
    ) -> DeviceDecisionOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let deviceCode = accountSurface.deviceUserCodes[userCode],
              var grant = accountSurface.deviceGrants[deviceCode]
        else { return .userCodeInvalid }
        if grant.status != "pending" { return .alreadyResolved }
        if grant.expiresAt <= now { return .expired }
        if approve {
            grant.status = "approved"
            grant.approvedByUserId = actorUserId
        } else {
            grant.status = "denied"
            grant.approvedByUserId = nil
        }
        accountSurface.deviceGrants[deviceCode] = grant
        return .decided
    }

    /// Spends one approved grant and opens its session in one critical section:
    /// two concurrent polls of one approved code issue exactly one session.
    func consumeDeviceGrant(deviceCode: String, now: Date) -> DeviceTokenOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard var grant = accountSurface.deviceGrants[deviceCode] else { return .deviceCodeInvalid }
        if grant.status == "consumed" { return .consumed }
        if grant.expiresAt <= now { return .expired }
        if grant.status == "denied" { return .denied }
        guard grant.status == "approved", let userId = grant.approvedByUserId else { return .pending }
        grant.status = "consumed"
        accountSurface.deviceGrants[deviceCode] = grant
        return .issued(userId: userId, tokens: openSessionLocked(userId: userId))
    }

    // MARK: - Refresh and logout

    /// Rotates one refresh token. The live-session lookup, the successor write
    /// and the receipt or predecessor record are one critical section: two
    /// concurrent rotations of one token cannot both succeed without a matching
    /// replay binding.
    func rotateRefreshToken(
        _ refreshToken: String,
        attemptId: String?,
        installationId: String?,
        now: Date
    ) -> RefreshRotation? {
        lock.lock()
        defer { lock.unlock() }
        if let attemptId, let installationId {
            return durableRotationLocked(
                refreshToken: refreshToken,
                attemptId: attemptId,
                installationId: installationId,
                now: now
            )
        }
        guard let live = accountSurface.sessions[refreshToken],
              !accountSurface.revokedFamilies.contains(live.familyId)
        else { return nil }
        accountSurface.sessions.removeValue(forKey: refreshToken)
        accountSurface.predecessorFamilies[AuthTokenCodec.sha256(refreshToken)] = live.familyId
        let successor = AuthTokenCodec.token()
        accountSurface.sessions[successor] = live
        let accessToken = AuthTokenCodec.token()
        accountSurface.accessTokens[accessToken] = live.userId
        accountSurface.accessTokenFamilies[accessToken] = live.familyId
        return RefreshRotation(accessToken: accessToken, refreshToken: successor)
    }

    private func durableRotationLocked(
        refreshToken: String,
        attemptId: String,
        installationId: String,
        now: Date
    ) -> RefreshRotation? {
        let hash = AuthTokenCodec.sha256(refreshToken)
        if let live = accountSurface.sessions.removeValue(forKey: refreshToken) {
            if accountSurface.revokedFamilies.contains(live.familyId) { return nil }
            let successor = AuthTokenCodec.token()
            accountSurface.sessions[successor] = live
            accountSurface.rotationReceipts[hash] = RotationReceipt(
                attemptId: attemptId,
                installationId: installationId,
                userId: live.userId,
                familyId: live.familyId,
                successor: successor,
                ciphertext: AuthTokenCodec.sealSuccessor(successor),
                expiresAt: now.addingTimeInterval(15 * 60)
            )
            let accessToken = AuthTokenCodec.token()
            accountSurface.accessTokens[accessToken] = live.userId
            accountSurface.accessTokenFamilies[accessToken] = live.familyId
            return RefreshRotation(accessToken: accessToken, refreshToken: successor)
        }
        guard let receipt = accountSurface.rotationReceipts[hash] else { return nil }
        if receipt.attemptId != attemptId || receipt.installationId != installationId { return nil }
        if receipt.expiresAt <= now || accountSurface.revokedFamilies.contains(receipt.familyId) { return nil }
        let accessToken = AuthTokenCodec.token()
        accountSurface.accessTokens[accessToken] = receipt.userId
        accountSurface.accessTokenFamilies[accessToken] = receipt.familyId
        return RefreshRotation(accessToken: accessToken, refreshToken: receipt.successor)
    }

    /// Revokes the family behind one refresh token (live, predecessor or
    /// replay receipt) in one critical section.
    func revokeRefreshFamily(refreshToken: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        let retainUntil = now.addingTimeInterval(30 * 24 * 60 * 60)
        if let live = accountSurface.sessions.removeValue(forKey: refreshToken) {
            revokeFamilyLocked(live.familyId, now: now, retainUntil: retainUntil, dropSessions: true)
        } else if let predecessorFamily = accountSurface.predecessorFamilies[AuthTokenCodec.sha256(refreshToken)] {
            revokeFamilyLocked(predecessorFamily, now: now, retainUntil: retainUntil, dropSessions: true)
        } else if let receipt = accountSurface.rotationReceipts[AuthTokenCodec.sha256(refreshToken)] {
            revokeFamilyLocked(receipt.familyId, now: now, retainUntil: retainUntil, dropSessions: false)
        }
    }

    private func revokeFamilyLocked(_ familyId: String, now: Date, retainUntil: Date, dropSessions: Bool) {
        accountSurface.revokedFamilies.insert(familyId)
        accountSurface.sessionFamilies[familyId]?.revokedAt = now
        accountSurface.sessionFamilies[familyId]?.revokedReason = "logout"
        accountSurface.sessionFamilies[familyId]?.capabilityRetainUntil = retainUntil
        if dropSessions {
            let familyTokens = accountSurface.sessions.filter { $0.value.familyId == familyId }.map { $0.key }
            for token in familyTokens { accountSurface.sessions.removeValue(forKey: token) }
        }
    }
}
