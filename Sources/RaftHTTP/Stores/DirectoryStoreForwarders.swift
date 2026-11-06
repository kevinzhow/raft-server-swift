import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The store-backed surface of `EmailLoginDirectory`.
///
/// Every accessor here forwards to one domain store, and each store owns its
/// row family behind its own lock. Keeping them in an extension leaves
/// `EmailLogin.swift` as a composition root: the directory lock, the store
/// instances, the injectable relays and `init()`.
extension EmailLoginDirectory {

    // Notification/announcement/push rows live in `NotificationsStore`. These
    // accessors keep the extension files' property names unchanged.
    public var fcmPushAvailable: Bool { get { notificationsStore.fcmPushAvailable } set { notificationsStore.fcmPushAvailable = newValue } }
    var announcements: [NotificationsStore.AnnouncementRow] { get { notificationsStore.announcements } set { notificationsStore.announcements = newValue } }

    // Profile surface rows live in `AuthProfileStore`.
    var timezoneObservations: [String: TimezoneObservation] { get { authProfileStore.timezoneObservations } set { authProfileStore.timezoneObservations = newValue } }
    var mobileAppEmailContactsByKey: [String: MobileAppEmailContact] { get { authProfileStore.mobileAppEmailContactsByKey } set { authProfileStore.mobileAppEmailContactsByKey = newValue } }
    var storedMobileAppEmailJourneys: [MobileAppEmailJourney] { get { authProfileStore.storedMobileAppEmailJourneys } set { authProfileStore.storedMobileAppEmailJourneys = newValue } }

    // Rows for the task, reminder and assignee-change surface live in `TasksAndRemindersStore`.
    var reminderEvents: [ReminderEvent] { get { tasksAndRemindersStore.reminderEvents } set { tasksAndRemindersStore.reminderEvents = newValue } }
    var taskRecords: [TaskRecord] { get { tasksAndRemindersStore.taskRecords } set { tasksAndRemindersStore.taskRecords = newValue } }
    var taskEvents: [(taskId: String, eventType: String, actorType: String)] { get { tasksAndRemindersStore.taskEvents } set { tasksAndRemindersStore.taskEvents = newValue } }
    var lastTaskServerWarning: String? { get { tasksAndRemindersStore.lastTaskServerWarning } set { tasksAndRemindersStore.lastTaskServerWarning = newValue } }
    var assigneeChangeEvents: [(taskId: String, assigneeId: String?, assigneeType: String?, previousAssigneeId: String?, previousAssigneeType: String?, actorType: String, actorId: String)] { get { tasksAndRemindersStore.assigneeChangeEvents } set { tasksAndRemindersStore.assigneeChangeEvents = newValue } }

    // Rows for the machine, Computer and migration surface live in `MachinesAndComputersStore`.
    var machines: [MachineRecord] { get { machinesAndComputersStore.machines } set { machinesAndComputersStore.machines = newValue } }
    var computers: [(id: String, serverId: String, name: String, apiKey: String, machineId: String?, revokedAt: Date?, online: Bool, version: String?)] { get { machinesAndComputersStore.computers } set { machinesAndComputersStore.computers = newValue } }
    var computerAttachers: [String: String] { get { machinesAndComputersStore.computerAttachers } set { machinesAndComputersStore.computerAttachers = newValue } }
    public var machineMigrationCapabilities: [String: Set<String>] { get { machinesAndComputersStore.machineMigrationCapabilities } set { machinesAndComputersStore.machineMigrationCapabilities = newValue } }
    var machineMigrations: [String: MachineMigrationRecord] { get { agentsRuntimeStore.machineMigrations } set { agentsRuntimeStore.machineMigrations = newValue } }
    var machineRuntimeModels: [String: [String: (models: [(id: String, label: String)], updatedAt: Date)]] { get { machinesAndComputersStore.machineRuntimeModels } set { machinesAndComputersStore.machineRuntimeModels = newValue } }
    var machineKeys: [String: (serverId: String, agentId: String)] { get { machinesAndComputersStore.machineKeys } set { machinesAndComputersStore.machineKeys = newValue } }

