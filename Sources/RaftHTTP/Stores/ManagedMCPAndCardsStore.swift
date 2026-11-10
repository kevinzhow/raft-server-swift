import Foundation
import RaftShared
import Synchronization

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
final class ManagedMCPAndCardsStore: Sendable {
    /// Every owned row is a checked value. One Mutex borrow covers a transaction
    /// across tables; read accessors return independent value snapshots.
    struct State: Sendable {
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
        /// Encrypted business facts, keyed by globally unique connection ID; never live configuration.
        var providerCredentials: [String: ProviderCredentialEnvelope] = [:]
        var providerAssignments: [ProviderAssignment] = []
        var agentApiIdempotencyKeys: [AgentApiIdempotencyRecord] = []
    }

    let storage = TransactionalState(State())

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    var managedMCPServers: [ManagedMCPServerRecord] {
        get { storage.withLock { $0.managedMCPServers } }
        set { storage.withLock { $0.managedMCPServers = newValue } }
    }

    var managedMCPAssignments: [String: [String: (enabled: Bool, allowedTools: [String]?)]] {
        get { storage.withLock { $0.managedMCPAssignments } }
        set { storage.withLock { $0.managedMCPAssignments = newValue } }
    }

    var actionCardRecords: [String: ActionCardRecord] {
        get { storage.withLock { $0.actionCardRecords } }
        set { storage.withLock { $0.actionCardRecords = newValue } }
    }

    var marketplaceInstallCards: [String: MarketplaceInstallCard] {
        get { storage.withLock { $0.marketplaceInstallCards } }
        set { storage.withLock { $0.marketplaceInstallCards = newValue } }
    }

    var integrationRegisterCards: [String: IntegrationRegisterCard] {
        get { storage.withLock { $0.integrationRegisterCards } }
        set { storage.withLock { $0.integrationRegisterCards = newValue } }
    }

    var agentApiSendReceipts: [String: AgentApiSendReceipt] {
        get { storage.withLock { $0.agentApiSendReceipts } }
        set { storage.withLock { $0.agentApiSendReceipts = newValue } }
    }

    var pendingActionMessageEvents: [(agentId: String, messageId: String, content: String)] {
        get { storage.withLock { $0.pendingActionMessageEvents } }
        set { storage.withLock { $0.pendingActionMessageEvents = newValue } }
    }

    var agentGrantSets: [String: Set<String>] {
        get { storage.withLock { $0.agentGrantSets } }
        set { storage.withLock { $0.agentGrantSets = newValue } }
    }

    var appConfigOverrides: [String: [String: [String: AppConfigValue]]] {
        get { storage.withLock { $0.appConfigOverrides } }
        set { storage.withLock { $0.appConfigOverrides = newValue } }
    }

    var appConfigRevisions: [String: [String: Int]] {
        get { storage.withLock { $0.appConfigRevisions } }
        set { storage.withLock { $0.appConfigRevisions = newValue } }
    }

    var agentIntegrationGrants: [String: Bool] {
        get { storage.withLock { $0.agentIntegrationGrants } }
        set { storage.withLock { $0.agentIntegrationGrants = newValue } }
    }

    var agentAudienceStatusOverrides: [String: String] {
        get { storage.withLock { $0.agentAudienceStatusOverrides } }
        set { storage.withLock { $0.agentAudienceStatusOverrides = newValue } }
    }

    var agentIntegrationLogins: [String: AgentIntegrationLoginRecord] {
        get { storage.withLock { $0.agentIntegrationLogins } }
        set { storage.withLock { $0.agentIntegrationLogins = newValue } }
    }

    /// Records the agent's login into a service unless one exists. The lookup and
    /// the insert are one critical section, so two concurrent first logins cannot
    /// both report `logged_in`. Returns whether the login already existed.
    func recordAgentIntegrationLogin(key: String, record: AgentIntegrationLoginRecord) -> Bool {
        return storage.withLock { ledgerState in
            if ledgerState.agentIntegrationLogins[key] != nil { return true }
            ledgerState.agentIntegrationLogins[key] = record
            return false
        }
    }

    var providerConnectionsEnabledServers: Set<String> {
        get { storage.withLock { $0.providerConnectionsEnabledServers } }
        set { storage.withLock { $0.providerConnectionsEnabledServers = newValue } }
    }

    var providerConnections: [ProviderConnection] {
        get { storage.withLock { $0.providerConnections } }
        set { storage.withLock { $0.providerConnections = newValue } }
    }

