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
        // Injectable relays and configuration that used to live inline on
        // `EmailLoginDirectory`.
        var machineMigrationProvisioner: (@Sendable (_ sourceMachineId: String, _ targetMachineId: String) -> String?)? = nil
        var machineMigrationLeaseDispatch: (@Sendable (_ machineId: String, _ role: String, _ migrationRef: String) -> Void)? = nil
        var machineMigrationStartAgent: (@Sendable (_ agentId: String) async throws -> MachineMigrationAgentStartOutcome)? = nil
        var machineMigrationArchiveSourceWorkspace: (@Sendable (_ machineId: String, _ migrationRef: String, _ agentId: String) async throws -> Void)? = nil
        var builtinModelCatalogCheck: (@Sendable (_ machineId: String, _ modelId: String) -> BuiltinModelCatalogResult)? = nil
        var agentRuntimeModelsForMachine: (@Sendable (_ machineId: String, _ runtime: String) -> [String]?)? = nil
        var runtimeAccountUsageManualRefresh: (@Sendable (String, String) -> RuntimeAccountUsageManualResult)? = nil
        var machineRuntimeModelProbe: (@Sendable (_ machineId: String, _ runtimeId: String, _ force: Bool) -> RuntimeModelProbeOutcome)? = nil
        var machineRoutedLocally: (@Sendable (_ machineId: String) -> Bool)? = nil
        var builtinCatalogMode: String = "supported"
        var computerAttachEnabledOverride: Bool? = nil
        var computerUpgradeSender: (@Sendable (_ machineId: String, _ targetVersion: String, _ requestId: String) -> Bool)? = nil
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

    // MARK: - Injected machine relays and configuration

    var machineMigrationProvisioner: (@Sendable (_ sourceMachineId: String, _ targetMachineId: String) -> String?)? {
        get { state.machineMigrationProvisioner }
        set { state.machineMigrationProvisioner = newValue }
    }

    var machineMigrationLeaseDispatch: (@Sendable (_ machineId: String, _ role: String, _ migrationRef: String) -> Void)? {
        get { state.machineMigrationLeaseDispatch }
        set { state.machineMigrationLeaseDispatch = newValue }
    }

    var machineMigrationStartAgent: (@Sendable (_ agentId: String) async throws -> MachineMigrationAgentStartOutcome)? {
        get { state.machineMigrationStartAgent }
        set { state.machineMigrationStartAgent = newValue }
    }

    var machineMigrationArchiveSourceWorkspace: (@Sendable (_ machineId: String, _ migrationRef: String, _ agentId: String) async throws -> Void)? {
        get { state.machineMigrationArchiveSourceWorkspace }
        set { state.machineMigrationArchiveSourceWorkspace = newValue }
    }

    var builtinModelCatalogCheck: (@Sendable (_ machineId: String, _ modelId: String) -> BuiltinModelCatalogResult)? {
        get { state.builtinModelCatalogCheck }
        set { state.builtinModelCatalogCheck = newValue }
    }

    var agentRuntimeModelsForMachine: (@Sendable (_ machineId: String, _ runtime: String) -> [String]?)? {
        get { state.agentRuntimeModelsForMachine }
        set { state.agentRuntimeModelsForMachine = newValue }
    }

    var runtimeAccountUsageManualRefresh: (@Sendable (String, String) -> RuntimeAccountUsageManualResult)? {
        get { state.runtimeAccountUsageManualRefresh }
        set { state.runtimeAccountUsageManualRefresh = newValue }
    }

    var machineRuntimeModelProbe: (@Sendable (_ machineId: String, _ runtimeId: String, _ force: Bool) -> RuntimeModelProbeOutcome)? {
        get { state.machineRuntimeModelProbe }
        set { state.machineRuntimeModelProbe = newValue }
    }

    var machineRoutedLocally: (@Sendable (_ machineId: String) -> Bool)? {
        get { state.machineRoutedLocally }
        set { state.machineRoutedLocally = newValue }
    }

    var builtinCatalogMode: String {
        get { state.builtinCatalogMode }
        set { state.builtinCatalogMode = newValue }
    }

    var computerAttachEnabledOverride: Bool? {
        get { state.computerAttachEnabledOverride }
        set { state.computerAttachEnabledOverride = newValue }
    }

    var computerUpgradeSender: (@Sendable (_ machineId: String, _ targetVersion: String, _ requestId: String) -> Bool)? {
        get { state.computerUpgradeSender }
        set { state.computerUpgradeSender = newValue }
    }

    // MARK: - Agent send / delivery credentials

    /// One machine-credential read for the agent send and delivery-ack routes:
    /// the machine row, the legacy key row and the delivery-ack capability all
    /// come from the same critical section.
    struct MachineCredentialSnapshot {
        let machine: MachineRecord?
        let legacy: (serverId: String, agentId: String)?
        let modelSeenCapability: Bool
    }

    func machineCredential(apiKey: String, agentId: String?) -> MachineCredentialSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let machine = storage.machines.first { $0.apiKey == apiKey }
        let legacy = storage.machineKeys[apiKey]
        var capability = false
        if let agentId, storage.machineModelSeenCapability.contains(agentId) {
            capability = true
        }
        if let machine, storage.machineModelSeenCapability.contains(machine.id) {
            capability = true
        }
        return MachineCredentialSnapshot(machine: machine, legacy: legacy, modelSeenCapability: capability)
    }

    /// The machine row only, as the runtime-profile and task-writer lookups use it.
    func machine(apiKey: String) -> MachineRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.machines.first { $0.apiKey == apiKey }
    }
}
