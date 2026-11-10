import Foundation

extension ManagedMCPAndCardsStore {
    /// Capture under the owner borrow; construct and encode the private DTO outside it.
    /// Call under the coordinator's exclusive gate for a multi-owner consistent cut.
    func exportPersistenceData() throws -> Data {
        let captured = storage.withLock { $0 }
        return try CollaborationPersistenceCoding.encode(CPCardsSnapshot(captured), format: "raft.managed-mcp-and-cards")
    }

    /// Fully decode and validate before the short business-field replacement borrow.
    /// Preserves this owner instance and does not publish any callbacks or frames.
    func restorePersistenceData(_ data: Data) throws {
        let decoded = try CollaborationPersistenceCoding.decode(CPCardsSnapshot.self, from: data, format: "raft.managed-mcp-and-cards")
        let restored = decoded.restored()
        storage.withLock { current in
            current.managedMCPServers = restored.managedMCPServers
            current.managedMCPAssignments = restored.managedMCPAssignments
            current.actionCardRecords = restored.actionCardRecords
            current.marketplaceInstallCards = restored.marketplaceInstallCards
            current.integrationRegisterCards = restored.integrationRegisterCards
            current.agentApiSendReceipts = restored.agentApiSendReceipts
            current.pendingActionMessageEvents = restored.pendingActionMessageEvents
            current.agentGrantSets = restored.agentGrantSets
            current.appConfigOverrides = restored.appConfigOverrides
            current.appConfigRevisions = restored.appConfigRevisions
            current.agentIntegrationGrants = restored.agentIntegrationGrants
            current.agentAudienceStatusOverrides = restored.agentAudienceStatusOverrides
            current.agentIntegrationLogins = restored.agentIntegrationLogins
            current.providerConnectionsEnabledServers = restored.providerConnectionsEnabledServers
            current.providerConnections = restored.providerConnections
            current.providerCredentials = restored.providerCredentials
            current.providerAssignments = restored.providerAssignments
            current.agentApiIdempotencyKeys = restored.agentApiIdempotencyKeys
        }
    }
}

private struct CPCardsSnapshot: Codable {
    var managedMCPServers: [CPMCPServer]
    var managedMCPAssignments: [String: [String: CPAssignment]]
    var actionCardRecords: [String: CPActionCard]
    var marketplaceInstallCards: [String: CPMarketplaceCard]
    var integrationRegisterCards: [String: CPIntegrationCard]
    var agentApiSendReceipts: [String: CPSendReceipt]
    var pendingActionMessageEvents: [CPPendingActionEvent]
    var agentGrantSets: [String: Set<String>]
    var appConfigOverrides: [String: [String: [String: CPConfigValue]]]
    var appConfigRevisions: [String: [String: Int]]
    var agentIntegrationGrants: [String: Bool]
    var agentAudienceStatusOverrides: [String: String]
    var agentIntegrationLogins: [String: CPIntegrationLogin]
    var providerConnectionsEnabledServers: Set<String>
    var providerConnections: [CPProviderConnection]
    /// Cards business payload v2; the shared collaboration envelope remains v1.
    var providerCredentialStorageVersion: Int
    var providerCredentials: [String: ProviderCredentialEnvelope]
    var providerAssignments: [CPProviderAssignment]
    var agentApiIdempotencyKeys: [CPIdempotency]

    init(_ value: ManagedMCPAndCardsStore.State) throws {
        managedMCPServers = value.managedMCPServers.map(CPMCPServer.init)
        managedMCPAssignments = value.managedMCPAssignments.mapValues { $0.mapValues(CPAssignment.init) }
        actionCardRecords = value.actionCardRecords.mapValues(CPActionCard.init)
        marketplaceInstallCards = value.marketplaceInstallCards.mapValues(CPMarketplaceCard.init)
        integrationRegisterCards = value.integrationRegisterCards.mapValues(CPIntegrationCard.init)
        agentApiSendReceipts = value.agentApiSendReceipts.mapValues(CPSendReceipt.init)
        pendingActionMessageEvents = value.pendingActionMessageEvents.map(CPPendingActionEvent.init)
        agentGrantSets = value.agentGrantSets
        appConfigOverrides = value.appConfigOverrides.mapValues { $0.mapValues { $0.mapValues(CPConfigValue.init) } }
        appConfigRevisions = value.appConfigRevisions
        agentIntegrationGrants = value.agentIntegrationGrants
        agentAudienceStatusOverrides = value.agentAudienceStatusOverrides
        agentIntegrationLogins = value.agentIntegrationLogins.mapValues(CPIntegrationLogin.init)
        providerConnectionsEnabledServers = value.providerConnectionsEnabledServers
        providerConnections = value.providerConnections.map(CPProviderConnection.init)
        providerCredentialStorageVersion = 2
        providerCredentials = value.providerCredentials
        providerAssignments = value.providerAssignments.map(CPProviderAssignment.init)
        agentApiIdempotencyKeys = value.agentApiIdempotencyKeys.map(CPIdempotency.init)
        try validateCredentials()
    }

