import Foundation
@testable import RaftHTTP

// Test seams moved out of Sources/RaftHTTP/Services/AgentMachineMigrationControlService.swift, AgentMigrationStatusService.swift, AgentHostedMigrationService.swift.

extension EmailLoginDirectory {

    /// Appends one machine row with a fresh key and returns its id.
    public func registerMachine(serverId: String, userId: String, name: String) -> String {
        machinesAndComputersStore.registerMachine(serverId: serverId, userId: userId, name: name)
    }

    public func enableAgentMigrationForTesting(serverId: String) {
        lock.lock()
        agentMigrationServers.insert(serverId)
        lock.unlock()
    }

    public func enableHostedMigrationForTesting(serverId: String) {
        lock.lock()
        hostedMigrationServers.insert(serverId)
        lock.unlock()
    }

    /// Test-only override of the deployment-level hosted provider token, so
    /// parallel suites never race on process environment.
    public func setHostedProviderTokenForTesting(_ token: String?) {
        lock.lock()
        hostedProviderTokenOverride = token
        lock.unlock()
    }

    public func enableHostedRuntimeForTesting(serverId: String) {
        lock.lock()
        hostedRuntimeServers.insert(serverId)
        lock.unlock()
    }

    public func seedHostedMigrationForTesting(
        agentId: String,
        serverId: String,
        supportRef: String,
        revision: Int = 1,
        state: String = "in_transit",
        sourceMachineId: String? = nil
    ) {
        lock.lock()
        hostedMigrations[agentId] = HostedMigrationRecord(
            agentId: agentId,
            serverId: serverId,
            supportRef: supportRef,
            revision: revision,
            state: state,
            sourceMachineId: sourceMachineId
        )
        lock.unlock()
    }

    public func seedMachineMigrationForTesting(
        agentId: String,
        serverId: String,
        supportRef: String,
        revision: Int,
        state: String,
        sourceMachineId: String,
        targetMachineId: String,
        transportGeneration: String
    ) {
        lock.lock()
        machineMigrations[supportRef] = MachineMigrationRecord(
            agentId: agentId,
            serverId: serverId,
            supportRef: supportRef,
            revision: revision,
            state: state,
            sourceMachineId: sourceMachineId,
            targetMachineId: targetMachineId,
            transportGeneration: transportGeneration
        )
        lock.unlock()
    }

