import Foundation
import Testing
@testable import RaftHTTP

/// The channel creation time is a new persisted fact. The snapshot codec must
/// round-trip it, and a snapshot written before it was retained must still
/// restore without a fabricated time.
@Test func channelCreationTimeRoundTripsAndLegacySnapshotsDecodeAbsent() throws {
    let ledger = OAuthLedger()
    ledger.addOwnedServer(id: "server", slug: "channel-time", name: "Channel Time", ownerId: "owner")
    let dm = ledger.createDirectChannel(
        serverId: "server", firstUserId: "owner", secondUserId: "agent", secondKind: .agent
    )
    let created = try #require(ledger.channelCreatedAt(id: dm))

    let restored = OAuthLedger()
    try restored.restorePersistenceData(try ledger.exportPersistenceData())
    #expect(restored.channelCreatedAt(id: dm) == created)

    var snapshot = try #require(
        try JSONSerialization.jsonObject(with: ledger.exportPersistenceData()) as? [String: Any]
    )
    var business = try #require(snapshot["businessState"] as? [String: Any])
    var records = try #require(business["channelRecords"] as? [[String: Any]])
    #expect(records.count == 2)
    for index in records.indices { records[index].removeValue(forKey: "createdAt") }
    business["channelRecords"] = records
    snapshot["businessState"] = business
    let legacy = try JSONSerialization.data(withJSONObject: snapshot)

    let legacyLedger = OAuthLedger()
    try legacyLedger.restorePersistenceData(legacy)
    #expect(legacyLedger.channelCreatedAt(id: dm) == nil)
    #expect(legacyLedger.channelInfo(id: dm)?.name == "")
    #expect(legacyLedger.channelHumanIds(channelId: dm) == ["owner"])
}
