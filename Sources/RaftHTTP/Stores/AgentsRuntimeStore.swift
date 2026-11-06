import Foundation

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
final class AgentsRuntimeStore: @unchecked Sendable {
    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State {
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
        var agentConfigLiftDispatch: (@Sendable (_ agentId: String, _ runtimeValuesChanged: Bool) -> Void)? = nil
        var agentConnectionOrigin = "http://localhost:3000"
        var agentConnectionProviderStorage: (@Sendable (AgentConnectionProviderRequest) -> AgentConnectionProviderResult)? = nil
        var agentCredentialUseThrottleOverrideMs: Int? = nil
        var wakeStreamHeartbeatOverrideMs: Int? = nil
        var agentAttachmentPresign: (@Sendable (String, Int, String, String) throws -> String)? = nil
    }

    private let lock = NSLock()
    private var storage = State()

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    /// Runs `body` on the owned state in ONE critical section, for a decision
    /// that reads and writes several rows and must not interleave with another
    /// request.
    func withState<Result>(_ body: (inout State) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var serverAgents: [String: ServerAgent] {
        get { state.serverAgents }
        set { state.serverAgents = newValue }
    }

    var channelAgentMembers: [String: Set<String>] {
        get { state.channelAgentMembers }
        set { state.channelAgentMembers = newValue }
    }

    var storedAgentDeliveries: [(agentId: String, messageId: String, channelType: String)] {
        get { state.storedAgentDeliveries }
        set { state.storedAgentDeliveries = newValue }
    }

    var assistantOwners: [String: String] {
        get { state.assistantOwners }
        set { state.assistantOwners = newValue }
    }

    var agentCredentials: [String: AgentCredential] {
        get { state.agentCredentials }
        set { state.agentCredentials = newValue }
    }

    var agentMachineIds: [String: String] {
        get { state.agentMachineIds }
        set { state.agentMachineIds = newValue }
    }

    var agentRuntimeProfiles: [String: AgentRuntimeProfileFact] {
        get { state.agentRuntimeProfiles }
        set { state.agentRuntimeProfiles = newValue }
    }

    var activeAgentMigrations: [String: AgentMigrationFact] {
        get { state.activeAgentMigrations }
        set { state.activeAgentMigrations = newValue }
    }

    var agentMigrationServers: Set<String> {
        get { state.agentMigrationServers }
        set { state.agentMigrationServers = newValue }
    }

    var hostedMigrationServers: Set<String> {
        get { state.hostedMigrationServers }
        set { state.hostedMigrationServers = newValue }
    }

    var hostedRuntimeServers: Set<String> {
        get { state.hostedRuntimeServers }
        set { state.hostedRuntimeServers = newValue }
    }

    var hostedProviderTokenOverride: String? {
        get { state.hostedProviderTokenOverride }
        set { state.hostedProviderTokenOverride = newValue }
    }

    var hostedMigrations: [String: HostedMigrationRecord] {
        get { state.hostedMigrations }
        set { state.hostedMigrations = newValue }
    }

    /// Computer migration rows. They live beside `agentMachineIds` and
    /// `hostedMigrations` so a flip, an auto-start completion or an assignment
    /// is one critical section over every row it reads and writes.
    var machineMigrations: [String: MachineMigrationRecord] {
        get { state.machineMigrations }
        set { state.machineMigrations = newValue }
    }

    var hostedRuntimes: [String: (provider: String, model: String?, state: String, retryNeedsModel: Bool, createdAt: Date)] {
        get { state.hostedRuntimes }
        set { state.hostedRuntimes = newValue }
    }

    var grokRuntimeServers: Set<String> {
        get { state.grokRuntimeServers }
        set { state.grokRuntimeServers = newValue }
    }

    var remoteUpgradeDisabledServers: Set<String> {
        get { state.remoteUpgradeDisabledServers }
        set { state.remoteUpgradeDisabledServers = newValue }
    }

    var agentStatusAdopted: Set<String> {
        get { state.agentStatusAdopted }
        set { state.agentStatusAdopted = newValue }
    }

    var agentStatusOccurredAt: [String: Date] {
        get { state.agentStatusOccurredAt }
        set { state.agentStatusOccurredAt = newValue }
    }

    var agentActivityEventIds: [String: Set<String>] {
        get { state.agentActivityEventIds }
        set { state.agentActivityEventIds = newValue }
    }

    var hostedUsage: [String: String] {
        get { state.hostedUsage }
        set { state.hostedUsage = newValue }
    }

    var hostedModelPickerServers: Set<String> {
        get { state.hostedModelPickerServers }
        set { state.hostedModelPickerServers = newValue }
    }

    var hostedModels: [String: HostedModelState] {
        get { state.hostedModels }
        set { state.hostedModels = newValue }
    }

    var agentArchiveRecords: [String: AgentArchiveRecord] {
        get { state.agentArchiveRecords }
        set { state.agentArchiveRecords = newValue }
    }

    var agentChannelJoinedAt: [String: Date] {
        get { state.agentChannelJoinedAt }
        set { state.agentChannelJoinedAt = newValue }
    }

    var agentChannelPosted: Set<String> {
        get { state.agentChannelPosted }
        set { state.agentChannelPosted = newValue }
    }

    var agentActivities: [String: (activity: String, detail: String)] {
        get { state.agentActivities }
        set { state.agentActivities = newValue }
    }

    var agentLastSeenAt: [String: Date] {
        get { state.agentLastSeenAt }
        set { state.agentLastSeenAt = newValue }
    }

    var agentAttachmentBytes: [String: Data] {
        get { state.agentAttachmentBytes }
        set { state.agentAttachmentBytes = newValue }
    }

    var externalPushWebhooks: [String: (url: String, secret: String)] {
        get { state.externalPushWebhooks }
        set { state.externalPushWebhooks = newValue }
    }

    var agentStatusProtocolAdoptedAt: [String: Date] {
        get { state.agentStatusProtocolAdoptedAt }
        set { state.agentStatusProtocolAdoptedAt = newValue }
    }

    var agentCursorPullState: [String: (lastPulledAt: Date, pendingAcks: Int)] {
        get { state.agentCursorPullState }
        set { state.agentCursorPullState = newValue }
    }

    var agentProviderPositions: [String: (provider: String, state: String, providerAgentId: String?, syncPending: Bool, lastErrorCode: String?, lastErrorAt: Date?, activatedAt: Date?)] {
        get { state.agentProviderPositions }
        set { state.agentProviderPositions = newValue }
    }

    var hostedAgents: Set<String> {
        get { state.hostedAgents }
        set { state.hostedAgents = newValue }
    }

    var agentInboxAvailable: Bool? {
        get { state.agentInboxAvailable }
        set { state.agentInboxAvailable = newValue }
    }

    var featureFlagRecords: [String: FeatureFlagRecord] {
        get { state.featureFlagRecords }
        set { state.featureFlagRecords = newValue }
    }

    var featureFlagRuleRecords: [FeatureFlagRuleRecord] {
        get { state.featureFlagRuleRecords }
        set { state.featureFlagRuleRecords = newValue }
    }

    /// The server-scoped rollout decision for one feature flag.
    ///
    /// The legacy helper read the flag row, the kill switch and the ordered
    /// rules in one expression while holding the directory lock. Keeping the
    /// decision here takes the same read under one store critical section so a
    /// concurrent flag edit cannot produce a torn decision.
    func featureFlagEnabled(key: String, serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let flag = storage.featureFlagRecords[key], flag.enabled, !flag.killSwitch else {
            return false
        }
        let rules = storage.featureFlagRuleRecords
            .filter { $0.key == key && $0.stage == "server" && $0.values.contains(serverId) }
            .sorted { $0.priority < $1.priority }
        if let rule = rules.first {
            return rule.decision == "allow"
        }
        return flag.defaultEnabled
    }

    // MARK: - Injected agent relays and configuration

    var agentMigrationCancelDispatch: (@Sendable (_ machineId: String, _ role: String, _ migrationRef: String, _ transportGeneration: String, _ stopAgent: Bool) -> Void)? {
        get { state.agentMigrationCancelDispatch }
        set { state.agentMigrationCancelDispatch = newValue }
    }

    var agentStartDispatch: (@Sendable (_ agentId: String, _ resumePrompt: String?) async throws -> AgentStartDispatchOutcome)? {
        get { state.agentStartDispatch }
        set { state.agentStartDispatch = newValue }
    }

    var agentActivityLogProvider: (@Sendable (_ agentId: String, _ limit: Int?) -> AgentSurfaceResult)? {
        get { state.agentActivityLogProvider }
        set { state.agentActivityLogProvider = newValue }
    }

    var agentActivitySummariesProvider: (@Sendable (_ agentId: String, _ limit: Int, _ beforeEndedAt: Int?, _ beforeId: String?) -> AgentSurfaceResult)? {
        get { state.agentActivitySummariesProvider }
        set { state.agentActivitySummariesProvider = newValue }
    }

    var agentSkillsProvider: (@Sendable (_ agentId: String) -> AgentSurfaceResult)? {
        get { state.agentSkillsProvider }
        set { state.agentSkillsProvider = newValue }
    }

    var agentHasMachineLocally: (@Sendable (_ agentId: String) -> Bool)? {
        get { state.agentHasMachineLocally }
        set { state.agentHasMachineLocally = newValue }
    }

    var agentWorkspaceTreeProvider: (@Sendable (_ agentId: String, _ dirPath: String?, _ includeHidden: Bool) -> AgentSurfaceResult)? {
        get { state.agentWorkspaceTreeProvider }
        set { state.agentWorkspaceTreeProvider = newValue }
    }

    var agentWorkspaceReadProvider: (@Sendable (_ agentId: String, _ path: String?) -> AgentSurfaceResult)? {
        get { state.agentWorkspaceReadProvider }
        set { state.agentWorkspaceReadProvider = newValue }
    }

    var agentStartControlDispatch: (@Sendable (_ agentId: String, _ control: String) -> Void)? {
        get { state.agentStartControlDispatch }
        set { state.agentStartControlDispatch = newValue }
    }

    var agentResetDispatch: (@Sendable (_ agentId: String, _ mode: String, _ terminalControl: String) -> Void)? {
        get { state.agentResetDispatch }
        set { state.agentResetDispatch = newValue }
    }

    var agentConfigLiftDispatch: (@Sendable (_ agentId: String, _ runtimeValuesChanged: Bool) -> Void)? {
        get { state.agentConfigLiftDispatch }
        set { state.agentConfigLiftDispatch = newValue }
    }

    var agentConnectionOrigin: String {
        get { state.agentConnectionOrigin }
        set { state.agentConnectionOrigin = newValue }
    }

    var agentConnectionProviderStorage: (@Sendable (AgentConnectionProviderRequest) -> AgentConnectionProviderResult)? {
        get { state.agentConnectionProviderStorage }
        set { state.agentConnectionProviderStorage = newValue }
    }

    var agentCredentialUseThrottleOverrideMs: Int? {
        get { state.agentCredentialUseThrottleOverrideMs }
        set { state.agentCredentialUseThrottleOverrideMs = newValue }
    }

    var wakeStreamHeartbeatOverrideMs: Int? {
        get { state.wakeStreamHeartbeatOverrideMs }
        set { state.wakeStreamHeartbeatOverrideMs = newValue }
    }

    var agentAttachmentPresign: (@Sendable (String, Int, String, String) throws -> String)? {
        get { state.agentAttachmentPresign }
        set { state.agentAttachmentPresign = newValue }
    }

    // MARK: - External diagnostics and migration cancellation

    /// One locked read of every row the external-diagnostics projection shows.
    func externalDiagnosticsFacts(agentId: String) -> ExternalAgentDiagnosticsFacts {
        lock.lock()
        defer { lock.unlock() }
        let hosted = storage.hostedRuntimes[agentId]
        return ExternalAgentDiagnosticsFacts(
            lastSeenAt: storage.agentLastSeenAt[agentId],
            activity: storage.agentActivities[agentId]?.activity ?? "idle",
            statusProtocolAdoptedAt: storage.agentStatusProtocolAdoptedAt[agentId],
            pushWebhookURL: storage.externalPushWebhooks[agentId]?.url,
            cursorLastPulledAt: storage.agentCursorPullState[agentId]?.lastPulledAt,
            cursorPendingAcks: storage.agentCursorPullState[agentId]?.pendingAcks ?? 0,
            providerPosition: storage.agentProviderPositions[agentId].map {
                ExternalAgentDiagnosticsFacts.ProviderPosition(
                    provider: $0.provider,
                    state: $0.state,
                    providerAgentId: $0.providerAgentId,
                    syncPending: $0.syncPending,
                    lastErrorCode: $0.lastErrorCode,
                    lastErrorAt: $0.lastErrorAt,
                    activatedAt: $0.activatedAt
                )
            },
            hostedRuntime: hosted.map {
                ExternalAgentDiagnosticsFacts.HostedRuntime(state: $0.state, createdAt: $0.createdAt)
            }
        )
    }

    /// One locked cancel transition for the hosted migration of one agent:
    /// presence, revision, terminal-state check and write share the lock, so
    /// two concurrent cancels cannot both pass the revision gate.
    func cancelHostedMigration(
        agentId: String,
        serverId: String,
        migrationRef: String,
        expectedRevision: Int,
        reason: String,
        now: Date
    ) -> AgentMigrationCancelOutcome<HostedMigrationRecord> {
        lock.lock()
        defer { lock.unlock() }
        guard let candidate = storage.hostedMigrations[agentId],
              candidate.supportRef == migrationRef,
              candidate.serverId == serverId
        else { return .missing }
        guard candidate.revision == expectedRevision else { return .stale }
        guard !AgentMigrationCancelPolicy.terminalStates.contains(candidate.state) else { return .terminal }
        var migration = candidate
        migration.state = "canceled_pre_flip"
        migration.revision += 1
        migration.canceledAt = now
        migration.cancelReason = reason
        migration.cancelDispatchAttempts = 1
        migration.cancelLastDispatchAt = now
        migration.cancelErrorCode = nil
        storage.hostedMigrations[agentId] = migration
        return .canceled(migration)
    }

    // MARK: - Agent send delivery

    /// Reads one agent credential without changing it. The caller still checks
    /// `revokedAt` and the agent runtime row.
    func agentCredential(token: String) -> (agentId: String, scopes: [String], revokedAt: Date?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let credential = storage.agentCredentials[token] else { return nil }
        return (credential.agentId, Array(credential.scopes), credential.revokedAt)
    }

    /// The shared agent-credential check: a present, unrevoked credential is
    /// marked used and its identity returned in one critical section.

    // MARK: - Join-link and agent-profile checks

    /// Whether one server already has an agent row. The setup reset refuses
    /// after this is true.
    func hasServerAgent(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.serverAgents.values.contains { $0.serverId == serverId }
    }

    func isHostedAgent(_ agentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.hostedAgents.contains(agentId)
    }

    /// The `agentCredentialAgent` read, kept in one critical section: a revoked
    /// credential does not resolve and a live one records the use.
    func useAgentCredential(token: String, now: Date) -> (agentId: String, scopes: [String])? {
        lock.lock()
        defer { lock.unlock() }
        guard let credential = storage.agentCredentials[token], credential.revokedAt == nil else {
            return nil
        }
        storage.agentCredentials[token]?.lastUsedAt = now
        return (credential.agentId, Array(credential.scopes))
    }

    /// Hosted-agent membership written by the profile route and read by the
    /// join-link policy.
    func markHosted(agentId: String) {
        lock.lock()
        storage.hostedAgents.insert(agentId)
        lock.unlock()
    }

    /// One activity-ingest pass over an agent's status rows.
    ///
    /// The legacy loop updated adopted/occurredAt/activities as it went and
    /// committed the dedupe set only after the last event, so a later invalid
    /// status leaves the earlier status writes in place. The outcome preserves
    /// that: `invalidStatus`/`detailInvalid`/`detailTooLong` return before the
    /// event-id commit.
    enum ActivityIngestOutcome: Sendable, Equatable {
        case applied(accepted: Int, rejected: Int)
        case invalidStatus
        case detailInvalid
        case detailTooLong
    }

    func applyActivityIngest(
        agentId: String,
        events: [AgentActivityEvent],
        now: @Sendable () -> Date
    ) -> ActivityIngestOutcome {
        let standardStatuses: Set<String> = ["working", "thinking", "online", "error", "offline"]
        lock.lock()
        defer { lock.unlock() }
        var accepted = 0
        var rejected = 0
        var seen = storage.agentActivityEventIds[agentId] ?? []
        for event in events {
            guard let eventId = event.eventId,
                  let occurred = event.occurredAt
            else {
                rejected += 1
                continue
            }
            if seen.contains(eventId) {
                rejected += 1
                continue
            }
            let status = event.status
            if let status, !standardStatuses.contains(status), status != "failed" {
                return .invalidStatus
            }
            var detailText = ""
            if let detail = event.detail {
                guard case .string(let text) = detail else { return .detailInvalid }
                if text.count > 200 { return .detailTooLong }
                detailText = text
            }
            let effective = min(occurred, now())
            seen.insert(eventId)
            accepted += 1
            let isStandardStatus = status.map { standardStatuses.contains($0) } ?? false
            if isStandardStatus, let status {
                storage.agentStatusAdopted.insert(agentId)
                if effective >= (storage.agentStatusOccurredAt[agentId] ?? .distantPast) {
                    storage.agentStatusOccurredAt[agentId] = effective
                    storage.agentActivities[agentId] = (activity: status, detail: detailText)
                }
            } else if let hookName = event.hookEventName, !storage.agentStatusAdopted.contains(agentId) {
                let hookStatus: String
                switch hookName {
                case "PreToolUse": hookStatus = "working"
                case "PostToolUseFailure": hookStatus = "error"
                case "Stop", "SessionEnd": hookStatus = "online"
                default: hookStatus = "working"
                }
                if effective >= (storage.agentStatusOccurredAt[agentId] ?? .distantPast) {
                    storage.agentStatusOccurredAt[agentId] = effective
                    storage.agentActivities[agentId] = (activity: hookStatus, detail: "")
                }
            }
        }
        storage.agentActivityEventIds[agentId] = seen
        return .applied(accepted: accepted, rejected: rejected)
    }

    /// The `agentCapabilityDenial` predicate: a live credential that does not
    /// carry the required scope is the only denial.
    func agentCredentialLacksScope(token: String, required: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let credential = storage.agentCredentials[token], credential.revokedAt == nil else {
            return false
        }
        return !credential.scopes.contains(required)
    }

    /// Raw credential lookup used by the profile update. The upstream handler
    /// does not re-check revocation here, and the parity test set depends on
    /// that reading.
    func agentId(forCredentialToken token: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentCredentials[token]?.agentId
    }

    /// The first-post attention hint: the membership check and the "already
    /// posted" insertion are one critical section, so two concurrent first
    /// sends cannot both publish the drive-by hint.
    func claimFirstAgentPost(channelId: String, agentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(agentId)"
        if storage.agentChannelPosted.contains(key) { return false }
        storage.agentChannelPosted.insert(key)
        return true
    }

    // MARK: - Runtime options and workspaces

    /// Whether the `grok` runtime is offered to one Server.
    func isGrokRuntimeEnabled(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.grokRuntimeServers.contains(serverId)
    }

    /// The agents bound to one machine, in the store's own iteration order.
    func agentIds(boundToMachine machineId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentMachineIds.filter { $0.value == machineId }.map(\.key)
    }

    /// The directory status of one agent, if the agent is registered.
    func agentStatus(agentId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.serverAgents[agentId]?.status
    }
}

extension AgentsRuntimeStore {
    /// Whether the agent has a stored channel membership row.
    func isChannelAgentMember(channelId: String, agentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.channelAgentMembers[channelId]?.contains(agentId) == true
    }

