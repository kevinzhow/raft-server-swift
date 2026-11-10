import Foundation

extension AgentMachineMigrationControlService {
    private func queryWorkspaceBinding(authorization: String?, serverId: String, agentId: String,
                                       persistence: BusinessPersistenceRuntime?) throws -> (MachineQueryAuthority, any MachineQuerying) {
        try machineQueryRead(persistence: persistence) {
            try workspaceAuthority(authorization, serverId: serverId, agentId: agentId)
            let machineId = agents.agentMachineIds[agentId] ?? agents.archiveRecord(agentId: agentId)?.machineId
            guard let machineId else { throw AgentMigrationControlError.machineUnassigned }
            let authority = try machineQueryAuthority(agents: agents, machineId: machineId, serverId: serverId)
            guard let port = machines.machineQueries else { throw MachineQueryError.offline }
            return (authority, port)
        }
    }

    public func queryAgentWorkspaceFiles(authorization: String?, serverId: String, agentId: String,
        query: String?, persistence: BusinessPersistenceRuntime?) async throws -> AgentWorkspaceFilesResponse {
        let binding: (MachineQueryAuthority, any MachineQuerying)
        do { binding = try queryWorkspaceBinding(authorization: authorization, serverId: serverId, agentId: agentId, persistence: persistence) }
        catch MachineQueryError.offline { throw AgentMigrationControlError.workspaceFilesMachineOffline }
        let dirPath = AgentSurfaceQuery.agentSurfaceQueryString(query, "dirPath")
        let hidden = ["1", "true"].contains((AgentSurfaceQuery.agentSurfaceQueryString(query, "includeHidden") ?? "").lowercased())
        let files: OrderedJSON
        do { files = try await binding.1.workspaceFiles(authority: binding.0, agentId: agentId, dirPath: dirPath, includeHidden: hidden) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // Authority changes during I/O take precedence over surfacing a
            // daemon result, including when that result is an error.
            try machineQueryRead(persistence: persistence) { try workspaceAuthority(authorization, serverId: serverId, agentId: agentId) }
            if case MachineQueryError.timedOut = error { throw AgentMigrationControlError.workspaceFilesTimeout }
            throw AgentMigrationControlError.workspaceFilesMachineOffline
        }
        return try machineQueryRead(persistence: persistence) {
            try workspaceAuthority(authorization, serverId: serverId, agentId: agentId)
            let machineId = agents.agentMachineIds[agentId] ?? agents.archiveRecord(agentId: agentId)?.machineId
            guard machineId == binding.0.machineId,
                  (try? machineQueryAuthority(agents: agents, machineId: binding.0.machineId, serverId: serverId)) == binding.0 else {
                throw AgentMigrationControlError.workspaceFilesMachineOffline
            }
            return AgentWorkspaceFilesResponse(files: files.render())
        }
    }

    public func queryAgentWorkspaceRead(authorization: String?, serverId: String, agentId: String,
        query: String?, persistence: BusinessPersistenceRuntime?) async throws -> AgentSurfaceBodyResponse {
        // The Node path error follows authentication/agent authority and precedes
        // any attempt to resolve a machine connection.
        try machineQueryRead(persistence: persistence) { try workspaceAuthority(authorization, serverId: serverId, agentId: agentId) }
        guard let path = AgentSurfaceQuery.agentSurfaceQueryString(query, "path"), !path.isEmpty else { throw WorkspaceQueryPathRequired() }
        let binding: (MachineQueryAuthority, any MachineQuerying)
        do { binding = try queryWorkspaceBinding(authorization: authorization, serverId: serverId, agentId: agentId, persistence: persistence) }
        catch MachineQueryError.offline { throw AgentMigrationControlError.workspaceReadMachineOffline }
        let body: OrderedJSON
        do { body = try await binding.1.workspaceRead(authority: binding.0, agentId: agentId, path: path) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try machineQueryRead(persistence: persistence) { try workspaceAuthority(authorization, serverId: serverId, agentId: agentId) }
            if case MachineQueryError.timedOut = error { throw AgentMigrationControlError.workspaceReadTimeout }
            throw AgentMigrationControlError.workspaceReadMachineOffline
        }
        return try machineQueryRead(persistence: persistence) {
            try workspaceAuthority(authorization, serverId: serverId, agentId: agentId)
            let machineId = agents.agentMachineIds[agentId] ?? agents.archiveRecord(agentId: agentId)?.machineId
            guard machineId == binding.0.machineId,
                  (try? machineQueryAuthority(agents: agents, machineId: binding.0.machineId, serverId: serverId)) == binding.0 else {
                throw AgentMigrationControlError.workspaceReadMachineOffline
            }
            return AgentSurfaceBodyResponse(body: body.render())
        }
    }
}

private struct WorkspaceQueryPathRequired: DomainError {
    let status: UInt = 400
    let errorMessage = "path query parameter is required"
}
