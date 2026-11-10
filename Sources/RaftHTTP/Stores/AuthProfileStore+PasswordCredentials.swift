import Foundation

/// Immutable credential version used for CPU proof outside the store mutex.
struct PasswordCredentialCandidate: Sendable, Equatable {
    let userId: String
    let email: String
    let encodedHash: String
}

/// Committed session families that the transport must close after publication.
public struct PasswordSessionRevocation: Sendable, Equatable {
    public let userId: String
    public let familyIds: [String]
}

extension AuthProfileStore {
    func passwordCandidate(email: String) -> PasswordCredentialCandidate? {
        state.withLock { state in
            guard let account = state.accountSurface.accounts[email], account.retiredAt == nil else { return nil }
            return PasswordCredentialCandidate(userId: account.id, email: email, encodedHash: account.passwordHash)
        }
    }

    func passwordCandidate(userId: String) -> PasswordCredentialCandidate? {
        state.withLock { state in
            guard let pair = state.accountSurface.accounts.first(where: { $0.value.id == userId }),
                  pair.value.retiredAt == nil else { return nil }
            return PasswordCredentialCandidate(userId: userId, email: pair.key, encodedHash: pair.value.passwordHash)
        }
    }

    func resetPasswordCandidate(tokenHash: String, now: Date) -> PasswordCredentialCandidate? {
        state.withLock { state in
            guard let reset = state.passwordResetTokens[tokenHash], reset.expiresAt > now,
                  let pair = state.accountSurface.accounts.first(where: { $0.value.id == reset.userId }),
                  pair.value.retiredAt == nil else { return nil }
            return PasswordCredentialCandidate(userId: pair.value.id, email: pair.key, encodedHash: pair.value.passwordHash)
        }
    }

    func commitPasswordReset(candidate: PasswordCredentialCandidate, tokenHash: String,
                             newHash: String, now: Date) -> PasswordSessionRevocation? {
        state.withLock { state in
            guard let reset = state.passwordResetTokens[tokenHash], reset.userId == candidate.userId,
                  reset.expiresAt > now, var account = state.accountSurface.accounts[candidate.email],
                  account.id == candidate.userId, account.retiredAt == nil,
                  account.passwordHash == candidate.encodedHash else { return nil }
            account.passwordHash = newHash
            account.passwordCredentialEstablishedAt = now
            state.accountSurface.accounts[candidate.email] = account
            return Self.revokePasswordSessionsLocked(state: &state, userId: account.id, now: now, reason: "password_reset")
        }
    }

    /// All credential lifecycle writes are one store transaction. No KDF,
    /// callback, transport operation or nested store access runs under this lock.
    static func revokePasswordSessionsLocked(state: inout State, userId: String, now: Date,
                                             reason: String) -> PasswordSessionRevocation {
        var families = Set(state.accountSurface.sessionFamilies.compactMap { $0.value.userId == userId ? $0.key : nil })
        for session in state.accountSurface.sessions.values where session.userId == userId { families.insert(session.familyId) }
        let access = state.accountSurface.accessTokens.filter { $0.value == userId }.map(\.key)
        for token in access {
            if let family = state.accountSurface.accessTokenFamilies[token] { families.insert(family) }
            state.accountSurface.accessTokens.removeValue(forKey: token)
            state.accountSurface.accessTokenFamilies.removeValue(forKey: token)
        }
        for receipt in state.accountSurface.rotationReceipts.values where receipt.userId == userId { families.insert(receipt.familyId) }
        for family in families {
            state.accountSurface.revokedFamilies.insert(family)
            state.accountSurface.sessionFamilies[family]?.revokedAt = now
            state.accountSurface.sessionFamilies[family]?.revokedReason = reason
            state.accountSurface.sessionFamilies[family]?.capabilityRetainUntil = now.addingTimeInterval(30 * 24 * 60 * 60)
        }
        state.accountSurface.sessions = state.accountSurface.sessions.filter { $0.value.userId != userId }
        state.accountSurface.rotationReceipts = state.accountSurface.rotationReceipts.filter { $0.value.userId != userId }
        state.accountSurface.predecessorFamilies = state.accountSurface.predecessorFamilies.filter { !families.contains($0.value) }
        state.passwordResetTokens = state.passwordResetTokens.filter { $0.value.userId != userId }
        return PasswordSessionRevocation(userId: userId, familyIds: families.sorted())
    }
}