    private enum CodingKeys: String, CodingKey {
        case managedMCPServers, managedMCPAssignments, actionCardRecords, marketplaceInstallCards
        case integrationRegisterCards, agentApiSendReceipts, pendingActionMessageEvents, agentGrantSets
        case appConfigOverrides, appConfigRevisions, agentIntegrationGrants, agentAudienceStatusOverrides
        case agentIntegrationLogins, providerConnectionsEnabledServers, providerConnections
        case providerCredentialStorageVersion, providerCredentials, providerAssignments, agentApiIdempotencyKeys
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        managedMCPServers = try values.decode([CPMCPServer].self, forKey: .managedMCPServers)
        managedMCPAssignments = try values.decode([String: [String: CPAssignment]].self, forKey: .managedMCPAssignments)
        actionCardRecords = try values.decode([String: CPActionCard].self, forKey: .actionCardRecords)
        marketplaceInstallCards = try values.decode([String: CPMarketplaceCard].self, forKey: .marketplaceInstallCards)
        integrationRegisterCards = try values.decode([String: CPIntegrationCard].self, forKey: .integrationRegisterCards)
        agentApiSendReceipts = try values.decode([String: CPSendReceipt].self, forKey: .agentApiSendReceipts)
        pendingActionMessageEvents = try values.decode([CPPendingActionEvent].self, forKey: .pendingActionMessageEvents)
        agentGrantSets = try values.decode([String: Set<String>].self, forKey: .agentGrantSets)
        appConfigOverrides = try values.decode([String: [String: [String: CPConfigValue]]].self, forKey: .appConfigOverrides)
        appConfigRevisions = try values.decode([String: [String: Int]].self, forKey: .appConfigRevisions)
        agentIntegrationGrants = try values.decode([String: Bool].self, forKey: .agentIntegrationGrants)
        agentAudienceStatusOverrides = try values.decode([String: String].self, forKey: .agentAudienceStatusOverrides)
        agentIntegrationLogins = try values.decode([String: CPIntegrationLogin].self, forKey: .agentIntegrationLogins)
        providerConnectionsEnabledServers = try values.decode(Set<String>.self, forKey: .providerConnectionsEnabledServers)
        providerConnections = try values.decode([CPProviderConnection].self, forKey: .providerConnections)
        providerAssignments = try values.decode([CPProviderAssignment].self, forKey: .providerAssignments)
        agentApiIdempotencyKeys = try values.decode([CPIdempotency].self, forKey: .agentApiIdempotencyKeys)

        if values.contains(.providerCredentialStorageVersion) {
            // A v2 payload must supply the full map and every required Data field.
            // Missing/null fields are a corrupt snapshot, never an empty credential default.
            providerCredentialStorageVersion = try values.decode(Int.self, forKey: .providerCredentialStorageVersion)
            providerCredentials = try values.decode([String: ProviderCredentialEnvelope].self, forKey: .providerCredentials)
        } else {
            // The legacy v1 payload never saved API keys. Its only lossless migration
            // is a state with no credential-bearing rows. Lost keys cannot be recovered.
            guard !values.contains(.providerCredentials) else {
                throw ProviderCredentialError.invalidPersistedCredentials
            }
            guard providerConnections.allSatisfy({ !$0.hasCredential }) else {
                throw ProviderCredentialError.legacyCredentialsRequireReplacement
            }
            providerCredentialStorageVersion = 2
            providerCredentials = [:]
        }
        try validateCredentials()
    }

