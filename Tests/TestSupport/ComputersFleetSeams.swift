import Foundation
@testable import RaftHTTP

// Test seams moved out of Sources/RaftHTTP/Services/ComputersFleetService.swift.

extension EmailLoginDirectory {

    public func computersForTesting(serverId: String) -> [(id: String, machineId: String, name: String, userId: String, revoked: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return computers.filter { $0.serverId == serverId }.map {
            ($0.id, $0.machineId ?? "", $0.name, computerAttachers[$0.machineId ?? ""] ?? "", $0.revokedAt != nil)
        }
    }

    /// `POST /api/computer/attach`. Mints a `sk_computer_*` principal for a
    /// server Computer. The gate is default-on; the slug resolves the Server in
    /// the body, and only owner/admin hold the manageMachines capability.
    public func machineExistsForTesting(machineId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return machines.contains { $0.id == machineId }
    }

    public func computerRecordForTesting(apiKey: String) -> (revokedAt: Date?, machineId: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let computer = computers.first(where: { $0.apiKey == apiKey }) else { return nil }
        return (computer.revokedAt, computer.machineId)
    }

    /// Models the pre-fix FK `SET NULL`: the machine disappears with no
    /// revocation receipt on the Computer.
    public func removeMachineWithoutRevocationForTesting(machineId: String) {
        lock.lock()
        machines.removeAll { $0.id == machineId }
        for index in computers.indices where computers[index].machineId == machineId {
            computers[index].machineId = nil
        }
        lock.unlock()
    }

    public func computerAPIKeyForTesting(machineId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return computers.first { $0.machineId == machineId && $0.revokedAt == nil }?.apiKey
    }

    public func linkComputerForTesting(serverId: String, machineId: String, online: Bool = false, version: String? = "1.0.0", attachedByUserId: String? = nil) {
        lock.lock()
        computers.append((
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            name: "linked-computer",
            apiKey: Self.computerAPIKeyMaterial(),
            machineId: machineId,
            revokedAt: nil,
            online: online,
            version: version
        ))
        if let attachedByUserId { computerAttachers[machineId] = attachedByUserId }
        lock.unlock()
    }

    public func registerMachineWithKeyForTesting(
        serverId: String,
        userId: String,
        name: String,
        apiKey providedApiKey: String? = nil
    ) -> (id: String, apiKey: String, fingerprint: String) {
        let id = UUID().uuidString.lowercased()
        let apiKey = providedApiKey ?? Self.machineAPIKeyMaterial()
        let fingerprint = Self.apiKeyFingerprint(apiKey)
        lock.lock()
        machines.append(MachineRecord(
            id: id,
            serverId: serverId,
            userId: userId,
            name: name,
            description: nil,
            apiKey: apiKey,
            apiKeyFingerprint: fingerprint
        ))
        lock.unlock()
        return (id, apiKey, fingerprint)
    }

    public func nullMachineFingerprintForTesting(machineId: String) {
        lock.lock()
        if let index = machines.firstIndex(where: { $0.id == machineId }) {
            machines[index].apiKeyFingerprint = nil
        }
        lock.unlock()
    }

    public func markMachineLegacyMigratedForTesting(machineId: String, at date: Date) {
        lock.lock()
        if let index = machines.firstIndex(where: { $0.id == machineId }) {
            machines[index].legacyKeyMigratedAt = date
        }
        lock.unlock()
    }
}
