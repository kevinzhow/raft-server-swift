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
        /// The stored App logo URL. The port keeps the URL projection only; the
        /// image bytes are not retained (the avatar routes share this rule).
        var logoUrl: String? = nil
    }

    /// One private integration-app share link. The token itself is never
    /// retained, only its hash, so an issued URL cannot be re-read from the
    /// ledger.
    struct ClientShareLink: Codable, Sendable {
        var id: String
        var clientId: String
        var tokenHash: String
        var createdByUserId: String?
        var createdByAgentId: String?
        var expiresAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var revokedAt: Date?
        var lastUsedAt: Date?
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
