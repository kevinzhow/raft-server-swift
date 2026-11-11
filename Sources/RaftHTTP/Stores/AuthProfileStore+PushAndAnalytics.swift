import Foundation

// MARK: - Managed MCP lifecycle: profile completion and push capability sections

/// Result of the locked profile completion. The store decides; the service
/// maps a refusal to its published `ManagedMCPLifecycleError`.
enum ProfileCompletionOutcome: Equatable {
    case unknownAccount
    /// The same name pair was already completed; the stored row is replayed.
    case replay(Account)
    case alreadyCompleted
    case nameTaken
    case completed(Account)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.unknownAccount, .unknownAccount), (.alreadyCompleted, .alreadyCompleted),
             (.nameTaken, .nameTaken):
            true
        case (.replay(let left), .replay(let right)), (.completed(let left), .completed(let right)):
            left.id == right.id && left.name == right.name
        default:
            false
        }
    }
}

/// Result of the locked push-family revocation.
enum PushFamilyRevocation: Equatable, Sendable {
    /// No family owns the capability nonce, or its retention window ended.
    case invalid
    /// The family was revoked earlier and the capability is still retained.
    case alreadyRevoked
    case revoked
}

extension AuthProfileStore {
    /// Completes the profile in one critical section: the unknown-account
    /// check, the completed-replay check, the taken-name check and the write
    /// cannot interleave with another account write.
    func completeProfile(userId: String, name: String, displayName: String, now: Date) -> ProfileCompletionOutcome {
        return state.withLock { state in
            guard let key = state.accountSurface.accounts.first(where: { $0.value.id == userId })?.key,
                  var account = state.accountSurface.accounts[key]
            else { return .unknownAccount }
            if account.profileSetupCompletedAt != nil {
                // Upstream `userService.completeProfile` replays only an exact
                // payload: `existing.name !== name || existing.displayName !==
                // displayName`. The stored display name is compared as stored;
                // it is never stood in for by the handle, because a completed
                // account may legitimately carry a null display name after
                // `PATCH /api/auth/me` cleared it.
                let replay = account.name == name && account.displayName == displayName
                return replay ? .replay(account) : .alreadyCompleted
            }
            let lowered = name.lowercased()
            let taken = Set(state.accountSurface.accounts.values.filter { $0.id != userId }.map { $0.name.lowercased() })
            guard !taken.contains(lowered) else { return .nameTaken }
            account.name = name
            account.displayName = displayName
            account.profileSetupCompletedAt = now
            // Upstream clears the editable suggestion when it writes the final
            // identity, so a completed public user publishes null here.
            account.profileSetupSuggestedHandle = nil
            state.accountSurface.accounts[key] = account
            return .completed(account)
        }
    }

    /// The user and session family behind an access token for the push routes.
    /// Unlike `userId(forAccessToken:)` it does not consult the revoked-family
    /// set: the push routes only ever checked the token table.
    func pushPrincipal(accessToken token: String) -> (userId: String, familyId: String?)? {
        return state.withLock { state in
            guard let userId = state.accountSurface.accessTokens[token] else { return nil }
            return (userId, state.accountSurface.accessTokenFamilies[token])
        }
    }

    /// Ensures the principal's session family exists and carries a revoke
    /// capability nonce, and answers `<familyId>.<nonce>`, in one critical
    /// section so two registrations cannot mint different nonces.
    func ensurePushRevokeCapability(userId: String, familyId existingFamilyId: String?) -> (familyId: String, capability: String) {
        return state.withLock { state in
            let familyId = existingFamilyId ?? UUID().uuidString.lowercased()
            if state.accountSurface.sessionFamilies[familyId] == nil {
                state.accountSurface.sessionFamilies[familyId] = SessionFamily(userId: userId)
            }
            var nonce = state.accountSurface.sessionFamilies[familyId]?.revokeCapabilityNonce
            if nonce == nil {
                let minted = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
                state.accountSurface.sessionFamilies[familyId]?.revokeCapabilityNonce = minted
                nonce = minted
            }
            return (familyId, "\(familyId).\(nonce ?? "")")
        }
    }

    /// Revokes the session family that owns the capability nonce and drops its
    /// refresh sessions and access tokens, in one critical section.
    func revokePushFamily(nonce: String, now: Date) -> PushFamilyRevocation {
        return state.withLock { state in
            guard let familyId = state.accountSurface.sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == nonce })?.key,
                  var family = state.accountSurface.sessionFamilies[familyId]
            else { return .invalid }
            if family.revokedAt != nil {
                if let retain = family.capabilityRetainUntil, retain > now { return .alreadyRevoked }
                return .invalid
            }
            family.revokedAt = now
            family.revokedReason = "push_family"
            family.capabilityRetainUntil = now.addingTimeInterval(30 * 24 * 60 * 60)
            state.accountSurface.sessionFamilies[familyId] = family
            for (token, _) in state.accountSurface.sessions.filter({ $0.value.familyId == familyId }) {
                state.accountSurface.sessions.removeValue(forKey: token)
            }
            for token in state.accountSurface.accessTokenFamilies.filter({ $0.value == familyId }).map(\.key) {
                state.accountSurface.accessTokens.removeValue(forKey: token)
                state.accountSurface.accessTokenFamilies.removeValue(forKey: token)
            }
            return .revoked
        }
    }
}

extension AuthProfileStore {
    /// The first account whose handle equals `name` ignoring case, in the
    /// ledger's dictionary order (the joint-channel invitee lookup).
    func firstAccount(caseInsensitiveName name: String) -> Account? {
        return state.withLock { state in
            return state.accountSurface.accounts.values.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }
}

// MARK: - Analytics identity and push family revoke

extension AuthProfileStore {
    /// The user's analytics id, minted on first use. Lookup and mint are one
    /// critical section, so two concurrent first events share one id.
    func analyticsId(userId: String) -> String {
        return state.withLock { state in
            if let existing = state.accountSurface.analyticsIds[userId] { return existing }
            let minted = UUID().uuidString.lowercased()
            state.accountSurface.analyticsIds[userId] = minted
            return minted
        }
    }

    /// Resolves a `push/family-revoke` capability (`<familyId>.<nonce>`)
    /// without consuming it.
    func familyRevokeTarget(capability: String) -> (userId: String, familyId: String)? {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return state.withLock { state in
            guard let familyId = state.accountSurface.sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key,
                  let family = state.accountSurface.sessionFamilies[familyId]
            else { return nil }
            return (family.userId, familyId)
        }
    }
}