    var providerAssignments: [ProviderAssignment] {
        get { storage.withLock { $0.providerAssignments } }
        set { storage.withLock { $0.providerAssignments = newValue } }
    }

    var agentApiIdempotencyKeys: [AgentApiIdempotencyRecord] {
        get { storage.withLock { $0.agentApiIdempotencyKeys } }
        set { storage.withLock { $0.agentApiIdempotencyKeys = newValue } }
    }

    // MARK: - Action-card execution

    /// One locked read of the card a route is about to authorize. The write
    /// below re-reads under its own lock, so the read is only a snapshot.
    func actionCard(messageId: String) -> ActionCardRecord? {
        return storage.withLock { ledgerState in
            return ledgerState.actionCardRecords[messageId]
        }
    }

    /// Marks the card executed and returns the updated row in one critical
    /// section, so the lookup and the state write cannot interleave with
    /// another request. `nil` means the row vanished between authorization and
    /// the write.
    func markActionCardExecuted(messageId: String, userId: String) -> ActionCardRecord? {
        return storage.withLock { ledgerState in
            guard var card = ledgerState.actionCardRecords[messageId] else { return nil }
            if card.state != "executed" {
                card.state = "executed"
                card.executedByUserId = userId
                ledgerState.actionCardRecords[messageId] = card
            }
            return card
        }
    }

    /// The prepared marketplace install card a prepare/execute request is
    /// about, in one critical section.
    func marketplaceInstallCard(messageId: String) -> MarketplaceInstallCard? {
        return storage.withLock { ledgerState in
            return ledgerState.marketplaceInstallCards[messageId]
        }
    }

    /// The prepared integration-registration card, in one critical section.
    func integrationRegisterCard(messageId: String) -> IntegrationRegisterCard? {
        return storage.withLock { ledgerState in
            return ledgerState.integrationRegisterCards[messageId]
        }
    }

    /// Inserts one prepared marketplace install card and returns the stored row.
    @discardableResult
    func insertMarketplaceInstallCard(_ card: MarketplaceInstallCard) -> MarketplaceInstallCard {
        return storage.withLock { ledgerState in
            ledgerState.marketplaceInstallCards[card.messageId] = card
            return card
        }
    }

    /// Inserts one prepared integration-registration card and returns it.
    @discardableResult
    func insertIntegrationRegisterCard(_ card: IntegrationRegisterCard) -> IntegrationRegisterCard {
        return storage.withLock { ledgerState in
            ledgerState.integrationRegisterCards[card.messageId] = card
            return card
        }
    }

    /// Inserts one prepared action-card row.
    func insertActionCardRecord(_ record: ActionCardRecord) {
        storage.withLock { ledgerState in
            ledgerState.actionCardRecords[record.messageId] = record
        }
    }

    /// Marks the marketplace card executed and returns the updated row in one
    /// critical section, so two executes cannot both write the result.
    func markMarketplaceInstallCardExecuted(
        messageId: String,
        userId: String,
        resultJSON: String
    ) -> MarketplaceInstallCard? {
        return storage.withLock { ledgerState in
            guard var card = ledgerState.marketplaceInstallCards[messageId] else { return nil }
            if card.state != "executed" {
                card.state = "executed"
                card.executedByUserId = userId
                card.resultJSON = resultJSON
                ledgerState.marketplaceInstallCards[messageId] = card
            }
            return card
        }
    }

    /// The integration-registration counterpart of
    /// `markMarketplaceInstallCardExecuted`.
    func markIntegrationRegisterCardExecuted(
        messageId: String,
        userId: String,
        resultJSON: String
    ) -> IntegrationRegisterCard? {
        return storage.withLock { ledgerState in
            guard var card = ledgerState.integrationRegisterCards[messageId] else { return nil }
            if card.state != "executed" {
                card.state = "executed"
                card.executedByUserId = userId
                card.resultJSON = resultJSON
                ledgerState.integrationRegisterCards[messageId] = card
            }
            return card
        }
    }

    /// Appends the external-agent action reply event emitted after an execute.
    func appendPendingActionMessageEvent(agentId: String, messageId: String, content: String) {
        storage.withLock { ledgerState in
            ledgerState.pendingActionMessageEvents.append((agentId, messageId, content))
        }
    }

