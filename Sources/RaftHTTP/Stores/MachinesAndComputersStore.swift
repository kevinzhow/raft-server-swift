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

    // MARK: - Machine migration status and cancellation

    /// The migration row the status route publishes: the first row for this
    /// agent in this Server, in the store's own iteration order (the legacy
    /// `values.first` selection).
    func machineMigration(agentId: String, serverId: String) -> MachineMigrationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.machineMigrations.values.first { $0.agentId == agentId && $0.serverId == serverId }
    }

    /// One locked cancel transition for one Computer migration: presence,
    /// revision, terminal-state check and the post-flip decision share the lock
    /// with the write, so two concurrent cancels cannot both pass the revision
    /// gate.
    func cancelMachineMigration(
        agentId: String,
        serverId: String,
        migrationRef: String,
        expectedRevision: Int,
        reason: String,
        now: Date
    ) -> AgentMigrationCancelOutcome<MachineMigrationRecord> {
        lock.lock()
        defer { lock.unlock() }
        guard let candidate = storage.machineMigrations[migrationRef],
              candidate.agentId == agentId,
              candidate.serverId == serverId
        else { return .missing }
        guard candidate.revision == expectedRevision else { return .stale }
        guard !AgentMigrationCancelPolicy.terminalStates.contains(candidate.state) else { return .terminal }
        var migration = candidate
        // Once the flip committed the agent belongs to the target, so the
        // cancellation is target-authoritative even though the agent may still
        // be arriving/starting.
        let postFlip = migration.flippedAt != nil
            || AgentMigrationCancelPolicy.postFlipStates.contains(migration.state)
        migration.state = postFlip ? "canceled_post_flip" : "canceled_pre_flip"
        migration.revision += 1
        migration.canceledAt = now
        migration.cancelReason = reason
        migration.cancelDispatchAttempts = 1
        migration.cancelLastDispatchAt = now
        migration.cancelErrorCode = nil
        migration.cancelGeneration = UUID().uuidString.lowercased()
        migration.cancelTransportGeneration = migration.transportGeneration
        migration.cancelDisposition = postFlip ? "post_flip_target_authoritative" : "pre_flip_source_authoritative"
        migration.cancelSourceAck = nil
        migration.cancelTargetAck = nil
        migration.cancelSourceAckAt = nil
        migration.cancelTargetAckAt = nil
        migration.transportTeardownAt = now
        migration.updatedAt = now
        storage.machineMigrations[migrationRef] = migration
        return .canceled(migration)
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

    // MARK: - Server setup reset

    /// Revokes every live Computer of one server and returns how many of them
    /// had a machine attached, matching the reset reply's `revokedComputers`.
    func revokeComputers(serverId: String, now: Date) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var revoked = 0
        for index in storage.computers.indices
        where storage.computers[index].serverId == serverId && storage.computers[index].revokedAt == nil {
            storage.computers[index].revokedAt = now
            if storage.computers[index].machineId != nil { revoked += 1 }
        }
        return revoked
    }

    // MARK: - Runtime forms, probes and credential liveness

    /// One Computer-owned machine row of one Server, as every runtime-form and
    /// runtime-probe route resolves it.
    func machine(id: String, serverId: String) -> MachineRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.machines.first { $0.id == id && $0.serverId == serverId }
    }

    /// The probe cache the runtime option sources fall back to.
    func runtimeModels(machineId: String, runtime: String) -> [(id: String, label: String)] {
        lock.lock()
        defer { lock.unlock() }
        return storage.machineRuntimeModels[machineId]?[runtime]?.models ?? []
    }

    /// Every Computer's cached `builtin` models. Empty when no machine is
    /// registered, read in one critical section so the two facts agree.
    func builtinRuntimeModels() -> [(id: String, label: String)] {
        lock.lock()
        defer { lock.unlock() }
        guard !storage.machines.isEmpty else { return [] }
        return Array(storage.machineRuntimeModels.values.flatMap { $0["builtin"]?.models ?? [] })
    }

    /// The `machineId\nworkspace` keys a Computer deleted.
    func deletedWorkspaceKeys() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return storage.deletedMachineWorkspaces
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
        lock.lock()
        defer { lock.unlock() }
        guard let machine = storage.machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            return nil
        }
        return RuntimeAccountUsageContext(
            machine: machine,
            attacher: storage.computerAttachers[machineId],
            online: storage.machineOnline[machineId] == true,
            snapshot: storage.runtimeAccountUsage["\(machineId)\n\(provider)"]
        )
    }

    /// Whether the usage refresh for `key` ran less than `cooldown` seconds ago.
    func runtimeAccountUsageRefreshInCooldown(key: String, now: Date, cooldown: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = storage.runtimeAccountUsageRefreshAt[key] else { return false }
        return now.timeIntervalSince(last) < cooldown
    }

    /// The cooldown check and the attempt stamp as one decision: of two
    /// concurrent requested refreshes exactly one claims the slot.
    func claimRuntimeAccountUsageRefresh(key: String, now: Date, cooldown: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = storage.runtimeAccountUsageRefreshAt[key], now.timeIntervalSince(last) < cooldown {
            return false
        }
        storage.runtimeAccountUsageRefreshAt[key] = now
        return true
    }

    /// Stamps a manual refresh attempt that produced no snapshot.
    func recordRuntimeAccountUsageRefreshAttempt(key: String, at: Date) {
        lock.lock()
        defer { lock.unlock() }
        storage.runtimeAccountUsageRefreshAt[key] = at
    }

    /// Stores a fresh snapshot and its refresh stamp together.
    func recordRuntimeAccountUsage(key: String, json: String, staleAfter: Date, refreshedAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        storage.runtimeAccountUsage[key] = (json, staleAfter)
        storage.runtimeAccountUsageRefreshAt[key] = refreshedAt
    }

    /// Whether `token` is a live machine key or a non-revoked Computer key, so
    /// an oversized body can be refused before any parser sees it.
    func machineCredentialIsLive(token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.machines.contains { $0.apiKey == token }
            || storage.computers.contains { $0.apiKey == token && $0.revokedAt == nil }
    }

    func computerCredentialIsLive(token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.computers.contains { $0.apiKey == token && $0.revokedAt == nil }
    }

    /// The `/daemon/connect` lookup by machine id.
    func machineCredentialIdentity(id: String) -> MachineCredentialIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let machine = storage.machines.first(where: { $0.id == id }) else { return nil }
        return MachineCredentialIdentity(machineId: machine.id, serverId: machine.serverId)
    }
}

