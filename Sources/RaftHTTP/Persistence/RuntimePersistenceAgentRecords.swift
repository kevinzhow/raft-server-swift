import Foundation

/// Persistence-only DTOs; shared business records do not acquire Codable.
enum RuntimePersistenceAgentRows {
    struct ServerAgentRow: Codable, Sendable {
        let id: String
        let serverId: String
        let name: String
        let avatarUrl: RuntimePersistenceNullable<String>
        let status: String

        init(_ row: ServerAgent) {
            id = row.id
            serverId = row.serverId
            name = row.name
            avatarUrl = .init(row.avatarUrl)
            status = row.status
        }

        var record: ServerAgent {
            ServerAgent(
                id: id,
                serverId: serverId,
                name: name,
                avatarUrl: avatarUrl.value,
                status: status
            )
        }
    }

    struct CredentialRow: Codable, Sendable {
        let id: String
        let agentId: String
        let scopes: Set<String>
        let name: String
        let createdAt: Date
        let lastUsedAt: RuntimePersistenceNullable<Date>
        let revokedAt: RuntimePersistenceNullable<Date>

        init(_ row: AgentCredential) {
            id = row.id
            agentId = row.agentId
            scopes = row.scopes
            name = row.name
            createdAt = row.createdAt
            lastUsedAt = .init(row.lastUsedAt)
            revokedAt = .init(row.revokedAt)
        }

        var record: AgentCredential {
            AgentCredential(
                id: id,
                agentId: agentId,
                scopes: scopes,
                name: name,
                createdAt: createdAt,
                lastUsedAt: lastUsedAt.value,
                revokedAt: revokedAt.value
            )
        }
    }

    struct RuntimeProfileRow: Codable, Sendable {
        let agentId: String
        let machineId: String
        let baselineMachineId: RuntimePersistenceNullable<String>
        let pendingBeforeMachineId: RuntimePersistenceNullable<String>
        let pendingAfterMachineId: RuntimePersistenceNullable<String>
        let migrationStatus: RuntimePersistenceNullable<String>
        let pendingKind: RuntimePersistenceNullable<String>
        let pendingReleaseNotesUrl: RuntimePersistenceNullable<String>

        init(_ row: AgentRuntimeProfileFact) {
            agentId = row.agentId
            machineId = row.machineId
            baselineMachineId = .init(row.baselineMachineId)
            pendingBeforeMachineId = .init(row.pendingBeforeMachineId)
            pendingAfterMachineId = .init(row.pendingAfterMachineId)
            migrationStatus = .init(row.migrationStatus)
            pendingKind = .init(row.pendingKind)
            pendingReleaseNotesUrl = .init(row.pendingReleaseNotesUrl)
        }

        var record: AgentRuntimeProfileFact {
            AgentRuntimeProfileFact(
                agentId: agentId,
                machineId: machineId,
                baselineMachineId: baselineMachineId.value,
                pendingBeforeMachineId: pendingBeforeMachineId.value,
                pendingAfterMachineId: pendingAfterMachineId.value,
                migrationStatus: migrationStatus.value,
                pendingKind: pendingKind.value,
                pendingReleaseNotesUrl: pendingReleaseNotesUrl.value
            )
        }
    }

    struct MigrationFactRow: Codable, Sendable {
        let agentId: String
        let sourceMachineId: String
        let targetMachineId: String
        let state: String

        init(_ row: AgentMigrationFact) {
            agentId = row.agentId
            sourceMachineId = row.sourceMachineId
            targetMachineId = row.targetMachineId
            state = row.state
        }

        var record: AgentMigrationFact {
            AgentMigrationFact(
                agentId: agentId,
                sourceMachineId: sourceMachineId,
                targetMachineId: targetMachineId,
                state: state
            )
        }
    }

    struct ArchiveRow: Codable, Sendable {
        let serverId: String
        let machineId: RuntimePersistenceNullable<String>
        let machineName: String
        let archivedAt: Date
        let archivedByUserId: String
        let workspaceState: String
        let pendingOp: RuntimePersistenceNullable<String>
        let lastErrorCode: RuntimePersistenceNullable<String>
        let lastErrorAt: RuntimePersistenceNullable<Date>

        init(_ row: AgentArchiveRecord) {
            serverId = row.serverId
            machineId = .init(row.machineId)
            machineName = row.machineName
            archivedAt = row.archivedAt
            archivedByUserId = row.archivedByUserId
            workspaceState = row.workspaceState
            pendingOp = .init(row.pendingOp)
            lastErrorCode = .init(row.lastErrorCode)
            lastErrorAt = .init(row.lastErrorAt)
        }

        var record: AgentArchiveRecord {
            AgentArchiveRecord(
                serverId: serverId,
                machineId: machineId.value,
                machineName: machineName,
                archivedAt: archivedAt,
                archivedByUserId: archivedByUserId,
                workspaceState: workspaceState,
                pendingOp: pendingOp.value,
                lastErrorCode: lastErrorCode.value,
                lastErrorAt: lastErrorAt.value
            )
        }
    }

    struct HostedModelRow: Codable, Sendable {
        let id: String
        let label: String
        let provider: String

        init(_ row: (id: String, label: String, provider: String)) {
            id = row.id
            label = row.label
            provider = row.provider
        }

        var record: (id: String, label: String, provider: String) {
            (
                id: id,
                label: label,
                provider: provider
            )
        }
    }

    struct HostedModelStateRow: Codable, Sendable {
        let models: [HostedModelRow]
        let defaultModel: RuntimePersistenceNullable<String>
        let defaultLabel: RuntimePersistenceNullable<String>
        let model: RuntimePersistenceNullable<String>
        let label: RuntimePersistenceNullable<String>
        let source: String
        let locked: Bool

