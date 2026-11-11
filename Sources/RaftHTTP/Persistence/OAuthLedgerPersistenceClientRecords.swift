import Foundation

// Explicit witnesses are required because these records are declared in other files.
extension OAuthLedger.Client: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case serverId
        case clientId
        case secretHash
        case appType
        case name
        case createdByUserId
        case descriptionText
        case homepageUrl
        case returnUrl
        case allowedScopes
        case outboundGroups
        case pendingOutboundRevisionId
        case pendingOutboundGroups
        case agentJwtEnabled
        case enabled
        case externalProvider
        case externalState
        case publishStatus
        case humanMarketplaceVisible
        case agentManifestUrl
        case agentManifestUrlSource
        case whenToUse
        case setupUrl
        case setupDescription
        case setupRevision
        case category
        case dataAccessSummary
        case publishRejectionReason
        case publishRequestedAt
        case publishReviewedAt
        case logoUrl
        case logoStorageKey
        case createdAt
        case updatedAt
        case outboundEvents
        case outboundRequestRevision
        case outboundCurrentRevisionId
        case outboundPendingEvents
        case outboundPendingRevisionState
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.serverId = try values.decode(String.self, forKey: .serverId)
        self.clientId = try values.decode(String.self, forKey: .clientId)
        self.secretHash = try values.decode(String.self, forKey: .secretHash)
        self.appType = try values.decode(String.self, forKey: .appType)
        self.name = try values.decode(String.self, forKey: .name)
        self.createdByUserId = try values.decode(String.self, forKey: .createdByUserId)
        self.descriptionText = try values.decode(String?.self, forKey: .descriptionText)
        self.homepageUrl = try values.decode(String?.self, forKey: .homepageUrl)
        self.returnUrl = try values.decode(String?.self, forKey: .returnUrl)
        self.allowedScopes = try values.decode([String]?.self, forKey: .allowedScopes)
        self.outboundGroups = try values.decode([String].self, forKey: .outboundGroups)
        self.pendingOutboundRevisionId = try values.decode(String?.self, forKey: .pendingOutboundRevisionId)
        self.pendingOutboundGroups = try values.decode([String].self, forKey: .pendingOutboundGroups)
        self.agentJwtEnabled = try values.decode(Bool?.self, forKey: .agentJwtEnabled)
        self.enabled = try values.decode(Bool.self, forKey: .enabled)
        self.externalProvider = try values.decode(String?.self, forKey: .externalProvider)
        self.externalState = try values.decode(String?.self, forKey: .externalState)
        self.publishStatus = try values.decode(String.self, forKey: .publishStatus)
        self.humanMarketplaceVisible = try values.decode(Bool.self, forKey: .humanMarketplaceVisible)
        self.agentManifestUrl = try values.decode(String?.self, forKey: .agentManifestUrl)
        self.agentManifestUrlSource = try values.decode(String?.self, forKey: .agentManifestUrlSource)
        self.whenToUse = try values.decode(String?.self, forKey: .whenToUse)
        self.setupUrl = try values.decode(String?.self, forKey: .setupUrl)
        self.setupDescription = try values.decode(String?.self, forKey: .setupDescription)
        self.setupRevision = try values.decode(Int.self, forKey: .setupRevision)
        self.category = try values.decodeIfPresent(String.self, forKey: .category) ?? "Other"
        self.dataAccessSummary = try values.decodeIfPresent(String.self, forKey: .dataAccessSummary)
        self.publishRejectionReason = try values.decodeIfPresent(String.self, forKey: .publishRejectionReason)
        self.publishRequestedAt = try values.decodeIfPresent(Date.self, forKey: .publishRequestedAt)
        self.publishReviewedAt = try values.decodeIfPresent(Date.self, forKey: .publishReviewedAt)
        self.logoUrl = try values.decodeIfPresent(String.self, forKey: .logoUrl)
        self.logoStorageKey = try values.decodeIfPresent(String.self, forKey: .logoStorageKey)
        self.createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.outboundEvents = try values.decodeIfPresent([String].self, forKey: .outboundEvents) ?? []
        self.outboundRequestRevision = try values.decodeIfPresent(Int.self, forKey: .outboundRequestRevision) ?? 0
        self.outboundCurrentRevisionId = try values.decodeIfPresent(String.self, forKey: .outboundCurrentRevisionId)
        self.outboundPendingEvents = try values.decodeIfPresent([String].self, forKey: .outboundPendingEvents) ?? []
        self.outboundPendingRevisionState = try values.decodeIfPresent(String.self, forKey: .outboundPendingRevisionState)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(serverId, forKey: .serverId)
        try values.encode(clientId, forKey: .clientId)
        try values.encode(secretHash, forKey: .secretHash)
        try values.encode(appType, forKey: .appType)
        try values.encode(name, forKey: .name)
        try values.encode(createdByUserId, forKey: .createdByUserId)
        try values.encode(descriptionText, forKey: .descriptionText)
        try values.encode(homepageUrl, forKey: .homepageUrl)
        try values.encode(returnUrl, forKey: .returnUrl)
        try values.encode(allowedScopes, forKey: .allowedScopes)
        try values.encode(outboundGroups, forKey: .outboundGroups)
        try values.encode(pendingOutboundRevisionId, forKey: .pendingOutboundRevisionId)
        try values.encode(pendingOutboundGroups, forKey: .pendingOutboundGroups)
        try values.encode(agentJwtEnabled, forKey: .agentJwtEnabled)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(externalProvider, forKey: .externalProvider)
        try values.encode(externalState, forKey: .externalState)
        try values.encode(publishStatus, forKey: .publishStatus)
        try values.encode(humanMarketplaceVisible, forKey: .humanMarketplaceVisible)
        try values.encode(agentManifestUrl, forKey: .agentManifestUrl)
        try values.encode(agentManifestUrlSource, forKey: .agentManifestUrlSource)
        try values.encode(whenToUse, forKey: .whenToUse)
        try values.encode(setupUrl, forKey: .setupUrl)
        try values.encode(setupDescription, forKey: .setupDescription)
        try values.encode(setupRevision, forKey: .setupRevision)
        try values.encode(category, forKey: .category)
        try values.encode(dataAccessSummary, forKey: .dataAccessSummary)
        try values.encode(publishRejectionReason, forKey: .publishRejectionReason)
        try values.encode(publishRequestedAt, forKey: .publishRequestedAt)
        try values.encode(publishReviewedAt, forKey: .publishReviewedAt)
        try values.encode(logoUrl, forKey: .logoUrl)
        try values.encode(logoStorageKey, forKey: .logoStorageKey)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(outboundEvents, forKey: .outboundEvents)
        try values.encode(outboundRequestRevision, forKey: .outboundRequestRevision)
        try values.encode(outboundCurrentRevisionId, forKey: .outboundCurrentRevisionId)
        try values.encode(outboundPendingEvents, forKey: .outboundPendingEvents)
        try values.encode(outboundPendingRevisionState, forKey: .outboundPendingRevisionState)
    }
}

