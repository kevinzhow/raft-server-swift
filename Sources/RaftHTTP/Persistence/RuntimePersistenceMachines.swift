import Foundation
import Synchronization

/// Versioned business snapshot for the existing MachinesAndComputersStore.
///
/// All 15 durable fields are explicit in Payload: every MachineRecord field,
/// original machine/computer API keys and fingerprints, key migration/revocation,
/// computer registration and attachment identities, deleted-workspace facts,
/// migration capabilities, status versions, runtime detections/models/usage and
/// refresh dates, broadcast policies and the release version/original notes JSON.
/// Array order/duplicates, dictionary keys, nulls and optional legacy keys survive.
///
/// Reset process presence on restore:
/// - machineOnline becomes empty (unknown/offline).
/// - computers[*].online becomes false; the field is not encoded in ComputerRow.
/// Machine lastSeenAt is historical metadata; it does not grant machine presence.
/// machineStatusVersions are restored exactly and are not reset or incremented.
///
/// Excluded and left unchanged in the existing instance:
/// - machineMigrationProvisioner, machineMigrationLeaseDispatch,
///   machineMigrationStartAgent, machineMigrationArchiveSourceWorkspace,
///   builtinModelCatalogCheck, agentRuntimeModelsForMachine,
///   runtimeAccountUsageManualRefresh, machineRuntimeModelProbe,
///   machineRoutedLocally, computerUpgradeSender: process dispatch/provider hooks.
/// - builtinCatalogMode, computerAttachEnabledOverride: live/simulation config.
///
/// No connection, callback, provider or simulation override is reconstructed from
/// the database. Opaque data includes credentials; never log it. The caller owns
/// admission, cross-owner snapshot/commit and publication ordering.
extension MachinesAndComputersStore {
    func exportPersistenceData() throws -> Data {
        let captured = storage.withLock { $0 }
        return try RuntimePersistenceFormat.encode(RuntimePersistenceMachinePayload(captured), domain: "raft.machines-computers")
    }

    /// Decode, validate and map all rows before taking one short mutation
    /// borrow. Copy only business fields into this instance; keep its relays.
    func restorePersistenceData(_ data: Data) throws {
        let payload = try RuntimePersistenceFormat.decode(RuntimePersistenceMachinePayload.self, from: data, domain: "raft.machines-computers")
        let business = payload.businessState()
        let retired = storage.withLock { state in
            let previous = state
            state.machines = business.machines
            state.machineStatusVersions = business.machineStatusVersions
            state.computers = business.computers
            state.computerAttachers = business.computerAttachers
            state.attachedComputers = business.attachedComputers
            state.deletedMachineWorkspaces = business.deletedMachineWorkspaces
            state.machineMigrationCapabilities = business.machineMigrationCapabilities
            state.machineRuntimeDetections = business.machineRuntimeDetections
            state.machineRuntimeModels = business.machineRuntimeModels
            state.runtimeAccountUsage = business.runtimeAccountUsage
            state.runtimeAccountUsageRefreshAt = business.runtimeAccountUsageRefreshAt
            state.machineKeys = business.machineKeys
            state.machineBroadcastPolicies = business.machineBroadcastPolicies
            state.machineModelSeenCapability = business.machineModelSeenCapability
            state.latestComputerRelease = business.latestComputerRelease
            state.machineOnline = [:]
            return previous
        }
        // Retire the previous COW containers after the Mutex borrow ends.
        withExtendedLifetime(retired) {}
    }
}

private struct RuntimePersistenceMachinePayload: Codable, Sendable {
    let machines: [RuntimePersistenceMachineRows.MachineRow]
    let machineStatusVersions: [String: Int]
    let computers: [RuntimePersistenceMachineRows.ComputerRow]
    let computerAttachers: [String: String]
    let attachedComputers: [String: RuntimePersistenceMachineRows.AttachedRow]
    let deletedMachineWorkspaces: Set<String>
    let machineMigrationCapabilities: [String: Set<String>]
    let machineRuntimeDetections: [String: RuntimePersistenceMachineRows.DetectionRow]
    let machineRuntimeModels: [String: [String: RuntimePersistenceMachineRows.ModelsRow]]
    let runtimeAccountUsage: [String: RuntimePersistenceMachineRows.UsageRow]
    let runtimeAccountUsageRefreshAt: [String: Date]
    let machineKeys: [String: RuntimePersistenceMachineRows.KeyRow]
    let machineBroadcastPolicies: [String: String]
    let machineModelSeenCapability: Set<String>
    let latestComputerRelease: RuntimePersistenceNullable<RuntimePersistenceMachineRows.ReleaseRow>

    init(_ state: MachinesAndComputersStore.State) {
        machines = state.machines.map(RuntimePersistenceMachineRows.MachineRow.init)
        machineStatusVersions = state.machineStatusVersions
        computers = state.computers.map(RuntimePersistenceMachineRows.ComputerRow.init)
        computerAttachers = state.computerAttachers
        attachedComputers = state.attachedComputers.mapValues(RuntimePersistenceMachineRows.AttachedRow.init)
        deletedMachineWorkspaces = state.deletedMachineWorkspaces
        machineMigrationCapabilities = state.machineMigrationCapabilities
        machineRuntimeDetections = state.machineRuntimeDetections.mapValues(RuntimePersistenceMachineRows.DetectionRow.init)
        machineRuntimeModels = state.machineRuntimeModels.mapValues { $0.mapValues(RuntimePersistenceMachineRows.ModelsRow.init) }
        runtimeAccountUsage = state.runtimeAccountUsage.mapValues(RuntimePersistenceMachineRows.UsageRow.init)
        runtimeAccountUsageRefreshAt = state.runtimeAccountUsageRefreshAt
        machineKeys = state.machineKeys.mapValues(RuntimePersistenceMachineRows.KeyRow.init)
        machineBroadcastPolicies = state.machineBroadcastPolicies
        machineModelSeenCapability = state.machineModelSeenCapability
        latestComputerRelease = .init(state.latestComputerRelease.map(RuntimePersistenceMachineRows.ReleaseRow.init))
    }

    /// Reconstruct rows outside the Mutex. State is a temporary private
    /// carrier here; none of its default callbacks/config is installed.
    func businessState() -> MachinesAndComputersStore.State {
        var state = MachinesAndComputersStore.State()
        state.machines = machines.map { $0.record }
        state.machineStatusVersions = machineStatusVersions
        state.computers = computers.map { $0.record }
        state.computerAttachers = computerAttachers
        state.attachedComputers = attachedComputers.mapValues { $0.record }
        state.deletedMachineWorkspaces = deletedMachineWorkspaces
        state.machineMigrationCapabilities = machineMigrationCapabilities
        state.machineRuntimeDetections = machineRuntimeDetections.mapValues { $0.record }
        state.machineRuntimeModels = machineRuntimeModels.mapValues { $0.mapValues { $0.record } }
        state.runtimeAccountUsage = runtimeAccountUsage.mapValues { $0.record }
        state.runtimeAccountUsageRefreshAt = runtimeAccountUsageRefreshAt
        state.machineKeys = machineKeys.mapValues { $0.record }
        state.machineBroadcastPolicies = machineBroadcastPolicies
        state.machineModelSeenCapability = machineModelSeenCapability
        state.latestComputerRelease = latestComputerRelease.value?.record
        return state
    }
}
