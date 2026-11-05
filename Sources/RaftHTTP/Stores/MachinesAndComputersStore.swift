import Foundation

/// Owns the machine, Computer and migration rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class MachinesAndComputersStore: @unchecked Sendable {
    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State {
        var machines: [MachineRecord] = []
        var machineStatusVersions: [String: Int] = [:]
        var machineOnline: [String: Bool] = [:]
        var computers: [(id: String, serverId: String, name: String, apiKey: String, machineId: String?, revokedAt: Date?, online: Bool, version: String?)] = []
        var computerAttachers: [String: String] = [:]
        var attachedComputers: [String: AttachedComputer] = [:]
        var deletedMachineWorkspaces: Set<String> = []
        var machineMigrationCapabilities: [String: Set<String>] = [:]
        var machineRuntimeDetections: [String: (status: String, unfinished: Set<String>)] = [:]
        var machineMigrations: [String: MachineMigrationRecord] = [:]
        var machineRuntimeModels: [String: [String: (models: [(id: String, label: String)], updatedAt: Date)]] = [:]
        var runtimeAccountUsage: [String: (json: String, staleAfter: Date)] = [:]
        var runtimeAccountUsageRefreshAt: [String: Date] = [:]
        var machineKeys: [String: (serverId: String, agentId: String)] = [:]
        var machineBroadcastPolicies: [String: String] = [:]
        var machineModelSeenCapability: Set<String> = []
        var latestComputerRelease: (version: String, notesJSON: String)? = nil
    }

    private let lock = NSLock()
    private var storage = State()

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    var machines: [MachineRecord] {
        get { state.machines }
        set { state.machines = newValue }
    }

    var machineStatusVersions: [String: Int] {
        get { state.machineStatusVersions }
        set { state.machineStatusVersions = newValue }
    }

    var machineOnline: [String: Bool] {
        get { state.machineOnline }
        set { state.machineOnline = newValue }
    }

    var computers: [(id: String, serverId: String, name: String, apiKey: String, machineId: String?, revokedAt: Date?, online: Bool, version: String?)] {
        get { state.computers }
        set { state.computers = newValue }
    }

    var computerAttachers: [String: String] {
        get { state.computerAttachers }
        set { state.computerAttachers = newValue }
    }

    var attachedComputers: [String: AttachedComputer] {
        get { state.attachedComputers }
        set { state.attachedComputers = newValue }
    }

    var deletedMachineWorkspaces: Set<String> {
        get { state.deletedMachineWorkspaces }
        set { state.deletedMachineWorkspaces = newValue }
    }

    var machineMigrationCapabilities: [String: Set<String>] {
        get { state.machineMigrationCapabilities }
        set { state.machineMigrationCapabilities = newValue }
    }

    var machineRuntimeDetections: [String: (status: String, unfinished: Set<String>)] {
        get { state.machineRuntimeDetections }
        set { state.machineRuntimeDetections = newValue }
    }

    var machineMigrations: [String: MachineMigrationRecord] {
        get { state.machineMigrations }
        set { state.machineMigrations = newValue }
    }

    var machineRuntimeModels: [String: [String: (models: [(id: String, label: String)], updatedAt: Date)]] {
        get { state.machineRuntimeModels }
        set { state.machineRuntimeModels = newValue }
    }

    var runtimeAccountUsage: [String: (json: String, staleAfter: Date)] {
        get { state.runtimeAccountUsage }
        set { state.runtimeAccountUsage = newValue }
    }

    var runtimeAccountUsageRefreshAt: [String: Date] {
        get { state.runtimeAccountUsageRefreshAt }
        set { state.runtimeAccountUsageRefreshAt = newValue }
    }

    var machineKeys: [String: (serverId: String, agentId: String)] {
        get { state.machineKeys }
        set { state.machineKeys = newValue }
    }

    var machineBroadcastPolicies: [String: String] {
        get { state.machineBroadcastPolicies }
        set { state.machineBroadcastPolicies = newValue }
    }

    var machineModelSeenCapability: Set<String> {
        get { state.machineModelSeenCapability }
        set { state.machineModelSeenCapability = newValue }
    }

    var latestComputerRelease: (version: String, notesJSON: String)? {
        get { state.latestComputerRelease }
        set { state.latestComputerRelease = newValue }
    }
}
