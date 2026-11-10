import Foundation
import Testing
@testable import RaftHTTP

// The auth account row is part of the version-1 opaque snapshot. This batch adds
// one new field group (survey role/time and the account-global first-onboarding
// pair). The old writer did not know those keys at all, so a row with none of
// them is the old shape and decodes the new facts as unknown/nil. Any other
// partial group, wrong JSON type/date, or missing pre-existing required key must
// reject the snapshot before the store changes (see
// `Sources/RaftHTTP/Persistence/AuthProfilePersistenceAccountRows.swift`).
//
// The codec's Date representation is the reference-date IEEE-754 bit pattern
// printed as hex; the new Date fields must keep exactly that spelling.

private enum SnapshotTestError: Error { case shape }

private let snapshotEmail = "snapshot-account@slock.test"
private let snapshotId = "11111111-1111-4111-8111-111111112018"
private let snapshotFamily = "30000000-0000-4000-8000-00000000000f"
private let profileAt = Date(timeIntervalSinceReferenceDate: 700_000_000.125)
private let surveyAt = Date(timeIntervalSinceReferenceDate: 700_000_100.25)
private let onboardingAt = Date(timeIntervalSinceReferenceDate: 700_000_200.75)

private func snapshotAccount(
    signupRole: String? = "engineering_leader",
    signupSurveyCompletedAt: Date? = surveyAt,
    firstOnboardingCompletedAt: Date? = onboardingAt,
    firstOnboardingCompletedSessionFamilyId: String? = snapshotFamily
) -> Account {
    Account(
        id: snapshotId,
        email: snapshotEmail,
        passwordHash: "argon2-placeholder",
        passwordCredentialEstablishedAt: profileAt,
        displayLanguage: "en",
        name: "snapshot-account",
        displayName: "Snapshot Account",
        profileSetupSuggestedHandle: "snapshot-account",
        profileSetupProvider: "google",
        profileSetupCompletedAt: profileAt,
        avatarUrl: "/api/avatars/users/snapshot.webp",
        description: "snapshot description",
        shareUsageData: true,
        emailVerified: true,
        stagingSelfAccountCapabilityHash: nil,
        retiredAt: nil,
        preferredLanguage: "ja",
        preferredTimezone: "Asia/Tokyo",
        preferredTranslationMode: "auto",
        autoTranslationEnabled: true,
        preferredTranslationDisplay: "bilingual",
        preferredTimeFormat: "24h",
        preferredMessageBodyFontSize: "md",
        referralSource: "other",
        referralSourceOther: "local meetup",
        referralSourceSkippedAt: profileAt,
        signupRole: signupRole,
        signupSurveyCompletedAt: signupSurveyCompletedAt,
        firstOnboardingCompletedAt: firstOnboardingCompletedAt,
        firstOnboardingCompletedSessionFamilyId: firstOnboardingCompletedSessionFamilyId
    )
}

private func snapshotStore(_ account: Account) -> AuthProfileStore {
    let store = AuthProfileStore()
    store.state.withLock { state in
        state.accountSurface.accounts[account.email] = account
        state.accountSurface.analyticsIds[account.id] = "20000000-0000-4000-8000-000000000002"
    }
    return store
}

private func snapshotData(_ account: Account) throws -> Data {
    try snapshotStore(account).exportAuthProfilePersistence()
}

private func freshStore(from data: Data) throws -> AuthProfileStore {
    let store = AuthProfileStore()
    try store.restoreAuthProfilePersistence(from: data)
    return store
}

private func snapshotAccountRow(_ data: Data) throws -> [String: Any] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = root["payload"] as? [String: Any],
          let accounts = payload["accounts"] as? [String: Any],
          let row = accounts[snapshotEmail] as? [String: Any]
    else { throw SnapshotTestError.shape }
    return row
}

/// Rewrites only this row of an otherwise untouched exported snapshot, so the
/// test controls the exact JSON the decoder sees.
private func mutateSnapshotRow(_ data: Data, _ mutate: (inout [String: Any]) -> Void) throws -> Data {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var payload = root["payload"] as? [String: Any],
          var accounts = payload["accounts"] as? [String: Any],
          var row = accounts[snapshotEmail] as? [String: Any]
    else { throw SnapshotTestError.shape }
    mutate(&row)
    accounts[snapshotEmail] = row
    payload["accounts"] = accounts
    root["payload"] = payload
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

private let newFactKeys = [
    "signupRole",
    "signupSurveyCompletedAt",
    "firstOnboardingCompletedAt",
    "firstOnboardingCompletedSessionFamilyId",
]

@Test func accountSnapshotRoundTripsTheNewSurveyAndFirstOnboardingFacts() throws {
    let source = snapshotAccount()
    let exported = try snapshotStore(source).exportAuthProfilePersistence()

    // The current writer always publishes the whole group, and the Date fields
    // keep the codec's reference-date bit spelling.
    let row = try snapshotAccountRow(exported)
    #expect(Set(newFactKeys).isSubset(of: Set(row.keys)))
    #expect(row["signupRole"] as? String == "engineering_leader")
    #expect(row["signupSurveyCompletedAt"] as? String
        == String(surveyAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16))
    #expect(row["firstOnboardingCompletedAt"] as? String
        == String(onboardingAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16))
    #expect(row["firstOnboardingCompletedSessionFamilyId"] as? String == snapshotFamily)

    let restored = try freshStore(from: exported)
    let restoredAccount = try #require(restored.account(userId: snapshotId))
    let before = AuthUserDTO(account: source)
    let after = AuthUserDTO(account: restoredAccount)
    #expect(before == after)
    #expect(before.signupRole == "engineering_leader")
    #expect(before.signupSurveyCompletedAt == DateText.iso8601(surveyAt))
    let service = AuthProfileService(store: restored)
    #expect(service.firstOnboardingCompletion(userId: snapshotId)
        == FirstOnboardingCompletion(completedAt: onboardingAt, sessionFamilyId: snapshotFamily))
}

