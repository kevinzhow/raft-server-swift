import Foundation

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
}
