import Foundation
@testable import RaftHTTP

// Test seams moved out of Sources/RaftHTTP/Services/RuntimeFormsAndProbesService.swift.

extension EmailLoginDirectory {

    public func addAgentMigrationForTesting(id: String, agentId: String = "", sourceMachineId: String, targetMachineId: String, state: String) {
        agentsRuntimeStore.withState { owned in
            owned.activeAgentMigrations[id] = AgentMigrationFact(
                agentId: agentId,
                sourceMachineId: sourceMachineId,
                targetMachineId: targetMachineId,
                state: state
            )
        }
    }

    public func setAgentMigrationStateForTesting(id: String, state: String) {
        agentsRuntimeStore.withState { owned in
            if var migration = owned.activeAgentMigrations[id] {
                migration.state = state
                owned.activeAgentMigrations[id] = migration
            }
        }
    }

    public func agentMigrationStateForTesting(id: String) -> String? {
        return agentsRuntimeStore.withState { owned in owned.activeAgentMigrations[id]?.state }
    }

    public func agentMigrationCountForTesting() -> Int {
        return agentsRuntimeStore.withState { owned in owned.activeAgentMigrations.count }
    }

    public func setLatestComputerReleaseForTesting(version: String, releaseNotesJSON: String) {
        machinesAndComputersStore.storage.withLock { owned in
            owned.latestComputerRelease = (version, releaseNotesJSON)
        }
    }

    public func setMachineBroadcastPolicyForTesting(machineId: String, policyJSON: String) {
        machinesAndComputersStore.storage.withLock { owned in
            owned.machineBroadcastPolicies[machineId] = policyJSON
        }
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
        agentsRuntimeStore.withState { owned in
            owned.agentRuntimeProfiles[agentId] = AgentRuntimeProfileFact(
                agentId: agentId,
                machineId: machineId,
                baselineMachineId: baselineMachineId,
                pendingBeforeMachineId: pendingBeforeMachineId,
                pendingAfterMachineId: pendingAfterMachineId,
                migrationStatus: migrationStatus,
                pendingKind: pendingKind,
                pendingReleaseNotesUrl: pendingReleaseNotesUrl
            )
        }
    }

    public func agentRuntimeProfileForTesting(agentId: String) -> AgentRuntimeProfileFact? {
        return agentsRuntimeStore.withState { owned in owned.agentRuntimeProfiles[agentId] }
    }

    public func agentMachineIdForTesting(agentId: String) -> String? {
        return agentsRuntimeStore.withState { owned in owned.agentMachineIds[agentId] }
    }

    public func revokeAccessTokenForTesting(_ token: String) {
        authProfileStore.state.withLock { owned in
            _ = owned.accountSurface.accessTokens.removeValue(forKey: token)
        }
    }

    public func retireUserForTesting(userId: String) {
        authProfileStore.state.withLock { owned in
            if let key = owned.accountSurface.accounts.first(where: { $0.value.id == userId })?.key {
                owned.accountSurface.accounts[key]?.retiredAt = Date()
            }
        }
    }

    public func setAgentMachineForTesting(agentId: String, machineId: String) {
        agentsRuntimeStore.withState { owned in
            owned.agentMachineIds[agentId] = machineId
        }
    }

    public func setAgentStatusForTesting(agentId: String, status: String) {
        oauth.setAgentStatus(id: agentId, status: status)
        agentsRuntimeStore.withState { $0.serverAgents[agentId]?.status = status }
    }

    public func setRuntimeAccountUsageForTesting(
        machineId: String,
        provider: String,
        json: String,
        staleAfter: Date
    ) {
        machinesAndComputersStore.storage.withLock { owned in
            owned.runtimeAccountUsage["\(machineId)\n\(provider)"] = (json, staleAfter)
        }
    }
}
