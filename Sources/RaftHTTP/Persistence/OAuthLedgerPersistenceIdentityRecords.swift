import Foundation

// Explicit witnesses are required because these records are declared in other files.
extension OAuthLedger.Server: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case slug
        case name
        case ownerId
        case avatarUrl
        case plan
        case deleted
        case productAnalyticsEnabled
        case translationEnabled
        case publiclyVisible
        case publicGuestJoinEnabled
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.slug = try values.decode(String.self, forKey: .slug)
        self.name = try values.decode(String.self, forKey: .name)
        self.ownerId = try values.decode(String.self, forKey: .ownerId)
        self.avatarUrl = try values.decode(String?.self, forKey: .avatarUrl)
        self.plan = try values.decode(String.self, forKey: .plan)
        self.deleted = try values.decode(Bool.self, forKey: .deleted)
        self.productAnalyticsEnabled = try values.decode(Bool.self, forKey: .productAnalyticsEnabled)
        self.translationEnabled = try values.decode(Bool.self, forKey: .translationEnabled)
        self.publiclyVisible = try values.decode(Bool.self, forKey: .publiclyVisible)
        self.publicGuestJoinEnabled = try values.decode(Bool.self, forKey: .publicGuestJoinEnabled)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(slug, forKey: .slug)
        try values.encode(name, forKey: .name)
        try values.encode(ownerId, forKey: .ownerId)
        try values.encode(avatarUrl, forKey: .avatarUrl)
        try values.encode(plan, forKey: .plan)
        try values.encode(deleted, forKey: .deleted)
        try values.encode(productAnalyticsEnabled, forKey: .productAnalyticsEnabled)
        try values.encode(translationEnabled, forKey: .translationEnabled)
        try values.encode(publiclyVisible, forKey: .publiclyVisible)
        try values.encode(publicGuestJoinEnabled, forKey: .publicGuestJoinEnabled)
    }
}

extension OAuthLedger.Agent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case serverId
        case name
        case displayName
        case avatarUrl
        case description
        case creatorUserId
        case runtime
        case runtimeConfigJSON
        case envVarsJSON
        case status
        case deleted
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.serverId = try values.decode(String.self, forKey: .serverId)
        self.name = try values.decode(String.self, forKey: .name)
        self.displayName = try values.decode(String.self, forKey: .displayName)
        self.avatarUrl = try values.decode(String?.self, forKey: .avatarUrl)
        self.description = try values.decode(String?.self, forKey: .description)
        self.creatorUserId = try values.decode(String?.self, forKey: .creatorUserId)
        self.runtime = try values.decode(String.self, forKey: .runtime)
        self.runtimeConfigJSON = try values.decode(String?.self, forKey: .runtimeConfigJSON)
        self.envVarsJSON = try values.decode(String?.self, forKey: .envVarsJSON)
        self.status = try values.decode(String.self, forKey: .status)
        self.deleted = try values.decode(Bool.self, forKey: .deleted)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(serverId, forKey: .serverId)
        try values.encode(name, forKey: .name)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(avatarUrl, forKey: .avatarUrl)
        try values.encode(description, forKey: .description)
        try values.encode(creatorUserId, forKey: .creatorUserId)
        try values.encode(runtime, forKey: .runtime)
        try values.encode(runtimeConfigJSON, forKey: .runtimeConfigJSON)
        try values.encode(envVarsJSON, forKey: .envVarsJSON)
        try values.encode(status, forKey: .status)
        try values.encode(deleted, forKey: .deleted)
    }
}

extension OAuthLedger.AgentGrant: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case serverId
        case agentId
        case clientRecordId
        case scopes
        case grantSource
        case grantedByUserId
        case createdAt
        case revokedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.serverId = try values.decode(String.self, forKey: .serverId)
        self.agentId = try values.decode(String.self, forKey: .agentId)
        self.clientRecordId = try values.decode(String.self, forKey: .clientRecordId)
        self.scopes = try values.decode([String].self, forKey: .scopes)
        self.grantSource = try values.decode(String.self, forKey: .grantSource)
        self.grantedByUserId = try values.decode(String?.self, forKey: .grantedByUserId)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.revokedAt = try values.decode(Date?.self, forKey: .revokedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(serverId, forKey: .serverId)
        try values.encode(agentId, forKey: .agentId)
        try values.encode(clientRecordId, forKey: .clientRecordId)
        try values.encode(scopes, forKey: .scopes)
        try values.encode(grantSource, forKey: .grantSource)
        try values.encode(grantedByUserId, forKey: .grantedByUserId)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(revokedAt, forKey: .revokedAt)
    }
}

extension OAuthLedger.AgentEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case serverId
        case agentId
        case clientId
        case kind
        case summary
        case payloadHash
        case payloadJSON
        case externalEventId
        case status
        case expiresAt
        case createdAt
        case deliveredAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.serverId = try values.decode(String.self, forKey: .serverId)
        self.agentId = try values.decode(String.self, forKey: .agentId)
        self.clientId = try values.decode(String.self, forKey: .clientId)
        self.kind = try values.decode(String.self, forKey: .kind)
        self.summary = try values.decode(String.self, forKey: .summary)
        self.payloadHash = try values.decode(String.self, forKey: .payloadHash)
        self.payloadJSON = try values.decode(String.self, forKey: .payloadJSON)
        self.externalEventId = try values.decode(String?.self, forKey: .externalEventId)
        self.status = try values.decode(String.self, forKey: .status)
        self.expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.deliveredAt = try values.decode(Date?.self, forKey: .deliveredAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(serverId, forKey: .serverId)
        try values.encode(agentId, forKey: .agentId)
        try values.encode(clientId, forKey: .clientId)
        try values.encode(kind, forKey: .kind)
        try values.encode(summary, forKey: .summary)
        try values.encode(payloadHash, forKey: .payloadHash)
        try values.encode(payloadJSON, forKey: .payloadJSON)
        try values.encode(externalEventId, forKey: .externalEventId)
        try values.encode(status, forKey: .status)
        try values.encode(expiresAt, forKey: .expiresAt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(deliveredAt, forKey: .deliveredAt)
    }
}
