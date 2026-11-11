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

private func snapshotPayload(_ data: Data) throws -> [String: Any] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = root["payload"] as? [String: Any]
    else { throw SnapshotTestError.shape }
    return payload
}

/// Rewrites only the payload object, leaving the versioned envelope untouched.
private func mutateSnapshotPayload(_ data: Data, _ mutate: (inout [String: Any]) -> Void) throws -> Data {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var payload = root["payload"] as? [String: Any]
    else { throw SnapshotTestError.shape }
    mutate(&payload)
    root["payload"] = payload
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

private func snapshotStoreWithIdentities(_ identities: [LinkedIdentity]) -> AuthProfileStore {
    let store = snapshotStore(snapshotAccount())
    store.state.withLock { state in
        state.accountSurface.linkedIdentities = identities
    }
    return store
}

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

// MARK: - One linked-identity owner

// The pre-batch version-1 payload stored linked sign-in identities twice:
// `identityRows` (the `/api/auth/identities` list/unlink rows) and
// `linkedIdentities` (`profileSetupProvider` and the social link flows). The
// unified owner is one ordered row list. The current writer publishes that list
// plus both retired projections, derived from it, so the previous binary can
// decode a snapshot written here. A snapshot that omits the whole
// `userAuthIdentities` group is the old shape and restores from both legacy
// fields; a partial pair or a malformed row rejects the whole snapshot. When
// the unified list is present it is authoritative and the retired rows are
// shape-checked but never merged, so a stale projection cannot add identities.

private let identityGoogle = LinkedIdentity(
    userId: snapshotId, provider: "google", providerUserId: "google-subject", providerEmail: "google@slock.test"
)
private let identityGithub = LinkedIdentity(
    userId: snapshotId, provider: "github", providerUserId: "github-subject", providerEmail: nil
)
private let identityApple = LinkedIdentity(
    userId: snapshotId, provider: "apple", providerUserId: nil, providerEmail: "apple@slock.test"
)

private func identityShape(_ identity: LinkedIdentity) -> String {
    let subject = identity.providerUserId.map { "subject=\($0)" } ?? "subject=nil"
    let email = identity.providerEmail.map { "email=\($0)" } ?? "email=nil"
    return "\(identity.provider)|\(subject)|\(email)"
}

// A copy of the previous binary's linked-identity decode shape. The previous
// `Payload` required every old top-level key (all of them are unchanged here),
// its `identityRows` row required a non-null provider email, and its
// `linkedIdentities` row required a provider subject. Synthesized Decodable
// ignores the new `userAuthIdentities` key, as the previous binary did.
private struct PreviousEnvelope: Decodable {
    let domain: String
    let version: Int
    let dateEncoding: String
    let payload: PreviousPayload
}

private struct PreviousPayload: Decodable {
    let timezoneObservations: PreviousPresence
    let mobileAppEmailContactsByKey: PreviousPresence
    let storedMobileAppEmailJourneys: PreviousPresence
    let identityRows: [String: [PreviousProviderIdentityRow]]
    let passwordResetTokens: PreviousPresence
    let legalAcceptances: PreviousPresence
    let emailVerificationTokens: PreviousPresence
    let emailVerificationIssueDates: PreviousPresence
    let accounts: PreviousPresence
    let analyticsIds: PreviousPresence
    let sessions: PreviousPresence
    let rotationReceipts: PreviousPresence
    let predecessorFamilies: PreviousPresence
    let revokedFamilies: PreviousPresence
    let sessionFamilies: PreviousPresence
    let retirementReceipts: PreviousPresence
    let accessTokens: PreviousPresence
    let accessTokenFamilies: PreviousPresence
    let appLoginRequests: PreviousPresence
    let socialCompletions: PreviousPresence
    let pendingSocialLinks: PreviousPresence
    let mobileRequests: PreviousPresence
    let consumedHandoffs: PreviousPresence
    let deviceGrants: PreviousPresence
    let deviceUserCodes: PreviousPresence
    let linkedIdentities: [PreviousLinkedIdentityRow]
}

/// Presence-only decoder for the rows this batch did not change.
private struct PreviousPresence: Decodable {
    init(from decoder: any Decoder) throws {
        _ = try decoder.singleValueContainer()
    }
}

private struct PreviousProviderIdentityRow: Decodable, Equatable {
    let provider: String
    let providerEmail: String

    init(provider: String, providerEmail: String) {
        self.provider = provider
        self.providerEmail = providerEmail
    }
}

private struct PreviousLinkedIdentityRow: Decodable, Equatable {
    let userId: String
    let provider: String
    let providerUserId: String
    let providerEmail: String?

    init(userId: String, provider: String, providerUserId: String, providerEmail: String?) {
        self.userId = userId
        self.provider = provider
        self.providerUserId = providerUserId
        self.providerEmail = providerEmail
    }

    private enum CodingKeys: String, CodingKey {
        case userId
        case provider
        case providerUserId
        case providerEmail
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userId = try values.decode(String.self, forKey: .userId)
        provider = try values.decode(String.self, forKey: .provider)
        providerUserId = try values.decode(String.self, forKey: .providerUserId)
        providerEmail = try values.decode(String?.self, forKey: .providerEmail)
    }
}

@Test func expandedSnapshotWritesBothRetiredProjectionsFromTheOneOwner() throws {
    let identities = [identityGoogle, identityGithub, identityApple]
    let exported = try snapshotStoreWithIdentities(identities).exportAuthProfilePersistence()
    let payload = try snapshotPayload(exported)

    // The unified list keeps the canonical nullable subject/email.
    let unified = try #require(payload["userAuthIdentities"] as? [[String: Any]])
    #expect(unified.map { $0["provider"] as? String } == ["google", "github", "apple"])
    #expect(unified[0]["providerUserId"] as? String == "google-subject")
    #expect(unified[1]["providerEmail"] is NSNull)
    #expect(unified[2]["providerUserId"] is NSNull)

    // `identityRows` is the old list shape: provider + non-null email, per-user
    // array order, and a row without an email has no representation there.
    let identityRows = try #require(payload["identityRows"] as? [String: [[String: Any]]])
    #expect(Set(identityRows.keys) == [snapshotId])
    let listRows = try #require(identityRows[snapshotId])
    #expect(listRows.map { $0["provider"] as? String } == ["google", "apple"])
    #expect(listRows.map { $0["providerEmail"] as? String } == ["google@slock.test", "apple@slock.test"])

    // `linkedIdentities` is the old ordered array shape. It always carries a
    // subject (the empty placeholder for an unknown one) and a nullable email.
    let linked = try #require(payload["linkedIdentities"] as? [[String: Any]])
    #expect(linked.map { $0["provider"] as? String } == ["google", "github", "apple"])
    #expect(linked[0]["providerUserId"] as? String == "google-subject")
    #expect(linked[1]["providerEmail"] is NSNull)
    #expect(linked[2]["providerUserId"] as? String == "")
    #expect(linked[2]["providerEmail"] as? String == "apple@slock.test")

    let restored = try freshStore(from: exported)
    #expect(restored.linkedIdentities.map(identityShape) == identities.map(identityShape))
    #expect(restored.profileSetupProvider(userId: snapshotId) == "google")
    let methods = restored.identitySnapshot(userId: snapshotId)
    #expect(methods.rows.map(\.provider) == ["google", "github", "apple"])
    #expect(methods.rows.map { $0.providerEmail as String? } == ["google@slock.test", nil, "apple@slock.test"])
    #expect(methods.passwordConfigured)

    // The unified list is authoritative and both projections derive from it, so
    // export -> restore -> export is byte-identical.
    let reexported = try restored.exportAuthProfilePersistence()
    #expect(reexported == exported)
    let twiceRestored = try freshStore(from: reexported)
    #expect(twiceRestored.linkedIdentities.map(identityShape) == identities.map(identityShape))
}

@Test func previousBinaryStrictCodecDecodesTheExpandedSnapshotForRollback() throws {
    let identities = [identityGoogle, identityGithub, identityApple]
    let exported = try snapshotStoreWithIdentities(identities).exportAuthProfilePersistence()

    // This is the previous binary's whole envelope/payload key set, decoded with
    // the previous strict row shapes. A new unknown `userAuthIdentities` key is
    // ignored exactly as the old synthesized decoder ignored it.
    let previous = try JSONDecoder().decode(PreviousEnvelope.self, from: exported)
    #expect(previous.domain == "raft.auth-profile")
    #expect(previous.version == 1)
    #expect(previous.dateEncoding == "reference-seconds-ieee754-hex")
    #expect(previous.payload.identityRows == [
        snapshotId: [
            PreviousProviderIdentityRow(provider: "google", providerEmail: "google@slock.test"),
            PreviousProviderIdentityRow(provider: "apple", providerEmail: "apple@slock.test"),
        ],
    ])
    #expect(previous.payload.linkedIdentities == [
        PreviousLinkedIdentityRow(
            userId: snapshotId, provider: "google",
            providerUserId: "google-subject", providerEmail: "google@slock.test"
        ),
        PreviousLinkedIdentityRow(
            userId: snapshotId, provider: "github",
            providerUserId: "github-subject", providerEmail: nil
        ),
        PreviousLinkedIdentityRow(
            userId: snapshotId, provider: "apple",
            providerUserId: "", providerEmail: "apple@slock.test"
        ),
    ])
    // The previous `profileSetupProvider` is the first linked row of the account.
    #expect(previous.payload.linkedIdentities.first(where: { $0.userId == snapshotId })?.provider == "google")

    // A rollback binary reads this snapshot, then rewrites its two legacy fields
    // when it next saves. Re-expanding that snapshot must coalesce the two
    // representations per account/provider instead of duplicating identities.
    let oldShape = try mutateSnapshotPayload(exported) { payload in
        payload.removeValue(forKey: "userAuthIdentities")
    }
    let restored = try freshStore(from: oldShape)
    #expect(restored.linkedIdentities.map(identityShape) == identities.map(identityShape))
    #expect(restored.profileSetupProvider(userId: snapshotId) == "google")
}

