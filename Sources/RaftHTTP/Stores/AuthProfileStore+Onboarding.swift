import Foundation

// The account-global first-onboarding pair. Upstream keeps both facts on the
// `users` row and writes them from the first final setup handoff only:
// `markSetupHandoffAcknowledged` updates `first_onboarding_completed_at` and
// `first_onboarding_completed_session_family_id` while the time is null
// (`services/serverService.ts:1533-1570`, columns at `db/schema.ts:97-98`).
// A retry must therefore keep the original time and family, and a caller with
// no real auth family stores JSON null.
//
// One critical section owns both columns so no interleaving can write a time
// with another command's family.

extension AuthProfileStore {
    /// Records the first final onboarding handoff for one account.
    ///
    /// The first call writes both facts and returns them; later calls return the
    /// retained pair unchanged. `nil` means the account row no longer exists.
    @discardableResult
    func recordFirstOnboardingCompletion(
        userId: String,
        at: Date,
        sessionFamilyId: String?
    ) -> (completedAt: Date, sessionFamilyId: String?)? {
        return state.withLock { state in
            guard let key = state.accountSurface.accounts.first(where: { $0.value.id == userId })?.key,
                  var account = state.accountSurface.accounts[key] else { return nil }
            if let completedAt = account.firstOnboardingCompletedAt {
                return (completedAt, account.firstOnboardingCompletedSessionFamilyId)
            }
            account.firstOnboardingCompletedAt = at
            account.firstOnboardingCompletedSessionFamilyId = sessionFamilyId
            state.accountSurface.accounts[key] = account
            return (at, sessionFamilyId)
        }
    }

    /// The retained pair, or `nil` when the account row is missing or onboarding
    /// has not completed.
    func firstOnboardingCompletion(userId: String) -> (completedAt: Date, sessionFamilyId: String?)? {
        return state.withLock { state in
            guard let account = state.accountSurface.accounts.values.first(where: { $0.id == userId }),
                  let completedAt = account.firstOnboardingCompletedAt else { return nil }
            return (completedAt, account.firstOnboardingCompletedSessionFamilyId)
        }
    }
}
