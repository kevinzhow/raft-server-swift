import Foundation
import Testing
@testable import RaftHTTP

/// The card `metadata` projections are `OrderedJSON` trees now. The reference
/// below is the retired string-concatenating implementation, copied verbatim, so
/// the tests lock byte equality with the legacy output.

private enum Legacy {
    static func marketplaceInstallActionJSON(_ card: MarketplaceInstallCard) -> String {
        let scopes = card.scopes.map(jsonString).joined(separator: ",")
        let draftHint = ",\"draftHint\":\(jsonString("\(card.agentName) requested \(card.clientName), which is public in the Raft Marketplace but is not installed on this Server. Installing is a Server owner/admin action; the Agent cannot install it automatically."))"
        let setupUrl = card.setupUrl.map(jsonString) ?? "null"
        return "{\"type\":\"integration:install_marketplace_app\",\"clientId\":\(jsonString(card.clientRecordId)),\"clientKey\":\(jsonString(card.clientKey)),\"clientName\":\(jsonString(card.clientName)),\"clientNameSha256\":\(jsonString(card.clientNameSha256)),\"agentId\":\(jsonString(card.agentId)),\"agentName\":\(jsonString(card.agentName)),\"scopes\":[\(scopes)],\"setupUrl\":\(setupUrl),\"setupRevision\":\(card.setupRevision)\(draftHint)}"
    }

    static func marketplaceInstallPresentationJSON(_ card: MarketplaceInstallCard) -> String {
        var items: [String] = []
        items.append("{\"key\":\"clientId\",\"value\":\(jsonString(card.clientRecordId))}")
        items.append("{\"key\":\"clientKey\",\"value\":\(jsonString(card.clientKey))}")
        items.append("{\"key\":\"clientName\",\"value\":\(jsonString(card.clientName))}")
        items.append("{\"key\":\"agentId\",\"value\":\(jsonString(card.agentId))}")
        items.append("{\"key\":\"agentName\",\"value\":\(jsonString(card.agentName))}")
        if !card.scopes.isEmpty {
            let scopes = card.scopes.map(jsonString).joined(separator: ", ")
            items.append("{\"key\":\"scopes\",\"value\":\(jsonString(scopes))}")
        }
        let warning = "This installs the Marketplace app for this Server so @\(card.agentName) can request the listed scopes."
        return "{\"title\":\(jsonString("Install \(card.clientName) on this Server")),\"confirmLabel\":\"Install App\",\"genericApprovalAllowed\":true,\"displayItems\":[\(items.joined(separator: ","))],\"warning\":\(jsonString(warning)),\"riskLevel\":\"elevated\"}"
    }

    static func marketplaceInstallMetadataJSON(_ card: MarketplaceInstallCard, serverName: String, executedAt: String) -> String {
        let executedAtJSON = card.state == "executed" ? jsonString(executedAt) : "null"
        let executedBy = card.executedByUserId.map(jsonString) ?? "null"
        let result = card.resultJSON ?? "null"
        return "{\"kind\":\"action-card\",\"sourceServerId\":\(jsonString(card.serverId)),\"targetServerName\":\(jsonString(serverName)),\"action\":\(marketplaceInstallActionJSON(card)),\"presentation\":\(marketplaceInstallPresentationJSON(card)),\"state\":\(jsonString(card.state)),\"executedAt\":\(executedAtJSON),\"executedByUserId\":\(executedBy),\"result\":\(result)}"
    }