    // Rows for the server-membership, sidebar and channel-authority surface live in `ServersAndChannelsStore`.
    var postableChannels: [String: PostableChannel] { get { serversAndChannelsStore.postableChannels } set { serversAndChannelsStore.postableChannels = newValue } }
    var threadOrder: [String] { get { serversAndChannelsStore.threadOrder } set { serversAndChannelsStore.threadOrder = newValue } }
    var hideHumansFromMembers: [String: Bool] { get { serversAndChannelsStore.hideHumansFromMembers } set { serversAndChannelsStore.hideHumansFromMembers = newValue } }
    var membershipAgreementAudits: [(serverId: String, subjectId: String, actorUserId: String, source: String, agreementId: String?, agreementVersion: Int?)] { get { serversAndChannelsStore.membershipAgreementAudits } set { serversAndChannelsStore.membershipAgreementAudits = newValue } }
    var jointProjections: [JointChannelLink] { get { serversAndChannelsStore.jointProjections } set { serversAndChannelsStore.jointProjections = newValue } }
    var serverMemberEvents: [ServerMemberEvent] { get { serversAndChannelsStore.serverMemberEvents } set { serversAndChannelsStore.serverMemberEvents = newValue } }
    var serverOnboardingSettings: [String: (agentId: String?, greeting: Bool)] { get { serversAndChannelsStore.serverOnboardingSettings } set { serversAndChannelsStore.serverOnboardingSettings = newValue } }
    var joinLinks: [String: JoinLinkRecord] { get { serversAndChannelsStore.joinLinks } set { serversAndChannelsStore.joinLinks = newValue } }
    var guestVisibleChannels: [String: Bool] { get { serversAndChannelsStore.guestVisibleChannels } set { serversAndChannelsStore.guestVisibleChannels = newValue } }
    var guestJoinableChannels: [String: Bool] { get { serversAndChannelsStore.guestJoinableChannels } set { serversAndChannelsStore.guestJoinableChannels = newValue } }
    var channelHumanRoles: [String: String] { get { serversAndChannelsStore.channelHumanRoles } set { serversAndChannelsStore.channelHumanRoles = newValue } }
    var sidebarReadAllEnabled: Bool { get { serversAndChannelsStore.sidebarReadAllEnabled } set { serversAndChannelsStore.sidebarReadAllEnabled = newValue } }

    // Rows for the managed-MCP, action-card and integration surface live in `ManagedMCPAndCardsStore`.
    var managedMCPServers: [ManagedMCPServerRecord] { get { managedMCPAndCardsStore.managedMCPServers } set { managedMCPAndCardsStore.managedMCPServers = newValue } }
    var actionCardRecords: [String: ActionCardRecord] { get { managedMCPAndCardsStore.actionCardRecords } set { managedMCPAndCardsStore.actionCardRecords = newValue } }
    var agentGrantSets: [String: Set<String>] { get { managedMCPAndCardsStore.agentGrantSets } set { managedMCPAndCardsStore.agentGrantSets = newValue } }
    var agentIntegrationGrants: [String: Bool] { get { managedMCPAndCardsStore.agentIntegrationGrants } set { managedMCPAndCardsStore.agentIntegrationGrants = newValue } }
    var agentAudienceStatusOverrides: [String: String] { get { managedMCPAndCardsStore.agentAudienceStatusOverrides } set { managedMCPAndCardsStore.agentAudienceStatusOverrides = newValue } }
    var agentApiIdempotencyKeys: [AgentApiIdempotencyRecord] { get { managedMCPAndCardsStore.agentApiIdempotencyKeys } set { managedMCPAndCardsStore.agentApiIdempotencyKeys = newValue } }

    // Rows for the agent-reminder and product-feedback surface live in `FeedbackStore`.
    var agentReminderSurfaceChannels: [String: String] { get { feedbackStore.agentReminderSurfaceChannels } set { feedbackStore.agentReminderSurfaceChannels = newValue } }

    // MARK: - Account, session and login rows (AuthProfileStore)

