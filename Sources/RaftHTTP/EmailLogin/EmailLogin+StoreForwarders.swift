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
/// instances, the injectable relays and `init()`. The `*ForTesting` accessors
/// live in `EmailLogin+TestSeams.swift`.
extension EmailLoginDirectory {

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

    // MARK: - Account, session and login rows (AuthProfileStore)

    var accounts: [String: Account] { get { authProfileStore.accounts } set { authProfileStore.accounts = newValue } }
    var analyticsIds: [String: String] { get { authProfileStore.analyticsIds } set { authProfileStore.analyticsIds = newValue } }
    var sessions: [String: LiveSession] { get { authProfileStore.sessions } set { authProfileStore.sessions = newValue } }
    var rotationReceipts: [String: RotationReceipt] { get { authProfileStore.rotationReceipts } set { authProfileStore.rotationReceipts = newValue } }
    var predecessorFamilies: [String: String] { get { authProfileStore.predecessorFamilies } set { authProfileStore.predecessorFamilies = newValue } }
    var revokedFamilies: Set<String> { get { authProfileStore.revokedFamilies } set { authProfileStore.revokedFamilies = newValue } }
    var sessionFamilies: [String: SessionFamily] { get { authProfileStore.sessionFamilies } set { authProfileStore.sessionFamilies = newValue } }
    var retirementReceipts: [String: RetirementReceipt] { get { authProfileStore.retirementReceipts } set { authProfileStore.retirementReceipts = newValue } }
    var accessTokens: [String: String] { get { authProfileStore.accessTokens } set { authProfileStore.accessTokens = newValue } }
    var accessTokenFamilies: [String: String] { get { authProfileStore.accessTokenFamilies } set { authProfileStore.accessTokenFamilies = newValue } }
    var emailVerifications: Int { get { authProfileStore.emailVerifications } set { authProfileStore.emailVerifications = newValue } }
    var appLoginRequests: [String: AppLoginRequest] { get { authProfileStore.appLoginRequests } set { authProfileStore.appLoginRequests = newValue } }
    var socialCompletions: [SocialCompletion] { get { authProfileStore.socialCompletions } set { authProfileStore.socialCompletions = newValue } }
    var pendingSocialLinks: [String: PendingSocialLink] { get { authProfileStore.pendingSocialLinks } set { authProfileStore.pendingSocialLinks = newValue } }
    var mobileRequests: [String: MobileOAuthRequest] { get { authProfileStore.mobileRequests } set { authProfileStore.mobileRequests = newValue } }
    var providerExchanges: Int { get { authProfileStore.providerExchanges } set { authProfileStore.providerExchanges = newValue } }
    var consumedHandoffs: Set<String> { get { authProfileStore.consumedHandoffs } set { authProfileStore.consumedHandoffs = newValue } }
    var deviceGrants: [String: DeviceGrant] { get { authProfileStore.deviceGrants } set { authProfileStore.deviceGrants = newValue } }
    var deviceUserCodes: [String: String] { get { authProfileStore.deviceUserCodes } set { authProfileStore.deviceUserCodes = newValue } }
    var appleLoginPlatforms: Set<String> { get { authProfileStore.appleLoginPlatforms } set { authProfileStore.appleLoginPlatforms = newValue } }
    var linkedIdentities: [LinkedIdentity] { get { authProfileStore.linkedIdentities } set { authProfileStore.linkedIdentities = newValue } }

    // MARK: - Human messages, reactions and read frontiers (MessagesAndThreadsStore)