    /// The machine and the last reported activity of one agent, from one
    /// critical section.
    func runtimeFacts(agentId: String) -> (machineId: String?, activity: String, detail: String) {
        lock.lock()
        defer { lock.unlock() }
        let activity = storage.agentActivities[agentId] ?? (activity: "offline", detail: "")
        return (storage.agentMachineIds[agentId], activity.activity, activity.detail)
    }
}

// MARK: - Computers fleet (ComputersFleetService)

enum MachineProfileReleaseOutcome {
    case released
    case activeMigration
    case activeRuntimeProfile
}

enum RunnerCredentialRevocation {
    case notBound
    case credentialMissing
    case revoked(credentialId: String)
}

extension AgentsRuntimeStore {
    /// The machine-delete gate and the runtime-profile cleanup in one critical
    /// section: an in-flight migration or a profile that still pins an active
    /// agent refuses the delete with no write; otherwise the profiles of the
    /// machine are removed (or their pending-before pointer cleared) before the
    /// lock is released. `agentActive` answers from the OAuth ledger.
    func releaseMachineProfiles(
        machineId: String,
        agentActive: (_ agentId: String) -> Bool
    ) -> MachineProfileReleaseOutcome {
        lock.lock()
        defer { lock.unlock() }
        let terminalStates: Set<String> = ["completed", "failed", "aborted", "cancelled"]
        let migrations = storage.activeAgentMigrations.values
        let activeMigration = migrations.contains { migration in
            migration.sourceMachineId == machineId && !terminalStates.contains(migration.state)
        }
        if activeMigration { return .activeMigration }
        var profileRemovals: [String] = []
        var profileUpdates: [String: AgentRuntimeProfileFact] = [:]
        for (agentId, profile) in storage.agentRuntimeProfiles {
            if profile.machineId == machineId {
                if !agentActive(agentId) {
                    profileRemovals.append(agentId)
                    continue
                }
                let assignment = storage.agentMachineIds[agentId]
                let proof = assignment.map { target in
                    migrations.contains { migration in
                        migration.agentId == agentId
                            && migration.sourceMachineId == machineId
                            && migration.targetMachineId == target
                            && migration.state == "completed"
                    }
                } ?? false
                if proof, profile.pendingKind == nil {
                    profileRemovals.append(agentId)
                } else {
                    return .activeRuntimeProfile
                }
            } else if profile.pendingBeforeMachineId == machineId {
                if !agentActive(agentId) {
                    var updated = profile
                    updated.pendingBeforeMachineId = nil
                    profileUpdates[agentId] = updated
                    continue
                }
                let proof = migrations.contains { migration in
                    migration.agentId == agentId
                        && migration.sourceMachineId == machineId
                        && migration.targetMachineId == profile.machineId
                        && migration.state == "completed"
                }
                if proof {
                    var updated = profile
                    updated.pendingBeforeMachineId = nil
                    profileUpdates[agentId] = updated
                } else {
                    return .activeRuntimeProfile
                }
            }
        }
        for agentId in profileRemovals {
            storage.agentRuntimeProfiles.removeValue(forKey: agentId)
        }
        for (agentId, profile) in profileUpdates {
            storage.agentRuntimeProfiles[agentId] = profile
        }
        return .released
    }