    private func validateCredentials() throws {
        guard providerCredentialStorageVersion == 2 else {
            throw ProviderCredentialError.invalidPersistedCredentials
        }
        var connectionIDs = Set<String>()
        for connection in providerConnections {
            guard connectionIDs.insert(connection.id).inserted else {
                throw ProviderCredentialError.invalidPersistedCredentials
            }
            if connection.hasCredential {
                guard connection.credentialVersion > 0,
                      let credential = providerCredentials[connection.id], credential.hasSupportedFormat else {
                    throw ProviderCredentialError.invalidPersistedCredentials
                }
            } else if providerCredentials[connection.id] != nil {
                throw ProviderCredentialError.invalidPersistedCredentials
            }
        }
        guard providerCredentials.keys.allSatisfy({ connectionIDs.contains($0) }) else {
            throw ProviderCredentialError.invalidPersistedCredentials
        }
    }

    func restored() -> ManagedMCPAndCardsStore.State {
        var value = ManagedMCPAndCardsStore.State()
        value.managedMCPServers = managedMCPServers.map { $0.restored() }
        value.managedMCPAssignments = managedMCPAssignments.mapValues { $0.mapValues { $0.restored() } }
        value.actionCardRecords = actionCardRecords.mapValues { $0.restored() }
        value.marketplaceInstallCards = marketplaceInstallCards.mapValues { $0.restored() }
        value.integrationRegisterCards = integrationRegisterCards.mapValues { $0.restored() }
        value.agentApiSendReceipts = agentApiSendReceipts.mapValues { $0.restored() }
        value.pendingActionMessageEvents = pendingActionMessageEvents.map { $0.restored() }
        value.agentGrantSets = agentGrantSets
        value.appConfigOverrides = appConfigOverrides.mapValues { $0.mapValues { $0.mapValues { $0.restored() } } }
        value.appConfigRevisions = appConfigRevisions
        value.agentIntegrationGrants = agentIntegrationGrants
        value.agentAudienceStatusOverrides = agentAudienceStatusOverrides
        value.agentIntegrationLogins = agentIntegrationLogins.mapValues { $0.restored() }
        value.providerConnectionsEnabledServers = providerConnectionsEnabledServers
        value.providerConnections = providerConnections.map { $0.restored() }
        value.providerCredentials = providerCredentials
        value.providerAssignments = providerAssignments.map { $0.restored() }
        value.agentApiIdempotencyKeys = agentApiIdempotencyKeys.map { $0.restored() }
        return value
    }
}

private struct CPMCPServer: Codable {
    var id: String
    var serverId: String
    var name: String
    var provider: String?
    var authMode: String?
    var oauthStatus: String?
    var endpointUrl: String
    var toolCatalogJSON: String
    var catalogVersion: Int
    var credentialHeaderNames: [String]
    var credentialHeaders: [String: String]

    init(_ value: ManagedMCPServerRecord) {
        id = value.id
        serverId = value.serverId
        name = value.name
        provider = value.provider
        authMode = value.authMode
        oauthStatus = value.oauthStatus
        endpointUrl = value.endpointUrl
        toolCatalogJSON = value.toolCatalogJSON
        catalogVersion = value.catalogVersion
        credentialHeaderNames = value.credentialHeaderNames
        credentialHeaders = value.credentialHeaders
    }

    func restored() -> ManagedMCPServerRecord {
        ManagedMCPServerRecord(id: id, serverId: serverId, name: name, provider: provider, authMode: authMode, oauthStatus: oauthStatus, endpointUrl: endpointUrl, toolCatalogJSON: toolCatalogJSON, catalogVersion: catalogVersion, credentialHeaderNames: credentialHeaderNames, credentialHeaders: credentialHeaders)
    }
}

private struct CPAssignment: Codable {
    var enabled: Bool
    var allowedTools: [String]?

    init(_ value: (enabled: Bool, allowedTools: [String]?)) {
        enabled = value.enabled
        allowedTools = value.allowedTools
    }

    func restored() -> (enabled: Bool, allowedTools: [String]?) {
        (enabled: enabled, allowedTools: allowedTools)
    }
}

