import Foundation
import Testing
@testable import RaftHTTP

// Upstream `markSetupHandoffAcknowledged` stamps the owner row and the
// account-global first-onboarding pair in one transaction, and only while
// `users.first_onboarding_completed_at` is null
// (`services/serverService.ts:1533-1570`). The account time and the auth
// session family are therefore first-write-wins: a retry keeps the original
// pair, and a caller without a real family stores JSON null.
//
// The pair is account-global and is not part of the published `me` object
// (`services/userService.ts:62-96`).

private let firstOnboardingAt = Date(timeIntervalSinceReferenceDate: 700_000_100.25)
private let laterOnboardingAt = Date(timeIntervalSinceReferenceDate: 700_000_200.5)

@Test func firstOnboardingCompletionKeepsTheFirstTimeAndSessionFamily() throws {
    let scene = AuthServicesUnitFixture()
    let userId = "11111111-1111-4111-8111-111111112013"
    let otherUserId = "11111111-1111-4111-8111-111111112014"
    scene.addAccount(id: userId, email: "first-onboarding@slock.test", password: "password123")
    scene.addAccount(id: otherUserId, email: "second-onboarding@slock.test", password: "password123")
    let service = scene.makeProfileService()

    // A fresh account has not completed onboarding.
    #expect(service.firstOnboardingCompletion(userId: userId) == nil)

    let first = try #require(service.recordFirstOnboardingCompletion(
        userId: userId, at: firstOnboardingAt, sessionFamilyId: "30000000-0000-4000-8000-00000000000b"
    ))
    #expect(first.completedAt == firstOnboardingAt)
    #expect(first.sessionFamilyId == "30000000-0000-4000-8000-00000000000b")
    #expect(service.firstOnboardingCompletion(userId: userId) == first)

    // A retry with a newer time, or from another session family, keeps the
    // original pair; the answer is the retained pair, not the attempted one.
    let retried = try #require(service.recordFirstOnboardingCompletion(
        userId: userId, at: laterOnboardingAt, sessionFamilyId: "30000000-0000-4000-8000-00000000000c"
    ))
    #expect(retried.completedAt == firstOnboardingAt)
    #expect(retried.sessionFamilyId == "30000000-0000-4000-8000-00000000000b")
    #expect(service.firstOnboardingCompletion(userId: userId) == first)

    // The fact is account-global, so a second account keeps its own pair.
    let other = try #require(service.recordFirstOnboardingCompletion(
        userId: otherUserId, at: laterOnboardingAt, sessionFamilyId: "30000000-0000-4000-8000-00000000000d"
    ))
    #expect(other.completedAt == laterOnboardingAt)
    #expect(other.sessionFamilyId == "30000000-0000-4000-8000-00000000000d")
    #expect(service.firstOnboardingCompletion(userId: userId) == first)
}

@Test func firstOnboardingCompletionStoresNoFamilyAsNullAndStaysFirstOnly() throws {
    let scene = AuthServicesUnitFixture()
    let userId = "11111111-1111-4111-8111-111111112015"
    scene.addAccount(id: userId, email: "familyless-onboarding@slock.test", password: "password123")
    let service = scene.makeProfileService()

    let familyless = try #require(service.recordFirstOnboardingCompletion(
        userId: userId, at: firstOnboardingAt, sessionFamilyId: nil
    ))
    #expect(familyless.completedAt == firstOnboardingAt)
    #expect(familyless.sessionFamilyId == nil)

    // A later real family does not replace the null the first command carried.
    let retried = try #require(service.recordFirstOnboardingCompletion(
        userId: userId, at: laterOnboardingAt, sessionFamilyId: "30000000-0000-4000-8000-00000000000e"
    ))
    #expect(retried.completedAt == firstOnboardingAt)
    #expect(retried.sessionFamilyId == nil)
    let stored = try #require(scene.account(userId: userId))
    #expect(stored.firstOnboardingCompletedAt == firstOnboardingAt)
    #expect(stored.firstOnboardingCompletedSessionFamilyId == nil)
}

@Test func firstOnboardingCompletionIgnoresAnUnknownAccount() throws {
    let scene = AuthServicesUnitFixture()
    let service = scene.makeProfileService()
    #expect(service.recordFirstOnboardingCompletion(
        userId: "11111111-1111-4111-8111-111111112016", at: firstOnboardingAt, sessionFamilyId: nil
    ) == nil)
    #expect(service.firstOnboardingCompletion(userId: "11111111-1111-4111-8111-111111112016") == nil)
}

@Test func concurrentFirstOnboardingCommandsRetainOnePair() async throws {
    let scene = AuthServicesUnitFixture()
    let userId = "11111111-1111-4111-8111-111111112017"
    scene.addAccount(id: userId, email: "concurrent-onboarding@slock.test", password: "password123")
    let service = scene.makeProfileService()
    let families = (0..<8).map { "30000000-0000-4000-8000-00000000001\($0)" }

    let retained = try await withThrowingTaskGroup(of: FirstOnboardingCompletion?.self) { group in
        for family in families {
            group.addTask {
                service.recordFirstOnboardingCompletion(
                    userId: userId,
                    at: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(family.suffix(1).count)),
                    sessionFamilyId: family
                )
            }
        }
        var values: [FirstOnboardingCompletion] = []
        for try await value in group {
            values.append(try #require(value))
        }
        return values
    }

    let winner = try #require(service.firstOnboardingCompletion(userId: userId))
    #expect(retained.allSatisfy { $0 == winner })
    let winnerFamily = try #require(winner.sessionFamilyId)
    #expect(families.contains(winnerFamily))
}