extension MachinesAndComputersStore {
    func machine(id: String) -> MachineRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.machines.first { $0.id == id }
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
        lock.lock()
        storage.deletedMachineWorkspaces.insert("\(machineId)\n\(directoryName)")
        lock.unlock()
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
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
            return .missing
        }
        if role != "owner", role != "admin", storage.machines[index].userId != userId {
            return .forbidden
        }
        if let description {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            storage.machines[index].description = trimmed.isEmpty ? nil : trimmed
        }
        return .applied(storage.machines[index])
    }

    /// Lookup, creator/admin gate and key replacement in one critical section.
    func rotateMachineKey(
        serverId: String,
        machineId: String,
        userId: String,
        role: String,
        apiKey: String
    ) -> FleetMachineMutation<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
            return .missing
        }
        if role != "owner", role != "admin", storage.machines[index].userId != userId {
            return .forbidden
        }
        storage.machines[index].apiKey = apiKey
        return .applied(apiKey)
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
        lock.lock()
        defer { lock.unlock() }
        let collides = storage.computers.contains { computer in
            computer.revokedAt == nil
                && computer.serverId == serverId
                && computer.name == name
                && storage.computerAttachers[computer.machineId ?? ""] == userId
        }
        if collides { return .nameCollision }
        storage.machines.append(MachineRecord(
            id: machineId,
            serverId: serverId,
            userId: userId,
            name: name,
            description: nil,
            apiKey: machineApiKey
        ))
        storage.computers.append((
            id: computerId,
            serverId: serverId,
            name: name,
            apiKey: computerApiKey,
            machineId: machineId,
            revokedAt: nil,
            online: false,
            version: nil
        ))
        storage.computerAttachers[machineId] = userId
        return .attached(machineId: machineId, computerId: computerId)
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
        lock.lock()
        defer { lock.unlock() }
        guard let machineIndex = storage.machines.firstIndex(where: { $0.id == machineId }) else {
            return .machineMissing
        }
        let serverId = storage.machines[machineIndex].serverId
        let liveComputerIndex = storage.computers.firstIndex { computer in
            computer.machineId == machineId && computer.serverId == serverId && computer.revokedAt == nil
        }
        if storage.machines[machineIndex].legacyKeyMigratedAt != nil {
            // Roster/daemon selection may retry after the server committed: the
            // setup did not finish locally, so resume the linked Computer with
            // a rotated credential instead of demanding the legacy key again.
            guard allowAlreadyMigratedResume, let liveComputerIndex else { return .alreadyMigrated }
            let live = storage.computers[liveComputerIndex]
            storage.computers[liveComputerIndex] = (
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
        storage.machines[machineIndex].legacyKeyMigratedAt = now
        let computerId: String
        let resumed: Bool
        if let liveComputerIndex {
            let live = storage.computers[liveComputerIndex]
            storage.computers[liveComputerIndex] = (
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
            storage.computers.append((
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
        storage.computerAttachers[machineId] = userId
        return .adopted(computerId: computerId, serverId: serverId, resumed: resumed)
    }

    /// Removes one machine row and revokes every Computer linked to it (the
    /// machine link is cleared, matched case-insensitively) in one critical
    /// section. Returns false when the machine is already gone.
    func removeMachine(serverId: String, machineId: String, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.machines.firstIndex(where: { $0.id == machineId && $0.serverId == serverId }) else {
            return false
        }
        storage.machines.remove(at: index)
        for computerIndex in storage.computers.indices
        where storage.computers[computerIndex].machineId?.caseInsensitiveCompare(machineId) == .orderedSame {
            storage.computers[computerIndex].machineId = nil
            storage.computers[computerIndex].revokedAt = now
        }
        return true
    }
}

extension MachinesAndComputersStore {
    /// Exact key match wins, then a revoked row with the same 16-character
    /// prefix, then a live row whose key does not verify, then absence; one
    /// critical section.
    func computerCredential(apiKey: String) -> ComputerCredentialLookup {
        lock.lock()
        defer { lock.unlock() }
        let length = EmailLoginDirectory.computerAPIKeyPrefixLength
        let prefix = String(apiKey.prefix(length))
        let candidates = storage.computers.filter { String($0.apiKey.prefix(length)) == prefix }
        if let computer = candidates.first(where: { $0.apiKey == apiKey }) {
            if computer.revokedAt != nil { return .revoked }
            guard let machineId = computer.machineId,
                  storage.machines.contains(where: { $0.id == machineId })
            else { return .machineUnlinked }
            return .linked(computerId: computer.id, machineId: machineId)
        }
        if candidates.contains(where: { $0.revokedAt != nil }) { return .revoked }
        if !candidates.isEmpty { return .keyMismatch }
        return .notFound
    }
}
