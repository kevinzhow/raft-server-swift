import Foundation

/// Versioned business snapshot for the existing AgentsRuntimeStore instance.
///
/// Durable coverage is exactly the 34 fields in Payload, including execution
/// commands, receipt fingerprints, watermarks and recovery decisions. In particular the
/// credential dictionary retains its original token keys, credential ids, scopes,
/// creation/use/revocation dates. Both migration families retain revisions,
/// transport token hashes/generations, manifests, chunk receipts, cancellations,
/// leases/dispatch history, arrival and archive retry facts. Attachment bytes,
/// original embedded JSON strings, webhook secrets, event dedupe/status times,
/// hosted models/usage/provider facts, feature flags and ordered rules survive.
/// ServerAgent.status is durable active/stopped business intent, not a socket.
///
/// Reset, rather than restore, these process-presence fields:
/// - agentActivities: direct channel activity projection (online/working/etc.).
/// - agentLastSeenAt: external diagnostics calls <=120 seconds "online".
/// Credential lastUsedAt and status occurrence/dedupe history remain durable.
///
/// Excluded and left unchanged in the current instance:
/// - hostedProviderTokenOverride, agentInboxAvailable: live/simulation overrides.
/// - agentMigrationCancelDispatch, agentStartDispatch, agentActivityLogProvider,
///   agentActivitySummariesProvider, agentSkillsProvider, agentHasMachineLocally,
///   agentWorkspaceTreeProvider, agentWorkspaceReadProvider,
///   agentStartControlDispatch, agentResetDispatch, agentConfigLiftDispatch,
///   agentConnectionOrigin, agentConnectionProviderStorage,
///   agentCredentialUseThrottleOverrideMs, wakeStreamHeartbeatOverrideMs,
///   agentAttachmentPresign: dispatch/providers or current process configuration.
///
/// Opaque data contains secrets. Do not log it. Cross-owner capture/commit and
/// publication ordering require the caller's persistence gate. This codec does
/// not make the 14-owner production transaction atomic or production-ready.
extension AgentsRuntimeStore {
    func exportPersistenceData() throws -> Data {
        let captured = withState { $0 }
        try captured.execution.validate()
        return try RuntimePersistenceFormat.encode(RuntimePersistenceAgentPayload(captured), domain: "raft.agents-runtime")
    }

    /// Decode, validate and map all rows before taking one short mutation
    /// borrow. Copy only business fields into this instance; keep its relays.
    func restorePersistenceData(_ data: Data) throws {
        let payload = try RuntimePersistenceFormat.decode(RuntimePersistenceAgentPayload.self, from: data, domain: "raft.agents-runtime")
        let business = try payload.businessState()
        let retired = withState { state in
            let previous = state
            state.execution = business.execution
            state.execution.fenceAfterRestore()
            state.serverAgents = business.serverAgents
            state.channelAgentMembers = business.channelAgentMembers
            state.storedAgentDeliveries = business.storedAgentDeliveries
            state.assistantOwners = business.assistantOwners
            state.agentCredentials = business.agentCredentials
            state.agentMachineIds = business.agentMachineIds
            state.agentRuntimeProfiles = business.agentRuntimeProfiles
            state.activeAgentMigrations = business.activeAgentMigrations
            state.agentMigrationServers = business.agentMigrationServers
            state.hostedMigrationServers = business.hostedMigrationServers
            state.hostedRuntimeServers = business.hostedRuntimeServers
            state.hostedMigrations = business.hostedMigrations
            state.machineMigrations = business.machineMigrations
            state.hostedRuntimes = business.hostedRuntimes
            state.grokRuntimeServers = business.grokRuntimeServers
            state.remoteUpgradeDisabledServers = business.remoteUpgradeDisabledServers
            state.agentStatusAdopted = business.agentStatusAdopted
            state.agentStatusOccurredAt = business.agentStatusOccurredAt
            state.agentActivityEventIds = business.agentActivityEventIds
            state.hostedUsage = business.hostedUsage
            state.hostedModelPickerServers = business.hostedModelPickerServers
            state.hostedModels = business.hostedModels
            state.agentArchiveRecords = business.agentArchiveRecords
            state.agentChannelJoinedAt = business.agentChannelJoinedAt
            state.agentChannelPosted = business.agentChannelPosted
            state.agentAttachmentBytes = business.agentAttachmentBytes
            state.externalPushWebhooks = business.externalPushWebhooks
            state.agentStatusProtocolAdoptedAt = business.agentStatusProtocolAdoptedAt
            state.agentCursorPullState = business.agentCursorPullState
            state.agentProviderPositions = business.agentProviderPositions
            state.hostedAgents = business.hostedAgents
            state.featureFlagRecords = business.featureFlagRecords
            state.featureFlagRuleRecords = business.featureFlagRuleRecords
            state.agentActivities = [:]
            state.agentLastSeenAt = [:]
            return previous
        }
        // Keep the old COW containers alive until after the borrow ends, so a
        // large attachment/message history is not destroyed under the Mutex.
        withExtendedLifetime(retired) {}
    }
}

