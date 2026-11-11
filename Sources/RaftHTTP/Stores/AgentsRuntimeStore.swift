import Foundation
import Synchronization
import RaftShared

/// Presence, push, cursor, status and provider facts for one external agent,
/// read as one locked snapshot so the diagnostics projection cannot mix two
/// versions of the same agent's rows.
struct ExternalAgentDiagnosticsFacts: Sendable {
    struct ProviderPosition: Sendable {
        let provider: String
        let state: String
        let providerAgentId: String?
        let syncPending: Bool
        let lastErrorCode: String?
        let lastErrorAt: Date?
        let activatedAt: Date?
    }

    struct HostedRuntime: Sendable {
        let state: String
        let createdAt: Date
    }

    let lastSeenAt: Date?
    let activity: String
    let statusProtocolAdoptedAt: Date?
    /// The registered push endpoint, if any. The projection publishes its host
    /// only, never the URL or the delivered secret.
    let pushWebhookURL: String?
    let cursorLastPulledAt: Date?
    let cursorPendingAcks: Int
    let providerPosition: ProviderPosition?
    let hostedRuntime: HostedRuntime?
}

/// Owns the agent-registry, hosted-runtime, migration, presence and feature-flag
/// rows that used to be stored inline on `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class AgentsRuntimeStore: Sendable {
    /// Every row this store owns. The mutex isolates this whole value so a
    /// transaction can inspect and update several rows together. Individual
    /// accessors copy or replace only their own field.
    struct State: Sendable {
        var execution = AgentExecutionState()
        var serverAgents: [String: ServerAgent] = [:]
        var channelAgentMembers: [String: Set<String>] = [:]
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
        var hostedProviderTokenOverride: String? = nil
        var hostedMigrations: [String: HostedMigrationRecord] = [:]
        var machineMigrations: [String: MachineMigrationRecord] = [:]
        var hostedRuntimes: [String: (provider: String, model: String?, state: String, retryNeedsModel: Bool, createdAt: Date)] = [:]
        var grokRuntimeServers: Set<String> = []
        var remoteUpgradeDisabledServers: Set<String> = []
        var agentStatusAdopted: Set<String> = []
        var agentStatusOccurredAt: [String: Date] = [:]
        var agentActivityEventIds: [String: Set<String>] = [:]
        var hostedUsage: [String: String] = [:]
        var hostedModelPickerServers: Set<String> = []
        var hostedModels: [String: HostedModelState] = [:]
        var agentArchiveRecords: [String: AgentArchiveRecord] = [:]
        var agentChannelJoinedAt: [String: Date] = [:]
        var agentChannelPosted: Set<String> = []
        var agentActivities: [String: (activity: String, detail: String)] = [:]
        /// Process-lifetime observation facts behind `agentActivities`: the
        /// canonical detailKind and when the server wrote it. They let a ready
        /// broadcast preserve a fresh busy activity instead of overwriting it.
        /// Reset with the presence rows on restore; neither is a durable fact.
        var agentActivityDetailKind: [String: String] = [:]
        var agentActivityObservedAt: [String: Date] = [:]
        /// RFC 069 §8 per-agent (daemon process, clientSeq) watermark for
        /// `agent:status`. A new daemon process owns an independent sequence
        /// space, so this is process/connection state, not durable presence.
        var sequencedStatusVersions: [String: (daemonInstanceId: String, clientSeq: Int64)] = [:]
        /// `broadcastReadyOnline`'s one-second per-agent dedupe window.
        var lastReadyOnlineBroadcastAt: [String: Date] = [:]
        /// One offline activity projection per machine connection epoch.
        var projectedMachineDisconnects: Set<String> = []
        /// Process-lifetime monotonic sequence for `agent:activity` socket
        /// pushes (upstream `lastActivityServerSeq`). Reset with the presence
        /// rows on restore; it is not a durable fact.
        var agentActivityServerSeq: Int = 0
        var agentLastSeenAt: [String: Date] = [:]
        var agentAttachmentBytes: [String: Data] = [:]
        var externalPushWebhooks: [String: (url: String, secret: String)] = [:]
        var agentStatusProtocolAdoptedAt: [String: Date] = [:]
        var agentCursorPullState: [String: (lastPulledAt: Date, pendingAcks: Int)] = [:]
        var agentProviderPositions: [String: (provider: String, state: String, providerAgentId: String?, syncPending: Bool, lastErrorCode: String?, lastErrorAt: Date?, activatedAt: Date?)] = [:]
        var hostedAgents: Set<String> = []
        var agentInboxAvailable: Bool? = nil
        var featureFlagRecords: [String: FeatureFlagRecord] = [
            "attachment_comments_v0": FeatureFlagRecord(key: "attachment_comments_v0", defaultEnabled: true),
        ]
        var featureFlagRuleRecords: [FeatureFlagRuleRecord] = []
        // Injectable relays and configuration that used to live inline on
        // `EmailLoginDirectory`. The directory keeps the atomic accessors.
        var agentMigrationCancelDispatch: (@Sendable (_ machineId: String, _ role: String, _ migrationRef: String, _ transportGeneration: String, _ stopAgent: Bool) -> Void)? = nil
        var agentStartDispatch: (@Sendable (_ agentId: String, _ resumePrompt: String?) async throws -> AgentStartDispatchOutcome)? = nil
        var agentActivityLogProvider: (@Sendable (_ agentId: String, _ limit: Int?) -> AgentSurfaceResult)? = nil
        var agentActivitySummariesProvider: (@Sendable (_ agentId: String, _ limit: Int, _ beforeEndedAt: Int?, _ beforeId: String?) -> AgentSurfaceResult)? = nil
        var agentSkillsProvider: (@Sendable (_ agentId: String) -> AgentSurfaceResult)? = nil
        var agentHasMachineLocally: (@Sendable (_ agentId: String) -> Bool)? = nil
        var agentWorkspaceTreeProvider: (@Sendable (_ agentId: String, _ dirPath: String?, _ includeHidden: Bool) -> AgentSurfaceResult)? = nil
        var agentWorkspaceReadProvider: (@Sendable (_ agentId: String, _ path: String?) -> AgentSurfaceResult)? = nil
        var agentStartControlDispatch: (@Sendable (_ agentId: String, _ control: String) -> Void)? = nil
        var agentResetDispatch: (@Sendable (_ agentId: String, _ mode: String, _ terminalControl: String) -> Void)? = nil
        var agentConnectionOrigin = "http://localhost:3000"
        var agentConnectionProviderStorage: (@Sendable (AgentConnectionProviderRequest) -> AgentConnectionProviderResult)? = nil
        var agentCredentialUseThrottleOverrideMs: Int? = nil
        var wakeStreamHeartbeatOverrideMs: Int? = nil
        var agentAttachmentPresign: (@Sendable (String, Int, String, String) throws -> String)? = nil
    }

    private let storage = TransactionalState(State())

    /// A copied snapshot of every owned row. Whole-state replacement is retained
    /// for deterministic setup; field setters below update only their own field.
    var state: State {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// Runs `body` on the owned state in ONE critical section, for a decision
    /// that reads and writes several rows and must not interleave with another
    /// request.
    func withState<Result>(_ body: (inout State) -> Result) -> Result {
        storage.withLock { state in body(&state) }
    }

    var serverAgents: [String: ServerAgent] {
        get { storage.withLock { $0.serverAgents } }
        set { storage.withLock { $0.serverAgents = newValue } }
    }

    var channelAgentMembers: [String: Set<String>] {
        get { storage.withLock { $0.channelAgentMembers } }
        set { storage.withLock { $0.channelAgentMembers = newValue } }
    }

    var storedAgentDeliveries: [(agentId: String, messageId: String, channelType: String)] {
        get { storage.withLock { $0.storedAgentDeliveries } }
        set { storage.withLock { $0.storedAgentDeliveries = newValue } }
    }

    var assistantOwners: [String: String] {
        get { storage.withLock { $0.assistantOwners } }
        set { storage.withLock { $0.assistantOwners = newValue } }
    }

    var agentCredentials: [String: AgentCredential] {
        get { storage.withLock { $0.agentCredentials } }
        set { storage.withLock { $0.agentCredentials = newValue } }
    }

    var agentMachineIds: [String: String] {
        get { storage.withLock { $0.agentMachineIds } }
        set { storage.withLock { $0.agentMachineIds = newValue } }
    }

    var agentRuntimeProfiles: [String: AgentRuntimeProfileFact] {
        get { storage.withLock { $0.agentRuntimeProfiles } }
        set { storage.withLock { $0.agentRuntimeProfiles = newValue } }
    }

    var activeAgentMigrations: [String: AgentMigrationFact] {
        get { storage.withLock { $0.activeAgentMigrations } }
        set { storage.withLock { $0.activeAgentMigrations = newValue } }
    }

    var agentMigrationServers: Set<String> {
        get { storage.withLock { $0.agentMigrationServers } }
        set { storage.withLock { $0.agentMigrationServers = newValue } }
    }

    var hostedMigrationServers: Set<String> {
        get { storage.withLock { $0.hostedMigrationServers } }
        set { storage.withLock { $0.hostedMigrationServers = newValue } }
    }

    var hostedRuntimeServers: Set<String> {
        get { storage.withLock { $0.hostedRuntimeServers } }
        set { storage.withLock { $0.hostedRuntimeServers = newValue } }
    }

    var hostedProviderTokenOverride: String? {
        get { storage.withLock { $0.hostedProviderTokenOverride } }
        set { storage.withLock { $0.hostedProviderTokenOverride = newValue } }
    }

    var hostedMigrations: [String: HostedMigrationRecord] {
        get { storage.withLock { $0.hostedMigrations } }
        set { storage.withLock { $0.hostedMigrations = newValue } }
    }

    /// Computer migration rows. They live beside `agentMachineIds` and
    /// `hostedMigrations` so a flip, an auto-start completion or an assignment
    /// is one critical section over every row it reads and writes.
    var machineMigrations: [String: MachineMigrationRecord] {
        get { storage.withLock { $0.machineMigrations } }
        set { storage.withLock { $0.machineMigrations = newValue } }
    }

    var hostedRuntimes: [String: (provider: String, model: String?, state: String, retryNeedsModel: Bool, createdAt: Date)] {
        get { storage.withLock { $0.hostedRuntimes } }
        set { storage.withLock { $0.hostedRuntimes = newValue } }
    }

    var grokRuntimeServers: Set<String> {
        get { storage.withLock { $0.grokRuntimeServers } }
        set { storage.withLock { $0.grokRuntimeServers = newValue } }
    }

    var remoteUpgradeDisabledServers: Set<String> {
        get { storage.withLock { $0.remoteUpgradeDisabledServers } }
        set { storage.withLock { $0.remoteUpgradeDisabledServers = newValue } }
    }

    var agentStatusAdopted: Set<String> {
        get { storage.withLock { $0.agentStatusAdopted } }
        set { storage.withLock { $0.agentStatusAdopted = newValue } }
    }

    var agentStatusOccurredAt: [String: Date] {
        get { storage.withLock { $0.agentStatusOccurredAt } }
        set { storage.withLock { $0.agentStatusOccurredAt = newValue } }
    }

    var agentActivityEventIds: [String: Set<String>] {
        get { storage.withLock { $0.agentActivityEventIds } }
        set { storage.withLock { $0.agentActivityEventIds = newValue } }
    }

    var hostedUsage: [String: String] {
        get { storage.withLock { $0.hostedUsage } }
        set { storage.withLock { $0.hostedUsage = newValue } }
    }

    var hostedModelPickerServers: Set<String> {
        get { storage.withLock { $0.hostedModelPickerServers } }
        set { storage.withLock { $0.hostedModelPickerServers = newValue } }
    }

    var hostedModels: [String: HostedModelState] {
        get { storage.withLock { $0.hostedModels } }
        set { storage.withLock { $0.hostedModels = newValue } }
    }

    var agentArchiveRecords: [String: AgentArchiveRecord] {
        get { storage.withLock { $0.agentArchiveRecords } }
        set { storage.withLock { $0.agentArchiveRecords = newValue } }
    }

    var agentChannelJoinedAt: [String: Date] {
        get { storage.withLock { $0.agentChannelJoinedAt } }
        set { storage.withLock { $0.agentChannelJoinedAt = newValue } }
    }

    var agentChannelPosted: Set<String> {
        get { storage.withLock { $0.agentChannelPosted } }
        set { storage.withLock { $0.agentChannelPosted = newValue } }
    }

    var agentActivities: [String: (activity: String, detail: String)] {
        get { storage.withLock { $0.agentActivities } }
        set { storage.withLock { $0.agentActivities = newValue } }
    }

    var agentLastSeenAt: [String: Date] {
        get { storage.withLock { $0.agentLastSeenAt } }
        set { storage.withLock { $0.agentLastSeenAt = newValue } }
    }

    var agentAttachmentBytes: [String: Data] {
        get { storage.withLock { $0.agentAttachmentBytes } }
        set { storage.withLock { $0.agentAttachmentBytes = newValue } }
    }

    var externalPushWebhooks: [String: (url: String, secret: String)] {
        get { storage.withLock { $0.externalPushWebhooks } }
        set { storage.withLock { $0.externalPushWebhooks = newValue } }
    }

    var agentStatusProtocolAdoptedAt: [String: Date] {
        get { storage.withLock { $0.agentStatusProtocolAdoptedAt } }
        set { storage.withLock { $0.agentStatusProtocolAdoptedAt = newValue } }
    }

    var agentCursorPullState: [String: (lastPulledAt: Date, pendingAcks: Int)] {
        get { storage.withLock { $0.agentCursorPullState } }
        set { storage.withLock { $0.agentCursorPullState = newValue } }
    }

    var agentProviderPositions: [String: (provider: String, state: String, providerAgentId: String?, syncPending: Bool, lastErrorCode: String?, lastErrorAt: Date?, activatedAt: Date?)] {
        get { storage.withLock { $0.agentProviderPositions } }
        set { storage.withLock { $0.agentProviderPositions = newValue } }
    }

    var hostedAgents: Set<String> {
        get { storage.withLock { $0.hostedAgents } }
        set { storage.withLock { $0.hostedAgents = newValue } }
    }

    var agentInboxAvailable: Bool? {
        get { storage.withLock { $0.agentInboxAvailable } }
        set { storage.withLock { $0.agentInboxAvailable = newValue } }
    }

    var featureFlagRecords: [String: FeatureFlagRecord] {
        get { storage.withLock { $0.featureFlagRecords } }
        set { storage.withLock { $0.featureFlagRecords = newValue } }
    }

    var featureFlagRuleRecords: [FeatureFlagRuleRecord] {
        get { storage.withLock { $0.featureFlagRuleRecords } }
        set { storage.withLock { $0.featureFlagRuleRecords = newValue } }
    }

    /// The server-scoped rollout decision for one feature flag.
    ///
    /// The legacy helper read the flag row, the kill switch and the ordered
    /// rules in one expression while holding the directory lock. Keeping the
    /// decision here takes the same read under one store critical section so a
    /// concurrent flag edit cannot produce a torn decision.
    func featureFlagEnabled(key: String, serverId: String) -> Bool {
        return withState { state in
            guard let flag = state.featureFlagRecords[key], flag.enabled, !flag.killSwitch else {
                return false
            }
            let rules = state.featureFlagRuleRecords
                .filter { $0.key == key && $0.stage == "server" && $0.values.contains(serverId) }
                .sorted { $0.priority < $1.priority }
            if let rule = rules.first {
                return rule.decision == "allow"
            }
            return flag.defaultEnabled
        }
    }

    // MARK: - Injected agent relays and configuration

    var agentMigrationCancelDispatch: (@Sendable (_ machineId: String, _ role: String, _ migrationRef: String, _ transportGeneration: String, _ stopAgent: Bool) -> Void)? {
        get { storage.withLock { $0.agentMigrationCancelDispatch } }
        set { storage.withLock { $0.agentMigrationCancelDispatch = newValue } }
    }

    var agentStartDispatch: (@Sendable (_ agentId: String, _ resumePrompt: String?) async throws -> AgentStartDispatchOutcome)? {
        get { storage.withLock { $0.agentStartDispatch } }
        set { storage.withLock { $0.agentStartDispatch = newValue } }
    }

    var agentActivityLogProvider: (@Sendable (_ agentId: String, _ limit: Int?) -> AgentSurfaceResult)? {
        get { storage.withLock { $0.agentActivityLogProvider } }
        set { storage.withLock { $0.agentActivityLogProvider = newValue } }
    }

    var agentActivitySummariesProvider: (@Sendable (_ agentId: String, _ limit: Int, _ beforeEndedAt: Int?, _ beforeId: String?) -> AgentSurfaceResult)? {
        get { storage.withLock { $0.agentActivitySummariesProvider } }
        set { storage.withLock { $0.agentActivitySummariesProvider = newValue } }
    }

    var agentSkillsProvider: (@Sendable (_ agentId: String) -> AgentSurfaceResult)? {
        get { storage.withLock { $0.agentSkillsProvider } }
        set { storage.withLock { $0.agentSkillsProvider = newValue } }
    }

    var agentHasMachineLocally: (@Sendable (_ agentId: String) -> Bool)? {
        get { storage.withLock { $0.agentHasMachineLocally } }
        set { storage.withLock { $0.agentHasMachineLocally = newValue } }
    }

    var agentWorkspaceTreeProvider: (@Sendable (_ agentId: String, _ dirPath: String?, _ includeHidden: Bool) -> AgentSurfaceResult)? {
        get { storage.withLock { $0.agentWorkspaceTreeProvider } }
        set { storage.withLock { $0.agentWorkspaceTreeProvider = newValue } }
    }

    var agentWorkspaceReadProvider: (@Sendable (_ agentId: String, _ path: String?) -> AgentSurfaceResult)? {
        get { storage.withLock { $0.agentWorkspaceReadProvider } }
        set { storage.withLock { $0.agentWorkspaceReadProvider = newValue } }
    }

    var agentStartControlDispatch: (@Sendable (_ agentId: String, _ control: String) -> Void)? {
        get { storage.withLock { $0.agentStartControlDispatch } }
        set { storage.withLock { $0.agentStartControlDispatch = newValue } }
    }

    var agentResetDispatch: (@Sendable (_ agentId: String, _ mode: String, _ terminalControl: String) -> Void)? {
        get { storage.withLock { $0.agentResetDispatch } }
        set { storage.withLock { $0.agentResetDispatch = newValue } }
    }

    var agentConnectionOrigin: String {
        get { storage.withLock { $0.agentConnectionOrigin } }
        set { storage.withLock { $0.agentConnectionOrigin = newValue } }
    }

    var agentConnectionProviderStorage: (@Sendable (AgentConnectionProviderRequest) -> AgentConnectionProviderResult)? {
        get { storage.withLock { $0.agentConnectionProviderStorage } }
        set { storage.withLock { $0.agentConnectionProviderStorage = newValue } }
    }

    var agentCredentialUseThrottleOverrideMs: Int? {
        get { storage.withLock { $0.agentCredentialUseThrottleOverrideMs } }
        set { storage.withLock { $0.agentCredentialUseThrottleOverrideMs = newValue } }
    }

    var wakeStreamHeartbeatOverrideMs: Int? {
        get { storage.withLock { $0.wakeStreamHeartbeatOverrideMs } }
        set { storage.withLock { $0.wakeStreamHeartbeatOverrideMs = newValue } }
    }

    var agentAttachmentPresign: (@Sendable (String, Int, String, String) throws -> String)? {
        get { storage.withLock { $0.agentAttachmentPresign } }
        set { storage.withLock { $0.agentAttachmentPresign = newValue } }
    }
}
