import Foundation
@testable import RaftHTTP

// Test seams moved out of Sources/RaftHTTP/Services/ComputersFleetService.swift.

extension EmailLoginDirectory {

    public func computersForTesting(serverId: String) -> [(id: String, machineId: String, name: String, userId: String, revoked: Bool)] {
        return machinesAndComputersStore.storage.withLock { storeState in
            return storeState.computers.filter { $0.serverId == serverId }.map {
                ($0.id, $0.machineId ?? "", $0.name, storeState.computerAttachers[$0.machineId ?? ""] ?? "", $0.revokedAt != nil)
            }
        }
    }

    /// `POST /api/computer/attach`. Mints a `sk_computer_*` principal for a
    /// server Computer. The gate is default-on; the slug resolves the Server in
    /// the body, and only owner/admin hold the manageMachines capability.
    public func machineExistsForTesting(machineId: String) -> Bool {
        return machinesAndComputersStore.storage.withLock { storeState in
            return storeState.machines.contains { $0.id == machineId }
        }
    }

    public func computerRecordForTesting(apiKey: String) -> (revokedAt: Date?, machineId: String?)? {
        return machinesAndComputersStore.storage.withLock { storeState in
            guard let computer = storeState.computers.first(where: { $0.apiKey == apiKey }) else { return nil }
            return (computer.revokedAt, computer.machineId)
        }
    }

    /// Models the pre-fix FK `SET NULL`: the machine disappears with no
    /// revocation receipt on the Computer.
    public func removeMachineWithoutRevocationForTesting(machineId: String) {
        machinesAndComputersStore.storage.withLock { storeState in
            storeState.machines.removeAll { $0.id == machineId }
            for index in storeState.computers.indices where storeState.computers[index].machineId == machineId {
                storeState.computers[index].machineId = nil
            }
        }
    }

    public func computerAPIKeyForTesting(machineId: String) -> String? {
        return machinesAndComputersStore.storage.withLock { storeState in
            return storeState.computers.first { $0.machineId == machineId && $0.revokedAt == nil }?.apiKey
        }
    }

    public func linkComputerForTesting(serverId: String, machineId: String, online: Bool = false, version: String? = "1.0.0", attachedByUserId: String? = nil) {
        machinesAndComputersStore.storage.withLock { storeState in
            storeState.computers.append((
                id: UUID().uuidString.lowercased(),
                serverId: serverId,
                name: "linked-computer",
                apiKey: MachineCredentialMaterial.computerAPIKeyMaterial(),
                machineId: machineId,
                revokedAt: nil,
                online: online,
                version: version
            ))
            if let attachedByUserId { storeState.computerAttachers[machineId] = attachedByUserId }
        }
    }

    public func registerMachineWithKeyForTesting(
        serverId: String,
        userId: String,
        name: String,
        apiKey providedApiKey: String? = nil
    ) -> (id: String, apiKey: String, fingerprint: String) {
        let id = UUID().uuidString.lowercased()
        let apiKey = providedApiKey ?? MachineCredentialMaterial.machineAPIKeyMaterial()
        let fingerprint = ComputersFleetService.apiKeyFingerprint(apiKey)
        machinesAndComputersStore.storage.withLock { storeState in
            storeState.machines.append(MachineRecord(
                id: id,
                serverId: serverId,
                userId: userId,
                name: name,
                description: nil,
                apiKey: apiKey,
                apiKeyFingerprint: fingerprint
            ))
        }
        return (id, apiKey, fingerprint)
    }

    public func nullMachineFingerprintForTesting(machineId: String) {
        machinesAndComputersStore.storage.withLock { storeState in
            if let index = storeState.machines.firstIndex(where: { $0.id == machineId }) {
                storeState.machines[index].apiKeyFingerprint = nil
            }
        }
    }

    public func markMachineLegacyMigratedForTesting(machineId: String, at date: Date) {
        machinesAndComputersStore.storage.withLock { storeState in
            if let index = storeState.machines.firstIndex(where: { $0.id == machineId }) {
                storeState.machines[index].legacyKeyMigratedAt = date
            }
        }
    }

    /// Seeds the machine runtime model catalog the label-catalog and
    /// runtime-options routes read.
    public func setMachineRuntimeModels(machineId: String, runtime: String, models: [(id: String, label: String)]) {
        machinesAndComputersStore.storage.withLock { storeState in
            storeState.machineRuntimeModels[machineId, default: [:]][runtime] = (models, Date())
        }
    }

    public func machineCount(serverId: String) -> Int {
        return machinesAndComputersStore.storage.withLock { storeState in
            return storeState.machines.filter { $0.serverId == serverId }.count
        }
    }
}