    /// The machine-binding check and the `inactive` status write for one
    /// runner in one critical section. Returns false when the agent is not
    /// bound to `machineId`.
    func stopRunner(agentId: String, machineId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storage.agentMachineIds[agentId] == machineId else { return false }
        if storage.serverAgents[agentId] != nil { storage.serverAgents[agentId]?.status = "inactive" }
        return true
    }

    /// The machine-binding check, the credential lookup and the revocation
    /// stamp in one critical section; an already revoked credential keeps its
    /// original revocation time.
    func revokeRunnerCredential(
        agentId: String,
        machineId: String,
        credentialId: String,
        now: Date
    ) -> RunnerCredentialRevocation {
        lock.lock()
        defer { lock.unlock() }
        guard storage.agentMachineIds[agentId] == machineId else { return .notBound }
        guard let entry = storage.agentCredentials.first(where: {
            $0.value.id == credentialId && $0.value.agentId == agentId
        }) else { return .credentialMissing }
        storage.agentCredentials[entry.key]?.revokedAt = entry.value.revokedAt ?? now
        return .revoked(credentialId: entry.value.id)
    }
}

// MARK: - Machine migration status and cancellation

extension AgentsRuntimeStore {
    /// The migration row the status route publishes: the first row for this
    /// agent in this Server, in the store's own iteration order (the legacy
    /// `values.first` selection).
    func machineMigration(agentId: String, serverId: String) -> MachineMigrationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.machineMigrations.values.first { $0.agentId == agentId && $0.serverId == serverId }
    }

