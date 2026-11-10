import Foundation

/// The account-global facts the server setup projection and handoff command need.
///
/// They live on the Auth account, not on the server's membership row:
///
/// * `surveyCompleted` reads `users.signup_survey_completed_at`. Upstream
///   `ownerSurveyPending` is `!!owner && owner.signupSurveyCompletedAt === null`
///   (services/serverSetupStateService.ts:807-847): a missing owner account is
///   not pending.
/// * `recordFirstOnboarding` is the account-global, first-time-only
///   `firstOnboardingCompletedAt` / `firstOnboardingCompletedSessionFamilyId`
///   write of the "Let's Go" command (services/serverService.ts:1556-1569).
///
/// This protocol is the seam: the setup service never reads the account record
/// itself. `AuthProfileSetupAccountFacts` is the production implementation over
/// the Auth account store; tests supply fixed answers.
public protocol SetupAccountFacts: Sendable {
    /// Whether this account already answered the signup survey.
    ///
    /// `nil` means the account row does not exist. Upstream fails open: a
    /// missing owner owes nothing, so an unknown account is not an unanswered
    /// survey and must not create a personal task.
    func surveyCompleted(userId: String) -> Bool?

    /// Records the account-global first onboarding completion. Called on every
    /// accepted handoff command; the implementation keeps only the first write
    /// and its session family (`null` when the session carries none).
    func recordFirstOnboarding(userId: String, at date: Date, sessionFamilyId: String?)
}

/// Production `SetupAccountFacts` over the Auth account owner.
///
/// The account-global facts are retained by `AuthProfileStore` in the same
/// critical section as the rest of the account row, including the strict
/// AccountRow persistence codec. The survey answer is the completion stamp the
/// `PATCH /api/auth/me` profile write already stamps; the first-onboarding pair
/// is only written by the first accepted handoff.
struct AuthProfileSetupAccountFacts: SetupAccountFacts {
    let accounts: AuthProfileStore

    init(accounts: AuthProfileStore) {
        self.accounts = accounts
    }

    func surveyCompleted(userId: String) -> Bool? {
        accounts.account(userId: userId).map { $0.signupSurveyCompletedAt != nil }
    }

    func recordFirstOnboarding(userId: String, at date: Date, sessionFamilyId: String?) {
        accounts.recordFirstOnboardingCompletion(
            userId: userId,
            at: date,
            sessionFamilyId: sessionFamilyId
        )
    }
}
