import Foundation
import Testing
@testable import RaftHTTP

/// The resend cap, cooldown and insert are one store critical section, so a
/// burst of simultaneous resends for one user can issue exactly one token.
@Test func emailVerificationIssueConcurrency() async {
    let store = AuthProfileStore()
    let userId = "11111111-1111-4111-8111-111111111901"
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let outcomes = await withTaskGroup(of: IssueOutcome.self) { group in
        for index in 0..<20 {
            group.addTask {
                store.issueVerificationTokenIfAllowed(
                    userId: userId,
                    token: "token-\(index)",
                    tokenHash: "hash-\(index)",
                    now: now,
                    ttl: 24 * 60 * 60,
                    hourlyLimit: 5,
                    cooldown: 60
                )
            }
        }
        var collected: [IssueOutcome] = []
        for await outcome in group { collected.append(outcome) }
        return collected
    }

    #expect(outcomes.filter { $0 == .issued }.count == 1)
    #expect(outcomes.filter { $0 == .cooldown }.count == 19)
    #expect(!outcomes.contains(.tooManyRequests))
    // Only the winner replaced the live token; the losers wrote nothing.
    #expect(store.latestVerificationToken(userId: userId)?.createdAt == now)
}
