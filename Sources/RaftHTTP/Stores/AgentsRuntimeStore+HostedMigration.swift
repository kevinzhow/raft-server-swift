import Foundation

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