    /// One locked cancel transition for one Computer migration: presence,
    /// revision, terminal-state check and the post-flip decision share the lock
    /// with the write, so two concurrent cancels cannot both pass the revision
    /// gate.
    func cancelMachineMigration(
        agentId: String,
        serverId: String,
        migrationRef: String,
        expectedRevision: Int,
        reason: String,
        now: Date
    ) -> AgentMigrationCancelOutcome<MachineMigrationRecord> {
        lock.lock()
        defer { lock.unlock() }
        guard let candidate = storage.machineMigrations[migrationRef],
              candidate.agentId == agentId,
              candidate.serverId == serverId
        else { return .missing }
        guard candidate.revision == expectedRevision else { return .stale }
        guard !AgentMigrationCancelPolicy.terminalStates.contains(candidate.state) else { return .terminal }
        var migration = candidate
        // Once the flip committed the agent belongs to the target, so the
        // cancellation is target-authoritative even though the agent may still
        // be arriving/starting.
        let postFlip = migration.flippedAt != nil
            || AgentMigrationCancelPolicy.postFlipStates.contains(migration.state)
        migration.state = postFlip ? "canceled_post_flip" : "canceled_pre_flip"
        migration.revision += 1
        migration.canceledAt = now
        migration.cancelReason = reason
        migration.cancelDispatchAttempts = 1
        migration.cancelLastDispatchAt = now
        migration.cancelErrorCode = nil
        migration.cancelGeneration = UUID().uuidString.lowercased()
        migration.cancelTransportGeneration = migration.transportGeneration
        migration.cancelDisposition = postFlip ? "post_flip_target_authoritative" : "pre_flip_source_authoritative"
        migration.cancelSourceAck = nil
        migration.cancelTargetAck = nil
        migration.cancelSourceAckAt = nil
        migration.cancelTargetAckAt = nil
        migration.transportTeardownAt = now
        migration.updatedAt = now
        storage.machineMigrations[migrationRef] = migration
        return .canceled(migration)
    }
}