@Test func oldVersionOneRowWithoutTheWholeGroupRestoresTheNewFactsAsNil() throws {
    let source = snapshotAccount()
    let current = try snapshotData(source)
    let oldShape = try mutateSnapshotRow(current) { row in
        for key in newFactKeys { row.removeValue(forKey: key) }
    }
    let oldRow = try snapshotAccountRow(oldShape)
    #expect(newFactKeys.allSatisfy { !oldRow.keys.contains($0) })

    let restored = try freshStore(from: oldShape)
    let account = try #require(restored.account(userId: snapshotId))
    #expect(account.signupRole == nil)
    #expect(account.signupSurveyCompletedAt == nil)
    #expect(account.firstOnboardingCompletedAt == nil)
    #expect(account.firstOnboardingCompletedSessionFamilyId == nil)
    // Everything the old writer did know stays byte-identical on the wire.
    var nilFacts = source
    nilFacts.signupRole = nil
    nilFacts.signupSurveyCompletedAt = nil
    nilFacts.firstOnboardingCompletedAt = nil
    nilFacts.firstOnboardingCompletedSessionFamilyId = nil
    #expect(AuthUserDTO(account: account) == AuthUserDTO(account: nilFacts))
    let service = AuthProfileService(store: restored)
    #expect(service.firstOnboardingCompletion(userId: snapshotId) == nil)
}

@Test func partialNewFieldGroupRejectsWithoutPartialRestore() throws {
    let exported = try snapshotData(snapshotAccount())
    let partial = try mutateSnapshotRow(exported) { row in
        row.removeValue(forKey: "firstOnboardingCompletedSessionFamilyId")
    }

    let target = snapshotStore(Account(
        id: "11111111-1111-4111-8111-111111112019",
        email: "untouched-target@slock.test",
        passwordHash: "target-hash",
        passwordCredentialEstablishedAt: profileAt,
        displayLanguage: nil,
        name: "untouched-target",
        profileSetupSuggestedHandle: nil,
        profileSetupProvider: nil,
        profileSetupCompletedAt: profileAt
    ))
    #expect(throws: AuthProfilePersistence.Failure.invalidSnapshot) {
        try target.restoreAuthProfilePersistence(from: partial)
    }
    #expect(target.account(userId: snapshotId) == nil)
    #expect(target.accountState.accounts.count == 1)
    #expect(target.account(userId: "11111111-1111-4111-8111-111111112019") != nil)
}

@Test func invalidNewFactTypesAndDatesRejectTheWholeSnapshot() throws {
    let exported = try snapshotData(snapshotAccount())
    let corruptions: [(String, Any)] = [
        ("signupRole", 5),
        ("signupRole", true),
        ("signupSurveyCompletedAt", "not-a-date"),
        ("firstOnboardingCompletedAt", 12.5),
        ("firstOnboardingCompletedSessionFamilyId", ["not", "a", "string"]),
    ]
    for (key, value) in corruptions {
        let corrupted = try mutateSnapshotRow(exported) { row in
            row[key] = value
        }
        #expect(throws: AuthProfilePersistence.Failure.invalidSnapshot, Comment(rawValue: key)) {
            try freshStore(from: corrupted)
        }
    }
    // A date that decodes but is not finite must reject too.
    let infinite = try mutateSnapshotRow(exported) { row in
        row["firstOnboardingCompletedAt"] = "7ff0000000000000"
    }
    #expect(throws: AuthProfilePersistence.Failure.invalidSnapshot) {
        try freshStore(from: infinite)
    }
}

@Test func missingPreExistingRequiredKeyRejectsBothShapes() throws {
    let exported = try snapshotData(snapshotAccount())
    let currentShapeMissingKey = try mutateSnapshotRow(exported) { row in
        row.removeValue(forKey: "referralSourceSkippedAt")
    }
    #expect(throws: AuthProfilePersistence.Failure.invalidSnapshot) {
        try freshStore(from: currentShapeMissingKey)
    }

    let oldShapeMissingKey = try mutateSnapshotRow(exported) { row in
        for key in newFactKeys { row.removeValue(forKey: key) }
        row.removeValue(forKey: "emailVerified")
    }
    #expect(throws: AuthProfilePersistence.Failure.invalidSnapshot) {
        try freshStore(from: oldShapeMissingKey)
    }
}
