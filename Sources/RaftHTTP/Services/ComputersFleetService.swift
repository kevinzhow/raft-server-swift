import Crypto
import Foundation

/// Fleet capabilities for session auth, realtime delivery, the device-login
/// gate and credential operations. Production binds the actual domain owners.
public struct ComputersFleetDependencies: Sendable {
    /// One minted `sk_agent_*` credential and its row id.
    public struct MintedCredential: Sendable, Equatable {
        public var apiKey: String
        public var credentialId: String

        public init(apiKey: String, credentialId: String) {
            self.apiKey = apiKey
            self.credentialId = credentialId
        }
    }

    public var sessionUserId: @Sendable (String?) -> String?
    public var emitRealtime: @Sendable (_ room: String, _ event: String, _ payload: String?) -> Void
    public var computerAttachEnabled: @Sendable () -> Bool
    public var mintAgentCredential: @Sendable (_ agentId: String, _ scopes: [String], _ name: String) -> MintedCredential
    public var computerCredential: @Sendable (_ apiKey: String) -> ComputerCredentialLookup

    /// Production capabilities retain their owners and read current state per call.
    init(
        auth: AuthCoreService,
        realtime: RealtimeRelayService,
        lifecycle: AgentsLifecycleService,
        agents: AgentsRuntimeStore,
        machines: MachinesAndComputersStore
    ) {
        self.init(
            sessionUserId: { try? auth.authenticate($0) },
            emitRealtime: { realtime.emit($0, $1, $2) },
            computerAttachEnabled: { lifecycle.computerAttachEnabled() },
            mintAgentCredential: { agentId, scopes, name in
                let minted = agents.mintAgentCredential(agentId: agentId, scopes: scopes, name: name)
                return MintedCredential(apiKey: minted.apiKey, credentialId: minted.credentialId)
            },
            computerCredential: { machines.computerCredential(apiKey: $0) }
        )
    }

    public init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        emitRealtime: @escaping @Sendable (String, String, String?) -> Void,
        computerAttachEnabled: @escaping @Sendable () -> Bool,
        mintAgentCredential: @escaping @Sendable (String, [String], String) -> MintedCredential,
        computerCredential: @escaping @Sendable (String) -> ComputerCredentialLookup
    ) {
        self.sessionUserId = sessionUserId
        self.emitRealtime = emitRealtime
        self.computerAttachEnabled = computerAttachEnabled
        self.mintAgentCredential = mintAgentCredential
        self.computerCredential = computerCredential
    }
}

/// The Computer fleet: machine registration surfaces, Computer attach/adoption,
/// runner control and the legacy machine roster.
///
/// The service owns authorization and projection; the machine/Computer rows
/// live in `MachinesAndComputersStore` and the runner bindings in
/// `AgentsRuntimeStore`, each mutation one critical section of its store.
public struct ComputersFleetService: Sendable {
    private let machines: MachinesAndComputersStore
    private let agents: AgentsRuntimeStore
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger
    private let dependencies: ComputersFleetDependencies
    private let now: @Sendable () -> Date

    init(
        machines: MachinesAndComputersStore,
        agents: AgentsRuntimeStore,
        profiles: AuthProfileStore,
        oauth: OAuthLedger,
        dependencies: ComputersFleetDependencies,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.machines = machines
        self.agents = agents
        self.profiles = profiles
        self.oauth = oauth
        self.dependencies = dependencies
        self.now = now
    }

    /// Computer-key resolution for transport adapters, from the machine-owner
    /// rows and their existing exact-key, revocation and linkage predicates.
    public func computerCredential(apiKey: String) -> ComputerCredentialLookup {
        machines.computerCredential(apiKey: apiKey)
    }

    // MARK: - Machine roster