    var accounts: [String: Account] { get { authProfileStore.accounts } set { authProfileStore.accounts = newValue } }
    var analyticsIds: [String: String] { get { authProfileStore.analyticsIds } set { authProfileStore.analyticsIds = newValue } }
    var sessions: [String: LiveSession] { get { authProfileStore.sessions } set { authProfileStore.sessions = newValue } }
    var revokedFamilies: Set<String> { get { authProfileStore.revokedFamilies } set { authProfileStore.revokedFamilies = newValue } }
    var sessionFamilies: [String: SessionFamily] { get { authProfileStore.sessionFamilies } set { authProfileStore.sessionFamilies = newValue } }
    var retirementReceipts: [String: RetirementReceipt] { get { authProfileStore.retirementReceipts } set { authProfileStore.retirementReceipts = newValue } }
    var accessTokens: [String: String] { get { authProfileStore.accessTokens } set { authProfileStore.accessTokens = newValue } }
    var accessTokenFamilies: [String: String] { get { authProfileStore.accessTokenFamilies } set { authProfileStore.accessTokenFamilies = newValue } }
    var emailVerifications: Int { get { authProfileStore.emailVerifications } set { authProfileStore.emailVerifications = newValue } }
    var socialCompletions: [SocialCompletion] { get { authProfileStore.socialCompletions } set { authProfileStore.socialCompletions = newValue } }
    var pendingSocialLinks: [String: PendingSocialLink] { get { authProfileStore.pendingSocialLinks } set { authProfileStore.pendingSocialLinks = newValue } }
    var mobileRequests: [String: MobileOAuthRequest] { get { authProfileStore.mobileRequests } set { authProfileStore.mobileRequests = newValue } }
    var providerExchanges: Int { get { authProfileStore.providerExchanges } set { authProfileStore.providerExchanges = newValue } }
    var linkedIdentities: [LinkedIdentity] { get { authProfileStore.linkedIdentities } set { authProfileStore.linkedIdentities = newValue } }

    // MARK: - Human messages, reactions and read frontiers (MessagesAndThreadsStore)

