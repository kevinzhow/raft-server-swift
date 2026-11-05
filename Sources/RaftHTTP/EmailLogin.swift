import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    public var linkOnConflict: Bool = false

    public init(provider: String, mode: String, nonce: String, kind: String, mobileRequestId: String, desktopNonce: String?, returnTo: String? = nil, linkUserId: String? = nil, linkOnConflict: Bool = false) {
        self.provider = provider
        self.mode = mode
        self.nonce = nonce
        self.kind = kind
        self.mobileRequestId = mobileRequestId
        self.desktopNonce = desktopNonce
        self.returnTo = returnTo
        self.linkUserId = linkUserId
        self.linkOnConflict = linkOnConflict
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
    let lock = NSLock()
    var accounts: [String: Account] = [:]
    let authProfileStore = AuthProfileStore()
    var analyticsIds: [String: String] = [:]
    let productEventStore = ProductEventStore()
    var sessions: [String: LiveSession] = [:]
    var rotationReceipts: [String: RotationReceipt] = [:]
    /// Plain refresh tokens are one-time; the predecessor hash still resolves
    /// to its family so a legacy logout can revoke the successor.
    var predecessorFamilies: [String: String] = [:]
    var revokedFamilies: Set<String> = []
    var sessionFamilies: [String: SessionFamily] = [:]
    var retirementReceipts: [String: RetirementReceipt] = [:]
    var accessTokens: [String: String] = [:]
    var accessTokenFamilies: [String: String] = [:]

    var emailVerifications = 0
    var humanMessageRows: [StoredHumanMessage] = []
    var channelAttachments: [String: ChannelAttachment] = [:]
    var recordedChannelMessageEvents: [ChannelMessageEvent] = []
    var forwardedBundles: [String: [ForwardedSource]] = [:]
    var forwardRecords: [String: StoredForwardRecord] = [:]
    var messageReactions: [StoredReaction] = []
    var reactionViewerVersions: [String: Int] = [:]
    var reactionDiscussionVersions: [String: Int] = [:]
    var serverAgents: [String: ServerAgent] = [:]
    var storedMentions: [StoredMention] = []
    var channelAgentMembers: [String: Set<String>] = [:]
    var machineKeys: [String: (serverId: String, agentId: String)] = [:]
    let inboxFactStore = InboxFactStore()
    var storedAgentDeliveries: [(agentId: String, messageId: String, channelType: String)] = []
    /// RFC 074 assistant link: agent id -> owner user id.
    var assistantOwners: [String: String] = [:]
    var agentCredentials: [String: AgentCredential] = [:]
    var agentMachineIds: [String: String] = [:]
    var agentRuntimeProfiles: [String: AgentRuntimeProfileFact] = [:]
    var activeAgentMigrations: [String: AgentMigrationFact] = [:]
    var latestComputerReleaseForTesting: (version: String, notesJSON: String)?
    var machineBroadcastPoliciesForTesting: [String: String] = [:]
    var agentMigrationServers: Set<String> = []
    var hostedMigrationServers: Set<String> = []
    var hostedRuntimeServers: Set<String> = []
    var hostedProviderTokenOverride: String?
    var hostedMigrations: [String: HostedMigrationRecord] = [:]
    var appLoginRequests: [String: AppLoginRequest] = [:]


    var machineMigrations: [String: MachineMigrationRecord] = [:]
    /// Test seam for the frozen-generation cancel dispatch to a Computer.
    public var agentMigrationCancelDispatch: (@Sendable (_ machineId: String, _ role: String, _ migrationRef: String, _ transportGeneration: String, _ stopAgent: Bool) -> Void)?
    /// Capabilities reported by each Computer for migration admission.
    public var machineMigrationCapabilities: [String: Set<String>] = [:]
    /// Runtime-detection progress reported by each Computer.
    public var machineRuntimeDetections: [String: (status: String, unfinished: Set<String>)] = [:]
    /// Server plan override; missing means Pro.
    public var serverPlans: [String: String] = [:]
    /// Returns an object-store session id, or nil when provisioning fails.
    public var machineMigrationProvisioner: (@Sendable (_ sourceMachineId: String, _ targetMachineId: String) -> String?)?
    /// Lease dispatch to the source (upload) and target (download) Computers.
    public var machineMigrationLeaseDispatch: (@Sendable (_ machineId: String, _ role: String, _ migrationRef: String) -> Void)?
    /// Target-side agent start for target import arrival. Returns `.dispatched`
    /// when the daemon accepted the launch and `.skipped(reason)` when a wake
    /// lock (or another gate) suppressed it.
    public var machineMigrationStartAgent: (@Sendable (_ agentId: String) async throws -> MachineMigrationAgentStartOutcome)?
    /// Ask the source Computer to archive the migrated-away workspace. Throws
    /// `MachineMigrationArchiveFailure` with a code-shaped cause on failure.
    public var machineMigrationArchiveSourceWorkspace: (@Sendable (_ machineId: String, _ migrationRef: String, _ agentId: String) async throws -> Void)?
    /// Agent start dispatch used by `POST /api/channels/:id/resume-all-agents`.
    /// Returns `.dispatched` when the daemon accepted the resume prompt and
    /// `.skipped(reason)` when a gate (for example a held wake lock) suppressed it.
    public var agentStartDispatch: (@Sendable (_ agentId: String, _ resumePrompt: String?) async throws -> AgentStartDispatchOutcome)?
    /// Recent activity-log entries for one agent, serialized as the HTTP body.
    public var agentActivityLogProvider: (@Sendable (_ agentId: String, _ limit: Int?) -> AgentSurfaceResult)?
    /// Turn summaries plus the next cursor; the handler redacts triggers the
    /// viewer cannot see.
    public var agentActivitySummariesProvider: (@Sendable (_ agentId: String, _ limit: Int, _ beforeEndedAt: Int?, _ beforeId: String?) -> AgentSurfaceResult)?
    /// `{"global":[...],"workspace":[...]}` skills body for one agent.
    public var agentSkillsProvider: (@Sendable (_ agentId: String) -> AgentSurfaceResult)?
    /// Whether the agent's Computer connection is owned by this replica.
    public var agentHasMachineLocally: (@Sendable (_ agentId: String) -> Bool)?
    /// File-tree JSON array for one agent workspace directory.
    public var agentWorkspaceTreeProvider: (@Sendable (_ agentId: String, _ dirPath: String?, _ includeHidden: Bool) -> AgentSurfaceResult)?
    /// One workspace file read body.
    public var agentWorkspaceReadProvider: (@Sendable (_ agentId: String, _ path: String?) -> AgentSurfaceResult)?
    /// Human Start control dispatch (`control: "human_start"`).
    public var agentStartControlDispatch: (@Sendable (_ agentId: String, _ control: String) -> Void)?
    /// Human Reset dispatch (`terminalControl: "human_reset"`).
    public var agentResetDispatch: (@Sendable (_ agentId: String, _ mode: String, _ terminalControl: String) -> Void)?
    /// Terminal-breaker lift on a PATCH, with whether a runtime value really changed.
    public var agentConfigLiftDispatch: (@Sendable (_ agentId: String, _ runtimeValuesChanged: Bool) -> Void)?
    /// Asks the target Computer whether its Built-in model catalog lists a preset.
    public var builtinModelCatalogCheck: (@Sendable (_ machineId: String, _ modelId: String) -> BuiltinModelCatalogResult)?
    /// Live model ids a Computer advertises for a runtime (v2 field-pointing).
    public var agentRuntimeModelsForMachine: (@Sendable (_ machineId: String, _ runtime: String) -> [String]?)?

    func builtinCatalogFailureReply() -> HTTPReply {
        Self.json(409, "{\"code\":\"builtin_catalog_unavailable\",\"error\":\"The target Computer's Built-in model catalog is unavailable. Retry after the Computer reconnects.\"}")
    }

    func builtinModelCheck(machineId: String?, config: [String: Any]) -> BuiltinModelCatalogResult? {
        guard let machineId,
              (config["runtime"] as? String) == "builtin",
              let model = config["model"] as? [String: Any],
              let modelId = model["id"] as? String,
              let check = builtinModelCatalogCheck
        else { return nil }
        return check(machineId, modelId)
    }
    var hostedRuntimes: [String: (provider: String, model: String?, state: String, retryNeedsModel: Bool, createdAt: Date)] = [:]
    var grokRuntimeServers: Set<String> = []
    var remoteUpgradeDisabledServers: Set<String> = []
    var agentStatusAdopted: Set<String> = []
    var agentStatusOccurredAt: [String: Date] = [:]
    var agentActivityEventIds: [String: Set<String>] = [:]
    let threadFollowStore = ThreadFollowStore()
    var agentIntegrationLogins: [String: AgentIntegrationLoginRecord] = [:]
    var attachmentCommentRecords: [String: [AttachmentCommentRecord]] = [:]
    var hostedUsage: [String: String] = [:]
    var hostedModelPickerServers: Set<String> = []
    var hostedModels: [String: HostedModelState] = [:]
    var agentConnectionOrigin = "http://localhost:3000"
    let agentConnectionLock = NSLock()
    var agentConnectionProviderStorage: (@Sendable (AgentConnectionProviderRequest) -> AgentConnectionProviderResult)?

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


    /// Raft's own default for hosted agents; naming it always follows the provider default.
    static let hostedDefaultModel = "deepseek-flash"

    var agentArchiveRecords: [String: AgentArchiveRecord] = [:]
    var postableChannels: [String: PostableChannel] = [:]
    var threadOrder: [String] = []
    var serverMemberRoles: [String: String] = [:]
    var hideHumansFromMembers: [String: Bool] = [:]
    var serverMemberStatuses: [String: String] = [:]
    var membershipAgreementAudits: [(
        serverId: String, subjectId: String, actorUserId: String,
        source: String, agreementId: String?, agreementVersion: Int?
    )] = []
    var jointProjections: [JointChannelLink] = []
    var serverMemberEvents: [ServerMemberEvent] = []
    var deletedServerIds: Set<String> = []
    var sidebarReadAllEnabled = false
    var translationProviderOverride: String?
    var appAgentReminderLedger: [String: String] = [:]
    var agentReminderSurfaceChannels: [String: String] = [:]
    var handsFeedbackUpstreamHandler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data))?
    var handsConversationSessionEnabledForTesting: Bool?
    var handsConversationAppTokenOverride: String?
    var productFeedbackReporterSessionCache: [String: (token: String, expiresAt: Date)] = [:]
    /// SecureString-shaped `HANDS_FEEDBACK_APPS` payload for `product_feedback_multi_app`.
    /// Production reads this from SSM; the port takes it from `setHandsFeedbackAppsForTesting`.
    var handsFeedbackAppsJSONForTesting: String?
    /// Overlay for the legacy `HANDS_FEEDBACK_*` view, so a test can reproduce the
    /// deploy environment without mutating the process environment.
    var handsFeedbackLegacyEnvironmentForTesting: [String: String]?
    var handsFeedbackWarningSinkForTesting: ((String) -> Void)?
    var productFeedbackRouteBindingSuccesses: [String: Date] = [:]
    var productFeedbackRouteCommitments: [String: Data] = [:]
    var productFeedbackRouteVerifiedCommitments: Set<String> = []
    var messageTranslationLedger: [String: (status: String, providerBilledChars: Int, targetLanguage: String, translatedContent: String)] = [:]
    var agentChannelJoinedAt: [String: Date] = [:]
    var agentChannelPosted: Set<String> = []
    var taskWriteHolds: [String: (seen: Int, latest: Int)] = [:]
    var readMutationRecords: [String: ReadMutationRecord] = [:]
    var readMutationAuthoritySeq: [String: Int] = [:]
    var readMutationOrder: [String] = []
    var readMutationAcks: [String: (scopeId: String, throughSeq: Int)] = [:]
    var userChannelReadCursorsForTesting: [String: Int] = [:]
    var jointInvites: [(
        id: String, hostServerId: String, hostChannelId: String,
        targetServerId: String, targetChannelId: String,
        targetOwnerId: String, status: String
    )] = []
    var composerResourceServers: Set<String> = []
    var installedServerApps: [String: Set<String>] = [:]
    var socialCompletions: [SocialCompletion] = []
    var pendingSocialLinks: [String: PendingSocialLink] = [:]
    var mobileRequests: [String: MobileOAuthRequest] = [:]
    var providerExchanges = 0
    var consumedHandoffs: Set<String> = []
    var deviceGrants: [String: DeviceGrant] = [:]
    var deviceUserCodes: [String: String] = [:]
    var mobileAppEmailContactsByKey: [String: MobileAppEmailContact] = [:]
    var storedMobileAppEmailJourneys: [MobileAppEmailJourney] = []
    var nativeNotificationEvents: [StoredNativeNotificationEvent] = []
    var nextNativeNotificationSeq = 0
    var nativeEnrollmentGrants: [StoredEnrollmentGrant] = []
    var nativeNotificationDevices: [StoredNotificationDevice] = []
    var nativeNotificationCredentials: [StoredNotificationCredential] = []
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
    /// Injected session-issuance failure: the pending link must roll back and
    /// stay usable.
    public var failNextSessionIssuanceForTesting = false
    public var handsFeedbackConfigured = false
    public var handsFeedbackBaseURLOverride: String?
    public var handsFeedbackAppIdOverride: String?
    public var handsFeedbackAppSlugOverride: String?
    public var handsFeedbackAppTokenOverride: String?
    public var providerConnectionsEnabledServers: Set<String> = []
    var providerConnections: [ProviderConnection] = []
    var providerAssignments: [ProviderAssignment] = []
    /// Share artifacts store the uploaded PNG bytes and the intrinsic size read
    /// from the IHDR chunk, because the public page advertises the real image
    /// dimensions and the PNG route serves the same bytes the user selected.

    var shareArtifacts: [String: ShareArtifactRecord] = [:]
    var timezoneObservations: [String: TimezoneObservation] = [:]
    var serverLabsState: [String: ServerLabsState] = [:]
    var serverInvites: [(id: String, serverId: String, email: String, role: String, tokenHash: String?)] = []
    var serverSwitcherOrders: [String: (ids: [String], version: Int)] = [:]
    var serverOnboardingSettings: [String: (agentId: String?, greeting: Bool)] = [:]
    var userOnboardingSettings: [String: UserOnboarding] = [:]
    var serverNotificationPrefs: [String: (muted: Bool, mentionsOnly: Bool, mode: String, version: Int)] = [:]
    var setupPhases: [String: String] = [:]
    var setupHandoffs: Set<String> = []
    var guestRoleServers: Set<String> = []
    var computers: [(id: String, serverId: String, name: String, apiKey: String, machineId: String?, revokedAt: Date?, online: Bool, version: String?)] = []
    var computerAttachers: [String: String] = [:]
    var runtimeAccountUsage: [String: (json: String, staleAfter: Date)] = [:]
    var runtimeAccountUsageRefreshAt: [String: Date] = [:]
    var machineRuntimeModels: [String: [String: (models: [(id: String, label: String)], updatedAt: Date)]] = [:]
    var proSeats: [String: Int] = [:]
    var joinLinks: [String: JoinLinkRecord] = [:]
    var usageLimitAttentionServers: Set<String> = []
    var systemAttentionIncidents: [SystemAttentionIncident] = []
    var systemAttentionReceipts: [String: SystemAttentionReceipt] = [:]
    var hostedAgents: Set<String> = []
    var threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)] = [:]
    var threadUnfollows: [String: ThreadUnfollowRecord] = [:]
    var threadFollowStarts: [String: Date] = [:]
    var threadFollowerRemovals: [String: (serverId: String, threadChannelId: String, agentId: String)] = [:]
    var staleThreadFollowerUndoTokens: Set<String> = []
    var channelReadVersions: [String: Int] = [:]
    var agentChannelReadCursors: [String: (seq: Int, version: Int)] = [:]
    /// Test-only override of `SLOCK_ATTESTED_SEND_MODE`; process environment is
    /// global state and parallel suites must not race on it.
    var sendFreshnessModeOverride: String?
    /// Serializes the freshness gate with the commit it protects, so two
    /// concurrent first replies cannot both pass the gate before either lands.
    let sendFreshnessCommitLock = NSLock()
    var attestedSendEventRecords: [AttestedSendEventRecord] = []
    var agentSendActivityRecords: [String: [(title: String, text: String, producerFactId: String?)]] = [:]
    /// Test seam for the daemon capability that makes legacy receive-ack a
    /// volatile delivery ack instead of a usability checkpoint.
    var machineModelSeenCapabilityForTesting: Set<String> = []
    // Human read frontiers live in the ledger alongside the message rows. The
    // directory keeps no parallel cursor store.
    var agentActivities: [String: (activity: String, detail: String)] = [:]
    var announcements: [(id: String, title: String, pages: [String], startsAt: Date, expiresAt: Date?, status: String, publishedAt: Date?, imageId: String?, audienceServerIds: [String])] = []
    var announcementImageAssets: [String: AnnouncementImageAsset] = [:]
    var announcementImageStorageAvailable = true

    var announcementDismissals: Set<String> = []
    var inboxDoneScopes: Set<String> = []
    var inboxDoneAt: [String: Date] = [:]
    /// Canonical Done frontier captured at admission, per `userId\nscopeId`.
    var inboxDoneFrontiers: [String: Int] = [:]
    var inboxResiduesForTesting: Set<String> = []
    var guestVisibleChannels: [String: Bool] = [:]
    var guestJoinableChannels: [String: Bool] = [:]
    var readReceiptsServers: Set<String> = []
    var channelHumanRoles: [String: String] = [:]
    var channelAuthorityRevisions: [String: Int] = [:]
    var sidebarModes: [String: (channel: String, joint: String, dm: String, pinned: String, channelTabs: [String], agentTabs: [String])] = [:]
    var sidebarSections: [String: (sections: [(id: String, name: String, emoji: String?, sortMode: String)], order: [String], placements: [(kind: String, id: String, sectionId: String, position: Int)], version: Int)] = [:]
    var sidebarPinnedRefs: [String: (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int)] = [:]
    var reminderRecords: [ReminderRecord] = []
    var reminderEvents: [ReminderEvent] = []
    var taskRecords: [TaskRecord] = []
    var pushRegistrations: [PushRegistration] = []
    public var fcmPushAvailable = true
    public var webPushEnabled = true
    var webPushSubscriptions: [WebPushSubscription] = []
    var machines: [MachineRecord] = []
    var machineStatusVersions: [String: Int] = [:]
    var machineOnline: [String: Bool] = [:]
    var agentCredentialUseThrottleOverrideMs: Int?
    var wakeStreamHeartbeatOverrideMs: Int?
    var agentLastSeenAt: [String: Date] = [:]
    var feedbackLocatorRecords: [FeedbackLocatorRecord] = []
    var managedMCPServers: [ManagedMCPServerRecord] = []
    var managedMCPAssignments: [String: [String: (enabled: Bool, allowedTools: [String]?)]] = [:]
    var actionCardRecords: [String: ActionCardRecord] = [:]
    var marketplaceInstallCards: [String: MarketplaceInstallCard] = [:]
    var integrationRegisterCards: [String: IntegrationRegisterCard] = [:]
    var agentApiSendReceipts: [String: AgentApiSendReceipt] = [:]
    var pendingActionMessageEvents: [(agentId: String, messageId: String, content: String)] = []
    var agentGrantSets: [String: Set<String>] = [:]
    var appConfigOverrides: [String: [String: [String: Any]]] = [:]
    var appConfigRevisions: [String: [String: Int]] = [:]
    var agentIntegrationGrants: [String: Bool] = [:]
    var agentAudienceStatusOverrides: [String: String] = [:]
    var agentAttachmentBytes: [String: Data] = [:]
    var agentAttachmentPresign: (@Sendable (String, Int, String, String) throws -> String)?

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


    static let agentAttachmentUnavailableMessage = "Attachment is unavailable."
    static let agentAttachmentUnavailableNextAction = "If this value came from a feedback report, do not use its artifactId here. Use the reportId with the Raft Feedback Admin integration instead: run `raft integration invoke --service \"Raft Feedback Admin\" --action download_feedback_transcript --param id=REPORT_ID --output PATH`."

    func agentAttachmentUnavailableReply() -> HTTPReply {
        let error = Self.agentAttachmentUnavailableMessage + " " + Self.agentAttachmentUnavailableNextAction
        return Self.json(404, "{\"error\":\(jsonString(error)),\"code\":\"ATTACHMENT_UNAVAILABLE\",\"suggestedNextAction\":\(jsonString(Self.agentAttachmentUnavailableNextAction))}")
    }

    func agentAttachmentUnavailableURLReply() -> HTTPReply {
        Self.json(409, "{\"error\":\"This Server's file storage cannot mint download URLs.\",\"code\":\"download_url_unavailable\",\"suggestedNextAction\":\"Download the attachment bytes instead: GET /internal/agent-api/attachments/:attachmentId (`raft attachment view --id <attachmentId> --output <path>`).\"}")
    }

    func agentVisibleAttachment(agentId: String, serverId: String, attachmentId: String) -> ChannelAttachment? {
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

    func agentAttachmentIdentity(authorization: String?) -> (agentId: String, serverId: String)? {
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
        reply.headers["Content-Disposition"] = "attachment; filename=\"\(attachment.filename)\"; filename*=UTF-8''\(Self.rfc5987Encode(attachment.filename))"
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


    /// A prepared Marketplace install card. The action payload is rebuilt from
    /// this record on every read, so the message projection never carries a
    /// stale canonical action.

    /// A prepared `integration:register_app` card. The initial client secret
    /// is created at execution time and never lands in card state.

    /// One committed agent-api send per (server, agent, idempotencyKey).


    var externalPushWebhooks: [String: (url: String, secret: String)] = [:]
    var agentStatusProtocolAdoptedAt: [String: Date] = [:]
    var agentCursorPullState: [String: (lastPulledAt: Date, pendingAcks: Int)] = [:]
    var agentProviderPositions: [String: (provider: String, state: String, providerAgentId: String?, syncPending: Bool, lastErrorCode: String?, lastErrorAt: Date?, activatedAt: Date?)] = [:]

    /// Production throttle for credential-use writes.
    public static let agentCredentialUseDefaultThrottleMs = 60_000
    var deletedMachineWorkspaces: Set<String> = []
    let realtimeEmitterLock = NSLock()
    var realtimeEmitterStorage: (@Sendable (String, String, String?) -> Void)?
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
    /// Test seam for the Computer model probe. Production has no live daemon relay here.
    public var machineRuntimeModelProbe: (@Sendable (_ machineId: String, _ runtimeId: String, _ force: Bool) -> RuntimeModelProbeOutcome)?
    /// Whether this server can route a probe to the Computer. Defaults to true.
    public var machineRoutedLocally: (@Sendable (_ machineId: String) -> Bool)?
    /// Built-in model catalog authority as reported by the Computer. Production
    /// has no live authority channel here, so the default is the modern mode.
    public var builtinCatalogMode: String = "supported"
    /// Test seam called before each already-read SSE frame. Production leaves it nil.
    public var nativeNotificationLiveWriteHook: (@Sendable (_ index: Int, _ eventCount: Int) async -> Void)?
    /// `NATIVE_NOTIFICATION_ATTESTATION_MODE`. Nil means the variable is unset.
    public var nativeNotificationAttestationMode: String? = nil
    /// Process `NODE_ENV`. Production enforces desktop attestation even when the mode is unset.
    public var nativeNotificationNodeEnv: String = "development"
    /// Test seam for signed-app attestation. A nil verifier never accepts evidence.
    public var nativeNotificationAttestationVerifier: (@Sendable (String) -> Bool)?
    var appleLoginPlatforms: Set<String> = []

    /// Raw `MOBILE_OAUTH_RETURN_URI`. A non-empty parsed list replaces the defaults.
    public var mobileOAuthReturnURI: String?
    /// Raw `MOBILE_OAUTH_ALLOWED_RETURN_URIS`. Used only when the primary list is empty.
    public var mobileOAuthAllowedReturnURIs: String?
    /// Raw `SLOCK_RELEASE_BRANCH`. Staging self-account opt-in is accepted only when this is exactly `staging`.
    public var releaseBranch: String?
    /// Raw `SLOCK_DEVICE_LOGIN_ENABLED`. Unset or empty keeps device login on. `false`, `0`, `no`, and `off` turn it off.
    public var deviceLoginGate: String?
    var linkedIdentities: [LinkedIdentity] = []
    var featureFlagRecords: [String: FeatureFlagRecord] = [
        "attachment_comments_v0": FeatureFlagRecord(key: "attachment_comments_v0", defaultEnabled: true),
    ]
    var featureFlagRuleRecords: [FeatureFlagRuleRecord] = []



    public static let termsVersion = "2026-05-12"
    public static let privacyVersion = "2026-05-12"
    public static let termsURL = "https://raft.build/terms"
    public static let privacyURL = "https://raft.build/privacy"

    public init() {}

    var experimentalSurfacesDisabledForTesting: Bool?

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

    public struct NativeEnrollmentGrantRecord: Sendable {
        public var secretHash: String
        public var json: String
    }











    public enum NativeStreamOpen: Sendable {
        case closed(HTTPReply)
        case streaming(userId: String, cursorSeq: Int, replay: [(seq: Int, frame: String)])
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
        return authProfileStore.legalAcceptanceCount
    }

    public var emailVerificationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return emailVerifications
    }

    public var providerExchangeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return providerExchanges
    }

    public var retirementReceiptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retirementReceipts.count
    }

    public var mobileOAuthRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mobileRequests.count
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

    /// `GET /api/attachments/:id/url`. A private source stays hidden. A copy on a visible channel does not.
    /// Test seam for the HTML preview body. Nil means the object is missing.
    public var attachmentPreviewBody: (@Sendable (_ attachmentId: String) -> String?)?

    /// Test seam for presigning a stored attachment object.
    public var attachmentPresign: (@Sendable (_ attachmentId: String, _ mimeType: String?, _ ttlSeconds: Int) -> String)?

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

    static let doneFrontierInt4Limit = 2_147_483_647

    static let selfCausedFreshnessExemptSubtypes: Set<String> = ["task.created_summary"]

    /// `GET /internal/agent-api/events`. Durable channel messages for the
    /// external agent plus pending third-party events; the call drains both.
    /// At most this many channel rows per conversation in one pull. The pull
    /// advances each conversation's cursor, and `has_more` says whether
    /// another call has anything left.
    static let agentInboxPullCap = 5

    public var humanMessageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.count
    }

    static let appLoginReturnUris: Set<String> = [
        "raft://login/callback",
        "raft-debug://login/callback",
    ]



    static let socialProviders: Set<String> = ["google", "github", "apple"]
    static let defaultMobileReturnURIs: Set<String> = [
        "raft://oauth/callback",
        "raft-alpha://oauth/callback",
        "raft-beta://oauth/callback",
        "raft-debug://oauth/callback",
        "raft-dev://oauth/callback",
    ]


    public struct ChannelMessageEvent: Equatable, Sendable {
        public var room: String
        public var name: String
        public var messageId: String
        public var attachmentIds: [String]
    }



    /// App ids inside `<app:…>` outside of a code fence are not required for this check; the send under test has no fence.

    /// Best-effort browser zone. A missing, non-string, empty, overlong, or non-canonical value is null.








    static let rejected = json(401, "{\"code\":\"AUTH_INVALID_CREDENTIALS\",\"error\":\"Invalid email or password\"}")
    static let missingAuthorization = json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
    static let invalidToken = json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
    static let wrongPassword = json(401, "{\"code\":\"AUTH_CURRENT_PASSWORD_INCORRECT\",\"error\":\"Current password is incorrect\"}")
    static let linkAuthRequired = json(401, "{\"code\":\"auth_required\",\"error\":\"Authentication is required to link an account\"}")
    static let linkMismatch = json(403, "{\"code\":\"link_user_mismatch\",\"error\":\"Social auth link does not match the authenticated user\"}")
    static let mobileLinkMismatch = json(403, "{\"code\":\"link_user_mismatch\",\"error\":\"Mobile OAuth link request does not match the authenticated user\"}")
    static let legalObject = "{\"termsVersion\":\"\(termsVersion)\",\"privacyVersion\":\"\(privacyVersion)\",\"termsUrl\":\"\(termsURL)\",\"privacyUrl\":\"\(privacyURL)\"}"
    static let legalRequired = json(422, "{\"error\":\"LEGAL_ACCEPTANCE_REQUIRED\",\"legal\":\(legalObject)}")
    static let returnURINotAllowed = json(400, "{\"code\":\"return_uri_not_allowed\",\"error\":\"Mobile OAuth return URI is not allowed\"}")
    static let termsChanged = json(409, "{\"error\":\"TERMS_CHANGED\",\"legal\":\(legalObject)}")

    static let deprecatedAgentRuntimes: Set<String> = ["kimi", "gemini", "antigravity", "copilot"]



    /// `GET /api/agent-runtime-providers/:kind`. Owners and admins can ask
    /// whether a hosted provider is usable for this server; the answer never
    /// exposes the deployment token or the provider base URL.

    var attachedComputers: [String: AttachedComputer] = [:]
    var computerAttachEnabledOverride: Bool?
    var scopeAttestationSecretOverride: String??
    var deploymentEnvironmentOverride: String??

    public var wakeStreamHeartbeatMs: Int? {
        lock.lock()
        let override = wakeStreamHeartbeatOverrideMs
        lock.unlock()
        if let override { return override }
        return ProcessInfo.processInfo.environment["SLOCK_WAKE_STREAM_HEARTBEAT_MS"].flatMap(Int.init)
    }

    public enum AgentWakeStreamStart {
        /// `cursorSeq` is the last hint seq already replayed; the stream then
        /// only pushes hints newer than it.
        case start(token: String, cursorSeq: Int?, firstFrame: String)
        case refused(HTTPReply)
    }

    /// Terminal migration failure codes a Computer may report over
    /// `transport-lost`; anything else collapses to the generic reason.
    static let migrationTerminalFailureCodes: Set<String> = [
        "MIGRATION_TRANSPORT_LOST",
        "MIGRATION_OBJECT_STORE_BUNDLE_TOO_LARGE",
        "MIGRATION_OBJECT_STORE_MANIFEST_TOO_LARGE",
        "MIGRATION_OBJECT_STORE_INSUFFICIENT_DISK",
        "MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED",
        "MIGRATION_WORKSPACE_ALREADY_EXISTS",
        "MIGRATION_WORKSPACE_COMPLETE_OLD_COPY",
        "MIGRATION_CHUNK_DIGEST_MISMATCH",
        "MIGRATION_WHOLE_BUNDLE_DIGEST_MISMATCH",
        "MIGRATION_LEASE_EXPIRED",
        "MIGRATION_GENERATION_STALE",
        "MIGRATION_CONTROL_MANIFEST_INVALID",
        "MIGRATION_CONTROL_MANIFEST_TOO_LARGE",
    ]
    static let migrationSourceArchiveMaxAttempts = 12
    static let migrationSourceArchiveMovedCodes: Set<String> = [
        "MIGRATION_WORKSPACE_ARCHIVE_AGENT_RUNNING",
        "MIGRATION_WORKSPACE_ARCHIVE_NEWER_OWNER",
    ]
    /// A `starting` row is observed, not re-dispatched, inside this window.
    static let migrationAutoStartLease: TimeInterval = 30

    static let agentConnectionProviders: Set<String> = ["github"]

    static let agentConnectionIDPattern = "^[A-Za-z0-9_.~-]{1,200}$"

    static let machineAPIKeyPrefix = "sk_machine_"
    static let computerAPIKeyPrefix = "sk_computer_"
    static let computerAPIKeyPrefixLength = 16





    static let onboardingSteps: Set<String> = [
        "add-computer", "create-agent", "invite-teammates", "join-community", "notifications",
    ]

    static let runtimeFormSchemas: [String: String] = [
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
        "grok": "grok.create.v1",
    ]

    /// Runtimes that still publish a v1 form definition.
    static let runtimeFormV1Runtimes: Set<String> = ["builtin", "claude", "cursor", "kimi-sdk"]

    /// Runtimes whose released form only exists at protocol v2; v1 clients
    /// must see them as having no form at all.
    static let runtimeFormV2Only: Set<String> = [
        "pi", "opencode", "gemini", "codex", "grok", "antigravity", "kimi",
    ]

    static let grokBundledModels: [RuntimeModelProbeModel] = [
        RuntimeModelProbeModel(
            id: "grok-4.5",
            label: "Grok 4.5",
            supportedReasoningEfforts: ["high", "medium", "low"],
            defaultReasoningEffort: "high"
        ),
        RuntimeModelProbeModel(id: "grok-4.6", label: "Grok 4.6"),
        RuntimeModelProbeModel(id: "grok-composer-2.5-fast", label: "Composer 2.5"),
    ]

    static let runtimeAccountUsageProviders: Set<String> = ["claude", "codex", "kimi", "grok"]


    public static let sharePNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=") ?? Data()

    static let timezoneAliases: [String: String] = [
        "US/Pacific": "America/Los_Angeles",
        "US/Eastern": "America/New_York",
        "US/Central": "America/Chicago",
        "US/Mountain": "America/Denver",
        "US/Alaska": "America/Anchorage",
        "US/Hawaii": "Pacific/Honolulu",
    ]

    public struct TimezoneObservation: Sendable {
        public var firstTimezone: String
        public var firstAt: Date
        public var lastTimezone: String
        public var lastAt: Date
    }



    static let scopeAttestationMaxChars = 16 * 1024

    public var computerUpgradeSender: (@Sendable (_ machineId: String, _ targetVersion: String, _ requestId: String) -> Bool)?

    static let attachmentCommentsDisabledReply = json(403, "{\"error\":\"Attachment comments are not enabled on this server\",\"code\":\"attachment_comments_disabled\"}")

    enum WhenToUseError: Error {
        case tooLong
        case notSingleLine
        case bareScopedPackage

        var message: String {
            switch self {
            case .tooLong: return "whenToUse must be at most 160 characters"
            case .notSingleLine: return "whenToUse must be a single line without control characters"
            case .bareScopedPackage:
                return "whenToUse must not contain a bare scoped package name like @scope/pkg; wrap it in backticks like `@scope/pkg`"
            }
        }
    }

    static let validTaskStatuses: Set<String> = ["todo", "in_progress", "in_review", "done", "cancelled"]


    static let labDefinitions: [(key: String, name: String, description: String, state: String)] = [
        ("open_lab", "Open Lab", "Available", "open"),
        ("paused_lab", "Paused Lab", "Paused", "paused"),
        ("draft_lab", "Draft Lab", "Hidden", "draft"),
        ("retired_lab", "Retired Lab", "Historical", "retired"),
    ]

    var memberAttentionJSON: String {
        ",\"attention\":{\"stillArrives\":[\"Followed threads still notify this member unless they unfollow them.\"],\"threadBoundary\":\"Removing this member does not unfollow existing thread follows. Private channel/thread content still requires current parent access.\",\"manageCommand\":\"Use raft thread unfollow to manage thread follows.\"}"
    }





    var marketplaceReviewerOverride: Set<String>?

    var agentInboxAvailableForTesting: Bool?

    var removedServerMembers: Set<String> = []

    var readPositionSettleMs: Int = 2000

    var deferredUnreadAdvance: [String: Int] = [:]

    var taskEvents: [(taskId: String, eventType: String, actorType: String)] = []

    var lastTaskServerWarning: String?

    var lastTaskServerQuery: String?

    var agentApiIdempotencyKeys: [AgentApiIdempotencyRecord] = []

    var assigneeChangeEvents: [(
        taskId: String, assigneeId: String?, assigneeType: String?,
        previousAssigneeId: String?, previousAssigneeType: String?,
        actorType: String, actorId: String
    )] = []

    var externalAvatarAssets: [String: ExternalAvatarAsset] = [:]

    var externalAvatarStorageAvailable = true
}
