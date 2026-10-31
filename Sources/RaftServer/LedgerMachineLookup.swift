import RaftConnectAuth
import RaftHTTP

/// Bridges the in-memory ledger onto the NIO `/daemon/connect` auth protocol.
struct LedgerMachineLookup: MachineCredentialLooking {
    let accounts: EmailLoginDirectory

    func findComputer(apiKey: String) async throws -> ComputerAuthResolution {
        switch accounts.computerCredential(apiKey: apiKey) {
        case .linked(let computerId, let machineId):
            return .linked(computerId: computerId, machineId: machineId)
        case .revoked:
            return .denied(.computerRevoked)
        case .machineUnlinked:
            return .denied(.computerMachineUnlinked)
        case .keyMismatch:
            return .denied(.computerKeyHashMismatch)
        case .notFound:
            return .denied(.computerNotFound)
        }
    }

    func machine(id: String) async throws -> MatchedMachine? {
        accounts.machineCredential(id: id).map {
            MatchedMachine(id: $0.machineId, serverId: $0.serverId)
        }
    }

    func serverExists(id: String) async throws -> Bool {
        accounts.serverExists(id: id)
    }

    func machine(apiKey: String) async throws -> MatchedMachine? {
        accounts.machineCredential(apiKey: apiKey).map {
            MatchedMachine(id: $0.machineId, serverId: $0.serverId)
        }
    }
}
