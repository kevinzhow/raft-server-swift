import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    public func mintAgentCredential(agentId: String, scopes: [String], name: String) -> String {
        agentsRuntimeStore.mintAgentCredential(agentId: agentId, scopes: scopes, name: name).apiKey
    }

    /// Binds a machine key to one agent. The legacy agent reaction route accepts that bearer.
    public func registerMachineForAgent(serverId: String, agentId: String) -> String {
        let key = "mk_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        machinesAndComputersStore.storage.withLock { state in
            state.machineKeys[key] = (serverId: serverId, agentId: agentId)
        }
        return key
    }

}