private struct RuntimePersistenceAgentPayload: Codable, Sendable {
    // Optional permits loading the existing schema before execution was added.
    let execution: AgentExecutionState?
    let serverAgents: [String: RuntimePersistenceAgentRows.ServerAgentRow]
    let channelAgentMembers: [String: Set<String>]
    let storedAgentDeliveries: [RuntimePersistenceAgentRows.DeliveryRow]
    let assistantOwners: [String: String]
    let agentCredentials: [String: RuntimePersistenceAgentRows.CredentialRow]
    let agentMachineIds: [String: String]
    let agentRuntimeProfiles: [String: RuntimePersistenceAgentRows.RuntimeProfileRow]
    let activeAgentMigrations: [String: RuntimePersistenceAgentRows.MigrationFactRow]
    let agentMigrationServers: Set<String>
    let hostedMigrationServers: Set<String>
    let hostedRuntimeServers: Set<String>
    let hostedMigrations: [String: RuntimePersistenceMigrationRows.HostedMigrationRow]
    let machineMigrations: [String: RuntimePersistenceMigrationRows.MachineMigrationRow]
    let hostedRuntimes: [String: RuntimePersistenceAgentRows.HostedRuntimeRow]
    let grokRuntimeServers: Set<String>
    let remoteUpgradeDisabledServers: Set<String>
    let agentStatusAdopted: Set<String>
    let agentStatusOccurredAt: [String: Date]
    let agentActivityEventIds: [String: Set<String>]
    let hostedUsage: [String: String]
    let hostedModelPickerServers: Set<String>
    let hostedModels: [String: RuntimePersistenceAgentRows.HostedModelStateRow]
    let agentArchiveRecords: [String: RuntimePersistenceAgentRows.ArchiveRow]
    let agentChannelJoinedAt: [String: Date]
    let agentChannelPosted: Set<String>
    let agentAttachmentBytes: [String: Data]
    let externalPushWebhooks: [String: RuntimePersistenceAgentRows.WebhookRow]
    let agentStatusProtocolAdoptedAt: [String: Date]
    let agentCursorPullState: [String: RuntimePersistenceAgentRows.CursorRow]
    let agentProviderPositions: [String: RuntimePersistenceAgentRows.ProviderPositionRow]
    let hostedAgents: Set<String>
    let featureFlagRecords: [String: RuntimePersistenceAgentRows.FlagRow]
    let featureFlagRuleRecords: [RuntimePersistenceAgentRows.FlagRuleRow]

