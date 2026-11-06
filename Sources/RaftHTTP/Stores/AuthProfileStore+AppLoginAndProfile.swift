import Foundation

extension AuthProfileStore {
    // MARK: App login

    func insertAppLoginRequest(_ request: AppLoginRequest) {
        lock.lock()
        accountSurface.appLoginRequests[request.id] = request
        lock.unlock()
    }

    func appLoginRequest(id: String) -> AppLoginRequest? {
        lock.lock()
        defer { lock.unlock() }
        return accountSurface.appLoginRequests[id]
    }

    /// Approves or denies one request. The expiry check, the pending check and
    /// the status write are one critical section, so a request cannot be both
    /// approved and denied.
    func decideAppLogin(
        requestId: String,
        decision: AppLoginDecision,
        now: Date
    ) -> AppLoginDecisionOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard var request = accountSurface.appLoginRequests[requestId] else { return .notFound }
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
        accountSurface.appLoginRequests[requestId] = request
        return .decided(request)
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
        lock.lock()
        defer { lock.unlock() }
        guard let request = accountSurface.appLoginRequests.values.first(where: { $0.code == code }) else {
            return .codeNotFound
        }
        if request.consumedAt != nil { return .codeConsumed }
        if request.expiresAt <= now { return .codeExpired }
        guard verifierChallenge == request.codeChallenge else { return .pkceMismatch }
        guard let userId = request.userId else { return .notApproved }
        var approved = request
        approved.consumedAt = now
        accountSurface.appLoginRequests[approved.id] = approved
        guard let account = accountSurface.accounts.values.first(where: { $0.id == userId }) else {
            return .accountMissing
        }
        return .completed(account, openSessionLocked(userId: userId))
    }

    // MARK: Profile writes

    /// Replaces the password when the current one matches. The compare and the
    /// write are one critical section.
    func changePassword(userId: String, currentHash: String, newHash: String) -> ChangePasswordOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard var account = accountSurface.accounts.values.first(where: { $0.id == userId }) else {
            return .accountMissing
        }
        guard account.passwordHash == currentHash else { return .wrongPassword }
        account.passwordHash = newHash
        accountSurface.accounts[account.email] = account
        return .changed
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
        lock.lock()
        defer { lock.unlock() }
        guard var account = accountSurface.accounts.values.first(where: { $0.id == userId }) else {
            return nil
        }
        var changed = false
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
                if accountSurface.analyticsIds[account.id] == nil {
                    accountSurface.analyticsIds[account.id] = newAnalyticsId
                }
            } else if share == false {
                accountSurface.analyticsIds.removeValue(forKey: account.id)
            }
            changed = true
        }
        if changed {
            accountSurface.accounts[account.email] = account
        }
        return account
    }

    /// Stores a new avatar path and returns the stored row, or `nil` when the
    /// account no longer exists.
    func setAvatarURL(userId: String, url: String) -> Account? {
        lock.lock()
        defer { lock.unlock() }
        guard var account = accountSurface.accounts.values.first(where: { $0.id == userId }) else {
            return nil
        }
        account.avatarUrl = url
        accountSurface.accounts[account.email] = account
        return account
    }

    /// The first/last timezone pair `me` appends once a user reported one.
    func timezoneObservation(userId: String) -> TimezoneObservation? {
        lock.lock()
        defer { lock.unlock() }
        return profile.timezoneObservations[userId]
    }
}
