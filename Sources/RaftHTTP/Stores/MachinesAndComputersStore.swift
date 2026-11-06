import Foundation
import Synchronization

/// Owns the machine, Computer and migration rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class MachinesAndComputersStore: Sendable {
    /// Every row this store owns. The mutex isolates this whole value so a
    /// transaction can inspect and update several rows together. Individual
    /// accessors copy or replace only their own field.
    struct State: Sendable {
        var machines: [MachineRecord] = []
        var machineStatusVersions: [String: Int] = [:]
        var machineOnline: [String: Bool] = [:]
        var computers: [(id: String, serverId: String, name: String, apiKey: String, machineId: String?, revokedAt: Date?, online: Bool, version: String?)] = []
        var computerAttachers: [String: String] = [:]
        var attachedComputers: [String: AttachedComputer] = [:]
        var deletedMachineWorkspaces: Set<String> = []
        var machineMigrationCapabilities: [String: Set<String>] = [:]
        var machineRuntimeDetections: [String: (status: String, unfinished: Set<String>)] = [:]
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

    private let storage = Mutex(State())

    /// A copied snapshot of every owned row. Whole-state replacement is retained
    /// for deterministic setup; field setters below update only their own field.
    var state: State {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    var machines: [MachineRecord] {
        get { storage.withLock { $0.machines } }
        set { storage.withLock { $0.machines = newValue } }
    }

    var machineStatusVersions: [String: Int] {
        get { storage.withLock { $0.machineStatusVersions } }
        set { storage.withLock { $0.machineStatusVersions = newValue } }
    }

    var machineOnline: [String: Bool] {
        get { storage.withLock { $0.machineOnline } }
        set { storage.withLock { $0.machineOnline = newValue } }
    }

    var computers: [(id: String, serverId: String, name: String, apiKey: String, machineId: String?, revokedAt: Date?, online: Bool, version: String?)] {
        get { storage.withLock { $0.computers } }
        set { storage.withLock { $0.computers = newValue } }
    }

    var computerAttachers: [String: String] {
        get { storage.withLock { $0.computerAttachers } }
        set { storage.withLock { $0.computerAttachers = newValue } }
    }

    var attachedComputers: [String: AttachedComputer] {
        get { storage.withLock { $0.attachedComputers } }
        set { storage.withLock { $0.attachedComputers = newValue } }
    }

    var deletedMachineWorkspaces: Set<String> {
        get { storage.withLock { $0.deletedMachineWorkspaces } }
        set { storage.withLock { $0.deletedMachineWorkspaces = newValue } }
    }

    var machineMigrationCapabilities: [String: Set<String>] {
        get { storage.withLock { $0.machineMigrationCapabilities } }
        set { storage.withLock { $0.machineMigrationCapabilities = newValue } }
    }

    var machineRuntimeDetections: [String: (status: String, unfinished: Set<String>)] {
        get { storage.withLock { $0.machineRuntimeDetections } }
        set { storage.withLock { $0.machineRuntimeDetections = newValue } }
    }

    var machineRuntimeModels: [String: [String: (models: [(id: String, label: String)], updatedAt: Date)]] {
        get { storage.withLock { $0.machineRuntimeModels } }
        set { storage.withLock { $0.machineRuntimeModels = newValue } }
    }

    var runtimeAccountUsage: [String: (json: String, staleAfter: Date)] {
        get { storage.withLock { $0.runtimeAccountUsage } }
        set { storage.withLock { $0.runtimeAccountUsage = newValue } }
    }

    var runtimeAccountUsageRefreshAt: [String: Date] {
        get { storage.withLock { $0.runtimeAccountUsageRefreshAt } }
        set { storage.withLock { $0.runtimeAccountUsageRefreshAt = newValue } }
    }

    var machineKeys: [String: (serverId: String, agentId: String)] {
        get { storage.withLock { $0.machineKeys } }
        set { storage.withLock { $0.machineKeys = newValue } }
    }

    var machineBroadcastPolicies: [String: String] {
        get { storage.withLock { $0.machineBroadcastPolicies } }
        set { storage.withLock { $0.machineBroadcastPolicies = newValue } }
    }

    var machineModelSeenCapability: Set<String> {
        get { storage.withLock { $0.machineModelSeenCapability } }
        set { storage.withLock { $0.machineModelSeenCapability = newValue } }
    }

    var latestComputerRelease: (version: String, notesJSON: String)? {
        get { storage.withLock { $0.latestComputerRelease } }
        set { storage.withLock { $0.latestComputerRelease = newValue } }
    }

    // MARK: - Injected machine relays and configuration

    var machineMigrationProvisioner: (@Sendable (_ sourceMachineId: String, _ targetMachineId: String) -> String?)? {
        get { storage.withLock { $0.machineMigrationProvisioner } }
        set { storage.withLock { $0.machineMigrationProvisioner = newValue } }
    }

    var machineMigrationLeaseDispatch: (@Sendable (_ machineId: String, _ role: String, _ migrationRef: String) -> Void)? {
        get { storage.withLock { $0.machineMigrationLeaseDispatch } }
        set { storage.withLock { $0.machineMigrationLeaseDispatch = newValue } }
    }

    var machineMigrationStartAgent: (@Sendable (_ agentId: String) async throws -> MachineMigrationAgentStartOutcome)? {
        get { storage.withLock { $0.machineMigrationStartAgent } }
        set { storage.withLock { $0.machineMigrationStartAgent = newValue } }
    }

    var machineMigrationArchiveSourceWorkspace: (@Sendable (_ machineId: String, _ migrationRef: String, _ agentId: String) async throws -> Void)? {
        get { storage.withLock { $0.machineMigrationArchiveSourceWorkspace } }
        set { storage.withLock { $0.machineMigrationArchiveSourceWorkspace = newValue } }
    }

    var builtinModelCatalogCheck: (@Sendable (_ machineId: String, _ modelId: String) -> BuiltinModelCatalogResult)? {
        get { storage.withLock { $0.builtinModelCatalogCheck } }
        set { storage.withLock { $0.builtinModelCatalogCheck = newValue } }
    }

    var agentRuntimeModelsForMachine: (@Sendable (_ machineId: String, _ runtime: String) -> [String]?)? {
        get { storage.withLock { $0.agentRuntimeModelsForMachine } }
        set { storage.withLock { $0.agentRuntimeModelsForMachine = newValue } }
    }

    var runtimeAccountUsageManualRefresh: (@Sendable (String, String) -> RuntimeAccountUsageManualResult)? {
        get { storage.withLock { $0.runtimeAccountUsageManualRefresh } }
        set { storage.withLock { $0.runtimeAccountUsageManualRefresh = newValue } }
    }

    var machineRuntimeModelProbe: (@Sendable (_ machineId: String, _ runtimeId: String, _ force: Bool) -> RuntimeModelProbeOutcome)? {
        get { storage.withLock { $0.machineRuntimeModelProbe } }
        set { storage.withLock { $0.machineRuntimeModelProbe = newValue } }
    }

    var machineRoutedLocally: (@Sendable (_ machineId: String) -> Bool)? {
        get { storage.withLock { $0.machineRoutedLocally } }
        set { storage.withLock { $0.machineRoutedLocally = newValue } }
    }

    var builtinCatalogMode: String {
        get { storage.withLock { $0.builtinCatalogMode } }
        set { storage.withLock { $0.builtinCatalogMode = newValue } }
    }

    var computerAttachEnabledOverride: Bool? {
        get { storage.withLock { $0.computerAttachEnabledOverride } }
        set { storage.withLock { $0.computerAttachEnabledOverride = newValue } }
    }

    var computerUpgradeSender: (@Sendable (_ machineId: String, _ targetVersion: String, _ requestId: String) -> Bool)? {
        get { storage.withLock { $0.computerUpgradeSender } }
        set { storage.withLock { $0.computerUpgradeSender = newValue } }
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
        return storage.withLock { state in
            let machine = state.machines.first { $0.apiKey == apiKey }
            let legacy = state.machineKeys[apiKey]
            var capability = false
            if let agentId, state.machineModelSeenCapability.contains(agentId) {
                capability = true
            }
            if let machine, state.machineModelSeenCapability.contains(machine.id) {
                capability = true
            }
            return MachineCredentialSnapshot(machine: machine, legacy: legacy, modelSeenCapability: capability)
        }
    }

    /// The machine row only, as the runtime-profile and task-writer lookups use it.
    func machine(apiKey: String) -> MachineRecord? {
        return storage.withLock { state in
            return state.machines.first { $0.apiKey == apiKey }
        }
    }

    // MARK: - Machine credential lookups

    /// The Machine a bearer token authenticates: a Machine key, else a live
    /// Computer key's Machine.
    func machineId(forToken token: String) -> String? {
        return storage.withLock { state in
            if let machine = state.machines.first(where: { $0.apiKey == token }) { return machine.id }
            if let computer = state.computers.first(where: { $0.apiKey == token && $0.revokedAt == nil }) {
                return computer.machineId
            }
            return nil
        }
    }

    func machineServerId(machineId: String) -> String? {
        return storage.withLock { state in
            return state.machines.first { $0.id == machineId }?.serverId
        }
    }

    func machineAPIKey(machineId: String) -> String? {
        return storage.withLock { state in
            return state.machines.first { $0.id == machineId }?.apiKey
        }
    }

    /// One increment-and-read: two concurrent bumps never return the same version.
    func bumpMachineStatusVersion(machineId: String) -> Int {
        return storage.withLock { state in
            let next = (state.machineStatusVersions[machineId] ?? 0) + 1
            state.machineStatusVersions[machineId] = next
            return next
        }
    }

    func setMachineOnline(machineId: String, online: Bool) {
        storage.withLock { $0.machineOnline[machineId] = online }
    }

    // MARK: - Server setup reset

    /// Revokes every live Computer of one server and returns how many of them
    /// had a machine attached, matching the reset reply's `revokedComputers`.
    func revokeComputers(serverId: String, now: Date) -> Int {
        return storage.withLock { state in
            var revoked = 0
            for index in state.computers.indices
            where state.computers[index].serverId == serverId && state.computers[index].revokedAt == nil {
                state.computers[index].revokedAt = now
                if state.computers[index].machineId != nil { revoked += 1 }
            }
            return revoked
        }
    }

    // MARK: - Runtime forms, probes and credential liveness

    /// One Computer-owned machine row of one Server, as every runtime-form and
    /// runtime-probe route resolves it.
    func machine(id: String, serverId: String) -> MachineRecord? {
        return storage.withLock { state in
            return state.machines.first { $0.id == id && $0.serverId == serverId }
        }
    }

    /// The probe cache the runtime option sources fall back to.
    func runtimeModels(machineId: String, runtime: String) -> [(id: String, label: String)] {
        return storage.withLock { state in
            return state.machineRuntimeModels[machineId]?[runtime]?.models ?? []
        }
    }

    /// Every Computer's cached `builtin` models. Empty when no machine is
    /// registered, read in one critical section so the two facts agree.
    func builtinRuntimeModels() -> [(id: String, label: String)] {
        return storage.withLock { state in
            guard !state.machines.isEmpty else { return [] }
            return Array(state.machineRuntimeModels.values.flatMap { $0["builtin"]?.models ?? [] })
        }
    }

    /// The `machineId\nworkspace` keys a Computer deleted.
    func deletedWorkspaceKeys() -> Set<String> {
        return storage.withLock { state in
            return state.deletedMachineWorkspaces
        }
    }

    /// Everything the runtime account usage routes read about one machine, in
    /// one critical section: the machine row, its attaching human, whether the
    /// Computer is online and the stored usage snapshot.
    struct RuntimeAccountUsageContext {
        let machine: MachineRecord
        let attacher: String?
        let online: Bool
        let snapshot: (json: String, staleAfter: Date)?
    }

    func runtimeAccountUsageContext(
        machineId: String,
        serverId: String,
        provider: String
    ) -> RuntimeAccountUsageContext? {
        return storage.withLock { state in
            guard let machine = state.machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
                return nil
            }
            return RuntimeAccountUsageContext(
                machine: machine,
                attacher: state.computerAttachers[machineId],
                online: state.machineOnline[machineId] == true,
                snapshot: state.runtimeAccountUsage["\(machineId)\n\(provider)"]
            )
        }
    }

    /// Whether the usage refresh for `key` ran less than `cooldown` seconds ago.
    func runtimeAccountUsageRefreshInCooldown(key: String, now: Date, cooldown: TimeInterval) -> Bool {
        return storage.withLock { state in
            guard let last = state.runtimeAccountUsageRefreshAt[key] else { return false }
            return now.timeIntervalSince(last) < cooldown
        }
    }

    /// The cooldown check and the attempt stamp as one decision: of two
    /// concurrent requested refreshes exactly one claims the slot.
    func claimRuntimeAccountUsageRefresh(key: String, now: Date, cooldown: TimeInterval) -> Bool {
        return storage.withLock { state in
            if let last = state.runtimeAccountUsageRefreshAt[key], now.timeIntervalSince(last) < cooldown {
                return false
            }
            state.runtimeAccountUsageRefreshAt[key] = now
            return true
        }
    }

    /// Stamps a manual refresh attempt that produced no snapshot.
    func recordRuntimeAccountUsageRefreshAttempt(key: String, at: Date) {
        return storage.withLock { state in
            state.runtimeAccountUsageRefreshAt[key] = at
        }
    }

    /// Stores a fresh snapshot and its refresh stamp together.
    func recordRuntimeAccountUsage(key: String, json: String, staleAfter: Date, refreshedAt: Date) {
        return storage.withLock { state in
            state.runtimeAccountUsage[key] = (json, staleAfter)
            state.runtimeAccountUsageRefreshAt[key] = refreshedAt
        }
    }

    /// Whether `token` is a live machine key or a non-revoked Computer key, so
    /// an oversized body can be refused before any parser sees it.
    func machineCredentialIsLive(token: String) -> Bool {
        return storage.withLock { state in
            return state.machines.contains { $0.apiKey == token }
                || state.computers.contains { $0.apiKey == token && $0.revokedAt == nil }
        }
    }

    func computerCredentialIsLive(token: String) -> Bool {
        return storage.withLock { state in
            return state.computers.contains { $0.apiKey == token && $0.revokedAt == nil }
        }
    }

    /// The machine a live Computer credential is attached to, for the
    /// migration target callbacks. A live credential without a machine answers
    /// `nil`, like an unknown one.
    func attachedMachineId(computerKey token: String) -> String? {
        return storage.withLock { state in
            return state.computers.first { $0.apiKey == token && $0.revokedAt == nil }?.machineId
        }
    }

    /// Appends one machine row with a fresh key and returns its id.
    func registerMachine(serverId: String, userId: String, name: String) -> String {
        let id = UUID().uuidString.lowercased()
        storage.withLock { state in
            state.machines.append(MachineRecord(
                id: id,
                serverId: serverId,
                userId: userId,
                name: name,
                description: nil,
                apiKey: MachineCredentialMaterial.machineAPIKeyMaterial()
            ))
        }
        return id
    }

    /// The `/daemon/connect` lookup by machine id.
    func machineCredentialIdentity(id: String) -> MachineCredentialIdentity? {
        return storage.withLock { state in
            guard let machine = state.machines.first(where: { $0.id == id }) else { return nil }
            return MachineCredentialIdentity(machineId: machine.id, serverId: machine.serverId)
        }
    }
}