    init(_ state: AgentsRuntimeStore.State) {
        execution = state.execution
        serverAgents = state.serverAgents.mapValues(RuntimePersistenceAgentRows.ServerAgentRow.init)
        channelAgentMembers = state.channelAgentMembers
        storedAgentDeliveries = state.storedAgentDeliveries.map(RuntimePersistenceAgentRows.DeliveryRow.init)
        assistantOwners = state.assistantOwners
        agentCredentials = state.agentCredentials.mapValues(RuntimePersistenceAgentRows.CredentialRow.init)
        agentMachineIds = state.agentMachineIds
        agentRuntimeProfiles = state.agentRuntimeProfiles.mapValues(RuntimePersistenceAgentRows.RuntimeProfileRow.init)
        activeAgentMigrations = state.activeAgentMigrations.mapValues(RuntimePersistenceAgentRows.MigrationFactRow.init)
        agentMigrationServers = state.agentMigrationServers
        hostedMigrationServers = state.hostedMigrationServers
        hostedRuntimeServers = state.hostedRuntimeServers
        hostedMigrations = state.hostedMigrations.mapValues(RuntimePersistenceMigrationRows.HostedMigrationRow.init)
        machineMigrations = state.machineMigrations.mapValues(RuntimePersistenceMigrationRows.MachineMigrationRow.init)
        hostedRuntimes = state.hostedRuntimes.mapValues(RuntimePersistenceAgentRows.HostedRuntimeRow.init)
        grokRuntimeServers = state.grokRuntimeServers
        remoteUpgradeDisabledServers = state.remoteUpgradeDisabledServers
        agentStatusAdopted = state.agentStatusAdopted
        agentStatusOccurredAt = state.agentStatusOccurredAt
        agentActivityEventIds = state.agentActivityEventIds
        hostedUsage = state.hostedUsage
        hostedModelPickerServers = state.hostedModelPickerServers
        hostedModels = state.hostedModels.mapValues(RuntimePersistenceAgentRows.HostedModelStateRow.init)
        agentArchiveRecords = state.agentArchiveRecords.mapValues(RuntimePersistenceAgentRows.ArchiveRow.init)
        agentChannelJoinedAt = state.agentChannelJoinedAt
        agentChannelPosted = state.agentChannelPosted
        agentAttachmentBytes = state.agentAttachmentBytes
        externalPushWebhooks = state.externalPushWebhooks.mapValues(RuntimePersistenceAgentRows.WebhookRow.init)
        agentStatusProtocolAdoptedAt = state.agentStatusProtocolAdoptedAt
        agentCursorPullState = state.agentCursorPullState.mapValues(RuntimePersistenceAgentRows.CursorRow.init)
        agentProviderPositions = state.agentProviderPositions.mapValues(RuntimePersistenceAgentRows.ProviderPositionRow.init)
        hostedAgents = state.hostedAgents
        featureFlagRecords = state.featureFlagRecords.mapValues(RuntimePersistenceAgentRows.FlagRow.init)
        featureFlagRuleRecords = state.featureFlagRuleRecords.map(RuntimePersistenceAgentRows.FlagRuleRow.init)
    }

    /// Reconstruct rows outside the Mutex. State is a temporary private
    /// carrier here; none of its default callbacks/config is installed.
    func businessState() throws -> AgentsRuntimeStore.State {
        var state = AgentsRuntimeStore.State()
        state.execution = execution ?? AgentExecutionState()
        try state.execution.validate()
        state.serverAgents = serverAgents.mapValues { $0.record }
        state.channelAgentMembers = channelAgentMembers
        state.storedAgentDeliveries = storedAgentDeliveries.map { $0.record }
        state.assistantOwners = assistantOwners
        state.agentCredentials = agentCredentials.mapValues { $0.record }
        state.agentMachineIds = agentMachineIds
        state.agentRuntimeProfiles = agentRuntimeProfiles.mapValues { $0.record }
        state.activeAgentMigrations = activeAgentMigrations.mapValues { $0.record }
        state.agentMigrationServers = agentMigrationServers
        state.hostedMigrationServers = hostedMigrationServers
        state.hostedRuntimeServers = hostedRuntimeServers
        state.hostedMigrations = hostedMigrations.mapValues { $0.record }
        state.machineMigrations = machineMigrations.mapValues { $0.record }
        state.hostedRuntimes = hostedRuntimes.mapValues { $0.record }
        state.grokRuntimeServers = grokRuntimeServers
        state.remoteUpgradeDisabledServers = remoteUpgradeDisabledServers
        state.agentStatusAdopted = agentStatusAdopted
        state.agentStatusOccurredAt = agentStatusOccurredAt
        state.agentActivityEventIds = agentActivityEventIds
        state.hostedUsage = hostedUsage
        state.hostedModelPickerServers = hostedModelPickerServers
        state.hostedModels = hostedModels.mapValues { $0.record }
        state.agentArchiveRecords = agentArchiveRecords.mapValues { $0.record }
        state.agentChannelJoinedAt = agentChannelJoinedAt
        state.agentChannelPosted = agentChannelPosted
        state.agentAttachmentBytes = agentAttachmentBytes
        state.externalPushWebhooks = externalPushWebhooks.mapValues { $0.record }
        state.agentStatusProtocolAdoptedAt = agentStatusProtocolAdoptedAt
        state.agentCursorPullState = agentCursorPullState.mapValues { $0.record }
        state.agentProviderPositions = agentProviderPositions.mapValues { $0.record }
        state.hostedAgents = hostedAgents
        state.featureFlagRecords = featureFlagRecords.mapValues { $0.record }
        state.featureFlagRuleRecords = featureFlagRuleRecords.map { $0.record }
        return state
    }
}
