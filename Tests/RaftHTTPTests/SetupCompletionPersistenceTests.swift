import Foundation
@testable import RaftHTTP
import Testing

// Synthetic persistence regressions for the post-setup fact group and the
// account-fact seam. The HTTP published path is covered by
// SetupCompletionHandoffTests; these tests pin the strict snapshot codec
// (old v1 shape, partial group, bad date, missing original key) and the two
// seam answers the projection must report separately.

private struct FixedSetupAccountFacts: SetupAccountFacts {
    /// `nil` models a missing account row: upstream fails open and owes nothing.
    var answered: Bool?
    func surveyCompleted(userId: String) -> Bool? { answered }
    func recordFirstOnboarding(userId: String, at date: Date, sessionFamilyId: String?) {}
}

private let seamServer = "33333333-3333-4333-8333-333333333740"
private let seamOwner = "11111111-1111-4111-8111-111111111740"
private let seamSecondServer = "33333333-3333-4333-8333-333333333741"

@Test func postSetupConsultsTheAccountSeamAndTheRetainedReceiptSeparately() throws {
    let store = ServersAndChannelsStore()
    let oauth = OAuthLedger()
    oauth.addOwnedServer(id: seamServer, slug: "seam", name: "Seam", ownerId: seamOwner)
    store.completeSetup(serverId: seamServer, userId: seamOwner)

    func project(_ facts: FixedSetupAccountFacts) -> SetupProjectionResponseDTO {
        ServerSetupProjectionService(
            store: store, agents: AgentsRuntimeStore(), computers: MachinesAndComputersStore(),
            oauth: oauth, accountFacts: facts
        ).project(serverId: seamServer, userId: seamOwner, role: "owner")
    }

    // Survey answer and handoff acknowledgment are different retained facts and
    // are reported independently (upstream postSetup has two members).
    let unanswered = project(FixedSetupAccountFacts(answered: false))
    #expect(unanswered.surface == "complete")
    #expect(unanswered.postSetupSurveyPending)
    #expect(unanswered.postSetupHandoffPending)
    let answered = project(FixedSetupAccountFacts(answered: true))
    #expect(!answered.postSetupSurveyPending)
    #expect(answered.postSetupHandoffPending)
    // A missing owner account owes no survey (`!!owner && … === null`), but the
    // handoff receipt is still read independently.
    let missingAccount = project(FixedSetupAccountFacts(answered: nil))
    #expect(!missingAccount.postSetupSurveyPending)
    #expect(missingAccount.postSetupHandoffPending)
    store.acknowledgeSetupHandoff(serverId: seamServer, originalOwnerId: seamOwner, at: Date())
    let acknowledged = project(FixedSetupAccountFacts(answered: false))
    #expect(acknowledged.postSetupSurveyPending)
    #expect(!acknowledged.postSetupHandoffPending)

    // An unknown legacy completion owes neither screen, even when the account
    // seam reports the survey as unanswered.
    let legacyStore = ServersAndChannelsStore()
    _ = legacyStore.setSetupPhase(serverId: seamServer, userId: seamOwner, phase: "complete")
    let legacy = ServerSetupProjectionService(
        store: legacyStore, agents: AgentsRuntimeStore(), computers: MachinesAndComputersStore(),
        oauth: oauth, accountFacts: FixedSetupAccountFacts(answered: false)
    ).project(serverId: seamServer, userId: seamOwner, role: "owner")
    #expect(legacy.surface == "complete")
    #expect(!legacy.postSetupSurveyPending)
    #expect(!legacy.postSetupHandoffPending)
}

// MARK: - Snapshot codec

