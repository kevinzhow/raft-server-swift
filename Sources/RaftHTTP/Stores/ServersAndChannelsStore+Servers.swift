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

    /// Writes one setup phase and returns the new value in the same critical
    /// section, so the transition reply cannot observe a torn state.
    func setSetupPhase(serverId: String, userId: String, phase: String) -> String {
        mutex.withLock { storage in
            storage.setupPhases["\(serverId)\n\(userId)"] = phase
            return phase
        }
    }

    /// Clears every setup phase and the handoff marker for one server in one
    /// critical section.
    func clearSetupState(serverId: String) {
        mutex.withLock { storage in
            storage.setupPhases = storage.setupPhases.filter { !$0.key.hasPrefix("\(serverId)\n") }
            storage.setupHandoffs.remove(serverId)
        }
    }

    func setSetupHandoff(serverId: String) {
        _ = mutex.withLock { storage in
            storage.setupHandoffs.insert(serverId)
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