    static func integrationRegisterActionJSON(_ card: IntegrationRegisterCard) -> String {
        var fields: [String] = [
            "\"type\":\"integration:register_app\"",
            "\"name\":\(jsonString(card.name))",
        ]
        if let clientKey = card.clientKey { fields.append("\"clientKey\":\(jsonString(clientKey))") }
        if let homepageUrl = card.homepageUrl { fields.append("\"homepageUrl\":\(jsonString(homepageUrl))") }
        fields.append("\"returnUrl\":\(jsonString(card.returnUrl))")
        if let agentManifestUrl = card.agentManifestUrl {
            fields.append("\"agentManifestUrl\":\(jsonString(agentManifestUrl))")
        }
        let scopes = card.scopes.map(jsonString).joined(separator: ",")
        fields.append("\"scopes\":[" + scopes + "]")
        if let setupUrl = card.setupUrl { fields.append("\"setupUrl\":\(jsonString(setupUrl))") }
        if let setupDescription = card.setupDescription { fields.append("\"setupDescription\":\(jsonString(setupDescription))") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    static func integrationRegisterPresentationJSON(_ card: IntegrationRegisterCard) -> String {
        var items: [String] = [
            "{\"key\":\"name\",\"value\":\(jsonString(card.name))}",
        ]
        if let clientKey = card.clientKey {
            items.append("{\"key\":\"clientKey\",\"value\":\(jsonString(clientKey))}")
        }
        items.append("{\"key\":\"returnUrl\",\"value\":\(jsonString(card.returnUrl))}")
        if !card.scopes.isEmpty {
            let scopes = card.scopes.map(jsonString).joined(separator: ", ")
            items.append("{\"key\":\"scopes\",\"value\":\(jsonString(scopes))}")
        }
        return "{\"title\":\(jsonString("Register Connected App \(card.name)")),\"confirmLabel\":\"Register App\",\"genericApprovalAllowed\":true,\"displayItems\":[\(items.joined(separator: ","))],\"warning\":\"The requesting agent becomes the initial app owner. No client secret is stored in this card.\",\"riskLevel\":\"elevated\"}"
    }

    static func integrationRegisterMetadataJSON(_ card: IntegrationRegisterCard, serverName: String) -> String {
        let executedBy = card.executedByUserId.map(jsonString) ?? "null"
        let result = card.resultJSON ?? "null"
        return "{\"kind\":\"action-card\",\"sourceServerId\":\(jsonString(card.serverId)),\"targetServerName\":\(jsonString(serverName)),\"action\":\(integrationRegisterActionJSON(card)),\"presentation\":\(integrationRegisterPresentationJSON(card)),\"state\":\(jsonString(card.state)),\"executedByUserId\":\(executedBy),\"result\":\(result)}"
    }
}

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
private let fixedStamp = ISO8601DateFormatter().string(from: fixedNow)

private func projection(_ directory: EmailLoginDirectory) -> ActionCardMetadataProjection {
    ActionCardMetadataProjection(
        cards: directory.managedMCPAndCardsStore,
        oauth: directory.oauth,
        now: { fixedNow }
    )
}

private func installCard(
    state: String = "prepared",
    scopes: [String] = ["agent:read", "agent:send"],
    setupUrl: String? = nil,
    executedBy: String? = nil,
    result: String? = nil,
    name: String = "Tricky \"App\" / \\ é\u{1}"
) -> MarketplaceInstallCard {
    MarketplaceInstallCard(
        messageId: "m-install",
        serverId: "11111111-1111-4111-8111-111111111111",
        clientRecordId: "rec-1",
        clientKey: "key/1",
        clientName: name,
        clientNameSha256: "ab12",
        agentId: "agent-1",
        agentName: "bot<&>",
        scopes: scopes,
        storageChannelId: "c1",
        localCarrierChannelId: "c1",
        state: state,
        executedByUserId: executedBy,
        resultJSON: result,
        setupUrl: setupUrl,
        setupRevision: 3
    )
}

private func registerCard(
    clientKey: String? = nil,
    homepage: String? = nil,
    manifest: String? = nil,
    setupUrl: String? = nil,
    setupDescription: String? = nil,
    scopes: [String] = [],
    state: String = "prepared",
    executedBy: String? = nil,
    result: String? = nil
) -> IntegrationRegisterCard {
    IntegrationRegisterCard(
        messageId: "m-register",
        serverId: "22222222-2222-4222-8222-222222222222",
        agentId: "agent-2",
        agentName: "Reg Bot",
        storageChannelId: "c2",
        localCarrierChannelId: "c2",
        name: "My \"App\"",
        clientKey: clientKey,
        homepageUrl: homepage,
        returnUrl: "https://example.com/cb?x=1&y=/z",
        agentManifestUrl: manifest,
        setupUrl: setupUrl,
        setupDescription: setupDescription,
        scopes: scopes,
        state: state,
        executedByUserId: executedBy,
        resultJSON: result
    )
}

@Test func marketplaceInstallMetadataIsByteIdenticalToTheLegacyString() {
    let directory = EmailLoginDirectory()
    let cases = [
        installCard(),
        installCard(scopes: [], setupUrl: "https://s.example/setup"),
        installCard(state: "executed", executedBy: "user-9", result: "{\"installed\":true,\"id\":\"x\"}"),
        installCard(state: "rejected", executedBy: "user-9", result: nil),
    ]
    for card in cases {
        #expect(
            projection(directory).marketplaceInstall(card)
                == Legacy.marketplaceInstallMetadataJSON(card, serverName: "this Server", executedAt: fixedStamp)
        )
    }
}

@Test func integrationRegisterMetadataIsByteIdenticalToTheLegacyString() {
    let directory = EmailLoginDirectory()
    let cases = [
        registerCard(),
        registerCard(clientKey: "ck", homepage: "https://h.example", manifest: "https://m.example/a.json",
                     setupUrl: "https://s", setupDescription: "Set \"up\"\n", scopes: ["openid", "email"]),
        registerCard(state: "executed", executedBy: "u", result: "{\"clientId\":\"c\"}"),
    ]
    for card in cases {
        #expect(
            projection(directory).integrationRegister(card)
                == Legacy.integrationRegisterMetadataJSON(card, serverName: "this Server")
        )
    }
}

@Test func metadataLookupFindsTheCardByMessageIdInLegacyPrecedence() {
    let directory = EmailLoginDirectory()
    let store = directory.managedMCPAndCardsStore
    #expect(projection(directory).metadata(messageId: "m-install") == nil)
    store.insertMarketplaceInstallCard(installCard())
    store.insertIntegrationRegisterCard(registerCard())
    #expect(
        projection(directory).metadata(messageId: "m-install")
            == Legacy.marketplaceInstallMetadataJSON(installCard(), serverName: "this Server", executedAt: fixedStamp)
    )
    #expect(
        projection(directory).metadata(messageId: "m-register")
            == Legacy.integrationRegisterMetadataJSON(registerCard(), serverName: "this Server")
    )
    #expect(projection(directory).metadata(messageId: "other") == nil)
}

@Test func theDirectoryAccessorProjectsThroughTheSameStores() {
    let directory = EmailLoginDirectory()
    directory.managedMCPAndCardsStore.insertIntegrationRegisterCard(registerCard())
    #expect(
        directory.actionCardMetadata.metadata(messageId: "m-register")
            == Legacy.integrationRegisterMetadataJSON(registerCard(), serverName: "this Server")
    )
}