private struct CPActionCard: Codable {
    var messageId: String
    var serverId: String
    var requesterAgentId: String
    var storageChannelId: String
    var localCarrierChannelId: String
    var actionType: String
    var channelName: String?
    var visibility: String
    var state: String
    var executedByUserId: String?

    init(_ value: ActionCardRecord) {
        messageId = value.messageId
        serverId = value.serverId
        requesterAgentId = value.requesterAgentId
        storageChannelId = value.storageChannelId
        localCarrierChannelId = value.localCarrierChannelId
        actionType = value.actionType
        channelName = value.channelName
        visibility = value.visibility
        state = value.state
        executedByUserId = value.executedByUserId
    }

    func restored() -> ActionCardRecord {
        ActionCardRecord(messageId: messageId, serverId: serverId, requesterAgentId: requesterAgentId, storageChannelId: storageChannelId, localCarrierChannelId: localCarrierChannelId, actionType: actionType, channelName: channelName, visibility: visibility, state: state, executedByUserId: executedByUserId)
    }
}

private struct CPMarketplaceCard: Codable {
    var messageId: String
    var serverId: String
    var clientRecordId: String
    var clientKey: String
    var clientName: String
    var clientNameSha256: String
    var agentId: String
    var agentName: String
    var scopes: [String]
    var storageChannelId: String
    var localCarrierChannelId: String
    var state: String
    var executedByUserId: String?
    var resultJSON: String?
    var setupUrl: String?
    var setupRevision: Int

    init(_ value: MarketplaceInstallCard) {
        messageId = value.messageId
        serverId = value.serverId
        clientRecordId = value.clientRecordId
        clientKey = value.clientKey
        clientName = value.clientName
        clientNameSha256 = value.clientNameSha256
        agentId = value.agentId
        agentName = value.agentName
        scopes = value.scopes
        storageChannelId = value.storageChannelId
        localCarrierChannelId = value.localCarrierChannelId
        state = value.state
        executedByUserId = value.executedByUserId
        resultJSON = value.resultJSON
        setupUrl = value.setupUrl
        setupRevision = value.setupRevision
    }

    func restored() -> MarketplaceInstallCard {
        MarketplaceInstallCard(messageId: messageId, serverId: serverId, clientRecordId: clientRecordId, clientKey: clientKey, clientName: clientName, clientNameSha256: clientNameSha256, agentId: agentId, agentName: agentName, scopes: scopes, storageChannelId: storageChannelId, localCarrierChannelId: localCarrierChannelId, state: state, executedByUserId: executedByUserId, resultJSON: resultJSON, setupUrl: setupUrl, setupRevision: setupRevision)
    }
}

private struct CPIntegrationCard: Codable {
    var messageId: String
    var serverId: String
    var agentId: String
    var agentName: String
    var storageChannelId: String
    var localCarrierChannelId: String
    var name: String
    var clientKey: String?
    var homepageUrl: String?
    var returnUrl: String
    var agentManifestUrl: String?
    var setupUrl: String?
    var setupDescription: String?
    var scopes: [String]
    var state: String
    var executedByUserId: String?
    var resultJSON: String?

    init(_ value: IntegrationRegisterCard) {
        messageId = value.messageId
        serverId = value.serverId
        agentId = value.agentId
        agentName = value.agentName
        storageChannelId = value.storageChannelId
        localCarrierChannelId = value.localCarrierChannelId
        name = value.name
        clientKey = value.clientKey
        homepageUrl = value.homepageUrl
        returnUrl = value.returnUrl
        agentManifestUrl = value.agentManifestUrl
        setupUrl = value.setupUrl
        setupDescription = value.setupDescription
        scopes = value.scopes
        state = value.state
        executedByUserId = value.executedByUserId
        resultJSON = value.resultJSON
    }

    func restored() -> IntegrationRegisterCard {
        IntegrationRegisterCard(messageId: messageId, serverId: serverId, agentId: agentId, agentName: agentName, storageChannelId: storageChannelId, localCarrierChannelId: localCarrierChannelId, name: name, clientKey: clientKey, homepageUrl: homepageUrl, returnUrl: returnUrl, agentManifestUrl: agentManifestUrl, setupUrl: setupUrl, setupDescription: setupDescription, scopes: scopes, state: state, executedByUserId: executedByUserId, resultJSON: resultJSON)
    }
}

