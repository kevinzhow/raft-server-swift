import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `POST /api/auth/login`.
///
/// A non-string or empty email or password is refused before any account lookup.
/// A missing account and a wrong password share one 401, and neither issues a session.

public final class EmailLoginDirectory: @unchecked Sendable {
    let lock = NSLock()
    var accounts: [String: Account] = [:]
    let authProfileStore = AuthProfileStore()
    let notificationsStore = NotificationsStore()
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
    let inboxFactStore = InboxFactStore()
    var storedAgentDeliveries: [(agentId: String, messageId: String, channelType: String)] = []
    /// RFC 074 assistant link: agent id -> owner user id.
    var assistantOwners: [String: String] = [:]
    var agentCredentials: [String: AgentCredential] = [:]
    var agentMachineIds: [String: String] = [:]
    var agentRuntimeProfiles: [String: AgentRuntimeProfileFact] = [:]
    var activeAgentMigrations: [String: AgentMigrationFact] = [:]
    var agentMigrationServers: Set<String> = []
    var hostedMigrationServers: Set<String> = []
    var hostedRuntimeServers: Set<String> = []
    var hostedProviderTokenOverride: String?
    var hostedMigrations: [String: HostedMigrationRecord] = [:]
    var appLoginRequests: [String: AppLoginRequest] = [:]

    /// Test seam for the frozen-generation cancel dispatch to a Computer.
    public var agentMigrationCancelDispatch: (@Sendable (_ machineId: String, _ role: String, _ migrationRef: String, _ transportGeneration: String, _ stopAgent: Bool) -> Void)?
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

    var hostedRuntimes: [String: (provider: String, model: String?, state: String, retryNeedsModel: Bool, createdAt: Date)] = [:]
    var grokRuntimeServers: Set<String> = []
    var remoteUpgradeDisabledServers: Set<String> = []
    var agentStatusAdopted: Set<String> = []
    var agentStatusOccurredAt: [String: Date] = [:]
    var agentActivityEventIds: [String: Set<String>] = [:]
    let threadFollowStore = ThreadFollowStore()
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

