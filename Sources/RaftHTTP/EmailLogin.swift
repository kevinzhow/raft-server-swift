import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `POST /api/auth/login`.
///
/// A non-string or empty email or password is refused before any account lookup.
/// A missing account and a wrong password share one 401, and neither issues a session.
///
/// This type is the composition root for the HTTP surface: one directory lock,
/// one store per ledger family, and the injectable relays and configuration
/// below. Store forwarding accessors live in `EmailLogin+StoreForwarders.swift`;
/// the test-only seams live in `EmailLogin+TestSeams.swift`.
public final class EmailLoginDirectory: @unchecked Sendable {
    let lock = NSLock()

    // Domain stores. Each owns one ledger family behind its own lock, and the
    // forwarding accessors keep the extension files' property names while this
    // body stays a composition root.
    let authProfileStore = AuthProfileStore()
    let notificationsStore = NotificationsStore()
    let productEventStore = ProductEventStore()
    let inboxFactStore = InboxFactStore()
    let threadFollowStore = ThreadFollowStore()
    let messagesAndThreadsStore = MessagesAndThreadsStore()
    let agentsRuntimeStore = AgentsRuntimeStore()
    let tasksAndRemindersStore = TasksAndRemindersStore()
    let machinesAndComputersStore = MachinesAndComputersStore()
    let serversAndChannelsStore = ServersAndChannelsStore()
    let managedMCPAndCardsStore = ManagedMCPAndCardsStore()
    let feedbackStore = FeedbackStore()

    // MARK: - Agent and machine relays

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

    var agentConnectionOrigin = "http://localhost:3000"
    let agentConnectionLock = NSLock()
    var agentConnectionProviderStorage: (@Sendable (AgentConnectionProviderRequest) -> AgentConnectionProviderResult)?

    // MARK: - Runtime and machine probes

    var translationProviderOverride: String?
    public var runtimeAccountUsageManualRefresh: (@Sendable (String, String) -> RuntimeAccountUsageManualResult)?
    /// Test seam for the Computer model probe. Production has no live daemon relay here.
    public var machineRuntimeModelProbe: (@Sendable (_ machineId: String, _ runtimeId: String, _ force: Bool) -> RuntimeModelProbeOutcome)?
    /// Whether this server can route a probe to the Computer. Defaults to true.
    public var machineRoutedLocally: (@Sendable (_ machineId: String) -> Bool)?
    /// Built-in model catalog authority as reported by the Computer. Production
    /// has no live authority channel here, so the default is the modern mode.
    public var builtinCatalogMode: String = "supported"
    var computerAttachEnabledOverride: Bool?
    var scopeAttestationSecretOverride: String??
    var deploymentEnvironmentOverride: String??
    public var computerUpgradeSender: (@Sendable (_ machineId: String, _ targetVersion: String, _ requestId: String) -> Bool)?
    var marketplaceReviewerOverride: Set<String>?
    var agentCredentialUseThrottleOverrideMs: Int?
    var wakeStreamHeartbeatOverrideMs: Int?
    var agentAttachmentPresign: (@Sendable (String, Int, String, String) throws -> String)?
    /// Test seam for the HTML preview body. Nil means the object is missing.
    public var attachmentPreviewBody: (@Sendable (_ attachmentId: String) -> String?)?
    /// Test seam for presigning a stored attachment object.
    public var attachmentPresign: (@Sendable (_ attachmentId: String, _ mimeType: String?, _ ttlSeconds: Int) -> String)?
    var readPositionSettleMs: Int = 2000
    /// Test-only override of `SLOCK_ATTESTED_SEND_MODE`; process environment is
    /// global state and parallel suites must not race on it.
    var sendFreshnessModeOverride: String?
    /// Serializes the freshness gate with the commit it protects, so two
    /// concurrent first replies cannot both pass the gate before either lands.
    let sendFreshnessCommitLock = NSLock()

    // MARK: - Feedback and translation transport

    public var handsFeedbackUpstreamHandler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data))?
    var handsConversationAppTokenOverride: String?
    var handsFeedbackBaseURLOverride: String?
    var handsFeedbackAppIdOverride: String?
    var handsFeedbackAppSlugOverride: String?
    var handsFeedbackAppTokenOverride: String?
    public var handsFeedbackConfigured = false

    // MARK: - Social and Apple sign-in

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
    /// Raw `MOBILE_OAUTH_RETURN_URI`. A non-empty parsed list replaces the defaults.
    public var mobileOAuthReturnURI: String?
    /// Raw `MOBILE_OAUTH_ALLOWED_RETURN_URIS`. Used only when the primary list is empty.
    public var mobileOAuthAllowedReturnURIs: String?
    /// Raw `SLOCK_RELEASE_BRANCH`. Staging self-account opt-in is accepted only when this is exactly `staging`.
    public var releaseBranch: String?
    /// Raw `SLOCK_DEVICE_LOGIN_ENABLED`. Unset or empty keeps device login on. `false`, `0`, `no`, and `off` turn it off.
    public var deviceLoginGate: String?

    // MARK: - Native notifications and mobile email

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
    /// Test seam called before each already-read SSE frame. Production leaves it nil.
    public var nativeNotificationLiveWriteHook: (@Sendable (_ index: Int, _ eventCount: Int) async -> Void)?
    /// `NATIVE_NOTIFICATION_ATTESTATION_MODE`. Nil means the variable is unset.
    public var nativeNotificationAttestationMode: String? = nil
    /// Process `NODE_ENV`. Production enforces desktop attestation even when the mode is unset.
    public var nativeNotificationNodeEnv: String = "development"
    /// Test seam for signed-app attestation. A nil verifier never accepts evidence.
    public var nativeNotificationAttestationVerifier: (@Sendable (String) -> Bool)?

    let realtimeEmitterLock = NSLock()
    var realtimeEmitterStorage: (@Sendable (String, String, String?) -> Void)?

    public init() {}
}