    var humanMessageRows: [StoredHumanMessage] { get { messagesAndThreadsStore.humanMessageRows } set { messagesAndThreadsStore.humanMessageRows = newValue } }
    var channelAttachments: [String: ChannelAttachment] { get { messagesAndThreadsStore.channelAttachments } set { messagesAndThreadsStore.channelAttachments = newValue } }
    var recordedChannelMessageEvents: [EmailLoginDirectory.ChannelMessageEvent] { get { messagesAndThreadsStore.recordedChannelMessageEvents } set { messagesAndThreadsStore.recordedChannelMessageEvents = newValue } }
    var forwardedBundles: [String: [EmailLoginDirectory.ForwardedSource]] { get { messagesAndThreadsStore.forwardedBundles } set { messagesAndThreadsStore.forwardedBundles = newValue } }
    var forwardRecords: [String: StoredForwardRecord] { get { messagesAndThreadsStore.forwardRecords } set { messagesAndThreadsStore.forwardRecords = newValue } }
    var messageReactions: [StoredReaction] { get { messagesAndThreadsStore.messageReactions } set { messagesAndThreadsStore.messageReactions = newValue } }
    var reactionViewerVersions: [String: Int] { get { messagesAndThreadsStore.reactionViewerVersions } set { messagesAndThreadsStore.reactionViewerVersions = newValue } }
    var reactionDiscussionVersions: [String: Int] { get { messagesAndThreadsStore.reactionDiscussionVersions } set { messagesAndThreadsStore.reactionDiscussionVersions = newValue } }
    var storedMentions: [StoredMention] { get { messagesAndThreadsStore.storedMentions } set { messagesAndThreadsStore.storedMentions = newValue } }
    var attachmentCommentRecords: [String: [AttachmentCommentRecord]] { get { messagesAndThreadsStore.attachmentCommentRecords } set { messagesAndThreadsStore.attachmentCommentRecords = newValue } }
    var messageTranslationLedger: [String: (status: String, providerBilledChars: Int, targetLanguage: String, translatedContent: String)] { get { messagesAndThreadsStore.messageTranslationLedger } set { messagesAndThreadsStore.messageTranslationLedger = newValue } }
    var readMutationRecords: [String: ReadMutationRecord] { get { messagesAndThreadsStore.readMutationRecords } set { messagesAndThreadsStore.readMutationRecords = newValue } }
    var readMutationAuthoritySeq: [String: Int] { get { messagesAndThreadsStore.readMutationAuthoritySeq } set { messagesAndThreadsStore.readMutationAuthoritySeq = newValue } }
    var readMutationOrder: [String] { get { messagesAndThreadsStore.readMutationOrder } set { messagesAndThreadsStore.readMutationOrder = newValue } }
    var readMutationAcks: [String: (scopeId: String, throughSeq: Int)] { get { messagesAndThreadsStore.readMutationAcks } set { messagesAndThreadsStore.readMutationAcks = newValue } }
    var shareArtifacts: [String: ShareArtifactRecord] { get { messagesAndThreadsStore.shareArtifacts } set { messagesAndThreadsStore.shareArtifacts = newValue } }
    var systemAttentionIncidents: [SystemAttentionIncident] { get { messagesAndThreadsStore.systemAttentionIncidents } set { messagesAndThreadsStore.systemAttentionIncidents = newValue } }
    var systemAttentionReceipts: [String: SystemAttentionReceipt] { get { messagesAndThreadsStore.systemAttentionReceipts } set { messagesAndThreadsStore.systemAttentionReceipts = newValue } }
    var threadFollows: [String: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)] { get { messagesAndThreadsStore.threadFollows } set { messagesAndThreadsStore.threadFollows = newValue } }
    var threadUnfollows: [String: ThreadUnfollowRecord] { get { messagesAndThreadsStore.threadUnfollows } set { messagesAndThreadsStore.threadUnfollows = newValue } }
    var threadFollowStarts: [String: Date] { get { messagesAndThreadsStore.threadFollowStarts } set { messagesAndThreadsStore.threadFollowStarts = newValue } }
    var threadFollowerRemovals: [String: (serverId: String, threadChannelId: String, agentId: String)] { get { messagesAndThreadsStore.threadFollowerRemovals } set { messagesAndThreadsStore.threadFollowerRemovals = newValue } }
    var staleThreadFollowerUndoTokens: Set<String> { get { messagesAndThreadsStore.staleThreadFollowerUndoTokens } set { messagesAndThreadsStore.staleThreadFollowerUndoTokens = newValue } }
    var channelReadVersions: [String: Int] { get { messagesAndThreadsStore.channelReadVersions } set { messagesAndThreadsStore.channelReadVersions = newValue } }
    var agentChannelReadCursors: [String: (seq: Int, version: Int)] { get { messagesAndThreadsStore.agentChannelReadCursors } set { messagesAndThreadsStore.agentChannelReadCursors = newValue } }
    var attestedSendEventRecords: [AttestedSendEventRecord] { get { messagesAndThreadsStore.attestedSendEventRecords } set { messagesAndThreadsStore.attestedSendEventRecords = newValue } }
    var agentSendActivityRecords: [String: [(title: String, text: String, producerFactId: String?)]] { get { messagesAndThreadsStore.agentSendActivityRecords } set { messagesAndThreadsStore.agentSendActivityRecords = newValue } }
    var inboxDoneScopes: Set<String> { get { messagesAndThreadsStore.inboxDoneScopes } set { messagesAndThreadsStore.inboxDoneScopes = newValue } }
    var inboxDoneAt: [String: Date] { get { messagesAndThreadsStore.inboxDoneAt } set { messagesAndThreadsStore.inboxDoneAt = newValue } }
    var inboxDoneFrontiers: [String: Int] { get { messagesAndThreadsStore.inboxDoneFrontiers } set { messagesAndThreadsStore.inboxDoneFrontiers = newValue } }
    var deferredUnreadAdvance: [String: Int] { get { messagesAndThreadsStore.deferredUnreadAdvance } set { messagesAndThreadsStore.deferredUnreadAdvance = newValue } }
    var externalAvatarAssets: [String: ExternalAvatarAsset] { get { messagesAndThreadsStore.externalAvatarAssets } set { messagesAndThreadsStore.externalAvatarAssets = newValue } }
    var externalAvatarStorageAvailable: Bool { get { messagesAndThreadsStore.externalAvatarStorageAvailable } set { messagesAndThreadsStore.externalAvatarStorageAvailable = newValue } }

    // MARK: - Agent registry, hosted runtime and migration rows (AgentsRuntimeStore)

    var serverAgents: [String: ServerAgent] { get { agentsRuntimeStore.serverAgents } set { agentsRuntimeStore.serverAgents = newValue } }
    var channelAgentMembers: [String: Set<String>] { get { agentsRuntimeStore.channelAgentMembers } set { agentsRuntimeStore.channelAgentMembers = newValue } }
    var storedAgentDeliveries: [(agentId: String, messageId: String, channelType: String)] { get { agentsRuntimeStore.storedAgentDeliveries } set { agentsRuntimeStore.storedAgentDeliveries = newValue } }
    var assistantOwners: [String: String] { get { agentsRuntimeStore.assistantOwners } set { agentsRuntimeStore.assistantOwners = newValue } }
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
    var agentStatusOccurredAt: [String: Date] { get { agentsRuntimeStore.agentStatusOccurredAt } set { agentsRuntimeStore.agentStatusOccurredAt = newValue } }
    var agentActivityEventIds: [String: Set<String>] { get { agentsRuntimeStore.agentActivityEventIds } set { agentsRuntimeStore.agentActivityEventIds = newValue } }
    var hostedUsage: [String: String] { get { agentsRuntimeStore.hostedUsage } set { agentsRuntimeStore.hostedUsage = newValue } }
    var hostedModelPickerServers: Set<String> { get { agentsRuntimeStore.hostedModelPickerServers } set { agentsRuntimeStore.hostedModelPickerServers = newValue } }
    var hostedModels: [String: HostedModelState] { get { agentsRuntimeStore.hostedModels } set { agentsRuntimeStore.hostedModels = newValue } }
    var agentArchiveRecords: [String: AgentArchiveRecord] { get { agentsRuntimeStore.agentArchiveRecords } set { agentsRuntimeStore.agentArchiveRecords = newValue } }
    var agentChannelJoinedAt: [String: Date] { get { agentsRuntimeStore.agentChannelJoinedAt } set { agentsRuntimeStore.agentChannelJoinedAt = newValue } }
    var agentChannelPosted: Set<String> { get { agentsRuntimeStore.agentChannelPosted } set { agentsRuntimeStore.agentChannelPosted = newValue } }
    var agentActivities: [String: (activity: String, detail: String)] { get { agentsRuntimeStore.agentActivities } set { agentsRuntimeStore.agentActivities = newValue } }
    var agentLastSeenAt: [String: Date] { get { agentsRuntimeStore.agentLastSeenAt } set { agentsRuntimeStore.agentLastSeenAt = newValue } }
    var agentAttachmentBytes: [String: Data] { get { agentsRuntimeStore.agentAttachmentBytes } set { agentsRuntimeStore.agentAttachmentBytes = newValue } }
    var externalPushWebhooks: [String: (url: String, secret: String)] { get { agentsRuntimeStore.externalPushWebhooks } set { agentsRuntimeStore.externalPushWebhooks = newValue } }
    var agentStatusProtocolAdoptedAt: [String: Date] { get { agentsRuntimeStore.agentStatusProtocolAdoptedAt } set { agentsRuntimeStore.agentStatusProtocolAdoptedAt = newValue } }
    var agentCursorPullState: [String: (lastPulledAt: Date, pendingAcks: Int)] { get { agentsRuntimeStore.agentCursorPullState } set { agentsRuntimeStore.agentCursorPullState = newValue } }
    var agentProviderPositions: [String: (provider: String, state: String, providerAgentId: String?, syncPending: Bool, lastErrorCode: String?, lastErrorAt: Date?, activatedAt: Date?)] { get { agentsRuntimeStore.agentProviderPositions } set { agentsRuntimeStore.agentProviderPositions = newValue } }
    var hostedAgents: Set<String> { get { agentsRuntimeStore.hostedAgents } set { agentsRuntimeStore.hostedAgents = newValue } }
    var featureFlagRecords: [String: FeatureFlagRecord] { get { agentsRuntimeStore.featureFlagRecords } set { agentsRuntimeStore.featureFlagRecords = newValue } }
    var featureFlagRuleRecords: [FeatureFlagRuleRecord] { get { agentsRuntimeStore.featureFlagRuleRecords } set { agentsRuntimeStore.featureFlagRuleRecords = newValue } }

    // MARK: - Lock-guarded configuration forwarders

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
}