    /// `DELETE /api/servers/:id/machines/:machineId/workspaces/:directoryName`.
    public func deleteMachineWorkspace(
        authorization: String?,
        serverId: String,
        machineId: String,
        directoryName: String
    ) throws -> OkResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ComputersFleetError.serverNotFound
        }
        guard let machine = machine(id: machineId, serverId: serverId) else {
            throw ComputersFleetError.machineNotFoundInServer
        }
        let canManage = role == "owner" || role == "admin" || machine.userId == userId
        let ownsDirectory = agents.state.agentMachineIds[directoryName] == machineId
        guard canManage else { throw ComputersFleetError.workspaceDeleteForbidden }
        guard ownsDirectory,
              let agent = oauth.agentRuntimeInfo(id: directoryName),
              agent.serverId == serverId
        else { throw ComputersFleetError.workspaceNotFound }
        // No physical delete adapter/outcome contract is implemented here. Do not
        // mark the cache/archive or report an unobserved filesystem mutation.
        throw MachineWorkspaceDeleteUnavailable()
    }

    /// `GET /api/servers/:id/machines`.
    public func listServerMachines(authorization: String?, serverId: String) throws -> ServerMachinesResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ComputersFleetError.serverNotFound
        }
        guard role != "guest" else { throw ComputersFleetError.forbidden }
        let snapshot = machines.state
        let assignments = agents.state
        let rows = snapshot.machines.filter { $0.serverId == serverId }
        let latest = snapshot.latestComputerRelease
        let linkedMachineIds = Set(snapshot.computers.compactMap(\.machineId))
        let remoteUpgradeDisabled = assignments.remoteUpgradeDisabledServers.contains(serverId)
        let accountsSnapshot = profiles.accounts
        let memberIds = Set(oauth.memberIdsWithRoles(serverId: serverId).map(\.id))
        // The enclosing business scope supplies a coherent read of both retained
        // owners. Legacy machineOnline Bools never grant live presence.
        let heartbeatFormatter = ISO8601DateFormatter()
        heartbeatFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries = rows.map { machine -> ServerMachineEntry in
            let policy = snapshot.machineBroadcastPolicies[machine.id]
            let linked = linkedMachineIds.contains(machine.id)
            let upgrade: Bool?
            let policyBody: OrderedJSON
            if !linked {
                upgrade = nil
                policyBody = .null
            } else if remoteUpgradeDisabled {
                upgrade = false
                policyBody = Self.broadcastPolicy(eligibility: "no_broadcast", reasonCode: "broadcast_disabled")
            } else {
                upgrade = policy != nil && latest != nil
                policyBody = policy.map(OrderedJSON.raw)
                    ?? Self.broadcastPolicy(eligibility: "ineligible", reasonCode: "policy_row_missing")
            }
            let agentCount = assignments.agentMachineIds.filter { agentId, machineId in
                machineId == machine.id && oauth.agentRuntimeInfo(id: agentId).map { !$0.deleted } == true
            }.count
            let account = accountsSnapshot.values.first { $0.id == machine.userId }
            var creator: ServerMachineCreator?
            if memberIds.contains(machine.userId), let account {
                creator = ServerMachineCreator(
                    id: account.id,
                    name: account.name,
                    displayName: account.displayName,
                    avatarUrl: account.avatarUrl,
                    gravatarHash: Self.sha256Hex(account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                )
            }
            return ServerMachineEntry(
                id: machine.id,
                name: machine.name,
                userId: machine.userId,
                description: machine.description,
                isComputer: linked,
                computerAttachedByCurrentUser: snapshot.computerAttachers[machine.id] == userId,
                agentCount: agentCount,
                creator: creator,
                status: assignments.execution.connections[machine.id].map {
                    $0.serverId == serverId && $0.online
                } == true ? "online" : "offline",
                // Zero is the existing logical counter's initial value, matching
                // Node getMachineStatusVersion; reads never bump it.
                statusVersion: snapshot.machineStatusVersions[machine.id] ?? 0,
                runtimes: machine.runtimes,
                computerUpgradeAvailable: upgrade,
                computerBroadcastPolicy: policyBody,
                runtimeVersions: machine.runtimeVersions,
                runtimeDetection: machine.runtimeDetection,
                hostname: machine.hostname,
                lastHeartbeat: machine.lastSeenAt.map { heartbeatFormatter.string(from: $0) }
            )
        }
        return ServerMachinesResponse(
            machines: entries,
            latestComputerVersion: latest?.version,
            latestComputerReleaseNotesJSON: latest?.notesJSON
        )
    }

    /// `PATCH /api/servers/:id/machines/:machineId`.
    public func patchServerMachine(
        authorization: String?,
        serverId: String,
        machineId: String,
        request: MachineDescriptionRequest
    ) throws -> MachineDescriptionResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ComputersFleetError.notAMember
        }
        switch machines.updateMachineDescription(
            serverId: serverId,
            machineId: machineId,
            userId: userId,
            role: role,
            description: request.description
        ) {
        case .missing:
            throw ComputersFleetError.machineNotFound
        case .forbidden:
            throw ComputersFleetError.forbidden
        case .applied(let machine):
            emitMachineUpdated(serverId: serverId, machineId: machineId)
            return MachineDescriptionResponse(id: machine.id, name: machine.name, description: machine.description)
        }
    }

    /// `POST /api/servers/:id/machines/:machineId/rotate-key`.
    public func rotateServerMachineKey(
        authorization: String?,
        serverId: String,
        machineId: String
    ) throws -> MachineKeyRotationResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ComputersFleetError.notAMember
        }
        switch machines.rotateMachineKey(
            serverId: serverId,
            machineId: machineId,
            userId: userId,
            role: role,
            apiKey: MachineCredentialMaterial.machineAPIKeyMaterial()
        ) {
        case .missing:
            throw ComputersFleetError.machineNotFound
        case .forbidden:
            throw ComputersFleetError.forbidden
        case .applied(let apiKey):
            return MachineKeyRotationResponse(apiKey: apiKey)
        }
    }

    /// `DELETE /api/servers/:id/machines/:machineId`.
    ///
    /// The runtime-profile gate and the profile cleanup are one critical
    /// section of `AgentsRuntimeStore`; the row removal and the Computer
    /// revocation are one critical section of `MachinesAndComputersStore`.
    /// The two stores never lock together, so the sections run in that order:
    /// a refused delete leaves both stores untouched.
    public func deleteServerMachine(
        authorization: String?,
        serverId: String,
        machineId: String
    ) throws -> OkResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ComputersFleetError.notAMember
        }
        guard let machine = machine(id: machineId, serverId: serverId) else {
            throw ComputersFleetError.machineNotFound
        }
        if role != "owner", role != "admin", machine.userId != userId {
            throw ComputersFleetError.forbidden
        }
        switch agents.releaseMachineProfiles(machineId: machineId, agentActive: { [oauth] agentId in
            guard let agent = oauth.agentRuntimeInfo(id: agentId) else { return false }
            return !agent.deleted
        }) {
        case .activeMigration:
            throw ComputersFleetError.machineHasActiveMigration
        case .activeRuntimeProfile:
            throw ComputersFleetError.machineHasActiveRuntimeProfile
        case .released:
            break
        }
        guard machines.removeMachine(serverId: serverId, machineId: machineId, now: now()) else {
            throw ComputersFleetError.machineNotFound
        }
        emitMachineUpdated(serverId: serverId, machineId: machineId)
        return OkResponse()
    }

    /// `POST /api/servers/:id/machines/:machineId/runtimes/rescan`.
    public func machineRuntimeRescan(
        authorization: String?,
        serverId: String,
        machineId: String
    ) throws -> MachineRuntimeRescanResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ComputersFleetError.serverNotFound
        }
        let snapshot = machines.state
        guard let machine = snapshot.machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            throw ComputersFleetError.computerNotFound
        }
        let online = snapshot.machineOnline[machineId] == true
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            throw ComputersFleetError.runtimeRescanForbidden
        }
        guard online else { throw ComputersFleetError.runtimeRescanOffline }
        return MachineRuntimeRescanResponse()
    }

    /// `GET /api/servers/:id/model-label-catalog`.
    public func modelLabelCatalog(authorization: String?, serverId: String) throws -> ModelLabelCatalogResponse {
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ComputersFleetError.notAMember
        }
        let snapshot = machines.state
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let catalog = snapshot.machines.filter { $0.serverId == serverId }.map { machine -> ModelLabelCatalogMachine in
            let runtimes = (snapshot.machineRuntimeModels[machine.id] ?? [:])
                .sorted { $0.key < $1.key }
                .map { runtime, entry in
                    ModelLabelCatalogRuntime(
                        runtime: runtime,
                        models: entry.models.map { ModelLabelCatalogModel(id: $0.id, label: $0.label) },
                        updatedAt: formatter.string(from: entry.updatedAt)
                    )
                }
            return ModelLabelCatalogMachine(machineId: machine.id, runtimes: runtimes)
        }
        return ModelLabelCatalogResponse(machines: catalog)
    }

    // MARK: - Computer attach and adoption

    /// `POST /api/computer/attach`. Mints a `sk_computer_*` principal for a
    /// server Computer. The gate is default-on; the slug resolves the Server in
    /// the body, and only owner/admin hold the manageMachines capability.
    public func attachComputer(authorization: String?, request: ComputerAttachRequest) throws -> ComputerAttachResponse {
        guard dependencies.computerAttachEnabled() else { throw ComputersFleetError.attachDisabled }
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ComputersFleetError.attachAuthRequired
        }
        guard let serverSlug = request.serverSlug, !serverSlug.isEmpty else {
            throw ComputersFleetError.serverSlugRequired
        }
        guard let serverId = oauth.serverIdForSlug(serverSlug),
              let details = oauth.serverDetailsValue(id: serverId),
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else { throw ComputersFleetError.notAuthorized }
        guard role == "owner" || role == "admin" else { throw ComputersFleetError.attachRequiresAdmin }
        let requestedName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = requestedName.isEmpty ? "raft-computer" : requestedName
        let apiKey = MachineCredentialMaterial.computerAPIKeyMaterial()
        switch machines.attachComputer(
            serverId: serverId,
            userId: userId,
            name: name,
            machineId: Self.newId(),
            machineApiKey: MachineCredentialMaterial.machineAPIKeyMaterial(),
            computerId: Self.newId(),
            computerApiKey: apiKey
        ) {
        case .nameCollision:
            throw ComputersFleetError.computerNameCollision
        case .attached(let machineId, let computerId):
            return ComputerAttachResponse(
                apiKey: apiKey,
                serverMachineId: computerId,
                machineId: machineId,
                serverId: serverId,
                serverSlug: details.slug,
                name: name
            )
        }
    }

    /// `POST /api/computer/adopt-legacy`. One-time migration from a legacy
    /// `sk_machine_*` / `sk_daemon_*` daemon to a fresh `sk_computer_*`
    /// principal. Authority depends on the selector: possession of the raw
    /// legacy key, a row from the caller's user-scoped legacy roster, or (with
    /// `registerMachines`) a daemon row on a Server the caller manages. All
    /// three mint a Computer attachment, so all three need the same
    /// owner/admin capability as `/api/computer/attach`.
    public func adoptLegacyComputer(
        authorization: String?,
        request: ComputerAdoptLegacyRequest
    ) throws -> ComputerAdoptResponse {
        guard dependencies.computerAttachEnabled() else { throw ComputersFleetError.attachDisabled }
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ComputersFleetError.adoptAuthRequired
        }
        let hasRawLegacyKey = request.legacyApiKey != nil
        let hasRosterIdentity = request.serverSlug != nil
            && request.legacyMachineId != nil
            && request.apiKeyFingerprint != nil
        let hasDaemonIdentity = request.serverSlug != nil && request.daemonId != nil
        guard hasRawLegacyKey || hasRosterIdentity || hasDaemonIdentity else {
            throw ComputersFleetError.legacyIdentityRequired
        }
        var requestedName: String?
        switch request.name {
        case .absent:
            break
        case .invalid:
            throw ComputersFleetError.nameInvalid
        case .value(let name):
            guard !name.isEmpty, name.count <= 200 else { throw ComputersFleetError.nameInvalid }
            requestedName = name
        }
        if hasRosterIdentity {
            return try adoptByRoster(
                userId: userId,
                serverSlug: request.serverSlug ?? "",
                legacyMachineId: request.legacyMachineId ?? "",
                fingerprint: request.apiKeyFingerprint ?? "",
                requestedName: requestedName
            )
        }
        if hasDaemonIdentity {
            return try adoptByDaemonId(
                userId: userId,
                serverSlug: request.serverSlug ?? "",
                daemonId: request.daemonId ?? "",
                requestedName: requestedName
            )
        }
        return try adoptByRawKey(
            userId: userId,
            rawKey: request.legacyApiKey ?? "",
            requestedName: requestedName
        )
    }

    private func adoptByRawKey(userId: String, rawKey: String, requestedName: String?) throws -> ComputerAdoptResponse {
        // The legacy auth middleware accepts both prefixes, so a real daemon in
        // the wild may still be running on either one.
        guard rawKey.hasPrefix("sk_machine_") || rawKey.hasPrefix("sk_daemon_") else {
            throw ComputersFleetError.legacyKeyInvalid
        }
        guard let matched = machines.state.machines.first(where: { $0.apiKey == rawKey })?.id else {
            throw ComputersFleetError.legacyKeyInvalid
        }
        // Possession is proven by the key itself; replay stays a hard conflict.
        return try adoptMatched(
            userId: userId,
            machineId: matched,
            requestedName: requestedName,
            allowAlreadyMigratedResume: false
        )
    }

    private func adoptByRoster(
        userId: String,
        serverSlug: String,
        legacyMachineId: String,
        fingerprint: String,
        requestedName: String?
    ) throws -> ComputerAdoptResponse {
        guard fingerprint.wholeMatch(of: /^[0-9a-fA-F]{16}$/) != nil else {
            throw ComputersFleetError.legacyKeyInvalid
        }
        guard let serverId = oauth.serverIdForSlug(serverSlug),
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else { throw ComputersFleetError.adoptNotAuthorized }
        // The roster identity is user-scoped: selecting somebody else's row is
        // the same 401 as an unknown key so the roster cannot be probed.
        let matched = machines.state.machines.first { machine in
            machine.id == legacyMachineId
                && machine.serverId == serverId
                && machine.userId == userId
                && machine.apiKeyFingerprint?.lowercased() == fingerprint.lowercased()
        }?.id
        guard let matched else { throw ComputersFleetError.legacyKeyInvalid }
        return try adoptMatched(
            userId: userId,
            machineId: matched,
            requestedName: requestedName,
            allowAlreadyMigratedResume: true
        )
    }

    private func adoptByDaemonId(
        userId: String,
        serverSlug: String,
        daemonId: String,
        requestedName: String?
    ) throws -> ComputerAdoptResponse {
        guard let serverId = oauth.serverIdForSlug(serverSlug),
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else { throw ComputersFleetError.adoptNotAuthorized }
        let managesMachines = role == "owner" || role == "admin"
        guard let row = machine(id: daemonId, serverId: serverId) else {
            // Managers learn the row is missing; everybody else collapses into
            // the capability refusal so the route cannot enumerate identities.
            throw managesMachines
                ? ComputersFleetError.legacyMachineNotFound
                : ComputersFleetError.adoptRequiresAdmin
        }
        if row.userId != userId && !managesMachines {
            throw ComputersFleetError.adoptRequiresAdmin
        }
        return try adoptMatched(
            userId: userId,
            machineId: row.id,
            requestedName: requestedName,
            allowAlreadyMigratedResume: true
        )
    }

    private func adoptMatched(
        userId: String,
        machineId: String,
        requestedName: String?,
        allowAlreadyMigratedResume: Bool
    ) throws -> ComputerAdoptResponse {
        guard let snapshot = machines.state.machines.first(where: { $0.id == machineId }) else {
            throw ComputersFleetError.legacyKeyInvalid
        }
        guard let role = oauth.memberRole(serverId: snapshot.serverId, userId: userId) else {
            throw ComputersFleetError.adoptNotAuthorized
        }
        let managesMachines = role == "owner" || role == "admin"
        if snapshot.userId != userId && !managesMachines {
            throw ComputersFleetError.adoptRequiresAdmin
        }
        let name = Self.adoptedComputerName(requestedName, fallback: snapshot.name)
        let apiKey = MachineCredentialMaterial.computerAPIKeyMaterial()
        switch machines.adoptLegacyMachine(
            machineId: machineId,
            userId: userId,
            name: name,
            allowAlreadyMigratedResume: allowAlreadyMigratedResume,
            apiKey: apiKey,
            newComputerId: Self.newId(),
            now: now()
        ) {
        case .machineMissing:
            throw ComputersFleetError.legacyKeyInvalid
        case .alreadyMigrated:
            throw ComputersFleetError.legacyMachineKeyMigrated
        case .adopted(let computerId, let serverId, let resumed):
            return ComputerAdoptResponse(
                apiKey: apiKey,
                computerId: computerId,
                machineId: machineId,
                serverId: serverId,
                resumed: resumed
            )
        }
    }

    /// `GET /api/computer/legacy-machines`. A daemon-adoption roster scoped to
    /// the caller's own machines on one Server. Unknown, deleted and
    /// non-member servers collapse into one 403 so the roster cannot enumerate
    /// servers, and credentials never leave through this surface.
    public func legacyMachines(
        authorization: String?,
        serverSlug: String?,
        includeAll: Bool
    ) throws -> LegacyMachinesResponse {
        guard dependencies.computerAttachEnabled() else { throw ComputersFleetError.attachDisabled }
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ComputersFleetError.attachAuthRequired
        }
        guard let serverSlug, !serverSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComputersFleetError.serverSlugRequired
        }
        guard let serverId = oauth.serverIdForSlug(serverSlug),
              let details = oauth.serverDetailsValue(id: serverId),
              oauth.memberRole(serverId: serverId, userId: userId) != nil
        else { throw ComputersFleetError.notAuthorized }
        let rows = machines.state.machines
            .filter { machine in
                machine.serverId == serverId
                    && machine.userId == userId
                    && (includeAll || machine.apiKeyFingerprint != nil)
            }
            .sorted { $0.name < $1.name }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries = rows.map { machine in
            LegacyMachineEntry(
                daemonId: machine.id,
                machineName: machine.name,
                hostname: machine.hostname,
                lastSeenAt: machine.lastSeenAt.map { formatter.string(from: $0) },
                hasFingerprint: machine.apiKeyFingerprint != nil,
                legacyKeyMigratedAt: machine.legacyKeyMigratedAt.map { formatter.string(from: $0) },
                apiKeyFingerprint: includeAll ? nil : machine.apiKeyFingerprint
            )
        }
        return LegacyMachinesResponse(serverId: serverId, serverSlug: details.slug, entries: entries)
    }

    // MARK: - Runner control plane

    /// `POST /internal/computer/runners/:agentId/credentials`. A live Computer
    /// mints an agent credential for a runner of its own machine only.
    public func computerMintRunnerCredential(
        authorization: String?,
        agentId: String,
        request: ComputerRunnerCredentialRequest
    ) throws -> ComputerRunnerCredentialResponse {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw ComputersFleetError.invalidComputerCredential
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        guard case .linked(let computerId, let machineId) = dependencies.computerCredential(apiKey) else {
            throw ComputersFleetError.invalidComputerCredential
        }
        guard let computer = machines.state.computers.first(where: { $0.id == computerId }),
              let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted,
              agent.serverId == computer.serverId,
              agents.state.agentMachineIds[agentId] == machineId
        else { throw ComputersFleetError.agentMissing }
        let allowed = ["send", "read", "mentions", "tasks", "reactions", "server", "channels", "knowledge", "mcp", "raftbench"]
        let scopes: [String]
        switch request.scopes {
        case .absent:
            scopes = allowed
        case .invalid:
            throw ComputersFleetError.scopesInvalid(message: "scopes must be an array of capability literals")
        case .list(let list):
            let values = Set(list)
            guard values.allSatisfy({ allowed.contains($0) }) else {
                let expected = allowed.joined(separator: ", ")
                throw ComputersFleetError.scopesInvalid(message: "scopes must each be one of: \(expected)")
            }
            guard !values.isEmpty else { throw ComputersFleetError.scopesEmpty }
            scopes = values.sorted()
        }
        var name = "computer-runner"
        switch request.name {
        case .absent:
            break
        case .invalid:
            throw ComputersFleetError.nameInvalid
        case .value(let text):
            guard !text.isEmpty, text.count <= 200 else { throw ComputersFleetError.nameInvalid }
            name = text
        }
        let minted = dependencies.mintAgentCredential(agentId, scopes, name)
        return ComputerRunnerCredentialResponse(
            credentialId: minted.credentialId,
            apiKey: minted.apiKey,
            scopes: scopes,
            agentId: agentId,
            agentName: agent.name,
            serverId: agent.serverId
        )
    }

    /// `GET /internal/computer/runners`. The §12 control-plane whitelist is
    /// enforced here, in the projection, so no agent record field (session ids,
    /// env vars, runtime config) can ever reach the wire — a client-side filter
    /// would not protect against a server dump bug. Default scope is this
    /// Computer's machine; `?scope=server` keeps the legacy server-wide view.
    public func computerRunners(authorization: String?, scope: String? = nil) throws -> ComputerRunnersResponse {
        let context = try runnerContext(authorization)
        let serverWide = scope == "server"
        let machineByAgent = agents.state.agentMachineIds
        let rows = oauth.serverAgents(serverId: context.serverId)
            .filter { !$0.deleted }
            .sorted { $0.name < $1.name }
            .filter { serverWide || machineByAgent[$0.id] == context.machineId }
            .map { agent in
                ComputerRunnerEntry(
                    agentId: agent.id,
                    name: agent.name,
                    status: agent.status,
                    model: Self.runnerModel(from: agent.runtimeConfigJSON),
                    runtime: agent.runtime
                )
            }
        return ComputerRunnersResponse(runners: rows)
    }

    /// `POST /internal/computer/runners/:agentId/stop`. A Computer stops only a
    /// runner bound to its own machine on its own Server; anything else answers
    /// the uniform missing-agent 404 so other machines' and servers' agents
    /// cannot be probed.
    public func computerStopRunner(authorization: String?, agentId: String) throws -> ComputerRunnerStopResponse {
        let context = try runnerContext(authorization)
        guard let agent = oauth.agentRuntimeInfo(id: agentId),
              !agent.deleted,
              agent.serverId == context.serverId
        else { throw ComputersFleetError.agentMissing }
        guard agents.stopRunner(agentId: agentId, machineId: context.machineId) else {
            throw ComputersFleetError.agentMissing
        }
        return ComputerRunnerStopResponse(agentId: agentId)
    }

    /// `DELETE /internal/computer/runners/:agentId/credentials/:credentialId`.
    /// Same machine binding as the stop surface: another machine's runner is a
    /// uniform missing-agent 404, never a credential oracle.
    public func computerRevokeRunnerCredential(
        authorization: String?,
        agentId: String,
        credentialId: String
    ) throws -> ComputerRunnerCredentialRevokeResponse {
        let context = try runnerContext(authorization)
        guard let agent = oauth.agentRuntimeInfo(id: agentId),
              !agent.deleted,
              agent.serverId == context.serverId
        else { throw ComputersFleetError.agentMissing }
        switch agents.revokeRunnerCredential(
            agentId: agentId,
            machineId: context.machineId,
            credentialId: credentialId,
            now: now()
        ) {
        case .notBound:
            throw ComputersFleetError.agentMissing
        case .credentialMissing:
            throw ComputersFleetError.credentialMissing
        case .revoked(let revokedCredentialId):
            return ComputerRunnerCredentialRevokeResponse(
                agentId: agentId,
                credentialId: revokedCredentialId,
                revoked: true
            )
        }
    }

    // MARK: - Computer controls

    /// `POST /api/servers/:id/machines/:machineId/computer/:action`.
    public func computerAction(
        authorization: String?,
        serverId: String,
        machineId: String,
        action: String,
        request: ComputerActionRequest
    ) throws -> ComputerActionResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ComputersFleetError.notAMember
        }
        guard role == "owner" || role == "admin" else { throw ComputersFleetError.forbidden }
        guard ["restart", "start", "stop", "upgrade"].contains(action) else {
            throw ComputersFleetError.unknownAction
        }
        if action == "upgrade" {
            guard !agents.state.remoteUpgradeDisabledServers.contains(serverId) else {
                throw ComputersFleetError.remoteUpgradeDisabled
            }
            let target = request.targetVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !target.isEmpty else { throw ComputersFleetError.invalidTargetVersion }
        }
        let snapshot = machines.state
        let machineExists = snapshot.machines.contains { $0.id == machineId && $0.serverId == serverId }
        let linked = snapshot.computers.filter { candidate in
            candidate.serverId == serverId
                && candidate.machineId == machineId
                && candidate.revokedAt == nil
        }
        let computer = linked.first { $0.online } ?? linked.first
        guard machineExists else { throw ComputersFleetError.machineNotFound }
        guard let computer else { throw ComputersFleetError.notAComputer }
        guard computer.online else { throw ComputersFleetError.computerOffline }
        guard let version = computer.version, !version.isEmpty else {
            throw ComputersFleetError.computerControlUnsupported
        }
        let requestId = Self.newId()
        if action == "upgrade" {
            let target = request.targetVersion ?? ""
            if let sender = snapshot.computerUpgradeSender, !sender(machineId, target, requestId) {
                throw ComputersFleetError.computerOffline
            }
        }
        return ComputerActionResponse(
            action: action,
            requestId: requestId,
            operationId: Self.newId(),
            computerVersion: version
        )
    }

    /// `POST /api/servers/:id/machines/:machineId/computer-lifecycle-operations`.
    ///
    /// The body is validated before the session is read, exactly as the
    /// published route does: a malformed request is a 400 even without a token.
    public func computerLifecycleOperation(
        authorization: String?,
        serverId: String,
        machineId: String,
        request: ComputerLifecycleRequest
    ) throws -> ComputerLifecycleOperationResponse {
        guard let action = request.action,
              ["start", "stop", "restart", "upgrade"].contains(action)
        else { throw ComputersFleetError.lifecycleUnknownAction }
        guard let operationId = request.operationId, ServerScope.isUUID(operationId) else {
            throw ComputersFleetError.invalidOperationId
        }
        guard let parentOperationId = request.parentOperationId, ServerScope.isUUID(parentOperationId) else {
            throw ComputersFleetError.invalidParentOperationId
        }
        let targetVersion = request.targetVersion
        if action == "upgrade" {
            guard !agents.state.remoteUpgradeDisabledServers.contains(serverId) else {
                throw ComputersFleetError.lifecycleBroadcastDisabled
            }
            if let targetVersion, targetVersion.wholeMatch(of: /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/) == nil {
                throw ComputersFleetError.lifecycleInvalidTargetVersion
            }
        } else if targetVersion != nil {
            throw ComputersFleetError.lifecycleInvalidTargetVersion
        }
        if request.completionModePresent {
            guard action == "upgrade", request.completionMode == "legacy_k_promoted" else {
                throw ComputersFleetError.invalidCompletionMode
            }
        }
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ComputersFleetError.serverNotFound
        }
        let snapshot = machines.state
        guard let machine = snapshot.machines.first(where: { $0.id == machineId && $0.serverId == serverId }) else {
            throw ComputersFleetError.machineNotFoundInServer
        }
        let computer = snapshot.computers.first {
            $0.machineId == machineId && $0.serverId == serverId && $0.revokedAt == nil
        }
        let online = snapshot.machineOnline[machineId] == true || computer?.online == true
        guard role == "owner" || role == "admin" || machine.userId == userId else {
            throw ComputersFleetError.lifecycleForbidden
        }
        guard computer != nil else { throw ComputersFleetError.lifecycleNotAComputer }
        if action == "start", online { throw ComputersFleetError.computerAlreadyOnline }
        if action != "start", !online { throw ComputersFleetError.lifecycleComputerNotOnline }
        var resolvedTarget = targetVersion
        if action == "upgrade", resolvedTarget == nil {
            guard let latest = machines.state.latestComputerRelease?.version else {
                throw ComputersFleetError.computerUpgradeUnavailable
            }
            resolvedTarget = latest
        }
        if request.completionModePresent { throw ComputersFleetError.lifecycleCompletionReadyPending }
        return ComputerLifecycleOperationResponse(
            operationId: operationId,
            parentOperationId: parentOperationId,
            serverId: serverId,
            machineId: machineId,
            actorUserId: userId,
            action: action,
            targetVersion: resolvedTarget
        )
    }

    // MARK: - Helpers

    private func requireUser(_ authorization: String?) throws -> String {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ComputersFleetError.unauthorized
        }
        return userId
    }

    private func machine(id: String, serverId: String) -> MachineRecord? {
        machines.state.machines.first { $0.id == id && $0.serverId == serverId }
    }

    /// Resolves the Computer behind a `sk_computer_*` bearer to its attached
    /// machine. A revoked, unknown or machine-unlinked credential is the 401.
    private func runnerContext(
        _ authorization: String?
    ) throws -> (computerId: String, serverId: String, machineId: String) {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            throw ComputersFleetError.invalidComputerCredential
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        let snapshot = machines.state
        guard let computer = snapshot.computers.first(where: { $0.apiKey == apiKey && $0.revokedAt == nil }),
              let machineId = computer.machineId,
              snapshot.machines.contains(where: { $0.id == machineId })
        else { throw ComputersFleetError.invalidComputerCredential }
        return (computer.id, computer.serverId, machineId)
    }

    private func emitMachineUpdated(serverId: String, machineId: String) {
        let payload = OrderedJSON.object([
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("machineId", machineId),
        ]).render()
        dependencies.emitRealtime("server:\(serverId)", "machine:updated", payload)
    }

    private static func newId() -> String {
        UUID().uuidString.lowercased()
    }

    private static func broadcastPolicy(eligibility: String, reasonCode: String) -> OrderedJSON {
        .object([
            OrderedJSONField("eligibility", eligibility),
            OrderedJSONField("targetVersion", .null),
            OrderedJSONField("policyRevision", .null),
            OrderedJSONField("reasonCode", reasonCode),
        ])
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `sha256(apiKey)` hex, first 16 characters — the wire identity the legacy
    /// daemon also writes into its local `owner.json`, so the roster picker and
    /// adoption intersect on the same value.
    static func apiKeyFingerprint(_ apiKey: String) -> String {
        String(sha256Hex(apiKey).prefix(16))
    }

    static func adoptedComputerName(_ supplied: String?, fallback: String) -> String {
        if let supplied {
            let trimmed = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count <= 200 { return trimmed }
        }
        if !fallback.isEmpty, fallback.count <= 200 { return fallback }
        return "raft-computer"
    }

    /// The `model` the runner whitelist publishes: a string, or the `id` of a
    /// structured model; anything else (or unreadable config) is empty.
    static func runnerModel(from runtimeConfigJSON: String?) -> String {
        guard let runtimeConfigJSON,
              let config = try? JSONDecoder().decode(RunnerRuntimeConfig.self, from: Data(runtimeConfigJSON.utf8))
        else { return "" }
        return config.model
    }

    private struct RunnerRuntimeConfig: Decodable {
        let model: String

        private enum CodingKeys: String, CodingKey { case model }
        private struct Structured: Decodable { let id: String }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? container.decode(String.self, forKey: .model) {
                model = text
            } else if let structured = try? container.decode(Structured.self, forKey: .model) {
                model = structured.id
            } else {
                model = ""
            }
        }
    }
}
