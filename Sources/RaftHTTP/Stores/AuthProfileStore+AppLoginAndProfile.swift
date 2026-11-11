import Foundation

extension AuthProfileStore {
    // MARK: App login

    func insertAppLoginRequest(_ request: AppLoginRequest) {
        state.withLock { state in
            state.accountSurface.appLoginRequests[request.id] = request
        }
    }

    func appLoginRequest(id: String) -> AppLoginRequest? {
        return state.withLock { state in
            return state.accountSurface.appLoginRequests[id]
        }
    }

    /// Approves or denies one request. The expiry check, the pending check and
    /// the status write are one critical section, so a request cannot be both
    /// approved and denied.
    func decideAppLogin(
        requestId: String,
        decision: AppLoginDecision,
        now: Date
    ) -> AppLoginDecisionOutcome {
        return state.withLock { state in
            guard var request = state.accountSurface.appLoginRequests[requestId] else { return .notFound }
            if request.expiresAt <= now { return .expired(request) }
            guard request.status == "pending" else { return .notPending }
            switch decision {
            case .approve(let userId, let code):
                request.status = "approved"
                request.code = code
                request.userId = userId
            case .deny:
                request.status = "denied"
            }
            state.accountSurface.appLoginRequests[requestId] = request
            return .decided(request)
        }
    }

    /// Spends one approved request's code. The code lookup, the consumed/expiry
    /// checks, the PKCE comparison, the consumed stamp and the session open are
    /// one critical section: a wrong verifier burns nothing, and two concurrent
    /// completions of one code cannot both open a session.
    func completeAppLogin(
        code: String,
        verifierChallenge: String,
        now: Date
    ) -> CompleteAppLoginOutcome {
        return state.withLock { state in
            guard let request = state.accountSurface.appLoginRequests.values.first(where: { $0.code == code }) else {
                return .codeNotFound
            }
            if request.consumedAt != nil { return .codeConsumed }
            if request.expiresAt <= now { return .codeExpired }
            guard verifierChallenge == request.codeChallenge else { return .pkceMismatch }
            guard let userId = request.userId else { return .notApproved }
            var approved = request
            approved.consumedAt = now
            state.accountSurface.appLoginRequests[approved.id] = approved
            guard let account = state.accountSurface.accounts.values.first(where: { $0.id == userId }) else {
                return .accountMissing
            }
            return .completed(account, Self.openSessionLocked(state: &state, userId: userId))
        }
    }

    // MARK: Profile writes

    /// Replaces the password when the current one matches. The compare and the
    /// write are one critical section.
    func changePassword(userId: String, currentHash: String, newHash: String,
                        authorizationToken: String, now: Date) -> ChangePasswordOutcome {
        return state.withLock { state in
            guard var account = state.accountSurface.accounts.values.first(where: { $0.id == userId }),
                  account.retiredAt == nil,
                  state.accountSurface.accessTokens[authorizationToken] == userId else { return .accountMissing }
            if let family = state.accountSurface.accessTokenFamilies[authorizationToken],
               state.accountSurface.revokedFamilies.contains(family) { return .accountMissing }
            guard account.passwordHash == currentHash else { return .wrongPassword }
            account.passwordHash = newHash
            account.passwordCredentialEstablishedAt = now
            state.accountSurface.accounts[account.email] = account
            return .changed(Self.revokePasswordSessionsLocked(state: &state, userId: userId, now: now, reason: "password_changed"))
        }
    }

    /// Applies every validated profile field and the analytics-id mapping the
    /// usage opt-in controls in one critical section and returns the stored
    /// row. `nil` means the account no longer exists and nothing was written.
    func applyProfileUpdate(
        userId: String,
        update: AccountProfileUpdate,
        now: Date,
        newAnalyticsId: String
    ) -> Account? {
        return state.withLock { state in
            guard var account = state.accountSurface.accounts.values.first(where: { $0.id == userId }) else {
                return nil
            }
            var changed = false
            if let displayName = update.displayName {
                account.displayName = displayName
                changed = true
            }
            if let description = update.description {
                account.description = description
                changed = true
            }
            // The survey role and its completion time are one fact: a present
            // role (JSON null included) always stamps this request's time.
            if let role = update.signupRole {
                account.signupRole = role
                account.signupSurveyCompletedAt = now
                changed = true
            }
            if let value = update.referralSource {
                account.referralSource = value
                account.referralSourceSkippedAt = nil
                changed = true
            }
            if let value = update.referralSourceOther {
                account.referralSourceOther = value
                changed = true
            }
            if update.referralSourceSkipped {
                account.referralSourceSkippedAt = now
                changed = true
            }
            if let value = update.preferredLanguage { account.preferredLanguage = value; changed = true }
            if let value = update.preferredTimezone { account.preferredTimezone = value; changed = true }
            if let value = update.preferredTranslationMode { account.preferredTranslationMode = value; changed = true }
            if let value = update.autoTranslationEnabled { account.autoTranslationEnabled = value; changed = true }
            if let value = update.preferredTranslationDisplay { account.preferredTranslationDisplay = value; changed = true }
            if let value = update.preferredTimeFormat { account.preferredTimeFormat = value; changed = true }
            if let value = update.preferredMessageBodyFontSize { account.preferredMessageBodyFontSize = value; changed = true }
            if let language = update.displayLanguage {
                account.displayLanguage = language
                changed = true
            }
            if let share = update.shareUsageData {
                account.shareUsageData = share
                if share == true {
                    if state.accountSurface.analyticsIds[account.id] == nil {
                        state.accountSurface.analyticsIds[account.id] = newAnalyticsId
                    }
                } else if share == false {
                    state.accountSurface.analyticsIds.removeValue(forKey: account.id)
                }
                changed = true
            }
            if changed {
                state.accountSurface.accounts[account.email] = account
            }
            return account
        }
    }

    /// Stores a new avatar path and returns the stored row, or `nil` when the
    /// account no longer exists.
    func setAvatarURL(userId: String, url: String) -> Account? {
        return state.withLock { state in
            guard var account = state.accountSurface.accounts.values.first(where: { $0.id == userId }) else {
                return nil
            }
            account.avatarUrl = url
            state.accountSurface.accounts[account.email] = account
            return account
        }
    }

    /// The first/last timezone pair `me` appends once a user reported one.
    func timezoneObservation(userId: String) -> TimezoneObservation? {
        return state.withLock { state in
            return state.profile.timezoneObservations[userId]
        }
    }

    /// Upstream `getProfileSetupProvider`: the first linked identity row for
    /// the account, in insertion order.
    func profileSetupProvider(userId: String) -> String? {
        state.withLock { state in
            state.accountSurface.linkedIdentities.first { $0.userId == userId }?.provider
        }
    }
}