private func snapshotObject(_ store: ServersAndChannelsStore) throws -> [String: Any] {
    let data = try store.exportPersistenceData()
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func encodeSnapshot(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func business(_ object: [String: Any]) throws -> [String: Any] {
    try #require(object["business"] as? [String: Any])
}

private func patchedSnapshot(
    _ store: ServersAndChannelsStore,
    _ patch: (inout [String: Any]) throws -> Void
) throws -> Data {
    var root = try snapshotObject(store)
    var fields = try business(root)
    try patch(&fields)
    root["business"] = fields
    return try encodeSnapshot(root)
}

private func dateHex(_ date: Date) -> String {
    let bits = String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - bits.count) + bits
}

private func date(fromHex text: String) -> Date {
    Date(timeIntervalSinceReferenceDate: Double(bitPattern: UInt64(text, radix: 16) ?? 0))
}

/// A store whose setup rows hold both new facts: a fresh `normal` completion and
/// one retained owner acknowledgment.
private func seededStore(acknowledgedAt date: Date) -> ServersAndChannelsStore {
    let store = ServersAndChannelsStore()
    store.completeSetup(serverId: seamServer, userId: seamOwner)
    store.acknowledgeSetupHandoff(serverId: seamServer, originalOwnerId: seamOwner, at: date)
    return store
}

@Test func setupCompletionGroupRoundTripsThroughExportAndRestore() throws {
    let acknowledgedAt = Date(timeIntervalSinceReferenceDate: 812_345_678.25)
    let source = seededStore(acknowledgedAt: acknowledgedAt)
    let exported = try source.exportPersistenceData()

    let restored = ServersAndChannelsStore()
    try restored.restorePersistenceData(exported)

    #expect(restored.setupPhase(serverId: seamServer, userId: seamOwner) == "complete")
    #expect(restored.setupCompletionReason(serverId: seamServer, userId: seamOwner) == .normal)
    let receipt = try #require(restored.setupHandoffReceipt(serverId: seamServer, ownerId: seamOwner))
    #expect(receipt.serverId == seamServer)
    #expect(receipt.originalOwnerId == seamOwner)
    #expect(receipt.acknowledgedAt == acknowledgedAt)

    // The same group is re-encoded, with the exact reference-date bits.
    let sourceGroup = try #require(try business(snapshotObject(source))["setupCompletion"] as? [String: Any])
    let restoredGroup = try #require(try business(snapshotObject(restored))["setupCompletion"] as? [String: Any])
    #expect(sourceGroup as NSDictionary == restoredGroup as NSDictionary)
    let receipts = try #require(restoredGroup["handoffReceipts"] as? [String: Any])
    let stored = try #require(receipts["\(seamServer)\n\(seamOwner)"] as? [String: Any])
    #expect(stored["acknowledgedAt"] as? String == dateHex(acknowledgedAt))
    #expect(date(fromHex: try #require(stored["acknowledgedAt"] as? String)) == acknowledgedAt)
}

@Test func oldV1SnapshotWithoutTheGroupRestoresUnknownAndKeepsTheLegacyMarker() throws {
    let legacy = ServersAndChannelsStore()
    _ = legacy.setSetupPhase(serverId: seamServer, userId: seamOwner, phase: "complete")
    _ = legacy.mutex.withLock { state in
        state.setupHandoffs.insert(seamServer)
    }
    // Strip the whole new group: the exact old v1 shape (every original key stays).
    let oldShape = try patchedSnapshot(legacy) { fields in
        fields.removeValue(forKey: "setupCompletion")
    }

    // A target with unrelated new facts already present must be fully replaced
    // by the old snapshot, not merged.
    let target = ServersAndChannelsStore()
    target.completeSetup(serverId: seamSecondServer, userId: seamOwner)
    target.acknowledgeSetupHandoff(serverId: seamSecondServer, originalOwnerId: seamOwner, at: Date())
    try target.restorePersistenceData(oldShape)

    #expect(target.setupPhase(serverId: seamServer, userId: seamOwner) == "complete")
    #expect(target.setupCompletionReason(serverId: seamServer, userId: seamOwner) == nil)
    #expect(target.setupHandoffReceipt(serverId: seamServer, ownerId: seamOwner) == nil)
    #expect(target.setupCompletionReason(serverId: seamSecondServer, userId: seamOwner) == nil)
    #expect(target.setupHandoffReceipt(serverId: seamSecondServer, ownerId: seamOwner) == nil)
    // The legacy subjectless marker is retained as history but never becomes a receipt.
    #expect(target.state.setupHandoffs.contains(seamServer))
    // Re-encoding writes the new shape with an empty group.
    let group = try #require(try business(snapshotObject(target))["setupCompletion"] as? [String: Any])
    #expect((group["completionReasons"] as? [String: Any])?.isEmpty == true)
    #expect((group["handoffReceipts"] as? [String: Any])?.isEmpty == true)
}

@Test func firstHandoffAcknowledgmentIsRetainedOnRetry() {
    let store = ServersAndChannelsStore()
    let first = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let second = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let retained = store.acknowledgeSetupHandoff(serverId: seamServer, originalOwnerId: seamOwner, at: first)
    #expect(retained.acknowledgedAt == first)
    let retried = store.acknowledgeSetupHandoff(serverId: seamServer, originalOwnerId: seamOwner, at: second)
    #expect(retried.acknowledgedAt == first)
    #expect(store.setupHandoffReceipt(serverId: seamServer, ownerId: seamOwner)?.acknowledgedAt == first)
    // A different server's acknowledgment is its own retained row.
    let other = store.acknowledgeSetupHandoff(serverId: seamSecondServer, originalOwnerId: seamOwner, at: second)
    #expect(other.acknowledgedAt == second)
}

@Test func partialSetupCompletionGroupIsRejectedWithoutPartialRestore() throws {
    let date = Date(timeIntervalSinceReferenceDate: 812_345_678.25)
    let source = seededStore(acknowledgedAt: date)
    let receiptKey = "\(seamServer)\n\(seamOwner)"

    let variants: [(String, (inout [String: Any]) throws -> Void)] = [
        ("group without handoffReceipts", { fields in
            var group = try #require(fields["setupCompletion"] as? [String: Any])
            group.removeValue(forKey: "handoffReceipts")
            fields["setupCompletion"] = group
        }),
        ("group without completionReasons", { fields in
            var group = try #require(fields["setupCompletion"] as? [String: Any])
            group.removeValue(forKey: "completionReasons")
            fields["setupCompletion"] = group
        }),
        ("group with a wrong-typed member", { fields in
            var group = try #require(fields["setupCompletion"] as? [String: Any])
            group["completionReasons"] = [String]()
            fields["setupCompletion"] = group
        }),
        ("group with a wrong-typed receipt", { fields in
            var group = try #require(fields["setupCompletion"] as? [String: Any])
            group["handoffReceipts"] = [receiptKey]
            fields["setupCompletion"] = group
        }),
        ("group with a malformed date", { fields in
            var group = try #require(fields["setupCompletion"] as? [String: Any])
            var receipts = try #require(group["handoffReceipts"] as? [String: Any])
            var receipt = try #require(receipts[receiptKey] as? [String: Any])
            receipt["acknowledgedAt"] = "not-a-date-bits!"
            receipts[receiptKey] = receipt
            group["handoffReceipts"] = receipts
            fields["setupCompletion"] = group
        }),
        ("group with a mismatched receipt identity", { fields in
            var group = try #require(fields["setupCompletion"] as? [String: Any])
            var receipts = try #require(group["handoffReceipts"] as? [String: Any])
            let receipt = try #require(receipts[receiptKey] as? [String: Any])
            receipts.removeValue(forKey: receiptKey)
            receipts["\(seamServer)\n\(seamSecondServer)"] = receipt
            group["handoffReceipts"] = receipts
            fields["setupCompletion"] = group
        }),
        ("explicit null group", { fields in
            fields["setupCompletion"] = NSNull()
        }),
    ]

    let target = ServersAndChannelsStore()
    _ = target.setSetupPhase(serverId: seamServer, userId: seamOwner, phase: "deferred")
    let untouched = try target.exportPersistenceData()
    for (label, patch) in variants {
        let data = try patchedSnapshot(source, patch)
        #expect(throws: (any Error).self, "\(label) must reject") {
            try target.restorePersistenceData(data)
        }
        #expect(try target.exportPersistenceData() == untouched, "\(label) must not restore partially")
    }
}