    var humanMessageRows: [StoredHumanMessage] { get { messagesAndThreadsStore.humanMessageRows } set { messagesAndThreadsStore.humanMessageRows = newValue } }
    var channelAttachments: [String: ChannelAttachment] { get { messagesAndThreadsStore.channelAttachments } set { messagesAndThreadsStore.channelAttachments = newValue } }
    var forwardedBundles: [String: [ForwardedSource]] { get { messagesAndThreadsStore.forwardedBundles } set { messagesAndThreadsStore.forwardedBundles = newValue } }
    var forwardRecords: [String: StoredForwardRecord] { get { messagesAndThreadsStore.forwardRecords } set { messagesAndThreadsStore.forwardRecords = newValue } }
    var messageReactions: [StoredReaction] { get { messagesAndThreadsStore.messageReactions } set { messagesAndThreadsStore.messageReactions = newValue } }
    var reactionDiscussionVersions: [String: Int] { get { messagesAndThreadsStore.reactionDiscussionVersions } set { messagesAndThreadsStore.reactionDiscussionVersions = newValue } }
    var storedMentions: [StoredMention] { get { messagesAndThreadsStore.storedMentions } set { messagesAndThreadsStore.storedMentions = newValue } }
    var attachmentCommentRecords: [String: [AttachmentCommentRecord]] { get { messagesAndThreadsStore.attachmentCommentRecords } set { messagesAndThreadsStore.attachmentCommentRecords = newValue } }
    var threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)] { get { messagesAndThreadsStore.threadFollows } set { messagesAndThreadsStore.threadFollows = newValue } }
    var threadUnfollows: [String: ThreadUnfollowRecord] { get { messagesAndThreadsStore.threadUnfollows } set { messagesAndThreadsStore.threadUnfollows = newValue } }
    var threadFollowStarts: [String: Date] { get { messagesAndThreadsStore.threadFollowStarts } set { messagesAndThreadsStore.threadFollowStarts = newValue } }
    var agentChannelReadCursors: [String: (seq: Int, version: Int)] { get { messagesAndThreadsStore.agentChannelReadCursors } set { messagesAndThreadsStore.agentChannelReadCursors = newValue } }
    var attestedSendEventRecords: [AttestedSendEventRecord] { get { messagesAndThreadsStore.attestedSendEventRecords } set { messagesAndThreadsStore.attestedSendEventRecords = newValue } }
    var agentSendActivityRecords: [String: [(title: String, text: String, producerFactId: String?)]] { get { messagesAndThreadsStore.agentSendActivityRecords } set { messagesAndThreadsStore.agentSendActivityRecords = newValue } }
    var inboxDoneScopes: Set<String> { get { messagesAndThreadsStore.inboxDoneScopes } set { messagesAndThreadsStore.inboxDoneScopes = newValue } }
    var inboxDoneAt: [String: Date] { get { messagesAndThreadsStore.inboxDoneAt } set { messagesAndThreadsStore.inboxDoneAt = newValue } }
    var inboxDoneFrontiers: [String: Int] { get { messagesAndThreadsStore.inboxDoneFrontiers } set { messagesAndThreadsStore.inboxDoneFrontiers = newValue } }

    // MARK: - Agent registry, hosted runtime and migration rows (AgentsRuntimeStore)

    var serverAgents: [String: ServerAgent] { get { agentsRuntimeStore.serverAgents } set { agentsRuntimeStore.serverAgents = newValue } }
    var channelAgentMembers: [String: Set<String>] { get { agentsRuntimeStore.channelAgentMembers } set { agentsRuntimeStore.channelAgentMembers = newValue } }
    var storedAgentDeliveries: [(agentId: String, messageId: String, channelType: String)] { get { agentsRuntimeStore.storedAgentDeliveries } set { agentsRuntimeStore.storedAgentDeliveries = newValue } }
    var agentCredentials: [String: AgentCredential] { get { agentsRuntimeStore.agentCredentials } set { agentsRuntimeStore.agentCredentials = newValue } }
    var agentMachineIds: [String: String] { get { agentsRuntimeStore.agentMachineIds } set { agentsRuntimeStore.agentMachineIds = newValue } }
    var agentRuntimeProfiles: [String: AgentRuntimeProfileFact] { get { agentsRuntimeStore.agentRuntimeProfiles } set { agentsRuntimeStore.agentRuntimeProfiles = newValue } }
    var activeAgentMigrations: [String: AgentMigrationFact] { get { agentsRuntimeStore.activeAgentMigrations } set { agentsRuntimeStore.activeAgentMigrations = newValue } }
    var agentMigrationServers: Set<String> { get { agentsRuntimeStore.agentMigrationServers } set { agentsRuntimeStore.agentMigrationServers = newValue } }
    var hostedMigrationServers: Set<String> { get { agentsRuntimeStore.hostedMigrationServers } set { agentsRuntimeStore.hostedMigrationServers = newValue } }
    var hostedRuntimeServers: Set<String> { get { agentsRuntimeStore.hostedRuntimeServers } set { agentsRuntimeStore.hostedRuntimeServers = newValue } }
    var hostedProviderTokenOverride: String? { get { agentsRuntimeStore.hostedProviderTokenOverride } set { agentsRuntimeStore.hostedProviderTokenOverride = newValue } }
    var hostedMigrations: [String: HostedMigrationRecord] { get { agentsRuntimeStore.hostedMigrations } set { agentsRuntimeStore.hostedMigrations = newValue } }
    var hostedRuntimes: [String: (provider: String, model: String?, state: String, retryNeedsModel: Bool, createdAt: Date)] { get { agentsRuntimeStore.hostedRuntimes } set { agentsRuntimeStore.hostedRuntimes = newValue } }
    var grokRuntimeServers: Set<String> { get { agentsRuntimeStore.grokRuntimeServers } set { agentsRuntimeStore.grokRuntimeServers = newValue } }
    var remoteUpgradeDisabledServers: Set<String> { get { agentsRuntimeStore.remoteUpgradeDisabledServers } set { agentsRuntimeStore.remoteUpgradeDisabledServers = newValue } }
    var agentStatusAdopted: Set<String> { get { agentsRuntimeStore.agentStatusAdopted } set { agentsRuntimeStore.agentStatusAdopted = newValue } }
    var hostedUsage: [String: String] { get { agentsRuntimeStore.hostedUsage } set { agentsRuntimeStore.hostedUsage = newValue } }
    var hostedModels: [String: HostedModelState] { get { agentsRuntimeStore.hostedModels } set { agentsRuntimeStore.hostedModels = newValue } }
    var agentActivities: [String: (activity: String, detail: String)] { get { agentsRuntimeStore.agentActivities } set { agentsRuntimeStore.agentActivities = newValue } }
    var agentAttachmentBytes: [String: Data] { get { agentsRuntimeStore.agentAttachmentBytes } set { agentsRuntimeStore.agentAttachmentBytes = newValue } }
    var featureFlagRecords: [String: FeatureFlagRecord] { get { agentsRuntimeStore.featureFlagRecords } set { agentsRuntimeStore.featureFlagRecords = newValue } }
    var featureFlagRuleRecords: [FeatureFlagRuleRecord] { get { agentsRuntimeStore.featureFlagRuleRecords } set { agentsRuntimeStore.featureFlagRuleRecords = newValue } }

    // MARK: - Agent relay configuration (AgentsRuntimeStore)

    /// Test seam for the frozen-generation cancel dispatch to a Computer.
    public var agentMigrationCancelDispatch: (@Sendable (_ machineId: String, _ role: String, _ migrationRef: String, _ transportGeneration: String, _ stopAgent: Bool) -> Void)? {
        get { agentsRuntimeStore.agentMigrationCancelDispatch }
        set { agentsRuntimeStore.agentMigrationCancelDispatch = newValue }
    }

    var agentCredentialUseThrottleOverrideMs: Int? {
        get { agentsRuntimeStore.agentCredentialUseThrottleOverrideMs }
        set { agentsRuntimeStore.agentCredentialUseThrottleOverrideMs = newValue }
    }

    var wakeStreamHeartbeatOverrideMs: Int? {
        get { agentsRuntimeStore.wakeStreamHeartbeatOverrideMs }
        set { agentsRuntimeStore.wakeStreamHeartbeatOverrideMs = newValue }
    }

    var agentAttachmentPresign: (@Sendable (String, Int, String, String) throws -> String)? {
        get { agentsRuntimeStore.agentAttachmentPresign }
        set { agentsRuntimeStore.agentAttachmentPresign = newValue }
    }

    // MARK: - Machine relay configuration (MachinesAndComputersStore)

    public var runtimeAccountUsageManualRefresh: (@Sendable (String, String) -> RuntimeAccountUsageManualResult)? {
        get { machinesAndComputersStore.runtimeAccountUsageManualRefresh }
        set { machinesAndComputersStore.runtimeAccountUsageManualRefresh = newValue }
    }

    /// Test seam for the Computer model probe. Production has no live daemon relay here.
    public var machineRuntimeModelProbe: (@Sendable (_ machineId: String, _ runtimeId: String, _ force: Bool) -> RuntimeModelProbeOutcome)? {
        get { machinesAndComputersStore.machineRuntimeModelProbe }
        set { machinesAndComputersStore.machineRuntimeModelProbe = newValue }
    }

    /// Built-in model catalog authority as reported by the Computer.
    public var builtinCatalogMode: String {
        get { machinesAndComputersStore.builtinCatalogMode }
        set { machinesAndComputersStore.builtinCatalogMode = newValue }
    }

    var computerAttachEnabledOverride: Bool? {
        get { machinesAndComputersStore.computerAttachEnabledOverride }
        set { machinesAndComputersStore.computerAttachEnabledOverride = newValue }
    }

    public var computerUpgradeSender: (@Sendable (_ machineId: String, _ targetVersion: String, _ requestId: String) -> Bool)? {
        get { machinesAndComputersStore.computerUpgradeSender }
        set { machinesAndComputersStore.computerUpgradeSender = newValue }
    }

    // MARK: - Sign-in configuration (AuthProfileStore)

    public var mobileProviderProfile: MobileProviderProfile? {
        get { authProfileStore.mobileProviderProfile }
        set { authProfileStore.mobileProviderProfile = newValue }
    }

    /// Exchanged web provider profile. The form-post callback stores a completion and does not link an identity.
    public var webProviderProfile: MobileProviderProfile? {
        get { authProfileStore.webProviderProfile }
        set { authProfileStore.webProviderProfile = newValue }
    }

    /// Providers with a client id and secret. Google and GitHub ignore the Apple platform gate.
    public var configuredSocialAuthProviders: Set<String> {
        get { authProfileStore.configuredSocialAuthProviders }
        set { authProfileStore.configuredSocialAuthProviders = newValue }
    }

    /// `APPLE_CLIENT_ID`, or `APPLE_WEB_CLIENT_ID` when the first is empty.
    public var appleClientId: String {
        get { authProfileStore.appleClientId }
        set { authProfileStore.appleClientId = newValue }
    }

    /// `APPLE_IOS_CLIENT_ID`. Native sign-in stays closed until this and the client secret are set.
    public var nativeAppleClientId: String {
        get { authProfileStore.nativeAppleClientId }
        set { authProfileStore.nativeAppleClientId = newValue }
    }

    public var nativeAppleClientSecret: String {
        get { authProfileStore.nativeAppleClientSecret }
        set { authProfileStore.nativeAppleClientSecret = newValue }
    }

    /// HMAC secret for the native request token. `NATIVE_APPLE_AUTH_STATE_SECRET`.
    public var nativeAppleStateSecret: String {
        get { authProfileStore.nativeAppleStateSecret }
        set { authProfileStore.nativeAppleStateSecret = newValue }
    }

    /// Stand-in for `https://appleid.apple.com/auth/token`. The shipped call builds the form body.
    public var exchangeNativeAppleCode: (@Sendable (NativeAppleCodeExchange) async -> String?)? {
        get { authProfileStore.exchangeNativeAppleCode }
        set { authProfileStore.exchangeNativeAppleCode = newValue }
    }

    /// `SERVER_URL`, without a trailing slash. Used as the Apple redirect base.
    public var serverURL: String {
        get { authProfileStore.serverURL }
        set { authProfileStore.serverURL = newValue }
    }

    /// `APP_URL`. Web OAuth errors redirect here.
    public var appURL: String {
        get { authProfileStore.appURL }
        set { authProfileStore.appURL = newValue }
    }

    /// Raw `MOBILE_OAUTH_RETURN_URI`. A non-empty parsed list replaces the defaults.
    public var mobileOAuthReturnURI: String? {
        get { authProfileStore.mobileOAuthReturnURI }
        set { authProfileStore.mobileOAuthReturnURI = newValue }
    }

    /// Raw `MOBILE_OAUTH_ALLOWED_RETURN_URIS`. Used only when the primary list is empty.
    public var mobileOAuthAllowedReturnURIs: String? {
        get { authProfileStore.mobileOAuthAllowedReturnURIs }
        set { authProfileStore.mobileOAuthAllowedReturnURIs = newValue }
    }

    /// Raw `SLOCK_RELEASE_BRANCH`. Staging self-account opt-in is accepted only when this is exactly `staging`.
    public var releaseBranch: String? {
        get { authProfileStore.releaseBranch }
        set { authProfileStore.releaseBranch = newValue }
    }

    /// Raw `SLOCK_DEVICE_LOGIN_ENABLED`. Unset or empty keeps device login on.
    public var deviceLoginGate: String? {
        get { authProfileStore.deviceLoginGate }
        set { authProfileStore.deviceLoginGate = newValue }
    }

    // MARK: - Notification and mobile-email configuration (NotificationsStore)

    /// `MOBILE_APP_EMAIL_UNSUBSCRIBE_SECRET`, or `JWT_SECRET`.
    public var mobileAppEmailUnsubscribeSecret: String {
        get { notificationsStore.mobileAppEmailUnsubscribeSecret }
        set { notificationsStore.mobileAppEmailUnsubscribeSecret = newValue }
    }

    /// Cancels one scheduled mobile-app lifecycle email. Unset means there is no provider call to make.
    public var cancelMobileAppEmail: (@Sendable (String) -> Void)? {
        get { notificationsStore.cancelMobileAppEmail }
        set { notificationsStore.cancelMobileAppEmail = newValue }
    }

    /// `SLOCK_NATIVE_NOTIFICATIONS_ENABLED=true`. Unset stays off outside the test harness.
    public var nativeNotificationsEnabled: Bool {
        get { notificationsStore.nativeNotificationsEnabled }
        set { notificationsStore.nativeNotificationsEnabled = newValue }
    }

    /// `NATIVE_NOTIFICATION_STREAM_POLL_MS`. Clamped to 250...5000 when a stream polls.
    public var nativeNotificationStreamPollMs: Int {
        get { notificationsStore.nativeNotificationStreamPollMs }
        set { notificationsStore.nativeNotificationStreamPollMs = newValue }
    }

    /// Emitted when an agent read cursor advances. Arguments: serverId, channelId, agentId, maxReadSeq.
    public var onAgentReadUpdated: (@Sendable (String, String, String, Int) -> Void)? {
        get { notificationsStore.onAgentReadUpdated }
        set { notificationsStore.onAgentReadUpdated = newValue }
    }

    /// Test seam called before each already-read SSE frame. Production leaves it nil.
    public var nativeNotificationLiveWriteHook: (@Sendable (_ index: Int, _ eventCount: Int) async -> Void)? {
        get { notificationsStore.nativeNotificationLiveWriteHook }
        set { notificationsStore.nativeNotificationLiveWriteHook = newValue }
    }

    /// `NATIVE_NOTIFICATION_ATTESTATION_MODE`. Nil means the variable is unset.
    public var nativeNotificationAttestationMode: String? {
        get { notificationsStore.nativeNotificationAttestationMode }
        set { notificationsStore.nativeNotificationAttestationMode = newValue }
    }

    /// Process `NODE_ENV`. Production enforces desktop attestation even when the mode is unset.
    public var nativeNotificationNodeEnv: String {
        get { notificationsStore.nativeNotificationNodeEnv }
        set { notificationsStore.nativeNotificationNodeEnv = newValue }
    }

    /// Test seam for signed-app attestation. A nil verifier never accepts evidence.
    public var nativeNotificationAttestationVerifier: (@Sendable (String) -> Bool)? {
        get { notificationsStore.nativeNotificationAttestationVerifier }
        set { notificationsStore.nativeNotificationAttestationVerifier = newValue }
    }

    // MARK: - Messaging and attachment configuration (MessagesAndThreadsStore)

    /// Test seam for the HTML preview body. Nil means the object is missing.
    public var attachmentPreviewBody: (@Sendable (_ attachmentId: String) -> String?)? {
        get { messagesAndThreadsStore.attachmentPreviewBody }
        set { messagesAndThreadsStore.attachmentPreviewBody = newValue }
    }

    /// Test seam for presigning a stored attachment object.
    public var attachmentPresign: (@Sendable (_ attachmentId: String, _ mimeType: String?, _ ttlSeconds: Int) -> String)? {
        get { messagesAndThreadsStore.attachmentPresign }
        set { messagesAndThreadsStore.attachmentPresign = newValue }
    }

    var readPositionSettleMs: Int {
        get { messagesAndThreadsStore.readPositionSettleMs }
        set { messagesAndThreadsStore.readPositionSettleMs = newValue }
    }

    /// Test-only override of `SLOCK_ATTESTED_SEND_MODE`; process environment is
    /// global state and parallel suites must not race on it.
    var sendFreshnessModeOverride: String? {
        get { messagesAndThreadsStore.sendFreshnessModeOverride }
        set { messagesAndThreadsStore.sendFreshnessModeOverride = newValue }
    }

}