extension OAuthLedger.IntegrationAuditEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case eventType
        case clientRecordId
        case installationId
        case serverId
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        self.eventType = try values.decode(String.self, forKey: .eventType)
        self.clientRecordId = try values.decode(String.self, forKey: .clientRecordId)
        self.installationId = try values.decode(String.self, forKey: .installationId)
        self.serverId = try values.decode(String.self, forKey: .serverId)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(eventType, forKey: .eventType)
        try values.encode(clientRecordId, forKey: .clientRecordId)
        try values.encode(installationId, forKey: .installationId)
        try values.encode(serverId, forKey: .serverId)
    }
}

extension OAuthLedger.InstallationToken: Codable {
    private enum CodingKeys: String, CodingKey {
        case tokenHash
        case installationId
        case clientId
        case serverId
        case grantRevision
        case groups
        case audience
        case expiresAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.tokenHash = try values.decode(String.self, forKey: .tokenHash)
        self.installationId = try values.decode(String.self, forKey: .installationId)
        self.clientId = try values.decode(String.self, forKey: .clientId)
        self.serverId = try values.decode(String.self, forKey: .serverId)
        self.grantRevision = try values.decode(Int.self, forKey: .grantRevision)
        self.groups = try values.decode([String].self, forKey: .groups)
        self.audience = try values.decode(String.self, forKey: .audience)
        self.expiresAt = try values.decode(Date.self, forKey: .expiresAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tokenHash, forKey: .tokenHash)
        try values.encode(installationId, forKey: .installationId)
        try values.encode(clientId, forKey: .clientId)
        try values.encode(serverId, forKey: .serverId)
        try values.encode(grantRevision, forKey: .grantRevision)
        try values.encode(groups, forKey: .groups)
        try values.encode(audience, forKey: .audience)
        try values.encode(expiresAt, forKey: .expiresAt)
    }
}

