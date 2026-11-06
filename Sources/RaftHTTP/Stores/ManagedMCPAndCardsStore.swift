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

    /// Records the agent's login into a service unless one exists. The lookup and
    /// the insert are one critical section, so two concurrent first logins cannot
    /// both report `logged_in`. Returns whether the login already existed.
    func recordAgentIntegrationLogin(key: String, record: AgentIntegrationLoginRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if storage.agentIntegrationLogins[key] != nil { return true }
        storage.agentIntegrationLogins[key] = record
        return false
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

    /// The prepared marketplace install card a prepare/execute request is
    /// about, in one critical section.
    func marketplaceInstallCard(messageId: String) -> MarketplaceInstallCard? {
        lock.lock()
        defer { lock.unlock() }
        return storage.marketplaceInstallCards[messageId]
    }

    /// The prepared integration-registration card, in one critical section.
    func integrationRegisterCard(messageId: String) -> IntegrationRegisterCard? {
        lock.lock()
        defer { lock.unlock() }
        return storage.integrationRegisterCards[messageId]
    }

    /// Inserts one prepared marketplace install card and returns the stored row.
    @discardableResult
    func insertMarketplaceInstallCard(_ card: MarketplaceInstallCard) -> MarketplaceInstallCard {
        lock.lock()
        defer { lock.unlock() }
        storage.marketplaceInstallCards[card.messageId] = card
        return card
    }

    /// Inserts one prepared integration-registration card and returns it.
    @discardableResult
    func insertIntegrationRegisterCard(_ card: IntegrationRegisterCard) -> IntegrationRegisterCard {
        lock.lock()
        defer { lock.unlock() }
        storage.integrationRegisterCards[card.messageId] = card
        return card
    }

    /// Inserts one prepared action-card row.
    func insertActionCardRecord(_ record: ActionCardRecord) {
        lock.lock()
        storage.actionCardRecords[record.messageId] = record
        lock.unlock()
    }

    /// Marks the marketplace card executed and returns the updated row in one
    /// critical section, so two executes cannot both write the result.
    func markMarketplaceInstallCardExecuted(
        messageId: String,
        userId: String,
        resultJSON: String
    ) -> MarketplaceInstallCard? {
        lock.lock()
        defer { lock.unlock() }
        guard var card = storage.marketplaceInstallCards[messageId] else { return nil }
        if card.state != "executed" {
            card.state = "executed"
            card.executedByUserId = userId
            card.resultJSON = resultJSON
            storage.marketplaceInstallCards[messageId] = card
        }
        return card
    }

    /// The integration-registration counterpart of
    /// `markMarketplaceInstallCardExecuted`.
    func markIntegrationRegisterCardExecuted(
        messageId: String,
        userId: String,
        resultJSON: String
    ) -> IntegrationRegisterCard? {
        lock.lock()
        defer { lock.unlock() }
        guard var card = storage.integrationRegisterCards[messageId] else { return nil }
        if card.state != "executed" {
            card.state = "executed"
            card.executedByUserId = userId
            card.resultJSON = resultJSON
            storage.integrationRegisterCards[messageId] = card
        }
        return card
    }

    /// Appends the external-agent action reply event emitted after an execute.
    func appendPendingActionMessageEvent(agentId: String, messageId: String, content: String) {
        lock.lock()
        storage.pendingActionMessageEvents.append((agentId, messageId, content))
        lock.unlock()
    }

    // MARK: - Agent-api idempotency

    /// Outcome of one idempotency-key lookup for an agent-api write.
    enum AgentApiIdempotencyLookup: Sendable, Equatable {
        case none
        case replay(status: Int, body: String)
        case mismatch
    }

    /// The lookup half of the agent-api idempotency contract, in one critical
    /// section and with typed values only, so a service never touches
    /// `HTTPReply` or `[String: Any]`.
    func agentApiIdempotencyLookup(
        agentId: String,
        route: String,
        key: String,
        fingerprint: String,
        now: Date
    ) -> AgentApiIdempotencyLookup {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = storage.agentApiIdempotencyKeys.first(where: {
            $0.agentId == agentId && $0.route == route && $0.key == key
        }), now.timeIntervalSince(existing.createdAt) < Self.agentApiIdempotencyTTL
        else {
            return .none
        }
        guard existing.fingerprint == fingerprint else { return .mismatch }
        return .replay(status: existing.status, body: existing.responseBody)
    }

    /// The store half: replace the row for this (agent, route, key) and keep
    /// the first reply's status and body for an exact replay.
    func storeAgentApiIdempotency(
        agentId: String,
        route: String,
        key: String,
        fingerprint: String,
        status: Int,
        body: String,
        now: Date
    ) {
        guard status == 200 || status == 201 else { return }
        lock.lock()
        defer { lock.unlock() }
        if let index = storage.agentApiIdempotencyKeys.firstIndex(where: {
            $0.agentId == agentId && $0.route == route && $0.key == key
        }) {
            storage.agentApiIdempotencyKeys.remove(at: index)
        }
        storage.agentApiIdempotencyKeys.append(AgentApiIdempotencyRecord(
            agentId: agentId,
            route: route,
            key: key,
            fingerprint: fingerprint,
            status: status,
            responseBody: body,
            createdAt: now
        ))
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

// MARK: - Managed MCP lifecycle: provider connection sections

/// The fields `PATCH /api/provider-connections/:id` may change. A `nil` member
/// leaves the stored value untouched.
struct ProviderConnectionPatch: Sendable, Equatable {
    var name: String?
    var endpointUrl: String?
    var supportsImageInput: Bool?
    /// A non-empty replacement API key (the credential rotates).
    var rotatesCredential: Bool
}

extension ManagedMCPAndCardsStore {
    /// Whether the provider-connections surface is enabled for the server.
    func isProviderConnectionsEnabled(serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.providerConnectionsEnabledServers.contains(serverId)
    }

    /// The server's provider connections, in creation order.
    func providerConnections(serverId: String) -> [ProviderConnection] {
        lock.lock()
        defer { lock.unlock() }
        return storage.providerConnections.filter { $0.serverId == serverId }
    }

    func insertProviderConnection(_ connection: ProviderConnection) {
        lock.lock()
        defer { lock.unlock() }
        storage.providerConnections.append(connection)
    }

    /// Applies a patch in one critical section and answers the stored row, or
    /// `nil` when the connection is not the server's.
    func patchProviderConnection(
        id: String,
        serverId: String,
        patch: ProviderConnectionPatch,
        now: Date
    ) -> ProviderConnection? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.providerConnections.firstIndex(where: { $0.id == id && $0.serverId == serverId }) else {
            return nil
        }
        if let name = patch.name { storage.providerConnections[index].name = name }
        if let endpoint = patch.endpointUrl { storage.providerConnections[index].endpointUrl = endpoint }
        if let supports = patch.supportsImageInput { storage.providerConnections[index].supportsImageInput = supports }
        if patch.rotatesCredential {
            storage.providerConnections[index].credentialVersion += 1
            storage.providerConnections[index].status = "unchecked"
            storage.providerConnections[index].hasCredential = true
        }
        storage.providerConnections[index].updatedAt = now
        return storage.providerConnections[index]
    }

    /// Rotates the credential in one critical section and answers the stored
    /// row, or `nil` when the connection is not the server's.
    func rotateProviderCredential(id: String, serverId: String, now: Date) -> ProviderConnection? {
        patchProviderConnection(
            id: id,
            serverId: serverId,
            patch: ProviderConnectionPatch(rotatesCredential: true),
            now: now
        )
    }

    /// Whether the connection exists and the agent assignments it carries, from
    /// one snapshot.
    func providerAssignments(serverId: String, connectionId: String) -> (known: Bool, assignments: [ProviderAssignment]) {
        lock.lock()
        defer { lock.unlock() }
        let known = storage.providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
        let assignments = storage.providerAssignments.filter { $0.connectionId == connectionId && $0.serverId == serverId }
        return (known, assignments)
    }
}

// MARK: - Managed MCP control plane (ManagedMCPControlPlaneService)

extension ManagedMCPAndCardsStore {
    /// How long an agent-api idempotency key keeps replaying its first reply.
    static let agentApiIdempotencyTTL: TimeInterval = 24 * 60 * 60

    func appendManagedMCPServer(_ record: ManagedMCPServerRecord) {
        lock.lock()
        defer { lock.unlock() }
        storage.managedMCPServers.append(record)
    }

    /// Applies `mutate` to one server row inside the critical section and
    /// returns the stored row, or nil when the row is absent. A throw from
    /// `mutate` keeps the edits it already made (the legacy handler wrote each
    /// member in place and refused part-way) and then propagates.
    func updateManagedMCPServer(
        serverId: String,
        id: String,
        _ mutate: (inout ManagedMCPServerRecord) throws -> Void
    ) rethrows -> ManagedMCPServerRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = storage.managedMCPServers.firstIndex(where: { $0.id == id && $0.serverId == serverId }) else {
            return nil
        }
        var record = storage.managedMCPServers[index]
        defer { storage.managedMCPServers[index] = record }
        try mutate(&record)
        return record
    }

    /// Removes one server row; false when no row matched.
    func removeManagedMCPServer(serverId: String, id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = storage.managedMCPServers.count
        storage.managedMCPServers.removeAll { $0.id == id && $0.serverId == serverId }
        return storage.managedMCPServers.count != before
    }

    /// Result of replacing an agent's assignment set.
    enum ManagedMCPAssignmentWrite: Sendable, Equatable {
        case stored
        case unknownServer
    }

    /// Replaces the whole assignment set of one agent. Every entry must name a
    /// server of `serverId`; the first unknown entry refuses the write and
    /// leaves the stored set untouched.
    func replaceManagedMCPAssignments(
        serverId: String,
        agentId: String,
        entries: [(mcpServerId: String?, enabled: Bool, allowedTools: [String]?)]
    ) -> ManagedMCPAssignmentWrite {
        lock.lock()
        defer { lock.unlock() }
        let serverIds = Set(storage.managedMCPServers.filter { $0.serverId == serverId }.map(\.id))
        var stored: [String: (enabled: Bool, allowedTools: [String]?)] = [:]
        for entry in entries {
            guard let id = entry.mcpServerId, serverIds.contains(id) else { return .unknownServer }
            stored[id] = (entry.enabled, entry.allowedTools)
        }
        storage.managedMCPAssignments[agentId] = stored
        return .stored
    }

    /// Sets one assignment of one agent; unknown when the server row is absent.
    func setManagedMCPAssignment(
        serverId: String,
        agentId: String,
        mcpServerId: String,
        enabled: Bool,
        allowedTools: [String]?
    ) -> ManagedMCPAssignmentWrite {
        lock.lock()
        defer { lock.unlock() }
        guard storage.managedMCPServers.contains(where: { $0.id == mcpServerId && $0.serverId == serverId }) else {
            return .unknownServer
        }
        storage.managedMCPAssignments[agentId, default: [:]][mcpServerId] = (enabled, allowedTools)
        return .stored
    }
}

// MARK: - Agent audience tokens

extension ManagedMCPAndCardsStore {
    /// The audience status of one agent; an agent without an override is
    /// `active`.
    func agentAudienceStatus(agentId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage.agentAudienceStatusOverrides[agentId] ?? "active"
    }

    /// Admits an App token for the `agent\nclient` grant key unless the grant
    /// was revoked, and records the grant as live on first use. The check and
    /// the write are one critical section, so a revocation cannot slip between
    /// them. `false` when the grant is revoked.
    func claimAgentIntegrationGrant(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if storage.agentIntegrationGrants[key] == true { return false }
        storage.agentIntegrationGrants[key] = false
        return true
    }
}