@Test func unifiedOwnerIgnoresDisagreeingRetiredProjections() throws {
    let identities = [identityGoogle]
    let exported = try snapshotStoreWithIdentities(identities).exportAuthProfilePersistence()
    let conflicting = try mutateSnapshotPayload(exported) { payload in
        payload["identityRows"] = [
            snapshotId: [
                ["provider": "github", "providerEmail": "stale@slock.test"],
                ["provider": "google", "providerEmail": "google@slock.test"],
            ],
        ]
        payload["linkedIdentities"] = [[
            "userId": snapshotId,
            "provider": "apple",
            "providerUserId": "stale-subject",
            "providerEmail": "stale@slock.test",
        ]]
    }

    // The retired pair is accepted alongside the unified list, but the unified
    // list wins: stale rows are never merged into extra identities.
    let restored = try freshStore(from: conflicting)
    #expect(restored.linkedIdentities.count == 1)
    #expect(restored.linkedIdentities.map(identityShape) == [identityShape(identityGoogle)])
    #expect(restored.profileSetupProvider(userId: snapshotId) == "google")
}

@Test func unifiedOnlySnapshotStillDecodesAfterTheExpandStep() throws {
    let exported = try snapshotStoreWithIdentities([identityGoogle]).exportAuthProfilePersistence()
    let unifiedOnly = try mutateSnapshotPayload(exported) { payload in
        payload.removeValue(forKey: "identityRows")
        payload.removeValue(forKey: "linkedIdentities")
    }
    let restored = try freshStore(from: unifiedOnly)
    #expect(restored.linkedIdentities.map(identityShape) == [identityShape(identityGoogle)])
    #expect(restored.profileSetupProvider(userId: snapshotId) == "google")
}