private struct CPSendReceipt: Codable {
    var messageId: String
    var messageSeq: Int
    var target: String
    var content: String
    var attachmentIds: [String]

    init(_ value: AgentApiSendReceipt) {
        messageId = value.messageId
        messageSeq = value.messageSeq
        target = value.target
        content = value.content
        attachmentIds = value.attachmentIds
    }

    func restored() -> AgentApiSendReceipt {
        AgentApiSendReceipt(messageId: messageId, messageSeq: messageSeq, target: target, content: content, attachmentIds: attachmentIds)
    }
}

private struct CPPendingActionEvent: Codable {
    var agentId: String
    var messageId: String
    var content: String

    init(_ value: (agentId: String, messageId: String, content: String)) {
        agentId = value.agentId
        messageId = value.messageId
        content = value.content
    }

    func restored() -> (agentId: String, messageId: String, content: String) {
        (agentId: agentId, messageId: messageId, content: content)
    }
}

private enum CPConfigValue: Codable {
    case boolean(Bool)
    case integer(Int)
    init(_ value: AppConfigValue) {
        switch value {
        case .boolean(let flag): self = .boolean(flag)
        case .integer(let number): self = .integer(number)
        }
    }
    func restored() -> AppConfigValue {
        switch self {
        case .boolean(let flag): return .boolean(flag)
        case .integer(let number): return .integer(number)
        }
    }
}

private struct CPIntegrationLogin: Codable {
    var serverId: String
    var agentId: String
    var clientId: String
    var scopes: [String]
    var loggedInAt: Date

    init(_ value: AgentIntegrationLoginRecord) {
        serverId = value.serverId
        agentId = value.agentId
        clientId = value.clientId
        scopes = value.scopes
        loggedInAt = value.loggedInAt
    }

    func restored() -> AgentIntegrationLoginRecord {
        AgentIntegrationLoginRecord(serverId: serverId, agentId: agentId, clientId: clientId, scopes: scopes, loggedInAt: loggedInAt)
    }
}

private struct CPProviderConnection: Codable {
    var id: String
    var serverId: String
    var name: String
    var providerId: String
    var endpointUrl: String?
    var supportsImageInput: Bool
    var status: String
    var configVersion: Int
    var credentialVersion: Int
    var hasCredential: Bool
    var createdAt: Date
    var updatedAt: Date

    init(_ value: ProviderConnection) {
        id = value.id
        serverId = value.serverId
        name = value.name
        providerId = value.providerId
        endpointUrl = value.endpointUrl
        supportsImageInput = value.supportsImageInput
        status = value.status
        configVersion = value.configVersion
        credentialVersion = value.credentialVersion
        hasCredential = value.hasCredential
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }

    func restored() -> ProviderConnection {
        ProviderConnection(id: id, serverId: serverId, name: name, providerId: providerId, endpointUrl: endpointUrl, supportsImageInput: supportsImageInput, status: status, configVersion: configVersion, credentialVersion: credentialVersion, hasCredential: hasCredential, createdAt: createdAt, updatedAt: updatedAt)
    }
}

private struct CPProviderAssignment: Codable {
    var connectionId: String
    var serverId: String
    var agentId: String
    var computerName: String?

    init(_ value: ProviderAssignment) {
        connectionId = value.connectionId
        serverId = value.serverId
        agentId = value.agentId
        computerName = value.computerName
    }

    func restored() -> ProviderAssignment {
        ProviderAssignment(connectionId: connectionId, serverId: serverId, agentId: agentId, computerName: computerName)
    }
}

private struct CPIdempotency: Codable {
    var agentId: String
    var route: String
    var key: String
    var fingerprint: String
    var status: Int
    var responseBody: String
    var createdAt: Date

    init(_ value: AgentApiIdempotencyRecord) {
        agentId = value.agentId
        route = value.route
        key = value.key
        fingerprint = value.fingerprint
        status = value.status
        responseBody = value.responseBody
        createdAt = value.createdAt
    }

    func restored() -> AgentApiIdempotencyRecord {
        AgentApiIdempotencyRecord(agentId: agentId, route: route, key: key, fingerprint: fingerprint, status: status, responseBody: responseBody, createdAt: createdAt)
    }
}