// MARK: - Migration transport (AgentHostedMigrationService)

/// Why a migration transport callback did not apply. The service maps each case
/// to its published refusal.
enum MachineMigrationTransportFailure: Error, Sendable, Equatable {
    case migrationMissing
    case controlManifestMissing
    case chunkInvalid
    case chunkReceiptMismatch
    case chunksMissing([Int])
    case generationStale
    case notReady
    case notFlippable
    case sourceMachineMismatch
    case notArriving
    case notActive
    case cancelGenerationStale
    case cancelNotRequested
    case cancelOutcomeMismatch
    case manifestConflict
}

/// What the source-archive dispatch of an arrival callback needs.
struct MachineMigrationArrivalContext: Sendable, Equatable {
    let supportRef: String
    let sourceMachineId: String
    let agentId: String
}

/// The result of the arrival transition: either a settled row to publish, or a
/// row that moved to `starting` and now needs its target start dispatched.
enum MachineMigrationArrivalOutcome: Sendable {
    case settled(MachineMigrationRecord)
    case dispatch(MachineMigrationRecord)
}

/// The auto-start completion: `completed` only the first time.
enum MachineMigrationAutoStartOutcome: Sendable {
    case completed(MachineMigrationRecord)
    case unchanged(MachineMigrationRecord)
}

/// The frozen cancellation facts one acknowledgement publishes.
struct MachineMigrationCancelAckView: Sendable, Equatable {
    let supportRef: String
    let state: String
    let revision: Int
    let disposition: String
}

/// The lease facts the source quiesce receipt answers with.
struct MachineMigrationQuiesceView: Sendable, Equatable {
    let transportGeneration: String
    let transportSessionId: String
}

/// One cancel acknowledgement as the target/source Computer reported it.
struct MachineMigrationCancelAck: Sendable {
    let supportRef: String
    let transportGeneration: String
    let cancelGeneration: String
    let role: String
    let outcome: String
}

extension AgentsRuntimeStore {
    private static let terminalMachineMigrationStates: Set<String> = [
        "canceled_pre_flip", "completed", "aborted", "failed",
    ]

    private func hasActiveMigrationLocked(agentId: String) -> Bool {
        storage.machineMigrations.values.contains {
            $0.agentId == agentId && !Self.terminalMachineMigrationStates.contains($0.state)
        } || storage.hostedMigrations[agentId] != nil
    }