// MARK: - Store-backed accessors

/// Directory-level accessors for store properties that production services read
/// and write. Each forwards to the domain store property of the same name.
extension EmailLoginDirectory {
    var experimentalSurfacesDisabledOverride: Bool? {
        get { authProfileStore.experimentalSurfacesDisabledOverride }
        set { authProfileStore.experimentalSurfacesDisabledOverride = newValue }
    }

    var inboxResidues: Set<String> {
        get { messagesAndThreadsStore.inboxResidues }
        set { messagesAndThreadsStore.inboxResidues = newValue }
    }

    var userChannelReadCursors: [String: Int] {
        get { messagesAndThreadsStore.userChannelReadCursors }
        set { messagesAndThreadsStore.userChannelReadCursors = newValue }
    }

    var agentInboxAvailable: Bool? {
        get { agentsRuntimeStore.agentInboxAvailable }
        set { agentsRuntimeStore.agentInboxAvailable = newValue }
    }

    var machineBroadcastPolicies: [String: String] {
        get { machinesAndComputersStore.machineBroadcastPolicies }
        set { machinesAndComputersStore.machineBroadcastPolicies = newValue }
    }

    var machineModelSeenCapability: Set<String> {
        get { machinesAndComputersStore.machineModelSeenCapability }
        set { machinesAndComputersStore.machineModelSeenCapability = newValue }
    }

    var latestComputerRelease: (version: String, notesJSON: String)? {
        get { machinesAndComputersStore.latestComputerRelease }
        set { machinesAndComputersStore.latestComputerRelease = newValue }
    }

}
