import Foundation

/// The `metadata` projection of a prepared action card (`kind: "action-card"`):
/// the card action, its presentation block and the execution state, keyed by
/// the carrier message id.
///
/// Every projection is a typed `OrderedJSON` tree whose member order is the
/// published legacy order, rendered once. The card rows live in
/// `ManagedMCPAndCardsStore`; the live server name comes from the OAuth ledger.
struct ActionCardMetadataProjection: Sendable {
    let cards: ManagedMCPAndCardsStore
    let oauth: OAuthLedger
    var now: @Sendable () -> Date = { Date() }

    /// The projection of whichever card the message id carries, or `nil`.
    func metadata(messageId: String) -> String? {
        if let card = cards.marketplaceInstallCard(messageId: messageId) {
            return marketplaceInstall(card)
        }
        if let card = cards.integrationRegisterCard(messageId: messageId) {
            return integrationRegister(card)
        }
        return nil
    }

    func marketplaceInstall(_ card: MarketplaceInstallCard) -> String {
        marketplaceInstallTree(card).render()
    }

    func integrationRegister(_ card: IntegrationRegisterCard) -> String {
        integrationRegisterTree(card).render()
    }

    /// The live server name an action-card metadata projection publishes.
    private func serverName(_ serverId: String) -> String {
        oauth.serverProfile(id: serverId)?.name ?? "this Server"
    }

    // MARK: - Marketplace install

    private func marketplaceInstallTree(_ card: MarketplaceInstallCard) -> OrderedJSON {
        var body = OrderedJSONObject()
        body.append("kind", "action-card")
        body.append("sourceServerId", card.serverId)
        body.append("targetServerName", serverName(card.serverId))
        body.append("action", marketplaceInstallAction(card))
        body.append("presentation", marketplaceInstallPresentation(card))
        body.append("state", card.state)
        body.append("executedAt", card.state == "executed"
            ? OrderedJSON.string(ISO8601DateFormatter().string(from: now()))
            : OrderedJSON.null)
        body.append("executedByUserId", OrderedJSON.stringOrNull(card.executedByUserId))
        body.append("result", OrderedJSON.raw(card.resultJSON ?? "null"))
        return body.json
    }

    private func marketplaceInstallAction(_ card: MarketplaceInstallCard) -> OrderedJSON {
        var action = OrderedJSONObject()
        action.append("type", "integration:install_marketplace_app")
        action.append("clientId", card.clientRecordId)
        action.append("clientKey", card.clientKey)
        action.append("clientName", card.clientName)
        action.append("clientNameSha256", card.clientNameSha256)
        action.append("agentId", card.agentId)
        action.append("agentName", card.agentName)
        action.append("scopes", OrderedJSON.array(card.scopes.map(OrderedJSON.string)))
        action.append("setupUrl", OrderedJSON.stringOrNull(card.setupUrl))
        action.append("setupRevision", card.setupRevision)
        action.append(
            "draftHint",
            "\(card.agentName) requested \(card.clientName), which is public in the Raft Marketplace but is not installed on this Server. Installing is a Server owner/admin action; the Agent cannot install it automatically."
        )
        return action.json
    }

    private func marketplaceInstallPresentation(_ card: MarketplaceInstallCard) -> OrderedJSON {
        var items: [OrderedJSON] = [
            Self.displayItem("clientId", card.clientRecordId),
            Self.displayItem("clientKey", card.clientKey),
            Self.displayItem("clientName", card.clientName),
            Self.displayItem("agentId", card.agentId),
            Self.displayItem("agentName", card.agentName),
        ]
        if !card.scopes.isEmpty {
            items.append(Self.displayItem("scopes", Self.quotedScopeList(card.scopes)))
        }
        var presentation = OrderedJSONObject()
        presentation.append("title", "Install \(card.clientName) on this Server")
        presentation.append("confirmLabel", "Install App")
        presentation.append("genericApprovalAllowed", true)
        presentation.append("displayItems", OrderedJSON.array(items))
        presentation.append(
            "warning",
            "This installs the Marketplace app for this Server so @\(card.agentName) can request the listed scopes."
        )
        presentation.append("riskLevel", "elevated")
        return presentation.json
    }

    // MARK: - Integration registration

    private func integrationRegisterTree(_ card: IntegrationRegisterCard) -> OrderedJSON {
        var body = OrderedJSONObject()
        body.append("kind", "action-card")
        body.append("sourceServerId", card.serverId)
        body.append("targetServerName", serverName(card.serverId))
        body.append("action", integrationRegisterAction(card))
        body.append("presentation", integrationRegisterPresentation(card))
        body.append("state", card.state)
        body.append("executedByUserId", OrderedJSON.stringOrNull(card.executedByUserId))
        body.append("result", OrderedJSON.raw(card.resultJSON ?? "null"))
        return body.json
    }

    private func integrationRegisterAction(_ card: IntegrationRegisterCard) -> OrderedJSON {
        var action = OrderedJSONObject()
        action.append("type", "integration:register_app")
        action.append("name", card.name)
        action.append("clientKey", ifPresent: card.clientKey)
        action.append("homepageUrl", ifPresent: card.homepageUrl)
        action.append("returnUrl", card.returnUrl)
        action.append("agentManifestUrl", ifPresent: card.agentManifestUrl)
        action.append("scopes", OrderedJSON.array(card.scopes.map(OrderedJSON.string)))
        action.append("setupUrl", ifPresent: card.setupUrl)
        action.append("setupDescription", ifPresent: card.setupDescription)
        return action.json
    }

    private func integrationRegisterPresentation(_ card: IntegrationRegisterCard) -> OrderedJSON {
        var items: [OrderedJSON] = [Self.displayItem("name", card.name)]
        if let clientKey = card.clientKey {
            items.append(Self.displayItem("clientKey", clientKey))
        }
        items.append(Self.displayItem("returnUrl", card.returnUrl))
        if !card.scopes.isEmpty {
            items.append(Self.displayItem("scopes", Self.quotedScopeList(card.scopes)))
        }
        var presentation = OrderedJSONObject()
        presentation.append("title", "Register Connected App \(card.name)")
        presentation.append("confirmLabel", "Register App")
        presentation.append("genericApprovalAllowed", true)
        presentation.append("displayItems", OrderedJSON.array(items))
        presentation.append(
            "warning",
            "The requesting agent becomes the initial app owner. No client secret is stored in this card."
        )
        presentation.append("riskLevel", "elevated")
        return presentation.json
    }

    /// The legacy display value is the already-quoted scope list
    /// (`"openid", "email"`), which the item then prints as a JSON string again.
    /// The doubled quoting is published behavior and is kept.
    private static func quotedScopeList(_ scopes: [String]) -> String {
        scopes.map { OrderedJSON.string($0).render() }.joined(separator: ", ")
    }

    private static func displayItem(_ key: String, _ value: String) -> OrderedJSON {
        .object([OrderedJSONField("key", key), OrderedJSONField("value", value)])
    }
}