    func machineMigration(ref: String) -> MachineMigrationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.machineMigrations[ref]
    }

    /// Whether the agent has a Computer migration that has not reached a
    /// terminal state, or any hosted migration row.
    func hasActiveMigration(agentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasActiveMigrationLocked(agentId: agentId)
    }

    /// The assignment write guarded by the active-migration check, one critical
    /// section. `false` when an active migration owns the agent.
    func assignMachine(agentId: String, machineId: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasActiveMigrationLocked(agentId: agentId) { return false }
        if let machineId {
            storage.agentMachineIds[agentId] = machineId
        } else {
            storage.agentMachineIds.removeValue(forKey: agentId)
        }
        return true
    }

    /// Inserts a freshly provisioned Computer migration unless one became
    /// active since the caller's early check. One critical section.
    func insertMachineMigrationIfIdle(_ record: MachineMigrationRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasActiveMigrationLocked(agentId: record.agentId) { return false }
        storage.machineMigrations[record.supportRef] = record
        return true
    }

    /// Stores the control manifest and its parsed chunk table. A manifest that
    /// differs from the registered one conflicts; presence and write share the
    /// lock.
    func putControlManifest(
        ref: String,
        body: String,
        chunks: [Int: (sha256: String, sizeBytes: Int)]
    ) -> Result<Void, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var record = storage.machineMigrations[ref] else { return .failure(.migrationMissing) }
        if let existing = record.manifestJSON, existing != body { return .failure(.manifestConflict) }
        record.manifestJSON = body
        record.manifestChunks = chunks
        if record.chunkReceipts.isEmpty { record.chunkReceipts = [:] }
        storage.machineMigrations[ref] = record
        return .success(())
    }

    /// Records one chunk receipt against the registered manifest.
    func recordChunkReceipt(
        ref: String,
        chunkIndex: Int,
        sha256: String
    ) -> Result<Void, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var record = storage.machineMigrations[ref] else { return .failure(.migrationMissing) }
        guard record.manifestJSON != nil, !record.manifestChunks.isEmpty else {
            return .failure(.controlManifestMissing)
        }
        guard let expected = record.manifestChunks[chunkIndex] else { return .failure(.chunkInvalid) }
        guard expected.sha256 == sha256 else { return .failure(.chunkReceiptMismatch) }
        record.chunkReceipts[chunkIndex] = sha256
        storage.machineMigrations[ref] = record
        return .success(())
    }

    /// `transfer_complete` once every manifest chunk has a receipt. The missing
    /// check and the state write share one critical section.
    func completeUpload(ref: String) -> Result<Void, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var record = storage.machineMigrations[ref] else { return .failure(.migrationMissing) }
        guard !record.manifestChunks.isEmpty else { return .failure(.controlManifestMissing) }
        let missing = record.manifestChunks.keys.filter { record.chunkReceipts[$0] == nil }.sorted()
        guard missing.isEmpty else { return .failure(.chunksMissing(missing)) }
        record.state = "transfer_complete"
        record.revision += 1
        storage.machineMigrations[ref] = record
        return .success(())
    }

    /// The target Computer's read of its own row.
    func targetMigration(
        ref: String,
        machineId: String
    ) -> Result<MachineMigrationRecord, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard let record = storage.machineMigrations[ref], record.targetMachineId == machineId else {
            return .failure(.migrationMissing)
        }
        return .success(record)
    }

    /// `ready` to `in_transit`: ownership, generation and state checks and the
    /// write are one critical section, so two concurrent starts cannot both
    /// consume the generation.
    func startTransfer(
        ref: String,
        machineId: String,
        generation: String,
        nextGeneration: String,
        now: Date
    ) -> Result<MachineMigrationRecord, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var record = storage.machineMigrations[ref], record.targetMachineId == machineId else {
            return .failure(.migrationMissing)
        }
        guard record.transportGeneration == generation else { return .failure(.generationStale) }
        guard record.state == "ready" else { return .failure(.notReady) }
        record.previousTransportGeneration = record.transportGeneration
        record.state = "in_transit"
        record.transportGeneration = nextGeneration
        record.revision += 1
        record.updatedAt = now
        storage.machineMigrations[ref] = record
        return .success(record)
    }

    /// `in_transit` to `arriving`: the row transition and the agent's machine
    /// binding move together. A replay after the flip returns the current row.
    func flipMachine(
        ref: String,
        machineId: String,
        generation: String,
        nextGeneration: String,
        now: Date
    ) -> Result<MachineMigrationRecord, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var record = storage.machineMigrations[ref], record.targetMachineId == machineId else {
            return .failure(.migrationMissing)
        }
        if (record.state == "arriving" || record.state == "completed")
            && storage.agentMachineIds[record.agentId] == record.targetMachineId {
            return .success(record)
        }
        guard record.transportGeneration == generation else { return .failure(.generationStale) }
        guard record.state == "in_transit" else { return .failure(.notFlippable) }
        guard storage.agentMachineIds[record.agentId] == record.sourceMachineId else {
            return .failure(.sourceMachineMismatch)
        }
        record.previousTransportGeneration = record.transportGeneration
        record.state = "arriving"
        record.flippedAt = now
        record.transportGeneration = nextGeneration
        record.revision += 1
        record.updatedAt = now
        storage.agentMachineIds[record.agentId] = record.targetMachineId
        storage.machineMigrations[ref] = record
        return .success(record)
    }

    /// Records a failed source-archive attempt. It does not bump `revision`:
    /// source cleanup is independent of the transfer state machine.
    func recordSourceArchiveFailure(ref: String, rawCode: String, now: Date) {
        let code = rawCode.range(of: "^[A-Za-z0-9_:.-]{1,160}$", options: .regularExpression) != nil
            ? rawCode
            : "MIGRATION_SOURCE_WORKSPACE_ARCHIVE_FAILED"
        lock.lock()
        defer { lock.unlock() }
        guard var record = storage.machineMigrations[ref],
              record.sourceWorkspaceArchivedAt == nil,
              record.sourceWorkspaceArchiveAbandonedAt == nil
        else { return }
        record.sourceWorkspaceArchiveAttempts += 1
        let agentMoved = EmailLoginDirectory.migrationSourceArchiveMovedCodes.contains(code)
        let exhausted = agentMoved
            || record.sourceWorkspaceArchiveAttempts >= EmailLoginDirectory.migrationSourceArchiveMaxAttempts
        record.sourceWorkspaceArchiveLastError = agentMoved ? "agent_moved" : code
        record.sourceWorkspaceArchiveRetryAt = exhausted
            ? nil
            : now.addingTimeInterval(
                EmailLoginDirectory.migrationSourceArchiveBackoff(attempts: record.sourceWorkspaceArchiveAttempts)
            )
        record.sourceWorkspaceArchiveAbandonedAt = exhausted ? now : nil
        record.updatedAt = now
        storage.machineMigrations[ref] = record
    }

    /// Stamps the source archive confirmation once.
    func confirmSourceArchive(ref: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = storage.machineMigrations[ref], current.sourceWorkspaceArchivedAt == nil else { return }
        current.sourceWorkspaceArchivedAt = now
        current.revision += 1
        current.updatedAt = now
        storage.machineMigrations[ref] = current
    }

    /// Records a failed target start while the row is `starting`; any other
    /// state leaves the row unchanged. Returns the row either way.
    func recordAutoStartFailure(
        ref: String,
        stage: String,
        code: String,
        now: Date
    ) -> Result<MachineMigrationRecord, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var record = storage.machineMigrations[ref] else { return .failure(.migrationMissing) }
        if record.state == "starting" {
            record.failureReason = "auto_start_failed"
            record.autoStartFailureStage = stage
            record.autoStartFailureCode = code
            record.revision += 1
            record.updatedAt = now
            storage.machineMigrations[ref] = record
        }
        return .success(record)
    }

    /// Phase 1 of the arrival callback: the cheap validity check plus the input
    /// the source archive dispatch needs. Idempotent once the archive is
    /// recorded and the target holds the agent.
    func arrivalContext(
        machineId: String,
        ref: String,
        generation: String
    ) -> Result<MachineMigrationArrivalContext, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard let record = storage.machineMigrations[ref], record.targetMachineId == machineId else {
            return .failure(.migrationMissing)
        }
        let archivableStates: Set<String> = ["arriving", "starting", "completed"]
        let held = storage.agentMachineIds[record.agentId] == record.targetMachineId
        let archivedAndHeld = archivableStates.contains(record.state)
            && record.sourceWorkspaceArchivedAt != nil
            && held
        if !archivedAndHeld {
            guard record.transportGeneration == generation else { return .failure(.generationStale) }
            guard archivableStates.contains(record.state) else { return .failure(.notArriving) }
            guard held else { return .failure(.sourceMachineMismatch) }
        }
        return .success(MachineMigrationArrivalContext(
            supportRef: record.supportRef,
            sourceMachineId: record.sourceMachineId,
            agentId: record.agentId
        ))
    }

    /// Phase 3: `arriving` to `starting`, or observe or reclaim an
    /// already-starting row so a replayed arrival is not a second transition.
    func arrivalTransition(
        machineId: String,
        ref: String,
        generation: String,
        reportPath: String?,
        reportSha256: String?,
        now: Date
    ) -> Result<MachineMigrationArrivalOutcome, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var current = storage.machineMigrations[ref], current.targetMachineId == machineId else {
            return .failure(.migrationMissing)
        }
        let held = storage.agentMachineIds[current.agentId] == current.targetMachineId
        if current.state == "completed" && held {
            return .success(.settled(current))
        }
        if current.state == "starting" && held {
            if current.failureReason == nil {
                if now < current.updatedAt.addingTimeInterval(EmailLoginDirectory.migrationAutoStartLease) {
                    return .success(.settled(current))
                }
                current.revision += 1
                current.updatedAt = now
            } else if current.failureReason != "auto_start_failed" {
                return .success(.settled(current))
            } else {
                current.failureReason = nil
                current.revision += 1
                current.updatedAt = now
            }
        } else {
            guard current.transportGeneration == generation else { return .failure(.generationStale) }
            guard current.state == "arriving" else { return .failure(.notArriving) }
            guard held else { return .failure(.sourceMachineMismatch) }
            current.previousTransportGeneration = current.transportGeneration
            current.state = "starting"
            current.arrivedAt = now
            current.failureReason = nil
            current.autoStartFailureStage = nil
            current.autoStartFailureCode = nil
            current.arrivalReportPath = reportPath
            current.arrivalReportSha256 = reportSha256
            current.revision += 1
            current.updatedAt = now
        }
        storage.machineMigrations[ref] = current
        return .success(.dispatch(current))
    }

    /// Phase 4: the agent runs on the target. The row transition and the
    /// machine binding are one critical section.
    func completeAutoStart(
        ref: String,
        nextGeneration: String,
        now: Date
    ) -> Result<MachineMigrationAutoStartOutcome, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var completed = storage.machineMigrations[ref] else { return .failure(.migrationMissing) }
        guard completed.state == "starting" else { return .success(.unchanged(completed)) }
        completed.state = "completed"
        completed.failureReason = nil
        completed.autoStartFailureStage = nil
        completed.autoStartFailureCode = nil
        completed.completedAt = now
        completed.transportTeardownAt = now
        completed.previousTransportGeneration = completed.transportGeneration
        completed.transportGeneration = nextGeneration
        completed.revision += 1
        completed.updatedAt = now
        storage.agentMachineIds[completed.agentId] = completed.targetMachineId
        storage.machineMigrations[ref] = completed
        return .success(.completed(completed))
    }

    /// A Computer's transport-lost report. A replay of the same terminal reason
    /// and a report for a replaced generation return the current row.
    func markTransportLost(
        machineId: String,
        ref: String,
        code: String,
        message: String?,
        detailCode: String?,
        reportedGeneration: String?,
        now: Date
    ) -> Result<MachineMigrationRecord, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var record = storage.machineMigrations[ref],
              record.sourceMachineId == machineId || record.targetMachineId == machineId
        else { return .failure(.migrationMissing) }
        if record.state == "failed" && record.failureReason == code { return .success(record) }
        if let reportedGeneration, record.transportGeneration != reportedGeneration { return .success(record) }
        let activeStates: Set<String> = ["provisioning", "prep", "ready", "in_transit", "arriving", "starting"]
        guard activeStates.contains(record.state) else { return .failure(.notActive) }
        record.state = "failed"
        record.revision += 1
        record.failureReason = code
        record.transportErrorCode = detailCode ?? code
        record.transportErrorMessage = message
        record.transportLostAt = now
        record.transportTeardownAt = now
        record.updatedAt = now
        storage.machineMigrations[ref] = record
        return .success(record)
    }

    /// One cancel acknowledgement from the source or the target. The generation
    /// checks, the frozen-disposition outcome check and the acknowledgement
    /// stamp are one critical section.
    func acknowledgeCancel(
        machineId: String,
        ref: String,
        ack: MachineMigrationCancelAck,
        now: Date
    ) -> Result<MachineMigrationCancelAckView, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var record = storage.machineMigrations[ref],
              record.supportRef == ack.supportRef,
              (ack.role == "source" ? record.sourceMachineId : record.targetMachineId) == machineId
        else { return .failure(.migrationMissing) }
        guard record.cancelGeneration == ack.cancelGeneration else { return .failure(.cancelGenerationStale) }
        guard record.cancelTransportGeneration == ack.transportGeneration else {
            return .failure(.generationStale)
        }
        let cancellationStates: Set<String> = [
            "cancel_requested_pre_flip", "cancel_requested_post_flip", "canceled_pre_flip", "canceled_post_flip",
        ]
        guard cancellationStates.contains(record.state), let disposition = record.cancelDisposition else {
            return .failure(.cancelNotRequested)
        }
        // Post-flip the target is authoritative: its successful outcome is
        // `stopped`, never `cleaned`.
        let successOutcome = (disposition == "post_flip_target_authoritative" && ack.role == "target")
            ? "stopped"
            : "cleaned"
        if ack.outcome != "needs_attention" && ack.outcome != successOutcome {
            return .failure(.cancelOutcomeMismatch)
        }
        if ack.outcome == "needs_attention" {
            record.cancelErrorCode = record.cancelErrorCode ?? "cleanup_incomplete"
            record.updatedAt = now
            storage.machineMigrations[ref] = record
        } else {
            let alreadyAcknowledged = ack.role == "source" ? record.cancelSourceAckAt : record.cancelTargetAckAt
            if alreadyAcknowledged == nil {
                if ack.role == "source" {
                    record.cancelSourceAck = ack.outcome
                    record.cancelSourceAckAt = now
                } else {
                    record.cancelTargetAck = ack.outcome
                    record.cancelTargetAckAt = now
                }
                if record.cancelSourceAckAt != nil && record.cancelTargetAckAt != nil {
                    record.transportTeardownAt = now
                    record.canceledAt = record.canceledAt ?? now
                }
                record.revision += 1
                record.updatedAt = now
                storage.machineMigrations[ref] = record
            }
        }
        return .success(MachineMigrationCancelAckView(
            supportRef: record.supportRef,
            state: record.state,
            revision: record.revision,
            disposition: disposition
        ))
    }

    /// Stores the source quiesce receipt for the source Computer's row.
    func recordSourceQuiesced(
        machineId: String,
        ref: String,
        receiptJSON: String?
    ) -> Result<MachineMigrationQuiesceView, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var record = storage.machineMigrations[ref], record.sourceMachineId == machineId else {
            return .failure(.migrationMissing)
        }
        record.quiesceReceiptJSON = receiptJSON
        storage.machineMigrations[ref] = record
        return .success(MachineMigrationQuiesceView(
            transportGeneration: record.transportGeneration,
            transportSessionId: record.transportSessionId
        ))
    }

    /// Stores the source progress body for the source Computer's row.
    func recordSourceProgress(
        machineId: String,
        ref: String,
        body: String
    ) -> Result<Void, MachineMigrationTransportFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard var record = storage.machineMigrations[ref], record.sourceMachineId == machineId else {
            return .failure(.migrationMissing)
        }
        record.progressJSON = body
        storage.machineMigrations[ref] = record
        return .success(())
    }
}