extension OAuthLedger.Installation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case serverId
        case clientId
        case installedByUserId
        case approvedGroups
        case grantRevision
        case status
        case agentJwtEnabled
        case setupCompletedRevision
        case setupCompletedAt
        case createdAt
        case approvedRequestRevisionId
        case subscribedEvents
        case subscriptionRevision
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.serverId = try values.decode(String.self, forKey: .serverId)
        self.clientId = try values.decode(String.self, forKey: .clientId)
        self.installedByUserId = try values.decode(String.self, forKey: .installedByUserId)
        self.approvedGroups = try values.decode([String].self, forKey: .approvedGroups)
        self.grantRevision = try values.decode(Int.self, forKey: .grantRevision)
        self.status = try values.decode(String.self, forKey: .status)
        self.agentJwtEnabled = try values.decode(Bool?.self, forKey: .agentJwtEnabled)
        self.setupCompletedRevision = try values.decode(Int?.self, forKey: .setupCompletedRevision)
        self.setupCompletedAt = try values.decode(Date?.self, forKey: .setupCompletedAt)
        self.createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.approvedRequestRevisionId = try values.decodeIfPresent(String.self, forKey: .approvedRequestRevisionId)
        self.subscribedEvents = try values.decodeIfPresent([String].self, forKey: .subscribedEvents) ?? []
        self.subscriptionRevision = try values.decodeIfPresent(Int.self, forKey: .subscriptionRevision) ?? 0
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(serverId, forKey: .serverId)
        try values.encode(clientId, forKey: .clientId)
        try values.encode(installedByUserId, forKey: .installedByUserId)
        try values.encode(approvedGroups, forKey: .approvedGroups)
        try values.encode(grantRevision, forKey: .grantRevision)
        try values.encode(status, forKey: .status)
        try values.encode(agentJwtEnabled, forKey: .agentJwtEnabled)
        try values.encode(setupCompletedRevision, forKey: .setupCompletedRevision)
        try values.encode(setupCompletedAt, forKey: .setupCompletedAt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(approvedRequestRevisionId, forKey: .approvedRequestRevisionId)
        try values.encode(subscribedEvents, forKey: .subscribedEvents)
        try values.encode(subscriptionRevision, forKey: .subscriptionRevision)
    }
}