@Test func oldIdentityRowsSnapshotRestoresIntoTheUnifiedOwner() throws {
    let exported = try snapshotData(snapshotAccount())
    let oldShape = try mutateSnapshotPayload(exported) { payload in
        payload.removeValue(forKey: "userAuthIdentities")
        payload["identityRows"] = [snapshotId: [["provider": "github", "providerEmail": "legacy@slock.test"]]]
        payload["linkedIdentities"] = []
    }
    #expect(try snapshotPayload(oldShape)["userAuthIdentities"] == nil)

    let restored = try freshStore(from: oldShape)
    #expect(restored.linkedIdentities.count == 1)
    let row = try #require(restored.linkedIdentities.first)
    #expect(row.userId == snapshotId)
    #expect(row.provider == "github")
    // The legacy row had no provider subject; restoring one would fabricate it.
    #expect((row.providerUserId as String?) == nil)
    #expect(row.providerEmail == "legacy@slock.test")
    #expect(restored.profileSetupProvider(userId: snapshotId) == "github")
    let list = restored.identitySnapshot(userId: snapshotId)
    #expect(list.rows.map(\.provider) == ["github"])
    #expect(list.rows.map { $0.providerEmail as String? } == ["legacy@slock.test"])

    // The next export still writes the unified field and expands both retired
    // shapes from that row.
    let reexported = try restored.exportAuthProfilePersistence()
    let payload = try snapshotPayload(reexported)
    #expect(payload["userAuthIdentities"] != nil)
    let rows = try #require(payload["identityRows"] as? [String: [[String: Any]]])
    #expect(rows[snapshotId]?.map { $0["providerEmail"] as? String } == ["legacy@slock.test"])
    let linked = try #require(payload["linkedIdentities"] as? [[String: Any]])
    #expect(linked.map { $0["provider"] as? String } == ["github"])
    #expect(linked[0]["providerUserId"] as? String == "")
}

