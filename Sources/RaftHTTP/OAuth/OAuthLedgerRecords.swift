import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    struct Server: Sendable {
        var id: String
        var slug: String
        var name: String
        var ownerId: String = ""
        var avatarUrl: String? = nil
        var plan: String = "free"
        var deleted = false
        var productAnalyticsEnabled = true
        var translationEnabled = false
        var publiclyVisible = false
        var publicGuestJoinEnabled = false
    }

    struct Agent: Sendable {
        var id: String
        var serverId: String
        var name: String
        var displayName: String
        var avatarUrl: String?
        var description: String?
        var creatorUserId: String? = nil
        var runtime: String = "managed"
        var runtimeConfigJSON: String? = nil
        var envVarsJSON: String? = nil
        var status: String = "inactive"
        var deleted = false
    }

    struct AgentGrant: Sendable {
        var id: String
        var serverId: String
        var agentId: String
        var clientRecordId: String
        var scopes: [String]
        var grantSource: String
        var grantedByUserId: String?
        var createdAt: Date
        var revokedAt: Date? = nil
    }

    struct AgentEvent: Sendable {
        var id: String
        var serverId: String
        var agentId: String
        var clientId: String
        var kind: String
        var summary: String
        var payloadHash: String
        var payloadJSON: String = "{}"
        var externalEventId: String?
        var status: String
        var expiresAt: Date
        var createdAt: Date
        var deliveredAt: Date? = nil
    }

    struct Client: Sendable {
        var id: String
        var serverId: String
        var clientId: String
        var secretHash: String
        var appType: String
        var name: String
        var createdByUserId: String
        var descriptionText: String? = nil
        var homepageUrl: String? = nil
        var returnUrl: String? = nil
        var allowedScopes: [String]? = nil
        var outboundGroups: [String] = []
        var pendingOutboundRevisionId: String? = nil
        var pendingOutboundGroups: [String] = []
        /// Legacy App-level switch. Built-in issuance ignores it; the column
        /// survives only for old web bundles.
        var agentJwtEnabled: Bool? = false
        var enabled: Bool = true
        var externalProvider: String? = nil
        var externalState: String? = nil
        var publishStatus: String = "draft"
        var humanMarketplaceVisible: Bool = false
        var agentManifestUrl: String? = nil
        var agentManifestUrlSource: String? = nil
        var whenToUse: String? = nil
        var setupUrl: String? = nil
        var setupDescription: String? = nil
        var setupRevision: Int = 1
        var category: String = "Other"
        var dataAccessSummary: String? = nil
        var publishRejectionReason: String? = nil
        var publishRequestedAt: Date? = nil
        var publishReviewedAt: Date? = nil
        /// The stored App logo URL projection and the object-store key of the
        /// retained original bytes.
        var logoUrl: String? = nil
        var logoStorageKey: String? = nil
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var outboundEvents: [String] = []
        var outboundRequestRevision: Int = 0
        var outboundCurrentRevisionId: String? = nil
        var outboundPendingEvents: [String] = []
        var outboundPendingRevisionState: String? = nil
    }

    /// One private integration-app share link. The token itself is never
    /// retained, only its hash, so an issued URL cannot be re-read from the
    /// ledger.
    ///
    /// Two producer generations use the same durable list: the agent-managed
    /// apps record the client key in `clientId`, the developer-platform apps
    /// record the client record id in `clientRecordId`. Both fields carry the
    /// same value; the coders accept either key so every retained snapshot
    /// restores.
    struct ClientShareLink: Sendable {
        var id: String
        var clientId: String
        var clientRecordId: String
        var tokenHash: String
        var createdByUserId: String?
        var createdByAgentId: String?
        var expiresAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var revokedAt: Date?
        var lastUsedAt: Date?

        init(id: String, clientId: String, tokenHash: String, createdByUserId: String?,
             createdByAgentId: String?, expiresAt: Date?, createdAt: Date, updatedAt: Date,
             revokedAt: Date?, lastUsedAt: Date?) {
            self.id = id
            self.clientId = clientId
            self.clientRecordId = clientId
            self.tokenHash = tokenHash
            self.createdByUserId = createdByUserId
            self.createdByAgentId = createdByAgentId
            self.expiresAt = expiresAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.revokedAt = revokedAt
            self.lastUsedAt = lastUsedAt
        }

        init(id: String, clientRecordId: String, tokenHash: String, expiresAt: Date?,
             createdAt: Date, updatedAt: Date, revokedAt: Date?, lastUsedAt: Date?) {
            self.init(id: id, clientId: clientRecordId, tokenHash: tokenHash,
                      createdByUserId: nil, createdByAgentId: nil, expiresAt: expiresAt,
                      createdAt: createdAt, updatedAt: updatedAt, revokedAt: revokedAt,
                      lastUsedAt: lastUsedAt)
        }
    }

    struct IntegrationAuditEvent: Sendable {
        var id: String = UUID().uuidString.lowercased()
        var eventType: String
        var clientRecordId: String
        var installationId: String
        var serverId: String
    }
    struct InstallationToken: Sendable {
        var tokenHash: String
        var installationId: String
        var clientId: String
        var serverId: String
        var grantRevision: Int
        var groups: [String]
        var audience: String
        var expiresAt: Date
    }

    struct Installation: Sendable {
        var id: String
        var serverId: String
        var clientId: String
        var installedByUserId: String
        var approvedGroups: [String]
        var grantRevision: Int
        var status: String
        /// Legacy installation-level switch, ignored by issuance.
        var agentJwtEnabled: Bool? = false
        var setupCompletedRevision: Int? = nil
        var setupCompletedAt: Date? = nil
        var createdAt: Date = Date()
        var approvedRequestRevisionId: String? = nil
        var subscribedEvents: [String] = []
        var subscriptionRevision: Int = 0
    }

    struct AppWebhookConfig: Sendable {
        var clientRecordId: String
        var endpointUrl: String
        var secret: String
        var previousSecret: String?
        var previousValidUntil: Date?
        var revision: Int
        var enabled: Bool
        var updatedAt: Date
    }

    struct AppPermissionRevision: Sendable {
        var id: String
        var clientRecordId: String
        var revision: Int
        var requestedGroups: [String]
        var requestedEvents: [String]
        var state: String
        var createdAt: Date
    }

    struct AccessRequest: Sendable {
        var id: String
        var serverId: String
        var userId: String
        var clientId: String
        var scopes: [String]
        var humanName: String
        var humanEmail: String
        var humanEmailVerified: Bool
        var humanAvatarUrl: String?
        var agentId: String? = nil
        var status: String = "approved"
        var oidc: Bool = false
        var nonce: String? = nil
        var codeChallenge: String? = nil
        var oidcRedirectURI: String? = nil
        var createdAt: Date
        var consumedAt: Date? = nil
        var remember: Bool = false
        var resolvedByUserId: String? = nil
        var resolvedAt: Date? = nil
        var updatedAt: Date? = nil
        var resource: String? = nil
        var principalType: String = "agent"
    }

    struct AccessToken: Sendable {
        var serverId: String
        var userId: String
        var clientId: String
        var requestId: String
        var tokenHash: String
        var scopes: [String]
        var expiresAt: Date
        var principalType: String = "human"
        var agentId: String? = nil
        var resource: String? = nil
        var revokedAt: Date? = nil
    }
}
