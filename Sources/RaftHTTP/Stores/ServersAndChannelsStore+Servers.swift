import Foundation

extension ServersAndChannelsStore {
    func isGuestRoleEnabled(serverId: String) -> Bool {
        mutex.withLock { storage in
            return storage.guestRoleServers.contains(serverId)
        }
    }

    func enableGuestRole(serverId: String) {
        _ = mutex.withLock { storage in
            storage.guestRoleServers.insert(serverId)
        }
    }

    func hideHumans(serverId: String) -> Bool {
        mutex.withLock { storage in
            return storage.hideHumansFromMembers[serverId] == true
        }
    }

    func setupPhase(serverId: String, userId: String) -> String {
        mutex.withLock { storage in
            return storage.setupPhases["\(serverId)\n\(userId)"] ?? "not_started"
        }
    }

    /// Raw phase write for fixtures that seed a phase without provenance (the
    /// legacy `complete` row an old build wrote). Production completion goes
    /// through `completeSetup` so the phase and its `normal` reason are one
    /// mutation; a raw write can therefore produce the intended "unknown"
    /// legacy state but must never be used to backfill a reason.
    @discardableResult
    func setSetupPhase(serverId: String, userId: String, phase: String) -> String {
        mutex.withLock { storage in
            storage.setupPhases["\(serverId)\n\(userId)"] = phase
            return phase
        }
    }

    /// Records a NEW terminal completion: `phase = complete` and the `normal`
    /// provenance in one critical section (upstream
    /// services/serverSetupStateService.ts:555-571). A row that is already
    /// `complete` keeps its retained phase, reason and timestamps: a terminal
    /// retry never rewrites provenance, and an old complete without a reason
    /// stays unknown rather than being backfilled with `normal`.
    @discardableResult
    func completeSetup(serverId: String, userId: String) -> String {
        mutex.withLock { storage in
            let key = "\(serverId)\n\(userId)"
            let phase = storage.setupPhases[key] ?? "not_started"
            guard phase != "complete" else { return phase }
            storage.setupPhases[key] = "complete"
            storage.setupCompletionReasons[key] = ServerSetupCompletionReason.normal.rawValue
            return "complete"
        }
    }

    /// `start`: enter `in_progress` and drop any retained provenance in the same
    /// critical section. Upstream `nextStateForAction` returns the state unchanged
    /// for `complete`/`in_progress` and clears `completionReason` only when a row
    /// leaves the pre-flow state (serverSetupStateService.ts:479-489).
    func startSetup(serverId: String, userId: String) {
        mutex.withLock { storage in
            let key = "\(serverId)\n\(userId)"
            let phase = storage.setupPhases[key] ?? "not_started"
            guard phase != "complete", phase != "in_progress" else { return }
            storage.setupPhases[key] = "in_progress"
            storage.setupCompletionReasons.removeValue(forKey: key)
        }
    }

    /// The retained completion reason for one member row. `nil` is unknown, not
    /// `normal`: a legacy complete with no recorded reason owes nothing.
    func setupCompletionReason(serverId: String, userId: String) -> ServerSetupCompletionReason? {
        mutex.withLock { storage in
            storage.setupCompletionReasons["\(serverId)\n\(userId)"]
                .flatMap(ServerSetupCompletionReason.init(rawValue:))
        }
    }

    /// The real first owner acknowledgment, or nil when the owner never pressed
    /// "Let's Go". The legacy `setupHandoffs` marker is deliberately not read.
    func setupHandoffReceipt(serverId: String, ownerId: String) -> SetupHandoffReceipt? {
        mutex.withLock { storage in
            storage.setupHandoffReceipts["\(serverId)\n\(ownerId)"]
        }
    }

    /// Retains the FIRST `(serverId, originalOwnerId)` acknowledgment. The
    /// second and later commands keep the first time (upstream stamps only while
    /// `setup_handoff_acknowledged_at` is null). Returns the retained receipt.
    @discardableResult
    func acknowledgeSetupHandoff(serverId: String, originalOwnerId: String, at date: Date) -> SetupHandoffReceipt {
        mutex.withLock { storage in
            let key = "\(serverId)\n\(originalOwnerId)"
            if let retained = storage.setupHandoffReceipts[key] { return retained }
            let receipt = SetupHandoffReceipt(
                serverId: serverId,
                originalOwnerId: originalOwnerId,
                acknowledgedAt: date
            )
            storage.setupHandoffReceipts[key] = receipt
            return receipt
        }
    }