@Test func oldLinkedIdentitiesSnapshotRestoresIntoTheUnifiedOwner() throws {
    let exported = try snapshotData(snapshotAccount())
    let oldShape = try mutateSnapshotPayload(exported) { payload in
        payload.removeValue(forKey: "userAuthIdentities")
        payload["identityRows"] = [:]
        payload["linkedIdentities"] = [[
            "userId": snapshotId,
            "provider": "apple",
            "providerUserId": "apple-subject",
            "providerEmail": "apple@slock.test",
        ]]
    }

    let restored = try freshStore(from: oldShape)
    #expect(restored.linkedIdentities.count == 1)
    let row = try #require(restored.linkedIdentities.first)
    #expect(row.provider == "apple")
    #expect(row.providerUserId == "apple-subject")
    #expect(row.providerEmail == "apple@slock.test")
    #expect(restored.profileSetupProvider(userId: snapshotId) == "apple")
    #expect(restored.identitySnapshot(userId: snapshotId).rows.map(\.provider) == ["apple"])

    // The export also derives the retired list row from the unified email.
    let reexported = try restored.exportAuthProfilePersistence()
    let payload = try snapshotPayload(reexported)
    let rows = try #require(payload["identityRows"] as? [String: [[String: Any]]])
    #expect(rows[snapshotId]?.map { $0["providerEmail"] as? String } == ["apple@slock.test"])
}

