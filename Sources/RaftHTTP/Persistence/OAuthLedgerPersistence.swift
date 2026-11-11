import Foundation

/// Errors contain format metadata only, never signing material or business rows.
public enum OAuthLedgerPersistenceError: Error, Sendable {
    case invalidFormat
    case unsupportedVersion(Int)
    case unsupportedDateEncoding
    case unsupportedSigningKeyDerivation
}

extension OAuthLedger {
    /// Capture all OAuth business rows and the current signing secret as opaque bytes.
    ///
    /// Callers must exclude concurrent mutations and secret changes across this call.
    /// The ledger's row Mutex and signing-secret Mutex are separate. This codec does
    /// not provide the transaction/commit boundary across them or across other owners.
    /// Encoding happens after the row borrow ends. No callback or network configuration
    /// exists in this ledger State; server/client/agent settings are business facts.
    public func exportPersistenceData() throws -> Data {
        let secret = jwtSecret
        let businessState = state.withLock { $0 }
        let snapshot = OAuthLedgerPersistenceSnapshot(jwtSecret: secret, businessState: businessState)
        return try OAuthLedgerPersistenceFormat.encoder().encode(snapshot)
    }

    /// Preflight a component before applying any part of a multi-owner restore.
    /// This checks the same complete schema as restore without changing an owner.
    public static func validatePersistenceData(_ data: Data) throws {
        _ = try OAuthLedgerPersistenceFormat.decoder().decode(
            OAuthLedgerPersistenceSnapshot.self, from: data
        )
    }

    /// Validate and decode completely before replacing any state.
    ///
    /// Use during startup before serving requests, or under the same exclusive
    /// persistence gate as export. The stored secret replaces the current secret so
    /// existing tokens and the deterministically derived ES256 key remain valid.
    /// The caller owns durable commit and publication ordering; decoding alone does
    /// not make an HTTP response, socket frame, or multi-owner write atomic.
    public func restorePersistenceData(_ data: Data) throws {
        let snapshot = try OAuthLedgerPersistenceFormat.decoder().decode(
            OAuthLedgerPersistenceSnapshot.self, from: data
        )
        jwtSecret = snapshot.jwtSecret
        state.withLock { $0 = snapshot.businessState }
    }
}

private enum OAuthLedgerPersistenceFormat {
    static let name = "raft.oauth-ledger"
    static let version = 1
    static let dateEncoding = "foundation-reference-date-ieee754-binary64-hex"
    // OAuthIDToken.swift derives the P-256 scalar exclusively from jwtSecret using
    // these fixed HKDF salt/info values and its fixed scalar-reduction algorithm.
    // There is no independently generated private key or key cache to serialize.
    static let signingKeyDerivation = "raft-oidc-v1/hkdf-sha256/id-token-es256-private/p256-v1"

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dataEncodingStrategy = .base64
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            let bits = String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            try value.encode(String(repeating: "0", count: 16 - bits.count) + bits)
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            guard text.utf8.count == 16,
                  text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let bits = UInt64(text, radix: 16)
            else {
                throw DecodingError.dataCorruptedError(
                    in: value, debugDescription: "Invalid OAuth persistence date bits"
                )
            }
            return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
        }
        return decoder
    }
}

/// The snapshot remains private. Public APIs return Data rather than owners or maps.
private struct OAuthLedgerPersistenceSnapshot: Codable {
    let jwtSecret: String
    let businessState: OAuthLedger.State

    private enum CodingKeys: String, CodingKey {
        case format
        case version
        case dateEncoding
        case signingKeyDerivation
        case jwtSecret
        case businessState
    }

    init(jwtSecret: String, businessState: OAuthLedger.State) {
        self.jwtSecret = jwtSecret
        self.businessState = businessState
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .format) == OAuthLedgerPersistenceFormat.name else {
            throw OAuthLedgerPersistenceError.invalidFormat
        }
        let version = try values.decode(Int.self, forKey: .version)
        guard version == OAuthLedgerPersistenceFormat.version else {
            throw OAuthLedgerPersistenceError.unsupportedVersion(version)
        }
        guard try values.decode(String.self, forKey: .dateEncoding) == OAuthLedgerPersistenceFormat.dateEncoding else {
            throw OAuthLedgerPersistenceError.unsupportedDateEncoding
        }
        guard try values.decode(String.self, forKey: .signingKeyDerivation) == OAuthLedgerPersistenceFormat.signingKeyDerivation else {
            throw OAuthLedgerPersistenceError.unsupportedSigningKeyDerivation
        }
        jwtSecret = try values.decode(String.self, forKey: .jwtSecret)
        businessState = try values.decode(OAuthLedger.State.self, forKey: .businessState)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(OAuthLedgerPersistenceFormat.name, forKey: .format)
        try values.encode(OAuthLedgerPersistenceFormat.version, forKey: .version)
        try values.encode(OAuthLedgerPersistenceFormat.dateEncoding, forKey: .dateEncoding)
        try values.encode(OAuthLedgerPersistenceFormat.signingKeyDerivation, forKey: .signingKeyDerivation)
        try values.encode(jwtSecret, forKey: .jwtSecret)
        try values.encode(businessState, forKey: .businessState)
    }
}

