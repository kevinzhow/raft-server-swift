import Foundation
@testable import RaftHTTP

// Test seams moved out of Sources/RaftHTTP/Services/RuntimeUsageAndAttestationsService.swift.

extension EmailLoginDirectory {

    /// Enables the usage-limit attention feed for one Server. Production turns
    /// this on from the agent-runtime path; the HTTP surface only reads it.
    public func enableUsageLimitAttentionForServer(_ serverId: String) {
        serversAndChannelsStore.usageLimitAttentionServers.insert(serverId)
    }

    public func disableUsageLimitAttentionForServer(_ serverId: String) {
        serversAndChannelsStore.usageLimitAttentionServers.remove(serverId)
    }

    @discardableResult
    public func addSystemAttentionIncidentForTesting(
        serverId: String,
        machineId: String,
        provider: String = "codex",
        windowKey: String = "primary",
        affectedAgentIds: [String] = [],
        activatedAt: Date = Date(),
        resetsAt: Date? = nil
    ) -> String {
        let generation = (messagesAndThreadsStore.systemAttentionIncidents
            .filter { $0.serverId == serverId && $0.machineId == machineId && $0.provider == provider && $0.windowKey == windowKey }
            .map(\.activationGeneration)
            .max() ?? 0) + 1
        let id = UUID().uuidString.lowercased()
        messagesAndThreadsStore.systemAttentionIncidents.append(SystemAttentionIncident(
            id: id,
            serverId: serverId,
            machineId: machineId,
            provider: provider,
            windowKey: windowKey,
            activationGeneration: generation,
            affectedAgentIds: affectedAgentIds,
            activatedAt: activatedAt,
            lastObservedAt: activatedAt,
            resetsAt: resetsAt,
            state: "active"
        ))
        return id
    }
}
