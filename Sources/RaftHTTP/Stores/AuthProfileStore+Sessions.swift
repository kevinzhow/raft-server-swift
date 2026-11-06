import Foundation

// MARK: - Session identity, app login and profile writes
//
// Each method below is one critical section over the account surface (and, for
// the identity list, the identity rows). They return plain values and decision
// enums; the `AuthIdentitiesService` maps them to its DTOs and typed errors.

/// A user's linked sign-in identities and the password flag, read together.
struct AuthIdentitySnapshot {
    var rows: [(provider: String, providerEmail: String)]
    var passwordConfigured: Bool
}

/// The access/refresh pair one opened session family issued.
struct IssuedSessionTokens: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
}

/// Result of the locked unlink-and-guard decision.
enum UnlinkIdentityOutcome {
    case notLinked(AuthIdentitySnapshot)
    case passwordCredentialRequired
    case unlinked(AuthIdentitySnapshot)
}

/// Result of the locked password login (pending-link check, password check,
/// session open and link consume).
enum AuthenticateOutcome {
    case authenticated(userId: String, email: String, tokens: IssuedSessionTokens, linkedProvider: String?)
    case pendingLinkExpired
    case pendingLinkAccountMismatch
    case rejected
}

/// What the signed-in user decided for a pending app-login request.
enum AppLoginDecision {
    case approve(userId: String, code: String)
    case deny
}

enum AppLoginDecisionOutcome {
    case decided(AppLoginRequest)
    case notFound
    case expired(AppLoginRequest)
    case notPending
}

/// Result of the locked one-time-code completion.
enum CompleteAppLoginOutcome {
    case completed(Account, IssuedSessionTokens)
    case codeNotFound
    case codeConsumed
    case codeExpired
    case pkceMismatch
    case notApproved
    case accountMissing
}

enum ChangePasswordOutcome: Equatable, Sendable {
    case changed
    case accountMissing
    case wrongPassword
}

/// The validated `PATCH /api/auth/me` profile fields. A double optional is
/// "leave alone" (outer `nil`), "clear" (`.some(nil)`) or "set".
struct AccountProfileUpdate: Sendable {
    var referralSource: String?? = nil
    var referralSourceOther: String?? = nil
    var referralSourceSkipped = false
    var preferredLanguage: String?? = nil
    var preferredTimezone: String?? = nil
    var preferredTranslationMode: String? = nil
    var autoTranslationEnabled: Bool? = nil
    var preferredTranslationDisplay: String? = nil
    var preferredTimeFormat: String?? = nil
    var preferredMessageBodyFontSize: String?? = nil
    var displayLanguage: String?? = nil
    var shareUsageData: Bool?? = nil
}

extension AuthProfileStore {
    /// The identity rows and the password flag in one critical section.
    func identitySnapshot(userId: String) -> AuthIdentitySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return identitySnapshotLocked(userId: userId, rows: identityRows[userId] ?? [])
    }

    private func identitySnapshotLocked(
        userId: String,
        rows: [(provider: String, providerEmail: String)]
    ) -> AuthIdentitySnapshot {
        let passwordConfigured = accountSurface.accounts.values
            .first { $0.id == userId }?.passwordCredentialEstablishedAt != nil
        return AuthIdentitySnapshot(rows: rows, passwordConfigured: passwordConfigured)
    }

    /// Unlinks the first row for `provider`. The row lookup, the
    /// final-credential guard and the row write are one critical section, so
    /// two concurrent unlinks of a passwordless user's last two identities
    /// cannot both pass the guard.
    func unlinkIdentity(userId: String, provider: String) -> UnlinkIdentityOutcome {
        lock.lock()
        defer { lock.unlock() }
        var rows = identityRows[userId] ?? []
        let before = identitySnapshotLocked(userId: userId, rows: rows)
        guard let index = rows.firstIndex(where: { $0.provider == provider }) else {
            return .notLinked(before)
        }
        if rows.count == 1, !before.passwordConfigured {
            return .passwordCredentialRequired
        }
        rows.remove(at: index)
        identityRows[userId] = rows
        return .unlinked(identitySnapshotLocked(userId: userId, rows: rows))
    }

    /// The account behind a bearer token, without the revoked-family check the
    /// session decisions apply (`requireAuth` for the OAuth routes).
    func account(forAnyAccessToken token: String) -> Account? {
        lock.lock()
        defer { lock.unlock() }
        guard let userId = accountSurface.accessTokens[token] else { return nil }
        return accountSurface.accounts.values.first { $0.id == userId }
    }

    /// Opens one session family. The caller holds `lock`.
    func openSessionLocked(userId: String) -> IssuedSessionTokens {
        let familyId = UUID().uuidString.lowercased()
        accountSurface.sessionFamilies[familyId] = SessionFamily(userId: userId, revokedAt: nil)
        let accessToken = AuthTokenCodec.token()
        let refreshToken = AuthTokenCodec.token()
        accountSurface.sessions[refreshToken] = LiveSession(userId: userId, familyId: familyId)
        accountSurface.accessTokens[accessToken] = userId
        accountSurface.accessTokenFamilies[accessToken] = familyId
        return IssuedSessionTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// Password login. The pending-link validation, the credential check, the
    /// first-password stamp, the session open and the link consume are one
    /// critical section, so a pending link cannot be spent twice.
    func authenticate(
        email: String,
        passwordHash: String,
        pendingLinkToken: String?,
        now: Date
    ) -> AuthenticateOutcome {
        lock.lock()
        defer { lock.unlock() }
        var pendingLink: PendingSocialLink?
        if let token = pendingLinkToken, !token.isEmpty {
            guard let pending = accountSurface.pendingSocialLinks[token], !pending.consumed,
                  !pending.cancelled, pending.expiresAt > now
            else { return .pendingLinkExpired }
            guard pending.email == email else { return .pendingLinkAccountMismatch }
            pendingLink = pending
        }
        guard var account = accountSurface.accounts[email],
              account.passwordHash == passwordHash,
              account.retiredAt == nil
        else { return .rejected }
        if account.passwordCredentialEstablishedAt == nil {
            account.passwordCredentialEstablishedAt = now
            accountSurface.accounts[email] = account
        }
        let tokens = openSessionLocked(userId: account.id)
        var linkedProvider: String?
        if var pending = pendingLink {
            pending.consumed = true
            accountSurface.pendingSocialLinks[pending.token] = pending
            if !accountSurface.linkedIdentities.contains(where: {
                $0.userId == account.id && $0.provider == pending.provider
                    && $0.providerUserId == pending.providerUserId
            }) {
                accountSurface.linkedIdentities.append(LinkedIdentity(
                    userId: account.id,
                    provider: pending.provider,
                    providerUserId: pending.providerUserId,
                    providerEmail: pending.email
                ))
            }
            linkedProvider = pending.provider
        }
        return .authenticated(userId: account.id, email: account.email, tokens: tokens, linkedProvider: linkedProvider)
    }
}