extension OAuthLedger.State: Codable {
    private enum CodingKeys: String, CodingKey {
        case servers
        case agents
        case agentRoles
        case clientMaintainerOwners
        case agentEvents
        case revokedGrantClients
        case agentGrants
        case autoGrantBlocked
        case members
        case channelRecords
        case channelHumans
        case channelAgents
        case channelMessages
        case channelSystemMessages
        case channelNotificationPrefs
        case channelReadCursors
        case channelDisplayPrefs
        case savedMessageRecords
        case savedMessageCounter
        case sidebarOrders
        case serverAgreementRecords
        case serverPushMutes
        case clients
        case clientShareLinks
        case integrationAuditEvents
        case requests
        case tokens
        case installations
        case installationTokens
        case officialAppClientIds
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        servers = try values.decode([String: OAuthLedger.Server].self, forKey: .servers)
        agents = try values.decode([String: OAuthLedger.Agent].self, forKey: .agents)
        agentRoles = try values.decode([String: String].self, forKey: .agentRoles)
        clientMaintainerOwners = try values.decode([String: Set<String>].self, forKey: .clientMaintainerOwners)
        agentEvents = try values.decode([OAuthLedger.AgentEvent].self, forKey: .agentEvents)
        revokedGrantClients = try values.decode(Set<String>.self, forKey: .revokedGrantClients)
        agentGrants = try values.decode([OAuthLedger.AgentGrant].self, forKey: .agentGrants)
        autoGrantBlocked = try values.decode(Set<String>.self, forKey: .autoGrantBlocked)
        members = try values.decode([String: String].self, forKey: .members)
        channelRecords = try values.decode([OAuthLedger.ChannelRecord].self, forKey: .channelRecords)
        channelHumans = try values.decode(Set<String>.self, forKey: .channelHumans)
        channelAgents = try values.decode(Set<String>.self, forKey: .channelAgents)
        channelMessages = try values.decode([OAuthLedger.ChannelMessageRecord].self, forKey: .channelMessages)
        channelSystemMessages = try values.decode([OAuthLedger.ChannelSystemMessageRecord].self, forKey: .channelSystemMessages)
        channelNotificationPrefs = try values.decode([String: OAuthLedger.ChannelNotificationPrefs].self, forKey: .channelNotificationPrefs)
        channelReadCursors = try values.decode([String: Int].self, forKey: .channelReadCursors)
        channelDisplayPrefs = try values.decode([String: OAuthLedger.ChannelDisplayPrefs].self, forKey: .channelDisplayPrefs)
        savedMessageRecords = try values.decode([OAuthLedger.SavedMessageRecord].self, forKey: .savedMessageRecords)
        savedMessageCounter = try values.decode(Int.self, forKey: .savedMessageCounter)
        sidebarOrders = try values.decode([String: OAuthLedger.SidebarOrder].self, forKey: .sidebarOrders)
        serverAgreementRecords = try values.decode([String: [OAuthLedger.ServerAgreementInfo]].self, forKey: .serverAgreementRecords)
        serverPushMutes = try values.decode(Set<String>.self, forKey: .serverPushMutes)
        clients = try values.decode([OAuthLedger.Client].self, forKey: .clients)
        clientShareLinks = try values.decodeIfPresent([OAuthLedger.ClientShareLink].self, forKey: .clientShareLinks) ?? []
        integrationAuditEvents = try values.decode([OAuthLedger.IntegrationAuditEvent].self, forKey: .integrationAuditEvents)
        requests = try values.decode([OAuthLedger.AccessRequest].self, forKey: .requests)
        tokens = try values.decode([OAuthLedger.AccessToken].self, forKey: .tokens)
        installations = try values.decode([OAuthLedger.Installation].self, forKey: .installations)
        installationTokens = try values.decode([OAuthLedger.InstallationToken].self, forKey: .installationTokens)
        officialAppClientIds = try values.decode(Set<String>.self, forKey: .officialAppClientIds)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(servers, forKey: .servers)
        try values.encode(agents, forKey: .agents)
        try values.encode(agentRoles, forKey: .agentRoles)
        try values.encode(clientMaintainerOwners, forKey: .clientMaintainerOwners)
        try values.encode(agentEvents, forKey: .agentEvents)
        try values.encode(revokedGrantClients, forKey: .revokedGrantClients)
        try values.encode(agentGrants, forKey: .agentGrants)
        try values.encode(autoGrantBlocked, forKey: .autoGrantBlocked)
        try values.encode(members, forKey: .members)
        try values.encode(channelRecords, forKey: .channelRecords)
        try values.encode(channelHumans, forKey: .channelHumans)
        try values.encode(channelAgents, forKey: .channelAgents)
        try values.encode(channelMessages, forKey: .channelMessages)
        try values.encode(channelSystemMessages, forKey: .channelSystemMessages)
        try values.encode(channelNotificationPrefs, forKey: .channelNotificationPrefs)
        try values.encode(channelReadCursors, forKey: .channelReadCursors)
        try values.encode(channelDisplayPrefs, forKey: .channelDisplayPrefs)
        try values.encode(savedMessageRecords, forKey: .savedMessageRecords)
        try values.encode(savedMessageCounter, forKey: .savedMessageCounter)
        try values.encode(sidebarOrders, forKey: .sidebarOrders)
        try values.encode(serverAgreementRecords, forKey: .serverAgreementRecords)
        try values.encode(serverPushMutes, forKey: .serverPushMutes)
        try values.encode(clients, forKey: .clients)
        try values.encode(clientShareLinks, forKey: .clientShareLinks)
        try values.encode(integrationAuditEvents, forKey: .integrationAuditEvents)
        try values.encode(requests, forKey: .requests)
        try values.encode(tokens, forKey: .tokens)
        try values.encode(installations, forKey: .installations)
        try values.encode(installationTokens, forKey: .installationTokens)
        try values.encode(officialAppClientIds, forKey: .officialAppClientIds)
    }
}