    /// Removes and returns the action reply events queued for one agent, in
    /// queue order, in one critical section so two concurrent drains can never
    /// both receive the same event.
    func takePendingActionMessageEvents(agentId: String) -> [(agentId: String, messageId: String, content: String)] {
        return storage.withLock { ledgerState in
            let taken = ledgerState.pendingActionMessageEvents.filter { $0.agentId == agentId }
            ledgerState.pendingActionMessageEvents.removeAll { $0.agentId == agentId }
            return taken
        }
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
        return storage.withLock { ledgerState in
            guard let existing = ledgerState.agentApiIdempotencyKeys.first(where: {
                $0.agentId == agentId && $0.route == route && $0.key == key
            }), now.timeIntervalSince(existing.createdAt) < Self.agentApiIdempotencyTTL
            else {
                return .none
            }
            guard existing.fingerprint == fingerprint else { return .mismatch }
            return .replay(status: existing.status, body: existing.responseBody)
        }
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
        storage.withLock { ledgerState in
            if let index = ledgerState.agentApiIdempotencyKeys.firstIndex(where: {
                $0.agentId == agentId && $0.route == route && $0.key == key
            }) {
                ledgerState.agentApiIdempotencyKeys.remove(at: index)
            }
            ledgerState.agentApiIdempotencyKeys.append(AgentApiIdempotencyRecord(
                agentId: agentId,
                route: route,
                key: key,
                fingerprint: fingerprint,
                status: status,
                responseBody: body,
                createdAt: now
            ))
        }
    }

    // MARK: - Managed MCP reads

    func managedMCPServers(serverId: String) -> [ManagedMCPServerRecord] {
        return storage.withLock { ledgerState in
            return ledgerState.managedMCPServers.filter { $0.serverId == serverId }
        }
    }

    func managedMCPServer(id: String, serverId: String) -> ManagedMCPServerRecord? {
        return storage.withLock { ledgerState in
            return ledgerState.managedMCPServers.first { $0.id == id && $0.serverId == serverId }
        }
    }

    // MARK: - Provider connections

    enum ProviderAssignmentLookup: Sendable {
        case connectionNotFound
        case assignmentNotFound
        case ok
    }

    func providerAssignmentLookup(
        serverId: String,
        connectionId: String,
        agentId: String
    ) -> ProviderAssignmentLookup {
        return storage.withLock { ledgerState in
            guard ledgerState.providerConnections.contains(where: { $0.id == connectionId && $0.serverId == serverId }) else {
                return .connectionNotFound
            }
            guard ledgerState.providerAssignments.contains(where: {
                $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId
            }) else {
                return .assignmentNotFound
            }
            return .ok
        }
    }

    /// Removes one assignment under a single lock, the write half of detach.
    @discardableResult
    func removeProviderAssignment(serverId: String, connectionId: String, agentId: String) -> Bool {
        return storage.withLock { ledgerState in
            let before = ledgerState.providerAssignments.count
            ledgerState.providerAssignments.removeAll {
                $0.connectionId == connectionId && $0.serverId == serverId && $0.agentId == agentId
            }
            return ledgerState.providerAssignments.count != before
        }
    }

    enum ProviderConnectionLookup: Sendable {
        case connectionNotFound
        case found(assignments: [ProviderAssignment])
    }

    func providerConnectionLookup(serverId: String, connectionId: String) -> ProviderConnectionLookup {
        return storage.withLock { ledgerState in
            guard ledgerState.providerConnections.contains(where: { $0.id == connectionId && $0.serverId == serverId }) else {
                return .connectionNotFound
            }
            let assignments = ledgerState.providerAssignments.filter {
                $0.connectionId == connectionId && $0.serverId == serverId
            }
            return .found(assignments: assignments)
        }
    }

    /// Removes the connection and every one of its assignments in the same
    /// critical section; the legacy path removed both rows under the directory
    /// lock.
    @discardableResult
    func deleteProviderConnection(serverId: String, connectionId: String) -> Bool {
        return storage.withLock { ledgerState in
            let before = ledgerState.providerConnections.count
            ledgerState.providerConnections.removeAll { $0.id == connectionId && $0.serverId == serverId }
            ledgerState.providerAssignments.removeAll {
                $0.connectionId == connectionId && $0.serverId == serverId
            }
            return ledgerState.providerConnections.count != before
        }
    }

    // MARK: - Agent app config

