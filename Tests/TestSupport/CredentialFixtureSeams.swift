import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func mintAgentCredential(agentId: String, scopes: [String], name: String) -> String {
        agentsRuntimeStore.mintAgentCredential(agentId: agentId, scopes: scopes, name: name).apiKey
    }

    /// Binds a legacy `sk_daemon_*` key row to one agent. The legacy agent
    /// machine routes accept that bearer as the daemon-compat principal.
    public func registerMachineForAgent(serverId: String, agentId: String) -> String {
        let key = "sk_daemon_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        machinesAndComputersStore.storage.withLock { state in
            state.machineKeys[key] = (serverId: serverId, agentId: agentId)
        }
        return key
    }

}