// MARK: - Hosted migration, credentials and archive (AgentHostedMigrationService, AgentMachineMigrationControlService)

/// Every row a hosted-migration start reads, from one critical section.
struct HostedMigrationStartFacts: Sendable {
    let hostedEnabled: Bool
    let runtimeEnabled: Bool
    let modelPickerEnabled: Bool
    let hasHostedRuntime: Bool
    let activeMigration: HostedMigrationRecord?
    let machineId: String?
}

/// Why a hosted-migration confirmation did not apply.
enum HostedMigrationConfirmFailure: Error, Sendable, Equatable {
    case notFound
    case revisionStale
    case reviewNotReady
    case targetAlreadyUsed
    case sourceMoved
}

/// The facts an agent delete decides from, read in one critical section.
struct AgentDeleteFacts: Sendable, Equatable {
    let machineId: String?
    let hostedRuntime: Bool
    let hasActiveMigration: Bool
}

/// Why an archive workspace delete request did not apply.
enum AgentArchiveWorkspaceFailure: Error, Sendable, Equatable {
    case missing
    case unavailable
    case pending
}

/// The migrations an agent delete treats as finished.
private let agentDeleteTerminalMigrationStates: Set<String> = [
    "canceled_pre_flip", "canceled", "completed", "arrived", "aborted", "failed",
]