        init(_ row: HostedModelState) {
            models = row.models.map(HostedModelRow.init)
            defaultModel = .init(row.defaultModel)
            defaultLabel = .init(row.defaultLabel)
            model = .init(row.model)
            label = .init(row.label)
            source = row.source
            locked = row.locked
        }

        var record: HostedModelState {
            HostedModelState(
                models: models.map { $0.record },
                defaultModel: defaultModel.value,
                defaultLabel: defaultLabel.value,
                model: model.value,
                label: label.value,
                source: source,
                locked: locked
            )
        }
    }

    struct FlagRow: Codable, Sendable {
        let key: String
        let enabled: Bool
        let killSwitch: Bool
        let defaultEnabled: Bool

        init(_ row: FeatureFlagRecord) {
            key = row.key
            enabled = row.enabled
            killSwitch = row.killSwitch
            defaultEnabled = row.defaultEnabled
        }

        var record: FeatureFlagRecord {
            FeatureFlagRecord(
                key: key,
                enabled: enabled,
                killSwitch: killSwitch,
                defaultEnabled: defaultEnabled
            )
        }
    }

    struct FlagRuleRow: Codable, Sendable {
        let key: String
        let stage: String
        let decision: String
        let values: [String]
        let clientOs: RuntimePersistenceNullable<[String]>
        let minClientBuild: RuntimePersistenceNullable<Int>
        let clientBuildTypes: RuntimePersistenceNullable<[String]>
        let priority: Int
        let createdAt: Date

        init(_ row: FeatureFlagRuleRecord) {
            key = row.key
            stage = row.stage
            decision = row.decision
            values = row.values
            clientOs = .init(row.clientOs)
            minClientBuild = .init(row.minClientBuild)
            clientBuildTypes = .init(row.clientBuildTypes)
            priority = row.priority
            createdAt = row.createdAt
        }

        var record: FeatureFlagRuleRecord {
            FeatureFlagRuleRecord(
                key: key,
                stage: stage,
                decision: decision,
                values: values,
                clientOs: clientOs.value,
                minClientBuild: minClientBuild.value,
                clientBuildTypes: clientBuildTypes.value,
                priority: priority,
                createdAt: createdAt
            )
        }
    }

    struct DeliveryRow: Codable, Sendable {
        let agentId: String
        let messageId: String
        let channelType: String

        init(_ row: (agentId: String, messageId: String, channelType: String)) {
            agentId = row.agentId
            messageId = row.messageId
            channelType = row.channelType
        }

        var record: (agentId: String, messageId: String, channelType: String) {
            (
                agentId: agentId,
                messageId: messageId,
                channelType: channelType
            )
        }
    }

    struct HostedRuntimeRow: Codable, Sendable {
        let provider: String
        let model: RuntimePersistenceNullable<String>
        let state: String
        let retryNeedsModel: Bool
        let createdAt: Date

        init(_ row: (provider: String, model: String?, state: String, retryNeedsModel: Bool, createdAt: Date)) {
            provider = row.provider
            model = .init(row.model)
            state = row.state
            retryNeedsModel = row.retryNeedsModel
            createdAt = row.createdAt
        }

        var record: (provider: String, model: String?, state: String, retryNeedsModel: Bool, createdAt: Date) {
            (
                provider: provider,
                model: model.value,
                state: state,
                retryNeedsModel: retryNeedsModel,
                createdAt: createdAt
            )
        }
    }

    struct WebhookRow: Codable, Sendable {
        let url: String
        let secret: String

        init(_ row: (url: String, secret: String)) {
            url = row.url
            secret = row.secret
        }

        var record: (url: String, secret: String) {
            (
                url: url,
                secret: secret
            )
        }
    }

    struct CursorRow: Codable, Sendable {
        let lastPulledAt: Date
        let pendingAcks: Int

        init(_ row: (lastPulledAt: Date, pendingAcks: Int)) {
            lastPulledAt = row.lastPulledAt
            pendingAcks = row.pendingAcks
        }

        var record: (lastPulledAt: Date, pendingAcks: Int) {
            (
                lastPulledAt: lastPulledAt,
                pendingAcks: pendingAcks
            )
        }
    }

    struct ProviderPositionRow: Codable, Sendable {
        let provider: String
        let state: String
        let providerAgentId: RuntimePersistenceNullable<String>
        let syncPending: Bool
        let lastErrorCode: RuntimePersistenceNullable<String>
        let lastErrorAt: RuntimePersistenceNullable<Date>
        let activatedAt: RuntimePersistenceNullable<Date>

        init(_ row: (provider: String, state: String, providerAgentId: String?, syncPending: Bool, lastErrorCode: String?, lastErrorAt: Date?, activatedAt: Date?)) {
            provider = row.provider
            state = row.state
            providerAgentId = .init(row.providerAgentId)
            syncPending = row.syncPending
            lastErrorCode = .init(row.lastErrorCode)
            lastErrorAt = .init(row.lastErrorAt)
            activatedAt = .init(row.activatedAt)
        }

        var record: (provider: String, state: String, providerAgentId: String?, syncPending: Bool, lastErrorCode: String?, lastErrorAt: Date?, activatedAt: Date?) {
            (
                provider: provider,
                state: state,
                providerAgentId: providerAgentId.value,
                syncPending: syncPending,
                lastErrorCode: lastErrorCode.value,
                lastErrorAt: lastErrorAt.value,
                activatedAt: activatedAt.value
            )
        }
    }
}
