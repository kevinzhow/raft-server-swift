import Foundation

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
        var appConfigOverrides: [String: [String: [String: Any]]] = [:]
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

    var appConfigOverrides: [String: [String: [String: Any]]] {
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
}
