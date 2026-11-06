import Foundation

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
