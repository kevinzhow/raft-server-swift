import Foundation
@testable import RaftHTTP

// Test seams moved out of Sources/RaftHTTP/Services/RuntimeUsageAndAttestationsService.swift.

extension EmailLoginDirectory {

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
        lock.lock()
        let generation = (systemAttentionIncidents
            .filter { $0.serverId == serverId && $0.machineId == machineId && $0.provider == provider && $0.windowKey == windowKey }
            .map(\.activationGeneration)
            .max() ?? 0) + 1
        let id = UUID().uuidString.lowercased()
        systemAttentionIncidents.append(SystemAttentionIncident(
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
        lock.unlock()
        return id
    }
}