    /// Test-observable snapshot of one machine migration row. Mirrors what the
    /// upstream suite reads straight out of the `agent_migrations` table.
    public func machineMigrationStateForTesting(migrationRef: String) -> MachineMigrationStateSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = machineMigrations[migrationRef] else { return nil }
        return MachineMigrationStateSnapshot(
            state: record.state,
            revision: record.revision,
            agentId: record.agentId,
            sourceMachineId: record.sourceMachineId,
            targetMachineId: record.targetMachineId,
            transportGeneration: record.transportGeneration,
            flippedAt: record.flippedAt,
            arrivedAt: record.arrivedAt,
            completedAt: record.completedAt,
            updatedAt: record.updatedAt,
            failureReason: record.failureReason,
            transportErrorCode: record.transportErrorCode,
            transportErrorMessage: record.transportErrorMessage,
            autoStartFailureStage: record.autoStartFailureStage,
            autoStartFailureCode: record.autoStartFailureCode,
            sourceWorkspaceArchivedAt: record.sourceWorkspaceArchivedAt,
            sourceWorkspaceArchiveAttempts: record.sourceWorkspaceArchiveAttempts,
            sourceWorkspaceArchiveLastError: record.sourceWorkspaceArchiveLastError,
            sourceWorkspaceArchiveRetryAt: record.sourceWorkspaceArchiveRetryAt,
            sourceWorkspaceArchiveAbandonedAt: record.sourceWorkspaceArchiveAbandonedAt,
            cancelDisposition: record.cancelDisposition,
            cancelSourceAck: record.cancelSourceAck,
            cancelTargetAck: record.cancelTargetAck,
            cancelSourceAckAt: record.cancelSourceAckAt,
            cancelTargetAckAt: record.cancelTargetAckAt,
            canceledAt: record.canceledAt,
            transportTeardownAt: record.transportTeardownAt
        )
    }

    /// Re-date a `starting` row so the auto-start dispatch lease can expire,
    /// matching the upstream suite's direct `updated_at` update.
    public func setMachineMigrationUpdatedAtForTesting(migrationRef: String, date: Date) {
        lock.lock()
        if var record = machineMigrations[migrationRef] {
            record.updatedAt = date
            machineMigrations[migrationRef] = record
        }
        lock.unlock()
    }

    public func setMachineMigrationArchiveStateForTesting(migrationRef: String, archivedAt: Date?) {
        lock.lock()
        if var record = machineMigrations[migrationRef] {
            record.sourceWorkspaceArchivedAt = archivedAt
            machineMigrations[migrationRef] = record
        }
        lock.unlock()
    }

    public func setAgentMuteForTesting(channelId: String, agentId: String, serverId: String, muteFromSeq: Int) {
        _ = oauth.setActivityMuted(channelId: channelId, receiverId: agentId, muted: true, muteFromSeq: muteFromSeq)
    }

    @discardableResult
    public func createAgentDirectChannelForTesting(serverId: String, firstAgentId: String, secondAgentId: String) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        postableChannels[id] = PostableChannel(serverId: serverId, memberIds: [firstAgentId, secondAgentId], kind: "dm", name: "dm")
        lock.unlock()
        return id
    }

    public func markMachineMigrationTransportLostForTesting(supportRef: String, message: String) {
        lock.lock()
        guard var migration = machineMigrations[supportRef] else {
            lock.unlock()
            return
        }
        let now = Date()
        migration.state = "failed"
        migration.revision += 1
        migration.failureReason = "MIGRATION_TRANSPORT_LOST"
        migration.transportErrorCode = "MIGRATION_TRANSPORT_LOST"
        migration.transportErrorMessage = message
        migration.transportLostAt = now
        migration.transportTeardownAt = now
        machineMigrations[supportRef] = migration
        lock.unlock()
    }

    public func setAgentStatusProtocolAdoptedForTesting(agentId: String, at date: Date?) {
        agentsRuntimeStore.agentStatusProtocolAdoptedAt[agentId] = date
    }

    public func setAgentCursorPullStateForTesting(agentId: String, lastPulledAt: Date?, pendingAcks: Int) {
        if let lastPulledAt {
            agentsRuntimeStore.agentCursorPullState[agentId] = (lastPulledAt, pendingAcks)
        } else {
            agentsRuntimeStore.agentCursorPullState[agentId] = nil
        }
    }

    public func setAgentProviderPositionForTesting(
        agentId: String,
        provider: String = "antiproton",
        state: String,
        providerAgentId: String?,
        syncPending: Bool = false,
        lastErrorCode: String? = nil,
        lastErrorAt: Date? = nil,
        activatedAt: Date?
    ) {
        agentsRuntimeStore.agentProviderPositions[agentId] = (
            provider,
            state,
            providerAgentId,
            syncPending,
            lastErrorCode,
            lastErrorAt,
            activatedAt
        )
    }

    public func machineMigrationCancelGenerationsForTesting(migrationRef: String) -> (cancel: String, transport: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = machineMigrations[migrationRef],
              let cancel = record.cancelGeneration,
              let transport = record.cancelTransportGeneration
        else { return nil }
        return (cancel, transport)
    }

    public func seedMachineMigrationCancelStateForTesting(
        migrationRef: String,
        state: String,
        cancelGeneration: String,
        cancelTransportGeneration: String,
        disposition: String
    ) {
        lock.lock()
        if var record = machineMigrations[migrationRef] {
            record.state = state
            record.cancelGeneration = cancelGeneration
            record.cancelTransportGeneration = cancelTransportGeneration
            record.cancelDisposition = disposition
            machineMigrations[migrationRef] = record
        }
        lock.unlock()
    }

    public func machineRegistrantForTesting(machineId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return machines.first { $0.id == machineId }?.userId
    }
}