@Test func bothOldIdentityFieldsMergeIntoTheUnifiedOwnerInStoredOrder() throws {
    let exported = try snapshotData(snapshotAccount())
    let oldShape = try mutateSnapshotPayload(exported) { payload in
        payload.removeValue(forKey: "userAuthIdentities")
        payload["identityRows"] = [
            snapshotId: [
                ["provider": "github", "providerEmail": "legacy-github@slock.test"],
                ["provider": "discord", "providerEmail": "legacy-discord@slock.test"],
            ],
        ]
        payload["linkedIdentities"] = [[
            "userId": snapshotId,
            "provider": "google",
            "providerUserId": "google-subject",
            "providerEmail": "google@slock.test",
        ]]
    }

    let restored = try freshStore(from: oldShape)
    // The legacy `linkedIdentities` order is the one `profileSetupProvider`
    // used before this batch, so those rows lead; the legacy list rows follow in
    // their stored order. Neither representation is dropped.
    #expect(restored.linkedIdentities.map(\.provider) == ["google", "github", "discord"])
    #expect(restored.linkedIdentities.map(\.providerEmail)
        == ["google@slock.test", "legacy-github@slock.test", "legacy-discord@slock.test"])
    #expect(restored.profileSetupProvider(userId: snapshotId) == "google")
    #expect(restored.identitySnapshot(userId: snapshotId).rows.map(\.provider)
        == ["google", "github", "discord"])

    // The expanded view round-trips through the retired shape without adding rows.
    let reexported = try restored.exportAuthProfilePersistence()
    let oldShapeAgain = try mutateSnapshotPayload(reexported) { payload in
        payload.removeValue(forKey: "userAuthIdentities")
    }
    let restoredAgain = try freshStore(from: oldShapeAgain)
    #expect(restoredAgain.linkedIdentities.map(identityShape) == restored.linkedIdentities.map(identityShape))
}

@Test func duplicateRetiredRepresentationsCoalesceIntoOneOwnerRow() throws {
    let exported = try snapshotData(snapshotAccount())
    let oldShape = try mutateSnapshotPayload(exported) { payload in
        payload.removeValue(forKey: "userAuthIdentities")
        payload["identityRows"] = [
            snapshotId: [["provider": "github", "providerEmail": "legacy@slock.test"]],
        ]
        payload["linkedIdentities"] = [[
            "userId": snapshotId,
            "provider": "github",
            "providerUserId": "github-subject",
            "providerEmail": "legacy@slock.test",
        ]]
    }

    let restored = try freshStore(from: oldShape)
    #expect(restored.linkedIdentities.count == 1)
    #expect(restored.linkedIdentities.map(identityShape)
        == ["github|subject=github-subject|email=legacy@slock.test"])
    #expect(restored.profileSetupProvider(userId: snapshotId) == "github")
}

@Test func partialOrMalformedIdentityFieldGroupsRejectTheWholeSnapshot() throws {
    let exported = try snapshotData(snapshotAccount())
    let identityRow: [String: Any] = ["provider": "github", "providerEmail": "legacy@slock.test"]

    // The old shape requires both legacy fields; a partial pair is corrupt.
    let missingLinked = try mutateSnapshotPayload(exported) { payload in
        payload.removeValue(forKey: "userAuthIdentities")
        payload.removeValue(forKey: "linkedIdentities")
        payload["identityRows"] = [snapshotId: [identityRow]]
    }
    #expect(throws: AuthProfilePersistence.Failure.invalidSnapshot) {
        try freshStore(from: missingLinked)
    }
    let missingRows = try mutateSnapshotPayload(exported) { payload in
        payload.removeValue(forKey: "userAuthIdentities")
        payload.removeValue(forKey: "identityRows")
        payload["linkedIdentities"] = []
    }
    #expect(throws: AuthProfilePersistence.Failure.invalidSnapshot) {
        try freshStore(from: missingRows)
    }

    // The new writer always emits the pair together; half of it is corrupt even
    // though the unified list is authoritative.
    for legacyKey in ["identityRows", "linkedIdentities"] {
        let mixed = try mutateSnapshotPayload(exported) { payload in
            payload.removeValue(forKey: legacyKey)
        }
        #expect(throws: AuthProfilePersistence.Failure.invalidSnapshot, Comment(rawValue: legacyKey)) {
            try freshStore(from: mixed)
        }
    }

    // The retired rows keep the previous strict shapes: an identity-list row
    // without an email and a linked row without a subject are corrupt.
    let badRetiredRow = try mutateSnapshotPayload(exported) { payload in
        payload["identityRows"] = [snapshotId: [["provider": "github"]]]
    }
    #expect(throws: AuthProfilePersistence.Failure.invalidSnapshot) {
        try freshStore(from: badRetiredRow)
    }
    let badRetiredSubject = try mutateSnapshotPayload(exported) { payload in
        payload["linkedIdentities"] = [[
            "userId": snapshotId,
            "provider": "github",
            "providerEmail": "legacy@slock.test",
        ]]
    }
    #expect(throws: AuthProfilePersistence.Failure.invalidSnapshot) {
        try freshStore(from: badRetiredSubject)
    }

    // Wrong types inside the unified group reject too, and the target store is
    // not partially replaced.
    let wrongType = try mutateSnapshotPayload(exported) { payload in
        payload["userAuthIdentities"] = ["not": "a list"]
    }
    let missingUnifiedEmail = try mutateSnapshotPayload(exported) { payload in
        payload["userAuthIdentities"] = [[
            "userId": snapshotId,
            "provider": "github",
            "providerUserId": "github-subject",
        ]]
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
    for corrupted in [wrongType, missingUnifiedEmail] {
        #expect(throws: AuthProfilePersistence.Failure.invalidSnapshot) {
            try target.restoreAuthProfilePersistence(from: corrupted)
        }
        #expect(target.account(userId: snapshotId) == nil)
        #expect(target.accountState.accounts.count == 1)
    }
}