@Test func missingOriginalRequiredKeyIsRejectedWithoutPartialRestore() throws {
    let source = seededStore(acknowledgedAt: Date(timeIntervalSinceReferenceDate: 812_345_678.25))
    let target = ServersAndChannelsStore()
    _ = target.setSetupPhase(serverId: seamServer, userId: seamOwner, phase: "deferred")
    let untouched = try target.exportPersistenceData()
    for key in ["threadOrder", "setupPhases", "serverMemberRoles"] {
        let data = try patchedSnapshot(source) { fields in
            fields.removeValue(forKey: key)
        }
        #expect(throws: (any Error).self, "\(key) is still required") {
            try target.restorePersistenceData(data)
        }
        #expect(try target.exportPersistenceData() == untouched)
    }
}

@Test func completionReasonGatesThePersonalPostSetupScreens() throws {
    let oauth = OAuthLedger()
    oauth.addOwnedServer(id: seamServer, slug: "reason-gate", name: "Reason Gate", ownerId: seamOwner)

    /// Seeds one retained completion state directly: the reason is the only
    /// difference between the rows, which is exactly the upstream gate.
    func project(phase: String, reason: String?) -> SetupProjectionResponseDTO {
        let store = ServersAndChannelsStore()
        store.mutex.withLock { state in
            state.setupPhases["\(seamServer)\n\(seamOwner)"] = phase
            if let reason {
                state.setupCompletionReasons["\(seamServer)\n\(seamOwner)"] = reason
            }
        }
        return ServerSetupProjectionService(
            store: store, agents: AgentsRuntimeStore(), computers: MachinesAndComputersStore(),
            oauth: oauth, accountFacts: FixedSetupAccountFacts(answered: false)
        ).project(serverId: seamServer, userId: seamOwner, role: "owner")
    }

    // A genuine flow completion, including the compatible legacy
    // `complete_after_defer`, owes both personal screens.
    for reason in ["normal", "complete_after_defer"] {
        let projection = project(phase: "complete", reason: reason)
        #expect(projection.surface == "complete")
        #expect(projection.postSetupSurveyPending, "\(reason) owes the survey")
        #expect(projection.postSetupHandoffPending, "\(reason) owes the handoff")
    }
    // Migration/admin terminal facts never went through onboarding, so they owe
    // neither screen even when the owner's survey row and handoff stamp are null.
    for reason in ["grandfathered", "admin_override"] {
        let projection = project(phase: "complete", reason: reason)
        #expect(projection.surface == "complete")
        #expect(!projection.postSetupSurveyPending, "\(reason) owes no survey")
        #expect(!projection.postSetupHandoffPending, "\(reason) owes no handoff")
    }
    // Unknown (a legacy complete with no reason) owes nothing.
    let unknown = project(phase: "complete", reason: nil)
    #expect(!unknown.postSetupSurveyPending)
    #expect(!unknown.postSetupHandoffPending)
    // A non-terminal phase with a stray retained reason still owes nothing.
    let inProgress = project(phase: "in_progress", reason: "normal")
    #expect(!inProgress.postSetupSurveyPending)
    #expect(!inProgress.postSetupHandoffPending)

    // A terminal retry never rewrites a retained reason (including the
    // compatible legacy value) and never reopens the row.
    let store = ServersAndChannelsStore()
    store.mutex.withLock { state in
        state.setupPhases["\(seamServer)\n\(seamOwner)"] = "complete"
        state.setupCompletionReasons["\(seamServer)\n\(seamOwner)"] = "complete_after_defer"
    }
    #expect(store.completeSetup(serverId: seamServer, userId: seamOwner) == "complete")
    #expect(store.setupCompletionReason(serverId: seamServer, userId: seamOwner) == .completeAfterDefer)
    store.startSetup(serverId: seamServer, userId: seamOwner)
    #expect(store.setupPhase(serverId: seamServer, userId: seamOwner) == "complete")
    #expect(store.setupCompletionReason(serverId: seamServer, userId: seamOwner) == .completeAfterDefer)
}
