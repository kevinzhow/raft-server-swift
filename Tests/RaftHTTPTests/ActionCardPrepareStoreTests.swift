import Foundation
@testable import RaftHTTP
import Testing

/// `ManagedMCPAndCardsStore.patchAppConfig` is one locked compare-and-set: the
/// revision check, the merge and the revision bump cannot interleave, so only
/// one of many concurrent patches with the same expected revision commits.
@Test func concurrentAppConfigPatchesCommitExactlyOnce() async {
    let store = ManagedMCPAndCardsStore()
    let appId = "system.cleaner"

    let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for index in 0..<32 {
            group.addTask {
                switch store.patchAppConfig(
                    agentId: "agent-a",
                    appId: appId,
                    expectedRevision: 0,
                    set: ["enabled": .boolean(index % 2 == 0)],
                    unset: []
                ) {
                case .applied:
                    return true
                case .revisionStale:
                    return false
                }
            }
        }
        var count = 0
        for await won in group where won { count += 1 }
        return count
    }

    #expect(winners == 1)
    let snapshot = store.appConfigSnapshot(agentId: "agent-a", appId: appId)
    #expect(snapshot.revision == 1)
    #expect(snapshot.overrides.keys.sorted() == ["enabled"])
}

/// The patch merges `set` and removes `unset` in the same critical section.
@Test func appConfigPatchMergesSetAndUnsetUnderOneLock() {
    let store = ManagedMCPAndCardsStore()
    let appId = "system.cleaner"
    _ = store.patchAppConfig(
        agentId: "agent-a",
        appId: appId,
        expectedRevision: 0,
        set: ["enabled": .boolean(false), "threshold_bytes": .integer(131_072)],
        unset: []
    )
    let result = store.patchAppConfig(
        agentId: "agent-a",
        appId: appId,
        expectedRevision: 1,
        set: ["interval_seconds": .integer(1800)],
        unset: ["threshold_bytes"]
    )
    guard case .applied(let snapshot) = result else {
        Issue.record("expected the second patch to commit")
        return
    }
    #expect(snapshot.revision == 2)
    #expect(snapshot.overrides["enabled"] == .boolean(false))
    #expect(snapshot.overrides["threshold_bytes"] == nil)
    #expect(snapshot.overrides["interval_seconds"] == .integer(1800))
}

/// The patch body keeps the legacy `NSNumber` tolerance: booleans and
/// fractional numbers are accepted for `expectedRevision`, `set` keeps its raw
/// value for validation, and non-string `unset` entries are skipped.
@Test func patchRequestBodyKeepsLegacyNumberTolerance() throws {
    let decoder = JSONDecoder()

    let booleanRevision = try decoder.decode(
        AgentAppConfigPatchRequest.self,
        from: Data(#"{"expectedRevision":true,"set":{"enabled":1},"unset":[1,"enabled"]}"#.utf8)
    )
    #expect(booleanRevision.expectedRevision == 1)
    #expect(AgentAppConfigPatchRequest.legacyInteger(booleanRevision.set["enabled"]!) == 1)
    #expect(booleanRevision.unset == ["enabled"])

    let fractionalRevision = try decoder.decode(
        AgentAppConfigPatchRequest.self,
        from: Data(#"{"expectedRevision":1.9,"set":{},"unset":[]}"#.utf8)
    )
    #expect(fractionalRevision.expectedRevision == 1)

    let missingRevision = try? decoder.decode(
        AgentAppConfigPatchRequest.self,
        from: Data(#"{"set":{}}"#.utf8)
    )
    #expect(missingRevision == nil)

    let stringRevision = try? decoder.decode(
        AgentAppConfigPatchRequest.self,
        from: Data(#"{"expectedRevision":"1"}"#.utf8)
    )
    #expect(stringRevision == nil)
}

/// The review body is the only request member, and every non-string value
/// falls through to `nil` so the published `invalid_expected_revision_id` 400
/// stays reachable.
@Test func reviewRequestBodyToleratesNonStringRevision() throws {
    let decoder = JSONDecoder()

    let string = try decoder.decode(
        ReviewAppNotificationPermissionsRequest.self,
        from: Data(#"{"expected_revision_id":"revision"}"#.utf8)
    )
    #expect(string.expectedRevisionId == "revision")

    for raw in [#"{"expected_revision_id":null}"#, #"{"expected_revision_id":123}"#, "{}"] {
        let decoded = try decoder.decode(
            ReviewAppNotificationPermissionsRequest.self,
            from: Data(raw.utf8)
        )
        #expect(decoded.expectedRevisionId == nil)
    }
}