    /// Clears every setup phase, reason and handoff receipt for one server in one
    /// critical section (the reset rollback). The legacy marker is cleared too.
    func clearSetupState(serverId: String) {
        mutex.withLock { storage in
            let prefix = "\(serverId)\n"
            storage.setupPhases = storage.setupPhases.filter { !$0.key.hasPrefix(prefix) }
            storage.setupCompletionReasons = storage.setupCompletionReasons.filter { !$0.key.hasPrefix(prefix) }
            storage.setupHandoffReceipts = storage.setupHandoffReceipts.filter { $0.value.serverId != serverId }
            storage.setupHandoffs.remove(serverId)
        }
    }

    func enableReadReceipts(serverId: String) {
        _ = mutex.withLock { storage in
            storage.readReceiptsServers.insert(serverId)
        }
    }

    func readReceiptsEnabled(serverId: String) -> Bool {
        mutex.withLock { storage in
            return storage.readReceiptsServers.contains(serverId)
        }
    }

    // MARK: - Server labs

    /// One locked read of a server's lab state, defaulted like the retired
    /// handler's `serverLabsState[serverId] ?? ServerLabsState()`.
    func serverLabs(serverId: String) -> ServerLabsState {
        mutex.withLock { storage in
            return storage.serverLabsState[serverId] ?? ServerLabsState()
        }
    }

    enum LabsApplyResult: Sendable, Equatable {
        case applied(state: ServerLabsState, changed: Bool)
        case versionConflict(currentVersion: Int)
    }

    enum LabEnrollmentApplyResult: Sendable, Equatable {
        case applied(state: ServerLabsState, changed: Bool)
        case versionConflict(currentVersion: Int)
        case accessDisabled
        case labNotOpen
    }

    /// The master-switch decision: expected-version check, toggle and version
    /// bump in one critical section.
    func applyLabsAccess(serverId: String, enabled: Bool, expectedVersion: Int) -> LabsApplyResult {
        mutex.withLock { storage in
            var state = storage.serverLabsState[serverId] ?? ServerLabsState()
            guard expectedVersion == state.version else {
                return .versionConflict(currentVersion: state.version)
            }
            let changed = state.accessEnabled != enabled
            if changed {
                state.accessEnabled = enabled
                state.version += 1
            }
            storage.serverLabsState[serverId] = state
            return .applied(state: state, changed: changed)
        }
    }

    /// The enrollment decision: expected-version, master switch, lab state and
    /// the enrollment write in one critical section, in the published order.
    func applyLabEnrollment(
        serverId: String,
        labKey: String,
        enabled: Bool,
        expectedVersion: Int,
        labOpen: Bool,
        now: Date
    ) -> LabEnrollmentApplyResult {
        mutex.withLock { storage in
            var state = storage.serverLabsState[serverId] ?? ServerLabsState()
            guard expectedVersion == state.version else {
                return .versionConflict(currentVersion: state.version)
            }
            guard state.accessEnabled else { return .accessDisabled }
            guard labOpen else { return .labNotOpen }
            let enrolled = state.enrolled.contains(labKey)
            let changed = enrolled != enabled
            if changed {
                if enabled {
                    state.enrolled.insert(labKey)
                    state.updatedAt[labKey] = now
                } else {
                    state.enrolled.remove(labKey)
                }
                state.version += 1
            }
            storage.serverLabsState[serverId] = state
            return .applied(state: state, changed: changed)
        }
    }

    func isServerDeleted(_ serverId: String) -> Bool {
        mutex.withLock { storage in
            return storage.deletedServerIds.contains(serverId)
        }
    }

    func markServerDeleted(_ serverId: String) {
        _ = mutex.withLock { storage in
            storage.deletedServerIds.insert(serverId)
        }
    }

    // MARK: - Server switcher order

    /// The caller's stored switcher order intersected with their live
    /// memberships, plus the version. The fixed OAuth query runs at the original
    /// decision point inside the Channels critical section.
    func serverOrder(userId: String, memberships: ServerMembershipQuery) -> (ids: [String], version: Int) {
        mutex.withLock { storage in
            let members = Set(memberships.memberServerIds(userId: userId))
            let ordered = Self.sanitizedServerOrder(
                stored: storage.serverSwitcherOrders[userId]?.ids ?? [],
                requested: nil,
                memberIds: members
            )
            return (ordered, storage.serverSwitcherOrders[userId]?.version ?? 0)
        }
    }

    /// Replaces the caller's switcher order. The version moves only when the
    /// sanitized list differs from the stored one; comparing, bumping and
    /// storing are one critical section, so two concurrent patches cannot both
    /// read the same version.
    func updateServerOrder(
        userId: String,
        requested: [String],
        memberships: ServerMembershipQuery
    ) -> (ids: [String], version: Int) {
        mutex.withLock { storage in
            let members = Set(memberships.memberServerIds(userId: userId))
            let stored = storage.serverSwitcherOrders[userId]
            let current = stored?.ids ?? Self.sanitizedServerOrder(stored: [], requested: nil, memberIds: members)
            let ordered = Self.sanitizedServerOrder(stored: stored?.ids ?? [], requested: requested, memberIds: members)
            var version = stored?.version ?? 0
            if ordered != current {
                version += 1
            }
            storage.serverSwitcherOrders[userId] = (ordered, version)
            return (ordered, version)
        }
    }