extension AgentsRuntimeStore {
    /// The deployment-level hosted provider token (or its test override) is set.
    func hostedProviderConfigured() -> Bool {
        lock.lock()
        let override = storage.hostedProviderTokenOverride
        lock.unlock()
        let token = override
            ?? ProcessInfo.processInfo.environment["ANTIPROTON_PROVISIONING_TOKEN"]
            ?? ""
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hostedProviderAvailable(serverId: String) -> Bool {
        lock.lock()
        let flagged = storage.hostedRuntimeServers.contains(serverId)
        lock.unlock()
        return flagged && hostedProviderConfigured()
    }

    func agentMigrationEnabled(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentMigrationServers.contains(serverId)
    }

    func hostedMigrationEnabled(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.hostedMigrationServers.contains(serverId)
    }

    func hostedStartFacts(agentId: String, serverId: String) -> HostedMigrationStartFacts {
        lock.lock()
        defer { lock.unlock() }
        return HostedMigrationStartFacts(
            hostedEnabled: storage.hostedMigrationServers.contains(serverId),
            runtimeEnabled: storage.hostedRuntimeServers.contains(serverId),
            modelPickerEnabled: storage.hostedModelPickerServers.contains(serverId),
            hasHostedRuntime: storage.hostedRuntimes[agentId] != nil,
            activeMigration: storage.hostedMigrations[agentId],
            machineId: storage.agentMachineIds[agentId]
        )
    }

    /// Inserts the hosted migration row unless the agent already ran in the
    /// cloud or holds a live migration since the caller's early check. One
    /// critical section.
    func insertHostedMigrationIfIdle(_ record: HostedMigrationRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if storage.hostedRuntimes[record.agentId] != nil { return false }
        if let existing = storage.hostedMigrations[record.agentId], existing.state != "canceled" { return false }
        storage.hostedMigrations[record.agentId] = record
        return true
    }

    /// `in_transit` to `arriving` for the hosted migration: every gate and both
    /// writes (the migration row and the provisioning hosted runtime row) are
    /// one critical section.
    func confirmHostedMigration(
        agentId: String,
        serverId: String,
        migrationRef: String,
        expectedRevision: Int,
        now: Date
    ) -> Result<HostedMigrationRecord, HostedMigrationConfirmFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard let migration = storage.hostedMigrations[agentId],
              migration.supportRef == migrationRef,
              migration.serverId == serverId
        else { return .failure(.notFound) }
        guard migration.revision == expectedRevision else { return .failure(.revisionStale) }
        guard migration.state == "in_transit" else { return .failure(.reviewNotReady) }
        guard storage.hostedRuntimes[agentId] == nil else { return .failure(.targetAlreadyUsed) }
        guard migration.sourceMachineId != nil,
              storage.agentMachineIds[agentId] == migration.sourceMachineId
        else { return .failure(.sourceMoved) }
        var updated = migration
        updated.state = "arriving"
        updated.revision += 1
        storage.hostedMigrations[agentId] = updated
        storage.hostedRuntimes[agentId] = ("antiproton", nil, "provisioning", false, now)
        return .success(updated)
    }

    func credentialId(token: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentCredentials[token]?.id
    }

    /// The credentials of one agent in the store's own iteration order.
    func credentials(agentId: String) -> [(token: String, credential: AgentCredential)] {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentCredentials
            .filter { $0.value.agentId == agentId }
            .map { (token: $0.key, credential: $0.value) }
    }

    /// Stamps the revocation of one credential; a credential revoked earlier
    /// keeps its original time. `false` when the id is unknown or belongs to
    /// another agent.
    func revokeCredential(agentId: String, credentialId: String, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let token = storage.agentCredentials.first(where: { $0.value.id == credentialId })?.key,
              storage.agentCredentials[token]?.agentId == agentId
        else { return false }
        let existing = storage.agentCredentials[token]?.revokedAt
        storage.agentCredentials[token]?.revokedAt = existing ?? now
        return true
    }

    func archiveRecord(agentId: String) -> AgentArchiveRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentArchiveRecords[agentId]
    }

    /// The facts an agent delete decides from.
    func agentDeleteFacts(agentId: String) -> AgentDeleteFacts {
        lock.lock()
        defer { lock.unlock() }
        let terminal = agentDeleteTerminalMigrationStates
        let hasActive = storage.activeAgentMigrations.values.contains {
            $0.agentId == agentId && !terminal.contains($0.state)
        } || storage.machineMigrations.values.contains {
            $0.agentId == agentId && !terminal.contains($0.state)
        } || (storage.hostedMigrations[agentId].map { !terminal.contains($0.state) } ?? false)
        return AgentDeleteFacts(
            machineId: storage.agentMachineIds[agentId],
            hostedRuntime: storage.hostedRuntimes[agentId] != nil,
            hasActiveMigration: hasActive
        )
    }

    func storeArchiveRecord(agentId: String, record: AgentArchiveRecord) {
        lock.lock()
        storage.agentArchiveRecords[agentId] = record
        lock.unlock()
    }

    /// Marks one archived workspace for deletion. The state and pending-op
    /// checks and the write are one critical section, so two concurrent
    /// requests cannot both queue a delete.
    func requestArchiveWorkspaceDelete(
        agentId: String
    ) -> Result<AgentArchiveRecord, AgentArchiveWorkspaceFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard let record = storage.agentArchiveRecords[agentId] else { return .failure(.missing) }
        guard record.workspaceState == "on_computer", record.machineId != nil else {
            return .failure(.unavailable)
        }
        guard record.pendingOp == nil else { return .failure(.pending) }
        var updated = record
        updated.pendingOp = "delete"
        updated.lastErrorCode = nil
        updated.lastErrorAt = nil
        storage.agentArchiveRecords[agentId] = updated
        return .success(updated)
    }
}
