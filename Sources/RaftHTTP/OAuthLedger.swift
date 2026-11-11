import Foundation
import Synchronization
import RaftShared

public struct ThirdPartyEventMessage: Sendable {
    public var id: String
    public var serverId: String
    public var clientKey: String
    public var clientName: String
    public var clientRecordId: String
    public var kind: String
    public var summary: String
}

public struct OAuthHuman: Sendable {
    public var id: String
    public var email: String
    public var name: String
    public var emailVerified: Bool
    public var avatarUrl: String?

    public init(id: String, email: String, name: String, emailVerified: Bool = false, avatarUrl: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.emailVerified = emailVerified
        self.avatarUrl = avatarUrl
    }
}

public enum OAuthSession: Sendable {
    case missing
    case invalid
    case user(OAuthHuman)
}

public struct CreatedOAuthClient: Sendable {
    public var id: String
    public var clientId: String
    public var clientSecret: String
}

public struct OAuthClientRejection: Error, Sendable {
    public var message: String
}

/// In-memory OAuth clients, human authorization codes, and access tokens.
/// `POST /api/oauth/authorize/human` and `POST /api/oauth/token` both use this ledger.
///
/// Each record-table transaction borrows one State from its Mutex. Helpers
/// ending in `Locked` receive that State explicitly and never acquire the Mutex.
/// The signing secret stays independent so JWT signing runs after redemption
/// releases the record-table transaction.
public final class OAuthLedger: Sendable {
    private let signingSecret = TransactionalState("test-jwt-secret")

    public var jwtSecret: String {
        get { signingSecret.withLock { $0 } }
        set { signingSecret.withLock { $0 = newValue } }
    }
    let state = TransactionalState(State())

    /// Transient profile-asset port shared by the user/server/agent avatar
    /// routes and the integration-logo routes. It is never part of persisted
    /// OAuth state; production installs the encrypted S3 actor here.
    public let assets = AvatarStorageRegistry()

    struct State: Sendable {
        var servers: [String: Server] = [:]
        var agents: [String: Agent] = [:]
        var agentRoles: [String: String] = [:]
        /// Agent owners of a server-local App (`oauth_client_maintainers`).
        var clientMaintainerOwners: [String: Set<String>] = [:]
        var agentEvents: [AgentEvent] = []
        var revokedGrantClients: Set<String> = []
        var agentGrants: [AgentGrant] = []
        var autoGrantBlocked: Set<String> = []
        var members: [String: String] = [:]
        var channelRecords: [ChannelRecord] = []
        var channelHumans: Set<String> = []
        var channelAgents: Set<String> = []
        var channelMessages: [ChannelMessageRecord] = []
        var channelSystemMessages: [ChannelSystemMessageRecord] = []
        var channelNotificationPrefs: [String: ChannelNotificationPrefs] = [:]
        var channelReadCursors: [String: Int] = [:]
        var channelDisplayPrefs: [String: ChannelDisplayPrefs] = [:]
        var savedMessageRecords: [SavedMessageRecord] = []
        var savedMessageCounter = 0
        var sidebarOrders: [String: SidebarOrder] = [:]
        var serverAgreementRecords: [String: [ServerAgreementInfo]] = [:]
        var serverPushMutes: Set<String> = []

        var clients: [Client] = []
        var clientShareLinks: [ClientShareLink] = []
        var appWebhookConfigs: [String: AppWebhookConfig] = [:]
        var appPermissionRevisions: [AppPermissionRevision] = []
        var integrationAuditEvents: [IntegrationAuditEvent] = []
        var requests: [AccessRequest] = []
        var tokens: [AccessToken] = []
        var installations: [Installation] = []
        var installationTokens: [InstallationToken] = []
        var officialAppClientIds: Set<String> = []
    }

    public init() {}
}
