import Foundation

/// One validated `system.cleaner` app-config override.
///
/// The legacy handler stored `NSNumber`/`Bool` values in a `[String: Any]`
/// dictionary. Only two shapes can pass the published validation: `enabled`
/// accepts boolean values (including the `0`/`1` numbers Foundation bridges),
/// and the two interval keys accept integers. Keeping the two cases explicit
/// lets the store own typed state without changing the rendered value: the
/// legacy writer always printed `number.intValue`.
enum AppConfigValue: Sendable, Equatable {
    case boolean(Bool)
    case integer(Int)
}

/// One locked read of an agent's app-config state.
struct AppConfigSnapshot: Sendable, Equatable {
    var revision: Int
    var overrides: [String: AppConfigValue]
}

/// Result of the compare-and-set app-config write. The store decides; the
/// service maps a refusal to its published `RAP_APP_CONFIG_REVISION_STALE` 409.
enum AppConfigPatchResult: Sendable, Equatable {
    case applied(AppConfigSnapshot)
    case revisionStale(current: Int)
}

/// Owns the managed-MCP, action-card and integration rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class ManagedMCPAndCardsStore: @unchecked Sendable {
    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State {
        var managedMCPServers: [ManagedMCPServerRecord] = []
        var managedMCPAssignments: [String: [String: (enabled: Bool, allowedTools: [String]?)]] = [:]
        var actionCardRecords: [String: ActionCardRecord] = [:]
        /// A prepared Marketplace install card. The action payload is rebuilt from
        /// this record on every read, so the message projection never carries a
        /// stale canonical action.
        var marketplaceInstallCards: [String: MarketplaceInstallCard] = [:]
        /// A prepared `integration:register_app` card. The initial client secret
        /// is created at execution time and never lands in card state.
        var integrationRegisterCards: [String: IntegrationRegisterCard] = [:]
        /// One committed agent-api send per (server, agent, idempotencyKey).
        var agentApiSendReceipts: [String: AgentApiSendReceipt] = [:]
        var pendingActionMessageEvents: [(agentId: String, messageId: String, content: String)] = []
        var agentGrantSets: [String: Set<String>] = [:]
        var appConfigOverrides: [String: [String: [String: AppConfigValue]]] = [:]
        var appConfigRevisions: [String: [String: Int]] = [:]
        var agentIntegrationGrants: [String: Bool] = [:]
        var agentAudienceStatusOverrides: [String: String] = [:]
        var agentIntegrationLogins: [String: AgentIntegrationLoginRecord] = [:]
        var providerConnectionsEnabledServers: Set<String> = []
        var providerConnections: [ProviderConnection] = []
        var providerAssignments: [ProviderAssignment] = []
        var agentApiIdempotencyKeys: [AgentApiIdempotencyRecord] = []
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

    var managedMCPServers: [ManagedMCPServerRecord] {
        get { state.managedMCPServers }
        set { state.managedMCPServers = newValue }
    }

    var managedMCPAssignments: [String: [String: (enabled: Bool, allowedTools: [String]?)]] {
        get { state.managedMCPAssignments }
        set { state.managedMCPAssignments = newValue }
    }

    var actionCardRecords: [String: ActionCardRecord] {
        get { state.actionCardRecords }
        set { state.actionCardRecords = newValue }
    }

    var marketplaceInstallCards: [String: MarketplaceInstallCard] {
        get { state.marketplaceInstallCards }
        set { state.marketplaceInstallCards = newValue }
    }

    var integrationRegisterCards: [String: IntegrationRegisterCard] {
        get { state.integrationRegisterCards }
        set { state.integrationRegisterCards = newValue }
    }

    var agentApiSendReceipts: [String: AgentApiSendReceipt] {
        get { state.agentApiSendReceipts }
        set { state.agentApiSendReceipts = newValue }
    }

    var pendingActionMessageEvents: [(agentId: String, messageId: String, content: String)] {
        get { state.pendingActionMessageEvents }
        set { state.pendingActionMessageEvents = newValue }
    }

    var agentGrantSets: [String: Set<String>] {
        get { state.agentGrantSets }
        set { state.agentGrantSets = newValue }
    }

    var appConfigOverrides: [String: [String: [String: AppConfigValue]]] {
        get { state.appConfigOverrides }
        set { state.appConfigOverrides = newValue }
    }

    var appConfigRevisions: [String: [String: Int]] {
        get { state.appConfigRevisions }
        set { state.appConfigRevisions = newValue }
    }

    var agentIntegrationGrants: [String: Bool] {
        get { state.agentIntegrationGrants }
        set { state.agentIntegrationGrants = newValue }
    }

    var agentAudienceStatusOverrides: [String: String] {
        get { state.agentAudienceStatusOverrides }
        set { state.agentAudienceStatusOverrides = newValue }
    }

    var agentIntegrationLogins: [String: AgentIntegrationLoginRecord] {
        get { state.agentIntegrationLogins }
        set { state.agentIntegrationLogins = newValue }
    }

    var providerConnectionsEnabledServers: Set<String> {
        get { state.providerConnectionsEnabledServers }
        set { state.providerConnectionsEnabledServers = newValue }
    }

    var providerConnections: [ProviderConnection] {
        get { state.providerConnections }
        set { state.providerConnections = newValue }
    }

    var providerAssignments: [ProviderAssignment] {
        get { state.providerAssignments }
        set { state.providerAssignments = newValue }
    }

    var agentApiIdempotencyKeys: [AgentApiIdempotencyRecord] {
        get { state.agentApiIdempotencyKeys }
        set { state.agentApiIdempotencyKeys = newValue }
    }

    // MARK: - Action-card execution

    /// One locked read of the card a route is about to authorize. The write
    /// below re-reads under its own lock, so the read is only a snapshot.
    func actionCard(messageId: String) -> ActionCardRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.actionCardRecords[messageId]
    }

    /// Marks the card executed and returns the updated row in one critical
    /// section, so the lookup and the state write cannot interleave with
    /// another request. `nil` means the row vanished between authorization and
    /// the write.
    func markActionCardExecuted(messageId: String, userId: String) -> ActionCardRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard var card = storage.actionCardRecords[messageId] else { return nil }
        if card.state != "executed" {
            card.state = "executed"
            card.executedByUserId = userId
            storage.actionCardRecords[messageId] = card
        }
        return card
    }

    // MARK: - Managed MCP reads

    func managedMCPServers(serverId: String) -> [ManagedMCPServerRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage.managedMCPServers.filter { $0.serverId == serverId }
    }

    func managedMCPServer(id: String, serverId: String) -> ManagedMCPServerRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.managedMCPServers.first { $0.id == id && $0.serverId == serverId }
    }

    // MARK: - Provider connections

    enum ProviderAssignmentLookup {
        case connectionNotFound
        case assignmentNotFound
        case ok
    }

    func providerAssignmentLookup(
        serverId: String,
        connectionId: String,
        agentId: String
    ) -> ProviderAssignmentLookup {
        lock.lock()
        defer { lock.unlock() }
        guard storage.providerConnections.contains(where: { $0.id == connectionId && $0.serverId == serverId }) else {
            return .connectionNotFound
        }
        guard storage.providerAssignments.contains(where: {
            $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId
        }) else {
            return .assignmentNotFound
        }
        return .ok
    }

    /// Removes one assignment under a single lock, the write half of detach.
    @discardableResult
    func removeProviderAssignment(serverId: String, connectionId: String, agentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = storage.providerAssignments.count
        storage.providerAssignments.removeAll {
            $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId
        }
        return storage.providerAssignments.count != before
    }

    enum ProviderConnectionLookup {
        case connectionNotFound
        case found(assignments: [ProviderAssignment])
    }

    func providerConnectionLookup(serverId: String, connectionId: String) -> ProviderConnectionLookup {
        lock.lock()
        defer { lock.unlock() }
        guard storage.providerConnections.contains(where: { $0.id == connectionId && $0.serverId == serverId }) else {
            return .connectionNotFound
        }
        let assignments = storage.providerAssignments.filter {
            $0.connectionId == connectionId && $0.serverId == serverId
        }
        return .found(assignments: assignments)
    }

    /// Removes the connection and every one of its assignments in the same
    /// critical section; the legacy path removed both rows under the directory
    /// lock.
    @discardableResult
    func deleteProviderConnection(serverId: String, connectionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = storage.providerConnections.count
        storage.providerConnections.removeAll { $0.id == connectionId && $0.serverId == serverId }
        storage.providerAssignments.removeAll {
            $0.connectionId == connectionId && $0.serverId == serverId
        }
        return storage.providerConnections.count != before
    }

    // MARK: - Agent app config

    /// One locked read of the revision and the overrides a reply projects.
    ///
    /// The legacy handler read the two dictionaries under the directory lock
    /// and then released it before rendering. Taking both under this store's
    /// lock keeps the reply's pair consistent.
    func appConfigSnapshot(agentId: String, appId: String) -> AppConfigSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AppConfigSnapshot(
            revision: storage.appConfigRevisions[agentId]?[appId] ?? 0,
            overrides: storage.appConfigOverrides[agentId]?[appId] ?? [:]
        )
    }

    /// The compare-and-set app-config write.
    ///
    /// The revision check, the merge and the revision bump are one critical
    /// section, so two concurrent patches with the same expected revision
    /// cannot both commit (the legacy handler held the directory lock across
    /// the same three steps).
    func patchAppConfig(
        agentId: String,
        appId: String,
        expectedRevision: Int,
        set: [String: AppConfigValue],
        unset: [String]
    ) -> AppConfigPatchResult {
        lock.lock()
        defer { lock.unlock() }
        let current = storage.appConfigRevisions[agentId]?[appId] ?? 0
        guard expectedRevision == current else {
            return .revisionStale(current: current)
        }
        var overrides = storage.appConfigOverrides[agentId]?[appId] ?? [:]
        for (key, value) in set { overrides[key] = value }
        for key in unset { overrides.removeValue(forKey: key) }
        storage.appConfigOverrides[agentId, default: [:]][appId] = overrides
        storage.appConfigRevisions[agentId, default: [:]][appId] = current + 1
        return .applied(AppConfigSnapshot(revision: current + 1, overrides: overrides))
    }

    // MARK: - Agent send receipts and the send commit lock

    /// The stored idempotency receipt for one `server\nagent\nkey`.
    func sendReceipt(key: String) -> AgentApiSendReceipt? {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentApiSendReceipts[key]
    }

    func setSendReceipt(_ receipt: AgentApiSendReceipt, key: String) {
        lock.lock()
        storage.agentApiSendReceipts[key] = receipt
        lock.unlock()
    }

    /// The cross-store commit barrier the legacy `sendFreshnessCommitLock`
    /// provided: the freshness gate and the message commit that follows it run
    /// under this one store lock, so two concurrent first replies cannot both
    /// pass the gate before either lands.
    private let sendCommitLock = NSLock()

    func withSendCommit<T>(_ body: () throws -> T) rethrows -> T {
        sendCommitLock.lock()
        defer { sendCommitLock.unlock() }
        return try body()
    }
}