    /// One locked read of the revision and the overrides a reply projects.
    ///
    /// The legacy handler read the two dictionaries under the directory lock
    /// and then released it before rendering. Taking both under this store's
    /// lock keeps the reply's pair consistent.
    func appConfigSnapshot(agentId: String, appId: String) -> AppConfigSnapshot {
        return storage.withLock { ledgerState in
            return AppConfigSnapshot(
                revision: ledgerState.appConfigRevisions[agentId]?[appId] ?? 0,
                overrides: ledgerState.appConfigOverrides[agentId]?[appId] ?? [:]
            )
        }
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
        return storage.withLock { ledgerState in
            let current = ledgerState.appConfigRevisions[agentId]?[appId] ?? 0
            guard expectedRevision == current else {
                return .revisionStale(current: current)
            }
            var overrides = ledgerState.appConfigOverrides[agentId]?[appId] ?? [:]
            for (key, value) in set { overrides[key] = value }
            for key in unset { overrides.removeValue(forKey: key) }
            ledgerState.appConfigOverrides[agentId, default: [:]][appId] = overrides
            ledgerState.appConfigRevisions[agentId, default: [:]][appId] = current + 1
            return .applied(AppConfigSnapshot(revision: current + 1, overrides: overrides))
        }
    }

    // MARK: - Agent send receipts and the send commit lock

    /// The stored idempotency receipt for one `server\nagent\nkey`.
    func sendReceipt(key: String) -> AgentApiSendReceipt? {
        return storage.withLock { ledgerState in
            return ledgerState.agentApiSendReceipts[key]
        }
    }

    func setSendReceipt(_ receipt: AgentApiSendReceipt, key: String) {
        storage.withLock { ledgerState in
            ledgerState.agentApiSendReceipts[key] = receipt
        }
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
    /// A prepared encrypted replacement. `nil` leaves credential and version untouched.
    var credential: ProviderCredentialEnvelope?
}

extension ManagedMCPAndCardsStore {
    /// Whether the provider-connections surface is enabled for the server.
    func isProviderConnectionsEnabled(serverId: String) -> Bool {
        return storage.withLock { ledgerState in
            return ledgerState.providerConnectionsEnabledServers.contains(serverId)
        }
    }

    /// The server's provider connections, in creation order.
    func providerConnections(serverId: String) -> [ProviderConnection] {
        return storage.withLock { ledgerState in
            return ledgerState.providerConnections.filter { $0.serverId == serverId }
        }
    }

    /// The metadata and actual sealed credential become visible in one owner transaction.
    func insertProviderConnection(_ connection: ProviderConnection, credential: ProviderCredentialEnvelope) throws {
        guard connection.hasCredential, credential.hasSupportedFormat else {
            throw ProviderCredentialError.invalidPersistedCredentials
        }
        try storage.withLock { ledgerState in
            guard !ledgerState.providerConnections.contains(where: { $0.id == connection.id }) else {
                throw ProviderCredentialError.invalidPersistedCredentials
            }
            ledgerState.providerConnections.append(connection)
            ledgerState.providerCredentials[connection.id] = credential
        }
    }

    func containsProviderConnection(id: String, serverId: String) -> Bool {
        storage.withLock { ledgerState in
            ledgerState.providerConnections.contains { $0.id == id && $0.serverId == serverId }
        }
    }

    /// One scoped snapshot; decryption happens after the owner borrow is released.
    func providerCredential(id: String, serverId: String) -> ProviderCredentialEnvelope? {
        storage.withLock { ledgerState in
            guard ledgerState.providerConnections.contains(where: {
                $0.id == id && $0.serverId == serverId && $0.hasCredential
            }) else { return nil }
            return ledgerState.providerCredentials[id]
        }
    }

    /// Applies a patch in one critical section and answers the stored row, or
    /// `nil` when the connection is not the server's.
    func patchProviderConnection(
        id: String,
        serverId: String,
        patch: ProviderConnectionPatch,
        now: Date
    ) throws -> ProviderConnection? {
        return try storage.withLock { ledgerState in
            guard let index = ledgerState.providerConnections.firstIndex(where: { $0.id == id && $0.serverId == serverId }) else {
                return nil
            }
            if let credential = patch.credential {
                guard credential.hasSupportedFormat,
                      ledgerState.providerConnections[index].credentialVersion < Int.max else {
                    throw ProviderCredentialError.invalidPersistedCredentials
                }
            }
            if let name = patch.name { ledgerState.providerConnections[index].name = name }
            if let endpoint = patch.endpointUrl { ledgerState.providerConnections[index].endpointUrl = endpoint }
            if let supports = patch.supportsImageInput { ledgerState.providerConnections[index].supportsImageInput = supports }
            if let credential = patch.credential {
                ledgerState.providerCredentials[id] = credential
                ledgerState.providerConnections[index].credentialVersion += 1
                ledgerState.providerConnections[index].status = "unchecked"
                ledgerState.providerConnections[index].hasCredential = true
            }
            ledgerState.providerConnections[index].updatedAt = now
            return ledgerState.providerConnections[index]
        }
    }

