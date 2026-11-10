import Foundation

/// The account-global facts the server setup projection and handoff command need.
///
/// They live on the Auth account, not on the server's membership row:
///
/// * `surveyCompleted` reads `users.signup_survey_completed_at`. Upstream
///   `ownerSurveyPending` is `owner.signupSurveyCompletedAt === null`
///   (services/serverSetupStateService.ts:825-836).
/// * `recordFirstOnboarding` is the account-global, first-time-only
///   `firstOnboardingCompletedAt` / `firstOnboardingCompletedSessionFamilyId`
///   write of the "Let's Go" command (services/serverService.ts:1556-1569).
///
/// BATCH-INTEGRATION: the Auth account fields (`signupRole`,
/// `signupSurveyCompletedAt`, `firstOnboardingCompletedAt`,
/// `firstOnboardingCompletedSessionFamilyId`) and their strict AccountRow codec
/// are owned by the Auth account slice. This protocol is the seam: the setup
/// service never reads the account record itself. The Auth slice supplies an
/// implementation backed by `AuthProfileStore`; until it lands,
/// `UnavailableSetupAccountFacts` keeps the current minimal state (no recorded
/// survey answer, no account-global record).
public protocol SetupAccountFacts: Sendable {
    /// True only when this account already answered the signup survey. Knowing
    /// nothing about the answer is `false`: the owner still owes the survey.
    func surveyCompleted(userId: String) -> Bool

    /// Records the account-global first onboarding completion. Called on every
    /// accepted handoff command; the implementation keeps only the first write
    /// and its session family (`null` when the session carries none).
    func recordFirstOnboarding(userId: String, at date: Date, sessionFamilyId: String?)
}

/// Minimal existing-state implementation of the Auth seam.
///
/// BATCH-INTEGRATION: replace with the `AuthProfileStore`-backed implementation
/// of the survey/account-global fields. `surveyCompleted` reports false
/// (unknown, so owed) and the account-global record is a no-op; the retained
/// receipt, not this facade, is what the projection reads for the handoff.
public struct UnavailableSetupAccountFacts: SetupAccountFacts {
    public init() {}

    public func surveyCompleted(userId: String) -> Bool { false }

    public func recordFirstOnboarding(userId: String, at date: Date, sessionFamilyId: String?) {
        // BATCH-INTEGRATION: first-time-only account-global write, owned by the
        // Auth account slice. There is no account record for this fact here, so
        // recording nothing is the only honest implementation.
    }
}