    /// Requested (or stored) ids the caller still belongs to, de-duplicated in
    /// order, then every remaining membership in sorted order.
    private static func sanitizedServerOrder(
        stored: [String],
        requested: [String]?,
        memberIds: Set<String>
    ) -> [String] {
        let base = requested ?? stored
        var seen = Set<String>()
        var ordered: [String] = []
        for id in base where memberIds.contains(id) && !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        for id in memberIds.sorted() where !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    // MARK: - Server profile reads and writes

    /// Whether the composer resource references (and therefore the apps list)
    /// are enabled for the server.
    func isComposerResourceEnabled(serverId: String) -> Bool {
        mutex.withLock { storage in
            return storage.composerResourceServers.contains(serverId)
        }
    }

    /// Applies the optional human-directory flag and returns the value the
    /// server now has, in one critical section.
    func updateHideHumans(serverId: String, hidden: Bool?) -> Bool {
        mutex.withLock { storage in
            if let hidden {
                storage.hideHumansFromMembers[serverId] = hidden
            }
            return storage.hideHumansFromMembers[serverId] == true
        }
    }

    // MARK: - Onboarding settings

    /// One server row plus one member row, read together.
    struct OnboardingSnapshot: Sendable {
        let agentId: String?
        let greeting: Bool
        let user: UserOnboarding
    }

    /// What `PATCH .../onboarding-settings` writes. `serverChange` is applied
    /// only for an owner or admin; the member row is always written.
    struct OnboardingPatch: Sendable {
        enum Change<Value: Sendable>: Sendable {
            case keep
            case set(Value)
            case clear
        }

        var isAdmin: Bool
        var agentId: Change<String> = .keep
        var greeting: Bool? = nil
        var reminderOptOut: Bool? = nil
        var currentStep: Change<String> = .keep
        /// Wizard step names whose dismissal timestamp is stamped when unset.
        var dismissedSteps: [String] = []
    }

    /// The server and member onboarding rows read in one critical section.
    func onboardingSnapshot(serverId: String, userId: String) -> OnboardingSnapshot {
        mutex.withLock { storage in
            let server = storage.serverOnboardingSettings[serverId] ?? (agentId: nil, greeting: true)
            let user = storage.userOnboardingSettings["\(serverId)\n\(userId)"] ?? UserOnboarding()
            return OnboardingSnapshot(agentId: server.agentId, greeting: server.greeting, user: user)
        }
    }

    /// Makes `agentId` the server's onboarding agent. The greeting flag is kept
    /// (it defaults on), so the read and the write are one critical section.
    func bindOnboardingAgent(serverId: String, agentId: String) {
        mutex.withLock { storage in
            let greeting = storage.serverOnboardingSettings[serverId]?.greeting ?? true
            storage.serverOnboardingSettings[serverId] = (agentId: agentId, greeting: greeting)
        }
    }

    /// The whole onboarding patch as one critical section: the server row (for
    /// an admin) and the member row are read, updated and written together,
    /// and the stored result is returned so the reply reflects exactly it.
    func applyOnboardingPatch(
        serverId: String,
        userId: String,
        patch: OnboardingPatch,
        now: Date
    ) -> OnboardingSnapshot {
        mutex.withLock { storage in
            var server = storage.serverOnboardingSettings[serverId] ?? (agentId: nil, greeting: true)
            if patch.isAdmin {
                switch patch.agentId {
                case .keep: break
                case .clear: server.agentId = nil
                case .set(let agentId): server.agentId = agentId
                }
                if let greeting = patch.greeting {
                    server.greeting = greeting
                }
                storage.serverOnboardingSettings[serverId] = server
            }
            let key = "\(serverId)\n\(userId)"
            var user = storage.userOnboardingSettings[key] ?? UserOnboarding()
            if let optOut = patch.reminderOptOut {
                user.reminderOptOut = optOut
            }
            switch patch.currentStep {
            case .keep: break
            case .clear: user.currentStep = nil
            case .set(let step): user.currentStep = step
            }
            for step in patch.dismissedSteps where user.dismissed[step] == nil {
                user.dismissed[step] = now
            }
            storage.userOnboardingSettings[key] = user
            return OnboardingSnapshot(agentId: server.agentId, greeting: server.greeting, user: user)
        }
    }
}