    var agentArchiveRecords: [String: AgentArchiveRecord] = [:]
    var translationProviderOverride: String?
    var handsFeedbackUpstreamHandler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data))?
    var handsConversationSessionEnabledForTesting: Bool?
    var handsConversationAppTokenOverride: String?
    var handsFeedbackWarningSinkForTesting: ((String) -> Void)?
    var messageTranslationLedger: [String: (status: String, providerBilledChars: Int, targetLanguage: String, translatedContent: String)] = [:]
    var agentChannelJoinedAt: [String: Date] = [:]
    var agentChannelPosted: Set<String> = []
    var readMutationRecords: [String: ReadMutationRecord] = [:]
    var readMutationAuthoritySeq: [String: Int] = [:]
    var readMutationOrder: [String] = []
    var readMutationAcks: [String: (scopeId: String, throughSeq: Int)] = [:]
    var userChannelReadCursorsForTesting: [String: Int] = [:]
    var socialCompletions: [SocialCompletion] = []
    var pendingSocialLinks: [String: PendingSocialLink] = [:]
    var mobileRequests: [String: MobileOAuthRequest] = [:]
    var providerExchanges = 0
    var consumedHandoffs: Set<String> = []
    var deviceGrants: [String: DeviceGrant] = [:]
    var deviceUserCodes: [String: String] = [:]
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
    /// Share artifacts store the uploaded PNG bytes and the intrinsic size read
    /// from the IHDR chunk, because the public page advertises the real image
    /// dimensions and the PNG route serves the same bytes the user selected.

    var shareArtifacts: [String: ShareArtifactRecord] = [:]
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
    // Human read frontiers live in the ledger alongside the message rows. The
    // directory keeps no parallel cursor store.
    var agentActivities: [String: (activity: String, detail: String)] = [:]
    var inboxDoneScopes: Set<String> = []
    var inboxDoneAt: [String: Date] = [:]
    /// Canonical Done frontier captured at admission, per `userId\nscopeId`.
    var inboxDoneFrontiers: [String: Int] = [:]
    var inboxResiduesForTesting: Set<String> = []
    var agentCredentialUseThrottleOverrideMs: Int?
    var wakeStreamHeartbeatOverrideMs: Int?
    var agentLastSeenAt: [String: Date] = [:]
    var agentAttachmentBytes: [String: Data] = [:]
    var agentAttachmentPresign: (@Sendable (String, Int, String, String) throws -> String)?

    var externalPushWebhooks: [String: (url: String, secret: String)] = [:]
    var agentStatusProtocolAdoptedAt: [String: Date] = [:]
    var agentCursorPullState: [String: (lastPulledAt: Date, pendingAcks: Int)] = [:]
    var agentProviderPositions: [String: (provider: String, state: String, providerAgentId: String?, syncPending: Bool, lastErrorCode: String?, lastErrorAt: Date?, activatedAt: Date?)] = [:]

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

    public init() {}

    var experimentalSurfacesDisabledForTesting: Bool?

    /// `GET /api/attachments/:id/url`. A private source stays hidden. A copy on a visible channel does not.
    /// Test seam for the HTML preview body. Nil means the object is missing.
    public var attachmentPreviewBody: (@Sendable (_ attachmentId: String) -> String?)?

    /// Test seam for presigning a stored attachment object.
    public var attachmentPresign: (@Sendable (_ attachmentId: String, _ mimeType: String?, _ ttlSeconds: Int) -> String)?

    var computerAttachEnabledOverride: Bool?
    var scopeAttestationSecretOverride: String??
    var deploymentEnvironmentOverride: String??

    public var computerUpgradeSender: (@Sendable (_ machineId: String, _ targetVersion: String, _ requestId: String) -> Bool)?

    var marketplaceReviewerOverride: Set<String>?

    var agentInboxAvailableForTesting: Bool?

    var readPositionSettleMs: Int = 2000

    var deferredUnreadAdvance: [String: Int] = [:]

    var externalAvatarAssets: [String: ExternalAvatarAsset] = [:]

    var externalAvatarStorageAvailable = true

    // MARK: - Store-backed surface

    // Domain stores. Each owns one ledger family behind its own lock; the
    // computed accessors below forward here so extension files keep their names.
    let tasksAndRemindersStore = TasksAndRemindersStore()
    let machinesAndComputersStore = MachinesAndComputersStore()
    let serversAndChannelsStore = ServersAndChannelsStore()
    let managedMCPAndCardsStore = ManagedMCPAndCardsStore()
    let feedbackStore = FeedbackStore()

    // Notification/announcement/push rows live in `NotificationsStore`. These
    // accessors keep the extension files' property names unchanged.
    var nativeNotificationEvents: [StoredNativeNotificationEvent] { get { notificationsStore.nativeNotificationEvents } set { notificationsStore.nativeNotificationEvents = newValue } }
    var nextNativeNotificationSeq: Int { get { notificationsStore.nextNativeNotificationSeq } set { notificationsStore.nextNativeNotificationSeq = newValue } }
    var nativeEnrollmentGrants: [StoredEnrollmentGrant] { get { notificationsStore.nativeEnrollmentGrants } set { notificationsStore.nativeEnrollmentGrants = newValue } }
    var nativeNotificationDevices: [StoredNotificationDevice] { get { notificationsStore.nativeNotificationDevices } set { notificationsStore.nativeNotificationDevices = newValue } }
    var nativeNotificationCredentials: [StoredNotificationCredential] { get { notificationsStore.nativeNotificationCredentials } set { notificationsStore.nativeNotificationCredentials = newValue } }
    var pushRegistrations: [PushRegistration] { get { notificationsStore.pushRegistrations } set { notificationsStore.pushRegistrations = newValue } }
    public var fcmPushAvailable: Bool { get { notificationsStore.fcmPushAvailable } set { notificationsStore.fcmPushAvailable = newValue } }
    public var webPushEnabled: Bool { get { notificationsStore.webPushEnabled } set { notificationsStore.webPushEnabled = newValue } }
    var webPushSubscriptions: [WebPushSubscription] { get { notificationsStore.webPushSubscriptions } set { notificationsStore.webPushSubscriptions = newValue } }
    var announcements: [NotificationsStore.AnnouncementRow] { get { notificationsStore.announcements } set { notificationsStore.announcements = newValue } }
    var announcementImageAssets: [String: AnnouncementImageAsset] { get { notificationsStore.announcementImageAssets } set { notificationsStore.announcementImageAssets = newValue } }
    var announcementImageStorageAvailable: Bool { get { notificationsStore.announcementImageStorageAvailable } set { notificationsStore.announcementImageStorageAvailable = newValue } }
    var announcementDismissals: Set<String> { get { notificationsStore.announcementDismissals } set { notificationsStore.announcementDismissals = newValue } }
    var serverNotificationPrefs: [String: NotificationsStore.ServerNotificationPref] { get { notificationsStore.serverNotificationPrefs } set { notificationsStore.serverNotificationPrefs = newValue } }

    // Profile surface rows live in `AuthProfileStore`.
    var timezoneObservations: [String: TimezoneObservation] { get { authProfileStore.timezoneObservations } set { authProfileStore.timezoneObservations = newValue } }
    var userOnboardingSettings: [String: UserOnboarding] { get { authProfileStore.userOnboardingSettings } set { authProfileStore.userOnboardingSettings = newValue } }
    var mobileAppEmailContactsByKey: [String: MobileAppEmailContact] { get { authProfileStore.mobileAppEmailContactsByKey } set { authProfileStore.mobileAppEmailContactsByKey = newValue } }
    var storedMobileAppEmailJourneys: [MobileAppEmailJourney] { get { authProfileStore.storedMobileAppEmailJourneys } set { authProfileStore.storedMobileAppEmailJourneys = newValue } }

    // Rows for the task, reminder and assignee-change surface live in `TasksAndRemindersStore`.
    var reminderRecords: [ReminderRecord] { get { tasksAndRemindersStore.reminderRecords } set { tasksAndRemindersStore.reminderRecords = newValue } }
    var reminderEvents: [ReminderEvent] { get { tasksAndRemindersStore.reminderEvents } set { tasksAndRemindersStore.reminderEvents = newValue } }
    var taskRecords: [TaskRecord] { get { tasksAndRemindersStore.taskRecords } set { tasksAndRemindersStore.taskRecords = newValue } }
    var taskWriteHolds: [String: (seen: Int, latest: Int)] { get { tasksAndRemindersStore.taskWriteHolds } set { tasksAndRemindersStore.taskWriteHolds = newValue } }
    var taskEvents: [(taskId: String, eventType: String, actorType: String)] { get { tasksAndRemindersStore.taskEvents } set { tasksAndRemindersStore.taskEvents = newValue } }
    var lastTaskServerWarning: String? { get { tasksAndRemindersStore.lastTaskServerWarning } set { tasksAndRemindersStore.lastTaskServerWarning = newValue } }
    var lastTaskServerQuery: String? { get { tasksAndRemindersStore.lastTaskServerQuery } set { tasksAndRemindersStore.lastTaskServerQuery = newValue } }
    var assigneeChangeEvents: [(taskId: String, assigneeId: String?, assigneeType: String?, previousAssigneeId: String?, previousAssigneeType: String?, actorType: String, actorId: String)] { get { tasksAndRemindersStore.assigneeChangeEvents } set { tasksAndRemindersStore.assigneeChangeEvents = newValue } }

    // Rows for the machine, Computer and migration surface live in `MachinesAndComputersStore`.
    var machines: [MachineRecord] { get { machinesAndComputersStore.machines } set { machinesAndComputersStore.machines = newValue } }
    var machineStatusVersions: [String: Int] { get { machinesAndComputersStore.machineStatusVersions } set { machinesAndComputersStore.machineStatusVersions = newValue } }
    var machineOnline: [String: Bool] { get { machinesAndComputersStore.machineOnline } set { machinesAndComputersStore.machineOnline = newValue } }
    var computers: [(id: String, serverId: String, name: String, apiKey: String, machineId: String?, revokedAt: Date?, online: Bool, version: String?)] { get { machinesAndComputersStore.computers } set { machinesAndComputersStore.computers = newValue } }
    var computerAttachers: [String: String] { get { machinesAndComputersStore.computerAttachers } set { machinesAndComputersStore.computerAttachers = newValue } }
    var attachedComputers: [String: AttachedComputer] { get { machinesAndComputersStore.attachedComputers } set { machinesAndComputersStore.attachedComputers = newValue } }
    var deletedMachineWorkspaces: Set<String> { get { machinesAndComputersStore.deletedMachineWorkspaces } set { machinesAndComputersStore.deletedMachineWorkspaces = newValue } }
    public var machineMigrationCapabilities: [String: Set<String>] { get { machinesAndComputersStore.machineMigrationCapabilities } set { machinesAndComputersStore.machineMigrationCapabilities = newValue } }
    public var machineRuntimeDetections: [String: (status: String, unfinished: Set<String>)] { get { machinesAndComputersStore.machineRuntimeDetections } set { machinesAndComputersStore.machineRuntimeDetections = newValue } }
    var machineMigrations: [String: MachineMigrationRecord] { get { machinesAndComputersStore.machineMigrations } set { machinesAndComputersStore.machineMigrations = newValue } }
    var machineRuntimeModels: [String: [String: (models: [(id: String, label: String)], updatedAt: Date)]] { get { machinesAndComputersStore.machineRuntimeModels } set { machinesAndComputersStore.machineRuntimeModels = newValue } }
    var runtimeAccountUsage: [String: (json: String, staleAfter: Date)] { get { machinesAndComputersStore.runtimeAccountUsage } set { machinesAndComputersStore.runtimeAccountUsage = newValue } }
    var runtimeAccountUsageRefreshAt: [String: Date] { get { machinesAndComputersStore.runtimeAccountUsageRefreshAt } set { machinesAndComputersStore.runtimeAccountUsageRefreshAt = newValue } }
    var machineKeys: [String: (serverId: String, agentId: String)] { get { machinesAndComputersStore.machineKeys } set { machinesAndComputersStore.machineKeys = newValue } }
    var machineBroadcastPoliciesForTesting: [String: String] { get { machinesAndComputersStore.machineBroadcastPolicies } set { machinesAndComputersStore.machineBroadcastPolicies = newValue } }
    var machineModelSeenCapabilityForTesting: Set<String> { get { machinesAndComputersStore.machineModelSeenCapability } set { machinesAndComputersStore.machineModelSeenCapability = newValue } }
    var latestComputerReleaseForTesting: (version: String, notesJSON: String)? { get { machinesAndComputersStore.latestComputerRelease } set { machinesAndComputersStore.latestComputerRelease = newValue } }

    // Rows for the server-membership, sidebar and channel-authority surface live in `ServersAndChannelsStore`.
    var postableChannels: [String: PostableChannel] { get { serversAndChannelsStore.postableChannels } set { serversAndChannelsStore.postableChannels = newValue } }
    var threadOrder: [String] { get { serversAndChannelsStore.threadOrder } set { serversAndChannelsStore.threadOrder = newValue } }
    var serverMemberRoles: [String: String] { get { serversAndChannelsStore.serverMemberRoles } set { serversAndChannelsStore.serverMemberRoles = newValue } }
    var hideHumansFromMembers: [String: Bool] { get { serversAndChannelsStore.hideHumansFromMembers } set { serversAndChannelsStore.hideHumansFromMembers = newValue } }
    var serverMemberStatuses: [String: String] { get { serversAndChannelsStore.serverMemberStatuses } set { serversAndChannelsStore.serverMemberStatuses = newValue } }
    var membershipAgreementAudits: [(serverId: String, subjectId: String, actorUserId: String, source: String, agreementId: String?, agreementVersion: Int?)] { get { serversAndChannelsStore.membershipAgreementAudits } set { serversAndChannelsStore.membershipAgreementAudits = newValue } }
    var jointProjections: [JointChannelLink] { get { serversAndChannelsStore.jointProjections } set { serversAndChannelsStore.jointProjections = newValue } }
    var serverMemberEvents: [ServerMemberEvent] { get { serversAndChannelsStore.serverMemberEvents } set { serversAndChannelsStore.serverMemberEvents = newValue } }
    var deletedServerIds: Set<String> { get { serversAndChannelsStore.deletedServerIds } set { serversAndChannelsStore.deletedServerIds = newValue } }
    var removedServerMembers: Set<String> { get { serversAndChannelsStore.removedServerMembers } set { serversAndChannelsStore.removedServerMembers = newValue } }
    public var serverPlans: [String: String] { get { serversAndChannelsStore.serverPlans } set { serversAndChannelsStore.serverPlans = newValue } }
    var serverLabsState: [String: ServerLabsState] { get { serversAndChannelsStore.serverLabsState } set { serversAndChannelsStore.serverLabsState = newValue } }
    var serverInvites: [(id: String, serverId: String, email: String, role: String, tokenHash: String?)] { get { serversAndChannelsStore.serverInvites } set { serversAndChannelsStore.serverInvites = newValue } }
    var serverSwitcherOrders: [String: (ids: [String], version: Int)] { get { serversAndChannelsStore.serverSwitcherOrders } set { serversAndChannelsStore.serverSwitcherOrders = newValue } }
    var serverOnboardingSettings: [String: (agentId: String?, greeting: Bool)] { get { serversAndChannelsStore.serverOnboardingSettings } set { serversAndChannelsStore.serverOnboardingSettings = newValue } }
    var setupPhases: [String: String] { get { serversAndChannelsStore.setupPhases } set { serversAndChannelsStore.setupPhases = newValue } }
    var setupHandoffs: Set<String> { get { serversAndChannelsStore.setupHandoffs } set { serversAndChannelsStore.setupHandoffs = newValue } }
    var guestRoleServers: Set<String> { get { serversAndChannelsStore.guestRoleServers } set { serversAndChannelsStore.guestRoleServers = newValue } }
    var proSeats: [String: Int] { get { serversAndChannelsStore.proSeats } set { serversAndChannelsStore.proSeats = newValue } }
    var joinLinks: [String: JoinLinkRecord] { get { serversAndChannelsStore.joinLinks } set { serversAndChannelsStore.joinLinks = newValue } }
    var usageLimitAttentionServers: Set<String> { get { serversAndChannelsStore.usageLimitAttentionServers } set { serversAndChannelsStore.usageLimitAttentionServers = newValue } }
    var guestVisibleChannels: [String: Bool] { get { serversAndChannelsStore.guestVisibleChannels } set { serversAndChannelsStore.guestVisibleChannels = newValue } }
    var guestJoinableChannels: [String: Bool] { get { serversAndChannelsStore.guestJoinableChannels } set { serversAndChannelsStore.guestJoinableChannels = newValue } }
    var readReceiptsServers: Set<String> { get { serversAndChannelsStore.readReceiptsServers } set { serversAndChannelsStore.readReceiptsServers = newValue } }
    var channelHumanRoles: [String: String] { get { serversAndChannelsStore.channelHumanRoles } set { serversAndChannelsStore.channelHumanRoles = newValue } }
    var channelAuthorityRevisions: [String: Int] { get { serversAndChannelsStore.channelAuthorityRevisions } set { serversAndChannelsStore.channelAuthorityRevisions = newValue } }
    var sidebarModes: [String: (channel: String, joint: String, dm: String, pinned: String, channelTabs: [String], agentTabs: [String])] { get { serversAndChannelsStore.sidebarModes } set { serversAndChannelsStore.sidebarModes = newValue } }
    var sidebarSections: [String: (sections: [(id: String, name: String, emoji: String?, sortMode: String)], order: [String], placements: [(kind: String, id: String, sectionId: String, position: Int)], version: Int)] { get { serversAndChannelsStore.sidebarSections } set { serversAndChannelsStore.sidebarSections = newValue } }
    var sidebarPinnedRefs: [String: (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int)] { get { serversAndChannelsStore.sidebarPinnedRefs } set { serversAndChannelsStore.sidebarPinnedRefs = newValue } }
    var sidebarReadAllEnabled: Bool { get { serversAndChannelsStore.sidebarReadAllEnabled } set { serversAndChannelsStore.sidebarReadAllEnabled = newValue } }
    var jointInvites: [(id: String, hostServerId: String, hostChannelId: String, targetServerId: String, targetChannelId: String, targetOwnerId: String, status: String)] { get { serversAndChannelsStore.jointInvites } set { serversAndChannelsStore.jointInvites = newValue } }
    var composerResourceServers: Set<String> { get { serversAndChannelsStore.composerResourceServers } set { serversAndChannelsStore.composerResourceServers = newValue } }
    var installedServerApps: [String: Set<String>] { get { serversAndChannelsStore.installedServerApps } set { serversAndChannelsStore.installedServerApps = newValue } }

    // Rows for the managed-MCP, action-card and integration surface live in `ManagedMCPAndCardsStore`.
    var managedMCPServers: [ManagedMCPServerRecord] { get { managedMCPAndCardsStore.managedMCPServers } set { managedMCPAndCardsStore.managedMCPServers = newValue } }
    var managedMCPAssignments: [String: [String: (enabled: Bool, allowedTools: [String]?)]] { get { managedMCPAndCardsStore.managedMCPAssignments } set { managedMCPAndCardsStore.managedMCPAssignments = newValue } }
    var actionCardRecords: [String: ActionCardRecord] { get { managedMCPAndCardsStore.actionCardRecords } set { managedMCPAndCardsStore.actionCardRecords = newValue } }
    var marketplaceInstallCards: [String: MarketplaceInstallCard] { get { managedMCPAndCardsStore.marketplaceInstallCards } set { managedMCPAndCardsStore.marketplaceInstallCards = newValue } }
    var integrationRegisterCards: [String: IntegrationRegisterCard] { get { managedMCPAndCardsStore.integrationRegisterCards } set { managedMCPAndCardsStore.integrationRegisterCards = newValue } }
    var agentApiSendReceipts: [String: AgentApiSendReceipt] { get { managedMCPAndCardsStore.agentApiSendReceipts } set { managedMCPAndCardsStore.agentApiSendReceipts = newValue } }
    var pendingActionMessageEvents: [(agentId: String, messageId: String, content: String)] { get { managedMCPAndCardsStore.pendingActionMessageEvents } set { managedMCPAndCardsStore.pendingActionMessageEvents = newValue } }
    var agentGrantSets: [String: Set<String>] { get { managedMCPAndCardsStore.agentGrantSets } set { managedMCPAndCardsStore.agentGrantSets = newValue } }
    var appConfigOverrides: [String: [String: [String: Any]]] { get { managedMCPAndCardsStore.appConfigOverrides } set { managedMCPAndCardsStore.appConfigOverrides = newValue } }
    var appConfigRevisions: [String: [String: Int]] { get { managedMCPAndCardsStore.appConfigRevisions } set { managedMCPAndCardsStore.appConfigRevisions = newValue } }
    var agentIntegrationGrants: [String: Bool] { get { managedMCPAndCardsStore.agentIntegrationGrants } set { managedMCPAndCardsStore.agentIntegrationGrants = newValue } }
    var agentAudienceStatusOverrides: [String: String] { get { managedMCPAndCardsStore.agentAudienceStatusOverrides } set { managedMCPAndCardsStore.agentAudienceStatusOverrides = newValue } }
    var agentIntegrationLogins: [String: AgentIntegrationLoginRecord] { get { managedMCPAndCardsStore.agentIntegrationLogins } set { managedMCPAndCardsStore.agentIntegrationLogins = newValue } }
    public var providerConnectionsEnabledServers: Set<String> { get { managedMCPAndCardsStore.providerConnectionsEnabledServers } set { managedMCPAndCardsStore.providerConnectionsEnabledServers = newValue } }
    var providerConnections: [ProviderConnection] { get { managedMCPAndCardsStore.providerConnections } set { managedMCPAndCardsStore.providerConnections = newValue } }
    var providerAssignments: [ProviderAssignment] { get { managedMCPAndCardsStore.providerAssignments } set { managedMCPAndCardsStore.providerAssignments = newValue } }
    var agentApiIdempotencyKeys: [AgentApiIdempotencyRecord] { get { managedMCPAndCardsStore.agentApiIdempotencyKeys } set { managedMCPAndCardsStore.agentApiIdempotencyKeys = newValue } }

    // Rows for the agent-reminder and product-feedback surface live in `FeedbackStore`.
    var appAgentReminderLedger: [String: String] { get { feedbackStore.appAgentReminderLedger } set { feedbackStore.appAgentReminderLedger = newValue } }
    var agentReminderSurfaceChannels: [String: String] { get { feedbackStore.agentReminderSurfaceChannels } set { feedbackStore.agentReminderSurfaceChannels = newValue } }
    var productFeedbackReporterSessionCache: [String: (token: String, expiresAt: Date)] { get { feedbackStore.productFeedbackReporterSessionCache } set { feedbackStore.productFeedbackReporterSessionCache = newValue } }
    var productFeedbackRouteBindingSuccesses: [String: Date] { get { feedbackStore.productFeedbackRouteBindingSuccesses } set { feedbackStore.productFeedbackRouteBindingSuccesses = newValue } }
    var productFeedbackRouteCommitments: [String: Data] { get { feedbackStore.productFeedbackRouteCommitments } set { feedbackStore.productFeedbackRouteCommitments = newValue } }
    var productFeedbackRouteVerifiedCommitments: Set<String> { get { feedbackStore.productFeedbackRouteVerifiedCommitments } set { feedbackStore.productFeedbackRouteVerifiedCommitments = newValue } }
    var feedbackLocatorRecords: [FeedbackLocatorRecord] { get { feedbackStore.feedbackLocatorRecords } set { feedbackStore.feedbackLocatorRecords = newValue } }
    var handsFeedbackAppsJSONForTesting: String? { get { feedbackStore.handsFeedbackAppsJSON } set { feedbackStore.handsFeedbackAppsJSON = newValue } }
    var handsFeedbackLegacyEnvironmentForTesting: [String: String]? { get { feedbackStore.handsFeedbackLegacyEnvironment } set { feedbackStore.handsFeedbackLegacyEnvironment = newValue } }
}