extension MachinesAndComputersStore {
    func machine(id: String) -> MachineRecord? {
        return storage.withLock { state in
            return state.machines.first { $0.id == id }
        }
    }
}

// MARK: - Computers fleet (ComputersFleetService)

/// Result of one permission-gated machine write.
enum FleetMachineMutation<Value> {
    case missing
    case forbidden
    case applied(Value)
}

enum ComputerAttachOutcome {
    case nameCollision
    case attached(machineId: String, computerId: String)
}

enum LegacyAdoptionOutcome {
    case machineMissing
    case alreadyMigrated
    case adopted(computerId: String, serverId: String, resumed: Bool)
}

extension MachinesAndComputersStore {
    /// Records one deleted machine workspace (`machineId\ndirectoryName`).
    func markWorkspaceDeleted(machineId: String, directoryName: String) {
        storage.withLock { _ = $0.deletedMachineWorkspaces.insert("\(machineId)\n\(directoryName)") }
    }

    /// Lookup, creator/admin gate and description write in one critical
    /// section. A non-nil `description` is trimmed and an empty result clears
    /// the stored value.
    func updateMachineDescription(
        serverId: String,
        machineId: String,
        userId: String,
        role: String,
        description: String?
    ) -> FleetMachineMutation<MachineRecord> {
        return storage.withLock { state in
            guard let index = state.machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
                return .missing
            }
            if role != "owner", role != "admin", state.machines[index].userId != userId {
                return .forbidden
            }
            if let description {
                let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
                state.machines[index].description = trimmed.isEmpty ? nil : trimmed
            }
            return .applied(state.machines[index])
        }
    }

    /// Lookup, creator/admin gate and key replacement in one critical section.
    func rotateMachineKey(
        serverId: String,
        machineId: String,
        userId: String,
        role: String,
        apiKey: String
    ) -> FleetMachineMutation<String> {
        return storage.withLock { state in
            guard let index = state.machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
                return .missing
            }
            if role != "owner", role != "admin", state.machines[index].userId != userId {
                return .forbidden
            }
            state.machines[index].apiKey = apiKey
            return .applied(apiKey)
        }
    }

    /// The name-collision check, the machine registration, the Computer row
    /// and the attacher binding in one critical section, so two concurrent
    /// attaches of one name cannot both pass the collision check.
    func attachComputer(
        serverId: String,
        userId: String,
        name: String,
        machineId: String,
        machineApiKey: String,
        computerId: String,
        computerApiKey: String
    ) -> ComputerAttachOutcome {
        return storage.withLock { state in
            let collides = state.computers.contains { computer in
                computer.revokedAt == nil
                    && computer.serverId == serverId
                    && computer.name == name
                    && state.computerAttachers[computer.machineId ?? ""] == userId
            }
            if collides { return .nameCollision }
            state.machines.append(MachineRecord(
                id: machineId,
                serverId: serverId,
                userId: userId,
                name: name,
                description: nil,
                apiKey: machineApiKey
            ))
            state.computers.append((
                id: computerId,
                serverId: serverId,
                name: name,
                apiKey: computerApiKey,
                machineId: machineId,
                revokedAt: nil,
                online: false,
                version: nil
            ))
            state.computerAttachers[machineId] = userId
            return .attached(machineId: machineId, computerId: computerId)
        }
    }

    /// The legacy-key migration mark and the Computer mint/rotation in one
    /// critical section: only the first caller flips `legacyKeyMigratedAt`, so
    /// concurrent adoption requests collapse into exactly one winner. A row
    /// that was already migrated may only resume its live Computer (with a
    /// rotated credential) when the selector allows it.
    func adoptLegacyMachine(
        machineId: String,
        userId: String,
        name: String,
        allowAlreadyMigratedResume: Bool,
        apiKey: String,
        newComputerId: String,
        now: Date
    ) -> LegacyAdoptionOutcome {
        return storage.withLock { state in
            guard let machineIndex = state.machines.firstIndex(where: { $0.id == machineId }) else {
                return .machineMissing
            }
            let serverId = state.machines[machineIndex].serverId
            let liveComputerIndex = state.computers.firstIndex { computer in
                computer.machineId == machineId && computer.serverId == serverId && computer.revokedAt == nil
            }
            if state.machines[machineIndex].legacyKeyMigratedAt != nil {
                // Roster/daemon selection may retry after the server committed: the
                // setup did not finish locally, so resume the linked Computer with
                // a rotated credential instead of demanding the legacy key again.
                guard allowAlreadyMigratedResume, let liveComputerIndex else { return .alreadyMigrated }
                let live = state.computers[liveComputerIndex]
                state.computers[liveComputerIndex] = (
                    id: live.id,
                    serverId: serverId,
                    name: name,
                    apiKey: apiKey,
                    machineId: machineId,
                    revokedAt: nil,
                    online: live.online,
                    version: live.version
                )
                return .adopted(computerId: live.id, serverId: serverId, resumed: true)
            }
            state.machines[machineIndex].legacyKeyMigratedAt = now
            let computerId: String
            let resumed: Bool
            if let liveComputerIndex {
                let live = state.computers[liveComputerIndex]
                state.computers[liveComputerIndex] = (
                    id: live.id,
                    serverId: serverId,
                    name: name,
                    apiKey: apiKey,
                    machineId: machineId,
                    revokedAt: nil,
                    online: live.online,
                    version: live.version
                )
                computerId = live.id
                resumed = true
            } else {
                computerId = newComputerId
                state.computers.append((
                    id: computerId,
                    serverId: serverId,
                    name: name,
                    apiKey: apiKey,
                    machineId: machineId,
                    revokedAt: nil,
                    online: false,
                    version: nil
                ))
                resumed = false
            }
            state.computerAttachers[machineId] = userId
            return .adopted(computerId: computerId, serverId: serverId, resumed: resumed)
        }
    }

    /// Removes one machine row and revokes every Computer linked to it (the
    /// machine link is cleared, matched case-insensitively) in one critical
    /// section. Returns false when the machine is already gone.
    func removeMachine(serverId: String, machineId: String, now: Date) -> Bool {
        return storage.withLock { state in
            guard let index = state.machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
                return false
            }
            state.machines.remove(at: index)
            for computerIndex in state.computers.indices
            where state.computers[computerIndex].machineId?.caseInsensitiveCompare(machineId) == .orderedSame {
                state.computers[computerIndex].machineId = nil
                state.computers[computerIndex].revokedAt = now
            }
            return true
        }
    }
}

extension MachinesAndComputersStore {
    /// Exact key match wins, then a revoked row with the same 16-character
    /// prefix, then a live row whose key does not verify, then absence; one
    /// critical section.
    func computerCredential(apiKey: String) -> ComputerCredentialLookup {
        return storage.withLock { state in
            let length = MachineCredentialMaterial.computerAPIKeyPrefixLength
            let prefix = String(apiKey.prefix(length))
            let candidates = state.computers.filter { String($0.apiKey.prefix(length)) == prefix }
            if let computer = candidates.first(where: { $0.apiKey == apiKey }) {
                if computer.revokedAt != nil { return .revoked }
                guard let machineId = computer.machineId,
                      state.machines.contains(where: { $0.id == machineId })
                else { return .machineUnlinked }
                return .linked(computerId: computer.id, machineId: machineId)
            }
            if candidates.contains(where: { $0.revokedAt != nil }) { return .revoked }
            if !candidates.isEmpty { return .keyMismatch }
            return .notFound
        }
    }
}
