import Foundation
@testable import RaftHTTP

// Test seams moved out of Sources/RaftHTTP/Services/RuntimeFormsAndProbesService.swift.

extension EmailLoginDirectory {

    public func addAgentMigrationForTesting(id: String, agentId: String = "", sourceMachineId: String, targetMachineId: String, state: String) {
        lock.lock()
        activeAgentMigrations[id] = AgentMigrationFact(
            agentId: agentId,
            sourceMachineId: sourceMachineId,
            targetMachineId: targetMachineId,
            state: state
        )
        lock.unlock()
    }

    public func setAgentMigrationStateForTesting(id: String, state: String) {
        lock.lock()
        if var migration = activeAgentMigrations[id] {
            migration.state = state
            activeAgentMigrations[id] = migration
        }
        lock.unlock()
    }

    public func agentMigrationStateForTesting(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return activeAgentMigrations[id]?.state
    }

    public func agentMigrationCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeAgentMigrations.count
    }

    public func setLatestComputerReleaseForTesting(version: String, releaseNotesJSON: String) {
        lock.lock()
        latestComputerRelease = (version, releaseNotesJSON)
        lock.unlock()
    }

    public func setMachineBroadcastPolicyForTesting(machineId: String, policyJSON: String) {
        lock.lock()
        machineBroadcastPolicies[machineId] = policyJSON
        lock.unlock()
    }

    public func setAgentRuntimeProfileForTesting(
        agentId: String,
        machineId: String,
        baselineMachineId: String? = nil,
        pendingBeforeMachineId: String? = nil,
        pendingAfterMachineId: String? = nil,
        migrationStatus: String? = nil,
        pendingKind: String? = nil,
        pendingReleaseNotesUrl: String? = nil
    ) {
        lock.lock()
        agentRuntimeProfiles[agentId] = AgentRuntimeProfileFact(
            agentId: agentId,
            machineId: machineId,
            baselineMachineId: baselineMachineId,
            pendingBeforeMachineId: pendingBeforeMachineId,
            pendingAfterMachineId: pendingAfterMachineId,
            migrationStatus: migrationStatus,
            pendingKind: pendingKind,
            pendingReleaseNotesUrl: pendingReleaseNotesUrl
        )
        lock.unlock()
    }

    public func agentRuntimeProfileForTesting(agentId: String) -> AgentRuntimeProfileFact? {
        lock.lock()
        defer { lock.unlock() }
        return agentRuntimeProfiles[agentId]
    }

    public func agentMachineIdForTesting(agentId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return agentMachineIds[agentId]
    }

    public func revokeAccessTokenForTesting(_ token: String) {
        lock.lock()
        accessTokens.removeValue(forKey: token)
        lock.unlock()
    }

    public func retireUserForTesting(userId: String) {
        lock.lock()
        if let key = accounts.first(where: { $0.value.id == userId })?.key {
            accounts[key]?.retiredAt = Date()
        }
        lock.unlock()
    }

    public func setAgentMachineForTesting(agentId: String, machineId: String) {
        lock.lock()
        agentMachineIds[agentId] = machineId
        lock.unlock()
    }

    public func setAgentStatusForTesting(agentId: String, status: String) {
        oauth.setAgentStatus(id: agentId, status: status)
        lock.lock()
        serverAgents[agentId]?.status = status
        lock.unlock()
    }

    public func setRuntimeAccountUsageForTesting(
        machineId: String,
        provider: String,
        json: String,
        staleAfter: Date
    ) {
        lock.lock()
        runtimeAccountUsage["\(machineId)\n\(provider)"] = (json, staleAfter)
        lock.unlock()
    }
}
