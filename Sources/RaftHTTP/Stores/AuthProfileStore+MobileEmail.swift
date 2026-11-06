import Foundation

extension AuthProfileStore {
    struct MobileEmailOptOut: Sendable {
        let userId: String
        let email: String
        let emailIds: [String]
    }

    /// Contact opt-out and the scheduled-mail selection share one Auth transaction.
    func beginMobileEmailOptOut(userId: String) -> MobileEmailOptOut? {
        state.withLock { state in
            guard let account = state.accountSurface.accounts.values.first(where: { $0.id == userId }) else { return nil }
            let email = AccountNaming.normalize(account.email)
            guard !email.isEmpty else { return nil }
            let audienceId = "mobile-app-lifecycle"
            state.profile.mobileAppEmailContactsByKey["\(audienceId)\n\(email)"] = MobileAppEmailContact(
                userId: userId, email: email, audienceId: audienceId,
                status: "unsubscribed", optedOutAt: Date()
            )
            let emailIds = state.profile.storedMobileAppEmailJourneys.compactMap { row -> String? in
                guard row.journeyKey == "first_computer_mobile_app_48h",
                      row.day1Status == "scheduled",
                      let emailId = row.day1EmailId, !emailId.isEmpty,
                      row.userId == userId || AccountNaming.normalize(row.email) == email
                else { return nil }
                return emailId
            }
            return MobileEmailOptOut(userId: userId, email: email, emailIds: emailIds)
        }
    }

    /// Runs after cancellation, and only changes rows that are still scheduled.
    func finishMobileEmailOptOut(_ optOut: MobileEmailOptOut) {
        state.withLock { state in
            let canceledAt = Date()
            for index in state.profile.storedMobileAppEmailJourneys.indices {
                let row = state.profile.storedMobileAppEmailJourneys[index]
                guard row.journeyKey == "first_computer_mobile_app_48h",
                      row.day1Status == "scheduled", let emailId = row.day1EmailId,
                      optOut.emailIds.contains(emailId),
                      row.userId == optOut.userId || AccountNaming.normalize(row.email) == optOut.email
                else { continue }
                state.profile.storedMobileAppEmailJourneys[index].day1Status = "skipped"
                state.profile.storedMobileAppEmailJourneys[index].suppressedReason = "unsubscribed"
                state.profile.storedMobileAppEmailJourneys[index].canceledAt = canceledAt
            }
        }
    }
}
