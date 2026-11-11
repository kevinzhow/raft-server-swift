import Foundation
import Testing
@testable import RaftHTTP

/// Developer-platform additions are new optional ledger keys. A retained
/// snapshot still restores when they are absent, and the share-link key that
/// two producer generations wrote is accepted either way. Encoding only adds
/// keys, so a rollback to the previous release can still read the snapshot.
@Test func appLogoAndShareLinkSnapshotAcceptsOlderRowsAndAddsOnlyKeys() throws {
    let ledger = OAuthLedger()
    ledger.addOwnedServer(id: "server", slug: "app-persist", name: "App Persist", ownerId: "owner")
    let created = try ledger.createManagedClient(
        serverId: "server", createdByUserId: "owner", name: "Persist App",
        description: nil, whenToUse: nil, homepageUrl: nil, returnUrl: nil,
        agentManifestUrl: nil, setupUrl: nil, setupDescription: nil,
        clientKey: "persist-app", allowedScopes: nil, category: "Other")
    var client = created.client
    client.logoUrl = "/api/integration-logos/\(client.id)/abc.webp"
    client.logoStorageKey = "public-assets/integration-logo/\(client.id)/abc.webp"
    ledger.replaceClientLogo(client)
    let issued = try #require(ledger.createManagedShareLink(
        serverId: "server", recordId: client.id, createdByUserId: "owner", expiresInDays: 7))

    let data = try ledger.exportPersistenceData()
    let restored = OAuthLedger()
    try restored.restorePersistenceData(data)
    let persisted = try #require(restored.managedClientRows(serverId: "server").first { $0.id == client.id })
    #expect(persisted.logoUrl == client.logoUrl)
    #expect(persisted.logoStorageKey == client.logoStorageKey)
    let persistedLink = try #require(restored.shareLinkActive(serverId: "server", recordId: client.id))
    #expect(persistedLink.clientId == client.id)
    #expect(persistedLink.clientRecordId == client.id)

    // A snapshot written before the developer-platform fields existed restores
    // with the defaults and never fabricates a stored object.
    var snapshot = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var business = try #require(snapshot["businessState"] as? [String: Any])
    var clients = try #require(business["clients"] as? [[String: Any]])
    let retiredClientKeys = ["category", "dataAccessSummary", "publishRejectionReason",
        "publishRequestedAt", "publishReviewedAt", "logoStorageKey", "createdAt", "updatedAt",
        "outboundEvents", "outboundRequestRevision", "outboundCurrentRevisionId",
        "outboundPendingEvents", "outboundPendingRevisionState"]
    for index in clients.indices {
        for key in retiredClientKeys { clients[index].removeValue(forKey: key) }
    }
    business["clients"] = clients
    var links = try #require(business["clientShareLinks"] as? [[String: Any]])
    for index in links.indices {
        links[index].removeValue(forKey: "createdByUserId")
        links[index].removeValue(forKey: "createdByAgentId")
    }
    business["clientShareLinks"] = links
    snapshot["businessState"] = business
    var legacyJSON = snapshot
    var legacyBusiness = try #require(legacyJSON["businessState"] as? [String: Any])
    var clientIdOnlyLinks = try #require(legacyBusiness["clientShareLinks"] as? [[String: Any]])
    for index in clientIdOnlyLinks.indices { clientIdOnlyLinks[index].removeValue(forKey: "clientRecordId") }
    legacyBusiness["clientShareLinks"] = clientIdOnlyLinks
    legacyJSON["businessState"] = legacyBusiness
    let legacy = OAuthLedger()
    try legacy.restorePersistenceData(try JSONSerialization.data(withJSONObject: legacyJSON))
    let oldClient = try #require(legacy.managedClientRows(serverId: "server").first { $0.id == client.id })
    #expect(oldClient.logoStorageKey == nil)
    #expect(oldClient.logoUrl == client.logoUrl)
    #expect(oldClient.category == "Other")
    #expect(oldClient.outboundEvents.isEmpty)
    let oldLink = try #require(legacy.shareLinkActive(serverId: "server", recordId: client.id))
    #expect(oldLink.clientId == client.id)
    #expect(oldLink.clientRecordId == client.id)

    // The other producer generation wrote only `clientRecordId`.
    var recordIdOnlyJSON = snapshot
    var recordIdBusiness = try #require(recordIdOnlyJSON["businessState"] as? [String: Any])
    var recordIdLinks = try #require(recordIdBusiness["clientShareLinks"] as? [[String: Any]])
    for index in recordIdLinks.indices { recordIdLinks[index].removeValue(forKey: "clientId") }
    recordIdBusiness["clientShareLinks"] = recordIdLinks
    recordIdOnlyJSON["businessState"] = recordIdBusiness
    let recordIdOnly = OAuthLedger()
    try recordIdOnly.restorePersistenceData(try JSONSerialization.data(withJSONObject: recordIdOnlyJSON))
    let recordIdLink = try #require(recordIdOnly.shareLinkActive(serverId: "server", recordId: client.id))
    #expect(recordIdLink.clientId == client.id)
    #expect(recordIdLink.clientRecordId == client.id)
    #expect(issued.link.id == persistedLink.id)
}