@Test func productionShapedOwnerRestoresUnchangedAndThePreviousCodecAcceptsIt() throws {
    // The production owner account under test has a password credential, no
    // social identities and no survey facts. Restoring the pre-unification
    // snapshot must leave every account field exactly as stored; only the
    // retired linked-identity group moves to the unified field.
    var source = snapshotAccount(
        signupRole: nil, signupSurveyCompletedAt: nil,
        firstOnboardingCompletedAt: nil, firstOnboardingCompletedSessionFamilyId: nil
    )
    source.profileSetupProvider = nil
    let exported = try snapshotStore(source).exportAuthProfilePersistence()
    let payload = try snapshotPayload(exported)
    #expect((payload["identityRows"] as? [String: Any])?.isEmpty == true)
    #expect((payload["linkedIdentities"] as? [Any])?.isEmpty == true)

    // The previous binary's strict decoder accepts this production shape.
    let previous = try JSONDecoder().decode(PreviousEnvelope.self, from: exported)
    #expect(previous.payload.identityRows.isEmpty)
    #expect(previous.payload.linkedIdentities.isEmpty)

    let oldShape = try mutateSnapshotPayload(exported) { payload in
        payload.removeValue(forKey: "userAuthIdentities")
    }
    let oldPayload = try snapshotPayload(oldShape)
    let oldAccountRow = try #require(
        (oldPayload["accounts"] as? [String: Any])?[snapshotEmail] as? [String: Any]
    )
    #expect(oldAccountRow["passwordHash"] as? String == "argon2-placeholder")
    #expect(oldAccountRow["passwordCredentialEstablishedAt"] as? String != nil)
    #expect(oldAccountRow["profileSetupProvider"] is NSNull)

    let restored = try freshStore(from: oldShape)
    let restoredAccount = try #require(restored.account(userId: snapshotId))
    #expect(AuthUserDTO(account: restoredAccount) == AuthUserDTO(account: source))
    #expect(restored.linkedIdentities.isEmpty)
    #expect(restored.profileSetupProvider(userId: snapshotId) == nil)
    let methods = restored.identitySnapshot(userId: snapshotId)
    #expect(methods.rows.isEmpty)
    #expect(methods.passwordConfigured)

    let reexported = try restored.exportAuthProfilePersistence()
    #expect(reexported == exported)
    let newAccountRow = try snapshotAccountRow(reexported)
    let oldRowBytes = try JSONSerialization.data(withJSONObject: oldAccountRow, options: [.sortedKeys])
    let newRowBytes = try JSONSerialization.data(withJSONObject: newAccountRow, options: [.sortedKeys])
    #expect(oldRowBytes == newRowBytes)
    let unified = try snapshotPayload(reexported)["userAuthIdentities"] as? [Any]
    #expect(unified?.isEmpty == true)
}
