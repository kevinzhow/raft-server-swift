import Foundation

extension AgentsRuntimeStore {
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