extension OAuthLedger.AccessRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case serverId
        case userId
        case clientId
        case scopes
        case humanName
        case humanEmail
        case humanEmailVerified
        case humanAvatarUrl
        case agentId
        case status
        case oidc
        case nonce
        case codeChallenge
        case oidcRedirectURI
        case createdAt
        case consumedAt
        case remember
        case resolvedByUserId
        case resolvedAt
        case updatedAt
        case resource
        case principalType
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.serverId = try values.decode(String.self, forKey: .serverId)
        self.userId = try values.decode(String.self, forKey: .userId)
        self.clientId = try values.decode(String.self, forKey: .clientId)
        self.scopes = try values.decode([String].self, forKey: .scopes)
        self.humanName = try values.decode(String.self, forKey: .humanName)
        self.humanEmail = try values.decode(String.self, forKey: .humanEmail)
        self.humanEmailVerified = try values.decode(Bool.self, forKey: .humanEmailVerified)
        self.humanAvatarUrl = try values.decode(String?.self, forKey: .humanAvatarUrl)
        self.agentId = try values.decode(String?.self, forKey: .agentId)
        self.status = try values.decode(String.self, forKey: .status)
        self.oidc = try values.decode(Bool.self, forKey: .oidc)
        self.nonce = try values.decode(String?.self, forKey: .nonce)
        self.codeChallenge = try values.decode(String?.self, forKey: .codeChallenge)
        self.oidcRedirectURI = try values.decode(String?.self, forKey: .oidcRedirectURI)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.consumedAt = try values.decode(Date?.self, forKey: .consumedAt)
        self.remember = try values.decodeIfPresent(Bool.self, forKey: .remember) ?? false
        self.resolvedByUserId = try values.decodeIfPresent(String.self, forKey: .resolvedByUserId)
        self.resolvedAt = try values.decodeIfPresent(Date.self, forKey: .resolvedAt)
        self.updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.resource = try values.decodeIfPresent(String.self, forKey: .resource)
        self.principalType = try values.decodeIfPresent(String.self, forKey: .principalType) ?? "agent"
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(serverId, forKey: .serverId)
        try values.encode(userId, forKey: .userId)
        try values.encode(clientId, forKey: .clientId)
        try values.encode(scopes, forKey: .scopes)
        try values.encode(humanName, forKey: .humanName)
        try values.encode(humanEmail, forKey: .humanEmail)
        try values.encode(humanEmailVerified, forKey: .humanEmailVerified)
        try values.encode(humanAvatarUrl, forKey: .humanAvatarUrl)
        try values.encode(agentId, forKey: .agentId)
        try values.encode(status, forKey: .status)
        try values.encode(oidc, forKey: .oidc)
        try values.encode(nonce, forKey: .nonce)
        try values.encode(codeChallenge, forKey: .codeChallenge)
        try values.encode(oidcRedirectURI, forKey: .oidcRedirectURI)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(consumedAt, forKey: .consumedAt)
        try values.encode(remember, forKey: .remember)
        try values.encode(resolvedByUserId, forKey: .resolvedByUserId)
        try values.encode(resolvedAt, forKey: .resolvedAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(resource, forKey: .resource)
        try values.encode(principalType, forKey: .principalType)
    }
}

