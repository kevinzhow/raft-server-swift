import Foundation
import Synchronization

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
/// All mutable records are protected by `lock`; operations in the domain
/// extensions hold it over each transaction, including calls to `...Locked`
/// helpers. The signing secret has its own Mutex because signing intentionally
/// happens after the transaction lock is released. The remaining unchecked
/// conformance covers the shared NSLock-protected record tables.
public final class OAuthLedger: @unchecked Sendable {
    private let signingSecret = Mutex("test-jwt-secret")

    public var jwtSecret: String {
        get { signingSecret.withLock { $0 } }
        set { signingSecret.withLock { $0 = newValue } }
    }
    let lock = NSLock()
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
    var integrationAuditEvents: [IntegrationAuditEvent] = []
    var requests: [AccessRequest] = []
    var tokens: [AccessToken] = []
    var installations: [Installation] = []
    var installationTokens: [InstallationToken] = []
    var officialAppClientIds: Set<String> = []

    public init() {}
}