    /// Rotates the credential in one critical section and answers the stored
    /// row, or `nil` when the connection is not the server's.
    func rotateProviderCredential(
        id: String, serverId: String, credential: ProviderCredentialEnvelope, now: Date
    ) throws -> ProviderConnection? {
        try patchProviderConnection(
            id: id,
            serverId: serverId,
            patch: ProviderConnectionPatch(credential: credential),
            now: now
        )
    }

    /// Whether the connection exists and the agent assignments it carries, from
    /// one snapshot.
    func providerAssignments(serverId: String, connectionId: String) -> (known: Bool, assignments: [ProviderAssignment]) {
        return storage.withLock { ledgerState in
            let known = ledgerState.providerConnections.contains { $0.id == connectionId && $0.serverId == serverId }
            let assignments = ledgerState.providerAssignments.filter { $0.connectionId == connectionId && $0.serverId == serverId }
            return (known, assignments)
        }
    }
}

// MARK: - Managed MCP control plane (ManagedMCPControlPlaneService)

extension ManagedMCPAndCardsStore {
    /// How long an agent-api idempotency key keeps replaying its first reply.
    static let agentApiIdempotencyTTL: TimeInterval = 24 * 60 * 60

    func appendManagedMCPServer(_ record: ManagedMCPServerRecord) {
        storage.withLock { ledgerState in
            ledgerState.managedMCPServers.append(record)
        }
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
        return try storage.withLock { ledgerState in
            guard let index = ledgerState.managedMCPServers.firstIndex(where: { $0.id == id && $0.serverId == serverId }) else {
                return nil
            }
            var record = ledgerState.managedMCPServers[index]
            defer { ledgerState.managedMCPServers[index] = record }
            try mutate(&record)
            return record
        }
    }

    /// Removes one server row; false when no row matched.
    func removeManagedMCPServer(serverId: String, id: String) -> Bool {
        return storage.withLock { ledgerState in
            let before = ledgerState.managedMCPServers.count
            ledgerState.managedMCPServers.removeAll { $0.id == id && $0.serverId == serverId }
            return ledgerState.managedMCPServers.count != before
        }
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
        return storage.withLock { ledgerState in
            let serverIds = Set(ledgerState.managedMCPServers.filter { $0.serverId == serverId }.map(\.id))
            var stored: [String: (enabled: Bool, allowedTools: [String]?)] = [:]
            for entry in entries {
                guard let id = entry.mcpServerId, serverIds.contains(id) else { return .unknownServer }
                stored[id] = (entry.enabled, entry.allowedTools)
            }
            ledgerState.managedMCPAssignments[agentId] = stored
            return .stored
        }
    }

    /// Sets one assignment of one agent; unknown when the server row is absent.
    func setManagedMCPAssignment(
        serverId: String,
        agentId: String,
        mcpServerId: String,
        enabled: Bool,
        allowedTools: [String]?
    ) -> ManagedMCPAssignmentWrite {
        return storage.withLock { ledgerState in
            guard ledgerState.managedMCPServers.contains(where: { $0.id == mcpServerId && $0.serverId == serverId }) else {
                return .unknownServer
            }
            ledgerState.managedMCPAssignments[agentId, default: [:]][mcpServerId] = (enabled, allowedTools)
            return .stored
        }
    }
}

// MARK: - Agent audience tokens

extension ManagedMCPAndCardsStore {
    /// The audience status of one agent; an agent without an override is
    /// `active`.
    func agentAudienceStatus(agentId: String) -> String {
        return storage.withLock { ledgerState in
            return ledgerState.agentAudienceStatusOverrides[agentId] ?? "active"
        }
    }

    /// Admits an App token for the `agent\nclient` grant key unless the grant
    /// was revoked, and records the grant as live on first use. The check and
    /// the write are one critical section, so a revocation cannot slip between
    /// them. `false` when the grant is revoked.
    func claimAgentIntegrationGrant(key: String) -> Bool {
        return storage.withLock { ledgerState in
            if ledgerState.agentIntegrationGrants[key] == true { return false }
            ledgerState.agentIntegrationGrants[key] = false
            return true
        }
    }
}