extension OAuthLedger.AccessToken: Codable {
    private enum CodingKeys: String, CodingKey {
        case serverId
        case userId
        case clientId
        case requestId
        case tokenHash
        case scopes
        case expiresAt
        case principalType
        case agentId
        case resource
        case revokedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.serverId = try values.decode(String.self, forKey: .serverId)
        self.userId = try values.decode(String.self, forKey: .userId)
        self.clientId = try values.decode(String.self, forKey: .clientId)
        self.requestId = try values.decode(String.self, forKey: .requestId)
        self.tokenHash = try values.decode(String.self, forKey: .tokenHash)
        self.scopes = try values.decode([String].self, forKey: .scopes)
        self.expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        self.principalType = try values.decode(String.self, forKey: .principalType)
        self.agentId = try values.decode(String?.self, forKey: .agentId)
        self.resource = try values.decode(String?.self, forKey: .resource)
        self.revokedAt = try values.decode(Date?.self, forKey: .revokedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(serverId, forKey: .serverId)
        try values.encode(userId, forKey: .userId)
        try values.encode(clientId, forKey: .clientId)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(tokenHash, forKey: .tokenHash)
        try values.encode(scopes, forKey: .scopes)
        try values.encode(expiresAt, forKey: .expiresAt)
        try values.encode(principalType, forKey: .principalType)
        try values.encode(agentId, forKey: .agentId)
        try values.encode(resource, forKey: .resource)
        try values.encode(revokedAt, forKey: .revokedAt)
    }
}


extension OAuthLedger.ClientShareLink: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, clientId, clientRecordId, tokenHash, createdByUserId, createdByAgentId
        case expiresAt, createdAt, updatedAt, revokedAt, lastUsedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let clientId = try values.decodeIfPresent(String.self, forKey: .clientId)
        let clientRecordId = try values.decodeIfPresent(String.self, forKey: .clientRecordId)
        guard let resolved = clientId ?? clientRecordId else {
            throw DecodingError.keyNotFound(CodingKeys.clientId,
                DecodingError.Context(codingPath: decoder.codingPath,
                    debugDescription: "a share link needs clientId or clientRecordId"))
        }
        self.id = try values.decode(String.self, forKey: .id)
        self.clientId = resolved
        self.clientRecordId = resolved
        self.tokenHash = try values.decode(String.self, forKey: .tokenHash)
        self.createdByUserId = try values.decodeIfPresent(String.self, forKey: .createdByUserId)
        self.createdByAgentId = try values.decodeIfPresent(String.self, forKey: .createdByAgentId)
        self.expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        self.revokedAt = try values.decodeIfPresent(Date.self, forKey: .revokedAt)
        self.lastUsedAt = try values.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(clientId, forKey: .clientId)
        try values.encode(clientRecordId, forKey: .clientRecordId)
        try values.encode(tokenHash, forKey: .tokenHash)
        try values.encode(createdByUserId, forKey: .createdByUserId)
        try values.encode(createdByAgentId, forKey: .createdByAgentId)
        try values.encode(expiresAt, forKey: .expiresAt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(revokedAt, forKey: .revokedAt)
        try values.encode(lastUsedAt, forKey: .lastUsedAt)
    }
}

extension OAuthLedger.AppWebhookConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case clientRecordId, endpointUrl, secret, previousSecret, previousValidUntil, revision, enabled, updatedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.clientRecordId = try values.decode(String.self, forKey: .clientRecordId)
        self.endpointUrl = try values.decode(String.self, forKey: .endpointUrl)
        self.secret = try values.decode(String.self, forKey: .secret)
        self.previousSecret = try values.decodeIfPresent(String.self, forKey: .previousSecret)
        self.previousValidUntil = try values.decodeIfPresent(Date.self, forKey: .previousValidUntil)
        self.revision = try values.decode(Int.self, forKey: .revision)
        self.enabled = try values.decode(Bool.self, forKey: .enabled)
        self.updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(clientRecordId, forKey: .clientRecordId)
        try values.encode(endpointUrl, forKey: .endpointUrl)
        try values.encode(secret, forKey: .secret)
        try values.encode(previousSecret, forKey: .previousSecret)
        try values.encode(previousValidUntil, forKey: .previousValidUntil)
        try values.encode(revision, forKey: .revision)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

extension OAuthLedger.AppPermissionRevision: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, clientRecordId, revision, requestedGroups, requestedEvents, state, createdAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.clientRecordId = try values.decode(String.self, forKey: .clientRecordId)
        self.revision = try values.decode(Int.self, forKey: .revision)
        self.requestedGroups = try values.decode([String].self, forKey: .requestedGroups)
        self.requestedEvents = try values.decode([String].self, forKey: .requestedEvents)
        self.state = try values.decode(String.self, forKey: .state)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(clientRecordId, forKey: .clientRecordId)
        try values.encode(revision, forKey: .revision)
        try values.encode(requestedGroups, forKey: .requestedGroups)
        try values.encode(requestedEvents, forKey: .requestedEvents)
        try values.encode(state, forKey: .state)
        try values.encode(createdAt, forKey: .createdAt)
    }
}
