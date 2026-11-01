import Crypto
import Foundation

public struct RefreshRotationReceipt: Equatable, Sendable {
    public var attemptId: String
    public var installationId: String
    public var successorTokenCiphertext: String

    public init(attemptId: String, installationId: String, successorTokenCiphertext: String) {
        self.attemptId = attemptId
        self.installationId = installationId
        self.successorTokenCiphertext = successorTokenCiphertext
    }
}

public struct NativeAppleCodeExchange: Equatable, Sendable {
    public var code: String
    public var clientId: String
    public var clientSecret: String
    public var grantType: String
    public var redirectUri: String?

    public init(code: String, clientId: String, clientSecret: String, grantType: String, redirectUri: String?) {
        self.code = code
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.grantType = grantType
        self.redirectUri = redirectUri
    }
}

public struct MobileProviderProfile: Equatable, Sendable {
    public var providerUserId: String
    public var email: String
    public var displayName: String?
    /// Apple rejects a link when this is false. Google and GitHub profiles are already verified.
    public var emailVerified: Bool

    public init(providerUserId: String, email: String, displayName: String?, emailVerified: Bool = true) {
        self.providerUserId = providerUserId
        self.email = email
        self.displayName = displayName
        self.emailVerified = emailVerified
    }
}

public struct SocialAuthState: Equatable, Sendable {
    public var provider: String
    public var mode: String
    public var nonce: String
    public var kind: String
    public var mobileRequestId: String
    public var desktopNonce: String?
    public var returnTo: String?
    public var linkUserId: String?

    public init(provider: String, mode: String, nonce: String, kind: String, mobileRequestId: String, desktopNonce: String?, returnTo: String? = nil, linkUserId: String? = nil) {
        self.provider = provider
        self.mode = mode
        self.nonce = nonce
        self.kind = kind
        self.mobileRequestId = mobileRequestId
        self.desktopNonce = desktopNonce
        self.returnTo = returnTo
        self.linkUserId = linkUserId
    }
}

public struct EmailLegalAcceptance: Equatable, Sendable {
    public var termsVersion: String
    public var privacyVersion: String
    public var termsUrl: String
    public var privacyUrl: String
    public var source: String
    public var userAgentHash: String?
    public var locale: String?

    public init(
        termsVersion: String,
        privacyVersion: String,
        termsUrl: String,
        privacyUrl: String,
        source: String,
        userAgentHash: String?,
        locale: String?
    ) {
        self.termsVersion = termsVersion
        self.privacyVersion = privacyVersion
        self.termsUrl = termsUrl
        self.privacyUrl = privacyUrl
        self.source = source
        self.userAgentHash = userAgentHash
        self.locale = locale
    }
}

public struct RecordedProductEvent: Sendable {
    public var subjectType: String
    public var subjectId: String
    public var eventType: String
    public var actorType: String
    public var actorId: String
    public var source: String
    public var idempotencyKey: String?
    public var metadataJSON: String
}

public struct ClientEventRecord: Sendable {
    public var event: String
    public var analyticsId: String
    public var serverId: String
    public var source: String
    public var sessionId: String
    public var appVersion: String?
    public var propertiesJSON: String
}

/// `POST /api/auth/login`.
///
/// A non-string or empty email or password is refused before any account lookup.
/// A missing account and a wrong password share one 401, and neither issues a session.

public final class EmailLoginDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [String: Account] = [:]
    private var analyticsIds: [String: String] = [:]
    private var productEventRecords: [RecordedProductEvent] = []
    private var clientEventRecords: [ClientEventRecord] = []
    private var seenClientEventIDs: Set<String> = []
    private var sessions: [String: LiveSession] = [:]
    private var rotationReceipts: [String: RotationReceipt] = [:]
    private var revokedFamilies: Set<String> = []
    private var sessionFamilies: [String: SessionFamily] = [:]
    private var retirementReceipts: [String: RetirementReceipt] = [:]
    private var accessTokens: [String: String] = [:]
    private var accessTokenFamilies: [String: String] = [:]
    private var legalAcceptances: [String: EmailLegalAcceptance] = [:]
    private var emailVerifications = 0
    private var humanMessageRows: [StoredHumanMessage] = []
    private var channelAttachments: [String: ChannelAttachment] = [:]
    private var recordedChannelMessageEvents: [ChannelMessageEvent] = []
    private var recordedReactionViewerEvents: [ReactionViewerEvent] = []
    private var forwardedBundles: [String: [ForwardedSource]] = [:]
    private var forwardRecords: [String: StoredForwardRecord] = [:]
    private var messageReactions: [StoredReaction] = []
    private var reactionViewerVersions: [String: Int] = [:]
    private var reactionDiscussionVersions: [String: Int] = [:]
    private var serverAgents: [String: ServerAgent] = [:]
    private var storedMentions: [StoredMention] = []
    private var channelAgentMembers: [String: Set<String>] = [:]
    private var machineKeys: [String: (serverId: String, agentId: String)] = [:]
    private var storedInboxFacts: [StoredInboxFact] = []
    private var storedAgentDeliveries: [(agentId: String, messageId: String, channelType: String)] = []
    private var agentCredentials: [String: AgentCredential] = [:]
    private var agentMachineIds: [String: String] = [:]
    private var agentMigrationServers: Set<String> = []
    private var hostedMigrationServers: Set<String> = []
    private var hostedRuntimeServers: Set<String> = []
    private var hostedMigrations: [String: HostedMigrationRecord] = [:]

    private struct HostedMigrationRecord {
        var agentId: String
        var serverId: String
        var supportRef: String
        var revision: Int
        var state: String
        var sourceMachineId: String?
    }
    private var hostedRuntimes: [String: (provider: String, model: String?, state: String, retryNeedsModel: Bool, createdAt: Date)] = [:]
    private var hostedUsage: [String: String] = [:]
    private var hostedModelPickerServers: Set<String> = []
    private var hostedModels: [String: HostedModelState] = [:]
    private var agentConnectionOrigin = "http://localhost:3000"
    private let agentConnectionLock = NSLock()
    private var agentConnectionProviderStorage: (@Sendable (AgentConnectionProviderRequest) -> AgentConnectionProviderResult)?

    /// Provider relay for `github` account connections. Production wires this to
    /// the hosted runtime provider; tests replace it with a deterministic stub.
    public var agentConnectionProvider: (@Sendable (AgentConnectionProviderRequest) -> AgentConnectionProviderResult)? {
        get {
            agentConnectionLock.lock()
            defer { agentConnectionLock.unlock() }
            return agentConnectionProviderStorage
        }
        set {
            agentConnectionLock.lock()
            agentConnectionProviderStorage = newValue
            agentConnectionLock.unlock()
        }
    }

    private struct HostedModelState {
        var models: [(id: String, label: String, provider: String)]
        var defaultModel: String?
        var defaultLabel: String?
        var model: String?
        var label: String?
        var source: String
        var locked: Bool
    }

    /// Raft's own default for hosted agents; naming it always follows the provider default.
    private static let hostedDefaultModel = "deepseek-flash"
    private var agentArchiveRecords: [String: (workspaceState: String, machineName: String, serverId: String)] = [:]
    private var postableChannels: [String: PostableChannel] = [:]
    private var threadOrder: [String] = []
    private var serverMemberRoles: [String: String] = [:]
    private var hideHumansFromMembers: [String: Bool] = [:]
    private var jointProjections: [JointChannelLink] = []
    private var composerResourceServers: Set<String> = []
    private var installedServerApps: [String: Set<String>] = [:]
    private var socialCompletions: [SocialCompletion] = []
    private var mobileRequests: [String: MobileOAuthRequest] = [:]
    private var providerExchanges = 0
    private var consumedHandoffs: Set<String> = []
    private var deviceGrants: [String: DeviceGrant] = [:]
    private var deviceUserCodes: [String: String] = [:]
    private var mobileAppEmailContactsByKey: [String: MobileAppEmailContact] = [:]
    private var storedMobileAppEmailJourneys: [MobileAppEmailJourney] = []
    private var nativeNotificationEvents: [StoredNativeNotificationEvent] = []
    private var nextNativeNotificationSeq = 0
    private var nativeEnrollmentGrants: [StoredEnrollmentGrant] = []
    private var nativeNotificationDevices: [StoredNotificationDevice] = []
    private var nativeNotificationCredentials: [StoredNotificationCredential] = []
    public var mobileProviderProfile: MobileProviderProfile?
    /// Exchanged web provider profile. The form-post callback stores a completion and does not link an identity.
    public var webProviderProfile: MobileProviderProfile?
    /// Providers with a client id and secret. Google and GitHub ignore the Apple platform gate.
    public var configuredSocialAuthProviders: Set<String> = []
    /// `APPLE_CLIENT_ID`, or `APPLE_WEB_CLIENT_ID` when the first is empty.
    public var appleClientId: String = ""
    /// `APPLE_IOS_CLIENT_ID`. Native sign-in stays closed until this and the client secret are set.
    public var nativeAppleClientId: String = ""
    public var nativeAppleClientSecret: String = ""
    /// HMAC secret for the native request token. `NATIVE_APPLE_AUTH_STATE_SECRET`.
    public var nativeAppleStateSecret: String = ""
    /// Stand-in for `https://appleid.apple.com/auth/token`. The shipped call builds the form body.
    public var exchangeNativeAppleCode: (@Sendable (NativeAppleCodeExchange) async -> String?)?
    /// `SERVER_URL`, without a trailing slash. Used as the Apple redirect base.
    public var serverURL: String = "http://localhost:3001"
    /// Human authorization codes and the token endpoint. The same ledger the HTTP routes exchange.
    public let oauth = OAuthLedger()
    /// `APP_URL`. Web OAuth errors redirect here.
    public var appURL: String = "http://localhost:3000"
    public var handsFeedbackConfigured = false
    public var providerConnectionsEnabledServers: Set<String> = []
    private var providerConnections: [ProviderConnection] = []
    private var providerAssignments: [ProviderAssignment] = []
    private var shareArtifacts: Set<String> = []
    private var timezoneObservations: [String: TimezoneObservation] = [:]
    private var serverLabsState: [String: ServerLabsState] = [:]
    private var serverInvites: [(id: String, serverId: String, email: String, role: String)] = []
    private var serverSwitcherOrders: [String: (ids: [String], version: Int)] = [:]
    private var serverOnboardingSettings: [String: (agentId: String?, greeting: Bool)] = [:]
    private var userOnboardingSettings: [String: UserOnboarding] = [:]
    private var serverNotificationPrefs: [String: (muted: Bool, mentionsOnly: Bool, mode: String, version: Int)] = [:]
    private var setupPhases: [String: String] = [:]
    private var setupHandoffs: Set<String> = []
    private var guestRoleServers: Set<String> = []
    private var computers: [(id: String, serverId: String, name: String, apiKey: String, machineId: String?, revokedAt: Date?, online: Bool, version: String?)] = []
    private var computerAttachers: [String: String] = [:]
    private var runtimeAccountUsage: [String: (json: String, staleAfter: Date)] = [:]
    private var runtimeAccountUsageRefreshAt: [String: Date] = [:]
    private var machineRuntimeModels: [String: [String: (models: [(id: String, label: String)], updatedAt: Date)]] = [:]
    private var proSeats: [String: Int] = [:]
    private var joinLinks: [String: JoinLinkRecord] = [:]
    private var usageLimitAttentionServers: Set<String> = []
    private var systemAttentionIncidents: [SystemAttentionIncident] = []
    private var systemAttentionReceipts: [String: SystemAttentionReceipt] = [:]
    private var hostedAgents: Set<String> = []
    private var threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)] = [:]
    private struct ThreadUnfollowRecord {
        var serverId: String
        var userId: String
        var threadChannelId: String
        var parentMessageId: String
        var unfollowedAt: Date
        var latestMessageId: String
        var replyCount: Int
        var frozenMessages: [(id: String, content: String)]
    }
    private var threadUnfollows: [String: ThreadUnfollowRecord] = [:]
    private var threadFollowStarts: [String: Date] = [:]
    private var threadFollowerRemovals: [String: (serverId: String, threadChannelId: String, agentId: String)] = [:]
    private var channelReadVersions: [String: Int] = [:]
    private var agentChannelReadCursors: [String: (seq: Int, version: Int)] = [:]
    private var agentActivities: [String: (activity: String, detail: String)] = [:]
    private var announcements: [(id: String, title: String, pages: [String], startsAt: Date, expiresAt: Date?, status: String, publishedAt: Date?, imageId: String?)] = []
    private var announcementImageAssets: [String: AnnouncementImageAsset] = [:]
    private var announcementImageStorageAvailable = true

    private struct AnnouncementImageAsset {
        var id: String
        var announcementId: String
        var contentType: String
        var bytes: Data
    }
    private var announcementDismissals: Set<String> = []
    private var inboxDoneScopes: Set<String> = []
    private var guestVisibleChannels: [String: Bool] = [:]
    private var readReceiptsServers: Set<String> = []
    private var channelHumanRoles: [String: String] = [:]
    private var channelAuthorityRevisions: [String: Int] = [:]
    private var sidebarModes: [String: (channel: String, joint: String, dm: String, pinned: String, channelTabs: [String], agentTabs: [String])] = [:]
    private var sidebarSections: [String: (sections: [(id: String, name: String, emoji: String?, sortMode: String)], order: [String], placements: [(kind: String, id: String, sectionId: String, position: Int)], version: Int)] = [:]
    private var sidebarPinnedRefs: [String: (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int)] = [:]
    private var reminderRecords: [ReminderRecord] = []
    private var taskRecords: [TaskRecord] = []
    private var pushRegistrations: [PushRegistration] = []
    public var fcmPushAvailable = true
    public var webPushEnabled = true
    private var webPushSubscriptions: [WebPushSubscription] = []
    private var machines: [MachineRecord] = []
    private var machineStatusVersions: [String: Int] = [:]
    private var machineOnline: [String: Bool] = [:]
    private var agentCredentialUseThrottleOverrideMs: Int?
    private var wakeStreamHeartbeatOverrideMs: Int?
    private var agentLastSeenAt: [String: Date] = [:]
    private var feedbackLocatorRecords: [FeedbackLocatorRecord] = []
    private var managedMCPServers: [ManagedMCPServerRecord] = []
    private var actionCardRecords: [String: ActionCardRecord] = [:]
    private var pendingActionMessageEvents: [(agentId: String, messageId: String, content: String)] = []
    private var agentChannelInboxDelivered: Set<String> = []
    private var agentGrantSets: [String: Set<String>] = [:]
    private var appConfigOverrides: [String: [String: [String: Any]]] = [:]
    private var appConfigRevisions: [String: [String: Int]] = [:]
    private var agentIntegrationGrants: [String: Bool] = [:]
    private var agentAudienceStatusOverrides: [String: String] = [:]
    private var agentAttachmentBytes: [String: Data] = [:]
    private var agentAttachmentPresign: (@Sendable (String, Int, String, String) throws -> String)?

    public func setAgentAttachmentPresignForTesting(_ handler: (@Sendable (String, Int, String, String) throws -> String)?) {
        lock.lock()
        agentAttachmentPresign = handler
        lock.unlock()
    }

    public func addAgentAttachmentForTesting(
        channelId: String,
        id: String,
        uploaderId: String,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        storageKey: String? = nil,
        bytes: Data
    ) {
        lock.lock()
        channelAttachments[id] = ChannelAttachment(
            id: id,
            channelId: channelId,
            uploaderId: uploaderId,
            filename: filename,
            messageId: nil,
            messagePosition: nil,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            storageKey: storageKey
        )
        agentAttachmentBytes[id] = bytes
        lock.unlock()
    }

    private static func rfc5987Encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static let agentAttachmentUnavailableMessage = "Attachment is unavailable."
    private static let agentAttachmentUnavailableNextAction = "If this value came from a feedback report, do not use its artifactId here. Use the reportId with the Raft Feedback Admin integration instead: run `raft integration invoke --service \"Raft Feedback Admin\" --action download_feedback_transcript --param id=REPORT_ID --output PATH`."

    private func agentAttachmentUnavailableReply() -> HTTPReply {
        let error = Self.agentAttachmentUnavailableMessage + " " + Self.agentAttachmentUnavailableNextAction
        return Self.json(404, "{\"error\":\(jsonString(error)),\"code\":\"ATTACHMENT_UNAVAILABLE\",\"suggestedNextAction\":\(jsonString(Self.agentAttachmentUnavailableNextAction))}")
    }

    private func agentAttachmentUnavailableURLReply() -> HTTPReply {
        Self.json(409, "{\"error\":\"This Server's file storage cannot mint download URLs.\",\"code\":\"download_url_unavailable\",\"suggestedNextAction\":\"Download the attachment bytes instead: GET /internal/agent-api/attachments/:attachmentId (`raft attachment view --id <attachmentId> --output <path>`).\"}")
    }

    private func agentVisibleAttachment(agentId: String, serverId: String, attachmentId: String) -> ChannelAttachment? {
        lock.lock()
        defer { lock.unlock() }
        guard let attachment = channelAttachments[attachmentId],
              let channel = postableChannels[attachment.channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else { return nil }
        let visible = channel.kind == "channel"
            || channel.memberIds.contains(agentId)
            || oauth.channelAgentIds(channelId: attachment.channelId).contains(agentId)
        return visible ? attachment : nil
    }

    private func agentAttachmentIdentity(authorization: String?) -> (agentId: String, serverId: String)? {
        switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
        case .refused: return nil
        case .success(let agentId, let serverId): return (agentId, serverId)
        }
    }

    public func agentAttachmentDownload(authorization: String?, attachmentId: String) -> HTTPReply {
        guard let identity = agentAttachmentIdentity(authorization: authorization) else {
            switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
            case .refused(let reply): return reply
            case .success: return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
            }
        }
        guard let attachment = agentVisibleAttachment(agentId: identity.agentId, serverId: identity.serverId, attachmentId: attachmentId) else {
            return agentAttachmentUnavailableReply()
        }
        lock.lock()
        let bytes = agentAttachmentBytes[attachmentId] ?? Data()
        lock.unlock()
        var reply = HTTPReply(
            status: 200,
            headers: [
                "Content-Type": attachment.mimeType ?? "application/octet-stream",
                "Content-Length": String(bytes.count),
            ],
            body: String(decoding: bytes, as: UTF8.self)
        )
        reply.headers["Cache-Control"] = "private, no-store"
        return reply
    }

    public func agentAttachmentDownloadURL(authorization: String?, attachmentId: String) -> HTTPReply {
        guard let identity = agentAttachmentIdentity(authorization: authorization) else {
            switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
            case .refused(let reply): return reply
            case .success: return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
            }
        }
        guard let attachment = agentVisibleAttachment(agentId: identity.agentId, serverId: identity.serverId, attachmentId: attachmentId) else {
            return agentAttachmentUnavailableReply()
        }
        lock.lock()
        let presign = agentAttachmentPresign
        lock.unlock()
        guard let presign else {
            return agentAttachmentUnavailableURLReply()
        }
        let ext = (attachment.filename as NSString).pathExtension
        let storageKey = attachment.storageKey ?? (ext.isEmpty ? "\(identity.serverId)/\(attachmentId)" : "\(identity.serverId)/\(attachmentId).\(ext)")
        let filename = attachment.filename
        let mimeType = attachment.mimeType ?? "application/octet-stream"
        let disposition = "attachment; filename=\"\(filename)\"; filename*=UTF-8''\(Self.rfc5987Encode(filename))"
        let url: String
        do {
            url = try presign(storageKey, 300, disposition, mimeType)
        } catch {
            return Self.json(500, "{\"error\":\"Failed to mint a download URL\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.string(from: Date().addingTimeInterval(300))
        var reply = Self.json(200, "{\"url\":\(jsonString(url)),\"expiresAt\":\(jsonString(expiresAt)),\"filename\":\(jsonString(filename)),\"mimeType\":\(jsonString(mimeType))}")
        reply.headers["Cache-Control"] = "private, no-store"
        return reply
    }

    public func setAgentAudienceStatusForTesting(agentId: String, status: String) {
        lock.lock()
        agentAudienceStatusOverrides[agentId] = status
        lock.unlock()
    }
    public func revokeAgentIntegrationGrantForTesting(agentId: String, clientKey: String) {
        lock.lock()
        agentIntegrationGrants["\(agentId)\n\(clientKey)"] = true
        lock.unlock()
    }

    public func restoreAgentIntegrationGrantForTesting(agentId: String, clientKey: String) {
        lock.lock()
        agentIntegrationGrants["\(agentId)\n\(clientKey)"] = false
        lock.unlock()
    }

    public func revokeAgentCredentialForTesting(apiKey: String) {
        lock.lock()
        agentCredentials[apiKey]?.revokedAt = Date()
        lock.unlock()
    }

    public func agentIntegrationToken(authorization: String?, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil,
              credential.scopes.contains("read"),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid integration token request\",\"code\":\"INVALID_REQUEST\"}")
        }
        for field in ["agentId", "serverId", "audience", "issuer", "expires_in", "scopes", "claims"]
        where object[field] != nil {
            return Self.json(400, "{\"error\":\"Request fields are derived from the credential\",\"code\":\"INVALID_REQUEST\"}")
        }
        guard let service = (object["service"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !service.isEmpty
        else {
            return Self.json(400, "{\"error\":\"service is required\",\"code\":\"INVALID_REQUEST\"}")
        }
        lock.lock()
        let status = agentAudienceStatusOverrides[agent.id] ?? "active"
        lock.unlock()
        guard status == "active" else {
            return Self.json(403, "{\"error\":\"Agent is not active\",\"code\":\"AGENT_INACTIVE\"}")
        }
        guard oauth.agentRole(serverId: agent.serverId, agentId: agent.id) != nil else {
            return Self.json(403, "{\"error\":\"Agent is not a member of this Server\",\"code\":\"AGENT_NOT_MEMBER\"}")
        }
        guard let client = oauth.localClientForAgentAudience(clientId: service, serverId: agent.serverId),
              client.enabled,
              client.allowedScopes.contains("openid"),
              client.allowedScopes.contains("profile")
        else {
            return Self.json(403, "{\"error\":\"That App is not available on this Server\",\"code\":\"APP_UNAVAILABLE\"}")
        }
        let grantKey = "\(agent.id)\n\(client.clientId)"
        lock.lock()
        let revoked = agentIntegrationGrants[grantKey] == true
        if !revoked {
            agentIntegrationGrants[grantKey] = false
        }
        lock.unlock()
        guard !revoked else {
            return Self.json(403, "{\"error\":\"Agent access to this App has been revoked\",\"code\":\"GRANT_REVOKED\"}")
        }
        guard let slug = oauth.serverProfile(id: agent.serverId)?.slug,
              let origin = OAuthDiscovery.issuerOrigin(serverURL),
              let signed = oauth.signAgentAudienceToken(
                  agentId: agent.id,
                  agentName: agent.name,
                  clientKey: client.clientId,
                  serverId: agent.serverId,
                  serverSlug: slug,
                  issuer: "\(origin)/oidc/\(slug)"
              )
        else {
            return Self.json(500, "{\"error\":\"Failed to issue the App token\"}")
        }
        var reply = Self.json(200, "{\"access_token\":\(jsonString(signed.token)),\"audience\":\(jsonString(client.clientId)),\"expires_in\":300}")
        reply.headers["Cache-Control"] = "no-store"
        return reply
    }

    private struct ActionCardRecord {
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
    }

    private struct ManagedMCPServerRecord {
        var id: String
        var serverId: String
        var name: String
        var provider: String?
        var authMode: String?
        var oauthStatus: String?
        var endpointUrl: String
        var toolCatalogJSON: String
        var catalogVersion: Int
    }

    private struct FeedbackLocatorRecord {
        var serverId: String
        var producerAgentId: String
        var reportId: String
        var receiptId: String
        var capturedAt: Date
        var runtime: String
        var nativeStatus: String
        var nativeLookupMethod: String
        var nativeLocatorKind: String
        var hasServedExact: Bool
        var servedExactSha256: [String]
        var routeBasis: String?
        var routeTarget: String?
        var payloadSha256: String
        var createdAt: Date
    }
    private var externalPushWebhooks: [String: (url: String, secret: String)] = [:]
    private var agentStatusProtocolAdoptedAt: [String: Date] = [:]
    private var agentCursorPullState: [String: (lastPulledAt: Date, pendingAcks: Int)] = [:]
    private var agentProviderPositions: [String: (provider: String, state: String, providerAgentId: String?, syncPending: Bool, lastErrorCode: String?, lastErrorAt: Date?, activatedAt: Date?)] = [:]

    /// Production throttle for credential-use writes.
    public static let agentCredentialUseDefaultThrottleMs = 60_000
    private var deletedMachineWorkspaces: Set<String> = []
    private let realtimeEmitterLock = NSLock()
    private var realtimeEmitterStorage: (@Sendable (String, String, String?) -> Void)?
    /// `MOBILE_APP_EMAIL_UNSUBSCRIBE_SECRET`, or `JWT_SECRET`. The test harness uses `test-jwt-secret`.
    public var mobileAppEmailUnsubscribeSecret: String = "test-jwt-secret"
    /// Cancels one scheduled mobile-app lifecycle email. Unset means there is no provider call to make.
    public var cancelMobileAppEmail: (@Sendable (String) -> Void)?
    /// `SLOCK_NATIVE_NOTIFICATIONS_ENABLED=true`. Unset stays off outside the test harness.
    public var nativeNotificationsEnabled: Bool = false
    /// `NATIVE_NOTIFICATION_STREAM_POLL_MS`. Clamped to 250...5000 when a stream polls.
    public var nativeNotificationStreamPollMs: Int = 1000
    /// Emitted when an agent read cursor advances. Arguments: serverId, channelId, agentId, maxReadSeq.
    public var onAgentReadUpdated: (@Sendable (String, String, String, Int) -> Void)?
    /// Production socket sink: room, event name, JSON payload.
    public var realtimeEmitter: (@Sendable (String, String, String?) -> Void)? {
        get {
            realtimeEmitterLock.lock()
            defer { realtimeEmitterLock.unlock() }
            return realtimeEmitterStorage
        }
        set {
            realtimeEmitterLock.lock()
            realtimeEmitterStorage = newValue
            realtimeEmitterLock.unlock()
        }
    }
    /// Test seam for a manual runtime-account usage refresh. Production has no live daemon relay here.
    public var runtimeAccountUsageManualRefresh: (@Sendable (String, String) -> RuntimeAccountUsageManualResult)?
    /// Test seam called before each already-read SSE frame. Production leaves it nil.
    public var nativeNotificationLiveWriteHook: (@Sendable (_ index: Int, _ eventCount: Int) async -> Void)?
    /// `NATIVE_NOTIFICATION_ATTESTATION_MODE`. Nil means the variable is unset.
    public var nativeNotificationAttestationMode: String? = nil
    /// Process `NODE_ENV`. Production enforces desktop attestation even when the mode is unset.
    public var nativeNotificationNodeEnv: String = "development"
    /// Test seam for signed-app attestation. A nil verifier never accepts evidence.
    public var nativeNotificationAttestationVerifier: (@Sendable (String) -> Bool)?
    private var appleLoginPlatforms: Set<String> = []

    /// Raw `MOBILE_OAUTH_RETURN_URI`. A non-empty parsed list replaces the defaults.
    public var mobileOAuthReturnURI: String?
    /// Raw `MOBILE_OAUTH_ALLOWED_RETURN_URIS`. Used only when the primary list is empty.
    public var mobileOAuthAllowedReturnURIs: String?
    /// Raw `SLOCK_RELEASE_BRANCH`. Staging self-account opt-in is accepted only when this is exactly `staging`.
    public var releaseBranch: String?
    /// Raw `SLOCK_DEVICE_LOGIN_ENABLED`. Unset or empty keeps device login on. `false`, `0`, `no`, and `off` turn it off.
    public var deviceLoginGate: String?
    private var linkedIdentities: [LinkedIdentity] = []
    private var featureFlagRecords: [String: FeatureFlagRecord] = [
        "attachment_comments_v0": FeatureFlagRecord(key: "attachment_comments_v0", defaultEnabled: true),
    ]
    private var featureFlagRuleRecords: [FeatureFlagRuleRecord] = []

    private struct FeatureFlagRecord {
        var key: String
        var enabled = true
        var killSwitch = false
        var defaultEnabled = false
    }

    private struct FeatureFlagRuleRecord {
        var key: String
        var stage: String
        var decision: String
        var values: [String]
        var clientOs: [String]?
        var minClientBuild: Int?
        var clientBuildTypes: [String]?
        var priority = 0
        var createdAt = Date()
    }

    public static let termsVersion = "2026-05-12"
    public static let privacyVersion = "2026-05-12"
    public static let termsURL = "https://raft.build/terms"
    public static let privacyURL = "https://raft.build/privacy"

    public init() {}

    private var experimentalSurfacesDisabledForTesting: Bool?

    /// Operator kill switch for `/internal/agent-api` and `/internal/computer`.
    /// `SLOCK_EXPERIMENTAL_SURFACES_DISABLED=true` disables them; tests may
    /// override without touching the process environment.
    public func setExperimentalSurfacesDisabledForTesting(_ value: Bool?) {
        lock.lock()
        experimentalSurfacesDisabledForTesting = value
        lock.unlock()
    }

    public var experimentalSurfacesDisabled: Bool {
        lock.lock()
        let override = experimentalSurfacesDisabledForTesting
        lock.unlock()
        if let override { return override }
        return (ProcessInfo.processInfo.environment["SLOCK_EXPERIMENTAL_SURFACES_DISABLED"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
    }

    public struct MobileAppEmailContact: Equatable, Sendable {
        public var userId: String
        public var email: String
        public var audienceId: String
        public var status: String
        public var optedOutAt: Date?
    }

    public struct NativeNotificationIntent: Sendable {
        public var recipientUserId: String
        public var eventKey: String
        public var serverId: String
        public var kind: String
        public var channelId: String
        public var threadId: String?
        public var parentChannelId: String?
        public var parentMessageId: String?
        public var messageId: String
        public var title: String
        public var body: String
        public var createdAt: Date

        public init(recipientUserId: String, eventKey: String, serverId: String, kind: String, channelId: String, threadId: String?, parentChannelId: String?, parentMessageId: String?, messageId: String, title: String, body: String, createdAt: Date) {
            self.recipientUserId = recipientUserId
            self.eventKey = eventKey
            self.serverId = serverId
            self.kind = kind
            self.channelId = channelId
            self.threadId = threadId
            self.parentChannelId = parentChannelId
            self.parentMessageId = parentMessageId
            self.messageId = messageId
            self.title = title
            self.body = body
            self.createdAt = createdAt
        }
    }

    /// The bytes an Ed25519 enrollment proof signs. The secret stays out of the stored row.
    public static func enrollmentProofTranscript(grant: String, appId: String, protocolVersion: Int, appVersion: String, releaseChannel: String, appInstanceId: String, publicKey: String, nonce: String) -> Data {
        let joined = [
            "raft-desktop-notification-enrollment-v1",
            sha256(grant),
            appId,
            String(protocolVersion),
            appVersion,
            releaseChannel,
            appInstanceId,
            publicKey,
            nonce,
        ].joined(separator: "\u{0}")
        return Data(joined.utf8)
    }

    /// The bytes an Ed25519 rotation proof signs.
    public static func rotationProofTranscript(credential: String, deviceId: String) -> Data {
        let joined = ["raft-desktop-notification-rotation-v1", sha256(credential), deviceId].joined(separator: "\u{0}")
        return Data(joined.utf8)
    }

    public struct NativeEnrollmentGrantRecord: Sendable {
        public var secretHash: String
        public var json: String
    }

    public func nativeEnrollmentGrantRecords() -> [NativeEnrollmentGrantRecord] {
        lock.lock()
        defer { lock.unlock() }
        return nativeEnrollmentGrants.map { grant in
            let json = "{\"id\":\(jsonString(grant.id)),\"secretHash\":\(jsonString(grant.secretHash)),\"publicKey\":\(jsonString(grant.publicKey)),\"nonce\":\(jsonString(grant.nonce))}"
            return NativeEnrollmentGrantRecord(secretHash: grant.secretHash, json: json)
        }
    }

    /// Moves a stored enrollment grant into the past. Exchange must then fail closed.
    public func expireNativeEnrollmentGrant(id: String) {
        lock.lock()
        if let index = nativeEnrollmentGrants.firstIndex(where: { $0.id == id }) {
            nativeEnrollmentGrants[index].expiresAt = Date().addingTimeInterval(-1)
        }
        lock.unlock()
    }

    /// Marks every session family for this user revoked. A later enrollment exchange must fail closed.
    public func revokeSessionFamilies(userId: String) {
        lock.lock()
        let now = Date()
        for key in sessionFamilies.keys where sessionFamilies[key]?.userId == userId {
            if sessionFamilies[key]?.revokedAt == nil {
                sessionFamilies[key]?.revokedAt = now
            }
            revokedFamilies.insert(key)
        }
        lock.unlock()
    }

    public func nativeNotificationCredentialJSON(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = nativeNotificationCredentials.first(where: { $0.id == id }) else { return nil }
        return "{\"id\":\(jsonString(row.id)),\"secretHash\":\(jsonString(row.secretHash)),\"scope\":\(jsonString(row.scope))}"
    }

    /// `POST /api/notifications/enrollment-grants`. The opaque grant is returned once. Only its hash is stored.
    public func issueNativeEnrollmentGrant(body: String, authorization: String?) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        lock.lock()
        guard let session = notificationSessionLocked(authorization) else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"A live normal session family is required\",\"code\":\"session_family_required\"}")
        }
        guard let request = Self.parseEnrollmentRequest(body) else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid enrollment exchange\",\"code\":\"invalid_enrollment_request\"}")
        }
        let attestation = Self.evaluateAttestation(
            body: body,
            mode: nativeNotificationAttestationMode,
            nodeEnv: nativeNotificationNodeEnv,
            verifier: nativeNotificationAttestationVerifier
        )
        if attestation.state == "rejected" {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Desktop application attestation is required\",\"code\":\"desktop_attestation_required\"}")
        }
        let id = UUID().uuidString.lowercased()
        let minted = Self.mintOpaqueCredential(prefix: "rng1", id: id)
        let now = Date()
        let expiresAt = now.addingTimeInterval(60)
        nativeEnrollmentGrants.append(StoredEnrollmentGrant(
            id: id,
            userId: session.userId,
            sessionFamilyId: session.familyId,
            secretHash: minted.secretHash,
            appId: request.appId,
            protocolVersion: request.protocolVersion,
            appVersion: request.appVersion,
            releaseChannel: request.releaseChannel,
            appInstanceId: request.appInstanceId,
            publicKey: request.publicKey,
            nonce: request.nonce,
            attestationState: attestation.state,
            expiresAt: expiresAt,
            createdAt: now,
            consumedAt: nil
        ))
        lock.unlock()
        return Self.json(201, "{\"grant\":\(jsonString(minted.opaque)),\"expiresAt\":\(jsonString(Self.iso8601(expiresAt)))}")
    }

    /// `POST /api/notifications/enrollment-exchanges`. One grant mints one credential. A second exchange is denied.
    public func exchangeNativeEnrollmentGrant(body: String) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let grantText = object["grant"] as? String,
              let parsed = Self.parseOpaqueCredential(grantText, prefix: "rng1")
        else {
            return Self.json(400, "{\"error\":\"Invalid enrollment exchange\",\"code\":\"invalid_enrollment_exchange\"}")
        }
        let proof = object["proof"] as? String ?? ""
        let denied = Self.json(403, "{\"error\":\"Enrollment exchange denied\",\"code\":\"enrollment_exchange_denied\"}")
        lock.lock()
        guard let index = nativeEnrollmentGrants.firstIndex(where: { $0.id == parsed.id }) else {
            lock.unlock()
            return denied
        }
        let grant = nativeEnrollmentGrants[index]
        let secretHash = Self.sha256(parsed.secret)
        guard secretHash == grant.secretHash,
              grant.consumedAt == nil,
              grant.expiresAt > Date(),
              grant.attestationState != "rejected",
              sessionFamilies[grant.sessionFamilyId]?.userId == grant.userId,
              sessionFamilies[grant.sessionFamilyId]?.revokedAt == nil
        else {
            lock.unlock()
            return denied
        }
        let transcript = Self.enrollmentProofTranscript(
            grant: grantText,
            appId: grant.appId,
            protocolVersion: grant.protocolVersion,
            appVersion: grant.appVersion,
            releaseChannel: grant.releaseChannel,
            appInstanceId: grant.appInstanceId,
            publicKey: grant.publicKey,
            nonce: grant.nonce
        )
        guard Self.verifyEd25519(publicKeySPKI: grant.publicKey, transcript: transcript, proof: proof) else {
            lock.unlock()
            return denied
        }
        let now = Date()
        let deviceId = UUID().uuidString.lowercased()
        nativeNotificationDevices.append(StoredNotificationDevice(
            id: deviceId,
            userId: grant.userId,
            appId: grant.appId,
            appVersion: grant.appVersion,
            releaseChannel: grant.releaseChannel,
            appInstanceId: grant.appInstanceId,
            publicKey: grant.publicKey
        ))
        let credentialId = UUID().uuidString.lowercased()
        let minted = Self.mintOpaqueCredential(prefix: "rnc1", id: credentialId)
        nativeNotificationCredentials.append(StoredNotificationCredential(
            id: credentialId,
            deviceId: deviceId,
            userId: grant.userId,
            sessionFamilyId: grant.sessionFamilyId,
            secretHash: minted.secretHash,
            scope: "notifications:stream",
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60)
        ))
        nativeEnrollmentGrants[index].consumedAt = now
        lock.unlock()
        return Self.json(201, "{\"credential\":\(jsonString(minted.opaque)),\"credentialId\":\(jsonString(credentialId)),\"deviceId\":\(jsonString(deviceId)),\"scope\":\"notifications:stream\",\"expiresAt\":\(jsonString(Self.iso8601(now.addingTimeInterval(30 * 24 * 60 * 60))))}")
    }

    /// `GET /api/notifications/devices`. The list omits hashes, public keys, and credential secrets.
    public func listNativeNotificationDevices(authorization: String?) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        lock.lock()
        guard let session = notificationSessionLocked(authorization) else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        let now = Date()
        let listed = nativeNotificationDevices.filter { $0.userId == session.userId }.map { device in
            let status = nativeDeviceStatusLocked(device, now: now)
            return "{\"deviceId\":\(jsonString(device.id)),\"appId\":\(jsonString(device.appId)),\"appVersion\":\(jsonString(device.appVersion)),\"releaseChannel\":\(jsonString(device.releaseChannel)),\"appInstanceId\":\(jsonString(device.appInstanceId)),\"attestationState\":\"missing\",\"status\":\(jsonString(status))}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"devices\":[\(listed)]}")
    }

    /// `DELETE /api/notifications/devices/:deviceId`. A missing or foreign device is 404.
    public func revokeNativeNotificationDevice(authorization: String?, deviceId: String) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let session = notificationSessionLocked(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\",\"code\":\"auth_required\"}")
        }
        let notFound = Self.json(404, "{\"error\":\"Notification device not found\",\"code\":\"notification_device_not_found\"}")
        guard deviceId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil,
              let index = nativeNotificationDevices.firstIndex(where: {
                  $0.id == deviceId && $0.userId == session.userId && $0.revokedAt == nil
              })
        else { return notFound }
        let now = Date()
        nativeNotificationDevices[index].revokedAt = now
        for credentialIndex in nativeNotificationCredentials.indices
        where nativeNotificationCredentials[credentialIndex].deviceId == deviceId
            && nativeNotificationCredentials[credentialIndex].revokedAt == nil {
            nativeNotificationCredentials[credentialIndex].revokedAt = now
        }
        return Self.noContent()
    }

    /// `POST /api/notifications/credentials/rotate`. The proof is the device key over the current credential.
    public func rotateNativeNotificationCredential(authorization: String?, body: String) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        let invalid = Self.json(401, "{\"error\":\"Invalid native notification credential\",\"code\":\"native_credential_invalid\"}")
        guard let authorization, authorization.hasPrefix("Bearer ") else { return invalid }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard token.hasPrefix("rnc1.") else { return invalid }
        let proof = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["proof"] as? String ?? ""
        lock.lock()
        defer { lock.unlock() }
        guard let principal = nativePrincipalLocked(authorization),
              let index = nativeNotificationCredentials.firstIndex(where: { $0.id == principal.credentialId && $0.revokedAt == nil })
        else { return invalid }
        guard Self.verifyEd25519(
            publicKeySPKI: principal.publicKey,
            transcript: Self.rotationProofTranscript(credential: token, deviceId: principal.deviceId),
            proof: proof
        ) else {
            return Self.json(403, "{\"error\":\"Invalid native notification credential proof\",\"code\":\"native_credential_proof_invalid\"}")
        }
        let current = nativeNotificationCredentials[index]
        let now = Date()
        nativeNotificationCredentials[index].revokedAt = now
        let credentialId = UUID().uuidString.lowercased()
        let minted = Self.mintOpaqueCredential(prefix: "rnc1", id: credentialId)
        let expiresAt = now.addingTimeInterval(30 * 24 * 60 * 60)
        nativeNotificationCredentials.append(StoredNotificationCredential(
            id: credentialId,
            deviceId: current.deviceId,
            userId: current.userId,
            sessionFamilyId: current.sessionFamilyId,
            secretHash: minted.secretHash,
            scope: "notifications:stream",
            expiresAt: expiresAt
        ))
        return Self.json(201, "{\"credential\":\(jsonString(minted.opaque)),\"credentialId\":\(jsonString(credentialId)),\"deviceId\":\(jsonString(current.deviceId)),\"scope\":\"notifications:stream\",\"expiresAt\":\(jsonString(Self.iso8601(expiresAt)))}")
    }

    /// `DELETE /api/notifications/credentials/current`. A credential-shaped bearer is 204 even when it is already dead.
    public func deleteCurrentNativeNotificationCredential(authorization: String?) -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        let invalid = Self.json(401, "{\"error\":\"Invalid native notification credential\",\"code\":\"native_credential_invalid\"}")
        guard let authorization, authorization.hasPrefix("Bearer ") else { return invalid }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard token.hasPrefix("rnc1.") else { return invalid }
        _ = revokeCurrentNativeCredential(token)
        return Self.noContent()
    }

    /// Caller holds `lock`.
    private func notificationSessionLocked(_ authorization: String?) -> (userId: String, familyId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let userId = accessTokens[token],
              let familyId = accessTokenFamilies[token],
              sessionFamilies[familyId]?.userId == userId,
              sessionFamilies[familyId]?.revokedAt == nil,
              accounts.values.contains(where: { $0.id == userId && $0.emailVerified })
        else { return nil }
        return (userId, familyId)
    }

    private static func evaluateAttestation(body: String, mode: String?, nodeEnv: String, verifier: ((String) -> Bool)?) -> (state: String, evidenceHash: String?) {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let raw = object?["attestation"] as? String
        let evidence = (raw?.isEmpty == false && (raw?.count ?? 0) <= 4096) ? raw : nil
        let enforce = nodeEnv == "production" || mode == "enforce" || (mode != nil && mode != "observe")
        let verified = evidence != nil && verifier?(evidence!) == true
        let hash = evidence.map { sha256($0) }
        if enforce && !verified { return ("rejected", hash) }
        if verified { return ("verified", hash) }
        return (evidence == nil ? "missing" : "observed", hash)
    }

    private static func parseEnrollmentRequest(_ body: String) -> (appId: String, protocolVersion: Int, appVersion: String, releaseChannel: String, appInstanceId: String, publicKey: String, nonce: String)? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let appId = object["appId"] as? String,
              appId == "ai.slock.desktop",
              appId.wholeMatch(of: /^[a-z0-9]+(?:\.[a-z0-9-]+){2,7}$/) != nil,
              ((object["protocolVersion"] as? NSNumber)?.intValue ?? object["protocolVersion"] as? Int) == 1,
              let appVersion = object["appVersion"] as? String,
              appVersion.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9._+()-]{0,63}$/) != nil,
              let releaseChannel = object["releaseChannel"] as? String,
              releaseChannel == "development" || releaseChannel == "staging" || releaseChannel == "production",
              let appInstanceId = object["appInstanceId"] as? String,
              appInstanceId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil,
              let publicKey = object["publicKey"] as? String,
              canonicalBase64URL(publicKey, minBytes: 32, maxBytes: 128) != nil,
              let nonce = object["nonce"] as? String,
              canonicalBase64URL(nonce, minBytes: 32, maxBytes: 32) != nil
        else { return nil }
        return (appId, 1, appVersion, releaseChannel, appInstanceId, publicKey, nonce)
    }

    private static func parseOpaqueCredential(_ value: String, prefix: String) -> (id: String, secret: String)? {
        guard value.count <= 160 else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == prefix,
              parts[1].wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil,
              canonicalBase64URL(parts[2], minBytes: 32, maxBytes: 32) != nil
        else { return nil }
        return (parts[1], parts[2])
    }

    private static func canonicalBase64URL(_ value: String, minBytes: Int, maxBytes: Int) -> Data? {
        guard value.wholeMatch(of: /^[A-Za-z0-9_-]+$/) != nil,
              let bytes = base64urlDecode(value),
              (minBytes...maxBytes).contains(bytes.count),
              base64url(bytes) == value
        else { return nil }
        return bytes
    }

    private static func mintOpaqueCredential(prefix: String, id: String) -> (opaque: String, secretHash: String) {
        var bytes = Data(count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        let secret = base64url(bytes)
        return ("\(prefix).\(id).\(secret)", sha256(secret))
    }

    private static func verifyEd25519(publicKeySPKI: String, transcript: Data, proof: String) -> Bool {
        guard let signature = canonicalBase64URL(proof, minBytes: 64, maxBytes: 64),
              let spki = canonicalBase64URL(publicKeySPKI, minBytes: 44, maxBytes: 44)
        else { return false }
        let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
        guard spki.starts(with: prefix), spki.count == 44,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: spki.dropFirst(prefix.count))
        else { return false }
        return key.isValidSignature(signature, for: transcript)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private struct StoredEnrollmentGrant {
        var id: String
        var userId: String
        var sessionFamilyId: String
        var secretHash: String
        var appId: String
        var protocolVersion: Int
        var appVersion: String
        var releaseChannel: String
        var appInstanceId: String
        var publicKey: String
        var nonce: String
        var attestationState: String
        var expiresAt: Date
        var createdAt: Date
        var consumedAt: Date?
    }

    private struct StoredNotificationDevice {
        var id: String
        var userId: String
        var appId: String
        var appVersion: String
        var releaseChannel: String
        var appInstanceId: String
        var publicKey: String = ""
        var revokedAt: Date? = nil
    }

    private struct StoredNotificationCredential {
        var id: String
        var deviceId: String
        var userId: String
        var sessionFamilyId: String
        var secretHash: String
        var scope: String
        var expiresAt: Date
        var revokedAt: Date? = nil
    }

    private struct StoredNativeNotificationEvent {
        var eventId: String
        var streamSeq: Int
        var recipientUserId: String
        var eventKey: String
        var serverId: String
        var channelId: String
        var messageId: String
        var title: String
        var body: String
        var targetUri: String
        var createdAt: Date
        var expiresAt: Date
    }

    public enum NativeStreamOpen: Sendable {
        case closed(HTTPReply)
        case streaming(userId: String, cursorSeq: Int, replay: [(seq: Int, frame: String)])
    }

    /// Opens `GET /api/notifications/stream`. A user session or a foreign cursor fails before any event-stream bytes.
    public func beginNativeNotificationStream(authorization: String?, lastEventId: String?) -> NativeStreamOpen {
        guard nativeNotificationsEnabled else {
            return .closed(Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}"))
        }
        let denied = Self.json(401, "{\"error\":\"Invalid native notification credential\",\"code\":\"native_credential_invalid\"}")
        let unavailable = Self.json(409, "{\"error\":\"Replay cursor is unavailable\",\"code\":\"replay_cursor_unavailable\"}")
        lock.lock()
        defer { lock.unlock() }
        guard let principal = nativePrincipalLocked(authorization) else {
            return .closed(denied)
        }
        let now = Date()
        if let lastEventId {
            guard lastEventId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil,
                  let cursor = nativeNotificationEvents.first(where: {
                      $0.eventId == lastEventId && $0.recipientUserId == principal.userId && $0.expiresAt > now
                  })
            else { return .closed(unavailable) }
            let replay = nativeNotificationEvents
                .filter { $0.recipientUserId == principal.userId && $0.streamSeq > cursor.streamSeq && $0.expiresAt > now }
                .sorted { $0.streamSeq < $1.streamSeq }
            if replay.count > 512 {
                return .closed(Self.json(409, "{\"error\":\"Replay window exceeded\",\"code\":\"replay_window_exceeded\"}"))
            }
            return .streaming(userId: principal.userId, cursorSeq: cursor.streamSeq, replay: replay.map { ($0.streamSeq, Self.sseFrame($0)) })
        }
        let latest = nativeNotificationEvents
            .filter { $0.recipientUserId == principal.userId && $0.expiresAt > now }
            .map(\.streamSeq)
            .max() ?? 0
        return .streaming(userId: principal.userId, cursorSeq: latest, replay: [])
    }

    /// Moves a stored native credential into the past. A later stream must fail closed.
    public func expireNativeNotificationEvent(id: String) {
        lock.lock()
        if let index = nativeNotificationEvents.firstIndex(where: { $0.eventId == id }) {
            nativeNotificationEvents[index].expiresAt = Date().addingTimeInterval(-1)
        }
        lock.unlock()
    }

    public func expireNativeNotificationCredential(id: String) {
        lock.lock()
        if let index = nativeNotificationCredentials.firstIndex(where: { $0.id == id }) {
            nativeNotificationCredentials[index].expiresAt = Date().addingTimeInterval(-1)
        }
        lock.unlock()
    }

    public func nativeNotificationDeviceRevokedAt(id: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return nativeNotificationDevices.first { $0.id == id }?.revokedAt
    }

    /// Revokes the native credential named by this opaque token. A later stream frame must not be written.
    public func revokeCurrentNativeCredential(_ opaque: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let parsed = Self.parseOpaqueCredential(opaque, prefix: "rnc1") else { return false }
        let hash = Self.sha256(parsed.secret)
        guard let index = nativeNotificationCredentials.firstIndex(where: {
            $0.id == parsed.id && $0.secretHash == hash && $0.revokedAt == nil
        }) else { return false }
        nativeNotificationCredentials[index].revokedAt = Date()
        return true
    }

    public func nativeNotificationCredentialIsLive(authorization: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nativePrincipalLocked(authorization) != nil
    }

    public func nativeNotificationFrames(userId: String, after cursor: Int) -> [(seq: Int, frame: String)] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return nativeNotificationEvents
            .filter { $0.recipientUserId == userId && $0.streamSeq > cursor && $0.expiresAt > now }
            .sorted { $0.streamSeq < $1.streamSeq }
            .map { ($0.streamSeq, Self.sseFrame($0)) }
    }

    /// Caller holds `lock`. A revoked device cannot authenticate, even if its credential row is still open.
    private func nativePrincipalLocked(_ authorization: String?) -> (userId: String, familyId: String, credentialId: String, deviceId: String, publicKey: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let parsed = Self.parseOpaqueCredential(token, prefix: "rnc1") else { return nil }
        let hash = Self.sha256(parsed.secret)
        let now = Date()
        guard let credential = nativeNotificationCredentials.first(where: {
            $0.id == parsed.id && $0.secretHash == hash && $0.revokedAt == nil && $0.expiresAt > now && $0.scope == "notifications:stream"
        }), let device = nativeNotificationDevices.first(where: { $0.id == credential.deviceId }),
              device.revokedAt == nil
        else { return nil }
        guard !revokedFamilies.contains(credential.sessionFamilyId),
              sessionFamilies[credential.sessionFamilyId]?.userId == credential.userId,
              sessionFamilies[credential.sessionFamilyId]?.revokedAt == nil
        else { return nil }
        return (credential.userId, credential.sessionFamilyId, credential.id, credential.deviceId, device.publicKey)
    }

    /// Caller holds `lock`. Revoked devices are `revoked`. A live unexpired credential on a live family is `active`.
    private func nativeDeviceStatusLocked(_ device: StoredNotificationDevice, now: Date) -> String {
        if let revokedAt = device.revokedAt, revokedAt <= now { return "revoked" }
        let active = nativeNotificationCredentials.contains { credential in
            credential.deviceId == device.id
                && credential.revokedAt == nil
                && credential.expiresAt > now
                && credential.scope == "notifications:stream"
                && !revokedFamilies.contains(credential.sessionFamilyId)
                && sessionFamilies[credential.sessionFamilyId]?.userId == device.userId
                && sessionFamilies[credential.sessionFamilyId]?.revokedAt == nil
        }
        return active ? "active" : "inactive"
    }

    private func liveNativeCredentialLocked(userId: String) -> Bool {
        let now = Date()
        return nativeNotificationCredentials.contains { credential in
            credential.userId == userId
                && credential.revokedAt == nil
                && credential.expiresAt > now
                && credential.scope == "notifications:stream"
                && !revokedFamilies.contains(credential.sessionFamilyId)
                && sessionFamilies[credential.sessionFamilyId]?.userId == userId
                && sessionFamilies[credential.sessionFamilyId]?.revokedAt == nil
                && nativeNotificationDevices.contains { $0.id == credential.deviceId && $0.revokedAt == nil }
        }
    }

    private static func sseFrame(_ event: StoredNativeNotificationEvent) -> String {
        let data = "{\"body\":\(jsonString(event.body)),\"createdAt\":\(jsonString(iso8601(event.createdAt))),\"eventId\":\(jsonString(event.eventId)),\"serverId\":\(jsonString(event.serverId)),\"targetUri\":\(jsonString(event.targetUri)),\"title\":\(jsonString(event.title)),\"version\":1}"
        return "event: native-notification.v1\nid: \(event.eventId)\ndata: \(data)\n\n"
    }

    /// `GET /api/notifications/stream`. The kill switch answers before any stream is opened.
    public func nativeNotificationStream() -> HTTPReply {
        guard nativeNotificationsEnabled else {
            return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
        }
        return Self.json(404, "{\"error\":\"Not found\",\"code\":\"not_found\"}")
    }

    public func nativeNotificationEventCount(eventKey: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return nativeNotificationEvents.filter { $0.eventKey == eventKey }.count
    }

    public func nativeNotificationEventIDs(recipientUserId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return nativeNotificationEvents.filter { $0.recipientUserId == recipientUserId }.map(\.eventId)
    }

    /// Disabled notifications persist nothing. An empty batch also persists nothing.
    /// A recipient without a live native credential does not grow the ledger. The same event key is stored once.
    public func persistNativeNotificationIntents(_ intents: [NativeNotificationIntent]) -> Int {
        if !nativeNotificationsEnabled || intents.isEmpty { return 0 }
        lock.lock()
        defer { lock.unlock() }
        var inserted = 0
        var seen = Set(nativeNotificationEvents.map(\.eventKey))
        for intent in intents {
            guard liveNativeCredentialLocked(userId: intent.recipientUserId), !seen.contains(intent.eventKey) else { continue }
            seen.insert(intent.eventKey)
            nextNativeNotificationSeq += 1
            let now = Date()
            nativeNotificationEvents.append(StoredNativeNotificationEvent(
                eventId: UUID().uuidString.lowercased(),
                streamSeq: nextNativeNotificationSeq,
                recipientUserId: intent.recipientUserId,
                eventKey: intent.eventKey,
                serverId: intent.serverId,
                channelId: intent.channelId,
                messageId: intent.messageId,
                title: intent.title,
                body: intent.body,
                targetUri: "raft://v1/servers/\(intent.serverId)/channels/\(intent.channelId)/messages/\(intent.messageId)",
                createdAt: intent.createdAt,
                expiresAt: Date(timeInterval: 24 * 60 * 60, since: max(now, intent.createdAt))
            ))
            inserted += 1
        }
        return inserted
    }

    public struct MobileAppEmailJourney: Equatable, Sendable {
        public var userId: String
        public var email: String
        public var journeyKey: String
        public var day1Status: String
        public var day1EmailId: String?
        public var suppressedReason: String?
        public var canceledAt: Date?
    }

    /// Signed token for `GET/POST /api/email/mobile-app/unsubscribe`. A missing locale is `en`.
    public func createMobileAppEmailUnsubscribeToken(userId: String, locale: String? = nil) -> String {
        let canonical = Self.mobileAppUnsubscribeLocale(locale)
        let claims = "{\"v\":1,\"typ\":\"mobile-app-email-unsubscribe\",\"sub\":\(jsonString(userId)),\"locale\":\(jsonString(canonical))}"
        let payload = Self.base64url(Data(claims.utf8))
        let signature = Self.mobileAppUnsubscribeSignature(payload: payload, secret: mobileAppEmailUnsubscribeSecret)
        return "\(payload).\(signature)"
    }

    /// A scheduled mobile-app lifecycle email. Unsubscribe cancels `day1Status` of `scheduled`.
    public func addMobileAppEmailJourney(userId: String, email: String, journeyKey: String, day1Status: String, day1EmailId: String?) {
        lock.lock()
        storedMobileAppEmailJourneys.append(MobileAppEmailJourney(
            userId: userId,
            email: Self.normalize(email),
            journeyKey: journeyKey,
            day1Status: day1Status,
            day1EmailId: day1EmailId,
            suppressedReason: nil,
            canceledAt: nil
        ))
        lock.unlock()
    }

    public func mobileAppEmailJourneys() -> [MobileAppEmailJourney] {
        lock.lock()
        defer { lock.unlock() }
        return storedMobileAppEmailJourneys
    }

    /// Local opt-outs for the mobile-app lifecycle audience. The human page does not write one.
    public func mobileAppEmailContacts() -> [MobileAppEmailContact] {
        lock.lock()
        defer { lock.unlock() }
        return mobileAppEmailContactsByKey.values.sorted { $0.email < $1.email }
    }

    public func setAccountProfileForTesting(id: String, name: String, displayName: String? = nil) {
        lock.lock()
        if let key = accounts.first(where: { $0.value.id == id })?.key, var account = accounts[key] {
            account.name = name
            account.displayName = displayName ?? name
            accounts[key] = account
        }
        lock.unlock()
    }

    public func addAccount(id: String, email: String, password: String, avatarUrl: String? = nil) {
        let normalized = Self.normalize(email)
        lock.lock()
        accounts[normalized] = Account(
            id: id,
            email: normalized,
            passwordHash: Self.sha256(password),
            displayLanguage: nil,
            name: String(normalized.split(separator: "@").first ?? "user"),
            profileSetupSuggestedHandle: nil,
            profileSetupProvider: nil,
            profileSetupCompletedAt: Date(),
            avatarUrl: avatarUrl
        )
        analyticsIds[id] = UUID().uuidString.lowercased()
        lock.unlock()
    }

    /// The product-analytics id for this user. Opting out removes it. Opting back in mints a new one.
    public func analyticsId(userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return analyticsIds[userId]
    }

    public var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    public var userCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accounts.count
    }

    public var legalAcceptanceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return legalAcceptances.count
    }

    public var emailVerificationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return emailVerifications
    }

    public func hasAccount(email: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accounts[Self.normalize(email)] != nil
    }

    public func legalAcceptance(userId: String) -> EmailLegalAcceptance? {
        lock.lock()
        defer { lock.unlock() }
        return legalAcceptances[userId]
    }

    public func userId(forEmail email: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return accounts[Self.normalize(email)]?.id
    }

    /// A provider callback already exchanged. The raw code is what `POST /:provider/complete` spends.
    public func addSocialCompletion(
        provider: String,
        code: String,
        email: String,
        mode: String = "login",
        intendedAction: String = "login",
        returnTo: String = "/",
        userId: String? = nil,
        providerUserId: String? = nil
    ) {
        lock.lock()
        socialCompletions.append(SocialCompletion(
            provider: provider,
            code: code,
            mode: mode,
            intendedAction: intendedAction,
            email: Self.normalize(email),
            returnTo: returnTo,
            userId: userId,
            providerUserId: providerUserId
        ))
        lock.unlock()
    }

    public func linkedProviderUserIds(userId: String, provider: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return linkedIdentities.filter { $0.userId == userId && $0.provider == provider }.map(\.providerUserId)
    }

    public func linkedProviderEmail(userId: String, provider: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return linkedIdentities.first { $0.userId == userId && $0.provider == provider }?.providerEmail
    }

    /// `POST /api/auth/:provider/complete`. A first login checks legal acceptance before the code is spent.
    public func completeSocial(
        provider: String,
        body: String,
        userAgent: String?,
        acceptLanguage: String?,
        authorization: String? = nil
    ) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.json(400, "{\"error\":\"Sign-in completion code is required\"}")
        }
        guard let code = object["code"] as? String, !code.isEmpty else {
            return Self.json(400, "{\"error\":\"Sign-in completion code is required\"}")
        }
        lock.lock()
        guard let index = socialCompletions.firstIndex(where: { $0.provider == provider && $0.code == code }) else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid or expired social auth completion\"}")
        }
        let completion = socialCompletions[index]
        if completion.mode == "link" {
            guard let authorization, authorization.hasPrefix("Bearer ") else {
                lock.unlock()
                return Self.linkAuthRequired
            }
            let token = String(authorization.dropFirst("Bearer ".count))
            guard let caller = accessTokens[token] else {
                lock.unlock()
                return Self.linkAuthRequired
            }
            guard completion.userId == caller else {
                lock.unlock()
                return Self.linkMismatch
            }
            socialCompletions.remove(at: index)
            let providerUserId = completion.providerUserId ?? ""
            if !linkedIdentities.contains(where: {
                $0.userId == caller && $0.provider == provider && $0.providerUserId == providerUserId
            }) {
                linkedIdentities.append(LinkedIdentity(
                    userId: caller,
                    provider: provider,
                    providerUserId: providerUserId
                ))
            }
            let rows = linkedIdentities.filter { $0.userId == caller }
            lock.unlock()
            let listed = rows.map {
                "{\"provider\":\(jsonString($0.provider)),\"providerUserId\":\(jsonString($0.providerUserId))}"
            }.joined(separator: ",")
            let linked = "{\"provider\":\(jsonString(provider)),\"mode\":\"link\",\"returnTo\":\(jsonString(completion.returnTo)),\"identities\":[\(listed)]}"
            return Self.json(200, linked)
        }
        if completion.mode == "login", completion.userId == nil {
            if object["acceptTerms"] as? Bool != true {
                lock.unlock()
                return Self.legalRequired
            }
            let terms = object["termsVersion"] as? String
            let privacy = object["privacyVersion"] as? String
            if terms != Self.termsVersion || privacy != Self.privacyVersion {
                lock.unlock()
                return Self.termsChanged
            }
        }
        socialCompletions.remove(at: index)
        let id = completion.userId ?? UUID().uuidString.lowercased()
        let taken = Set(accounts.values.map(\.name))
        let pendingName = Self.pendingHandle(taken: taken)
        let suggested = Self.availableUserName(
            seed: String(completion.email.split(separator: "@").first ?? "user"),
            taken: taken
        )
        if completion.userId == nil, accounts[completion.email] != nil {
            lock.unlock()
            return Self.json(409, "{\"error\":\"An account with this email already exists. Sign in with email and password first, then connect \(provider) in Settings.\"}")
        }
        if completion.userId == nil {
            accounts[completion.email] = Account(
                id: id,
                email: completion.email,
                passwordHash: Self.sha256(Self.token()),
                displayLanguage: nil,
                name: pendingName,
                profileSetupSuggestedHandle: suggested
            )
            let source = (object["legalAcceptanceSource"] as? String) == "invite" ? "invite" : "oauth"
            legalAcceptances[id] = EmailLegalAcceptance(
                termsVersion: Self.termsVersion,
                privacyVersion: Self.privacyVersion,
                termsUrl: Self.termsURL,
                privacyUrl: Self.privacyURL,
                source: source,
                userAgentHash: userAgent.flatMap { $0.isEmpty ? nil : Self.sha256($0) },
                locale: acceptLanguage
            )
        }
        let accessToken = Self.token()
        let refreshToken = Self.token()
        sessions[refreshToken] = LiveSession(userId: id, familyId: UUID().uuidString.lowercased())
        accessTokens[accessToken] = id
        lock.unlock()
        let response = "{\"provider\":\(jsonString(provider)),\"mode\":\(jsonString(completion.mode)),\"returnTo\":\(jsonString(completion.returnTo)),\"accessToken\":\(jsonString(accessToken)),\"refreshToken\":\(jsonString(refreshToken))}"
        return Self.json(200, response)
    }

    /// `POST /api/auth/register`. A non-string email, password, or name is 400 before any account exists. Missing acceptance is 422. A stale version is 409 and creates no account.
    public func register(body: String, userAgent: String?, acceptLanguage: String?) -> HTTPReply {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.registerInvalid([Issue(path: "", message: "Expected object, received string")])
        }
        var issues: [Issue] = []
        let email = Self.stringField(object["email"], path: "email", into: &issues)
        let password = Self.stringField(object["password"], path: "password", into: &issues)
        if object["name"] != nil {
            _ = Self.stringField(object["name"], path: "name", into: &issues)
        }
        let capability = Self.stagingCapability(object["stagingSelfAccountCapability"], into: &issues)
        guard let email, let password, issues.isEmpty else {
            return Self.registerInvalid(issues)
        }
        if capability != nil {
            let stagingEmail = email.wholeMatch(of: /(?i).*@mail\.build/) != nil
            if releaseBranch != "staging" || !stagingEmail {
                return Self.json(403, "{\"error\":\"Staging self-account registration is unavailable\"}")
            }
        }
        if let name = object["name"] as? String, Self.isReservedAgentName(name) {
            return Self.json(400, "{\"error\":\"This username is reserved. Choose another name.\"}")
        }
        if object["acceptTerms"] as? Bool != true {
            return Self.legalRequired
        }
        let terms = object["termsVersion"] as? String
        let privacy = object["privacyVersion"] as? String
        if terms != Self.termsVersion || privacy != Self.privacyVersion {
            return Self.termsChanged
        }

        let normalized = Self.normalize(email)
        let source = (object["legalAcceptanceSource"] as? String) == "invite" ? "invite" : "signup"
        let requestedName = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if accounts[normalized] != nil {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Email already registered\"}")
        }
        let taken = Set(accounts.values.map(\.name))
        let pendingName = Self.pendingHandle(taken: taken)
        let suggested = Self.availableUserName(
            seed: (requestedName?.isEmpty == false ? requestedName! : String(normalized.split(separator: "@").first ?? "user")),
            taken: taken
        )
        let id = UUID().uuidString.lowercased()
        accounts[normalized] = Account(
            id: id,
            email: normalized,
            passwordHash: Self.sha256(password),
            displayLanguage: nil,
            name: pendingName,
            profileSetupSuggestedHandle: suggested,
            stagingSelfAccountCapabilityHash: capability.map(Self.sha256)
        )
        legalAcceptances[id] = EmailLegalAcceptance(
            termsVersion: Self.termsVersion,
            privacyVersion: Self.privacyVersion,
            termsUrl: Self.termsURL,
            privacyUrl: Self.privacyURL,
            source: source,
            userAgentHash: userAgent.flatMap { $0.isEmpty ? nil : Self.sha256($0) },
            locale: acceptLanguage
        )
        let issued = openSessionLocked(userId: id)
        emailVerifications += 1
        lock.unlock()
        let user = "{\"id\":\(jsonString(id)),\"email\":\(jsonString(normalized)),\"name\":\(jsonString(pendingName)),\"profileSetupCompletedAt\":null,\"profileSetupSuggestedHandle\":\(jsonString(suggested)),\"profileSetupProvider\":null}"
        let response = "{\"user\":\(user),\"accessToken\":\(jsonString(issued.accessToken)),\"refreshToken\":\(jsonString(issued.refreshToken))}"
        return Self.json(200, response)
    }

    /// `POST /api/auth/staging-self-account/retire`. The caller's access token stays usable after the sessions are revoked.
    public func retireStagingSelfAccount(body: String, authorization: String?) -> HTTPReply {
        guard let actorId = retirementActor(authorization) else { return Self.invalidToken }
        if releaseBranch != "staging" {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let userId = object?["userId"] as? String ?? ""
        let capability = object?["capability"] as? String ?? ""
        if userId != actorId {
            return Self.json(403, "{\"error\":\"User ownership mismatch\"}")
        }
        if capability.isEmpty {
            return Self.json(403, "{\"error\":\"Invalid retirement capability\"}")
        }
        guard userId.wholeMatch(of: /(?i)[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil else {
            return Self.json(404, "{\"error\":\"User not found\"}")
        }
        lock.lock()
        guard let key = accounts.first(where: { $0.value.id == userId })?.key, var account = accounts[key] else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"User not found\"}")
        }
        if !account.emailVerified || account.email.wholeMatch(of: /(?i).*@mail\.build/) == nil {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Unsupported account\"}")
        }
        if account.stagingSelfAccountCapabilityHash == nil || account.stagingSelfAccountCapabilityHash != Self.sha256(capability) {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Invalid retirement capability\"}")
        }
        if account.retiredAt != nil {
            let receipt = retirementReceipts[userId]
            lock.unlock()
            guard let receipt else { return Self.json(500, "{\"error\":\"Retirement receipt unavailable\"}") }
            return Self.retirementJSON(receipt)
        }
        let now = Date()
        account.retiredAt = now
        accounts[key] = account
        let live = sessions.filter { $0.value.userId == userId }
        for (token, session) in live {
            sessions.removeValue(forKey: token)
            revokedFamilies.insert(session.familyId)
        }
        let familyIds = sessionFamilies.compactMap { $0.value.userId == userId ? $0.key : nil }
        for familyId in familyIds {
            revokedFamilies.insert(familyId)
            if sessionFamilies[familyId]?.revokedAt == nil {
                sessionFamilies[familyId]?.revokedAt = now
            }
        }
        let receipt = RetirementReceipt(
            userId: userId,
            actorUserId: actorId,
            environment: "staging",
            terminalState: "retired",
            sessionsRevoked: live.count
        )
        retirementReceipts[userId] = receipt
        lock.unlock()
        return Self.retirementJSON(receipt)
    }

    /// `POST /api/auth/device/authorize`. The surface is on unless the gate is an explicit off value.
    public func authorizeDevice(body: String) -> HTTPReply {
        if let disabled = deviceSurfaceDisabled() { return disabled }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        var clientName: String?
        if object.keys.contains("clientName"), !(object["clientName"] is NSNull) {
            guard let name = object["clientName"] as? String, name.count <= 200 else {
                return Self.json(400, "{\"error\":\"clientName must be a string up to 200 chars\",\"code\":\"client_name_invalid\"}")
            }
            clientName = name
        }
        let userCode = makeUserCode()
        let deviceCode = Self.deviceSecret()
        let expiresAt = Date(timeIntervalSinceNow: 600)
        lock.lock()
        deviceGrants[deviceCode] = DeviceGrant(
            deviceCode: deviceCode,
            userCode: userCode,
            status: "pending",
            approvedByUserId: nil,
            expiresAt: expiresAt,
            clientName: clientName
        )
        deviceUserCodes[userCode] = deviceCode
        lock.unlock()
        guard let verification = deviceVerification(userCode: userCode) else {
            return Self.json(503, "{\"error\":\"Device login URL is not configured\",\"code\":\"DEVICE_LOGIN_URL_UNAVAILABLE\"}")
        }
        let response = "{\"deviceCode\":\(jsonString(deviceCode)),\"userCode\":\(jsonString(userCode)),\"verificationUri\":\(jsonString(verification.uri)),\"verificationUriComplete\":\(jsonString(verification.complete)),\"expiresIn\":600,\"interval\":5}"
        return Self.json(201, response)
    }

    /// `POST /api/auth/device/approve`. Only the signed-in user can approve or deny a code.
    public func approveDevice(body: String, authorization: String?) -> HTTPReply {
        if let disabled = deviceSurfaceDisabled() { return disabled }
        let actor: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            actor = id
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        guard let rawCode = object["userCode"] as? String, !rawCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.json(400, "{\"error\":\"userCode is required\",\"code\":\"user_code_required\"}")
        }
        let approve = object["approve"] == nil ? true : (object["approve"] as? Bool == true)
        let normalized = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        lock.lock()
        guard let deviceCode = deviceUserCodes[normalized], var grant = deviceGrants[deviceCode] else {
            lock.unlock()
            return Self.deviceUpdateFailed("user_code_invalid", status: 404)
        }
        if grant.status != "pending" {
            lock.unlock()
            return Self.deviceUpdateFailed("already_resolved", status: 409)
        }
        if grant.expiresAt <= Date() {
            lock.unlock()
            return Self.deviceUpdateFailed("expired", status: 410)
        }
        if approve {
            grant.status = "approved"
            grant.approvedByUserId = actor
        } else {
            grant.status = "denied"
            grant.approvedByUserId = nil
        }
        deviceGrants[deviceCode] = grant
        lock.unlock()
        let action = approve ? "approved" : "denied"
        return Self.json(200, "{\"ok\":true,\"action\":\(jsonString(action))}")
    }

    /// `POST /api/auth/device/token`. A pending grant stays pending. Approval issues one session, then the code is spent.
    public func pollDeviceToken(body: String) -> HTTPReply {
        if let disabled = deviceSurfaceDisabled() { return disabled }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        guard let deviceCode = object["deviceCode"] as? String, !deviceCode.isEmpty else {
            return Self.json(400, "{\"error\":\"deviceCode is required\",\"code\":\"device_code_required\"}")
        }
        lock.lock()
        guard var grant = deviceGrants[deviceCode] else {
            lock.unlock()
            return Self.deviceNotReady("device_code_invalid", status: 400)
        }
        if grant.status == "consumed" {
            lock.unlock()
            return Self.deviceNotReady("device_code_consumed", status: 410)
        }
        if grant.expiresAt <= Date() {
            lock.unlock()
            return Self.deviceNotReady("expired_token", status: 410)
        }
        if grant.status == "denied" {
            lock.unlock()
            return Self.deviceNotReady("access_denied", status: 403)
        }
        guard grant.status == "approved", let userId = grant.approvedByUserId else {
            lock.unlock()
            return Self.deviceNotReady("authorization_pending", status: 400)
        }
        grant.status = "consumed"
        deviceGrants[deviceCode] = grant
        let issued = openSessionLocked(userId: userId)
        lock.unlock()
        let response = "{\"accessToken\":\(jsonString(issued.accessToken)),\"refreshToken\":\(jsonString(issued.refreshToken)),\"userId\":\(jsonString(userId))}"
        return Self.json(200, response)
    }

    /// `POST /api/auth/refresh`. A matching attempt and installation replay the same successor.
    public func refresh(body: String, attemptHeader: String?, installationHeader: String?) -> HTTPReply {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refreshToken = object["refreshToken"] as? String, !refreshToken.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Refresh token is required\"}")
        }
        let attempt = Self.refreshAttempt(attemptHeader)
        let installation = Self.refreshInstallation(installationHeader)
        if installationHeader != nil, attempt == nil || installation == nil {
            return Self.json(400, "{\"error\":\"Invalid refresh replay binding\"}")
        }
        lock.lock()
        let outcome = refreshLocked(
            refreshToken: refreshToken,
            attemptId: attempt,
            installationId: installation
        )
        lock.unlock()
        switch outcome {
        case .rejected:
            return Self.json(401, "{\"error\":\"Invalid or expired refresh token\"}")
        case .rotated(let userId, let successor):
            return Self.json(200, "{\"accessToken\":\(jsonString(userId.accessToken)),\"refreshToken\":\(jsonString(successor))}")
        }
    }

    public func refreshRotationReceipts() -> [RefreshRotationReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return rotationReceipts.values.map {
            RefreshRotationReceipt(
                attemptId: $0.attemptId,
                installationId: $0.installationId,
                successorTokenCiphertext: $0.ciphertext
            )
        }
    }

    public func expireRefreshReceipts() {
        lock.lock()
        for key in rotationReceipts.keys {
            rotationReceipts[key]?.expiresAt = Date(timeIntervalSinceNow: -1)
        }
        lock.unlock()
    }

    /// Moves one mobile OAuth request's expiry into the past. Completion then reports `handoff_code_expired`.
    public func expireMobileOAuthRequest(id: String) {
        lock.lock()
        mobileRequests[id]?.expiresAt = Date(timeIntervalSinceNow: -1)
        lock.unlock()
    }

    /// `POST /api/auth/logout`. Revoking the predecessor's family blocks a later replay.
    public func logout(body: String) -> HTTPReply {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let refreshToken = object["refreshToken"] as? String, !refreshToken.isEmpty {
            lock.lock()
            if let live = sessions.removeValue(forKey: refreshToken) {
                revokedFamilies.insert(live.familyId)
                sessionFamilies[live.familyId]?.revokedAt = Date()
                sessionFamilies[live.familyId]?.revokedReason = "logout"
                sessionFamilies[live.familyId]?.capabilityRetainUntil = Date().addingTimeInterval(30 * 24 * 60 * 60)
                let familyTokens = sessions.filter { $0.value.familyId == live.familyId }.map { $0.key }
                for token in familyTokens { sessions.removeValue(forKey: token) }
            } else if let receipt = rotationReceipts[Self.sha256(refreshToken)] {
                revokedFamilies.insert(receipt.familyId)
                sessionFamilies[receipt.familyId]?.revokedAt = Date()
                sessionFamilies[receipt.familyId]?.revokedReason = "logout"
                sessionFamilies[receipt.familyId]?.capabilityRetainUntil = Date().addingTimeInterval(30 * 24 * 60 * 60)
            }
            lock.unlock()
        }
        return Self.json(200, "{\"ok\":true}")
    }

    public var providerExchangeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return providerExchanges
    }

    public func oauthRequestStatus(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.status
    }

    public func oauthRequestReturnUri(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.returnUri
    }

    public func oauthRequestCodeHash(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.codeHash
    }

    public func oauthRequestExpiresAt(id: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.expiresAt
    }

    public func oauthRequestProviderUserId(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.profileUserId
    }

    public func oauthRequestProviderEmail(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.profileEmail
    }

    public func isEmailVerified(userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accounts.values.first { $0.id == userId }?.emailVerified ?? false
    }

    /// The Node fixture marks a row verified without an HTTP call. Retirement refuses an unverified account.
    public func markEmailVerified(userId: String) {
        lock.lock()
        if let key = accounts.first(where: { $0.value.id == userId })?.key {
            accounts[key]?.emailVerified = true
        }
        lock.unlock()
    }

    public func stagingSelfAccountCapabilityHash(userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return accounts.values.first { $0.id == userId }?.stagingSelfAccountCapabilityHash
    }

    public func retiredAt(userId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return accounts.values.first { $0.id == userId }?.retiredAt
    }

    public var retirementReceiptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retirementReceipts.count
    }

    public func sessionCount(for userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.filter { $0.userId == userId }.count
    }

    public func sessionFamilyRevokedAts(userId: String) -> [Date?] {
        lock.lock()
        defer { lock.unlock() }
        return sessionFamilies.values.filter { $0.userId == userId }.map(\.revokedAt)
    }

    public func oauthRequestCodeChallenge(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests[id]?.codeChallenge
    }

    public var mobileOAuthRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests.count
    }

    /// Adds platform allow rules for Apple sign-in. An empty set leaves Apple disabled on every platform.
    public func allowAppleLogin(on platforms: [String]) {
        lock.lock()
        appleLoginPlatforms.formUnion(platforms)
        lock.unlock()
    }

    /// `GET /api/auth/providers`. A missing platform is web. Anything other than web or mobile is refused first.
    public func authProviders(platform raw: String?) -> HTTPReply {
        let platform = raw ?? "web"
        guard platform == "web" || platform == "mobile" else {
            return Self.json(400, "{\"code\":\"platform_invalid\",\"error\":\"platform must be web or mobile\"}")
        }
        lock.lock()
        let configured = configuredSocialAuthProviders
        let allowed = appleLoginPlatforms
        lock.unlock()
        let providers: [(id: String, label: String)] = [
            ("google", "Google"),
            ("github", "GitHub"),
            ("apple", "Apple"),
        ]
        let listed = providers.map { provider in
            let enabled = configured.contains(provider.id) && (provider.id != "apple" || allowed.contains(platform))
            return "{\"id\":\(jsonString(provider.id)),\"label\":\(jsonString(provider.label)),\"enabled\":\(enabled ? "true" : "false")}"
        }.joined(separator: ",")
        return Self.json(200, "{\"providers\":[\(listed)]}")
    }

    /// `POST /api/auth/mobile/oauth/start`. The desktop nonce is taken from the loopback return URI.
    public func startMobileOAuth(body: String) -> HTTPReply {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth start\"}")
        }
        guard let returnUri = object["returnUri"] as? String,
              Self.isDesktopLoopback(returnUri) || configuredMobileReturnURIs().contains(returnUri)
        else {
            return Self.returnURINotAllowed
        }
        guard let provider = object["provider"] as? String,
              Self.socialProviders.contains(provider),
              let mode = object["mode"] as? String, mode == "login" || mode == "link",
              let challenge = object["codeChallenge"] as? String,
              challenge.wholeMatch(of: /^[A-Za-z0-9_-]{32,256}$/) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth start\"}")
        }
        if provider == "apple", !mobileAppleAvailable() {
            return Self.appleNotConfigured
        }
        return openedMobileOAuth(provider: provider, mode: mode, returnUri: returnUri, challenge: challenge, userId: nil)
    }

    /// `GET /api/auth/:provider/start`. Apple stays closed until its web platform rule is allowed.
    public func startWebOAuth(provider: String, returnTo: String?) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        guard webProviderAvailable(provider) else {
            return Self.json(404, "{\"error\":\"\(Self.providerLabel(provider)) sign-in is not configured\"}")
        }
        let nonce = Self.randomHex(16)
        let safeReturn = Self.sanitizeReturnTo(returnTo)
        let state = Self.signSocialAuthState(SocialAuthState(
            provider: provider,
            mode: "login",
            nonce: nonce,
            kind: "web",
            mobileRequestId: "",
            desktopNonce: nil,
            returnTo: safeReturn
        ))
        let url = webAuthorizationURL(provider: provider, state: state, nonce: nonce)
        return Self.redirect(url, cookie: stateCookie(provider: provider, nonce: nonce))
    }

    /// `POST /api/auth/:provider/link/start`. The bearer is required before the web gate is checked.
    public func startWebOAuthLink(provider: String, body: String, authorization: String?) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard webProviderAvailable(provider) else {
            return Self.json(404, "{\"error\":\"\(Self.providerLabel(provider)) sign-in is not configured\"}")
        }
        let returnTo = Self.returnToField(body)
        let nonce = Self.randomHex(16)
        let safeReturn = Self.sanitizeReturnTo(returnTo)
        let state = Self.signSocialAuthState(SocialAuthState(
            provider: provider,
            mode: "link",
            nonce: nonce,
            kind: "web",
            mobileRequestId: "",
            desktopNonce: nil,
            returnTo: safeReturn,
            linkUserId: userId
        ))
        let url = webAuthorizationURL(provider: provider, state: state, nonce: nonce)
        let payload = "{\"url\":\(jsonString(url))}"
        return Self.json(200, payload, cookie: stateCookie(provider: provider, nonce: nonce))
    }

    /// `POST /api/auth/:provider/callback`. A cancelled Apple form post redirects back with that error.
    public func webOAuthCallback(provider: String, body: String, cookie: String?) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let fields = Self.formFields(body)
        if let stateToken = fields["state"],
           let parsed = Self.verifySocialAuthState(stateToken),
           parsed.kind == "mobile" {
            return mobileOAuthCallback(
                provider: provider,
                code: fields["code"],
                state: stateToken,
                providerError: fields["error"]
            )
        }
        let invalid = Self.socialCallbackURL(
            appURL: appURL,
            provider: provider,
            mode: "login",
            returnTo: "/",
            error: "This sign-in link is invalid or expired. Please try again."
        )
        guard let stateToken = fields["state"],
              let state = Self.verifySocialAuthState(stateToken),
              state.kind != "mobile",
              state.provider == provider,
              state.mode == "login" || state.mode == "link"
        else {
            return Self.redirect(invalid)
        }
        if state.mode == "login" {
            let nonce = Self.cookieValue(cookie, name: "slock_\(provider)_oauth_nonce")
            if nonce != state.nonce {
                return Self.redirect(invalid)
            }
        }
        let code = fields["code"] ?? ""
        if code.isEmpty {
            let provided = fields["error"] ?? ""
            let error = provided.isEmpty ? "\(Self.providerLabel(provider)) sign-in was cancelled" : provided
            return Self.redirect(Self.socialCallbackURL(
                appURL: appURL,
                provider: provider,
                mode: state.mode,
                returnTo: state.returnTo ?? "/",
                error: error
            ))
        }
        guard state.mode == "link",
              let linkUserId = state.linkUserId,
              let profile = webProviderProfile,
              !profile.providerUserId.isEmpty,
              !profile.email.isEmpty
        else {
            return Self.redirect(invalid)
        }
        if !profile.emailVerified {
            return Self.redirect(Self.socialCallbackURL(
                appURL: appURL,
                provider: provider,
                mode: state.mode,
                returnTo: state.returnTo ?? "/",
                error: "\(provider) account email is not verified"
            ))
        }
        let completionCode = Self.randomHex(32)
        lock.lock()
        socialCompletions.append(SocialCompletion(
            provider: provider,
            code: completionCode,
            mode: "link",
            intendedAction: "link",
            email: Self.normalize(profile.email),
            returnTo: state.returnTo ?? "/",
            userId: linkUserId,
            providerUserId: profile.providerUserId
        ))
        lock.unlock()
        return Self.redirect(Self.socialCallbackURL(
            appURL: appURL,
            provider: provider,
            mode: "link",
            returnTo: state.returnTo ?? "/",
            code: completionCode
        ))
    }

    /// `POST /api/auth/mobile/oauth/apple/native/start`. No browser URL is returned. Link mode requires the owner before a row is written.
    public func startNativeApple(body: String, authorization: String? = nil) -> HTTPReply {
        guard nativeAppleAvailable() else { return Self.appleNotConfigured }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.nativeAppleInvalidRequest
        }
        let platform = object["platform"] as? String
        let appEnv = (object["appEnv"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard platform == "ios", !appEnv.isEmpty else { return Self.nativeAppleInvalidRequest }
        guard object["codeChallengeMethod"] as? String == "S256" else {
            return Self.json(400, "{\"code\":\"invalid_request\",\"error\":\"Native Apple sign-in requires an S256 challenge\"}")
        }
        guard let mode = object["mode"] as? String, mode == "login" || mode == "link" else {
            return Self.nativeAppleInvalidCredential
        }
        let linkUserId: String?
        if mode == "link" {
            switch authorize(authorization) {
            case .rejected:
                return Self.nativeAppleAuthRequired
            case .user(let id):
                linkUserId = id
            }
        } else {
            linkUserId = nil
        }
        guard let returnUri = object["returnUri"] as? String,
              Self.isDesktopLoopback(returnUri) || configuredMobileReturnURIs().contains(returnUri),
              let challenge = object["codeChallenge"] as? String,
              challenge.wholeMatch(of: /^[A-Za-z0-9_-]{32,256}$/) != nil
        else {
            return Self.nativeAppleInvalidCredential
        }
        let id = UUID().uuidString.lowercased()
        let expiresAt = Date(timeIntervalSinceNow: 600)
        lock.lock()
        mobileRequests[id] = MobileOAuthRequest(
            id: id,
            provider: "apple",
            mode: mode,
            status: "pending_provider",
            codeChallenge: challenge,
            returnUri: returnUri,
            nonce: "",
            expiresAt: expiresAt,
            userId: linkUserId
        )
        lock.unlock()
        let token = Self.signNativeAppleRequestToken(
            secret: nativeAppleStateSecret,
            requestId: id,
            mode: mode,
            codeChallenge: challenge,
            expiresAt: expiresAt,
            userId: linkUserId
        )
        let expires = ISO8601DateFormatter().string(from: expiresAt)
        let response = "{\"requestId\":\(jsonString(id)),\"requestToken\":\(jsonString(token)),\"returnUri\":\(jsonString(returnUri)),\"expiresAt\":\(jsonString(expires))}"
        return Self.json(201, response)
    }

    /// `POST /api/auth/mobile/oauth/apple/native/authorize`. Both the supplied identity token and the exchanged code must agree before a handoff exists.
    /// Link mode checks the owner before the row is claimed. The row is claimed as `provider_processing` before the code exchange, so a second caller is already consumed.
    public func authorizeNativeApple(body: String, authorization: String? = nil) async -> HTTPReply {
        guard nativeAppleAvailable() else { return Self.appleNotConfigured }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestId = object["requestId"] as? String, !requestId.isEmpty,
              let requestToken = object["requestToken"] as? String, !requestToken.isEmpty,
              let authorizationCode = object["authorizationCode"] as? String, !authorizationCode.isEmpty,
              let identityToken = object["identityToken"] as? String, !identityToken.isEmpty
        else {
            return Self.nativeAppleInvalidCredential
        }
        let claims: NativeAppleRequestClaims
        switch Self.verifyNativeAppleRequestToken(requestToken, secret: nativeAppleStateSecret) {
        case .expired:
            return Self.nativeAppleRequestExpired
        case .invalid:
            return Self.nativeAppleInvalidCredential
        case .valid(let parsed):
            claims = parsed
        }
        guard claims.requestId == requestId else { return Self.nativeAppleInvalidCredential }
        let callerId: String?
        if case .user(let id) = authorize(authorization) {
            callerId = id
        } else {
            callerId = nil
        }
        let challenge: String
        switch claimNativeApple(
            requestId: requestId,
            mode: claims.mode,
            codeChallenge: claims.codeChallenge,
            tokenUserId: claims.userId,
            callerId: callerId
        ) {
        case .missing:
            return Self.nativeAppleInvalidCredential
        case .authRequired:
            return Self.nativeAppleAuthRequired
        case .userMismatch:
            return Self.nativeAppleLinkMismatch
        case .expired:
            return Self.nativeAppleRequestExpired
        case .consumed:
            return Self.nativeAppleRequestConsumed
        case .claimed(let storedChallenge):
            challenge = storedChallenge
        }

        let exchange = NativeAppleCodeExchange(
            code: authorizationCode,
            clientId: nativeAppleClientId,
            clientSecret: nativeAppleClientSecret,
            grantType: "authorization_code",
            redirectUri: nil
        )
        let exchangedToken = await exchangeNativeAppleCode?(exchange)
        guard let exchangedToken, !exchangedToken.isEmpty,
              let supplied = parseAppleIdentity(identityToken),
              let exchanged = parseAppleIdentity(exchangedToken),
              supplied.subject == exchanged.subject,
              supplied.nonce == challenge,
              exchanged.nonce == challenge
        else {
            failNativeAppleIfProcessing(requestId: requestId)
            return Self.nativeAppleInvalidCredential
        }
        if let left = supplied.email, let right = exchanged.email, left != right {
            failNativeAppleIfProcessing(requestId: requestId)
            return Self.nativeAppleInvalidCredential
        }
        let stored = storedAppleIdentity(subject: supplied.subject)
        guard let email = supplied.email ?? exchanged.email ?? stored?.email else {
            failNativeAppleIfProcessing(requestId: requestId)
            return Self.nativeAppleInvalidCredential
        }
        let loginUserId = claims.mode == "login" ? stored?.userId : nil
        guard let completed = finishNativeApple(
            requestId: requestId,
            email: email,
            subject: supplied.subject,
            loginUserId: loginUserId
        ) else {
            failNativeAppleIfProcessing(requestId: requestId)
            return Self.nativeAppleInvalidCredential
        }
        let response = "{\"requestId\":\(jsonString(requestId)),\"handoffCode\":\(jsonString(completed.handoff)),\"provider\":\"apple\",\"mode\":\(jsonString(completed.mode))}"
        return Self.json(200, response)
    }

    private enum NativeAppleClaim {
        case missing
        case authRequired
        case userMismatch
        case expired
        case consumed
        case claimed(String)
    }

    /// Moves `pending_provider` to `provider_processing` before any Apple call. A past row expiry and a link-owner mismatch are decided before that claim.
    private func claimNativeApple(
        requestId: String,
        mode: String,
        codeChallenge: String,
        tokenUserId: String?,
        callerId: String?
    ) -> NativeAppleClaim {
        lock.lock()
        defer { lock.unlock() }
        guard var request = mobileRequests[requestId],
              request.provider == "apple",
              request.mode == mode,
              request.codeChallenge == codeChallenge,
              request.userId == tokenUserId
        else { return .missing }
        if request.mode == "link" {
            guard let callerId else { return .authRequired }
            guard request.userId == callerId else { return .userMismatch }
        }
        if request.expiresAt < Date() {
            request.status = "expired"
            mobileRequests[requestId] = request
            return .expired
        }
        guard request.status == "pending_provider" else { return .consumed }
        request.status = "provider_processing"
        mobileRequests[requestId] = request
        return .claimed(request.codeChallenge)
    }

    /// A previously linked Apple subject can supply the verified email Apple omits on a later login.
    private func storedAppleIdentity(subject: String) -> (userId: String, email: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = linkedIdentities.first(where: { $0.provider == "apple" && $0.providerUserId == subject }) else {
            return nil
        }
        let email = row.providerEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !email.isEmpty else { return nil }
        return (row.userId, email)
    }

    private func failNativeAppleIfProcessing(requestId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var request = mobileRequests[requestId], request.status == "provider_processing" else { return }
        request.status = "failed"
        mobileRequests[requestId] = request
    }

    private func finishNativeApple(requestId: String, email: String, subject: String, loginUserId: String?) -> (handoff: String, mode: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard var request = mobileRequests[requestId], request.status == "provider_processing" else { return nil }
        let handoff = Self.randomHex(32)
        request.status = "provider_completed"
        request.handoffCode = handoff
        request.codeHash = Self.sha256(handoff)
        request.profileEmail = email
        request.profileUserId = subject
        if request.mode == "login" {
            request.userId = loginUserId
        }
        let mode = request.mode
        mobileRequests[requestId] = request
        return (handoff, mode)
    }

    /// `POST /api/auth/mobile/oauth/:provider/link/start`. The bearer is required before a request row is written.
    public func startMobileOAuthLink(provider: String, body: String, authorization: String?) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth start\"}")
        }
        guard let returnUri = object["returnUri"] as? String,
              Self.isDesktopLoopback(returnUri) || configuredMobileReturnURIs().contains(returnUri)
        else {
            return Self.returnURINotAllowed
        }
        guard let challenge = object["codeChallenge"] as? String,
              challenge.wholeMatch(of: /^[A-Za-z0-9_-]{32,256}$/) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth start\"}")
        }
        return openedMobileOAuth(provider: provider, mode: "link", returnUri: returnUri, challenge: challenge, userId: userId)
    }

    private func openedMobileOAuth(provider: String, mode: String, returnUri: String, challenge: String, userId: String?) -> HTTPReply {
        let id = UUID().uuidString.lowercased()
        let nonce = Self.randomHex(16)
        let desktopNonce = Self.desktopNonce(from: returnUri)
        lock.lock()
        mobileRequests[id] = MobileOAuthRequest(
            id: id,
            provider: provider,
            mode: mode,
            status: "pending_provider",
            codeChallenge: challenge,
            returnUri: returnUri,
            nonce: nonce,
            expiresAt: Date(timeIntervalSinceNow: 600),
            userId: userId
        )
        lock.unlock()
        let state = Self.signSocialAuthState(SocialAuthState(
            provider: provider,
            mode: mode,
            nonce: nonce,
            kind: "mobile",
            mobileRequestId: id,
            desktopNonce: desktopNonce
        ))
        let authorizationUrl = Self.authorizationURL(provider: provider, state: state)
        let expires = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: 600))
        let response = "{\"requestId\":\(jsonString(id)),\"authorizationUrl\":\(jsonString(authorizationUrl)),\"returnUri\":\(jsonString(returnUri)),\"expiresAt\":\(jsonString(expires))}"
        return Self.json(201, response)
    }

    /// `GET /api/auth/:provider/callback`. A desktop nonce that does not match the stored return URI is refused before any provider exchange.
    public func mobileOAuthCallback(provider: String, code: String?, state: String?, providerError: String? = nil) -> HTTPReply {
        guard let state, let parsed = Self.verifySocialAuthState(state),
              parsed.kind == "mobile", parsed.provider == provider
        else {
            return Self.text(400, "Invalid mobile OAuth request")
        }
        lock.lock()
        guard var request = mobileRequests[parsed.mobileRequestId],
              request.provider == provider,
              request.mode == parsed.mode,
              !request.codeChallenge.isEmpty
        else {
            lock.unlock()
            return Self.text(400, "Invalid mobile OAuth request")
        }
        let expected = Self.desktopNonce(from: request.returnUri)
        if expected != parsed.desktopNonce {
            lock.unlock()
            return Self.text(400, "Invalid mobile OAuth request")
        }
        if code == nil || code?.isEmpty == true {
            let error = (providerError?.isEmpty == false) ? providerError! : "provider_cancelled"
            request.status = "failed"
            let returnUri = request.returnUri
            let mode = request.mode
            mobileRequests[parsed.mobileRequestId] = request
            lock.unlock()
            return Self.redirect(Self.failureLocation(returnUri: returnUri, provider: provider, mode: mode, error: error))
        }
        guard let profile = mobileProviderProfile, profile.emailVerified else {
            request.status = "failed"
            let returnUri = request.returnUri
            let mode = request.mode
            mobileRequests[parsed.mobileRequestId] = request
            lock.unlock()
            return Self.redirect(Self.failureLocation(
                returnUri: returnUri,
                provider: provider,
                mode: mode,
                error: "provider_exchange_failed"
            ))
        }
        providerExchanges += 1
        let handoff = Self.randomHex(32)
        request.status = "provider_completed"
        request.handoffCode = handoff
        request.codeHash = Self.sha256(handoff)
        request.profileEmail = Self.normalize(profile.email)
        request.profileUserId = profile.providerUserId
        request.profileName = profile.displayName
        let returnUri = request.returnUri
        let mode = request.mode
        mobileRequests[parsed.mobileRequestId] = request
        lock.unlock()
        return Self.redirect(Self.loopbackLocation(returnUri: returnUri, provider: provider, mode: mode, code: handoff))
    }

    /// `POST /api/auth/mobile/oauth/complete`. The handoff code is spent only after the PKCE verifier matches.
    public func completeMobileOAuth(body: String) -> HTTPReply {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        lock.lock()
        if consumedHandoffs.contains(code) {
            lock.unlock()
            return Self.json(410, "{\"code\":\"handoff_code_consumed\"}")
        }
        guard let requestId = mobileRequests.first(where: { $0.value.handoffCode == code })?.key,
              var request = mobileRequests[requestId],
              request.status == "provider_completed"
        else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        if request.expiresAt < Date() {
            request.status = "expired"
            mobileRequests[requestId] = request
            lock.unlock()
            return Self.json(410, "{\"code\":\"handoff_code_expired\",\"error\":\"Mobile OAuth code has expired\"}")
        }
        let verifier = object["codeVerifier"] as? String ?? ""
        if verifier.isEmpty {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        if Self.pkceS256(verifier) != request.codeChallenge {
            request.status = "failed"
            mobileRequests[requestId] = request
            lock.unlock()
            return Self.json(400, "{\"code\":\"pkce_mismatch\",\"error\":\"PKCE verifier did not match the OAuth request\"}")
        }
        if request.mode == "login", let existingId = request.userId {
            guard let account = accounts.values.first(where: { $0.id == existingId }) else {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
            }
            let accessToken = Self.token()
            let refreshToken = Self.token()
            sessions[refreshToken] = LiveSession(userId: account.id, familyId: UUID().uuidString.lowercased())
            accessTokens[accessToken] = account.id
            request.status = "completed"
            request.handoffCode = nil
            mobileRequests[requestId] = request
            consumedHandoffs.insert(code)
            let returnUri = request.returnUri
            let mode = request.mode
            let provider = request.provider
            lock.unlock()
            let user = "{\"id\":\(jsonString(account.id)),\"email\":\(jsonString(account.email)),\"name\":\(jsonString(account.name)),\"profileSetupCompletedAt\":null,\"profileSetupProvider\":\(jsonString(provider))}"
            let response = "{\"user\":\(user),\"accessToken\":\(jsonString(accessToken)),\"refreshToken\":\(jsonString(refreshToken)),\"mode\":\(jsonString(mode)),\"returnUri\":\(jsonString(returnUri))}"
            return Self.json(200, response)
        }
        if object["acceptTerms"] as? Bool != true {
            lock.unlock()
            return Self.legalRequired
        }
        let terms = object["termsVersion"] as? String
        let privacy = object["privacyVersion"] as? String
        if terms != Self.termsVersion || privacy != Self.privacyVersion {
            lock.unlock()
            return Self.termsChanged
        }
        let email = request.profileEmail ?? ""
        guard !email.isEmpty else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        let taken = Set(accounts.values.map(\.name))
        let pendingName = Self.pendingHandle(taken: taken)
        let id = UUID().uuidString.lowercased()
        accounts[email] = Account(
            id: id,
            email: email,
            passwordHash: Self.sha256(Self.token()),
            displayLanguage: nil,
            name: pendingName,
            profileSetupSuggestedHandle: Self.availableUserName(seed: request.profileName ?? email, taken: taken),
            profileSetupProvider: request.provider
        )
        legalAcceptances[id] = EmailLegalAcceptance(
            termsVersion: Self.termsVersion,
            privacyVersion: Self.privacyVersion,
            termsUrl: Self.termsURL,
            privacyUrl: Self.privacyURL,
            source: "oauth",
            userAgentHash: nil,
            locale: nil
        )
        let accessToken = Self.token()
        let refreshToken = Self.token()
        sessions[refreshToken] = LiveSession(userId: id, familyId: UUID().uuidString.lowercased())
        accessTokens[accessToken] = id
        let providerUserId = request.profileUserId ?? ""
        if !providerUserId.isEmpty, !linkedIdentities.contains(where: {
            $0.userId == id && $0.provider == request.provider && $0.providerUserId == providerUserId
        }) {
            linkedIdentities.append(LinkedIdentity(
                userId: id,
                provider: request.provider,
                providerUserId: providerUserId
            ))
        }
        request.status = "completed"
        request.handoffCode = nil
        mobileRequests[requestId] = request
        consumedHandoffs.insert(code)
        let returnUri = request.returnUri
        let mode = request.mode
        let provider = request.provider
        lock.unlock()
        let user = "{\"id\":\(jsonString(id)),\"email\":\(jsonString(email)),\"name\":\(jsonString(pendingName)),\"profileSetupCompletedAt\":null,\"profileSetupProvider\":\(jsonString(provider))}"
        let response = "{\"user\":\(user),\"accessToken\":\(jsonString(accessToken)),\"refreshToken\":\(jsonString(refreshToken)),\"mode\":\(jsonString(mode)),\"returnUri\":\(jsonString(returnUri))}"
        return Self.json(200, response)
    }

    /// `POST /api/auth/mobile/oauth/:provider/link/complete`. A different account is refused before the handoff is spent.
    public func completeMobileOAuthLink(provider: String, body: String, authorization: String?) -> HTTPReply {
        guard Self.socialProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let caller: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            caller = id
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        let verifier = object["codeVerifier"] as? String ?? ""
        lock.lock()
        if consumedHandoffs.contains(code) {
            lock.unlock()
            return Self.json(410, "{\"code\":\"handoff_code_consumed\"}")
        }
        guard let requestId = mobileRequests.first(where: { $0.value.handoffCode == code })?.key,
              var request = mobileRequests[requestId],
              request.status == "provider_completed"
        else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        if request.expiresAt < Date() {
            request.status = "expired"
            mobileRequests[requestId] = request
            lock.unlock()
            return Self.json(410, "{\"code\":\"handoff_code_expired\",\"error\":\"Mobile OAuth code has expired\"}")
        }
        if verifier.isEmpty {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid mobile OAuth completion\"}")
        }
        if Self.pkceS256(verifier) != request.codeChallenge {
            request.status = "failed"
            mobileRequests[requestId] = request
            lock.unlock()
            return Self.json(400, "{\"code\":\"pkce_mismatch\",\"error\":\"PKCE verifier did not match the OAuth request\"}")
        }
        if request.provider != provider {
            lock.unlock()
            return Self.json(400, "{\"code\":\"provider_mismatch\",\"error\":\"Mobile OAuth code does not match the requested provider\"}")
        }
        if request.mode != "link" {
            lock.unlock()
            return Self.json(400, "{\"code\":\"mode_mismatch\",\"error\":\"Mobile OAuth code does not match the requested mode\"}")
        }
        guard request.userId == caller else {
            lock.unlock()
            return Self.mobileLinkMismatch
        }
        let providerUserId = request.profileUserId ?? ""
        let providerEmail = request.profileEmail ?? ""
        if !linkedIdentities.contains(where: {
            $0.userId == caller && $0.provider == provider && $0.providerUserId == providerUserId
        }) {
            linkedIdentities.append(LinkedIdentity(
                userId: caller,
                provider: provider,
                providerUserId: providerUserId,
                providerEmail: providerEmail
            ))
        }
        request.status = "completed"
        request.handoffCode = nil
        mobileRequests[requestId] = request
        consumedHandoffs.insert(code)
        let returnUri = request.returnUri
        let listed = linkedIdentities.filter { $0.userId == caller }.map {
            "{\"provider\":\(jsonString($0.provider)),\"providerEmail\":\(jsonString($0.providerEmail ?? ""))}"
        }.joined(separator: ",")
        lock.unlock()
        let response = "{\"provider\":\(jsonString(provider)),\"mode\":\"link\",\"returnUri\":\(jsonString(returnUri)),\"identities\":[\(listed)]}"
        return Self.json(200, response)
    }

    /// `POST /api/feature-flags/evaluate`. Admin flag routes are not mounted. An empty key list is rejected before any flag read.
    public func createFeatureFlagForTesting(
        key: String,
        defaultEnabled: Bool = false,
        enabled: Bool = true,
        killSwitch: Bool = false
    ) {
        lock.lock()
        featureFlagRecords[key] = FeatureFlagRecord(
            key: key,
            enabled: enabled,
            killSwitch: killSwitch,
            defaultEnabled: defaultEnabled
        )
        lock.unlock()
    }

    public func addFeatureFlagRuleForTesting(
        key: String,
        stage: String,
        decision: String,
        values: [String],
        clientOs: [String]? = nil,
        minClientBuild: Int? = nil,
        clientBuildTypes: [String]? = nil,
        priority: Int = 0
    ) {
        lock.lock()
        featureFlagRuleRecords.append(FeatureFlagRuleRecord(
            key: key,
            stage: stage,
            decision: decision,
            values: values,
            clientOs: clientOs,
            minClientBuild: minClientBuild,
            clientBuildTypes: clientBuildTypes,
            priority: priority
        ))
        lock.unlock()
    }

    public func setFeatureFlagKillSwitchForTesting(key: String, killSwitch: Bool) {
        lock.lock()
        featureFlagRecords[key]?.killSwitch = killSwitch
        lock.unlock()
    }

    private struct FeatureFlagClientFacts {
        var os: String?
        var buildNumber: Int?
        var buildType: String?
    }

    private static func featureFlagClientFacts(_ object: [String: Any]) -> FeatureFlagClientFacts {
        let osValues: Set<String> = ["android", "ios", "ohos"]
        let buildTypes: Set<String> = ["release", "alpha", "debug"]
        let os = (object["os"] as? String).flatMap { osValues.contains($0) ? $0 : nil }
        let buildType = (object["buildType"] as? String).flatMap { buildTypes.contains($0) ? $0 : nil }
        var buildNumber: Int?
        if let raw = object["buildNumber"] {
            if let string = raw as? String, string.range(of: "^[0-9]{1,15}$", options: .regularExpression) != nil {
                buildNumber = Int(string)
            } else if let number = raw as? NSNumber,
                      String(cString: number.objCType) != "c",
                      String(cString: number.objCType) != "B",
                      number.doubleValue >= 0,
                      number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue <= Double(Int.max) {
                buildNumber = number.intValue
            }
        }
        return FeatureFlagClientFacts(os: os, buildNumber: buildNumber, buildType: buildType)
    }

    private func featureFlagRules(key: String, stage: String) -> [FeatureFlagRuleRecord] {
        featureFlagRuleRecords
            .filter { $0.key == key && $0.stage == stage }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private func featureFlagRuleReply(key: String, rule: FeatureFlagRuleRecord, stage: String) -> HTTPReply {
        Self.json(200, "{\"evaluations\":[{\"key\":\(jsonString(key)),\"enabled\":\(rule.decision == "allow"),\"reason\":\(jsonString(stage + "_rule"))}]}")
    }

    private func evaluateFeatureFlagKey(
        key: String,
        userId: String,
        serverId: String?,
        platform: String?,
        client: FeatureFlagClientFacts
    ) -> (enabled: Bool, reason: String) {
        guard let flag = featureFlagRecords[key] else {
            return (false, "missing_flag")
        }
        if flag.killSwitch { return (false, "kill_switch") }
        if !flag.enabled { return (false, "flag_disabled") }
        if let rule = featureFlagRules(key: key, stage: "user").first(where: { $0.values.contains(userId) }) {
            return (rule.decision == "allow", "user_rule")
        }
        if let platform,
           let rule = featureFlagRules(key: key, stage: "platform").first(where: { $0.values.contains(platform) }) {
            return (rule.decision == "allow", "platform_rule")
        }
        if let serverId {
            for rule in featureFlagRules(key: key, stage: "client") where rule.values.contains(serverId) {
                let hasConstraint = rule.clientOs != nil || rule.minClientBuild != nil || rule.clientBuildTypes != nil
                guard hasConstraint else { continue }
                if let clientOs = rule.clientOs {
                    guard let os = client.os, clientOs.contains(os) else { continue }
                }
                if let buildTypes = rule.clientBuildTypes {
                    guard let buildType = client.buildType, buildTypes.contains(buildType) else { continue }
                }
                if let minimum = rule.minClientBuild {
                    guard let buildNumber = client.buildNumber, buildNumber >= minimum else { continue }
                }
                return (rule.decision == "allow", "client_rule")
            }
        }
        if let serverId,
           let rule = featureFlagRules(key: key, stage: "server").first(where: { $0.values.contains(serverId) }) {
            return (rule.decision == "allow", "server_rule")
        }
        return (flag.defaultEnabled, "default")
    }

    /// `POST /api/feature-flags/evaluate`. Admin flag routes are not mounted.
    public func evaluateFeatureFlags(body: String, authorization: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let rawKeys: [Any]
        if let keys = object["keys"] as? [Any] {
            rawKeys = keys
        } else if let key = object["key"] as? String {
            rawKeys = [key]
        } else {
            rawKeys = []
        }
        let parsed = rawKeys.map { Self.featureFlagKey($0) }
        if parsed.isEmpty || parsed.count > 50 || parsed.contains(where: { $0 == nil }) {
            return Self.json(400, "{\"error\":\"keys must contain 1-50 valid feature flag keys\"}")
        }
        var serverId: String?
        if let rawServerId = object["serverId"], !(rawServerId is NSNull) {
            guard let value = rawServerId as? String, ServerScope.isUUID(value) else {
                return Self.json(400, "{\"error\":\"serverId must be a valid UUID\"}")
            }
            serverId = value
        }
        if let serverId, oauth.memberRole(serverId: serverId, userId: userId) == nil {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        var platform: String?
        if let rawPlatform = object["platform"], !(rawPlatform is NSNull) {
            guard let value = rawPlatform as? String, value == "web" || value == "mobile" else {
                return Self.json(400, "{\"error\":\"platform must be web or mobile\"}")
            }
            platform = value
        }
        let client = Self.featureFlagClientFacts(object)
        let unique = parsed.compactMap { $0 }.reduce(into: [String]()) { list, key in
            if !list.contains(key) { list.append(key) }
        }
        lock.lock()
        let evaluations = unique.map { key -> String in
            let result = evaluateFeatureFlagKey(key: key, userId: userId, serverId: serverId, platform: platform, client: client)
            return "{\"key\":\(jsonString(key)),\"enabled\":\(result.enabled),\"reason\":\(jsonString(result.reason))}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"evaluations\":[\(evaluations)]}")
    }

    /// Records a channel the owner can post in. Resource-reference checks run only after this membership is visible.
    public func addPostableChannel(serverId: String, channelId: String, memberId: String, kind: String = "channel", parentChannelId: String? = nil, parentMessageId: String? = nil, name: String? = nil) {
        lock.lock()
        var channel = postableChannels[channelId] ?? PostableChannel(serverId: serverId, memberIds: [])
        channel.serverId = serverId
        channel.memberIds.insert(memberId)
        if channel.kind == "channel" || kind != "channel" {
            channel.kind = kind
        }
        if let parentChannelId {
            channel.parentChannelId = parentChannelId
        }
        if let parentMessageId {
            channel.parentMessageId = parentMessageId
        }
        if let name {
            channel.name = name
        }
        postableChannels[channelId] = channel
        lock.unlock()
    }

    /// Server role used by the hidden human directory. Only `member` is hidden on #all.
    public func setServerMemberRole(serverId: String, userId: String, role: String) {
        lock.lock()
        serverMemberRoles["\(serverId)\n\(userId)"] = role
        lock.unlock()
    }

    public func setHideHumansFromMembers(serverId: String, hidden: Bool) {
        lock.lock()
        hideHumansFromMembers[serverId] = hidden
        lock.unlock()
    }

    /// Links a server's local joint channel to the canonical channel that stores the messages.
    public func addJointChannelProjection(localChannelId: String, canonicalChannelId: String, serverId: String) {
        lock.lock()
        jointProjections.append(JointChannelLink(localChannelId: localChannelId, canonicalChannelId: canonicalChannelId, serverId: serverId))
        lock.unlock()
    }

    /// A thread whose messages hang off one parent message. Context short links on the parent channel can land here.
    public func addThreadChannel(serverId: String, threadChannelId: String, parentChannelId: String, parentMessageId: String, memberId: String) {
        lock.lock()
        var channel = postableChannels[threadChannelId] ?? PostableChannel(serverId: serverId, memberIds: [])
        channel.serverId = serverId
        channel.memberIds.insert(memberId)
        channel.kind = "thread"
        channel.parentChannelId = parentChannelId
        channel.parentMessageId = parentMessageId
        postableChannels[threadChannelId] = channel
        lock.unlock()
    }

    /// A user-to-user DM. Only the two participants may be notified by a mention.
    public func addDirectMessage(serverId: String, channelId: String, participantIds: [String], agentId: String? = nil) {
        lock.lock()
        postableChannels[channelId] = PostableChannel(serverId: serverId, memberIds: Set(participantIds), kind: "dm", agentId: agentId)
        lock.unlock()
    }

    private enum SearchViewer {
        case user(String)
        case agent(String)
    }

    /// A public channel is searchable by anyone on the server. A thread follows its parent, and a deleted parent hides the thread. Archived channels stay searchable.
    private func messageSearchVisibleLocked(messageChannelId: String, serverId: String?, viewer: SearchViewer) -> Bool {
        func isMember(_ id: String, _ channel: PostableChannel) -> Bool {
            switch viewer {
            case .user(let userId):
                return channel.memberIds.contains(userId)
            case .agent(let agentId):
                return channelAgentMembers[id]?.contains(agentId) == true
            }
        }
        guard let channel = postableChannels[messageChannelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else { return false }
        if channel.kind == "thread" {
            guard let parentId = channel.parentChannelId,
                  let parent = postableChannels[parentId],
                  parent.serverId == serverId,
                  parent.deletedAt == nil
            else { return false }
            return parent.kind == "channel" || isMember(parentId, parent) || isMember(messageChannelId, channel)
        }
        return channel.kind == "channel" || isMember(messageChannelId, channel)
    }

    /// `DELETE /api/channels/:channelId`. A member soft-deletes the channel. Search then hides it and threads under it.
    public func deleteChannel(channelId: String, authorization: String?, serverId: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        lock.lock()
        guard var channel = postableChannels[channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let role = oauth.memberRole(serverId: serverId ?? "", userId: userId) {
            guard role == "owner" || role == "admin" else {
                lock.unlock()
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
        } else if !channel.memberIds.contains(userId) {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        channel.deletedAt = Date()
        postableChannels[channelId] = channel
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    /// `GET /internal/agent/:agentId/search`. The machine key must belong to that agent. Public channels on its server are visible.
    public func searchAgentMessages(agentId: String, query: String?, limit: String?, authorization: String?) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        let pageLimit: Int
        if let limit, let parsed = Int(limit), parsed > 0 {
            pageLimit = min(parsed, 100)
        } else {
            pageLimit = 20
        }
        let queryTokens = Self.searchTokens((query ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        guard !queryTokens.isEmpty else {
            return Self.json(200, "{\"results\":[],\"hasMore\":false}")
        }
        lock.lock()
        guard let machine = machineKeys[token], machine.agentId == agentId else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let serverId = machine.serverId
        var strict: [(StoredHumanMessage, Int)] = []
        var relaxed: [(StoredHumanMessage, Int)] = []
        for message in humanMessageRows where messageSearchVisibleLocked(messageChannelId: message.channelId, serverId: serverId, viewer: .agent(agentId)) {
            let counts = Self.tokenCounts(message.content)
            if let score = Self.matchScore(counts, queryTokens, requireAll: true) {
                strict.append((message, score))
            } else if queryTokens.count > 1, let score = Self.matchScore(counts, queryTokens, requireAll: false) {
                relaxed.append((message, score))
            }
        }
        let fallbackUsed = strict.isEmpty && !relaxed.isEmpty
        var hits = fallbackUsed ? relaxed : strict
        hits.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.createdAt > rhs.0.createdAt
        }
        let hasMore = !fallbackUsed && hits.count > pageLimit
        let page = hits.prefix(pageLimit)
        let results = page.map { pair in
            let message = pair.0
            let channel = postableChannels[message.channelId]
            let parentId = (channel?.kind == "thread" ? channel?.parentChannelId : nil) ?? message.channelId
            let snippet = Self.searchSnippet(message.content)
            let archivedJSON: String
            if let archivedAt = oauth.channelArchivedAt(id: parentId) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                archivedJSON = jsonString(formatter.string(from: archivedAt))
            } else {
                archivedJSON = "null"
            }
            return "{\"id\":\(jsonString(message.id)),\"senderId\":\(jsonString(message.senderId)),\"senderType\":\(jsonString(message.senderType)),\"channelId\":\(jsonString(message.channelId)),\"parentChannelId\":\(jsonString(parentId)),\"content\":\(jsonString(message.content)),\"snippet\":\(jsonString(snippet)),\"channelArchivedAt\":\(archivedJSON)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"results\":[\(results)],\"hasMore\":\(hasMore ? "true" : "false")}")
    }

    /// `GET /api/messages/search`. Relevance ranks by how often `q` appears. `sort=recent` uses `createdAt`.
    public func searchHumanMessages(query: String?, sort: String?, limit: String?, authorization: String?, serverId: String?, channelId: String? = nil, senderId: String? = nil, senderType: String? = nil, mentionTarget: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        let sortMode: String
        if let sort, !sort.isEmpty {
            guard sort == "relevance" || sort == "recent" else {
                return Self.json(400, "{\"error\":\"Invalid search sort\"}")
            }
            sortMode = sort
        } else {
            sortMode = "relevance"
        }
        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pageLimit: Int
        if let limit, let parsed = Int(limit), parsed > 0 {
            pageLimit = min(parsed, 100)
        } else {
            pageLimit = 20
        }
        let scopedSenderType: String?
        if let senderType, !senderType.isEmpty {
            guard senderType == "user" || senderType == "agent" else {
                return Self.json(400, "{\"error\":\"Invalid sender type\"}")
            }
            scopedSenderType = senderType
        } else {
            scopedSenderType = nil
        }
        let mentionSelf: Bool
        if let mentionTarget, !mentionTarget.isEmpty {
            guard mentionTarget == "self" else {
                return Self.json(400, "{\"error\":\"Invalid mention target\"}")
            }
            mentionSelf = true
        } else {
            mentionSelf = false
        }
        let queryTokens = Self.searchTokens(needle)
        let scopedChannel = (channelId?.isEmpty == false) ? channelId : nil
        let scopedSender = (senderId?.isEmpty == false) ? senderId : nil
        if queryTokens.isEmpty && scopedChannel == nil && scopedSender == nil && scopedSenderType == nil && !mentionSelf {
            return Self.json(200, "{\"results\":[],\"hasMore\":false}")
        }
        let effectiveSort = queryTokens.isEmpty ? "recent" : sortMode
        lock.lock()
        if let scopedChannel {
            guard let channel = postableChannels[scopedChannel],
                  channel.serverId == serverId,
                  channel.deletedAt == nil,
                  channel.kind == "channel" || channel.memberIds.contains(userId)
            else {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
        }
        func accepts(_ message: StoredHumanMessage) -> Bool {
            guard messageSearchVisibleLocked(messageChannelId: message.channelId, serverId: serverId, viewer: .user(userId)) else { return false }
            if let scopedSender, message.senderId != scopedSender { return false }
            if let scopedSenderType, message.senderType != scopedSenderType { return false }
            if mentionSelf && !storedMentions.contains(where: { $0.messageId == message.id && $0.targetType == "user" && $0.targetId == userId }) {
                return false
            }
            if let scopedChannel {
                if message.channelId == scopedChannel { return true }
                let channel = postableChannels[message.channelId]
                return channel?.kind == "thread" && channel?.parentChannelId == scopedChannel
            }
            return true
        }
        var strict: [(StoredHumanMessage, Int)] = []
        var relaxed: [(StoredHumanMessage, Int)] = []
        var browse: [(StoredHumanMessage, Int)] = []
        for message in humanMessageRows where accepts(message) {
            if queryTokens.isEmpty {
                browse.append((message, 0))
                continue
            }
            let counts = Self.tokenCounts(message.content)
            if let score = Self.matchScore(counts, queryTokens, requireAll: true) {
                strict.append((message, score))
            } else if queryTokens.count > 1, let score = Self.matchScore(counts, queryTokens, requireAll: false) {
                relaxed.append((message, score))
            }
        }
        let fallbackUsed = !queryTokens.isEmpty && strict.isEmpty && !relaxed.isEmpty
        var hits = queryTokens.isEmpty ? browse : (fallbackUsed ? relaxed : strict)
        if effectiveSort == "recent" {
            hits.sort { $0.0.createdAt > $1.0.createdAt }
        } else {
            hits.sort { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.createdAt > rhs.0.createdAt
            }
        }
        let hasMore = !fallbackUsed && hits.count > pageLimit
        let page = hits.prefix(pageLimit)
        let results = page.map { pair in
            let message = pair.0
            let channel = postableChannels[message.channelId]
            let parentId = (channel?.kind == "thread" ? channel?.parentChannelId : nil) ?? message.channelId
            let snippet = Self.searchSnippet(message.content)
            let archivedJSON: String
            if let archivedAt = oauth.channelArchivedAt(id: parentId) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                archivedJSON = jsonString(formatter.string(from: archivedAt))
            } else {
                archivedJSON = "null"
            }
            return "{\"id\":\(jsonString(message.id)),\"senderId\":\(jsonString(message.senderId)),\"senderType\":\(jsonString(message.senderType)),\"channelId\":\(jsonString(message.channelId)),\"parentChannelId\":\(jsonString(parentId)),\"content\":\(jsonString(message.content)),\"snippet\":\(jsonString(snippet)),\"channelArchivedAt\":\(archivedJSON)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"results\":[\(results)],\"hasMore\":\(hasMore ? "true" : "false")}")
    }

    private static func searchSnippet(_ content: String) -> String {
        let compact = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if compact.count <= 180 { return compact }
        return String(compact.prefix(177)) + "..."
    }

    /// Latin words stay whole. Each CJK character is its own token, so a query that shares no full phrase can still match a character.
    private static func searchTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var latin = ""
        func flush() {
            let word = latin.lowercased()
            latin = ""
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            tokens.append(word)
        }
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                flush()
                tokens.append(String(scalar))
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                latin.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func tokenCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in searchTokens(text) {
            counts[token, default: 0] += 1
        }
        return counts
    }

    /// Strict mode requires every query token. Relaxed mode sums the tokens that do appear.
    private static func matchScore(_ counts: [String: Int], _ queryTokens: [String], requireAll: Bool) -> Int? {
        var total = 0
        for token in queryTokens {
            let count = counts[token] ?? 0
            if count == 0 {
                if requireAll { return nil }
                continue
            }
            total += count
        }
        return total > 0 ? total : nil
    }

    /// Context for a human message that is not in the permalink catalog. A DM short id resolves only for a participant.
    public func humanMessageContext(messageId: String, channelId: String?, authorization: String?, serverId: String?, before: String? = nil, after: String? = nil) -> HTTPReply? {
        guard MessageContext.isShortId(messageId) || ServerScope.isUUID(messageId) else { return nil }
        guard let channelId, ServerScope.isUUID(channelId) else { return nil }
        guard let userId = sessionUserId(authorization: authorization) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let channel = postableChannels[channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil,
              channel.kind == "channel" || channel.memberIds.contains(userId)
        else { return nil }
        let storageChannelId = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId ?? channelId
        let rows = humanMessageRows.filter { $0.channelId == storageChannelId || $0.channelId == channelId }
        let matches = rows.filter { Self.messageIdMatches($0.id, messageId) }
        if matches.count == 1, let message = matches.first, let index = rows.firstIndex(where: { $0.id == message.id }) {
            let beforeCount = Self.contextWindowSide(before)
            let afterCount = Self.contextWindowSide(after)
            let start = max(0, index - beforeCount)
            let end = min(rows.count, index + 1 + afterCount)
            let parts = rows[start..<end].map { row -> String in
                let seq = (rows.firstIndex { $0.id == row.id } ?? 0) + 1
                let metadata = forwardMetadataJSONLocked(messageId: row.id, userId: userId, serverId: serverId)
                var json = "{\"id\":\(jsonString(row.id)),\"channelId\":\(jsonString(channelId)),\"content\":\(jsonString(row.content)),\"seq\":\(seq)"
                if let metadata {
                    json += ",\"actionMetadata\":\(metadata)"
                }
                json += "}"
                return json
            }
            let windowIds = rows[start..<end].map(\.id)
            return Self.contextJSON(
                channelId: channelId,
                message: message,
                seq: index + 1,
                archived: channel.archived,
                canonical: nil,
                messagesJSON: parts.joined(separator: ","),
                hasOlder: start > 0,
                hasNewer: end < rows.count,
                threadSummariesJSON: threadSummariesJSONLocked(parentChannelId: channelId, parentIds: windowIds)
            )
        }
        let replies = humanMessageRows.filter { row in
            guard Self.messageIdMatches(row.id, messageId),
                  let thread = postableChannels[row.channelId],
                  thread.kind == "thread",
                  thread.serverId == serverId,
                  thread.deletedAt == nil,
                  let parentMessageId = thread.parentMessageId,
                  let parent = humanMessageRows.first(where: { $0.id == parentMessageId }),
                  parent.channelId == channelId
            else { return false }
            return true
        }
        if replies.count == 1, let reply = replies.first, let thread = postableChannels[reply.channelId] {
            let threadRows = humanMessageRows.filter { $0.channelId == reply.channelId }
            let seq = (threadRows.firstIndex { $0.id == reply.id } ?? 0) + 1
            let canonical = "{\"kind\":\"thread\",\"channelId\":\(jsonString(channelId)),\"messageId\":\(jsonString(reply.id)),\"threadParentMessageId\":\(jsonString(thread.parentMessageId ?? "")),\"threadChannelId\":\(jsonString(reply.channelId))}"
            return Self.contextJSON(channelId: reply.channelId, message: reply, seq: seq, archived: thread.archived, canonical: canonical)
        }
        let threadChannels = postableChannels.filter { id, thread in
            thread.kind == "thread"
                && thread.serverId == serverId
                && thread.deletedAt == nil
                && Self.messageIdMatches(id, messageId)
                && thread.parentMessageId.flatMap { parentId in
                    humanMessageRows.first { $0.id == parentId && $0.channelId == channelId }
                } != nil
        }
        guard threadChannels.count == 1,
              let parentMessageId = threadChannels.values.first?.parentMessageId,
              let parent = humanMessageRows.first(where: { $0.id == parentMessageId && $0.channelId == channelId })
        else { return nil }
        let seq = (rows.firstIndex { $0.id == parent.id } ?? 0) + 1
        return Self.contextJSON(channelId: parent.channelId, message: parent, seq: seq, archived: channel.archived, canonical: nil)
    }

    private static func messageIdMatches(_ stored: String, _ given: String) -> Bool {
        if ServerScope.isUUID(given) {
            return stored.caseInsensitiveCompare(given) == .orderedSame
        }
        return stored.lowercased().hasPrefix(given.lowercased())
    }

    private static func contextWindowSide(_ raw: String?) -> Int {
        guard let raw, raw.wholeMatch(of: /^\d+$/) != nil, let value = Int(raw) else { return 15 }
        return min(value, 15)
    }

    private static func contextJSON(channelId: String, message: StoredHumanMessage, seq: Int, archived: Bool, canonical: String?, actionMetadata: String? = nil, messagesJSON: String? = nil, hasOlder: Bool = false, hasNewer: Bool = false, threadSummariesJSON: String = "") -> HTTPReply {
        var messageJSON = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(channelId)),\"content\":\(jsonString(message.content)),\"seq\":\(seq)"
        if let actionMetadata {
            messageJSON += ",\"actionMetadata\":\(actionMetadata)"
        }
        messageJSON += "}"
        let renderedMessages = messagesJSON ?? messageJSON
        var body = "{\"channelId\":\(jsonString(channelId)),\"targetMessageId\":\(jsonString(message.id)),\"hasOlder\":\(hasOlder ? "true" : "false"),\"hasNewer\":\(hasNewer ? "true" : "false"),\"messages\":[\(renderedMessages)]"
        if let canonical {
            body += ",\"canonicalTarget\":\(canonical)"
        }
        body += ",\"threadSummariesByParentMessageId\":{\(threadSummariesJSON)},\"historyLimited\":false,\"channelArchived\":\(archived ? "true" : "false")}"
        return Self.json(200, body)
    }

    /// Turns on Computer and App references for one server. Installed apps stay empty until recorded separately.
    public func allowComposerResourceReferences(serverId: String) {
        lock.lock()
        composerResourceServers.insert(serverId)
        lock.unlock()
    }

    /// `POST /api/messages/mention-actions/execute`. A resolution id belongs to the sender who wrote the mention.
    public func executeMentionActions(body: String, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String,
              action == "notify" || action == "add"
        else {
            return Self.json(400, "{\"error\":\"action must be notify or add\"}")
        }
        var seen = Set<String>()
        var resolutionIds: [String] = []
        for id in (object["resolutionIds"] as? [Any])?.compactMap({ $0 as? String }) ?? [] where !seen.contains(id) {
            seen.insert(id)
            resolutionIds.append(id)
            if resolutionIds.count == 100 { break }
        }
        if resolutionIds.isEmpty {
            return Self.json(400, "{\"error\":\"resolutionIds must include at least one id\"}")
        }
        lock.lock()
        var results: [String] = []
        for id in resolutionIds {
            guard let index = storedMentions.firstIndex(where: { $0.id == id }),
                  postableChannels[storedMentions[index].channelId]?.serverId == serverId,
                  storedMentions[index].senderId == userId
            else {
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\(jsonString(action)),\"status\":\"not_found\"}")
                continue
            }
            if action == "notify" {
                if !mentionTargetCanReadLocked(
                    channelId: storedMentions[index].channelId,
                    targetType: storedMentions[index].targetType,
                    targetId: storedMentions[index].targetId
                ) {
                    results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"notify\",\"status\":\"no_permission\",\"reason\":\"target_lacks_read_access\"}")
                    continue
                }
                if storedMentions[index].notifiedAt == nil {
                    storedMentions[index].notifiedAt = Date()
                    storedMentions[index].notifiedByType = "user"
                    storedMentions[index].notifiedById = userId
                    storedMentions[index].notifiedAction = "notify_only"
                    if storedMentions[index].targetType == "agent" {
                        storedAgentDeliveries.append((
                            agentId: storedMentions[index].targetId,
                            messageId: storedMentions[index].messageId,
                            channelType: "channel"
                        ))
                    }
                }
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"notify\",\"status\":\"queued\",\"dedupedResolutionIds\":[\(jsonString(id))]}")
            } else if storedMentions[index].notifiedAction == "add" {
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"delivered\",\"reason\":\"already_delivered\",\"dedupedResolutionIds\":[\(jsonString(id))]}")
            } else if !senderStillInChannelLocked(channelId: storedMentions[index].channelId, userId: userId) {
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"no_permission\",\"reason\":\"sender_lacks_channel_access\"}")
            } else {
                storedMentions[index].notifiedAt = Date()
                storedMentions[index].notifiedByType = "user"
                storedMentions[index].notifiedById = userId
                storedMentions[index].notifiedAction = "add"
                let targetId = storedMentions[index].targetId
                let mentionChannelId = storedMentions[index].channelId
                if storedMentions[index].targetType == "agent" {
                    var agents = channelAgentMembers[mentionChannelId] ?? []
                    agents.insert(targetId)
                    channelAgentMembers[mentionChannelId] = agents
                    storedAgentDeliveries.append((
                        agentId: targetId,
                        messageId: storedMentions[index].messageId,
                        channelType: "channel"
                    ))
                } else {
                    postableChannels[mentionChannelId]?.memberIds.insert(targetId)
                }
                results.append("{\"resolutionId\":\(jsonString(id)),\"action\":\"add\",\"status\":\"delivered\",\"dedupedResolutionIds\":[\(jsonString(id))]}")
            }
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"action\":\(jsonString(action)),\"results\":[\(results.joined(separator: ","))]}")
    }

    /// A removed channel member can no longer add someone through a mention they sent earlier.
    private func senderStillInChannelLocked(channelId: String, userId: String) -> Bool {
        guard let stored = postableChannels[channelId] else { return false }
        if stored.kind == "thread", let parentId = stored.parentChannelId, let parent = postableChannels[parentId] {
            return parent.memberIds.contains(userId)
        }
        return stored.memberIds.contains(userId)
    }

    /// Public channels are readable by any signed-in user. Private surfaces and their threads require membership.
    private func mentionTargetCanReadLocked(channelId: String, targetType: String, targetId: String) -> Bool {
        guard let stored = postableChannels[channelId] else { return false }
        let surface: PostableChannel
        let surfaceId: String
        if stored.kind == "thread", let parentId = stored.parentChannelId, let parent = postableChannels[parentId] {
            surface = parent
            surfaceId = parentId
        } else {
            surface = stored
            surfaceId = channelId
        }
        if targetType == "agent" {
            if surface.kind == "channel" { return true }
            return channelAgentMembers[surfaceId]?.contains(targetId) == true
                || channelAgentMembers[channelId]?.contains(targetId) == true
        }
        if surface.kind == "channel" { return true }
        return surface.memberIds.contains(targetId) || stored.memberIds.contains(targetId)
    }

    /// `POST /api/messages`. A bad human create body is refused before any message row exists.
    /// An App reference is refused before persistence when that app is not installed on the channel's server.
    public func createHumanMessage(body: String, authorization: String?, serverId: String?, contract: String = "v1") -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        guard Self.humanMessageBodyIsValid(body) else {
            return Self.json(400, "{\"error\":\"Invalid message request body\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelId = object["channelId"] as? String,
              let content = object["content"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid message request body\"}")
        }
        lock.lock()
        let channel = postableChannels[channelId]
        let referencesEnabled = composerResourceServers.contains(channel?.serverId ?? "")
        let installed = installedServerApps[channel?.serverId ?? ""] ?? []
        lock.unlock()
        guard let channel, channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let parentMember = channel.kind == "thread"
            && (channel.parentChannelId.flatMap { postableChannels[$0] }?.memberIds.contains(userId) ?? false)
        guard channel.memberIds.contains(userId) || parentMember else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        if channel.archived {
            return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
        }
        let appIds = Self.appReferenceIds(content)
        if !appIds.isEmpty {
            if !referencesEnabled {
                return Self.json(400, "{\"error\":\"Computer and App references are not enabled in this server\"}")
            }
            if appIds.contains(where: { !installed.contains($0) }) {
                return Self.json(400, "{\"error\":\"App reference is not installed in this server\"}")
            }
        }
        let attachmentIds = (object["attachmentIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        let mentions = Self.mentionInputs(object["mentions"])
        let senderTimezone = Self.parseOptionalIanaTimezone(object["timezone"])
        let reply: HTTPReply
        if object["randomId"] != nil {
            guard let randomId = object["randomId"] as? String, !randomId.isEmpty, randomId.count <= 128 else {
                return Self.json(400, "{\"error\":\"randomId must be a non-empty string with at most 128 characters\"}")
            }
            reply = storeHumanMessage(channelId: channelId, senderId: userId, content: content, randomId: randomId, attachmentIds: attachmentIds, senderTimezone: senderTimezone)
        } else {
            reply = storeHumanMessage(channelId: channelId, senderId: userId, content: content, randomId: nil, attachmentIds: attachmentIds, senderTimezone: senderTimezone)
        }
        if reply.status == 200, channel.kind == "thread", let parentMessageId = channel.parentMessageId {
            lock.lock()
            threadFollows["\(serverId ?? "")\n\(userId)\n\(channelId)"] = (
                serverId: serverId ?? "",
                userId: userId,
                threadChannelId: channelId,
                parentMessageId: parentMessageId
            )
            for mention in mentions where mention.type == "user" || mention.type == "agent" {
                guard ServerScope.isUUID(mention.id), mention.id != userId else { continue }
                let valid: Bool
                if mention.type == "user" {
                    valid = accounts.values.contains { $0.id == mention.id }
                        && oauth.memberRole(serverId: serverId ?? "", userId: mention.id) != nil
                } else {
                    valid = oauth.agentRuntimeInfo(id: mention.id)?.serverId == serverId
                }
                if valid {
                    threadFollows["\(serverId ?? "")\n\(mention.id)\n\(channelId)"] = (
                        serverId: serverId ?? "",
                        userId: mention.id,
                        threadChannelId: channelId,
                        parentMessageId: parentMessageId
                    )
                }
            }
            lock.unlock()
        }
        if contract == "v2" {
            return v2HumanSend(reply, channelId: channelId, mentions: mentions)
        }
        return withPendingMentionActions(reply, channelId: channelId, mentions: mentions)
    }

    /// `GET /api/messages/forward/enabled`. The rollout flag is retired, so this stays true.
    public func messageForwardEnabled(authorization: String?, serverId: String?) -> HTTPReply {
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let userId):
            guard isEmailVerified(userId: userId) else {
                return Self.json(403, "{\"error\":\"Email verification required\"}")
            }
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"Missing X-Server-Id header\"}")
        }
        return Self.json(200, "{\"enabled\":true}")
    }

    /// `GET /api/messages/forward/targets/search`. An empty query returns no targets.
    public func searchForwardTargets(query: String?, limit rawLimit: String?, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"Missing X-Server-Id header\"}")
        }
        let q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return Self.json(200, "{\"targets\":[]}")
        }
        let pageLimit: Int
        if let rawLimit, let parsed = Int(rawLimit), parsed > 0 {
            pageLimit = min(parsed, 20)
        } else {
            pageLimit = 20
        }
        lock.lock()
        defer { lock.unlock() }
        let role = serverMemberRoles["\(serverId)\n\(userId)"]
        let isGuest = role == "guest"
        let hideHumans = hideHumansFromMembers[serverId] == true || isGuest
        var results: [(score: Int, title: String, json: String)] = []
        for (id, channel) in postableChannels where channel.serverId == serverId && channel.deletedAt == nil && !channel.archived {
            guard channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint" else { continue }
            let score = Self.forwardTargetScore(q, channel.name.lowercased())
            if score <= 0 { continue }
            let joined = channel.memberIds.contains(userId)
            if isGuest && !joined { continue }
            if channel.kind != "channel" && !joined { continue }
            let canForwardNow = channel.kind != "channel" || joined
            let required = channel.kind == "channel" && !joined ? "join_channel" : nil
            let title = "#\(channel.name)"
            results.append((
                score + (joined ? 50 : 0),
                title,
                Self.forwardTargetJSON(
                    type: "channel",
                    channelType: channel.kind,
                    id: id,
                    title: title,
                    subtitle: "",
                    avatarUrl: nil,
                    channelId: id,
                    joined: joined,
                    dmExists: nil,
                    canForwardNow: canForwardNow,
                    requiredAction: required
                )
            ))
        }
        var dmPeerIds = Set<String>()
        for (id, channel) in postableChannels where channel.serverId == serverId && channel.kind == "dm" && channel.deletedAt == nil && channel.memberIds.contains(userId) {
            let peerId = channel.agentId ?? channel.memberIds.first { $0 != userId }
            guard let peerId else { continue }
            dmPeerIds.insert(peerId)
            let agent = serverAgents[peerId]
            let account = accounts.values.first { $0.id == peerId }
            let label = agent?.name ?? account?.name ?? peerId
            let score = Self.forwardTargetScore(q, label.lowercased())
            if score <= 0 { continue }
            let title = "@\(label)"
            results.append((
                score + 50,
                title,
                Self.forwardTargetJSON(
                    type: "dm",
                    channelType: "dm",
                    id: peerId,
                    title: title,
                    subtitle: agent == nil ? "" : "agent",
                    avatarUrl: agent?.avatarUrl ?? account?.avatarUrl,
                    channelId: id,
                    joined: nil,
                    dmExists: true,
                    canForwardNow: true,
                    requiredAction: nil
                )
            ))
        }
        if !isGuest {
            for agent in serverAgents.values where agent.serverId == serverId && !dmPeerIds.contains(agent.id) {
                let score = Self.forwardTargetScore(q, agent.name.lowercased())
                if score <= 0 { continue }
                let title = "@\(agent.name)"
                results.append((
                    score,
                    title,
                    Self.forwardTargetJSON(
                        type: "agent",
                        channelType: nil,
                        id: agent.id,
                        title: title,
                        subtitle: "agent",
                        avatarUrl: agent.avatarUrl,
                        channelId: nil,
                        joined: nil,
                        dmExists: false,
                        canForwardNow: false,
                        requiredAction: "create_dm"
                    )
                ))
            }
        }
        if !hideHumans {
            for (key, memberRole) in serverMemberRoles {
                let parts = key.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, parts[0] == serverId, memberRole != "guest" else { continue }
                let memberId = parts[1]
                if memberId == userId || dmPeerIds.contains(memberId) { continue }
                guard let account = accounts.values.first(where: { $0.id == memberId }) else { continue }
                let score = Self.forwardTargetScore(q, account.name.lowercased())
                if score <= 0 { continue }
                let title = "@\(account.name)"
                results.append((
                    score,
                    title,
                    Self.forwardTargetJSON(
                        type: "human",
                        channelType: nil,
                        id: memberId,
                        title: title,
                        subtitle: "",
                        avatarUrl: account.avatarUrl,
                        channelId: nil,
                        joined: nil,
                        dmExists: false,
                        canForwardNow: false,
                        requiredAction: "create_dm"
                    )
                ))
            }
        }
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title < rhs.title
        }
        let targets = results.prefix(pageLimit).map(\.json).joined(separator: ",")
        return Self.json(200, "{\"targets\":[\(targets)]}")
    }

    private static func forwardTargetScore(_ query: String, _ candidate: String) -> Int {
        if candidate.isEmpty { return 0 }
        if candidate == query { return 400 }
        if candidate.hasPrefix(query) { return 300 }
        if candidate.range(of: " \(query)") != nil { return 250 }
        if let range = candidate.range(of: query) {
            let index = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            return max(1, 150 - index)
        }
        return 0
    }

    private static func forwardTargetJSON(
        type: String,
        channelType: String?,
        id: String,
        title: String,
        subtitle: String,
        avatarUrl: String?,
        channelId: String?,
        joined: Bool?,
        dmExists: Bool?,
        canForwardNow: Bool,
        requiredAction: String?
    ) -> String {
        let channelTypeJSON = channelType.map { jsonString($0) } ?? "null"
        let avatarJSON = avatarUrl.map { jsonString($0) } ?? "null"
        let channelJSON = channelId.map { jsonString($0) } ?? "null"
        let joinedJSON = joined.map { $0 ? "true" : "false" } ?? "null"
        let dmJSON = dmExists.map { $0 ? "true" : "false" } ?? "null"
        let requiredJSON = requiredAction.map { jsonString($0) } ?? "null"
        return "{\"type\":\(jsonString(type)),\"channelType\":\(channelTypeJSON),\"id\":\(jsonString(id)),\"title\":\(jsonString(title)),\"subtitle\":\(jsonString(subtitle)),\"avatarUrl\":\(avatarJSON),\"channelId\":\(channelJSON),\"joined\":\(joinedJSON),\"dmExists\":\(dmJSON),\"canForwardNow\":\(canForwardNow ? "true" : "false"),\"requiredAction\":\(requiredJSON)}"
    }

    /// `POST /api/messages/forward`. An empty note becomes `Forwarded N message(s)` in the destination.
    public func forwardHumanMessage(body: String, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"Missing X-Server-Id header\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let destinationChannelId: String
        if let raw = object["destinationChannelId"] as? String {
            destinationChannelId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let raw = object["channelId"] as? String {
            destinationChannelId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            destinationChannelId = ""
        }
        let note: String?
        if object["note"] == nil || object["note"] is NSNull {
            note = ""
        } else if let raw = object["note"] as? String {
            note = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            note = nil
        }
        let sourceIds = Self.forwardSourceIds(object["sourceMessageIds"])
        if object["destinationChannelIds"] != nil {
            guard let sourceIds, let note else {
                return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
            }
            if note.count > 32_000 {
                return Self.json(400, "{\"error\":\"Message content exceeds maximum length of 32000 characters\"}")
            }
            return forwardToMany(
                object: object,
                sourceIds: sourceIds,
                note: note,
                authorization: authorization,
                serverId: serverId
            )
        }
        guard !destinationChannelId.isEmpty, let sourceIds, let note else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        if note.count > 32_000 {
            return Self.json(400, "{\"error\":\"Message content exceeds maximum length of 32000 characters\"}")
        }
        let randomId: String
        if object["randomId"] == nil || object["randomId"] is NSNull {
            randomId = "forward-\(UUID().uuidString.lowercased())"
        } else if let raw = object["randomId"] as? String, !raw.isEmpty, raw.count <= 128 {
            randomId = raw
        } else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let content = note.isEmpty
            ? "Forwarded \(sourceIds.count) message\(sourceIds.count == 1 ? "" : "s")"
            : note
        lock.lock()
        if let existing = humanMessageRows.first(where: { $0.senderId == userId && $0.randomId == randomId }) {
            if existing.channelId == destinationChannelId,
               existing.content == content,
               let record = forwardRecords[existing.id],
               record.sourceIds == sourceIds {
                let snapshot = existing
                lock.unlock()
                return Self.forwardMessageReply(message: snapshot, record: record, outcome: "idempotent_replay")
            }
            lock.unlock()
            return Self.json(409, "{\"error\":\"This forward request id was already used for different content\",\"code\":\"idempotency_conflict\"}")
        }
        guard let destination = postableChannels[destinationChannelId],
              destination.serverId == serverId,
              destination.deletedAt == nil
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard destination.memberIds.contains(userId) else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"You must join this channel to send messages\"}")
        }
        var pending: [PendingForwardSource] = []
        for id in sourceIds {
            guard let message = humanMessageRows.first(where: { $0.id == id }) else {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Source message not found\"}")
            }
            let jointLocalId = jointLocalChannelIdLocked(canonicalChannelId: message.channelId, serverId: serverId, userId: userId)
            let channel = jointLocalId.flatMap { postableChannels[$0] }
                ?? (messageSearchVisibleLocked(messageChannelId: message.channelId, serverId: serverId, viewer: .user(userId))
                    ? postableChannels[message.channelId] : nil)
            guard let channel else {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Source message not found\"}")
            }
            if message.actionKind == "forwarded-bundle" || forwardedBundles[message.id] != nil {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Forwarded messages can't be forwarded. Select the original message instead.\",\"code\":\"forwarded_source_not_supported\"}")
            }
            if message.messageType != "chat" || message.actionKind != nil {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Only ordinary chat messages can be forwarded\",\"code\":\"unsupported_source_message\"}")
            }
            let attachments = channelAttachments.values
                .filter { $0.messageId == message.id }
                .sorted { ($0.messagePosition ?? 0) < ($1.messagePosition ?? 0) }
            pending.append(PendingForwardSource(
                messageId: message.id,
                content: message.content,
                createdAt: message.createdAt,
                channelId: jointLocalId ?? message.channelId,
                channelKind: channel.kind,
                channelName: channel.name,
                parentChannelId: channel.parentChannelId,
                senderId: message.senderId,
                attachments: attachments
            ))
        }
        let selectedThreads = Set(pending.filter { $0.channelKind == "thread" }.map(\.channelId))
        let prepared = pending.map { source in
            (source, forwardContextLocked(source: source, selectedThreads: selectedThreads))
        }
        if Set(prepared.map { $0.1.bundleSourceId }).count != 1 {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Forwarded bundles must come from a single source\",\"code\":\"cross_source_bundle\"}")
        }
        let ordered = prepared.sorted { lhs, rhs in
            if lhs.1.sourceIsThreadParent != rhs.1.sourceIsThreadParent {
                return lhs.1.sourceIsThreadParent
            }
            if lhs.0.createdAt != rhs.0.createdAt { return lhs.0.createdAt < rhs.0.createdAt }
            return lhs.0.messageId < rhs.0.messageId
        }
        var legacy: [ForwardedSource] = []
        var itemRecords: [ForwardItemRecord] = []
        var projections: [(attachment: ChannelAttachment, id: String, position: Int)] = []
        var position = 0
        for (source, context) in ordered {
            let exposed = context.sourceTargetId != nil
            legacy.append(ForwardedSource(
                sourceServerId: exposed ? serverId : "",
                sourceTargetId: context.sourceTargetId ?? "",
                sourceMessageId: exposed ? source.messageId : "",
                snapshotId: context.snapshotId ?? "",
                snapshotType: context.snapshotType,
                snapshotLabel: context.snapshotLabel,
                snapshotLabelVisibility: context.snapshotLabelVisibility,
                provenanceState: "available"
            ))
            var snapshots: [ForwardAttachmentSnapshot] = []
            for attachment in source.attachments {
                let projectedId = UUID().uuidString.lowercased()
                snapshots.append(ForwardAttachmentSnapshot(
                    id: projectedId,
                    filename: attachment.filename,
                    mimeType: attachment.mimeType ?? "",
                    sizeBytes: attachment.sizeBytes ?? 0,
                    width: attachment.width,
                    height: attachment.height
                ))
                projections.append((attachment, projectedId, position))
                position += 1
            }
            let exposesPointers = context.snapshotLabelVisibility == "public" && context.sourceTargetId != nil
            let uniqueName = accounts.values.first { $0.id == source.senderId }?.name ?? "unknown"
            itemRecords.append(ForwardItemRecord(
                sourceMessageId: source.messageId,
                exposesPointers: exposesPointers,
                sourceAuthorUniqueName: uniqueName,
                sourceIsThreadParent: context.sourceIsThreadParent,
                contentSnapshot: source.content,
                sourceTargetId: context.sourceTargetId,
                sourceThreadId: context.sourceThreadId,
                parentChannelId: context.parentChannelId,
                snapshotId: context.snapshotId,
                snapshotType: context.snapshotType,
                snapshotLabel: context.snapshotLabel,
                snapshotLabelVisibility: context.snapshotLabelVisibility,
                provenanceState: "available",
                attachments: snapshots,
                attachmentPolicy: snapshots.isEmpty ? "excluded" : "projected"
            ))
        }
        let storageChannelId = jointProjections.first { $0.localChannelId == destinationChannelId }?.canonicalChannelId ?? destinationChannelId
        let record = StoredForwardRecord(sourceIds: sourceIds, items: itemRecords, destinationTargetId: destinationChannelId)
        lock.unlock()
        let storedReply = storeHumanMessage(
            channelId: storageChannelId,
            senderId: userId,
            content: content,
            randomId: randomId,
            attachmentIds: []
        )
        guard storedReply.status == 200,
              let data = storedReply.body.data(using: .utf8),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = stored["id"] as? String
        else { return storedReply }
        lock.lock()
        forwardedBundles[messageId] = legacy
        forwardRecords[messageId] = record
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].attachmentIds = projections.map(\.id)
        }
        for projection in projections {
            var copy = projection.attachment
            copy.id = projection.id
            copy.channelId = destinationChannelId
            copy.messageId = messageId
            copy.messagePosition = projection.position
            channelAttachments[copy.id] = copy
        }
        guard var message = humanMessageRows.first(where: { $0.id == messageId }) else {
            lock.unlock()
            return storedReply
        }
        lock.unlock()
        message.channelId = destinationChannelId
        return Self.forwardMessageReply(message: message, record: record, outcome: "success")
    }

    private func forwardContextLocked(source: PendingForwardSource, selectedThreads: Set<String>) -> ForwardSourceContext {
        if source.channelKind == "thread" {
            let parent = source.parentChannelId.flatMap { postableChannels[$0] }
            let publicParent = parent?.kind == "channel"
            return ForwardSourceContext(
                bundleSourceId: source.channelId,
                sourceTargetId: publicParent ? source.channelId : nil,
                sourceThreadId: publicParent ? source.channelId : nil,
                parentChannelId: publicParent ? source.parentChannelId : nil,
                sourceIsThreadParent: false,
                snapshotId: publicParent ? source.parentChannelId : nil,
                snapshotType: "thread",
                snapshotLabel: publicParent ? "#\(parent?.name ?? "")" : "",
                snapshotLabelVisibility: publicParent ? "public" : "restricted"
            )
        }
        if source.channelKind == "channel",
           let threadId = postableChannels.first(where: { $0.value.kind == "thread" && $0.value.parentMessageId == source.messageId })?.key,
           selectedThreads.contains(threadId) {
            return ForwardSourceContext(
                bundleSourceId: threadId,
                sourceTargetId: threadId,
                sourceThreadId: threadId,
                parentChannelId: source.channelId,
                sourceIsThreadParent: true,
                snapshotId: source.channelId,
                snapshotType: "thread",
                snapshotLabel: "#\(source.channelName)",
                snapshotLabelVisibility: "public"
            )
        }
        let publicSource = source.channelKind == "channel"
        return ForwardSourceContext(
            bundleSourceId: source.channelId,
            sourceTargetId: publicSource ? source.channelId : nil,
            sourceThreadId: nil,
            parentChannelId: nil,
            sourceIsThreadParent: false,
            snapshotId: publicSource ? source.channelId : nil,
            snapshotType: publicSource ? "channel" : source.channelKind,
            snapshotLabel: publicSource ? "#\(source.channelName)" : "",
            snapshotLabelVisibility: publicSource ? "public" : "restricted"
        )
    }

    private static func forwardMessageReply(message: StoredHumanMessage, record: StoredForwardRecord, outcome: String) -> HTTPReply {
        let items = forwardItemsJSON(record.items)
        var body = "{\"id\":\(jsonString(message.id)),\"messageType\":\"chat\",\"channelId\":\(jsonString(message.channelId)),\"content\":\(jsonString(message.content)),\"attachments\":[\(attachmentJSON(message.attachmentIds))]"
        if let randomId = message.randomId {
            body += ",\"randomId\":\(jsonString(randomId))"
        }
        body += ",\"actionMetadata\":{\"kind\":\"forwarded-bundle\",\"destinationTargetId\":\(jsonString(record.destinationTargetId)),\"forwardedItems\":[\(items)]}}"
        var reply = json(200, body)
        reply.headers["X-Raft-Forward-Outcome"] = outcome
        return reply
    }

    private static func forwardItemsJSON(_ items: [ForwardItemRecord]) -> String {
        items.map { forwardItemJSON($0) }.joined(separator: ",")
    }

    private static func forwardAttachmentSnapshotsJSON(_ snapshots: [ForwardAttachmentSnapshot]) -> String {
        snapshots.map { snap in
            let width = snap.width.map(String.init) ?? "null"
            let height = snap.height.map(String.init) ?? "null"
            return "{\"id\":\(jsonString(snap.id)),\"filename\":\(jsonString(snap.filename)),\"mimeType\":\(jsonString(snap.mimeType)),\"sizeBytes\":\(snap.sizeBytes),\"width\":\(width),\"height\":\(height)}"
        }.joined(separator: ",")
    }

    private static func forwardItemJSON(_ item: ForwardItemRecord) -> String {
        let attachments = forwardAttachmentSnapshotsJSON(item.attachments)
        let snapshotId = item.snapshotId.map { jsonString($0) } ?? "null"
        let parent = item.sourceIsThreadParent ? "true" : "false"
        let target = item.sourceTargetId.map { jsonString($0) } ?? "null"
        let messageIdJSON = item.exposesPointers ? jsonString(item.sourceMessageId) : "null"
        var body = "{\"sourceMessageId\":\(messageIdJSON),\"sourceIsThreadParent\":\(parent),\"contentSnapshot\":\(jsonString(item.contentSnapshot)),\"sourceAuthorSnapshot\":{\"uniqueName\":\(jsonString(item.sourceAuthorUniqueName))},\"sourceTargetId\":\(target)"
        if !item.exposesPointers {
            body += ",\"sourceMessageSeq\":null,\"sourceServerId\":null"
        }
        if let threadId = item.sourceThreadId {
            body += ",\"sourceThreadId\":\(jsonString(threadId))"
        }
        if let parentChannelId = item.parentChannelId {
            body += ",\"parentChannelId\":\(jsonString(parentChannelId))"
        }
        body += ",\"sourceTargetSnapshot\":{\"id\":\(snapshotId),\"type\":\(jsonString(item.snapshotType)),\"label\":\(jsonString(item.snapshotLabel)),\"labelVisibility\":\(jsonString(item.snapshotLabelVisibility))},\"attachmentSnapshots\":[\(attachments)],\"attachmentPolicy\":\(jsonString(item.attachmentPolicy)),\"provenanceState\":\(jsonString(item.provenanceState))}"
        return body
    }

    /// A viewer who cannot read the source still sees the forward, with the pointers removed.
    private static func scrubbedForwardItemJSON(_ item: ForwardItemRecord) -> String {
        let attachments = forwardAttachmentSnapshotsJSON(item.attachments)
        let parent = item.sourceIsThreadParent ? "true" : "false"
        let type = item.snapshotType.isEmpty ? "channel" : item.snapshotType
        return "{\"sourceMessageId\":null,\"sourceIsThreadParent\":\(parent),\"contentSnapshot\":\(jsonString(item.contentSnapshot)),\"sourceServerId\":null,\"sourceTargetId\":null,\"sourceThreadId\":null,\"parentChannelId\":null,\"sourceTargetSnapshot\":{\"id\":null,\"type\":\(jsonString(type)),\"label\":\"\",\"labelVisibility\":\"restricted\"},\"attachmentSnapshots\":[\(attachments)],\"attachmentPolicy\":\(jsonString(item.attachmentPolicy)),\"provenanceState\":\"original_unavailable\"}"
    }

    private func forwardMetadataJSONLocked(messageId: String, userId: String, serverId: String?) -> String? {
        guard let record = forwardRecords[messageId] else { return nil }
        let rendered = record.items.map { item in
            forwardItemReadableLocked(item, userId: userId, serverId: serverId)
                ? Self.forwardItemJSON(item)
                : Self.scrubbedForwardItemJSON(item)
        }.joined(separator: ",")
        return "{\"kind\":\"forwarded-bundle\",\"forwardedItems\":[\(rendered)]}"
    }

    private func forwardItemReadableLocked(_ item: ForwardItemRecord, userId: String, serverId: String?) -> Bool {
        guard let targetId = item.sourceTargetId, let serverId else { return false }
        guard let channel = postableChannels[targetId], channel.serverId == serverId, channel.deletedAt == nil else { return false }
        if channel.kind == "channel" { return true }
        if channel.kind == "thread" {
            guard let parentId = channel.parentChannelId,
                  let parent = postableChannels[parentId],
                  parent.serverId == serverId,
                  parent.deletedAt == nil
            else { return channel.memberIds.contains(userId) }
            if parent.kind == "channel" { return true }
            return parent.memberIds.contains(userId) || channel.memberIds.contains(userId)
        }
        return channel.memberIds.contains(userId)
    }

    /// A batch keeps one result per distinct destination. A denial or conflict stays inside that result.
    private func forwardToMany(object: [String: Any], sourceIds: [String], note: String, authorization: String?, serverId: String) -> HTTPReply {
        guard let destinations = Self.forwardDestinationIds(object["destinationChannelIds"]) else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        guard let rawRequestId = object["requestId"] as? String else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let requestId = rawRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ServerScope.isUUID(requestId) else {
            return Self.json(400, "{\"error\":\"Destination channel and full source message ids are required\"}")
        }
        let sourcesJSON = sourceIds.map { jsonString($0) }.joined(separator: ",")
        var results: [String] = []
        var successes = 0
        var replays = 0
        for destination in destinations {
            let randomId = "forward:\(requestId):\(destination)"
            let body = "{\"destinationChannelId\":\(jsonString(destination)),\"sourceMessageIds\":[\(sourcesJSON)],\"note\":\(jsonString(note)),\"randomId\":\(jsonString(randomId))}"
            let reply = forwardHumanMessage(body: body, authorization: authorization, serverId: serverId)
            if reply.status == 200 {
                successes += 1
                if reply.value(for: "X-Raft-Forward-Outcome") == "idempotent_replay" {
                    replays += 1
                }
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"success\",\"message\":\(reply.body)}")
            } else if reply.status == 409 {
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"failed\",\"code\":\"request_conflict\",\"error\":\"Forward request conflicts with an earlier request\"}")
            } else if reply.status == 403 || reply.status == 404 {
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"failed\",\"code\":\"destination_unavailable\",\"error\":\"Could not forward to this target\"}")
            } else {
                results.append("{\"destinationChannelId\":\(jsonString(destination)),\"status\":\"failed\",\"code\":\"forward_failed\",\"error\":\"Could not forward to this target\"}")
            }
        }
        let failed = destinations.count - successes
        let outcome: String
        if failed > 0 {
            outcome = successes > 0 ? "partial_failure" : "all_failed"
        } else if replays == destinations.count {
            outcome = "idempotent_replay"
        } else {
            outcome = "success"
        }
        var reply = Self.json(200, "{\"results\":[\(results.joined(separator: ","))]}")
        reply.headers["X-Raft-Forward-Outcome"] = outcome
        return reply
    }

    private static func forwardDestinationIds(_ value: Any?) -> [String]? {
        guard let rows = value as? [Any], !rows.isEmpty else { return nil }
        var ids: [String] = []
        var seen = Set<String>()
        for row in rows {
            guard let raw = row as? String else { return nil }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ServerScope.isUUID(id) else { return nil }
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        if ids.isEmpty || ids.count > 10 { return nil }
        return ids
    }

    private static func forwardSourceIds(_ value: Any?) -> [String]? {
        guard let rows = value as? [Any], !rows.isEmpty, rows.count <= 20 else { return nil }
        var ids: [String] = []
        for row in rows {
            guard let raw = row as? String else { return nil }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ServerScope.isUUID(id), !ids.contains(id) else { return nil }
            ids.append(id)
        }
        return ids
    }

    /// `POST /api/v2/messages`. The message is always nested. A stopped agent DM adds `agent_stopped`.
    private func v2HumanSend(_ reply: HTTPReply, channelId: String, mentions: [MentionInput]) -> HTTPReply {
        guard reply.status == 200,
              let data = reply.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = object["id"] as? String
        else { return reply }
        let pending = pendingMentionActionsJSON(channelId: channelId, messageId: messageId, mentions: mentions)
        let warnings = stoppedAgentDeliveryWarningJSON(channelId: channelId, messageId: messageId)
        var body = "{\"message\":\(reply.body)"
        if !pending.isEmpty {
            body += ",\"pendingMentionActions\":[\(pending)]"
        }
        if !warnings.isEmpty {
            body += ",\"deliveryWarnings\":[\(warnings)]"
        }
        body += "}"
        return Self.json(200, body)
    }

    /// A DM delivery to a stopped agent is dropped as `wake_suppressed` and reported to the v2 sender as `agent_stopped`.
    private func stoppedAgentDeliveryWarningJSON(channelId: String, messageId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = postableChannels[channelId],
              channel.kind == "dm",
              let agentId = channel.agentId,
              serverAgents[agentId]?.status == "stopped"
        else { return "" }
        storedAgentDeliveries.append((agentId: agentId, messageId: messageId, channelType: channel.kind))
        return "{\"targetType\":\"agent\",\"targetId\":\(jsonString(agentId)),\"reason\":\"agent_stopped\"}"
    }

    /// Outsider mentions on a new human send are returned beside the message, not inside it.
    private func withPendingMentionActions(_ reply: HTTPReply, channelId: String, mentions: [MentionInput]) -> HTTPReply {
        guard reply.status == 200,
              let data = reply.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = object["id"] as? String
        else { return reply }
        let actions = pendingMentionActionsJSON(channelId: channelId, messageId: messageId, mentions: mentions)
        guard !actions.isEmpty else { return reply }
        return Self.json(200, "{\"message\":\(reply.body),\"pendingMentionActions\":[\(actions)]}")
    }

    private func pendingMentionActionsJSON(channelId: String, messageId: String, mentions: [MentionInput]) -> String {
        lock.lock()
        defer { lock.unlock() }
        let channel = postableChannels[channelId]
        let members = channel?.memberIds ?? []
        let serverId = channel?.serverId
        let directMessage = channel?.kind == "dm"
        let expiresAt = Self.pendingMentionExpiry()
        var parts: [String] = []
        for mention in mentions {
            guard mention.type == "user" || mention.type == "agent",
                  ServerScope.isUUID(mention.id),
                  !mention.name.isEmpty
            else { continue }
            let avatar: String?
            if mention.type == "user" {
                guard accounts.values.contains(where: { $0.id == mention.id }), !members.contains(mention.id) else { continue }
                avatar = accounts.values.first { $0.id == mention.id }?.avatarUrl
            } else {
                guard let agent = serverAgents[mention.id], agent.serverId == serverId else { continue }
                avatar = agent.avatarUrl
            }
            let avatarJSON = avatar.map { jsonString($0) } ?? "null"
            let existing = storedMentions.first { $0.messageId == messageId && $0.targetType == mention.type && $0.targetId == mention.id }
            let resolutionId = existing?.id ?? UUID().uuidString.lowercased()
            if existing == nil {
                let senderId = humanMessageRows.first { $0.id == messageId }?.senderId ?? ""
                storedMentions.append(StoredMention(
                    id: resolutionId,
                    messageId: messageId,
                    channelId: channelId,
                    senderId: senderId,
                    targetType: mention.type,
                    targetId: mention.id,
                    handle: mention.name,
                    notifiableAtSend: false,
                    notifiedAt: nil,
                    notifiedByType: nil,
                    notifiedById: nil,
                    notifiedAction: nil
                ))
            }
            if directMessage { continue }
            parts.append("{\"resolutionId\":\(jsonString(resolutionId)),\"messageId\":\(jsonString(messageId)),\"targetType\":\(jsonString(mention.type)),\"targetHandle\":\(jsonString(mention.name)),\"targetAvatarUrl\":\(avatarJSON),\"reason\":\"not_member\",\"availableActions\":[\"notify\",\"add\"],\"expiresAt\":\(jsonString(expiresAt))}")
        }
        return parts.joined(separator: ",")
    }

    private static func pendingMentionExpiry() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date().addingTimeInterval(7 * 24 * 60 * 60))
    }

    private static func mentionInputs(_ value: Any?) -> [MentionInput] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { row in
            guard let object = row as? [String: Any],
                  let type = object["type"] as? String,
                  let id = object["id"] as? String,
                  let name = object["name"] as? String
            else { return nil }
            return MentionInput(type: type, id: id, name: name)
        }
    }

    /// An agent that belongs to a server but is not a member of a channel until someone adds it.
    public func addServerAgent(serverId: String, id: String, name: String, avatarUrl: String?, status: String = "inactive") {
        lock.lock()
        serverAgents[id] = ServerAgent(id: id, serverId: serverId, name: name, avatarUrl: avatarUrl, status: status)
        lock.unlock()
    }

    public struct ForwardedSource: Equatable, Sendable {
        public var sourceServerId: String
        public var sourceTargetId: String
        public var sourceMessageId: String
        public var snapshotId: String
        public var snapshotType: String
        public var snapshotLabel: String
        public var snapshotLabelVisibility: String
        public var provenanceState: String

        public init(sourceServerId: String, sourceTargetId: String, sourceMessageId: String, snapshotId: String, snapshotType: String, snapshotLabel: String, snapshotLabelVisibility: String, provenanceState: String) {
            self.sourceServerId = sourceServerId
            self.sourceTargetId = sourceTargetId
            self.sourceMessageId = sourceMessageId
            self.snapshotId = snapshotId
            self.snapshotType = snapshotType
            self.snapshotLabel = snapshotLabel
            self.snapshotLabelVisibility = snapshotLabelVisibility
            self.provenanceState = provenanceState
        }
    }

    private struct ForwardAttachmentSnapshot {
        var id: String
        var filename: String
        var mimeType: String
        var sizeBytes: Int
        var width: Int?
        var height: Int?
    }

    private struct ForwardSourceContext {
        var bundleSourceId: String
        var sourceTargetId: String?
        var sourceThreadId: String?
        var parentChannelId: String?
        var sourceIsThreadParent: Bool
        var snapshotId: String?
        var snapshotType: String
        var snapshotLabel: String
        var snapshotLabelVisibility: String
    }

    private struct ForwardItemRecord {
        var sourceMessageId: String
        var exposesPointers: Bool
        var sourceAuthorUniqueName: String
        var sourceIsThreadParent: Bool
        var contentSnapshot: String
        var sourceTargetId: String?
        var sourceThreadId: String?
        var parentChannelId: String?
        var snapshotId: String?
        var snapshotType: String
        var snapshotLabel: String
        var snapshotLabelVisibility: String
        var provenanceState: String
        var attachments: [ForwardAttachmentSnapshot]
        var attachmentPolicy: String
    }

    private struct StoredForwardRecord {
        var sourceIds: [String]
        var items: [ForwardItemRecord]
        var destinationTargetId: String
    }

    private struct PendingForwardSource {
        var messageId: String
        var content: String
        var createdAt: Date
        var channelId: String
        var channelKind: String
        var channelName: String
        var parentChannelId: String?
        var senderId: String
        var attachments: [ChannelAttachment]
    }

    public struct ReactionViewerEvent: Equatable, Sendable {
        public var room: String
        public var name: String
        public var payload: String
    }

    /// Stored forwarded-bundle metadata. The reaction route projects it for the HTTP body and the channel broadcast.
    public func setForwardedBundle(messageId: String, items: [ForwardedSource]) {
        lock.lock()
        forwardedBundles[messageId] = items
        lock.unlock()
    }

    public func reactionViewerEvents() -> [ReactionViewerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedReactionViewerEvents
    }

    /// An uploaded file on a channel. The send route keeps the caller's `attachmentIds` order, not upload time.
    public func addChannelAttachment(channelId: String, uploaderId: String, filename: String, mimeType: String? = nil, sizeBytes: Int? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        channelAttachments[id] = ChannelAttachment(
            id: id,
            channelId: channelId,
            uploaderId: uploaderId,
            filename: filename,
            messageId: nil,
            messagePosition: nil,
            mimeType: mimeType,
            sizeBytes: sizeBytes
        )
        lock.unlock()
        return id
    }

    public func linkedAttachmentPositions(ids: [String]) -> [(id: String, messagePosition: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return ids.compactMap { id in
            guard let position = channelAttachments[id]?.messagePosition else { return nil }
            return (id, position)
        }.sorted { $0.messagePosition < $1.messagePosition }
    }

    /// Stored attachment rows for these ids, in `messagePosition` order. Unlinked rows keep a nil position and sort first.
    public func linkedAttachmentRecords(ids: [String]) -> [(id: String, messageId: String?, messagePosition: Int?)] {
        lock.lock()
        defer { lock.unlock() }
        return ids.compactMap { id in
            guard let row = channelAttachments[id] else { return nil }
            return (row.id, row.messageId, row.messagePosition)
        }.sorted { ($0.messagePosition ?? -1) < ($1.messagePosition ?? -1) }
    }

    /// `GET /api/attachments/:id/url`. A private source stays hidden. A copy on a visible channel does not.
    public func attachmentDownloadURL(attachmentId: String, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        guard let serverId, !serverId.isEmpty else {
            return Self.json(400, "{\"error\":\"Missing X-Server-Id header\"}")
        }
        guard ServerScope.isUUID(attachmentId) else {
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        lock.lock()
        let visible: Bool = {
            guard let attachment = channelAttachments[attachmentId],
                  let channel = postableChannels[attachment.channelId],
                  channel.serverId == serverId,
                  channel.deletedAt == nil
            else { return false }
            if channel.kind == "channel" { return true }
            if channel.kind == "thread",
               let parentId = channel.parentChannelId,
               let parent = postableChannels[parentId],
               parent.kind == "channel",
               parent.serverId == serverId,
               parent.deletedAt == nil {
                return true
            }
            return channel.memberIds.contains(userId)
        }()
        lock.unlock()
        guard visible else {
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        return Self.json(200, "{\"url\":\(jsonString("/api/attachments/\(attachmentId)")),\"expiresAt\":null}")
    }

    /// `GET /api/messages/sync`. `since_seq=0` returns the channel page, including a joint canonical store.
    public func softDeletePostableChannelForTesting(channelId: String) {
        lock.lock()
        postableChannels[channelId]?.deletedAt = Date()
        lock.unlock()
    }

    public func followThreadForTesting(serverId: String, userId: String, threadChannelId: String, parentMessageId: String) {
        lock.lock()
        threadFollows["\(serverId)\n\(userId)\n\(threadChannelId)"] = (serverId, userId, threadChannelId, parentMessageId)
        lock.unlock()
    }

    public func addTaskForTesting(
        channelId: String,
        title: String,
        messageId: String,
        assigneeType: String?,
        assigneeId: String?
    ) {
        lock.lock()
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        taskRecords.append(TaskRecord(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            title: title,
            description: nil,
            status: "in_progress",
            taskNumber: taskNumber,
            messageId: messageId,
            createdAt: Date(),
            assigneeId: assigneeId,
            assigneeType: assigneeType
        ))
        lock.unlock()
    }

    private func canManageThreadLocked(serverId: String, thread: PostableChannel, userId: String) -> Bool {
        if oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" {
            return true
        }
        guard let parentMessageId = thread.parentMessageId else { return false }
        return humanMessageRows.first { $0.id == parentMessageId }?.senderId == userId
    }

    public func removeThreadFollower(authorization: String?, serverId: String, threadId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let thread = postableChannels[threadId], thread.serverId == serverId, thread.kind == "thread" else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        guard canManageThreadLocked(serverId: serverId, thread: thread, userId: userId) else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let undoToken = UUID().uuidString.lowercased()
        threadFollowerRemovals[undoToken] = (serverId, threadId, agentId)
        lock.unlock()
        oauth.removeChannelAgent(channelId: threadId, agentId: agentId)
        return Self.json(200, "{\"removed\":true,\"undoToken\":\(jsonString(undoToken))}")
    }

    public func restoreThreadFollower(authorization: String?, serverId: String, threadId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let thread = postableChannels[threadId], thread.serverId == serverId, thread.kind == "thread" else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        guard canManageThreadLocked(serverId: serverId, thread: thread, userId: userId) else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        threadFollowerRemovals = threadFollowerRemovals.filter { $0.value.threadChannelId != threadId || $0.value.agentId != agentId }
        lock.unlock()
        oauth.addChannelAgent(channelId: threadId, agentId: agentId)
        return Self.json(200, "{\"restored\":true}")
    }

    public func threadFollowerRoster(authorization: String?, serverId: String, threadChannelIds: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let ids = (threadChannelIds ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        var threads: [String] = []
        lock.lock()
        for threadId in ids {
            guard let thread = postableChannels[threadId], thread.serverId == serverId, thread.kind == "thread" else { continue }
            let authorId = thread.parentMessageId.flatMap { parentId in
                humanMessageRows.first { $0.id == parentId }?.senderId
            }
            let canManage = role == "owner" || role == "admin" || authorId == userId
            let agents = oauth.channelAgentIds(channelId: threadId).compactMap { agentId -> String? in
                guard let agent = oauth.agentRuntimeInfo(id: agentId) else { return nil }
                return "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name))}"
            }.joined(separator: ",")
            threads.append("{\"threadChannelId\":\(jsonString(threadId)),\"canManage\":\(canManage),\"agents\":[\(agents)]}")
        }
        lock.unlock()
        return Self.json(200, "{\"threads\":[\("\(threads.joined(separator: ","))")]}")
    }

    public func setThreadFollow(authorization: String?, serverId: String, body: String, follow: Bool) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        lock.lock()
        var threadId = object["threadChannelId"] as? String
        if threadId == nil, let parentMessageId = object["parentMessageId"] as? String {
            threadId = threadFollows.values.first {
                $0.serverId == serverId && $0.parentMessageId == parentMessageId
            }?.threadChannelId
            if threadId == nil {
                threadId = postableChannels.first { _, channel in
                    channel.serverId == serverId && channel.parentMessageId == parentMessageId
                }?.key
            }
        }
        lock.unlock()
        guard let threadId, let thread = oauth.channelInfo(id: threadId), thread.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        lock.lock()
        let key = "\(serverId)\n\(userId)\n\(threadId)"
        let parentMessageId = postableChannels[threadId]?.parentMessageId ?? (object["parentMessageId"] as? String) ?? ""
        if follow {
            threadFollows[key] = (serverId, userId, threadId, parentMessageId)
            threadFollowStarts[key] = threadFollowStarts[key] ?? Date()
            threadUnfollows.removeValue(forKey: key)
        } else {
            threadFollows.removeValue(forKey: key)
            let startedAt = threadFollowStarts.removeValue(forKey: key) ?? .distantPast
            let frozen = humanMessageRows
                .filter { $0.channelId == threadId && $0.createdAt >= startedAt }
                .map { (id: $0.id, content: $0.content) }
            threadUnfollows[key] = ThreadUnfollowRecord(
                serverId: serverId,
                userId: userId,
                threadChannelId: threadId,
                parentMessageId: parentMessageId,
                unfollowedAt: Date(),
                latestMessageId: frozen.last?.id ?? parentMessageId,
                replyCount: frozen.count,
                frozenMessages: frozen
            )
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"following\":\(follow)}")
    }

    public func unfollowedInbox(authorization: String?, serverId: String, limit rawLimit: String?, query: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let limit = Self.messagePageLimit(rawLimit)
        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        var records = threadUnfollows.values.filter { $0.serverId == serverId && $0.userId == userId }
        if !needle.isEmpty {
            records = records.filter { record in
                record.frozenMessages.contains { $0.content.localizedCaseInsensitiveContains(needle) }
            }
        }
        records.sort { $0.unfollowedAt > $1.unfollowedAt }
        let page = Array(records.prefix(limit))
        let formatter = ISO8601DateFormatter()
        let items = page.map { record -> String in
            "{\"kind\":\"thread\",\"threadChannelId\":\(jsonString(record.threadChannelId)),\"latestActivityMessageId\":\(jsonString(record.latestMessageId)),\"replyCount\":\(record.replyCount),\"unreadCount\":0,\"hasMention\":false,\"isFollowing\":false,\"unfollowedAt\":\(jsonString(formatter.string(from: record.unfollowedAt)))}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"items\":[\("\(items)")],\"hasMore\":\(records.count > page.count),\"totalCount\":null}")
    }

    @discardableResult
    public func addHumanMessageForTesting(channelId: String, senderId: String, content: String, messageType: String = "chat", senderType: String = "user") -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        humanMessageRows.append(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: nil,
            messageType: messageType,
            senderType: senderType
        ))
        lock.unlock()
        return id
    }

    public func threadFollowerIdsForTesting(threadChannelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return threadFollows.values
            .filter { $0.threadChannelId == threadChannelId }
            .map(\.userId)
            .sorted()
    }

    public func followedThreads(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let follows = threadFollows.values.filter {
            $0.serverId == serverId
                && $0.userId == userId
                && !inboxDoneScopes.contains("\(userId)\n\($0.threadChannelId)")
        }
        var rows: [String] = []
        for follow in follows {
            guard let thread = postableChannels[follow.threadChannelId], thread.deletedAt == nil else { continue }
            if let parentId = thread.parentChannelId, let parent = postableChannels[parentId], parent.deletedAt != nil {
                continue
            }
            if oauth.memberRole(serverId: serverId, userId: userId) == "guest", !guestCanSeeScopeLocked(follow.threadChannelId) {
                continue
            }
            let info = oauth.channelUnreadInfo(channelId: follow.threadChannelId, userId: userId)
            let threadReplies = humanMessageRows.filter { $0.channelId == follow.threadChannelId }
            var unreadCount = info.unreadCount
            if !threadReplies.isEmpty {
                unreadCount = threadReplies.enumerated().filter { index, reply in
                    index + 1 > info.maxReadSeq && reply.senderId != userId
                }.count
            }
            let task = taskRecords.first { $0.messageId == follow.parentMessageId }
            let taskJSON = task.map { jsonString($0.id) } ?? "null"
            let claimedType = task?.assigneeType.map { jsonString($0) } ?? "null"
            let claimedId = task?.assigneeId.map { jsonString($0) } ?? "null"
            var claimedName = "null"
            if let assigneeId = task?.assigneeId, let assigneeType = task?.assigneeType {
                if assigneeType == "user" {
                    if let name = accounts.values.first(where: { $0.id == assigneeId })?.name {
                        claimedName = jsonString(name)
                    }
                } else if let name = oauth.agentRuntimeInfo(id: assigneeId)?.name {
                    claimedName = jsonString(name)
                }
            }
            rows.append("{\"threadChannelId\":\(jsonString(follow.threadChannelId)),\"unreadCount\":\(unreadCount),\"taskId\":\(taskJSON),\"taskClaimedByType\":\(claimedType),\"taskClaimedById\":\(claimedId),\"taskClaimedByName\":\(claimedName)}")
        }
        lock.unlock()
        return Self.json(200, "{\"threads\":[\("\(rows.joined(separator: ","))")]}")
    }

    public func threadInfo(authorization: String?, serverId: String, channelId: String, messageId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        lock.lock()
        let inChannel = humanMessageRows.contains { $0.id == messageId && $0.channelId == channelId }
            || oauth.messageChannelId(messageId) == channelId
        guard inChannel else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        guard let thread = postableChannels.first(where: { _, candidate in
            candidate.serverId == serverId && candidate.kind == "thread"
                && candidate.parentChannelId == channelId && candidate.parentMessageId == messageId
                && candidate.deletedAt == nil
        }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        let replies = humanMessageRows.filter { $0.channelId == thread.key }
        var participants = Set(replies.map(\.senderId))
        if let parent = humanMessageRows.first(where: { $0.id == messageId }) {
            participants.insert(parent.senderId)
        }
        let participantJSON = participants.sorted().map { jsonString($0) }.joined(separator: ",")
        let lastReply = replies.last.map { jsonString(ISO8601DateFormatter().string(from: $0.createdAt)) } ?? "null"
        lock.unlock()
        return Self.json(200, "{\"threadChannelId\":\(jsonString(thread.key)),\"replyCount\":\(replies.count),\"lastReplyAt\":\(lastReply),\"participantIds\":[\("\(participantJSON)")]}")
    }

    public func channelThreadSummaries(authorization: String?, serverId: String?, channelId: String, parentMessageIds rawParentIds: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        lock.lock()
        guard let channel = postableChannels[channelId], channel.serverId == serverId else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let visible = channel.kind == "channel" || channel.memberIds.contains(userId)
        guard visible else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        var threads = postableChannels.filter { _, candidate in
            candidate.serverId == serverId
                && candidate.kind == "thread"
                && candidate.parentChannelId == channelId
                && candidate.deletedAt == nil
        }
        let requestedParents: Set<String>? = {
            guard let rawParentIds, !rawParentIds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Set(rawParentIds.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }()
        if let requestedParents {
            threads = threads.filter { _, thread in
                guard let parentMessageId = thread.parentMessageId else { return false }
                return requestedParents.contains(parentMessageId)
            }
        }
        let orderIndex = Dictionary(uniqueKeysWithValues: threadOrder.enumerated().map { ($1, $0) })
        var orderedThreads = threads.map { (id: $0.key, channel: $0.value) }
        orderedThreads.sort { (orderIndex[$0.id] ?? Int.max) < (orderIndex[$1.id] ?? Int.max) }
        if requestedParents == nil, orderedThreads.count > 100 {
            orderedThreads = Array(orderedThreads.suffix(100))
        }
        threads = Dictionary(uniqueKeysWithValues: orderedThreads.map { ($0.id, $0.channel) })
        var summaries: [String] = []
        for (threadId, thread) in threads {
            guard let parentMessageId = thread.parentMessageId else { continue }
            let replies = humanMessageRows.filter { $0.channelId == threadId }
            var participantSet = Set(replies.map(\.senderId))
            if let parent = humanMessageRows.first(where: { $0.id == parentMessageId }) {
                participantSet.insert(parent.senderId)
            }
            let participants = Array(participantSet).sorted()
            let participantJSON = participants.map { jsonString($0) }.joined(separator: ",")
            let following = threadFollows["\(serverId ?? "")\n\(userId)\n\(threadId)"] != nil
            let unreadInfo = oauth.channelUnreadInfo(channelId: threadId, userId: userId)
            var unreadCount = 0
            var firstUnread: String?
            if following {
                if replies.isEmpty {
                    unreadCount = unreadInfo.unreadCount
                    firstUnread = oauth.firstUnreadMessageId(channelId: threadId, userId: userId)
                } else {
                    var first: String?
                    for (index, reply) in replies.enumerated() where index + 1 > unreadInfo.maxReadSeq && reply.senderId != userId {
                        unreadCount += 1
                        if first == nil { first = reply.id }
                    }
                    firstUnread = first
                }
            }
            let firstUnreadJSON = firstUnread.map { jsonString($0) } ?? "null"
            let latestReplies = replies.filter { $0.messageType != "system" }.suffix(3).map { reply -> String in
                let senderName: String
                let senderDisplay: String
                if reply.senderType == "agent" {
                    let info = oauth.agentRuntimeInfo(id: reply.senderId)
                    senderName = info?.name ?? reply.senderId
                    senderDisplay = info?.displayName ?? senderName
                } else {
                    let name = accounts.values.first { $0.id == reply.senderId }?.name ?? reply.senderId
                    senderName = name
                    senderDisplay = name
                }
                return "{\"preview\":\(jsonString(reply.content)),\"senderType\":\(jsonString(reply.senderType)),\"senderId\":\(jsonString(reply.senderId)),\"senderName\":\(jsonString(senderName)),\"senderDisplayName\":\(jsonString(senderDisplay))}"
            }.joined(separator: ",")
            summaries.append("\(jsonString(parentMessageId)):{\"threadChannelId\":\(jsonString(threadId)),\"replyCount\":\(replies.count),\"latestReplies\":[\(latestReplies)],\"unreadCount\":\(unreadCount),\"firstUnreadMessageId\":\(firstUnreadJSON),\"participantIds\":[\(participantJSON)]}")
        }
        lock.unlock()
        return Self.json(200, "{\(summaries.joined(separator: ","))}")
    }

    public func syncChannelMessages(channelId: String?, sinceSeq: String?, authorization: String?, serverId: String?, limit rawLimit: String? = nil) -> HTTPReply {
        if let channelId, !ServerScope.isUUID(channelId) {
            return Self.json(400, "{\"error\":\"Invalid channel id\"}")
        }
        guard sinceSeq == nil || sinceSeq == "0" || Int(sinceSeq ?? "") != nil else {
            return Self.json(400, "{\"error\":\"Invalid sync cursor\"}")
        }
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        let pageLimit = Self.messagePageLimit(rawLimit)
        if channelId == nil {
            let cursor = Int(sinceSeq ?? "") ?? 0
            lock.lock()
            var visibleChannels: [String] = []
            for (id, channel) in postableChannels {
                guard channel.serverId == serverId, channel.deletedAt == nil, !channel.archived else { continue }
                if channel.kind == "channel" || channel.memberIds.contains(userId) {
                    visibleChannels.append(id)
                }
            }
            var listed: [String] = []
            for id in visibleChannels {
                let rows = humanMessageRows.filter { $0.channelId == id }
                for (index, message) in rows.enumerated() where index + 1 > cursor {
                    listed.append("{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(id)),\"seq\":\(index + 1),\"content\":\(jsonString(message.content))}")
                }
            }
            lock.unlock()
            let page = listed.suffix(pageLimit)
            return Self.json(200, "[\(page.joined(separator: ","))]")
        }
        guard let channelId else {
            return Self.json(400, "{\"error\":\"Invalid channel id\"}")
        }
        lock.lock()
        let visible: Bool = {
            guard let channel = postableChannels[channelId], channel.serverId == serverId else { return false }
            if channel.kind == "channel" { return true }
            let guest = serverId.flatMap { oauth.memberRole(serverId: $0, userId: userId) } == "guest"
            if channel.kind == "thread" {
                if guest { return false }
                if let parentId = channel.parentChannelId,
                   let parent = postableChannels[parentId], parent.kind == "channel" {
                    return true
                }
            }
            return channel.memberIds.contains(userId)
        }()
        let storageChannelId = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId ?? channelId
        let allRows = humanMessageRows.filter { $0.channelId == storageChannelId || $0.channelId == channelId }
        let cursor = Int(sinceSeq ?? "") ?? 0
        let indexed = allRows.enumerated().filter { $0.offset + 1 > cursor }
        let limitedIndexed = Array(indexed.suffix(pageLimit))
        let listed = limitedIndexed.map { index, message -> String in
            var row = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(channelId)),\"seq\":\(index + 1),\"content\":\(jsonString(message.content))"
            if let metadata = forwardMetadataJSONLocked(messageId: message.id, userId: userId, serverId: serverId) {
                row += ",\"actionMetadata\":\(metadata)"
            }
            row += "}"
            return row
        }.joined(separator: ",")
        lock.unlock()
        guard visible else {
            return Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
        }
        let body = "[\(listed)]"
        return Self.json(200, body)
    }

    /// `GET /api/messages/:messageId/mention-deliveries`. Only the author who can still read the channel sees coarse outcomes.
    public func mentionDeliveries(messageId: String, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        guard ServerScope.isUUID(messageId) else {
            return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let message = humanMessageRows.first(where: { $0.id.caseInsensitiveCompare(messageId) == .orderedSame }),
              message.senderType == "user",
              message.senderId == userId,
              messageSearchVisibleLocked(messageChannelId: message.channelId, serverId: serverId, viewer: .user(userId)),
              postableChannels[message.channelId]?.serverId == serverId
        else {
            return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
        }
        let deliveries = storedMentions.filter {
            $0.messageId == message.id && $0.targetType == "agent" && $0.notifiableAtSend
        }.map { mention in
            "{\"targetId\":\(jsonString(mention.targetId)),\(Self.mentionDeliveryFields(handle: mention.handle, terminalCode: mention.terminalCode))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"messageId\":\(jsonString(message.id)),\"deliveries\":[\(deliveries)]}")
    }

    private static func mentionDeliveryFields(handle: String, terminalCode: String?) -> String {
        guard let terminalCode, terminalCode != "INSTRUMENT_FAILED" else {
            return "\"targetHandle\":\(jsonString(handle)),\"outcome\":\"unknown\""
        }
        let category: String
        switch terminalCode {
        case "QUOTA_LIMITED":
            category = "quota"
        case "DELIVERY_REJECTED":
            category = "runtime_error"
        default:
            category = "unclassified"
        }
        return "\"targetHandle\":\(jsonString(handle)),\"outcome\":\"lost\",\"reasonCategory\":\(jsonString(category))"
    }

    /// `GET /api/messages/channel/:channelId`. A non-UUID is `Channel not found`. A UUID the caller cannot see uses the neutral body.
    public func listChannelMessages(channelId: String, authorization: String?, serverId: String?, limit rawLimit: String? = nil, before rawBefore: String? = nil, after rawAfter: String? = nil) -> HTTPReply {
        if let serverId, let userId = sessionUserId(authorization: authorization) {
            lock.lock()
            let threadScope = postableChannels[channelId]?.kind == "thread"
            let guestVisible = guestCanSeeScopeLocked(channelId)
            lock.unlock()
            if threadScope, oauth.memberRole(serverId: serverId, userId: userId) == "guest", !guestVisible {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
        }
        let before = Self.parsePageCursor(rawBefore)
        let after = Self.parsePageCursor(rawAfter)
        if before == .invalid || after == .invalid || (before.value != nil && after.value != nil && rawBefore != nil && rawAfter != nil) {
            return Self.json(400, "{\"error\":\"Invalid message page cursor\",\"code\":\"invalid_message_page_cursor\"}")
        }
        if !ServerScope.isUUID(channelId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let userId: String?
        if case .user(let id) = authorize(authorization) {
            userId = id
        } else {
            userId = nil
        }
        lock.lock()
        let visible: Bool = {
            guard let channel = postableChannels[channelId], channel.serverId == serverId, let userId else { return false }
            if channel.kind == "channel" { return true }
            let guest = serverId.flatMap { oauth.memberRole(serverId: $0, userId: userId) } == "guest"
            if channel.kind == "thread" {
                if guest { return false }
                if let parentId = channel.parentChannelId,
                   let parent = postableChannels[parentId], parent.kind == "channel" {
                    return true
                }
            }
            return channel.memberIds.contains(userId)
        }()
        let storageChannelId = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId ?? channelId
        let rows = humanMessageRows.filter { $0.channelId == storageChannelId || $0.channelId == channelId }
        let cursorRows = rows.enumerated().filter { index, _ in
            let seq = index + 1
            if let before = before.value, seq >= before { return false }
            if let after = after.value, seq <= after { return false }
            return true
        }.map(\.element)
        let pageRows = Array(cursorRows.suffix(Self.messagePageLimit(rawLimit)))
        let highWater = rows.count
        let pageSeqs = pageRows.compactMap { row in rows.firstIndex(where: { $0.id == row.id }).map { $0 + 1 } }
        let isTail = rawBefore == nil && rawAfter == nil
        let coveredFrom = pageSeqs.first ?? (isTail ? 1 : 0)
        let coveredThrough = pageSeqs.last ?? 0
        let coveredAfter = max(0, coveredFrom - 1)
        let pageHasGap = !isTail
        let pageHasNewer = rawBefore != nil
        let completeThroughLatest = isTail
        let windowJSON = "{\"schemaVersion\":1,\"domain\":\"receiver_visible_messages_v1\",\"serverId\":\(jsonString(serverId ?? "")),\"receiverKind\":\"user\",\"receiverId\":\(jsonString(userId ?? "")),\"scopeId\":\(jsonString(channelId)),\"coveredFromSeq\":\(coveredFrom),\"coveredAfterSeq\":\(coveredAfter),\"coveredThroughSeq\":\(coveredThrough),\"remoteHighWaterSeq\":\(highWater),\"hasGap\":\(pageHasGap),\"hasNewer\":\(pageHasNewer),\"completeThroughLatest\":\(completeThroughLatest)}"
        let listed = pageRows.map { message in
            var row = "{\"id\":\(jsonString(message.id)),\"content\":\(jsonString(message.content)),\"attachments\":[\(Self.attachmentJSON(message.attachmentIds))],\"reactions\":[\(reactionJSONLocked(messageId: message.id))],\"mentions\":[\(visibleMentionJSONLocked(messageId: message.id))]"
            if let userId, let metadata = forwardMetadataJSONLocked(messageId: message.id, userId: userId, serverId: serverId) {
                row += ",\"actionMetadata\":\(metadata)"
            }
            row += "}"
            return row
        }.joined(separator: ",")
        let summaries = threadSummariesJSONLocked(parentChannelId: channelId, parentIds: pageRows.map(\.id))
        lock.unlock()
        guard visible else {
            return Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
        }
        return Self.json(200, "{\"messages\":[\(listed)],\"historyLimited\":false,\"messageWindow\":\(windowJSON),\"threadSummariesByParentMessageId\":{\(summaries)}}")
    }

    /// Missing, zero, or non-numeric limits are 50. A positive limit is capped at 200. The page is the newest rows.
    private enum PageCursor: Equatable {
        case absent
        case value(Int)
        case invalid

        var value: Int? {
            if case .value(let value) = self { return value }
            return nil
        }
    }

    private static func parsePageCursor(_ raw: String?) -> PageCursor {
        guard let raw else { return .absent }
        if raw == "0" { return .value(0) }
        guard let parsed = Int(raw), parsed > 0 else { return .invalid }
        return .value(parsed)
    }

    private static func messagePageLimit(_ raw: String?) -> Int {
        guard let raw, let parsed = Int(raw), parsed > 0 else { return 50 }
        return min(parsed, 200)
    }

    /// Summaries for threads whose parent message is on this page. Newest three non-system replies, oldest of those first.
    private func threadSummariesJSONLocked(parentChannelId: String, parentIds: [String]) -> String {
        let parents = Set(parentIds)
        var parts: [String] = []
        for (threadId, thread) in postableChannels {
            guard thread.kind == "thread",
                  thread.deletedAt == nil,
                  thread.parentChannelId == parentChannelId,
                  let parentId = thread.parentMessageId,
                  parents.contains(parentId)
            else { continue }
            let replies = humanMessageRows.filter { $0.channelId == threadId }
            let previews = replies.filter { $0.messageType != "system" }.suffix(3)
            let latest = previews.map { "{\"preview\":\(jsonString($0.content))}" }.joined(separator: ",")
            parts.append("\(jsonString(parentId)):{\"replyCount\":\(replies.count),\"latestReplies\":[\(latest)]}")
        }
        return parts.joined(separator: ",")
    }

    /// Mentions a reader can see: notifiable at send, or later notified.
    private func visibleMentionJSONLocked(messageId: String) -> String {
        storedMentions.filter { row in
            row.messageId == messageId && (row.notifiableAtSend || row.notifiedAt != nil)
        }.map { row in
            "{\"type\":\(jsonString(row.targetType)),\"id\":\(jsonString(row.targetId)),\"name\":\(jsonString(row.handle))}"
        }.joined(separator: ",")
    }

    /// Stores a message row with a fixed id. Reaction short-id tests need a known prefix.
    public func insertHumanMessage(id: String, channelId: String, senderId: String, content: String, messageType: String = "chat", senderType: String = "user", actionKind: String? = nil) {
        lock.lock()
        humanMessageRows.append(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            messageType: messageType,
            senderType: senderType,
            actionKind: actionKind
        ))
        lock.unlock()
    }

    /// Task columns on a source message. A forward must not copy them onto the destination.
    public func setHumanMessageTask(messageId: String, status: String, number: Int, assigneeType: String, assigneeId: String, claimedAt: String, completedAt: String) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].taskStatus = status
            humanMessageRows[index].taskNumber = number
            humanMessageRows[index].taskAssigneeType = assigneeType
            humanMessageRows[index].taskAssigneeId = assigneeId
            humanMessageRows[index].taskClaimedAt = claimedAt
            humanMessageRows[index].taskCompletedAt = completedAt
        }
        lock.unlock()
    }

    /// A mention row search can filter with `mentionTarget=self`. Send only stores mentions of people who are not yet members.
    /// A notifiable agent mention whose delivery ended in a terminal code. The author route projects that code.
    public func recordAgentMentionDelivery(messageId: String, agentId: String, handle: String, terminalCode: String) {
        lock.lock()
        let message = humanMessageRows.first { $0.id == messageId }
        storedMentions.append(StoredMention(
            id: UUID().uuidString.lowercased(),
            messageId: messageId,
            channelId: message?.channelId ?? "",
            senderId: message?.senderId ?? "",
            targetType: "agent",
            targetId: agentId,
            handle: handle,
            notifiableAtSend: true,
            notifiedAt: nil,
            notifiedByType: nil,
            notifiedById: nil,
            notifiedAction: nil,
            terminalCode: terminalCode
        ))
        lock.unlock()
    }

    public func addMessageMention(messageId: String, targetType: String, targetId: String) {
        lock.lock()
        let message = humanMessageRows.first { $0.id == messageId }
        storedMentions.append(StoredMention(
            id: UUID().uuidString.lowercased(),
            messageId: messageId,
            channelId: message?.channelId ?? "",
            senderId: message?.senderId ?? "",
            targetType: targetType,
            targetId: targetId,
            handle: "",
            notifiableAtSend: true,
            notifiedAt: nil,
            notifiedByType: nil,
            notifiedById: nil,
            notifiedAction: nil
        ))
        lock.unlock()
    }

    /// Pins the timestamp used by `sort=recent` message search.
    public func setHumanMessageCreatedAt(messageId: String, createdAt: Date) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].createdAt = createdAt
        }
        lock.unlock()
    }

    public func markMessageSystem(messageId: String) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].messageType = "system"
        }
        lock.unlock()
    }

    public func archiveChannel(channelId: String) {
        lock.lock()
        postableChannels[channelId]?.archived = true
        lock.unlock()
    }

    public func markChannelDeleted(channelId: String) {
        lock.lock()
        postableChannels[channelId]?.deletedAt = Date()
        lock.unlock()
    }

    /// Drops a channel membership. A later send on another channel must not replay this channel's randomId.
    public func removeChannelMember(channelId: String, memberId: String) {
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(memberId)
        lock.unlock()
    }

    public func humanMessageRandomIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.filter { $0.channelId == channelId }.compactMap(\.randomId)
    }

    public func humanMessageIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.filter { $0.channelId == channelId }.map(\.id)
    }

    /// The IANA zone stored for a human send. Human HTTP never returns this column.
    public func storedSenderTimezone(messageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.senderTimezone
    }

    public struct MentionFact: Equatable, Sendable {
        public var targetType: String
        public var targetId: String
        public var notifiableAtSend: Bool
        public var notified: Bool
    }

    public struct InboxFact: Equatable, Sendable {
        public var receiverType: String
        public var receiverId: String
        public var personalMention: Bool = false
        public var unreadEligible: Bool = true

        public init(receiverType: String, receiverId: String, personalMention: Bool = false, unreadEligible: Bool = true) {
            self.receiverType = receiverType
            self.receiverId = receiverId
            self.personalMention = personalMention
            self.unreadEligible = unreadEligible
        }
    }

    public struct MentionActionRecord: Equatable, Sendable {
        public var notified: Bool
        public var notifiedByType: String?
        public var notifiedById: String?
        public var notifiedAction: String?
    }

    /// The stored notify/add row for one resolution id.
    public func mentionActionRecord(id: String) -> MentionActionRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = storedMentions.first(where: { $0.id == id }) else { return nil }
        return MentionActionRecord(
            notified: row.notifiedAt != nil,
            notifiedByType: row.notifiedByType,
            notifiedById: row.notifiedById,
            notifiedAction: row.notifiedAction
        )
    }

    public func channelAgentIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(channelAgentMembers[channelId] ?? []).sorted()
    }

    public func channelMemberIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(postableChannels[channelId]?.memberIds ?? []).sorted()
    }

    /// Mention rows written for this message. Public-channel outsiders stay `notifiableAtSend: false` and unnotified.
    public func messageMentionRows(messageId: String) -> [MentionFact] {
        lock.lock()
        defer { lock.unlock() }
        return storedMentions.filter { $0.messageId == messageId }.map {
            MentionFact(targetType: $0.targetType, targetId: $0.targetId, notifiableAtSend: $0.notifiableAtSend, notified: $0.notifiedAt != nil)
        }
    }

    public func inboxFacts(messageId: String, receiverIds: [String]) -> [InboxFact] {
        lock.lock()
        defer { lock.unlock() }
        let wanted = Set(receiverIds)
        return storedInboxFacts.filter { $0.messageId == messageId && wanted.contains($0.receiverId) }.map {
            InboxFact(
                receiverType: $0.receiverType,
                receiverId: $0.receiverId,
                personalMention: $0.personalMention,
                unreadEligible: $0.unreadEligible
            )
        }
    }

    public func agentDeliveries(agentId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedAgentDeliveries.filter { $0.agentId == agentId }.map(\.messageId)
    }

    public func agentDeliveryChannelTypes(agentId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedAgentDeliveries.filter { $0.agentId == agentId }.map(\.channelType)
    }

    /// `GET /api/channels/inbox`. A DM outsider mention is not an inbox item.
    public func doneInbox(authorization: String?, serverId: String?, limit: Int) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let guest = serverId.flatMap { oauth.memberRole(serverId: $0, userId: userId) } == "guest"
        let scopes = inboxDoneScopes
            .filter { $0.hasPrefix("\(userId)\n") }
            .map { String($0.dropFirst("\(userId)\n".count)) }
            .filter { !guest || guestCanSeeScopeLocked($0) }
            .sorted()
            .prefix(max(0, limit))
        let items = scopes.map { scopeId -> String in
            let kind = postableChannels[scopeId]?.kind == "thread" ? "thread" : "channel"
            let following = threadFollows["\(serverId ?? "")\n\(userId)\n\(scopeId)"] != nil
            let unread = oauth.channelUnreadInfo(channelId: scopeId, userId: userId).unreadCount
            let scopeJSON = jsonString(scopeId)
            if kind == "thread" {
                return "{\"kind\":\"thread\",\"threadChannelId\":\(scopeJSON),\"isFollowing\":\(following),\"unreadCount\":\(unread)}"
            }
            return "{\"kind\":\"channel\",\"channelId\":\(scopeJSON),\"unreadCount\":\(unread)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"items\":[\("\(items)")]}")
    }

    public func threadInboxUndone(authorization: String?, serverId: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let threadId = object["threadChannelId"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid inbox undone request\"}")
        }
        lock.lock()
        guard postableChannels[threadId]?.kind == "thread" else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Inbox scope not found\"}")
        }
        inboxDoneScopes.remove("\(userId)\n\(threadId)")
        lock.unlock()
        _ = serverId
        return Self.json(200, "{\"ok\":true}")
    }

    public func channelInboxDone(authorization: String?, serverId: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelId = object["channelId"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid inbox done request\"}")
        }
        lock.lock()
        let isThread = postableChannels[channelId]?.kind == "thread"
        if isThread {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Inbox scope not found\"}")
        }
        inboxDoneScopes.insert("\(userId)\n\(channelId)")
        lock.unlock()
        _ = serverId
        return Self.json(200, "{\"ok\":true}")
    }

    public func threadInboxDone(authorization: String?, serverId: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let threadId = object["threadChannelId"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid inbox done request\"}")
        }
        lock.lock()
        guard postableChannels[threadId]?.kind == "thread" else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Inbox scope not found\"}")
        }
        inboxDoneScopes.insert("\(userId)\n\(threadId)")
        lock.unlock()
        _ = serverId
        return Self.json(200, "{\"ok\":true}")
    }

    public func inboxReadAll(authorization: String?, serverId: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let serverId, oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        var scopeIds = Set(storedInboxFacts.filter { $0.receiverId == userId && $0.serverId == serverId }.compactMap(\.channelId))
        scopeIds.formUnion(threadFollows.values.filter { $0.serverId == serverId && $0.userId == userId }.map(\.threadChannelId))
        var scopeRows: [String] = []
        for scopeId in scopeIds.sorted() {
            inboxDoneScopes.insert("\(userId)\n\(scopeId)")
            let latest = oauth.channelUnreadInfo(channelId: scopeId, userId: userId).latestSeq ?? 0
            oauth.setChannelReadCursor(channelId: scopeId, userId: userId, seq: latest)
            let key = "\(scopeId)\n\(userId)"
            channelReadVersions[key] = (channelReadVersions[key] ?? 0) + 1
            scopeRows.append("{\"scopeId\":\(jsonString(scopeId)),\"maxReadSeq\":\(latest),\"readStateVersion\":\(channelReadVersions[key] ?? 1)}")
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"markedCount\":\(scopeIds.count),\"scopes\":[\(scopeRows.joined(separator: ","))]}")
    }

    public func addInboxFactForTesting(receiverId: String, serverId: String, channelId: String, messageId: String) {
        lock.lock()
        storedInboxFacts.append(StoredInboxFact(
            messageId: messageId,
            receiverType: "user",
            receiverId: receiverId,
            channelId: channelId,
            serverId: serverId,
            personalMention: false
        ))
        lock.unlock()
    }

    @discardableResult
    public func addChannelMessageForTesting(
        channelId: String,
        content: String,
        senderId: String,
        createdAt: Date = Date(),
        senderType: String = "user",
        messageType: String = "chat"
    ) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        humanMessageRows.append(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: nil,
            messageType: messageType,
            senderType: senderType,
            createdAt: createdAt
        ))
        lock.unlock()
        return id
    }

    @discardableResult
    public func addSystemMessageForTesting(channelId: String, content: String) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        humanMessageRows.append(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: "system",
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "user"
        ))
        lock.unlock()
        return id
    }

    @discardableResult
    public func addExternalProjectionMessageForTesting(
        channelId: String,
        senderName: String,
        content: String,
        externalMessageId: String,
        provider: String = "slack"
    ) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        humanMessageRows.append(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: "external-projection-\(id.prefix(8))",
            content: content,
            randomId: nil,
            messageType: "chat",
            senderType: "external_projection",
            externalMessageId: externalMessageId,
            externalProvider: provider,
            externalSenderName: senderName
        ))
        lock.unlock()
        return id
    }

    public func channelInbox(
        authorization: String?,
        serverId: String?,
        filter: String?,
        query: String? = nil
    ) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        let params = Self.inboxQueryParameters(query)
        let effectiveFilter = params["filter"] ?? filter ?? "all"
        let limit = min(max(Int(params["limit"] ?? "") ?? 30, 1), 100)
        let offset = max(Int(params["offset"] ?? "") ?? 0, 0)
        let ascending = params["sort"] == "asc"
        let channelFilter = params["channelId"].flatMap { $0.isEmpty ? nil : $0 }
        let scope = params["scope"]
        let search = params["q"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        lock.lock()
        let facts = storedInboxFacts
        let doneScopes = inboxDoneScopes
        let mentions = storedMentions
        let follows = threadFollows
        let humanRows = humanMessageRows
        let postable = postableChannels
        lock.unlock()

        var lastFacts: [String: StoredInboxFact] = [:]
        for fact in facts where fact.receiverType == "user" && fact.receiverId == userId {
            guard let scopeId = fact.channelId else { continue }
            if serverId != nil && fact.serverId != serverId { continue }
            if doneScopes.contains("\(userId)\n\(scopeId)") { continue }
            lastFacts[scopeId] = fact
        }

        var visibleScopes: Set<String> = []
        if let serverId {
            visibleScopes = Set(oauth.channelsForServer(serverId: serverId, userId: userId).map(\.id))
        }

        var rows: [InboxRow] = []
        for (scopeId, fact) in lastFacts {
            let scopeServer = fact.serverId ?? postable[scopeId]?.serverId
            if let serverId, let scopeServer, scopeServer != serverId { continue }
            let channel = postable[scopeId]
            let type = channel?.kind ?? oauth.channelType(id: scopeId) ?? "channel"
            if serverId != nil && channel == nil && oauth.channelInfo(id: scopeId) == nil { continue }
            if type == "private" || type == "dm" {
                if !visibleScopes.contains(scopeId) { continue }
            }
            let isThread = type == "thread"
            if let scopeServer, oauth.memberRole(serverId: scopeServer, userId: userId) == "guest",
               !guestCanSeeScopeLocked(scopeId) {
                continue
            }
            let parentChannelId = isThread ? channel?.parentChannelId : nil
            if isThread, let parentChannelId,
               postable[parentChannelId]?.kind == "dm",
               doneScopes.contains("\(userId)\n\(parentChannelId)") { continue }
            let detailMap = inboxMessageDetails(
                scopeId: scopeId,
                history: oauth.historyMessages(channelId: scopeId),
                humans: humanRows
            )
            let scopeMentions = mentions.filter {
                $0.channelId == scopeId
                    && $0.targetType == "user"
                    && $0.targetId == userId
                    && ($0.notifiableAtSend || $0.notifiedAt != nil)
            }
            let unread = oauth.channelUnreadInfo(channelId: scopeId, userId: userId).unreadCount
            let firstUnread = oauth.firstUnreadMessageId(channelId: scopeId, userId: userId)
            let firstMention = scopeMentions
                .map { (messageId: $0.messageId, seq: detailMap[$0.messageId]?.seq ?? 0) }
                .min { $0.seq < $1.seq }?.messageId
            let lastMessageId = fact.messageId
            let detail = detailMap[lastMessageId]
            let isFollowing = follows["\(serverId ?? "")\n\(userId)\n\(scopeId)"] != nil
            rows.append(InboxRow(
                scopeId: scopeId,
                kind: isThread ? "thread" : "channel",
                parentChannelId: parentChannelId,
                lastMessageId: lastMessageId,
                lastActivityAt: detail?.createdAt ?? Date(timeIntervalSince1970: 0),
                searchText: [
                    detail?.content ?? "",
                    detail.map { senderName(senderId: $0.senderId) } ?? "",
                ].joined(separator: " ").lowercased(),
                unreadCount: unread,
                firstUnreadMessageId: firstUnread,
                firstMentionMessageId: firstMention,
                hasMention: !scopeMentions.isEmpty,
                isFollowing: isFollowing,
                isDM: type == "dm" || (isThread && postable[parentChannelId ?? ""]?.kind == "dm")
            ))
        }

        let scopedRows = scope == "dms" ? rows.filter(\.isDM) : rows
        let activeUnreadCount = scopedRows.reduce(0) { $0 + $1.unreadCount }
        let filtered = scopedRows.filter { row in
            switch effectiveFilter {
            case "unread": row.unreadCount > 0
            case "mentions": row.hasMention
            case "unread_mentions": row.unreadCount > 0 && row.hasMention
            default: true
            }
        }.filter { row in
            if let channelFilter {
                let parent = row.kind == "thread" ? (row.parentChannelId ?? row.scopeId) : row.scopeId
                if parent != channelFilter { return false }
            }
            if let search, !search.isEmpty, !row.searchText.contains(search) {
                return false
            }
            return true
        }

        let totalCount = filtered.count
        let totalUnreadCount = filtered.reduce(0) { $0 + $1.unreadCount }
        let sorted = filtered.sorted { left, right in
            if left.lastActivityAt != right.lastActivityAt {
                return ascending ? left.lastActivityAt < right.lastActivityAt : left.lastActivityAt > right.lastActivityAt
            }
            return ascending ? left.scopeId < right.scopeId : left.scopeId > right.scopeId
        }
        let page = Array(sorted.dropFirst(offset).prefix(limit))
        let hasMore = offset + page.count < totalCount

        let items = page.map { row -> String in
            let firstUnread = row.firstUnreadMessageId.map(jsonString) ?? "null"
            let firstMention = row.firstMentionMessageId.map(jsonString) ?? "null"
            if row.kind == "thread" {
                let parent = row.parentChannelId.map(jsonString) ?? "null"
                return "{\"kind\":\"thread\",\"threadChannelId\":\(jsonString(row.scopeId)),\"parentChannelId\":\(parent),\"latestActivityMessageId\":\(jsonString(row.lastMessageId)),\"firstUnreadMessageId\":\(firstUnread),\"firstMentionMessageId\":\(firstMention),\"unreadCount\":\(row.unreadCount),\"hasMention\":\(row.hasMention),\"isFollowing\":\(row.isFollowing)}"
            }
            return "{\"kind\":\"channel\",\"channelId\":\(jsonString(row.scopeId)),\"lastMessageId\":\(jsonString(row.lastMessageId)),\"firstUnreadMessageId\":\(firstUnread),\"firstMentionMessageId\":\(firstMention),\"unreadCount\":\(row.unreadCount),\"hasMention\":\(row.hasMention)}"
        }.joined(separator: ",")

        // Facets keep the query filter but ignore channelId, pagination, and the sort direction.
        var groups: [String: InboxGroup] = [:]
        for row in filtered {
            let groupId = row.kind == "thread" ? (row.parentChannelId ?? row.scopeId) : row.scopeId
            let existing = groups[groupId]
            groups[groupId] = InboxGroup(
                channelId: groupId,
                channelName: oauth.channelInfo(id: groupId)?.name ?? postable[groupId]?.name ?? "",
                channelType: oauth.channelType(id: groupId) ?? postable[groupId]?.kind ?? "channel",
                count: (existing?.count ?? 0) + 1,
                lastActivityAt: max(existing?.lastActivityAt ?? Date(timeIntervalSince1970: 0), row.lastActivityAt)
            )
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let groupItems = groups.values.sorted { left, right in
            let leftDM = left.channelType == "dm"
            let rightDM = right.channelType == "dm"
            if leftDM != rightDM { return leftDM }
            if left.lastActivityAt != right.lastActivityAt { return left.lastActivityAt > right.lastActivityAt }
            if left.channelName != right.channelName { return left.channelName < right.channelName }
            return left.channelId < right.channelId
        }.map { group in
            "{\"channelId\":\(jsonString(group.channelId)),\"channelName\":\(jsonString(group.channelName)),\"channelType\":\(jsonString(group.channelType)),\"count\":\(group.count),\"lastActivityAt\":\(jsonString(formatter.string(from: group.lastActivityAt)))}"
        }.joined(separator: ",")

        return Self.json(
            200,
            "{\"items\":[\(items)],\"hasMore\":\(hasMore),\"totalCount\":\(totalCount),\"totalUnreadCount\":\(totalUnreadCount),\"activeUnreadCount\":\(activeUnreadCount),\"groups\":[\(groupItems)]}"
        )
    }

    private struct InboxRow {
        var scopeId: String
        var kind: String
        var parentChannelId: String?
        var lastMessageId: String
        var lastActivityAt: Date
        var searchText: String
        var unreadCount: Int
        var firstUnreadMessageId: String?
        var firstMentionMessageId: String?
        var hasMention: Bool
        var isFollowing: Bool
        var isDM: Bool
    }

    private struct InboxGroup {
        var channelId: String
        var channelName: String
        var channelType: String
        var count: Int
        var lastActivityAt: Date
    }

    private struct InboxMessageDetail {
        var content: String
        var senderId: String
        var seq: Int
        var createdAt: Date
    }

    private func inboxMessageDetails(
        scopeId: String,
        history: [OAuthLedger.HistoryMessage],
        humans: [StoredHumanMessage]
    ) -> [String: InboxMessageDetail] {
        var details: [String: InboxMessageDetail] = [:]
        for message in history {
            details[message.id] = InboxMessageDetail(
                content: message.content,
                senderId: message.senderId,
                seq: message.seq,
                createdAt: message.createdAt
            )
        }
        for message in humans where message.channelId == scopeId {
            details[message.id] = InboxMessageDetail(
                content: message.content,
                senderId: message.senderId,
                seq: details[message.id]?.seq ?? 0,
                createdAt: message.createdAt
            )
        }
        return details
    }

    private func senderName(senderId: String) -> String {
        if let agent = oauth.agentRuntimeInfo(id: senderId) { return agent.name }
        lock.lock()
        let name = accounts.values.first { $0.id == senderId }?.name
        lock.unlock()
        return name ?? senderId
    }

    private static func inboxQueryParameters(_ query: String?) -> [String: String] {
        guard let query, !query.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let item = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(item[0]).removingPercentEncoding ?? String(item[0])
            let value = item.count == 2 ? (String(item[1]).removingPercentEncoding ?? String(item[1])) : ""
            result[name] = value
        }
        return result
    }


    /// `GET /internal/agent-api/mentions`. Outsider rows stay hidden until they were notifiable at send or later notified.
    public func agentMentionInbox(authorization: String?, limit rawLimit: String? = nil) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        let allowed = credential?.scopes.contains("mentions") == true
        let rows = storedMentions.filter { row in
            row.targetType == "agent"
                && row.targetId == credential?.agentId
                && (row.notifiableAtSend || row.notifiedAt != nil)
        }
        lock.unlock()
        guard allowed else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let pageLimit = Self.messagePageLimit(rawLimit)
        let ordered = rows.reversed()
        let page = Array(ordered.prefix(pageLimit))
        let mentions = page.map { "{\"messageId\":\(jsonString($0.messageId))}" }.joined(separator: ",")
        return Self.json(200, "{\"mentions\":[\(mentions)],\"has_more\":\(rows.count > page.count)}")
    }

    /// `GET /internal/agent-api/wake-hints`. A read credential sees the
    /// undrained third-party events as wake hints.
    public func agentWakeHints(authorization: String?, since: String?) -> HTTPReply {
        switch agentReadCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let agentId):
            let hints = oauth.pendingThirdPartyEventMessages(agentId: agentId).map {
                "{\"seq\":null,\"message_id\":\(jsonString($0.id)),\"wake_reason\":\"message_pending\"}"
            }.joined(separator: ",")
            return Self.json(200, "{\"wake_hints\":[\(hints)]}")
        }
    }

    /// `GET /internal/agent-api/events`. Durable channel messages for the
    /// external agent plus pending third-party events; the call drains both.
    public func agentThirdPartyEvents(authorization: String?) -> HTTPReply {
        switch agentReadCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let agentId):
            guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
                return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            }
            lock.lock()
            let actionEvents = pendingActionMessageEvents.filter { $0.agentId == agentId }
            pendingActionMessageEvents.removeAll { $0.agentId == agentId }
            var channelRows: [(message: StoredHumanMessage, channelName: String, channelType: String, senderName: String)] = []
            for message in humanMessageRows {
                guard message.senderId != agentId,
                      let channel = postableChannels[message.channelId],
                      channel.serverId == agent.serverId,
                      channel.deletedAt == nil
                else { continue }
                let visible = channel.kind == "channel"
                    || channel.memberIds.contains(agentId)
                    || oauth.channelAgentIds(channelId: message.channelId).contains(agentId)
                guard visible else { continue }
                let key = "\(agentId)\n\(message.id)"
                guard !agentChannelInboxDelivered.contains(key) else { continue }
                let senderName = message.externalSenderName
                    ?? accounts.values.first { $0.id == message.senderId }?.name
                    ?? (message.senderId == "system" ? "system" : message.senderId)
                let channelType = channel.kind == "dm" ? "dm" : "channel"
                channelRows.append((message, channel.name, channelType, senderName))
            }
            for row in channelRows {
                agentChannelInboxDelivered.insert("\(agentId)\n\(row.message.id)")
            }
            let mentionedIds = Set(storedMentions.filter {
                $0.targetType == "agent" && $0.targetId == agentId
            }.map(\.messageId))
            lock.unlock()

            var events: [String] = []
            var seq = 0
            for row in channelRows.sorted(by: { $0.message.createdAt < $1.message.createdAt }) {
                seq += 1
                let message = row.message
                let senderType: String
                if message.senderType == "external_projection" {
                    senderType = "third_party_app"
                } else if message.messageType == "system" || message.senderId == "system" {
                    senderType = "system"
                } else if message.senderType == "agent" {
                    senderType = "agent"
                } else {
                    senderType = "human"
                }
                var rowJSON = "{\"seq\":\(seq),\"message_id\":\(jsonString(message.id)),\"sender_id\":\(jsonString(message.senderId)),\"sender_name\":\(jsonString(row.senderName)),\"sender_type\":\(jsonString(senderType)),\"senderType\":\(jsonString(senderType)),\"content\":\(jsonString(message.content)),\"mentioned\":\(mentionedIds.contains(message.id)),\"channel_id\":\(jsonString(message.channelId)),\"channel_name\":\(jsonString(row.channelName)),\"channel_type\":\(jsonString(row.channelType)),\"timestamp\":\(jsonString(Self.isoString(message.createdAt)))"
                if senderType == "third_party_app" {
                    let externalId = message.externalMessageId.map(jsonString) ?? "null"
                    let provider = message.externalProvider.map(jsonString) ?? "null"
                    let actor = message.externalSenderName.map(jsonString) ?? "null"
                    rowJSON += ",\"external_message\":{\"message_id\":\(externalId),\"provider\":\(provider),\"actor_name\":\(actor)}"
                }
                rowJSON += "}"
                events.append(rowJSON)
            }
            for event in actionEvents {
                seq += 1
                events.append("{\"seq\":\(seq),\"message_id\":\(jsonString(event.messageId)),\"sender_type\":\"agent\",\"senderType\":\"agent\",\"content\":\(jsonString(event.content)),\"mentioned\":true}")
            }
            for message in oauth.takeThirdPartyEventMessages(agentId: agentId) {
                seq += 1
                let resource = "urn:raft:server:\(message.serverId):agent-inbound"
                let content = Self.inertThirdPartyMentions(message.summary)
                events.append("{\"seq\":\(seq),\"message_id\":\(jsonString(message.id)),\"sender_type\":\"third_party_app\",\"senderType\":\"third_party_app\",\"content\":\(jsonString(content)),\"mentioned\":false,\"third_party_event\":{\"id\":\(jsonString(message.id)),\"kind\":\(jsonString(message.kind)),\"summary\":\(jsonString(message.summary)),\"source\":{\"client_id\":\(jsonString(message.clientKey)),\"client_name\":\(jsonString(message.clientName)),\"oauth_client_id\":\(jsonString(message.clientRecordId)),\"resource\":\(jsonString(resource))}}}")
            }
            return Self.json(200, "{\"events\":[\(events.joined(separator: ","))]}")
        }
    }

    /// Third-party content stays inert: mentions read as plain `user:<handle>`.
    private static func inertThirdPartyMentions(_ text: String) -> String {
        text.replacingOccurrences(
            of: "@([A-Za-z0-9_.-]+)",
            with: "user:$1",
            options: .regularExpression
        )
    }

    /// `GET /internal/agent-api/wake-hints/stream`. The SSE projection opens
    /// with the same pending hints; reading it does not drain the inbox.
    public func agentWakeHintsStream(authorization: String?, since: String?) -> HTTPReply {
        switch agentReadCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let agentId):
            let raw = (since ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty, raw != "latest" {
                guard let value = Int(raw), value >= 0 else {
                    return Self.json(400, "{\"error\":\"since / Last-Event-ID must be a non-negative integer (messageSeq) or 'latest'\",\"code\":\"since_invalid\"}")
                }
            }
            let frames = oauth.pendingThirdPartyEventMessages(agentId: agentId).map { message in
                let data = "{\"seq\":null,\"message_id\":\(jsonString(message.id)),\"wake_reason\":\"message_pending\"}"
                return "event: wake-hint\nid: null\ndata: \(data)\n\n"
            }.joined()
            let body = ": connected\n\n" + frames
            return HTTPReply(
                status: 200,
                headers: [
                    "X-Robots-Tag": AppFallback.robotsTag,
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-cache, no-transform",
                    "X-Accel-Buffering": "no",
                    "Content-Length": String(Data(body.utf8).count),
                ],
                body: body
            )
        }
    }

    /// `POST /internal/agent-api/third-party-events/delivered`. A managed
    /// daemon reports the events it served locally so they stop replaying.
    public func reportThirdPartyEventsDelivered(authorization: String?, body: String) -> HTTPReply {
        switch agentReadCredential(authorization) {
        case .failure(let reply):
            return reply
        case .success(let agentId):
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            guard let raw = object?["eventIds"] as? [Any], !raw.isEmpty else {
                return Self.json(400, "{\"error\":\"eventIds must be a non-empty array\",\"code\":\"event_ids_invalid\"}")
            }
            var ids: [String] = []
            for item in raw {
                guard let text = item as? String,
                      text.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil
                else {
                    return Self.json(400, "{\"error\":\"eventIds must contain third-party event ids\",\"code\":\"event_ids_invalid\"}")
                }
                ids.append(text.lowercased())
            }
            let delivered = oauth.markThirdPartyEventsDelivered(agentId: agentId, ids: ids)
            return Self.json(200, "{\"ok\":true,\"delivered\":\(delivered)}")
        }
    }

    private enum AgentRead {
        case failure(HTTPReply)
        case success(String)
    }

    private func agentReadCredential(_ authorization: String?) -> AgentRead {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .failure(Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"))
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.scopes.contains("read") else {
            return .failure(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        }
        recordAgentCredentialUse(token: token)
        return .success(credential.agentId)
    }

    /// A raw agent API key. The mentions inbox accepts it when `mentions` is one of the scopes.
    public func mintAgentCredential(agentId: String, scopes: [String], name: String) -> String {
        let key = "sk_agent_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        lock.lock()
        agentCredentials[key] = AgentCredential(agentId: agentId, scopes: Set(scopes), name: name)
        lock.unlock()
        return key
    }

    /// Binds a machine key to one agent. The legacy agent reaction route accepts that bearer.
    public func registerMachineForAgent(serverId: String, agentId: String) -> String {
        let key = "mk_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        lock.lock()
        machineKeys[key] = (serverId: serverId, agentId: agentId)
        lock.unlock()
        return key
    }

    public func addChannelAgent(channelId: String, agentId: String) {
        lock.lock()
        var members = channelAgentMembers[channelId] ?? []
        members.insert(agentId)
        channelAgentMembers[channelId] = members
        lock.unlock()
    }

    public func storedMessageReactionActors(messageId: String) -> [(reactorType: String, reactorId: String)] {
        lock.lock()
        defer { lock.unlock() }
        return messageReactions.filter { $0.messageId == messageId }.map { ($0.reactorType, $0.reactorId) }
    }

    /// Reaction rows still stored for this message. An idempotent add leaves one row; a delete leaves none.
    public func storedMessageReactions(messageId: String) -> [(emoji: String, reactorId: String)] {
        lock.lock()
        defer { lock.unlock() }
        return messageReactions.filter { $0.messageId == messageId }.map { ($0.emoji, $0.reactorId) }
    }

    /// `POST /api/messages/:messageId/reactions`. A second add of the same emoji by the same user does not raise the count.
    public func addMessageReaction(messageId: String, body: String, authorization: String?, serverId: String?) -> HTTPReply {
        mutateMessageReaction(messageId: messageId, body: body, authorization: authorization, serverId: serverId, remove: false)
    }

    /// `DELETE /api/messages/:messageId/reactions`.
    public func removeMessageReaction(messageId: String, body: String, authorization: String?, serverId: String?) -> HTTPReply {
        mutateMessageReaction(messageId: messageId, body: body, authorization: authorization, serverId: serverId, remove: true)
    }

    private func mutateMessageReaction(messageId: String, body: String, authorization: String?, serverId: String?, remove: Bool) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        guard let emoji = Self.reactionEmoji(body) else {
            return Self.json(400, "{\"error\":\"A valid emoji is required\"}")
        }
        lock.lock()
        let message: StoredHumanMessage
        let channel: PostableChannel
        switch resolveReactionTargetLocked(messageId: messageId, userId: userId, serverId: serverId) {
        case .missing:
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        case .ambiguous:
            lock.unlock()
            return Self.json(400, "{\"error\":\"Message short id is ambiguous\"}")
        case .message(let resolvedMessage, let resolvedChannel, _):
            message = resolvedMessage
            channel = resolvedChannel
        }
        if message.messageType == "system" {
            lock.unlock()
            return Self.json(400, "{\"error\":\"System messages cannot receive reactions\"}")
        }
        if !channel.memberIds.contains(userId) {
            lock.unlock()
            return Self.json(403, "{\"error\":\"You must join this channel to react to messages\"}")
        }
        if channel.archived {
            lock.unlock()
            return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
        }
        let changed: Bool
        if remove {
            let before = messageReactions.count
            messageReactions.removeAll { $0.messageId == message.id && $0.emoji == emoji && $0.reactorId == userId && $0.reactorType == "user" }
            changed = messageReactions.count != before
        } else if messageReactions.contains(where: { $0.messageId == message.id && $0.emoji == emoji && $0.reactorId == userId && $0.reactorType == "user" }) {
            changed = false
        } else {
            messageReactions.append(StoredReaction(messageId: message.id, emoji: emoji, reactorId: userId, reactorType: "user"))
            changed = true
        }
        let viewerKey = "\(message.id)\n\(userId)"
        if changed {
            reactionViewerVersions[viewerKey] = (reactionViewerVersions[viewerKey] ?? 0) + 1
            noteDiscussionChangeLocked(messageId: message.id, emoji: emoji)
        }
        let viewerJSON = reactionViewerJSONLocked(messageId: message.id, userId: userId, serverId: serverId ?? "")
        recordedReactionViewerEvents.append(ReactionViewerEvent(
            room: "user:\(userId)",
            name: "reaction_viewer:updated",
            payload: viewerJSON
        ))
        let bodyJSON = finishReactionLocked(message: message, actorId: userId, serverId: serverId, viewerJSON: viewerJSON)
        lock.unlock()
        return Self.json(200, bodyJSON)
    }

    /// `GET /api/messages/:messageId/reactions/viewer`. A cold read uses the same snapshot as the last mutation ACK.
    public func reactionViewer(messageId: String, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        lock.lock()
        switch resolveReactionTargetLocked(messageId: messageId, userId: userId, serverId: serverId) {
        case .missing:
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        case .ambiguous:
            lock.unlock()
            return Self.json(400, "{\"error\":\"Message short id is ambiguous\"}")
        case .message(let message, let channel, _):
            if message.messageType == "system" {
                lock.unlock()
                return Self.json(400, "{\"error\":\"System messages cannot receive reactions\"}")
            }
            if channel.archived {
                lock.unlock()
                return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
            }
            let body = reactionViewerJSONLocked(messageId: message.id, userId: userId, serverId: serverId ?? "")
            lock.unlock()
            return Self.json(200, body)
        }
    }

    /// `POST` and `DELETE /internal/agent/:agentId/messages/:messageId/reactions`. The machine key must belong to that agent.
    public func mutateAgentMessageReaction(agentId: String, messageId: String, body: String, authorization: String?, remove: Bool) -> HTTPReply {
        guard let emoji = Self.reactionEmoji(body) else {
            return Self.json(400, "{\"error\":\"A valid emoji is required\"}")
        }
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        guard let machine = machineKeys[token], machine.agentId == agentId else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let message = humanMessageRows.first(where: { $0.id.caseInsensitiveCompare(messageId) == .orderedSame }),
              postableChannels[message.channelId]?.serverId == machine.serverId,
              channelAgentMembers[message.channelId]?.contains(agentId) == true
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        let bodyJSON = writeAgentReactionLocked(message: message, agentId: agentId, emoji: emoji, serverId: machine.serverId, remove: remove)
        lock.unlock()
        return Self.json(200, bodyJSON)
    }

    /// `POST` and `DELETE /internal/agent-api/messages/:messageId/reactions`. The credential must include `reactions`.
    public func mutateAgentApiMessageReaction(messageId: String, body: String, authorization: String?, remove: Bool) -> HTTPReply {
        guard let emoji = Self.reactionEmoji(body) else {
            return Self.json(400, "{\"error\":\"A valid emoji is required\"}")
        }
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        guard let credential = agentCredentials[token], credential.scopes.contains("reactions"),
              let agent = serverAgents[credential.agentId]
        else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let agentId = credential.agentId
        guard let message = humanMessageRows.first(where: { $0.id.caseInsensitiveCompare(messageId) == .orderedSame }),
              postableChannels[message.channelId]?.serverId == agent.serverId,
              channelAgentMembers[message.channelId]?.contains(agentId) == true
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        let bodyJSON = writeAgentReactionLocked(message: message, agentId: agentId, emoji: emoji, serverId: agent.serverId, remove: remove)
        lock.unlock()
        return Self.json(200, bodyJSON)
    }

    /// `GET /api/messages/:messageId/reactions/actors`. The cursor is bound to the caller, message, emoji, and discussion version.
    public func listReactionActors(messageId: String, authorization: String?, serverId: String?, emoji: String?, limit: String?, cursor: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected:
            return PublicVisits.authRequired(authorization: authorization)
        case .user(let id):
            userId = id
        }
        guard let emoji, let validEmoji = Self.validReactionEmoji(emoji) else {
            return Self.json(400, "{\"error\":\"A valid emoji is required\",\"code\":\"invalid_reaction_emoji\"}")
        }
        let pageLimit: Int
        if let limit {
            guard let parsed = Int(limit), parsed >= 1, parsed <= 100, String(parsed) == limit else {
                return Self.json(400, "{\"error\":\"limit must be an integer between 1 and 100\",\"code\":\"invalid_reaction_actor_limit\"}")
            }
            pageLimit = parsed
        } else {
            pageLimit = 50
        }
        lock.lock()
        let message: StoredHumanMessage
        let channel: PostableChannel
        let localChannelId: String
        switch resolveReactionTargetLocked(messageId: messageId, userId: userId, serverId: serverId) {
        case .missing:
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        case .ambiguous:
            lock.unlock()
            return Self.json(400, "{\"error\":\"Message short id is ambiguous\"}")
        case .message(let resolved, let resolvedChannel, let resolvedLocalId):
            if resolved.messageType == "system" {
                lock.unlock()
                return Self.json(400, "{\"error\":\"System messages cannot receive reactions\"}")
            }
            if resolvedChannel.archived {
                lock.unlock()
                return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
            }
            message = resolved
            channel = resolvedChannel
            localChannelId = resolvedLocalId
        }
        let currentVersion = reactionDiscussionVersions["\(message.id)\n\(validEmoji)"] ?? 0
        var afterKind: String?
        var afterId: String?
        if let cursor {
            guard let decoded = Self.decodeActorCursor(cursor) else {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Invalid reaction actors cursor\",\"code\":\"invalid_reaction_actors_cursor\"}")
            }
            if decoded.principalId != userId || decoded.serverId != (serverId ?? "") || decoded.messageId != message.id || decoded.emoji != validEmoji {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Invalid reaction actors cursor\",\"code\":\"invalid_reaction_actors_cursor\"}")
            }
            let visibility = reactionActorVisibilityLocked(channelId: localChannelId, requesterId: userId)
            if decoded.visibilityHash != visibility.hash {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Reaction actor visibility changed while reading this page\",\"code\":\"reaction_actor_visibility_changed\",\"rebaselineRequired\":true}")
            }
            if decoded.discussionVersion != currentVersion {
                lock.unlock()
                return Self.json(409, "{\"error\":\"Reaction discussion changed while reading this page\",\"code\":\"reaction_discussion_version_changed\",\"currentDiscussionVersion\":\(currentVersion),\"rebaselineRequired\":true}")
            }
            afterKind = decoded.actorKind
            afterId = decoded.actorId
        }
        let visibility = reactionActorVisibilityLocked(channelId: localChannelId, requesterId: userId)
        var actors = messageReactions
            .filter { row in
                row.messageId == message.id && row.emoji == validEmoji && (
                    (row.reactorType == "user" && visibility.humans.contains(row.reactorId))
                    || (row.reactorType == "agent" && visibility.agents.contains(row.reactorId))
                )
            }
            .map { (kind: $0.reactorType, id: $0.reactorId) }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
                return lhs.id < rhs.id
            }
        if let afterKind, let afterId {
            actors = actors.filter { $0.kind > afterKind || ($0.kind == afterKind && $0.id > afterId) }
        }
        let hasMore = actors.count > pageLimit
        let page = Array(actors.prefix(pageLimit))
        let nextCursor: String?
        if hasMore, let last = page.last {
            nextCursor = Self.encodeActorCursor(ActorCursor(
                principalId: userId,
                serverId: serverId ?? "",
                messageId: message.id,
                emoji: validEmoji,
                discussionVersion: currentVersion,
                visibilityHash: visibility.hash,
                actorKind: last.kind,
                actorId: last.id
            ))
        } else {
            nextCursor = nil
        }
        let actorJSON = page.map { "{\"actorRef\":{\"kind\":\(jsonString($0.kind)),\"id\":\(jsonString($0.id))}}" }.joined(separator: ",")
        let cursorJSON = nextCursor.map { jsonString($0) } ?? "null"
        let scopeKind = channel.kind == "thread" ? "thread" : "channel"
        let localServer = jsonString(serverId ?? "")
        let discussion = "{\"root\":{\"kind\":\"message\",\"serverId\":\(localServer),\"id\":\(jsonString(message.id))},\"relation\":{\"kind\":\"reactionActors\",\"emoji\":\(jsonString(validEmoji))},\"parentScope\":{\"serverId\":\(localServer),\"scopeKind\":\(jsonString(scopeKind)),\"scopeId\":\(jsonString(localChannelId))}}"
        lock.unlock()
        return Self.json(200, "{\"discussion\":\(discussion),\"discussionVersion\":\(currentVersion),\"actors\":[\(actorJSON)],\"nextCursor\":\(cursorJSON)}")
    }

    private func writeAgentReactionLocked(message: StoredHumanMessage, agentId: String, emoji: String, serverId: String, remove: Bool) -> String {
        let changed: Bool
        if remove {
            let before = messageReactions.count
            messageReactions.removeAll { $0.messageId == message.id && $0.emoji == emoji && $0.reactorId == agentId && $0.reactorType == "agent" }
            changed = messageReactions.count != before
        } else if messageReactions.contains(where: { $0.messageId == message.id && $0.emoji == emoji && $0.reactorId == agentId && $0.reactorType == "agent" }) {
            changed = false
        } else {
            messageReactions.append(StoredReaction(messageId: message.id, emoji: emoji, reactorId: agentId, reactorType: "agent"))
            changed = true
        }
        if changed {
            noteDiscussionChangeLocked(messageId: message.id, emoji: emoji)
        }
        return finishReactionLocked(message: message, actorId: agentId, serverId: serverId)
    }

    private func noteDiscussionChangeLocked(messageId: String, emoji: String) {
        let key = "\(messageId)\n\(emoji)"
        reactionDiscussionVersions[key] = (reactionDiscussionVersions[key] ?? 0) + 1
    }

    /// On #all, a member of a hidden human directory sees only themself. Agents stay visible. Owners are not hidden.
    private func reactionActorVisibilityLocked(channelId: String, requesterId: String) -> (humans: Set<String>, agents: Set<String>, hash: String) {
        guard let channel = postableChannels[channelId] else { return ([], [], "") }
        let hiddenDirectory = hideHumansFromMembers[channel.serverId] == true
            && serverMemberRoles["\(channel.serverId)\n\(requesterId)"] == "member"
            && channel.name == "all"
            && (channel.kind == "channel" || channel.kind == "private")
        let roster = jointRosterLocked(channelId: channelId) ?? channel.memberIds
        let humans = hiddenDirectory
            ? roster.filter { $0 == requesterId }
            : roster
        let agents = channelAgentMembers[channelId] ?? []
        let hash = humans.sorted().joined(separator: ",") + "|" + agents.sorted().joined(separator: ",")
        return (humans, agents, hash)
    }

    private func finishReactionLocked(message: StoredHumanMessage, actorId: String, serverId: String?, viewerJSON: String? = nil) -> String {
        let reactions = reactionJSONLocked(messageId: message.id)
        let senderName = accounts.values.first { $0.id == message.senderId }?.name ?? "Unknown user"
        let httpMetadata = forwardedBundleJSONLocked(messageId: message.id, userId: actorId, serverId: serverId, scrub: false)
        let socketMetadata = forwardedBundleJSONLocked(messageId: message.id, userId: actorId, serverId: serverId, scrub: true)
        var bodyJSON = "{\"reactions\":[\(reactions)]"
        if let httpMetadata {
            bodyJSON += ",\"actionMetadata\":\(httpMetadata)"
        }
        if let viewerJSON {
            bodyJSON += ",\"reactionViewer\":\(viewerJSON)"
        }
        bodyJSON += "}"
        var payload = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(message.channelId)),\"content\":\(jsonString(message.content)),\"senderName\":\(jsonString(senderName)),\"commentRef\":null,\"reactions\":[\(reactions)]"
        if let socketMetadata {
            payload += ",\"actionMetadata\":\(socketMetadata)"
        }
        payload += "}"
        emitRealtime("channel:\(message.channelId)", "message:updated", payload)
        return bodyJSON
    }

    private func emitRealtime(_ room: String, _ event: String, _ payload: String?) {
        realtimeEmitterLock.lock()
        let emitter = realtimeEmitterStorage
        realtimeEmitterLock.unlock()
        emitter?(room, event, payload)
    }

    /// The HTTP body keeps a forwarded source the viewer can read. The channel broadcast always strips it.
    private func forwardedBundleJSONLocked(messageId: String, userId: String, serverId: String?, scrub: Bool) -> String? {
        guard let items = forwardedBundles[messageId], !items.isEmpty else { return nil }
        let rendered = items.map { item -> String in
            let readable = !scrub && viewerCanReadForwardedSourceLocked(item, userId: userId, serverId: serverId)
            if readable {
                return "{\"sourceServerId\":\(jsonString(item.sourceServerId)),\"sourceTargetId\":\(jsonString(item.sourceTargetId)),\"sourceMessageId\":\(jsonString(item.sourceMessageId)),\"sourceTargetSnapshot\":{\"id\":\(jsonString(item.snapshotId)),\"type\":\(jsonString(item.snapshotType)),\"label\":\(jsonString(item.snapshotLabel)),\"labelVisibility\":\(jsonString(item.snapshotLabelVisibility))},\"provenanceState\":\(jsonString(item.provenanceState))}"
            }
            let type = item.snapshotType.isEmpty ? "channel" : item.snapshotType
            return "{\"sourceMessageId\":null,\"sourceServerId\":null,\"sourceTargetId\":null,\"sourceTargetSnapshot\":{\"id\":null,\"type\":\(jsonString(type)),\"label\":\"\",\"labelVisibility\":\"restricted\"},\"provenanceState\":\"original_unavailable\"}"
        }.joined(separator: ",")
        return "{\"kind\":\"forwarded-bundle\",\"forwardedItems\":[\(rendered)]}"
    }

    private func viewerCanReadForwardedSourceLocked(_ item: ForwardedSource, userId: String, serverId: String?) -> Bool {
        guard item.sourceServerId == serverId,
              let channel = postableChannels[item.sourceTargetId],
              channel.serverId == serverId
        else { return false }
        if channel.kind == "channel" { return true }
        return channel.memberIds.contains(userId)
    }

    private enum ReactionTarget {
        case message(StoredHumanMessage, PostableChannel, String)
        case ambiguous
        case missing
    }

    private struct ActorCursor {
        var principalId: String
        var serverId: String
        var messageId: String
        var emoji: String
        var discussionVersion: Int
        var visibilityHash: String
        var actorKind: String
        var actorId: String
    }

    private static func validReactionEmoji(_ raw: String) -> String? {
        let emoji = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if emoji.isEmpty || emoji.utf16.count > 16 || emoji.contains(where: \.isWhitespace) {
            return nil
        }
        return emoji
    }

    private static func encodeActorCursor(_ cursor: ActorCursor) -> String {
        let json = "{\"principalId\":\(jsonString(cursor.principalId)),\"serverId\":\(jsonString(cursor.serverId)),\"messageId\":\(jsonString(cursor.messageId)),\"emoji\":\(jsonString(cursor.emoji)),\"discussionVersion\":\(cursor.discussionVersion),\"visibilityHash\":\(jsonString(cursor.visibilityHash)),\"actorKind\":\(jsonString(cursor.actorKind)),\"actorId\":\(jsonString(cursor.actorId))}"
        var encoded = Data(json.utf8).base64EncodedString()
        encoded = encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return encoded
    }

    private static func decodeActorCursor(_ raw: String) -> ActorCursor? {
        if raw.isEmpty || raw.utf8.count > 2048 { return nil }
        var base = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base.count % 4
        if remainder != 0 { base += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let principalId = object["principalId"] as? String,
              let serverId = object["serverId"] as? String,
              let messageId = object["messageId"] as? String,
              let emoji = object["emoji"] as? String,
              let visibilityHash = object["visibilityHash"] as? String,
              let actorKind = object["actorKind"] as? String,
              let actorId = object["actorId"] as? String,
              actorKind == "user" || actorKind == "agent"
        else { return nil }
        let version: Int
        if let number = object["discussionVersion"] as? NSNumber {
            version = number.intValue
        } else if let int = object["discussionVersion"] as? Int {
            version = int
        } else {
            return nil
        }
        return ActorCursor(
            principalId: principalId,
            serverId: serverId,
            messageId: messageId,
            emoji: emoji,
            discussionVersion: version,
            visibilityHash: visibilityHash,
            actorKind: actorKind,
            actorId: actorId
        )
    }

    /// A short id counts only messages this user can see. Hidden private rows with the same prefix stay out of the match.
    /// A joint guest resolves the canonical message through that server's local projection.
    private func resolveReactionTargetLocked(messageId: String, userId: String, serverId: String?) -> ReactionTarget {
        if MessageContext.isShortId(messageId) {
            let matches = humanMessageRows.filter {
                Self.messageIdHasShortPrefix($0.id, prefix: messageId) && reactionMessageVisibleLocked($0, userId: userId, serverId: serverId)
            }
            if matches.count > 1 { return .ambiguous }
            if let message = matches.first, let channel = postableChannels[message.channelId] {
                return .message(message, channel, message.channelId)
            }
            return .missing
        }
        guard let message = humanMessageRows.first(where: { $0.id.caseInsensitiveCompare(messageId) == .orderedSame }) else {
            return .missing
        }
        if reactionMessageVisibleLocked(message, userId: userId, serverId: serverId),
           let channel = postableChannels[message.channelId] {
            return .message(message, channel, message.channelId)
        }
        if postableChannels[message.channelId]?.deletedAt == nil,
           let localId = jointLocalChannelIdLocked(canonicalChannelId: message.channelId, serverId: serverId, userId: userId),
           let local = postableChannels[localId],
           local.deletedAt == nil {
            return .message(message, local, localId)
        }
        return .missing
    }

    private func jointLocalChannelIdLocked(canonicalChannelId: String, serverId: String?, userId: String) -> String? {
        guard let serverId else { return nil }
        return jointProjections.first { link in
            link.canonicalChannelId == canonicalChannelId
                && link.serverId == serverId
                && postableChannels[link.localChannelId]?.memberIds.contains(userId) == true
        }?.localChannelId
    }

    /// Members of every local projection of one joint channel. Nil when this channel is not joint.
    private func jointRosterLocked(channelId: String) -> Set<String>? {
        let canonical = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId
            ?? (jointProjections.contains { $0.canonicalChannelId == channelId } ? channelId : nil)
        guard let canonical else { return nil }
        var ids = postableChannels[canonical]?.memberIds ?? []
        for link in jointProjections where link.canonicalChannelId == canonical {
            ids.formUnion(postableChannels[link.localChannelId]?.memberIds ?? [])
        }
        return ids
    }

    /// Public channels are visible to any authenticated user on the server. Private, DM, and thread rows require membership.
    /// A deleted channel is not visible, so the reaction route answers 404 before the archive check.
    private func reactionMessageVisibleLocked(_ message: StoredHumanMessage, userId: String, serverId: String?) -> Bool {
        guard let channel = postableChannels[message.channelId],
              channel.serverId == serverId,
              channel.deletedAt == nil
        else { return false }
        if channel.kind == "channel" { return true }
        return channel.memberIds.contains(userId)
    }

    /// The caller's own emojis, ordered by UTF-16 code units, plus the version that advances only when a row changes.
    private func reactionViewerJSONLocked(messageId: String, userId: String, serverId: String) -> String {
        let version = reactionViewerVersions["\(messageId)\n\(userId)"] ?? 0
        let emojis = messageReactions
            .filter { $0.messageId == messageId && $0.reactorType == "user" && $0.reactorId == userId }
            .map(\.emoji)
            .sorted(by: Self.utf16Ascending)
        let list = emojis.map { jsonString($0) }.joined(separator: ",")
        return "{\"serverId\":\(jsonString(serverId)),\"messageId\":\(jsonString(messageId)),\"viewerVersion\":\(version),\"reactedEmojis\":[\(list)]}"
    }

    private static func utf16Ascending(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        for index in 0..<min(left.count, right.count) where left[index] != right[index] {
            return left[index] < right[index]
        }
        return left.count < right.count
    }

    /// Node `uuidShortIdRange`: the half-open prefix of canonical lowercase UUID text.
    private static func messageIdHasShortPrefix(_ id: String, prefix: String) -> Bool {
        let normalized = prefix.lowercased()
        guard normalized.count == 8, let start = UInt64(normalized, radix: 16) else { return false }
        let value = id.lowercased()
        let lower = normalized + "-0000-0000-0000-000000000000"
        guard value >= lower else { return false }
        let next = start + 1
        if next > 0xffff_ffff { return true }
        let hex = String(next, radix: 16)
        let upper = String(repeating: "0", count: 8 - hex.count) + hex + "-0000-0000-0000-000000000000"
        return value < upper
    }

    /// Node `parseReactionEmoji`: a trimmed string, at most 16 UTF-16 code units, with no whitespace.
    private static func reactionEmoji(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["emoji"] as? String
        else { return nil }
        let emoji = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if emoji.isEmpty || emoji.utf16.count > 16 || emoji.contains(where: \.isWhitespace) {
            return nil
        }
        return emoji
    }

    private func reactionJSONLocked(messageId: String) -> String {
        var order: [String] = []
        var buckets: [String: (ids: [String], names: [String])] = [:]
        for row in messageReactions where row.messageId == messageId {
            if buckets[row.emoji] == nil {
                order.append(row.emoji)
                buckets[row.emoji] = ([], [])
            }
            let name = row.reactorType == "agent"
                ? (serverAgents[row.reactorId]?.name ?? "Unknown agent")
                : (accounts.values.first { $0.id == row.reactorId }?.name ?? "Unknown user")
            var bucket = buckets[row.emoji] ?? ([], [])
            bucket.ids.append(row.reactorId)
            bucket.names.append(name)
            buckets[row.emoji] = bucket
        }
        return order.map { emoji in
            let bucket = buckets[emoji] ?? ([], [])
            let ids = bucket.ids.map { jsonString($0) }.joined(separator: ",")
            let names = bucket.names.map { jsonString($0) }.joined(separator: ",")
            return "{\"emoji\":\(jsonString(emoji)),\"count\":\(bucket.ids.count),\"reactorIds\":[\(ids)],\"reactorNames\":[\(names)]}"
        }.joined(separator: ",")
    }

    public var humanMessageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.count
    }

    private func storeHumanMessage(channelId: String, senderId: String, content: String, randomId: String?, attachmentIds: [String], senderTimezone: String? = nil) -> HTTPReply {
        lock.lock()
        if let randomId, let existing = humanMessageRows.first(where: { $0.senderId == senderId && $0.randomId == randomId }) {
            if existing.channelId != channelId {
                lock.unlock()
                return Self.json(409, "{\"error\":\"randomId has already been used for a different message\",\"code\":\"random_id_conflict\"}")
            }
            let matches = attachmentOrderMatches(message: existing, attachmentIds: attachmentIds, uploaderId: senderId)
            let snapshot = existing
            lock.unlock()
            if matches {
                return Self.humanMessageJSON(snapshot)
            }
            return Self.json(400, "{\"error\":\"This idempotent send was already committed with a different ordered attachment set.\",\"code\":\"attachment_replay_conflict\"}")
        }
        var seenAttachmentIds = Set<String>()
        for id in attachmentIds {
            if seenAttachmentIds.contains(id) {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Attachment \(id) was requested more than once. Send each attachment ID exactly once.\",\"code\":\"attachment_duplicate\"}")
            }
            seenAttachmentIds.insert(id)
            guard let row = channelAttachments[id], row.channelId == channelId, row.uploaderId == senderId else {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Attachment \(id) is not available for this sender. Re-upload the file and send the new attachment ID.\",\"code\":\"attachment_not_found\"}")
            }
            if row.messageId != nil {
                lock.unlock()
                return Self.json(400, "{\"error\":\"Attachment \(id) is already attached to another message. Re-upload the file and send the new attachment ID.\",\"code\":\"attachment_already_linked\"}")
            }
        }
        let stored = StoredHumanMessage(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            senderId: senderId,
            content: content,
            randomId: randomId,
            attachmentIds: attachmentIds,
            senderTimezone: senderTimezone
        )
        for (position, id) in attachmentIds.enumerated() {
            channelAttachments[id]?.messageId = stored.id
            channelAttachments[id]?.messagePosition = position
        }
        humanMessageRows.append(stored)
        recordedChannelMessageEvents.append(ChannelMessageEvent(
            room: "channel:\(channelId)",
            name: "message:new",
            messageId: stored.id,
            attachmentIds: attachmentIds
        ))
        lock.unlock()
        let reply = Self.humanMessageJSON(stored)
        emitRealtime("channel:\(channelId)", "message:new", reply.body)
        return reply
    }

    /// Replay accepts only the stored ids, positions, and uploader. It does not write.
    private func attachmentOrderMatches(message: StoredHumanMessage, attachmentIds: [String], uploaderId: String) -> Bool {
        guard message.attachmentIds.count == attachmentIds.count else { return false }
        for (index, id) in attachmentIds.enumerated() {
            guard message.attachmentIds[index] == id,
                  let row = channelAttachments[id],
                  row.messageId == message.id,
                  row.messagePosition == index,
                  row.uploaderId == uploaderId
            else { return false }
        }
        return true
    }

    public func channelMessageEvents() -> [ChannelMessageEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedChannelMessageEvents
    }

    /// The user behind a normal access token. `requireAuth` does not demand a verified email.
    public func oauthSession(authorization: String?) -> OAuthSession {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return .missing }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        defer { lock.unlock() }
        guard let userId = accessTokens[token],
              let account = accounts.values.first(where: { $0.id == userId })
        else { return .invalid }
        return .user(OAuthHuman(
            id: account.id,
            email: account.email,
            name: account.name,
            emailVerified: account.emailVerified,
            avatarUrl: account.avatarUrl
        ))
    }

    public func login(body: String) -> HTTPReply {
        switch Self.parse(body) {
        case .invalid(let issues):
            return Self.invalid(issues)
        case .request(let request):
            return authenticate(request)
        }
    }

    private func authenticate(_ request: Request) -> HTTPReply {
        let email = Self.normalize(request.email)
        lock.lock()
        let account = accounts[email]
        let matches = account.map { $0.passwordHash == Self.sha256(request.password) } ?? false
        guard let account, matches, account.retiredAt == nil else {
            lock.unlock()
            return Self.rejected
        }
        let issued = openSessionLocked(userId: account.id)
        let body = "{\"user\":{\"id\":\(jsonString(account.id)),\"email\":\(jsonString(account.email))},\"accessToken\":\(jsonString(issued.accessToken)),\"refreshToken\":\(jsonString(issued.refreshToken))}"
        lock.unlock()
        return Self.json(200, body)
    }

    /// `POST /api/auth/me/avatar`. A file over 5 MB is refused before the stored path changes.
    public func uploadAvatar(authorization: String?, contentType: String?, body: Data) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard let file = Self.multipartFile(named: "avatar", contentType: contentType, body: body) else {
            return Self.json(400, "{\"error\":\"No avatar file provided\"}")
        }
        if file.count > Self.maxProfileAvatarBytes {
            return Self.json(400, "{\"error\":\"Avatar image must be 5 MB or smaller\",\"errorCode\":\"PROFILE_AVATAR_TOO_LARGE\",\"maxBytes\":\(Self.maxProfileAvatarBytes)}")
        }
        let hash = String(Self.sha256(file).prefix(32))
        let avatarURL = "/api/avatars/users/\(hash).webp"
        lock.lock()
        guard var account = accounts.values.first(where: { $0.id == userId }) else {
            lock.unlock()
            return Self.invalidToken
        }
        account.avatarUrl = avatarURL
        accounts[account.email] = account
        let snapshot = account
        lock.unlock()
        return Self.json(200, Self.userJSON(snapshot))
    }

    /// `GET /api/auth/me`. The hash is SHA-256 of the stored email, trimmed and lowercased.
    public func me(authorization: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        lock.lock()
        let account = accounts.values.first { $0.id == userId }
        lock.unlock()
        guard let account, account.retiredAt == nil else { return Self.invalidToken }
        var json = Self.userJSON(account)
        lock.lock()
        let observation = timezoneObservations[userId]
        lock.unlock()
        if let observation {
            let extra = String(Self.timezoneJSON(observation).dropFirst())
            if let closing = json.lastIndex(of: "}") {
                json = String(json[..<closing]) + "," + extra
            }
        }
        return Self.json(200, json)
    }

    /// `PATCH /api/auth/me`. A wrong current password is refused before any profile write.
    /// Display language accepts only the shipped UI catalogs, `en` and `zh-cn`.
    public func patch(authorization: String?, body: String) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.json(400, "{\"error\":\"Failed to update profile\"}")
        }

        if let current = object["currentPassword"] as? String, !current.isEmpty,
           let newPassword = object["newPassword"] as? String, !newPassword.isEmpty {
            if newPassword.count < 8 {
                return Self.json(400, "{\"error\":\"New password must be at least 8 characters\"}")
            }
            lock.lock()
            guard var account = accounts.values.first(where: { $0.id == userId }) else {
                lock.unlock()
                return Self.invalidToken
            }
            guard account.passwordHash == Self.sha256(current) else {
                lock.unlock()
                return Self.wrongPassword
            }
            account.passwordHash = Self.sha256(newPassword)
            accounts[account.email] = account
            lock.unlock()
        }

        var languageUpdate: String??
        if object["displayLanguage"] != nil {
            switch Self.parseDisplayLanguage(object["displayLanguage"]!) {
            case .invalid(let message):
                return Self.json(400, "{\"error\":\(jsonString(message))}")
            case .value(let language):
                languageUpdate = language
            }
        } else {
            languageUpdate = nil
        }

        var shareUpdate: Bool?? = nil
        if let raw = object["shareUsageData"] {
            if raw is NSNull {
                shareUpdate = .some(nil)
            } else if let bool = raw as? Bool {
                shareUpdate = .some(bool)
            } else {
                return Self.json(400, "{\"error\":\"shareUsageData must be a boolean or null\"}")
            }
        }

        var languagePreference: String?? = nil
        if let raw = object["preferredLanguage"] {
            if raw is NSNull {
                languagePreference = .some(nil)
            } else if let value = raw as? String,
                      value.wholeMatch(of: /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/) != nil {
                languagePreference = .some(value.lowercased())
            } else {
                return Self.json(400, "{\"error\":\"Unsupported preferredLanguage\"}")
            }
        }
        var timezonePreference: String?? = nil
        if let raw = object["preferredTimezone"] {
            if raw is NSNull {
                timezonePreference = .some(nil)
            } else if let value = raw as? String, TimeZone(identifier: value) != nil {
                timezonePreference = .some(value)
            } else {
                return Self.json(400, "{\"error\":\"Invalid preferredTimezone\"}")
            }
        }
        var modePreference: String? = nil
        if let raw = object["preferredTranslationMode"] {
            guard let value = raw as? String, ["off", "manual", "auto"].contains(value) else {
                return Self.json(400, "{\"error\":\"Invalid preferredTranslationMode\"}")
            }
            modePreference = value
        }
        var autoPreference: Bool? = nil
        if let raw = object["autoTranslationEnabled"] {
            guard let value = raw as? Bool else {
                return Self.json(400, "{\"error\":\"Invalid autoTranslationEnabled\"}")
            }
            autoPreference = value
        }
        var displayPreference: String? = nil
        if let raw = object["preferredTranslationDisplay"] {
            guard let value = raw as? String, ["translated", "bilingual", "original"].contains(value) else {
                return Self.json(400, "{\"error\":\"Invalid preferredTranslationDisplay\"}")
            }
            displayPreference = value
        }
        var timeFormatPreference: String?? = nil
        if let raw = object["preferredTimeFormat"] {
            if raw is NSNull {
                timeFormatPreference = .some(nil)
            } else if let value = raw as? String, ["12h", "24h"].contains(value.lowercased()) {
                timeFormatPreference = .some(value.lowercased())
            } else {
                return Self.json(400, "{\"error\":\"Invalid preferredTimeFormat\"}")
            }
        }
        var fontSizePreference: String?? = nil
        if let raw = object["preferredMessageBodyFontSize"] {
            if raw is NSNull {
                fontSizePreference = .some(nil)
            } else if let value = raw as? String, ["sm", "md", "lg", "xl"].contains(value.lowercased()) {
                fontSizePreference = .some(value.lowercased())
            } else {
                return Self.json(400, "{\"error\":\"Invalid preferredMessageBodyFontSize\"}")
            }
        }

        var referralSourceUpdate: String?? = nil
        var referralOtherUpdate: String?? = nil
        var referralSkipped = false
        if let raw = object["referralSource"] {
            if raw is NSNull {
                referralSourceUpdate = .some(nil)
                referralOtherUpdate = .some(nil)
            } else if let value = raw as? String,
                      ["twitter_x", "linkedin", "friend_colleague", "search", "hn_reddit", "podcast_blog_newsletter", "other"].contains(value) {
                referralSourceUpdate = .some(value)
                if value == "other", let other = object["referralSourceOther"] as? String {
                    let trimmed = String(other.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                    referralOtherUpdate = .some(trimmed.isEmpty ? nil : trimmed)
                } else {
                    referralOtherUpdate = .some(nil)
                }
            } else {
                return Self.json(400, "{\"error\":\"Invalid referralSource\"}")
            }
        } else if object["referralSourceOther"] != nil {
            return Self.json(400, "{\"error\":\"referralSource is required when referralSourceOther is provided\"}")
        }
        if let raw = object["referralSourceSkipped"] {
            guard let value = raw as? Bool else {
                return Self.json(400, "{\"error\":\"referralSourceSkipped must be a boolean\"}")
            }
            referralSkipped = value
        }

        lock.lock()
        guard var account = accounts.values.first(where: { $0.id == userId }) else {
            lock.unlock()
            return Self.invalidToken
        }
        var changed = false
        if let value = referralSourceUpdate {
            account.referralSource = value
            account.referralSourceSkippedAt = nil
            changed = true
        }
        if let value = referralOtherUpdate {
            account.referralSourceOther = value
            changed = true
        }
        if referralSkipped {
            account.referralSourceSkippedAt = Date()
            changed = true
        }
        if let value = languagePreference { account.preferredLanguage = value; changed = true }
        if let value = timezonePreference { account.preferredTimezone = value; changed = true }
        if let value = modePreference { account.preferredTranslationMode = value; changed = true }
        if let value = autoPreference { account.autoTranslationEnabled = value; changed = true }
        if let value = displayPreference { account.preferredTranslationDisplay = value; changed = true }
        if let value = timeFormatPreference { account.preferredTimeFormat = value; changed = true }
        if let value = fontSizePreference { account.preferredMessageBodyFontSize = value; changed = true }
        if let language = languageUpdate {
            account.displayLanguage = language
            changed = true
        }
        if let share = shareUpdate {
            account.shareUsageData = share
            if share == true {
                if analyticsIds[account.id] == nil {
                    analyticsIds[account.id] = UUID().uuidString.lowercased()
                }
            } else if share == false {
                analyticsIds.removeValue(forKey: account.id)
            }
            changed = true
        }
        if changed {
            accounts[account.email] = account
        }
        let snapshot = account
        lock.unlock()
        return Self.json(200, Self.userJSON(snapshot))
    }

    private struct MobileOAuthRequest {
        var id: String
        var provider: String
        var mode: String
        var status: String
        var codeChallenge: String
        var returnUri: String
        var nonce: String
        var expiresAt: Date
        var handoffCode: String? = nil
        var codeHash: String? = nil
        var profileEmail: String? = nil
        var profileUserId: String? = nil
        var profileName: String? = nil
        var userId: String? = nil
    }

    private struct LiveSession {
        var userId: String
        var familyId: String
    }

    private struct SessionFamily {
        var userId: String
        var revokedAt: Date?
        var revokedReason: String?
        var revokeCapabilityNonce: String?
        var capabilityRetainUntil: Date?
    }

    private struct RetirementReceipt {
        var userId: String
        var actorUserId: String
        var environment: String
        var terminalState: String
        var sessionsRevoked: Int
    }

    private struct DeviceGrant {
        var deviceCode: String
        var userCode: String
        var status: String
        var approvedByUserId: String?
        var expiresAt: Date
        var clientName: String?
    }

    private static func deviceLoginEnabled(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return true }
        return !(value == "0" || value == "false" || value == "no" || value == "off")
    }

    private func deviceSurfaceDisabled() -> HTTPReply? {
        if Self.deviceLoginEnabled(deviceLoginGate) { return nil }
        return Self.json(404, "{\"error\":\"Device login is not enabled\",\"code\":\"device_login_disabled\"}")
    }

    private func deviceVerification(userCode: String) -> (uri: String, complete: String)? {
        let trimmed = appURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        let uri = "\(base)/login/device"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        let encoded = userCode.addingPercentEncoding(withAllowedCharacters: allowed) ?? userCode
        return (uri, "\(uri)?user_code=\(encoded)")
    }

    private func makeUserCode() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var chars = ""
        for _ in 0..<8 {
            chars.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return "\(chars.prefix(4))-\(chars.dropFirst(4))"
    }

    private static func deviceSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "dvc_\(encoded)"
    }

    private static func deviceNotReady(_ code: String, status: Int) -> HTTPReply {
        json(status, "{\"error\":\"Device authorization not ready\",\"code\":\(jsonString(code))}")
    }

    private static func deviceUpdateFailed(_ code: String, status: Int) -> HTTPReply {
        json(status, "{\"error\":\"Device authorization could not be updated\",\"code\":\(jsonString(code))}")
    }

    /// Opens one session family. The caller already holds `lock`.
    private func openSessionLocked(userId: String) -> (accessToken: String, refreshToken: String) {
        let familyId = UUID().uuidString.lowercased()
        sessionFamilies[familyId] = SessionFamily(userId: userId, revokedAt: nil)
        let accessToken = Self.token()
        let refreshToken = Self.token()
        sessions[refreshToken] = LiveSession(userId: userId, familyId: familyId)
        accessTokens[accessToken] = userId
        accessTokenFamilies[accessToken] = familyId
        return (accessToken, refreshToken)
    }

    /// Retirement auth keeps the access token after the account is retired. A missing bearer is the invalid-token body.
    private func retirementActor(_ authorization: String?) -> String? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let id = accessTokens[token]
        lock.unlock()
        return id
    }

    private static func stagingCapability(_ value: Any?, into issues: inout [Issue]) -> String? {
        guard let value else { return nil }
        guard let text = value as? String else {
            issues.append(Issue(path: "stagingSelfAccountCapability", message: "Expected string, received \(kind(value))"))
            return nil
        }
        if text.count < 32 {
            issues.append(Issue(path: "stagingSelfAccountCapability", message: "String must contain at least 32 character(s)"))
            return nil
        }
        if text.count > 256 {
            issues.append(Issue(path: "stagingSelfAccountCapability", message: "String must contain at most 256 character(s)"))
            return nil
        }
        return text
    }

    private static func retirementJSON(_ receipt: RetirementReceipt) -> HTTPReply {
        let body = "{\"receipt\":{\"userId\":\(jsonString(receipt.userId)),\"actorUserId\":\(jsonString(receipt.actorUserId)),\"environment\":\(jsonString(receipt.environment)),\"terminalState\":\(jsonString(receipt.terminalState)),\"sessionsRevoked\":\(receipt.sessionsRevoked)}}"
        return json(200, body)
    }

    private struct RotationReceipt {
        var attemptId: String
        var installationId: String
        var userId: String
        var familyId: String
        var successor: String
        var ciphertext: String
        var expiresAt: Date
    }

    private struct IssuedRefresh {
        var accessToken: String
        var userId: String
    }

    private enum RefreshOutcome {
        case rejected
        case rotated(IssuedRefresh, String)
    }

    private func refreshLocked(refreshToken: String, attemptId: String?, installationId: String?) -> RefreshOutcome {
        if let attemptId, let installationId {
            return durableRefreshLocked(refreshToken: refreshToken, attemptId: attemptId, installationId: installationId)
        }
        guard let live = sessions[refreshToken], !revokedFamilies.contains(live.familyId) else {
            return .rejected
        }
        let accessToken = Self.token()
        accessTokens[accessToken] = live.userId
        accessTokenFamilies[accessToken] = live.familyId
        return .rotated(IssuedRefresh(accessToken: accessToken, userId: live.userId), refreshToken)
    }

    private func durableRefreshLocked(refreshToken: String, attemptId: String, installationId: String) -> RefreshOutcome {
        let hash = Self.sha256(refreshToken)
        if let live = sessions.removeValue(forKey: refreshToken) {
            if revokedFamilies.contains(live.familyId) {
                return .rejected
            }
            let successor = Self.token()
            sessions[successor] = live
            let ciphertext = Self.sealSuccessor(successor)
            rotationReceipts[hash] = RotationReceipt(
                attemptId: attemptId,
                installationId: installationId,
                userId: live.userId,
                familyId: live.familyId,
                successor: successor,
                ciphertext: ciphertext,
                expiresAt: Date(timeIntervalSinceNow: 15 * 60)
            )
            let accessToken = Self.token()
            accessTokens[accessToken] = live.userId
            accessTokenFamilies[accessToken] = live.familyId
            return .rotated(IssuedRefresh(accessToken: accessToken, userId: live.userId), successor)
        }
        guard let receipt = rotationReceipts[hash] else { return .rejected }
        if receipt.attemptId != attemptId || receipt.installationId != installationId { return .rejected }
        if receipt.expiresAt <= Date() || revokedFamilies.contains(receipt.familyId) { return .rejected }
        let accessToken = Self.token()
        accessTokens[accessToken] = receipt.userId
        accessTokenFamilies[accessToken] = receipt.familyId
        return .rotated(IssuedRefresh(accessToken: accessToken, userId: receipt.userId), receipt.successor)
    }

    private struct SocialCompletion {
        var provider: String
        var code: String
        var mode: String
        var intendedAction: String
        var email: String
        var returnTo: String
        var userId: String?
        var providerUserId: String?
    }

    private struct LinkedIdentity {
        var userId: String
        var provider: String
        var providerUserId: String
        var providerEmail: String? = nil
    }

    private static let socialProviders: Set<String> = ["google", "github", "apple"]
    private static let defaultMobileReturnURIs: Set<String> = [
        "raft://oauth/callback",
        "raft-alpha://oauth/callback",
        "raft-beta://oauth/callback",
        "raft-debug://oauth/callback",
        "raft-dev://oauth/callback",
    ]

    /// Primary env wins when it parses to at least one URI. Otherwise the legacy list replaces the defaults. An empty parse falls through.
    private func configuredMobileReturnURIs() -> Set<String> {
        let primary = Self.parseConfiguredMobileReturnURIs(mobileOAuthReturnURI)
        if !primary.isEmpty { return primary }
        let legacy = Self.parseConfiguredMobileReturnURIs(mobileOAuthAllowedReturnURIs)
        if !legacy.isEmpty { return legacy }
        return Self.defaultMobileReturnURIs
    }

    private static func parseConfiguredMobileReturnURIs(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        var values: Set<String> = []
        for part in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "\n" }) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { values.insert(trimmed) }
        }
        return values
    }

    private struct Account {
        var id: String
        var email: String
        var passwordHash: String
        var displayLanguage: String?
        var name: String
        var displayName: String? = nil
        var profileSetupSuggestedHandle: String?
        var profileSetupProvider: String? = nil
        var profileSetupCompletedAt: Date? = nil
        var avatarUrl: String? = nil
        var shareUsageData: Bool? = nil
        var emailVerified: Bool = false
        var stagingSelfAccountCapabilityHash: String? = nil
        var retiredAt: Date? = nil
        var preferredLanguage: String? = nil
        var preferredTimezone: String? = nil
        var preferredTranslationMode: String = "off"
        var autoTranslationEnabled: Bool = false
        var preferredTranslationDisplay: String = "translated"
        var preferredTimeFormat: String? = nil
        var preferredMessageBodyFontSize: String? = nil
        var referralSource: String? = nil
        var referralSourceOther: String? = nil
        var referralSourceSkippedAt: Date? = nil
    }

    private struct Request {
        var email: String
        var password: String
    }

    private struct Issue {
        var path: String
        var message: String
    }

    private enum Parsed {
        case request(Request)
        case invalid([Issue])
    }

    private static func parse(_ body: String) -> Parsed {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .invalid([Issue(path: "", message: "Expected object, received string")])
        }
        var issues: [Issue] = []
        let email = stringField(object["email"], path: "email", into: &issues)
        let password = stringField(object["password"], path: "password", into: &issues)
        if !issues.isEmpty { return .invalid(issues) }
        return .request(Request(email: email ?? "", password: password ?? ""))
    }

    private struct JointChannelLink {
        var localChannelId: String
        var canonicalChannelId: String
        var serverId: String
    }

    private struct PostableChannel {
        var serverId: String
        var memberIds: Set<String>
        var kind: String = "channel"
        var agentId: String? = nil
        var parentChannelId: String? = nil
        var parentMessageId: String? = nil
        var archived: Bool = false
        var deletedAt: Date? = nil
        var name: String = ""
    }

    private struct StoredMention {
        var id: String
        var messageId: String
        var channelId: String
        var senderId: String
        var targetType: String
        var targetId: String
        var handle: String
        var notifiableAtSend: Bool
        var notifiedAt: Date?
        var notifiedByType: String?
        var notifiedById: String?
        var notifiedAction: String?
        var terminalCode: String? = nil
    }

    private struct StoredInboxFact {
        var messageId: String
        var receiverType: String
        var receiverId: String
        var channelId: String?
        var serverId: String?
        var personalMention: Bool
        var unreadEligible: Bool = true
    }

    private struct AgentCredential {
        var id: String = UUID().uuidString.lowercased()
        var agentId: String
        var scopes: Set<String>
        var name: String
        var createdAt: Date = Date()
        var lastUsedAt: Date?
        var revokedAt: Date?
    }

    private struct MentionInput {
        var type: String
        var id: String
        var name: String
    }

    private struct ServerAgent {
        var id: String
        var serverId: String
        var name: String
        var avatarUrl: String?
        var status: String = "inactive"
    }

    private struct JoinLinkRecord {
        var id: String
        var token: String
        var serverId: String
        var role: String
        var createdAt: Date
        var expiresAt: Date?
        var maxUses: Int?
        var useCount: Int
        var revokedAt: Date?
    }

    private struct SystemAttentionIncident {
        var id: String
        var serverId: String
        var machineId: String
        var provider: String
        var windowKey: String
        var activationGeneration: Int
        var affectedAgentIds: [String]
        var activatedAt: Date
        var lastObservedAt: Date
        var resetsAt: Date?
        var state: String
    }

    private struct SystemAttentionReceipt {
        var seenAt: Date?
        var dismissedAt: Date?
    }

    private struct StoredReaction {
        var messageId: String
        var emoji: String
        var reactorId: String
        var reactorType: String
    }

    private struct StoredHumanMessage {
        var id: String
        var channelId: String
        var senderId: String
        var content: String
        var randomId: String?
        var attachmentIds: [String] = []
        var messageType: String = "chat"
        var senderType: String = "user"
        var createdAt: Date = Date()
        var actionKind: String? = nil
        var taskStatus: String? = nil
        var taskNumber: Int? = nil
        var taskAssigneeType: String? = nil
        var taskAssigneeId: String? = nil
        var taskClaimedAt: String? = nil
        var taskCompletedAt: String? = nil
        var senderTimezone: String? = nil
        var externalMessageId: String? = nil
        var externalProvider: String? = nil
        var externalSenderName: String? = nil
    }

    public func removeChannelMemberForTesting(channelId: String, userId: String) {
        oauth.removeChannelHuman(channelId: channelId, userId: userId)
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(userId)
        lock.unlock()
    }

    public func setChannelGuestVisibleForTesting(channelId: String, visible: Bool) {
        lock.lock()
        guestVisibleChannels[channelId] = visible
        lock.unlock()
    }

    private func guestCanSeeScopeLocked(_ scopeId: String) -> Bool {
        if postableChannels[scopeId]?.kind == "thread",
           let parentId = postableChannels[scopeId]?.parentChannelId {
            return guestVisibleChannels[parentId] ?? true
        }
        return guestVisibleChannels[scopeId] ?? true
    }

    public func setChannelPostablePrivateForTesting(channelId: String) {
        lock.lock()
        postableChannels[channelId]?.kind = "private"
        lock.unlock()
    }

    public func agentApiIdentity(authorization: String?) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        guard let credential = agentCredentials[token], credential.revokedAt == nil else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let agentId = credential.agentId
        let credentialId = credential.id
        let scopes = credential.scopes.sorted()
        lock.unlock()
        recordAgentCredentialUse(token: token)
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let scopesJSON = scopes.map { jsonString($0) }.joined(separator: ",")
        return Self.json(200, "{\"agentId\":\(jsonString(agentId)),\"credentialId\":\(jsonString(credentialId)),\"serverId\":\(jsonString(agent.serverId)),\"scopes\":[\(scopesJSON)]}")
    }

    public func agentAttachmentUploadCapabilities(authorization: String?) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted,
              let profile = oauth.serverProfile(id: agent.serverId)
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let limit = profile.plan == "free" ? 50 * 1024 * 1024 : 90 * 1024 * 1024
        return Self.json(200, "{\"directUploadEnabled\":false,\"directUploadThresholdBytes\":null,\"maxBytes\":\(limit),\"sessionExpiresInSeconds\":null}")
    }

    public func attachmentUploadSessionCreate(authorization: String?, serverId: String) -> HTTPReply {
        guard sessionUserId(authorization: authorization) != nil else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: sessionUserId(authorization: authorization) ?? "") != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        return Self.json(403, "{\"code\":\"UPLOAD_FORBIDDEN\",\"message\":\"The member cannot upload to this channel.\",\"retryable\":false}")
    }

    public func attachmentUploadSessionMissing(authorization: String?, uploadId: String) -> HTTPReply {
        guard sessionUserId(authorization: authorization) != nil else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        return Self.json(404, "{\"code\":\"UPLOAD_SESSION_NOT_FOUND\",\"message\":\"Upload session not found.\",\"retryable\":false}")
    }

    public func attachmentUploadCapabilities(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let profile = oauth.serverProfile(id: serverId), oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let limit = profile.plan == "free" ? 50 * 1024 * 1024 : 90 * 1024 * 1024
        return Self.json(200, "{\"directUploadEnabled\":false,\"directUploadThresholdBytes\":null,\"maxBytes\":\(limit),\"sessionExpiresInSeconds\":null}")
    }

    public func addChannelAttachmentForTesting(channelId: String, id: String, uploaderId: String, filename: String) {
        lock.lock()
        channelAttachments[id] = ChannelAttachment(id: id, channelId: channelId, uploaderId: uploaderId, filename: filename, messageId: nil, messagePosition: nil)
        lock.unlock()
    }

    public func addChannelFileForTesting(
        channelId: String,
        id: String,
        uploaderId: String,
        uploaderType: String = "user",
        messageId: String,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        createdAt: Date,
        thumbnailKey: String? = nil
    ) {
        lock.lock()
        channelAttachments[id] = ChannelAttachment(
            id: id,
            channelId: channelId,
            uploaderId: uploaderId,
            filename: filename,
            messageId: messageId,
            messagePosition: 0,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            uploaderType: uploaderType,
            createdAt: createdAt,
            thumbnailKey: thumbnailKey
        )
        lock.unlock()
    }

    private func visibleAttachment(userId: String, serverId: String?, attachment: ChannelAttachment) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = postableChannels[attachment.channelId], channel.serverId == serverId, channel.deletedAt == nil else {
            return false
        }
        return channel.kind == "channel" || channel.memberIds.contains(userId)
    }

    private static func channelFilesBase64URLEncode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func channelFilesBase64URLDecode(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func channelFilesLimit(_ raw: String?) -> Int {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = Double(raw), value.isFinite
        else { return 500 }
        return max(1, min(Int(value.rounded(.down)), 500))
    }

    private static func channelFileMimeType(filename: String, stored: String?) -> String {
        if let stored, !stored.isEmpty { return stored }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }

    public func channelFiles(
        authorization: String?,
        serverId: String,
        channelId: String,
        limit rawLimit: String? = nil,
        cursor rawCursor: String? = nil
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = postableChannels[channelId] ?? nil,
              channel.serverId == serverId,
              channel.deletedAt == nil
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let kind = channel.kind
        let isMember = channel.memberIds.contains(userId)
        guard kind == "channel" || isMember else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let limit = Self.channelFilesLimit(rawLimit)
        let cursor: (createdAt: Date, id: String)?
        if let rawCursor, !rawCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let decoded = Self.channelFilesBase64URLDecode(rawCursor),
                  let object = (try? JSONSerialization.jsonObject(with: Data(decoded.utf8))) as? [String: Any],
                  let createdAtRaw = object["createdAt"] as? String,
                  let createdAt = Self.isoDate(createdAtRaw),
                  let id = object["id"] as? String
            else {
                return Self.json(400, "{\"error\":\"Invalid cursor\"}")
            }
            cursor = (createdAt, id)
        } else {
            cursor = nil
        }

        lock.lock()
        var scopeChannels: Set<String> = [channelId]
        for (id, candidate) in postableChannels
        where candidate.serverId == serverId && candidate.kind == "thread"
            && candidate.parentChannelId == channelId && candidate.deletedAt == nil {
            scopeChannels.insert(id)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var files: [ChannelAttachment] = []
        for attachment in channelAttachments.values {
            guard scopeChannels.contains(attachment.channelId) else { continue }
            if let messageId = attachment.messageId,
               !humanMessageRows.contains(where: { $0.id == messageId && $0.channelId == attachment.channelId }) {
                continue
            }
            if let cursor {
                if attachment.createdAt > cursor.createdAt { continue }
                if attachment.createdAt == cursor.createdAt && attachment.id >= cursor.id { continue }
            }
            files.append(attachment)
        }
        files.sort { left, right in
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id > right.id
        }
        let page = Array(files.prefix(limit))
        let nextCursor: String?
        if files.count > limit, let last = page.last {
            let encoded = "{\"createdAt\":\(jsonString(formatter.string(from: last.createdAt))),\"id\":\(jsonString(last.id))}"
            nextCursor = Self.channelFilesBase64URLEncode(encoded)
        } else {
            nextCursor = nil
        }
        let rows = page.map { attachment -> String in
            let source = postableChannels[attachment.channelId]
            let isThread = source?.kind == "thread"
            let parentMessageId = isThread ? source?.parentMessageId : nil
            let parentJSON = parentMessageId.map(jsonString) ?? "null"
            let parentShort = parentMessageId.map { jsonString(String($0.prefix(8))) } ?? "null"
            let uploaderName: String?
            let uploaderDisplay: String?
            if attachment.uploaderType == "agent" {
                let agent = oauth.agentRuntimeInfo(id: attachment.uploaderId)
                uploaderName = agent?.name
                uploaderDisplay = agent?.displayName
            } else if attachment.uploaderType == "user" {
                let account = accounts.values.first { $0.id == attachment.uploaderId }
                uploaderName = account?.name
                uploaderDisplay = account?.name
            } else {
                uploaderName = nil
                uploaderDisplay = nil
            }
            let nameJSON = uploaderName.map(jsonString) ?? "null"
            let displayJSON = (uploaderDisplay ?? uploaderName).map(jsonString) ?? "null"
            let mime = Self.channelFileMimeType(filename: attachment.filename, stored: attachment.mimeType)
            let size = attachment.sizeBytes.map(String.init) ?? "null"
            let width = attachment.width.map(String.init) ?? "null"
            let height = attachment.height.map(String.init) ?? "null"
            let thumbnail = attachment.thumbnailKey.map { _ in jsonString("/api/attachments/\(attachment.id)/thumbnail") } ?? "null"
            return "{\"id\":\(jsonString(attachment.id)),\"messageId\":\(jsonString(attachment.messageId ?? "")),\"channelId\":\(jsonString(attachment.channelId)),\"filename\":\(jsonString(attachment.filename)),\"mimeType\":\(jsonString(mime)),\"sizeBytes\":\(size),\"width\":\(width),\"height\":\(height),\"thumbnailUrl\":\(thumbnail),\"createdAt\":\(jsonString(formatter.string(from: attachment.createdAt))),\"uploader\":{\"type\":\(jsonString(attachment.uploaderType == "agent" ? "agent" : "user")),\"id\":\(jsonString(attachment.uploaderId)),\"name\":\(nameJSON),\"displayName\":\(displayJSON)},\"source\":{\"type\":\(jsonString(isThread ? "thread" : "channel")),\"channelId\":\(jsonString(attachment.channelId)),\"parentMessageId\":\(parentJSON),\"parentMessageShortId\":\(parentShort)}}"
        }
        lock.unlock()
        let nextJSON = nextCursor.map(jsonString) ?? "null"
        return Self.json(200, "{\"files\":[\(rows.joined(separator: ","))],\"nextCursor\":\(nextJSON)}")
    }

    public func readAttachment(authorization: String?, serverId: String?, attachmentId: String, kind: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let attachment = channelAttachments[attachmentId]
        lock.unlock()
        guard let attachment, visibleAttachment(userId: userId, serverId: serverId, attachment: attachment) else {
            return Self.json(404, "{\"error\":\"Attachment not found\"}")
        }
        switch kind {
        case "url":
            return Self.json(200, "{\"url\":\"\(jsonString("/api/attachments/\(attachmentId)"))\"}")
        case "html-preview-url":
            return Self.json(200, "{\"url\":\"\(jsonString("/api/attachments/\(attachmentId)/html-preview"))\"}")
        default:
            return Self.json(200, "{\"id\":\(jsonString(attachment.id)),\"filename\":\(jsonString(attachment.filename)),\"mimeType\":\(attachment.mimeType.map { jsonString($0) } ?? "null")}")
        }
    }

    private struct ChannelAttachment {
        var id: String
        var channelId: String
        var uploaderId: String
        var filename: String
        var messageId: String?
        var messagePosition: Int?
        var mimeType: String? = nil
        var sizeBytes: Int? = nil
        var width: Int? = nil
        var height: Int? = nil
        var uploaderType: String = "user"
        var createdAt: Date = Date()
        var thumbnailKey: String? = nil
        var storageKey: String? = nil
    }

    public struct ChannelMessageEvent: Equatable, Sendable {
        public var room: String
        public var name: String
        public var messageId: String
        public var attachmentIds: [String]
    }

    private static func attachmentJSON(_ ids: [String]) -> String {
        ids.map { "{\"id\":\(jsonString($0))}" }.joined(separator: ",")
    }

    private static func humanMessageJSON(_ message: StoredHumanMessage) -> HTTPReply {
        var body = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(message.channelId)),\"content\":\(jsonString(message.content)),\"attachments\":[\(attachmentJSON(message.attachmentIds))]"
        if let randomId = message.randomId {
            body += ",\"randomId\":\(jsonString(randomId))"
        }
        body += "}"
        return json(200, body)
    }

    /// App ids inside `<app:…>` outside of a code fence are not required for this check; the send under test has no fence.
    private static func appReferenceIds(_ content: String) -> [String] {
        var ids: [String] = []
        for match in content.matches(of: /<app:([a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+)>/) {
            let id = String(match.1)
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Best-effort browser zone. A missing, non-string, empty, overlong, or non-canonical value is null.
    private static func parseOptionalIanaTimezone(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 128 { return nil }
        if trimmed != "UTC" && !trimmed.contains("/") { return nil }
        if trimmed == "UTC" { return "UTC" }
        guard let zone = TimeZone(identifier: trimmed) else { return nil }
        let canonical = zone.identifier
        if canonical != "UTC" && !canonical.contains("/") { return nil }
        return canonical
    }

    private static func humanMessageBodyIsValid(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channelId = object["channelId"] as? String,
              ServerScope.isUUID(channelId)
        else { return false }
        if let attachments = object["attachmentIds"] {
            guard let ids = attachments as? [Any] else { return false }
            for id in ids {
                guard let string = id as? String, ServerScope.isUUID(string) else { return false }
            }
        }
        if object["asTask"] != nil {
            guard object["asTask"] is Bool else { return false }
        }
        return true
    }

    private static func featureFlagKey(_ value: Any) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^[a-z0-9][a-z0-9_.-]{0,127}$/) != nil else { return nil }
        return trimmed
    }

    private static func stringField(_ value: Any?, path: String, into issues: inout [Issue]) -> String? {
        guard let value else {
            issues.append(Issue(path: path, message: "Required"))
            return nil
        }
        if let string = value as? String {
            if string.isEmpty {
                issues.append(Issue(path: path, message: "String must contain at least 1 character(s)"))
                return nil
            }
            return string
        }
        issues.append(Issue(path: path, message: "Expected string, received \(kind(value))"))
        return nil
    }

    private static func kind(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if value is NSDictionary { return "object" }
        if value is NSArray { return "array" }
        if value is Bool { return "boolean" }
        if value is NSNumber { return "number" }
        return "object"
    }

    private static func invalid(_ issues: [Issue]) -> HTTPReply {
        bodyIssues(issues, error: "Invalid email login body", code: "email_login_body_invalid")
    }

    private static func registerInvalid(_ issues: [Issue]) -> HTTPReply {
        bodyIssues(issues, error: "Invalid email registration body", code: "email_register_body_invalid")
    }

    private static func bodyIssues(_ issues: [Issue], error: String, code: String) -> HTTPReply {
        let listed = issues.map {
            "{\"path\":\(jsonString($0.path)),\"message\":\(jsonString($0.message))}"
        }.joined(separator: ",")
        return json(400, "{\"error\":\(jsonString(error)),\"code\":\(jsonString(code)),\"issues\":[\(listed)]}")
    }

    private static let rejected = json(401, "{\"code\":\"AUTH_INVALID_CREDENTIALS\",\"error\":\"Invalid email or password\"}")
    private static let missingAuthorization = json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
    private static let invalidToken = json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
    private static let wrongPassword = json(401, "{\"code\":\"AUTH_CURRENT_PASSWORD_INCORRECT\",\"error\":\"Current password is incorrect\"}")
    private static let linkAuthRequired = json(401, "{\"code\":\"auth_required\",\"error\":\"Authentication is required to link an account\"}")
    private static let linkMismatch = json(403, "{\"code\":\"link_user_mismatch\",\"error\":\"Social auth link does not match the authenticated user\"}")
    private static let mobileLinkMismatch = json(403, "{\"code\":\"link_user_mismatch\",\"error\":\"Mobile OAuth link request does not match the authenticated user\"}")
    private static let legalObject = "{\"termsVersion\":\"\(termsVersion)\",\"privacyVersion\":\"\(privacyVersion)\",\"termsUrl\":\"\(termsURL)\",\"privacyUrl\":\"\(privacyURL)\"}"
    private static let legalRequired = json(422, "{\"error\":\"LEGAL_ACCEPTANCE_REQUIRED\",\"legal\":\(legalObject)}")
    private static let returnURINotAllowed = json(400, "{\"code\":\"return_uri_not_allowed\",\"error\":\"Mobile OAuth return URI is not allowed\"}")
    private static let termsChanged = json(409, "{\"error\":\"TERMS_CHANGED\",\"legal\":\(legalObject)}")

    private enum Auth {
        case user(String)
        case rejected(HTTPReply)
    }

    /// The user id behind a live access token. A missing or unknown bearer is nil.
    public func sessionUserId(authorization: String?) -> String? {
        if case .user(let id) = authorize(authorization) { return id }
        return nil
    }

    /// Access-token identity used by the socket layer. The family id scopes
    /// revocation to the connection family that owns the token.
    public func sessionIdentity(accessToken: String) -> (userId: String, familyId: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let userId = accessTokens[accessToken] else { return nil }
        return (userId, accessTokenFamilies[accessToken])
    }

    /// Resolve a `push/family-revoke` capability without consuming it.
    public func familyRevokeTarget(capability: String) -> (userId: String, familyId: String)? {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let familyId = sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key,
              let family = sessionFamilies[familyId]
        else { return nil }
        return (family.userId, familyId)
    }

    public func setShareUsageData(userId: String, value: Bool?) {
        lock.lock()
        if let key = accounts.first(where: { $0.value.id == userId })?.key {
            accounts[key]?.shareUsageData = value
        }
        lock.unlock()
    }

    public func recordedProductEvents(subjectId: String) -> [RecordedProductEvent] {
        lock.lock()
        defer { lock.unlock() }
        return productEventRecords.filter { $0.subjectId == subjectId }
    }

    /// `GET /api/product-events/config`.
    public func clientEventsConfig(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let allowed = accounts.values.first(where: { $0.id == userId })?.shareUsageData == true
        lock.unlock()
        return Self.json(200, "{\"clientEventsAllowed\":\(allowed)}")
    }

    public func recordedClientEvents(serverId: String) -> [ClientEventRecord] {
        lock.lock()
        defer { lock.unlock() }
        return clientEventRecords.filter { $0.serverId == serverId }
    }

    /// `POST /api/product-events/batch`.
    public func clientEventsBatch(
        authorization: String?,
        serverId: String,
        userAgent: String,
        country: String,
        body: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let allowed = accounts.values.first(where: { $0.id == userId })?.shareUsageData == true
        lock.unlock()
        guard allowed else {
            return Self.json(202, "{\"accepted\":0}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              object["source"] as? String == "web",
              let events = object["events"] as? [[String: Any]], !events.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid event batch\"}")
        }
        let appVersion = object["app_version"] as? String
        if let appVersion, appVersion.wholeMatch(of: /^[0-9]+\.[0-9]+\.[0-9]+$/) == nil {
            return Self.json(400, "{\"error\":\"Invalid app_version\"}")
        }
        let uuidPattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        let now = Date()
        var rows: [ClientEventRecord] = []
        var batchSeen: Set<String> = []
        for event in events {
            guard let uuid = event["uuid"] as? String, uuid.wholeMatch(of: uuidPattern) != nil,
                  let name = event["event"] as? String,
                  let timestamp = event["timestamp"] as? String,
                  let parsed = formatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp),
                  let session = event["client_session_id"] as? String,
                  session.wholeMatch(of: uuidPattern) != nil,
                  let properties = event["properties"] as? [String: Any]
            else {
                return Self.json(400, "{\"error\":\"Invalid event batch\"}")
            }
            if now.timeIntervalSince(parsed) > 7 * 24 * 60 * 60 { continue }
            if seenClientEventIDs.contains(uuid) || !batchSeen.insert(uuid).inserted { continue }
            var sanitized: [String: Any] = [:]
            let allowedKeys: Set<String>
            if name == "activity_open" {
                allowedKeys = ["from"]
            } else if name == "activity_mark" {
                allowedKeys = ["action"]
            } else {
                continue
            }
            guard Set(properties.keys).isSubset(of: allowedKeys) else { continue }
            for (key, value) in properties {
                if let text = value as? String { sanitized[key] = text }
            }
            for (key, value) in Self.deviceContext(userAgent: userAgent, country: country) {
                sanitized[key] = value
            }
            let propertiesJSON: String
            if let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]) {
                propertiesJSON = String(decoding: data, as: UTF8.self)
            } else {
                propertiesJSON = "{}"
            }
            let analyticsId: String
            lock.lock()
            if let existing = analyticsIds[userId] {
                analyticsId = existing
            } else {
                let minted = UUID().uuidString.lowercased()
                analyticsIds[userId] = minted
                analyticsId = minted
            }
            lock.unlock()
            rows.append(ClientEventRecord(
                event: name,
                analyticsId: analyticsId,
                serverId: serverId,
                source: "web",
                sessionId: session,
                appVersion: appVersion,
                propertiesJSON: propertiesJSON
            ))
        }
        lock.lock()
        for row in rows {
            clientEventRecords.append(row)
        }
        for event in events {
            if let uuid = event["uuid"] as? String, uuid.wholeMatch(of: uuidPattern) != nil {
                seenClientEventIDs.insert(uuid)
            }
        }
        lock.unlock()
        return Self.json(202, "{\"accepted\":\(rows.count)}")
    }

    private static func deviceContext(userAgent: String, country: String) -> [String: Any] {
        var context: [String: Any] = [:]
        if let range = userAgent.range(of: "Chrome/") {
            let rest = userAgent[range.upperBound...]
            let major = rest.prefix(while: { $0 != "." && !$0.isWhitespace })
            context["$browser"] = "chrome"
            if let version = Int(major) { context["$browser_version"] = version }
        } else if userAgent.contains("Firefox/") {
            context["$browser"] = "firefox"
        } else if userAgent.contains("Safari/") {
            context["$browser"] = "safari"
        } else {
            context["$browser"] = "unknown"
        }
        if userAgent.contains("Windows") {
            context["$os"] = "windows"
        } else if userAgent.contains("Mac OS X") {
            context["$os"] = "macos"
        } else if userAgent.contains("Android") {
            context["$os"] = "android"
        } else if userAgent.contains("iPhone") || userAgent.contains("iPad") {
            context["$os"] = "ios"
        } else if userAgent.contains("Linux") {
            context["$os"] = "linux"
        } else {
            context["$os"] = "unknown"
        }
        context["$device_type"] = userAgent.contains("Mobile") ? "mobile" : "desktop"
        let normalizedCountry = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalizedCountry.wholeMatch(of: /^[A-Z]{2}$/) != nil {
            context["$country"] = normalizedCountry
        }
        return context
    }

    private enum AgentAuthority {
        case allowed(userId: String, role: String, info: OAuthLedger.AgentManagementInfo)
        case denied(HTTPReply)
    }

    private func agentAuthority(_ authorization: String?, agentId: String) -> AgentAuthority {
        guard let userId = sessionUserId(authorization: authorization) else {
            return .denied(Self.json(401, "{\"error\":\"Unauthorized\"}"))
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted else {
            return .denied(Self.json(404, "{\"error\":\"Agent not found\"}"))
        }
        guard let role = oauth.memberRole(serverId: info.serverId, userId: userId) else {
            return .denied(Self.json(403, "{\"error\":\"Not a member of this server\"}"))
        }
        if role == "owner" || role == "admin" || info.creatorUserId == userId {
            return .allowed(userId: userId, role: role, info: info)
        }
        return .denied(Self.json(403, "{\"error\":\"Forbidden\"}"))
    }

    public func createAgentRoute(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid Agent\"}")
        }
        let external = object["external"] as? Bool ?? false
        if external, object["machineId"] != nil {
            return Self.json(400, "{\"error\":\"External agents cannot be assigned to a Computer\"}")
        }
        let rawConfig = object["runtimeConfig"] as? [String: Any] ?? [:]
        var config = Self.normalizeRuntimeConfig(rawConfig)
        var envVars: [String: String] = [:]
        if external {
            config = [
                "version": 1,
                "runtime": "external",
                "model": ["kind": "preset", "id": "external"],
                "mode": ["kind": "default"],
                "reasoningEffort": NSNull(),
                "envVars": NSNull(),
            ]
        } else if object["envVars"] != nil {
            let validation = Self.validatedEnvVars(object["envVars"])
            if let error = validation.error {
                return Self.json(400, "{\"error\":\(jsonString(error))}")
            }
            if let env = validation.env {
                config["envVars"] = env
            }
        }
        if !external {
            if let command = config["command"] as? String, !command.isEmpty,
               let configRuntime = config["runtime"] as? String, configRuntime != "claude" {
                return Self.json(400, "{\"error\":\"runtimeConfig.command is not supported for runtime: \(configRuntime)\"}")
            }
            let userEnv = (config["envVars"] as? [String: String]) ?? [:]
            envVars = Self.derivedAgentEnvVars(config, userEnv: userEnv)
        }
        let runtime = external ? "external" : (config["runtime"] as? String ?? "managed")
        let configJSON = Self.serializeJSON(config)
        let envJSON = external ? "null" : Self.serializeJSON(envVars)
        let agentId = oauth.createAgent(
            serverId: serverId,
            name: name,
            creatorUserId: userId,
            runtime: runtime,
            runtimeConfigJSON: configJSON,
            envVarsJSON: envJSON
        )
        if let machineId = object["machineId"] as? String, !machineId.isEmpty {
            lock.lock()
            agentMachineIds[agentId] = machineId
            lock.unlock()
        }
        let creator = "{\"type\":\"human\",\"id\":\(jsonString(userId))}"
        let runtimeJSON = Self.agentRuntimeJSON(
            id: agentId,
            name: name,
            runtime: runtime,
            runtimeConfigJSON: configJSON,
            envVarsJSON: envJSON,
            external: external
        )
        return Self.json(200, String(runtimeJSON.dropLast()) + ",\"creator\":\(creator)}")
    }

    public func listServerAgents(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.lock()
        let seen = agentLastSeenAt
        lock.unlock()
        let rows = oauth.serverAgents(serverId: serverId).map { agent -> String in
            let canSeeConfig = role == "owner" || role == "admin" || agent.creatorUserId == userId
            let creatorJSON = agent.creatorUserId.map { "{\"type\":\"human\",\"id\":\(jsonString($0))}" } ?? "null"
            var base = "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"runtime\":\(jsonString(agent.runtime)),\"model\":\(jsonString(Self.agentModel(from: agent.runtimeConfigJSON, external: agent.runtime == "external"))),\"external\":\(agent.runtime == "external"),\"serverRole\":\"member\",\"creator\":\(creatorJSON),\"description\":\(agent.description.map { jsonString($0) } ?? "null")"
            if agent.runtime == "external" {
                let lastSeen = seen[agent.id].map { jsonString(formatter.string(from: $0)) } ?? "null"
                base += ",\"lastSeenAt\":\(lastSeen)"
            }
            if canSeeConfig {
                return base + ",\"runtimeConfig\":\(agent.runtimeConfigJSON ?? "null"),\"envVars\":\(agent.envVarsJSON ?? "null")}"
            }
            return base + "}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func listArchivedAgents(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let rows = agentArchiveRecords
            .filter { $0.value.serverId == serverId }
            .map { id, record in
                "{\"agentId\":\(jsonString(id)),\"machineName\":\(record.machineName.isEmpty ? "null" : jsonString(record.machineName)),\"workspaceState\":\(jsonString(record.workspaceState))}"
            }
            .sorted()
        lock.unlock()
        return Self.json(200, "{\"agents\":[\("\(rows.joined(separator: ","))")]}")
    }

    public func agentRuntimeOptions(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        return Self.json(200, "{\"agentId\":\(jsonString(agentId)),\"runtimes\":[],\"models\":[]}")
    }

    public func agentLogin(authorization: String?, body: String) -> HTTPReply {
        let enabled = (ProcessInfo.processInfo.environment["SLOCK_SELF_HOSTED_RUNNER_BOOTSTRAP_ENABLED"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
        guard enabled else {
            return Self.json(404, "{\"error\":\"Self-hosted runner bootstrap is not enabled\",\"code\":\"self_hosted_runner_bootstrap_disabled\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let token = (object["bootstrapToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            return Self.json(400, "{\"error\":\"bootstrapToken is required\",\"code\":\"missing_bootstrap_token\"}")
        }
        return Self.json(401, "{\"error\":\"token_invalid\",\"code\":\"token_invalid\"}")
    }

    public func createAgentBootstrapToken(authorization: String?, serverId: String, agentId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"code\":\"insufficient_role\",\"error\":\"issueAgentCredentials requires human creator authority\"}")
        }
        guard info.runtime == "external" else {
            return Self.json(400, "{\"code\":\"agent_not_external\",\"error\":\"Only external Agents get bootstrap tokens\"}")
        }
        return Self.json(201, "{\"token\":\"bootstrap-disabled\",\"createdAt\":\"1970-01-01T00:00:00.000Z\",\"scopes\":[\"channels\",\"knowledge\",\"mentions\",\"reactions\",\"read\",\"send\",\"tasks\"]}")
    }

    public func patchAgentCreator(authorization: String?, serverId: String, agentId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let creatorType = object["creatorType"] as? String, creatorType == "user",
              let creatorId = object["creatorId"] as? String,
              oauth.memberRole(serverId: serverId, userId: creatorId) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid creator\"}")
        }
        _ = oauth.setAgentCreator(id: agentId, creatorUserId: creatorId)
        return Self.json(200, "{\"creator\":{\"type\":\"human\",\"id\":\(jsonString(creatorId))}}")
    }

    public func getAgentRoute(authorization: String?, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard agentId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let role = oauth.memberRole(serverId: agent.serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if role == "guest" {
            let avatar = "null"
            let description = agent.description.map { jsonString($0) } ?? "null"
            return Self.json(200, "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"avatarUrl\":\(avatar),\"description\":\(description),\"profileProjection\":\"channel_summary\"}")
        }
        let canSeeConfig = role == "owner" || role == "admin" || agent.creatorUserId == userId
        let creatorJSON = agent.creatorUserId.map { "{\"type\":\"human\",\"id\":\(jsonString($0))}" } ?? "null"
        let base = "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"runtime\":\(jsonString(agent.runtime)),\"model\":\(jsonString(Self.agentModel(from: agent.runtimeConfigJSON, external: agent.runtime == "external"))),\"external\":\(agent.runtime == "external"),\"serverRole\":\"member\",\"creator\":\(creatorJSON),\"description\":\(agent.description.map { jsonString($0) } ?? "null")"
        let body = canSeeConfig
            ? base + ",\"runtimeConfig\":\(agent.runtimeConfigJSON ?? "null"),\"envVars\":\(agent.envVarsJSON ?? "null")}"
            : base + "}"
        return Self.json(200, body)
    }

    /// nil means the field was absent and must be ignored.
    private static func validatedEnvVars(_ value: Any?) -> (env: [String: String]?, error: String?) {
        guard let value, !(value is NSNull) else { return (nil, nil) }
        guard let object = value as? [String: Any] else {
            return (nil, "envVars must be an object")
        }
        var env: [String: String] = [:]
        for (key, raw) in object {
            guard let text = raw as? String else {
                return (nil, "envVars keys and values must be strings")
            }
            guard key.wholeMatch(of: /^[A-Za-z_][A-Za-z0-9_]*$/) != nil else {
                return (nil, "Invalid env var key \"\(key)\": must match [A-Za-z_][A-Za-z0-9_]*")
            }
            guard !key.contains("\0"), !text.contains("\0") else {
                return (nil, "envVars keys and values must not contain null bytes")
            }
            env[key] = text
        }
        return (env, nil)
    }

    private static func normalizeRuntimeConfig(_ raw: [String: Any]) -> [String: Any] {
        var config = raw
        if config["version"] == nil { config["version"] = 1 }
        if config["mode"] == nil { config["mode"] = ["kind": "default"] }
        if config["reasoningEffort"] == nil { config["reasoningEffort"] = NSNull() }
        var userEnv: [String: String] = [:]
        if let env = config["envVars"] as? [String: String] {
            for (key, value) in env where !key.hasPrefix("ANTHROPIC_") {
                userEnv[key] = value
            }
        }
        config["envVars"] = userEnv
        return config
    }

    private static func derivedAgentEnvVars(_ config: [String: Any], userEnv: [String: String]) -> [String: String] {
        var env = userEnv
        if config["runtime"] as? String == "claude" {
            if let provider = config["provider"] as? [String: Any], provider["kind"] as? String == "custom" {
                if let apiUrl = provider["apiUrl"] as? String { env["ANTHROPIC_BASE_URL"] = apiUrl }
                if let apiKey = provider["apiKey"] as? String { env["ANTHROPIC_API_KEY"] = apiKey }
            }
            if let model = config["model"] as? [String: Any], model["kind"] as? String == "custom",
               let name = model["name"] as? String {
                env["ANTHROPIC_CUSTOM_MODEL_OPTION"] = name
            }
        }
        return env
    }

    private static func privateJSON(_ body: String) -> HTTPReply {
        HTTPReply(
            status: 200,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Cache-Control": "private, no-store",
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }

    private static func serializeJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func agentModel(from runtimeConfigJSON: String?, external: Bool) -> String {
        if external { return "external" }
        guard let runtimeConfigJSON,
              let config = (try? JSONSerialization.jsonObject(with: Data(runtimeConfigJSON.utf8))) as? [String: Any],
              let model = config["model"] as? [String: Any]
        else { return "" }
        return (model["name"] as? String) ?? (model["id"] as? String) ?? ""
    }

    private static func agentRuntimeJSON(
        id: String,
        name: String,
        runtime: String,
        runtimeConfigJSON: String,
        envVarsJSON: String,
        external: Bool
    ) -> String {
        let config = (try? JSONSerialization.jsonObject(with: Data(runtimeConfigJSON.utf8))) as? [String: Any] ?? [:]
        let model: String
        if external {
            model = "external"
        } else {
            model = (config["model"] as? [String: Any])?["name"] as? String
                ?? (config["model"] as? [String: Any])?["id"] as? String
                ?? ""
        }
        let env = envVarsJSON.isEmpty ? "{}" : envVarsJSON
        return "{\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),\"runtime\":\(jsonString(runtime)),\"model\":\(jsonString(model)),\"external\":\(external),\"machineId\":null,\"reasoningEffort\":null,\"envVars\":\(env),\"runtimeConfig\":\(runtimeConfigJSON.isEmpty ? "{}" : runtimeConfigJSON)}"
    }

    public func uploadAgentAvatar(authorization: String?, agentId: String, byteCount: Int) -> HTTPReply {
        switch agentAuthority(authorization, agentId: agentId) {
        case .denied(let reply):
            return reply
        case .allowed:
            let maxBytes = 5 * 1024 * 1024
            guard byteCount <= maxBytes else {
                return Self.json(400, "{\"error\":\"Avatar image must be 5 MB or smaller\",\"errorCode\":\"PROFILE_AVATAR_TOO_LARGE\",\"maxBytes\":\(maxBytes)}")
            }
            let key = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let avatarUrl = "/api/avatars/users/\(key).webp"
            oauth.updateAgentAvatar(id: agentId, avatarUrl: avatarUrl)
            return Self.json(200, "{\"avatarUrl\":\(jsonString(avatarUrl))}")
        }
    }

    public func externalAgentStatus(authorization: String?, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentRuntimeInfo(id: agentId), !info.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard oauth.memberRole(serverId: info.serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard info.runtime == "external" else {
            return Self.json(400, "{\"error\":\"Agent is not external\"}")
        }
        lock.lock()
        let credentials = agentCredentials.values.filter { $0.agentId == agentId }
        let minted = !credentials.isEmpty
        let lastUsedAt = credentials.compactMap { $0.lastUsedAt }.max()
        lock.unlock()
        let setupState: String
        if lastUsedAt != nil {
            setupState = "connected"
        } else if minted {
            setupState = "credential_minted"
        } else {
            setupState = "waiting_for_login"
        }
        let usedJSON = lastUsedAt.map { jsonString(ISO8601DateFormatter().string(from: $0)) } ?? "null"
        return Self.json(200, "{\"setupState\":\(jsonString(setupState)),\"credentialLastUsedAt\":\(usedJSON),\"lastActivityAt\":null}")
    }

    public func setWakeStreamHeartbeatMsForTesting(_ value: Int?) {
        lock.lock()
        wakeStreamHeartbeatOverrideMs = value
        lock.unlock()
    }

    public var wakeStreamHeartbeatMs: Int? {
        lock.lock()
        let override = wakeStreamHeartbeatOverrideMs
        lock.unlock()
        if let override { return override }
        return ProcessInfo.processInfo.environment["SLOCK_WAKE_STREAM_HEARTBEAT_MS"].flatMap(Int.init)
    }

    public func setAgentCredentialUseThrottleMsForTesting(_ value: Int?) {
        lock.lock()
        agentCredentialUseThrottleOverrideMs = value
        lock.unlock()
    }

    public func agentCredentialLastUsedAtForTesting(apiKey: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return agentCredentials[apiKey]?.lastUsedAt
    }

    private func recordAgentCredentialUse(token: String) {
        let now = Date()
        lock.lock()
        guard var credential = agentCredentials[token], credential.revokedAt == nil else {
            lock.unlock()
            return
        }
        let throttle = agentCredentialUseThrottleOverrideMs ?? Self.agentCredentialUseDefaultThrottleMs
        if let last = credential.lastUsedAt, now.timeIntervalSince(last) * 1000 < Double(throttle) {
            lock.unlock()
            return
        }
        credential.lastUsedAt = now
        agentCredentials[token] = credential
        agentLastSeenAt[credential.agentId] = now
        lock.unlock()
        guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), agent.runtime == "external" else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        emitRealtime("server:\(agent.serverId)", "agent:seen", "{\"agentId\":\(jsonString(agent.id)),\"lastSeenAt\":\(jsonString(formatter.string(from: now)))}")
    }

    public func refreshAgentWakeStreamCredential(token: String) {
        recordAgentCredentialUse(token: token)
    }

    public enum AgentWakeStreamStart {
        case start(token: String, firstFrame: String)
        case refused(HTTPReply)
    }

    public func beginAgentWakeHintsStream(authorization: String?, since: String?) -> AgentWakeStreamStart {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .refused(Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"))
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil, credential.scopes.contains("read") else {
            return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        }
        let raw = (since ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, raw != "latest" {
            guard let value = Int(raw), value >= 0 else {
                return .refused(Self.json(400, "{\"error\":\"since / Last-Event-ID must be a non-negative integer (messageSeq) or 'latest'\",\"code\":\"since_invalid\"}"))
            }
        }
        recordAgentCredentialUse(token: token)
        let frames = oauth.pendingThirdPartyEventMessages(agentId: credential.agentId).map { message in
            let data = "{\"seq\":null,\"message_id\":\(jsonString(message.id)),\"wake_reason\":\"message_pending\"}"
            return "event: wake-hint\nid: null\ndata: \(data)\n\n"
        }.joined()
        return .start(token: token, firstFrame: ": connected\n\n" + frames)
    }

    public func markAgentCredentialUsed(agentId: String) {
        lock.lock()
        for key in agentCredentials.keys where agentCredentials[key]?.agentId == agentId {
            agentCredentials[key]?.lastUsedAt = Date()
        }
        lock.unlock()
    }

    public func manageableAgentList(authorization: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let result = oauth.manageableAgents(userId: userId)
        let rows = result.agents.map { agent in
            "{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"serverId\":\(jsonString(agent.serverId)),\"serverName\":\(agent.serverName.map { jsonString($0) } ?? "null")}"
        }.joined(separator: ",")
        let reason: String
        if !result.agents.isEmpty {
            reason = "ok"
        } else if result.serverCount > 0 {
            reason = "no_agents_on_manageable_servers"
        } else {
            reason = "no_manageable_server"
        }
        return Self.json(200, "{\"ok\":true,\"data\":{\"agents\":[\("\(rows)")],\"reason\":\(jsonString(reason)),\"manageable_server_count\":\(result.serverCount)}}")
    }

    public func patchAgent(authorization: String?, agentId: String, body: String) -> HTTPReply {
        switch agentAuthority(authorization, agentId: agentId) {
        case .denied(let reply):
            return reply
        case .allowed(_, _, let info):
            guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
                return Self.json(400, "{\"error\":\"Invalid Agent update\"}")
            }
            var description: String?
            if let value = object["description"] as? String {
                oauth.updateAgentDescription(id: agentId, description: value)
                description = value
            }
            var avatarUrl: String?
            if let value = object["avatarUrl"] as? String {
                oauth.updateAgentAvatar(id: agentId, avatarUrl: value)
                avatarUrl = value
            }
            var runtimeConfigJSON = info.runtimeConfigJSON
            var envVarsJSON = info.envVarsJSON
            var replacedRuntime: String?
            if let rawConfig = object["runtimeConfig"] as? [String: Any] {
                let config = Self.normalizeRuntimeConfig(rawConfig)
                if let command = config["command"] as? String, !command.isEmpty,
                   let configRuntime = config["runtime"] as? String, configRuntime != "claude" {
                    return Self.json(400, "{\"error\":\"runtimeConfig.command is not supported for runtime: \(configRuntime)\"}")
                }
                let userEnv = (config["envVars"] as? [String: String]) ?? [:]
                let env = Self.derivedAgentEnvVars(config, userEnv: userEnv)
                runtimeConfigJSON = Self.serializeJSON(config)
                envVarsJSON = Self.serializeJSON(env)
                replacedRuntime = config["runtime"] as? String
                oauth.updateAgentRuntime(id: agentId, runtimeConfigJSON: runtimeConfigJSON, envVarsJSON: envVarsJSON)
                if let replacedRuntime { oauth.updateAgentRuntimeId(id: agentId, runtime: replacedRuntime) }
            }
            if object["envVars"] != nil {
                let validation = Self.validatedEnvVars(object["envVars"])
                if let error = validation.error {
                    return Self.json(400, "{\"error\":\(jsonString(error))}")
                }
                var userEnv: [String: String] = [:]
                for (key, value) in validation.env ?? [:] {
                    if key.hasPrefix("ANTHROPIC_") { continue }
                    userEnv[key] = value
                }
                var config = (info.runtimeConfigJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
                config["envVars"] = userEnv
                let env = Self.derivedAgentEnvVars(config, userEnv: userEnv)
                runtimeConfigJSON = Self.serializeJSON(config)
                envVarsJSON = Self.serializeJSON(env)
                oauth.updateAgentRuntime(id: agentId, runtimeConfigJSON: runtimeConfigJSON, envVarsJSON: envVarsJSON)
            }
            let descriptionJSON = description.map { jsonString($0) } ?? "null"
            let latest = oauth.agentRuntimeInfo(id: agentId)
            let runtimeForResponse = latest?.runtime ?? info.runtime
            let configForModel = runtimeConfigJSON ?? latest?.runtimeConfigJSON ?? info.runtimeConfigJSON
            let model = Self.agentModel(from: configForModel, external: runtimeForResponse == "external")
            let avatarJSON = avatarUrl.map { jsonString($0) } ?? "null"
            return Self.json(200, "{\"id\":\(jsonString(info.id)),\"model\":\(jsonString(model)),\"runtime\":\(jsonString(runtimeForResponse)),\"description\":\(descriptionJSON),\"avatarUrl\":\(avatarJSON),\"runtimeConfig\":\(runtimeConfigJSON ?? "null"),\"envVars\":\(envVarsJSON ?? "null")}")
        }
    }

    public func agentAssistantOwner(authorization: String?, serverId: String, agentId: String, method: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"code\":\"assistant_requires_creator\",\"error\":\"Only the agent creator can lend assistant ownership\"}")
        }
        return Self.json(403, "{\"code\":\"assistant_not_enabled\",\"error\":\"Assistant ownership is not enabled\"}")
    }

    public func putAgentPushWebhook(authorization: String?, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawURL = object["url"] as? String,
              let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              let secret = object["secret"] as? String, !secret.isEmpty
        else {
            return Self.json(400, "{\"error\":\"url and secret are required\"}")
        }
        lock.lock()
        externalPushWebhooks[credential.agentId] = (url: rawURL, secret: secret)
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func setAgentStatusProtocolAdoptedForTesting(agentId: String, at date: Date?) {
        lock.lock()
        agentStatusProtocolAdoptedAt[agentId] = date
        lock.unlock()
    }

    public func setAgentCursorPullStateForTesting(agentId: String, lastPulledAt: Date?, pendingAcks: Int) {
        lock.lock()
        if let lastPulledAt {
            agentCursorPullState[agentId] = (lastPulledAt, pendingAcks)
        } else {
            agentCursorPullState[agentId] = nil
        }
        lock.unlock()
    }

    public func setAgentProviderPositionForTesting(
        agentId: String,
        provider: String = "antiproton",
        state: String,
        providerAgentId: String?,
        syncPending: Bool = false,
        lastErrorCode: String? = nil,
        lastErrorAt: Date? = nil,
        activatedAt: Date?
    ) {
        lock.lock()
        agentProviderPositions[agentId] = (provider, state, providerAgentId, syncPending, lastErrorCode, lastErrorAt, activatedAt)
        lock.unlock()
    }

    private static func isoOrNull(_ date: Date?) -> String {
        guard let date else { return "null" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return jsonString(formatter.string(from: date))
    }

    public func externalAgentDiagnostics(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard info.runtime == "external" else {
            return Self.json(400, "{\"code\":\"agent_not_external\",\"error\":\"External diagnostics require an external Agent\"}")
        }
        lock.lock()
        let lastSeen = agentLastSeenAt[agentId]
        let activity = agentActivities[agentId]?.activity ?? "idle"
        let adoptedAt = agentStatusProtocolAdoptedAt[agentId]
        let webhook = externalPushWebhooks[agentId]
        let cursor = agentCursorPullState[agentId]
        let position = agentProviderPositions[agentId]
        let hosted = hostedRuntimes[agentId]
        lock.unlock()

        let online = lastSeen.map { Date().timeIntervalSince($0) <= 120 } ?? false
        let presence = "{\"lastSeenAt\":\(Self.isoOrNull(lastSeen)),\"online\":\(online),\"onlineWindowMs\":120000}"
        let status = "{\"activity\":\(jsonString(activity)),\"statusProtocolAdoptedAt\":\(Self.isoOrNull(adoptedAt))}"

        let endpointHost = webhook.flatMap { URLComponents(string: $0.url)?.host }
        let push = "{\"registered\":\(webhook != nil),\"enabled\":\(webhook != nil),\"endpointHost\":\(endpointHost.map(jsonString) ?? "null"),\"disabledReason\":null,\"disabledAt\":null,\"consecutiveFailures\":0,\"lastAttemptAt\":null,\"lastDeliveryAt\":null,\"lastError\":null,\"nextAttemptAt\":null}"

        let events = "{\"lastCursorPullAt\":\(Self.isoOrNull(cursor?.lastPulledAt)),\"pendingCursorAckCount\":\(cursor?.pendingAcks ?? 0)}"

        let provider: String
        if let position {
            let errorCode = position.lastErrorCode.map(jsonString) ?? "null"
            provider = "{\"kind\":\(jsonString(position.provider)),\"state\":\(jsonString(position.state)),\"providerAgentId\":\(position.providerAgentId.map(jsonString) ?? "null"),\"syncPending\":\(position.syncPending),\"lastErrorCode\":\(errorCode),\"lastErrorAt\":\(Self.isoOrNull(position.lastErrorAt)),\"activatedAt\":\(Self.isoOrNull(position.activatedAt))}"
        } else if let hosted {
            provider = "{\"kind\":\"antiproton\",\"state\":\(jsonString(hosted.state)),\"providerAgentId\":null,\"syncPending\":false,\"lastErrorCode\":null,\"lastErrorAt\":null,\"activatedAt\":\(Self.isoOrNull(hosted.createdAt))}"
        } else {
            provider = "null"
        }

        let connections: String
        if hosted != nil {
            connections = "[{\"provider\":\"github\",\"state\":\"unavailable\",\"account\":null,\"reason\":\"Cloud connections are not enabled for this server\"}]"
        } else {
            connections = "[{\"provider\":\"github\",\"state\":\"not_applicable\",\"account\":null,\"reason\":null}]"
        }

        return Self.json(200, "{\"agentId\":\(jsonString(agentId)),\"runtime\":\"external\",\"provider\":\(provider),\"presence\":\(presence),\"status\":\(status),\"push\":\(push),\"events\":\(events),\"connections\":\(connections)}")
    }

    public func agentMigrationStatus(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"code\":\"not_supported\",\"error\":\"Agent migration status requires creator or server admin authority\"}")
        }
        return Self.json(200, "{\"migration\":null}")
    }

    public func agentMigrationCancel(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"code\":\"not_supported\",\"error\":\"Agent migration cancel requires creator or server admin authority\"}")
        }
        return Self.json(404, "{\"code\":\"migration_not_found\",\"error\":\"No active migration\"}")
    }

    public func enableAgentMigrationForTesting(serverId: String) {
        lock.lock()
        agentMigrationServers.insert(serverId)
        lock.unlock()
    }

    public func enableHostedMigrationForTesting(serverId: String) {
        lock.lock()
        hostedMigrationServers.insert(serverId)
        lock.unlock()
    }

    public func enableHostedRuntimeForTesting(serverId: String) {
        lock.lock()
        hostedRuntimeServers.insert(serverId)
        lock.unlock()
    }

    public func seedHostedMigrationForTesting(
        agentId: String,
        serverId: String,
        supportRef: String,
        revision: Int = 1,
        state: String = "in_transit",
        sourceMachineId: String? = nil
    ) {
        lock.lock()
        hostedMigrations[agentId] = HostedMigrationRecord(
            agentId: agentId,
            serverId: serverId,
            supportRef: supportRef,
            revision: revision,
            state: state,
            sourceMachineId: sourceMachineId
        )
        lock.unlock()
    }

    private func migrationError(_ status: Int, _ code: String, _ message: String) -> HTTPReply {
        Self.json(status, "{\"error\":\(jsonString(message)),\"code\":\(jsonString(code)),\"details\":{\"failureReason\":\(jsonString(code))}}")
    }

    private func migrationStatusJSON(_ migration: HostedMigrationRecord) -> String {
        let source = migration.sourceMachineId.map(jsonString) ?? "null"
        return "{\"migrationRef\":\(jsonString(migration.supportRef)),\"agentId\":\(jsonString(migration.agentId)),\"state\":\(jsonString(migration.state)),\"sourceMachineId\":\(source),\"targetKind\":\"hosted\",\"targetMachineId\":null,\"provider\":\"antiproton\",\"failureReason\":null,\"abortReason\":null,\"transportErrorCode\":null,\"transportErrorMessage\":null,\"readyAt\":null,\"flippedAt\":null,\"arrivedAt\":null,\"completedAt\":null,\"abortedAt\":null,\"canceledAt\":null,\"cancelReason\":null,\"cancelNeedsAttention\":false}"
    }

    private func migrationUpdatedJSON(_ migration: HostedMigrationRecord) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = jsonString(formatter.string(from: Date()))
        return "{\"agentId\":\(jsonString(migration.agentId)),\"migrationRef\":\(jsonString(migration.supportRef)),\"state\":\(jsonString(migration.state)),\"revision\":\(migration.revision),\"authority\":\"source\",\"disposition\":null,\"needsAttention\":false,\"dispatchAttempts\":0,\"attentionDeadlineAt\":null,\"sourceAcknowledgedAt\":null,\"targetAcknowledgedAt\":null,\"targetOutcome\":null,\"canceledAt\":null,\"updatedAt\":\(now)}"
    }

    public func confirmHostedMigration(
        authorization: String?,
        serverId: String,
        agentId: String,
        body: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let migrationEnabled = agentMigrationServers.contains(serverId)
        let hostedEnabled = hostedMigrationServers.contains(serverId)
        lock.unlock()
        guard migrationEnabled else {
            return migrationError(403, "agent_migration_ui_disabled", "Agent migration UI is not enabled on this server")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return migrationError(404, "AGENT_NOT_FOUND", "Agent not found")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return migrationError(403, "not_supported", "The `migrateAgents` capability or human creator authority is required to confirm an agent migration")
        }
        guard hostedEnabled else {
            return migrationError(403, "HOSTED_TARGET_UNAVAILABLE", "Moving agents to the cloud is not enabled on this server")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        guard let migrationRef = object["migrationRef"] as? String,
              migrationRef.range(of: "^mig_[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil
        else {
            return migrationError(400, "MIGRATION_REF_INVALID", "migrationRef is required")
        }
        guard let rawRevision = object["expectedRevision"] as? NSNumber,
              rawRevision.doubleValue.rounded() == rawRevision.doubleValue,
              rawRevision.intValue >= 1
        else {
            return migrationError(400, "MIGRATION_REVISION_INVALID", "expectedRevision must be a positive integer")
        }
        let expectedRevision = rawRevision.intValue
        lock.lock()
        let migration = hostedMigrations[agentId]
        let existingHosted = hostedRuntimes[agentId] != nil
        let assignedMachine = agentMachineIds[agentId]
        lock.unlock()
        guard let migration, migration.supportRef == migrationRef, migration.serverId == serverId else {
            return migrationError(404, "MIGRATION_NOT_FOUND", "Migration to the cloud not found")
        }
        guard migration.revision == expectedRevision else {
            return migrationError(409, "MIGRATION_REVISION_STALE", "The migration changed since this review was shown")
        }
        guard migration.state == "in_transit" else {
            return migrationError(409, "HOSTED_REVIEW_NOT_READY", "The move to the cloud is not waiting for confirmation")
        }
        guard !existingHosted else {
            return migrationError(409, "HOSTED_TARGET_ALREADY_USED", "This agent has already run in the cloud")
        }
        guard migration.sourceMachineId != nil, assignedMachine == migration.sourceMachineId else {
            return migrationError(409, "HOSTED_REVIEW_NOT_READY", "The agent is no longer on the migration's source computer")
        }
        var updated = migration
        updated.state = "arriving"
        updated.revision += 1
        lock.lock()
        hostedMigrations[agentId] = updated
        hostedRuntimes[agentId] = ("antiproton", nil, "provisioning", false, Date())
        lock.unlock()
        oauth.setAgentRuntime(id: agentId, runtime: "external")
        for member in oauth.memberIdsWithRoles(serverId: serverId) where member.role == "owner" || member.role == "admin" {
            emitRealtime("user:\(member.id)", "agent:migration-updated", migrationUpdatedJSON(updated))
        }
        return Self.json(200, "{\"migration\":\(migrationStatusJSON(updated))}")
    }

    public func agentDirectMessages(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let dms = postableChannels.filter { _, channel in
            channel.kind == "dm" && channel.serverId == serverId && channel.memberIds.contains(agentId)
                && channel.memberIds.contains { $0 != agentId && oauth.agentRuntimeInfo(id: $0) != nil }
        }
        let rows = dms.map { channelId, channel -> String in
            let peerAgentId = channel.memberIds.first { $0 != agentId && oauth.agentRuntimeInfo(id: $0) != nil } ?? ""
            let peerName = oauth.agentRuntimeInfo(id: peerAgentId)?.name ?? ""
            let preview = humanMessageRows.last { $0.channelId == channelId && $0.messageType != "system" }?.content
            let previewJSON = preview.map { jsonString($0) } ?? "null"
            return "{\"id\":\(jsonString(channelId)),\"peerId\":\(jsonString(peerAgentId)),\"peerName\":\(jsonString(peerName)),\"lastMessagePreview\":\(previewJSON)}"
        }.sorted()
        lock.unlock()
        return Self.json(200, "[\(rows.joined(separator: ","))]")
    }

    @discardableResult
    public func createAgentDirectChannelForTesting(serverId: String, firstAgentId: String, secondAgentId: String) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        postableChannels[id] = PostableChannel(serverId: serverId, memberIds: [firstAgentId, secondAgentId], kind: "dm", name: "dm")
        lock.unlock()
        return id
    }

    public func agentPrivateSurface(authorization: String?, serverId: String, agentId: String, surface: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        switch surface {
        case "activity-log":
            return Self.json(200, "[]")
        case "skills":
            return Self.json(200, "{\"global\":[],\"workspace\":[]}")
        case "activity":
            return Self.json(200, "{\"activity\":\"idle\",\"detail\":\"\"}")
        default:
            return Self.json(200, "{\"summaries\":[],\"nextCursor\":null}")
        }
    }

    public func agentScopesRoute(authorization: String?, serverId: String, agentId: String, method: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
              info.serverId == serverId,
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        let grants = ["attachment:upload", "message:send", "message:read", "channel:join", "channel:leave", "thread:unfollow", "channel:read", "channel:create", "channel:update", "channel:add_member", "channel:remove_member", "server:read", "server:update", "knowledge:read", "task:read", "task:write", "action:prepare"]
        if method == "PUT" {
            guard info.runtime == "external" else {
                return Self.json(422, "{\"code\":\"agent_scopes_unsupported\",\"error\":\"Agent scopes are managed for external agents only\"}")
            }
            let mode = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["mode"] as? String ?? "default"
            return Self.json(200, "{\"agentId\":\(jsonString(agentId)),\"mode\":\(jsonString(mode)),\"scopes\":[\("\(grants.map { jsonString($0) }.joined(separator: ","))")],\"revision\":1}")
        }
        return Self.json(200, "{\"agentId\":\(jsonString(agentId)),\"mode\":\"default\",\"scopes\":[\("\(grants.map { jsonString($0) }.joined(separator: ","))")],\"revision\":0}")
    }

    public func agentWorkspaceFiles(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let info = oauth.agentManagementInfo(id: agentId)
        let ownerServerId = info?.serverId ?? agentArchiveRecords[agentId]?.serverId
        guard ownerServerId == serverId else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info?.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        return Self.json(503, "{\"code\":\"daemon_offline\",\"error\":\"Agent has no connected machine\"}")
    }

    public func agentArchiveWorkspaceAction(authorization: String?, serverId: String, agentId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let record = agentArchiveRecords[agentId]
        lock.unlock()
        guard let record, record.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let action = object["action"] as? String,
              action == "keep" || action == "delete"
        else {
            return Self.json(400, "{\"code\":\"archive_workspace_choice_invalid\",\"error\":\"action must be keep or delete\"}")
        }
        let state = action == "delete" ? "deleted" : "on_computer"
        lock.lock()
        agentArchiveRecords[agentId] = (workspaceState: state, machineName: record.machineName, serverId: record.serverId)
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"archive\":{\"workspaceState\":\(jsonString(state)),\"machineName\":\(jsonString(record.machineName))}}")
    }

    public func agentChannels(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let rows = oauth.channelsForServer(serverId: info.serverId, userId: userId).compactMap { channel -> String? in
            guard oauth.channelAgentIds(channelId: channel.id).contains(agentId) else { return nil }
            lock.lock()
            let postable = postableChannels[channel.id]
            lock.unlock()
            if let postable, postable.kind == "thread" || postable.kind == "dm" { return nil }
            let type = oauth.channelType(id: channel.id) ?? "channel"
            guard type == "channel" || type == "private" || type == "joint" else { return nil }
            if type != "channel", !oauth.channelHumanIds(channelId: channel.id).contains(userId) { return nil }
            let prefs = oauth.notificationPrefs(channelId: channel.id, userId: agentId)
            let muteJSON = prefs.muteFromSeq.map(String.init) ?? "null"
            return "{\"id\":\(jsonString(channel.id)),\"name\":\(jsonString(channel.name)),\"description\":\(oauth.channelInfo(id: channel.id)?.description.map { jsonString($0) } ?? "null"),\"type\":\(jsonString(type)),\"createdAt\":\(jsonString(createdAt)),\"archivedAt\":null,\"activityMuted\":\(prefs.activityMuted),\"muteFromSeq\":\(muteJSON)}"
        }
        return Self.json(200, "[\(rows.joined(separator: ","))]")
    }

    public func agentArchiveView(authorization: String?, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let record = agentArchiveRecords[agentId]
        lock.unlock()
        guard let record, let role = oauth.memberRole(serverId: record.serverId, userId: userId) else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        return Self.json(200, "{\"archive\":{\"workspaceState\":\(jsonString(record.workspaceState)),\"machineName\":\(jsonString(record.machineName))}}")
    }

    public func deleteAgentRoute(authorization: String?, agentId: String, body: String = "") -> HTTPReply {
        switch agentAuthority(authorization, agentId: agentId) {
        case .denied(let reply):
            return reply
        case .allowed:
            var workspaceChoice = "keep"
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
               let workspace = object["workspace"] as? String {
                guard workspace == "keep" || workspace == "delete" else {
                    return Self.json(400, "{\"code\":\"archive_workspace_choice_invalid\",\"error\":\"workspace must be keep or delete\"}")
                }
                workspaceChoice = workspace
            }
            lock.lock()
            let machineName = agentMachineIds[agentId].flatMap { id in machines.first { $0.id == id }?.name } ?? ""
            let state = workspaceChoice == "delete" ? "deleted" : "on_computer"
            agentArchiveRecords[agentId] = (workspaceState: state, machineName: machineName, serverId: oauth.agentManagementInfo(id: agentId)?.serverId ?? "")
            lock.unlock()
            oauth.deleteAgent(id: agentId)
            return Self.json(200, "{\"ok\":true}")
        }
    }

    public func agentRuntimeAction(authorization: String?, agentId: String, action: String, body: String = "") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let role = oauth.memberRole(serverId: info.serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if info.runtime == "external" {
            return Self.json(400, "{\"error\":\"External agents do not use Raft-managed runtime lifecycle\"}")
        }
        let privileged = role == "owner" || role == "admin" || info.creatorUserId == userId
        if action == "start" {
            guard privileged else { return Self.json(403, "{\"error\":\"Forbidden\"}") }
            return Self.json(202, "{\"ok\":true,\"status\":\"accepted\"}")
        }
        if action == "stop" {
            return Self.json(200, "{\"ok\":true}")
        }
        if action == "migrate" {
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            if let target = object?["target"] as? [String: Any], target["kind"] as? String == "hosted" {
                return startHostedMigration(info: info, userId: userId, serverId: info.serverId, target: target)
            }
            return Self.json(202, "{\"ok\":true,\"status\":\"accepted\"}")
        }
        let mode = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["mode"] as? String ?? "session"
        guard mode == "restart" || mode == "session" || mode == "full" else {
            return Self.json(400, "{\"error\":\"mode must be restart, session, or full\"}")
        }
        if mode == "full", !privileged {
            return Self.json(403, "{\"error\":\"resetAgentWorkspace requires creator or server admin authority\"}")
        }
        return Self.json(202, "{\"ok\":true,\"status\":\"accepted\"}")
    }

    private func startHostedMigration(
        info: OAuthLedger.AgentManagementInfo,
        userId: String,
        serverId: String,
        target: [String: Any]
    ) -> HTTPReply {
        lock.lock()
        let hostedEnabled = hostedMigrationServers.contains(serverId)
        let runtimeEnabled = hostedRuntimeServers.contains(serverId)
        let picker = hostedModelPickerServers.contains(serverId)
        let existingHosted = hostedRuntimes[info.id] != nil
        let activeMigration = hostedMigrations[info.id]
        let machineId = agentMachineIds[info.id]
        lock.unlock()
        guard hostedEnabled else {
            return migrationError(403, "HOSTED_TARGET_UNAVAILABLE", "Moving agents to the cloud is not enabled on this server")
        }
        guard runtimeEnabled else {
            return migrationError(409, "HOSTED_TARGET_UNAVAILABLE", "Cloud agents are not enabled for this server")
        }
        let provider = target["provider"] as? String ?? "antiproton"
        guard provider == "antiproton" else {
            return migrationError(422, "HOSTED_TARGET_UNAVAILABLE", "Unknown cloud provider")
        }
        var hostedModel: String?
        if let raw = target["hostedModel"] {
            guard let value = raw as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 200
            else {
                return migrationError(400, "HOSTED_TARGET_MODEL_INVALID", "`target.hostedModel` must be a model id or null")
            }
            hostedModel = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard machineId != nil else {
            return migrationError(409, "AGENT_HAS_NO_SOURCE_MACHINE", "Agent has no source computer")
        }
        guard !existingHosted else {
            return migrationError(409, "HOSTED_TARGET_ALREADY_USED", "This agent has already run in the cloud")
        }
        if let activeMigration, activeMigration.state != "canceled" {
            return migrationError(409, "MIGRATION_ALREADY_IN_PROGRESS", "Agent already has an active migration")
        }
        if let hostedModel, hostedModel != Self.hostedDefaultModel, !picker {
            return migrationError(422, "HOSTED_TARGET_MODEL_INVALID", "This model cannot be used for a cloud agent here (picker_disabled)")
        }
        let supportRef = "mig_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(22))
        let record = HostedMigrationRecord(
            agentId: info.id,
            serverId: serverId,
            supportRef: supportRef,
            revision: 1,
            state: "preparing",
            sourceMachineId: machineId
        )
        lock.lock()
        hostedMigrations[info.id] = record
        lock.unlock()
        for member in oauth.memberIdsWithRoles(serverId: serverId) where member.role == "owner" || member.role == "admin" {
            emitRealtime("user:\(member.id)", "agent:migration-updated", migrationUpdatedJSON(record))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let deadline = jsonString(formatter.string(from: Date().addingTimeInterval(3600)))
        let source = record.sourceMachineId.map(jsonString) ?? "null"
        return Self.json(200, "{\"migrationRef\":\(jsonString(supportRef)),\"state\":\(jsonString(record.state)),\"targetKind\":\"hosted\",\"sourceMachineId\":\(source),\"targetMachineId\":null,\"prepDeadlineAt\":\(deadline),\"transferDeadlineAt\":\(deadline),\"arrivalDeadlineAt\":\(deadline)}")
    }

    public func assignAgentMachine(authorization: String?, agentId: String, body: String) -> HTTPReply {
        switch agentAuthority(authorization, agentId: agentId) {
        case .denied(let reply):
            return reply
        case .allowed:
            guard let info = oauth.agentRuntimeInfo(id: agentId) else {
                return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
            }
            if info.runtime == "external" {
                return Self.json(400, "{\"error\":\"External agents cannot be assigned to a Computer\"}")
            }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
                  let machineId = object["machineId"] as? String, !machineId.isEmpty
            else {
                return Self.json(400, "{\"error\":\"machineId is required\"}")
            }
            lock.lock()
            agentMachineIds[agentId] = machineId
            lock.unlock()
            return Self.json(200, "{\"ok\":true}")
        }
    }

    public func issueAgentCredential(authorization: String?, agentId: String, body: String = "") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
              let role = oauth.memberRole(serverId: info.serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard info.runtime == "external" else {
            return Self.json(400, "{\"code\":\"agent_not_external\",\"error\":\"Only external Agents get credentials\"}")
        }
        let requested = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let requestedScopes = (requested?["scopes"] as? [Any])?.compactMap { $0 as? String } ?? []
        let capabilities = requestedScopes.isEmpty
            ? ["channels", "knowledge", "mentions", "reactions", "read", "send", "tasks"]
            : Array(Set(requestedScopes)).sorted()
        let key = mintAgentCredential(agentId: agentId, scopes: capabilities, name: "session-issued")
        lock.lock()
        let credentialId = agentCredentials[key]?.id ?? ""
        lock.unlock()
        return Self.json(201, "{\"credentialId\":\(jsonString(credentialId)),\"apiKey\":\(jsonString(key)),\"agentId\":\(jsonString(agentId)),\"serverId\":\(jsonString(info.serverId)),\"scopes\":[\(capabilities.map { jsonString($0) }.joined(separator: ","))]}")
    }

    public func listAgentCredentials(authorization: String?, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
              let role = oauth.memberRole(serverId: info.serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.lock()
        let rows = agentCredentials
            .filter { $0.value.agentId == agentId }
            .map { key, credential -> String in
                let masked = String(key.prefix(14)) + "***"
                let created = jsonString(formatter.string(from: credential.createdAt))
                let used = credential.lastUsedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
                let revoked = credential.revokedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
                let scopes = credential.scopes.sorted().map { jsonString($0) }.joined(separator: ",")
                return "{\"id\":\(jsonString(credential.id)),\"maskedToken\":\(jsonString(masked)),\"name\":\(jsonString(credential.name)),\"scopes\":[\(scopes)],\"createdAt\":\(created),\"lastUsedAt\":\(used),\"revokedAt\":\(revoked)}"
            }
        lock.unlock()
        return Self.json(200, "{\"credentials\":[\(rows.joined(separator: ","))]}")
    }

    public func revokeAgentCredential(authorization: String?, agentId: String, credentialId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted,
              let role = oauth.memberRole(serverId: info.serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        guard let token = agentCredentials.first(where: { $0.value.id == credentialId })?.key,
              agentCredentials[token]?.agentId == agentId else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Credential not found\"}")
        }
        let existingRevocation = agentCredentials[token]?.revokedAt
        agentCredentials[token]?.revokedAt = existingRevocation ?? Date()
        lock.unlock()
        return HTTPReply(status: 204, headers: [:], body: "")
    }

    public func registerMachine(serverId: String, userId: String, name: String) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        machines.append(MachineRecord(
            id: id,
            serverId: serverId,
            userId: userId,
            name: name,
            description: nil,
            apiKey: Self.machineAPIKeyMaterial()
        ))
        lock.unlock()
        return id
    }

    public func machineAPIKey(machineId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return machines.first { $0.id == machineId }?.apiKey
    }

    public func bumpMachineStatusVersion(machineId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (machineStatusVersions[machineId] ?? 0) + 1
        machineStatusVersions[machineId] = next
        return next
    }

    public func setMachineOnline(machineId: String, online: Bool) {
        lock.lock()
        machineOnline[machineId] = online
        lock.unlock()
    }

    public func setMachineRuntimesForTesting(machineId: String, runtimes: [String]) {
        lock.lock()
        if let index = machines.firstIndex(where: { $0.id == machineId }) {
            machines[index].runtimes = runtimes
        }
        lock.unlock()
    }

    private struct OnboardingAdoptionChange {
        var field: String
        var before: String?
        var after: String?
    }

    private func onboardingAdoptionState(
        serverId: String,
        agentId: String
    ) -> (agent: OAuthLedger.AgentRuntimeInfo, role: String, changes: [OnboardingAdoptionChange])? {
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return nil
        }
        let role = oauth.agentRole(serverId: serverId, agentId: agentId) ?? "member"
        var changes: [OnboardingAdoptionChange] = []
        if agent.name != "Cindy" {
            changes.append(OnboardingAdoptionChange(field: "name", before: agent.name, after: "Cindy"))
        }
        if agent.displayName != "Cindy" {
            changes.append(OnboardingAdoptionChange(field: "displayName", before: agent.displayName, after: "Cindy"))
        }
        if agent.description != "Onboarding Assistant" {
            changes.append(OnboardingAdoptionChange(field: "role", before: agent.description, after: "Onboarding Assistant"))
        }
        if role != "admin" {
            changes.append(OnboardingAdoptionChange(field: "serverRole", before: role, after: "admin"))
        }
        if agent.avatarUrl != "pixel:mug" {
            changes.append(OnboardingAdoptionChange(field: "avatarUrl", before: agent.avatarUrl, after: "pixel:mug"))
        }
        return (agent, role, changes)
    }

    private func onboardingAdoptionJSON(
        canAdopt: Bool,
        changes: [OnboardingAdoptionChange],
        appliedChanges: [OnboardingAdoptionChange]? = nil,
        agent: OAuthLedger.AgentRuntimeInfo? = nil,
        role: String? = nil
    ) -> String {
        func changesJSON(_ values: [OnboardingAdoptionChange]) -> String {
            values.map { change in
                let before = change.before.map(jsonString) ?? "null"
                let after = change.after.map(jsonString) ?? "null"
                return "{\"field\":\(jsonString(change.field)),\"before\":\(before),\"after\":\(after)}"
            }.joined(separator: ",")
        }
        var body = "{\"canAdopt\":\(canAdopt),\"changes\":[\(changesJSON(changes))]"
        if let appliedChanges {
            body += ",\"appliedChanges\":[\(changesJSON(appliedChanges))]"
        }
        if let agent {
            let description = agent.description.map(jsonString) ?? "null"
            let avatar = agent.avatarUrl.map(jsonString) ?? "null"
            body += ",\"agent\":{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"description\":\(description),\"avatarUrl\":\(avatar),\"serverRole\":\(jsonString(role ?? "member"))}"
        }
        return body + "}"
    }

    public func onboardingIdentityAdoption(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let state = onboardingAdoptionState(serverId: serverId, agentId: agentId) else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
                || state.agent.creatorUserId == userId
        else {
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to edit agents\"}")
        }
        lock.lock()
        let onboardingAgentId = serverOnboardingSettings[serverId]?.agentId
        lock.unlock()
        guard onboardingAgentId == agentId else {
            return Self.json(400, "{\"error\":\"Agent is not this server's onboarding agent\"}")
        }
        return Self.json(200, onboardingAdoptionJSON(canAdopt: !state.changes.isEmpty, changes: state.changes))
    }

    public func adoptOnboardingIdentity(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let state = onboardingAdoptionState(serverId: serverId, agentId: agentId) else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
                || state.agent.creatorUserId == userId
        else {
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to edit agents\"}")
        }
        lock.lock()
        let onboardingAgentId = serverOnboardingSettings[serverId]?.agentId
        lock.unlock()
        guard onboardingAgentId == agentId else {
            return Self.json(400, "{\"error\":\"Agent is not this server's onboarding agent\"}")
        }
        let changes = state.changes
        guard !changes.isEmpty else {
            return Self.json(200, onboardingAdoptionJSON(
                canAdopt: false,
                changes: [],
                appliedChanges: [],
                agent: state.agent,
                role: state.role
            ))
        }
        if oauth.serverAgents(serverId: serverId).contains(where: { $0.id != agentId && $0.name == "Cindy" }) {
            return Self.json(409, "{\"error\":\"Agent name is already taken\"}")
        }
        oauth.adoptAgentIdentity(
            serverId: serverId,
            agentId: agentId,
            name: "Cindy",
            displayName: "Cindy",
            description: "Onboarding Assistant",
            avatarUrl: "pixel:mug",
            role: "admin"
        )
        emitRealtime("server:\(serverId)", "agent:updated", "{\"agentId\":\(jsonString(agentId))}")
        let updated = oauth.agentRuntimeInfo(id: agentId) ?? state.agent
        return Self.json(200, onboardingAdoptionJSON(
            canAdopt: false,
            changes: [],
            appliedChanges: changes,
            agent: updated,
            role: "admin"
        ))
    }

    public func setHostedUsageForTesting(agentId: String, json: String) {
        lock.lock()
        hostedUsage[agentId] = json
        lock.unlock()
    }

    public func agentHostedUsage(authorization: String?, serverId: String, agentId: String, query: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
                || agent.creatorUserId == userId
        else {
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to view cloud agent usage\"}")
        }
        lock.lock()
        let hosted = hostedRuntimes[agentId]
        let body = hostedUsage[agentId]
        lock.unlock()
        guard hosted != nil else {
            return Self.json(404, "{\"error\":\"Agent is not a cloud agent\",\"code\":\"hosted_runtime_missing\"}")
        }
        var params: [String: String] = [:]
        for pair in (query ?? "").split(separator: "&") {
            let item = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(item[0]).removingPercentEncoding ?? String(item[0])
            let value = item.count == 2 ? (String(item[1]).removingPercentEncoding ?? String(item[1])) : ""
            params[name] = value
        }
        let bucket = params["bucket"] ?? "1d"
        guard ["1h", "1d"].contains(bucket) else {
            return Self.json(400, "{\"error\":\"Invalid usage query\",\"code\":\"hosted_runtime_usage_invalid_query\"}")
        }
        let now = Date()
        func parse(_ name: String) -> Date? {
            guard let raw = params[name], !raw.isEmpty else { return nil }
            return Self.isoDate(raw)
        }
        if params["from"] != nil, parse("from") == nil {
            return Self.json(400, "{\"error\":\"Invalid usage query\",\"code\":\"hosted_runtime_usage_invalid_query\"}")
        }
        if params["to"] != nil, parse("to") == nil {
            return Self.json(400, "{\"error\":\"Invalid usage query\",\"code\":\"hosted_runtime_usage_invalid_query\"}")
        }
        let from = parse("from") ?? now.addingTimeInterval(-7 * 24 * 60 * 60)
        let to = parse("to") ?? now
        guard to >= from, to.timeIntervalSince(from) <= 31 * 24 * 60 * 60 else {
            return Self.json(400, "{\"error\":\"Invalid usage query\",\"code\":\"hosted_runtime_usage_invalid_query\"}")
        }
        guard let body else {
            return Self.json(409, "{\"error\":\"The cloud runtime is not ready\",\"code\":\"hosted_runtime_usage_not_ready\"}")
        }
        return Self.json(200, body)
    }

    public func setHostedRuntimeForTesting(
        agentId: String,
        provider: String = "openai",
        model: String? = nil,
        state: String = "active",
        retryNeedsModel: Bool = false
    ) {
        lock.lock()
        hostedRuntimes[agentId] = (provider, model, state, retryNeedsModel, Date())
        lock.unlock()
    }

    public func agentHostedRuntime(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
                || agent.creatorUserId == userId
        else {
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to view cloud agent status\"}")
        }
        lock.lock()
        let hosted = hostedRuntimes[agentId]
        lock.unlock()
        guard let hosted else {
            return Self.json(404, "{\"error\":\"Agent is not a cloud agent\",\"code\":\"hosted_runtime_missing\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let model = hosted.model.map(jsonString) ?? "null"
        return Self.json(200, "{\"hostedRuntime\":{\"agentId\":\(jsonString(agentId)),\"provider\":\(jsonString(hosted.provider)),\"model\":\(model),\"state\":\(jsonString(hosted.state)),\"retryNeedsModel\":\(hosted.retryNeedsModel),\"createdAt\":\(jsonString(formatter.string(from: hosted.createdAt)))},\"onboardingSetup\":null}")
    }

    public func enableHostedModelPicker(serverId: String) {
        lock.lock()
        hostedModelPickerServers.insert(serverId)
        lock.unlock()
    }

    public func hostedRuntimeStateForTesting(agentId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return hostedRuntimes[agentId]?.state
    }

    public func setHostedRuntimeStateForTesting(
        agentId: String,
        state: String,
        retryNeedsModel: Bool = false
    ) {
        lock.lock()
        if let existing = hostedRuntimes[agentId] {
            hostedRuntimes[agentId] = (existing.provider, existing.model, state, retryNeedsModel, existing.createdAt)
        } else {
            hostedRuntimes[agentId] = ("antiproton", nil, state, retryNeedsModel, Date())
        }
        lock.unlock()
    }

    public func retryAgentProvisioning(
        authorization: String?,
        serverId: String,
        agentId: String,
        body: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
                || agent.creatorUserId == userId
        else {
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to retry provisioning\"}")
        }
        lock.lock()
        let hosted = hostedRuntimes[agentId]
        lock.unlock()
        guard let hosted else {
            return Self.json(404, "{\"error\":\"Agent is not a cloud agent\",\"code\":\"hosted_runtime_missing\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        var modelProvided = false
        var providedModel: String?
        if let raw = object?["model"] {
            modelProvided = true
            if raw is NSNull {
                providedModel = nil
            } else if let value = raw as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.count <= 200 {
                providedModel = value.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return Self.json(400, "{\"error\":\"`model` must be a model id or null\",\"code\":\"hosted_runtime_model_invalid\"}")
            }
        }
        if modelProvided, hosted.retryNeedsModel {
            lock.lock()
            let picker = hostedModelPickerServers.contains(serverId)
            let state = hostedModels[agentId]
            lock.unlock()
            if let providedModel, providedModel != Self.hostedDefaultModel, !picker {
                return Self.json(403, "{\"error\":\"This server does not pick a cloud agent model\",\"code\":\"model_picker_disabled\"}")
            }
            let picked = providedModel == Self.hostedDefaultModel && !picker ? nil : providedModel
            if let picked {
                if state?.locked == true {
                    return Self.json(409, "{\"error\":\"An administrator has set this agent's model\",\"code\":\"hosted_runtime_model_locked\"}")
                }
                guard state?.models.contains(where: { $0.id == picked }) == true else {
                    return Self.json(422, "{\"error\":\"The provider does not offer this model\",\"code\":\"hosted_runtime_model_not_offered\"}")
                }
            }
        }
        switch hosted.state {
        case "failed":
            if hosted.retryNeedsModel, !modelProvided {
                return Self.json(409, "{\"error\":\"The provider refused the picked model; retry with `model` set to an offered id, or null for the default\",\"code\":\"hosted_runtime_model_required\"}")
            }
        case "provisioning", "deleting":
            break
        default:
            return Self.json(409, "{\"error\":\"Nothing to retry\",\"code\":\"hosted_runtime_nothing_to_retry\"}")
        }
        lock.lock()
        hostedRuntimes[agentId] = (hosted.provider, hosted.model, "provisioning", false, hosted.createdAt)
        if modelProvided, var state = hostedModels[agentId] {
            let picked = providedModel == Self.hostedDefaultModel && hostedModelPickerServers.contains(serverId) == false ? nil : providedModel
            if let picked, let option = state.models.first(where: { $0.id == picked }) {
                state.model = option.id
                state.label = option.label
                state.source = "chosen"
            } else if picked == nil {
                state.model = state.defaultModel
                state.label = state.defaultLabel
                state.source = "default"
            }
            hostedModels[agentId] = state
        }
        let updated = hostedRuntimes[agentId]!
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let modelJSON = updated.model.map(jsonString) ?? "null"
        return Self.json(200, "{\"hostedRuntime\":{\"agentId\":\(jsonString(agentId)),\"provider\":\(jsonString(updated.provider)),\"model\":\(modelJSON),\"state\":\(jsonString(updated.state)),\"retryNeedsModel\":\(updated.retryNeedsModel),\"createdAt\":\(jsonString(formatter.string(from: updated.createdAt)))}}")
    }

    public func setHostedModelForTesting(
        agentId: String,
        models: [(id: String, label: String, provider: String)] = [
            ("deepseek-flash", "DeepSeek Flash", "deepseek"),
            ("gpt-5.6-luna", "GPT-5.6 Luna", "openai"),
        ],
        defaultModel: String? = "deepseek-flash",
        defaultLabel: String? = "DeepSeek Flash",
        model: String? = "deepseek-flash",
        label: String? = "DeepSeek Flash",
        source: String = "default",
        locked: Bool = false
    ) {
        lock.lock()
        hostedModels[agentId] = HostedModelState(
            models: models,
            defaultModel: defaultModel,
            defaultLabel: defaultLabel,
            model: model,
            label: label,
            source: source,
            locked: locked
        )
        lock.unlock()
    }

    /// Shared guard for the hosted model reads and writes: agent membership,
    /// owner/admin/creator authority, an existing hosted runtime, and an
    /// active provision. Returns the agent id or the reply to send.
    private enum HostedModelGuardResult {
        case allowed(String)
        case refused(HTTPReply)
    }

    private func hostedModelGuard(
        authorization: String?,
        serverId: String,
        agentId: String,
        action: String
    ) -> HostedModelGuardResult {
        guard let userId = sessionUserId(authorization: authorization) else {
            return .refused(Self.json(401, "{\"error\":\"Unauthorized\"}"))
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return .refused(Self.json(404, "{\"error\":\"Agent not found\"}"))
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
                || agent.creatorUserId == userId
        else {
            return .refused(Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to \(action) a cloud agent's model\"}"))
        }
        lock.lock()
        let hosted = hostedRuntimes[agentId]
        let models = hostedModels[agentId]
        lock.unlock()
        guard let hosted else {
            return .refused(Self.json(404, "{\"error\":\"Agent is not a cloud agent\",\"code\":\"hosted_runtime_missing\"}"))
        }
        guard hosted.state == "active", models != nil else {
            return .refused(Self.json(409, "{\"error\":\"The cloud runtime is not ready\",\"code\":\"hosted_runtime_model_not_ready\"}"))
        }
        return .allowed(agentId)
    }

    private func hostedModelView(_ state: HostedModelState, picker: Bool) -> String {
        let models = state.models.map { model in
            "{\"id\":\(jsonString(model.id)),\"label\":\(jsonString(model.label)),\"provider\":\(jsonString(model.provider))}"
        }.joined(separator: ",")
        let defaultModel = state.defaultModel.map(jsonString) ?? "null"
        let defaultLabel = state.defaultLabel.map(jsonString) ?? "null"
        let model = state.model.map(jsonString) ?? "null"
        let label = state.label.map(jsonString) ?? "null"
        return "{\"models\":[\(models)],\"default\":\(defaultModel),\"defaultLabel\":\(defaultLabel),\"model\":\(model),\"label\":\(label),\"source\":\(jsonString(state.source)),\"locked\":\(state.locked),\"picker\":\(picker)}"
    }

    public func agentHostedModel(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        switch hostedModelGuard(authorization: authorization, serverId: serverId, agentId: agentId, action: "view") {
        case .refused(let reply):
            return reply
        case .allowed(let id):
            lock.lock()
            let state = hostedModels[id]
            let picker = hostedModelPickerServers.contains(serverId)
            lock.unlock()
            guard let state else {
                return Self.json(409, "{\"error\":\"The cloud runtime is not ready\",\"code\":\"hosted_runtime_model_not_ready\"}")
            }
            return Self.json(200, hostedModelView(state, picker: picker))
        }
    }

    public func setAgentHostedModel(
        authorization: String?,
        serverId: String,
        agentId: String,
        body: String
    ) -> HTTPReply {
        switch hostedModelGuard(authorization: authorization, serverId: serverId, agentId: agentId, action: "change") {
        case .refused(let reply):
            return reply
        case .allowed(let id):
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            guard let raw = object?["model"] else {
                return Self.json(400, "{\"error\":\"`model` must be a model id or null\",\"code\":\"hosted_runtime_model_invalid\"}")
            }
            let requested: String?
            if raw is NSNull {
                requested = nil
            } else if let value = raw as? String,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.count <= 200 {
                requested = value.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return Self.json(400, "{\"error\":\"`model` must be a model id or null\",\"code\":\"hosted_runtime_model_invalid\"}")
            }
            lock.lock()
            let picker = hostedModelPickerServers.contains(serverId)
            lock.unlock()
            if let requested, requested != Self.hostedDefaultModel, !picker {
                return Self.json(403, "{\"error\":\"This server does not pick a cloud agent model\",\"code\":\"model_picker_disabled\"}")
            }
            let picked: String?
            if let requested, requested == Self.hostedDefaultModel, !picker {
                picked = nil
            } else {
                picked = requested
            }
            lock.lock()
            guard var state = hostedModels[id] else {
                lock.unlock()
                return Self.json(409, "{\"error\":\"The cloud runtime is not ready\",\"code\":\"hosted_runtime_model_not_ready\"}")
            }
            if let picked {
                if state.locked {
                    lock.unlock()
                    return Self.json(409, "{\"error\":\"An administrator has set this agent's model\",\"code\":\"hosted_runtime_model_locked\"}")
                }
                guard let option = state.models.first(where: { $0.id == picked }) else {
                    lock.unlock()
                    return Self.json(422, "{\"error\":\"The provider does not offer this model\",\"code\":\"hosted_runtime_model_not_offered\"}")
                }
                state.model = option.id
                state.label = option.label
                state.source = "chosen"
            } else {
                state.model = state.defaultModel
                state.label = state.defaultLabel
                state.source = "default"
            }
            hostedModels[id] = state
            lock.unlock()
            return Self.json(200, hostedModelView(state, picker: picker))
        }
    }

    public func setAgentConnectionOriginForTesting(origin: String) {
        lock.lock()
        agentConnectionOrigin = origin
        lock.unlock()
    }

    private static let agentConnectionProviders: Set<String> = ["github"]

    private static let agentConnectionIDPattern = "^[A-Za-z0-9_.~-]{1,200}$"

    private static func isAgentConnectionIdentifier(_ value: String) -> Bool {
        value.range(of: agentConnectionIDPattern, options: .regularExpression) != nil
    }

    private enum AgentConnectionLoadResult {
        case loaded(agentId: String, userId: String, role: String)
        case refused(HTTPReply)
    }

    private struct HostedConnectionConnectorRecord {
        var id: String
        var account: String
        var creatorRaftUserId: String?
        var createdAt: String?
        var current: Bool
    }

    private struct HostedConnectionStatusRecord {
        var connected: Bool
        var account: String?
        var connectedAt: String?
        var connectedBy: String?
        var scopes: [String]
        var connectorId: String?
        var connectors: [HostedConnectionConnectorRecord]
    }

    private func agentConnectionProviderCall(
        method: String,
        action: String,
        provider: String,
        agentId: String,
        body: String? = nil
    ) -> AgentConnectionProviderResult {
        let relay = agentConnectionProvider
        guard let relay else { return .unavailable }
        return relay(AgentConnectionProviderRequest(
            method: method,
            action: action,
            provider: provider,
            agentId: agentId,
            body: body
        ))
    }

    private func loadAgentForConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String
    ) -> AgentConnectionLoadResult {
        guard let userId = sessionUserId(authorization: authorization) else {
            return .refused(Self.json(401, "{\"error\":\"Unauthorized\"}"))
        }
        guard Self.agentConnectionProviders.contains(provider) else {
            return .refused(Self.json(404, "{\"error\":\"Unknown connection provider\",\"code\":\"agent_connection_provider_unknown\"}"))
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return .refused(Self.json(404, "{\"error\":\"Agent not found\"}"))
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              role != "guest",
              role == "owner" || role == "admin" || agent.creatorUserId == userId
        else {
            return .refused(Self.json(403, "{\"error\":\"Only the agent's creator or a server owner/admin can manage its connections\",\"code\":\"agent_connection_forbidden\"}"))
        }
        lock.lock()
        let hosted = hostedRuntimes[agentId]
        lock.unlock()
        guard let hosted else {
            return .refused(Self.json(400, "{\"error\":\"Agent is not a cloud agent\",\"code\":\"agent_connection_not_provider_backed\"}"))
        }
        guard hosted.state == "active" else {
            return .refused(Self.json(409, "{\"error\":\"The agent is not provisioned on its provider yet\",\"code\":\"agent_connection_agent_not_active\",\"state\":\(jsonString(hosted.state))}"))
        }
        return .loaded(agentId: agentId, userId: userId, role: role)
    }

    private static func parseConnectionStatus(_ body: String) -> HostedConnectionStatusRecord? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return nil
        }
        let connected = object["connected"] as? Bool ?? false
        var connectors: [HostedConnectionConnectorRecord] = []
        if let raw = object["connectors"] as? [Any] {
            for entry in raw {
                guard let row = entry as? [String: Any],
                      let id = row["id"] as? String,
                      isAgentConnectionIdentifier(id)
                else { continue }
                connectors.append(HostedConnectionConnectorRecord(
                    id: id,
                    account: row["account"] as? String ?? "",
                    creatorRaftUserId: row["creatorRaftUserId"] as? String,
                    createdAt: row["createdAt"] as? String,
                    current: row["current"] as? Bool ?? false
                ))
                if connectors.count >= 100 { break }
            }
        }
        let rawConnectorId = object["connectorId"] as? String
        let connectorId = connected ? rawConnectorId.flatMap { isAgentConnectionIdentifier($0) ? $0 : nil } : nil
        return HostedConnectionStatusRecord(
            connected: connected,
            account: object["account"] as? String,
            connectedAt: object["connectedAt"] as? String,
            connectedBy: object["connectedBy"] as? String,
            scopes: (object["scopes"] as? [Any])?.compactMap { $0 as? String } ?? [],
            connectorId: connectorId,
            connectors: connectors
        )
    }

    private func connectionMemberIdentity(serverId: String, userId: String) -> (name: String, displayName: String)? {
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else { return nil }
        lock.lock()
        let account = accounts.values.first { $0.id == userId }
        lock.unlock()
        guard let account else { return nil }
        return (account.name, account.name)
    }

    private func connectionUserJSON(serverId: String, userId: String) -> String {
        let identity = connectionMemberIdentity(serverId: serverId, userId: userId)
        let name = identity.map { jsonString($0.name) } ?? "null"
        let displayName = identity.map { jsonString($0.displayName) } ?? "null"
        return "{\"id\":\(jsonString(userId)),\"name\":\(name),\"displayName\":\(displayName)}"
    }

    private func connectionStatusJSON(
        _ parsed: HostedConnectionStatusRecord,
        provider: String,
        serverId: String,
        userId: String,
        role: String
    ) -> String {
        let connectedBy: String
        if parsed.connected, let id = parsed.connectedBy {
            let identity = connectionMemberIdentity(serverId: serverId, userId: id)
            let name = identity.map { jsonString($0.displayName) } ?? "null"
            connectedBy = "{\"id\":\(jsonString(id)),\"name\":\(name)}"
        } else {
            connectedBy = "null"
        }
        let connectors = parsed.connectors.map { connector -> String in
            let creator: String
            if let creatorId = connector.creatorRaftUserId {
                creator = connectionUserJSON(serverId: serverId, userId: creatorId)
            } else {
                creator = "null"
            }
            let canManage = role == "owner" || role == "admin" || connector.creatorRaftUserId == userId
            let createdAt = connector.createdAt.map(jsonString) ?? "null"
            return "{\"id\":\(jsonString(connector.id)),\"account\":\(jsonString(connector.account)),\"createdAt\":\(createdAt),\"creator\":\(creator),\"current\":\(connector.current),\"canManage\":\(canManage)}"
        }.joined(separator: ",")
        let scopes = parsed.scopes.map { jsonString($0) }.joined(separator: ",")
        let account = parsed.connected ? (parsed.account.map(jsonString) ?? "null") : "null"
        let connectedAt = parsed.connected ? (parsed.connectedAt.map(jsonString) ?? "null") : "null"
        let connectorId = parsed.connectorId.map(jsonString) ?? "null"
        return "{\"provider\":\(jsonString(provider)),\"supported\":true,\"connected\":\(parsed.connected),\"account\":\(account),\"connectedAt\":\(connectedAt),\"connectedBy\":\(connectedBy),\"scopes\":[\(scopes)],\"connectorId\":\(connectorId),\"connectors\":[\(connectors)]}"
    }

    private static func providerErrorParts(_ body: String) -> (code: String?, message: String?) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else {
            return (nil, nil)
        }
        return (error["code"] as? String, error["message"] as? String)
    }

    private func redactProviderMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        var value = message
        for pattern in [
            "(ghp_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9]+",
            "Bearer [A-Za-z0-9._~+/=-]+",
            "sk-[A-Za-z0-9_-]+",
        ] {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return value
    }

    private func agentConnectionProviderFailure(_ result: AgentConnectionProviderResult, thisServer: Bool = true) -> HTTPReply {
        switch result {
        case .unavailable:
            return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":null,\"providerMessage\":null,\"providerStatus\":null}")
        case .empty(let status):
            return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":null,\"providerMessage\":null,\"providerStatus\":\(status)}")
        case .response(let status, let body):
            let parts = Self.providerErrorParts(body)
            let message = redactProviderMessage(parts.message)
            if (400..<500).contains(status) {
                let error = message ?? "The provider refused the request"
                return Self.json(409, "{\"error\":\(jsonString(error)),\"code\":\"agent_connection_provider_refused\",\"providerCode\":\(parts.code.map(jsonString) ?? "null"),\"providerMessage\":\(message.map(jsonString) ?? "null"),\"providerStatus\":\(status)}")
            }
            return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":\(parts.code.map(jsonString) ?? "null"),\"providerMessage\":\(message.map(jsonString) ?? "null"),\"providerStatus\":\(status)}")
        }
    }

    /// A 404 from the provider may mean the connections route is missing
    /// (unsupported) or that the provider no longer knows the agent. Only the
    /// agent lookup can tell them apart.
    private func agentConnection404Reply(
        provider: String,
        agentId: String,
        body: String,
        connectorScoped: Bool = false
    ) -> HTTPReply {
        let lookup = agentConnectionProviderCall(method: "GET", action: "agentLookup", provider: provider, agentId: agentId)
        switch lookup {
        case .response(let status, _) where (200..<300).contains(status):
            if connectorScoped {
                return Self.json(404, "{\"error\":\"That connection does not exist on this server\",\"code\":\"agent_connection_connector_not_found\"}")
            }
            return Self.json(409, "{\"error\":\"The provider does not support connections\",\"code\":\"agent_connection_unsupported\"}")
        case .response(let status, let lookupBody) where status == 404:
            return agentConnectionMissingReply(providerMessage: Self.providerErrorParts(lookupBody).message ?? Self.providerErrorParts(body).message)
        default:
            return agentConnectionProviderFailure(lookup)
        }
    }

    private func agentConnectionMissingReply(providerMessage: String?) -> HTTPReply {
        let message = redactProviderMessage(providerMessage)
        return Self.json(409, "{\"error\":\"This agent no longer exists at its provider; connections are unavailable. Recreate the agent.\",\"code\":\"agent_connection_agent_missing_at_provider\",\"providerMessage\":\(message.map(jsonString) ?? "null")}")
    }

    private func agentConnectionStatus404Reply(provider: String, agentId: String) -> HTTPReply {
        let lookup = agentConnectionProviderCall(method: "GET", action: "agentLookup", provider: provider, agentId: agentId)
        switch lookup {
        case .response(let status, _) where (200..<300).contains(status):
            return Self.json(200, "{\"provider\":\(jsonString(provider)),\"supported\":false}")
        case .response(let status, let lookupBody) where status == 404:
            return agentConnectionMissingReply(providerMessage: Self.providerErrorParts(lookupBody).message)
        default:
            return agentConnectionProviderFailure(lookup)
        }
    }

    private func pendingInvalidReply(providerCode: String? = nil, message: String? = nil) -> HTTPReply {
        Self.json(404, "{\"error\":\"The connection link expired or is invalid; start again\",\"code\":\"agent_connection_pending_invalid\",\"providerCode\":\(providerCode.map(jsonString) ?? "null"),\"providerMessage\":\(redactProviderMessage(message).map(jsonString) ?? "null")}")
    }

    private func agentConnectionStatusFailure(_ result: AgentConnectionProviderResult, provider: String, agentId: String, serverId: String, userId: String, role: String) -> HTTPReply {
        switch result {
        case .response(let status, let body) where (200..<300).contains(status):
            guard let parsed = Self.parseConnectionStatus(body) else {
                return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":\"invalid_response\",\"providerMessage\":null,\"providerStatus\":\(status)}")
            }
            return Self.json(200, connectionStatusJSON(parsed, provider: provider, serverId: serverId, userId: userId, role: role))
        case .response(let status, _) where status == 404:
            return agentConnectionStatus404Reply(provider: provider, agentId: agentId)
        default:
            return agentConnectionProviderFailure(result)
        }
    }

    public func agentConnectionStatus(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded(_, let userId, let role):
            let result = agentConnectionProviderCall(method: "GET", action: "status", provider: provider, agentId: agentId)
            return agentConnectionStatusFailure(result, provider: provider, agentId: agentId, serverId: serverId, userId: userId, role: role)
        }
    }

    public func startAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        body: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded(_, let userId, _):
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            let rawAccess = object?["access"]
            let access: String?
            if rawAccess == nil || rawAccess is NSNull {
                access = nil
            } else if let value = rawAccess as? String, value == "private" {
                access = "private"
            } else {
                return Self.json(400, "{\"error\":\"access must be \\\"private\\\" when present\",\"code\":\"agent_connection_invalid\"}")
            }
            lock.lock()
            let origin = agentConnectionOrigin
            lock.unlock()
            var bodyJSON = "{\"returnUrl\":\(jsonString("\(origin)/api/connections/callback/\(serverId)/\(agentId)")),\"initiatedBy\":{\"raftUserId\":\(jsonString(userId))}"
            if let access {
                bodyJSON += ",\"access\":\(jsonString(access))"
            }
            bodyJSON += "}"
            let result = agentConnectionProviderCall(method: "POST", action: "start", provider: provider, agentId: agentId, body: bodyJSON)
            switch result {
            case .response(let status, let responseBody) where (200..<300).contains(status):
                guard let parsed = (try? JSONSerialization.jsonObject(with: Data(responseBody.utf8))) as? [String: Any],
                      let url = parsed["url"] as? String,
                      let parsedURL = URL(string: url),
                      parsedURL.scheme == "http" || parsedURL.scheme == "https"
                else {
                    return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":\"invalid_connection_url\",\"providerMessage\":null,\"providerStatus\":\(status)}")
                }
                let expiresAt = (parsed["expiresAt"] as? String).map(jsonString) ?? "\"\""
                let scopes = ((parsed["scopes"] as? [Any])?.compactMap { $0 as? String } ?? []).map(jsonString).joined(separator: ",")
                return Self.json(200, "{\"url\":\(jsonString(parsedURL.absoluteString)),\"expiresAt\":\(expiresAt),\"scopes\":[\(scopes)]}")
            case .response(let status, let responseBody) where status == 404:
                return agentConnection404Reply(provider: provider, agentId: agentId, body: responseBody)
            default:
                return agentConnectionProviderFailure(result)
            }
        }
    }

    public func confirmAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        body: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded(_, let userId, let role):
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            guard let pending = object?["pending"] as? String, !pending.isEmpty else {
                return Self.json(400, "{\"error\":\"pending is required\",\"code\":\"agent_connection_invalid\"}")
            }
            guard Self.isAgentConnectionIdentifier(pending) else {
                return pendingInvalidReply()
            }
            let requestBody = "{\"pending\":\(jsonString(pending)),\"raftUserId\":\(jsonString(userId))}"
            let result = agentConnectionProviderCall(method: "POST", action: "confirm", provider: provider, agentId: agentId, body: requestBody)
            switch result {
            case .response(let status, let responseBody) where (200..<300).contains(status):
                guard let parsed = Self.parseConnectionStatus(responseBody) else {
                    return Self.json(502, "{\"error\":\"The provider could not complete the request\",\"code\":\"agent_connection_provider_error\",\"providerCode\":\"invalid_response\",\"providerMessage\":null,\"providerStatus\":\(status)}")
                }
                return Self.json(200, connectionStatusJSON(parsed, provider: provider, serverId: serverId, userId: userId, role: role))
            case .response(let status, let responseBody) where status == 404:
                let parts = Self.providerErrorParts(responseBody)
                return pendingInvalidReply(providerCode: parts.code, message: parts.message)
            default:
                return agentConnectionProviderFailure(result)
            }
        }
    }

    public func assignAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        body: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded(_, let userId, let role):
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            guard let connectorId = object?["connectorId"] as? String, Self.isAgentConnectionIdentifier(connectorId) else {
                return Self.json(400, "{\"error\":\"connectorId is required\",\"code\":\"agent_connection_invalid\"}")
            }
            let statusResult = agentConnectionProviderCall(method: "GET", action: "status", provider: provider, agentId: agentId)
            guard case .response(let statusCode, let statusBody) = statusResult,
                  (200..<300).contains(statusCode)
            else {
                if case .response(404, let body) = statusResult {
                    return agentConnection404Reply(provider: provider, agentId: agentId, body: body)
                }
                return agentConnectionProviderFailure(statusResult)
            }
            guard let parsed = Self.parseConnectionStatus(statusBody),
                  let connector = parsed.connectors.first(where: { $0.id == connectorId })
            else {
                return Self.json(404, "{\"error\":\"That connection does not exist on this server\",\"code\":\"agent_connection_connector_not_found\"}")
            }
            let isManager = role == "owner" || role == "admin"
            guard isManager || connector.creatorRaftUserId == userId else {
                return Self.json(403, "{\"error\":\"Only the connection's creator or a server admin can assign or disconnect it\",\"code\":\"agent_connection_connector_forbidden\"}")
            }
            let actingRole = connector.creatorRaftUserId == userId ? "creator" : "admin"
            let requestBody = "{\"connectorId\":\(jsonString(connectorId)),\"actingRaftUserId\":\(jsonString(userId)),\"actingRole\":\(jsonString(actingRole))}"
            let result = agentConnectionProviderCall(method: "PUT", action: "assign", provider: provider, agentId: agentId, body: requestBody)
            switch result {
            case .response(let status, _) where (200..<300).contains(status):
                let refreshed = agentConnectionProviderCall(method: "GET", action: "status", provider: provider, agentId: agentId)
                return agentConnectionStatusFailure(refreshed, provider: provider, agentId: agentId, serverId: serverId, userId: userId, role: role)
            case .response(let status, let responseBody) where status == 404:
                return agentConnection404Reply(provider: provider, agentId: agentId, body: responseBody, connectorScoped: true)
            default:
                return agentConnectionProviderFailure(result)
            }
        }
    }

    public func disconnectAgentConnection(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded:
            let result = agentConnectionProviderCall(method: "DELETE", action: "disconnect", provider: provider, agentId: agentId)
            switch result {
            case .response(let status, let responseBody) where status == 404:
                return agentConnection404Reply(provider: provider, agentId: agentId, body: responseBody)
            case .response(let status, _) where (200..<300).contains(status):
                return Self.json(204, "")
            case .empty(let status) where (200..<300).contains(status):
                return Self.json(204, "")
            default:
                return agentConnectionProviderFailure(result)
            }
        }
    }

    public func disconnectAgentConnector(
        authorization: String?,
        serverId: String,
        agentId: String,
        provider: String,
        connectorId: String
    ) -> HTTPReply {
        switch loadAgentForConnection(authorization: authorization, serverId: serverId, agentId: agentId, provider: provider) {
        case .refused(let reply):
            return reply
        case .loaded(_, let userId, let role):
            guard Self.isAgentConnectionIdentifier(connectorId) else {
                return Self.json(400, "{\"error\":\"connectorId is required\",\"code\":\"agent_connection_invalid\"}")
            }
            let statusResult = agentConnectionProviderCall(method: "GET", action: "status", provider: provider, agentId: agentId)
            guard case .response(let statusCode, let statusBody) = statusResult,
                  (200..<300).contains(statusCode)
            else {
                if case .response(404, let body) = statusResult {
                    return agentConnection404Reply(provider: provider, agentId: agentId, body: body)
                }
                return agentConnectionProviderFailure(statusResult)
            }
            guard let parsed = Self.parseConnectionStatus(statusBody),
                  let connector = parsed.connectors.first(where: { $0.id == connectorId })
            else {
                return Self.json(404, "{\"error\":\"That connection does not exist on this server\",\"code\":\"agent_connection_connector_not_found\"}")
            }
            let isManager = role == "owner" || role == "admin"
            guard isManager || connector.creatorRaftUserId == userId else {
                return Self.json(403, "{\"error\":\"Only the connection's creator or a server admin can assign or disconnect it\",\"code\":\"agent_connection_connector_forbidden\"}")
            }
            let actingRole = connector.creatorRaftUserId == userId ? "creator" : "admin"
            let requestBody = "{\"actingRaftUserId\":\(jsonString(userId)),\"actingRole\":\(jsonString(actingRole))}"
            let result = agentConnectionProviderCall(method: "DELETE", action: "disconnectConnector", provider: provider, agentId: agentId, body: requestBody)
            switch result {
            case .response(let status, let responseBody) where status == 502:
                let failed = (try? JSONSerialization.jsonObject(with: Data(responseBody.utf8))) as? [String: Any]
                let failedCount = (failed?["failed"] as? [Any])?.count ?? 0
                return Self.json(502, "{\"error\":\"Disconnect partially completed; retry to finish\",\"code\":\"agent_connection_connector_disconnect_partial\",\"failedCount\":\(failedCount)}")
            case .response(let status, let responseBody) where status == 404:
                return agentConnection404Reply(provider: provider, agentId: agentId, body: responseBody, connectorScoped: true)
            case .response(let status, _) where (200..<300).contains(status):
                return Self.json(204, "")
            case .empty(let status) where (200..<300).contains(status):
                return Self.json(204, "")
            default:
                return agentConnectionProviderFailure(result)
            }
        }
    }

    public func agentRuntimeForm(
        authorization: String?,
        serverId: String,
        agentId: String,
        language: String?
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
                || agent.creatorUserId == userId
        else {
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to edit agents\"}")
        }
        guard agent.runtime != "external", let schemaVersion = Self.runtimeFormSchemas[agent.runtime] else {
            return Self.json(404, "{\"error\":\"This agent's runtime configuration has no editable runtime form\",\"issues\":[{\"code\":\"no_runtime_form\",\"pointer\":\"/runtimeConfig\"}]}")
        }
        let config = (agent.runtimeConfigJSON.flatMap { $0.data(using: .utf8) })
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        var values: [String: Any] = [:]
        if agent.runtime != "antigravity",
           let model = config["model"] as? [String: Any],
           let id = (model["id"] as? String) ?? (model["name"] as? String) {
            values["model"] = id
        }
        values["envVars"] = (config["envVars"] as? [String: String]) ?? [:]
        var writeOnly: [String] = []
        if agent.runtime == "claude" {
            let provider = config["provider"] as? [String: Any]
            values["provider"] = (provider?["kind"] as? String) ?? "default"
            if let apiUrl = provider?["apiUrl"] as? String { values["apiUrl"] = apiUrl }
            if let effort = config["reasoningEffort"] as? String { values["reasoningEffort"] = effort }
            values["fastMode"] = (config["fastMode"] as? Bool) ?? false
            if let command = config["command"] as? String { values["command"] = command }
            writeOnly = ["/apiKey"]
        }
        let zh = Self.prefersChinese(language)
        let label = zh ? "模型" : "Model"
        let valueJSON = (try? JSONSerialization.data(withJSONObject: values))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let fields = "[{\"key\":\"model\",\"kind\":\"select\",\"label\":\(jsonString(label)),\"required\":true}]"
        let capabilities = "{\"providerKinds\":[\"preset\"],\"writeOnlyPointers\":[\(writeOnly.map(jsonString).joined(separator: ","))],\"forbiddenPointers\":[\"/hostUserState\"]}"
        return Self.json(200, "{\"protocolVersion\":2,\"runtimeId\":\(jsonString(agent.runtime)),\"schemaVersion\":\(jsonString(schemaVersion)),\"fields\":\(fields),\"values\":\(valueJSON),\"capabilities\":\(capabilities)}")
    }

    public func setAgentMachineForTesting(agentId: String, machineId: String) {
        lock.lock()
        agentMachineIds[agentId] = machineId
        lock.unlock()
    }

    public func setAgentStatusForTesting(agentId: String, status: String) {
        lock.lock()
        serverAgents[agentId]?.status = status
        lock.unlock()
    }

    /// Keyed lookup shared by `/daemon/connect` and the legacy machine surface.
    public func machineCredential(apiKey: String) -> MachineCredentialIdentity? {        lock.lock()
        defer { lock.unlock() }
        guard let machine = machines.first(where: { $0.apiKey == apiKey }) else { return nil }
        return MachineCredentialIdentity(machineId: machine.id, serverId: machine.serverId)
    }

    public func machineCredential(id: String) -> MachineCredentialIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let machine = machines.first(where: { $0.id == id }) else { return nil }
        return MachineCredentialIdentity(machineId: machine.id, serverId: machine.serverId)
    }

    public func serverExists(id: String) -> Bool {
        oauth.serverDetailsValue(id: id) != nil
    }

    /// Exact key match wins, then a revoked row with the same 16-character
    /// prefix, then a live row whose key does not verify, then absence.
    public func computerCredential(apiKey: String) -> ComputerCredentialLookup {
        lock.lock()
        defer { lock.unlock() }
        let prefix = String(apiKey.prefix(Self.computerAPIKeyPrefixLength))
        let candidates = computers.filter {
            String($0.apiKey.prefix(Self.computerAPIKeyPrefixLength)) == prefix
        }
        if let computer = candidates.first(where: { $0.apiKey == apiKey }) {
            if computer.revokedAt != nil { return .revoked }
            guard let machineId = computer.machineId,
                  machines.contains(where: { $0.id == machineId })
            else { return .machineUnlinked }
            return .linked(computerId: computer.id, machineId: machineId)
        }
        if candidates.contains(where: { $0.revokedAt != nil }) { return .revoked }
        if !candidates.isEmpty { return .keyMismatch }
        return .notFound
    }

    private static let machineAPIKeyPrefix = "sk_machine_"
    private static let computerAPIKeyPrefix = "sk_computer_"
    private static let computerAPIKeyPrefixLength = 16

    private static func machineAPIKeyMaterial() -> String {
        machineAPIKeyPrefix + credentialHex64()
    }

    private static func computerAPIKeyMaterial() -> String {
        computerAPIKeyPrefix + credentialHex64()
    }

    private static func credentialHex64() -> String {
        (UUID().uuidString + UUID().uuidString)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
    }

    private struct UserOnboarding {
        var reminderOptOut = false
        var dismissed: [String: Date] = [:]
        var currentStep: String?
    }

    private static let onboardingSteps: Set<String> = [
        "add-computer", "create-agent", "invite-teammates", "join-community", "notifications",
    ]

    private func onboardingJSON(serverId: String, userId: String) -> String {
        lock.lock()
        let server = serverOnboardingSettings[serverId] ?? (agentId: nil, greeting: true)
        let user = userOnboardingSettings["\(serverId)\n\(userId)"] ?? UserOnboarding()
        let slug = oauth.serverDetailsValue(id: serverId)?.slug ?? ""
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func dismissed(_ key: String) -> String {
            user.dismissed[key].map { jsonString(formatter.string(from: $0)) } ?? "null"
        }
        let agent = server.agentId.map { jsonString($0) } ?? "null"
        let step = user.currentStep.map { jsonString($0) } ?? "null"
        let wizardEnabled = !(slug == "community" || slug == "community-cn")
        return "{\"onboardingAgentId\":\(agent),\"agentAllChannelGreetingEnabled\":\(server.greeting),\"onboardingWizardEnabled\":\(wizardEnabled),\"setupModalReminderOptOut\":\(user.reminderOptOut),\"dismissedAddComputerStepAt\":\(dismissed("add-computer")),\"dismissedCreateAgentStepAt\":\(dismissed("create-agent")),\"dismissedInviteStepAt\":\(dismissed("invite-teammates")),\"dismissedCommunityStepAt\":\(dismissed("join-community")),\"dismissedNotificationStepAt\":\(dismissed("notifications")),\"onboardingWizardCurrentStep\":\(step)}"
    }

    public func serverSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let onboarding = onboardingJSON(serverId: serverId, userId: userId)
        return Self.json(200, "{\"settings\":{\"onboardSettings\":\(onboarding),\"feedbackSettings\":{\"enabled\":true}}}")
    }

    public func serverOnboardingSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        return Self.json(200, onboardingJSON(serverId: serverId, userId: userId))
    }

    public func patchServerOnboardingSettings(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid onboarding settings\"}")
        }
        let isAdmin = role == "owner" || role == "admin"
        if object["onboardingAgentId"] != nil || object["agentAllChannelGreetingEnabled"] != nil {
            guard isAdmin else {
                return Self.json(403, "{\"error\":\"Only server owners and admins can update onboarding settings\"}")
            }
        }
        if let greeting = object["agentAllChannelGreetingEnabled"] {
            guard greeting is Bool else {
                return Self.json(400, "{\"error\":\"agentAllChannelGreetingEnabled must be a boolean\"}")
            }
        }
        if let rawStep = object["onboardingWizardCurrentStep"], !(rawStep is NSNull) {
            guard let step = rawStep as? String, Self.onboardingSteps.contains(step) else {
                return Self.json(400, "{\"error\":\"Invalid onboarding step\"}")
            }
        }
        lock.lock()
        var server = serverOnboardingSettings[serverId] ?? (agentId: nil, greeting: true)
        if isAdmin {
            if let rawAgent = object["onboardingAgentId"] {
                if rawAgent is NSNull {
                    server.agentId = nil
                } else if let agentId = rawAgent as? String {
                    server.agentId = agentId
                }
            }
            if let greeting = object["agentAllChannelGreetingEnabled"] as? Bool {
                server.greeting = greeting
            }
            serverOnboardingSettings[serverId] = server
        }
        let key = "\(serverId)\n\(userId)"
        var user = userOnboardingSettings[key] ?? UserOnboarding()
        if let value = object["setupModalReminderOptOut"] as? Bool {
            user.reminderOptOut = value
        }
        if let rawStep = object["onboardingWizardCurrentStep"] {
            user.currentStep = rawStep is NSNull ? nil : rawStep as? String
        }
        let dismissKeys: [(String, String)] = [
            ("dismissedAddComputerStep", "add-computer"),
            ("dismissedCreateAgentStep", "create-agent"),
            ("dismissedInviteStep", "invite-teammates"),
            ("dismissedCommunityStep", "join-community"),
            ("dismissedNotificationStep", "notifications"),
        ]
        for (field, step) in dismissKeys {
            if object[field] as? Bool == true, user.dismissed[step] == nil {
                user.dismissed[step] = Date()
            }
        }
        userOnboardingSettings[key] = user
        lock.unlock()
        return Self.json(200, onboardingJSON(serverId: serverId, userId: userId))
    }

    private func serverNotificationJSON(_ prefs: (muted: Bool, mentionsOnly: Bool, mode: String, version: Int)) -> String {
        "{\"serverPushMuted\":\(prefs.muted),\"serverPushMentionsOnly\":\(prefs.mentionsOnly),\"serverPushMode\":\(jsonString(prefs.mode)),\"prefsVersion\":\(prefs.version)}"
    }

    public func memberNotificationSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        let prefs = serverNotificationPrefs["\(serverId)\n\(userId)"] ?? (muted: false, mentionsOnly: false, mode: "all", version: 0)
        lock.unlock()
        return Self.json(200, serverNotificationJSON(prefs))
    }

    public func patchServerNotificationSettings(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid notification settings\"}")
        }
        if let muted = object["serverPushMuted"], !(muted is Bool) {
            return Self.json(400, "{\"error\":\"serverPushMuted must be a boolean\"}")
        }
        if let rawMode = object["serverPushMode"] {
            guard let mode = rawMode as? String, ["all", "mentions", "none"].contains(mode) else {
                return Self.json(400, "{\"error\":\"serverPushMode must be one of all, mentions, none\"}")
            }
        }
        lock.lock()
        let key = "\(serverId)\n\(userId)"
        var prefs = serverNotificationPrefs[key] ?? (muted: false, mentionsOnly: false, mode: "all", version: 0)
        if let mode = object["serverPushMode"] as? String {
            prefs.mode = mode
            prefs.muted = mode == "none"
            prefs.mentionsOnly = mode == "mentions"
        }
        if let muted = object["serverPushMuted"] as? Bool {
            prefs.muted = muted
            if muted {
                prefs.mode = "none"
                prefs.mentionsOnly = false
            } else if prefs.mode == "none" {
                prefs.mode = "all"
                prefs.mentionsOnly = false
            }
        }
        let previous = serverNotificationPrefs[key]
        let changed = previous == nil
            || previous!.muted != prefs.muted
            || previous!.mentionsOnly != prefs.mentionsOnly
            || previous!.mode != prefs.mode
        if changed {
            prefs.version = (previous?.version ?? 0) + 1
        }
        serverNotificationPrefs[key] = prefs
        lock.unlock()
        if changed {
            let payload = "{\"serverId\":\(jsonString(serverId)),\"scopeId\":\(jsonString(serverId)),\"prefs\":{\"serverPushMuted\":\(prefs.muted),\"serverPushMentionsOnly\":\(prefs.mentionsOnly),\"serverPushMode\":\(jsonString(prefs.mode))},\"prefsVersion\":\(prefs.version)}"
            emitRealtime("user:\(userId)", "notification_prefs:updated", payload)
        }
        return Self.json(200, serverNotificationJSON(prefs))
    }

    public func registerServerMachine(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"The `registerMachines` capability is required to register machines\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Self.json(400, "{\"error\":\"Name is required\"}")
        }
        let machineId = registerMachine(serverId: serverId, userId: userId, name: name)
        let apiKey = machineAPIKey(machineId: machineId) ?? ""
        let machine = "{\"id\":\(jsonString(machineId)),\"serverId\":\(jsonString(serverId)),\"name\":\(jsonString(name)),\"userId\":\(jsonString(userId)),\"description\":null}"
        emitRealtime("server:\(serverId)", "machine:updated", "{\"serverId\":\(jsonString(serverId)),\"machineId\":\(jsonString(machineId))}")
        return Self.json(200, "{\"machine\":\(machine),\"apiKey\":\(jsonString(apiKey))}")
    }

    private static let runtimeFormSchemas: [String: String] = [
        "builtin": "builtin-pi.create.v3",
        "claude": "claude.create.v1",
        "codex": "codex.create.v1",
        "kimi-sdk": "kimi-sdk.create.v1",
        "cursor": "cursor.create.v1",
        "opencode": "opencode.create.v1",
        "pi": "pi.create.v1",
        "gemini": "gemini.create.v1",
        "kimi": "kimi.create.v1",
        "antigravity": "antigravity.create.v1",
    ]

    public func runtimeFormDefinition(
        authorization: String?,
        serverId: String,
        machineId: String,
        runtimeId: String,
        protocolVersion: Int,
        schemaVersion: String?,
        language: String?
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or machine creator authority is required to inspect runtime forms\"}")
        }
        guard let expected = Self.runtimeFormSchemas[runtimeId] else {
            return Self.json(404, "{\"error\":\"Runtime form not found\",\"issues\":[{\"code\":\"unknown_form_runtime\",\"pointer\":\"/runtimeId\"}]}")
        }
        if protocolVersion == 1, let schemaVersion, schemaVersion != expected {
            return Self.json(409, "{\"error\":\"Runtime form schema is stale or unknown\",\"issues\":[{\"code\":\"stale_form_schema\",\"pointer\":\"/schemaVersion\"}]}")
        }
        let zh = Self.prefersChinese(language)
        if protocolVersion == 2 {
            let label = zh ? "模型" : "Model"
            return Self.json(200, "{\"protocolVersion\":2,\"runtimeId\":\(jsonString(runtimeId)),\"schemaVersion\":\(jsonString(expected)),\"fields\":[{\"key\":\"model\",\"kind\":\"select\",\"label\":\(jsonString(label)),\"required\":true}],\"capabilities\":{\"providerKinds\":[\"preset\"],\"writeOnlyPointers\":[\"/apiKey\"],\"forbiddenPointers\":[\"/hostUserState\"]}}")
        }
        let properties: String
        let required: String
        let sources: String
        if runtimeId == "builtin" {
            properties = "{\"apiKey\":{\"type\":\"string\",\"writeOnly\":true},\"supportsImageInput\":{\"type\":\"boolean\"},\"providerId\":{\"type\":\"string\"},\"model\":{\"type\":\"string\"}}"
            required = "[\"providerId\",\"model\"]"
            sources = "{\"provider\":{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"provider\"},\"model\":{\"protocolVersion\":1,\"runtimeId\":\"builtin\",\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\"}}"
        } else {
            properties = "{\"model\":{\"type\":\"string\"}}"
            required = "[\"model\"]"
            sources = "{\"model\":{\"protocolVersion\":1,\"runtimeId\":\(jsonString(runtimeId)),\"schemaVersion\":\(jsonString(expected)),\"sourceId\":\"model\"}}"
        }
        return Self.json(200, "{\"protocolVersion\":1,\"runtimeId\":\(jsonString(runtimeId)),\"schemaVersion\":\(jsonString(expected)),\"dataSchema\":{\"type\":\"object\",\"properties\":\(properties),\"required\":\(required)},\"uiSchema\":{},\"capabilities\":{\"providerKinds\":[\"preset\"],\"writeOnlyPointers\":[\"/apiKey\"],\"forbiddenPointers\":[\"/hostUserState\"]},\"optionSources\":\(sources)}")
    }

    public func runtimeFormOptionSource(
        authorization: String?,
        serverId: String,
        machineId: String,
        runtimeId: String,
        sourceId: String,
        protocolVersion: Int,
        schemaVersion: String?,
        language: String?
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        let cachedModels = machineRuntimeModels[machineId]?[runtimeId]?.models ?? []
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or machine creator authority is required to inspect runtime form option sources\"}")
        }
        guard let expected = Self.runtimeFormSchemas[runtimeId] else {
            return Self.json(404, "{\"error\":\"Runtime form option source not found\",\"issues\":[{\"code\":\"unknown_form_runtime\",\"pointer\":\"/runtimeId\"}]}")
        }
        if protocolVersion == 1, let schemaVersion, schemaVersion != expected {
            return Self.json(409, "{\"error\":\"Runtime form schema is stale or unknown\",\"issues\":[{\"code\":\"stale_form_schema\",\"pointer\":\"/schemaVersion\"}]}")
        }
        let zh = Self.prefersChinese(language)
        switch sourceId {
        case "provider" where runtimeId == "builtin":
            let options = "{\"value\":\"deepseek\",\"label\":\(jsonString(zh ? "DeepSeek" : "DeepSeek")),\"providerKind\":\"preset\"},{\"value\":\"moonshotai\",\"label\":\(jsonString(zh ? "月之暗面" : "Moonshot AI")),\"providerKind\":\"preset\"}"
            return Self.json(200, "{\"sourceId\":\"provider\",\"schemaVersion\":\(jsonString(expected)),\"kind\":\"select\",\"options\":[\(options)]}")
        case "model":
            if runtimeId == "builtin" {
                let deepseek = "{\"value\":\"deepseek-chat\",\"label\":\"DeepSeek Chat\"}"
                let moonshot = "{\"value\":\"kimi-k2\",\"label\":\"Kimi K2\"}"
                return Self.json(200, "{\"sourceId\":\"model\",\"schemaVersion\":\(jsonString(expected)),\"kind\":\"dependent_select\",\"optionsByValue\":{\"deepseek\":[\(deepseek)],\"moonshotai\":[\(moonshot)]}}")
            }
            let options = cachedModels.map { "{\"value\":\(jsonString($0.id)),\"label\":\(jsonString($0.label))}" }.joined(separator: ",")
            return Self.json(200, "{\"sourceId\":\"model\",\"schemaVersion\":\(jsonString(expected)),\"kind\":\"select\",\"options\":[\(options)]}")
        default:
            return Self.json(404, "{\"error\":\"Runtime form option source not found\",\"issues\":[{\"code\":\"unknown_option_source\",\"pointer\":\"/sourceId\"}]}")
        }
    }

    private static func prefersChinese(_ language: String?) -> Bool {
        guard let language else { return false }
        return language.lowercased().hasPrefix("zh")
    }

    public func setRuntimeAccountUsageForTesting(
        machineId: String,
        provider: String,
        json: String,
        staleAfter: Date
    ) {
        lock.lock()
        runtimeAccountUsage["\(machineId)\n\(provider)"] = (json, staleAfter)
        lock.unlock()
    }

    public func machineRuntimeAccountUsage(
        authorization: String?,
        serverId: String,
        machineId: String,
        provider: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard Self.runtimeAccountUsageProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Runtime account usage provider not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        let attacher = computerAttachers[machineId]
        let record = runtimeAccountUsage["\(machineId)\n\(provider)"]
        lock.unlock()
        guard canInspectRuntimeAccountUsage(serverId: serverId, userId: userId, attacher: attacher) else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or attaching-human authority is required to inspect runtime account usage\"}")
        }
        _ = machine
        guard let record else {
            return Self.json(200, "{\"state\":\"missing\",\"snapshot\":null}")
        }
        let state = record.staleAfter <= Date() ? "stale" : "fresh"
        return Self.json(200, "{\"state\":\(jsonString(state)),\"snapshot\":\(record.json)}")
    }

    public func refreshMachineRuntimeAccountUsage(
        authorization: String?,
        serverId: String,
        machineId: String,
        provider: String,
        body: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard Self.runtimeAccountUsageProviders.contains(provider) else {
            return Self.json(404, "{\"error\":\"Runtime account usage provider not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        let attacher = computerAttachers[machineId]
        let online = machineOnline[machineId] == true
        lock.unlock()
        _ = machine
        guard canInspectRuntimeAccountUsage(serverId: serverId, userId: userId, attacher: attacher) else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or attaching-human authority is required to refresh runtime account usage\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let manual = (object["reason"] as? String) == "manual"
        let key = "\(machineId)\n\(provider)"
        lock.lock()
        let now = Date()
        if let last = runtimeAccountUsageRefreshAt[key], now.timeIntervalSince(last) < 60 {
            lock.unlock()
            return Self.json(202, "{\"accepted\":false,\"state\":\"cooldown\"}")
        }
        lock.unlock()

        guard manual else {
            lock.lock()
            runtimeAccountUsageRefreshAt[key] = now
            lock.unlock()
            return Self.json(202, "{\"accepted\":true,\"state\":\"requested\"}")
        }

        guard online else {
            return Self.json(202, "{\"accepted\":false,\"state\":\"computer_offline\"}")
        }

        let result = runtimeAccountUsageManualRefresh?(machineId, provider) ?? .timeout
        switch result {
        case .snapshot(let json):
            let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            let staleAfter = (parsed?["staleAfter"] as? String).flatMap(Self.isoDate) ?? now.addingTimeInterval(1800)
            lock.lock()
            runtimeAccountUsage[key] = (json, staleAfter)
            runtimeAccountUsageRefreshAt[key] = now
            lock.unlock()
            return Self.json(200, "{\"accepted\":true,\"state\":\"fresh\",\"snapshot\":\(json)}")
        case .timeout:
            lock.lock()
            runtimeAccountUsageRefreshAt[key] = now
            lock.unlock()
            return Self.json(200, "{\"accepted\":true,\"state\":\"timeout\"}")
        case .offline:
            return Self.json(202, "{\"accepted\":false,\"state\":\"computer_offline\"}")
        }
    }

    private func canInspectRuntimeAccountUsage(serverId: String, userId: String, attacher: String?) -> Bool {
        if attacher == userId { return true }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        return role == "owner" || role == "admin"
    }

    private static let runtimeAccountUsageProviders: Set<String> = ["claude", "codex", "kimi", "grok"]

    public func machineRuntimeOptions(authorization: String?, serverId: String, machineId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        let installed = Set(machine.runtimes)
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or machine creator authority is required to inspect runtime options\"}")
        }
        let catalog: [(id: String, binary: String)] = [
            ("claude", "claude"),
            ("codex", "codex"),
            ("builtin", ""),
            ("kimi-sdk", ""),
            ("cursor", "cursor-agent"),
            ("opencode", "opencode"),
            ("pi", "pi"),
        ]
        let options = catalog.map { runtime -> String in
            let capability = installed.contains(runtime.id)
                ? "available"
                : (runtime.binary.isEmpty ? "update_required" : "not_installed")
            let canSelect = capability == "available"
            return "{\"runtimeId\":\(jsonString(runtime.id)),\"capabilityStatus\":\(jsonString(capability)),\"admissionStatus\":\"available_for_new\",\"admissionReason\":null,\"current\":false,\"availableForNew\":true,\"manageableForCurrentAgent\":false,\"canSelectInThisContext\":\(canSelect)}"
        }.joined(separator: ",")
        return Self.json(200, "{\"context\":\"new_agent\",\"machineId\":\(jsonString(machine.id)),\"options\":[\(options)]}")
    }

    public func machineRuntimeModels(authorization: String?, serverId: String, machineId: String, runtime: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found in this server\"}")
        }
        let models = machineRuntimeModels[machineId]?[runtime]?.models ?? []
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or machine creator authority is required to inspect runtime models\"}")
        }
        let modelJSON = models.map {
            "{\"id\":\(jsonString($0.id)),\"label\":\(jsonString($0.label))}"
        }.joined(separator: ",")
        let defaultModel = models.first?.id
        let defaultJSON = defaultModel.map(jsonString) ?? "null"
        return Self.json(200, "{\"kind\":\"live\",\"value\":{\"models\":[\(modelJSON)],\"default\":\(defaultJSON)},\"models\":[\(modelJSON)],\"default\":\(defaultJSON)}")
    }

    public func machineWorkspaces(authorization: String?, serverId: String, machineId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found in this server\"}")
        }
        let canManage = role == "owner" || role == "admin" || machine.userId == userId
        let keys = agentMachineIds.filter { $0.value == machineId }.map(\.key)
        let deleted = deletedMachineWorkspaces
        lock.unlock()
        guard canManage else {
            return Self.json(403, "{\"error\":\"You do not have permission to view machine workspaces\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let epoch = formatter.string(from: Date(timeIntervalSince1970: 0))
        let rows = keys.compactMap { agentId -> String? in
            guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId else { return nil }
            if deleted.contains("\(machineId)\n\(agentId)") { return nil }
            let agentStatus: String
            lock.lock()
            agentStatus = serverAgents[agentId]?.status ?? "inactive"
            lock.unlock()
            let status = agent.deleted ? "deleted" : (agentStatus == "inactive" ? "stopped" : "active")
            let name = agent.displayName.isEmpty ? agent.name : agent.displayName
            return "{\"directoryName\":\(jsonString(agent.id)),\"totalSizeBytes\":0,\"lastModified\":\(jsonString(epoch)),\"fileCount\":0,\"status\":\(jsonString(status)),\"agentName\":\(jsonString(name)),\"agentStatus\":\(jsonString(agentStatus))}"
        }
        return Self.json(200, "[\(rows.joined(separator: ","))]")
    }

    public func deleteMachineWorkspace(authorization: String?, serverId: String, machineId: String, directoryName: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found in this server\"}")
        }
        let canManage = role == "owner" || role == "admin" || machine.userId == userId
        let ownsDirectory = agentMachineIds[directoryName] == machineId
        lock.unlock()
        guard canManage else {
            return Self.json(403, "{\"error\":\"The `controlComputers` capability or machine creator authority is required to delete machine workspaces\"}")
        }
        guard ownsDirectory, let agent = oauth.agentRuntimeInfo(id: directoryName), agent.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Workspace not found\"}")
        }
        lock.lock()
        deletedMachineWorkspaces.insert("\(machineId)\n\(directoryName)")
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func serverUsage(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Guests cannot access server management data\"}")
        }
        let agents = oauth.serverAgents(serverId: serverId).count
        lock.lock()
        let machinesCount = machines.filter { $0.serverId == serverId }.count
        lock.unlock()
        let channels = oauth.channelsForServer(serverId: serverId, userId: userId, includeArchived: true)
            .filter { ($0.type == "channel" || $0.type == "private") && oauth.channelArchivedAt(id: $0.id) == nil }
            .count
        return Self.json(200, "{\"agents\":\(agents),\"machines\":\(machinesCount),\"channels\":\(channels)}")
    }

    public func serverSystemNotifications(authorization: String?, serverId: String) -> HTTPReply {        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let generatedAt = Date()
        if role == "guest" {
            return Self.json(200, serverSystemNotificationsBody(generatedAt: generatedAt, notifications: []))
        }
        lock.lock()
        let rows = machines.filter { $0.serverId == serverId }
        let online = machineOnline
        let computerMachineIds = Set(computers.compactMap { computer -> String? in
            guard computer.serverId == serverId, computer.revokedAt == nil else { return nil }
            return computer.machineId
        })
        var activeByMachine: [String: Int] = [:]
        for agent in serverAgents.values where agent.serverId == serverId && agent.status == "active" {
            if let machineId = agentMachineIds[agent.id] {
                activeByMachine[machineId, default: 0] += 1
            }
        }
        lock.unlock()

        let rawDaemons = rows
            .filter { !computerMachineIds.contains($0.id) }
            .sorted { $0.id < $1.id }
        let offline = rawDaemons.filter { online[$0.id] != true }
        var notifications: [String] = []
        if !offline.isEmpty {
            let activeCount = offline.reduce(0) { $0 + (activeByMachine[$1.id] ?? 0) }
            let names = offline.map(\.name).joined(separator: ", ")
            let singular = offline.count == 1
            let title = "\(names) \(singular ? "is" : "are") offline"
            let body = activeCount > 0
                ? "\(activeCount) \(activeCount == 1 ? "agent is" : "agents are") active on \(singular ? "this computer" : "these computers") and can't run until \(singular ? "it reconnects" : "they reconnect")."
                : "No agents are active on \(singular ? "this computer" : "these computers") right now — reconnect when you need \(singular ? "it" : "them") next."
            let ids = offline.map(\.id).joined(separator: ",")
            let machineRefs = offline.map {
                "{\"id\":\(jsonString($0.id)),\"name\":\(jsonString($0.name))}"
            }.joined(separator: ",")
            let copyTitle = singular ? "machine.offline.title.one" : "machine.offline.title.many"
            let copyBody = activeCount > 0
                ? (singular ? "machine.offline.body.active.one" : "machine.offline.body.active.many")
                : (singular ? "machine.offline.body.idle.one" : "machine.offline.body.idle.many")
            let evaluation = "{\"clock\":\"server\",\"evaluatedAt\":\(jsonString(Self.isoString(generatedAt))),\"offlineAfterMs\":0,\"statusAuthority\":\"canonical_machine_read_model\",\"runKind\":\"raw_daemon\",\"versionAuthority\":\"latest_daemon_release\"}"
            let notification = "{\"id\":\(jsonString("machine-offline:\(ids)")),\"type\":\"machine.offline\",\"schemaVersion\":1,\"state\":\"active\",\"kind\":\"\(activeCount > 0 ? "error" : "warning")\",\"title\":\(jsonString(title)),\"body\":\(jsonString(body)),\"copy\":{\"titleKey\":\(jsonString(copyTitle)),\"bodyKey\":\(jsonString(copyBody)),\"actionLabelKey\":\"common.view\",\"params\":{\"machineNames\":\(jsonString(names)),\"machineCount\":\(offline.count),\"activeAgentCount\":\(activeCount),\"targetDaemonVersion\":null}},\"action\":{\"label\":\"View\",\"targetType\":\"machine\",\"targetId\":\(jsonString(offline[0].id))},\"payload\":{\"machines\":[\(machineRefs)],\"activeAgentCount\":\(activeCount),\"targetDaemonVersion\":null,\"evaluation\":\(evaluation)}}"
            notifications.append(notification)
        }
        return Self.json(200, serverSystemNotificationsBody(generatedAt: generatedAt, notifications: notifications))
    }

    private func serverSystemNotificationsBody(generatedAt: Date, notifications: [String]) -> String {
        "{\"contractVersion\":\"server-system-notifications-v1\",\"generatedAt\":\(jsonString(Self.isoString(generatedAt))),\"snapshotMode\":\"replace\",\"clientState\":{\"read\":\"none\",\"dismiss\":\"local_by_notification_id\"},\"notifications\":[\(notifications.joined(separator: ","))]}"
    }

    public func enableUsageLimitAttentionForServer(_ serverId: String) {
        lock.lock()
        usageLimitAttentionServers.insert(serverId)
        lock.unlock()
    }

    public func disableUsageLimitAttentionForServer(_ serverId: String) {
        lock.lock()
        usageLimitAttentionServers.remove(serverId)
        lock.unlock()
    }

    @discardableResult
    public func addSystemAttentionIncidentForTesting(
        serverId: String,
        machineId: String,
        provider: String = "codex",
        windowKey: String = "primary",
        affectedAgentIds: [String] = [],
        activatedAt: Date = Date(),
        resetsAt: Date? = nil
    ) -> String {
        lock.lock()
        let generation = (systemAttentionIncidents
            .filter { $0.serverId == serverId && $0.machineId == machineId && $0.provider == provider && $0.windowKey == windowKey }
            .map(\.activationGeneration)
            .max() ?? 0) + 1
        let id = UUID().uuidString.lowercased()
        systemAttentionIncidents.append(SystemAttentionIncident(
            id: id,
            serverId: serverId,
            machineId: machineId,
            provider: provider,
            windowKey: windowKey,
            activationGeneration: generation,
            affectedAgentIds: affectedAgentIds,
            activatedAt: activatedAt,
            lastObservedAt: activatedAt,
            resetsAt: resetsAt,
            state: "active"
        ))
        lock.unlock()
        return id
    }

    public func listSystemAttention(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let generatedAt = Date()
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else {
            return Self.json(200, systemAttentionBody(generatedAt: generatedAt, notifications: []))
        }
        lock.lock()
        guard usageLimitAttentionServers.contains(serverId) else {
            lock.unlock()
            return Self.json(200, systemAttentionBody(generatedAt: generatedAt, notifications: []))
        }
        let incidents = systemAttentionIncidents
            .filter { $0.serverId == serverId && $0.state == "active" }
            .filter { systemAttentionReceipts["\($0.id)\n\(userId)"]?.dismissedAt == nil }
            .sorted { $0.activatedAt > $1.activatedAt }
        let notifications = incidents.map { incident -> String in
            let seenAt = systemAttentionReceipts["\(incident.id)\n\(userId)"]?.seenAt.map { jsonString(Self.isoString($0)) } ?? "null"
            let resetsAt = incident.resetsAt.map { jsonString(Self.isoString($0)) } ?? "null"
            let machineName = machines.first { $0.id == incident.machineId }?.name ?? ""
            let affected = incident.affectedAgentIds.map(jsonString).joined(separator: ",")
            return "{\"id\":\(jsonString(incident.id)),\"kind\":\"usage_limit_reached\",\"severity\":\"warning\",\"state\":\"active\",\"activatedAt\":\(jsonString(Self.isoString(incident.activatedAt))),\"lastObservedAt\":\(jsonString(Self.isoString(incident.lastObservedAt))),\"seenAt\":\(seenAt),\"machine\":{\"id\":\(jsonString(incident.machineId)),\"name\":\(jsonString(machineName))},\"provider\":\(jsonString(incident.provider)),\"windowKey\":\(jsonString(incident.windowKey)),\"resetsAt\":\(resetsAt),\"affectedAgentIds\":[\(affected)]}"
        }
        lock.unlock()
        return Self.json(200, systemAttentionBody(generatedAt: generatedAt, notifications: notifications))
    }

    public func markSystemAttentionSeen(authorization: String?, serverId: String, incidentId: String) -> HTTPReply {
        systemAttentionReceipt(authorization: authorization, serverId: serverId, incidentId: incidentId, dismiss: false)
    }

    public func dismissSystemAttention(authorization: String?, serverId: String, incidentId: String) -> HTTPReply {
        systemAttentionReceipt(authorization: authorization, serverId: serverId, incidentId: incidentId, dismiss: true)
    }

    private func systemAttentionReceipt(
        authorization: String?,
        serverId: String,
        incidentId: String,
        dismiss: Bool
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard ServerScope.isUUID(incidentId) else {
            return Self.json(400, "{\"error\":\"Invalid system attention incident\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
        else {
            return Self.json(404, "{\"error\":\"System attention incident not found\"}")
        }
        lock.lock()
        guard usageLimitAttentionServers.contains(serverId),
              systemAttentionIncidents.contains(where: {
                  $0.id == incidentId && $0.serverId == serverId && $0.state == "active"
              })
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"System attention incident not found\"}")
        }
        let key = "\(incidentId)\n\(userId)"
        let now = Date()
        var receipt = systemAttentionReceipts[key] ?? SystemAttentionReceipt(seenAt: nil, dismissedAt: nil)
        if receipt.seenAt == nil { receipt.seenAt = now }
        if dismiss { receipt.dismissedAt = now }
        systemAttentionReceipts[key] = receipt
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    private func systemAttentionBody(generatedAt: Date, notifications: [String]) -> String {
        let unseen = notifications.reduce(0) { count, notification in
            count + (notification.contains("\"seenAt\":null") ? 1 : 0)
        }
        return "{\"contractVersion\":\"server-system-attention-v1\",\"generatedAt\":\(jsonString(Self.isoString(generatedAt))),\"snapshotMode\":\"replace\",\"unseenCount\":\(unseen),\"notifications\":[\(notifications.joined(separator: ","))]}"
    }

    public func listServerMachines(authorization: String?, serverId: String) -> HTTPReply {        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let rows = machines.filter { $0.serverId == serverId }
        lock.unlock()
        let json = rows.map { machine in
            "{\"id\":\(jsonString(machine.id)),\"name\":\(jsonString(machine.name)),\"userId\":\(jsonString(machine.userId)),\"description\":\(machine.description.map { jsonString($0) } ?? "null")}"
        }.joined(separator: ",")
        return Self.json(200, "{\"machines\":[\(json)]}")
    }

    public func patchServerMachine(authorization: String?, serverId: String, machineId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let index = machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found\"}")
        }
        if role != "owner", role != "admin", machines[index].userId != userId {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        if let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
           let description = object["description"] as? String {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            machines[index].description = trimmed.isEmpty ? nil : trimmed
        }
        let machine = machines[index]
        lock.unlock()
        emitRealtime("server:\(serverId)", "machine:updated", "{\"serverId\":\(jsonString(serverId)),\"machineId\":\(jsonString(machineId))}")
        return Self.json(200, "{\"id\":\(jsonString(machine.id)),\"name\":\(jsonString(machine.name)),\"description\":\(machine.description.map { jsonString($0) } ?? "null")}")
    }

    public func rotateServerMachineKey(authorization: String?, serverId: String, machineId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let index = machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found\"}")
        }
        if role != "owner", role != "admin", machines[index].userId != userId {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        machines[index].apiKey = Self.machineAPIKeyMaterial()
        let key = machines[index].apiKey ?? ""
        lock.unlock()
        return Self.json(200, "{\"apiKey\":\(jsonString(key))}")
    }

    public func attachComputer(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let slug = object["serverSlug"] as? String,
              oauth.serverDetailsValue(id: serverId)?.slug == slug
        else {
            return Self.json(400, "{\"error\":\"Invalid computer attach request\"}")
        }
        let machineId = registerMachine(serverId: serverId, userId: userId, name: name)
        let apiKey = Self.computerAPIKeyMaterial()
        lock.lock()
        computers.append((id: UUID().uuidString.lowercased(), serverId: serverId, name: name, apiKey: apiKey, machineId: machineId, revokedAt: nil, online: false, version: nil))
        computerAttachers[machineId] = userId
        lock.unlock()
        return Self.json(201, "{\"apiKey\":\(jsonString(apiKey)),\"machineId\":\(jsonString(machineId))}")
    }

    public func computerRunners(authorization: String?) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Invalid computer credential\"}")
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let valid = computers.contains { computer in
            computer.apiKey == apiKey
                && computer.revokedAt == nil
                && computer.machineId.map { machineId in machines.contains { $0.id == machineId } } == true
        }
        lock.unlock()
        guard valid else {
            return Self.json(401, "{\"error\":\"Invalid computer credential\"}")
        }
        return Self.json(200, "{\"runners\":[]}")
    }

    public func setMachineRuntimeModels(machineId: String, runtime: String, models: [(id: String, label: String)]) {
        lock.lock()
        machineRuntimeModels[machineId, default: [:]][runtime] = (models, Date())
        lock.unlock()
    }

    public func linkComputerForTesting(serverId: String, machineId: String, online: Bool = false, version: String? = "1.0.0", attachedByUserId: String? = nil) {
        lock.lock()
        computers.append((
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            name: "linked-computer",
            apiKey: Self.computerAPIKeyMaterial(),
            machineId: machineId,
            revokedAt: nil,
            online: online,
            version: version
        ))
        if let attachedByUserId { computerAttachers[machineId] = attachedByUserId }
        lock.unlock()
    }

    public func computerAction(authorization: String?, serverId: String, machineId: String, action: String, body: String = "") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard ["restart", "start", "stop", "upgrade"].contains(action) else {
            return Self.json(400, "{\"error\":\"Unknown computer action\",\"code\":\"unknown_action\"}")
        }
        if action == "upgrade" {
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            let target = (object?["targetVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !target.isEmpty else {
                return Self.json(400, "{\"error\":\"targetVersion is required\",\"code\":\"invalid_target_version\"}")
            }
        }
        lock.lock()
        let machineExists = machines.contains { $0.id == machineId && $0.serverId == serverId }
        let linked = computers.filter { candidate in
            candidate.serverId == serverId
                && candidate.machineId == machineId
                && candidate.revokedAt == nil
        }
        let computer = linked.first { $0.online } ?? linked.first
        lock.unlock()
        guard machineExists else {
            return Self.json(404, "{\"error\":\"Machine not found\"}")
        }
        guard let computer else {
            return Self.json(409, "{\"error\":\"Machine is not a Computer\",\"code\":\"not_a_computer\"}")
        }
        guard computer.online else {
            return Self.json(409, "{\"error\":\"Computer is offline\",\"code\":\"computer_offline\"}")
        }
        guard let version = computer.version, !version.isEmpty else {
            return Self.json(409, "{\"error\":\"Raft couldn't verify the Computer version. Reconnect the Computer, then try again.\",\"code\":\"computer_control_unsupported\"}")
        }
        return Self.json(200, "{\"ok\":true,\"action\":\(jsonString(action)),\"requestId\":\(jsonString(UUID().uuidString.lowercased())),\"operationId\":\(jsonString(UUID().uuidString.lowercased())),\"computerVersion\":\(jsonString(version))}")
    }

    public func machineRuntimeRescan(authorization: String?, serverId: String, machineId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Computer not found\"}")
        }
        let online = machineOnline[machineId] == true
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `editMachines` capability or machine creator authority is required to rescan runtimes\"}")
        }
        guard online else {
            return Self.json(409, "{\"error\":\"Computer is offline\"}")
        }
        return Self.json(200, "{\"requested\":true}")
    }

    public func modelLabelCatalog(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let serverMachines = machines.filter { $0.serverId == serverId }
        let snapshot = machineRuntimeModels
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let machinesJSON = serverMachines.map { machine -> String in
            let runtimes = snapshot[machine.id] ?? [:]
            let runtimesJSON = runtimes.map { runtime, entry -> String in
                let models = entry.models.map { model in
                    "{\"id\":\(jsonString(model.id)),\"label\":\(jsonString(model.label))}"
                }.joined(separator: ",")
                return "\(jsonString(runtime)):{\"models\":[\(models)],\"updatedAt\":\(jsonString(formatter.string(from: entry.updatedAt)))}"
            }.joined(separator: ",")
            return "\(jsonString(machine.id)):{\"runtimes\":{\(runtimesJSON)}}"
        }.joined(separator: ",")
        return Self.json(200, "{\"machines\":{\(machinesJSON)}}")
    }

    public func machineCount(serverId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return machines.filter { $0.serverId == serverId }.count
    }

    public func deleteServerMachine(authorization: String?, serverId: String, machineId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let index = machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found\"}")
        }
        if role != "owner", role != "admin", machines[index].userId != userId {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        machines.remove(at: index)
        for computerIndex in computers.indices where computers[computerIndex].machineId?.caseInsensitiveCompare(machineId) == .orderedSame {
            computers[computerIndex].machineId = nil
            computers[computerIndex].revokedAt = Date()
        }
        lock.unlock()
        emitRealtime("server:\(serverId)", "machine:updated", "{\"serverId\":\(jsonString(serverId)),\"machineId\":\(jsonString(machineId))}")
        return Self.json(200, "{\"ok\":true}")
    }

    private struct MachineRecord {
        var id: String
        var serverId: String
        var userId: String
        var name: String
        var description: String?
        var apiKey: String?
        var runtimes: [String] = []
    }

    public func computerLifecycleOperation(
        authorization: String?,
        serverId: String,
        machineId: String,
        body: String
    ) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let action = object["action"] as? String,
              ["start", "stop", "restart", "upgrade"].contains(action)
        else {
            return Self.json(400, "{\"error\":\"Unknown Computer lifecycle action\",\"code\":\"unknown_action\"}")
        }
        guard let operationId = object["operationId"] as? String, ServerScope.isUUID(operationId) else {
            return Self.json(400, "{\"error\":\"A valid operationId is required\",\"code\":\"invalid_operation_id\"}")
        }
        guard let parentOperationId = object["parentOperationId"] as? String, ServerScope.isUUID(parentOperationId) else {
            return Self.json(400, "{\"error\":\"A valid parentOperationId is required\",\"code\":\"invalid_parent_operation_id\"}")
        }
        let targetVersion = object["targetVersion"] as? String
        if action == "upgrade" {
            if let targetVersion, targetVersion.wholeMatch(of: /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/) == nil {
                return Self.json(400, "{\"error\":\"A valid targetVersion is required only for upgrade\",\"code\":\"invalid_target_version\"}")
            }
        } else if targetVersion != nil {
            return Self.json(400, "{\"error\":\"A valid targetVersion is required only for upgrade\",\"code\":\"invalid_target_version\"}")
        }
        if let completionMode = object["completionMode"] {
            guard action == "upgrade", completionMode as? String == "legacy_k_promoted" else {
                return Self.json(400, "{\"error\":\"Unknown Computer lifecycle completion mode\",\"code\":\"invalid_completion_mode\"}")
            }
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        guard let machine = machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Machine not found in this server\"}")
        }
        let computer = computers.first { $0.machineId == machineId && $0.serverId == serverId && $0.revokedAt == nil }
        let online = machineOnline[machineId] == true || computer?.online == true
        lock.unlock()
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            return Self.json(403, "{\"error\":\"The `controlComputers` capability or machine creator authority is required to control Computers\"}")
        }
        guard computer != nil else {
            return Self.json(409, "{\"error\":\"Lifecycle operations are only available for managed Computers\",\"code\":\"not_a_computer\"}")
        }
        if action == "start", online {
            return Self.json(409, "{\"error\":\"Computer is already online\",\"code\":\"computer_already_online\"}")
        }
        if action != "start", !online {
            return Self.json(409, "{\"error\":\"Computer is not online\",\"code\":\"computer_offline\"}")
        }
        if action == "upgrade", targetVersion == nil {
            return Self.json(409, "{\"error\":\"Hands could not select a newer alpha release for this Computer.\",\"code\":\"computer_upgrade_unavailable\"}")
        }
        if object["completionMode"] != nil {
            return Self.json(409, "{\"error\":\"The live Computer ready attestation is not visible yet.\",\"code\":\"computer_lifecycle_completion_ready_pending\"}")
        }
        let versionJSON = targetVersion.map(jsonString) ?? "null"
        return Self.json(201, "{\"operationId\":\(jsonString(operationId)),\"parentOperationId\":\(jsonString(parentOperationId)),\"serverId\":\(jsonString(serverId)),\"machineId\":\(jsonString(machineId)),\"actorUserId\":\(jsonString(userId)),\"action\":\(jsonString(action)),\"dispatchMode\":\"local\",\"connectionEpochBefore\":null,\"targetVersion\":\(versionJSON)}")
    }

    public func mentionDeliveryDiagnostic(
        authorization: String?,
        serverId: String,
        machineId: String,
        agentId: String,
        messageId: String
    ) -> HTTPReply {
        guard ServerScope.isUUID(messageId) else {
            return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              let agent = oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        lock.lock()
        let machineMatches = machines.contains { $0.id == machineId && $0.serverId == serverId }
        let assigned = agentMachineIds[agentId] == machineId
        lock.unlock()
        guard machineMatches, assigned else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
    }

    public func agentSessionTranscript(
        authorization: String?,
        serverId: String,
        machineId: String,
        agentId: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        let machineExists = machines.contains { $0.id == machineId && $0.serverId == serverId }
        let assignedMachine = agentMachineIds[agentId]
        let online = machineOnline[machineId] == true
        lock.unlock()
        guard machineExists else {
            return Self.json(404, "{\"error\":\"Machine not found in this server\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found in this server\"}")
        }
        guard assignedMachine == machineId else {
            return Self.json(400, "{\"error\":\"Agent is not assigned to this machine\"}")
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to view agent diagnostics\"}")
        }
        guard online else {
            return Self.json(409, "{\"error\":\"Computer is offline\",\"code\":\"machine_offline\"}")
        }
        return Self.json(200, "{\"sessionId\":null,\"transcript\":[]}")
    }

    public func redriveMentionDelivery(
        authorization: String?,
        serverId: String,
        machineId: String,
        agentId: String,
        messageId: String,
        body: String
    ) -> HTTPReply {
        guard ServerScope.isUUID(messageId) else {
            return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              let agent = oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        lock.lock()
        let machineMatches = machines.contains { $0.id == machineId && $0.serverId == serverId }
        let assigned = agentMachineIds[agentId] == machineId
        lock.unlock()
        guard machineMatches, assigned else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              object.count == 1,
              let version = object["expectedVersion"] as? NSNumber,
              version.doubleValue.rounded() == version.doubleValue,
              version.intValue >= 0
        else {
            return Self.json(400, "{\"status\":\"INVALID_REQUEST\"}")
        }
        return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
    }

    public func submitTranscriptFeedback(
        authorization: String?,
        serverId: String,
        agentId: String,
        reportId: String,
        body: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard reportId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
                return Self.json(400, "{\"error\":\"Invalid transcript request\"}")
            }
            if let raw = object["reportGeneratedAt"], !(raw is NSNull) {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                guard let text = raw as? String,
                      fractional.date(from: text) != nil || ISO8601DateFormatter().date(from: text) != nil
                else {
                    return Self.json(400, "{\"error\":\"reportGeneratedAt must be an ISO timestamp\"}")
                }
            }
        }
        return Self.json(202, "{\"accepted\":true,\"feedbackReportId\":\(jsonString(reportId)),\"agentId\":\(jsonString(agentId))}")
    }

    public func createShareArtifact(authorization: String?, serverId: String, body: String, baseURL: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Guests cannot create share artifacts\"}")
        }
        guard let channelId = Self.multipartField(body, name: "channelId"),
              let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId
        else {
            return Self.json(403, "{\"error\":\"Channel is outside the active server\"}")
        }
        let id = UUID().uuidString.lowercased()
        lock.lock()
        shareArtifacts.insert(id)
        lock.unlock()
        let root = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return Self.json(200, "{\"id\":\(jsonString(id)),\"url\":\(jsonString(root + "/share/" + id)),\"imageUrl\":\(jsonString(root + "/share/" + id + ".png"))}")
    }

    private static func multipartField(_ body: String, name: String) -> String? {
        guard let range = body.range(of: "name=\"\(name)\"") else { return nil }
        let rest = body[range.upperBound...]
        guard let separator = rest.range(of: "\r\n\r\n") else { return nil }
        let value = rest[separator.upperBound...]
        guard let end = value.range(of: "\r\n") else { return nil }
        return String(value[..<end.lowerBound])
    }

    public func shareArtifactPage(id: String, baseURL: String) -> HTTPReply? {
        guard id.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return nil
        }
        lock.lock()
        let exists = shareArtifacts.contains(id.lowercased())
        lock.unlock()
        guard exists else { return nil }
        let root = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let imageURL = root + "/share/" + id + ".png"
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="robots" content="noindex, nofollow">
        <meta name="twitter:card" content="summary_large_image">
        <meta name="twitter:image" content="\(imageURL)">
        <meta property="og:image:width" content="1">
        <meta property="og:image:height" content="1">
        <meta name="twitter:image:alt" content="Slock conversation screenshot">
        <style>.share-card { width: min(100%, 960px); margin-inline: auto; }</style></head>
        <body><div class="share-card"><img src="\(imageURL)" alt="Slock conversation screenshot"></div></body></html>
        """
        return HTTPReply(
            status: 200,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "X-Robots-Tag": "noindex, nofollow",
                "Content-Length": String(Data(html.utf8).count),
            ],
            body: html
        )
    }

    public func shareArtifactExists(id: String) -> Bool {
        guard id.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return shareArtifacts.contains(id.lowercased())
    }

    public static let sharePNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=") ?? Data()

    private func humanUnreadCount(channelId: String, userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let rows = humanMessageRows.filter { $0.channelId == channelId }
        let cursor = oauth.channelUnreadInfo(channelId: channelId, userId: userId).maxReadSeq
        return rows.enumerated().filter { index, row in
            index + 1 > cursor && row.senderId != userId
        }.count
    }

    public func serversUnreadSummary(authorization: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let entries = oauth.serverIdsForMember(userId: userId).map { serverId -> String in
            let joined = oauth.channelsForServer(serverId: serverId, userId: userId).filter {
                $0.joined && ($0.type == "channel" || $0.type == "")
            }
            let total = joined.reduce(0) { sum, channel in
                sum + oauth.channelUnreadInfo(channelId: channel.id, userId: userId).unreadCount + humanUnreadCount(channelId: channel.id, userId: userId)
            }
            let muted = oauth.isServerPushMuted(serverId: serverId, userId: userId)
            return "{\"serverId\":\(jsonString(serverId)),\"unreadCount\":\(total),\"serverPushMuted\":\(muted),\"activityUnreadCount\":\(total)}"
        }.joined(separator: ",")
        return Self.privateJSON("[\(entries)]")
    }

    public struct TimezoneObservation: Sendable {
        public var firstTimezone: String
        public var firstAt: Date
        public var lastTimezone: String
        public var lastAt: Date
    }

    public func observeTimezone(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              Set(object.keys) == ["timezone"],
              let raw = object["timezone"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid timezone observation\"}")
        }
        let timezone = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !timezone.isEmpty, timezone.count <= 128,
              timezone == "UTC" || timezone.contains("/"),
              TimeZone(identifier: timezone) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid timezone observation\"}")
        }
        lock.lock()
        var observation = timezoneObservations[userId]
        let now = Date()
        if observation == nil {
            observation = TimezoneObservation(firstTimezone: timezone, firstAt: now, lastTimezone: timezone, lastAt: now)
        } else if let existing = observation {
            observation = TimezoneObservation(
                firstTimezone: existing.firstTimezone,
                firstAt: existing.firstAt,
                lastTimezone: timezone,
                lastAt: now
            )
        }
        timezoneObservations[userId] = observation
        lock.unlock()
        guard let stored = observation else {
            return Self.json(500, "{\"error\":\"Timezone observation not stored\"}")
        }
        return Self.json(200, Self.timezoneJSON(stored))
    }

    public func timezoneObservation(userId: String) -> TimezoneObservation? {
        lock.lock()
        defer { lock.unlock() }
        return timezoneObservations[userId]
    }

    private static func timezoneJSON(_ observation: TimezoneObservation) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "{\"firstObservedTimezone\":\(jsonString(observation.firstTimezone)),\"firstObservedTimezoneAt\":\(jsonString(formatter.string(from: observation.firstAt))),\"lastObservedTimezone\":\(jsonString(observation.lastTimezone)),\"lastObservedTimezoneAt\":\(jsonString(formatter.string(from: observation.lastAt)))}"
    }

    public func authenticatedUserId(authorization: String?) -> String? {
        sessionUserId(authorization: authorization)
    }

    public func serverScopeAttestation(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let scope = object["scope"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid scope attestation request\"}")
        }
        let audience: String
        let resource: String
        switch scope {
        case "web-trace-batch:create":
            audience = "trace-ingest-worker"
            resource = "servers/\(serverId)/web-traces"
        case "feedback-report:create":
            guard role == "owner" || role == "admin" else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            audience = "feedback-worker"
            resource = "servers/\(serverId)/feedback-reports"
        default:
            return Self.json(400, "{\"error\":\"Unknown scope\"}")
        }
        let expiresAt = Date().addingTimeInterval(300)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header = ["alg": "HS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "scope": scope,
            "actorType": "user",
            "sub": userId,
            "serverId": serverId,
            "aud": audience,
            "resource": resource,
            "exp": Int(expiresAt.timeIntervalSince1970),
        ]
        let secret = ProcessInfo.processInfo.environment["SCOPE_ATTESTATION_SECRET"] ?? "scope-attestation-default-secret"
        let token = Self.signHS256(header: header, claims: claims, secret: secret)
        return Self.json(200, "{\"attestation\":\(jsonString(token)),\"scope\":\(jsonString(scope)),\"audience\":\(jsonString(audience)),\"resource\":\(jsonString(resource)),\"expiresAt\":\(jsonString(formatter.string(from: expiresAt)))}")
    }

    private static func signHS256(header: [String: Any], claims: [String: Any], secret: String) -> String {
        func base64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let headerJSON = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data("{}".utf8)
        let claimsJSON = (try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])) ?? Data("{}".utf8)
        let signingInput = "\(base64url(headerJSON)).\(base64url(claimsJSON))"
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: SymmetricKey(data: Data(secret.utf8))))
        return "\(signingInput).\(base64url(mac))"
    }

    public func putServerAgreement(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can manage the pre-join agreement\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["enabled"] as? Bool,
              let title = object["title"] as? String,
              let bodyMarkdown = object["bodyMarkdown"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid agreement request\"}")
        }
        guard bodyMarkdown.count <= 5000 else {
            return Self.json(400, "{\"error\":\"Agreement body must be 5000 characters or fewer\"}")
        }
        let agreement: OAuthLedger.ServerAgreementInfo?
        if enabled {
            agreement = oauth.putServerAgreement(serverId: serverId, title: title, bodyMarkdown: bodyMarkdown)
        } else {
            agreement = nil
        }
        let json: String
        if let agreement {
            json = Self.agreementJSON(agreement)
        } else {
            json = "null"
        }
        return Self.json(200, "{\"agreement\":\(json)}")
    }

    public func getServerAgreement(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if let agreement = oauth.activeServerAgreement(serverId: serverId) {
            return Self.json(200, "{\"agreement\":\(Self.agreementJSON(agreement))}")
        }
        return Self.json(200, "{\"agreement\":null}")
    }

    private static func agreementJSON(_ agreement: OAuthLedger.ServerAgreementInfo) -> String {
        "{\"id\":\(jsonString(agreement.id)),\"version\":\(agreement.version),\"title\":\(jsonString(agreement.title)),\"bodyMarkdown\":\(jsonString(agreement.bodyMarkdown)),\"enabled\":\(agreement.enabled)}"
    }

    private func sanitizedServerOrder(userId: String, requested: [String]?) -> [String] {
        let memberIds = Set(oauth.serverIdsForMember(userId: userId))
        let stored = serverSwitcherOrders[userId]?.ids ?? []
        let base = requested ?? stored
        var seen = Set<String>()
        var ordered: [String] = []
        for id in base where memberIds.contains(id) && !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        for id in memberIds.sorted() where !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    public func seedServerSwitcherOrder(userId: String, ids: [String], version: Int) {
        lock.lock()
        serverSwitcherOrders[userId] = (ids, version)
        lock.unlock()
    }

    public func activityContractRejection() -> HTTPReply {
        HTTPReply(
            status: 400,
            headers: [
                "Content-Type": AppFallback.jsonContentType,
                "X-Raft-Contract": "raft.activity-sync;revision=2",
                "Access-Control-Expose-Headers": "X-Raft-Contract",
                "Content-Length": "26",
            ],
            body: "{\"error\":\"invalid contract\"}"
        )
    }

    public func serverOrder(authorization: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        lock.lock()
        let ordered = sanitizedServerOrder(userId: userId, requested: nil)
        let version = serverSwitcherOrders[userId]?.version ?? 0
        lock.unlock()
        let ids = ordered.map { jsonString($0) }.joined(separator: ",")
        return Self.json(200, "{\"serverOrder\":[\("\(ids)")],\"serverOrderVersion\":\(version)}")
    }

    public func patchServerOrder(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let requested = object["serverOrder"] as? [String]
        else {
            return Self.json(400, "{\"error\":\"Invalid server order\"}")
        }
        lock.lock()
        let current = serverSwitcherOrders[userId]?.ids ?? sanitizedServerOrder(userId: userId, requested: nil)
        let ordered = sanitizedServerOrder(userId: userId, requested: requested)
        var version = serverSwitcherOrders[userId]?.version ?? 0
        if ordered != current {
            version += 1
        }
        serverSwitcherOrders[userId] = (ordered, version)
        lock.unlock()
        let ids = ordered.map { jsonString($0) }.joined(separator: ",")
        return Self.json(200, "{\"serverOrder\":[\("\(ids)")],\"serverOrderVersion\":\(version)}")
    }

    public func orderedServerList(authorization: String?) -> HTTPReply? {
        guard let userId = sessionUserId(authorization: authorization) else { return nil }
        let memberIds = oauth.serverIdsForMember(userId: userId)
        guard !memberIds.isEmpty else { return nil }
        let ordered = sanitizedServerOrder(userId: userId, requested: nil)
        lock.lock()
        let version = serverSwitcherOrders[userId]?.version ?? 0
        lock.unlock()
        let rows = ordered.compactMap { serverId -> String? in
            guard let details = oauth.serverDetailsValue(id: serverId) else { return nil }
            let role = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
            return "{\"id\":\(jsonString(serverId)),\"slug\":\(jsonString(details.slug)),\"role\":\(jsonString(role)),\"serverOrderVersion\":\(version),\"publicPageLive\":false}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func enableComposerResourceReferences(serverId: String, enabled: Bool = true) {
        lock.lock()
        if enabled {
            composerResourceServers.insert(serverId)
        } else {
            composerResourceServers.remove(serverId)
        }
        lock.unlock()
    }

    public func serverApps(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let enabled = composerResourceServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        let apps: [(String, String)] = [
            ("system.cleaner", "Memory Cleaner"),
            ("system.reminder", "Reminder"),
        ]
        let rows = apps.map { app in
            "{\"appId\":\(jsonString(app.0)),\"displayName\":\(jsonString(app.1))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"apps\":[\("\(rows)")]}")
    }

    private static func translationProviderAvailable() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        switch environment["TRANSLATION_PROVIDER"] ?? "" {
        case "fake":
            return true
        case "volcengine":
            let id = environment["TRANSLATION_VOLCENGINE_ACCESS_KEY_ID"] ?? ""
            let secret = environment["TRANSLATION_VOLCENGINE_SECRET_ACCESS_KEY"] ?? ""
            return !id.isEmpty && !secret.isEmpty
        case "google":
            let project = environment["TRANSLATION_GOOGLE_PROJECT_ID"] ?? ""
            let token = environment["TRANSLATION_GOOGLE_ACCESS_TOKEN"] ?? ""
            return !project.isEmpty && !token.isEmpty
        default:
            return false
        }
    }

    public func batchTranslateMessages(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard oauth.serverProfile(id: serverId)?.translationEnabled == true else {
            return Self.json(403, "{\"error\":\"Translation is disabled for this server\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let ids = (object?["messageIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        let results = ids.map { id -> String in
            guard let message = oauth.messageContent(id: id),
                  let channel = oauth.channelInfo(id: message.channelId),
                  channel.serverId == serverId,
                  oauth.channelType(id: message.channelId) == "channel"
                      || oauth.isChannelParticipant(channelId: message.channelId, userId: userId)
            else {
                return "{\"messageId\":\(jsonString(id)),\"status\":\"not_found\"}"
            }
            return "{\"messageId\":\(jsonString(id)),\"status\":\"translated\",\"translatedText\":\(jsonString(message.content))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"results\":[\("\(results)")]}")
    }

    public func serverTranslationSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let enabled = oauth.serverProfile(id: serverId)?.translationEnabled ?? false
        let canManage = role == "owner" || role == "admin"
        return Self.json(200, "{\"translationEnabled\":\(enabled),\"translationAvailable\":\(Self.translationProviderAvailable()),\"canManageTranslation\":\(canManage)}")
    }

    public func patchServerTranslationSettings(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can update translation settings\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["translationEnabled"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"translationEnabled must be a boolean\"}")
        }
        oauth.setServerTranslationEnabled(id: serverId, enabled: enabled)
        return Self.json(200, "{\"translationEnabled\":\(enabled),\"translationAvailable\":\(Self.translationProviderAvailable()),\"canManageTranslation\":true}")
    }

    public func patchServerProfile(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let profile = oauth.serverProfile(id: serverId)
        else {
            return Self.json(400, "{\"error\":\"Invalid server update\"}")
        }
        var name = profile.name
        if let rawName = object["name"] {
            guard let text = rawName as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.json(400, "{\"error\":\"Server name is required\"}")
            }
            name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var hidden: Bool?
        if let rawHidden = object["hideHumansFromMembers"] {
            guard let value = rawHidden as? Bool else {
                return Self.json(400, "{\"error\":\"hideHumansFromMembers must be a boolean\"}")
            }
            hidden = value
        }
        oauth.updateServer(id: serverId, name: name, avatarUrl: profile.avatarUrl)
        if let hidden {
            lock.lock()
            hideHumansFromMembers[serverId] = hidden
            lock.unlock()
        }
        let hiddenValue: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return hideHumansFromMembers[serverId] == true
        }()
        let avatar = profile.avatarUrl.map { jsonString($0) } ?? "null"
        return Self.json(200, "{\"id\":\(jsonString(serverId)),\"name\":\(jsonString(name)),\"slug\":\(jsonString(profile.slug)),\"avatarUrl\":\(avatar),\"hideHumansFromMembers\":\(hiddenValue)}")
    }

    public func memberProfile(authorization: String?, serverId: String, memberId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let targetRole = oauth.memberRole(serverId: serverId, userId: memberId)
        if targetRole == nil {
            lock.lock()
            let removed = removedServerMembers.contains("\(serverId)\n\(memberId)")
            let account = accounts.values.first { $0.id == memberId }
            lock.unlock()
            let canSee = role == "owner" || role == "admin" || memberId == userId
            guard removed, canSee, let account else {
                return Self.json(404, "{\"error\":\"User not found\"}")
            }
            let email = canSee ? jsonString(account.email) : "null"
            return Self.json(200, "{\"userId\":\(jsonString(memberId)),\"name\":\(jsonString(account.name)),\"displayName\":\(jsonString(account.name)),\"email\":\(email),\"avatarUrl\":\(account.avatarUrl.map { jsonString($0) } ?? "null"),\"membershipStatus\":\"removed\"}")
        }
        lock.lock()
        let hiddenDirectory = hideHumansFromMembers[serverId] == true
        let targetAccount = accounts.values.first { $0.id == memberId }
        lock.unlock()
        let isAdmin = role == "owner" || role == "admin"
        var contextual = false
        if hiddenDirectory, !isAdmin, memberId != userId {
            contextual = oauth.channelsForServer(serverId: serverId, userId: userId)
                .contains { channel in
                    channel.type == "channel"
                        && oauth.channelArchivedAt(id: channel.id) == nil
                        && oauth.isChannelParticipant(channelId: channel.id, userId: userId)
                        && oauth.isChannelParticipant(channelId: channel.id, userId: memberId)
                }
            guard contextual else {
                return Self.json(404, "{\"error\":\"User not found\"}")
            }
        }
        let email: String
        if isAdmin || memberId == userId {
            email = targetAccount.map { jsonString($0.email) } ?? "null"
        } else {
            email = "null"
        }
        let name = jsonString(targetAccount?.name ?? "")
        let avatar = targetAccount?.avatarUrl.map { jsonString($0) } ?? "null"
        return Self.json(200, "{\"userId\":\(jsonString(memberId)),\"name\":\(name),\"displayName\":\(name),\"email\":\(email),\"avatarUrl\":\(avatar)}")
    }

    public func serverMembersList(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let canSeeAllEmails = role == "owner" || role == "admin"
        lock.lock()
        let hiddenDirectory = hideHumansFromMembers[serverId] == true
        lock.unlock()
        var members = oauth.memberIdsWithRoles(serverId: serverId)
        if hiddenDirectory, role != "owner", role != "admin" {
            members = members.filter { $0.id == userId }
        }
        let rows = members.map { member -> String in
            lock.lock()
            let account = accounts.values.first { $0.id == member.id }
            lock.unlock()
            let email: String
            if canSeeAllEmails || member.id == userId {
                email = account.map { jsonString($0.email) } ?? "null"
            } else {
                email = "null"
            }
            let name = jsonString(account?.name ?? "")
            let displayName = jsonString(account?.name ?? "")
            let avatar = account?.avatarUrl.map { jsonString($0) } ?? "null"
            return "{\"userId\":\(jsonString(member.id)),\"role\":\(jsonString(member.role)),\"name\":\(name),\"displayName\":\(displayName),\"email\":\(email),\"avatarUrl\":\(avatar)}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func serverMemberGraph(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let hiddenDirectory = hideHumansFromMembers[serverId] == true
        lock.unlock()
        if hiddenDirectory, role != "owner", role != "admin" {
            return Self.json(403, "{\"error\":\"Member graph is not available\"}")
        }
        let memberIds = oauth.memberIds(serverId: serverId)
        let agentIds = oauth.activeAgentIds(serverId: serverId)
        let allChannelId = oauth.allChannelId(serverId: serverId)
        var channels: [(id: String, name: String, humans: [String], agents: [String])] = []
        if let allChannelId {
            channels.append((allChannelId, "all", memberIds, agentIds))
        }
        for channel in oauth.channelsForServer(serverId: serverId, userId: userId) {
            guard channel.type == "channel", channel.name != "all",
                  oauth.channelArchivedAt(id: channel.id) == nil
            else { continue }
            let humans = oauth.channelHumanIds(channelId: channel.id).filter { memberIds.contains($0) }
            let agents = oauth.channelAgentIds(channelId: channel.id).filter { agentIds.contains($0) }
            channels.append((channel.id, channel.name, humans, agents))
        }
        var edges: [String] = []
        var humanChannelIds: [String: [String]] = [:]
        var agentChannelIds: [String: [String]] = [:]
        var channelsJSON: [String] = []
        for channel in channels {
            for human in channel.humans {
                humanChannelIds[human, default: []].append(channel.id)
                edges.append("{\"channelId\":\(jsonString(channel.id)),\"memberType\":\"human\",\"memberId\":\(jsonString(human))}")
            }
            for agent in channel.agents {
                agentChannelIds[agent, default: []].append(channel.id)
                edges.append("{\"channelId\":\(jsonString(channel.id)),\"memberType\":\"agent\",\"memberId\":\(jsonString(agent))}")
            }
            channelsJSON.append("{\"id\":\(jsonString(channel.id)),\"name\":\(jsonString(channel.name)),\"memberCount\":\(channel.humans.count + channel.agents.count)}")
        }
        let humans = memberIds.map { memberId -> String in
            let ids = (humanChannelIds[memberId] ?? []).map { jsonString($0) }.joined(separator: ",")
            return "{\"id\":\(jsonString(memberId)),\"channelIds\":[\("\(ids)")]}"
        }
        let agents = agentIds.map { agentId -> String in
            let info = oauth.agentRuntimeInfo(id: agentId)
            let ids = (agentChannelIds[agentId] ?? []).map { jsonString($0) }.joined(separator: ",")
            return "{\"id\":\(jsonString(agentId)),\"name\":\(jsonString(info?.name ?? "")),\"channelIds\":[\("\(ids)")]}"
        }
        return Self.json(200, "{\"humans\":[\("\(humans.joined(separator: ","))")],\"agents\":[\("\(agents.joined(separator: ","))")],\"channels\":[\("\(channelsJSON.joined(separator: ","))")],\"edges\":[\("\(edges.joined(separator: ","))")]}")
    }

    public func uploadServerAvatar(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let key = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let avatarUrl = "/api/avatars/server-\(serverId)/\(key).webp"
        oauth.setServerAvatar(id: serverId, avatarUrl: avatarUrl)
        return Self.json(200, "{\"avatarUrl\":\(jsonString(avatarUrl))}")
    }

    public func agentSend(authorization: String?, agentId: String, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let machine = machines.first { $0.apiKey == apiKey }
        let legacy = machineKeys[apiKey]
        lock.unlock()
        guard let machineServerId = machine?.serverId ?? legacy?.serverId else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == machineServerId else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let target = object["target"] as? String,
              let content = object["content"] as? String,
              target.hasPrefix("#")
        else {
            return Self.json(400, "{\"error\":\"Invalid target\"}")
        }
        let rawName = String(target.dropFirst())
        let segments = rawName.split(separator: ":", maxSplits: 1).map(String.init)
        let name = segments.first ?? rawName
        let shortId = segments.count > 1 ? segments[1] : nil
        lock.lock()
        let candidate = postableChannels.first { channelId, channel in
            channel.serverId == agent.serverId && channel.name == name && channel.deletedAt == nil
        }
        var resolved: (String, PostableChannel)? = candidate
        if let shortId, let (parentId, parent) = candidate {
            guard oauth.channelAgentIds(channelId: parentId).contains(agent.id) else {
                lock.unlock()
                return Self.json(403, "{\"error\":\"Agent is not a member of the parent channel\"}")
            }
            resolved = postableChannels.first { _, channel in
                channel.serverId == agent.serverId
                    && channel.kind == "thread"
                    && channel.parentChannelId == parentId
                    && (channel.parentMessageId?.hasPrefix(shortId) ?? false)
                    && channel.deletedAt == nil
            }
            if resolved == nil {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Thread not found\"}")
            }
        }
        lock.unlock()
        guard let (channelId, channel) = resolved else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if shortId == nil, !oauth.channelAgentIds(channelId: channelId).contains(agent.id) {
            return Self.json(403, "{\"error\":\"Agent is not a member of this channel\"}")
        }
        if channel.archived {
            return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
        }
        let messageId = UUID().uuidString.lowercased()
        lock.lock()
        humanMessageRows.append(StoredHumanMessage(
            id: messageId,
            channelId: channelId,
            senderId: agent.id,
            content: content,
            randomId: nil,
            senderType: "agent"
        ))
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(messageId)),\"channelId\":\(jsonString(channelId))}")
    }

    public func runtimeProfileMigrationDone(authorization: String?, agentId: String, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        guard let machine = machines.first(where: { $0.apiKey == apiKey }) else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        lock.unlock()
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == machine.serverId else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let migrationKey = (object?["migrationKey"] as? String) ?? ""
        let message = "Runtime Profile migration acknowledgments are deprecated; runtime changes reset the session automatically."
        if migrationKey.isEmpty {
            return Self.json(200, "{\"ok\":true,\"deprecated\":true,\"noop\":\"no pending migration\",\"message\":\(jsonString(message))}")
        }
        return Self.json(200, "{\"ok\":true,\"deprecated\":true,\"message\":\(jsonString(message))}")
    }

    public func markAgentHosted(agentId: String) {
        lock.lock()
        hostedAgents.insert(agentId)
        lock.unlock()
    }

    public func updateAgentProfile(authorization: String?, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid profile update\"}")
        }
        lock.lock()
        let hosted = hostedAgents.contains(agent.id)
        lock.unlock()
        if hosted, object["description"] != nil {
            return Self.json(403, "{\"error\":\"Hosted agents cannot change their own description\",\"code\":\"hosted_agent_description_human_only\",\"suggestedNextAction\":\"Ask a human owner or admin to edit it in your Profile tab in Raft. Nothing was changed.\"}")
        }
        if let description = object["description"] as? String {
            oauth.updateAgentDescription(id: agent.id, description: description)
        }
        if let displayName = object["displayName"] as? String,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            oauth.updateAgentDisplayName(id: agent.id, displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Self.json(200, "{\"ok\":true}")
    }

    public func setServerSeats(serverId: String, seats: Int) {
        lock.lock()
        proSeats[serverId] = seats
        lock.unlock()
    }

    private func seatLimitMessageLocked(serverId: String) -> String? {
        guard let seats = proSeats[serverId] else { return nil }
        let used = oauth.memberIdsWithRoles(serverId: serverId).filter { $0.role != "guest" }.count
        guard used >= seats else { return nil }
        return "Seat limit reached (\(used)/\(seats) on Pro plan)"
    }

    public func createJoinLink(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can create join links\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can create join links\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        var expiresAt: Date?
        if let raw = object["expiresAt"] as? String, !raw.isEmpty {
            guard let parsed = Self.isoDate(raw) else {
                return Self.json(400, "{\"error\":\"expiresAt must be a valid date\"}")
            }
            expiresAt = parsed
        }
        var maxUses: Int?
        if let raw = object["maxUses"], !(raw is NSNull) {
            if let string = raw as? String, string.isEmpty {
                maxUses = nil
            } else if let number = raw as? NSNumber, number.doubleValue.rounded() == number.doubleValue,
                      number.intValue >= 1 {
                maxUses = number.intValue
            } else {
                return Self.json(400, "{\"error\":\"maxUses must be a positive integer\"}")
            }
        }
        let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let link = JoinLinkRecord(
            id: UUID().uuidString.lowercased(),
            token: token,
            serverId: serverId,
            role: "member",
            createdAt: Date(),
            expiresAt: expiresAt,
            maxUses: maxUses,
            useCount: 0,
            revokedAt: nil
        )
        lock.lock()
        joinLinks[token] = link
        lock.unlock()
        let expiresJSON = expiresAt.map { jsonString(Self.isoString($0)) } ?? "null"
        let maxUsesJSON = maxUses.map(String.init) ?? "null"
        return Self.json(200, "{\"token\":\(jsonString(token)),\"link\":\(joinLinkJSON(link)),\"maxUses\":\(maxUsesJSON),\"expiresAt\":\(expiresJSON)}")
    }

    public func listJoinLinks(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can view join links\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can view join links\"}")
        }
        lock.lock()
        let now = Date()
        let links = joinLinks.values
            .filter { $0.serverId == serverId && $0.revokedAt == nil }
            .filter { !Self.joinLinkExpired($0, now: now) && !Self.joinLinkExhausted($0) }
            .sorted { $0.createdAt > $1.createdAt }
            .map(joinLinkJSON)
            .joined(separator: ",")
        lock.unlock()
        return Self.json(200, "[\(links)]")
    }

    public func revokeJoinLink(authorization: String?, serverId: String, linkId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can revoke join links\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can revoke join links\"}")
        }
        lock.lock()
        if let key = joinLinks.first(where: { $0.value.id == linkId && $0.value.serverId == serverId })?.key {
            joinLinks[key]?.revokedAt = Date()
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func inviteInfo(token: String?) -> HTTPReply {
        guard let token, let link = joinLinks[token.lowercased()] else {
            return Self.json(404, "{\"error\":\"Invite not found\"}")
        }
        guard link.revokedAt == nil, !Self.joinLinkExpired(link, now: Date()), !Self.joinLinkExhausted(link) else {
            return Self.json(404, "{\"error\":\"Invite not found\"}")
        }
        guard let profile = oauth.serverProfile(id: link.serverId) else {
            return Self.json(404, "{\"error\":\"Invite not found\"}")
        }
        lock.lock()
        let message = seatLimitMessageLocked(serverId: link.serverId)
        lock.unlock()
        let messageJSON = message.map { jsonString($0) } ?? "null"
        return Self.json(200, "{\"serverId\":\(jsonString(profile.id)),\"serverName\":\(jsonString(profile.name)),\"serverSlug\":\(jsonString(profile.slug)),\"humanSeatLimitReached\":\(message != nil),\"humanSeatLimitMessage\":\(messageJSON)}")
    }

    public func acceptInvite(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawToken = object["token"] as? String,
              let existing = joinLinks[rawToken.lowercased()],
              existing.revokedAt == nil,
              !Self.joinLinkExpired(existing, now: Date()),
              !Self.joinLinkExhausted(existing)
        else {
            return Self.json(400, "{\"error\":\"Invalid invite\"}")
        }
        lock.lock()
        let message = seatLimitMessageLocked(serverId: existing.serverId)
        if let message {
            lock.unlock()
            return Self.json(400, "{\"error\":\(jsonString(message))}")
        }
        let oldCount = joinLinks[rawToken.lowercased()]?.useCount ?? 0
        joinLinks[rawToken.lowercased()]?.useCount = oldCount + 1
        lock.unlock()
        oauth.addMember(serverId: existing.serverId, userId: userId, role: existing.role)
        return Self.json(200, "{\"ok\":true,\"serverId\":\(jsonString(existing.serverId))}")
    }

    private func joinLinkJSON(_ link: JoinLinkRecord) -> String {
        let expiresAt = link.expiresAt.map { jsonString(Self.isoString($0)) } ?? "null"
        let revokedAt = link.revokedAt.map { jsonString(Self.isoString($0)) } ?? "null"
        let maxUses = link.maxUses.map(String.init) ?? "null"
        return "{\"id\":\(jsonString(link.id)),\"token\":\(jsonString(link.token)),\"createdAt\":\(jsonString(Self.isoString(link.createdAt))),\"expiresAt\":\(expiresAt),\"maxUses\":\(maxUses),\"useCount\":\(link.useCount),\"revokedAt\":\(revokedAt)}"
    }

    private static func joinLinkExpired(_ link: JoinLinkRecord, now: Date) -> Bool {
        if let expiresAt = link.expiresAt, expiresAt <= now { return true }
        return false
    }

    private static func joinLinkExhausted(_ link: JoinLinkRecord) -> Bool {
        if let maxUses = link.maxUses, link.useCount >= maxUses { return true }
        return false
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public func listServerInvites(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let rows = serverInvites.filter { $0.serverId == serverId }.map { invite in
            "{\"id\":\(jsonString(invite.id)),\"invitedEmail\":\(jsonString(invite.email)),\"email\":\(jsonString(invite.email)),\"role\":\(jsonString(invite.role)),\"status\":\"pending\"}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "[\(rows)]")
    }

    public func revokeServerInvite(authorization: String?, serverId: String, inviteId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can revoke invites\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can revoke invites\"}")
        }
        lock.lock()
        serverInvites.removeAll { $0.id == inviteId && $0.serverId == serverId }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func createServerInvite(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawEmail = object["email"] as? String
        else {
            return Self.json(400, "{\"error\":\"Enter a valid email address\"}")
        }
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.wholeMatch(of: /^[^\s@]+@[^\s@]+\.[^\s@]+$/) != nil else {
            return Self.json(400, "{\"error\":\"Enter a valid email address\"}")
        }
        let inviteRole = (object["role"] as? String) ?? "member"
        guard ["member", "guest"].contains(inviteRole) else {
            return Self.json(400, "{\"error\":\"role must be one of: member, guest\"}")
        }
        if inviteRole == "guest" {
            lock.lock()
            let enabled = guestRoleServers.contains(serverId)
            lock.unlock()
            guard enabled else {
                return Self.json(400, "{\"error\":\"Guest access is not enabled for this server\"}")
            }
        }
        if inviteRole == "member" {
            lock.lock()
            let message = seatLimitMessageLocked(serverId: serverId)
            lock.unlock()
            if let message {
                return Self.json(400, "{\"error\":\(jsonString(message))}")
            }
        }
        let id = UUID().uuidString.lowercased()
        lock.lock()
        serverInvites.append((id: id, serverId: serverId, email: email, role: inviteRole))
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(id)),\"invitedEmail\":\(jsonString(email)),\"email\":\(jsonString(email)),\"role\":\(jsonString(inviteRole)),\"invite\":{\"id\":\(jsonString(id)),\"email\":\(jsonString(email)),\"role\":\(jsonString(inviteRole)),\"status\":\"pending\"}}")
    }

    public func leaveServer(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if role == "owner", oauth.ownerCount(serverId: serverId) <= 1 {
            return Self.json(400, "{\"error\":\"The owner cannot leave the server\"}")
        }
        oauth.removeMember(serverId: serverId, userId: userId)
        lock.lock()
        removedServerMembers.insert("\(serverId)\n\(userId)")
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    private func setupProjectionJSON(serverId: String, userId: String, role: String) -> String {
        lock.lock()
        let phase = setupPhases["\(serverId)\n\(userId)"] ?? "not_started"
        lock.unlock()
        if role == "owner" || role == "admin" {
            let currentStep = phase == "in_progress" ? "computer_runtime" : "computer_runtime"
            return "{\"surface\":\"computer_runtime\",\"phase\":\(jsonString(phase)),\"currentStep\":\(jsonString(currentStep)),\"blocksChat\":true,\"allowedExits\":[\"reset\",\"return_to_server\"],\"sideEffectState\":{\"transitions\":\"enabled\",\"completion\":\"disabled\"},\"gateReason\":\"computer_offline\",\"computerStatus\":\"offline\",\"runtimeStatus\":\"unknown\",\"runtimeOptions\":[],\"hasConnectedComputer\":false,\"offlineComputers\":[],\"postSetup\":{\"surveyPending\":false,\"handoffPending\":false}}"
        }
        return "{\"surface\":\"none\",\"phase\":null,\"currentStep\":null,\"blocksChat\":false,\"allowedExits\":[\"return_to_server\"],\"sideEffectState\":{\"transitions\":\"disabled\",\"completion\":\"disabled\"},\"gateReason\":\"insufficient_permission\",\"computerStatus\":\"unknown\",\"runtimeStatus\":\"unknown\",\"runtimeOptions\":[],\"hasConnectedComputer\":false,\"offlineComputers\":[],\"postSetup\":{\"surveyPending\":false,\"handoffPending\":false}}"
    }

    public func slackBridgeUnavailable() -> HTTPReply {
        Self.json(503, "{\"ok\":false,\"code\":\"slack_bridge_provider_unavailable\"}")
    }

    public func serverSetupProjection(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        return Self.json(200, setupProjectionJSON(serverId: serverId, userId: userId, role: role))
    }

    public func serverSetupTransition(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let action = object["action"] as? String,
              action == "start" || action == "reset" || action == "return_to_server"
        else {
            return Self.json(400, "{\"error\":\"INVALID_SETUP_ACTION\"}")
        }
        lock.lock()
        let key = "\(serverId)\n\(userId)"
        if action == "start" {
            setupPhases[key] = "in_progress"
        } else if action == "reset" {
            setupPhases[key] = "not_started"
        }
        lock.unlock()
        return Self.json(200, setupProjectionJSON(serverId: serverId, userId: userId, role: role))
    }

    public func serverSetupReset(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
        }
        guard role == "owner" else {
            return Self.json(403, "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
        }
        lock.lock()
        let hasAgent = serverAgents.values.contains { $0.serverId == serverId }
        if hasAgent {
            lock.unlock()
            return Self.json(409, "{\"error\":\"SERVER_ALREADY_SET_UP\"}")
        }
        var revokedComputers = 0
        for index in computers.indices where computers[index].serverId == serverId && computers[index].revokedAt == nil {
            computers[index].revokedAt = Date()
            if computers[index].machineId != nil { revokedComputers += 1 }
        }
        setupPhases = setupPhases.filter { !$0.key.hasPrefix("\(serverId)\n") }
        setupHandoffs.remove(serverId)
        lock.unlock()
        var projection = setupProjectionJSON(serverId: serverId, userId: userId, role: role)
        projection.removeLast()
        projection += ",\"revokedComputers\":\(revokedComputers)}"
        return Self.json(200, projection)
    }

    public func serverSetupHandoff(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.serverProfile(id: serverId) != nil else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" else {
            return Self.json(403, "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
        }
        lock.lock()
        setupHandoffs.insert(serverId)
        lock.unlock()
        return Self.json(200, setupProjectionJSON(serverId: serverId, userId: userId, role: "owner"))
    }

    public func enableGuestRoleTransitions(serverId: String) {
        lock.lock()
        guestRoleServers.insert(serverId)
        lock.unlock()
    }

    public func patchServerMemberRole(authorization: String?, serverId: String, memberId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only the owner can change member roles\"}")
        }
        guard let targetRole = oauth.memberRole(serverId: serverId, userId: memberId) else {
            return Self.json(404, "{\"error\":\"Member not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let newRole = object["role"] as? String,
              ["owner", "admin", "member", "guest"].contains(newRole)
        else {
            return Self.json(400, "{\"error\":\"Invalid member role\"}")
        }
        if role == "admin", targetRole == "owner" || targetRole == "admin" || newRole == "owner" {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        if memberId == userId {
            let canSelfDemoteToGuest = targetRole == "owner" && newRole == "guest" && oauth.ownerCount(serverId: serverId) > 1
            guard canSelfDemoteToGuest else {
                return Self.json(400, "{\"error\":\"You cannot change your own role\"}")
            }
        }
        if newRole == "guest" {
            lock.lock()
            let enabled = guestRoleServers.contains(serverId)
            lock.unlock()
            guard enabled else {
                return Self.json(403, "{\"error\":\"Guest role transitions are not enabled\"}")
            }
        }
        if targetRole == "guest", newRole == "member" {
            lock.lock()
            let message = seatLimitMessageLocked(serverId: serverId)
            lock.unlock()
            if let message {
                return Self.json(409, "{\"error\":\(jsonString(message)),\"code\":\"human_seat_limit_reached\"}")
            }
        }
        oauth.addMember(serverId: serverId, userId: memberId, role: newRole)
        if newRole == "guest", let allChannel = oauth.allChannelId(serverId: serverId) {
            oauth.removeChannelHuman(channelId: allChannel, userId: memberId)
        }
        if newRole != targetRole {
            let payload = "{\"serverId\":\(jsonString(serverId)),\"userId\":\(jsonString(memberId)),\"previousRole\":\(jsonString(targetRole)),\"role\":\(jsonString(newRole))}"
            emitRealtime("server:\(serverId)", "server:member-updated", payload)
        }
        return Self.json(200, "{\"ok\":true,\"changed\":true}")
    }

    public func removeServerMember(authorization: String?, serverId: String, memberId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let targetRole = oauth.memberRole(serverId: serverId, userId: memberId) else {
            return Self.json(404, "{\"error\":\"Member not found\"}")
        }
        if targetRole == "owner" {
            guard role == "owner" else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            guard oauth.ownerCount(serverId: serverId) > 1 else {
                return Self.json(400, "{\"error\":\"The last owner cannot be removed\"}")
            }
        }
        oauth.removeMember(serverId: serverId, userId: memberId)
        lock.lock()
        removedServerMembers.insert("\(serverId)\n\(memberId)")
        lock.unlock()
        emitRealtime("server:\(serverId)", "server:member-removed", "{\"serverId\":\(jsonString(serverId)),\"userId\":\(jsonString(memberId))}")
        emitRealtime("user:\(memberId)", "server:membership-removed", "{\"serverId\":\(jsonString(serverId))}")
        return Self.json(200, "{\"ok\":true}")
    }

    public func deleteServerRoute(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        oauth.deleteServer(id: serverId)
        return Self.json(200, "{\"ok\":true}")
    }

    private enum SidebarPinnedChannelResolution {
        case missing
        case channel((kind: String, id: String))
        case dm((kind: String, id: String), legacyId: String)
    }

    private func sidebarHumanDMChannelId(peerId: String, userId: String, serverId: String) -> String? {
        oauth.channelsForServer(serverId: serverId, userId: userId, includeArchived: true)
            .first {
                $0.type == "dm"
                    && oauth.channelHumanIds(channelId: $0.id).contains(userId)
                    && oauth.channelHumanIds(channelId: $0.id).contains(peerId)
                    && oauth.channelAgentIds(channelId: $0.id).isEmpty
            }?.id
    }

    private func sidebarPinnedChannel(
        id: String,
        serverId: String,
        userId: String
    ) -> SidebarPinnedChannelResolution {
        guard let channel = oauth.channelInfo(id: id), channel.serverId == serverId else {
            return .missing
        }
        let type = oauth.channelType(id: id) ?? "channel"
        if type == "dm" {
            let agents = oauth.channelAgentIds(channelId: id)
            if agents.count == 1 {
                return .dm(("agent", agents[0]), legacyId: id)
            }
            let humans = oauth.channelHumanIds(channelId: id).filter { $0 != userId }
            if let peer = humans.first {
                return .dm(("human", peer), legacyId: id)
            }
            return .missing
        }
        if type == "private" && !oauth.channelHumanIds(channelId: id).contains(userId) {
            return .missing
        }
        return .channel(("channel", id))
    }

    public func patchSidebarOrder(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid sidebar order\"}")
        }
        let key = "\(serverId)\n\(userId)"
        lock.lock()
        var modes = sidebarModes[key] ?? ("manual", "manual", "manual", "manual", ["chat"], ["activity", "profile"])
        lock.unlock()
        func mode(_ field: String, _ current: String) -> String? {
            guard let raw = object[field] else { return current }
            guard let value = raw as? String, ["manual", "recent", "az"].contains(value) else { return nil }
            return value
        }
        guard let channel = mode("channelSortMode", modes.channel),
              let joint = mode("jointChannelSortMode", modes.joint),
              let dm = mode("dmSortMode", modes.dm),
              let pinned = mode("pinnedSortMode", modes.pinned)
        else {
            return Self.json(400, "{\"error\":\"Invalid sidebar sort mode\"}")
        }
        func tabs(_ field: String, _ current: [String], allowed: Set<String>) -> [String]? {
            guard let raw = object[field] else { return current }
            guard let values = raw as? [String] else { return nil }
            return values.filter { allowed.contains($0) }
        }
        guard let channelTabs = tabs("channelPanelTabOrder", modes.channelTabs, allowed: ["files", "tasks", "chat"]),
              let agentTabs = tabs("agentPanelTabOrder", modes.agentTabs, allowed: ["activity", "integrations", "profile"])
        else {
            return Self.json(400, "{\"error\":\"Invalid sidebar panel order\"}")
        }
        lock.lock()
        var sections = sidebarSections[key] ?? ([], ["system:pinned", "system:joint", "system:channels", "system:dms"], [], 0)
        lock.unlock()
        let hasSectionFields = object["customSections"] != nil || object["sectionOrder"] != nil || object["sectionPlacements"] != nil
        if hasSectionFields {
            if let rawVersion = object["sectionsVersion"] {
                guard let version = rawVersion as? Int, version == sections.version else {
                    return Self.json(409, "{\"error\":\"Sidebar sections changed\",\"code\":\"SIDEBAR_SECTIONS_VERSION_CONFLICT\"}")
                }
            }
            if let rawSections = object["customSections"] {
                guard let entries = rawSections as? [[String: Any]] else {
                    return Self.json(400, "{\"error\":\"Invalid custom sections\"}")
                }
                var parsed: [(id: String, name: String, emoji: String?, sortMode: String)] = []
                for entry in entries {
                    guard let id = entry["id"] as? String, !id.isEmpty,
                          let name = entry["name"] as? String
                    else { return Self.json(400, "{\"error\":\"Invalid custom sections\"}") }
                    let emoji: String?
                    if let raw = entry["emoji"], !(raw is NSNull) {
                        guard let value = raw as? String else { return Self.json(400, "{\"error\":\"Invalid custom sections\"}") }
                        emoji = value
                    } else {
                        emoji = nil
                    }
                    let sortMode = (entry["sortMode"] as? String) ?? "manual"
                    guard ["manual", "recent", "az"].contains(sortMode) else {
                        return Self.json(400, "{\"error\":\"Invalid custom sections\"}")
                    }
                    parsed.append((id, name.trimmingCharacters(in: .whitespacesAndNewlines), emoji, sortMode))
                }
                sections.sections = parsed
            }
            if let rawOrder = object["sectionOrder"] {
                guard let requested = rawOrder as? [String] else {
                    return Self.json(400, "{\"error\":\"Invalid section order\"}")
                }
                var order = requested
                for system in ["system:pinned", "system:joint", "system:channels", "system:dms"] where !order.contains(system) {
                    order.append(system)
                }
                sections.order = order
            }
            if let rawPlacements = object["sectionPlacements"] {
                guard let entries = rawPlacements as? [[String: Any]] else {
                    return Self.json(400, "{\"error\":\"Invalid section placements\"}")
                }
                var placements: [(kind: String, id: String, sectionId: String, position: Int)] = []
                for entry in entries {
                    guard let kind = entry["kind"] as? String, ["channel", "agent"].contains(kind),
                          let id = entry["id"] as? String,
                          let sectionId = entry["sectionId"] as? String
                    else { return Self.json(400, "{\"error\":\"Invalid section placements\"}") }
                    if kind == "channel" {
                        lock.lock()
                        let exists = postableChannels[id]?.deletedAt == nil && postableChannels[id] != nil
                        lock.unlock()
                        guard exists else { continue }
                    }
                    placements.append((kind, id, sectionId, placements.count))
                }
                sections.placements = placements
            }
            sections.version += 1
        }
        lock.lock()
        var pinnedState = sidebarPinnedRefs[key] ?? ([], [], [], 0)
        lock.unlock()
        var pinnedChanged = false
        if let rawPinned = object["pinned"] {
            guard object["pinnedChannelIds"] == nil else {
                return Self.json(400, "{\"error\":\"Invalid sidebar pinned references\"}")
            }
            guard let entries = rawPinned as? [[String: Any]] else {
                return Self.json(400, "{\"error\":\"Invalid sidebar pinned references\"}")
            }
            var refs: [(kind: String, id: String)] = []
            var channelIds: [String] = []
            var agentIds: [String] = []
            for entry in entries {
                guard let kind = entry["kind"] as? String,
                      ["channel", "agent", "human"].contains(kind),
                      let id = entry["id"] as? String,
                      !id.isEmpty
                else {
                    return Self.json(400, "{\"error\":\"Invalid sidebar pinned references\"}")
                }
                if kind == "channel" {
                    switch sidebarPinnedChannel(id: id, serverId: serverId, userId: userId) {
                    case .missing:
                        continue
                    case .channel(let canonical):
                        refs.append(canonical)
                        channelIds.append(id)
                    case .dm(let canonical, let legacyId):
                        refs.append(canonical)
                        channelIds.append(legacyId)
                    }
                } else if kind == "agent" {
                    guard let agent = oauth.agentRuntimeInfo(id: id), agent.serverId == serverId else { continue }
                    refs.append(("agent", id))
                    agentIds.append(id)
                } else {
                    lock.lock()
                    let exists = accounts.values.contains { $0.id == id }
                    lock.unlock()
                    guard exists else { continue }
                    refs.append(("human", id))
                    if let dm = sidebarHumanDMChannelId(peerId: id, userId: userId, serverId: serverId) {
                        channelIds.append(dm)
                    }
                }
            }
            var seen = Set<String>()
            refs = refs.filter { seen.insert("\($0.kind)\n\($0.id)").inserted }
            var channelSeen = Set<String>()
            channelIds = channelIds.filter { channelSeen.insert($0).inserted }
            var agentSeen = Set<String>()
            agentIds = agentIds.filter { agentSeen.insert($0).inserted }
            pinnedChanged = refs.map { "\($0.kind)\n\($0.id)" } != pinnedState.refs.map { "\($0.kind)\n\($0.id)" }
            if pinnedChanged {
                pinnedState = (refs, channelIds, agentIds, pinnedState.version + 1)
            }
        } else if object["pinnedChannelIds"] != nil || object["pinnedAgentIds"] != nil || object["pinnedOrder"] != nil {
            func stringArray(_ field: String) -> [String]? {
                guard let raw = object[field] else { return [] }
                return raw as? [String]
            }
            guard let requestedChannels = stringArray("pinnedChannelIds"),
                  let requestedAgents = stringArray("pinnedAgentIds"),
                  let requestedOrder = object["pinnedOrder"] == nil ? nil : stringArray("pinnedOrder")
            else {
                return Self.json(400, "{\"error\":\"Invalid sidebar pinned references\"}")
            }
            var refs = pinnedState.refs.filter { $0.kind == "human" }
            var channelIds: [String] = []
            var agentIds: [String] = []
            let channelSource = requestedChannels.isEmpty && object["pinnedChannelIds"] == nil
                ? (requestedOrder ?? []).filter { oauth.channelInfo(id: $0) != nil }
                : requestedChannels
            for id in channelSource {
                switch sidebarPinnedChannel(id: id, serverId: serverId, userId: userId) {
                case .missing:
                    continue
                case .channel(let canonical):
                    refs.append(canonical)
                    channelIds.append(id)
                case .dm(let canonical, let legacyId):
                    refs.append(canonical)
                    channelIds.append(legacyId)
                }
            }
            let agentSource = requestedAgents.isEmpty && object["pinnedAgentIds"] == nil
                ? (requestedOrder ?? []).filter { oauth.agentRuntimeInfo(id: $0)?.serverId == serverId }
                : requestedAgents
            for id in agentSource {
                guard let agent = oauth.agentRuntimeInfo(id: id), agent.serverId == serverId else { continue }
                refs.append(("agent", id))
                agentIds.append(id)
            }
            var seen = Set<String>()
            refs = refs.filter { seen.insert("\($0.kind)\n\($0.id)").inserted }
            var channelSeen = Set<String>()
            channelIds = channelIds.filter { channelSeen.insert($0).inserted }
            var agentSeen = Set<String>()
            agentIds = agentIds.filter { agentSeen.insert($0).inserted }
            pinnedChanged = refs.map { "\($0.kind)\n\($0.id)" } != pinnedState.refs.map { "\($0.kind)\n\($0.id)" }
            if pinnedChanged {
                pinnedState = (refs, channelIds, agentIds, pinnedState.version + 1)
            }
        }
        lock.lock()
        if pinnedChanged { sidebarPinnedRefs[key] = pinnedState }
        sidebarModes[key] = (channel, joint, dm, pinned, channelTabs, agentTabs)
        if hasSectionFields { sidebarSections[key] = sections }
        lock.unlock()
        if pinnedChanged {
            let refsJSON = pinnedState.refs.map { "{\"kind\":\(jsonString($0.kind)),\"id\":\(jsonString($0.id))}" }.joined(separator: ",")
            emitRealtime("user:\(userId)", "pinned:updated", "{\"pinned\":[\(refsJSON)],\"pinnedVersion\":\(pinnedState.version)}")
        }
        return sidebarOrder(authorization: authorization, serverId: serverId)
    }

    public func sidebarOrder(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let order = oauth.sanitizedSidebarOrder(serverId: serverId, userId: userId)
        lock.lock()
        let visibleChannelOrder = order.channelOrder.filter { postableChannels[$0]?.deletedAt == nil }
        lock.unlock()
        func array(_ values: [String]) -> String {
            values.map { jsonString($0) }.joined(separator: ",")
        }
        lock.lock()
        let modes = sidebarModes["\(serverId)\n\(userId)"] ?? ("manual", "manual", "manual", "manual", ["chat"], ["activity", "profile"])
        let sections = sidebarSections["\(serverId)\n\(userId)"] ?? ([], [], [], 0)
        let storedPinned = sidebarPinnedRefs["\(serverId)\n\(userId)"]
        lock.unlock()
        let pinnedState: (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int)
        if let storedPinned {
            pinnedState = storedPinned
        } else {
            var refs: [(kind: String, id: String)] = []
            var channelIds: [String] = []
            var agentIds: [String] = []
            for id in order.pinnedOrder {
                if oauth.agentRuntimeInfo(id: id)?.serverId == serverId {
                    refs.append(("agent", id))
                    agentIds.append(id)
                } else if oauth.channelInfo(id: id)?.serverId == serverId {
                    refs.append(("channel", id))
                    channelIds.append(id)
                } else {
                    refs.append(("human", id))
                }
            }
            pinnedState = (refs, channelIds, agentIds, 0)
        }
        let pinnedJSON = pinnedState.refs.map {
            "{\"kind\":\(jsonString($0.kind)),\"id\":\(jsonString($0.id))}"
        }.joined(separator: ",")
        let legacyPinnedOrder = storedPinned == nil ? order.pinnedOrder : (pinnedState.channelIds + pinnedState.agentIds)
        let sectionJSON = sections.sections.map { section -> String in
            "{\"id\":\(jsonString(section.id)),\"name\":\(jsonString(section.name)),\"emoji\":\(section.emoji.map { jsonString($0) } ?? "null"),\"sortMode\":\(jsonString(section.sortMode))}"
        }.joined(separator: ",")
        let placementJSON = sections.placements.map { placement in
            "{\"kind\":\(jsonString(placement.kind)),\"id\":\(jsonString(placement.id)),\"sectionId\":\(jsonString(placement.sectionId)),\"position\":\(placement.position)}"
        }.joined(separator: ",")
        return Self.json(200, "{\"channelOrder\":[\("\(array(visibleChannelOrder))")],\"agentOrder\":[\("\(array(order.agentOrder))")],\"dmOrder\":[\("\(array(order.dmOrder))")],\"pinned\":[\(pinnedJSON)],\"pinnedChannelIds\":[\("\(array(pinnedState.channelIds))")],\"pinnedAgentIds\":[\("\(array(pinnedState.agentIds))")],\"pinnedOrder\":[\("\(array(legacyPinnedOrder))")],\"pinnedVersion\":\(pinnedState.version),\"hiddenDmIds\":[\("\(array(order.hiddenDmIds))")],\"channelSortMode\":\(jsonString(modes.channel)),\"jointChannelSortMode\":\(jsonString(modes.joint)),\"dmSortMode\":\(jsonString(modes.dm)),\"pinnedSortMode\":\(jsonString(modes.pinned)),\"channelPanelTabOrder\":[\("\(array(modes.channelTabs))")],\"agentPanelTabOrder\":[\("\(array(modes.agentTabs))")],\"customSections\":[\("\(sectionJSON)")],\"sectionOrder\":[\("\(array(sections.order.isEmpty ? ["system:pinned", "system:joint", "system:channels", "system:dms"] : sections.order))")],\"sectionPlacements\":[\("\(placementJSON)")],\"sectionsVersion\":\(sections.version)}")
    }

    public func addTaskSnapshot(
        channelId: String,
        title: String,
        status: String,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        lock.lock()
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        taskRecords.append(TaskRecord(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            title: title,
            description: nil,
            status: status,
            taskNumber: taskNumber,
            messageId: UUID().uuidString.lowercased(),
            createdAt: createdAt,
            completedAt: completedAt,
            updatedAt: updatedAt
        ))
        lock.unlock()
    }

    public func addCompletedTask(
        channelId: String,
        title: String,
        createdAt: Date,
        completedAt: Date
    ) {
        lock.lock()
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        taskRecords.append(TaskRecord(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            title: title,
            description: nil,
            status: "done",
            taskNumber: taskNumber,
            messageId: UUID().uuidString.lowercased(),
            createdAt: createdAt,
            completedAt: completedAt
        ))
        lock.unlock()
    }

    public func addTask(channelId: String, title: String, description: String?) -> String {
        lock.lock()
        defer { lock.unlock() }
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        let id = UUID().uuidString.lowercased()
        taskRecords.append(TaskRecord(
            id: id,
            channelId: channelId,
            title: title,
            description: description,
            status: "todo",
            taskNumber: taskNumber,
            messageId: UUID().uuidString.lowercased(),
            createdAt: Date()
        ))
        return id
    }

    public func addTasks(channelId: String, titles: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var ids: [String] = []
        for title in titles {
            let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
            let id = UUID().uuidString.lowercased()
            taskRecords.append(TaskRecord(
                id: id,
                channelId: channelId,
                title: title,
                description: nil,
                status: "todo",
                taskNumber: taskNumber,
                messageId: UUID().uuidString.lowercased(),
                createdAt: Date()
            ))
            ids.append(id)
        }
        return ids
    }

    private enum TaskChannelAccess {
        case readOnly
        case write
        case missing
    }

    private func taskChannelAccess(serverId: String, channelId: String, userId: String) -> TaskChannelAccess {
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return .missing
        }
        if oauth.isChannelParticipant(channelId: channelId, userId: userId) {
            return .write
        }
        let type = oauth.channelType(id: channelId) ?? "channel"
        return type == "channel" ? .readOnly : .missing
    }

    private static let validTaskStatuses: Set<String> = ["todo", "in_progress", "in_review", "done", "cancelled"]

    private enum TaskStatusFilterResult {
        case valid(String?)
        case invalid(HTTPReply)
    }

    private static func taskStatusFilter(_ rawQuery: String?) -> TaskStatusFilterResult {
        guard let rawQuery else { return .valid(nil) }
        let statusOccurrences = rawQuery.split(separator: "&").filter { $0.hasPrefix("status=") }
        guard statusOccurrences.count <= 1 else {
            return .invalid(Self.json(400, "{\"error\":\"status must be a single valid task status\"}"))
        }
        guard let occurrence = statusOccurrences.first else { return .valid(nil) }
        let value = String(occurrence.dropFirst("status=".count)).removingPercentEncoding ?? ""
        guard validTaskStatuses.contains(value) else {
            return .invalid(Self.json(400, "{\"error\":\"status must be a single valid task status\"}"))
        }
        return .valid(value)
    }

    private func taskJSON(_ task: TaskRecord) -> String {
        let assignee = task.assigneeId.map { jsonString($0) } ?? "null"
        let assigneeType = task.assigneeType.map { jsonString($0) } ?? "null"
        let claimed = task.claimedAt.map { jsonString(ISO8601DateFormatter().string(from: $0)) } ?? "null"
        return "{\"id\":\(jsonString(task.id)),\"channelId\":\(jsonString(task.channelId)),\"messageId\":\(jsonString(task.messageId)),\"title\":\(jsonString(task.title)),\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber),\"claimedById\":\(assignee),\"claimedByType\":\(assigneeType),\"claimedAt\":\(claimed),\"revision\":\(task.revision)}"
    }

    private struct ServerLabsState {
        var accessEnabled = false
        var version = 0
        var enrolled: Set<String> = []
        var updatedAt: [String: Date] = [:]
    }

    private static let labDefinitions: [(key: String, name: String, description: String, state: String)] = [
        ("open_lab", "Open Lab", "Available", "open"),
        ("paused_lab", "Paused Lab", "Paused", "paused"),
        ("draft_lab", "Draft Lab", "Hidden", "draft"),
        ("retired_lab", "Retired Lab", "Historical", "retired"),
    ]

    private func labsJSON(serverId: String, userId: String, role: String, state: ServerLabsState) -> String {
        let labs = Self.labDefinitions
            .filter { $0.state == "open" || $0.state == "paused" }
            .map { lab -> String in
                let enrolled = state.enrolled.contains(lab.key)
                let effective = state.accessEnabled && lab.state == "open" && enrolled
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let updated = state.updatedAt[lab.key].map { jsonString(formatter.string(from: $0)) } ?? "null"
                return "{\"labKey\":\(jsonString(lab.key)),\"name\":\(jsonString(lab.name)),\"description\":\(jsonString(lab.description)),\"state\":\(jsonString(lab.state)),\"enrolled\":\(enrolled),\"effective\":\(effective),\"updatedAt\":\(updated)}"
            }
            .joined(separator: ",")
        let canManageAccess = role == "owner"
        let canManageEnrollments = role == "owner" || role == "admin"
        return "{\"accessEnabled\":\(state.accessEnabled),\"version\":\(state.version),\"canManageAccess\":\(canManageAccess),\"canManageEnrollments\":\(canManageEnrollments),\"labs\":[\(labs)]}"
    }

    public func getServerLabs(authorization: String?, serverId: String, headerServerId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard headerServerId == serverId else {
            return Self.json(403, "{\"error\":\"Server scope forbidden\",\"code\":\"server_scope_forbidden\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let state = serverLabsState[serverId] ?? ServerLabsState()
        lock.unlock()
        return Self.json(200, labsJSON(serverId: serverId, userId: userId, role: role, state: state))
    }

    public func patchServerLabsAccess(authorization: String?, serverId: String, headerServerId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard headerServerId == serverId else {
            return Self.json(403, "{\"error\":\"Server scope forbidden\",\"code\":\"server_scope_forbidden\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard role == "owner" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["enabled"] as? Bool,
              let expectedVersion = object["expectedVersion"] as? Int
        else {
            return Self.json(400, "{\"error\":\"Invalid labs access request\"}")
        }
        lock.lock()
        var state = serverLabsState[serverId] ?? ServerLabsState()
        if expectedVersion != state.version {
            let current = state.version
            lock.unlock()
            return Self.json(409, "{\"error\":\"Server Labs version changed\",\"code\":\"server_labs_version_conflict\",\"currentVersion\":\(current)}")
        }
        let applied = state.accessEnabled != enabled
        if applied {
            state.accessEnabled = enabled
            state.version += 1
        }
        serverLabsState[serverId] = state
        lock.unlock()
        var replyState = state
        if !applied {
            replyState.version = state.version
        }
        let json = labsJSON(serverId: serverId, userId: userId, role: role, state: replyState)
        return Self.json(200, "{\"applied\":\(applied),\"accessEnabled\":\(state.accessEnabled),\"version\":\(state.version),\"labs\":\(labsOnlyJSON(json))}")
    }

    private func labsOnlyJSON(_ labs: String) -> String {
        guard let range = labs.range(of: "\"labs\":[") else { return "[]" }
        let suffix = labs[range.upperBound...]
        guard let end = suffix.lastIndex(of: "]") else { return "[]" }
        return "[" + String(suffix[..<end]) + "]"
    }

    public func putServerLabEnrollment(authorization: String?, serverId: String, headerServerId: String, labKey: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard headerServerId == serverId else {
            return Self.json(403, "{\"error\":\"Server scope forbidden\",\"code\":\"server_scope_forbidden\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let definition = Self.labDefinitions.first(where: { $0.key == labKey }),
              definition.state == "open" || definition.state == "paused"
        else {
            return Self.json(404, "{\"error\":\"Lab not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["enabled"] as? Bool,
              let expectedVersion = object["expectedVersion"] as? Int
        else {
            return Self.json(400, "{\"error\":\"Invalid lab enrollment request\"}")
        }
        lock.lock()
        var state = serverLabsState[serverId] ?? ServerLabsState()
        if expectedVersion != state.version {
            let current = state.version
            lock.unlock()
            return Self.json(409, "{\"error\":\"Server Labs version changed\",\"code\":\"server_labs_version_conflict\",\"currentVersion\":\(current)}")
        }
        guard state.accessEnabled else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Server Labs access is disabled\",\"code\":\"server_labs_access_disabled\"}")
        }
        guard definition.state == "open" else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Lab is not open\",\"code\":\"lab_not_open\"}")
        }
        let isEnrolled = state.enrolled.contains(labKey)
        let applied = isEnrolled != enabled
        if applied {
            if enabled {
                state.enrolled.insert(labKey)
                state.updatedAt[labKey] = Date()
            } else {
                state.enrolled.remove(labKey)
            }
            state.version += 1
        }
        serverLabsState[serverId] = state
        lock.unlock()
        let json = labsJSON(serverId: serverId, userId: userId, role: role, state: state)
        return Self.json(200, "{\"applied\":\(applied),\"version\":\(state.version),\"labs\":\(labsOnlyJSON(json))}")
    }

    public func taskSnapshotMetrics(authorization: String?, serverId: String, rawQuery: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        var channelFilter: String?
        for pair in (rawQuery ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "channelId" {
                let rawChannel = parts[1].removingPercentEncoding ?? parts[1]
                guard UUID(uuidString: rawChannel) != nil,
                      let channel = oauth.channelInfo(id: rawChannel), channel.serverId == serverId
                else {
                    return Self.json(404, "{\"error\":\"Channel not found\"}")
                }
                if (oauth.channelType(id: rawChannel) ?? "channel") != "channel",
                   !oauth.isChannelParticipant(channelId: rawChannel, userId: userId) {
                    return Self.json(404, "{\"error\":\"Channel not found\"}")
                }
                channelFilter = rawChannel
            }
        }
        let visible = Set(oauth.channelsForServer(serverId: serverId, userId: userId).filter { $0.joined }.map { $0.id })
        lock.lock()
        let rows = taskRecords.filter { task in
            channelFilter.map({ $0 == task.channelId }) ?? visible.contains(task.channelId)
        }
        lock.unlock()
        let inReview = rows.filter { $0.status == "in_review" }.count
        let done = rows.filter { $0.status == "done" }.count
        let durations = rows.compactMap { task -> Double? in
            guard let completedAt = task.completedAt else { return nil }
            return completedAt.timeIntervalSince(task.createdAt) / 3600
        }.sorted()
        func percentile(_ value: Double) -> Double {
            guard !durations.isEmpty else { return 0 }
            let index = max(0, min(durations.count - 1, Int(ceil(value * Double(durations.count))) - 1))
            return durations[index]
        }
        let median = percentile(0.5)
        let p90 = percentile(0.9)
        func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let firstCreatedAt = rows.compactMap { $0.createdAt }.min()
        let latestUpdatedAt = rows.compactMap { $0.updatedAt ?? $0.completedAt ?? $0.createdAt }.max()
        let firstJSON = firstCreatedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        let latestJSON = latestUpdatedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        return Self.json(200, "{\"total\":\(rows.count),\"inReview\":\(inReview),\"done\":\(done),\"durationSamples\":\(durations.count),\"medianHours\":\(number(median)),\"p90Hours\":\(number(p90)),\"firstCreatedAt\":\(firstJSON),\"latestUpdatedAt\":\(latestJSON)}")
    }

    public func taskPeriodMetrics(authorization: String?, serverId: String, rawQuery: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        var params: [String: String] = [:]
        for pair in (rawQuery ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { params[parts[0]] = parts[1].removingPercentEncoding ?? parts[1] }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        func parse(_ value: String?) -> Date? {
            guard let value else { return nil }
            return formatter.date(from: value) ?? fallback.date(from: value)
        }
        guard let from = parse(params["from"]), let midpoint = parse(params["midpoint"]), let to = parse(params["to"]) else {
            return Self.json(400, "{\"error\":\"Invalid metrics window\"}")
        }
        let week: TimeInterval = 7 * 24 * 60 * 60
        guard abs(midpoint.timeIntervalSince(from) - week) < 1,
              abs(to.timeIntervalSince(midpoint) - week) < 1
        else {
            return Self.json(400, "{\"error\":\"Invalid metrics window\"}")
        }
        var channelFilter: String?
        if let rawChannel = params["channelId"] {
            guard UUID(uuidString: rawChannel) != nil else {
                return Self.json(400, "{\"error\":\"Invalid channelId\"}")
            }
            guard let channel = oauth.channelInfo(id: rawChannel), channel.serverId == serverId else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            if (oauth.channelType(id: rawChannel) ?? "channel") != "channel",
               !oauth.isChannelParticipant(channelId: rawChannel, userId: userId) {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            channelFilter = rawChannel
        }
        let visible = Set(oauth.channelsForServer(serverId: serverId, userId: userId).filter { $0.joined }.map { $0.id })
        lock.lock()
        let rows = taskRecords.filter { task in
            guard let completedAt = task.completedAt else { return false }
            guard channelFilter.map({ $0 == task.channelId }) ?? visible.contains(task.channelId) else { return false }
            return completedAt >= from && completedAt < to
        }
        lock.unlock()
        func metrics(_ start: Date, _ end: Date) -> String {
            let window = rows.filter { task in
                guard let completedAt = task.completedAt else { return false }
                return completedAt >= start && completedAt < end
            }
            let durations = window.compactMap { task -> Double? in
                guard let completedAt = task.completedAt else { return nil }
                return completedAt.timeIntervalSince(task.createdAt) / 3600
            }.sorted()
            let mean = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
            let median: Double
            if durations.isEmpty {
                median = 0
            } else if durations.count % 2 == 1 {
                median = durations[durations.count / 2]
            } else {
                median = (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2
            }
            func number(_ value: Double) -> String {
                value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
            }
            return "{\"completed\":\(window.count),\"durationSamples\":\(durations.count),\"meanHours\":\(number(mean)),\"medianHours\":\(number(median))}"
        }
        return Self.json(200, "{\"current\":\(metrics(midpoint, to)),\"previous\":\(metrics(from, midpoint))}")
    }

    public func listChannelTasks(authorization: String?, serverId: String, channelId: String, rawQuery: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let status: String?
        switch Self.taskStatusFilter(rawQuery) {
        case .invalid(let reply): return reply
        case .valid(let value): status = value
        }
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Channel not found\"}")
        case .readOnly, .write: break
        }
        lock.lock()
        let rows = taskRecords.filter {
            $0.channelId == channelId && (status == nil || $0.status == status)
        }
        lock.unlock()
        let items = rows.map { taskJSON($0) }.joined(separator: ",")
        return Self.json(200, "{\"tasks\":[\("\(items)")]}")
    }

    public func getChannelTaskByNumber(authorization: String?, serverId: String, channelId: String, taskNumber: Int) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Channel not found\"}")
        case .readOnly, .write: break
        }
        lock.lock()
        let task = taskRecords.first { $0.channelId == channelId && $0.taskNumber == taskNumber }
        lock.unlock()
        guard let task else { return Self.json(404, "{\"error\":\"Task not found\"}") }
        return Self.json(200, "{\"task\":\(taskJSON(task))}")
    }

    public func createChannelTasks(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Channel not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let tasks = object["tasks"] as? [[String: Any]],
              !tasks.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid task list\"}")
        }
        let titles = tasks.compactMap { $0["title"] as? String }.filter { !$0.isEmpty }
        let ids = addTasks(channelId: channelId, titles: titles)
        return Self.json(200, "{\"taskIds\":[\("\(ids.map { jsonString($0) }.joined(separator: ","))")]}")
    }

    public func assignTask(authorization: String?, serverId: String, taskId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid assignment\"}")
        }
        let assignee: (type: String, id: String)?
        if object["assignee"] is NSNull {
            assignee = nil
        } else if let raw = object["assignee"] as? [String: Any],
                  let type = raw["type"] as? String, type == "user" || type == "agent",
                  let id = raw["id"] as? String, !id.isEmpty {
            assignee = (type, id)
        } else {
            return Self.json(400, "{\"error\":\"Invalid assignment\"}")
        }
        let expectedRevision = object["expectedRevision"] as? Int
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        lock.unlock()
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if (oauth.channelType(id: channelId) ?? "channel") != "channel",
           !oauth.isChannelParticipant(channelId: channelId, userId: userId) {
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        if let assignee {
            if assignee.type == "user" {
                guard oauth.isChannelParticipant(channelId: channelId, userId: assignee.id),
                      oauth.memberRole(serverId: serverId, userId: assignee.id) != nil
                else {
                    return Self.json(409, "{\"error\":\"Assignee is not in this channel\"}")
                }
            } else {
                guard let agent = oauth.agentRuntimeInfo(id: assignee.id), agent.serverId == serverId, !agent.deleted else {
                    return Self.json(409, "{\"error\":\"Assignee is not in this channel\"}")
                }
            }
        }
        lock.lock()
        guard taskRecords[index].status != "done" else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"A done task cannot be reassigned\"}")
        }
        let currentRevision = taskRecords[index].revision
        if let expectedRevision, expectedRevision != currentRevision {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Task changed concurrently\",\"currentRevision\":\(currentRevision)}")
        }
        let sameAssignee = taskRecords[index].assigneeId == assignee?.id
            && taskRecords[index].assigneeType == assignee?.type
        if sameAssignee {
            let task = taskRecords[index]
            lock.unlock()
            return Self.json(200, taskJSON(task))
        }
        taskRecords[index].assigneeId = assignee?.id
        taskRecords[index].assigneeType = assignee?.type
        taskRecords[index].claimedAt = nil
        taskRecords[index].revision += 1
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    private func archivedChannelReply(_ channelId: String) -> HTTPReply? {
        guard oauth.channelArchivedAt(id: channelId) != nil else { return nil }
        return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
    }

    public func setChannelArchivedRoute(authorization: String?, serverId: String, channelId: String, archived: Bool) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let channelAdmin = channelHumanRoles["\(channelId)\n\(userId)"] == "admin"
        lock.unlock()
        guard role == "owner" || role == "admin" || channelAdmin else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let existing = oauth.channelArchivedAt(id: channelId)
        if archived {
            if existing == nil {
                let now = Date()
                oauth.setChannelArchived(id: channelId, archivedAt: now)
            }
            lock.lock()
            postableChannels[channelId]?.archived = true
            for (id, var postable) in postableChannels where postable.parentChannelId == channelId {
                postable.archived = true
                postableChannels[id] = postable
            }
            lock.unlock()
        } else {
            oauth.setChannelArchived(id: channelId, archivedAt: nil)
            lock.lock()
            postableChannels[channelId]?.archived = false
            for (id, var postable) in postableChannels where postable.parentChannelId == channelId {
                postable.archived = false
                postableChannels[id] = postable
            }
            lock.unlock()
        }
        if let date = oauth.channelArchivedAt(id: channelId) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return Self.json(200, "{\"archivedAt\":\(jsonString(formatter.string(from: date)))}")
        }
        return Self.json(200, "{\"archivedAt\":null}")
    }

    public func agentJoinChannel(authorization: String?, channelId: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.scopes.contains("channels"),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: agent.id, scope: "channel:join") { return reply }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if oauth.channelAgentIds(channelId: channelId).contains(agent.id) {
            return Self.json(200, "{\"ok\":true}")
        }
        guard oauth.agentRole(serverId: agent.serverId, agentId: agent.id) != nil else {
            return Self.json(403, "{\"error\":\"Server role cannot join public channels\"}")
        }
        oauth.addChannelAgent(channelId: channelId, agentId: agent.id)
        return Self.json(200, "{\"ok\":true}")
    }

    public func joinChannel(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        if oauth.isChannelParticipant(channelId: channelId, userId: userId) {
            return Self.json(200, "{\"ok\":true}")
        }
        guard oauth.channelType(id: channelId) == "channel" else {
            return Self.json(403, "{\"error\":\"Private channels are invite-only\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Server role cannot join public channels\"}")
        }
        oauth.addChannelHuman(channelId: channelId, userId: userId)
        return Self.json(200, "{\"ok\":true}")
    }

    private func agentCredentialAgent(_ authorization: String?) -> (agentId: String, scopes: [String])? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        defer { lock.unlock() }
        guard let credential = agentCredentials[token], credential.revokedAt == nil else { return nil }
        agentCredentials[token]?.lastUsedAt = Date()
        return (credential.agentId, Array(credential.scopes))
    }

    private func agentCapabilityDenied(_ error: String) -> HTTPReply {
        Self.json(403, "{\"error\":\(jsonString(error)),\"code\":\"server_role_required\",\"currentRole\":\"member\",\"suggestedNextAction\":\"Ask a server owner or admin to grant the capability; your role is member.\"}")
    }

    private func agentAndRole(_ authorization: String?, scopes: [String]) -> (agent: OAuthLedger.AgentRuntimeInfo, role: String?)? {
        lock.lock()
        let token = authorization?.hasPrefix("Bearer ") == true ? String(authorization!.dropFirst("Bearer ".count)) : ""
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, scopes.allSatisfy({ credential.scopes.contains($0) }),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { return nil }
        return (agent, oauth.agentRole(serverId: agent.serverId, agentId: agent.id))
    }

    public func agentUpdateChannel(authorization: String?, channelId: String, body: String) -> HTTPReply {
        guard let (agent, role) = agentAndRole(authorization, scopes: ["channels"]) else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard role == "owner" || role == "admin" else {
            return agentCapabilityDenied("Agent requires editChannelMetadata or changeChannelVisibility capability to update channels")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel update\"}")
        }
        var name = channel.name
        if let raw = object["name"] as? String {
            name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        }
        _ = oauth.renameChannel(id: channelId, name: name)
        lock.lock()
        postableChannels[channelId]?.name = name
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(jsonString(name)),\"type\":\(jsonString(oauth.channelType(id: channelId) == "private" ? "private" : "channel"))}")
    }

    private var memberAttentionJSON: String {
        ",\"attention\":{\"stillArrives\":[\"Followed threads still notify this member unless they unfollow them.\"],\"threadBoundary\":\"Removing this member does not unfollow existing thread follows. Private channel/thread content still requires current parent access.\",\"manageCommand\":\"Use raft thread unfollow to manage thread follows.\"}"
    }

    public func agentChannelMemberWrite(authorization: String?, channelId: String, body: String, remove: Bool) -> HTTPReply {
        guard let (agent, role) = agentAndRole(authorization, scopes: ["channels"]) else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if remove && role != "owner" && role != "admin" {
            return agentCapabilityDenied("Agent requires removeChannelMembers capability to remove channel members")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel member\"}")
        }
        if let userName = object["user"] as? String {
            lock.lock()
            let target = accounts.values.first { $0.name == userName || $0.id == userName }?.id
            lock.unlock()
            guard let target, oauth.memberRole(serverId: agent.serverId, userId: target) != nil else {
                return Self.json(404, "{\"error\":\"User not found\"}")
            }
            if remove {
                let wasMember = oauth.channelHumanIds(channelId: channelId).contains(target)
                lock.lock()
                postableChannels[channelId]?.memberIds.remove(target)
                lock.unlock()
                _ = oauth.removeChannelHuman(channelId: channelId, userId: target)
                return Self.json(200, "{\"ok\":true,\"wasMember\":\(wasMember),\"member\":{\"type\":\"human\",\"name\":\(jsonString(userName))}\(memberAttentionJSON)}")
            }
            let already = oauth.channelHumanIds(channelId: channelId).contains(target)
            if !already {
                accountsForInvite(userId: target, serverId: agent.serverId, channelId: channelId)
            }
            return Self.json(200, "{\"ok\":true,\"alreadyMember\":\(already),\"member\":{\"type\":\"human\",\"name\":\(jsonString(userName))}}")
        }
        if let agentName = object["agent"] as? String {
            let target = oauth.activeAgentIds(serverId: agent.serverId).first { oauth.agentRuntimeInfo(id: $0)?.name == agentName || $0 == agentName }
            guard let target else {
                return Self.json(404, "{\"error\":\"Agent not found\"}")
            }
            if remove {
                let wasMember = oauth.channelAgentIds(channelId: channelId).contains(target)
                oauth.removeChannelAgent(channelId: channelId, agentId: target)
                return Self.json(200, "{\"ok\":true,\"wasMember\":\(wasMember),\"member\":{\"type\":\"agent\",\"name\":\(jsonString(agentName))}\(memberAttentionJSON)}")
            }
            let already = oauth.channelAgentIds(channelId: channelId).contains(target)
            if !already {
                oauth.addChannelAgent(channelId: channelId, agentId: target)
            }
            return Self.json(200, "{\"ok\":true,\"alreadyMember\":\(already),\"member\":{\"type\":\"agent\",\"name\":\(jsonString(agentName))}}")
        }
        return Self.json(400, "{\"error\":\"Invalid channel member\"}")
    }

    public func agentUpdateServer(authorization: String?, body: String) -> HTTPReply {
        guard let (agent, role) = agentAndRole(authorization, scopes: ["server"]) else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard role == "owner" || role == "admin" else {
            return agentCapabilityDenied("Agent requires editServerSettings capability to edit the server profile")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid server update\"}")
        }
        oauth.updateServerName(id: agent.serverId, name: name)
        return Self.json(200, "{\"ok\":true,\"id\":\(jsonString(agent.serverId)),\"name\":\(jsonString(name))}")
    }

    public func agentChannelMembers(authorization: String?, agentId: String, channelRef: String?) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let machine = machines.first { $0.apiKey == apiKey }
        let legacy = machineKeys[apiKey]
        lock.unlock()
        guard let machineServerId = machine?.serverId ?? legacy?.serverId,
              let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted,
              agent.serverId == machineServerId
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let reference = (channelRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.hasPrefix("#") else {
            return Self.json(400, "{\"error\":\"channel is required\"}")
        }
        let raw = String(reference.dropFirst())
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? raw
        let shortId = parts.count > 1 ? parts[1] : nil
        lock.lock()
        let parent = postableChannels.first { _, channel in
            channel.serverId == agent.serverId && channel.name == name && channel.kind == "channel" && channel.deletedAt == nil
        }?.key
        var targetId = parent
        var type = "channel"
        if let shortId, let parent {
            targetId = postableChannels.first { _, channel in
                channel.serverId == agent.serverId && channel.kind == "thread"
                    && channel.parentChannelId == parent
                    && (channel.parentMessageId?.hasPrefix(shortId) ?? false)
            }?.key
            type = targetId == nil ? "channel" : "thread"
        }
        guard let targetId, let parentId = type == "thread" ? postableChannels[targetId]?.parentChannelId : targetId else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let humanIds = oauth.channelHumanIds(channelId: parentId)
        let agentIds = oauth.channelAgentIds(channelId: parentId)
        let humanNames = Dictionary(uniqueKeysWithValues: humanIds.map { id in
            (id, accounts.values.first { $0.id == id }?.name ?? id)
        })
        lock.unlock()
        let humans = humanIds.map { id -> String in
            let name = humanNames[id] ?? id
            let role = oauth.memberRole(serverId: agent.serverId, userId: id) ?? "member"
            return "{\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),\"role\":\(jsonString(role))}"
        }.joined(separator: ",")
        let agents = agentIds.map { id -> String in
            "{\"id\":\(jsonString(id)),\"name\":\(jsonString(oauth.agentRuntimeInfo(id: id)?.name ?? ""))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"channel\":{\"ref\":\(jsonString(reference)),\"type\":\(jsonString(type))},\"humans\":[\(humans)],\"agents\":[\(agents)]}")
    }

    public func agentServerInfo(authorization: String?) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let profile = oauth.serverProfile(id: agent.serverId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        let role = oauth.agentRole(serverId: agent.serverId, agentId: agent.id)
        lock.lock()
        let channels = postableChannels
            .filter { $0.value.serverId == agent.serverId && $0.value.deletedAt == nil }
            .map { id, channel -> (String, String, Bool) in
                let joined = channel.memberIds.contains(agent.id) || oauth.channelAgentIds(channelId: id).contains(agent.id)
                return (id, channel.name, joined)
            }
            .sorted { $0.0 < $1.0 }
        let agentRows = oauth.activeAgentIds(serverId: agent.serverId).map { otherId -> String in
            let info = oauth.agentRuntimeInfo(id: otherId)
            let activity = agentActivities[otherId] ?? (activity: "offline", detail: "")
            let otherRole = oauth.agentRole(serverId: agent.serverId, agentId: otherId) ?? "null"
            return "{\"id\":\(jsonString(otherId)),\"name\":\(jsonString(info?.name ?? "")),\"role\":\(otherRole == "null" ? "null" : jsonString(otherRole)),\"status\":\"active\",\"activity\":\(jsonString(activity.activity)),\"activityDetail\":\(jsonString(activity.detail))}"
        }
        lock.unlock()
        let channelJSON = channels.map { id, name, joined in
            "{\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),\"joined\":\(joined)}"
        }.joined(separator: ",")
        let roleJSON = role.map { jsonString($0) } ?? "null"
        let body = "{\"id\":\(jsonString(profile.id)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"runtimeContext\":{\"agentId\":\(jsonString(agent.id)),\"runtime\":\(jsonString(agent.runtime)),\"model\":\"external\",\"reasoningEffort\":null},\"serverRole\":\(roleJSON),\"serverCapabilities\":{\"addChannelMembers\":true,\"createChannels\":true},\"channels\":[\(channelJSON)],\"agents\":[\(agentRows.joined(separator: ","))]}"
        return Self.json(200, body)
    }

    public func agentResolveChannel(authorization: String?, body: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let target = object["target"] as? String, target.hasPrefix("#")
        else {
            return Self.json(400, "{\"error\":\"Invalid target\"}")
        }
        let name = String(target.dropFirst())
        lock.lock()
        let channelId = postableChannels.first { _, channel in
            channel.serverId == agent.serverId && channel.name == name && channel.deletedAt == nil
        }?.key
        lock.unlock()
        guard let channelId, let channel = oauth.channelInfo(id: channelId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let type = oauth.channelType(id: channelId) ?? "channel"
        lock.lock()
        let joined = postableChannels[channelId]?.memberIds.contains(agent.id) == true
            || oauth.channelAgentIds(channelId: channelId).contains(agent.id)
        lock.unlock()
        guard type == "channel" || joined else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        return Self.json(200, "{\"channelId\":\(jsonString(channelId)),\"type\":\(jsonString(type))}")
    }

    public func agentCreateChannel(authorization: String?, body: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization), credential.scopes.contains("channels"),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawName = object["name"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid channel\"}")
        }
        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard name.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) != nil else {
            return Self.json(400, "{\"error\":\"Invalid channel\"}")
        }
        let visibility = (object["visibility"] as? String) ?? "public"
        guard ["public", "private"].contains(visibility) else {
            return Self.json(400, "{\"error\":\"Invalid channel visibility\"}")
        }
        let type = visibility == "private" ? "private" : "channel"
        let channelId = oauth.createChannel(serverId: agent.serverId, name: name, creatorUserId: agent.id, type: type)
        oauth.removeChannelHuman(channelId: channelId, userId: agent.id)
        oauth.addChannelAgent(channelId: channelId, agentId: agent.id)
        lock.lock()
        postableChannels[channelId] = PostableChannel(serverId: agent.serverId, memberIds: [], kind: type, name: name)
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(jsonString(name)),\"type\":\(jsonString(type)),\"createdByAgentId\":\(jsonString(agent.id))}")
    }

    // MARK: - Product feedback locators (`POST/GET /internal/agent-api/feedback-locators`)

    private static let feedbackLocatorForbiddenKeys: Set<String> = [
        "body", "content", "content_window", "context", "context_window", "feedback_body",
        "l3", "message_body", "path", "prompt", "raw", "raw_args", "raw_argv", "raw_error",
        "raw_value", "raw_values", "searched_paths", "searchedpaths", "session_content",
        "session_text", "stderr", "stdin", "stdout", "trajectory", "transcript", "value",
        "values", "wider_window", "window",
    ]

    private static func normalizeFeedbackKey(_ key: String) -> String {
        var result = ""
        var previous: Character?
        for character in key {
            if character == "-" || character == " " {
                result.append("_")
            } else if character.isUppercase, let prior = previous, prior.isLowercase {
                result.append("_")
                result.append(Character(character.lowercased()))
            } else {
                result.append(Character(character.lowercased()))
            }
            previous = character
        }
        return result
    }

    private static func feedbackContainsForbiddenKey(_ value: Any) -> Bool {
        if let array = value as? [Any] {
            return array.contains(where: feedbackContainsForbiddenKey)
        }
        guard let object = value as? [String: Any] else { return false }
        for (key, nested) in object {
            if feedbackLocatorForbiddenKeys.contains(normalizeFeedbackKey(key)) { return true }
            if feedbackContainsForbiddenKey(nested) { return true }
        }
        return false
    }

    private static func feedbackStableJSON(_ value: Any) -> String {
        if let array = value as? [Any] {
            return "[" + array.map { feedbackStableJSON($0) }.joined(separator: ",") + "]"
        }
        if let object = value as? [String: Any] {
            let parts = object.keys.sorted().map { key in
                "\(jsonString(key)):\(feedbackStableJSON(object[key] as Any))"
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            if type == "c" || type == "B" {
                return number.boolValue ? "true" : "false"
            }
            if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e15 {
                return String(number.int64Value)
            }
            return String(number.doubleValue)
        }
        if let string = value as? String {
            return jsonString(string)
        }
        return "null"
    }

    public func setAgentGrantsForTesting(agentId: String, scopes: [String]) {
        lock.lock()
        agentGrantSets[agentId] = Set(scopes)
        lock.unlock()
    }

    public func resetAgentGrantsForTesting(agentId: String) {
        lock.lock()
        agentGrantSets.removeValue(forKey: agentId)
        lock.unlock()
    }

    private func agentGrantDenial(agentId: String, scope: String) -> HTTPReply? {
        lock.lock()
        let grants = agentGrantSets[agentId]
        lock.unlock()
        guard let grants, !grants.contains(scope) else { return nil }
        return Self.json(403, "{\"error\":\"missing required scope\",\"requiredScope\":\(jsonString(scope)),\"reason\":\"missing_scope\"}")
    }

    private enum FeedbackLocatorIdentityResult {
        case success(agentId: String, serverId: String)
        case refused(HTTPReply)
    }

    private func feedbackLocatorIdentity(
        authorization: String?,
        capability: String
    ) -> FeedbackLocatorIdentityResult {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .refused(Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"))
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil else {
            return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        }
        guard credential.scopes.contains(capability) else {
            return .refused(Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\(jsonString(capability))}"))
        }
        guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
        }
        return .success(agentId: credential.agentId, serverId: agent.serverId)
    }

    private func feedbackLocatorFailure(_ status: Int, _ reason: String) -> HTTPReply {
        Self.json(status, "{\"status\":\"failed\",\"reason_code\":\(jsonString(reason))}")
    }

    public func ingestFeedbackLocator(authorization: String?, body: String) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "send") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let envelope = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return feedbackLocatorFailure(400, "invalid_payload")
        }
        guard (envelope["artifact_kind"] as? String) == "raft-feedback-locator-v0" else {
            return feedbackLocatorFailure(400, "unknown_artifact_kind")
        }
        guard (envelope["event_kind"] as? String) == "feedback-locator:created" else {
            return feedbackLocatorFailure(400, "unknown_event_kind")
        }
        guard let payload = envelope["payload"] as? [String: Any] else {
            return feedbackLocatorFailure(400, "invalid_payload")
        }
        if Self.feedbackContainsForbiddenKey(payload) {
            return feedbackLocatorFailure(400, "forbidden_field")
        }
        let route = payload["route"] as? [String: Any]
        let resolution = route?["resolution"] as? [String: Any]
        if let resolution, (resolution["status"] as? String) != "resolved",
           resolution["target"] != nil || resolution["ref"] != nil {
            return feedbackLocatorFailure(400, "invalid_route_ref")
        }
        if let target = resolution?["target"] as? [String: Any] {
            guard (target["kind"] as? String) == "public_channel",
                  let ref = target["ref"] as? String,
                  ref.range(of: "^#[a-z0-9][a-z0-9_-]{0,126}$", options: [.regularExpression, .caseInsensitive]) != nil
            else {
                return feedbackLocatorFailure(400, "invalid_route_ref")
            }
        }
        guard (payload["schema_version"] as? String) == "raft.feedback.locator.v0" else {
            return feedbackLocatorFailure(400, "unknown_schema_version")
        }
        guard let reportId = payload["report_id"] as? String,
              ServerScope.isUUID(reportId),
              let capturedRaw = payload["captured_at"] as? String,
              let capturedAt = Self.isoDate(capturedRaw),
              let producer = payload["producer"] as? [String: Any],
              (producer["server_id"] as? String) == identity.serverId,
              (producer["agent_id"] as? String) == identity.agentId,
              let locators = payload["locators"] as? [String: Any],
              let l0 = locators["l0"] as? [String: Any],
              let runtime = l0["runtime"] as? String,
              let native = l0["native"] as? [String: Any],
              let nativeStatus = native["status"] as? String
        else {
            return feedbackLocatorFailure(400, "invalid_payload")
        }
        if (resolution?["status"] as? String) == "resolved" {
            if let delivery = route?["delivery"] as? [String: Any],
               let status = delivery["status"] as? String,
               status == "accepted" || status == "failed" {
                return feedbackLocatorFailure(400, "invalid_payload")
            }
            guard let ref = (resolution?["target"] as? [String: Any])?["ref"] as? String,
                  ref == "#proj-feedback"
            else {
                return feedbackLocatorFailure(400, "invalid_route_ref")
            }
            let name = String(ref.dropFirst())
            lock.lock()
            let exists = postableChannels.values.contains {
                $0.serverId == identity.serverId && $0.kind == "channel" && $0.name == name && $0.deletedAt == nil
            }
            lock.unlock()
            guard exists else {
                return feedbackLocatorFailure(400, "invalid_route_ref")
            }
        }
        let nativeLookupMethod = native["lookup_method"] as? String ?? "not_attempted"
        let nativeLocatorKind = native["locator_kind"] as? String ?? "none"
        var servedExactSha256: [String] = []
        if let exacts = payload["exacts"] as? [Any] {
            for entry in exacts {
                guard let row = entry as? [String: Any],
                      (row["status"] as? String) == "retained",
                      let sha = row["sha256"] as? String
                else { continue }
                servedExactSha256.append(sha)
            }
        }
        let routeBasis = (resolution?["status"] as? String) == "resolved" ? resolution?["basis"] as? String : nil
        let routeTarget = (resolution?["status"] as? String) == "resolved"
            ? (resolution?["target"] as? [String: Any])?["ref"] as? String
            : nil
        let digest = Self.sha256(Self.feedbackStableJSON(payload))
        lock.lock()
        if let existing = feedbackLocatorRecords.first(where: {
            $0.serverId == identity.serverId && $0.reportId == reportId
        }) {
            let same = existing.payloadSha256 == digest
            let receipt = existing.receiptId
            lock.unlock()
            if !same {
                return feedbackLocatorFailure(409, "report_identity_conflict")
            }
            return Self.json(200, "{\"status\":\"accepted\",\"receipt_id\":\(jsonString(receipt)),\"report_id\":\(jsonString(reportId)),\"duplicate\":true}")
        }
        let receiptId = UUID().uuidString.lowercased()
        feedbackLocatorRecords.append(FeedbackLocatorRecord(
            serverId: identity.serverId,
            producerAgentId: identity.agentId,
            reportId: reportId,
            receiptId: receiptId,
            capturedAt: capturedAt,
            runtime: runtime,
            nativeStatus: nativeStatus,
            nativeLookupMethod: nativeLookupMethod,
            nativeLocatorKind: nativeLocatorKind,
            hasServedExact: !servedExactSha256.isEmpty,
            servedExactSha256: servedExactSha256,
            routeBasis: routeBasis,
            routeTarget: routeTarget,
            payloadSha256: digest,
            createdAt: Date()
        ))
        lock.unlock()
        return Self.json(200, "{\"status\":\"accepted\",\"receipt_id\":\(jsonString(receiptId)),\"report_id\":\(jsonString(reportId)),\"duplicate\":false}")
    }

    public func listFeedbackLocators(
        authorization: String?,
        reportId: String?,
        runtime: String?,
        nativeStatus: String?,
        nativeLookupMethod: String?,
        servedExactSha256: String?,
        routeBasis: String?,
        limit rawLimit: String?
    ) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        let limit = min(max(Int(rawLimit ?? "") ?? 50, 1), 100)
        lock.lock()
        var rows = feedbackLocatorRecords
            .filter { $0.serverId == identity.serverId }
            .sorted { $0.createdAt > $1.createdAt }
        if let reportId, !reportId.isEmpty { rows = rows.filter { $0.reportId == reportId } }
        if let runtime, !runtime.isEmpty { rows = rows.filter { $0.runtime == runtime } }
        if let nativeStatus, !nativeStatus.isEmpty { rows = rows.filter { $0.nativeStatus == nativeStatus } }
        if let nativeLookupMethod, !nativeLookupMethod.isEmpty {
            rows = rows.filter { $0.nativeLookupMethod == nativeLookupMethod }
        }
        if let servedExactSha256, !servedExactSha256.isEmpty {
            rows = rows.filter { $0.servedExactSha256.contains(servedExactSha256) }
        }
        if let routeBasis, !routeBasis.isEmpty { rows = rows.filter { $0.routeBasis == routeBasis } }
        rows = Array(rows.prefix(limit))
        let locators = rows.map { row -> String in
            let shas = row.servedExactSha256.map { jsonString($0) }.joined(separator: ",")
            let basis = row.routeBasis.map(jsonString) ?? "null"
            let target = row.routeTarget.map(jsonString) ?? "null"
            return "{\"report_id\":\(jsonString(row.reportId)),\"receipt_id\":\(jsonString(row.receiptId)),\"captured_at\":\(jsonString(Self.isoString(row.capturedAt))),\"runtime\":\(jsonString(row.runtime)),\"native_status\":\(jsonString(row.nativeStatus)),\"native_lookup_method\":\(jsonString(row.nativeLookupMethod)),\"native_locator_kind\":\(jsonString(row.nativeLocatorKind)),\"has_served_exact\":\(row.hasServedExact),\"served_exact_sha256\":[\(shas)],\"route_basis\":\(basis),\"route_target\":\(target)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"locators\":[\(locators)]}")
    }

    public func addManagedMCPServerForTesting(
        serverId: String,
        name: String,
        provider: String? = nil,
        authMode: String? = nil,
        oauthStatus: String? = nil,
        endpointUrl: String = "https://example.com/mcp",
        tools: [(name: String, inputSchemaJSON: String)] = [],
        catalogVersion: Int = 1
    ) -> String {
        let id = UUID().uuidString.lowercased()
        let catalog = tools.map { tool in
            "{\"name\":\(jsonString(tool.name)),\"inputSchema\":\(tool.inputSchemaJSON)}"
        }.joined(separator: ",")
        lock.lock()
        managedMCPServers.append(ManagedMCPServerRecord(
            id: id,
            serverId: serverId,
            name: name,
            provider: provider,
            authMode: authMode,
            oauthStatus: oauthStatus,
            endpointUrl: endpointUrl,
            toolCatalogJSON: "[\(catalog)]",
            catalogVersion: catalogVersion
        ))
        lock.unlock()
        return id
    }

    private func managedMCPUnavailable(_ record: ManagedMCPServerRecord) -> Bool {
        record.authMode == "oauth" && record.oauthStatus != "connected"
    }

    private func managedMCPTools(_ record: ManagedMCPServerRecord) -> [(name: String, schemaJSON: String)] {
        guard let data = record.toolCatalogJSON.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            let schema = row["inputSchema"] ?? ["type": "object"]
            let schemaData = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{}".utf8)
            return (name, String(decoding: schemaData, as: UTF8.self))
        }
    }

    public func managedMCPToolSnapshot(authorization: String?) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "mcp") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        lock.lock()
        let records = managedMCPServers.filter { $0.serverId == identity.serverId }
        lock.unlock()
        var tools: [String] = []
        var unavailable: [String] = []
        var catalogVersion = 1
        for record in records {
            if managedMCPUnavailable(record) {
                unavailable.append("{\"mcpServerId\":\(jsonString(record.id)),\"serverName\":\(jsonString(record.name)),\"status\":\"reconnect_required\"}")
                continue
            }
            catalogVersion = max(catalogVersion, record.catalogVersion)
            for tool in managedMCPTools(record) {
                tools.append("{\"mcpServerId\":\(jsonString(record.id)),\"serverName\":\(jsonString(record.name)),\"toolName\":\(jsonString(tool.name)),\"inputSchema\":\(tool.schemaJSON),\"assignmentVersion\":1,\"catalogVersion\":\(record.catalogVersion)}")
            }
        }
        var document = "{\"catalogVersion\":\(catalogVersion),\"tools\":[\(tools.joined(separator: ","))]"
        if !unavailable.isEmpty {
            document += ",\"unavailable\":[\(unavailable.joined(separator: ","))]"
        }
        document += "}"
        return Self.json(200, document)
    }

    public func callManagedMCPTool(authorization: String?, body: String) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "mcp") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawServerId = object["mcpServerId"] as? String,
              ServerScope.isUUID(rawServerId),
              let toolName = object["toolName"] as? String, !toolName.isEmpty
        else {
            return Self.json(400, "{\"code\":\"managed_mcp_invalid_request\",\"error\":\"mcpServerId must be a UUID and toolName is required\"}")
        }
        lock.lock()
        let record = managedMCPServers.first { $0.id == rawServerId && $0.serverId == identity.serverId }
        lock.unlock()
        guard let record else {
            return Self.json(404, "{\"code\":\"managed_mcp_server_not_found\",\"error\":\"MCP server not found\"}")
        }
        guard !managedMCPUnavailable(record) else {
            return Self.json(409, "{\"code\":\"managed_mcp_reconnect_required\",\"error\":\"The managed MCP connector needs to be reconnected\",\"suggestedNextAction\":\"Ask a server admin to reconnect the connector, then retry.\"}")
        }
        let staleText = "\"\(toolName)\" is no longer offered by \"\(record.name)\"; don't call it again. If you still need it, tell the person who asked."
        let offered = managedMCPTools(record).map(\.name)
        let staleVersion = object["expectedConfigVersion"] as? NSNumber
        let staleAssignment = object["expectedAssignmentVersion"] as? NSNumber
        if !offered.contains(toolName)
            || (staleVersion != nil && staleVersion?.intValue != record.catalogVersion)
            || (staleAssignment != nil && staleAssignment?.intValue != 1) {
            return Self.json(409, "{\"code\":\"managed_mcp_config_stale\",\"error\":\(jsonString(staleText)),\"suggestedNextAction\":\(jsonString(staleText))}")
        }
        return Self.json(502, "{\"code\":\"managed_mcp_upstream_unavailable\",\"error\":\"The managed MCP transport is not available in this build\"}")
    }

    // MARK: - Action cards (`POST /internal/agent-api/prepare-action`, `POST /api/actions/:id/execute`)

    private static let appConfigSchemaJSON = "{\"enabled\":{\"type\":\"boolean\"},\"threshold_bytes\":{\"type\":\"integer\",\"minimum\":4096,\"maximum\":1073741824},\"interval_seconds\":{\"type\":\"integer\",\"minimum\":900,\"maximum\":604800}}"
    private static func appConfigDefaults() -> [String: Any] {
        ["enabled": true, "threshold_bytes": 65536, "interval_seconds": 3600]
    }

    private func appConfigReply(agentId: String, appId: String) -> HTTPReply? {
        guard appId == "system.cleaner" else { return nil }
        lock.lock()
        let revision = appConfigRevisions[agentId]?[appId] ?? 0
        let overrides = appConfigOverrides[agentId]?[appId] ?? [:]
        lock.unlock()
        var effective = Self.appConfigDefaults()
        for (key, value) in overrides {
            effective[key] = value
        }
        let order = ["enabled", "threshold_bytes", "interval_seconds"]
        var overridesJSON: [String] = []
        for key in order {
            guard let value = overrides[key] else { continue }
            overridesJSON.append("\(jsonString(key)):\(Self.appConfigValueJSON(value))")
        }
        var effectiveJSON: [String] = []
        for key in order {
            guard let value = effective[key] else { continue }
            effectiveJSON.append("\(jsonString(key)):\(Self.appConfigValueJSON(value))")
        }
        let body = "{\"appId\":\(jsonString(appId)),\"revision\":\(revision),\"schema\":\(Self.appConfigSchemaJSON),\"defaults\":{\"enabled\":true,\"threshold_bytes\":65536,\"interval_seconds\":3600},\"overrides\":{\(overridesJSON.joined(separator: ","))},\"effective\":{\(effectiveJSON.joined(separator: ","))}}"
        return Self.json(200, body)
    }

    private static func appConfigValueJSON(_ value: Any) -> String {
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let number = value as? NSNumber { return String(number.intValue) }
        if let string = value as? String { return jsonString(string) }
        return "null"
    }

    private func appConfigError(_ status: Int, error: String, code: String) -> HTTPReply {
        Self.json(status, "{\"error\":\(jsonString(error)),\"errorCode\":\(jsonString(code))}")
    }

    private func featureFlagEnabledForServer(_ key: String, serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let flag = featureFlagRecords[key], flag.enabled, !flag.killSwitch else { return false }
        let rules = featureFlagRuleRecords
            .filter { $0.key == key && $0.stage == "server" && $0.values.contains(serverId) }
            .sorted { $0.priority < $1.priority }
        if let rule = rules.first {
            return rule.decision == "allow"
        }
        return flag.defaultEnabled
    }

    private var marketplaceReviewerOverride: Set<String>?

    public func setMarketplaceReviewerIdsForTesting(_ ids: Set<String>?) {
        lock.lock()
        marketplaceReviewerOverride = ids
        lock.unlock()
    }

    private func marketplaceReviewerIds() -> Set<String> {
        lock.lock()
        let override = marketplaceReviewerOverride
        lock.unlock()
        if let override { return override }
        let raw = ProcessInfo.processInfo.environment["SLOCK_MARKETPLACE_REVIEWER_USER_IDS"] ?? ""
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public func integrationMarketplace(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let reviewers = marketplaceReviewerIds()
        let rows = oauth.appPermissionReviewRows(serverId: serverId).map { row -> String in
            let groups = row.pendingGroups.map { jsonString($0) }.joined(separator: ",")
            let revision = row.pendingRevisionId.map(jsonString) ?? "null"
            return "{\"id\":\(jsonString(row.id)),\"clientId\":\(jsonString(row.clientId)),\"name\":\(jsonString(row.name)),\"appNotificationPendingGroups\":[\(groups)],\"appNotificationPendingRevisionId\":\(revision),\"canReviewAppNotifications\":\(reviewers.contains(userId))}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func reviewAppNotificationPermissions(
        authorization: String?,
        serverId: String,
        clientId: String,
        body: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let raw = object["expected_revision_id"] as? String,
              ServerScope.isUUID(raw)
        else {
            return Self.json(400, "{\"error\":\"expected_revision_id must be a revision UUID\",\"code\":\"invalid_expected_revision_id\"}")
        }
        do {
            let groups = try oauth.approveAppOutboundPermission(clientRecordId: clientId, expectedRevisionId: raw)
            let groupsJSON = groups.map { jsonString($0) }.joined(separator: ",")
            return Self.json(200, "{\"ok\":true,\"groups\":[\(groupsJSON)]}")
        } catch OAuthLedger.AppPermissionReviewError.notFound {
            return Self.json(404, "{\"error\":\"App not found\"}")
        } catch {
            return Self.json(409, "{\"error\":\"The permission request changed since it was displayed\",\"code\":\"permission_revision_stale\"}")
        }
    }

    /// `GET /api/integrations/clients/:clientId/agent-jwt`. Read-only state for
    /// web bundles from the previous release.
    public func legacyAppAgentJWTSettings(authorization: String?, serverId: String, clientRecordId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else {
            var reply = Self.json(403, "{\"error\":\"Only server owners and admins can read Agent JWT access\"}")
            reply.headers["Cache-Control"] = "private, no-store"
            return reply
        }
        guard let client = oauth.legacyAgentJWTClient(clientRecordId: clientRecordId) else {
            var reply = Self.json(404, "{\"error\":\"App not found on this Server\"}")
            reply.headers["Cache-Control"] = "private, no-store"
            return reply
        }
        let source = client.serverId == serverId
        let installationStatus = oauth.legacyAgentJWTInstallationStatus(clientRecordId: clientRecordId, serverId: serverId)
        if !source, client.appType != "third_party_global" || installationStatus == nil {
            var reply = Self.json(404, "{\"error\":\"App not found on this Server\"}")
            reply.headers["Cache-Control"] = "private, no-store"
            return reply
        }
        let scopesOK = client.allowedScopes.contains("openid") && client.allowedScopes.contains("profile")
        let installationOK = installationStatus == nil || installationStatus == "active"
        let effective = client.enabled && scopesOK && installationOK
            && (client.appType == "server_local" || installationStatus == "active")
        let scopeValue = source ? "app" : "installation"
        let body = "{\"scope\":\(jsonString(scopeValue)),\"enabled\":true,\"appEnabled\":true,\"effectiveEnabled\":\(effective),\"canEnable\":false,\"audience\":\(jsonString(client.clientKey)),\"expiresIn\":300}"
        var reply = Self.json(200, body)
        reply.headers["Cache-Control"] = "private, no-store"
        return reply
    }

    public func refuseLegacyAppAgentJWTWrite() -> HTTPReply {
        var reply = Self.json(410, "{\"error\":\"Agent JWT is built in for every App; there is no setting to change\"}")
        reply.headers["Cache-Control"] = "private, no-store"
        return reply
    }

    public func agentContext(authorization: String?) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil,
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard credential.scopes.contains("read") else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"read\"}")
        }
        guard let server = oauth.serverProfile(id: agent.serverId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        let role = oauth.agentRole(serverId: agent.serverId, agentId: agent.id) ?? "member"
        let external = agent.runtime == "external"
        let capabilities = credential.scopes.sorted().map { jsonString($0) }.joined(separator: ",")
        let description = agent.description.map { jsonString($0) } ?? "null"
        let prompt: String
        if external {
            let displayName = agent.displayName
            let text = """
            # Raft CLI operating guide

            You are "\(displayName)" (@\(agent.name)), an external AI agent in the Raft server "\(server.name)".

            Your server role is \(role). Permission checks always use your current role.

            Initial role: \(agent.description ?? "No initial role was provided.").

            reminders_unsupported_for_external_agents — external agents cannot create reminders; ask a human instead.
            """
            prompt = "{\"audience\":\"self-hosted-runner\",\"text\":\(jsonString(text))}"
        } else {
            prompt = "null"
        }
        let features = "{\"reminderApp\":\(featureFlagEnabledForServer("reminder_app", serverId: server.id)),\"vaultApp\":\(featureFlagEnabledForServer("vault_app", serverId: server.id))}"
        let body = "{\"agent\":{\"id\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"description\":\(description),\"runtime\":\(jsonString(agent.runtime)),\"external\":\(external),\"assistantOf\":null,\"serverRole\":\(jsonString(role))},\"server\":{\"id\":\(jsonString(server.id)),\"slug\":\(jsonString(server.slug)),\"name\":\(jsonString(server.name))},\"credential\":{\"capabilities\":[\(capabilities)]},\"prompt\":\(prompt),\"features\":\(features)}"
        return Self.json(200, body)
    }

    public func agentAppConfig(authorization: String?, appId: String) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let reply = appConfigReply(agentId: identity.agentId, appId: appId) else {
            return appConfigError(404, error: "Unknown app", code: "RAP_APP_CONFIG_APP_UNKNOWN")
        }
        return reply
    }

    public func patchAgentAppConfig(authorization: String?, appId: String, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, credential.revokedAt == nil,
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard credential.scopes.contains("tasks") else {
            return Self.json(403, "{\"error\":\"missing required capability\",\"requiredCapability\":\"tasks\"}")
        }
        guard appId == "system.cleaner" else {
            return appConfigError(404, error: "Unknown app", code: "RAP_APP_CONFIG_APP_UNKNOWN")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let expectedRevision = object["expectedRevision"] as? NSNumber
        else {
            return Self.json(400, "{\"error\":\"Invalid config request\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
        }
        let set = object["set"] as? [String: Any] ?? [:]
        let unset = (object["unset"] as? [Any])?.compactMap { $0 as? String } ?? []
        for (key, value) in set {
            switch key {
            case "enabled":
                guard value is Bool || (value as? NSNumber).map({ String(cString: $0.objCType) == "c" || String(cString: $0.objCType) == "B" }) == true else {
                    return Self.json(400, "{\"error\":\"Invalid value for enabled\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
                }
            case "threshold_bytes", "interval_seconds":
                guard let number = value as? NSNumber,
                      String(cString: number.objCType) != "c", String(cString: number.objCType) != "B"
                else {
                    return Self.json(400, "{\"error\":\"Invalid value for \(key)\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
                }
                let intValue = number.intValue
                if key == "threshold_bytes", intValue < 4096 || intValue > 1_073_741_824 {
                    return Self.json(400, "{\"error\":\"Invalid value for threshold_bytes\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
                }
                if key == "interval_seconds", intValue < 900 || intValue > 604_800 {
                    return Self.json(400, "{\"error\":\"Invalid value for interval_seconds\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
                }
            default:
                return Self.json(400, "{\"error\":\"Unknown config key\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
            }
        }
        for key in unset where !["enabled", "threshold_bytes", "interval_seconds"].contains(key) {
            return Self.json(400, "{\"error\":\"Unknown config key\",\"errorCode\":\"RAP_APP_CONFIG_INVALID\"}")
        }
        lock.lock()
        let current = appConfigRevisions[agent.id]?[appId] ?? 0
        guard expectedRevision.intValue == current else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Config revision is stale; current revision is \(current)\",\"errorCode\":\"RAP_APP_CONFIG_REVISION_STALE\",\"currentRevision\":\(current)}")
        }
        var overrides = appConfigOverrides[agent.id]?[appId] ?? [:]
        for (key, value) in set { overrides[key] = value }
        for key in unset { overrides.removeValue(forKey: key) }
        appConfigOverrides[agent.id, default: [:]][appId] = overrides
        appConfigRevisions[agent.id, default: [:]][appId] = current + 1
        lock.unlock()
        return appConfigReply(agentId: agent.id, appId: appId) ?? appConfigError(404, error: "Unknown app", code: "RAP_APP_CONFIG_APP_UNKNOWN")
    }

    private enum DMPeerResolution {
        case resolved(peerId: String, peerKind: String, name: String)
        case ambiguous(String)
        case invalidKind(String, String)
        case notFound
    }

    /// Callers hold the directory lock.
    private func resolveDMPeerLocked(serverId: String, agentId: String, name rawName: String, kind rawKind: String?) -> DMPeerResolution {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = rawKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let kind, kind != "agent", kind != "human" {
            return .invalidKind(kind, name)
        }
        let humans = accounts.values.filter {
            $0.id != agentId
                && ($0.name.caseInsensitiveCompare(name) == .orderedSame
                    || ($0.displayName ?? "").caseInsensitiveCompare(name) == .orderedSame)
                && oauth.memberRole(serverId: serverId, userId: $0.id) != nil
        }.map(\.id)
        let agents = oauth.serverAgents(serverId: serverId)
            .filter { $0.id != agentId && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .map(\.id)
        switch kind {
        case "agent":
            guard let id = agents.first else { return .notFound }
            return .resolved(peerId: id, peerKind: "agent", name: name)
        case "human":
            guard let id = humans.first else { return .notFound }
            return .resolved(peerId: id, peerKind: "human", name: name)
        default:
            if !humans.isEmpty, !agents.isEmpty { return .ambiguous(name) }
            if let id = humans.first { return .resolved(peerId: id, peerKind: "human", name: name) }
            if let id = agents.first { return .resolved(peerId: id, peerKind: "agent", name: name) }
            return .notFound
        }
    }

    /// Callers hold the directory lock.
    private func dmChannelIdLocked(serverId: String, agentId: String, peerId: String) -> String? {
        postableChannels.first { _, channel in
            channel.serverId == serverId
                && channel.kind == "dm"
                && channel.deletedAt == nil
                && channel.memberIds.contains(agentId)
                && channel.memberIds.contains(peerId)
        }?.key
    }

    private func dmPeerFailure(_ resolution: DMPeerResolution) -> HTTPReply? {
        switch resolution {
        case .ambiguous(let name):
            return Self.json(409, "{\"error\":\"More than one DM peer is named \(name). Address it as dm:@\(name)~agent or dm:@\(name)~human.\",\"code\":\"DM_TARGET_AMBIGUOUS\",\"suggestedNextAction\":\"Retry with dm:@\(name)~agent for the agent or dm:@\(name)~human for the human.\"}")
        case .invalidKind(let kind, _):
            return Self.json(400, "{\"error\":\"Unknown DM peer kind \(kind).\",\"code\":\"DM_TARGET_INVALID_PEER_KIND\",\"suggestedNextAction\":\"Use dm:@<name>~human or dm:@<name>~agent.\"}")
        case .notFound:
            return Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
        case .resolved:
            return nil
        }
    }

    public func agentSendMessage(authorization: String?, body: String, v2: Bool) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "send") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let target = object["target"] as? String,
              let content = object["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid send request\"}")
        }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("dm:@") else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        var raw = String(trimmed.dropFirst("dm:@".count))
        var suffix: String?
        if let colon = raw.lastIndex(of: ":") {
            suffix = String(raw[raw.index(after: colon)...])
            raw = String(raw[..<colon])
        }
        if suffix != nil {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        var kind: String?
        if let tilde = raw.firstIndex(of: "~") {
            kind = String(raw[raw.index(after: tilde)...])
            raw = String(raw[..<tilde])
        }
        lock.lock()
        let resolution = resolveDMPeerLocked(serverId: identity.serverId, agentId: identity.agentId, name: raw, kind: kind)
        lock.unlock()
        if let failure = dmPeerFailure(resolution) { return failure }
        guard case .resolved(let peerId, _, _) = resolution else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let channelId: String
        lock.lock()
        let existing = dmChannelIdLocked(serverId: identity.serverId, agentId: identity.agentId, peerId: peerId)
        lock.unlock()
        if let existing {
            channelId = existing
        } else {
            channelId = oauth.createDirectChannel(serverId: identity.serverId, firstUserId: identity.agentId, secondUserId: peerId)
            addPostableChannel(serverId: identity.serverId, channelId: channelId, memberId: identity.agentId, kind: "dm", name: "dm")
            addPostableChannel(serverId: identity.serverId, channelId: channelId, memberId: peerId, kind: "dm", name: "dm")
            oauth.addChannelHuman(channelId: channelId, userId: peerId)
        }
        let messageId = UUID().uuidString.lowercased()
        lock.lock()
        humanMessageRows.append(StoredHumanMessage(
            id: messageId,
            channelId: channelId,
            senderId: identity.agentId,
            content: content,
            randomId: nil,
            messageType: "chat",
            senderType: "agent"
        ))
        lock.unlock()
        let message = "{\"id\":\(jsonString(messageId)),\"channelId\":\(jsonString(channelId)),\"content\":\(jsonString(content))}"
        return v2 ? Self.json(200, "{\"message\":\(message)}") : Self.json(200, message)
    }

    private enum AgentTaskAuthResult {
        case ok(agentId: String, serverId: String)
        case refused(HTTPReply)
    }

    private func agentTaskAuth(authorization: String?, legacyAgentId: String?) -> AgentTaskAuthResult {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .refused(Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}"))
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        let machine = machines.first { $0.apiKey == token }
        lock.unlock()
        if let credential, credential.revokedAt == nil {
            guard credential.scopes.contains("tasks") else {
                return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
            }
            guard let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
                return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
            }
            return .ok(agentId: agent.id, serverId: agent.serverId)
        }
        if let machine, let legacyAgentId,
           let agent = oauth.agentRuntimeInfo(id: legacyAgentId), !agent.deleted,
           agent.serverId == machine.serverId {
            return .ok(agentId: agent.id, serverId: agent.serverId)
        }
        return .refused(Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}"))
    }

    private func agentTaskChannel(serverId: String, agentId: String, reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if trimmed.hasPrefix("#") {
            let name = String(trimmed.dropFirst())
            for (id, channel) in postableChannels {
                guard channel.serverId == serverId, channel.name == name, channel.deletedAt == nil else { continue }
                guard channel.kind == "channel"
                    || channel.memberIds.contains(agentId)
                    || oauth.channelAgentIds(channelId: id).contains(agentId)
                else { continue }
                return id
            }
            return nil
        }
        guard postableChannels[trimmed]?.serverId == serverId else { return nil }
        return trimmed
    }

    public func agentTasksList(authorization: String?, legacyAgentId: String?, channelRef: String?) -> HTTPReply {
        let auth: (agentId: String, serverId: String)
        switch agentTaskAuth(authorization: authorization, legacyAgentId: legacyAgentId) {
        case .refused(let reply): return reply
        case .ok(let agentId, let serverId): auth = (agentId, serverId)
        }
        if let reply = agentGrantDenial(agentId: auth.agentId, scope: "task:read") { return reply }
        guard let channelRef,
              let channelId = agentTaskChannel(serverId: auth.serverId, agentId: auth.agentId, reference: channelRef)
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let rows = taskRecords.filter { $0.channelId == channelId }.map { task in
            "{\"id\":\(jsonString(task.id)),\"channelId\":\(jsonString(task.channelId)),\"title\":\(jsonString(task.title)),\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"tasks\":[\(rows)]}")
    }

    public func agentTasksCreate(authorization: String?, legacyAgentId: String?, body: String) -> HTTPReply {
        let auth: (agentId: String, serverId: String)
        switch agentTaskAuth(authorization: authorization, legacyAgentId: legacyAgentId) {
        case .refused(let reply): return reply
        case .ok(let agentId, let serverId): auth = (agentId, serverId)
        }
        if let reply = agentGrantDenial(agentId: auth.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: auth.serverId, agentId: auth.agentId, reference: channelRef),
              let rawTasks = object["tasks"] as? [[String: Any]]
        else {
            return Self.json(400, "{\"error\":\"Invalid task request\"}")
        }
        let titles = rawTasks.compactMap { task -> String? in
            let title = (task["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
        guard !titles.isEmpty, titles.count == rawTasks.count else {
            return Self.json(400, "{\"error\":\"Invalid task request\"}")
        }
        let ids = addTasks(channelId: channelId, titles: titles)
        let idsJSON = ids.map { jsonString($0) }.joined(separator: ",")
        return Self.json(200, "{\"taskIds\":[\(idsJSON)]}")
    }

    private var agentInboxAvailableForTesting: Bool?
    private var removedServerMembers: Set<String> = []

    public func setAgentInboxAvailableForTesting(_ value: Bool?) {
        lock.lock()
        agentInboxAvailableForTesting = value
        lock.unlock()
    }

    private struct AgentInboxRow {
        var target: String
        var kind: String
        var lastReadSeq: Int
        var unread: Int
        var mentions: Int
        var latestSeq: Int
        var activitySeq: Int
        var latestSenderName: String
        var latestAt: Date?
        var joinedAt: Date
    }

    private static func isoMillis(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// `GET /internal/agent-api/inbox/conversations`.
    public func agentInboxConversations(
        authorization: String?,
        limit rawLimit: String?,
        beforeSeq rawBefore: String?,
        view rawView: String?
    ) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        lock.lock()
        let available = agentInboxAvailableForTesting ?? true
        lock.unlock()
        guard available else {
            return Self.json(503, "{\"error\":\"The agent inbox is unavailable\",\"code\":\"INBOX_UNAVAILABLE\",\"suggestedNextAction\":\"Retry after the inbox service recovers.\"}")
        }
        let view = rawView ?? "unread"
        guard view == "unread" || view == "mentions" else {
            return Self.json(400, "{\"error\":\"view must be unread or mentions\"}")
        }
        let limit: Int
        if let rawLimit, !rawLimit.isEmpty {
            guard let parsed = Int(rawLimit), parsed >= 1, parsed <= 100 else {
                return Self.json(400, "{\"error\":\"limit must be between 1 and 100\"}")
            }
            limit = parsed
        } else {
            limit = 20
        }
        var before: Int?
        if let rawBefore, !rawBefore.isEmpty {
            guard let parsed = Int(rawBefore), parsed > 0 else {
                return Self.json(400, "{\"error\":\"before_seq must be a positive integer\"}")
            }
            before = parsed
        }
        lock.lock()
        let serverId = identity.serverId
        let agentId = identity.agentId
        var rows: [AgentInboxRow] = []

        func latestMessage(_ storageChannelId: String) -> (seq: Int, message: StoredHumanMessage?) {
            let messages = humanMessageRows.filter { $0.channelId == storageChannelId }
            guard let last = messages.last else { return (0, nil) }
            let global = (humanMessageRows.firstIndex { $0.id == last.id } ?? 0) + 1
            return (global, last)
        }
        func senderName(_ message: StoredHumanMessage?) -> String? {
            guard let message else { return nil }
            if let external = message.externalSenderName { return external }
            if message.senderId == "system" { return "system" }
            return accounts.values.first { $0.id == message.senderId }?.name
                ?? oauth.agentRuntimeInfo(id: message.senderId)?.name
        }
        func mentionStats(channelId: String) -> (count: Int, maxSeq: Int?) {
            let ids = Set(storedMentions.filter {
                $0.targetType == "agent" && $0.targetId == agentId && $0.channelId == channelId
            }.map(\.messageId))
            guard !ids.isEmpty else { return (0, nil) }
            let messages = humanMessageRows.filter { $0.channelId == channelId }
            var maxSeq: Int?
            for (index, message) in messages.enumerated() where ids.contains(message.id) {
                maxSeq = index + 1
            }
            return (ids.count, maxSeq)
        }

        // Channel and DM rows.
        for (id, channel) in postableChannels {
            guard channel.serverId == serverId, channel.deletedAt == nil else { continue }
            let visible = channel.kind == "channel"
                || channel.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: id).contains(agentId)
            guard visible else { continue }
            var target: String
            var kind: String
            if channel.kind == "dm" {
                let peer = channel.memberIds.compactMap { member -> (String, String)? in
                    guard member != agentId,
                          let account = accounts.values.first(where: { $0.id == member }),
                          oauth.memberRole(serverId: serverId, userId: member) != nil
                    else { return nil }
                    return (member, account.name)
                }.first
                guard let peer else { continue }
                target = "dm:@\(peer.1)"
                kind = "dm"
            } else if channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint" {
                target = "#\(channel.name)"
                kind = "channel"
            } else {
                continue
            }
            let storage = jointProjections.first { $0.localChannelId == id }?.canonicalChannelId ?? id
            let latest = latestMessage(storage)
            guard latest.seq > 0 else { continue }
            let cursor = agentChannelReadCursors["\(id)\n\(agentId)"]?.seq ?? 0
            let unread = humanMessageRows.filter { $0.channelId == storage }.enumerated().filter { index, message in
                index + 1 > cursor && message.senderId != agentId
            }.count
            let mentions = mentionStats(channelId: storage)
            rows.append(AgentInboxRow(
                target: target,
                kind: kind,
                lastReadSeq: cursor,
                unread: unread,
                mentions: mentions.count,
                latestSeq: latest.seq,
                activitySeq: latest.seq,
                latestSenderName: senderName(latest.message) ?? "",
                latestAt: latest.message?.createdAt,
                joinedAt: latest.message?.createdAt ?? Date()
            ))
        }

        // Followed thread rows.
        for follow in threadFollows.values where follow.userId == agentId && follow.serverId == serverId {
            guard let thread = postableChannels[follow.threadChannelId], thread.deletedAt == nil,
                  let parentId = thread.parentChannelId,
                  let parent = postableChannels[parentId], parent.deletedAt == nil
            else { continue }
            let visible = thread.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: follow.threadChannelId).contains(agentId)
                || parent.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: parentId).contains(agentId)
            guard visible else { continue }
            let storage = jointProjections.first { $0.localChannelId == follow.threadChannelId }?.canonicalChannelId ?? follow.threadChannelId
            let latest = latestMessage(storage)
            guard latest.seq > 0 else { continue }
            let cursor = agentChannelReadCursors["\(follow.threadChannelId)\n\(agentId)"]?.seq ?? 0
            let unread = humanMessageRows.filter { $0.channelId == storage }.enumerated().filter { index, message in
                index + 1 > cursor && message.senderId != agentId
            }.count
            let mentions = mentionStats(channelId: storage)
            let parentShort = String((thread.parentMessageId ?? "").prefix(8))
            let target: String
            if parent.kind == "dm" {
                let peer = parent.memberIds.compactMap { member -> String? in
                    guard member != agentId,
                          let account = accounts.values.first(where: { $0.id == member }),
                          oauth.memberRole(serverId: serverId, userId: member) != nil
                    else { return nil }
                    return account.name
                }.first ?? "unknown"
                target = "dm:@\(peer):\(parentShort)"
            } else {
                target = "#\(parent.name):\(parentShort)"
            }
            rows.append(AgentInboxRow(
                target: target,
                kind: "thread",
                lastReadSeq: cursor,
                unread: unread,
                mentions: mentions.count,
                latestSeq: latest.seq,
                activitySeq: latest.seq,
                latestSenderName: senderName(latest.message) ?? "",
                latestAt: latest.message?.createdAt,
                joinedAt: threadFollowStarts["\(serverId)\n\(agentId)\n\(follow.threadChannelId)"] ?? Date()
            ))
        }
        lock.unlock()

        let totals = (
            conversations: rows.count,
            dms: rows.filter { $0.kind == "dm" }.count,
            mentions: rows.filter { $0.mentions > 0 }.count
        )
        var filtered = rows
        if view == "mentions" {
            filtered = filtered.filter { $0.mentions > 0 }
        } else {
            filtered = filtered.filter { $0.unread > 0 || $0.mentions > 0 }
        }
        if let before {
            filtered = filtered.filter { $0.activitySeq < before }
        }
        filtered.sort { left, right in
            if left.activitySeq != right.activitySeq { return left.activitySeq > right.activitySeq }
            return left.target < right.target
        }
        let hasMore = filtered.count > limit
        let page = Array(filtered.prefix(limit))
        let nextBefore = hasMore ? page.last?.activitySeq : nil
        let items = page.map { row -> String in
            let latestAt = row.latestAt.map { jsonString(Self.isoMillis($0)) } ?? "null"
            return "{\"target\":\(jsonString(row.target)),\"kind\":\(jsonString(row.kind)),\"unread\":\(row.unread),\"mentions\":\(row.mentions),\"lastReadSeq\":\(row.lastReadSeq),\"activitySeq\":\(row.activitySeq),\"latestSenderName\":\(jsonString(row.latestSenderName)),\"latestAt\":\(latestAt)}"
        }.joined(separator: ",")
        let nextJSON = nextBefore.map(String.init) ?? "null"
        return Self.json(200, "{\"view\":\(jsonString(view)),\"items\":[\(items)],\"totals\":{\"conversations\":\(totals.conversations),\"dms\":\(totals.dms),\"mentions\":\(totals.mentions)},\"hasMore\":\(hasMore),\"nextBeforeSeq\":\(nextJSON)}")
    }

    private func agentHistoryThread(parentId: String, anchorMessageId: String) -> String? {
        for (id, channel) in postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard channel.parentMessageId == anchorMessageId else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }

    private func agentHistoryThreadById(parentId: String, suffix: String) -> String? {
        for (id, channel) in postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard id.hasPrefix(suffix) else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }

    private func agentHistoryThreadByAnchorPrefix(parentId: String, suffix: String) -> String? {
        for (id, channel) in postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard channel.parentMessageId?.hasPrefix(suffix) == true else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }

    private func actionCardTarget(serverId: String, agentId: String, target: String) -> (local: String, storage: String)? {
        guard target.hasPrefix("#") else { return nil }
        let name = String(target.dropFirst())
        lock.lock()
        var local: String?
        for (id, channel) in postableChannels {
            guard channel.serverId == serverId, channel.name == name, channel.deletedAt == nil,
                  channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint"
            else { continue }
            if channel.kind != "channel",
               !channel.memberIds.contains(agentId),
               !oauth.channelAgentIds(channelId: id).contains(agentId) {
                continue
            }
            local = id
            break
        }
        let storage = local.flatMap { id in jointProjections.first { $0.localChannelId == id }?.canonicalChannelId } ?? local
        lock.unlock()
        guard let local, let storage else { return nil }
        return (local, storage)
    }

    public func prepareActionCard(authorization: String?, body: String) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "send") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let target = object["target"] as? String,
              let action = object["action"] as? [String: Any],
              (action["type"] as? String) == "channel:create",
              let channelName = action["name"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid action card request\",\"code\":\"INVALID_PAYLOAD\"}")
        }
        let trimmedName = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 64 else {
            return Self.json(400, "{\"error\":\"Invalid channel name\",\"code\":\"INVALID_PAYLOAD\"}")
        }
        let visibility = (action["visibility"] as? String) == "private" ? "private" : "channel"
        guard let resolved = actionCardTarget(serverId: identity.serverId, agentId: identity.agentId, target: target) else {
            return Self.json(404, "{\"error\":\"Target channel not found\",\"code\":\"TARGET_NOT_FOUND\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: identity.agentId) else {
            return Self.json(404, "{\"error\":\"Requester agent not found\",\"code\":\"AGENT_NOT_FOUND\"}")
        }
        let messageId = UUID().uuidString.lowercased()
        let content = "@\(agent.name) proposed creating channel #\(trimmedName)"
        lock.lock()
        humanMessageRows.append(StoredHumanMessage(
            id: messageId,
            channelId: resolved.storage,
            senderId: identity.agentId,
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "agent",
            actionKind: "action-card"
        ))
        actionCardRecords[messageId] = ActionCardRecord(
            messageId: messageId,
            serverId: identity.serverId,
            requesterAgentId: identity.agentId,
            storageChannelId: resolved.storage,
            localCarrierChannelId: resolved.local,
            actionType: "channel:create",
            channelName: trimmedName,
            visibility: visibility,
            state: "prepared",
            executedByUserId: nil
        )
        lock.unlock()
        let metadata = "{\"kind\":\"action-card\",\"state\":\"prepared\",\"action\":{\"type\":\"channel:create\",\"name\":\(jsonString(trimmedName)),\"visibility\":\(jsonString(visibility))},\"carrierChannelId\":\(jsonString(resolved.storage))}"
        return Self.json(201, "{\"messageId\":\(jsonString(messageId)),\"metadata\":\(metadata)}")
    }

    private func actionCardServerName(_ serverId: String) -> String {
        oauth.serverProfile(id: serverId)?.name ?? "this Server"
    }

    /// Writes the durable result reply into the card's thread, records the
    /// preparer's unread mention fact, and queues the external-agent event.
    private func postActionCardReply(
        card: ActionCardRecord,
        confirmerUserId: String,
        success: Bool,
        resultName: String?,
        failureReason: String?
    ) {
        guard let requester = oauth.agentRuntimeInfo(id: card.requesterAgentId) else { return }
        lock.lock()
        let confirmer = accounts.values.first { $0.id == confirmerUserId }
        let confirmerHandle = confirmer?.name ?? "a human"
        let serverName = oauth.serverProfile(id: card.serverId)?.name ?? "this Server"
        let storageServerId = postableChannels[card.storageChannelId]?.serverId ?? card.serverId
        var canonicalThread = postableChannels.first { _, channel in
            channel.kind == "thread"
                && channel.parentChannelId == card.storageChannelId
                && channel.parentMessageId == card.messageId
        }?.key
        var createdThread = false
        if canonicalThread == nil {
            let threadId = oauth.createThreadChannel(parentChannelId: card.storageChannelId, parentMessageId: card.messageId)
            var thread = postableChannels[threadId] ?? PostableChannel(serverId: storageServerId, memberIds: [])
            thread.serverId = storageServerId
            thread.kind = "thread"
            thread.parentChannelId = card.storageChannelId
            thread.parentMessageId = card.messageId
            thread.name = "thread"
            thread.memberIds.insert(card.requesterAgentId)
            thread.memberIds.insert(confirmerUserId)
            if let parentMembers = postableChannels[card.storageChannelId]?.memberIds {
                thread.memberIds.formUnion(parentMembers)
            }
            postableChannels[threadId] = thread
            canonicalThread = threadId
            createdThread = true
        }
        guard let threadId = canonicalThread else {
            lock.unlock()
            return
        }
        // Give each Joint projection its own thread row pointing at the
        // canonical thread, so either human surface can read the reply.
        for link in jointProjections where link.canonicalChannelId == card.storageChannelId {
            let existing = postableChannels.first { _, channel in
                channel.kind == "thread" && channel.parentChannelId == link.localChannelId && channel.parentMessageId == card.messageId
            }?.key
            let localThreadId: String
            if let existing {
                localThreadId = existing
            } else {
                let created = oauth.createThreadChannel(parentChannelId: link.localChannelId, parentMessageId: card.messageId)
                var thread = postableChannels[created] ?? PostableChannel(serverId: link.serverId, memberIds: [])
                thread.serverId = link.serverId
                thread.kind = "thread"
                thread.parentChannelId = link.localChannelId
                thread.parentMessageId = card.messageId
                thread.name = "thread"
                thread.memberIds.insert(card.requesterAgentId)
                thread.memberIds.insert(confirmerUserId)
                if let parentMembers = postableChannels[link.localChannelId]?.memberIds {
                    thread.memberIds.formUnion(parentMembers)
                }
                postableChannels[created] = thread
                jointProjections.append(JointChannelLink(localChannelId: created, canonicalChannelId: threadId, serverId: link.serverId))
                localThreadId = created
            }
            if localThreadId != threadId {
                postableChannels[localThreadId]?.memberIds.insert(card.requesterAgentId)
                postableChannels[localThreadId]?.memberIds.insert(confirmerUserId)
            }
        }
        _ = createdThread
        let cardRef = "\(card.messageId.prefix(8))"
        let content: String
        if success {
            content = [
                "@\(requester.name) your action card `\(cardRef)` (creating channel #\(card.channelName ?? "")) was executed by @\(confirmerHandle) on \(serverName), acting with @\(confirmerHandle)'s permissions.",
                resultName.map { "Result: created channel #\($0)." },
            ].compactMap { $0 }.joined(separator: "\n")
        } else {
            content = "@\(requester.name) your action card `\(cardRef)` (creating channel #\(card.channelName ?? "")) failed when @\(confirmerHandle) tried to execute it on \(serverName): \(failureReason ?? "the action could not be completed"). The card is still pending and can be retried."
        }
        let replyId = UUID().uuidString.lowercased()
        humanMessageRows.append(StoredHumanMessage(
            id: replyId,
            channelId: threadId,
            senderId: "system",
            content: content,
            randomId: nil,
            messageType: "system",
            senderType: "system"
        ))
        storedInboxFacts.append(StoredInboxFact(
            messageId: replyId,
            receiverType: "agent",
            receiverId: card.requesterAgentId,
            channelId: threadId,
            serverId: card.serverId,
            personalMention: true,
            unreadEligible: true
        ))
        storedInboxFacts.append(StoredInboxFact(
            messageId: replyId,
            receiverType: "user",
            receiverId: confirmerUserId,
            channelId: threadId,
            serverId: card.serverId,
            personalMention: true,
            unreadEligible: false
        ))
        storedMentions.append(StoredMention(
            id: UUID().uuidString.lowercased(),
            messageId: replyId,
            channelId: threadId,
            senderId: "system",
            targetType: "agent",
            targetId: card.requesterAgentId,
            handle: requester.name,
            notifiableAtSend: true,
            notifiedAt: nil,
            notifiedByType: nil,
            notifiedById: nil,
            notifiedAction: nil
        ))
        if requester.runtime == "external" {
            pendingActionMessageEvents.append((card.requesterAgentId, replyId, content))
        }
        lock.unlock()
        emitRealtime("channel:\(threadId)", "message:new", "{\"id\":\(jsonString(replyId)),\"channelId\":\(jsonString(threadId)),\"content\":\(jsonString(content))}")
    }

    public func executeActionCard(authorization: String?, serverId: String, messageId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        let card = actionCardRecords[messageId]
        lock.unlock()
        guard let card else {
            return Self.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
        }
        guard oauth.memberRole(serverId: card.serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        if let expected = object?["expectedState"] as? String, expected == "executed", card.state != "executed" {
            return Self.json(409, "{\"error\":\"The action card is not executed\",\"code\":\"STATE_MISMATCH\"}")
        }
        if card.state == "executed" {
            return Self.json(200, "{\"messageId\":\(jsonString(messageId)),\"metadata\":{\"kind\":\"action-card\",\"state\":\"executed\"}}")
        }
        let name = card.channelName ?? ""
        lock.lock()
        let duplicate = postableChannels.values.contains {
            $0.serverId == card.serverId && $0.name == name && $0.deletedAt == nil
                && ($0.kind == "channel" || $0.kind == "private")
        }
        lock.unlock()
        if duplicate {
            let reason = "a channel named #\(name) already exists"
            postActionCardReply(card: card, confirmerUserId: userId, success: false, resultName: nil, failureReason: reason)
            return Self.json(409, "{\"error\":\"\(reason)\",\"code\":\"ACTION_FAILED\",\"reason\":\(jsonString(reason))}")
        }
        let channelId = oauth.createChannel(
            serverId: card.serverId,
            name: name,
            creatorUserId: userId,
            type: card.visibility == "private" ? "private" : "channel"
        )
        addPostableChannel(
            serverId: card.serverId,
            channelId: channelId,
            memberId: userId,
            kind: card.visibility == "private" ? "private" : "channel",
            name: name
        )
        addPostableChannel(serverId: card.serverId, channelId: channelId, memberId: card.requesterAgentId, kind: card.visibility == "private" ? "private" : "channel", name: name)
        oauth.addChannelHuman(channelId: channelId, userId: userId)
        oauth.addChannelAgent(channelId: channelId, agentId: card.requesterAgentId)
        lock.lock()
        if var updated = actionCardRecords[messageId] {
            updated.state = "executed"
            updated.executedByUserId = userId
            actionCardRecords[messageId] = updated
        }
        lock.unlock()
        postActionCardReply(card: card, confirmerUserId: userId, success: true, resultName: name, failureReason: nil)
        let metadata = "{\"kind\":\"action-card\",\"state\":\"executed\",\"action\":{\"type\":\"channel:create\",\"name\":\(jsonString(name))},\"result\":{\"kind\":\"channel\",\"id\":\(jsonString(channelId)),\"name\":\(jsonString(name))}}"
        return Self.json(200, "{\"messageId\":\(jsonString(messageId)),\"metadata\":\(metadata)}")
    }

    public func agentHistory(authorization: String?, agentId: String? = nil, channelRef: String?, before: String?, after: String?, around: String? = nil, limit: String?) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        let machine = machines.first { $0.apiKey == token }
        lock.unlock()
        let resolvedAgentId: String
        if let credential {
            guard credential.scopes.contains("read") else {
                return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
            }
            resolvedAgentId = credential.agentId
        } else if let machine, let requestedAgentId = agentId,
                  let candidate = oauth.agentRuntimeInfo(id: requestedAgentId),
                  !candidate.deleted,
                  candidate.serverId == machine.serverId {
            resolvedAgentId = requestedAgentId
        } else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: resolvedAgentId), !agent.deleted else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let reference = (channelRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else {
            return Self.json(400, "{\"error\":\"channel is required\"}")
        }
        if reference.hasPrefix("agent-event:") {
            let rawRef = String(reference.dropFirst("agent-event:".count))
            switch oauth.readThirdPartyAgentEventForAgent(agentId: agent.id, ref: rawRef) {
            case .ambiguous:
                return Self.json(409, "{\"error\":\"That 8-character event address matches more than one of your events. Use the full event id, printed as `event_id:` in the event body.\",\"errorCode\":\"AMBIGUOUS_ID\",\"suggestedNextAction\":\"raft message read --target 'agent-event:<full-event-id>'\"}")
            case .expired:
                return Self.json(410, "{\"error\":\"This third-party event has expired and its payload is no longer retained.\",\"errorCode\":\"EXPIRED\"}")
            case .absent:
                return Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
            case .found(let message):
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let id = jsonString(message.id)
                let external = message.externalEventId.map(jsonString) ?? "null"
                let payload = message.payloadJSON.isEmpty ? "{}" : message.payloadJSON
                let row = "{\"id\":\(id),\"content\":\(jsonString(message.content)),\"seq\":1,\"senderType\":\"third_party_app\",\"senderId\":\(jsonString(message.clientKey)),\"senderName\":\(jsonString(message.clientName)),\"createdAt\":\(jsonString(formatter.string(from: message.createdAt))),\"attachments\":[],\"third_party_event\":{\"id\":\(id),\"kind\":\(jsonString(message.kind)),\"client_id\":\(jsonString(message.clientKey)),\"client_name\":\(jsonString(message.clientName)),\"external_event_id\":\(external),\"payload_hash\":\(jsonString(message.payloadHash)),\"payload\":\(payload),\"expires_at\":\(jsonString(formatter.string(from: message.expiresAt)))}}"
                return Self.json(200, "{\"messages\":[\(row)],\"has_more\":false,\"has_older\":false,\"has_newer\":false}")
            }
        }
        lock.lock()
        var channelId: String?
        var canonicalTarget: String?
        var consumptionScope: String?
        var refusal: HTTPReply?
        if reference.hasPrefix("#") {
            let raw = String(reference.dropFirst())
            let segments = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = segments.first ?? raw
            let suffix = segments.count > 1 ? segments[1] : nil
            var parentId: String?
            let candidates = postableChannels.filter { _, channel in
                channel.serverId == agent.serverId
                    && channel.name == name
                    && channel.deletedAt == nil
                    && (channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint")
            }
            for (id, channel) in candidates {
                if channel.kind == "channel" {
                    parentId = id
                    break
                }
                if channel.memberIds.contains(agent.id) {
                    parentId = id
                    break
                }
                if oauth.channelAgentIds(channelId: id).contains(agent.id) {
                    parentId = id
                    break
                }
            }
            if let parentId {
                if let suffix, !suffix.isEmpty {
                    let anchor = oauth.historyMessages(channelId: parentId).first { $0.id.hasPrefix(suffix) }
                    var threadId: String?
                    if let anchor {
                        threadId = agentHistoryThread(parentId: parentId, anchorMessageId: anchor.id)
                        if threadId == nil {
                            let nextAction = "raft message read --target '#\(name)' --around \(suffix)"
                            refusal = Self.json(404, "{\"error\":\"There is no thread on message \(suffix) in #\(name)\",\"suggestedNextAction\":\(jsonString(nextAction))}")
                        }
                    } else {
                        threadId = agentHistoryThreadById(parentId: parentId, suffix: suffix)
                        if threadId == nil {
                            threadId = agentHistoryThreadByAnchorPrefix(parentId: parentId, suffix: suffix)
                        }
                        if threadId == nil {
                            refusal = Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
                        }
                    }
                    if let threadId, let thread = postableChannels[threadId] {
                        channelId = threadId
                        let anchorShort = thread.parentMessageId.map { String($0.prefix(8)) } ?? suffix
                        canonicalTarget = "#\(name):\(anchorShort)"
                    }
                } else {
                    channelId = parentId
                    canonicalTarget = "#\(name)"
                }
            } else {
                refusal = Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
            }
        } else if reference.hasPrefix("dm:@") {
            var raw = String(reference.dropFirst("dm:@".count))
            var suffix: String?
            if let colon = raw.lastIndex(of: ":") {
                suffix = String(raw[raw.index(after: colon)...])
                raw = String(raw[..<colon])
            }
            var kind: String?
            if let tilde = raw.firstIndex(of: "~") {
                kind = String(raw[raw.index(after: tilde)...])
                raw = String(raw[..<tilde])
            }
            let resolution = resolveDMPeerLocked(serverId: agent.serverId, agentId: agent.id, name: raw, kind: kind)
            if let failure = dmPeerFailure(resolution) {
                refusal = failure
            } else if case .resolved(let peerId, _, _) = resolution {
                if let dmId = dmChannelIdLocked(serverId: agent.serverId, agentId: agent.id, peerId: peerId) {
                    if let suffix, !suffix.isEmpty {
                        let anchor = oauth.historyMessages(channelId: dmId).first { $0.id.hasPrefix(suffix) }
                        var threadId = anchor.flatMap { found in
                            agentHistoryThread(parentId: dmId, anchorMessageId: found.id)
                        }
                        if threadId == nil {
                            threadId = agentHistoryThreadById(parentId: dmId, suffix: suffix)
                        }
                        if let threadId {
                            channelId = threadId
                            canonicalTarget = reference
                            consumptionScope = "{\"agent_id\":\(jsonString(agent.id)),\"channel_id\":\(jsonString(threadId)),\"channel_type\":\"thread\",\"target\":\(jsonString(reference))}"
                        } else {
                            refusal = Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
                        }
                    } else {
                        channelId = dmId
                        canonicalTarget = reference
                        consumptionScope = "{\"agent_id\":\(jsonString(agent.id)),\"channel_id\":\(jsonString(dmId)),\"channel_type\":\"dm\",\"target\":\(jsonString(reference))}"
                    }
                } else {
                    refusal = Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
                }
            }
        } else {
            channelId = postableChannels.keys.first { $0 == reference }
        }
        let visible = channelId.flatMap { id -> Bool? in
            guard let channel = postableChannels[id] else { return nil }
            if channel.kind == "dm" {
                return channel.memberIds.contains(agent.id)
            }
            if channel.kind == "thread", let parentId = channel.parentChannelId,
               let parent = postableChannels[parentId], parent.kind == "dm" {
                return parent.memberIds.contains(agent.id)
            }
            return channel.kind == "channel" || channel.memberIds.contains(agent.id) || oauth.channelAgentIds(channelId: id).contains(agent.id)
        } ?? false
        lock.unlock()
        if let refusal { return refusal }
        guard let channelId, visible else {
            return Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
        }
        let channelCard: String = {
            lock.lock()
            defer { lock.unlock() }
            guard let channel = postableChannels[channelId], channel.kind != "dm" else { return "" }
            let cardId: String
            if channel.kind == "thread", let parent = channel.parentChannelId {
                cardId = parent
            } else {
                cardId = channelId
            }
            guard let info = oauth.channelInfo(id: cardId) else { return "" }
            let type = oauth.channelType(id: cardId) ?? "channel"
            let archived = oauth.channelArchivedAt(id: cardId) != nil || postableChannels[cardId]?.archived == true
            let description = info.description.map(jsonString) ?? "null"
            return ",\"channel_card\":{\"id\":\(jsonString(cardId)),\"name\":\(jsonString(info.name)),\"type\":\(jsonString(type)),\"description\":\(description),\"archived\":\(archived)}"
        }()
        let messages = oauth.historyMessages(channelId: channelId)
        let pageLimit = min(max(Int(limit ?? "") ?? 20, 1), 100)
        let beforeSeq = Int(before ?? "")
        let afterSeq = Int(after ?? "")
        var filtered = messages
        if let beforeSeq { filtered = filtered.filter { $0.seq < beforeSeq } }
        if let afterSeq { filtered = filtered.filter { $0.seq > afterSeq } }
        let page: [OAuthLedger.HistoryMessage]
        if let around, !around.isEmpty {
            if let index = filtered.firstIndex(where: { $0.id.hasPrefix(around) || $0.id == around }) {
                let half = max(1, pageLimit / 2)
                let start = max(0, index - half)
                let end = min(filtered.count, start + pageLimit)
                page = Array(filtered[start..<end])
            } else {
                return Self.json(404, "{\"error\":\"Message not found\"}")
            }
        } else if afterSeq != nil {
            page = Array(filtered.prefix(pageLimit))
        } else {
            page = Array(filtered.suffix(pageLimit))
        }
        let firstSeq = page.first?.seq ?? 0
        let lastSeq = page.last?.seq ?? 0
        let hasOlder = afterSeq == nil && messages.contains { $0.seq < firstSeq }
        let hasNewer = messages.contains { $0.seq > lastSeq }
        let hasMore = hasOlder || (afterSeq != nil && hasNewer)
        let latestSeq = messages.last?.seq ?? 0
        lock.lock()
        let previous = agentChannelReadCursors["\(channelId)\n\(agent.id)"] ?? (seq: 0, version: 0)
        agentChannelReadCursors["\(channelId)\n\(agent.id)"] = (max(previous.seq, latestSeq), previous.version + (latestSeq > previous.seq ? 1 : 0))
        let readSeq = max(previous.seq, latestSeq)
        lock.unlock()
        if latestSeq > previous.seq {
            onAgentReadUpdated?(agent.serverId, channelId, agent.id, latestSeq)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let json = page.map { message -> String in
            let senderType = message.senderId == agent.id ? "agent" : "user"
            let senderName: String
            if senderType == "agent" {
                senderName = oauth.agentRuntimeInfo(id: message.senderId)?.name ?? message.senderId
            } else {
                lock.lock()
                senderName = accounts.values.first { $0.id == message.senderId }?.name ?? message.senderId
                lock.unlock()
            }
            return "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(channelId)),\"content\":\(jsonString(message.content)),\"seq\":\(message.seq),\"senderType\":\(jsonString(senderType)),\"senderId\":\(jsonString(message.senderId)),\"senderName\":\(jsonString(senderName)),\"createdAt\":\(jsonString(formatter.string(from: Date()))),\"attachments\":[]}"
        }.joined(separator: ",")
        return Self.json(200, "{\"messages\":[\("\(json)")],\"has_more\":\(hasMore),\"has_older\":\(hasOlder),\"has_newer\":\(hasNewer),\"last_read_seq\":\(readSeq),\"target\":\(jsonString(canonicalTarget ?? reference))\(consumptionScope.map { ",\"consumption_scope\":\($0)" } ?? "")\(channelCard)}")
    }

    public func agentChannelMembershipFromMachine(authorization: String?, agentId: String, channelId: String, join: Bool) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let machine = machines.first { $0.apiKey == apiKey }
        lock.unlock()
        guard let machine else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == machine.serverId else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        if join, let reply = agentGrantDenial(agentId: agent.id, scope: "channel:join") { return reply }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if join {
            oauth.addChannelAgent(channelId: channelId, agentId: agent.id)
        } else {
            oauth.removeChannelAgent(channelId: channelId, agentId: agent.id)
        }
        return Self.json(200, "{\"ok\":true}")
    }

    public func leaveChannel(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(userId)
        lock.unlock()
        _ = oauth.removeChannelHuman(channelId: channelId, userId: userId)
        return Self.json(200, "{\"ok\":true}")
    }

    public func agentLeaveChannel(authorization: String?, channelId: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == agent.serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        oauth.removeChannelAgent(channelId: channelId, agentId: agent.id)
        return Self.json(200, "{\"ok\":true}")
    }

    public func addChannelMembersBatch(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard role == "owner" || role == "admin" || oauth.isChannelParticipant(channelId: channelId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel members\"}")
        }
        let rawUserIds = (object["userIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        let rawAgentIds = (object["agentIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        var seenUsers = Set<String>()
        var seenAgents = Set<String>()
        let uniqueUserIds = rawUserIds.filter { seenUsers.insert($0).inserted }
        let invalidUserIds = uniqueUserIds.filter { oauth.memberRole(serverId: serverId, userId: $0) == nil }
        if !invalidUserIds.isEmpty {
            let invalid = invalidUserIds.map { jsonString($0) }.joined(separator: ",")
            return Self.json(400, "{\"error\":\"One or more users are not members of this server\",\"code\":\"users_not_in_server\",\"invalidUserIds\":[\(invalid)]}")
        }
        var addedUsers: [String] = []
        var addedAgents: [String] = []
        var alreadyUsers: [String] = []
        var alreadyAgents: [String] = []
        for target in uniqueUserIds {
            guard oauth.memberRole(serverId: serverId, userId: target) != nil else { continue }
            if oauth.channelHumanIds(channelId: channelId).contains(target) {
                alreadyUsers.append(target)
            } else {
                accountsForInvite(userId: target, serverId: serverId, channelId: channelId)
                addedUsers.append(target)
            }
        }
        for agentId in rawAgentIds where seenAgents.insert(agentId).inserted {
            guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else { continue }
            if oauth.channelAgentIds(channelId: channelId).contains(agentId) {
                alreadyAgents.append(agentId)
            } else {
                oauth.addChannelAgent(channelId: channelId, agentId: agentId)
                addedAgents.append(agentId)
            }
        }
        func array(_ values: [String]) -> String {
            values.map { jsonString($0) }.joined(separator: ",")
        }
        return Self.json(200, "{\"ok\":true,\"added\":{\"userIds\":[\("\(array(addedUsers))")],\"agentIds\":[\("\(array(addedAgents))")]},\"alreadyMembers\":{\"userIds\":[\("\(array(alreadyUsers))")],\"agentIds\":[\("\(array(alreadyAgents))")]}}")
    }

    private func accountsForInvite(userId: String, serverId: String, channelId: String) {
        lock.lock()
        postableChannels[channelId, default: PostableChannel(serverId: serverId, memberIds: [])].memberIds.insert(userId)
        lock.unlock()
        oauth.addChannelHuman(channelId: channelId, userId: userId)
    }

    public func createThreadFromChannel(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let parentMessageId = object["parentMessageId"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid thread request\"}")
        }
        lock.lock()
        if let existing = postableChannels.first(where: { _, candidate in
            candidate.serverId == serverId && candidate.kind == "thread"
                && candidate.parentChannelId == channelId && candidate.parentMessageId == parentMessageId
                && candidate.deletedAt == nil
        }) {
            let replies = humanMessageRows.filter { $0.channelId == existing.key }
            let participants = Array(Set(replies.map(\.senderId))).sorted()
            lock.unlock()
            let participantJSON = participants.map { jsonString($0) }.joined(separator: ",")
            return Self.json(200, "{\"threadChannelId\":\(jsonString(existing.key)),\"replyCount\":\(replies.count),\"lastReplyAt\":\(replies.last.map { jsonString(ISO8601DateFormatter().string(from: $0.createdAt)) } ?? "null"),\"participantIds\":[\(participantJSON)]}")
        }
        let threadId = oauth.createThreadChannel(parentChannelId: channelId, parentMessageId: parentMessageId)
        postableChannels[threadId] = PostableChannel(
            serverId: serverId,
            memberIds: [userId],
            kind: "thread",
            parentChannelId: channelId,
            parentMessageId: parentMessageId,
            name: "thread"
        )
        threadOrder.append(threadId)
        var messageId: String?
        if let content = object["content"] as? String, !content.isEmpty {
            let id = UUID().uuidString.lowercased()
            humanMessageRows.append(StoredHumanMessage(
                id: id,
                channelId: threadId,
                senderId: userId,
                content: content,
                randomId: nil
            ))
            messageId = id
        }
        lock.unlock()
        if messageId != nil {
            threadFollows["\(serverId)\n\(userId)\n\(threadId)"] = (serverId, userId, threadId, parentMessageId)
        }
        let messageJSON = messageId.map { jsonString($0) } ?? "null"
        return Self.json(200, "{\"threadChannelId\":\(jsonString(threadId)),\"messageId\":\(messageJSON),\"replyCount\":0,\"lastReplyAt\":null,\"participantIds\":[]}")
    }

    public func addChannelMember(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        if let reply = archivedChannelReply(channelId) { return reply }
        lock.lock()
        let actorChannelAdmin = channelHumanRoles["\(channelId)\n\(userId)"] == "admin"
        lock.unlock()
        if role != "owner" && role != "admin" && !actorChannelAdmin {
            if !oauth.isChannelParticipant(channelId: channelId, userId: userId) {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel member\"}")
        }
        if let agentId = object["agentId"] as? String {
            guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
                return Self.json(400, "{\"error\":\"Invalid agent\"}")
            }
            oauth.addChannelAgent(channelId: channelId, agentId: agentId)
            return Self.json(200, "{\"ok\":true}")
        }
        if let targetUserId = object["userId"] as? String {
            guard oauth.memberRole(serverId: serverId, userId: targetUserId) != nil else {
                return Self.json(400, "{\"error\":\"Invalid member\"}")
            }
            accountsForInvite(userId: targetUserId, serverId: serverId, channelId: channelId)
            return Self.json(200, "{\"ok\":true}")
        }
        return Self.json(400, "{\"error\":\"Invalid channel member\"}")
    }

    public func removeChannelHuman(authorization: String?, serverId: String, channelId: String, memberId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let actorChannelAdmin = channelHumanRoles["\(channelId)\n\(userId)"] == "admin"
        lock.unlock()
        guard role == "owner" || role == "admin" || actorChannelAdmin || userId == memberId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(memberId)
        lock.unlock()
        _ = oauth.removeChannelHuman(channelId: channelId, userId: memberId)
        return Self.json(200, "{\"ok\":true}")
    }

    public func removeChannelMember(authorization: String?, serverId: String, channelId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard role == "owner" || role == "admin" || oauth.isChannelParticipant(channelId: channelId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        oauth.removeChannelAgent(channelId: channelId, agentId: agentId)
        return Self.json(200, "{\"ok\":true}")
    }

    private func threadMemberMutationReply(_ channelId: String) -> HTTPReply? {
        lock.lock()
        let kind = postableChannels[channelId]?.kind ?? oauth.channelType(id: channelId)
        lock.unlock()
        guard kind == "thread" else { return nil }
        return Self.json(400, "{\"error\":\"Thread members are managed with follow/unfollow\"}")
    }

    private func channelActorCanSee(channelId: String, userId: String) -> Bool {
        lock.lock()
        let postable = postableChannels[channelId]
        lock.unlock()
        if let postable {
            return postable.kind == "channel" || postable.memberIds.contains(userId)
        }
        return oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId)
    }

    public func channelAgentsRoute(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              channelActorCanSee(channelId: channelId, userId: userId)
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let agents = oauth.channelAgentIds(channelId: channelId).map { agentId -> String in
            let info = oauth.agentRuntimeInfo(id: agentId)
            let activity = agentActivities[agentId] ?? (activity: "offline", detail: "")
            return "{\"id\":\(jsonString(agentId)),\"name\":\(jsonString(info?.name ?? "")),\"activity\":\(jsonString(activity.activity)),\"activityDetail\":\(jsonString(activity.detail))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"agents\":[\("\(agents)")]}")
    }

    public func updateChannelHumanRole(authorization: String?, serverId: String, channelId: String, memberId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              oauth.isChannelParticipant(channelId: channelId, userId: userId)
                  || oauth.channelType(id: channelId) == "channel"
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        if let reply = threadMemberMutationReply(channelId) { return reply }
        lock.lock()
        let actorRole = channelHumanRoles["\(channelId)\n\(userId)"]
        lock.unlock()
        let actorServerRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        guard actorRole == "admin" || actorServerRole == "owner" || actorServerRole == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let role = object["role"] as? String, role == "admin" || role == "member"
        else {
            return Self.json(400, "{\"error\":\"Invalid channel role\"}")
        }
        let targetServerRole = oauth.memberRole(serverId: serverId, userId: memberId) ?? "member"
        if targetServerRole == "owner" || targetServerRole == "admin" {
            return Self.json(403, "{\"error\":\"Server role is managed separately\",\"code\":\"protected_server_role\"}")
        }
        if userId == memberId, role == "member" {
            return Self.json(409, "{\"error\":\"A channel admin cannot demote themselves\",\"code\":\"channel_admin_self_demote_forbidden\"}")
        }
        lock.lock()
        channelHumanRoles["\(channelId)\n\(memberId)"] = role
        let revision = (channelAuthorityRevisions[channelId] ?? 1) + 1
        channelAuthorityRevisions[channelId] = revision
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"authorityRevision\":\(revision)}")
    }

    public func channelMembers(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              oauth.isChannelParticipant(channelId: channelId, userId: userId)
                  || oauth.channelType(id: channelId) == "channel"
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let scopeChannelId: String = {
            if let channel = postableChannels[channelId], channel.kind == "thread", let parentId = channel.parentChannelId {
                return parentId
            }
            return channelId
        }()
        lock.unlock()
        let agents = oauth.channelAgentIds(channelId: scopeChannelId).map { agentId -> String in
            let info = oauth.agentRuntimeInfo(id: agentId)
            let name = info?.name ?? ""
            let activity = agentActivities[agentId] ?? (activity: "offline", detail: "")
            return "{\"id\":\(jsonString(agentId)),\"name\":\(jsonString(name)),\"activity\":\(jsonString(activity.activity)),\"activityDetail\":\(jsonString(activity.detail))}"
        }.joined(separator: ",")
        let viewerServerRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        lock.lock()
        let viewerLocalRole = channelHumanRoles["\(channelId)\n\(userId)"]
        lock.unlock()
        let viewerIsChannelAdmin = viewerLocalRole == "admin" || viewerServerRole == "owner" || viewerServerRole == "admin"
        let humans = oauth.channelHumanIds(channelId: scopeChannelId).map { humanId -> String in
            let targetServerRole = oauth.memberRole(serverId: serverId, userId: humanId) ?? "member"
            lock.lock()
            let targetLocalRole = channelHumanRoles["\(channelId)\n\(humanId)"]
            lock.unlock()
            let basis: String? = targetLocalRole == "admin" ? "channel_role"
                : ((targetServerRole == "owner" || targetServerRole == "admin") ? "server_role" : nil)
            let effectiveRole = basis == nil ? "member" : "admin"
            let canChange = viewerIsChannelAdmin && targetServerRole != "owner" && targetServerRole != "admin" && humanId != userId
            return "{\"id\":\(jsonString(humanId)),\"serverRole\":\(jsonString(targetServerRole)),\"effectiveChannelRole\":\(jsonString(effectiveRole)),\"channelAdminBasis\":\(basis.map { jsonString($0) } ?? "null"),\"canChangeChannelRole\":\(canChange)}"
        }.joined(separator: ",")
        return Self.json(200, "{\"agents\":[\("\(agents)")],\"humans\":[\("\(humans)")]}")
    }

    public func deleteTask(authorization: String?, serverId: String, taskId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        let creatorId = taskRecords[index].creatorId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        if role != "owner" && role != "admin" && creatorId != userId {
            return Self.json(403, "{\"error\":\"Only the task creator can delete it\"}")
        }
        lock.lock()
        taskRecords.remove(at: index)
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func claimTask(authorization: String?, serverId: String, taskId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        lock.lock()
        taskRecords[index].assigneeId = userId
        taskRecords[index].assigneeType = "user"
        taskRecords[index].claimedAt = Date()
        taskRecords[index].revision += 1
        if taskRecords[index].status == "todo" { taskRecords[index].status = "in_progress" }
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    public func unclaimTask(authorization: String?, serverId: String, taskId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        lock.lock()
        taskRecords[index].assigneeId = nil
        taskRecords[index].assigneeType = nil
        taskRecords[index].claimedAt = nil
        taskRecords[index].revision += 1
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    public func updateTaskStatus(authorization: String?, serverId: String, taskId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let status = object["status"] as? String, Self.validTaskStatuses.contains(status)
        else {
            return Self.json(400, "{\"error\":\"Invalid task status\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.id == taskId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let channelId = taskRecords[index].channelId
        lock.unlock()
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Task not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        lock.lock()
        let current = taskRecords[index]
        if status == "todo", current.status == "in_progress", current.assigneeId != userId {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Only the current assignee can return this task to todo\"}")
        }
        taskRecords[index].status = status
        if status == "done", taskRecords[index].completedAt == nil {
            taskRecords[index].completedAt = Date()
        }
        if status == "in_progress", taskRecords[index].claimedAt == nil {
            taskRecords[index].claimedAt = Date()
        }
        if status == "todo" {
            taskRecords[index].claimedAt = nil
        }
        taskRecords[index].revision += 1
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }

    public func convertMessageToTask(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let messageId = object["messageId"] as? String
        else {
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        let storedChannelId: String?
        if let known = oauth.messageChannelId(messageId) {
            storedChannelId = known
        } else {
            lock.lock()
            storedChannelId = humanMessageRows.first { $0.id == messageId }?.channelId
            lock.unlock()
        }
        guard let channelId = storedChannelId else {
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: return Self.json(404, "{\"error\":\"Message not found\"}")
        case .readOnly: return Self.json(403, "{\"error\":\"Join the channel to change tasks\"}")
        case .write: break
        }
        let ids = addTasks(channelId: channelId, titles: ["Converted message"])
        return Self.json(200, "{\"taskIds\":[\("\(ids.map { jsonString($0) }.joined(separator: ","))")]}")
    }

    public func listServerTasks(authorization: String?, serverId: String, rawQuery: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        func repeated(_ name: String) -> Bool {
            guard let rawQuery else { return false }
            return rawQuery.split(separator: "&").filter { $0.hasPrefix(name + "=") }.count > 1
        }
        if ["limit", "cursor", "detail", "status"].contains(where: repeated) {
            return Self.json(400, "{\"error\":\"Repeated query parameter\"}")
        }
        let status: String?
        switch Self.taskStatusFilter(rawQuery) {
        case .invalid(let reply): return reply
        case .valid(let value): status = value
        }
        guard let rawQuery else {
            return legacyTasksJSON(serverId: serverId, userId: userId, status: status, detail: "full")
        }
        var params: [String: String] = [:]
        for pair in rawQuery.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { params[parts[0]] = parts[1].removingPercentEncoding ?? parts[1] }
        }
        let detail = params["detail"] ?? "full"
        guard detail == "full" || detail == "summary" else {
            return Self.json(400, "{\"error\":\"detail must be full or summary\"}")
        }
        var limit: Int?
        if let rawLimit = params["limit"] {
            guard let value = Int(rawLimit), (1...500).contains(value) else {
                return Self.json(400, "{\"error\":\"limit must be between 1 and 500\"}")
            }
            limit = value
        }
        var cursor: (channelId: String, taskNumber: Int)?
        if let rawCursor = params["cursor"] {
            guard limit != nil else {
                return Self.json(400, "{\"error\":\"cursor requires limit\"}")
            }
            guard let decoded = Self.decodeCursor(rawCursor) else {
                return Self.json(400, "{\"error\":\"Invalid cursor\"}")
            }
            cursor = decoded
        }
        let ordered = orderedTasks(serverId: serverId, userId: userId, status: status)
        var startIndex = 0
        if let cursor {
            guard let index = ordered.firstIndex(where: {
                $0.task.channelId == cursor.channelId && $0.task.taskNumber == cursor.taskNumber
            }) else {
                return Self.json(400, "{\"error\":\"Invalid cursor\"}")
            }
            startIndex = index + 1
        }
        var page = ordered
        var nextCursor: String?
        if let limit {
            let slice = Array(ordered.dropFirst(startIndex).prefix(limit))
            page = slice
            if let last = slice.last, startIndex + slice.count < ordered.count {
                nextCursor = Self.encodeCursor(channelId: last.task.channelId, taskNumber: last.task.taskNumber)
            }
        } else {
            page = Array(ordered.dropFirst(0))
        }
        let items = page.map { entry in
            detail == "summary"
                ? summaryTaskJSON(entry.task, channelName: entry.channelName, channelType: entry.channelType)
                : fullTaskJSON(entry.task, channelName: entry.channelName, channelType: entry.channelType)
        }.joined(separator: ",")
        if limit == nil {
            return Self.json(200, "{\"tasks\":[\("\(items)")]}")
        }
        let cursorJSON = nextCursor.map { jsonString($0) } ?? "null"
        return Self.json(200, "{\"tasks\":[\("\(items)")],\"next_cursor\":\(cursorJSON)}")
    }

    private func orderedTasks(
        serverId: String,
        userId: String,
        status: String?
    ) -> [(task: TaskRecord, channelName: String, channelType: String)] {
        let visible = oauth.channelsForServer(serverId: serverId, userId: userId).filter { $0.joined }
        let names = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.name) })
        let types = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.type) })
        lock.lock()
        let rows = taskRecords.filter {
            names[$0.channelId] != nil && (status == nil || $0.status == status)
        }
        lock.unlock()
        return rows
            .map { (task: $0, channelName: names[$0.channelId] ?? "", channelType: types[$0.channelId] ?? "channel") }
            .sorted {
                if $0.channelName != $1.channelName { return $0.channelName < $1.channelName }
                if $0.task.taskNumber != $1.task.taskNumber { return $0.task.taskNumber < $1.task.taskNumber }
                return $0.task.id < $1.task.id
            }
    }

    private func legacyTasksJSON(serverId: String, userId: String, status: String?, detail: String) -> HTTPReply {
        let ordered = orderedTasks(serverId: serverId, userId: userId, status: status)
        let items = ordered.map { entry in
            fullTaskJSON(entry.task, channelName: entry.channelName, channelType: entry.channelType)
        }.joined(separator: ",")
        return Self.json(200, "{\"tasks\":[\("\(items)")]}")
    }

    private static func encodeCursor(channelId: String, taskNumber: Int) -> String {
        let payload = "{\"c\":\(jsonString(channelId)),\"n\":\(taskNumber)}"
        return Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeCursor(_ raw: String) -> (channelId: String, taskNumber: Int)? {
        var base64 = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let channelId = object["c"] as? String,
              channelId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil,
              let taskNumber = object["n"] as? Int
        else { return nil }
        return (channelId, taskNumber)
    }

    private func fullTaskJSON(_ task: TaskRecord, channelName: String, channelType: String) -> String {
        let description = task.description.map { jsonString($0) } ?? "null"
        return "{\"id\":\(jsonString(task.id)),\"channelId\":\(jsonString(task.channelId)),\"channelName\":\(jsonString(channelName)),\"channelType\":\(jsonString(channelType)),\"title\":\(jsonString(task.title)),\"description\":\(description),\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber),\"messageId\":\(jsonString(task.messageId)),\"revision\":\(task.revision)}"
    }

    private func summaryTaskJSON(_ task: TaskRecord, channelName: String, channelType: String) -> String {
        let descriptionBytes = task.description.map { Data($0.utf8).count } ?? 0
        let hasDescription = task.description != nil && !(task.description ?? "").isEmpty
        let claimed = task.claimedAt.map { jsonString(ISO8601DateFormatter().string(from: $0)) } ?? "null"
        let assignee = task.assigneeId.map { jsonString($0) } ?? "null"
        let assigneeType = task.assigneeType.map { jsonString($0) } ?? "null"
        return "{\"channelId\":\(jsonString(task.channelId)),\"channelName\":\(jsonString(channelName)),\"channelType\":\(jsonString(channelType)),\"claimedAt\":\(claimed),\"claimedById\":\(assignee),\"claimedByName\":null,\"claimedByType\":\(assigneeType),\"completedAt\":null,\"createdAt\":null,\"createdById\":null,\"createdByName\":null,\"createdByType\":\"user\",\"descriptionBytes\":\(descriptionBytes),\"hasDescription\":\(hasDescription),\"id\":\(jsonString(task.id)),\"isLegacy\":false,\"messageId\":\(jsonString(task.messageId)),\"readOnlyReason\":null,\"revision\":\(task.revision),\"source\":\"tasks\",\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber),\"title\":\(jsonString(task.title)),\"updatedAt\":null}"
    }

    private struct TaskRecord {
        var id: String
        var channelId: String
        var title: String
        var description: String?
        var status: String
        var taskNumber: Int
        var messageId: String
        var createdAt: Date
        var completedAt: Date? = nil
        var updatedAt: Date? = nil
        var creatorId: String? = nil
        var assigneeId: String? = nil
        var assigneeType: String? = nil
        var claimedAt: Date? = nil
        var revision: Int = 0
    }

    public func addReminder(serverId: String, ownerAgentId: String, title: String, fireAt: Date) {
        lock.lock()
        reminderRecords.append(ReminderRecord(
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            ownerAgentId: ownerAgentId,
            title: title,
            fireAt: fireAt
        ))
        lock.unlock()
    }

    public func listReminders(authorization: String?, serverId: String, ownerAgentId: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let agents = oauth.serverAgents(serverId: serverId)
        if let ownerAgentId, !ownerAgentId.isEmpty {
            guard let agent = agents.first(where: { $0.id == ownerAgentId }) else {
                return Self.json(404, "{\"error\":\"Agent not found\"}")
            }
            guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            return Self.reminderListJSON(remindersFor([ownerAgentId]))
        }
        let visibleAgentIds: Set<String>
        if role == "owner" || role == "admin" {
            visibleAgentIds = Set(agents.map { $0.id })
        } else {
            visibleAgentIds = Set(agents.filter { $0.creatorUserId == userId }.map { $0.id })
        }
        return Self.reminderListJSON(remindersFor(visibleAgentIds))
    }

    private func remindersFor(_ agentIds: Set<String>) -> [ReminderRecord] {
        lock.lock()
        defer { lock.unlock() }
        return reminderRecords.filter { agentIds.contains($0.ownerAgentId) }
    }

    private static func reminderListJSON(_ rows: [ReminderRecord]) -> HTTPReply {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let items = rows.map { reminder in
            "{\"id\":\(jsonString(reminder.id)),\"title\":\(jsonString(reminder.title)),\"ownerAgentId\":\(jsonString(reminder.ownerAgentId)),\"fireAt\":\(jsonString(formatter.string(from: reminder.fireAt)))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"reminders\":[\("\(items)")]}")
    }

    private struct ReminderRecord {
        var id: String
        var serverId: String
        var ownerAgentId: String
        var title: String
        var fireAt: Date
    }

    public func saveChannelMessage(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let messageId = object["messageId"] as? String,
              oauth.saveMessage(userId: userId, messageId: messageId)
        else {
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        return Self.json(200, "{\"ok\":true}")
    }

    public func checkSavedMessages(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let messageIds = object["messageIds"] as? [String]
        else {
            return Self.json(400, "{\"error\":\"Invalid saved check request\"}")
        }
        let saved = Set(oauth.savedMessages(userId: userId).map(\.messageId))
        lock.lock()
        let visible = messageIds.filter { id in
            guard saved.contains(id) else { return false }
            guard let entry = oauth.savedMessages(userId: userId).first(where: { $0.messageId == id }) else { return false }
            if let scope = postableChannels[entry.channelId] {
                guard scope.serverId == serverId, scope.deletedAt == nil, !scope.archived else { return false }
                return scope.kind == "channel" || scope.memberIds.contains(userId)
            }
            return true
        }
        lock.unlock()
        let ids = visible.map { jsonString($0) }.joined(separator: ",")
        return Self.json(200, "{\"savedIds\":[\("\(ids)")]}")
    }

    public func listSavedMessages(
        authorization: String?,
        serverId: String,
        query: String?,
        channelId: String?,
        sort: String?,
        limit: Int,
        offset: Int
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        var entries = oauth.savedMessages(userId: userId)
        lock.lock()
        entries = entries.filter { entry in
            if let scope = postableChannels[entry.channelId] {
                guard scope.serverId == serverId, scope.deletedAt == nil, !scope.archived else { return false }
                if scope.kind == "channel" { return true }
                return scope.memberIds.contains(userId)
            }
            if let parentChannelId = entry.parentChannelId, let parent = postableChannels[parentChannelId] {
                guard parent.serverId == serverId, parent.deletedAt == nil, !parent.archived else { return false }
                return parent.kind == "channel" || parent.memberIds.contains(userId)
            }
            return true
        }
        lock.unlock()
        if let channelId, !channelId.isEmpty {
            entries = entries.filter { $0.channelId == channelId || $0.parentChannelId == channelId }
        }
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needle = query.lowercased()
            entries = entries.filter {
                $0.content.lowercased().contains(needle)
                    || ($0.parentMessagePreview?.lowercased().contains(needle) ?? false)
            }
        }
        if sort == "asc" {
            entries.sort { $0.savedAt < $1.savedAt }
        } else {
            entries.sort { $0.savedAt > $1.savedAt }
        }
        let total = entries.count
        let page = Array(entries.dropFirst(max(0, offset)).prefix(max(0, limit)))
        let rows = page.map { entry -> String in
            let parentChannel = entry.parentChannelId.map { jsonString($0) } ?? "null"
            let parentMessage = entry.parentMessageId.map { jsonString($0) } ?? "null"
            let preview = entry.parentMessagePreview.map { jsonString($0) } ?? "null"
            return "{\"messageId\":\(jsonString(entry.messageId)),\"channelId\":\(jsonString(entry.channelId)),\"channelType\":\(jsonString(entry.channelType)),\"content\":\(jsonString(entry.content)),\"parentChannelId\":\(parentChannel),\"parentMessageId\":\(parentMessage),\"parentMessagePreview\":\(preview),\"replyCount\":\(entry.replyCount)}"
        }.joined(separator: ",")
        return Self.json(200, "{\"saved\":[\("\(rows)")],\"total\":\(total),\"hasMore\":\(offset + page.count < total)}")
    }

    public func setAllChannelVisibility(authorization: String?, serverId: String, visible: Bool) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let allChannelId = oauth.allChannelId(serverId: serverId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        oauth.setChannelType(id: allChannelId, type: visible ? "channel" : "private")
        return Self.json(200, "{\"id\":\(jsonString(allChannelId)),\"visible\":\(visible)}")
    }

    public func createDirectChannelRoute(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let peerId = object["userId"] as? String,
              oauth.memberRole(serverId: serverId, userId: peerId) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid DM peer\"}")
        }
        let channelId = oauth.createDirectChannel(serverId: serverId, firstUserId: userId, secondUserId: peerId)
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"type\":\"dm\",\"activityMuteSupported\":false}")
    }

    public func listDirectChannels(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let rows = oauth.channelsForServer(serverId: serverId, userId: userId)
            .filter { $0.type == "dm" }
            .map { channel in
                "{\"id\":\(jsonString(channel.id)),\"type\":\"dm\",\"joined\":\(channel.joined),\"activityMuteSupported\":false}"
            }
            .joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func enableReadReceiptsForServer(_ serverId: String) {
        lock.lock()
        readReceiptsServers.insert(serverId)
        lock.unlock()
    }

    public func readReceiptsEnabled(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readReceiptsServers.contains(serverId)
    }

    public func setAgentReadCursorForTesting(agentId: String, channelId: String, seq: Int, version: Int = 1) {
        lock.lock()
        agentChannelReadCursors["\(channelId)\n\(agentId)"] = (seq, version)
        lock.unlock()
    }

    public func setChannelHumanRoleForTesting(channelId: String, userId: String, role: String) {
        lock.lock()
        channelHumanRoles["\(channelId)\n\(userId)"] = role
        lock.unlock()
    }

    public func getChannelRoute(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let type = oauth.channelType(id: channelId) ?? "channel"
        lock.lock()
        let joined = channel.name == "all"
            || postableChannels[channelId]?.memberIds.contains(userId) == true
            || oauth.channelHumanIds(channelId: channelId).contains(userId)
        lock.unlock()
        let supported = type == "channel"
        let info = oauth.channelUnreadInfo(channelId: channelId, userId: userId)
        lock.lock()
        let version = channelReadVersions["\(channelId)\n\(userId)"] ?? 0
        let receiptsEnabled = readReceiptsServers.contains(serverId)
        let agentIds = oauth.channelAgentIds(channelId: channelId)
        let peerSeqs = agentIds.map { agentId in
            (agentId, agentChannelReadCursors["\(channelId)\n\(agentId)"]?.seq ?? 0)
        }
        lock.unlock()
        let serverRole = oauth.memberRole(serverId: serverId, userId: userId) ?? "member"
        lock.lock()
        let localRole = channelHumanRoles["\(channelId)\n\(userId)"]
        let authorityRevision = channelAuthorityRevisions[channelId] ?? 1
        lock.unlock()
        let basis: String? = localRole == "admin" ? "channel_role"
            : ((serverRole == "owner" || serverRole == "admin") ? "server_role" : nil)
        let channelRole = basis == nil ? "member" : "admin"
        let serverAdmin = serverRole == "owner" || serverRole == "admin"
        let capability = basis != nil
        let capsJSON = "{\"editChannelMetadata\":\(capability),\"archiveChannels\":\(capability),\"addChannelMembers\":\(capability),\"changeChannelMemberRoles\":\(capability),\"deleteChannels\":\(serverAdmin),\"changeChannelVisibility\":\(serverAdmin),\"federateChannels\":\(serverAdmin)}"
        var peersJSON = ""
        if receiptsEnabled {
            if peerSeqs.count > 50 {
                var counts: [Int: Int] = [:]
                for (_, seq) in peerSeqs { counts[seq, default: 0] += 1 }
                let buckets = counts.keys.sorted().map { seq in
                    "{\"seq\":\(seq),\"count\":\(counts[seq] ?? 0)}"
                }.joined(separator: ",")
                peersJSON = ",\"peerReadSummary\":{\"peerCount\":\(peerSeqs.count),\"readCountAtSeq\":[\("\(buckets)")]}"
            } else {
                let peers = peerSeqs.map { agentId, seq in
                    "{\"peerKind\":\"agent\",\"peerId\":\(jsonString(agentId)),\"maxReadSeq\":\(seq)}"
                }.joined(separator: ",")
                peersJSON = ",\"peerReadStates\":[\("\(peers)")]"
            }
        }
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(jsonString(channel.name)),\"type\":\(jsonString(type)),\"joined\":\(joined),\"maxReadSeq\":\(info.maxReadSeq),\"readStateVersion\":\(version),\"activityMuteSupported\":\(supported),\"channelRole\":\(jsonString(channelRole)),\"channelAdminBasis\":\(basis.map { jsonString($0) } ?? "null"),\"channelAuthorityRevision\":\(authorityRevision),\"channelCapabilities\":\(capsJSON)\(peersJSON)}")
    }

    public func channelDisplaySettings(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard oauth.canAccessChannelPrefs(channelId: channelId, userId: userId, serverId: serverId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let prefs = oauth.channelDisplayPrefs(channelId: channelId, userId: userId)
        return Self.json(200, "{\"collapseLongMessages\":\(prefs.collapseLongMessages),\"prefsVersion\":\(prefs.prefsVersion)}")
    }

    public func patchChannelDisplaySettings(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard oauth.canAccessChannelPrefs(channelId: channelId, userId: userId, serverId: serverId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let collapse = object["collapseLongMessages"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"collapseLongMessages must be a boolean\"}")
        }
        let prefs = oauth.setCollapseLongMessages(channelId: channelId, userId: userId, collapse: collapse)
        return Self.json(200, "{\"collapseLongMessages\":\(prefs.collapseLongMessages),\"prefsVersion\":\(prefs.prefsVersion)}")
    }

    public func addStoredMentionForTesting(
        channelId: String,
        messageId: String,
        targetId: String,
        targetType: String = "user",
        handle: String = "peer",
        terminalCode: String? = nil
    ) {
        lock.lock()
        storedMentions.append(StoredMention(
            id: UUID().uuidString.lowercased(),
            messageId: messageId,
            channelId: channelId,
            senderId: "peer",
            targetType: targetType,
            targetId: targetId,
            handle: handle,
            notifiableAtSend: true,
            notifiedAt: nil,
            notifiedByType: nil,
            notifiedById: nil,
            notifiedAction: nil,
            terminalCode: terminalCode
        ))
        lock.unlock()
    }

    public func updateChannelReadState(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let readable = postableChannels[channelId].map { $0.kind == "channel" || $0.memberIds.contains(userId) }
            ?? (oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId))
        lock.unlock()
        guard readable else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let seq = object["seq"] as? Int, seq >= 0
        else {
            return Self.json(400, "{\"error\":\"seq must be a non-negative integer\"}")
        }
        let key = "\(channelId)\n\(userId)"
        lock.lock()
        let info = oauth.channelUnreadInfo(channelId: channelId, userId: userId)
        let current = max(info.maxReadSeq, channelReadVersions[key] == nil ? 0 : info.maxReadSeq)
        if seq <= info.maxReadSeq {
            let version = channelReadVersions[key] ?? 0
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"maxReadSeq\":\(current),\"readStateVersion\":\(version)}")
        }
        channelReadVersions[key] = (channelReadVersions[key] ?? 0) + 1
        let version = channelReadVersions[key] ?? 1
        lock.unlock()
        oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: seq)
        return Self.json(200, "{\"ok\":true,\"maxReadSeq\":\(seq),\"readStateVersion\":\(version)}")
    }

    public func markChannelReadAll(authorization: String?, serverId: String, channelId: String, body: String = "{}") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let readableAll = postableChannels[channelId].map { $0.kind == "channel" || $0.memberIds.contains(userId) }
            ?? (oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId))
        lock.unlock()
        guard readableAll else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
           let receiver = object["receiver"] as? [String: Any],
           let kind = receiver["kind"] as? String,
           let receiverId = receiver["id"] as? String {
            guard kind == "agent", let agent = oauth.agentRuntimeInfo(id: receiverId), agent.serverId == serverId else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            let canDelegate = role == "owner" || role == "admin" || agent.creatorUserId == userId
            guard canDelegate, oauth.channelAgentIds(channelId: channelId).contains(agent.id) else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            let latestSeq = oauth.channelUnreadInfo(channelId: channelId, userId: userId).latestSeq ?? 0
            lock.lock()
            let key = "\(channelId)\n\(receiverId)"
            let previous = agentChannelReadCursors[key] ?? (seq: 0, version: 0)
            let version = latestSeq > previous.seq ? previous.version + 1 : previous.version
            agentChannelReadCursors[key] = (seq: max(previous.seq, latestSeq), version: version)
            lock.unlock()
            if latestSeq > previous.seq {
                onAgentReadUpdated?(serverId, channelId, receiverId, latestSeq)
            }
            return Self.json(200, "{\"ok\":true,\"seq\":\(max(previous.seq, latestSeq)),\"readStateVersion\":\(max(version, 1))}")
        }
        let latest = oauth.channelUnreadInfo(channelId: channelId, userId: userId).latestSeq ?? 0
        let key = "\(channelId)\n\(userId)"
        lock.lock()
        channelReadVersions[key] = (channelReadVersions[key] ?? 0) + 1
        let version = channelReadVersions[key] ?? 1
        lock.unlock()
        oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: latest)
        return Self.json(200, "{\"ok\":true,\"seq\":\(latest),\"readStateVersion\":\(version)}")
    }

    @discardableResult
    public func addAnnouncementForTesting(
        title: String,
        pages: [String],
        startsAt: Date = Date(),
        expiresAt: Date? = nil,
        status: String = "published",
        publishedAt: Date? = nil,
        imageId: String? = nil
    ) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        announcements.append((
            id: id,
            title: title,
            pages: pages,
            startsAt: startsAt,
            expiresAt: expiresAt,
            status: status,
            publishedAt: publishedAt ?? (status == "draft" ? nil : Date()),
            imageId: imageId
        ))
        lock.unlock()
        return id
    }

    public func setAnnouncementStateForTesting(
        id: String,
        status: String,
        publishedAt: Date?,
        startsAt: Date
    ) {
        lock.lock()
        if let index = announcements.firstIndex(where: { $0.id == id }) {
            announcements[index].status = status
            announcements[index].publishedAt = publishedAt
            announcements[index].startsAt = startsAt
        }
        lock.unlock()
    }

    public func addAnnouncementImageForTesting(id: String, announcementId: String, contentType: String, bytes: Data) {
        lock.lock()
        announcementImageAssets[id] = AnnouncementImageAsset(
            id: id,
            announcementId: announcementId,
            contentType: contentType,
            bytes: bytes
        )
        lock.unlock()
    }

    private struct ExternalAvatarAsset {
        var id: String
        var contentType: String
        var bytes: Data
        var sourceDigest: String
        var active: Bool
    }

    private var externalAvatarAssets: [String: ExternalAvatarAsset] = [:]
    private var externalAvatarStorageAvailable = true

    public func addExternalAvatarForTesting(
        id: String,
        contentType: String = "image/webp",
        bytes: Data,
        sourceDigest: String,
        active: Bool = true
    ) {
        lock.lock()
        externalAvatarAssets[id] = ExternalAvatarAsset(
            id: id,
            contentType: contentType,
            bytes: bytes,
            sourceDigest: sourceDigest,
            active: active
        )
        lock.unlock()
    }

    public func setExternalAvatarStorageAvailableForTesting(_ available: Bool) {
        lock.lock()
        externalAvatarStorageAvailable = available
        lock.unlock()
    }

    public func externalAvatar(file: String) -> HTTPReply {
        guard file.hasSuffix(".webp") else {
            return Self.avatarPlainText(404, "Not found")
        }
        let id = String(file.dropLast(".webp".count))
        guard ServerScope.isUUID(id) else {
            return Self.avatarPlainText(404, "Not found")
        }
        lock.lock()
        let asset = externalAvatarAssets[id]
        let storageAvailable = externalAvatarStorageAvailable
        lock.unlock()
        guard let asset, asset.active else {
            return Self.avatarPlainText(404, "Not found")
        }
        guard storageAvailable else {
            return Self.avatarPlainText(503, "Avatar storage is unavailable")
        }
        return HTTPReply(
            status: 200,
            headers: [
                "Content-Type": asset.contentType,
                "Content-Length": String(asset.bytes.count),
                "Content-Disposition": "inline",
                "Cache-Control": "public, no-cache, must-revalidate",
                "ETag": "\"sha256-\(asset.sourceDigest)\"",
                "X-Content-Type-Options": "nosniff",
                "Cross-Origin-Resource-Policy": "cross-origin",
            ],
            body: String(decoding: asset.bytes, as: UTF8.self)
        )
    }

    private static func avatarPlainText(_ status: Int, _ body: String) -> HTTPReply {
        HTTPReply(
            status: status,
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }

    public func setAnnouncementImageStorageAvailableForTesting(_ available: Bool) {
        lock.lock()
        announcementImageStorageAvailable = available
        lock.unlock()
    }

    public func announcementImage(id: String) -> HTTPReply {
        guard ServerScope.isUUID(id) else {
            return Self.json(404, "{\"error\":\"Announcement image not found\"}")
        }
        lock.lock()
        let asset = announcementImageAssets[id]
        let announcement = announcements.first { $0.id == asset?.announcementId }
        let storageAvailable = announcementImageStorageAvailable
        lock.unlock()
        guard let asset, let announcement,
              announcement.publishedAt != nil,
              announcement.status != "draft",
              announcement.startsAt <= Date()
        else {
            return Self.json(404, "{\"error\":\"Announcement image not found\"}")
        }
        guard storageAvailable else {
            return Self.json(503, "{\"error\":\"Announcement image storage unavailable\"}")
        }
        return HTTPReply(
            status: 200,
            headers: [
                "Content-Type": asset.contentType,
                "Cache-Control": "public, max-age=31536000, immutable",
                "Cross-Origin-Resource-Policy": "cross-origin",
                "Content-Length": String(asset.bytes.count),
            ],
            body: String(decoding: asset.bytes, as: UTF8.self)
        )
    }

    public func activeAnnouncements(authorization: String?, after: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        if let after, !after.isEmpty, !ServerScope.isUUID(after) {
            return Self.json(400, "{\"error\":\"Invalid announcement cursor\"}")
        }
        let now = Date()
        lock.lock()
        let rows = announcements
            .filter { $0.startsAt <= now && ($0.expiresAt == nil || $0.expiresAt! > now) }
            .filter { !announcementDismissals.contains("\(userId)\n\($0.id)") }
            .filter { after == nil || $0.id != after }
            .sorted { $0.startsAt < $1.startsAt }
            .prefix(1)
        let documents = rows.map { announcement -> String in
            let pages = announcement.pages.map { jsonString($0) }.joined(separator: ",")
            return "{\"id\":\(jsonString(announcement.id)),\"title\":\(jsonString(announcement.title)),\"pages\":[\(pages)]}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"announcements\":[\(documents)]}")
    }

    public func dismissAnnouncement(authorization: String?, announcementId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        guard announcements.contains(where: { $0.id == announcementId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Announcement not found\"}")
        }
        announcementDismissals.insert("\(userId)\n\(announcementId)")
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func setAgentActivity(agentId: String, activity: String, detail: String) {
        lock.lock()
        agentActivities[agentId] = (activity, detail)
        lock.unlock()
    }

    public func agentReadCursor(agentId: String, channelId: String) -> (seq: Int, version: Int) {
        lock.lock()
        defer { lock.unlock() }
        return agentChannelReadCursors["\(channelId)\n\(agentId)"] ?? (0, 0)
    }

    public func markChannelUnread(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        lock.lock()
        let readableUnread = postableChannels[channelId].map { $0.kind == "channel" || $0.memberIds.contains(userId) }
            ?? (oauth.channelType(id: channelId) == "channel" || oauth.isChannelParticipant(channelId: channelId, userId: userId))
        lock.unlock()
        guard readableUnread else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let cursor = max(0, (oauth.latestPeerMessageSeq(channelId: channelId, excluding: userId) ?? 1) - 1)
        oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: cursor)
        let info = oauth.channelUnreadInfo(channelId: channelId, userId: userId)
        return Self.json(200, "{\"channelId\":\(jsonString(channelId)),\"unreadCount\":\(info.unreadCount),\"maxReadSeq\":\(info.maxReadSeq)}")
    }

    public func channelUnread(authorization: String?, serverId: String, summary: Bool) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let channels = oauth.channelsForServer(serverId: serverId, userId: userId).filter { channel in
            guard channel.joined else { return false }
            if let thread = postableChannels[channel.id], thread.kind == "thread" {
                guard let parentId = thread.parentChannelId,
                      let parent = postableChannels[parentId],
                      parent.deletedAt == nil
                else { return false }
            }
            return true
        }
        if !summary {
            let pairs = channels.compactMap { channel -> String? in
                let info = oauth.channelUnreadInfo(channelId: channel.id, userId: userId)
                guard info.unreadCount > 0 else { return nil }
                return "\(jsonString(channel.id)):\(info.unreadCount)"
            }.joined(separator: ",")
            return Self.privateJSON("{\(pairs)}")
        }
        let entries = channels.map { channel -> String in
            let info = oauth.channelUnreadInfo(channelId: channel.id, userId: userId)
            let latest: String
            if let messageId = info.latestMessageId, let seq = info.latestSeq {
                latest = "{\"messageId\":\(jsonString(messageId)),\"seq\":\"\(seq)\"}"
            } else {
                latest = "null"
            }
            let mentions = storedMentions.filter { $0.channelId == channel.id && $0.targetType == "user" && $0.targetId == userId }
            let hasAny = !mentions.isEmpty
            return "\(jsonString(channel.id)):{\"unreadCount\":\(info.unreadCount),\"hasMention\":\(hasAny),\"hasAnyMention\":\(hasAny),\"readState\":{\"kind\":\"present\",\"readStateVersion\":0,\"maxReadSeq\":\"\(info.maxReadSeq)\",\"latestActivity\":\(latest)}}"
        }.joined(separator: ",")
        return Self.privateJSON("{\"channels\":{\(entries)}}")
    }

    public func channelNotificationSettings(authorization: String?, serverId: String, channelId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let channelType = oauth.channelType(id: channelId) ?? "channel"
        guard channelType != "thread" else {
            return Self.json(400, "{\"error\":\"Threads use follow/unfollow instead of activity mute\"}")
        }
        let supported = channelType == "channel"
        let prefs = oauth.notificationPrefs(channelId: channelId, userId: userId)
        let muteSeq = prefs.muteFromSeq.map(String.init) ?? "null"
        return Self.json(200, "{\"activityMuted\":\(prefs.activityMuted),\"muteFromSeq\":\(muteSeq),\"prefsVersion\":\(prefs.prefsVersion),\"activityMuteSupported\":\(supported)}")
    }

    public func patchChannelNotificationSettings(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        let channelType = oauth.channelType(id: channelId) ?? "channel"
        guard channelType != "thread" else {
            return Self.json(400, "{\"error\":\"Threads use follow/unfollow instead of activity mute\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let muted = object["activityMuted"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"activityMuted must be a boolean\"}")
        }
        let result = oauth.setActivityMuted(channelId: channelId, userId: userId, muted: muted)
        let muteSeq = result.prefs.muteFromSeq.map(String.init) ?? "null"
        let supported = channelType == "channel"
        return Self.json(200, "{\"activityMuted\":\(result.prefs.activityMuted),\"muteFromSeq\":\(muteSeq),\"prefsVersion\":\(result.prefs.prefsVersion),\"activityMuteSupported\":\(supported)}")
    }

    public func patchChannelRoute(authorization: String?, serverId: String, channelId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil,
              let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId
        else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if let reply = archivedChannelReply(channelId) { return reply }
        guard channelActorCanSee(channelId: channelId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid channel update\"}")
        }
        if let rawVisibility = object["visibility"] {
            guard let visibility = rawVisibility as? String, ["private", "public"].contains(visibility) else {
                return Self.json(400, "{\"error\":\"Invalid channel visibility\"}")
            }
            if oauth.allChannelId(serverId: serverId) == channelId {
                return Self.json(403, "{\"error\":\"Only a human can do it, from channel settings or server settings\",\"code\":\"all_channel_visibility_managed_separately\"}")
            }
            guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            lock.lock()
            let isMember = postableChannels[channelId]?.memberIds.contains(userId) == true
            lock.unlock()
            guard isMember || oauth.isChannelParticipant(channelId: channelId, userId: userId) else {
                return Self.json(403, "{\"error\":\"You must be a channel member\",\"code\":\"channel_membership_required\"}")
            }
            _ = oauth.setChannelType(id: channelId, type: visibility == "private" ? "private" : "channel")
            lock.lock()
            postableChannels[channelId]?.kind = visibility == "private" ? "private" : "channel"
            if visibility == "private" {
                let snapshot = postableChannels[channelId]?.memberIds ?? []
                let threadIds = Set(postableChannels.filter { $0.value.kind == "thread" && $0.value.parentChannelId == channelId }.keys)
                for (key, follow) in threadFollows where threadIds.contains(follow.threadChannelId) && !snapshot.contains(follow.userId) {
                    threadFollows.removeValue(forKey: key)
                }
            }
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"id\":\(jsonString(channelId)),\"visibility\":\(jsonString(visibility)),\"type\":\(jsonString(visibility == "private" ? "private" : "channel"))}")
        }
        lock.lock()
        let actorName = accounts.values.first(where: { $0.id == userId })?.name ?? "Someone"
        lock.unlock()
        var newName: String?
        if let name = object["name"] as? String, name != channel.name {
            guard name.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) != nil else {
                return Self.json(400, "{\"error\":\"Invalid channel name\"}")
            }
            newName = name
        }
        let newDescription = object["description"] as? String
        var systemMessage: String?
        if let newName {
            systemMessage = "@\(actorName) renamed this channel from #\(channel.name) to #\(newName)."
        }
        let seq = oauth.updateChannel(
            id: channelId,
            name: newName,
            description: newDescription,
            systemMessage: systemMessage
        )
        let latest = oauth.channelInfo(id: channelId)
        let nameJSON = jsonString(latest?.name ?? channel.name)
        let descriptionJSON = latest?.description.map { jsonString($0) } ?? "null"
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(nameJSON),\"description\":\(descriptionJSON),\"systemMessageSeq\":\(seq.map(String.init) ?? "null")}")
    }

    public func createChannelRoute(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String,
              name.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,79}$/) != nil,
              name != "all"
        else {
            return Self.json(400, "{\"error\":\"Invalid channel\"}")
        }
        let description = object["description"] as? String
        let channelId = oauth.createChannel(
            serverId: serverId,
            name: name,
            creatorUserId: userId,
            description: description
        )
        lock.lock()
        postableChannels[channelId] = PostableChannel(serverId: serverId, memberIds: [userId], name: name)
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(channelId)),\"name\":\(jsonString(name)),\"joined\":true,\"activityMuteSupported\":true,\"activityMuted\":false,\"muteFromSeq\":null,\"prefsVersion\":0,\"maxReadSeq\":0,\"readStateVersion\":0}")
    }

    public func listChannels(authorization: String?, serverId: String, archived: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = oauth.channelsForServer(serverId: serverId, userId: userId, includeArchived: archived == "include")
            .filter { archived == "include" || oauth.channelArchivedAt(id: $0.id) == nil }
            .map { channel -> String in
            let last = channel.lastMessageAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
            let muteSeq = channel.muteFromSeq.map(String.init) ?? "null"
            let archivedAt = oauth.channelArchivedAt(id: channel.id).map { jsonString(formatter.string(from: $0)) } ?? "null"
            return "{\"id\":\(jsonString(channel.id)),\"name\":\(jsonString(channel.name)),\"type\":\(jsonString(channel.type)),\"joined\":\(channel.name == "all" || channel.joined),\"archivedAt\":\(archivedAt),\"lastMessageAt\":\(last),\"activityMuted\":\(channel.activityMuted),\"muteFromSeq\":\(muteSeq),\"prefsVersion\":\(channel.prefsVersion),\"activityMuteSupported\":\(channel.type == "channel")}"
        }.joined(separator: ",")
        return Self.json(200, "[\(rows)]")
    }

    public func completeProfile(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawName = object["name"] as? String,
              let rawDisplay = object["displayName"] as? String
        else {
            return Self.json(400, "{\"error\":\"name and displayName are required\",\"code\":\"PROFILE_SETUP_INVALID\"}")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !displayName.isEmpty else {
            return Self.json(400, "{\"error\":\"name and displayName are required\",\"code\":\"PROFILE_SETUP_INVALID\"}")
        }
        let lowered = name.lowercased()
        if lowered.hasPrefix("pending_") || Self.reservedAgentNames.contains(lowered) {
            return Self.json(400, "{\"error\":\"This username is reserved. Choose another name.\",\"code\":\"PROFILE_SETUP_NAME_RESERVED\"}")
        }
        lock.lock()
        guard let key = accounts.first(where: { $0.value.id == userId })?.key, var account = accounts[key] else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        if let completedAt = account.profileSetupCompletedAt {
            let replay = account.name == name && (account.displayName ?? account.name) == displayName
            lock.unlock()
            if replay {
                let user = Self.userJSON(accounts[key] ?? account)
                return Self.json(200, "{\"name\":\(jsonString(account.name)),\"displayName\":\(jsonString(account.displayName ?? account.name)),\"profileSetupCompletedAt\":\(jsonString(Self.isoString(completedAt))),\"user\":\(user)}")
            }
            return Self.json(409, "{\"error\":\"Profile setup is already completed\",\"code\":\"PROFILE_SETUP_ALREADY_COMPLETED\"}")
        }
        let taken = Set(accounts.values.filter { $0.id != userId }.map { $0.name.lowercased() })
        guard !taken.contains(lowered) else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"That username is taken\",\"code\":\"PROFILE_SETUP_NAME_TAKEN\"}")
        }
        account.name = name
        account.displayName = displayName
        account.profileSetupCompletedAt = Date()
        accounts[key] = account
        lock.unlock()
        let completed = account.profileSetupCompletedAt ?? Date()
        let user = Self.userJSON(account)
        return Self.json(200, "{\"name\":\(jsonString(name)),\"displayName\":\(jsonString(displayName)),\"profileSetupCompletedAt\":\(jsonString(Self.isoString(completed))),\"user\":\(user)}")
    }

    public func createServer(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let profileSetupPending = accounts.values.first { $0.id == userId }.map {
            $0.emailVerified && $0.profileSetupCompletedAt == nil
        } ?? false
        lock.unlock()
        if profileSetupPending {
            return Self.json(403, "{\"error\":\"Profile setup required\",\"code\":\"PROFILE_SETUP_REQUIRED\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawName = object["name"] as? String,
              let rawSlug = object["slug"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid server request\"}")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !slug.isEmpty else {
            return Self.json(400, "{\"error\":\"Invalid server request\"}")
        }
        if let existing = oauth.serverIdForSlug(slug) {
            if let profile = oauth.serverProfile(id: existing), let role = oauth.memberRole(serverId: existing, userId: userId) {
                return Self.json(200, "{\"id\":\(jsonString(profile.id)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"role\":\(jsonString(role))}")
            }
            return Self.json(409, "{\"error\":\"Slug is already taken\"}")
        }
        guard slug.count >= 5 else {
            return Self.json(400, "{\"error\":\"Slug must be at least 5 characters\"}")
        }
        let serverId = UUID().uuidString.lowercased()
        oauth.addOwnedServer(id: serverId, slug: slug, name: name, ownerId: userId)
        return Self.json(200, "{\"id\":\(jsonString(serverId)),\"name\":\(jsonString(name)),\"slug\":\(jsonString(slug)),\"role\":\"owner\"}")
    }

    public func serverProductAnalyticsSettings(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let enabled = oauth.serverAnalyticsAllowed(id: serverId) ?? true
        let canManage = role == "owner" || role == "admin"
        return Self.json(200, "{\"productAnalyticsEnabled\":\(enabled),\"canManageProductAnalytics\":\(canManage)}")
    }

    public func patchServerProductAnalyticsSettings(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["productAnalyticsEnabled"] as? Bool
        else {
            return Self.json(400, "{\"error\":\"productAnalyticsEnabled must be a boolean\"}")
        }
        oauth.setServerProductAnalytics(id: serverId, enabled: enabled)
        return Self.json(200, "{\"productAnalyticsEnabled\":\(enabled),\"canManageProductAnalytics\":true}")
    }

    public func serverDetails(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let profile = oauth.serverProfile(id: serverId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        if role == "guest" {
            return Self.json(200, "{\"id\":\(jsonString(profile.id)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"avatarUrl\":null}")
        }
        let avatar = profile.avatarUrl.map { jsonString($0) } ?? "null"
        let body = "{\"id\":\(jsonString(profile.id)),\"ownerId\":\(jsonString(profile.ownerId)),\"name\":\(jsonString(profile.name)),\"slug\":\(jsonString(profile.slug)),\"avatarUrl\":\(avatar),\"plan\":\(jsonString(profile.plan)),\"translationEnabled\":\(profile.translationEnabled),\"publiclyVisible\":\(profile.publiclyVisible),\"publicGuestJoinEnabled\":\(profile.publicGuestJoinEnabled)}"
        return Self.json(200, body)
    }

    public func setProviderConnectionsEnabled(serverId: String, enabled: Bool) {
        lock.lock()
        if enabled {
            providerConnectionsEnabledServers.insert(serverId)
        } else {
            providerConnectionsEnabledServers.remove(serverId)
        }
        lock.unlock()
    }

    public static let providerConnectionProviderIds = [
        "deepseek", "minimax", "minimax-cn", "zai", "zai-coding-cn", "moonshotai",
        "moonshotai-cn", "kimi-coding", "qwen-token-plan", "qwen-token-plan-cn",
        "openrouter", "openai", "anthropic", "google", "xai", "xiaomi",
        "openai-compatible", "anthropic-compatible",
    ]

    public func listProviderConnections(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let rows = providerConnections.filter { $0.serverId == serverId }
        lock.unlock()
        let connections = rows.map { Self.providerConnectionJSON($0) }.joined(separator: ",")
        let options = Self.providerConnectionProviderIds.map { id -> String in
            let kind = id.hasSuffix("-compatible") ? "gateway" : "preset"
            return "{\"id\":\(jsonString(id)),\"label\":\(jsonString(Self.providerConnectionLabel(id))),\"providerKind\":\(jsonString(kind))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"connections\":[\(connections)],\"providerOptions\":[\(options)]}")
    }

    public func createProviderConnection(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let providerId = object["providerId"] as? String,
              Self.providerConnectionProviderIds.contains(providerId),
              let apiKey = object["apiKey"] as? String, !apiKey.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let allowedKeys: Set<String> = ["name", "providerId", "apiKey", "endpointUrl", "supportsImageInput", "authMethod"]
        guard Set(object.keys).isSubset(of: allowedKeys) else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let now = Date()
        let connection = ProviderConnection(
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            providerId: providerId,
            endpointUrl: object["endpointUrl"] as? String,
            supportsImageInput: object["supportsImageInput"] as? Bool ?? false,
            status: "unchecked",
            configVersion: 1,
            credentialVersion: 1,
            hasCredential: true,
            createdAt: now,
            updatedAt: now
        )
        lock.lock()
        providerConnections.append(connection)
        lock.unlock()
        return Self.json(201, Self.providerConnectionJSON(connection))
    }

    public func retiredProviderProbe(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        return Self.json(410, "{\"error\":\"Provider probing is retired\"}")
    }

    public func patchProviderConnection(authorization: String?, serverId: String, connectionId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        let allowedKeys: Set<String> = ["name", "providerId", "apiKey", "endpointUrl", "supportsImageInput", "authMethod"]
        guard Set(object.keys).isSubset(of: allowedKeys) else {
            return Self.json(400, "{\"error\":\"Invalid provider connection\"}")
        }
        if object["apiKey"] != nil, object["providerId"] != nil {
            return Self.json(400, "{\"error\":\"Rotate the credential separately from provider configuration\"}")
        }
        lock.lock()
        guard let index = providerConnections.firstIndex(where: { $0.id == connectionId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        if let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providerConnections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let endpoint = object["endpointUrl"] as? String {
            providerConnections[index].endpointUrl = endpoint
        }
        if let supports = object["supportsImageInput"] as? Bool {
            providerConnections[index].supportsImageInput = supports
        }
        if let apiKey = object["apiKey"] as? String, !apiKey.isEmpty {
            providerConnections[index].credentialVersion += 1
            providerConnections[index].status = "unchecked"
            providerConnections[index].hasCredential = true
        }
        providerConnections[index].updatedAt = Date()
        let updated = providerConnections[index]
        lock.unlock()
        return Self.json(200, Self.providerConnectionJSON(updated))
    }

    public func rotateProviderConnectionCredential(authorization: String?, serverId: String, connectionId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        let enabled = providerConnectionsEnabledServers.contains(serverId)
        lock.unlock()
        guard enabled else {
            return Self.json(404, "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId), role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let apiKey = object["apiKey"] as? String, !apiKey.isEmpty
        else {
            return Self.json(400, "{\"error\":\"apiKey is required\"}")
        }
        lock.lock()
        guard let index = providerConnections.firstIndex(where: { $0.id == connectionId && $0.serverId == serverId }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        providerConnections[index].credentialVersion += 1
        providerConnections[index].status = "unchecked"
        providerConnections[index].hasCredential = true
        providerConnections[index].updatedAt = Date()
        let updated = providerConnections[index]
        lock.unlock()
        return Self.json(200, Self.providerConnectionJSON(updated))
    }

    public func pushRegistration(installationId: String, provider: String) -> PushRegistration? {
        lock.lock()
        defer { lock.unlock() }
        return pushRegistrations.first { $0.installationId == installationId && $0.provider == provider }
    }

    public func registerPushDevice(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let installationId = object["installationId"] as? String,
              installationId.wholeMatch(of: /^[A-Za-z0-9._:-]{1,128}$/) != nil,
              let provider = object["provider"] as? String, provider == "apns" || provider == "fcm",
              let topic = object["topic"] as? String,
              topic.wholeMatch(of: /^[A-Za-z0-9.-]{1,155}$/) != nil,
              let deviceToken = object["deviceToken"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid push registration\"}")
        }
        let env = object["env"] as? String ?? ""
        if provider == "apns" {
            guard env == "sandbox" || env == "production",
                  deviceToken.wholeMatch(of: /^[A-Za-z0-9._-]{1,256}$/) != nil
            else {
                return Self.json(400, "{\"error\":\"Invalid push registration\"}")
            }
        } else {
            guard env == "production",
                  deviceToken.wholeMatch(of: /^[A-Za-z0-9._:-]{1,4096}$/) != nil
            else {
                return Self.json(400, "{\"error\":\"Invalid push registration\"}")
            }
        }
        let appVersion = object["appVersion"] as? String
        lock.lock()
        let familyId = principal.familyId ?? UUID().uuidString.lowercased()
        if sessionFamilies[familyId] == nil {
            sessionFamilies[familyId] = SessionFamily(userId: principal.userId)
        }
        var nonce = sessionFamilies[familyId]?.revokeCapabilityNonce
        if nonce == nil {
            let minted = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            sessionFamilies[familyId]?.revokeCapabilityNonce = minted
            nonce = minted
        }
        let revokeCapability = "\(familyId).\(nonce ?? "")"
        if let index = pushRegistrations.firstIndex(where: {
            $0.installationId == installationId && $0.provider == provider
        }) {
            pushRegistrations[index].env = env
            pushRegistrations[index].topic = topic
            pushRegistrations[index].deviceToken = deviceToken
            pushRegistrations[index].appVersion = appVersion
            pushRegistrations[index].userId = principal.userId
            pushRegistrations[index].serverId = serverId
            pushRegistrations[index].sessionFamilyId = familyId
            pushRegistrations[index].revokeCapability = revokeCapability
        } else {
            pushRegistrations.append(PushRegistration(
                installationId: installationId,
                provider: provider,
                env: env,
                topic: topic,
                deviceToken: deviceToken,
                appVersion: appVersion,
                userId: principal.userId,
                serverId: serverId,
                sessionFamilyId: familyId,
                revokeCapability: revokeCapability
            ))
        }
        lock.unlock()
        let registration = "{\"installationId\":\(jsonString(installationId)),\"provider\":\(jsonString(provider)),\"env\":\(jsonString(env)),\"topic\":\(jsonString(topic))}"
        return Self.json(200, "{\"revoke_capability\":\(jsonString(revokeCapability)),\"registration\":\(registration)}")
    }

    public func webPushEndpoints(userId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return webPushSubscriptions.filter { $0.userId == userId }.map { $0.endpoint }
    }

    public func recordWebPushSubscription(authorization: String?, body: String) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let endpoint = object["endpoint"] as? String,
              Self.isPublicHTTPSPushEndpoint(endpoint),
              let keys = object["keys"] as? [String: Any],
              let p256dh = keys["p256dh"] as? String, !p256dh.isEmpty,
              let auth = keys["auth"] as? String, !auth.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid push subscription\"}")
        }
        lock.lock()
        if !webPushSubscriptions.contains(where: { $0.userId == principal.userId && $0.endpoint == endpoint }) {
            webPushSubscriptions.append(WebPushSubscription(userId: principal.userId, endpoint: endpoint))
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    private static func isPublicHTTPSPushEndpoint(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        if host.contains(":") { return false }
        let octets = host.split(separator: ".")
        if octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) {
            guard let first = UInt8(octets[0]), let second = UInt8(octets[1]) else { return false }
            if first == 10 || first == 127 || first == 0 { return false }
            if first == 172, (16...31).contains(second) { return false }
            if first == 192, second == 168 { return false }
            if first == 169, second == 254 { return false }
            return false
        }
        return true
    }

    public func revokePushFamily(body: String) -> HTTPReply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let capability = object["capability"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid capability\"}")
        }
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              parts[0].wholeMatch(of: /^[A-Za-z0-9-]+$/) != nil,
              parts[1].wholeMatch(of: /^[A-Za-z0-9]+$/) != nil
        else {
            return Self.json(400, "{\"error\":\"Invalid capability\"}")
        }
        lock.lock()
        guard let familyId = sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key,
              var family = sessionFamilies[familyId]
        else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Capability is no longer valid\"}")
        }
        let now = Date()
        if let revokedAt = family.revokedAt {
            if let retain = family.capabilityRetainUntil, retain > now {
                lock.unlock()
                return Self.json(204, "")
            }
            _ = revokedAt
            lock.unlock()
            return Self.json(403, "{\"error\":\"Capability is no longer valid\"}")
        }
        family.revokedAt = now
        family.revokedReason = "push_family"
        family.capabilityRetainUntil = now.addingTimeInterval(30 * 24 * 60 * 60)
        sessionFamilies[familyId] = family
        let refreshTokens = sessions.filter { $0.value.familyId == familyId }.map { $0.key }
        for token in refreshTokens { sessions.removeValue(forKey: token) }
        let accessTokensToDrop = accessTokenFamilies.filter { $0.value == familyId }.map { $0.key }
        for token in accessTokensToDrop {
            accessTokens.removeValue(forKey: token)
            accessTokenFamilies.removeValue(forKey: token)
        }
        lock.unlock()
        return Self.json(204, "")
    }

    public func pushFamilyStatus(capability: String) -> (revoked: Bool, reason: String?, retainUntil: Date?)? {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let family = sessionFamilies.values.first(where: { $0.revokeCapabilityNonce == parts[1] }) else {
            return nil
        }
        return (family.revokedAt != nil, family.revokedReason, family.capabilityRetainUntil)
    }

    public func expirePushFamilyCapability(capability: String) {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return }
        lock.lock()
        if let familyId = sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key {
            sessionFamilies[familyId]?.capabilityRetainUntil = Date().addingTimeInterval(-1)
        }
        lock.unlock()
    }

    public func pushDeliveryStatus(authorization: String?, installationId: String?) -> HTTPReply {
        guard let principal = pushPrincipal(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let installationId, installationId.wholeMatch(of: /^[A-Za-z0-9._:-]{1,128}$/) != nil else {
            return Self.json(400, "{\"error\":\"Valid installationId is required\"}")
        }
        lock.lock()
        let active = fcmPushAvailable && pushRegistrations.contains {
            $0.installationId == installationId
                && $0.provider == "fcm"
                && $0.userId == principal.userId
        }
        lock.unlock()
        let servers = oauth.serverIdsForMember(userId: principal.userId).sorted()
        let rows = servers.map { "\"\($0)\":{\"fcmActive\":\(active ? "true" : "false")}" }.joined(separator: ",")
        return Self.json(200, "{\"servers\":{\(rows)}}")
    }

    public func unbindPushInstallation(authorization: String?, serverId: String, installationId: String) -> HTTPReply {
        guard pushPrincipal(authorization) != nil else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        lock.lock()
        var unbound = 0
        for index in pushRegistrations.indices where pushRegistrations[index].installationId == installationId {
            pushRegistrations[index].userId = nil
            pushRegistrations[index].serverId = nil
            pushRegistrations[index].sessionFamilyId = nil
            unbound += 1
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"unbound\":\(unbound)}")
    }

    private func pushPrincipal(_ authorization: String?) -> (userId: String, familyId: String?)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let userId = accessTokens[token]
        let familyId = accessTokenFamilies[token]
        lock.unlock()
        guard let userId else { return nil }
        return (userId, familyId)
    }

    public func assignAgentToProviderConnection(connectionId: String, serverId: String, agentId: String, computerName: String?) {
        lock.lock()
        providerAssignments.append(ProviderAssignment(
            connectionId: connectionId,
            serverId: serverId,
            agentId: agentId,
            computerName: computerName
        ))
        lock.unlock()
    }

    public func listAssignedProviderAgents(authorization: String?, serverId: String, connectionId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let known = providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assignments = providerAssignments.filter { $0.connectionId == connectionId && $0.serverId == serverId }
        lock.unlock()
        guard known else {
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        var rows: [String] = []
        for assignment in assignments {
            guard let info = oauth.providerAgentInfo(serverId: serverId, agentId: assignment.agentId) else { continue }
            let computer = assignment.computerName.map { jsonString($0) } ?? "null"
            rows.append("{\"id\":\(jsonString(assignment.agentId)),\"name\":\(jsonString(info.name)),\"displayName\":\(jsonString(info.displayName)),\"runtime\":\(jsonString(info.runtime)),\"status\":\(jsonString(info.status)),\"computerName\":\(computer),\"deleted\":\(info.deleted)}")
        }
        return Self.json(200, "{\"agents\":[\(rows.joined(separator: ","))]}")
    }

    public func detachProviderAgent(authorization: String?, serverId: String, connectionId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard agentId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return Self.json(400, "{\"error\":\"Invalid agent id\"}")
        }
        lock.lock()
        let known = providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assigned = providerAssignments.contains { $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId }
        lock.unlock()
        guard known else {
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        guard assigned else {
            return Self.json(404, "{\"error\":\"Provider agent assignment not found\"}")
        }
        let live = oauth.providerAgentInfo(serverId: serverId, agentId: agentId).map { !$0.deleted } ?? false
        if live {
            return Self.json(409, "{\"error\":\"The Agent still uses this provider connection\",\"code\":\"provider_connection_assignment_active\"}")
        }
        lock.lock()
        providerAssignments.removeAll { $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func deleteProviderConnection(authorization: String?, serverId: String, connectionId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" || oauth.memberRole(serverId: serverId, userId: userId) == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let known = providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assignments = providerAssignments.filter { $0.connectionId == connectionId && $0.serverId == serverId }
        lock.unlock()
        guard known else {
            return Self.json(404, "{\"error\":\"Provider connection not found\"}")
        }
        let liveAssignments = assignments.filter { assignment in
            oauth.providerAgentInfo(serverId: serverId, agentId: assignment.agentId).map { !$0.deleted } ?? false
        }
        guard liveAssignments.isEmpty else {
            return Self.json(409, "{\"error\":\"Agents still use this provider connection\",\"code\":\"provider_connection_assignment_active\"}")
        }
        lock.lock()
        providerConnections.removeAll { $0.id == connectionId && $0.serverId == serverId }
        providerAssignments.removeAll { $0.connectionId == connectionId && $0.serverId == serverId }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    private struct WebPushSubscription: Sendable {
        var userId: String
        var endpoint: String
    }

    public struct PushRegistration: Sendable {
        public var installationId: String
        public var provider: String
        public var env: String
        public var topic: String
        public var deviceToken: String
        public var appVersion: String?
        public var userId: String?
        public var serverId: String?
        public var sessionFamilyId: String?
        public var revokeCapability: String
    }

    private struct ProviderAssignment {
        var connectionId: String
        var serverId: String
        var agentId: String
        var computerName: String?
    }

    private static func providerConnectionLabel(_ id: String) -> String {
        switch id {
        case "openai-compatible": return "OpenAI compatible"
        case "anthropic-compatible": return "Anthropic compatible"
        case "minimax-cn": return "MiniMax CN"
        case "zai-coding-cn": return "Z.ai Coding CN"
        case "moonshotai-cn": return "Moonshot AI CN"
        case "kimi-coding": return "Kimi Coding"
        case "qwen-token-plan": return "Qwen Token Plan"
        case "qwen-token-plan-cn": return "Qwen Token Plan CN"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    private static func providerConnectionJSON(_ connection: ProviderConnection) -> String {
        let endpoint = connection.endpointUrl.map { jsonString($0) } ?? "null"
        return "{\"id\":\(jsonString(connection.id)),\"name\":\(jsonString(connection.name)),\"providerId\":\(jsonString(connection.providerId)),\"authMethod\":\"api_key\",\"endpointUrl\":\(endpoint),\"supportsImageInput\":\(connection.supportsImageInput),\"enabled\":true,\"status\":\(jsonString(connection.status)),\"configVersion\":\(connection.configVersion),\"credentialVersion\":\(connection.credentialVersion),\"hasCredential\":\(connection.hasCredential),\"assignedAgentCount\":0,\"latestVerified\":null,\"lastCheckedAt\":null,\"lastErrorCategory\":null,\"createdAt\":\(jsonString(ISO8601DateFormatter().string(from: connection.createdAt))),\"updatedAt\":\(jsonString(ISO8601DateFormatter().string(from: connection.updatedAt)))}"
    }

    private struct ProviderConnection {
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
    }

    /// `POST /api/product-feedback`. The upstream proxy is not ported; the
    /// route still enforces the auth, form, and configuration contract.
    public func submitProductFeedback(authorization: String?, contentType: String, body: String) -> HTTPReply {
        guard sessionUserId(authorization: authorization) != nil else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let fields = Self.multipartFields(body: body, contentType: contentType),
              let submissionId = fields["submission_id"],
              submissionId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil,
              let type = fields["type"], ["idea", "problem"].contains(type),
              let message = fields["message"], !message.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
        }
        if let rawMetadata = fields["metadata"], !rawMetadata.isEmpty {
            guard let metadata = (try? JSONSerialization.jsonObject(with: Data(rawMetadata.utf8))) as? [String: Any] else {
                return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
            }
            let nativeKinds = ["ios", "android", "macos", "windows", "linux"]
            if let clientKind = metadata["client_kind"] as? String, nativeKinds.contains(clientKind) {
                let platform = metadata["platform"] as? String ?? ""
                if platform != clientKind || metadata["browser"] != nil {
                    return Self.json(400, "{\"error\":\"Invalid feedback submission\",\"code\":\"feedback_invalid\"}")
                }
            }
        }
        guard handsFeedbackConfigured else {
            return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_not_configured\"}")
        }
        return Self.json(503, "{\"error\":\"Feedback service is temporarily unavailable\",\"code\":\"feedback_integration_unavailable\"}")
    }

    private static func multipartFields(body: String, contentType: String) -> [String: String]? {
        guard let boundaryRange = contentType.range(of: "boundary=") else { return nil }
        var boundary = String(contentType[boundaryRange.upperBound...])
        boundary = boundary.split(separator: ";").first.map(String.init) ?? boundary
        boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" \""))
        guard !boundary.isEmpty else { return nil }
        var fields: [String: String] = [:]
        for part in body.components(separatedBy: "--\(boundary)") {
            guard part.contains("name=\"") else { continue }
            let segments = part.components(separatedBy: "\r\n\r\n")
            guard segments.count >= 2 else { continue }
            let header = segments[0]
            guard let nameRange = header.range(of: "name=\"") else { continue }
            let rest = header[nameRange.upperBound...]
            guard let closing = rest.firstIndex(of: "\"") else { continue }
            let name = String(rest[..<closing])
            var value = segments[1]
            if value.hasSuffix("\r\n") { value.removeLast() }
            fields[name] = value
        }
        return fields.isEmpty ? nil : fields
    }

    /// `POST /api/product-events/onboarding-wizard`.
    public func recordOnboardingWizard(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let serverEnabled = oauth.serverAnalyticsAllowed(id: serverId), serverEnabled else {
            return Self.json(204, "")
        }
        lock.lock()
        let shareUsageData = accounts.values.first(where: { $0.id == userId })?.shareUsageData
        lock.unlock()
        if shareUsageData == false {
            return Self.json(204, "")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let eventType = object["eventType"] as? String, !eventType.isEmpty,
              let rawMetadata = object["metadata"] as? [String: Any]
        else {
            return Self.json(400, "{\"error\":\"Invalid product event\"}")
        }
        let stepId = rawMetadata["step_id"] as? String ?? ""
        if eventType == "onboarding_wizard.step_shown", stepId == "enable-notifications" {
            return Self.json(400, "{\"error\":\"Only tracked onboarding wizard steps are accepted\"}")
        }
        let allowedKeys = ["step_id", "wizard_version", "session_id", "action", "result", "reason"]
        var sanitized: [String: Any] = [:]
        for key in allowedKeys {
            if let value = rawMetadata[key] as? String { sanitized[key] = value }
        }
        if let latency = rawMetadata["latency_ms"] as? Double {
            sanitized["latency_ms"] = Int(latency)
        } else if let latency = rawMetadata["latency_ms"] as? Int {
            sanitized["latency_ms"] = latency
        }
        let metadataJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]) {
            metadataJSON = String(decoding: data, as: UTF8.self)
        } else {
            metadataJSON = "{}"
        }
        let record = RecordedProductEvent(
            subjectType: "onboarding_wizard",
            subjectId: serverId,
            eventType: eventType,
            actorType: "human",
            actorId: userId,
            source: "web",
            idempotencyKey: object["idempotencyKey"] as? String,
            metadataJSON: metadataJSON
        )
        lock.lock()
        productEventRecords.append(record)
        lock.unlock()
        return Self.json(204, "")
    }

    private func authorize(_ authorization: String?) -> Auth {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return .rejected(Self.missingAuthorization)
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let id = accessTokens[token]
        lock.unlock()
        guard let id else { return .rejected(Self.invalidToken) }
        return .user(id)
    }

    private enum DisplayLanguage {
        case value(String?)
        case invalid(String)
    }

    /// Shipped UI catalogs only. Region tags collapse inside `en` and `zh-cn`; `zh-TW` and `fr` do not.
    static func normalizeDisplayLocale(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return nil }
        if value == "en" || value.hasPrefix("en-") { return "en" }
        if value == "zh-cn" || value == "zh" || value == "zh-hans" || value == "zh-hans-cn" { return "zh-cn" }
        return nil
    }

    private static func parseDisplayLanguage(_ raw: Any) -> DisplayLanguage {
        if raw is NSNull { return .value(nil) }
        guard let string = raw as? String else {
            return .invalid("displayLanguage must be a string or null")
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .value(nil) }
        guard let normalized = normalizeDisplayLocale(trimmed) else {
            return .invalid("displayLanguage must be a supported UI display locale")
        }
        return .value(normalized)
    }

    private static func userJSON(_ account: Account) -> String {
        let hash = sha256(account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let language = account.displayLanguage.map { jsonString($0) } ?? "null"
        let provider = account.profileSetupProvider.map { jsonString($0) } ?? "null"
        let displayName = jsonString(account.displayName ?? account.name)
        let suggestedHandle = account.profileSetupSuggestedHandle.map { jsonString($0) } ?? "null"
        let completedAt: String
        if let completed = account.profileSetupCompletedAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            completedAt = jsonString(formatter.string(from: completed))
        } else {
            completedAt = "null"
        }
        let avatar = account.avatarUrl.map { jsonString($0) } ?? "null"
        let share: String
        if let value = account.shareUsageData {
            share = value ? "true" : "false"
        } else {
            share = "null"
        }
        let preferredLanguage = account.preferredLanguage.map { jsonString($0) } ?? "null"
        let preferredTimezone = account.preferredTimezone.map { jsonString($0) } ?? "null"
        let preferredTimeFormat = account.preferredTimeFormat.map { jsonString($0) } ?? "null"
        let preferredFontSize = account.preferredMessageBodyFontSize.map { jsonString($0) } ?? "null"
        let referralSource = account.referralSource.map { jsonString($0) } ?? "null"
        let referralOther = account.referralSourceOther.map { jsonString($0) } ?? "null"
        let skippedAt: String
        if let date = account.referralSourceSkippedAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            skippedAt = jsonString(formatter.string(from: date))
        } else {
            skippedAt = "null"
        }
        return "{\"id\":\(jsonString(account.id)),\"email\":\(jsonString(account.email)),\"name\":\(jsonString(account.name)),\"displayName\":\(displayName),\"gravatarHash\":\(jsonString(hash)),\"displayLanguage\":\(language),\"profileSetupCompletedAt\":\(completedAt),\"profileSetupSuggestedHandle\":\(suggestedHandle),\"profileSetupProvider\":\(provider),\"avatarUrl\":\(avatar),\"shareUsageData\":\(share),\"preferredLanguage\":\(preferredLanguage),\"preferredTimezone\":\(preferredTimezone),\"preferredTranslationMode\":\(jsonString(account.preferredTranslationMode)),\"autoTranslationEnabled\":\(account.autoTranslationEnabled),\"preferredTranslationDisplay\":\(jsonString(account.preferredTranslationDisplay)),\"preferredTimeFormat\":\(preferredTimeFormat),\"preferredMessageBodyFontSize\":\(preferredFontSize),\"referralSource\":\(referralSource),\"referralSourceOther\":\(referralOther),\"referralSourceSkippedAt\":\(skippedAt)}"
    }

    private static let reservedAgentNames: Set<String> = [
        "all", "human", "humans", "agent", "agents", "here", "idle", "busy", "system", "reminders",
    ]

    /// Final handles stay unclaimed until profile setup. The stored name is `pending_` plus 20 hex characters.
    static func pendingHandle(taken: Set<String>) -> String {
        for _ in 0..<10 {
            let handle = "pending_\(randomHex(10))"
            if !taken.contains(handle) { return handle }
        }
        return "pending_\(randomHex(10))"
    }

    static func slugifyUserName(_ seed: String) -> String {
        let lowered = seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var normalized = ""
        for scalar in lowered.unicodeScalars {
            let value = scalar.value
            let allowed = (value >= 97 && value <= 122) || (value >= 48 && value <= 57) || value == 95 || value == 45
            normalized.append(allowed ? Character(scalar) : "-")
        }
        normalized = trimHyphens(normalized)
        let prefixed = normalized.first?.isLetter == true ? normalized : "user-\(normalized)"
        var compact = ""
        var previousHyphen = false
        for character in prefixed {
            if character == "-" {
                if previousHyphen { continue }
                previousHyphen = true
            } else {
                previousHyphen = false
            }
            compact.append(character)
        }
        compact = trimHyphens(compact)
        let fallback = compact.isEmpty ? "user-account" : compact
        return fallback.count >= 5 ? fallback : "\(fallback)-user"
    }

    static func availableUserName(seed: String, taken: Set<String>) -> String {
        let base = slugifyUserName(seed)
        if !taken.contains(base) { return base }
        for suffix in 1..<100 {
            let candidate = "\(base)-\(suffix + 1)"
            if !taken.contains(candidate) { return candidate }
        }
        return "\(base)-\(randomHex(2))"
    }

    private static func trimHyphens(_ value: String) -> String {
        var text = value
        while text.hasPrefix("-") { text.removeFirst() }
        while text.hasSuffix("-") { text.removeLast() }
        return text
    }

    private static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `dm:@reminders` names an agent's private reminder conversation, so the handle is reserved.
    static func isReservedAgentName(_ name: String) -> Bool {
        var normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("@") { normalized.removeFirst() }
        return reservedAgentNames.contains(normalized.lowercased())
    }

    private static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let maxProfileAvatarBytes = 5 * 1024 * 1024

    public static func sha256Hex(_ value: String) -> String {
        sha256(value)
    }

    private static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func multipartFile(named name: String, contentType: String?, body: Data) -> Data? {
        guard let boundary = boundaryParameter(contentType) else { return nil }
        let delimiter = Data("--\(boundary)".utf8)
        let headerBreak = Data("\r\n\r\n".utf8)
        let crlf = Data("\r\n".utf8)
        let marker = "name=\"\(name)\""
        var remainder = body[body.startIndex...]
        var parts: [Data] = []
        while let range = remainder.range(of: delimiter) {
            let piece = remainder[..<range.lowerBound]
            if !piece.isEmpty { parts.append(Data(piece)) }
            remainder = remainder[range.upperBound...]
        }
        if !remainder.isEmpty { parts.append(Data(remainder)) }
        for var part in parts {
            if part.starts(with: crlf) { part.removeFirst(crlf.count) }
            guard let split = part.range(of: headerBreak) else { continue }
            let headers = part[..<split.lowerBound]
            var file = Data(part[split.upperBound...])
            if file.count >= crlf.count, file.suffix(crlf.count) == crlf {
                file.removeLast(crlf.count)
            }
            guard let headerText = String(data: Data(headers), encoding: .utf8), headerText.contains(marker) else { continue }
            return file
        }
        return nil
    }

    private static func boundaryParameter(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        for part in contentType.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(trimmed.dropFirst("boundary=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func refreshAttempt(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^arf_[0-9a-f]{16}$/) != nil else { return nil }
        return trimmed
    }

    static func refreshInstallation(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^ari_[0-9a-f]{32}$/) != nil else { return nil }
        return trimmed
    }

    public static func signSocialAuthState(_ state: SocialAuthState) -> String {
        let header = base64url(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8))
        var payload: [String: Any] = [
            "provider": state.provider,
            "mode": state.mode,
            "nonce": state.nonce,
            "kind": state.kind,
            "mobileRequestId": state.mobileRequestId,
            "iss": "slock-social-auth",
            "aud": "social-auth-state",
            "exp": Int(Date().timeIntervalSince1970) + 600,
        ]
        if let desktopNonce = state.desktopNonce {
            payload["desktopNonce"] = desktopNonce
        }
        if let returnTo = state.returnTo {
            payload["returnTo"] = returnTo
        }
        if let linkUserId = state.linkUserId {
            payload["linkUserId"] = linkUserId
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let body = base64url(encoded)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("\(header).\(body)".utf8), using: stateKey))
        return "\(header).\(body).\(base64url(mac))"
    }

    public static func verifySocialAuthState(_ token: String) -> SocialAuthState? {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3 else { return nil }
        let signing = Data("\(parts[0]).\(parts[1])".utf8)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: signing, using: stateKey))
        guard let given = base64urlDecode(parts[2]), given == expected else { return nil }
        guard let payload = base64urlDecode(parts[1]),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let provider = object["provider"] as? String,
              let mode = object["mode"] as? String,
              let nonce = object["nonce"] as? String,
              let kind = object["kind"] as? String,
              let requestId = object["mobileRequestId"] as? String,
              (object["iss"] as? String) == "slock-social-auth",
              (object["aud"] as? String) == "social-auth-state"
        else { return nil }
        let exp = (object["exp"] as? NSNumber)?.intValue ?? (object["exp"] as? Int) ?? 0
        if exp < Int(Date().timeIntervalSince1970) { return nil }
        return SocialAuthState(
            provider: provider,
            mode: mode,
            nonce: nonce,
            kind: kind,
            mobileRequestId: requestId,
            desktopNonce: object["desktopNonce"] as? String,
            returnTo: object["returnTo"] as? String,
            linkUserId: object["linkUserId"] as? String
        )
    }

    private static let stateKey = SymmetricKey(data: Data(SHA256.hash(data: Data("slock-social-auth-state".utf8))))

    private static func isDesktopLoopback(_ returnUri: String) -> Bool {
        guard let url = URL(string: returnUri),
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.path == "/auth/done",
              let port = url.port,
              (1024...65535).contains(port),
              let fragment = url.fragment,
              fragment.wholeMatch(of: /^state=[A-Za-z0-9_-]{16,256}$/) != nil
        else { return false }
        return url.absoluteString == returnUri || "\(url.absoluteString)" == returnUri
    }

    private static func desktopNonce(from returnUri: String) -> String? {
        guard isDesktopLoopback(returnUri), let fragment = URL(string: returnUri)?.fragment else { return nil }
        return String(fragment.dropFirst("state=".count))
    }

    private static func authorizationURL(provider: String, state: String) -> String {
        switch provider {
        case "github":
            var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: "configured"),
                URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1/api/auth/github/callback"),
                URLQueryItem(name: "scope", value: "read:user user:email"),
                URLQueryItem(name: "state", value: state),
            ]
            return components.string ?? ""
        default:
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: "configured"),
                URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1/api/auth/google/callback"),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "openid email profile"),
                URLQueryItem(name: "state", value: state),
            ]
            return components.string ?? ""
        }
    }

    private static func pkceS256(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func failureLocation(returnUri: String, provider: String, mode: String, error: String) -> String {
        let pieces = returnUri.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let base = pieces[0]
        let hash = pieces.count > 1 ? "#\(pieces[1])" : ""
        let separator = base.contains("?") ? "&" : "?"
        return "\(base)\(separator)provider=\(provider)&mode=\(mode)&error=\(error)\(hash)"
    }

    private static func loopbackLocation(returnUri: String, provider: String, mode: String, code: String) -> String {
        let pieces = returnUri.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let base = pieces[0]
        let hash = pieces.count > 1 ? "#\(pieces[1])" : ""
        let separator = base.contains("?") ? "&" : "?"
        return "\(base)\(separator)provider=\(provider)&mode=\(mode)&code=\(code)\(hash)"
    }

    private static func redirect(_ location: String, cookie: String? = nil) -> HTTPReply {
        var headers = [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Location": location,
            "Content-Length": "0",
        ]
        if let cookie { headers["Set-Cookie"] = cookie }
        return HTTPReply(status: 302, headers: headers, body: "")
    }

    private static func isMobileUnsubscribeUserId(_ value: String) -> Bool {
        value.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.ignoresCase()) != nil
    }

    private static func mobileAppUnsubscribeLocale(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if value == "zh-cn" || value == "zh" || value == "zh-hans" || value == "zh-hans-cn" { return "zh-cn" }
        if value == "en" || value.hasPrefix("en-") { return "en" }
        return "en"
    }

    private static func mobileAppUnsubscribeSignature(payload: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let message = Data("mobile-app-email-unsubscribe:v1:\(payload)".utf8)
        return base64url(Data(HMAC<SHA256>.authenticationCode(for: message, using: key)))
    }

    private func verifyMobileAppEmailUnsubscribeToken(_ token: String) -> (userId: String, locale: String)? {
        guard !token.isEmpty, token.count <= 512 else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let expected = Self.mobileAppUnsubscribeSignature(payload: parts[0], secret: mobileAppEmailUnsubscribeSecret)
        guard parts[1] == expected else { return nil }
        guard let data = Self.base64urlDecode(parts[0]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.sorted().joined(separator: ",") == "locale,sub,typ,v"
        else { return nil }
        let version = (object["v"] as? NSNumber)?.intValue ?? (object["v"] as? Int)
        guard version == 1,
              (object["typ"] as? String) == "mobile-app-email-unsubscribe",
              let userId = object["sub"] as? String,
              Self.isMobileUnsubscribeUserId(userId),
              let locale = object["locale"] as? String,
              locale == "en" || locale == "zh-cn"
        else { return nil }
        return (userId, locale)
    }

    /// `GET /api/email/mobile-app/unsubscribe`. A valid token shows the confirmation page and writes nothing.
    public func mobileAppEmailUnsubscribePage(token: String?) -> HTTPReply {
        guard let token, let identity = verifyMobileAppEmailUnsubscribeToken(token) else {
            return Self.mobileAppUnsubscribeInvalid()
        }
        let copy = Self.mobileAppUnsubscribeCopy(identity.locale)
        let action = "/api/email/mobile-app/unsubscribe?token=\(Self.urlQuery(token))&source=visible"
        let body = "<h1 style=\"margin:0 0 12px;font-size:22px;\">\(copy.confirmationHeading)</h1><p style=\"margin:0 0 20px;line-height:1.5;\">\(copy.confirmationBody)</p><form method=\"post\" action=\"\(action)\"><input type=\"hidden\" name=\"List-Unsubscribe\" value=\"One-Click\"><button type=\"submit\" style=\"cursor:pointer;padding:10px 16px;border:2px solid #141111;border-radius:8px;background:#fe7da8;color:#141111;font:inherit;font-weight:700;box-shadow:2px 2px 0 #141111;\">\(copy.submit)</button></form>"
        return Self.mobileAppUnsubscribeHTML(lang: copy.htmlLang, title: copy.confirmationTitle, body: body)
    }

    /// `POST /api/email/mobile-app/unsubscribe`. One-click is an empty 200. A visible submit is the success page.
    public func mobileAppEmailUnsubscribeSubmit(token: String?, source: String?, body: String) -> HTTPReply {
        guard let token, let identity = verifyMobileAppEmailUnsubscribeToken(token),
              Self.formField(body, "List-Unsubscribe") == "One-Click"
        else { return Self.mobileAppUnsubscribeInvalid() }
        recordMobileAppEmailOptOut(userId: identity.userId)
        let copy = Self.mobileAppUnsubscribeCopy(identity.locale)
        if source == "visible" {
            let page = "<h1 style=\"margin:0 0 12px;font-size:22px;\">\(copy.successHeading)</h1><p style=\"margin:0;line-height:1.5;\">\(copy.successBody)</p>"
            return Self.mobileAppUnsubscribeHTML(lang: copy.htmlLang, title: copy.successTitle, body: page)
        }
        return Self.text(200, "")
    }

    private func recordMobileAppEmailOptOut(userId: String) {
        lock.lock()
        guard let account = accounts.values.first(where: { $0.id == userId }) else {
            lock.unlock()
            return
        }
        let email = Self.normalize(account.email)
        guard !email.isEmpty else {
            lock.unlock()
            return
        }
        let audienceId = "mobile-app-lifecycle"
        mobileAppEmailContactsByKey["\(audienceId)\n\(email)"] = MobileAppEmailContact(
            userId: userId,
            email: email,
            audienceId: audienceId,
            status: "unsubscribed",
            optedOutAt: Date()
        )
        let emailIds = storedMobileAppEmailJourneys.compactMap { row -> String? in
            guard row.journeyKey == "first_computer_mobile_app_48h",
                  row.day1Status == "scheduled",
                  let emailId = row.day1EmailId,
                  !emailId.isEmpty,
                  row.userId == userId || Self.normalize(row.email) == email
            else { return nil }
            return emailId
        }
        let cancel = cancelMobileAppEmail
        lock.unlock()
        for emailId in emailIds {
            cancel?(emailId)
        }
        guard !emailIds.isEmpty else { return }
        lock.lock()
        let canceledAt = Date()
        for index in storedMobileAppEmailJourneys.indices {
            let row = storedMobileAppEmailJourneys[index]
            guard row.journeyKey == "first_computer_mobile_app_48h",
                  row.day1Status == "scheduled",
                  let emailId = row.day1EmailId,
                  emailIds.contains(emailId),
                  row.userId == userId || Self.normalize(row.email) == email
            else { continue }
            storedMobileAppEmailJourneys[index].day1Status = "skipped"
            storedMobileAppEmailJourneys[index].suppressedReason = "unsubscribed"
            storedMobileAppEmailJourneys[index].canceledAt = canceledAt
        }
        lock.unlock()
    }

    private static func mobileAppUnsubscribeCopy(_ locale: String) -> (htmlLang: String, confirmationTitle: String, confirmationHeading: String, confirmationBody: String, submit: String, successTitle: String, successHeading: String, successBody: String, invalidTitle: String, invalidHeading: String, invalidBody: String) {
        if locale == "zh-cn" {
            return (
                "zh-CN",
                "退订 Raft 移动端应用邮件",
                "要退订移动端应用邮件吗？",
                "Raft 将不再向你发送关于移动端应用的邮件。",
                "退订",
                "已退订",
                "你已退订。",
                "Raft 不会再向你发送移动端应用邮件。",
                "退订链接无效",
                "这个退订链接无效。",
                "请使用 Raft 原始邮件中的链接。"
            )
        }
        return (
            "en",
            "Unsubscribe from Raft mobile-app emails",
            "Unsubscribe from mobile-app emails?",
            "Raft will stop sending you emails about the mobile app.",
            "Unsubscribe",
            "Unsubscribed",
            "You are unsubscribed.",
            "Raft will no longer send you mobile-app emails.",
            "Invalid unsubscribe link",
            "This unsubscribe link is invalid.",
            "Please use the link from the original Raft email."
        )
    }

    private static func mobileAppUnsubscribeInvalid() -> HTTPReply {
        let copy = mobileAppUnsubscribeCopy("en")
        let body = "<h1 style=\"margin:0 0 12px;font-size:22px;\">\(copy.invalidHeading)</h1><p style=\"margin:0;line-height:1.5;\">\(copy.invalidBody)</p>"
        return mobileAppUnsubscribeHTML(status: 400, lang: copy.htmlLang, title: copy.invalidTitle, body: body)
    }

    private static func mobileAppUnsubscribeHTML(status: Int = 200, lang: String, title: String, body: String) -> HTTPReply {
        let page = """
        <!doctype html>
        <html lang="\(lang)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title)</title>
        </head>
        <body style="margin:0;padding:40px 20px;background:#fffaf0;color:#141111;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
          <main style="box-sizing:border-box;max-width:520px;margin:0 auto;padding:28px;background:#fff;border:2px solid #141111;border-radius:16px;box-shadow:4px 4px 0 #141111;">
            \(body)
          </main>
        </body>
        </html>
        """
        return HTTPReply(
            status: status,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Cache-Control": "no-store",
                "Referrer-Policy": "no-referrer",
                "Content-Type": "text/html; charset=utf-8",
            ],
            body: page
        )
    }

    private static func formField(_ body: String, _ name: String) -> String? {
        for pair in body.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.first?.removingPercentEncoding == name || parts.first == name else { continue }
            let raw = parts.count > 1 ? parts[1] : ""
            return raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        }
        return nil
    }

    private static func urlQuery(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64urlDecode(_ value: String) -> Data? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)
    }

    private static func text(_ status: Int, _ body: String) -> HTTPReply {
        HTTPReply(
            status: status,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }

    private static func sealSuccessor(_ token: String) -> String {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data("slock-session-refresh-rotation-receipt".utf8))))
        if let sealed = try? AES.GCM.seal(Data(token.utf8), using: key) {
            return sealed.ciphertext.base64EncodedString()
        }
        return sha256("sealed:\(token)")
    }

    private static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static let appleNotConfigured = json(404, "{\"code\":\"provider_not_configured\",\"error\":\"Apple sign-in is not configured\"}")
    private static let nativeAppleInvalidRequest = json(400, "{\"code\":\"invalid_request\",\"error\":\"Native Apple sign-in requires the iOS platform and app environment\"}")
    private static let nativeAppleInvalidCredential = json(400, "{\"code\":\"native_apple_invalid_credential\",\"error\":\"Apple sign-in credential was invalid\"}")
    private static let nativeAppleAuthRequired = json(401, "{\"code\":\"auth_required\",\"error\":\"Apple account linking requires authentication\"}")
    private static let nativeAppleLinkMismatch = json(403, "{\"code\":\"link_user_mismatch\",\"error\":\"Apple account linking does not match the authenticated user\"}")
    private static let nativeAppleRequestExpired = json(410, "{\"code\":\"native_apple_request_expired\",\"error\":\"Apple sign-in request expired\"}")
    private static let nativeAppleRequestConsumed = json(410, "{\"code\":\"native_apple_request_consumed\",\"error\":\"Apple sign-in request was already used\"}")

    private struct NativeAppleRequestClaims {
        var requestId: String
        var mode: String
        var codeChallenge: String
        var userId: String?
    }

    private enum NativeAppleRequestToken {
        case valid(NativeAppleRequestClaims)
        case expired
        case invalid
    }

    private struct AppleIdentityClaims {
        var subject: String
        var nonce: String
        var email: String?
    }

    private func nativeAppleAvailable() -> Bool {
        lock.lock()
        let configured = !nativeAppleClientId.isEmpty && !nativeAppleClientSecret.isEmpty
        let gate = appleLoginPlatforms.contains("mobile")
        lock.unlock()
        return configured && gate
    }

    public static func signNativeAppleRequestToken(secret: String, requestId: String, mode: String, codeChallenge: String, expiresAt: Date, userId: String? = nil) -> String {
        let header = base64url(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8))
        var payload: [String: Any] = [
            "kind": "native_apple_ios",
            "requestId": requestId,
            "mode": mode,
            "codeChallenge": codeChallenge,
            "iss": "slock-native-apple-auth",
            "aud": "native-apple-auth-request",
            "exp": Int(expiresAt.timeIntervalSince1970),
        ]
        if let userId { payload["userId"] = userId }
        let encoded = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let body = base64url(encoded)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("\(header).\(body)".utf8), using: key))
        return "\(header).\(body).\(base64url(mac))"
    }

    private static func verifyNativeAppleRequestToken(_ token: String, secret: String) -> NativeAppleRequestToken {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let headerData = base64urlDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else { return .invalid }
        guard header["alg"] as? String == "HS256" else { return .invalid }
        let key = SymmetricKey(data: Data(secret.utf8))
        let signing = Data("\(parts[0]).\(parts[1])".utf8)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: signing, using: key))
        guard let given = base64urlDecode(parts[2]), given == expected else { return .invalid }
        guard let payloadData = base64urlDecode(parts[1]),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              object["kind"] as? String == "native_apple_ios",
              let requestId = object["requestId"] as? String, !requestId.isEmpty,
              let mode = object["mode"] as? String, mode == "login" || mode == "link",
              let challenge = object["codeChallenge"] as? String,
              challenge.wholeMatch(of: /^[A-Za-z0-9_-]{32,256}$/) != nil,
              (object["iss"] as? String) == "slock-native-apple-auth",
              (object["aud"] as? String) == "native-apple-auth-request"
        else { return .invalid }
        let tokenUserId: String?
        if object["userId"] == nil || object["userId"] is NSNull {
            tokenUserId = nil
        } else if let id = object["userId"] as? String, !id.isEmpty {
            tokenUserId = id
        } else {
            return .invalid
        }
        let exp = (object["exp"] as? NSNumber)?.intValue ?? (object["exp"] as? Int) ?? 0
        if exp < Int(Date().timeIntervalSince1970) { return .expired }
        return .valid(NativeAppleRequestClaims(requestId: requestId, mode: mode, codeChallenge: challenge, userId: tokenUserId))
    }

    private func parseAppleIdentity(_ token: String) -> AppleIdentityClaims? {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let headerData = Self.base64urlDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let payloadData = Self.base64urlDecode(parts[1]),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              object["iss"] as? String == "https://appleid.apple.com",
              object["aud"] as? String == nativeAppleClientId,
              let subject = object["sub"] as? String, !subject.isEmpty,
              let nonce = object["nonce"] as? String, !nonce.isEmpty
        else { return nil }
        let exp = (object["exp"] as? NSNumber)?.intValue ?? (object["exp"] as? Int) ?? 0
        if exp < Int(Date().timeIntervalSince1970) { return nil }
        let rawEmail = (object["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if rawEmail.isEmpty {
            return AppleIdentityClaims(subject: subject, nonce: nonce, email: nil)
        }
        let verified: Bool
        if let flag = object["email_verified"] as? Bool {
            verified = flag
        } else if let flag = object["email_verified"] as? String {
            verified = flag == "true"
        } else {
            verified = false
        }
        guard verified else { return nil }
        return AppleIdentityClaims(subject: subject, nonce: nonce, email: rawEmail)
    }

    private func mobileAppleAvailable() -> Bool {
        lock.lock()
        let configured = configuredSocialAuthProviders.contains("apple")
        let allowed = appleLoginPlatforms.contains("mobile")
        lock.unlock()
        return configured && allowed
    }

    private func webProviderAvailable(_ provider: String) -> Bool {
        lock.lock()
        let configured = configuredSocialAuthProviders.contains(provider)
        let allowed = appleLoginPlatforms.contains("web")
        lock.unlock()
        guard configured else { return false }
        if provider == "apple" { return allowed }
        return true
    }

    private func webAuthorizationURL(provider: String, state: String, nonce: String) -> String {
        guard provider == "apple" else {
            return Self.authorizationURL(provider: provider, state: state)
        }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        var components = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appleClientId),
            URLQueryItem(name: "redirect_uri", value: "\(base)/api/auth/apple/callback"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "form_post"),
            URLQueryItem(name: "scope", value: "email"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        return components.string ?? ""
    }

    private func stateCookie(provider: String, nonce: String) -> String {
        let encoded = nonce.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? nonce
        var parts = [
            "slock_\(provider)_oauth_nonce=\(encoded)",
            "Path=/api/auth/\(provider)/callback",
            "Max-Age=600",
            "HttpOnly",
            "SameSite=\(provider == "apple" ? "None" : "Lax")",
        ]
        if provider == "apple" || serverURL.hasPrefix("https://") {
            parts.append("Secure")
        }
        return parts.joined(separator: "; ")
    }

    private static func providerLabel(_ id: String) -> String {
        switch id {
        case "google": "Google"
        case "github": "GitHub"
        case "apple": "Apple"
        default: id
        }
    }

    private static func sanitizeReturnTo(_ input: String?) -> String {
        guard let input, input.hasPrefix("/"), !input.hasPrefix("//"), !input.contains("\\"), !input.contains("://") else {
            return "/"
        }
        return input
    }

    private static func returnToField(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["returnTo"] as? String
    }

    private static func formFields(_ body: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0].removingPercentEncoding ?? parts[0]
            let raw = parts.count > 1 ? parts[1] : ""
            fields[name] = raw.removingPercentEncoding ?? raw
        }
        return fields
    }

    private static func cookieValue(_ header: String?, name: String) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            let halves = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard halves.first == name else { continue }
            let raw = halves.count > 1 ? halves[1] : ""
            return raw.removingPercentEncoding ?? raw
        }
        return nil
    }

    private static func socialCallbackURL(appURL: String, provider: String, mode: String, returnTo: String, error: String? = nil, code: String? = nil) -> String {
        let base = appURL.hasSuffix("/") ? String(appURL.dropLast()) : appURL
        var items = [
            URLQueryItem(name: "auth_callback", value: "social"),
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "returnTo", value: returnTo),
        ]
        if let code { items.append(URLQueryItem(name: "code", value: code)) }
        if let error { items.append(URLQueryItem(name: "error", value: error)) }
        var components = URLComponents(string: base) ?? URLComponents()
        components.queryItems = items
        return components.string ?? base
    }

    private static func noContent() -> HTTPReply {
        HTTPReply(
            status: 204,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Length": "0",
            ],
            body: ""
        )
    }

    private static func json(_ status: Int, _ body: String, cookie: String? = nil) -> HTTPReply {
        var headers = [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(Data(body.utf8).count),
        ]
        if let cookie { headers["Set-Cookie"] = cookie }
        return HTTPReply(status: status, headers: headers, body: body)
    }
}
